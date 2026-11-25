// Comprehensive tests for backup targets configuration, SFB1 streaming encryption, zero-dep AWS SigV4 S3/R2 client,
// S3Place, Copies policy & S3 sync/restore, and /copies/settings + /copies/s3/test + /copies/restore HTTP routes.
import assert from "node:assert/strict";
import { createHash, createHmac } from "node:crypto";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { afterEach, test } from "node:test";
import { Effect, Exit, Scope, type Clock } from "effect";
import { TestClock } from "effect/testing";
import { PeerBus, Refused, bytesOf, withBytes } from "../src/mesh/bus.ts";
import { Fibers } from "../src/ops/fibers.ts";
import { ConfigFile } from "../src/ops/config.ts";
import { checkConfig } from "../src/accounts/check.ts";
import { Copies, historyFile, keptDir } from "../src/replica/copies.ts";
import { outcomeFile } from "../src/replica/restore.ts";
import {
  type NormalizedBackupConfig,
  type NormalizedS3Target,
  applyBackupUpdate,
  checkBackupConfig,
  keyFingerprint,
  readBackupConfig,
} from "../src/replica/backup-config.ts";
import { parseEncryptionKey, sfb1Open, sfb1OpenStream, sfb1Seal, sfb1SealStream } from "../src/replica/crypto.ts";
import { S3Client, S3Place, encodeS3Path, extractAllXmlTags, extractXmlTag, formatAmzDate, rfc3986Encode, unescapeXml } from "../src/replica/s3.ts";
import { routes as copiesRoutes } from "../src/api/routes/copies.ts";
import { takeBack } from "./reference/replica-restore.ts";
import { InlineRunner } from "./reference/replica-work.ts";
import { Store } from "../src/store/store.ts";
import { HOME, dataDir, rowsOf, station } from "./replica-fakes.ts";

type Json = any;
const scopes: Scope.Closeable[] = [];
const closing: (() => Promise<void>)[] = [];

afterEach(async () => {
  for (const c of closing.splice(0).reverse()) await c().catch(() => {});
  for (const s of scopes.splice(0)) await Effect.runPromise(Scope.close(s, Exit.void));
});

function testClock(): Clock.Clock & { move: (ms: number) => Promise<void> } {
  const scope = Effect.runSync(Scope.make());
  scopes.push(scope);
  const clock = Effect.runSync(Scope.provide(TestClock.make(), scope));
  return Object.assign(clock, { move: (ms: number) => Effect.runPromise(clock.adjust(`${ms} millis`)) });
}

const sid = (c: string) => c.repeat(64);
const TEST_KEY = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

function escapeXml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&apos;");
}

/// Deterministic in-memory mock S3 HTTP server on 127.0.0.1 supporting ListObjectsV2 pagination, GET, PUT, DELETE,
/// and Multipart Upload (Create / UploadPart / Complete / Abort) with optional SigV4 auth checking and failure injection.
class MockS3Server {
  readonly objects = new Map<string, Buffer>();
  readonly uploads = new Map<string, { key: string; parts: Map<number, { etag: string; data: Buffer }> }>();
  readonly abortedUploads: string[] = [];
  readonly completedUploads: string[] = [];
  readonly puts: string[] = [];
  readonly singleDeletes: string[] = [];
  readonly batchDeletes: string[][] = [];
  readonly failDeleteKeys = new Map<string, { code: string; message: string }>();
  readonly omitDeleteKeys = new Set<string>();
  maxListKeys = 1000;
  failPartNumber: number | null = null;
  requireAuth = true;
  accessKeyId = "AKIA_TEST_KEY_12345";
  secretAccessKey = "SECRET_TEST_VALUE_67890";
  region = "auto";
  bucket = "test-bucket";
  #nextUpload = 1;
  #server = createServer((req, res) => void this.#handle(req, res));
  endpoint = "";

