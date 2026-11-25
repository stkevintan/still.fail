// Regression tests for D72a: 2-level 256-bucket `transcriptManifest` read-side pipeline,
// compact local `WorkPassed.heads` IPC vs inline disk `head.json` invariant, fail-closed `drop()`,
// FolderPlace closure validation, S3Place manifest protection & `hasUnverifiedHead`,
// `handOver`/`holdsAllLogical` partial rejection & logical equivalence, `restore`, manifest GC,
// and `Known` manifest cache without skipping chat attachment `oldFiles` or pending `drop()` pages.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { join, sep } from "node:path";
import { after, test } from "node:test";
import { zstdCompressSync } from "node:zlib";
import { MbProcess, mbReaderBinary } from "../src/read/mb-reader.ts";
import { direct } from "../src/drive/fs.ts";
import { Copies, tell } from "../src/replica/copies.ts";
import { type Head, VERSION, asHead } from "../src/replica/format.ts";
import {
  MANIFEST_GC_GRACE_MS,
  MANIFEST_MAX_BYTES,
  MANIFEST_MAX_ENTRIES,
  encodeTranscriptManifest,
  loadLocalTranscriptFiles,
  loadTranscriptManifest,
  parseLeafManifest,
  parseRootManifest,
  readStreamBounded,
} from "../src/replica/manifest.ts";
import { FolderPlace, type Held, type Known, type Own, type Place, handOver, holdsAll, holdsAllLogical, level } from "../src/replica/places.ts";
import { serve } from "../src/replica/peers.ts";
import { ProgramRunner, exportThread } from "../src/replica/runner.ts";
import { S3Place } from "../src/replica/s3.ts";
import type { NormalizedS3Target } from "../src/replica/backup-config.ts";
import { Fibers } from "../src/ops/fibers.ts";
import { Store } from "../src/store/store.ts";
import { Exporter, nothingTold } from "./reference/replica-export.ts";
import { takeBack, takeBackSoon } from "./reference/replica-restore.ts";
import { InlineRunner } from "./reference/replica-work.ts";
import { HOME, attach, dataDir } from "./replica-fakes.ts";
import { testClock } from "./hub-fakes.ts";

const sid = (ch: string) => ch.repeat(64);

const binary = mbReaderBinary();
const skipMb = binary === null ? "the MoonBit program is not built here" : false;
const closing: (() => Promise<void> | void)[] = [];
after(async () => {
  for (const fn of closing.splice(0)) await fn();
});

const sha256 = (data: Buffer | string) => createHash("sha256").update(data).digest("hex");
const hex64 = (prefix: string, fill = "0") => (prefix + fill.repeat(64)).slice(0, 64);

function makeHead(overrides: Partial<Head> = {}): Head {
  return {
    v: VERSION,
    origin: sid("a"),
    workspace: HOME,
    gen: "1-00000001",
    name: "laptop",
    dataDir: "/tmp/a",
    made: 1000,
    to: 1,
    batches: ["0000000001-0000000001-aaaaaaaa.ndjson.zst"],
    files: {},
    chats: 1,
    messages: 1,
    bytes: 100,
    runs: [{ run: "11111111", from: 1 }],
    ...overrides,
  };
}

class MiniS3Server {
  readonly objects = new Map<string, Buffer>();
  server: ReturnType<typeof createServer> | null = null;
  port = 0;

  async start(): Promise<void> {
    this.server = createServer((req: IncomingMessage, res: ServerResponse) => {
      const chunks: Buffer[] = [];
      req.on("data", (c: Buffer) => chunks.push(c));
      req.on("end", () => this.#handle(req, res, Buffer.concat(chunks)));
    });
    await new Promise<void>((resolve) => {
      this.server!.listen(0, "127.0.0.1", () => {
        const addr = this.server!.address();
        this.port = typeof addr === "object" && addr !== null ? addr.port : 0;
        resolve();
      });
    });
  }

  async stop(): Promise<void> {
    if (this.server === null) return;
    const s = this.server;
    this.server = null;
    await new Promise<void>((resolve) => s.close(() => resolve()));
  }

  target(encKeyHex: string, includeTranscripts = true): NormalizedS3Target {
    return {
      id: "s3-test",
      name: "S3 Test",
      endpoint: `http://127.0.0.1:${this.port}`,
      region: "us-east-1",
      bucket: "bkt",
      prefix: "pfx",
      forcePathStyle: true,
      accessKeyId: "AKIA",
      secretAccessKey: "SECRET",
      encryptionKey: encKeyHex,
      includeTranscripts,
    };
  }

  #handle(req: IncomingMessage, res: ServerResponse, body: Buffer): void {
    const u = new URL(req.url ?? "/", `http://127.0.0.1:${this.port}`);
    const parts = u.pathname.replace(/^\/+/, "").split("/");
    const key = parts.slice(1).map(decodeURIComponent).join("/");
    if (req.method === "GET" && u.searchParams.get("list-type") === "2") {
      const prefix = u.searchParams.get("prefix") ?? "";
      const keys = [...this.objects.keys()].filter((k) => k.startsWith(prefix)).sort();
      const xml = `<ListBucketResult><IsTruncated>false</IsTruncated>${keys.map((k) => `<Contents><Key>${k}</Key></Contents>`).join("")}</ListBucketResult>`;
      res.writeHead(200, { "content-type": "application/xml" });
      res.end(xml);
      return;
    }
    if (req.method === "POST" && u.searchParams.has("delete")) {
      const xmlText = body.toString("utf8");
      const deleted: string[] = [];
      const re = /<Key>([^<]+)<\/Key>/g;
      let m: RegExpExecArray | null;
      while ((m = re.exec(xmlText)) !== null) {
        this.objects.delete(m[1]!);
        deleted.push(m[1]!);
      }
      res.writeHead(200, { "content-type": "application/xml" });
      res.end(`<DeleteResult>${deleted.map((k) => `<Deleted><Key>${k}</Key></Deleted>`).join("")}</DeleteResult>`);
      return;
    }
    if (req.method === "PUT") {
      this.objects.set(key, body);
      res.writeHead(200, { etag: `"${sha256(body)}"` });
      res.end();
      return;
    }
    if (req.method === "GET") {
      const data = this.objects.get(key);
      if (data === undefined) {
        res.writeHead(404);
        res.end("<Error><Code>NoSuchKey</Code></Error>");
        return;
      }
      res.writeHead(200);
      res.end(data);
      return;
    }
    res.writeHead(405);
    res.end();
  }
}

function makeTranscriptStation(label: string) {
  const data = dataDir(label);
  const db = join(data, "stillfail.db");
  const store = Store.open(db, join(data, "archive"));
  closing.push(() => store.close());
  const room = join(data, "sessions", "chat", "chat:tr", "workspace");
  mkdirSync(room, { recursive: true });
  store.insertSession({
    key: "chat:tr",
    connect: "chat",
    runtime: "codex",
    profile: "cx",
    workspace: room,
    token: "tok",
    createdAt: 1,
    lastActiveAt: 1,
    ws: null,
  });
  store.setRuntimeSessionId("chat:tr", "codex-tr-001");
  const thread = store.openThread("chat", "C", "ts-tr", "TR Chat", "p@x").id;
  store.joinThread(thread, "chat:tr", "chat");
  const att = attach(data, "chat:tr", "pic.txt", "attachment-bytes");
  store.insertMessage({ thread, ts: "m1", authorKind: "person", author: "p@x", text: "hello", attachments: [att] });
  const trDir = join(data, "transcripts", "codex", "2026", "11", "25");
  mkdirSync(trDir, { recursive: true });
  const trPath = join(trDir, "rollout-2026-11-25-codex-tr-001.jsonl");
  writeFileSync(trPath, "line-0\n".repeat(400) + "line-1\n".repeat(400));
  utimesSync(trPath, new Date(1_700_000_000_000), new Date(1_700_000_000_000));
  return { data, db, store, thread, trPath, att };
}

test("1. Canonical manifest codec, empty set, MoonBit/TS parity, compact IPC vs inline disk head.json, and strict fallback rebuild", async () => {
  // Empty set canonical JSON
  const empty = encodeTranscriptManifest({});
  assert.equal(empty.rootBytes.toString("utf8"), '{"v":1,"buckets":{}}');
  assert.equal(empty.leaves.size, 0);
  const parsedEmpty = parseRootManifest(empty.rootBytes, empty.rootHash);
  assert.deepEqual(parsedEmpty, { v: 1, buckets: {} });

  // 256-bucket sorting
  const hff2 = hex64("ff", "2");
  const hff1 = hex64("ff", "1");
  const h00b = hex64("00", "b");
  const h00a = hex64("00", "a");
  const enc = encodeTranscriptManifest({ [hff2]: 20, [h00b]: 2, [hff1]: 10, [h00a]: 1 });
  assert.deepEqual(Object.keys(enc.buckets), ["00", "ff"]);
  const leaf00 = enc.leaves.get(enc.buckets["00"]!)!;
  assert.equal(leaf00.bytes.toString("utf8"), `{"v":1,"files":{"${h00a}":1,"${h00b}":2}}`);

  // TS Exporter vs MoonBit Exporter parity: compact IPC + inline disk head.json
  const s = makeTranscriptStation("d72a-parity");
  const tsReplica = join(s.data, "replica-ts");
  const mbReplica = join(s.data, "replica-mb");
  const now = 1_700_000_000_000;
  const exp = new Exporter({ db: s.db, replica: tsReplica, dataDir: s.data, origin: sid("a"), now: () => now, chunkBytes: 1024, compactHeads: true });
  closing.push(() => exp.close());
  exp.setPlaces({ home: HOME, workspaces: [{ workspace: HOME, name: "src" }] });
  const tsPass = exp.pass(nothingTold());
  const tsHead = tsPass.heads[HOME]!;
  assert.equal(tsHead.transcriptFiles, undefined, "TS IPC head omits transcriptFiles");
  assert.ok(typeof tsHead.transcriptManifest === "string", "TS IPC head carries transcriptManifest");

  // Disk head.json keeps inline transcriptFiles and NO transcriptManifest
  const tsDiskHead = JSON.parse(readFileSync(join(tsReplica, "own", HOME, tsHead.gen, "head.json"), "utf8")) as Head;
  assert.equal(tsDiskHead.transcriptManifest, undefined, "disk head.json must NOT carry transcriptManifest in D72a");
  assert.ok(tsDiskHead.transcriptFiles !== undefined && Object.keys(tsDiskHead.transcriptFiles).length > 0);
  const tsResolved = await loadLocalTranscriptFiles(tsReplica, tsHead);
  assert.deepEqual(tsResolved, tsDiskHead.transcriptFiles);

  // Fallback rebuild from own head.json when local manifests/ deleted: succeeds iff hash matches
  rmSync(join(tsReplica, "manifests"), { recursive: true, force: true });
  const rebuilt = await loadLocalTranscriptFiles(tsReplica, tsHead);
  assert.deepEqual(rebuilt, tsDiskHead.transcriptFiles, "rebuilds from own head.json when canonical root hash matches");

  // Tamper disk head.json transcriptFiles -> recomputed hash mismatches -> MUST throw!
  const tamperedDisk = { ...tsDiskHead, transcriptFiles: { [hex64("aa")]: 999 } };
  writeFileSync(join(tsReplica, "own", HOME, tsHead.gen, "head.json"), JSON.stringify(tamperedDisk));
  await assert.rejects(
    () => loadLocalTranscriptFiles(tsReplica, tsHead),
    /does not match/,
    "mismatching own head.json must throw and never silently drop files",
  );

  // MoonBit parity when binary is present
  if (binary !== null) {
    const runner = new ProgramRunner({ db: s.db, replica: mbReplica, dataDir: s.data, origin: sid("a"), chunkBytes: 1024 }, exportThread);
    closing.push(() => runner.close());
    await runner.places({ home: HOME, workspaces: [{ workspace: HOME, name: "src" }] });
    const mbPass = await runner.pass(nothingTold());
    const mbHead = mbPass.heads[HOME]!;
    assert.equal(mbHead.transcriptFiles, undefined, "MB IPC head omits transcriptFiles");
    assert.ok(typeof mbHead.transcriptManifest === "string", "MB IPC head carries transcriptManifest");
    const mbDiskHead = JSON.parse(readFileSync(join(mbReplica, "own", HOME, mbHead.gen, "head.json"), "utf8")) as Head;
    assert.equal(mbDiskHead.transcriptManifest, undefined, "MB disk head.json keeps inline transcriptFiles");
    assert.ok(mbDiskHead.transcriptFiles !== undefined);
    // Canonical manifest root hash computed by TS on MB's transcriptFiles MUST match MB's root hash byte-for-byte!
    assert.equal(encodeTranscriptManifest(mbDiskHead.transcriptFiles).rootHash, mbHead.transcriptManifest);
    assert.deepEqual(await loadLocalTranscriptFiles(mbReplica, mbHead), mbDiskHead.transcriptFiles);
  }
});

test("2. Adversarial manifest validation: sha256, version, extra keys, duplicate keys, bad bucket, prefix mismatch, invalid compSize, and 64 MiB / 500k bombs", () => {
  const h0a = hex64("0a", "1");
  const h0b = hex64("0b", "2");
  const leafOk = Buffer.from(`{"v":1,"files":{"${h0a}":123}}`, "utf8");
  const leafOkHash = sha256(leafOk);

  // Tampered sha256
  assert.throws(() => parseLeafManifest(leafOk, hex64("ff", "f"), "0a"), /hash mismatch/);
  // Wrong v
  const badV = Buffer.from('{"v":2,"buckets":{}}', "utf8");
  assert.throws(() => parseRootManifest(badV, sha256(badV)), /version/);
  // Extra top-level key
  const extraKey = Buffer.from('{"v":1,"buckets":{},"extra":1}', "utf8");
  assert.throws(() => parseRootManifest(extraKey, sha256(extraKey)), /only keys|too many keys/);
  // Duplicate JSON key (plain and \u0076 escape)
  const dupTop = Buffer.from('{"v":1,"\\u0076":1,"buckets":{}}', "utf8");
  assert.throws(() => parseRootManifest(dupTop, sha256(dupTop)), /duplicate JSON key/);
  const dupNested = Buffer.from(`{"v":1,"files":{"${h0a}":1,"${h0a}":2}}`, "utf8");
  assert.throws(() => parseLeafManifest(dupNested, sha256(dupNested), "0a"), /duplicate JSON key/);
  // Invalid bucket key
  for (const badB of ["0G", "0", "000", "ZZ"]) {
    const raw = Buffer.from(`{"v":1,"buckets":{"${badB}":"${leafOkHash}"}}`, "utf8");
    assert.throws(() => parseRootManifest(raw, sha256(raw)), /invalid manifest bucket key/);
  }
  // Bucket prefix mismatch
  const mismatch = Buffer.from(`{"v":1,"files":{"${h0b}":10}}`, "utf8");
  assert.throws(() => parseLeafManifest(mismatch, sha256(mismatch), "0a"), /does not match bucket/);
  // Invalid compSize (-1, -0, 1.5, > MAX_SAFE_INTEGER)
  for (const badSz of ["-1", "-0", "1.5", "9007199254740992"]) {
    const raw = Buffer.from(`{"v":1,"files":{"${h0a}":${badSz}}}`, "utf8");
    assert.throws(() => parseLeafManifest(raw, sha256(raw), "0a"));
  }
  // 64 MiB byte cap bomb & 500k entry cap bomb
  assert.throws(() => parseLeafManifest(leafOk, leafOkHash, "0a", { bytes: MANIFEST_MAX_BYTES, entries: 0 }), /max bytes/);
  assert.throws(() => parseLeafManifest(leafOk, leafOkHash, "0a", { bytes: 0, entries: MANIFEST_MAX_ENTRIES }), /max entries/);
  // asHead rejects invalid transcriptManifest
  assert.equal(asHead(makeHead({ transcriptManifest: "not-a-hash" })), null);
  assert.notEqual(asHead(makeHead({ transcriptManifest: leafOkHash, transcriptFiles: { [h0a]: 123 } })), null);
});