  async start(): Promise<void> {
    await new Promise<void>((resolve) => {
      this.#server.listen(0, "127.0.0.1", () => {
        const addr = this.#server.address();
        assert.ok(addr !== null && typeof addr === "object");
        this.endpoint = `http://127.0.0.1:${addr.port}`;
        resolve();
      });
    });
    closing.push(() => new Promise<void>((resolve) => this.#server.close(() => resolve())));
  }

  target(overrides: Partial<NormalizedS3Target> = {}): NormalizedS3Target {
    return {
      id: "r2main",
      name: "Cloudflare R2",
      endpoint: this.endpoint,
      region: this.region,
      bucket: this.bucket,
      prefix: "stillfail-backup",
      forcePathStyle: true,
      accessKeyId: this.accessKeyId,
      secretAccessKey: this.secretAccessKey,
      encryptionKey: TEST_KEY,
      includeTranscripts: true,
      ...overrides,
    };
  }

  async #readBody(req: IncomingMessage): Promise<Buffer> {
    const chunks: Buffer[] = [];
    for await (const c of req) chunks.push(Buffer.isBuffer(c) ? c : Buffer.from(c));
    return Buffer.concat(chunks);
  }

  #verifySigV4(req: IncomingMessage, url: URL, body: Buffer): boolean {
    const auth = req.headers.authorization;
    const amzDate = req.headers["x-amz-date"];
    const payloadHash = req.headers["x-amz-content-sha256"];
    if (typeof auth !== "string" || typeof amzDate !== "string" || typeof payloadHash !== "string") return false;
    const m = /^AWS4-HMAC-SHA256 Credential=([^/]+)\/(\d{8})\/([^/]+)\/s3\/aws4_request, SignedHeaders=([^,]+), Signature=([0-9a-f]{64})$/.exec(auth);
    if (m === null) return false;
    const [, ak, dateStamp, region, signedHeaders, sig] = m;
    if (ak !== this.accessKeyId || region !== this.region) return false;
    if (createHash("sha256").update(body).digest("hex") !== payloadHash) return false;

    const queryPairs: [string, string][] = [];
    for (const [k, v] of url.searchParams.entries()) queryPairs.push([rfc3986Encode(k), rfc3986Encode(v)]);
    queryPairs.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : 0));
    const canonicalQuery = queryPairs.map(([k, v]) => `${k}=${v}`).join("&");

    const hdrNames = signedHeaders!.split(";");
    const canonicalHeaders = hdrNames.map((h) => `${h}:${String(req.headers[h] ?? "").trim()}\n`).join("");
    const canonicalRequest = `${req.method}\n${url.pathname}\n${canonicalQuery}\n${canonicalHeaders}\n${signedHeaders}\n${payloadHash}`;
    const scope = `${dateStamp}/${region}/s3/aws4_request`;
    const stringToSign = `AWS4-HMAC-SHA256\n${amzDate}\n${scope}\n${createHash("sha256").update(canonicalRequest).digest("hex")}`;
    const kDate = createHmac("sha256", `AWS4${this.secretAccessKey}`).update(dateStamp!).digest();
    const kRegion = createHmac("sha256", kDate).update(region!).digest();
    const kService = createHmac("sha256", kRegion).update("s3").digest();
    const kSigning = createHmac("sha256", kService).update("aws4_request").digest();
    const expected = createHmac("sha256", kSigning).update(stringToSign).digest("hex");
    return expected === sig;
  }

  async #handle(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const body = await this.#readBody(req);
    const url = new URL(req.url ?? "/", this.endpoint);
    if (this.requireAuth && !this.#verifySigV4(req, url, body)) {
      res.writeHead(403, { "content-type": "application/xml" });
      res.end(`<Error><Code>SignatureDoesNotMatch</Code><Message>Invalid SigV4</Message></Error>`);
      return;
    }

    const prefixBucket = `/${this.bucket}`;
    if (url.pathname !== prefixBucket && !url.pathname.startsWith(`${prefixBucket}/`)) {
      res.writeHead(404, { "content-type": "application/xml" });
      res.end(`<Error><Code>NoSuchBucket</Code><Message>Bucket not found</Message></Error>`);
      return;
    }
    const rawKey = url.pathname.length > prefixBucket.length + 1 ? decodeURIComponent(url.pathname.slice(prefixBucket.length + 1)) : "";

    // ListObjectsV2
    if (req.method === "GET" && url.searchParams.get("list-type") === "2") {
      const prefix = url.searchParams.get("prefix") ?? "";
      const maxKeys = Math.min(this.maxListKeys, parseInt(url.searchParams.get("max-keys") ?? "1000", 10) || 1000);
      const token = url.searchParams.get("continuation-token");
      const all = [...this.objects.keys()].filter((k) => k.startsWith(prefix)).sort();
      const start = token !== null ? parseInt(token, 10) : 0;
      const page = all.slice(start, start + maxKeys);
      const truncated = start + page.length < all.length;
      const nextToken = truncated ? String(start + page.length) : "";
      const contents = page.map((k) => `<Contents><Key>${escapeXml(k)}</Key><Size>${this.objects.get(k)!.length}</Size></Contents>`).join("");
      res.writeHead(200, { "content-type": "application/xml" });
      res.end(
        `<ListBucketResult><IsTruncated>${truncated ? "true" : "false"}</IsTruncated>${truncated ? `<NextContinuationToken>${nextToken}</NextContinuationToken>` : ""}${contents}</ListBucketResult>`,
      );
      return;
    }

    // CreateMultipartUpload
    if (req.method === "POST" && url.searchParams.has("uploads")) {
      const uid = `up-${this.#nextUpload++}`;
      this.uploads.set(uid, { key: rawKey, parts: new Map() });
      res.writeHead(200, { "content-type": "application/xml" });
      res.end(`<InitiateMultipartUploadResult><UploadId>${uid}</UploadId></InitiateMultipartUploadResult>`);
      return;
    }

    // UploadPart
    if (req.method === "PUT" && url.searchParams.has("uploadId") && url.searchParams.has("partNumber")) {
      const uid = url.searchParams.get("uploadId")!;
      const pn = parseInt(url.searchParams.get("partNumber")!, 10);
      const up = this.uploads.get(uid);
      if (up === undefined) {
        res.writeHead(404);
        res.end();
        return;
      }
      if (this.failPartNumber === pn) {
        res.writeHead(500, { "content-type": "application/xml" });
        res.end(`<Error><Code>InternalError</Code><Message>injected part failure</Message></Error>`);
        return;
      }
      const etag = `"${createHash("md5").update(body).digest("hex")}"`;
      up.parts.set(pn, { etag, data: body });
      res.writeHead(200, { etag });
      res.end();
      return;
    }

    // CompleteMultipartUpload
    if (req.method === "POST" && url.searchParams.has("uploadId")) {
      const uid = url.searchParams.get("uploadId")!;
      const up = this.uploads.get(uid);
      if (up === undefined) {
        res.writeHead(404);
        res.end();
        return;
      }
      const partNums = extractAllXmlTags(body.toString("utf8"), "PartNumber").map((s) => parseInt(s, 10));
      const assembled = Buffer.concat(partNums.map((n) => up.parts.get(n)!.data));
      this.objects.set(up.key, assembled);
      this.puts.push(up.key);
      this.uploads.delete(uid);
      this.completedUploads.push(uid);
      res.writeHead(200, { "content-type": "application/xml" });
      res.end(`<CompleteMultipartUploadResult><Key>${escapeXml(up.key)}</Key></CompleteMultipartUploadResult>`);
      return;
    }

    // AbortMultipartUpload
    if (req.method === "DELETE" && url.searchParams.has("uploadId")) {
      const uid = url.searchParams.get("uploadId")!;
      this.uploads.delete(uid);
      this.abortedUploads.push(uid);
      res.writeHead(204);
      res.end();
      return;
    }

    // DeleteObjects (POST /?delete)
    if (req.method === "POST" && url.searchParams.has("delete")) {
      const expectedMd5 = createHash("md5").update(body).digest("base64");
      if (req.headers["content-md5"] !== expectedMd5) {
        res.writeHead(400, { "content-type": "application/xml" });
        res.end(`<Error><Code>InvalidDigest</Code><Message>Missing or mismatched Content-MD5</Message></Error>`);
        return;
      }
      const keys = extractAllXmlTags(body.toString("utf8"), "Key");
      this.batchDeletes.push(keys);
      const deletedXml: string[] = [];
      const errorXml: string[] = [];
      for (const k of keys) {
        if (this.omitDeleteKeys.has(k)) continue;
        const fail = this.failDeleteKeys.get(k);
        if (fail !== undefined) {
          errorXml.push(`<Error><Key>${escapeXml(k)}</Key><Code>${escapeXml(fail.code)}</Code><Message>${escapeXml(fail.message)}</Message></Error>`);
        } else {
          this.objects.delete(k);
          deletedXml.push(`<Deleted><Key>${escapeXml(k)}</Key></Deleted>`);
        }
      }
      res.writeHead(200, { "content-type": "application/xml" });
      res.end(`<DeleteResult>${deletedXml.join("")}${errorXml.join("")}</DeleteResult>`);
      return;
    }

    // Standard object GET / PUT / DELETE
    if (req.method === "PUT") {
      this.objects.set(rawKey, body);
      this.puts.push(rawKey);
      res.writeHead(200);
      res.end();
      return;
    }
    if (req.method === "GET") {
      const data = this.objects.get(rawKey);
      if (data === undefined) {
        res.writeHead(404, { "content-type": "application/xml" });
        res.end(`<Error><Code>NoSuchKey</Code><Message>Not found</Message></Error>`);
        return;
      }
      res.writeHead(200, { "content-type": "application/octet-stream" });
      res.end(data);
      return;
    }
    if (req.method === "DELETE") {
      this.objects.delete(rawKey);
      this.singleDeletes.push(rawKey);
      res.writeHead(204);
      res.end();
      return;
    }
    res.writeHead(405);
    res.end();
  }
}

// ── 1. SFB1 Crypto tests (including cross-engine test vectors shared with MoonBit) ──

test("SFB1 encryption: empty, small, multi-frame, cross-engine vectors, and tamper/replay/truncation rejection", async () => {
  const key = parseEncryptionKey(TEST_KEY);
  const salt = Buffer.from("00112233445566778899aabbccddeeff", "hex");
  const ctx = { ws: "W1", origin: sid("a"), logicalPath: "head/lz5x0-0123abcd" };

  // Exact cross-engine vectors verified by station/mb/src/replica_coord/replica_coord_s3_wbtest.mbt
  const emptySealed = sfb1Seal(key, ctx, Buffer.alloc(0), { salt });
  assert.equal(
    emptySealed.toString("hex"),
    "5346423100112233445566778899aabbccddeeff000000000140a2e9bf1bf2949ec5fae9ca903efa96",
  );
  assert.deepEqual(sfb1Open(key, ctx, emptySealed), Buffer.alloc(0));

  const multiSealed = sfb1Seal(key, ctx, Buffer.from("hello world!", "utf8"), { salt, frameMax: 6 });
  assert.equal(
    multiSealed.toString("hex"),
    "5346423100112233445566778899aabbccddeeff00000006002e63aae6fe5b61738dcd97164d941d7f8367508a978800000006015b8d9be61e0c9263c0e4ff3a687527e0dd690945bb93",
  );
  assert.equal(sfb1Open(key, ctx, multiSealed).toString("utf8"), "hello world!");

  // Streaming seal + open across multiple frames & irregular chunk sizes
  const big = Buffer.alloc(50_000);
  for (let i = 0; i < big.length; i++) big[i] = (i * 31 + 7) & 0xff;
  async function* irregular(buf: Buffer) {
    for (let i = 0; i < buf.length; i += 1337) yield buf.subarray(i, Math.min(i + 1337, buf.length));
  }
  const encChunks: Buffer[] = [];
  for await (const c of sfb1SealStream(key, ctx, irregular(big), { frameMax: 4096 })) encChunks.push(c);
  const encWhole = Buffer.concat(encChunks);
  assert.deepEqual(sfb1Open(key, ctx, encWhole), big);

  const decChunks: Buffer[] = [];
  for await (const c of sfb1OpenStream(key, ctx, irregular(encWhole))) decChunks.push(c);
  assert.deepEqual(Buffer.concat(decChunks), big);

  // Tampering ciphertext or tag -> rejected
  const tampered = Buffer.from(multiSealed);
  tampered[tampered.length - 1]! ^= 0x01;
  assert.throws(() => sfb1Open(key, ctx, tampered));

  // Truncation -> rejected
  assert.throws(() => sfb1Open(key, ctx, multiSealed.subarray(0, multiSealed.length - 1)));
  // Truncated after first non-final frame -> rejected
  const firstFrameEnd = 20 + 5 + 6 + 16;
  assert.throws(() => sfb1Open(key, ctx, multiSealed.subarray(0, firstFrameEnd)));

  // Trailing bytes after final frame -> rejected
  assert.throws(() => sfb1Open(key, ctx, Buffer.concat([multiSealed, Buffer.from([0x00])])));

  // Reordering frames -> rejected (index & final flag bound in nonce + AAD)
  const f0 = multiSealed.subarray(20, firstFrameEnd);
  const f1 = multiSealed.subarray(firstFrameEnd);
  assert.throws(() => sfb1Open(key, ctx, Buffer.concat([multiSealed.subarray(0, 20), f1, f0])));

  // Cross-ws / cross-origin / cross-logicalPath replay -> rejected
  assert.throws(() => sfb1Open(key, { ...ctx, ws: "W2" }, multiSealed));
  assert.throws(() => sfb1Open(key, { ...ctx, origin: sid("b") }, multiSealed));
  assert.throws(() => sfb1Open(key, { ...ctx, logicalPath: "head/other" }, multiSealed));
});

// ── 2. AWS SigV4, XML escaping, pagination, and Multipart Upload tests ──

test("S3Client: SigV4 path/virtual-hosted URLs, pagination, XML escaping, multipart upload & abort on failure", async () => {
  assert.deepEqual(formatAmzDate(Date.UTC(2026, 10, 22, 13, 11, 6)), {
    dateStamp: "20261122",
    amzDate: "20261122T131106Z",
  });
  assert.equal(rfc3986Encode("a b/c~d!e'f(g)h*i"), "a%20b%2Fc~d%21e%27f%28g%29h%2Ai");
  assert.equal(encodeS3Path("dir/a b/file+1.enc"), "dir/a%20b/file%2B1.enc");
  assert.equal(unescapeXml("a&amp;b&lt;c&gt;&quot;d&quot;&apos;e&#33;&#x21;"), "a&b<c>\"d\"'e!!");
  assert.equal(extractXmlTag("<Root><Key>p/a&amp;b</Key></Root>", "Key"), "p/a&b");

  const s3 = new MockS3Server();
  await s3.start();

  // Virtual-hosted URL signing shape check
  const vhostClient = new S3Client(
    s3.target({ endpoint: "https://s3.us-east-1.amazonaws.com", forcePathStyle: false, bucket: "my-bkt" }),
    { now: () => Date.UTC(2026, 10, 22, 12, 0, 0) },
  );
  const signedVhost = vhostClient.signRequest("GET", "a/b c.enc", { "z": "1", "a": "2" }, Buffer.alloc(0));
  assert.equal(signedVhost.url, "https://my-bkt.s3.us-east-1.amazonaws.com/a/b%20c.enc?a=2&z=1");
  assert.match(signedVhost.headers.authorization!, /^AWS4-HMAC-SHA256 Credential=AKIA_TEST_KEY_12345\/20261122\/auto\/s3\/aws4_request/);

  // Connection test & pagination with XML special chars
  const client = new S3Client(s3.target(), { multipartThreshold: 1024, multipartPartSize: 512 });
  await client.testConnection();
  s3.maxListKeys = 2;
  for (const k of ["stillfail-backup/k1", "stillfail-backup/k2&x", "stillfail-backup/k3", "stillfail-backup/k4", "stillfail-backup/k5"]) {
    await client.putObject(k, Buffer.from(`val:${k}`));
  }
  const listed = await client.listPrefix("stillfail-backup/");
  assert.deepEqual(listed, ["stillfail-backup/k1", "stillfail-backup/k2&x", "stillfail-backup/k3", "stillfail-backup/k4", "stillfail-backup/k5"]);
  assert.equal((await client.getObject("stillfail-backup/k2&x")).toString("utf8"), "val:stillfail-backup/k2&x");

  // Multipart upload above threshold
  const payload = Buffer.alloc(2300, 0x42);
  async function* chunked(b: Buffer) {
    for (let i = 0; i < b.length; i += 400) yield b.subarray(i, Math.min(i + 400, b.length));
  }
  await client.putStream("stillfail-backup/big.bin", chunked(payload));
  assert.equal(s3.completedUploads.length, 1);
  assert.deepEqual(s3.objects.get("stillfail-backup/big.bin"), payload);

  // Multipart upload failure triggers AbortMultipartUpload
  s3.failPartNumber = 2;
  await assert.rejects(() => client.putStream("stillfail-backup/fail.bin", chunked(payload)));
  assert.equal(s3.abortedUploads.length, 1);
  assert.equal(s3.objects.has("stillfail-backup/fail.bin"), false);
  s3.failPartNumber = null;
});

// ── 3. End-to-end Copies with Mock S3: sync, dedup, rollback new gen, prune, zero-peer restore ──

function across(v: Json): Json {
  const bytes = bytesOf(v);
  const copy = JSON.parse(JSON.stringify(v));
  return bytes === null ? copy : withBytes(copy, bytes);
}

type Node = {
  id: string;
  data: string;
  store: Store;
  copies: Copies;
  up: boolean;
  workspaces: string[];
  bus: PeerBus;
  backup: NormalizedBackupConfig;
};

class Mesh {
  readonly nodes = new Map<string, Node>();
  readonly rosters = new Map<string, string[]>();
  readonly clock = testClock();

  add(
    id: string,
    workspaces: string[],
    opts: { made?: { data: string; store: Store }; backup?: NormalizedBackupConfig } = {},
  ): Node {
    const data = opts.made?.data ?? dataDir(id.slice(0, 4));
    const store = opts.made?.store ?? Store.open(join(data, "stillfail.db"), join(data, "archive"));
    const bus = new PeerBus({ sleep: async () => {} });
    const fibers = new Fibers("copies", this.clock);
    const node = {
      id,
      data,
      store,
      up: true,
      workspaces,
      bus,
      backup: opts.backup ?? { mode: "auto", stations: [], acceptOthers: true, s3: [] },
    } as Node;
    bus.attach(async (to, ws, request) => {
      const there = this.nodes.get(to);
      if (there === undefined || !there.up || !node.up) throw new Error("station unreachable");
      if (ws !== null && (!there.workspaces.includes(ws) || !(this.rosters.get(ws) ?? []).includes(id))) {
        throw new Error("peer is not another station in this workspace");
      }
      return across(await there.bus.handle(ws ?? "", id, across(request)));
    });
    const runner = new InlineRunner({
      db: join(data, "stillfail.db"),
      replica: join(data, "replica"),
      dataDir: data,
      origin: id,
      now: () => this.clock.currentTimeMillisUnsafe(),
    });
    node.copies = new Copies({
      data,
      here: () => id,
      places: () => ({ home: node.workspaces[0] ?? null, workspaces: node.workspaces.map((w) => ({ workspace: w, name: `${id.slice(0, 4)} in ${w}` })) }),
      roster: (ws) => (this.rosters.get(ws) ?? []).map((s) => ({ id: s, name: s.slice(0, 4) })),
      ask: (s, r) => bus.ask(s, r),
      runner,
      fibers,
      changed: () => {},
      restart: async () => null,
      backup: () => node.backup,
    });
    bus.on("replica.", node.copies.answers());
    store.subscribe((c) => node.copies.told(c));
    this.nodes.set(id, node);
    closing.push(async () => {
      await node.copies.close();
      await runner.close();
      await fibers.close();
      try { store.close(); } catch {}
    });
    return node;
  }