test("3 & 4. Dual-field coexistence (union protection), FolderPlace closure validation, fail-closed drop(), and concurrent put(head) vs drop() lock", async () => {
  const dir = dataDir("d72a-folder");
  const place = new FolderPlace(join(dir, "replicas"));
  const origin = sid("a");
  const batch = "0000000001-0000000001-aaaaaaaa.ndjson.zst";
  await place.put(HOME, origin, "1-00000001", "batch", batch, Buffer.from("batch-bytes"));

  const cManifest = hex64("11", "a");
  const cInlineOnly = hex64("22", "b");
  const cUnref = hex64("33", "c");
  const enc = encodeTranscriptManifest({ [cManifest]: 50 });

  // Closure validation: missing root -> rejected
  const headM = makeHead({
    origin,
    batches: [batch],
    transcriptManifest: enc.rootHash,
    transcriptFiles: { [cInlineOnly]: 60 },
  });
  await assert.rejects(() => place.put(HOME, origin, headM.gen, "head", "head.json", Buffer.from(JSON.stringify(headM))), /missing/);

  // Partial head with transcriptManifest -> rejected
  const badPartial = makeHead({ origin, batches: [batch], transcriptManifest: enc.rootHash, partial: true });
  await assert.rejects(() => place.put(HOME, origin, badPartial.gen, "head", "head.json", Buffer.from(JSON.stringify(badPartial))), /partial head/);

  // Put root only, missing leaf -> rejected
  await place.putFile(HOME, origin, enc.rootHash, enc.rootBytes);
  await assert.rejects(() => place.put(HOME, origin, headM.gen, "head", "head.json", Buffer.from(JSON.stringify(headM))), /missing/);

  // Put leaf, missing chunk -> rejected
  for (const [lh, { bytes }] of enc.leaves) await place.putFile(HOME, origin, lh, bytes);
  await assert.rejects(() => place.put(HOME, origin, headM.gen, "head", "head.json", Buffer.from(JSON.stringify(headM))), /not here yet/);

  // Put chunks + inline-only chunk + unreferenced chunk -> put(head) succeeds!
  await place.putFile(HOME, origin, cManifest, Buffer.from("m"));
  await place.putFile(HOME, origin, cInlineOnly, Buffer.from("i"));
  await place.putFile(HOME, origin, cUnref, Buffer.from("u"));
  await place.put(HOME, origin, headM.gen, "head", "head.json", Buffer.from(JSON.stringify(headM)));

  // Dual-field coexistence protection: drop() protects union (root + leaf + cManifest + cInlineOnly) and deletes only cUnref
  const leafHash = [...enc.leaves.keys()][0]!;
  await place.drop(HOME, origin, headM.gen, [], [enc.rootHash, leafHash, cManifest, cInlineOnly, cUnref]);
  assert.notEqual(await place.pathOf(HOME, origin, null, enc.rootHash), null, "root protected");
  assert.notEqual(await place.pathOf(HOME, origin, null, leafHash), null, "leaf protected");
  assert.notEqual(await place.pathOf(HOME, origin, null, cManifest), null, "manifest chunk protected");
  assert.notEqual(await place.pathOf(HOME, origin, null, cInlineOnly), null, "inline coexistence chunk protected");
  assert.equal(await place.pathOf(HOME, origin, null, cUnref), null, "unreferenced file dropped");

  // Concurrent put("head") vs drop() serialized under #withLock
  const cNew = hex64("44", "d");
  const enc2 = encodeTranscriptManifest({ [cManifest]: 50, [cNew]: 70 });
  await place.putFile(HOME, origin, cNew, Buffer.from("n"));
  await place.putFile(HOME, origin, enc2.rootHash, enc2.rootBytes);
  for (const [lh, { bytes }] of enc2.leaves) await place.putFile(HOME, origin, lh, bytes);
  const head2 = makeHead({ origin, batches: [batch], to: 2, made: 2000, transcriptManifest: enc2.rootHash });
  await Promise.all([
    place.put(HOME, origin, head2.gen, "head", "head.json", Buffer.from(JSON.stringify(head2))),
    place.drop(HOME, origin, head2.gen, [], [cNew]),
  ]);
  // Whether drop ran before or after put(head2), if put(head2) won, cNew is still present OR if drop ran before put(head2), put(head2) would reject missing cNew.
  // In our serial order put(head2) was queued first, so cNew MUST survive!
  assert.notEqual(await place.pathOf(HOME, origin, null, cNew), null, "serialized put(head) + drop() protects new chunk");

  // Fail-closed drop(): corrupting manifest leaf aborts drop() and deletes NOTHING
  await place.putFile(HOME, origin, cUnref, Buffer.from("u2"));
  const leaf2Hash = [...enc2.leaves.keys()][0]!;
  writeFileSync(join(place.dir(HOME, origin), "files", leaf2Hash), "corrupted-json");
  place.forget(HOME, origin);
  await assert.rejects(() => place.drop(HOME, origin, head2.gen, [], [cUnref]));
  assert.notEqual(await place.pathOf(HOME, origin, null, cUnref), null, "fail-closed drop() must NOT delete files when manifest is corrupted");

  // Fail-closed drop(): corrupting head.json aborts drop()
  writeFileSync(join(place.dir(HOME, origin), head2.gen, "head.json"), "{broken");
  place.forget(HOME, origin);
  await assert.rejects(() => place.drop(HOME, origin, head2.gen, [], [cUnref]));
  assert.notEqual(await place.pathOf(HOME, origin, null, cUnref), null, "fail-closed drop() must NOT delete files when head.json is corrupted");
});

test("5. S3Place reads transcriptManifest head, protects root+leaves+chunks in held/drop/pruneOrphans, and pauses on corrupted/missing leaf", async () => {
  const srv = new MiniS3Server();
  await srv.start();
  closing.push(() => srv.stop());
  const encKey = "ab".repeat(32);
  const s3 = new S3Place(srv.target(encKey, true), { now: () => 1_700_000_000_000 });
  const origin = sid("a");
  const c1 = hex64("aa", "1");
  const cInline = hex64("bb", "2");
  const cOrphan = hex64("cc", "3");
  const enc = encodeTranscriptManifest({ [c1]: 100 });
  const leafHash = [...enc.leaves.keys()][0]!;

  await s3.putFile(HOME, origin, c1, Buffer.from("chunk-1"));
  await s3.putFile(HOME, origin, cInline, Buffer.from("inline-1"));
  await s3.putFile(HOME, origin, cOrphan, Buffer.from("orphan-1"));
  await s3.putFile(HOME, origin, enc.rootHash, enc.rootBytes);
  await s3.putFile(HOME, origin, leafHash, enc.leaves.get(leafHash)!.bytes);

  const head = makeHead({
    origin,
    transcriptManifest: enc.rootHash,
    transcriptFiles: { [cInline]: 200 },
  });
  await s3.put(HOME, origin, head.gen, "head", "head.json", Buffer.from(JSON.stringify(head)), head);

  // Fresh S3Place reads manifest head: held().files includes root + leaf + c1 + cInline (union!)
  const s3Reader = new S3Place(srv.target(encKey, true), { now: () => 1_700_000_000_000 });
  const held = await s3Reader.held(HOME, origin);
  assert.equal(held.hasUnverifiedHead, undefined);
  assert.ok(held.files.includes(enc.rootHash), "held() includes rootHash");
  assert.ok(held.files.includes(leafHash), "held() includes leafHash");
  assert.ok(held.files.includes(c1), "held() includes manifest chunk");
  assert.ok(held.files.includes(cInline), "held() includes inline coexistence chunk");

  // drop() protects root + leaf + c1; pruneOrphans() removes only cOrphan
  await s3Reader.drop(HOME, origin, head.gen, [], [enc.rootHash, leafHash, c1]);
  await s3Reader.pruneOrphans(HOME, origin, head);
  const afterPrune = await s3Reader.held(HOME, origin);
  assert.ok(afterPrune.files.includes(enc.rootHash));
  assert.ok(afterPrune.files.includes(leafHash));
  assert.ok(afterPrune.files.includes(c1));
  assert.ok(!srv.objects.has(`pfx/${s3Reader.wsTag(HOME)}/${s3Reader.originTag(origin)}/files/${s3Reader.fileTag(cOrphan)}.enc`), "orphan deleted");

  // Now delete the leaf object in S3 and add another orphan -> held() MUST set hasUnverifiedHead and pause drop/pruneOrphans!
  const cOrphan2 = hex64("dd", "4");
  await s3Reader.putFile(HOME, origin, cOrphan2, Buffer.from("orphan-2"));
  const leafS3Key = `pfx/${s3Reader.wsTag(HOME)}/${s3Reader.originTag(origin)}/files/${s3Reader.fileTag(leafHash)}.enc`;
  srv.objects.delete(leafS3Key);

  const s3Broken = new S3Place(srv.target(encKey, true), { now: () => 1_700_000_000_000 });
  const heldBroken = await s3Broken.held(HOME, origin);
  assert.equal(heldBroken.hasUnverifiedHead, true, "missing bucket leaf sets hasUnverifiedHead");
  await s3Broken.drop(HOME, origin, head.gen, [], [cOrphan2, c1]);
  await s3Broken.pruneOrphans(HOME, origin);
  const orphan2Key = `pfx/${s3Broken.wsTag(HOME)}/${s3Broken.originTag(origin)}/files/${s3Broken.fileTag(cOrphan2)}.enc`;
  assert.ok(srv.objects.has(orphan2Key), "drop/pruneOrphans conservatively paused when hasUnverifiedHead is true");
});

test("6. handOver / holdsAll / holdsAllLogical reject partial for full and accept inline vs manifest logical equivalence", async () => {
  const origin = sid("a");
  const c1 = hex64("1a", "1");
  const c2 = hex64("2b", "2");
  const fChat = hex64("3c", "3");
  const enc = encodeTranscriptManifest({ [c1]: 11, [c2]: 22 });
  const leaf1 = enc.buckets["1a"]!;
  const leaf2 = enc.buckets["2b"]!;

  const fullInline = makeHead({ origin, files: { [fChat]: 5 }, transcriptFiles: { [c1]: 11, [c2]: 22 } });
  const partialHeadObj = makeHead({ origin, files: { [fChat]: 5 }, transcriptFiles: { [c1]: 11 }, partial: true });
  const fullManifest = makeHead({ origin, files: { [fChat]: 5 }, transcriptManifest: enc.rootHash });

  // Sync holdsAll rejects partial for full even at same `to`
  const mineInline: Held = { gens: [{ gen: fullInline.gen, head: fullInline, batches: fullInline.batches }], files: [fChat, c1, c2] };
  const theirsPartial: Held = { gens: [{ gen: partialHeadObj.gen, head: partialHeadObj, batches: partialHeadObj.batches }], files: [fChat, c1, c2] };
  assert.equal(holdsAll(mineInline, theirsPartial), false, "partial head must NEVER satisfy full head");

  // Logical equivalence: manifest on `mine` vs inline on `theirs`
  const mineManifest: Held = {
    gens: [{ gen: fullManifest.gen, head: fullManifest, batches: fullManifest.batches }],
    files: [fChat, c1, c2, enc.rootHash, leaf1, leaf2],
  };
  const manifestStore = new Map<string, Buffer>([
    [enc.rootHash, enc.rootBytes],
    [leaf1, enc.leaves.get(leaf1)!.bytes],
    [leaf2, enc.leaves.get(leaf2)!.bytes],
  ]);
  const readMap = async (h: string) => manifestStore.get(h) ?? null;

  assert.equal(
    await holdsAllLogical(mineManifest, mineInline, { readMine: readMap }),
    true,
    "manifest head on mine is logically equivalent to inline head on theirs",
  );
  assert.equal(
    await holdsAllLogical(mineInline, mineManifest, { readTheirs: readMap }),
    true,
    "inline head on mine is logically equivalent to manifest head on theirs",
  );
  assert.equal(
    await holdsAllLogical(mineManifest, theirsPartial, { readMine: readMap }),
    false,
    "holdsAllLogical rejects partial head on theirs",
  );

  // Real FolderPlace handOver: if target only holds partial, handOver MUST push full head!
  const d = dataDir("d72a-handover");
  const fromPlace = new FolderPlace(join(d, "from"));
  const toPlace = new FolderPlace(join(d, "to"));
  const batch = fullInline.batches[0]!;
  await fromPlace.put(HOME, origin, fullInline.gen, "batch", batch, Buffer.from("b"));
  await fromPlace.putFile(HOME, origin, fChat, Buffer.from("chat"));
  await fromPlace.putFile(HOME, origin, c1, Buffer.from("c1"));
  await fromPlace.putFile(HOME, origin, c2, Buffer.from("c2"));
  await fromPlace.put(HOME, origin, fullInline.gen, "head", "head.json", Buffer.from(JSON.stringify(fullInline)));

  await toPlace.put(HOME, origin, fullInline.gen, "batch", batch, Buffer.from("b"));
  await toPlace.putFile(HOME, origin, fChat, Buffer.from("chat"));
  await toPlace.putFile(HOME, origin, c1, Buffer.from("c1"));
  await toPlace.put(HOME, origin, fullInline.gen, "head", "head.json", Buffer.from(JSON.stringify(partialHeadObj)));

  const ok = await handOver(fromPlace, toPlace, HOME, origin);
  assert.equal(ok, true);
  const toHeld = await toPlace.held(HOME, origin);
  assert.equal(toHeld.gens[0]!.head!.partial, undefined, "handOver replaced partial head with full head");
});