  async settle(): Promise<void> {
    for (let i = 0; i < 3; i++) for (const n of this.nodes.values()) if (n.up) await n.copies.settle();
  }
}

function holders(mesh: Mesh, ws: string, origin: string): string[] {
  return [...mesh.nodes.values()]
    .filter(
      (n) =>
        existsSync(join(keptDir(n.data), ws, origin)) &&
        readdirSync(join(keptDir(n.data), ws, origin)).some((g) => existsSync(join(keptDir(n.data), ws, origin, g, "head.json"))),
    )
    .map((n) => n.id);
}

test("Copies S3 end-to-end: sync, file dedup, prune, rollback new gen, and zero-peer S3 discovery + restore", async () => {
  const s3 = new MockS3Server();
  await s3.start();
  const s3Target = s3.target();

  const mesh = new Mesh();
  const [A, D] = [sid("a"), sid("d")];
  mesh.rosters.set(HOME, [A]);
  const made = station();
  const a = mesh.add(A, [HOME], {
    made,
    backup: { mode: "manual", stations: [], acceptOthers: true, s3: [s3Target] },
  });
  await a.copies.start();
  await mesh.settle();

  // Verify S3 objects exist and contain no plaintext ws or origin IDs in keys
  assert.ok(s3.objects.size > 0);
  for (const key of s3.objects.keys()) {
    assert.ok(!key.includes(HOME), `key should not contain plaintext ws: ${key}`);
    assert.ok(!key.includes(A), `key should not contain plaintext origin: ${key}`);
  }
  const ov = a.copies.overview(HOME, true) as Json;
  assert.equal(ov.backup.s3.length, 1);
  assert.equal(ov.backup.s3[0].error, null);
  assert.ok(ov.backup.s3[0].to > 0);

  // Incremental pass: file is NOT re-uploaded (deduped)
  const filePutsBefore = s3.puts.filter((k) => k.includes("/files/")).length;
  assert.ok(filePutsBefore > 0);
  made.store.deleteSession(made.deleted);
  await mesh.settle();
  const filePutsAfter = s3.puts.filter((k) => k.includes("/files/")).length;
  assert.equal(filePutsAfter, filePutsBefore, "existing files must not be re-uploaded");

  // Station A dies; brand new empty station D joins with ZERO peers and ONLY the same S3 target!
  a.up = false;
  mesh.rosters.set(HOME, [D]);
  const d = mesh.add(D, [HOME], {
    backup: { mode: "manual", stations: [], acceptOthers: true, s3: [s3Target] },
  });
  await d.copies.start();
  await d.copies.settle();

  const list = (await d.copies.restorable(HOME)) as Json[];
  assert.equal(list.length, 1);
  assert.equal(list[0].station, A);
  assert.deepEqual(list[0].from, [{ s3: s3Target.id, name: s3Target.name }]);

  // Restore directly from S3 and verify identical DB rows
  await d.copies.restore(HOME, A, list[0].gen, { s3: s3Target.id });
  d.store.close();
  const ready = takeBack(d.data, join(d.data, "stillfail.db"), 0);
  assert.ok(ready !== null);
  const restoredDb = new DatabaseSync(join(d.data, "stillfail.db"));
  closing.push(async () => restoredDb.close());
  const origDb = new DatabaseSync(join(a.data, "stillfail.db"));
  closing.push(async () => origDb.close());

  const want = rowsOf(origDb, null, a.data, d.data);
  const got = rowsOf(restoredDb, null);
  for (const table of Object.keys(want)) {
    assert.deepEqual([...got[table]!.entries()].sort(), [...want[table]!.entries()].sort(), `${table} restored from S3`);
  }
  assert.ok(want.entries!.size > 30);

  // Verify S3 rollback detection (`behind` -> new generation on S3Place)
  const place = new S3Place(s3Target);
  const heldBefore = await place.held(HOME, A);
  assert.equal(heldBefore.gens.length, 1);
  // Simulate a future generation already on S3: `behind()` triggers new generation on next pass
  const fakeFutureGen = "zzzzzz-12345678";
  const futureHead = { ...heldBefore.gens[0]!.head!, gen: fakeFutureGen };
  await place.put(HOME, A, fakeFutureGen, "head", "head.json", Buffer.from(JSON.stringify(futureHead)));
  a.up = true;
  mesh.rosters.set(HOME, [A]);
  await a.copies.start();
  await a.copies.settle();
  const heldAfter = await place.held(HOME, A);
  assert.ok(heldAfter.gens.length >= 3, "rollback should create a new generation beside the existing ones");
});

// ── 4. Policy controls: manual stations, stations: [], acceptOthers: false ──

test("Backup policies: manual station list, stations: [] (S3-only), and acceptOthers: false refusal + auto skip", async () => {
  const s3 = new MockS3Server();
  await s3.start();
  const mesh = new Mesh();
  const [A, B, C, D] = [sid("a"), sid("b"), sid("c"), sid("d")];
  mesh.rosters.set(HOME, [A, B, C, D]);
  const made = station();
  // Manual mode: A only backs up to C (not B or D)
  const a = mesh.add(A, [HOME], {
    made,
    backup: { mode: "manual", stations: [C], acceptOthers: true, s3: [s3.target()] },
  });
  const b = mesh.add(B, [HOME]);
  const c = mesh.add(C, [HOME]);
  const d = mesh.add(D, [HOME]);
  for (const n of mesh.nodes.values()) await n.copies.start();
  await mesh.settle();

  assert.deepEqual(holders(mesh, HOME, A), [C]);
  assert.ok(s3.objects.size > 0);

  // Switch A to stations: [] (S3 only)
  a.backup = { mode: "manual", stations: [], acceptOthers: true, s3: [s3.target()] };
  a.copies.configChanged();
  await mesh.settle();
  assert.deepEqual((a.copies.overview(HOME, true) as Json).keepers, []);

  // Switch B to acceptOthers: false -> rejects inbound replica.put and auto mode skips B
  b.backup = { mode: "auto", stations: [], acceptOthers: false, s3: [] };
  b.copies.configChanged();
  await mesh.settle();

  // Direct replica.put to B is refused with "not accepting copies"
  await assert.rejects(
    () =>
      a.bus.ask(
        B,
        withBytes(
          { method: "replica.put", workspace: HOME, origin: A, gen: "lz5x0-0123abcd", kind: "head", name: "head.json" },
          (async function* () {
            yield Buffer.from("{}");
          })(),
        ),
      ),
    (e: unknown) => e instanceof Refused && e.message.includes("not accepting copies"),
  );

  // Switch A back to auto mode: should pick C and D (skipping B which has acceptOthers: false)
  a.backup = { mode: "auto", stations: [], acceptOthers: true, s3: [] };
  a.copies.configChanged();
  await mesh.settle();
  const autoHolders = holders(mesh, HOME, A).sort();
  assert.ok(!autoHolders.includes(B), "auto mode must skip peer with acceptOthers === false");
  assert.deepEqual(autoHolders, [C, D].sort());
});

// ── 5. HTTP routes: GET/PUT /copies/settings, POST /copies/s3/test, POST /copies/restore ──

test("HTTP routes: /copies/settings secret redaction, key generation, secret preservation, validation, RBAC, and /copies/s3/test", async () => {
  const s3 = new MockS3Server();
  await s3.start();

  const dir = dataDir("routes");
  mkdirSync(dir, { recursive: true });
  const config = new ConfigFile(dir);
  config.check = (raw, d) => checkConfig(raw, d);

  const mesh = new Mesh();
  const A = sid("a");
  const B = sid("b");
  mesh.rosters.set(HOME, [A, B]);
  const a = mesh.add(A, [HOME]);
  // Bind copies backup config to live ConfigFile
  const runner = new InlineRunner({
    db: join(a.data, "stillfail.db"),
    replica: join(a.data, "replica"),
    dataDir: a.data,
    origin: A,
    now: () => mesh.clock.currentTimeMillisUnsafe(),
  });
  closing.push(async () => await runner.close());
  const fibers = new Fibers("routes", mesh.clock);
  closing.push(async () => await fibers.close());
  const copies = new Copies({
    data: a.data,
    here: () => A,
    places: () => ({ home: HOME, workspaces: [{ workspace: HOME, name: "test" }] }),
    roster: () => [{ id: A, name: "A" }, { id: B, name: "B" }],
    ask: (s, r) => a.bus.ask(s, r),
    runner,
    fibers,
    changed: () => {},
    restart: async () => null,
    backup: () => readBackupConfig(config.raw()),
  });
  closing.push(async () => await copies.close());
  await copies.start();

  const routeList = copiesRoutes({ copies, retire: {} as any, starts: false, config, changed: () => {} });
  const call = async (method: string, path: string, bodyObj: unknown, role: "owner" | "member" = "owner") => {
    const r = routeList.find((x) => x.method === method && x.pattern.test(path));
    assert.ok(r, `route ${method} ${path} should exist`);
    const m = path.match(r.pattern)!;
    return r.handle({
      method,
      path,
      query: new URLSearchParams(),
      headers: {},
      body: Buffer.from(bodyObj === undefined ? "" : JSON.stringify(bodyObj), "utf8"),
      viewer: { workspace: HOME, email: "u@example.com", role, device: "dev1" } as any,
      lang: "en",
    } as any, m);
  };

  // Non-manager gets 403 on all settings / test routes
  assert.equal((await call("GET", "/copies/settings", undefined, "member")).status, 403);
  assert.equal((await call("PUT", "/copies/settings", { mode: "auto" }, "member")).status, 403);
  assert.equal((await call("POST", "/copies/s3/test", {}, "member")).status, 403);

  // PUT /copies/settings: create new S3 target without encryptionKey -> auto-generated & returned once
  const put1 = await call("PUT", "/copies/settings", {
    mode: "manual",
    stations: [B],
    acceptOthers: false,
    s3: [
      {
        name: "My R2",
        endpoint: s3.endpoint,
        bucket: s3.bucket,
        prefix: "/custom-prefix/",
        accessKeyId: s3.accessKeyId,
        secretAccessKey: s3.secretAccessKey,
      },
    ],
  });
  assert.equal(put1.status, 200);
  const put1Body = JSON.parse(put1.body.toString("utf8"));
  assert.equal(put1Body.mode, "manual");
  assert.deepEqual(put1Body.stations, [B]);
  assert.equal(put1Body.acceptOthers, false);
  assert.equal(put1Body.s3.length, 1);
  const targetId = put1Body.s3[0].id as string;
  assert.match(targetId, /^[a-z0-9_-]{1,32}$/);
  assert.equal(put1Body.s3[0].prefix, "custom-prefix");
  const genKey = put1Body.generatedKeys[targetId] as string;
  assert.match(genKey, /^[0-9a-f]{64}$/);
  assert.equal(put1Body.s3[0].keyFingerprint, keyFingerprint(genKey));
  // Never leaks plaintext secrets!
  assert.equal("secretAccessKey" in put1Body.s3[0], false);
  assert.equal("encryptionKey" in put1Body.s3[0], false);
  assert.ok(!put1.body.toString("utf8").includes(s3.secretAccessKey));

  // GET /copies/settings never returns plaintext secrets or generatedKeys
  const get1 = await call("GET", "/copies/settings", undefined);
  assert.equal(get1.status, 200);
  const get1Text = get1.body.toString("utf8");
  assert.ok(!get1Text.includes(s3.secretAccessKey));
  assert.ok(!get1Text.includes(genKey));

  // PUT /copies/settings: update name & prefix while omitting accessKeyId, secretAccessKey & encryptionKey -> preserves all 3!
  const put2 = await call("PUT", "/copies/settings", {
    s3: [
      {
        id: targetId,
        name: "Renamed R2",
        endpoint: s3.endpoint,
        bucket: s3.bucket,
        prefix: "renamed-prefix",
      },
    ],
  });
  assert.equal(put2.status, 200);
  const put2Body = JSON.parse(put2.body.toString("utf8"));
  assert.deepEqual(put2Body.generatedKeys, {});
  assert.equal(put2Body.s3[0].name, "Renamed R2");
  assert.equal(put2Body.s3[0].keyFingerprint, keyFingerprint(genKey));
  const persisted = readBackupConfig(config.raw());
  assert.equal(persisted.s3[0]!.accessKeyId, s3.accessKeyId);
  assert.equal(persisted.s3[0]!.secretAccessKey, s3.secretAccessKey);
  assert.equal(persisted.s3[0]!.encryptionKey, genKey);

  // Validation errors -> 400
  assert.equal((await call("PUT", "/copies/settings", { mode: "bogus" })).status, 400);
  assert.equal((await call("PUT", "/copies/settings", { stations: ["not-a-station"] })).status, 400);
  assert.equal(
    (
      await call("PUT", "/copies/settings", {
        s3: [{ name: "Bad", endpoint: "http://example.com", bucket: "bkt", accessKeyId: "ak", secretAccessKey: "sk" }],
      })
    ).status,
    400,
  );
  assert.equal(
    (
      await call("PUT", "/copies/settings", {
        s3: [{ name: "BadKey", endpoint: s3.endpoint, bucket: "bkt", accessKeyId: "ak", secretAccessKey: "sk", encryptionKey: "zz" }],
      })
    ).status,
    400,
  );
  assert.throws(() => checkBackupConfig({ s3: [{ id: "a", name: "x", endpoint: s3.endpoint, bucket: "bkt", accessKeyId: "ak", secretAccessKey: "sk", encryptionKey: TEST_KEY }, { id: "a", name: "y", endpoint: s3.endpoint, bucket: "bkt", accessKeyId: "ak", secretAccessKey: "sk", encryptionKey: TEST_KEY }] }));
  assert.throws(() => applyBackupUpdate({}, "not-an-object"));

  // POST /copies/s3/test: success with saved id (including empty accessKeyId/secretAccessKey fallback), failure with bad secret
  const testOk = await call("POST", "/copies/s3/test", { id: targetId });
  assert.equal(testOk.status, 200);
  assert.deepEqual(JSON.parse(testOk.body.toString("utf8")), { ok: true });

  const testFallback = await call("POST", "/copies/s3/test", { id: targetId, accessKeyId: "", secretAccessKey: "" });
  assert.equal(testFallback.status, 200);
  assert.deepEqual(JSON.parse(testFallback.body.toString("utf8")), { ok: true });

  const testBad = await call("POST", "/copies/s3/test", {
    endpoint: s3.endpoint,
    bucket: s3.bucket,
    accessKeyId: s3.accessKeyId,
    secretAccessKey: "WRONG_SECRET",
  });
  assert.equal(testBad.status, 200);
  const testBadBody = JSON.parse(testBad.body.toString("utf8"));
  assert.equal(testBadBody.ok, false);
  assert.match(testBadBody.error, /403|SignatureDoesNotMatch/);

  // Verify config.json was written cleanly with backup field
  const rawOnDisk = JSON.parse(readFileSync(config.path, "utf8"));
  assert.equal(rawOnDisk.backup.s3[0].name, "Renamed R2");
});

// ── 6. Persistent backup history & GET /copies/history route ──