test("7. restore with transcriptManifest: normal restore, missing single chunk (chat-first missing count), and corrupted manifest error", async () => {
  const s = makeTranscriptStation("d72a-restore");
  const replica = join(s.data, "replica");
  const origin = sid("a");
  const exp = new Exporter({ db: s.db, replica, dataDir: s.data, origin, now: () => 1_700_000_000_000, chunkBytes: 1024, compactHeads: true });
  closing.push(() => exp.close());
  exp.setPlaces({ home: HOME, workspaces: [{ workspace: HOME, name: "src" }] });
  const p = exp.pass(nothingTold());
  const compactHead = p.heads[HOME]!;
  assert.ok(compactHead.transcriptManifest !== undefined);

  // Build a FolderPlace holding the manifest-based head (simulating D72b/manifest remote source)
  const kept = new FolderPlace(join(s.data, "kept"));
  const genDirPath = join(replica, "own", HOME, compactHead.gen);
  for (const b of compactHead.batches) {
    await kept.put(HOME, origin, compactHead.gen, "batch", b, readFileSync(join(genDirPath, "log", b)));
  }
  const tf = await loadLocalTranscriptFiles(replica, compactHead);
  const enc = encodeTranscriptManifest(tf);
  for (const h of Object.keys(compactHead.files)) {
    await kept.putFile(HOME, origin, h, exp.sourceOf(h)!);
  }
  for (const h of Object.keys(tf)) {
    await kept.putFile(HOME, origin, h, exp.sourceOf(h)!);
  }
  await kept.putFile(HOME, origin, enc.rootHash, enc.rootBytes);
  for (const [lh, { bytes }] of enc.leaves) await kept.putFile(HOME, origin, lh, bytes);
  await kept.put(HOME, origin, compactHead.gen, "head", "head.json", Buffer.from(JSON.stringify(compactHead)));

  // Helper to stage restore via Copies.restore() from local `kept`
  const runRestore = async (label: string, mutateKept?: (k: FolderPlace) => void, useMb = false) => {
    const targetData = dataDir(label);
    const clock = testClock();
    Store.open(join(targetData, "stillfail.db"), join(targetData, "archive"), clock.clock).close();
    const fibers = new Fibers("restore-test");
    closing.push(() => fibers.close());
    const runner = new InlineRunner({ db: join(targetData, "stillfail.db"), replica: join(targetData, "replica"), dataDir: targetData, origin: sid("b"), now: () => 1 });
    closing.push(() => runner.close());
    const copies = new Copies({
      data: targetData,
      here: () => sid("b"),
      places: () => ({ home: HOME, workspaces: [{ workspace: HOME, name: "dst" }] }),
      roster: () => [{ id: sid("b"), name: "dst" }],
      ask: async () => { throw new Error("unused"); },
      runner,
      fibers,
      changed: () => {},
      restart: async () => null,
    });
    closing.push(() => copies.close());
    // Copy kept into copies.kept
    const srcHeld = await kept.held(HOME, origin);
    for (const f of srcHeld.files) {
      await copies.kept.putFile(HOME, origin, f, (await kept.read(HOME, origin, null, f))!);
    }
    for (const g of srcHeld.gens) {
      for (const b of g.batches) await copies.kept.put(HOME, origin, g.gen, "batch", b, (await kept.read(HOME, origin, g.gen, b))!);
      if (g.head !== null) await copies.kept.put(HOME, origin, g.gen, "head", "head.json", Buffer.from(JSON.stringify(g.head)));
    }
    mutateKept?.(copies.kept);
    await copies.placesChanged();
    await copies.settle();
    await copies.restore(HOME, origin, compactHead.gen, { station: sid("b") });
    await copies.close();
    if (useMb && binary !== null) {
      await takeBackSoon(targetData, join(targetData, "stillfail.db"), 10, binary);
    } else {
      takeBack(targetData, join(targetData, "stillfail.db"), 10);
    }
    return JSON.parse(readFileSync(join(targetData, "replica", "restored.json"), "utf8"));
  };

  // 7a. Normal manifest restore (TS + MB)
  const okTs = await runRestore("d72a-res-ok-ts");
  assert.equal(okTs.error, null);
  assert.equal(okTs.missing, 0);
  assert.ok(okTs.files >= 2);
  if (binary !== null) {
    const okMb = await runRestore("d72a-res-ok-mb", undefined, true);
    assert.equal(okMb.error, null);
    assert.equal(okMb.missing, 0);
    assert.equal(okMb.files, okTs.files);
  }

  // 7b. Missing single transcript chunk -> chat DB & attachment still restore, transcript recorded in `missing`
  const oneChunk = Object.keys(tf)[0]!;
  const missingChunkRes = await runRestore("d72a-res-miss-chunk", (k) => {
    rmSync(join(k.dir(HOME, origin), "files", oneChunk));
  });
  assert.equal(missingChunkRes.error, null, "missing single transcript chunk does NOT fail restore");
  assert.equal(missingChunkRes.missing, 1, "missing transcript counted in outcome.missing");
  assert.ok(missingChunkRes.files >= 1, "chat attachment still placed");

  // 7c. Corrupted manifest leaf -> restore MUST fail!
  const oneLeaf = [...enc.leaves.keys()][0]!;
  await assert.rejects(
    () => runRestore("d72a-res-bad-manifest", (k) => {
      writeFileSync(join(k.dir(HOME, origin), "files", oneLeaf), "tampered-leaf");
    }),
    /hash mismatch/,
    "corrupted manifest leaf fails restore during bring",
  );

  // 7d. Direct takeBack / takeBackSoon with tampered manifest leaf on disk -> outcome.error set!
  const badDirect = dataDir("d72a-res-direct-bad");
  const clock = testClock();
  Store.open(join(badDirect, "stillfail.db"), join(badDirect, "archive"), clock.clock).close();
  const copy = join(badDirect, "restore", "copy");
  mkdirSync(join(copy, compactHead.gen, "log"), { recursive: true });
  mkdirSync(join(copy, "files"), { recursive: true });
  for (const b of compactHead.batches) {
    writeFileSync(join(copy, compactHead.gen, "log", b), readFileSync(join(genDirPath, "log", b)));
  }
  writeFileSync(join(copy, compactHead.gen, "head.json"), JSON.stringify(compactHead));
  writeFileSync(join(copy, "files", enc.rootHash), enc.rootBytes);
  writeFileSync(join(copy, "files", oneLeaf), "corrupted-on-disk");
  writeFileSync(join(badDirect, "restore", "ready.json"), JSON.stringify({ origin, workspace: HOME, gen: compactHead.gen, name: "src", from: "x" }));
  if (binary !== null) {
    await takeBackSoon(badDirect, join(badDirect, "stillfail.db"), 20, binary);
  } else {
    takeBack(badDirect, join(badDirect, "stillfail.db"), 20);
  }
  const directOutcome = JSON.parse(readFileSync(join(badDirect, "replica", "restored.json"), "utf8"));
  assert.notEqual(directOutcome.error, null, "corrupted manifest fails takeBack/takeBackSoon");
  assert.equal(directOutcome.reason, "error");
});

test("8. <replica>/manifests/ 10-minute superseded-time grace GC keeps live and recently superseded manifests and removes expired ones", () => {
  const s = makeTranscriptStation("d72a-gc");
  const replica = join(s.data, "replica");
  let now = 1_700_000_000_000;
  const exp = new Exporter({ db: s.db, replica, dataDir: s.data, origin: sid("a"), now: () => now, chunkBytes: 1024, compactHeads: true });
  closing.push(() => exp.close());
  exp.setPlaces({ home: HOME, workspaces: [{ workspace: HOME, name: "src" }] });

  const p1 = exp.pass(nothingTold());
  const oldRoot = p1.heads[HOME]!.transcriptManifest!;
  assert.ok(existsSync(join(replica, "manifests", oldRoot)));

  // Advance 20 minutes while oldRoot is STILL live (mtime is now 20 min old, > 10 min grace).
  now += 2 * MANIFEST_GC_GRACE_MS;
  const twentyMinAgo = new Date(now - 2 * MANIFEST_GC_GRACE_MS);
  utimesSync(join(replica, "manifests", oldRoot), twentyMinAgo, twentyMinAgo);

  // Modify transcript so a new manifest root is written; oldRoot leaves live set AT THIS MOMENT (`now`).
  writeFileSync(s.trPath, "updated-content-" + "x".repeat(2000));
  utimesSync(s.trPath, new Date(now), new Date(now));
  const p2 = exp.pass({ ...nothingTold(), transcripts: true });
  const newRoot = p2.heads[HOME]!.transcriptManifest!;
  assert.notEqual(newRoot, oldRoot);
  // Even though oldRoot's mtime is 20 min old, it was JUST superseded -> MUST be kept for 10 min from supersession!
  assert.ok(existsSync(join(replica, "manifests", oldRoot)), "reused old-mtime manifest kept immediately after supersession");

  // 9 minutes after supersession (< 10 min grace) -> STILL kept!
  now += MANIFEST_GC_GRACE_MS - 60_000;
  exp.pass({ ...nothingTold(), transcripts: true });
  assert.ok(existsSync(join(replica, "manifests", oldRoot)), "unreferenced manifest kept within 10-min superseded grace");
  assert.ok(existsSync(join(replica, "manifests", newRoot)), "live manifest kept");

  // 10+ minutes after supersession -> removed, while live newRoot (even with old mtime) MUST stay!
  now += 60_000;
  utimesSync(join(replica, "manifests", newRoot), twentyMinAgo, twentyMinAgo);
  exp.pass({ ...nothingTold(), transcripts: true });
  assert.ok(!existsSync(join(replica, "manifests", oldRoot)), "superseded manifest GC'd past 10-min grace");
  assert.ok(existsSync(join(replica, "manifests", newRoot)), "live manifest NEVER GC'd regardless of mtime");
});

test("9. Known manifest cache hit skips loadTranscriptFiles on unchanged transcriptManifest while still dropping deleted chat attachments and pending drop pages", async () => {
  const origin = sid("a");
  const c1 = hex64("11", "1");
  const c2 = hex64("22", "2");
  const att1 = hex64("aa", "1");
  const att2 = hex64("bb", "2");
  const attOld1 = hex64("cc", "3");
  const attOld2 = hex64("dd", "4");
  const batch1 = "0000000001-0000000001-aaaaaaaa.ndjson.zst";
  const batch2 = "0000000002-0000000002-bbbbbbbb.ndjson.zst";
  const enc = encodeTranscriptManifest({ [c1]: 10, [c2]: 20 });

  const storedFiles = new Set<string>([att1, att2, attOld1, attOld2, c1, c2]);
  const storedBatches = new Set<string>([batch1]);
  const droppedPages: string[][] = [];
  let putHeadCount = 0;
  let lastWireHead: Head | null = null;
  let failSecondDropPage = true;

  const fakePlace: Place = {
    async held() {
      return {
        gens: [{ gen: "1-00000001", head: null, batches: [...storedBatches] }],
        files: [...storedFiles],
      };
    },
    async put(_ws, _origin, _gen, kind, name, bytes, head) {
      if (kind === "batch") storedBatches.add(name);
      else {
        putHeadCount++;
        lastWireHead = head ?? (JSON.parse(bytes.toString("utf8")) as Head);
      }
    },
    async putFile(_ws, _origin, hash) {
      storedFiles.add(hash);
    },
    async drop(_ws, _origin, _gen, _batches, files) {
      if (failSecondDropPage && droppedPages.length === 1) {
        failSecondDropPage = false;
        throw new Error("simulated drop page failure");
      }
      droppedPages.push([...files]);
      for (const f of files) storedFiles.delete(f);
    },
  };

  let loadCalls = 0;
  const makeOwn = (head: Head): Own => ({
    head,
    batch: async () => Buffer.from("b"),
    sources: async (hashes) => new Map(hashes.map((h) => [h, `/fake/${h}`])),
    loadTranscriptFiles: async () => {
      loadCalls++;
      return { [c1]: 10, [c2]: 20 };
    },
  });

  // Round 1: initial level with compact manifest head, dropFilesPage=1 -> page 1 drops attOld1, page 2 fails (leaving attOld2 pending!)
  const head1 = makeHead({ origin, batches: [batch1], files: { [att1]: 5, [att2]: 6 }, transcriptManifest: enc.rootHash, to: 1, made: 1000 });
  // First level fails on 2nd drop page; we can simulate Known after page 1 succeeded (attOld2 still in k.files)
  await assert.rejects(() => level(fakePlace, HOME, makeOwn(head1), null, { dropFilesPage: 1 }), /simulated drop page failure/);
  assert.equal(loadCalls, 1);
  assert.equal(putHeadCount, 1);
  // Wire head MUST be inline transcriptFiles (D72a iron law)!
  assert.equal(lastWireHead!.transcriptManifest, undefined, "wire head must NOT carry transcriptManifest in D72a");
  assert.deepEqual(lastWireHead!.transcriptFiles, { [c1]: 10, [c2]: 20 });

  // Build Known representing confirmed manifest + pending attOld2 still in place
  const knownAfterPartialDrop: Known = {
    gen: head1.gen,
    batches: new Set([batch1]),
    files: new Set([att1, att2, attOld2, c1, c2]),
    others: new Set(),
    to: 1,
    made: 1000,
    manifest: {
      gen: head1.gen,
      strategy: "with-transcripts",
      rootHash: enc.rootHash,
      transcriptFiles: { [c1]: 10, [c2]: 20 },
      tfCount: 2,
      complete: true,
    },
  };

  // Round 2: chat attachment `att2` deleted, `transcriptManifest` UNCHANGED!
  // Known cache MUST hit (loadCalls stays 1!) AND MUST still drop BOTH `att2` (deleted chat attachment) AND `attOld2` (pending drop page)!
  const head2 = makeHead({ origin, batches: [batch1, batch2], files: { [att1]: 5 }, transcriptManifest: enc.rootHash, to: 2, made: 2000 });
  const res2 = await level(fakePlace, HOME, makeOwn(head2), knownAfterPartialDrop, { dropFilesPage: 1 });
  assert.equal(res2.behind, false);
  assert.equal(loadCalls, 1, "Known manifest cache hit MUST NOT re-call loadTranscriptFiles");
  assert.equal(storedFiles.has(att2), false, "deleted chat attachment att2 was reclaimed");
  assert.equal(storedFiles.has(attOld2), false, "pending drop page file attOld2 was reclaimed");
  assert.equal(storedFiles.has(att1), true, "live chat attachment att1 kept");
  assert.equal(storedFiles.has(c1), true, "live transcript c1 kept");
  assert.equal(storedFiles.has(c2), true, "live transcript c2 kept");
});

test("10. R1: FolderPlace warm-cache fail-closed (without forget) + drop() readdir EACCES/EIO rejection", async () => {
  const root = dataDir("d72a-r1-warm-cache");
  const place = new FolderPlace(root);
  const origin = sid("a");
  const gen = "100-aaaaaaaa";
  const batch = "0000000001-0000000001-11111111.ndjson.zst";
  const c1 = hex64("11", "1");
  const c2 = hex64("22", "2");
  const orphan = hex64("99", "9");
  const enc = encodeTranscriptManifest({ [c1]: 10, [c2]: 20 });

  await place.put(HOME, origin, gen, "batch", batch, Buffer.from("b"));
  await place.putFile(HOME, origin, c1, Buffer.from("c1"));
  await place.putFile(HOME, origin, c2, Buffer.from("c2"));
  await place.putFile(HOME, origin, orphan, Buffer.from("orphan"));
  await place.putFile(HOME, origin, enc.rootHash, enc.rootBytes);
  for (const [lh, { bytes }] of enc.leaves) {
    await place.putFile(HOME, origin, lh, bytes);
  }
  const head = makeHead({ origin, gen, batches: [batch], transcriptManifest: enc.rootHash, to: 2, made: 2000 });
  // Put valid head -> warms both #meta and #headFiles caches inside `place`!
  await place.put(HOME, origin, gen, "head", "head.json", Buffer.from(JSON.stringify(head)));

  // Corrupt one leaf on disk WITHOUT touching head.json and WITHOUT creating a new FolderPlace (warm cache!)
  const leafHash = [...enc.leaves.keys()][0]!;
  const filesDir = join(place.dir(HOME, origin), "files");
  writeFileSync(join(filesDir, leafHash), "corrupted-after-cache-warm");

  // Strict #headMeta in put("head") re-verifies warm-cached manifest heads and fails closed on corrupted leaf
  const olderHead = makeHead({ origin, gen, batches: [batch], to: 1, made: 1000 });
  await assert.rejects(
    () => place.put(HOME, origin, gen, "head", "head.json", Buffer.from(JSON.stringify(olderHead))),
    /hash mismatch/,
    "warm-cached FolderPlace.put('head') re-verifies existing manifest head and rejects on leaf corruption",
  );

  // Now drop() on the SAME warm-cached `place` MUST re-verify the manifest, throw, and preserve ALL files!
  await assert.rejects(
    () => place.drop(HOME, origin, gen, [], [orphan, c1, c2]),
    /hash mismatch/,
    "warm-cached FolderPlace.drop() must still fail-closed on post-write leaf corruption",
  );
  assert.ok(existsSync(join(filesDir, orphan)));
  assert.ok(existsSync(join(filesDir, c1)));
  assert.ok(existsSync(join(filesDir, c2)));

  // Restore leaf so manifest is valid again, then test readdir EACCES / EIO in drop() via wrapped Fs
  writeFileSync(join(filesDir, leafHash), enc.leaves.get(leafHash)!.bytes);
  for (const errCode of ["EACCES", "EIO"] as const) {
    const faultyFs = {
      ...direct,
      names: async (dir: string) => {
        if (dir === place.dir(HOME, origin)) {
          throw Object.assign(new Error(`${errCode}: simulated readdir failure`), { code: errCode });
        }
        return direct.names(dir);
      },
    };
    const faultyPlace = new FolderPlace(root, faultyFs);
    await assert.rejects(
      () => faultyPlace.drop(HOME, origin, gen, [], [orphan, c1]),
      new RegExp(errCode),
      `FolderPlace.drop() must throw on readdir ${errCode} instead of treating as 0 live gens`,
    );
    assert.ok(existsSync(join(filesDir, orphan)));
    assert.ok(existsSync(join(filesDir, c1)));
  }
});