test("Backup history: peer & S3 sync persistence, error dedup & recovery, restore outcome merge, and GET /copies/history", async () => {
  const s3 = new MockS3Server();
  await s3.start();
  const s3Target = s3.target({ id: "r2hist", name: "R2 Hist" });

  const mesh = new Mesh();
  const [A, B] = [sid("a"), sid("b")];
  mesh.rosters.set(HOME, [A, B]);
  const made = station();
  const a = mesh.add(A, [HOME], {
    made,
    backup: { mode: "manual", stations: [B], acceptOthers: true, s3: [s3Target] },
  });
  const b = mesh.add(B, [HOME]);

  await b.copies.start();
  await a.copies.start();
  await mesh.settle();

  // Peer + S3 sync both recorded and persisted to <data>/replica/history.json
  const hist1 = a.copies.history(HOME);
  assert.ok(hist1.length >= 2, `expected at least 2 records, got ${hist1.length}`);
  const peerOk = hist1.find((r) => r.kind === "sync" && r.targetKind === "station" && r.target === B && r.status === "ok");
  const s3Ok = hist1.find((r) => r.kind === "sync" && r.targetKind === "s3" && r.target === s3Target.id && r.status === "ok");
  assert.ok(peerOk, "peer sync ok record missing");
  assert.ok(s3Ok, "s3 sync ok record missing");
  assert.equal(peerOk.targetName, B.slice(0, 4));
  assert.equal(s3Ok.targetName, "R2 Hist");
  assert.ok(peerOk.chats > 0 && peerOk.messages > 0 && peerOk.batches > 0 && peerOk.bytes > 0);
  assert.equal(peerOk.reason, null);
  assert.equal(peerOk.error, null);
  assert.ok(s3Ok.chats > 0 && s3Ok.messages > 0 && s3Ok.batches > 0 && s3Ok.bytes > 0);

  // overview.copies must NOT embed history
  const ov = a.copies.overview(HOME, true) as Json;
  assert.equal("history" in ov, false);

  // Persisted file exists and contains no secrets
  const histPath = historyFile(a.data);
  assert.ok(existsSync(histPath), "history.json should exist on disk");
  const rawHistText = readFileSync(histPath, "utf8");
  assert.ok(!rawHistText.includes(s3.secretAccessKey));
  assert.ok(!rawHistText.includes(TEST_KEY));

  // Take peer B offline and trigger multiple retries -> error deduplicated to a single record
  b.up = false;
  await mesh.clock.move(10_000);
  made.store.deleteSession(made.deleted);
  await a.copies.settle();
  const errCountAfterFirst = a.copies.history(HOME).filter((r) => r.target === B && r.status === "error").length;
  assert.equal(errCountAfterFirst, 1, "first peer failure should record 1 error");

  // Advance clock across backoff retries while B is still offline -> no duplicate error records
  await mesh.clock.move(10_000);
  await a.copies.settle();
  await mesh.clock.move(20_000);
  await a.copies.settle();
  const errCountAfterRetries = a.copies.history(HOME).filter((r) => r.target === B && r.status === "error").length;
  assert.equal(errCountAfterRetries, 1, "repeated failures with same reason must not spam history");

  // Bring B back online -> recovery records a new ok entry
  b.up = true;
  await mesh.clock.move(60_000);
  await mesh.settle();
  const okAfterRecovery = a.copies.history(HOME).filter((r) => r.target === B && r.status === "ok").length;
  assert.ok(okAfterRecovery >= 2, "recovery after failure should record a new ok entry");
  // (and a sync that went well right after one that went well to the same place took its place: never two in a row)
  for (const target of [B, s3Target.id]) {
    const mine = a.copies.history(HOME).filter((r) => r.kind === "sync" && r.target === target);
    for (let i = 1; i < mine.length; i++) assert.ok(!(mine[i - 1]!.status === "ok" && mine[i]!.status === "ok"), `two syncs that went well to ${target} in a row`);
  }

  // Restart a fresh Copies instance on the same data dir + an outcomeFile -> reloads history & merges restore record
  const restoreAt = mesh.clock.currentTimeMillisUnsafe() + 5000;
  writeFileSync(
    outcomeFile(a.data),
    JSON.stringify({
      origin: sid("c"),
      name: "OldStation",
      from: `s3:${s3Target.id}`,
      at: restoreAt,
      rows: { sessions: 3, entries: 19 },
      files: 1,
      missing: 0,
      error: null,
      reason: null,
      pending: false,
      left: 0,
    }),
  );
  const runner2 = new InlineRunner({
    db: join(a.data, "stillfail.db"),
    replica: join(a.data, "replica"),
    dataDir: a.data,
    origin: A,
    now: () => mesh.clock.currentTimeMillisUnsafe(),
  });
  closing.push(async () => await runner2.close());
  const fibers2 = new Fibers("copies-reload", mesh.clock);
  closing.push(async () => await fibers2.close());
  const reloaded = new Copies({
    data: a.data,
    here: () => A,
    places: () => ({ home: HOME, workspaces: [{ workspace: HOME, name: "A" }] }),
    roster: () => [{ id: A, name: "A" }, { id: B, name: "Cedar" }],
    ask: (s, r) => a.bus.ask(s, r),
    runner: runner2,
    fibers: fibers2,
    changed: () => {},
    restart: async () => null,
    backup: () => a.backup,
  });
  closing.push(async () => await reloaded.close());

  const reloadedHist = reloaded.history(HOME, 50);
  assert.equal(reloadedHist[0]!.kind, "restore");
  assert.equal(reloadedHist[0]!.targetKind, "s3");
  assert.equal(reloadedHist[0]!.target, s3Target.id);
  assert.equal(reloadedHist[0]!.targetName, "R2 Hist");
  assert.equal(reloadedHist[0]!.status, "ok");
  assert.equal(reloadedHist[0]!.chats, 3);
  assert.equal(reloadedHist[0]!.messages, 19);
  assert.ok(reloadedHist.some((r) => r.kind === "sync" && r.targetKind === "station" && r.status === "ok"));
  assert.ok(reloadedHist.some((r) => r.kind === "sync" && r.targetKind === "s3" && r.status === "ok"));

  // HTTP route GET /copies/history?limit=2: allowed for ordinary member, truncated, newest-first, no secrets
  const routeList = copiesRoutes({ copies: reloaded, retire: {} as any, starts: false, changed: () => {} });
  const histRoute = routeList.find((x) => x.method === "GET" && x.pattern.test("/copies/history"));
  assert.ok(histRoute, "GET /copies/history route should exist");
  const resp = await histRoute.handle(
    {
      method: "GET",
      path: "/copies/history",
      query: [["limit", "2"]],
      headers: {},
      body: Buffer.alloc(0),
      viewer: { workspace: HOME, email: "member@example.com", role: "member", device: "dev1" } as any,
      lang: "en",
    } as any,
    "/copies/history".match(histRoute.pattern)!,
  );
  assert.equal(resp.status, 200);
  const respText = resp.body.toString("utf8");
  assert.ok(!respText.includes(s3.secretAccessKey));
  assert.ok(!respText.includes(TEST_KEY));
  const respBody = JSON.parse(respText);
  assert.equal(Array.isArray(respBody.records), true);
  assert.equal(respBody.records.length, 2);
  assert.ok(respBody.records[0].at >= respBody.records[1].at);
  assert.equal(respBody.records[0].kind, "restore");

  // Restore failure on an empty station records a kind="restore", status="error" entry
  const D = sid("d");
  mesh.rosters.set(HOME, [D]);
  const emptyNode = mesh.add(D, [HOME], {
    backup: { mode: "manual", stations: [], acceptOthers: true, s3: [] },
  });
  await emptyNode.copies.start();
  await emptyNode.copies.settle();
  await assert.rejects(() => emptyNode.copies.restore(HOME, A, "lz5x0-0123abcd", { s3: "missing-s3" }));
  await emptyNode.copies.settle();
  const failHist = emptyNode.copies.history(HOME);
  assert.equal(failHist.length, 1);
  assert.equal(failHist[0]!.kind, "restore");
  assert.equal(failHist[0]!.targetKind, "s3");
  assert.equal(failHist[0]!.target, "missing-s3");
  assert.equal(failHist[0]!.status, "error");
  assert.equal(failHist[0]!.reason, "gone");
});