test("11. R1: manifests/ GC runs under backlog (transcripts_pending=true) keeping manifest count bounded", () => {
  const s = makeTranscriptStation("d72a-r1-backlog-gc");
  const replica = join(s.data, "replica");
  let now = 1_700_000_000_000;
  // Create 5 additional codex sessions + transcript files so transcriptPassFiles=1 yields backlog across passes
  const trDir = join(s.data, "transcripts", "codex", "2026", "11", "25");
  for (let i = 1; i <= 5; i++) {
    const key = `chat:tr-extra-${i}`;
    const room = join(s.data, "sessions", "chat", key, "workspace");
    mkdirSync(room, { recursive: true });
    s.store.insertSession({
      key,
      connect: "chat",
      runtime: "codex",
      profile: "cx",
      workspace: room,
      token: `tok-${i}`,
      createdAt: 1,
      lastActiveAt: 1,
      ws: null,
    });
    s.store.setRuntimeSessionId(key, `codex-extra-00${i}`);
    const p = join(trDir, `rollout-2026-11-25-codex-extra-00${i}.jsonl`);
    writeFileSync(p, `{"i":${i},"pad":"${String(i).repeat(1200)}"}\n`);
    utimesSync(p, new Date(now), new Date(now));
  }
  const exp = new Exporter({
    db: s.db,
    replica,
    dataDir: s.data,
    origin: sid("a"),
    now: () => now,
    chunkBytes: 1024,
    transcriptPassFiles: 1,
    compactHeads: true,
  });
  closing.push(() => exp.close());
  exp.setPlaces({ home: HOME, workspaces: [{ workspace: HOME, name: "src" }] });

  const manifestsDir = join(replica, "manifests");
  let sawPending = false;
  let maxManifestFiles = 0;
  for (let step = 0; step < 8; step++) {
    now += MANIFEST_GC_GRACE_MS + 1000;
    const p = exp.pass({ ...nothingTold(), transcripts: true });
    if (p.more) sawPending = true;
    if (existsSync(manifestsDir)) {
      const count = readdirSync(manifestsDir).length;
      if (count > maxManifestFiles) maxManifestFiles = count;
    }
    if (!p.more && step >= 4) break;
  }
  assert.equal(sawPending, true, "test setup actually exercised transcripts_pending=true backlog");
  // Because each pass advances past grace period and GC runs even when transcripts_pending=true,
  // manifests/ only keeps current live + 1 just-superseded generation (never unbounded accumulation).
  const finalCount = readdirSync(manifestsDir).length;
  assert.ok(finalCount <= maxManifestFiles && finalCount < 20, `manifests/ stayed bounded during backlog (final=${finalCount}, max=${maxManifestFiles})`);
});

test("12. R1: Exporter default compact_heads=false returns inline transcriptFiles (frozen MoonBit replica_coord compatibility)", async () => {
  const s = makeTranscriptStation("d72a-r1-default-inline");
  const tsReplica = join(s.data, "replica-ts");
  const now = 1_700_000_000_000;
  const exp = new Exporter({ db: s.db, replica: tsReplica, dataDir: s.data, origin: sid("a"), now: () => now, chunkBytes: 1024 });
  closing.push(() => exp.close());
  exp.setPlaces({ home: HOME, workspaces: [{ workspace: HOME, name: "src" }] });
  const p = exp.pass(nothingTold());
  const head = p.heads[HOME]!;
  assert.equal(head.transcriptManifest, undefined, "default TS Exporter must NOT emit transcriptManifest");
  assert.ok(head.transcriptFiles !== undefined && Object.keys(head.transcriptFiles).length > 0, "default TS Exporter emits inline transcriptFiles");

  if (binary !== null) {
    const mbReplica = join(s.data, "replica-mb");
    const defaultExportThread = () =>
      new MbProcess(binary, [
        "--builder", "replica-export",
        "--db", s.db,
        "--replica", mbReplica,
        "--data-dir", s.data,
        "--origin", sid("a"),
        "--sep", sep,
        "--chunk-bytes", "1024",
      ]);
    const runner = new ProgramRunner({ db: s.db, replica: mbReplica, dataDir: s.data, origin: sid("a"), chunkBytes: 1024 }, defaultExportThread);
    closing.push(() => runner.close());
    await runner.places({ home: HOME, workspaces: [{ workspace: HOME, name: "src" }] });
    const mbPass = await runner.pass(nothingTold());
    const mbHead = mbPass.heads[HOME]!;
    assert.equal(mbHead.transcriptManifest, undefined, "default MB replica-export without --compact-heads must NOT emit transcriptManifest");
    assert.ok(mbHead.transcriptFiles !== undefined && Object.keys(mbHead.transcriptFiles).length > 0, "default MB replica-export emits inline transcriptFiles");
  }
});

test("13. R1: S3Place.put('head') verifies manifest before remote write, dual-field drop() union protection, and self-heal resumes GC", async () => {
  const mock = new MiniS3Server();
  await mock.start();
  closing.push(() => mock.stop());
  const target: NormalizedS3Target = {
    ...mock.target("22".repeat(32), true),
    id: "t1",
    prefix: "r1",
  };
  const s3 = new S3Place(target);
  const origin = sid("a");
  const gen = "100-aaaaaaaa";
  const batch = "0000000001-0000000001-11111111.ndjson.zst";
  const c1 = hex64("11", "1");
  const inlineExtra = hex64("22", "2");
  const orphan = hex64("99", "9");
  const enc = encodeTranscriptManifest({ [c1]: 10 });

  await s3.put(HOME, origin, gen, "batch", batch, Buffer.from("b"));
  await s3.putFile(HOME, origin, c1, Buffer.from("c1"));
  await s3.putFile(HOME, origin, inlineExtra, Buffer.from("inline-extra"));
  await s3.putFile(HOME, origin, orphan, Buffer.from("orphan"));
  await s3.putFile(HOME, origin, enc.rootHash, enc.rootBytes);
  for (const [lh, { bytes }] of enc.leaves) await s3.putFile(HOME, origin, lh, bytes);

  // 13a. Put valid head1 (dual-field: transcriptManifest + inline transcriptFiles with inlineExtra)
  const head1 = makeHead({
    origin,
    gen,
    batches: [batch],
    transcriptManifest: enc.rootHash,
    transcriptFiles: { [c1]: 10, [inlineExtra]: 12 },
    to: 1,
    made: 1000,
  });
  await s3.put(HOME, origin, gen, "head", "head.json", Buffer.from(JSON.stringify(head1)), head1);

  // 13b. Attempt to put head2 with missing/corrupt transcriptManifest -> MUST reject BEFORE overwriting remote head1!
  const missingManifestRoot = hex64("de", "a");
  const head2Bad = makeHead({ origin, gen, batches: [batch], transcriptManifest: missingManifestRoot, to: 2, made: 2000 });
  await assert.rejects(
    () => s3.put(HOME, origin, gen, "head", "head.json", Buffer.from(JSON.stringify(head2Bad)), head2Bad),
    /missing/,
    "S3Place.put('head') must reject invalid manifest before overwriting remote head",
  );
  const heldAfterBad = await s3.held(HOME, origin);
  assert.equal(heldAfterBad.gens[0]!.head!.to, 1, "remote head1 was NOT overwritten by failed put('head')");
  assert.equal(heldAfterBad.hasUnverifiedHead, undefined);

  // 13c. Dual-field drop() protects inline-only chunk `inlineExtra` AND manifest chunk `c1`, while deleting `orphan`
  await s3.drop(HOME, origin, gen, [], [c1, inlineExtra, orphan]);
  const wt = s3.wsTag(HOME);
  const ot = s3.originTag(origin);
  assert.ok(mock.objects.has(`r1/${wt}/${ot}/files/${s3.fileTag(c1)}.enc`), "manifest chunk protected");
  assert.ok(mock.objects.has(`r1/${wt}/${ot}/files/${s3.fileTag(inlineExtra)}.enc`), "dual-field inline-only chunk protected");
  assert.ok(!mock.objects.has(`r1/${wt}/${ot}/files/${s3.fileTag(orphan)}.enc`), "orphan chunk deleted");

  // 13d. Self-heal: corrupt current gen's head on S3 + add an orphan -> held() reports unverifiedGens=[gen],
  // then level() rewrites verified wireHead for `gen`, clears hasUnverifiedHead, and deletes the orphan!
  const orphan2 = hex64("88", "8");
  await s3.putFile(HOME, origin, orphan2, Buffer.from("orphan2"));
  mock.objects.set(`r1/${wt}/${ot}/head/${gen}.enc`, Buffer.from("corrupted-head-bytes"));
  const unverifiedHeld = await s3.held(HOME, origin);
  assert.equal(unverifiedHeld.hasUnverifiedHead, true);
  assert.deepEqual(unverifiedHeld.unverifiedGens, [gen]);

  const ownHead = makeHead({ origin, gen, batches: [batch], transcriptFiles: { [c1]: 10 }, to: 2, made: 2000 });
  const own: Own = {
    head: ownHead,
    batch: async () => Buffer.from("b"),
    sources: async () => new Map(),
  };
  const levelled = await level(s3, HOME, own, null);
  assert.equal(levelled.behind, false);
  assert.equal(levelled.known.hasUnverifiedHead, false, "self-healed own gen clears hasUnverifiedHead");
  assert.ok(!mock.objects.has(`r1/${wt}/${ot}/files/${s3.fileTag(orphan2)}.enc`), "orphan reclaimed after own gen self-healed");
});

test("14. R1: handOver and holdsAll/holdsAllLogical verify actual on-disk Holding.batches and emit inline wire head", async () => {
  const fromPlace = new FolderPlace(dataDir("d72a-r1-ho-from"));
  const toPlace = new FolderPlace(dataDir("d72a-r1-ho-to"));
  const origin = sid("a");
  const gen = "100-aaaaaaaa";
  const b1 = "0000000001-0000000001-11111111.ndjson.zst";
  const b2 = "0000000002-0000000002-22222222.ndjson.zst";
  const c1 = hex64("11", "1");
  const enc = encodeTranscriptManifest({ [c1]: 10 });

  await fromPlace.put(HOME, origin, gen, "batch", b1, Buffer.from("b1"));
  await fromPlace.put(HOME, origin, gen, "batch", b2, Buffer.from("b2"));
  await fromPlace.putFile(HOME, origin, c1, Buffer.from("c1"));
  await fromPlace.putFile(HOME, origin, enc.rootHash, enc.rootBytes);
  for (const [lh, { bytes }] of enc.leaves) await fromPlace.putFile(HOME, origin, lh, bytes);
  const fromHead = makeHead({ origin, gen, batches: [b1, b2], transcriptManifest: enc.rootHash, to: 2, made: 2000 });
  await fromPlace.put(HOME, origin, gen, "head", "head.json", Buffer.from(JSON.stringify(fromHead)));

  // Seed toPlace with b1 + full head declaring [b1, b2], but DELETE b2 from disk!
  await toPlace.put(HOME, origin, gen, "batch", b1, Buffer.from("b1"));
  await toPlace.put(HOME, origin, gen, "batch", b2, Buffer.from("b2"));
  await toPlace.putFile(HOME, origin, c1, Buffer.from("c1"));
  const toHeadInline = makeHead({ origin, gen, batches: [b1, b2], transcriptFiles: { [c1]: 10 }, to: 2, made: 2000 });
  await toPlace.put(HOME, origin, gen, "head", "head.json", Buffer.from(JSON.stringify(toHeadInline)));
  rmSync(join(toPlace.dir(HOME, origin), gen, "log", b2));

  const mineHeld = await fromPlace.held(HOME, origin);
  const theirsHeldMissingBatch = await toPlace.held(HOME, origin);
  assert.equal(holdsAll(mineHeld, theirsHeldMissingBatch), false, "holdsAll rejects missing on-disk batch");
  assert.equal(
    await holdsAllLogical(mineHeld, theirsHeldMissingBatch, {
      readMine: (h, max) => fromPlace.readBounded(HOME, origin, null, h, max),
    }),
    false,
    "holdsAllLogical rejects missing on-disk batch even when head.json matches",
  );

  // handOver MUST detect missing b2, re-upload b2, NOT overwrite existing same-to full head, and return true!
  const wireHeads: Head[] = [];
  const origPut = toPlace.put.bind(toPlace);
  toPlace.put = async (ws, orig, g, kind, name, bytes) => {
    if (kind === "head") wireHeads.push(JSON.parse(bytes.toString("utf8")) as Head);
    return origPut(ws, orig, g, kind, name, bytes);
  };
  const ok = await handOver(fromPlace, toPlace, HOME, origin);
  assert.equal(ok, true);
  assert.ok(existsSync(join(toPlace.dir(HOME, origin), gen, "log", b2)), "handOver restored missing batch file b2");
  assert.equal(wireHeads.length, 0, "handOver must NOT call put('head') when destination already has same-to full head");
  assert.deepEqual((await toPlace.held(HOME, origin)).gens[0]!.head!.transcriptFiles, { [c1]: 10 });

  // Also test: destination missing b2 AND has conflicting same-to full head -> uploads b2, does NOT call put('head'), preserves destination head, returns false!
  const toConflict = new FolderPlace(dataDir("d72a-r3-ho-missing-batch-conflict"));
  const cOther = hex64("22", "2");
  await toConflict.put(HOME, origin, gen, "batch", b1, Buffer.from("b1"));
  await toConflict.put(HOME, origin, gen, "batch", b2, Buffer.from("b2"));
  await toConflict.putFile(HOME, origin, cOther, Buffer.from("other"));
  const conflictHead = makeHead({ origin, gen, batches: [b1, b2], transcriptFiles: { [cOther]: 5 }, to: 2, made: 2001 });
  await toConflict.put(HOME, origin, gen, "head", "head.json", Buffer.from(JSON.stringify(conflictHead)));
  rmSync(join(toConflict.dir(HOME, origin), gen, "log", b2));
  let conflictHeadPuts = 0;
  const origConflictPut = toConflict.put.bind(toConflict);
  toConflict.put = async (ws, orig, g, kind, name, bytes) => {
    if (kind === "head") conflictHeadPuts++;
    return origConflictPut(ws, orig, g, kind, name, bytes);
  };
  assert.equal(await handOver(fromPlace, toConflict, HOME, origin), false, "conflicting same-to full head with missing batch returns false");
  assert.ok(existsSync(join(toConflict.dir(HOME, origin), gen, "log", b2)), "missing batch b2 was uploaded");
  assert.equal(conflictHeadPuts, 0, "must NOT call put('head') to overwrite conflicting same-to full head");
  assert.deepEqual((await toConflict.held(HOME, origin)).gens[0]!.head!.transcriptFiles, { [cOther]: 5 }, "original destination head preserved");
});

test("15. R1: streaming byte cap aborts early + parse-time entry cap + strict integer / -0 rejection", async () => {
  // 15a. readStreamBounded aborts async generator immediately once maxBytes exceeded (never buffers full stream)
  let chunksYielded = 0;
  async function* oversizedStream(): AsyncIterable<Buffer> {
    for (let i = 0; i < 100; i++) {
      chunksYielded++;
      yield Buffer.alloc(1024, 0x41);
    }
  }
  await assert.rejects(
    () => readStreamBounded(oversizedStream(), 2048),
    /exceeds max bytes/,
  );
  assert.equal(chunksYielded, 3, "stream aborted immediately on the 3rd chunk (3072 > 2048), never buffered 100 chunks");

  // 15b. Strict integer syntax rejection (-0, 1e0, 1.0, 01, > MAX_SAFE_INTEGER) + MAX_SAFE_INTEGER acceptance
  const h1 = hex64("0a", "1");
  const h2 = hex64("0a", "2");
  for (const bad of ["-0", "1e0", "1E2", "1.0", "01", "9007199254740992", "99999999999999999999"]) {
    const raw = Buffer.from(`{"v":1,"files":{"${h1}":${bad}}}`, "utf8");
    const hash = createHash("sha256").update(raw).digest("hex");
    assert.throws(() => parseLeafManifest(raw, hash, "0a"), `must reject non-strict integer ${bad}`);
  }
  const maxSafeRaw = Buffer.from(`{"v":1,"files":{"${h1}":9007199254740991}}`, "utf8");
  const maxSafeHash = createHash("sha256").update(maxSafeRaw).digest("hex");
  assert.equal(parseLeafManifest(maxSafeRaw, maxSafeHash, "0a").files[h1], 9007199254740991);

  // 15c. Parse-time entry cap rejects during StrictJsonParser when remainingEntries is exceeded
  const twoEntries = Buffer.from(`{"v":1,"files":{"${h1}":1,"${h2}":2}}`, "utf8");
  const twoHash = createHash("sha256").update(twoEntries).digest("hex");
  assert.throws(
    () => parseLeafManifest(twoEntries, twoHash, "0a", { bytes: 0, entries: MANIFEST_MAX_ENTRIES - 1 }),
    /exceeds max entries/,
  );
});

test("16. R1: local restore when a transcript chunk disappears between held() and stream() still restores chat and records missing", async () => {
  const s = makeTranscriptStation("d72a-r1-vanish");
  const replica = join(s.data, "replica");
  const origin = sid("a");
  const exp = new Exporter({ db: s.db, replica, dataDir: s.data, origin, now: () => 1_700_000_000_000, chunkBytes: 1024, compactHeads: true });
  closing.push(() => exp.close());
  exp.setPlaces({ home: HOME, workspaces: [{ workspace: HOME, name: "src" }] });
  const p = exp.pass(nothingTold());
  const compactHead = p.heads[HOME]!;
  const tf = await loadLocalTranscriptFiles(replica, compactHead);
  const enc = encodeTranscriptManifest(tf);
  const genDirPath = join(replica, "own", HOME, compactHead.gen);

  const targetData = dataDir("d72a-r1-vanish-dst");
  const clock = testClock();
  Store.open(join(targetData, "stillfail.db"), join(targetData, "archive"), clock.clock).close();
  const fibers = new Fibers("vanish-restore");
  closing.push(() => fibers.close());
  const runner = new InlineRunner({ db: join(targetData, "stillfail.db"), replica: join(targetData, "replica"), dataDir: targetData, origin: sid("b"), now: () => 1 });
  closing.push(() => runner.close());
  const copies = new Copies({
    data: targetData,
    here: () => sid("b"),
    places: () => ({ home: HOME, workspaces: [{ workspace: HOME, name: "dst" }] }),
    roster: () => [{ id: sid("b"), name: "dst" }],
    ask: async () => { throw new Error("unused"); },
    runner,
    fibers,
    restart: async () => null,
    changed: () => {},
  });
  closing.push(() => copies.close());

  for (const b of compactHead.batches) {
    await copies.kept.put(HOME, origin, compactHead.gen, "batch", b, readFileSync(join(genDirPath, "log", b)));
  }
  for (const h of Object.keys(compactHead.files)) {
    await copies.kept.putFile(HOME, origin, h, exp.sourceOf(h)!);
  }
  const tfHashes = Object.keys(tf);
  for (const h of tfHashes) {
    await copies.kept.putFile(HOME, origin, h, exp.sourceOf(h)!);
  }
  await copies.kept.putFile(HOME, origin, enc.rootHash, enc.rootBytes);
  for (const [lh, { bytes }] of enc.leaves) await copies.kept.putFile(HOME, origin, lh, bytes);
  await copies.kept.put(HOME, origin, compactHead.gen, "head", "head.json", Buffer.from(JSON.stringify(compactHead)));

  // Delete one transcript chunk AFTER held() lists it, right before stream() reads it!
  const vanishedChunk = tfHashes[0]!;
  const origHeld = copies.kept.held.bind(copies.kept);
  copies.kept.held = async (ws, orig) => {
    const res = await origHeld(ws, orig);
    rmSync(join(copies.kept.dir(ws, orig), "files", vanishedChunk), { force: true });
    return res;
  };

  await copies.placesChanged();
  await copies.settle();
  await copies.restore(HOME, origin, compactHead.gen, { station: sid("b") });
  takeBack(targetData, join(targetData, "stillfail.db"), 20);
  const outcome = JSON.parse(readFileSync(join(targetData, "replica", "restored.json"), "utf8"));
  assert.equal(outcome.error, null, "vanished transcript chunk must not fail chat restore");
  assert.ok(outcome.missing >= 1, "vanished transcript chunk recorded in missing");
  const restoredDb = Store.open(join(targetData, "stillfail.db"), join(targetData, "archive"), clock.clock);
  assert.ok(restoredDb.getSession("chat:tr") !== null, "chat session restored intact");
  const restoredAtt = join(targetData, s.att.path.slice(s.data.length + 1));
  assert.equal(readFileSync(restoredAtt, "utf8"), "attachment-bytes", "chat attachment restored intact");
  restoredDb.close();
});

test("17. R1: mid-flight configChanged() switching includeTranscripts does not write back stale Known", async () => {
  const s = makeTranscriptStation("d72a-r1-config-race");
  const mock = new MiniS3Server();
  await mock.start();
  closing.push(() => mock.stop());
  const origin = sid("a");
  const fibers = new Fibers("config-race");
  closing.push(() => fibers.close());
  const runner = new InlineRunner({ db: s.db, replica: join(s.data, "replica"), dataDir: s.data, origin, now: () => 1_700_000_000_000, chunkBytes: 1024 });
  closing.push(() => runner.close());

  let includeTranscripts = false;
  let releaseFirstHead: (() => void) | null = null;
  const firstHeadPaused = new Promise<void>((resolve) => {
    // Hook mock S3 PUT of head/*.enc to pause the first sync mid-flight
    const origPut = mock.objects.set.bind(mock.objects);
    let pausedOnce = false;
    mock.objects.set = (k: string, v: Buffer) => {
      if (!pausedOnce && k.includes("/head/")) {
        pausedOnce = true;
        resolve();
      }
      return origPut(k, v);
    };
  });

  // Gate on fetch for the first head PUT so the sync stays genuinely in-flight while configChanged() runs!
  const origFetch = globalThis.fetch;
  let headPutGate: Promise<void> | null = new Promise<void>((r) => { releaseFirstHead = r; });
  let firstHeadStartedResolve!: () => void;
  const firstHeadStarted = new Promise<void>((r) => { firstHeadStartedResolve = r; });
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    if (init?.method === "PUT" && url.includes("/head/") && headPutGate !== null) {
      const gate = headPutGate;
      headPutGate = null;
      firstHeadStartedResolve();
      await gate;
    }
    return origFetch(input, init);
  }) as typeof fetch;
  closing.push(() => {
    globalThis.fetch = origFetch;
  });

  const makeTarget = (): NormalizedS3Target => ({
    ...mock.target("33".repeat(32), includeTranscripts),
    id: "s3-race",
    name: "race",
    prefix: "race",
  });

  const copies = new Copies({
    data: s.data,
    here: () => origin,
    places: () => ({ home: HOME, workspaces: [{ workspace: HOME, name: "src" }] }),
    roster: () => [{ id: origin, name: "src" }],
    ask: async () => { throw new Error("unused"); },
    runner,
    fibers,
    restart: async () => null,
    changed: () => {},
    backup: () => ({ mode: "manual", stations: [], acceptOthers: true, s3: [makeTarget()] }),
  });
  closing.push(() => copies.close());

  await copies.placesChanged();
  await copies.settleExport();
  // Trigger first sync with includeTranscripts=false
  copies.configChanged();
  await firstHeadStarted;

  // Mid-flight: flip includeTranscripts=true and call configChanged()!
  includeTranscripts = true;
  copies.configChanged();
  // Release the in-flight first sync
  releaseFirstHead!();
  await firstHeadPaused;

  // Wait deterministically for Copies to finish both the in-flight sync and the automatic re-sync under includeTranscripts=true
  await copies.settle();
  const s3Verify = new S3Place(makeTarget());
  const held = await s3Verify.held(HOME, origin);
  assert.equal(held.gens.length, 1);
  const h = held.gens[0]!.head!;
  const diskHeadPath = join(s.data, "replica", "own", HOME, h.gen, "head.json");
  const expectedTf = (JSON.parse(readFileSync(diskHeadPath, "utf8")) as Head).transcriptFiles ?? {};
  const expectedHashes = Object.keys(expectedTf);
  assert.ok(expectedHashes.length > 0, "expected at least one transcript chunk");
  const heldFiles = new Set(held.files);
  for (const hash of expectedHashes) {
    assert.ok(heldFiles.has(hash), `expected transcript chunk ${hash} uploaded to S3 after includeTranscripts=true toggle`);
  }
});

test("18. R2: handOver refuses and preserves source copy on source readdir EIO or corrupted head.json", async () => {
  const srcRoot = dataDir("d72a-r2-ho-err-src");
  const dstRoot = dataDir("d72a-r2-ho-err-dst");
  const srcSeed = new FolderPlace(srcRoot);
  const dstPlace = new FolderPlace(dstRoot);
  const origin = sid("a");
  const gen = "100-aaaaaaaa";
  const batch = "0000000001-0000000001-11111111.ndjson.zst";
  const c1 = hex64("11", "1");

  await srcSeed.put(HOME, origin, gen, "batch", batch, Buffer.from("b1"));
  await srcSeed.putFile(HOME, origin, c1, Buffer.from("c1"));
  const validHead = makeHead({ origin, gen, batches: [batch], transcriptFiles: { [c1]: 10 }, to: 1, made: 1000 });
  await srcSeed.put(HOME, origin, gen, "head", "head.json", Buffer.from(JSON.stringify(validHead)));

  // 18a. Source readdir EIO -> handOver returns false, source directory and batch remain intact
  const eioFs = {
    ...direct,
    names: async (dir: string) => {
      if (dir === srcSeed.dir(HOME, origin)) {
        throw Object.assign(new Error("EIO: simulated source readdir failure"), { code: "EIO" });
      }
      return direct.names(dir);
    },
  };
  const eioSrc = new FolderPlace(srcRoot, eioFs);
  assert.equal(await handOver(eioSrc, dstPlace, HOME, origin), false, "handOver must return false on source readdir EIO");
  assert.ok(existsSync(join(srcSeed.dir(HOME, origin), gen, "log", batch)), "source batch preserved after EIO");
  assert.ok(existsSync(join(srcSeed.dir(HOME, origin), "files", c1)), "source file preserved after EIO");

  // 18b. Corrupted source head.json -> heldStrict marks hasUnverifiedHead, handOver returns false and preserves source
  writeFileSync(join(srcSeed.dir(HOME, origin), gen, "head.json"), "{corrupted-json");
  const strictHeld = await srcSeed.heldStrict(HOME, origin);
  assert.equal(strictHeld.hasUnverifiedHead, true, "heldStrict marks corrupted head.json as unverified");
  assert.equal(await handOver(srcSeed, dstPlace, HOME, origin), false, "handOver must refuse corrupted source head.json");
  assert.ok(existsSync(join(srcSeed.dir(HOME, origin), gen, "log", batch)), "source batch preserved on corrupted head.json");
});

test("19. R2: same-to conflicting full heads do not overwrite destination + dual-field handOver preserves union", async () => {
  const origin = sid("a");
  const gen = "100-aaaaaaaa";
  const batch = "0000000001-0000000001-11111111.ndjson.zst";
  const cMine = hex64("11", "1");
  const cTheirs = hex64("22", "2");
  const cInline = hex64("33", "3");

  // 19a. Conflicting full heads at same `to=2` (each has a unique chunk) -> handOver must NOT overwrite destination and returns false
  const fromA = new FolderPlace(dataDir("d72a-r2-conflict-from"));
  const toA = new FolderPlace(dataDir("d72a-r2-conflict-to"));
  await fromA.put(HOME, origin, gen, "batch", batch, Buffer.from("b"));
  await fromA.putFile(HOME, origin, cMine, Buffer.from("mine"));
  const headMine = makeHead({ origin, gen, batches: [batch], transcriptFiles: { [cMine]: 4 }, to: 2, made: 2000 });
  await fromA.put(HOME, origin, gen, "head", "head.json", Buffer.from(JSON.stringify(headMine)));

  await toA.put(HOME, origin, gen, "batch", batch, Buffer.from("b"));
  await toA.putFile(HOME, origin, cTheirs, Buffer.from("theirs"));
  const headTheirs = makeHead({ origin, gen, batches: [batch], transcriptFiles: { [cTheirs]: 6 }, to: 2, made: 2001 });
  await toA.put(HOME, origin, gen, "head", "head.json", Buffer.from(JSON.stringify(headTheirs)));

  assert.equal(await handOver(fromA, toA, HOME, origin), false, "conflicting same-to full heads must return false to protect source");
  const toHeldAfter = await toA.held(HOME, origin);
  assert.deepEqual(toHeldAfter.gens[0]!.head!.transcriptFiles, { [cTheirs]: 6 }, "destination full head was NOT overwritten");

  // Also direct FolderPlace.put('head') with conflicting same-to full head must reject (/head conflict:/) and preserve existing full head
  await assert.rejects(
    () => toA.put(HOME, origin, gen, "head", "head.json", Buffer.from(JSON.stringify(headMine))),
    /head conflict:/,
  );
  assert.deepEqual((await toA.held(HOME, origin)).gens[0]!.head!.transcriptFiles, { [cTheirs]: 6 });

  // 19b. Dual-field source head (transcriptManifest + extra inline-only transcriptFiles) -> handOver emits inline union!
  const fromB = new FolderPlace(dataDir("d72a-r2-dual-from"));
  const toB = new FolderPlace(dataDir("d72a-r2-dual-to"));
  const enc = encodeTranscriptManifest({ [cMine]: 4 });
  await fromB.put(HOME, origin, gen, "batch", batch, Buffer.from("b"));
  await fromB.putFile(HOME, origin, cMine, Buffer.from("mine"));
  await fromB.putFile(HOME, origin, cInline, Buffer.from("inline"));
  await fromB.putFile(HOME, origin, enc.rootHash, enc.rootBytes);
  for (const [lh, { bytes }] of enc.leaves) await fromB.putFile(HOME, origin, lh, bytes);
  const dualHead = makeHead({
    origin,
    gen,
    batches: [batch],
    transcriptManifest: enc.rootHash,
    transcriptFiles: { [cInline]: 6 },
    to: 2,
    made: 2000,
  });
  await fromB.put(HOME, origin, gen, "head", "head.json", Buffer.from(JSON.stringify(dualHead)));

  assert.equal(await handOver(fromB, toB, HOME, origin), true);
  const dstHead = (await toB.held(HOME, origin)).gens[0]!.head!;
  assert.equal(dstHead.transcriptManifest, undefined, "handOver wire head is inline");
  assert.deepEqual(dstHead.transcriptFiles, { [cMine]: 4, [cInline]: 6 }, "dual-field handOver preserves union of manifest and inline-only refs");
});

test("20. R2: gc_manifests preserves grace state across readdir errors and grants full 10-min grace to old-mtime orphans after restart", () => {
  const s = makeTranscriptStation("d72a-r2-gc-restart");
  const replica = join(s.data, "replica");
  let now = 1_700_000_000_000;
  let injectReaddirErr = false;
  const manifestsDir = join(replica, "manifests");

  const exp1 = new Exporter({
    db: s.db,
    replica,
    dataDir: s.data,
    origin: sid("a"),
    now: () => now,
    chunkBytes: 1024,
    compactHeads: true,
    testFaults: {
      readdirError: (p) => (injectReaddirErr && p === manifestsDir ? Object.assign(new Error("EIO"), { code: "EIO" }) : null),
    },
  });
  closing.push(() => exp1.close());
  exp1.setPlaces({ home: HOME, workspaces: [{ workspace: HOME, name: "src" }] });

  const p1 = exp1.pass(nothingTold());
  const oldRoot = p1.heads[HOME]!.transcriptManifest!;
  // Modify transcript so oldRoot is superseded at `now`
  now += 60_000;
  writeFileSync(s.trPath, "updated-" + "z".repeat(2000));
  utimesSync(s.trPath, new Date(now), new Date(now));
  const p2 = exp1.pass({ ...nothingTold(), transcripts: true });
  assert.notEqual(p2.heads[HOME]!.transcriptManifest, oldRoot);

  // Inject readdir error halfway through grace -> must NOT clear superseded record!
  now += 5 * 60_000;
  injectReaddirErr = true;
  exp1.pass({ ...nothingTold(), transcripts: true });
  assert.ok(existsSync(join(manifestsDir, oldRoot)));

  // Clear readdir error and advance remaining 5 minutes -> oldRoot is GC'd right on schedule (proving grace record was preserved)!
  injectReaddirErr = false;
  now += 5 * 60_000;
  exp1.pass({ ...nothingTold(), transcripts: true });
  assert.ok(!existsSync(join(manifestsDir, oldRoot)), "grace record survived readdir error and expired at 10 min");
  exp1.close();

  // Restart: plant an old-mtime orphan manifest file (mtime = 1 hour ago) and start a fresh Exporter!
  const orphanHash = hex64("de", "a");
  const orphanPath = join(manifestsDir, orphanHash);
  writeFileSync(orphanPath, "{}");
  const oneHourAgo = new Date(now - 60 * 60_000);
  utimesSync(orphanPath, oneHourAgo, oneHourAgo);

  const exp2 = new Exporter({ db: s.db, replica, dataDir: s.data, origin: sid("a"), now: () => now, chunkBytes: 1024, compactHeads: true });
  closing.push(() => exp2.close());
  exp2.setPlaces({ home: HOME, workspaces: [{ workspace: HOME, name: "src" }] });

  // Pass 1 after restart: old-mtime orphan is observed for the first time -> MUST NOT be deleted immediately!
  exp2.pass(nothingTold());
  assert.ok(existsSync(orphanPath), "after restart, old-mtime orphan gets full 10-min grace from first observation");

  // 9 min later -> still kept!
  now += MANIFEST_GC_GRACE_MS - 60_000;
  exp2.pass(nothingTold());
  assert.ok(existsSync(orphanPath), "after restart, orphan still kept at 9 min");

  // 10 min after first observation -> deleted!
  now += 60_000;
  exp2.pass(nothingTold());
  assert.ok(!existsSync(orphanPath), "after restart, orphan GC'd after full 10-min grace");
});