test("D71: S3Client.deleteObjects batches >1000 keys with Content-MD5/SigV4, handles partial errors, and S3Place reconciles post-crash orphans safely", async () => {
  const s3 = new MockS3Server();
  await s3.start();
  const target = s3.target();
  const client = new S3Client(target);

  // 1. >1000 keys (2050) -> 3 DeleteObjects batches (1000 + 1000 + 50), 0 single DELETEs, XML special chars intact
  const keys: string[] = [];
  for (let i = 0; i < 2050; i++) {
    const k = i === 7 ? "stillfail-backup/special&<key>.enc" : `stillfail-backup/k-${i}.enc`;
    s3.objects.set(k, Buffer.from("x"));
    keys.push(k);
  }
  const delRes = await client.deleteObjects(keys);
  assert.equal(delRes.deleted.length, 2050);
  assert.equal(delRes.errors.length, 0);
  assert.deepEqual(s3.batchDeletes.map((b) => b.length), [1000, 1000, 50]);
  assert.equal(s3.singleDeletes.length, 0);
  assert.equal(s3.objects.size, 0);

  // 2. S3Place.drop partial <Error>: AccessDenied throws & retains failed key; NoSuchKey treated as gone
  const { level } = await import("../src/replica/places.ts");
  const origin = sid("a");
  const gen = "1000-aaaaaaaa";
  const place = new S3Place(target);
  const hOk = sid("1");
  const hDenied = sid("2");
  const hNoSuch = sid("3");
  await place.putFile(HOME, origin, hOk, Buffer.from("ok"));
  await place.putFile(HOME, origin, hDenied, Buffer.from("denied"));
  const deniedKey = `${target.prefix}/${place.wsTag(HOME)}/${place.originTag(origin)}/files/${place.fileTag(hDenied)}.enc`;
  const noSuchKey = `${target.prefix}/${place.wsTag(HOME)}/${place.originTag(origin)}/files/${place.fileTag(hNoSuch)}.enc`;
  s3.failDeleteKeys.set(deniedKey, { code: "AccessDenied", message: "forbidden" });
  s3.failDeleteKeys.set(noSuchKey, { code: "NoSuchKey", message: "gone" });
  await assert.rejects(() => place.drop(HOME, origin, gen, [], [hOk, hDenied, hNoSuch]), /AccessDenied/);
  assert.equal(s3.objects.has(`${target.prefix}/${place.wsTag(HOME)}/${place.originTag(origin)}/files/${place.fileTag(hOk)}.enc`), false);
  assert.equal(s3.objects.has(deniedKey), true, "AccessDenied object stays in bucket");
  s3.failDeleteKeys.clear();

  // 3. Post-crash orphan reconciliation: write new head without calling drop, then fresh S3Place runs level()
  const hLive = sid("4");
  const hOrphan = sid("5");
  const orphanKey = `${target.prefix}/${place.wsTag(HOME)}/${place.originTag(origin)}/files/${place.fileTag(hOrphan)}.enc`;
  const liveKey = `${target.prefix}/${place.wsTag(HOME)}/${place.originTag(origin)}/files/${place.fileTag(hLive)}.enc`;
  await place.putFile(HOME, origin, hLive, Buffer.from("live"));
  await place.putFile(HOME, origin, hOrphan, Buffer.from("orphan"));
  const head = {
    v: 1 as const,
    origin,
    workspace: HOME,
    gen,
    name: "a",
    dataDir: "/d",
    made: 1000,
    to: 1,
    batches: [],
    files: { [hLive]: 4 },
    chats: 1,
    messages: 1,
    bytes: 4,
    runs: [{ run: "12345678", from: 1 }],
  };
  await place.put(HOME, origin, gen, "head", "head.json", Buffer.from(JSON.stringify(head)));

  // 3a. Corrupted second head present -> allHeadsVerified === false -> ZERO orphans deleted!
  const corruptHeadKey = `${target.prefix}/${place.wsTag(HOME)}/${place.originTag(origin)}/head/2000-bbbbbbbb.enc`;
  s3.objects.set(corruptHeadKey, Buffer.from("not-valid-sfb1-ciphertext"));
  const placeWithCorrupt = new S3Place(target);
  const resCorrupt = await level(placeWithCorrupt, HOME, {
    head,
    batch: async () => Buffer.alloc(0),
    sources: async () => new Map(),
  });
  assert.equal(resCorrupt.behind, false);
  assert.equal(s3.objects.has(orphanKey), true, "corrupted head disables orphan deletion");
  assert.equal(s3.objects.has(deniedKey), true, "corrupted head disables orphan deletion for all unreferenced files");

  // 3b. Remove corrupted head -> allHeadsVerified === true -> orphans batch-deleted via DeleteObjects, live kept!
  s3.objects.delete(corruptHeadKey);
  s3.batchDeletes.length = 0;
  s3.singleDeletes.length = 0;
  const placeClean = new S3Place(target);
  const resClean = await level(placeClean, HOME, {
    head,
    batch: async () => Buffer.alloc(0),
    sources: async () => new Map(),
  });
  assert.equal(resClean.behind, false);
  assert.equal(s3.objects.has(orphanKey), false, "orphan file deleted once all heads verified");
  assert.equal(s3.objects.has(deniedKey), false, "second orphan file deleted once all heads verified");
  assert.equal(s3.objects.has(liveKey), true, "live referenced file preserved");
  assert.equal(s3.batchDeletes.length, 1, "orphans reclaimed via DeleteObjects batch");
  assert.equal(s3.singleDeletes.length, 0);

  // 4. R1/R2 fix: crash-recovery orphan + local missing > 0 -> new head references pre-uploaded H while an unrelated
  //    true orphan ALSO exists: pruneOrphans MUST NOT delete H, AND MUST still clean up the unrelated true orphan!
  const hPreUploaded = sid("6");
  const hTrueOrphanWithMissing = sid("a");
  const preKey = `${target.prefix}/${place.wsTag(HOME)}/${place.originTag(origin)}/files/${place.fileTag(hPreUploaded)}.enc`;
  const trueOrphanKey = `${target.prefix}/${place.wsTag(HOME)}/${place.originTag(origin)}/files/${place.fileTag(hTrueOrphanWithMissing)}.enc`;
  await place.putFile(HOME, origin, hPreUploaded, Buffer.from("only-copy-on-s3"));
  await place.putFile(HOME, origin, hTrueOrphanWithMissing, Buffer.from("unrelated-true-orphan"));
  const headWithPre = { ...head, to: 2, made: 2000, files: { [hLive]: 4, [hPreUploaded]: 15 } };
  const placeMissing = new S3Place(target);
  const resMissing = await level(placeMissing, HOME, {
    head: headWithPre,
    batch: async () => Buffer.alloc(0),
    sources: async () => new Map(), // local copy of hPreUploaded is missing!
  });
  assert.equal(resMissing.behind, false);
  assert.equal(resMissing.missing, 1);
  assert.equal(s3.objects.has(preKey), true, "pre-uploaded file referenced by new head MUST NOT be pruned when local source is missing");
  assert.equal(s3.objects.has(trueOrphanKey), false, "unrelated true orphan MUST still be cleaned up even when missing > 0");

  // 5. R1 fix: pruneOrphans AccessDenied -> level() succeeds (best-effort) and keeps orphan for retry
  const hOrphanDenied = sid("7");
  const orphanDeniedKey = `${target.prefix}/${place.wsTag(HOME)}/${place.originTag(origin)}/files/${place.fileTag(hOrphanDenied)}.enc`;
  await place.putFile(HOME, origin, hOrphanDenied, Buffer.from("orphan-denied"));
  s3.failDeleteKeys.set(orphanDeniedKey, { code: "AccessDenied", message: "object-lock" });
  const placeBestEffort = new S3Place(target);
  const resBestEffort = await level(placeBestEffort, HOME, {
    head: headWithPre,
    batch: async () => Buffer.alloc(0),
    sources: async () => new Map(),
  });
  assert.equal(resBestEffort.behind, false, "level() succeeds even when pruneOrphans hits AccessDenied");
  assert.equal(s3.objects.has(orphanDeniedKey), true, "denied orphan stays in bucket");
  // Direct pruneOrphans still throws on AccessDenied, then succeeds once cleared
  await assert.rejects(() => placeBestEffort.pruneOrphans(HOME, origin), /AccessDenied/);
  s3.failDeleteKeys.clear();
  await placeBestEffort.pruneOrphans(HOME, origin);
  assert.equal(s3.objects.has(orphanDeniedKey), false, "orphan reclaimed on retry once AccessDenied clears");

  // 6. R1 fix: multi-gen includeTranscripts:false + corrupted head protects old-gen transcripts & files in normal drop()
  const gen2 = "3000-cccccccc";
  const hOldTr = sid("8");
  const oldTrKey = `${target.prefix}/${place.wsTag(HOME)}/${place.originTag(origin)}/files/${place.fileTag(hOldTr)}.enc`;
  await place.putFile(HOME, origin, hOldTr, Buffer.from("old-gen-transcript"));
  const headGen1WithTr = { ...headWithPre, to: 3, made: 3000, transcriptFiles: { [hOldTr]: 18 } };
  await place.put(HOME, origin, gen, "head", "head.json", Buffer.from(JSON.stringify(headGen1WithTr)));
  const headGen2 = { ...head, gen: gen2, to: 1, made: 4000, files: { [hLive]: 4 }, transcriptFiles: { [hOldTr]: 18 } };
  const placeMultiGen = new S3Place(target);
  const resMultiGen = await level(
    placeMultiGen,
    HOME,
    { head: headGen2, batch: async () => Buffer.alloc(0), sources: async () => new Map() },
    null,
    { includeTranscripts: false },
  );
  assert.equal(resMultiGen.behind, false);
  assert.equal(s3.objects.has(oldTrKey), true, "includeTranscripts:false MUST NOT delete transcript referenced by older generation");

  // Corrupted head present -> normal level() and direct S3Place.drop() skip file deletion
  const hExtra = sid("9");
  const extraKey = `${target.prefix}/${place.wsTag(HOME)}/${place.originTag(origin)}/files/${place.fileTag(hExtra)}.enc`;
  await place.putFile(HOME, origin, hExtra, Buffer.from("extra"));
  s3.objects.set(corruptHeadKey, Buffer.from("corrupted-head"));
  const placeCorruptDrop = new S3Place(target);
  await placeCorruptDrop.held(HOME, origin);
  await placeCorruptDrop.drop(HOME, origin, gen2, [], [hExtra]);
  assert.equal(s3.objects.has(extraKey), true, "S3Place.drop() MUST NOT delete files when an unverified head exists");
  s3.objects.delete(corruptHeadKey);

  // 7. R1 fix: DeleteObjects 200 response omits key B -> MissingFromResponse error, B stays in k.files
  const kA = "stillfail-backup/omit-a.enc";
  const kB = "stillfail-backup/omit-b.enc";
  s3.objects.set(kA, Buffer.from("a"));
  s3.objects.set(kB, Buffer.from("b"));
  s3.omitDeleteKeys.add(kB);
  const omitRes = await client.deleteObjects([kA, kB]);
  assert.deepEqual(omitRes.deleted, [kA]);
  assert.equal(omitRes.errors.length, 1);
  assert.equal(omitRes.errors[0]!.key, kB);
  assert.equal(omitRes.errors[0]!.code, "MissingFromResponse");
  // Via level(): omitted file hash stays in known.files
  const hOmit = sid("b");
  const hOmitKey = `${target.prefix}/${place.wsTag(HOME)}/${place.originTag(origin)}/files/${place.fileTag(hOmit)}.enc`;
  await place.putFile(HOME, origin, hOmit, Buffer.from("omit-me"));
  s3.omitDeleteKeys.add(hOmitKey);
  const placeOmit = new S3Place(target);
  const knownOmit = {
    gen: gen2,
    batches: new Set<string>(),
    files: new Set([hLive, hOmit]),
    others: new Set([hPreUploaded, hOldTr]),
    to: 1,
    made: 4000,
  };
  await assert.rejects(
    () => level(placeOmit, HOME, { head: headGen2, batch: async () => Buffer.alloc(0), sources: async () => new Map() }, knownOmit, { includeTranscripts: false }),
    /MissingFromResponse/,
  );
  assert.equal(knownOmit.files.has(hOmit), true, "omitted key stays in known.files for retry");
  s3.omitDeleteKeys.clear();

  // 8. R2 fix: same-gen S3Place syncs includeTranscripts:true then switches to includeTranscripts:false
  //    -> current-gen transcript deleted via DeleteObjects, chat attachment kept, older-gen exclusive transcript kept!
  const originToggle = sid("c");
  const genOld = "5000-11111111";
  const genCur = "6000-22222222";
  const hChat = sid("d");
  const hCurTr = sid("e");
  const hOldOnlyTr = sid("f");
  const placeToggle = new S3Place(target);
  await placeToggle.putFile(HOME, originToggle, hOldOnlyTr, Buffer.from("old-gen-exclusive-transcript"));
  const headOld = {
    ...head,
    origin: originToggle,
    gen: genOld,
    to: 1,
    made: 5000,
    files: {},
    transcriptFiles: { [hOldOnlyTr]: 28 },
  };
  await placeToggle.put(HOME, originToggle, genOld, "head", "head.json", Buffer.from(JSON.stringify(headOld)));

  const headCur = {
    ...head,
    origin: originToggle,
    gen: genCur,
    to: 1,
    made: 6000,
    files: { [hChat]: 4 },
    transcriptFiles: { [hCurTr]: 18 },
  };
  const toggleTmp = dataDir();
  const chatPath = join(toggleTmp, "chat-attach.bin");
  const curTrPath = join(toggleTmp, "cur-tr.bin");
  writeFileSync(chatPath, Buffer.from("chat"));
  writeFileSync(curTrPath, Buffer.from("current-transcript"));
  const toggleSources = new Map<string, string>([
    [hChat, chatPath],
    [hCurTr, curTrPath],
  ]);

  // First sync with includeTranscripts: true
  const placeToggleLive = new S3Place(target);
  const knownToggle1 = await level(
    placeToggleLive,
    HOME,
    { head: headCur, batch: async () => Buffer.alloc(0), sources: async () => toggleSources },
    null,
    { includeTranscripts: true },
  );
  assert.equal(knownToggle1.behind, false);
  const chatKey = `${target.prefix}/${placeToggleLive.wsTag(HOME)}/${placeToggleLive.originTag(originToggle)}/files/${placeToggleLive.fileTag(hChat)}.enc`;
  const curTrKey = `${target.prefix}/${placeToggleLive.wsTag(HOME)}/${placeToggleLive.originTag(originToggle)}/files/${placeToggleLive.fileTag(hCurTr)}.enc`;
  const oldOnlyTrKey = `${target.prefix}/${placeToggleLive.wsTag(HOME)}/${placeToggleLive.originTag(originToggle)}/files/${placeToggleLive.fileTag(hOldOnlyTr)}.enc`;
  assert.equal(s3.objects.has(chatKey), true, "chat attachment uploaded");
  assert.equal(s3.objects.has(curTrKey), true, "current-gen transcript uploaded");
  assert.equal(s3.objects.has(oldOnlyTrKey), true, "older-gen exclusive transcript present");

  // Switch same gen to includeTranscripts: false -> curTr deleted via DeleteObjects, chat + oldOnlyTr preserved
  s3.batchDeletes.length = 0;
  s3.singleDeletes.length = 0;
  const knownToggle2 = await level(
    placeToggleLive,
    HOME,
    { head: { ...headCur, to: 2, made: 6001 }, batch: async () => Buffer.alloc(0), sources: async () => toggleSources },
    knownToggle1.known,
    { includeTranscripts: false },
  );
  assert.equal(knownToggle2.behind, false);
  assert.equal(s3.objects.has(curTrKey), false, "includeTranscripts:false MUST delete current-gen transcript from S3");
  assert.equal(s3.objects.has(chatKey), true, "chat attachment MUST be preserved");
  assert.equal(s3.objects.has(oldOnlyTrKey), true, "older-gen exclusive transcript MUST remain protected");
  assert.ok(s3.batchDeletes.some((batch) => batch.includes(curTrKey)), "current-gen transcript deleted via DeleteObjects");
  assert.equal(s3.singleDeletes.length, 0);
});