test("21. R2: local restore aborts on real EACCES/EIO instead of swallowing into missing", async () => {
  const s = makeTranscriptStation("d72a-r2-restore-eio");
  const replica = join(s.data, "replica");
  const origin = sid("a");
  const exp = new Exporter({ db: s.db, replica, dataDir: s.data, origin, now: () => 1_700_000_000_000, chunkBytes: 1024, compactHeads: true });
  closing.push(() => exp.close());
  exp.setPlaces({ home: HOME, workspaces: [{ workspace: HOME, name: "src" }] });
  const p = exp.pass(nothingTold());
  const compactHead = p.heads[HOME]!;
  const tf = await loadLocalTranscriptFiles(replica, compactHead);
  const enc = encodeTranscriptManifest(tf);
  const genDirPath = join(replica, "own", HOME, compactHead.gen);
  const targetChunk = Object.keys(tf)[0]!;

  const targetData = dataDir("d72a-r2-restore-eio-dst");
  const clock = testClock();
  Store.open(join(targetData, "stillfail.db"), join(targetData, "archive"), clock.clock).close();
  const fibers = new Fibers("eio-restore");
  closing.push(() => fibers.close());
  const runner = new InlineRunner({ db: join(targetData, "stillfail.db"), replica: join(targetData, "replica"), dataDir: targetData, origin: sid("b"), now: () => 1 });
  closing.push(() => runner.close());
  const copies = new Copies({
    data: targetData,
    here: () => sid("b"),
    places: () => ({ home: HOME, workspaces: [{ workspace: HOME, name: "dst" }] }),
    roster: () => [{ id: sid("b"), name: "dst" }],
    ask: async () => { throw new Error("unused"); },
    runner,
    fibers,
    restart: async () => null,
    changed: () => {},
  });
  closing.push(() => copies.close());

  for (const b of compactHead.batches) {
    await copies.kept.put(HOME, origin, compactHead.gen, "batch", b, readFileSync(join(genDirPath, "log", b)));
  }
  for (const h of Object.keys(compactHead.files)) {
    await copies.kept.putFile(HOME, origin, h, exp.sourceOf(h)!);
  }
  for (const h of Object.keys(tf)) {
    await copies.kept.putFile(HOME, origin, h, exp.sourceOf(h)!);
  }
  await copies.kept.putFile(HOME, origin, enc.rootHash, enc.rootBytes);
  for (const [lh, { bytes }] of enc.leaves) await copies.kept.putFile(HOME, origin, lh, bytes);
  await copies.kept.put(HOME, origin, compactHead.gen, "head", "head.json", Buffer.from(JSON.stringify(compactHead)));

  // Wrap copies.kept.fs.read to throw EACCES on targetChunk -> stream() must preserve EACCES and abort restore!
  const origFsRead = copies.kept.fs.read.bind(copies.kept.fs);
  const badPath = join(copies.kept.dir(HOME, origin), "files", targetChunk);
  (copies.kept as unknown as { fs: typeof direct }).fs = {
    ...copies.kept.fs,
    read: async (path, offset, length) => {
      if (path === badPath) throw Object.assign(new Error("EACCES: permission denied"), { code: "EACCES" });
      return origFsRead(path, offset, length);
    },
  };

  await copies.placesChanged();
  await copies.settle();
  await assert.rejects(
    () => copies.restore(HOME, origin, compactHead.gen, { station: sid("b") }),
    /EACCES/,
    "restore must abort on EACCES instead of swallowing it as ENOENT missingChunk",
  );
});

test("22. R3: source generation with on-disk batches but no head.json is never approved for deletion by handOver/holdsAll/holdsAllLogical", async () => {
  const fromPlace = new FolderPlace(dataDir("d72a-r3-nohead-from"));
  const toPlace = new FolderPlace(dataDir("d72a-r3-nohead-to"));
  const origin = sid("a");
  const gen = "100-aaaaaaaa";
  const batch = "0000000001-0000000001-11111111.ndjson.zst";

  // Seed source with an in-flight batch file and NO head.json
  await fromPlace.put(HOME, origin, gen, "batch", batch, Buffer.from("in-flight-batch"));

  const mine = await fromPlace.heldStrict(HOME, origin);
  const theirs = await toPlace.held(HOME, origin);
  assert.equal(holdsAll(mine, theirs), false, "holdsAll must refuse unfinished gen with batches and no head.json");
  assert.equal(await holdsAllLogical(mine, theirs), false, "holdsAllLogical must refuse unfinished gen with batches and no head.json");
  assert.equal(await handOver(fromPlace, toPlace, HOME, origin), false, "handOver must refuse and preserve source");
  assert.ok(existsSync(join(fromPlace.dir(HOME, origin), gen, "log", batch)), "in-flight source batch preserved");
});

test("23. R3: same-to partial vs partial with distinct transcript chunks does not approve handOver deletion", async () => {
  const fromPlace = new FolderPlace(dataDir("d72a-r3-partial-from"));
  const toPlace = new FolderPlace(dataDir("d72a-r3-partial-to"));
  const origin = sid("a");
  const gen = "100-aaaaaaaa";
  const batch = "0000000001-0000000001-11111111.ndjson.zst";
  const cMine = hex64("11", "1");
  const cTheirs = hex64("22", "2");

  await fromPlace.put(HOME, origin, gen, "batch", batch, Buffer.from("b"));
  await fromPlace.putFile(HOME, origin, cMine, Buffer.from("mine"));
  const minePartial = makeHead({ origin, gen, batches: [batch], transcriptFiles: { [cMine]: 4 }, partial: true, to: 2, made: 2000 });
  await fromPlace.put(HOME, origin, gen, "head", "head.json", Buffer.from(JSON.stringify(minePartial)));

  await toPlace.put(HOME, origin, gen, "batch", batch, Buffer.from("b"));
  await toPlace.putFile(HOME, origin, cTheirs, Buffer.from("theirs"));
  const theirsPartial = makeHead({ origin, gen, batches: [batch], transcriptFiles: { [cTheirs]: 6 }, partial: true, to: 2, made: 2001 });
  await toPlace.put(HOME, origin, gen, "head", "head.json", Buffer.from(JSON.stringify(theirsPartial)));

  const mineHeld = await fromPlace.heldStrict(HOME, origin);
  const theirsHeld = await toPlace.held(HOME, origin);
  assert.equal(holdsAll(mineHeld, theirsHeld), false, "holdsAll must require transcript superset for same-to partial vs partial");
  assert.equal(await holdsAllLogical(mineHeld, theirsHeld), false, "holdsAllLogical must require transcript superset for same-to partial vs partial");
  assert.equal(await handOver(fromPlace, toPlace, HOME, origin), false, "handOver must return false when same-to partial lacks source unique chunk");
  assert.deepEqual((await toPlace.held(HOME, origin)).gens[0]!.head!.transcriptFiles, { [cTheirs]: 6 }, "destination partial head preserved");
});

test("24. R3: PeerPlace/serve restore aborts on FolderPlace.pathOf EACCES/EIO instead of masking as 'not kept here'", async () => {
  const s = makeTranscriptStation("d72a-r3-peer-eio");
  const replica = join(s.data, "replica");
  const origin = sid("a");
  const peerId = sid("c");
  const exp = new Exporter({ db: s.db, replica, dataDir: s.data, origin, now: () => 1_700_000_000_000, chunkBytes: 1024, compactHeads: true });
  closing.push(() => exp.close());
  exp.setPlaces({ home: HOME, workspaces: [{ workspace: HOME, name: "src" }] });
  const p = exp.pass(nothingTold());
  const compactHead = p.heads[HOME]!;
  const tf = await loadLocalTranscriptFiles(replica, compactHead);
  const enc = encodeTranscriptManifest(tf);
  const genDirPath = join(replica, "own", HOME, compactHead.gen);
  const targetChunk = Object.keys(tf)[0]!;

  // Seed peer's FolderPlace with full backup
  const peerRoot = dataDir("d72a-r3-peer-kept");
  const peerSeed = new FolderPlace(peerRoot);
  for (const b of compactHead.batches) {
    await peerSeed.put(HOME, origin, compactHead.gen, "batch", b, readFileSync(join(genDirPath, "log", b)));
  }
  for (const h of Object.keys(compactHead.files)) {
    await peerSeed.putFile(HOME, origin, h, exp.sourceOf(h)!);
  }
  for (const h of Object.keys(tf)) {
    await peerSeed.putFile(HOME, origin, h, exp.sourceOf(h)!);
  }
  await peerSeed.putFile(HOME, origin, enc.rootHash, enc.rootBytes);
  for (const [lh, { bytes }] of enc.leaves) await peerSeed.putFile(HOME, origin, lh, bytes);
  await peerSeed.put(HOME, origin, compactHead.gen, "head", "head.json", Buffer.from(JSON.stringify(compactHead)));

  // Wrap peer's FolderPlace fs.stat to throw EACCES on targetChunk -> pathOf must propagate EACCES (NOT return null / "not kept here")
  const badPath = join(peerSeed.dir(HOME, origin), "files", targetChunk);
  const faultyPeerPlace = new FolderPlace(peerRoot, {
    ...direct,
    stat: async (path) => {
      if (path === badPath) throw Object.assign(new Error("EACCES: permission denied"), { code: "EACCES" });
      return direct.stat(path);
    },
  });
  const handler = serve({
    place: faultyPeerPlace,
    inWorkspace: () => true,
    hello: () => [],
  });

  const targetData = dataDir("d72a-r3-peer-dst");
  const clock = testClock();
  Store.open(join(targetData, "stillfail.db"), join(targetData, "archive"), clock.clock).close();
  const fibers = new Fibers("peer-eio-restore");
  closing.push(() => fibers.close());
  const runner = new InlineRunner({ db: join(targetData, "stillfail.db"), replica: join(targetData, "replica"), dataDir: targetData, origin: sid("b"), now: () => 1 });
  closing.push(() => runner.close());
  const copies = new Copies({
    data: targetData,
    here: () => sid("b"),
    places: () => ({ home: HOME, workspaces: [{ workspace: HOME, name: "dst" }] }),
    roster: () => [{ id: sid("b"), name: "dst" }, { id: peerId, name: "peer" }],
    ask: async (_station, req) => handler(sid("b"), req, HOME),
    runner,
    fibers,
    restart: async () => null,
    changed: () => {},
  });
  closing.push(() => copies.close());

  await copies.placesChanged();
  await copies.settle();
  await assert.rejects(
    () => copies.restore(HOME, origin, compactHead.gen, { station: peerId }),
    /EACCES/,
    "PeerPlace/serve restore must abort on EACCES instead of treating it as 'not kept here' missing chunk",
  );
});

test("25. R4: same-to partial <-> full bidirectional superset check rejects conflicting refs and upgrades clean subsets", async () => {
  const origin = sid("a");
  const gen = "100-aaaaaaaa";
  const batch = "0000000001-0000000001-11111111.ndjson.zst";
  const cCommon = hex64("11", "1");
  const cUniquePartial = hex64("22", "2");
  const cUniqueFull = hex64("33", "3");

  // 25a. Source partial (has cUniquePartial) -> destination full (lacks cUniquePartial): MUST return false & preserve source!
  const fromPartial = new FolderPlace(dataDir("d72a-r4-p2f-from"));
  const toFull = new FolderPlace(dataDir("d72a-r4-p2f-to"));
  await fromPartial.put(HOME, origin, gen, "batch", batch, Buffer.from("b"));
  await fromPartial.putFile(HOME, origin, cUniquePartial, Buffer.from("up"));
  const srcPartialHead = makeHead({ origin, gen, batches: [batch], transcriptFiles: { [cUniquePartial]: 2 }, partial: true, to: 2, made: 2000 });
  await fromPartial.put(HOME, origin, gen, "head", "head.json", Buffer.from(JSON.stringify(srcPartialHead)));

  await toFull.put(HOME, origin, gen, "batch", batch, Buffer.from("b"));
  await toFull.putFile(HOME, origin, cUniqueFull, Buffer.from("uf"));
  const dstFullHead = makeHead({ origin, gen, batches: [batch], transcriptFiles: { [cUniqueFull]: 2 }, to: 2, made: 2001 });
  await toFull.put(HOME, origin, gen, "head", "head.json", Buffer.from(JSON.stringify(dstFullHead)));

  const mineP = await fromPartial.heldStrict(HOME, origin);
  const theirsF = await toFull.held(HOME, origin);
  assert.equal(holdsAll(mineP, theirsF), false, "holdsAll rejects same-to partial -> full when full lacks partial unique chunk");
  assert.equal(await holdsAllLogical(mineP, theirsF), false, "holdsAllLogical rejects same-to partial -> full when full lacks partial unique chunk");
  assert.equal(await handOver(fromPartial, toFull, HOME, origin), false, "handOver returns false and preserves source partial");

  // 25b. Source full (has cCommon, cUniqueFull) -> destination partial (has cUniquePartial not in source full):
  //      MUST NOT call to.put('head'), preserves destination partial head, and returns false!
  const fromFull = new FolderPlace(dataDir("d72a-r4-f2p-from"));
  const toPartial = new FolderPlace(dataDir("d72a-r4-f2p-to"));
  await fromFull.put(HOME, origin, gen, "batch", batch, Buffer.from("b"));
  await fromFull.putFile(HOME, origin, cCommon, Buffer.from("cm"));
  await fromFull.putFile(HOME, origin, cUniqueFull, Buffer.from("uf"));
  const srcFullHead = makeHead({ origin, gen, batches: [batch], transcriptFiles: { [cCommon]: 2, [cUniqueFull]: 2 }, to: 2, made: 2001 });
  await fromFull.put(HOME, origin, gen, "head", "head.json", Buffer.from(JSON.stringify(srcFullHead)));

  await toPartial.put(HOME, origin, gen, "batch", batch, Buffer.from("b"));
  await toPartial.putFile(HOME, origin, cUniquePartial, Buffer.from("up"));
  const dstPartialConflict = makeHead({ origin, gen, batches: [batch], transcriptFiles: { [cUniquePartial]: 2 }, partial: true, to: 2, made: 2000 });
  await toPartial.put(HOME, origin, gen, "head", "head.json", Buffer.from(JSON.stringify(dstPartialConflict)));

  let headPutCalls = 0;
  const origPut = toPartial.put.bind(toPartial);
  toPartial.put = async (ws, orig, g, kind, name, bytes) => {
    if (kind === "head") headPutCalls++;
    return origPut(ws, orig, g, kind, name, bytes);
  };
  assert.equal(await handOver(fromFull, toPartial, HOME, origin), false, "handOver refuses overwriting conflicting same-to partial head");
  assert.equal(headPutCalls, 0, "must NOT call to.put('head') when source full does not cover destination partial");
  assert.deepEqual((await toPartial.held(HOME, origin)).gens[0]!.head!.transcriptFiles, { [cUniquePartial]: 2 }, "destination partial head preserved intact");

  // 25c. Clean subset destination partial (only cCommon) -> source full (cCommon + cUniqueFull): upgrades cleanly to full!
  const toPartialSubset = new FolderPlace(dataDir("d72a-r4-f2p-ok"));
  await toPartialSubset.put(HOME, origin, gen, "batch", batch, Buffer.from("b"));
  await toPartialSubset.putFile(HOME, origin, cCommon, Buffer.from("cm"));
  const dstPartialSubset = makeHead({ origin, gen, batches: [batch], transcriptFiles: { [cCommon]: 2 }, partial: true, to: 2, made: 2000 });
  await toPartialSubset.put(HOME, origin, gen, "head", "head.json", Buffer.from(JSON.stringify(dstPartialSubset)));

  assert.equal(await handOver(fromFull, toPartialSubset, HOME, origin), true, "clean subset partial upgrades to full");
  const upgraded = (await toPartialSubset.held(HOME, origin)).gens[0]!.head!;
  assert.equal(upgraded.partial, undefined, "upgraded head is full");
  assert.deepEqual(upgraded.transcriptFiles, { [cCommon]: 2, [cUniqueFull]: 2 });

  // 25d. R5 TOCTOU: concurrent same-to partial update between handOver's to.held() and to.put('head')
  //      adds a unique chunk `cConcurrentOnly` not in `fromFull` -> FolderPlace.put('head') under #withLock
  //      MUST refuse overwrite, preserve `cConcurrentOnly` on disk, and handOver MUST return false!
  const cConcurrentOnly = hex64("44", "4");
  const toToctou = new FolderPlace(dataDir("d72a-r5-toctou"));
  await toToctou.put(HOME, origin, gen, "batch", batch, Buffer.from("b"));
  await toToctou.putFile(HOME, origin, cCommon, Buffer.from("cm"));
  await toToctou.put(HOME, origin, gen, "head", "head.json", Buffer.from(JSON.stringify(dstPartialSubset)));

  let injectedConcurrent = false;
  const wrappedTo: Place = {
    held: (ws, orig) => toToctou.held(ws, orig),
    putFile: (ws, orig, hash, src) => toToctou.putFile(ws, orig, hash, src),
    drop: (ws, orig, g, b, f) => toToctou.drop(ws, orig, g, b, f),
    put: async (ws, orig, g, kind, name, bytes) => {
      if (kind === "head" && !injectedConcurrent) {
        injectedConcurrent = true;
        // Simulate concurrent writer updating the same-to partial head with a new unique chunk before handOver's put("head")!
        await toToctou.putFile(ws, orig, cConcurrentOnly, Buffer.from("co"));
        const concurrentPartial = makeHead({
          origin,
          gen,
          batches: [batch],
          transcriptFiles: { [cCommon]: 2, [cConcurrentOnly]: 2 },
          partial: true,
          to: 2,
          made: 2000,
        });
        await toToctou.put(ws, orig, g, "head", "head.json", Buffer.from(JSON.stringify(concurrentPartial)));
      }
      return toToctou.put(ws, orig, g, kind, name, bytes);
    },
  };
  assert.equal(await handOver(fromFull, wrappedTo, HOME, origin), false, "TOCTOU concurrent partial update must prevent overwrite and return false");
  assert.equal(injectedConcurrent, true);
  const afterToctou = (await toToctou.held(HOME, origin)).gens[0]!.head!;
  assert.equal(afterToctou.partial, true, "concurrent partial head preserved on disk");
  assert.deepEqual(afterToctou.transcriptFiles, { [cCommon]: 2, [cConcurrentOnly]: 2 }, "cConcurrentOnly preserved on disk");

  // Also verify synchronous holdsAll rejects dual-field heads sharing the same transcriptManifest root when inline-only refs differ
  const encCommon = encodeTranscriptManifest({ [cCommon]: 2 });
  const dualMine: Held = {
    gens: [{ gen, head: makeHead({ origin, gen, batches: [batch], transcriptManifest: encCommon.rootHash, transcriptFiles: { [cUniqueFull]: 2 }, to: 2 }), batches: [batch] }],
    files: [cCommon, cUniqueFull],
  };
  const dualTheirsMissingInline: Held = {
    gens: [{ gen, head: makeHead({ origin, gen, batches: [batch], transcriptManifest: encCommon.rootHash, to: 2 }), batches: [batch] }],
    files: [cCommon, cUniqueFull],
  };
  assert.equal(holdsAll(dualMine, dualTheirsMissingInline), false, "sync holdsAll must check inline transcriptFiles superset even when transcriptManifest roots match");
});

test("26. R6: FolderPlace.put('head') fails closed on stat/readAll/corrupt existing head AND level() rejects on same-to partial conflict without advancing Known", async () => {
  const origin = sid("a");
  const gen = "100-aaaaaaaa";
  const batch = "0000000001-0000000001-11111111.ndjson.zst";
  const cCommon = hex64("11", "1");
  const cUniquePartial = hex64("22", "2");
  const cUniqueFull = hex64("33", "3");

  // 26a. Existing head on disk, cold-cache FolderPlace: stat EIO, readAll EIO, and corrupted head.json MUST reject put('head') and preserve original bytes!
  const rootA = dataDir("d72a-r6-failclosed");
  const seed = new FolderPlace(rootA);
  await seed.put(HOME, origin, gen, "batch", batch, Buffer.from("b"));
  await seed.putFile(HOME, origin, cCommon, Buffer.from("cm"));
  await seed.putFile(HOME, origin, cUniquePartial, Buffer.from("up"));
  await seed.putFile(HOME, origin, cUniqueFull, Buffer.from("uf"));
  const origHead = makeHead({ origin, gen, batches: [batch], transcriptFiles: { [cCommon]: 2, [cUniquePartial]: 2 }, to: 2, made: 2000 });
  const origBytes = Buffer.from(JSON.stringify(origHead));
  await seed.put(HOME, origin, gen, "head", "head.json", origBytes);
  const headPath = join(seed.dir(HOME, origin), gen, "head.json");
  const incomingHead = makeHead({ origin, gen, batches: [batch], transcriptFiles: { [cCommon]: 2, [cUniqueFull]: 2 }, to: 3, made: 3000 });
  const incomingBytes = Buffer.from(JSON.stringify(incomingHead));

  // (i) stat EIO on head.json
  const statEioPlace = new FolderPlace(rootA, {
    ...direct,
    stat: async (p) => {
      if (p === headPath) throw Object.assign(new Error("EIO: stat head failed"), { code: "EIO" });
      return direct.stat(p);
    },
  });
  await assert.rejects(() => statEioPlace.put(HOME, origin, gen, "head", "head.json", incomingBytes), /EIO/);
  assert.deepEqual(readFileSync(headPath), origBytes, "original head.json bytes preserved after stat EIO");

  // (ii) readAll EIO on head.json
  const readEioPlace = new FolderPlace(rootA, {
    ...direct,
    readAll: async (p) => {
      if (p === headPath) throw Object.assign(new Error("EIO: readAll head failed"), { code: "EIO" });
      return direct.readAll(p);
    },
  });
  await assert.rejects(() => readEioPlace.put(HOME, origin, gen, "head", "head.json", incomingBytes), /EIO/);
  assert.deepEqual(readFileSync(headPath), origBytes, "original head.json bytes preserved after readAll EIO");

  // (iii) corrupted bytes on disk in head.json -> cold-cache FolderPlace MUST reject and preserve disk bytes
  const corruptedBytes = Buffer.from("{corrupted-head-json");
  writeFileSync(headPath, corruptedBytes);
  const coldCorruptPlace = new FolderPlace(rootA);
  await assert.rejects(() => coldCorruptPlace.put(HOME, origin, gen, "head", "head.json", incomingBytes), /corrupted head\.json/);
  assert.deepEqual(readFileSync(headPath), corruptedBytes, "corrupted head.json bytes untouched on fail-closed put('head')");

  // 26b. level() hitting same-to partial conflict rejects (/head conflict:/), does NOT advance Known.to/made or clear unverifiedGens, and preserves destination partial head
  const rootB = dataDir("d72a-r6-level-conflict");
  const dstPlace = new FolderPlace(rootB);
  await dstPlace.put(HOME, origin, gen, "batch", batch, Buffer.from("b"));
  await dstPlace.putFile(HOME, origin, cCommon, Buffer.from("cm"));
  await dstPlace.putFile(HOME, origin, cUniquePartial, Buffer.from("up"));
  const dstPartial = makeHead({ origin, gen, batches: [batch], transcriptFiles: { [cCommon]: 2, [cUniquePartial]: 2 }, partial: true, to: 2, made: 2000 });
  await dstPlace.put(HOME, origin, gen, "head", "head.json", Buffer.from(JSON.stringify(dstPartial)));

  const ownHead = makeHead({ origin, gen, batches: [batch], transcriptFiles: { [cCommon]: 2, [cUniqueFull]: 2 }, to: 2, made: 2001 });
  const cFullPath = join(rootB, "src-full-chunk");
  writeFileSync(cFullPath, "uf");
  const own: Own = {
    head: ownHead,
    batch: async () => Buffer.from("b"),
    sources: async (hashes) => new Map(hashes.filter((h) => h === cUniqueFull).map((h) => [h, cFullPath])),
  };
  const known: Known = {
    gen,
    batches: new Set([batch]),
    files: new Set([cCommon, cUniquePartial]),
    others: new Set(),
    hasUnverifiedHead: true,
    unverifiedGens: new Set([gen]),
    to: 2,
    made: -1,
  };

  await assert.rejects(() => level(dstPlace, HOME, own, known), /head conflict:/);
  assert.equal(known.to, 2, "known.to not advanced");
  assert.equal(known.made, -1, "known.made not advanced");
  assert.equal(known.hasUnverifiedHead, true, "known.hasUnverifiedHead not cleared");
  assert.ok(known.unverifiedGens?.has(gen), "known.unverifiedGens not cleared");
  const afterConflict = (await dstPlace.held(HOME, origin)).gens[0]!.head!;
  assert.equal(afterConflict.partial, true, "destination partial head preserved");
  assert.deepEqual(afterConflict.transcriptFiles, { [cCommon]: 2, [cUniquePartial]: 2 }, "cUniquePartial preserved on disk");
});

test("27. R7: warm-cached FolderPlace.put('head') re-verifies existing manifest root/leaf AND level() rejects same-to full conflict while succeeding idempotently on superset", async () => {
  const origin = sid("a");
  const gen = "100-aaaaaaaa";
  const batch = "0000000001-0000000001-11111111.ndjson.zst";
  const cCommon = hex64("11", "1");
  const cDstOnly = hex64("22", "2");
  const cSrcOnly = hex64("33", "3");

  // 27a. Same warm-cached FolderPlace instance: tamper manifest leaf, then tamper manifest root (leaving head.json mtime & size intact)
  //      -> put('head') with higher to=3 inline head MUST reject both times and preserve original head.json bytes!
  const rootA = dataDir("d72a-r7-warm-manifest");
  const warmPlace = new FolderPlace(rootA);
  const enc = encodeTranscriptManifest({ [cCommon]: 2 });
  await warmPlace.put(HOME, origin, gen, "batch", batch, Buffer.from("b"));
  await warmPlace.putFile(HOME, origin, cCommon, Buffer.from("cm"));
  await warmPlace.putFile(HOME, origin, enc.rootHash, enc.rootBytes);
  for (const [lh, { bytes }] of enc.leaves) {
    await warmPlace.putFile(HOME, origin, lh, bytes);
  }
  const origManifestHead = makeHead({ origin, gen, batches: [batch], transcriptManifest: enc.rootHash, to: 2, made: 2000 });
  const origHeadBytes = Buffer.from(JSON.stringify(origManifestHead));
  await warmPlace.put(HOME, origin, gen, "head", "head.json", origHeadBytes);

  const headPath = join(warmPlace.dir(HOME, origin), gen, "head.json");
  const filesDir = join(warmPlace.dir(HOME, origin), "files");
  const leafHash = [...enc.leaves.keys()][0]!;
  const origLeafBytes = enc.leaves.get(leafHash)!.bytes;
  const higherHead = makeHead({ origin, gen, batches: [batch], transcriptFiles: { [cCommon]: 2 }, to: 3, made: 3000 });
  const higherHeadBytes = Buffer.from(JSON.stringify(higherHead));

  // Tamper leaf on disk (head.json mtime/size unchanged) -> warm-cached put('head') MUST reject!
  writeFileSync(join(filesDir, leafHash), "tampered-leaf-bytes");
  await assert.rejects(
    () => warmPlace.put(HOME, origin, gen, "head", "head.json", higherHeadBytes),
    /hash mismatch/,
    "warm-cached put('head') must re-verify manifest leaf and reject corruption",
  );
  assert.deepEqual(readFileSync(headPath), origHeadBytes, "head.json preserved after leaf tamper");

  // Restore leaf, tamper root on disk (head.json mtime/size unchanged) -> warm-cached put('head') MUST reject!
  writeFileSync(join(filesDir, leafHash), origLeafBytes);
  writeFileSync(join(filesDir, enc.rootHash), "tampered-root-bytes");
  await assert.rejects(
    () => warmPlace.put(HOME, origin, gen, "head", "head.json", higherHeadBytes),
    /hash mismatch/,
    "warm-cached put('head') must re-verify manifest root and reject corruption",
  );
  assert.deepEqual(readFileSync(headPath), origHeadBytes, "head.json preserved after root tamper");

  // 27b. level() hitting same-to full conflict rejects (/head conflict:/) with BOTH known=null and pre-populated Known,
  //      never advances known.made or clears unverifiedGens, and preserves destination full head;
  //      control case where destination full head covers source succeeds idempotently!
  const rootB = dataDir("d72a-r7-level-full-conflict");
  const dstPlace = new FolderPlace(rootB);
  await dstPlace.put(HOME, origin, gen, "batch", batch, Buffer.from("b"));
  await dstPlace.putFile(HOME, origin, cCommon, Buffer.from("cm"));
  await dstPlace.putFile(HOME, origin, cDstOnly, Buffer.from("do"));
  const dstFull = makeHead({ origin, gen, batches: [batch], transcriptFiles: { [cCommon]: 2, [cDstOnly]: 2 }, to: 2, made: 2000 });
  await dstPlace.put(HOME, origin, gen, "head", "head.json", Buffer.from(JSON.stringify(dstFull)));

  const srcChunkPath = join(rootB, "src-only-chunk");
  writeFileSync(srcChunkPath, "so");
  const ownHead = makeHead({ origin, gen, batches: [batch], transcriptFiles: { [cCommon]: 2, [cSrcOnly]: 2 }, to: 2, made: 2001 });
  const own: Own = {
    head: ownHead,
    batch: async () => Buffer.from("b"),
    sources: async (hashes) => new Map(hashes.filter((h) => h === cSrcOnly).map((h) => [h, srcChunkPath])),
  };

  // (i) known = null (level reads held() -> sees made=2000 != 2001 -> calls put('head') -> rejects with head conflict!)
  await assert.rejects(() => level(dstPlace, HOME, own, null), /head conflict:/);
  const afterNullKnown = (await dstPlace.held(HOME, origin)).gens[0]!.head!;
  assert.equal(afterNullKnown.made, 2000);
  assert.deepEqual(afterNullKnown.transcriptFiles, { [cCommon]: 2, [cDstOnly]: 2 });

  // (ii) pre-populated Known with made=2000 and unverifiedGens={gen}
  const known: Known = {
    gen,
    batches: new Set([batch]),
    files: new Set([cCommon, cDstOnly]),
    others: new Set(),
    hasUnverifiedHead: true,
    unverifiedGens: new Set([gen]),
    to: 2,
    made: 2000,
  };
  await assert.rejects(() => level(dstPlace, HOME, own, known), /head conflict:/);
  assert.equal(known.made, 2000, "known.made must NOT advance on same-to full conflict");
  assert.equal(known.hasUnverifiedHead, true, "known.hasUnverifiedHead must NOT clear on same-to full conflict");
  assert.ok(known.unverifiedGens?.has(gen), "known.unverifiedGens must NOT clear on same-to full conflict");
  const afterKnownConflict = (await dstPlace.held(HOME, origin)).gens[0]!.head!;
  assert.equal(afterKnownConflict.made, 2000);
  assert.deepEqual(afterKnownConflict.transcriptFiles, { [cCommon]: 2, [cDstOnly]: 2 });

  // (iii) Control case: destination full head holds superset { cCommon, cSrcOnly, cDstOnly } -> level() succeeds idempotently!
  const rootC = dataDir("d72a-r7-level-full-superset");
  const dstSuperset = new FolderPlace(rootC);
  await dstSuperset.put(HOME, origin, gen, "batch", batch, Buffer.from("b"));
  await dstSuperset.putFile(HOME, origin, cCommon, Buffer.from("cm"));
  await dstSuperset.putFile(HOME, origin, cSrcOnly, Buffer.from("so"));
  await dstSuperset.putFile(HOME, origin, cDstOnly, Buffer.from("do"));
  const dstSupersetHead = makeHead({
    origin,
    gen,
    batches: [batch],
    transcriptFiles: { [cCommon]: 2, [cSrcOnly]: 2, [cDstOnly]: 2 },
    to: 2,
    made: 2000,
  });
  await dstSuperset.put(HOME, origin, gen, "head", "head.json", Buffer.from(JSON.stringify(dstSupersetHead)));
  const okRes = await level(dstSuperset, HOME, own, null);
  assert.equal(okRes.behind, false, "superset same-to full head succeeds idempotently in level()");
  // Disk head stays untouched (never overwritten by subset incoming head)
  assert.deepEqual((await dstSuperset.held(HOME, origin)).gens[0]!.head!.transcriptFiles, { [cCommon]: 2, [cSrcOnly]: 2, [cDstOnly]: 2 });

  // (iv) R8: initial inventory (known = null) with IDENTICAL `to=2` AND `made=2000`:
  //      - conflicting destination full head MUST force put('head') and reject /head conflict:/ without returning synced Known;
  //      - covering superset destination full head MUST take fast path without calling put('head') (putHeadCalls === 0)!
  const ownSameMade: Own = {
    head: makeHead({ origin, gen, batches: [batch], transcriptFiles: { [cCommon]: 2, [cSrcOnly]: 2 }, to: 2, made: 2000 }),
    batch: async () => Buffer.from("b"),
    sources: async (hashes) => new Map(hashes.filter((h) => h === cSrcOnly).map((h) => [h, srcChunkPath])),
  };
  await assert.rejects(() => level(dstPlace, HOME, ownSameMade, null), /head conflict:/);
  const afterSameMadeConflict = (await dstPlace.held(HOME, origin)).gens[0]!.head!;
  assert.equal(afterSameMadeConflict.made, 2000);
  assert.deepEqual(afterSameMadeConflict.transcriptFiles, { [cCommon]: 2, [cDstOnly]: 2 });

  let supersetPutHeadCalls = 0;
  const origSupersetPut = dstSuperset.put.bind(dstSuperset);
  dstSuperset.put = async (ws, orig, g, kind, name, bytes) => {
    if (kind === "head") supersetPutHeadCalls++;
    return origSupersetPut(ws, orig, g, kind, name, bytes);
  };
  const fastRes = await level(dstSuperset, HOME, ownSameMade, null);
  assert.equal(fastRes.behind, false, "same-to same-made superset succeeds on fast path");
  assert.equal(supersetPutHeadCalls, 0, "same-to same-made superset skips put('head') on fast path");

  // 27c. R9: MiniS3Server + S3Place E2E verification of level() common-layer conflict rejection & superset preservation
  const mock = new MiniS3Server();
  await mock.start();
  closing.push(() => mock.stop());
  const readS3Bytes = async (p: S3Place, hash: string): Promise<Buffer> => {
    const chunks: Buffer[] = [];
    for await (const c of await p.read(HOME, origin, null, hash)) chunks.push(c);
    return Buffer.concat(chunks);
  };

  // 27c-i: S3 conflict rejection (both same made=2000 and different made=2001) preserves remote head & cDstOnly bytes
  const conflictTarget: NormalizedS3Target = {
    ...mock.target("33".repeat(32), true),
    id: "t-r9-conflict",
    prefix: "r9c",
  };
  const s3Conflict = new S3Place(conflictTarget);
  await s3Conflict.put(HOME, origin, gen, "batch", batch, Buffer.from("b"));
  await s3Conflict.putFile(HOME, origin, cCommon, Buffer.from("cm"));
  await s3Conflict.putFile(HOME, origin, cDstOnly, Buffer.from("do"));
  await s3Conflict.put(HOME, origin, gen, "head", "head.json", Buffer.from(JSON.stringify(dstFull)), dstFull);

  await assert.rejects(() => level(s3Conflict, HOME, ownSameMade, null), /head conflict:/, "S3 same-to same-made conflict rejected");
  await assert.rejects(() => level(s3Conflict, HOME, own, null), /head conflict:/, "S3 same-to diff-made conflict rejected");
  const s3ConflictFresh = new S3Place(conflictTarget);
  const s3ConflictHeld = await s3ConflictFresh.held(HOME, origin);
  assert.equal(s3ConflictHeld.gens[0]!.head!.made, 2000, "S3 remote head.made preserved after conflicts");
  assert.deepEqual(
    s3ConflictHeld.gens[0]!.head!.transcriptFiles,
    { [cCommon]: 2, [cDstOnly]: 2 },
    "S3 remote head.transcriptFiles preserved after conflicts",
  );
  assert.deepEqual(
    await readS3Bytes(s3ConflictFresh, cDstOnly),
    Buffer.from("do"),
    "S3 cDstOnly object bytes still readable after conflicts",
  );

  // 27c-ii: S3 superset preservation does NOT overwrite remote head or delete cDstOnly via drop() or pruneOrphans(),
  //         both on initial inventory (known=null) and subsequent call with returned Known!
  const supersetTarget: NormalizedS3Target = {
    ...mock.target("44".repeat(32), true),
    id: "t-r9-superset",
    prefix: "r9s",
  };
  const s3Superset = new S3Place(supersetTarget);
  await s3Superset.put(HOME, origin, gen, "batch", batch, Buffer.from("b"));
  await s3Superset.putFile(HOME, origin, cCommon, Buffer.from("cm"));
  await s3Superset.putFile(HOME, origin, cSrcOnly, Buffer.from("so"));
  await s3Superset.putFile(HOME, origin, cDstOnly, Buffer.from("do"));
  await s3Superset.put(HOME, origin, gen, "head", "head.json", Buffer.from(JSON.stringify(dstSupersetHead)), dstSupersetHead);

  const r1 = await level(s3Superset, HOME, own, null, { includeTranscripts: true });
  assert.equal(r1.behind, false, "S3 superset first level() succeeds");
  const s3SupersetFresh1 = new S3Place(supersetTarget);
  const s3SupersetHeld1 = await s3SupersetFresh1.held(HOME, origin);
  assert.deepEqual(
    s3SupersetHeld1.gens[0]!.head!.transcriptFiles,
    { [cCommon]: 2, [cSrcOnly]: 2, [cDstOnly]: 2 },
    "S3 remote superset head preserved after first level()",
  );
  assert.deepEqual(
    await readS3Bytes(s3SupersetFresh1, cDstOnly),
    Buffer.from("do"),
    "S3 cDstOnly object still readable after first level() (not dropped or pruned)",
  );

  const r2 = await level(s3Superset, HOME, own, r1.known, { includeTranscripts: true });
  assert.equal(r2.behind, false, "S3 superset second level() with returned Known succeeds");
  const s3SupersetFresh2 = new S3Place(supersetTarget);
  assert.deepEqual(
    (await s3SupersetFresh2.held(HOME, origin)).gens[0]!.head!.transcriptFiles,
    { [cCommon]: 2, [cSrcOnly]: 2, [cDstOnly]: 2 },
    "S3 remote superset head still preserved after second level()",
  );
  assert.deepEqual(
    await readS3Bytes(s3SupersetFresh2, cDstOnly),
    Buffer.from("do"),
    "S3 cDstOnly object still readable after second level() with Known",
  );

  // 27c-iii: R10: pure policy toggle includeTranscripts: true -> false with UNCHANGED head (to/made) and known=null
  //          MUST drop current-gen exclusive transcript chunk while keeping chat attachment and older-gen transcript!
  const toggleTarget: NormalizedS3Target = {
    ...mock.target("55".repeat(32), true),
    id: "t-r10-toggle",
    prefix: "r10t",
  };
  const s3Toggle1 = new S3Place(toggleTarget);
  const genOld = "090-aaaaaaaa";
  const fChat = hex64("aa", "a");
  const cOldGenTr = hex64("bb", "b");
  const cCurOnlyTr = hex64("cc", "c");
  await s3Toggle1.put(HOME, origin, genOld, "batch", batch, Buffer.from("b"));
  await s3Toggle1.putFile(HOME, origin, cOldGenTr, Buffer.from("old"));
  const oldGenHead = makeHead({ origin, gen: genOld, batches: [batch], transcriptFiles: { [cOldGenTr]: 3 }, to: 1, made: 1000 });
  await s3Toggle1.put(HOME, origin, genOld, "head", "head.json", Buffer.from(JSON.stringify(oldGenHead)), oldGenHead);

  const toggleDir = dataDir("d72a-r10-toggle-src");
  const fChatPath = join(toggleDir, "chat-att");
  const cCurTrPath = join(toggleDir, "cur-tr");
  writeFileSync(fChatPath, "chat");
  writeFileSync(cCurTrPath, "cur");
  const toggleCurHead = makeHead({
    origin,
    gen,
    batches: [batch],
    files: { [fChat]: 4 },
    transcriptFiles: { [cCurOnlyTr]: 3 },
    to: 2,
    made: 2000,
  });
  const ownToggle: Own = {
    head: toggleCurHead,
    batch: async () => Buffer.from("b"),
    sources: async (hashes) => {
      const m = new Map<string, string>();
      for (const h of hashes) {
        if (h === fChat) m.set(h, fChatPath);
        else if (h === cCurOnlyTr) m.set(h, cCurTrPath);
      }
      return m;
    },
  };

  // Step 1: sync with includeTranscripts: true -> fChat, cOldGenTr, cCurOnlyTr all readable on S3
  const tRes1 = await level(s3Toggle1, HOME, ownToggle, null, { includeTranscripts: true });
  assert.equal(tRes1.behind, false);
  const s3ToggleVerify1 = new S3Place(toggleTarget);
  assert.deepEqual(await readS3Bytes(s3ToggleVerify1, fChat), Buffer.from("chat"));
  assert.deepEqual(await readS3Bytes(s3ToggleVerify1, cOldGenTr), Buffer.from("old"));
  assert.deepEqual(await readS3Bytes(s3ToggleVerify1, cCurOnlyTr), Buffer.from("cur"));

  // Step 2: keep head (to/made) identical, fresh S3Place + known=null (simulating configChanged()), toggle includeTranscripts: false
  const s3Toggle2 = new S3Place(toggleTarget);
  const tRes2 = await level(s3Toggle2, HOME, ownToggle, null, { includeTranscripts: false });
  assert.equal(tRes2.behind, false);

  const wtToggle = s3Toggle2.wsTag(HOME);
  const otToggle = s3Toggle2.originTag(origin);
  assert.equal(
    mock.objects.has(`r10t/${wtToggle}/${otToggle}/files/${s3Toggle2.fileTag(cCurOnlyTr)}.enc`),
    false,
    "current-gen exclusive transcript chunk deleted from S3 after includeTranscripts: true -> false",
  );
  const s3ToggleVerify2 = new S3Place(toggleTarget);
  await assert.rejects(() => readS3Bytes(s3ToggleVerify2, cCurOnlyTr), "reading deleted current-gen transcript rejects");
  assert.deepEqual(
    await readS3Bytes(s3ToggleVerify2, fChat),
    Buffer.from("chat"),
    "chat attachment preserved on S3 after includeTranscripts: false",
  );
  assert.deepEqual(
    await readS3Bytes(s3ToggleVerify2, cOldGenTr),
    Buffer.from("old"),
    "older-gen exclusive transcript preserved on S3 after includeTranscripts: false",
  );

  // 27c-iv: R11: pre-existing S3 transcriptManifest head (containing cCurOnlyTr + target-extra cDstOnly) with
  //         includeTranscripts: false + known=null MUST drop cCurOnlyTr while keeping manifest root/leaves,
  //         chat attachment fChat, older-gen cOldGenTr, AND target-extra cDstOnly; generic drop() without opts
  //         MUST still protect cDstOnly!
  const manifestToggleTarget: NormalizedS3Target = {
    ...mock.target("66".repeat(32), true),
    id: "t-r11-manifest-toggle",
    prefix: "r11m",
  };
  const s3ManSeed = new S3Place(manifestToggleTarget);
  await s3ManSeed.put(HOME, origin, genOld, "batch", batch, Buffer.from("b"));
  await s3ManSeed.putFile(HOME, origin, cOldGenTr, Buffer.from("old"));
  await s3ManSeed.put(HOME, origin, genOld, "head", "head.json", Buffer.from(JSON.stringify(oldGenHead)), oldGenHead);

  const encToggle = encodeTranscriptManifest({ [cCurOnlyTr]: 3, [cDstOnly]: 2 });
  await s3ManSeed.put(HOME, origin, gen, "batch", batch, Buffer.from("b"));
  await s3ManSeed.putFile(HOME, origin, fChat, Buffer.from("chat"));
  await s3ManSeed.putFile(HOME, origin, cCurOnlyTr, Buffer.from("cur"));
  await s3ManSeed.putFile(HOME, origin, cDstOnly, Buffer.from("do"));
  await s3ManSeed.putFile(HOME, origin, encToggle.rootHash, encToggle.rootBytes);
  for (const [lh, { bytes }] of encToggle.leaves) {
    await s3ManSeed.putFile(HOME, origin, lh, bytes);
  }
  const manifestToggleHead = makeHead({
    origin,
    gen,
    batches: [batch],
    files: { [fChat]: 4 },
    transcriptManifest: encToggle.rootHash,
    to: 2,
    made: 2000,
  });
  await s3ManSeed.put(HOME, origin, gen, "head", "head.json", Buffer.from(JSON.stringify(manifestToggleHead)), manifestToggleHead);

  const s3ManLevel = new S3Place(manifestToggleTarget);
  const mRes = await level(s3ManLevel, HOME, ownToggle, null, { includeTranscripts: false });
  assert.equal(mRes.behind, false);

  const wtMan = s3ManLevel.wsTag(HOME);
  const otMan = s3ManLevel.originTag(origin);
  assert.equal(
    mock.objects.has(`r11m/${wtMan}/${otMan}/files/${s3ManLevel.fileTag(cCurOnlyTr)}.enc`),
    false,
    "current-gen exclusive transcript chunk deleted from S3 manifest head when includeTranscripts: false",
  );
  const s3ManVerify = new S3Place(manifestToggleTarget);
  await assert.rejects(() => readS3Bytes(s3ManVerify, cCurOnlyTr), "reading deleted current-gen manifest transcript rejects");
  assert.deepEqual(
    await readS3Bytes(s3ManVerify, encToggle.rootHash),
    encToggle.rootBytes,
    "manifest root preserved on S3 after includeTranscripts: false",
  );
  for (const [lh, { bytes }] of encToggle.leaves) {
    assert.deepEqual(
      await readS3Bytes(s3ManVerify, lh),
      bytes,
      `manifest leaf ${lh.slice(0, 8)} preserved on S3 after includeTranscripts: false`,
    );
  }
  assert.deepEqual(await readS3Bytes(s3ManVerify, fChat), Buffer.from("chat"), "chat attachment preserved on S3 manifest head");
  assert.deepEqual(await readS3Bytes(s3ManVerify, cOldGenTr), Buffer.from("old"), "older-gen transcript preserved on S3 manifest head");
  assert.deepEqual(await readS3Bytes(s3ManVerify, cDstOnly), Buffer.from("do"), "target-extra cDstOnly preserved on S3 manifest head");

  // Generic drop() without opts MUST still protect cDstOnly referenced by live manifest head!
  await s3ManVerify.held(HOME, origin);
  await s3ManVerify.drop(HOME, origin, gen, [], [cDstOnly]);
  assert.deepEqual(
    await readS3Bytes(new S3Place(manifestToggleTarget), cDstOnly),
    Buffer.from("do"),
    "generic S3Place.drop() without allowCurrentGenTranscripts still protects live manifest chunk cDstOnly",
  );
});
