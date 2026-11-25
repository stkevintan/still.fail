// Tests for Phase 2 session transcript 4 MiB chunked CAS incremental backup, GC, `carriedTo` path remapping on
// restore, `includeTranscripts: false` S3 policy, and workspace exclusion (both TS reference and MoonBit reader).
import assert from "node:assert/strict";
import { createHash, createHmac } from "node:crypto";
import { EventEmitter } from "node:events";
import { chmodSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { join, sep } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { afterEach, test } from "node:test";
import { Effect, Exit, Scope, type Clock } from "effect";
import { TestClock } from "effect/testing";
import { PeerBus, bytesOf, withBytes } from "../src/mesh/bus.ts";
import { Fibers } from "../src/ops/fibers.ts";
import { MbProcess, mbReaderBinary } from "../src/read/mb-reader.ts";
import { claudeProject, resetTranscriptLocateCache } from "../src/read/transcript.ts";
import type { NormalizedBackupConfig, NormalizedS3Target } from "../src/replica/backup-config.ts";
import { Copies } from "../src/replica/copies.ts";
import { loadLocalTranscriptFiles } from "../src/replica/manifest.ts";
import { PeerPlace, serve } from "../src/replica/peers.ts";
import { FolderPlace, level } from "../src/replica/places.ts";
import { moved, takeBackSoon } from "../src/replica/restore.ts";
import { ProgramRunner, exportThread } from "../src/replica/runner.ts";
import { S3Place, extractAllXmlTags } from "../src/replica/s3.ts";
import { Store } from "../src/store/store.ts";
import { HOME, OTHER, dataDir } from "./replica-fakes.ts";
import { CHUNK_GC_GRACE_MS, Exporter, nothingTold } from "./reference/replica-export.ts";
import { decodeBatch } from "./reference/replica-format.ts";
import { takeBack } from "./reference/replica-restore.ts";
import { InlineRunner } from "./reference/replica-work.ts";

const binary = mbReaderBinary();
const skipMb = binary === null ? "the MoonBit program is not built here (station/mb/build.sh)" : false;

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

class MockS3Server {
  readonly objects = new Map<string, Buffer>();
  readonly puts: string[] = [];
  readonly deletes: string[] = [];
  readonly bucket = "transcript-bucket";
  readonly region = "auto";
  readonly accessKeyId = "AKIA_TR_TEST";
  readonly secretAccessKey = "SECRET_TR_TEST";
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
      id: "r2tr",
      name: "R2 Transcripts",
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

  async #handle(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const url = new URL(req.url ?? "/", this.endpoint);
    const body = await this.#readBody(req);
    const segments = url.pathname.replace(/^\/+/, "").split("/").map(decodeURIComponent);
    const bucket = segments[0] ?? "";
    const key = segments.slice(1).join("/");
    if (bucket !== this.bucket) {
      res.writeHead(404).end("<Error><Code>NoSuchBucket</Code></Error>");
      return;
    }
    if (req.method === "GET" && url.searchParams.get("list-type") === "2") {
      const prefix = url.searchParams.get("prefix") ?? "";
      const matching = [...this.objects.keys()].filter((k) => k.startsWith(prefix)).sort();
      const xml =
        `<?xml version="1.0" encoding="UTF-8"?><ListBucketResult><IsTruncated>false</IsTruncated>` +
        matching.map((k) => `<Contents><Key>${escapeXml(k)}</Key><Size>${this.objects.get(k)!.length}</Size></Contents>`).join("") +
        `</ListBucketResult>`;
      res.writeHead(200, { "content-type": "application/xml" }).end(xml);
      return;
    }
    if (req.method === "PUT") {
      this.objects.set(key, body);
      this.puts.push(key);
      const etag = `"${createHash("md5").update(body).digest("hex")}"`;
      res.writeHead(200, { etag }).end();
      return;
    }
    if (req.method === "GET") {
      const obj = this.objects.get(key);
      if (obj === undefined) {
        res.writeHead(404).end("<Error><Code>NoSuchKey</Code></Error>");
        return;
      }
      res.writeHead(200, { "content-type": "application/octet-stream" }).end(obj);
      return;
    }
    if (req.method === "POST" && url.searchParams.has("delete")) {
      const expectedMd5 = createHash("md5").update(body).digest("base64");
      if (req.headers["content-md5"] !== expectedMd5) {
        res.writeHead(400, { "content-type": "application/xml" }).end("<Error><Code>InvalidDigest</Code></Error>");
        return;
      }
      const keys = extractAllXmlTags(body.toString("utf8"), "Key");
      for (const k of keys) {
        this.objects.delete(k);
        this.deletes.push(k);
      }
      const xml =
        `<?xml version="1.0" encoding="UTF-8"?><DeleteResult>` +
        keys.map((k) => `<Deleted><Key>${escapeXml(k)}</Key></Deleted>`).join("") +
        `</DeleteResult>`;
      res.writeHead(200, { "content-type": "application/xml" }).end(xml);
      return;
    }
    if (req.method === "DELETE") {
      this.objects.delete(key);
      this.deletes.push(key);
      res.writeHead(204).end();
      return;
    }
    res.writeHead(405).end();
  }
}

function makeTranscriptStation() {
  const data = dataDir("tr-src");
  const db = join(data, "stillfail.db");
  const store = Store.open(db, join(data, "archive"));

  // 1. Claude session with transcript + subagent transcript + workspace code (must NOT be backed up)
  const claudeRoom = join(data, "sessions", "chat", "chat:claude", "workspace");
  mkdirSync(join(claudeRoom, "src"), { recursive: true });
  const workspaceSecret = join(claudeRoom, "src", "secret.ts");
  writeFileSync(workspaceSecret, "export const DO_NOT_BACKUP = true;\n");
  const claudeId = "claude-sess-001";
  store.insertSession({
    key: "chat:claude",
    connect: "chat",
    runtime: "claude",
    profile: "cc",
    workspace: claudeRoom,
    token: "tok-claude",
    createdAt: 1,
    lastActiveAt: 1,
    ws: null,
  });
  store.setRuntimeSessionId("chat:claude", claudeId);
  const tClaude = store.openThread("chat", "C", "ts-claude", "Claude Chat", "p@x").id;
  store.joinThread(tClaude, "chat:claude", "chat");
  // Chat attachment (MUST be backed up even when includeTranscripts: false)
  const attDir = join(claudeRoom, "uploads");
  mkdirSync(attDir, { recursive: true });
  const attPath = join(attDir, "note.txt");
  writeFileSync(attPath, "attached note content");
  store.insertMessage({
    thread: tClaude,
    ts: "c.1",
    authorKind: "person",
    author: "p@x",
    text: "hello claude",
    attachments: [{ name: "note.txt", path: attPath, size: 21 }],
  });

  const claudeProj = claudeProject(claudeRoom)!;
  const claudeTrDir = join(data, "transcripts", "claude", claudeProj);
  mkdirSync(join(claudeTrDir, claudeId), { recursive: true });
  const claudeTrPath = join(claudeTrDir, `${claudeId}.jsonl`);
  // Make ~10 KiB (> 2 chunks of 4 KiB) with deterministic content
  const lineA = JSON.stringify({ role: "user", text: "A".repeat(2000) }) + "\n";
  const lineB = JSON.stringify({ role: "assistant", text: "B".repeat(2000) }) + "\n";
  const lineC = JSON.stringify({ role: "user", text: "C".repeat(2000) }) + "\n";
  const lineD = JSON.stringify({ role: "assistant", text: "D".repeat(2000) }) + "\n";
  const lineE = JSON.stringify({ role: "user", text: "E".repeat(2000) }) + "\n";
  const claudeInitial = lineA + lineB + lineC + lineD + lineE;
  writeFileSync(claudeTrPath, claudeInitial);
  utimesSync(claudeTrPath, new Date(1_700_000_000_000), new Date(1_700_000_000_000));
  const claudeSubPath = join(claudeTrDir, claudeId, "sub-1.jsonl");
  writeFileSync(claudeSubPath, '{"sub":true}\n');

  // 2. Codex session with rollout transcript
  const codexRoom = join(data, "sessions", "chat", "chat:codex", "workspace");
  mkdirSync(codexRoom, { recursive: true });
  const codexId = "codex-sess-002";
  store.insertSession({
    key: "chat:codex",
    connect: "chat",
    runtime: "codex",
    profile: "cx",
    workspace: codexRoom,
    token: "tok-codex",
    createdAt: 2,
    lastActiveAt: 2,
    ws: null,
  });
  store.setRuntimeSessionId("chat:codex", codexId);
  const tCodex = store.openThread("chat", "C", "ts-codex", "Codex Chat", "p@x").id;
  store.joinThread(tCodex, "chat:codex", "chat");
  store.insertMessage({ thread: tCodex, ts: "x.1", authorKind: "person", author: "p@x", text: "hello codex" });
  const codexTrDir = join(data, "transcripts", "codex", "2026", "11", "22");
  mkdirSync(codexTrDir, { recursive: true });
  const codexTrPath = join(codexTrDir, `rollout-2026-11-22-${codexId}.jsonl`);
  const codexContent = '{"type":"event","payload":"codex-rollout-body"}\n';
  writeFileSync(codexTrPath, codexContent);

  // 3. AGY session with conversations/*.db, annotations/*.pbtxt, brain/<id>/**
  const agyRoom = join(data, "sessions", "chat", "chat:agy", "workspace");
  mkdirSync(agyRoom, { recursive: true });
  const agyId = "agy-sess-003";
  store.insertSession({
    key: "chat:agy",
    connect: "chat",
    runtime: "agy",
    profile: "agyprof",
    workspace: agyRoom,
    token: "tok-agy",
    createdAt: 3,
    lastActiveAt: 3,
    ws: null,
  });
  store.setRuntimeSessionId("chat:agy", agyId);
  const tAgy = store.openThread("chat", "C", "ts-agy", "AGY Chat", "p@x").id;
  store.joinThread(tAgy, "chat:agy", "chat");
  store.insertMessage({ thread: tAgy, ts: "g.1", authorKind: "person", author: "p@x", text: "hello agy" });
  const agyCli = join(data, "homes", "agyprof", "agy", ".gemini", "antigravity-cli");
  mkdirSync(join(agyCli, "conversations"), { recursive: true });
  mkdirSync(join(agyCli, "annotations"), { recursive: true });
  mkdirSync(join(agyCli, "brain", agyId, "notes"), { recursive: true });
  const agyDbPath = join(agyCli, "conversations", `${agyId}.db`);
  const agyAnnPath = join(agyCli, "annotations", `${agyId}.pbtxt`);
  const agyBrainPath = join(agyCli, "brain", agyId, "notes", "plan.md");
  const agyDbBytes = Buffer.from([0x53, 0x51, 0x4c, 0x69, 0x74, 0x65, 0x00, 0xde, 0xad, 0xbe, 0xef]);
  writeFileSync(agyDbPath, agyDbBytes);
  writeFileSync(agyAnnPath, 'status: "active"\n');
  writeFileSync(agyBrainPath, "# Plan\n- Step 1\n");
  // Also place a fake token file under homes/agyprof/ (outside antigravity-cli whitelist): must NOT be backed up!
  const agyTokenPath = join(data, "homes", "agyprof", "auth-token.json");
  writeFileSync(agyTokenPath, '{"token":"super-secret"}');

  return {
    data,
    db,
    store,
    claudeRoom,
    claudeId,
    claudeTrPath,
    claudeSubPath,
    claudeInitial,
    workspaceSecret,
    codexTrPath,
    codexContent,
    agyDbPath,
    agyDbBytes,
    agyAnnPath,
    agyBrainPath,
    agyTokenPath,
  };
}

test("TS reference: transcript discovery whitelist, 4 KiB chunk dedup, and orphan chunk GC", async () => {
  const s = makeTranscriptStation();
  closing.push(async () => s.store.close());
  const replica = join(s.data, "replica");
  let now = 1_700_000_000_000;
  const exporter = new Exporter({
    db: s.db,
    replica,
    dataDir: s.data,
    origin: sid("a"),
    now: () => now,
    chunkBytes: 4096,
  });
  closing.push(async () => exporter.close());
  exporter.setPlaces({ home: HOME, workspaces: [{ workspace: HOME, name: "src" }] });

  // Initial pass discovers Claude + Codex + AGY transcripts, excludes workspace & token files
  const p1 = exporter.pass(nothingTold());
  assert.equal(p1.wrote, 1);
  const head1 = p1.heads[HOME]!;
  assert.ok(head1.transcriptFiles !== undefined, "default Exporter returns inline transcriptFiles for MoonBit compatibility");
  assert.equal(head1.transcriptManifest, undefined);
  const head1Tf = await loadLocalTranscriptFiles(replica, head1);
  assert.ok(Object.keys(head1Tf).length > 0);

  // Decode batch and inspect `tr` records
  const genDir = join(replica, "own", HOME, head1.gen);
  const trRecs = head1.batches.flatMap((b) =>
    [...decodeBatch(readFileSync(join(genDir, "log", b))).lines].map((l) => JSON.parse(l)).filter((r) => "tr" in r),
  );
  const trPaths = trRecs.map((r) => r.tr as string);
  assert.ok(trPaths.includes(s.claudeTrPath), "Claude .jsonl discovered");
  assert.ok(trPaths.includes(s.claudeSubPath), "Claude subagent .jsonl discovered");
  assert.ok(trPaths.includes(s.codexTrPath), "Codex rollout discovered");
  assert.ok(trPaths.includes(s.agyDbPath), "AGY conversations/*.db discovered");
  assert.ok(trPaths.includes(s.agyAnnPath), "AGY annotations/*.pbtxt discovered");
  assert.ok(trPaths.includes(s.agyBrainPath), "AGY brain/* discovered");
  assert.ok(!trPaths.includes(s.workspaceSecret), "sessions/*/workspace NEVER backed up");
  assert.ok(!trPaths.includes(s.agyTokenPath), "profile auth token NEVER backed up");

  // 4 KiB chunking: ~10 KiB file -> 3 chunks (4096 + 4096 + remainder)
  const claudeRec1 = trRecs.find((r) => r.tr === s.claudeTrPath)!;
  assert.equal(claudeRec1.chunks.length, 3, "10 KiB file split into 3 chunks of 4 KiB");
  const prefix0 = claudeRec1.chunks[0] as string;
  const prefix1 = claudeRec1.chunks[1] as string;
  const oldTail = claudeRec1.chunks[2] as string;
  assert.ok(existsSync(join(replica, "chunks", oldTail)));

  // Append a new line to Claude transcript -> prefix chunks [0] and [1] 100% reused, oldTail GC'd!
  now += 60_000;
  writeFileSync(s.claudeTrPath, s.claudeInitial + JSON.stringify({ role: "assistant", text: "appended-line" }) + "\n");
  utimesSync(s.claudeTrPath, new Date(1_700_000_060_000), new Date(1_700_000_060_000));
  const p2 = exporter.pass({ ...nothingTold(), transcripts: true });
  assert.equal(p2.wrote, 1);
  const head2 = p2.heads[HOME]!;
  const newBatch = head2.batches[head2.batches.length - 1]!;
  const trRecs2 = [...decodeBatch(readFileSync(join(genDir, "log", newBatch))).lines]
    .map((l) => JSON.parse(l))
    .filter((r) => "tr" in r);
  assert.equal(trRecs2.length, 1, "only changed transcript re-emitted");
  assert.equal(trRecs2[0].tr, s.claudeTrPath);
  assert.equal(trRecs2[0].chunks.length, 3);
  assert.equal(trRecs2[0].chunks[0], prefix0, "chunk 0 hash 100% reused");
  assert.equal(trRecs2[0].chunks[1], prefix1, "chunk 1 hash 100% reused");
  assert.notEqual(trRecs2[0].chunks[2], oldTail, "tail chunk updated");
  const head2Tf = await loadLocalTranscriptFiles(replica, head2);
  assert.equal(head2Tf[oldTail], undefined, "orphan tail chunk removed from head transcripts");
  assert.ok(existsSync(join(replica, "chunks", oldTail)), "orphan tail chunk retained on disk during grace period");
  now += CHUNK_GC_GRACE_MS;
  exporter.pass({ ...nothingTold(), transcripts: true });
  assert.ok(!existsSync(join(replica, "chunks", oldTail)), "orphan tail chunk GC'd from disk after grace period");

  // Delete codex session -> its transcript chunk is retained during grace period, then GC'd
  const codexRec = trRecs.find((r) => r.tr === s.codexTrPath)!;
  const codexChunk = codexRec.chunks[0] as string;
  assert.ok(existsSync(join(replica, "chunks", codexChunk)));
  s.store.deleteSession("chat:codex");
  now += 60_000;
  const p3 = exporter.pass({ ...nothingTold(), removedSessions: [{ key: "chat:codex", ws: null }], transcripts: true });
  assert.equal(p3.wrote, 1);
  const head3 = p3.heads[HOME]!;
  const head3Tf = await loadLocalTranscriptFiles(replica, head3);
  assert.equal(head3Tf[codexChunk], undefined);
  assert.ok(existsSync(join(replica, "chunks", codexChunk)), "deleted session transcript chunk retained during grace period");
  now += CHUNK_GC_GRACE_MS;
  exporter.pass({ ...nothingTold(), transcripts: true });
  assert.ok(!existsSync(join(replica, "chunks", codexChunk)), "deleted session transcript chunk GC'd after grace period");
});

test("E2E (MoonBit reader + Mock S3 + PeerPlace): chunk dedup, includeTranscripts: false, and carriedTo restore", { skip: skipMb }, async () => {
  const s = makeTranscriptStation();
  closing.push(async () => s.store.close());
  const s3WithTr = new MockS3Server();
  const s3NoTr = new MockS3Server();
  await s3WithTr.start();
  await s3NoTr.start();

  const targetWithTr = s3WithTr.target({ id: "r2full", includeTranscripts: true });
  const targetNoTr = s3NoTr.target({ id: "r2chat", includeTranscripts: false });

  const originId = sid("a");
  const peerId = sid("b");
  const clock = testClock();
  const fibersA = new Fibers("copies-a", clock);
  const fibersB = new Fibers("copies-b", clock);
  closing.push(async () => {
    await fibersA.close();
    await fibersB.close();
  });

  // Real MoonBit `stillfail-reader --builder replica-export --chunk-bytes 4096`
  const runnerA = new ProgramRunner({ db: s.db, replica: join(s.data, "replica"), dataDir: s.data, origin: originId, chunkBytes: 4096 });
  closing.push(async () => runnerA.close());

  const dataB = dataDir("tr-peer");
  const storeB = Store.open(join(dataB, "stillfail.db"), join(dataB, "archive"));
  closing.push(async () => storeB.close());
  const runnerB = new InlineRunner({ db: join(dataB, "stillfail.db"), replica: join(dataB, "replica"), dataDir: dataB, origin: peerId, now: () => 1_700_000_000_000 });
  closing.push(async () => runnerB.close());

  const bus = new Map<string, ReturnType<Copies["answers"]>>();
  const ask = async (to: string, req: any): Promise<any> => {
    const h = bus.get(to);
    if (h === undefined) throw new Error("offline");
    return h(to === peerId ? originId : peerId, req, HOME);
  };

  const backupCfg: NormalizedBackupConfig = {
    mode: "manual",
    stations: [peerId],
    acceptOthers: true,
    s3: [targetWithTr, targetNoTr],
  };

  const copiesA = new Copies({
    data: s.data,
    here: () => originId,
    places: () => ({ home: HOME, workspaces: [{ workspace: HOME, name: "station-a" }] }),
    roster: () => [
      { id: originId, name: "station-a" },
      { id: peerId, name: "station-b" },
    ],
    ask,
    runner: runnerA,
    fibers: fibersA,
    changed: () => {},
    restart: async () => null,
    backup: () => backupCfg,
    s3ClientOptions: { now: () => 1_700_000_000_000 },
  });
  const copiesB = new Copies({
    data: dataB,
    here: () => peerId,
    places: () => ({ home: HOME, workspaces: [{ workspace: HOME, name: "station-b" }] }),
    roster: () => [
      { id: originId, name: "station-a" },
      { id: peerId, name: "station-b" },
      { id: sid("d"), name: "station-d" },
    ],
    ask,
    runner: runnerB,
    fibers: fibersB,
    changed: () => {},
    restart: async () => null,
  });
  closing.push(async () => {
    await copiesA.close();
    await copiesB.close();
  });
  bus.set(originId, copiesA.answers());
  bus.set(peerId, copiesB.answers());

  await copiesA.start();
  await copiesA.settle();

  // Verify S3 with includeTranscripts: true received all transcript chunks, while includeTranscripts: false received ZERO!
  const s3PlaceFull = new S3Place(targetWithTr, { now: () => 1_700_000_000_000 });
  const s3PlaceChat = new S3Place(targetNoTr, { now: () => 1_700_000_000_000 });
  const heldFull = await s3PlaceFull.held(HOME, originId);
  const heldChat = await s3PlaceChat.held(HOME, originId);
  assert.equal(heldFull.gens.length, 1);
  const head = heldFull.gens[0]!.head!;
  const tfHashes = Object.keys(head.transcriptFiles ?? {});
  const attHashes = Object.keys(head.files);
  assert.ok(tfHashes.length >= 5, `expected transcript chunks in head.transcriptFiles, got ${tfHashes.length}`);
  assert.equal(attHashes.length, 1, "chat attachment present");

  for (const h of attHashes) {
    assert.ok(heldFull.files.includes(h), "r2full has attachment");
    assert.ok(heldChat.files.includes(h), "r2chat has attachment");
  }
  for (const h of tfHashes) {
    assert.ok(heldFull.files.includes(h), `r2full has transcript chunk ${h}`);
    assert.ok(!heldChat.files.includes(h), `r2chat (includeTranscripts: false) MUST NOT have transcript chunk ${h}`);
    const tag = s3PlaceChat.fileTag(h);
    assert.ok(![...s3NoTr.objects.keys()].some((k) => k.includes(tag)), "no encrypted transcript chunk object in r2chat bucket");
  }

  // Verify PeerPlace also received all transcript chunks
  const heldPeer = await copiesB.kept.held(HOME, originId);
  for (const h of tfHashes) {
    assert.ok(heldPeer.files.includes(h), `PeerPlace has transcript chunk ${h}`);
  }

  // Append to Claude transcript on A, verify only 1 new tail chunk is uploaded to r2full (prefix chunks reused!)
  const putsBefore = s3WithTr.puts.length;
  const claudeAppended = s.claudeInitial + JSON.stringify({ role: "assistant", text: "second-turn-tail" }) + "\n";
  writeFileSync(s.claudeTrPath, claudeAppended);
  utimesSync(s.claudeTrPath, new Date(1_700_000_120_000), new Date(1_700_000_120_000));
  copiesA.told({ type: "session", key: "chat:claude" });
  await copiesA.settle();
  const newFilePuts = s3WithTr.puts.slice(putsBefore).filter((k) => k.includes("/files/"));
  assert.equal(newFilePuts.length, 1, `expected exactly 1 new tail chunk uploaded, got ${newFilePuts.length}`);

  // ── Restore from S3 (r2full) into a brand-new empty station at a DIFFERENT dataDir via real MoonBit takeBackSoon ──
  const dataRestoredS3 = dataDir("tr-restore-s3");
  const dbRestoredS3 = join(dataRestoredS3, "stillfail.db");
  const storeRestoredS3 = Store.open(dbRestoredS3, join(dataRestoredS3, "archive"));
  storeRestoredS3.close();
  const fibersC = new Fibers("copies-c", clock);
  closing.push(async () => fibersC.close());
  const runnerC = new InlineRunner({ db: dbRestoredS3, replica: join(dataRestoredS3, "replica"), dataDir: dataRestoredS3, origin: sid("c"), now: () => 1_700_000_200_000 });
  closing.push(async () => runnerC.close());
  const copiesC = new Copies({
    data: dataRestoredS3,
    here: () => sid("c"),
    places: () => ({ home: HOME, workspaces: [{ workspace: HOME, name: "station-c" }] }),
    roster: () => [{ id: sid("c"), name: "station-c" }],
    ask: async () => { throw new Error("offline"); },
    runner: runnerC,
    fibers: fibersC,
    changed: () => {},
    restart: async () => null,
    backup: () => ({ mode: "manual", stations: [], acceptOthers: true, s3: [targetWithTr, targetNoTr] }),
    s3ClientOptions: { now: () => 1_700_000_200_000 },
  });
  closing.push(async () => copiesC.close());
  await copiesC.start();
  await copiesC.settle();
  await copiesC.restore(HOME, originId, head.gen, { s3: "r2full" });

  // Run real MoonBit `--builder replica-restore`
  const readyS3 = await takeBackSoon(dataRestoredS3, dbRestoredS3, 1_700_000_200_000, binary!);
  assert.ok(readyS3 !== null);

  // Verify Claude transcript was remapped via `carriedTo` to the new dataDir's claudeProject!
  const expectedClaudeRoom = moved(s.claudeRoom, s.data, dataRestoredS3);
  const expectedClaudeProj = claudeProject(expectedClaudeRoom)!;
  assert.notEqual(expectedClaudeProj, claudeProject(s.claudeRoom), "new dataDir has a different claudeProject name");
  const restoredClaudeTr = join(dataRestoredS3, "transcripts", "claude", expectedClaudeProj, `${s.claudeId}.jsonl`);
  assert.ok(existsSync(restoredClaudeTr), `Claude transcript restored at remapped project path: ${restoredClaudeTr}`);
  assert.deepEqual(readFileSync(restoredClaudeTr), Buffer.from(claudeAppended), "Claude transcript byte-for-byte identical");
  assert.equal(statSync(restoredClaudeTr).mode & 0o777, 0o644);

  const restoredClaudeSub = join(dataRestoredS3, "transcripts", "claude", expectedClaudeProj, s.claudeId, "sub-1.jsonl");
  assert.ok(existsSync(restoredClaudeSub), "Claude subagent transcript restored at remapped project path");
  assert.equal(readFileSync(restoredClaudeSub, "utf8"), '{"sub":true}\n');

  const restoredCodexTr = moved(s.codexTrPath, s.data, dataRestoredS3);
  assert.ok(existsSync(restoredCodexTr), "Codex transcript restored");
  assert.equal(readFileSync(restoredCodexTr, "utf8"), s.codexContent);

  const restoredAgyDb = moved(s.agyDbPath, s.data, dataRestoredS3);
  const restoredAgyAnn = moved(s.agyAnnPath, s.data, dataRestoredS3);
  const restoredAgyBrain = moved(s.agyBrainPath, s.data, dataRestoredS3);
  assert.deepEqual(readFileSync(restoredAgyDb), s.agyDbBytes, "AGY binary .db byte-for-byte identical");
  assert.equal(readFileSync(restoredAgyAnn, "utf8"), 'status: "active"\n');
  assert.equal(readFileSync(restoredAgyBrain, "utf8"), "# Plan\n- Step 1\n");

  // Workspace code & auth token MUST NOT exist on restored station
  assert.ok(!existsSync(moved(s.workspaceSecret, s.data, dataRestoredS3)), "workspace code file NOT restored");
  assert.ok(!existsSync(moved(s.agyTokenPath, s.data, dataRestoredS3)), "profile token NOT restored");

  // ── Restore from PeerPlace into another empty station via TS reference `takeBack` ──
  const dataRestoredPeer = dataDir("tr-restore-peer");
  const dbRestoredPeer = join(dataRestoredPeer, "stillfail.db");
  Store.open(dbRestoredPeer, join(dataRestoredPeer, "archive")).close();
  const fibersD = new Fibers("copies-d", clock);
  closing.push(async () => fibersD.close());
  const runnerD = new InlineRunner({ db: dbRestoredPeer, replica: join(dataRestoredPeer, "replica"), dataDir: dataRestoredPeer, origin: sid("d"), now: () => 1_700_000_200_000 });
  closing.push(async () => runnerD.close());
  const copiesD = new Copies({
    data: dataRestoredPeer,
    here: () => sid("d"),
    places: () => ({ home: HOME, workspaces: [{ workspace: HOME, name: "station-d" }] }),
    roster: () => [
      { id: peerId, name: "station-b" },
      { id: sid("d"), name: "station-d" },
    ],
    ask: async (to, req) => {
      assert.equal(to, peerId);
      return copiesB.answers()(sid("d"), req, HOME);
    },
    runner: runnerD,
    fibers: fibersD,
    changed: () => {},
    restart: async () => null,
  });
  closing.push(async () => copiesD.close());
  await copiesD.start();
  await copiesD.settle();
  await copiesD.restore(HOME, originId, head.gen, { station: peerId });
  const readyPeer = takeBack(dataRestoredPeer, dbRestoredPeer, 1_700_000_200_000);
  assert.ok(readyPeer !== null);
  const peerClaudeProj = claudeProject(moved(s.claudeRoom, s.data, dataRestoredPeer))!;
  assert.deepEqual(
    readFileSync(join(dataRestoredPeer, "transcripts", "claude", peerClaudeProj, `${s.claudeId}.jsonl`)),
    Buffer.from(claudeAppended),
    "PeerPlace + TS takeBack restores byte-identical Claude transcript at remapped path",
  );
  assert.deepEqual(readFileSync(moved(s.agyDbPath, s.data, dataRestoredPeer)), s.agyDbBytes);

  // ── Restore from `includeTranscripts: false` S3 target succeeds cleanly without 404 ──
  const dataRestoredNoTr = dataDir("tr-restore-notr");
  const dbRestoredNoTr = join(dataRestoredNoTr, "stillfail.db");
  Store.open(dbRestoredNoTr, join(dataRestoredNoTr, "archive")).close();
  const fibersE = new Fibers("copies-e", clock);
  closing.push(async () => fibersE.close());
  const runnerE = new InlineRunner({ db: dbRestoredNoTr, replica: join(dataRestoredNoTr, "replica"), dataDir: dataRestoredNoTr, origin: sid("e"), now: () => 1_700_000_200_000 });
  closing.push(async () => runnerE.close());
  const copiesE = new Copies({
    data: dataRestoredNoTr,
    here: () => sid("e"),
    places: () => ({ home: HOME, workspaces: [{ workspace: HOME, name: "station-e" }] }),
    roster: () => [{ id: sid("e"), name: "station-e" }],
    ask: async () => { throw new Error("offline"); },
    runner: runnerE,
    fibers: fibersE,
    changed: () => {},
    restart: async () => null,
    backup: () => ({ mode: "manual", stations: [], acceptOthers: true, s3: [targetNoTr] }),
    s3ClientOptions: { now: () => 1_700_000_200_000 },
  });
  closing.push(async () => copiesE.close());
  await copiesE.start();
  await copiesE.settle();
  await copiesE.restore(HOME, originId, head.gen, { s3: "r2chat" });
  const readyNoTr = await takeBackSoon(dataRestoredNoTr, dbRestoredNoTr, 1_700_000_200_000, binary!);
  assert.ok(readyNoTr !== null);
  const outcomeNoTr = JSON.parse(readFileSync(join(dataRestoredNoTr, "replica", "restored.json"), "utf8"));
  assert.equal(outcomeNoTr.error, null, "restore from includeTranscripts:false target has no error");
  assert.ok(outcomeNoTr.missing >= 1, "missing transcript files counted gracefully");
  assert.ok(existsSync(moved(join(s.claudeRoom, "uploads", "note.txt"), s.data, dataRestoredNoTr)), "chat attachment still restored");
});

test("incremental transcript pass budget (files & bytes) and safe tr_del / GC (TS reference + MoonBit reader)", async () => {
  const makeFiveFileStation = (tag: string) => {
    const data = dataDir(tag);
    const db = join(data, "stillfail.db");
    const store = Store.open(db, join(data, "archive"));
    closing.push(async () => store.close());
    const room = join(data, "sessions", "chat", "chat:batch", "workspace");
    mkdirSync(room, { recursive: true });
    const cid = "claude-batch-001";
    store.insertSession({
      key: "chat:batch",
      connect: "chat",
      runtime: "claude",
      profile: "cc",
      workspace: room,
      token: "tok-batch",
      createdAt: 1,
      lastActiveAt: 1,
      ws: null,
    });
    store.setRuntimeSessionId("chat:batch", cid);
    const t = store.openThread("chat", "C", "ts-batch", "Batch Chat", "p@x").id;
    store.joinThread(t, "chat:batch", "chat");
    store.insertMessage({ thread: t, ts: "b.1", authorKind: "person", author: "p@x", text: "hello batch" });

    const proj = claudeProject(room)!;
    const trDir = join(data, "transcripts", "claude", proj);
    mkdirSync(join(trDir, cid), { recursive: true });
    const files: string[] = [];
    const mainPath = join(trDir, `${cid}.jsonl`);
    writeFileSync(mainPath, '{"i":0,"body":"main-transcript-0"}\n');
    files.push(mainPath);
    for (let i = 1; i <= 4; i++) {
      const p = join(trDir, cid, `sub-${i}.jsonl`);
      writeFileSync(p, `{"i":${i},"body":"sub-transcript-${i}"}\n`);
      files.push(p);
    }
    return { data, db, files };
  };

  // 1. TS reference: 5 files with transcriptPassFiles: 2 -> 3 passes (2 + 2 + 1), no spurious tr_del
  const tsSrc = makeFiveFileStation("tr-budget-ts");
  const tsReplica = join(tsSrc.data, "replica");
  let now = 1_700_000_000_000;
  const exporter = new Exporter({
    db: tsSrc.db,
    replica: tsReplica,
    dataDir: tsSrc.data,
    origin: sid("a"),
    now: () => now,
    chunkBytes: 1024,
    transcriptPassFiles: 2,
    fold: false,
  });
  closing.push(async () => exporter.close());
  exporter.setPlaces({ home: HOME, workspaces: [{ workspace: HOME, name: "src" }] });

  const readBatchRecs = (replica: string, head: { gen: string; batches: string[] }, batchIdx: number) => {
    const genDir = join(replica, "own", HOME, head.gen);
    return [...decodeBatch(readFileSync(join(genDir, "log", head.batches[batchIdx]!))).lines].map((l) => JSON.parse(l));
  };

  const p1 = exporter.pass(nothingTold());
  assert.equal(p1.more, true, "pass 1 truncated by transcriptPassFiles=2");
  const head1 = p1.heads[HOME]!;
  const recs1 = readBatchRecs(tsReplica, head1, 0);
  assert.equal(recs1.filter((r) => "tr" in r).length, 2, "pass 1 exports exactly 2 transcript files");
  assert.equal(recs1.filter((r) => "tr_del" in r).length, 0, "pass 1 emits no spurious tr_del");

  now += 1000;
  const p2 = exporter.pass(nothingTold());
  assert.equal(p2.more, true, "pass 2 truncated by transcriptPassFiles=2");
  const head2 = p2.heads[HOME]!;
  const recs2 = readBatchRecs(tsReplica, head2, head2.batches.length - 1);
  assert.equal(recs2.filter((r) => "tr" in r).length, 2, "pass 2 exports next 2 transcript files");
  assert.equal(recs2.filter((r) => "tr_del" in r).length, 0, "pass 2 emits no spurious tr_del");

  now += 1000;
  const p3 = exporter.pass(nothingTold());
  assert.equal(p3.more, false, "pass 3 finishes remaining 1 file");
  const head3 = p3.heads[HOME]!;
  const recs3 = readBatchRecs(tsReplica, head3, head3.batches.length - 1);
  assert.equal(recs3.filter((r) => "tr" in r).length, 1, "pass 3 exports final 1 transcript file");
  assert.equal(recs3.filter((r) => "tr_del" in r).length, 0, "pass 3 emits no tr_del");
  const head3Tf = await loadLocalTranscriptFiles(tsReplica, head3);
  assert.equal(Object.keys(head3Tf).length, 5, "all 5 transcript chunks present in head");

  // Delete 1 file and run a complete pass -> tr_del emitted and orphan chunk GC'd
  const deletedPath = tsSrc.files[4]!;
  const chunksBefore = new Set(Object.keys(head3Tf));
  rmSync(deletedPath);
  now += 1000;
  const p4 = exporter.pass({ ...nothingTold(), transcripts: true });
  assert.equal(p4.more, false);
  const head4 = p4.heads[HOME]!;
  const recs4 = readBatchRecs(tsReplica, head4, head4.batches.length - 1);
  const dels4 = recs4.filter((r) => "tr_del" in r).map((r) => r.tr_del);
  assert.deepEqual(dels4, [deletedPath], "complete pass emits tr_del for deleted file");
  const chunksAfter = new Set(Object.keys(await loadLocalTranscriptFiles(tsReplica, head4)));
  assert.equal(chunksAfter.size, 4, "deleted file chunk removed from head transcripts");
  const orphaned = [...chunksBefore].filter((ch) => !chunksAfter.has(ch));
  assert.equal(orphaned.length, 1);
  for (const ch of orphaned) {
    assert.ok(existsSync(join(tsReplica, "chunks", ch)), "orphan chunk retained on disk during grace period");
  }
  now += CHUNK_GC_GRACE_MS;
  exporter.pass({ ...nothingTold(), transcripts: true });
  for (const ch of orphaned) {
    assert.ok(!existsSync(join(tsReplica, "chunks", ch)), "orphan chunk GC'd from disk after grace period");
  }

  // 2. Single file larger than transcriptPassBytes must still make progress in one pass (no infinite loop)
  const bigData = dataDir("tr-budget-big");
  const bigDb = join(bigData, "stillfail.db");
  const bigStore = Store.open(bigDb, join(bigData, "archive"));
  closing.push(async () => bigStore.close());
  const bigRoom = join(bigData, "sessions", "chat", "chat:big", "workspace");
  mkdirSync(bigRoom, { recursive: true });
  bigStore.insertSession({
    key: "chat:big",
    connect: "chat",
    runtime: "codex",
    profile: "cx",
    workspace: bigRoom,
    token: "tok-big",
    createdAt: 1,
    lastActiveAt: 1,
    ws: null,
  });
  bigStore.setRuntimeSessionId("chat:big", "codex-big-001");
  const tBig = bigStore.openThread("chat", "C", "ts-big", "Big Chat", "p@x").id;
  bigStore.joinThread(tBig, "chat:big", "chat");
  const bigDir = join(bigData, "transcripts", "codex", "2026", "11", "22");
  mkdirSync(bigDir, { recursive: true });
  const bigFile = join(bigDir, "rollout-2026-11-22-codex-big-001.jsonl");
  writeFileSync(bigFile, "A".repeat(1024) + "B".repeat(1024) + "C".repeat(452));
  const bigExporter = new Exporter({
    db: bigDb,
    replica: join(bigData, "replica"),
    dataDir: bigData,
    origin: sid("a"),
    now: () => 1_700_000_000_000,
    chunkBytes: 1024,
    transcriptPassBytes: 512,
  });
  closing.push(async () => bigExporter.close());
  bigExporter.setPlaces({ home: HOME, workspaces: [{ workspace: HOME, name: "big" }] });
  const bigPass = bigExporter.pass(nothingTold());
  assert.equal(bigPass.more, false, "single file exceeding transcriptPassBytes completes in 1 pass");
  assert.equal(Object.keys(await loadLocalTranscriptFiles(join(bigData, "replica"), bigPass.heads[HOME]!)).length, 3, "2500B file split into 3 chunks of 1024B");

  // 3. MoonBit reader parity for transcriptPassFiles=2 (when binary is built)
  if (binary !== null) {
    const mbSrc = makeFiveFileStation("tr-budget-mb");
    const mbReplica = join(mbSrc.data, "replica");
    const runner = new ProgramRunner({
      db: mbSrc.db,
      replica: mbReplica,
      dataDir: mbSrc.data,
      origin: sid("a"),
      chunkBytes: 1024,
      transcriptPassFiles: 2,
    });
    closing.push(async () => runner.close());
    await runner.places({ home: HOME, workspaces: [{ workspace: HOME, name: "src" }] });

    const mp1 = await runner.pass(nothingTold());
    assert.equal(mp1.more, true, "MB pass 1 truncated by transcriptPassFiles=2");
    assert.equal(Object.keys(await loadLocalTranscriptFiles(mbReplica, mp1.heads[HOME]!)).length, 2);

    const mp2 = await runner.pass(nothingTold());
    assert.equal(mp2.more, true, "MB pass 2 truncated by transcriptPassFiles=2");
    assert.equal(Object.keys(await loadLocalTranscriptFiles(mbReplica, mp2.heads[HOME]!)).length, 4);

    const mp3 = await runner.pass(nothingTold());
    assert.equal(mp3.more, false, "MB pass 3 finishes remaining 1 file");
    assert.equal(Object.keys(await loadLocalTranscriptFiles(mbReplica, mp3.heads[HOME]!)).length, 5);

    rmSync(mbSrc.files[4]!);
    const mp4 = await runner.pass({ ...nothingTold(), transcripts: true });
    assert.equal(mp4.more, false);
    assert.equal(Object.keys(await loadLocalTranscriptFiles(mbReplica, mp4.heads[HOME]!)).length, 4, "MB complete pass deletes and GCs orphan chunk");
  }
});

test("ProgramRunner.close() force-kills a hung worker after closeGraceMs and rejects pending asks", async () => {
  class FakeHungThread extends EventEmitter {
    killed = false;
    posted: unknown[] = [];
    postMessage(m: unknown) {
      this.posted.push(m);
      // Intentionally never replies to simulate a worker stuck in a long pass.
    }
    kill() {
      this.killed = true;
    }
  }
  const fake = new FakeHungThread();
  const runner = new ProgramRunner(
    { db: "/tmp/x.db", replica: "/tmp/r", dataDir: "/tmp/d", origin: sid("a") },
    () => fake,
    25,
  );
  const pendingPass = runner.pass(nothingTold());
  await runner.close();
  assert.equal(fake.killed, true, "hung worker was force-killed after closeGraceMs");
  await assert.rejects(pendingPass, /closed/);
  await assert.rejects(runner.pass(nothingTold()), /closed/);
});

test("Copies.close() closes runner before awaiting hung pass so closeGraceMs force-kill triggers without deadlock", async () => {
  class FakeHungThread extends EventEmitter {
    killed = false;
    postMessage(_m: unknown) {
      // Never replies: simulates replica-export stuck in a long pass.
    }
    kill() {
      this.killed = true;
    }
  }
  const fake = new FakeHungThread();
  const data = dataDir("tr-copies-close");
  const clock = testClock();
  const fibers = new Fibers("copies-close", clock);
  closing.push(async () => fibers.close());
  const runner = new ProgramRunner(
    { db: join(data, "stillfail.db"), replica: join(data, "replica"), dataDir: data, origin: sid("a") },
    () => fake,
    25,
  );
  const copies = new Copies({
    data,
    here: () => sid("a"),
    places: () => ({ home: HOME, workspaces: [{ workspace: HOME, name: "a" }] }),
    roster: () => [{ id: sid("a"), name: "a" }],
    ask: async () => { throw new Error("offline"); },
    runner,
    fibers,
    changed: () => {},
    restart: async () => null,
  });

  // Trigger a stuck pass via told() + gather (1s).
  copies.told({ type: "session", key: "s-hung" });
  await clock.move(1_000);
  // copies.close() must call runner.close() first, triggering fake.kill() after ~25ms and returning cleanly.
  await copies.close();
  assert.equal(fake.killed, true, "Copies.close() triggered ProgramRunner force-kill without deadlocking on #passing");
});

test("Copies pass failure strictly respects exponential backoff even when told() arrives during retry window", async () => {
  const data = dataDir("tr-backoff");
  const clock = testClock();
  const fibers = new Fibers("copies-backoff", clock);
  closing.push(async () => fibers.close());

  let shouldFail = true;
  let passCalls = 0;
  const seenSessions: string[] = [];
  const runner = {
    places: async () => {},
    pass: async (told: ReturnType<typeof nothingTold>) => {
      passCalls++;
      if (shouldFail) throw new Error("database is locked");
      seenSessions.push(...told.sessions);
      return { heads: {}, more: false, wrote: 1, read: 0, empty: false };
    },
    newGenerations: async () => {},
    sources: async () => ({}),
    close: async () => {},
  };

  const copies = new Copies({
    data,
    here: () => sid("a"),
    places: () => ({ home: HOME, workspaces: [{ workspace: HOME, name: "a" }] }),
    roster: () => [{ id: sid("a"), name: "a" }],
    ask: async () => { throw new Error("offline"); },
    runner,
    fibers,
    changed: () => {},
    restart: async () => null,
  });
  closing.push(async () => copies.close());

  // First change triggers gather (1s) -> pass #1 fails -> 5s backoff armed
  copies.told({ type: "session", key: "s1" });
  await clock.move(1_000);
  assert.equal(passCalls, 1);

  // Changes arriving during the 5s backoff must NOT trigger a 1s gather retry
  copies.told({ type: "session", key: "s2" });
  await clock.move(1_000);
  assert.equal(passCalls, 1, "backoff not bypassed at +1s");
  copies.told({ type: "session", key: "s3" });
  await clock.move(3_000);
  assert.equal(passCalls, 1, "backoff not bypassed at +4s");

  // At +5s retry fires, succeeds, and exports all accumulated sessions together
  shouldFail = false;
  await clock.move(1_500);
  assert.equal(passCalls, 2, "retry fired after 5s backoff");
  assert.ok(seenSessions.includes("s1"));
  assert.ok(seenSessions.includes("s2"));
  assert.ok(seenSessions.includes("s3"));
});

async function makeMbExportHelper(
  db: string,
  replica: string,
  data: string,
  origin: string,
  chunkBytes = 4096,
  extraArgs: string[] = [],
) {
  const proc = new MbProcess(binary!, [
    "--builder",
    "replica-export",
    "--db",
    db,
    "--replica",
    replica,
    "--data-dir",
    data,
    "--origin",
    origin,
    "--sep",
    sep,
    "--chunk-bytes",
    String(chunkBytes),
    ...extraArgs,
  ]);
  closing.push(() => proc.terminate().then(() => {}));
  const waiting = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void }>();
  let next = 0;
  proc.on("message", (m: any) => {
    const w = waiting.get(m.id);
    waiting.delete(m.id);
    if (m.error !== undefined) w?.reject(new Error(m.error));
    else w?.resolve(m.answer);
  });
  proc.on("exit", () => {
    for (const w of waiting.values()) w.reject(new Error("replica-export ended"));
    waiting.clear();
  });
  const ask = (m: Record<string, unknown>, now: number) =>
    new Promise<any>((resolve, reject) => {
      const id = ++next;
      waiting.set(id, { resolve, reject });
      proc.postMessage({ ...m, id, now });
    });
  return {
    places: (now: number, workspaces: { workspace: string; name: string }[] = [{ workspace: HOME, name: "src" }]) =>
      ask({ type: "places", places: { home: HOME, workspaces } }, now),
    testFaults: (faults: Record<string, string[]> | null, now: number) => ask({ type: "testFaults", faults }, now),
    pass: (told: ReturnType<typeof nothingTold>, now: number) => ask({ type: "pass", told }, now),
    sources: (hashes: string[], now: number) => ask({ type: "sources", hashes }, now) as Promise<Record<string, string>>,
    newGenerations: (after: number, now: number) => ask({ type: "newGenerations", after }, now),
    close: (now: number) => ask({ type: "close" }, now),
  };
}

async function runLongSyncGraceRegression(mode: "ts" | "mb") {
  const s = makeTranscriptStation();
  closing.push(async () => s.store.close());
  const replica = join(s.data, "replica");
  const originId = sid("a");
  const peerId = sid("b");
  let now = 1_700_000_000_000;

  let passFn: (told: ReturnType<typeof nothingTold>) => Promise<any>;
  let sourcesFn: (hashes: string[]) => Promise<Map<string, string>>;
  if (mode === "ts") {
    const exporter = new Exporter({
      db: s.db,
      replica,
      dataDir: s.data,
      origin: originId,
      now: () => now,
      chunkBytes: 4096,
    });
    closing.push(async () => exporter.close());
    exporter.setPlaces({ home: HOME, workspaces: [{ workspace: HOME, name: "src" }] });
    passFn = async (told) => exporter.pass(told);
    sourcesFn = async (hashes) => {
      const m = new Map<string, string>();
      for (const h of hashes) {
        const src = exporter.sourceOf(h);
        if (src !== null) m.set(h, src);
      }
      return m;
    };
  } else {
    const mb = await makeMbExportHelper(s.db, replica, s.data, originId, 4096);
    await mb.places(now);
    passFn = (told) => mb.pass(told, now);
    sourcesFn = async (hashes) => new Map(Object.entries(await mb.sources(hashes, now)));
  }

  const p1 = await passFn(nothingTold());
  const head1 = p1.heads[HOME]!;
  const genDir = join(replica, "own", HOME, head1.gen);
  const trRecs1 = head1.batches.flatMap((b: string) =>
    [...decodeBatch(readFileSync(join(genDir, "log", b))).lines].map((l) => JSON.parse(l)).filter((r) => "tr" in r),
  );
  const claudeRec1 = trRecs1.find((r: any) => r.tr === s.claudeTrPath)!;
  const oldTail = claudeRec1.chunks[2] as string;
  assert.ok(existsSync(join(replica, "chunks", oldTail)));

  // Set up a PeerPlace whose putFile pauses on `oldTail` before `stat(source)` runs.
  const peerDir = dataDir(`tr-grace-peer-${mode}`);
  const peerFolder = new FolderPlace(join(peerDir, "replicas"));
  const peerHandler = serve({ place: peerFolder, inWorkspace: () => true, hello: () => [] });
  let hitOldTail!: () => void;
  const oldTailReached = new Promise<void>((r) => {
    hitOldTail = r;
  });
  let releasePutFile!: () => void;
  const putFileGate = new Promise<void>((r) => {
    releasePutFile = r;
  });
  class PausingPeerPlace extends PeerPlace {
    override async putFile(ws: string, origin: string, hash: string, source: string | Buffer): Promise<void> {
      if (hash === oldTail) {
        hitOldTail();
        await putFileGate;
      }
      return super.putFile(ws, origin, hash, source);
    }
  }
  const peerPlace = new PausingPeerPlace(peerId, async (_to, req) => peerHandler(originId, req, HOME));

  // Start `level()` for head1; it pauses right before PeerPlace.putFile stats `oldTail`.
  const levelPromise = level(peerPlace, HOME, {
    head: head1,
    batch: (name) => readFile(join(genDir, "log", name)),
    sources: sourcesFn,
    loadTranscriptFiles: () => loadLocalTranscriptFiles(replica, head1),
  });
  await oldTailReached;

  // Simulate 4 rounds of 30s transcript updates (~120s+, spanning > STALE_HEADS_MOST=2) while putFile is in flight.
  const evictedTails: string[] = [oldTail];
  let content = s.claudeInitial;
  let prevTail = oldTail;
  for (let round = 1; round <= 4; round++) {
    now += 30_000;
    content += JSON.stringify({ role: "assistant", text: `turn-append-${round}` }) + "\n";
    writeFileSync(s.claudeTrPath, content);
    utimesSync(s.claudeTrPath, new Date(now), new Date(now));
    const pr = await passFn({ ...nothingTold(), transcripts: true });
    const hr = pr.heads[HOME]!;
    const lastBatch = hr.batches[hr.batches.length - 1]!;
    const recs = [...decodeBatch(readFileSync(join(genDir, "log", lastBatch))).lines]
      .map((l) => JSON.parse(l))
      .filter((r) => "tr" in r && r.tr === s.claudeTrPath);
    assert.equal(recs.length, 1);
    const nextTail = recs[0].chunks[2] as string;
    assert.notEqual(nextTail, prevTail, `round ${round} produced a new tail chunk`);
    if (round < 4) evictedTails.push(nextTail);
    prevTail = nextTail;
  }
  assert.equal(evictedTails.length, 4);
  for (const ch of evictedTails) {
    assert.ok(existsSync(join(replica, "chunks", ch)), `evicted chunk ${ch} stays on disk during grace window`);
  }

  // Release putFile -> level() succeeds on the first try with zero ENOENT!
  releasePutFile();
  const levelled = await levelPromise;
  assert.equal(levelled.behind, false);
  assert.equal(levelled.missing, 0);
  const held = await peerFolder.held(HOME, originId);
  assert.ok(held.files.includes(oldTail), "PeerPlace received oldTail cleanly with zero ENOENT");

  // Advance past CHUNK_GC_GRACE_MS and run a pass -> all 4 evicted tail chunks are GC'd from disk, live tail kept.
  now += CHUNK_GC_GRACE_MS;
  await passFn({ ...nothingTold(), transcripts: true });
  for (const ch of evictedTails) {
    assert.ok(!existsSync(join(replica, "chunks", ch)), `evicted chunk ${ch} GC'd after grace period`);
  }
  assert.ok(existsSync(join(replica, "chunks", prevTail)), "current live tail chunk remains on disk");
}

async function runReReferencedChunkRegression(mode: "ts" | "mb") {
  const s = makeTranscriptStation();
  closing.push(async () => s.store.close());
  const replica = join(s.data, "replica");
  const originId = sid("a");
  let now = 1_700_000_000_000;

  let passFn: (told: ReturnType<typeof nothingTold>) => Promise<any>;
  if (mode === "ts") {
    const exporter = new Exporter({
      db: s.db,
      replica,
      dataDir: s.data,
      origin: originId,
      now: () => now,
      chunkBytes: 4096,
    });
    closing.push(async () => exporter.close());
    exporter.setPlaces({ home: HOME, workspaces: [{ workspace: HOME, name: "src" }] });
    passFn = async (told) => exporter.pass(told);
  } else {
    const mb = await makeMbExportHelper(s.db, replica, s.data, originId, 4096);
    await mb.places(now);
    passFn = (told) => mb.pass(told, now);
  }

  const p1 = await passFn(nothingTold());
  const head1 = p1.heads[HOME]!;
  const genDir = join(replica, "own", HOME, head1.gen);
  const trRecs1 = head1.batches.flatMap((b: string) =>
    [...decodeBatch(readFileSync(join(genDir, "log", b))).lines].map((l) => JSON.parse(l)).filter((r) => "tr" in r),
  );
  const chunkC = trRecs1.find((r: any) => r.tr === s.claudeTrPath)!.chunks[2] as string;
  assert.ok(existsSync(join(replica, "chunks", chunkC)));

  const readGcPending = () => {
    const db = new DatabaseSync(join(replica, "export.db"), { readOnly: true });
    try {
      return (db.prepare("SELECT chunk_hash FROM transcript_chunk_gc ORDER BY chunk_hash").all() as { chunk_hash: string }[]).map((r) => r.chunk_hash);
    } finally {
      db.close();
    }
  };

  // At t0: evict chunk C -> recorded in transcript_chunk_gc, still on disk.
  const t0 = now + 60_000;
  now = t0;
  writeFileSync(s.claudeTrPath, s.claudeInitial + JSON.stringify({ role: "assistant", text: "temp-append" }) + "\n");
  utimesSync(s.claudeTrPath, new Date(now), new Date(now));
  const p2 = await passFn({ ...nothingTold(), transcripts: true });
  assert.equal((await loadLocalTranscriptFiles(replica, p2.heads[HOME]!))[chunkC], undefined);
  assert.ok(existsSync(join(replica, "chunks", chunkC)), "chunk C retained on disk at t0");
  assert.ok(readGcPending().includes(chunkC), "chunk C recorded in transcript_chunk_gc");

  // At t0 + 300_000 (within grace period): restore content so chunk C is re-referenced.
  now = t0 + 300_000;
  writeFileSync(s.claudeTrPath, s.claudeInitial);
  utimesSync(s.claudeTrPath, new Date(now), new Date(now));
  const p3 = await passFn({ ...nothingTold(), transcripts: true });
  assert.notEqual((await loadLocalTranscriptFiles(replica, p3.heads[HOME]!))[chunkC], undefined, "chunk C re-referenced in head transcripts");
  assert.ok(existsSync(join(replica, "chunks", chunkC)), "chunk C still on disk at t0 + 300s");
  assert.ok(!readGcPending().includes(chunkC), "chunk C cleared from transcript_chunk_gc on re-reference");

  // At t0 + 1_000_000 (past original grace deadline): chunk C must NOT be deleted and transcript_chunk_gc has no residue.
  now = t0 + 1_000_000;
  const p4 = await passFn({ ...nothingTold(), transcripts: true });
  assert.notEqual((await loadLocalTranscriptFiles(replica, p4.heads[HOME]!))[chunkC], undefined);
  assert.ok(existsSync(join(replica, "chunks", chunkC)), "re-referenced chunk C survives past original grace deadline");
  assert.ok(!readGcPending().includes(chunkC), "no transcript_chunk_gc residue for chunk C");
}

test("TS reference + PeerPlace: long sync across 4 rounds of 30s transcript updates hits zero ENOENT", () =>
  runLongSyncGraceRegression("ts"));

test("MoonBit reader + PeerPlace: long sync across 4 rounds of 30s transcript updates hits zero ENOENT", { skip: skipMb }, () =>
  runLongSyncGraceRegression("mb"));

test("TS reference: chunk re-referenced within grace period is not deleted and clears transcript_chunk_gc", () =>
  runReReferencedChunkRegression("ts"));

test("MoonBit reader: chunk re-referenced within grace period is not deleted and clears transcript_chunk_gc", { skip: skipMb }, () =>
  runReReferencedChunkRegression("mb"));

async function runTranscriptCacheConsistency(mode: "ts" | "mb") {
  const s = makeTranscriptStation();
  closing.push(async () => s.store.close());
  const replica = join(s.data, "replica");
  const originId = sid("a");
  let now = 1_700_000_000_000;

  let passFn: (told: ReturnType<typeof nothingTold>) => Promise<any>;
  let newGenFn: (after: number) => Promise<void>;
  if (mode === "ts") {
    const exporter = new Exporter({
      db: s.db,
      replica,
      dataDir: s.data,
      origin: originId,
      now: () => now,
      chunkBytes: 4096,
    });
    closing.push(async () => exporter.close());
    exporter.setPlaces({ home: HOME, workspaces: [{ workspace: HOME, name: "src" }] });
    passFn = async (told) => exporter.pass(told);
    newGenFn = async (after) => exporter.newGenerations(after);
  } else {
    const mb = await makeMbExportHelper(s.db, replica, s.data, originId, 4096);
    await mb.places(now);
    passFn = (told) => mb.pass(told, now);
    newGenFn = (after) => mb.newGenerations(after, now);
  }

  // 1. Initial pass populates transcriptFiles and tfCache.
  const p1 = await passFn(nothingTold());
  const tf1 = await loadLocalTranscriptFiles(replica, p1.heads[HOME]!);
  assert.ok(Object.keys(tf1).length >= 3);

  // 2. Non-transcript chat-only pass hits tfCache with zero drift.
  now += 10_000;
  const thread = s.store.sessionThreads("chat:claude")[0]!.thread.id;
  s.store.insertMessage({ thread, ts: "c.cache.1", authorKind: "person", author: "p@x", text: "chat only" });
  const p2 = await passFn(nothingTold());
  assert.equal(p2.wrote, 1);
  assert.deepEqual(await loadLocalTranscriptFiles(replica, p2.heads[HOME]!), tf1, "cached transcriptFiles matches on non-transcript pass");

  // 3. Updating a transcript invalidates tfCache and updates head.transcriptFiles.
  now += 10_000;
  writeFileSync(s.claudeTrPath, s.claudeInitial + JSON.stringify({ role: "assistant", text: "cache-invalidation-append" }) + "\n");
  utimesSync(s.claudeTrPath, new Date(now), new Date(now));
  const p3 = await passFn({ ...nothingTold(), transcripts: true });
  const tf3 = await loadLocalTranscriptFiles(replica, p3.heads[HOME]!);
  assert.notDeepEqual(tf3, tf1, "transcript update invalidates cache");

  // 4. Failed pass with rollback clears tfCache; subsequent pass succeeds with exact state.
  now += 10_000;
  const gen = p3.heads[HOME]!.gen as string;
  const headPath = join(replica, "own", HOME, gen, "head.json");
  const keptPath = join(replica, "own", HOME, gen, "head.kept");
  writeFileSync(s.codexTrPath, '{"type":"event","payload":"codex-before-rollback"}\n');
  utimesSync(s.codexTrPath, new Date(now), new Date(now));
  // Make head.json unwritable (directory) so write_head fails and pass rolls back.
  writeFileSync(keptPath, readFileSync(headPath));
  rmSync(headPath);
  mkdirSync(headPath);
  await assert.rejects(() => passFn({ ...nothingTold(), transcripts: true }));
  rmSync(headPath, { recursive: true });
  writeFileSync(headPath, readFileSync(keptPath));
  rmSync(keptPath);
  // Chat-only pass after rollback must still see pre-rollback tf3 (not uncommitted codex update).
  now += 10_000;
  s.store.insertMessage({ thread, ts: "c.cache.2", authorKind: "person", author: "p@x", text: "after rollback" });
  const pAfterRollback = await passFn(nothingTold());
  assert.deepEqual(await loadLocalTranscriptFiles(replica, pAfterRollback.heads[HOME]!), tf3, "rollback cleared tfCache so stale uncommitted transcripts are not leaked");

  // Now commit the codex transcript update.
  now += 10_000;
  const p4 = await passFn({ ...nothingTold(), transcripts: true });
  const tf4 = await loadLocalTranscriptFiles(replica, p4.heads[HOME]!);
  assert.notDeepEqual(tf4, tf3);

  // 5. Deleting a transcript (tr_del) invalidates tfCache.
  now += 10_000;
  rmSync(s.codexTrPath);
  const p5 = await passFn({ ...nothingTold(), transcripts: true });
  const tf5 = await loadLocalTranscriptFiles(replica, p5.heads[HOME]!);
  assert.notDeepEqual(tf5, tf4, "tr_del invalidates tfCache");

  // 6. newGenerations() clears tfCache and re-exports cleanly.
  now += 60_000;
  await newGenFn(now - 1);
  const p6 = await passFn(nothingTold());
  assert.deepEqual(await loadLocalTranscriptFiles(replica, p6.heads[HOME]!), tf5, "newGenerations re-exports exact transcriptFiles");
}

test("TS reference: transcriptFiles cache stays consistent across chat-only pass, tr, tr_del, rollback, and newGenerations", () =>
  runTranscriptCacheConsistency("ts"));

test("MoonBit reader: transcriptFiles cache stays consistent across chat-only pass, tr, tr_del, rollback, and newGenerations", { skip: skipMb }, () =>
  runTranscriptCacheConsistency("mb"));

// ── D71: AGY brain cache pruning, unreadable protection, tr_del batch throttling, and restore compatibility ──

function makeAgyBrainStation() {
  const data = dataDir("agy-d71");
  const db = join(data, "stillfail.db");
  const store = Store.open(db, join(data, "archive"));
  const agyRoom = join(data, "sessions", "chat", "chat:agy-d71", "workspace");
  mkdirSync(agyRoom, { recursive: true });
  const agyId = "agy-brain-d71";
  store.insertSession({
    key: "chat:agy-d71",
    connect: "chat",
    runtime: "agy",
    profile: "agyprof",
    workspace: agyRoom,
    token: "tok-agy-d71",
    createdAt: 1,
    lastActiveAt: 1,
    ws: null,
  });
  store.setRuntimeSessionId("chat:agy-d71", agyId);
  const t = store.openThread("chat", "C", "ts-agy-d71", "AGY D71", "p@x").id;
  store.joinThread(t, "chat:agy-d71", "chat");
  store.insertMessage({ thread: t, ts: "g.1", authorKind: "person", author: "p@x", text: "hello agy d71" });

  const cli = join(data, "homes", "agyprof", "agy", ".gemini", "antigravity-cli");
  const brain = join(cli, "brain", agyId);
  const keptFiles = [
    join(cli, "conversations", `${agyId}.db`),
    join(cli, "annotations", `${agyId}.pbtxt`),
    join(brain, "task.md"),
    join(brain, "scratchpad", "a.txt"),
    join(brain, "notes", "scratch", "b.txt"),
    join(brain, ".system_generated", "logs", "transcript.jsonl"),
    join(brain, ".system_generated", "logs", "transcript_full.jsonl"),
    join(brain, ".system_generated", "logs", "media", "x.png"),
    join(brain, ".system_generated", "messages", "m1.json"),
  ];
  const prunedFiles = [
    join(brain, ".system_generated", "steps", "1", "output.txt"),
    join(brain, ".system_generated", "logs", "chunks", "chunk-0.json"),
    join(brain, "scratch", "tmp.py"),
  ];
  for (const p of [...keptFiles, ...prunedFiles]) {
    mkdirSync(join(p, ".."), { recursive: true });
    writeFileSync(p, `content:${p}\n`);
  }
  return { data, db, store, cli, brain, agyId, keptFiles, prunedFiles };
}

test("D71: AGY brain exact pruning (no-descend) + restore parity + legacy backup compatibility (TS + MoonBit)", async () => {
  const s = makeAgyBrainStation();
  closing.push(async () => s.store.close());
  const now = 1_700_000_000_000;
  const originId = sid("a");

  // 1. TS reference: record every readdir call and explicitly assert pruned dirs have 0 readdir calls
  const prunedDirs = new Set([
    join(s.brain, ".system_generated", "steps"),
    join(s.brain, ".system_generated", "logs", "chunks"),
    join(s.brain, "scratch"),
  ]);
  const readdirVisited: string[] = [];
  const replicaTs = join(s.data, "replica-ts");
  const exporter = new Exporter({
    db: s.db,
    replica: replicaTs,
    dataDir: s.data,
    origin: originId,
    now: () => now,
    chunkBytes: 4096,
    testFaults: {
      onReaddir: (dir) => {
        readdirVisited.push(dir);
      },
    },
  });
  closing.push(async () => exporter.close());
  exporter.setPlaces({ home: HOME, workspaces: [{ workspace: HOME, name: "src" }] });
  const pTs = exporter.pass(nothingTold());
  const headTs = pTs.heads[HOME]!;
  const genDirTs = join(replicaTs, "own", HOME, headTs.gen);
  const trPathsTs = headTs.batches
    .flatMap((b) => [...decodeBatch(readFileSync(join(genDirTs, "log", b))).lines].map((l) => JSON.parse(l)))
    .filter((r) => "tr" in r)
    .map((r) => r.tr as string)
    .sort();
  assert.deepEqual(trPathsTs, [...s.keptFiles].sort(), "TS reference keeps exact non-cache files and excludes 3 cache subtrees");
  assert.ok(readdirVisited.includes(s.brain), "TS actually walked brain root");
  for (const pd of prunedDirs) {
    assert.equal(readdirVisited.filter((d) => d === pd).length, 0, `TS must never call readdir on pruned dir ${pd}`);
  }

  // 2. Restore TS export into a new dataDir -> all kept files restored, pruned caches absent
  const diskHeadTs = JSON.parse(readFileSync(join(genDirTs, "head.json"), "utf8")) as typeof headTs;
  const restoreDir = dataDir("agy-d71-restore");
  Store.open(join(restoreDir, "stillfail.db"), join(restoreDir, "archive")).close();
  const copyDir = join(restoreDir, "restore", "copy");
  mkdirSync(join(copyDir, "files"), { recursive: true });
  mkdirSync(join(copyDir, diskHeadTs.gen, "log"), { recursive: true });
  writeFileSync(join(copyDir, diskHeadTs.gen, "head.json"), JSON.stringify(diskHeadTs));
  for (const b of diskHeadTs.batches) {
    writeFileSync(join(copyDir, diskHeadTs.gen, "log", b), readFileSync(join(genDirTs, "log", b)));
  }
  for (const h of [...Object.keys(diskHeadTs.files), ...Object.keys(diskHeadTs.transcriptFiles ?? {})]) {
    writeFileSync(join(copyDir, "files", h), readFileSync(exporter.sourceOf(h)!));
  }
  writeFileSync(
    join(restoreDir, "restore", "ready.json"),
    JSON.stringify({ origin: originId, workspace: HOME, gen: diskHeadTs.gen, name: "src", from: "peer" }),
  );
  takeBack(restoreDir, join(restoreDir, "stillfail.db"), now + 1000);
  for (const p of s.keptFiles) {
    const dest = p.replace(s.data, restoreDir);
    assert.equal(existsSync(dest), true, `restored kept file ${dest}`);
    assert.equal(readFileSync(dest, "utf8"), `content:${p}\n`);
  }
  for (const p of s.prunedFiles) {
    const dest = p.replace(s.data, restoreDir);
    assert.equal(existsSync(dest), false, `pruned cache file must not exist after restore: ${dest}`);
  }

  // 3. Legacy backup containing brain/<id>/scratch/legacy.txt is STILL restorable (is_transcript_path untouched)
  const legacyDir = dataDir("agy-d71-legacy-restore");
  Store.open(join(legacyDir, "stillfail.db"), join(legacyDir, "archive")).close();
  const legacyCopy = join(legacyDir, "restore", "copy");
  const legacyChunkHash = Object.keys(diskHeadTs.transcriptFiles!)[0]!;
  const legacyPath = join(s.brain, "scratch", "legacy.txt");
  const legacyGen = "1000-deadbeef";
  const legacyLines = [
    ...diskHeadTs.batches.flatMap((b) => [...decodeBatch(readFileSync(join(genDirTs, "log", b))).lines]),
    JSON.stringify({ tr: legacyPath, room: null, size: 12, mtime: now, mode: 0o644, chunks: [legacyChunkHash] }),
  ];
  const { encodeBatch, batchName } = await import("./reference/replica-format.ts");
  const batchBytes = encodeBatch({ v: 1, gen: legacyGen, from: 1, to: 1, made: now }, [], legacyLines.map((l) => Buffer.from(l + "\n")));
  const bName = batchName(1, 1, batchBytes);
  mkdirSync(join(legacyCopy, "files"), { recursive: true });
  mkdirSync(join(legacyCopy, legacyGen, "log"), { recursive: true });
  writeFileSync(join(legacyCopy, legacyGen, "log", bName), batchBytes);
  writeFileSync(
    join(legacyCopy, legacyGen, "head.json"),
    JSON.stringify({ ...diskHeadTs, gen: legacyGen, batches: [bName], to: 1 }),
  );
  for (const h of [...Object.keys(diskHeadTs.files), ...Object.keys(diskHeadTs.transcriptFiles ?? {})]) {
    writeFileSync(join(legacyCopy, "files", h), readFileSync(exporter.sourceOf(h)!));
  }
  writeFileSync(
    join(legacyDir, "restore", "ready.json"),
    JSON.stringify({ origin: originId, workspace: HOME, gen: legacyGen, name: "src", from: "peer" }),
  );
  takeBack(legacyDir, join(legacyDir, "stillfail.db"), now + 2000);
  assert.equal(existsSync(legacyPath.replace(s.data, legacyDir)), true, "legacy backup scratch file still restores cleanly");

  // 4. MoonBit reader parity: forbid_readdir proves MoonBit never calls readdir on pruned dirs
  if (binary !== null) {
    const replicaMb = join(s.data, "replica-mb");
    const mb = await makeMbExportHelper(s.db, replicaMb, s.data, originId, 4096, [
      "--test-faults",
      JSON.stringify({ forbid_readdir: [...prunedDirs] }),
    ]);
    await mb.places(now);
    const pMb = await mb.pass(nothingTold(), now);
    const headMb = pMb.heads[HOME]!;
    const genDirMb = join(replicaMb, "own", HOME, headMb.gen);
    const trPathsMb = headMb.batches
      .flatMap((b: string) => [...decodeBatch(readFileSync(join(genDirMb, "log", b))).lines].map((l) => JSON.parse(l)))
      .filter((r: any) => "tr" in r)
      .map((r: any) => r.tr as string)
      .sort();
    assert.deepEqual(trPathsMb, trPathsTs, "MoonBit reader matches TS reference brain pruning 1:1");
  }
});

test("D71: brain/<id> root symlink and subdir symlink are never followed or exported (TS + MoonBit)", async () => {
  const s = makeAgyBrainStation();
  closing.push(async () => s.store.close());
  const now = 1_700_000_000_000;
  const originId = sid("a");

  // Outside target dir that symlinks point to (must NEVER be exported)
  const outsideTarget = join(s.data, "outside-secret");
  mkdirSync(outsideTarget, { recursive: true });
  writeFileSync(join(outsideTarget, "leak.md"), "secret-via-symlink\n");

  // Subdir symlink inside existing brain/<id>
  symlinkSync(outsideTarget, join(s.brain, "linked-sub"), "dir");

  // Second AGY session whose brain/<id2> root itself is a symlink
  const agyId2 = "agy-brain-symlink-root";
  const room2 = join(s.data, "sessions", "chat", "chat:agy-sym", "workspace");
  mkdirSync(room2, { recursive: true });
  s.store.insertSession({
    key: "chat:agy-sym",
    connect: "chat",
    runtime: "agy",
    profile: "agyprof",
    workspace: room2,
    token: "tok-agy-sym",
    createdAt: 2,
    lastActiveAt: 2,
    ws: null,
  });
  s.store.setRuntimeSessionId("chat:agy-sym", agyId2);
  const t2 = s.store.openThread("chat", "C", "ts-agy-sym", "AGY Sym", "p@x").id;
  s.store.joinThread(t2, "chat:agy-sym", "chat");
  symlinkSync(outsideTarget, join(s.cli, "brain", agyId2), "dir");

  const replicaTs = join(s.data, "replica-sym-ts");
  const exporter = new Exporter({ db: s.db, replica: replicaTs, dataDir: s.data, origin: originId, now: () => now, chunkBytes: 4096 });
  closing.push(async () => exporter.close());
  exporter.setPlaces({ home: HOME, workspaces: [{ workspace: HOME, name: "src" }] });
  const pTs = exporter.pass(nothingTold());
  const headTs = pTs.heads[HOME]!;
  const genDirTs = join(replicaTs, "own", HOME, headTs.gen);
  const tsPaths = headTs.batches
    .flatMap((b) => [...decodeBatch(readFileSync(join(genDirTs, "log", b))).lines].map((l) => JSON.parse(l)))
    .filter((r) => "tr" in r)
    .map((r) => r.tr as string);
  assert.ok(!tsPaths.some((p) => p.includes("leak.md")), "TS must not follow root or subdir symlinks");

  if (binary !== null) {
    const replicaMb = join(s.data, "replica-sym-mb");
    const mb = await makeMbExportHelper(s.db, replicaMb, s.data, originId, 4096);
    await mb.places(now);
    const pMb = await mb.pass(nothingTold(), now);
    const headMb = pMb.heads[HOME]!;
    const genDirMb = join(replicaMb, "own", HOME, headMb.gen);
    const mbPaths = headMb.batches
      .flatMap((b: string) => [...decodeBatch(readFileSync(join(genDirMb, "log", b))).lines].map((l) => JSON.parse(l)))
      .filter((r: any) => "tr" in r)
      .map((r: any) => r.tr as string);
    assert.ok(!mbPaths.some((p: string) => p.includes("leak.md")), "MoonBit must not follow root or subdir symlinks");
    assert.deepEqual(mbPaths.sort(), tsPaths.sort());
  }
});

test("D71: unreadable directory / lstat / discovery-parent / fresh & mid short-read protection (TS + MoonBit, root-safe)", async () => {
  const s = makeAgyBrainStation();
  closing.push(async () => s.store.close());
  let now = 1_700_000_000_000;
  const originId = sid("a");
  const mkErr = (code: string): NodeJS.ErrnoException => Object.assign(new Error(`${code}: injected`), { code });

  // Also add a Claude session with subagent dir to cover claude unreadable protection
  const claudeRoom = join(s.data, "sessions", "chat", "chat:claude-d71", "workspace");
  mkdirSync(claudeRoom, { recursive: true });
  const claudeId = "claude-d71-001";
  s.store.insertSession({
    key: "chat:claude-d71",
    connect: "chat",
    runtime: "claude",
    profile: "cc",
    workspace: claudeRoom,
    token: "tok-cc-d71",
    createdAt: 2,
    lastActiveAt: 2,
    ws: null,
  });
  s.store.setRuntimeSessionId("chat:claude-d71", claudeId);
  const tClaude = s.store.openThread("chat", "C", "ts-cc-d71", "Claude D71", "p@x").id;
  s.store.joinThread(tClaude, "chat:claude-d71", "chat");
  const claudeTrDir = join(s.data, "transcripts", "claude", claudeProject(claudeRoom)!);
  const claudeSubDir = join(claudeTrDir, claudeId);
  mkdirSync(claudeSubDir, { recursive: true });
  const claudeTrPath = join(claudeTrDir, `${claudeId}.jsonl`);
  const claudeSubPath = join(claudeSubDir, "sub-1.jsonl");
  writeFileSync(claudeTrPath, '{"role":"user","text":"hello"}\n');
  writeFileSync(claudeSubPath, '{"sub":true}\n');

  // Dedicated Claude session discovered via Finder scanning `transcripts/claude/` (workspace != slug)
  const finderEioId = "cc-finder-eio";
  const claudeProjectsDir = join(s.data, "transcripts", "claude");
  const finderEioSlugDir = join(claudeProjectsDir, "-finder-eio-slug");
  mkdirSync(finderEioSlugDir, { recursive: true });
  const finderEioTrPath = join(finderEioSlugDir, `${finderEioId}.jsonl`);
  writeFileSync(finderEioTrPath, '{"role":"user","text":"finder-eio-keep"}\n');
  const finderEioRoom = join(s.data, "sessions", "chat", "chat:claude-finder-eio", "workspace");
  mkdirSync(finderEioRoom, { recursive: true });
  s.store.insertSession({
    key: "chat:claude-finder-eio",
    connect: "chat",
    runtime: "claude",
    profile: "cc",
    workspace: finderEioRoom,
    token: "tok-cc-finder-eio",
    createdAt: 2,
    lastActiveAt: 2,
    ws: null,
  });
  s.store.setRuntimeSessionId("chat:claude-finder-eio", finderEioId);
  const tFinderEio = s.store.openThread("chat", "C", "ts-cc-finder-eio", "Claude Finder EIO", "p@x").id;
  s.store.joinThread(tFinderEio, "chat:claude-finder-eio", "chat");

  // Sibling dir notes2 to verify strict directory boundary matching (notes vs notes2)
  const notesDir = join(s.brain, "notes");
  const notes2File = join(s.brain, "notes2", "sibling.txt");
  mkdirSync(join(notes2File, ".."), { recursive: true });
  writeFileSync(notes2File, "sibling content\n");

  const taskPath = join(s.brain, "task.md");
  const notesFile = join(s.brain, "notes", "scratch", "b.txt");
  const annPath = join(s.cli, "annotations", `${s.agyId}.pbtxt`);

  const readStatePaths = (replica: string) => {
    const db = new DatabaseSync(join(replica, "export.db"), { readOnly: true });
    try {
      return db.prepare("SELECT path, chunks_json FROM transcript_files ORDER BY path").all() as { path: string; chunks_json: string }[];
    } finally {
      db.close();
    }
  };

  type FaultSpec = {
    lstat_err?: string[];
    readdir_err?: string[];
    finder_readdir_err?: string[];
    forbid_readdir?: string[];
    read_short?: string[];
    read_short_after_first?: string[];
    other_kind?: string[];
  };

  const runDeterministicSuite = async (mode: "ts" | "mb") => {
    const replica = join(s.data, `replica-faults-${mode}`);
    let activeFaults: FaultSpec = {};
    const readdirVisited = new Set<string>();
    let exporter: Exporter | null = null;
    let mb: Awaited<ReturnType<typeof makeMbExportHelper>> | null = null;
    if (mode === "ts") {
      exporter = new Exporter({
        db: s.db,
        replica,
        dataDir: s.data,
        origin: originId,
        now: () => now,
        chunkBytes: 16,
        testFaults: {
          onReaddir: (d) => {
            readdirVisited.add(d);
            if (activeFaults.forbid_readdir?.includes(d)) throw new Error(`BUG: descended into forbidden directory ${d}`);
          },
          lstatError: (p) => (activeFaults.lstat_err?.includes(p) ? mkErr("EIO") : null),
          readdirError: (d) => (activeFaults.readdir_err?.includes(d) ? mkErr("EACCES") : null),
          finderReaddirError: (d) => (activeFaults.finder_readdir_err?.includes(d) ? mkErr("EIO") : null),
          readShort: (p, offset) =>
            Boolean(activeFaults.read_short?.includes(p) || (offset > 0 && activeFaults.read_short_after_first?.includes(p))),
          otherKind: (p) => Boolean(activeFaults.other_kind?.includes(p)),
        },
      });
      closing.push(async () => exporter?.close());
      exporter.setPlaces({ home: HOME, workspaces: [{ workspace: HOME, name: "src" }] });
    } else {
      mb = await makeMbExportHelper(s.db, replica, s.data, originId, 16);
      await mb.places(now);
    }
    const setFaults = async (f: FaultSpec) => {
      activeFaults = f;
      if (mb !== null) await mb.testFaults(f, now);
    };
    const pass = async (told: ReturnType<typeof nothingTold>) =>
      exporter !== null ? exporter.pass(told) : mb!.pass(told, now);

    // Ensure notes2File, annPath, taskPath, and finderEioTrPath start from clean baseline for this mode run
    mkdirSync(join(notes2File, ".."), { recursive: true });
    writeFileSync(notes2File, "sibling content\n");
    writeFileSync(annPath, `content:${annPath}\n`);
    writeFileSync(taskPath, `content:${taskPath}\n`);
    utimesSync(taskPath, new Date(now), new Date(now));
    writeFileSync(finderEioTrPath, '{"role":"user","text":"finder-eio-keep"}\n');
    utimesSync(finderEioTrPath, new Date(now), new Date(now));

    // Baseline export
    await pass(nothingTold());
    const baseline = readStatePaths(replica);
    assert.ok(baseline.some((r) => r.path === notes2File));
    assert.ok(baseline.some((r) => r.path === claudeSubPath));

    // (a) brain root lstat EIO -> all brain files preserved, 0 tr_del
    now += 10_000;
    await setFaults({ lstat_err: [s.brain] });
    const pRoot = await pass({ ...nothingTold(), transcripts: true });
    assert.equal(pRoot.wrote, 0, `${mode}: brain root lstat EIO emits no tr_del`);
    assert.deepEqual(readStatePaths(replica), baseline);

    // (b) claude subdir readdir EACCES -> claudeSubPath preserved
    now += 10_000;
    await setFaults({ readdir_err: [claudeSubDir] });
    const pClaude = await pass({ ...nothingTold(), transcripts: true });
    assert.equal(pClaude.wrote, 0, `${mode}: claude subdir EACCES preserves subagent transcript`);
    assert.ok(readStatePaths(replica).some((r) => r.path === claudeSubPath));

    // (c) subdir readdir EACCES on `notes` while `notes2/sibling.txt` is genuinely deleted (ENOENT)
    now += 10_000;
    await setFaults({ readdir_err: [notesDir] });
    rmSync(notes2File);
    const pSub = await pass({ ...nothingTold(), transcripts: true });
    assert.equal(pSub.wrote, 1);
    const afterSub = readStatePaths(replica);
    assert.ok(afterSub.some((r) => r.path === notesFile), `${mode}: unreadable subdir preserves its files`);
    assert.ok(!afterSub.some((r) => r.path === notes2File), `${mode}: strict dir boundary allows genuine ENOENT sibling tr_del`);

    // (d) single file lstat EIO -> preserved; confirmed ENOENT -> normal tr_del
    now += 10_000;
    await setFaults({ lstat_err: [annPath] });
    const pLstat = await pass({ ...nothingTold(), transcripts: true });
    assert.equal(pLstat.wrote, 0, `${mode}: file lstat EIO preserves row`);
    assert.ok(readStatePaths(replica).some((r) => r.path === annPath));

    now += 10_000;
    await setFaults({});
    rmSync(annPath);
    const pEnoent = await pass({ ...nothingTold(), transcripts: true });
    assert.equal(pEnoent.wrote, 1);
    assert.ok(!readStatePaths(replica).some((r) => r.path === annPath), `${mode}: confirmed ENOENT emits tr_del`);

    // (e) Discovery-stage parent dir unreadable (e.g. chmod 0o111 on parent dir while file exists on disk):
    // Simulate a file not discovered in `active` whose parent dir fails `readdir` -> tr_del double-check preserves it!
    now += 10_000;
    const orphanDir = join(s.brain, "unlisted-parent");
    const orphanFile = join(orphanDir, "keep.md");
    mkdirSync(orphanDir, { recursive: true });
    writeFileSync(orphanFile, "keep-me\n");
    await pass({ ...nothingTold(), transcripts: true });
    assert.ok(readStatePaths(replica).some((r) => r.path === orphanFile));
    now += 10_000;
    // Inject readdir_err on orphanDir so walk skips it AND tr_del parent check sees unreadable parent
    await setFaults({ readdir_err: [orphanDir] });
    const pParentUnreadable = await pass({ ...nothingTold(), transcripts: true });
    assert.equal(pParentUnreadable.wrote, 0, `${mode}: unreadable parent dir protects file from tr_del`);
    assert.ok(readStatePaths(replica).some((r) => r.path === orphanFile));
    await setFaults({});

    // (f) Fresh file short read (offset 0) -> never commits half record or emits tr
    now += 10_000;
    const freshFile = join(s.brain, "fresh-short.md");
    writeFileSync(freshFile, "brand-new-file-content-that-fails-at-offset-0\n");
    await setFaults({ read_short: [freshFile] });
    const pFreshShort = await pass({ ...nothingTold(), transcripts: true });
    assert.equal(pFreshShort.wrote, 0, `${mode}: fresh file short read must not commit`);
    assert.ok(!readStatePaths(replica).some((r) => r.path === freshFile));
    await setFaults({});
    rmSync(freshFile);

    // (g) Existing file mid-stream short read (offset > 0) -> preserves old row, emits no tr/tr_del
    now += 10_000;
    const prevTaskRow = readStatePaths(replica).find((r) => r.path === taskPath)!;
    writeFileSync(taskPath, "0123456789abcdef_second_chunk_that_will_short_read\n");
    utimesSync(taskPath, new Date(now), new Date(now));
    await setFaults({ read_short_after_first: [taskPath] });
    const pMidShort = await pass({ ...nothingTold(), transcripts: true });
    assert.equal(pMidShort.wrote, 0, `${mode}: mid-stream short read preserves old row`);
    assert.deepEqual(readStatePaths(replica).find((r) => r.path === taskPath), prevTaskRow);
    await setFaults({});
    now += 10_000;
    const pRecover = await pass({ ...nothingTold(), transcripts: true });
    assert.equal(pRecover.wrote, 1);
    assert.notDeepEqual(readStatePaths(replica).find((r) => r.path === taskPath), prevTaskRow);

    // (h) R2: `other` dirent kind -> lstat dispatch exports file & dir, enforces brain pruning, protects lstat_err
    now += 10_000;
    const otherFile = join(s.brain, "other-file.md");
    const otherDir = join(s.brain, "other-dir");
    const otherInside = join(otherDir, "inside.md");
    const otherBad = join(s.brain, "other-bad.md");
    const scratchDir = join(s.brain, "scratch");
    mkdirSync(otherDir, { recursive: true });
    writeFileSync(otherBad, "other-bad-keep\n");
    await pass({ ...nothingTold(), transcripts: true });
    assert.ok(readStatePaths(replica).some((r) => r.path === otherBad));

    now += 10_000;
    writeFileSync(otherFile, "other-file-content\n");
    writeFileSync(otherInside, "other-dir-inside-content\n");
    readdirVisited.clear();
    await setFaults({
      other_kind: [otherFile, otherDir, otherBad, scratchDir],
      lstat_err: [otherBad],
      forbid_readdir: [scratchDir],
    });
    const pOther = await pass({ ...nothingTold(), transcripts: true });
    assert.equal(pOther.wrote, 1);
    if (mode === "ts") {
      assert.equal(readdirVisited.has(scratchDir), false, "TS: other-kind scratch dir must have 0 readdir visits");
    }
    const afterOther = readStatePaths(replica);
    assert.ok(afterOther.some((r) => r.path === otherFile), `${mode}: other-kind file exported via lstat dispatch`);
    assert.ok(afterOther.some((r) => r.path === otherInside), `${mode}: other-kind dir recursed via lstat dispatch`);
    assert.ok(afterOther.some((r) => r.path === otherBad), `${mode}: other-kind lstat_err preserved without tr_del`);
    await setFaults({});
    rmSync(otherFile);
    rmSync(otherDir, { recursive: true, force: true });
    rmSync(otherBad);
    now += 10_000;
    await pass({ ...nothingTold(), transcripts: true });

    // (i) R2: previously backed-up dir replaced with symlink to external dir -> emits tr_del and NEVER follows/probes external target
    now += 10_000;
    const swapDir = join(s.brain, "swapdir");
    const swapFile = join(swapDir, "a.txt");
    mkdirSync(swapDir, { recursive: true });
    writeFileSync(swapFile, "real-dir-content\n");
    await pass({ ...nothingTold(), transcripts: true });
    assert.ok(readStatePaths(replica).some((r) => r.path === swapFile));

    now += 10_000;
    rmSync(swapDir, { recursive: true, force: true });
    const extTarget = dataDir(`d71-swap-ext-${mode}`);
    writeFileSync(join(extTarget, "a.txt"), "external-secret\n");
    symlinkSync(extTarget, swapDir);
    readdirVisited.clear();
    await setFaults({ readdir_err: [extTarget, swapDir], forbid_readdir: [extTarget, swapDir] });
    const pSwap = await pass({ ...nothingTold(), transcripts: true });
    assert.equal(pSwap.wrote, 1);
    if (mode === "ts") {
      assert.equal(readdirVisited.has(extTarget), false, "TS: symlink external target must have 0 readdir visits");
      assert.equal(readdirVisited.has(swapDir), false, "TS: symlinked dir must have 0 readdir visits");
    }
    assert.ok(!readStatePaths(replica).some((r) => r.path === swapFile), `${mode}: dir replaced by symlink emits tr_del without following target`);
    await setFaults({});
    rmSync(swapDir, { force: true });

    // (j) R3/R4: Finder opendir succeeds (dir is 0o755!) but mid-iteration readdir hits EIO -> ONLY Finder failed_dirs
    //     saves existing Claude transcript (dir_unreadable_checked sees 0o755 as readable!) -> 0 tr_del (root-safe, TS + MB);
    //     then clear fault + append new content -> re-discovered and exported (proves no poisoned `elsewhere` negative cache!)
    const prevFinderRow = readStatePaths(replica).find((r) => r.path === finderEioTrPath)!;
    assert.ok(prevFinderRow, `${mode}: baseline has finderEioTrPath`);
    resetTranscriptLocateCache();
    now += 10_000;
    await setFaults({ finder_readdir_err: [claudeProjectsDir] });
    const pFinderEio = await pass({ ...nothingTold(), transcripts: true });
    assert.equal(pFinderEio.wrote, 0, `${mode}: Finder mid-iteration EIO on 0o755 dir preserves transcript with 0 tr_del`);
    assert.deepEqual(readStatePaths(replica).find((r) => r.path === finderEioTrPath), prevFinderRow);

    await setFaults({});
    now += 10_000;
    writeFileSync(finderEioTrPath, `{"role":"user","text":"finder-eio-keep"}\n{"role":"assistant","text":"recovered-after-eio-${mode}"}\n`);
    utimesSync(finderEioTrPath, new Date(now), new Date(now));
    const pFinderRecover = await pass({ ...nothingTold(), transcripts: true });
    assert.equal(pFinderRecover.wrote, 1, `${mode}: recovery pass after Finder EIO re-discovers and exports appended content`);
    const recoveredFinderRow = readStatePaths(replica).find((r) => r.path === finderEioTrPath)!;
    assert.ok(recoveredFinderRow, `${mode}: finderEioTrPath retained after recovery`);
    assert.notEqual(recoveredFinderRow.chunks_json, prevFinderRow.chunks_json, `${mode}: appended content exported (no poisoned negative cache)`);

    // (k) R4: two workspaces in the SAME pass sharing the same Claude runtime ID (both scanning `transcripts/claude`):
    //     injecting `finder_readdir_err` must preserve BOTH workspaces' rows with 0 tr_del (no negative-cache short-circuit on 2nd ws)
    const ws2Key = `chat:claude-finder-eio-ws2-${mode}`;
    const ws2Room = join(s.data, "sessions", "chat", ws2Key, "workspace");
    mkdirSync(ws2Room, { recursive: true });
    s.store.insertSession({
      key: ws2Key,
      connect: "chat",
      runtime: "claude",
      profile: "cc",
      workspace: ws2Room,
      token: `tok-${ws2Key}`,
      createdAt: 4,
      lastActiveAt: 4,
      ws: OTHER,
    });
    s.store.setRuntimeSessionId(ws2Key, finderEioId);
    const tWs2 = s.store.openThread("chat", "C", `ts-${ws2Key}`, "Claude Finder WS2", "p@x").id;
    s.store.joinThread(tWs2, ws2Key, "chat");
    const twoWsList = [
      { workspace: HOME, name: "src" },
      { workspace: OTHER, name: "other" },
    ];
    if (exporter !== null) exporter.setPlaces({ home: HOME, workspaces: twoWsList });
    else await mb!.places(now, twoWsList);

    const readWsRows = (ws: string) => {
      const db = new DatabaseSync(join(replica, "export.db"), { readOnly: true });
      try {
        return db.prepare("SELECT path, chunks_json FROM transcript_files WHERE ws = ? ORDER BY path").all(ws) as { path: string; chunks_json: string }[];
      } finally {
        db.close();
      }
    };
    resetTranscriptLocateCache();
    now += 10_000;
    await pass({ ...nothingTold(), transcripts: true });
    assert.ok(readWsRows(HOME).some((r) => r.path === finderEioTrPath), `${mode}: HOME has shared Claude transcript`);
    assert.ok(readWsRows(OTHER).some((r) => r.path === finderEioTrPath), `${mode}: OTHER has shared Claude transcript`);

    resetTranscriptLocateCache();
    now += 10_000;
    await setFaults({ finder_readdir_err: [claudeProjectsDir] });
    const pTwoWsEio = await pass({ ...nothingTold(), transcripts: true });
    assert.equal(pTwoWsEio.wrote, 0, `${mode}: shared Claude ID across 2 workspaces emits 0 tr_del on Finder EIO`);
    assert.ok(readWsRows(HOME).some((r) => r.path === finderEioTrPath), `${mode}: HOME row preserved`);
    assert.ok(readWsRows(OTHER).some((r) => r.path === finderEioTrPath), `${mode}: OTHER row preserved (no negative-cache skip)`);
    await setFaults({});
    if (exporter !== null) exporter.setPlaces({ home: HOME, workspaces: [{ workspace: HOME, name: "src" }] });
    else await mb!.places(now);
  };

  await runDeterministicSuite("ts");
  if (binary !== null) {
    await runDeterministicSuite("mb");
  }

  // Real OS EACCES check on non-root systems (Linux CI / pvg-office-1), including Finder discovery-stage chmod 0o111!
  if (typeof process.getuid === "function" && process.getuid() !== 0) {
    // Dedicated Claude session whose transcript is discovered via Finder scanning `transcripts/claude/` (cwd != slug)
    const finderClaudeId = "cc-finder-0111";
    const finderSlugDir = join(s.data, "transcripts", "claude", "-other-project-slug");
    const finderProjectsDir = join(s.data, "transcripts", "claude");
    mkdirSync(finderSlugDir, { recursive: true });
    const finderTrPath = join(finderSlugDir, `${finderClaudeId}.jsonl`);
    writeFileSync(finderTrPath, '{"role":"user","text":"finder-0111-keep"}\n');
    const finderRoom = join(s.data, "sessions", "chat", "chat:claude-finder", "workspace");
    mkdirSync(finderRoom, { recursive: true });
    s.store.insertSession({
      key: "chat:claude-finder",
      connect: "chat",
      runtime: "claude",
      profile: "cc",
      workspace: finderRoom,
      token: "tok-cc-finder",
      createdAt: 3,
      lastActiveAt: 3,
      ws: null,
    });
    s.store.setRuntimeSessionId("chat:claude-finder", finderClaudeId);
    const tFinder = s.store.openThread("chat", "C", "ts-cc-finder", "Claude Finder", "p@x").id;
    s.store.joinThread(tFinder, "chat:claude-finder", "chat");

    // Verify Finder discovery-stage chmod 0o111 (execute-only, not readable) protects finderTrPath in BOTH TS and MB!
    const replicaOsTs = join(s.data, "replica-faults-os-ts");
    const expOsTs = new Exporter({
      db: s.db,
      replica: replicaOsTs,
      dataDir: s.data,
      origin: originId,
      now: () => now,
      chunkBytes: 16,
    });
    closing.push(async () => expOsTs.close());
    expOsTs.setPlaces({ home: HOME, workspaces: [{ workspace: HOME, name: "src" }] });
    expOsTs.pass(nothingTold());
    assert.ok(readStatePaths(replicaOsTs).some((r) => r.path === finderTrPath), "TS baseline has Finder-discovered Claude transcript");

    const replicaOsMb = join(s.data, "replica-faults-os-mb");
    const mb = binary !== null ? await makeMbExportHelper(s.db, replicaOsMb, s.data, originId, 16) : null;
    if (mb !== null) {
      await mb.places(now);
      await mb.pass(nothingTold(), now);
      assert.ok(readStatePaths(replicaOsMb).some((r) => r.path === finderTrPath), "MB baseline has Finder-discovered Claude transcript");
    }

    const convDir = join(s.cli, "conversations");
    const dbPath = join(convDir, `${s.agyId}.db`);
    try {
      // Clear TS `elsewhere` cache so Finder must actually readdir `transcripts/claude` (no stale cache hit!)
      resetTranscriptLocateCache();
      // chmod 0o111 on `transcripts/claude` (Finder's scan dir!): lstat on <slug> and <id>.jsonl SUCCEEDS,
      // Finder's readdir FAILS, so ONLY Finder failed_dirs + ancestor dir readability check saves finderTrPath from tr_del!
      chmodSync(finderProjectsDir, 0o111);
      now += 10_000;
      assert.equal(expOsTs.pass({ ...nothingTold(), transcripts: true }).wrote, 0, "TS: chmod 0o111 on Finder projects dir preserves transcript");
      assert.ok(readStatePaths(replicaOsTs).some((r) => r.path === finderTrPath));
      if (mb !== null) {
        assert.equal((await mb.pass({ ...nothingTold(), transcripts: true }, now)).wrote, 0, "MB: chmod 0o111 on Finder projects dir preserves transcript");
        assert.ok(readStatePaths(replicaOsMb).some((r) => r.path === finderTrPath));
      }
      chmodSync(finderProjectsDir, 0o755);

      if (mb !== null) {
        chmodSync(notesDir, 0o000);
        now += 10_000;
        assert.equal((await mb.pass({ ...nothingTold(), transcripts: true }, now)).wrote, 0);
        assert.ok(readStatePaths(replicaOsMb).some((r) => r.path === notesFile));
        chmodSync(notesDir, 0o755);

        chmodSync(convDir, 0o000);
        now += 10_000;
        assert.equal((await mb.pass({ ...nothingTold(), transcripts: true }, now)).wrote, 0);
        assert.ok(readStatePaths(replicaOsMb).some((r) => r.path === dbPath));
        chmodSync(convDir, 0o755);
      }
    } finally {
      try { chmodSync(finderProjectsDir, 0o755); } catch {}
      try { chmodSync(notesDir, 0o755); } catch {}
      try { chmodSync(convDir, 0o755); } catch {}
    }
  }
});

test("D71: tr_del batch throttling shares budget across multiple workspaces (ws1 + ws2) with TS/MoonBit 0-diff", async () => {
  const s = makeAgyBrainStation();
  closing.push(async () => s.store.close());
  let now = 1_700_000_000_000;
  const originId = sid("a");

  // Second AGY session in workspace OTHER
  const agyId2 = "agy-brain-other-ws";
  const room2 = join(s.data, "sessions", "chat", "chat:agy-other", "workspace");
  mkdirSync(room2, { recursive: true });
  s.store.insertSession({
    key: "chat:agy-other",
    connect: "chat",
    runtime: "agy",
    profile: "agyprof",
    workspace: room2,
    token: "tok-agy-other",
    createdAt: 2,
    lastActiveAt: 2,
    ws: OTHER,
  });
  s.store.setRuntimeSessionId("chat:agy-other", agyId2);
  const t2 = s.store.openThread("chat", "C", "ts-agy-other", "AGY Other", "p@x").id;
  s.store.joinThread(t2, "chat:agy-other", "chat");

  // ws1 (HOME): 2 stale files; ws2 (OTHER): 3 stale files; budget = 3 -> pass 1 deletes 3 total (more:true), pass 2 deletes 2 (more:false)
  const ws1Files: string[] = [];
  for (let i = 1; i <= 2; i++) {
    const p = join(s.brain, "extra1", `a${i}.txt`);
    mkdirSync(join(p, ".."), { recursive: true });
    writeFileSync(p, `ws1-${i}\n`);
    ws1Files.push(p);
  }
  const brain2 = join(s.cli, "brain", agyId2);
  const ws2Keep = join(brain2, "keep.md");
  mkdirSync(brain2, { recursive: true });
  writeFileSync(ws2Keep, "keep\n");
  const ws2Files: string[] = [];
  for (let i = 1; i <= 3; i++) {
    const p = join(brain2, "extra2", `b${i}.txt`);
    mkdirSync(join(p, ".."), { recursive: true });
    writeFileSync(p, `ws2-${i}\n`);
    ws2Files.push(p);
  }

  const wsList = [
    { workspace: HOME, name: "home" },
    { workspace: OTHER, name: "other" },
  ];
  const replicaTs = join(s.data, "replica-multiws-ts");
  const exporter = new Exporter({
    db: s.db,
    replica: replicaTs,
    dataDir: s.data,
    origin: originId,
    now: () => now,
    chunkBytes: 4096,
    transcriptPassDeletes: 3,
    fold: false,
  });
  closing.push(async () => exporter.close());
  exporter.setPlaces({ home: HOME, workspaces: wsList });
  exporter.pass(nothingTold());

  const replicaMb = join(s.data, "replica-multiws-mb");
  const mb = binary !== null
    ? await makeMbExportHelper(s.db, replicaMb, s.data, originId, 4096, ["--transcript-pass-deletes", "3", "--no-fold"])
    : null;
  if (mb !== null) {
    await mb.places(now, wsList);
    await mb.pass(nothingTold(), now);
  }

  for (const p of [...ws1Files, ...ws2Files]) rmSync(p);

  const countAll = (replica: string) => {
    const db = new DatabaseSync(join(replica, "export.db"), { readOnly: true });
    try {
      return (db.prepare("SELECT COUNT(*) AS n FROM transcript_files").get() as { n: number }).n;
    } finally {
      db.close();
    }
  };
  const baseKeep = s.keptFiles.length + 1; // +1 for ws2Keep
  assert.equal(countAll(replicaTs), baseKeep + 5);

  now += 10_000;
  const p1Ts = exporter.pass({ ...nothingTold(), transcripts: true });
  assert.equal(p1Ts.more, true, "TS pass 1 hits shared budget=3 across ws1+ws2");
  assert.equal(countAll(replicaTs), baseKeep + 2, "TS pass 1 deleted exactly 3 across workspaces");

  now += 10_000;
  const p2Ts = exporter.pass(nothingTold());
  assert.equal(p2Ts.more, false, "TS pass 2 drains remaining 2");
  assert.equal(countAll(replicaTs), baseKeep);

  if (mb !== null) {
    const p1Mb = await mb.pass({ ...nothingTold(), transcripts: true }, now - 10_000);
    assert.equal(p1Mb.more, true, "MB pass 1 hits shared budget=3 across ws1+ws2");
    assert.equal(countAll(replicaMb), baseKeep + 2, "MB pass 1 deleted exactly 3 across workspaces");
    const p2Mb = await mb.pass(nothingTold(), now);
    assert.equal(p2Mb.more, false, "MB pass 2 drains remaining 2");
    assert.equal(countAll(replicaMb), baseKeep);
  }
});

test("D71: tr_del batch throttling drains 7 stale records in 3 passes (3 + 3 + 1) with TS/MoonBit 0-diff", async () => {
  const s = makeAgyBrainStation();
  closing.push(async () => s.store.close());
  let now = 1_700_000_000_000;
  const originId = sid("a");

  // Create 7 extra files under brain/<id>/extra/
  const extraFiles: string[] = [];
  const extraDir = join(s.brain, "extra");
  mkdirSync(extraDir, { recursive: true });
  for (let i = 1; i <= 7; i++) {
    const p = join(extraDir, `f${i}.txt`);
    writeFileSync(p, `extra-${i}\n`);
    extraFiles.push(p);
  }

  const replicaTs = join(s.data, "replica-del-ts");
  const exporter = new Exporter({
    db: s.db,
    replica: replicaTs,
    dataDir: s.data,
    origin: originId,
    now: () => now,
    chunkBytes: 4096,
    transcriptPassDeletes: 3,
    fold: false,
  });
  closing.push(async () => exporter.close());
  exporter.setPlaces({ home: HOME, workspaces: [{ workspace: HOME, name: "src" }] });
  exporter.pass(nothingTold());

  const replicaMb = join(s.data, "replica-del-mb");
  const mb = binary !== null
    ? await makeMbExportHelper(s.db, replicaMb, s.data, originId, 4096, ["--transcript-pass-deletes", "3", "--no-fold"])
    : null;
  if (mb !== null) {
    await mb.places(now);
    await mb.pass(nothingTold(), now);
  }

  const countStateRows = (replica: string) => {
    const db = new DatabaseSync(join(replica, "export.db"), { readOnly: true });
    try {
      return (db.prepare("SELECT COUNT(*) AS n FROM transcript_files").get() as { n: number }).n;
    } finally {
      db.close();
    }
  };
  const initialCount = countStateRows(replicaTs);
  assert.equal(initialCount, s.keptFiles.length + 7);

  // Delete all 7 extra files -> must drain in 3 passes: 3 (more:true), 3 (more:true), 1 (more:false)
  for (const p of extraFiles) rmSync(p);

  const trDelsInLatestBatch = (replica: string, head: any) => {
    const genDir = join(replica, "own", HOME, head.gen);
    const last = head.batches[head.batches.length - 1]!;
    return [...decodeBatch(readFileSync(join(genDir, "log", last))).lines]
      .map((l) => JSON.parse(l))
      .filter((r) => "tr_del" in r)
      .map((r) => r.tr_del as string);
  };

  const tsPerPass: string[][] = [];
  const mbPerPass: string[][] = [];
  const expectedRemaining = [s.keptFiles.length + 4, s.keptFiles.length + 1, s.keptFiles.length];
  for (let round = 1; round <= 3; round++) {
    now += 10_000;
    const pTs = exporter.pass(round === 1 ? { ...nothingTold(), transcripts: true } : nothingTold());
    assert.equal(pTs.more, round < 3, `TS pass ${round}: expected more=${round < 3}`);
    assert.equal(countStateRows(replicaTs), expectedRemaining[round - 1], `TS pass ${round} remaining rows`);
    tsPerPass.push(trDelsInLatestBatch(replicaTs, pTs.heads[HOME]!));

    if (mb !== null) {
      const pMb = await mb.pass(round === 1 ? { ...nothingTold(), transcripts: true } : nothingTold(), now);
      assert.equal(pMb.more, round < 3, `MB pass ${round}: expected more=${round < 3}`);
      assert.equal(countStateRows(replicaMb), expectedRemaining[round - 1], `MB pass ${round} remaining rows`);
      mbPerPass.push(trDelsInLatestBatch(replicaMb, pMb.heads[HOME]!));
    }
  }
  assert.deepEqual(tsPerPass.map((x) => x.length), [3, 3, 1], "TS deletes 3 + 3 + 1");
  assert.deepEqual(tsPerPass.flat().sort(), [...extraFiles].sort());
  if (mb !== null) {
    assert.deepEqual(mbPerPass, tsPerPass, "MoonBit and TS reference emit identical tr_del batches pass by pass");
  }
});

/// Exports `s` to `replica` until it is caught up, in the TS reference (`mode: "ts"`) or the MoonBit reader, a new
/// exporter each call (as a station's start): the rounds it took, none past `most`.
async function exportCaughtUp(mode: "ts" | "mb", s: { db: string; data: string }, replica: string, now: number, most: number) {
  const originId = sid("a");
  const rounds: { more: boolean; read: number }[] = [];
  if (mode === "ts") {
    const exporter = new Exporter({ db: s.db, replica, dataDir: s.data, origin: originId, now: () => now, chunkBytes: 4096, fold: false });
    try {
      exporter.setPlaces({ home: HOME, workspaces: [{ workspace: HOME, name: "src" }] });
      for (let i = 0; i < most; i++) {
        const p = exporter.pass(nothingTold());
        rounds.push({ more: p.more, read: p.read });
        if (!p.more) break;
      }
    } finally {
      exporter.close();
    }
  } else {
    const mb = await makeMbExportHelper(s.db, replica, s.data, originId, 4096, ["--no-fold"]);
    try {
      await mb.places(now);
      for (let i = 0; i < most; i++) {
        const p = await mb.pass(nothingTold(), now);
        rounds.push({ more: p.more, read: p.read });
        if (!p.more) break;
      }
    } finally {
      await mb.close(now);
    }
  }
  return rounds;
}

test("D75: more sessions than PASS_ROWS no longer starve the logs and transcripts of every pass (TS + MoonBit)", async () => {
  const s = makeAgyBrainStation();
  closing.push(async () => s.store.close());
  const now = 1_700_000_000_000;
  const modes: ("ts" | "mb")[] = binary !== null ? ["ts", "mb"] : ["ts"];
  const replicaOf = (mode: "ts" | "mb") => join(s.data, `replica-d75-${mode}`);
  // A first export, caught up, by an exporter from before D71: it still holds a derived cache file of the brain.
  const steps = s.prunedFiles.find((p) => p.includes(`${sep}steps${sep}`))!;
  for (const mode of modes) {
    assert.equal((await exportCaughtUp(mode, s, replicaOf(mode), now, 5)).at(-1)!.more, false);
    const state = new DatabaseSync(join(replicaOf(mode), "export.db"), { timeout: 5000 });
    try {
      state.prepare("INSERT INTO transcript_files (ws, path, room, size, mtime, mode, chunks_json) VALUES (?, ?, NULL, 1, 1, 420, '[]')").run(HOME, steps);
    } finally {
      state.close();
    }
  }

  // Then 3,000 sessions and 3,000 runtime sessions (6,000 rows > PASS_ROWS), and logs to export behind them.
  const raw = new DatabaseSync(s.db, { timeout: 5000 });
  try {
    const cols = (raw.prepare("PRAGMA table_info(sessions)").all() as { name: string }[]).map((c) => c.name);
    const picked = cols.map((c) => (c === "key" ? "'bulk:' || n" : c === "token" ? "'tok-bulk-' || n" : c === "runtime_session_id" ? "NULL" : c));
    raw.exec("BEGIN IMMEDIATE");
    raw.exec(`WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 3000)
      INSERT INTO sessions (${cols.join(", ")}) SELECT ${picked.join(", ")} FROM seq, sessions WHERE key = 'chat:agy-d71'`);
    raw.exec(`WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 3000)
      INSERT INTO runtime_sessions (session_key, id, profile, at, runtime) SELECT 'bulk:' || n, 'bulk-rt-' || n, 'agyprof', n, 'agy' FROM seq`);
    raw.exec("COMMIT");
  } finally {
    raw.close();
  }
  const t2 = s.store.openThread("chat", "C", "ts-d75", "D75", "p@x").id;
  s.store.joinThread(t2, "chat:agy-d71", "chat");
  for (let i = 0; i < 600; i++) s.store.insertMessage({ thread: t2, ts: `d75.${i}`, authorKind: "person", author: "p@x", text: `backlog ${i}` });
  for (let i = 0; i < 3; i++) s.store.insertLetter({ thread: t2, ts: `d75l.${i}`, authorKind: "person", author: "u", text: `letter ${i}`, letter: { way: "in", title: "another", link: null } });
  s.store.startTurn("turn-d75", "chat:agy-d71", "message");
  s.store.endTurn("turn-d75", "done", null, null, null);

  const one = (db: string, sql: string) => {
    const d = new DatabaseSync(db, { readOnly: true });
    try {
      return d.prepare(sql).get() as Record<string, unknown>;
    } finally {
      d.close();
    }
  };
  const maxOf = (table: string) => Number(one(s.db, `SELECT MAX(rowid) AS m FROM ${table}`).m);
  const roundsBy: Record<string, number> = {};
  for (const mode of modes) {
    const replica = replicaOf(mode);
    const rounds = await exportCaughtUp(mode, s, replica, now + 10_000, 25);
    assert.equal(rounds.at(-1)!.more, false, `${mode}: caught up within 25 passes (rounds: ${JSON.stringify(rounds)})`);
    assert.equal(rounds[0]!.more, true, `${mode}: the first pass ran out of its rows on the sessions alone`);
    assert.ok(rounds.slice(1).every((r) => r.read < 5000), `${mode}: later passes do not read the sessions again in their budget`);
    roundsBy[mode] = rounds.length;
    const state = join(replica, "export.db");
    for (const k of ["entries", "letters", "turns"]) {
      assert.equal(Number(one(state, `SELECT v FROM meta WHERE k = '${k}'`).v), maxOf(k), `${mode}: ${k} exported to the end`);
    }
    assert.equal(Number(one(state, "SELECT COUNT(*) AS n FROM entering").n), 0, `${mode}: no thread left entering`);
    const d = new DatabaseSync(state, { readOnly: true });
    let paths: string[];
    try {
      paths = (d.prepare("SELECT path FROM transcript_files").all() as { path: string }[]).map((r) => r.path);
    } finally {
      d.close();
    }
    for (const kept of s.keptFiles) assert.ok(paths.includes(kept), `${mode}: transcript ${kept} exported`);
    assert.ok(!paths.includes(steps), `${mode}: the derived cache record is dropped`);
    const gen = String(one(state, `SELECT v FROM meta WHERE k = 'gen:${HOME}'`).v);
    const log = join(replica, "own", HOME, gen, "log");
    const records = readdirSync(log)
      .filter((b) => !b.endsWith(".writing"))
      .flatMap((b) => [...decodeBatch(readFileSync(join(log, b))).lines].map((l) => JSON.parse(l) as Record<string, unknown>));
    assert.ok(records.some((r) => r.tr_del === steps), `${mode}: tr_del sent for the derived cache record`);
    assert.equal(records.filter((r) => r.r === "entries" && (r.row as { thread?: number }).thread === t2).length, 600, `${mode}: the backlog's entries exported`);
  }
  if (roundsBy.mb !== undefined) assert.equal(roundsBy.mb, roundsBy.ts, "MoonBit and the TS reference take the same passes");
});

test("D75: MoonBit exporter parses head.json again only when its size or mtime changed, and never across generations", { skip: skipMb }, async () => {
  const s = makeAgyBrainStation();
  closing.push(async () => s.store.close());
  let now = 1_700_000_000_000;
  const replica = join(s.data, "replica-d75-head");
  const mb = await makeMbExportHelper(s.db, replica, s.data, sid("a"), 4096);
  await mb.places(now);
  let p = await mb.pass(nothingTold(), now);
  while (p.more) p = await mb.pass(nothingTold(), now);
  const gen = String(p.heads[HOME].gen);
  const headPath = join(replica, "own", HOME, gen, "head.json");
  const written = readFileSync(headPath, "utf8");
  const quiet = async () => (await mb.pass(nothingTold(), (now += 1_000))).heads[HOME];
  assert.deepEqual(await quiet(), JSON.parse(written), "a quiet pass answers the head as written");

  // The same size and mtime: the head kept is answered, the file is not parsed again.
  const at = new Date(1_700_000_100_000);
  utimesSync(headPath, at, at);
  assert.equal((await quiet()).name, "src", "a changed mtime reads the file again");
  const changed = written.replace(/"name":(\s*)"src"/, '"name":$1"srX"');
  assert.notEqual(changed, written);
  assert.equal(Buffer.byteLength(changed), Buffer.byteLength(written));
  writeFileSync(headPath, changed);
  utimesSync(headPath, at, at);
  assert.equal((await quiet()).name, "src", "same size and mtime: answered from the head kept");

  // Its mtime moved: read again, as it is on disk now.
  const later = new Date(1_700_000_200_000);
  utimesSync(headPath, later, later);
  assert.equal((await quiet()).name, "srX", "a moved mtime reads the file again");
  // A different size at the same mtime: read again.
  const longer = written.replace(/"name":(\s*)"src"/, '"name":$1"srcXY"');
  writeFileSync(headPath, longer);
  utimesSync(headPath, later, later);
  assert.equal((await quiet()).name, "srcXY", "a changed size reads the file again");

  // Gone: the head starts again from nothing rather than from the one kept.
  rmSync(headPath);
  const fresh = await quiet();
  assert.equal(fresh.to, 0, "a removed head.json is not answered from memory");
  assert.deepEqual(fresh.batches, []);

  // A new generation never answers the old one's head.
  await mb.newGenerations(now, now);
  const next = await mb.pass(nothingTold(), (now += 1_000));
  assert.notEqual(next.heads[HOME].gen, gen, "a new generation");
  assert.equal(next.heads[HOME].name, "src");
  assert.deepEqual(next.heads[HOME], JSON.parse(readFileSync(join(replica, "own", HOME, String(next.heads[HOME].gen), "head.json"), "utf8")));
  assert.deepEqual(await quiet(), next.heads[HOME], "and a quiet pass after it answers that generation's head");
});

// ── D76: a transcript sweep goes on where the pass budget cut it, and the derived caches go while it is cut ──

type D76Opts = { files?: number; bytes?: number; deletes?: number; grace?: number };
type D76Pass = { tr: string[]; trDel: string[]; more: boolean };

/// The TS reference's or the MoonBit reader's exporter of `s`, with the given transcript budgets.
async function d76Exporter(mode: "ts" | "mb", s: { db: string; data: string }, replica: string, clock: { now: number }, workspaces: { workspace: string; name: string }[], opts: D76Opts = {}) {
  if (mode === "ts") {
    const e = new Exporter({
      db: s.db,
      replica,
      dataDir: s.data,
      origin: sid("a"),
      now: () => clock.now,
      chunkBytes: 4096,
      transcriptPassFiles: opts.files,
      transcriptPassBytes: opts.bytes,
      transcriptPassDeletes: opts.deletes,
      chunkGcGraceMs: opts.grace,
      fold: false,
    });
    e.setPlaces({ home: HOME, workspaces });
    return {
      pass: async (told: ReturnType<typeof nothingTold>) => e.pass(told) as { more: boolean },
      newGenerations: async (after: number) => e.newGenerations(after),
      close: async () => e.close(),
    };
  }
  const args = ["--no-fold"];
  if (opts.files !== undefined) args.push("--transcript-pass-files", String(opts.files));
  if (opts.bytes !== undefined) args.push("--transcript-pass-bytes", String(opts.bytes));
  if (opts.deletes !== undefined) args.push("--transcript-pass-deletes", String(opts.deletes));
  if (opts.grace !== undefined) args.push("--chunk-gc-grace-ms", String(opts.grace));
  const mb = await makeMbExportHelper(s.db, replica, s.data, sid("a"), 4096, args);
  await mb.places(clock.now, workspaces);
  return {
    pass: async (told: ReturnType<typeof nothingTold>) => (await mb.pass(told, clock.now)) as { more: boolean },
    newGenerations: async (after: number) => {
      await mb.newGenerations(after, clock.now);
    },
    close: async () => {
      await mb.close(clock.now);
    },
  };
}

/// The `tr` and `tr_del` records of `ws`'s current generation in batches not in `seen` (which they are added to).
function d76Records(replica: string, ws: string, seen: Set<string>): { tr: string[]; trDel: string[] } {
  const state = new DatabaseSync(join(replica, "export.db"), { readOnly: true });
  let gen: string;
  try {
    gen = String((state.prepare("SELECT v FROM meta WHERE k = ?").get(`gen:${ws}`) as { v: string }).v);
  } finally {
    state.close();
  }
  const log = join(replica, "own", ws, gen, "log");
  const out = { tr: [] as string[], trDel: [] as string[] };
  for (const b of readdirSync(log).filter((b) => !b.endsWith(".writing")).sort()) {
    if (seen.has(`${gen}/${b}`)) continue;
    seen.add(`${gen}/${b}`);
    for (const l of decodeBatch(readFileSync(join(log, b))).lines) {
      const r = JSON.parse(l) as Record<string, unknown>;
      if (typeof r.tr === "string") out.tr.push(r.tr);
      if (typeof r.tr_del === "string") out.trDel.push(r.tr_del);
    }
  }
  return out;
}

function d76Rows(replica: string, ws: string): string[] {
  const state = new DatabaseSync(join(replica, "export.db"), { readOnly: true });
  try {
    return (state.prepare("SELECT path FROM transcript_files WHERE ws = ? ORDER BY path").all(ws) as { path: string }[]).map((r) => r.path);
  } finally {
    state.close();
  }
}

test("D76: a session written all the time no longer starves the transcripts after it nor the derived caches' tr_del (TS + MoonBit)", async () => {
  const s = makeAgyBrainStation();
  closing.push(async () => s.store.close());
  const modes: ("ts" | "mb")[] = binary !== null ? ["ts", "mb"] : ["ts"];
  const workspaces = [{ workspace: HOME, name: "src" }];
  const sorted = [...s.keptFiles].sort();
  const active = join(s.cli, "annotations", `${s.agyId}.pbtxt`);
  const tail = join(s.cli, "conversations", `${s.agyId}.db`);
  assert.equal(sorted[0], active, "the session written all the time sorts first");
  assert.equal(sorted.at(-1), tail, "the transcript starved behind it sorts last");
  const steps = [1, 2, 3, 4, 5].map((i) => join(s.brain, ".system_generated", "steps", String(i), "output.txt"));

  const byMode: Record<string, D76Pass[]> = {};
  for (const mode of modes) {
    const replica = join(s.data, `replica-d76-${mode}`);
    const clock = { now: 1_700_000_000_000 };
    writeFileSync(active, "a".repeat(100));
    writeFileSync(tail, "z".repeat(100));
    utimesSync(active, 1_700_000_000, 1_700_000_000);
    utimesSync(tail, 1_700_000_000, 1_700_000_000);
    // Caught up first, by an exporter from before D71 that still holds 5 derived cache records.
    const first = await d76Exporter(mode, s, replica, clock, workspaces);
    try {
      let p = await first.pass(nothingTold());
      for (let i = 0; i < 5 && p.more; i++) p = await first.pass(nothingTold());
      assert.equal(p.more, false, `${mode}: caught up`);
    } finally {
      await first.close();
    }
    const state = new DatabaseSync(join(replica, "export.db"), { timeout: 5000 });
    try {
      for (const p of steps) state.prepare("INSERT INTO transcript_files (ws, path, room, size, mtime, mode, chunks_json) VALUES (?, ?, NULL, 1, 1, 420, '[]')").run(HOME, p);
    } finally {
      state.close();
    }
    assert.ok(steps.every((p) => d76Rows(replica, HOME).includes(p)));

    // The last transcript changes once; the first is written before every pass, each time more than a pass's bytes.
    // Only the first pass is told of it: the station tells of transcripts at most once in its debounce window.
    writeFileSync(tail, "z".repeat(200));
    utimesSync(tail, 1_700_000_005, 1_700_000_005);
    const seen = new Set<string>();
    d76Records(replica, HOME, seen);
    const e = await d76Exporter(mode, s, replica, clock, workspaces, { bytes: 1024, deletes: 2 });
    const passes: D76Pass[] = [];
    try {
      for (let round = 1; round <= 10; round++) {
        writeFileSync(active, "a".repeat(2000 + round));
        utimesSync(active, 1_700_000_010 + round, 1_700_000_010 + round);
        clock.now += 10_000;
        const p = await e.pass(round === 1 ? { ...nothingTold(), transcripts: true } : nothingTold());
        passes.push({ ...d76Records(replica, HOME, seen), more: p.more });
        if (!p.more) break;
      }
      assert.equal(passes.at(-1)!.more, false, `${mode}: the sweep ends though the first session is written before every pass (${JSON.stringify(passes)})`);
      assert.deepEqual(passes[0], { tr: [active], trDel: steps.slice(0, 2), more: true }, `${mode}: the pass cut short still drops the first derived caches`);
      assert.deepEqual(passes[1], { tr: [tail], trDel: steps.slice(2, 4), more: true }, `${mode}: the next pass goes on at the transcript it was cut at`);
      assert.deepEqual(passes[2], { tr: [], trDel: steps.slice(4), more: false }, `${mode}: the tr_del left go on without the paths read again`);
      assert.equal(passes.length, 3);
      const rows = d76Rows(replica, HOME);
      assert.ok(rows.includes(tail), `${mode}: the last transcript exported`);
      assert.ok(steps.every((p) => !rows.includes(p)), `${mode}: every derived cache record dropped`);
      // The sweep over, the next one starts from the first path again.
      writeFileSync(active, "a".repeat(3000));
      utimesSync(active, 1_700_000_100, 1_700_000_100);
      clock.now += 10_000;
      const again = await e.pass({ ...nothingTold(), transcripts: true });
      assert.deepEqual({ ...d76Records(replica, HOME, seen), more: again.more }, { tr: [active], trDel: [], more: false }, `${mode}: a new sweep from the start`);
    } finally {
      await e.close();
    }
    byMode[mode] = passes;
  }
  if (byMode.mb !== undefined) assert.deepEqual(byMode.mb, byMode.ts, "MoonBit and the TS reference pass for pass");
});

test("D76: sweeps over several workspaces end with deleted transcripts dropped, and newGenerations starts them over (TS + MoonBit)", async () => {
  const s = makeAgyBrainStation();
  closing.push(async () => s.store.close());
  const modes: ("ts" | "mb")[] = binary !== null ? ["ts", "mb"] : ["ts"];
  const agyId2 = "agy-brain-d76-other";
  const room2 = join(s.data, "sessions", "chat", "chat:agy-d76-other", "workspace");
  mkdirSync(room2, { recursive: true });
  s.store.insertSession({
    key: "chat:agy-d76-other",
    connect: "chat",
    runtime: "agy",
    profile: "agyprof",
    workspace: room2,
    token: "tok-agy-d76-other",
    createdAt: 2,
    lastActiveAt: 2,
    ws: OTHER,
  });
  s.store.setRuntimeSessionId("chat:agy-d76-other", agyId2);
  const t2 = s.store.openThread("chat", "C", "ts-agy-d76-other", "AGY D76 Other", "p@x").id;
  s.store.joinThread(t2, "chat:agy-d76-other", "chat");
  const brain2 = join(s.cli, "brain", agyId2);
  const other = [1, 2, 3, 4].map((i) => join(brain2, "notes", `n${i}.md`));
  mkdirSync(join(brain2, "notes"), { recursive: true });
  const workspaces = [
    { workspace: HOME, name: "home" },
    { workspace: OTHER, name: "other" },
  ];
  const gone: Record<string, string> = { [HOME]: join(s.brain, "notes", "scratch", "b.txt"), [OTHER]: other[1]! };
  const kept: Record<string, string[]> = { [HOME]: s.keptFiles.filter((p) => p !== gone[HOME]).sort(), [OTHER]: other.filter((p) => p !== gone[OTHER]).sort() };
  const writeAll = (tag: string, t: number) => {
    for (const p of [...s.keptFiles, ...other]) {
      if (!existsSync(p) && tag !== "first") continue;
      writeFileSync(p, `${tag}:${p}\n`);
      utimesSync(p, t, t);
    }
  };

  const byMode: Record<string, { sweep: Record<string, { tr: string[]; trDel: string[] }>; passes: number; regen: number }> = {};
  for (const mode of modes) {
    const replica = join(s.data, `replica-d76-ws-${mode}`);
    const clock = { now: 1_700_000_000_000 };
    writeAll("first", 1_700_000_000);
    const first = await d76Exporter(mode, s, replica, clock, workspaces);
    try {
      let p = await first.pass(nothingTold());
      for (let i = 0; i < 5 && p.more; i++) p = await first.pass(nothingTold());
      assert.equal(p.more, false, `${mode}: caught up`);
    } finally {
      await first.close();
    }
    assert.deepEqual(d76Rows(replica, OTHER), [...other].sort(), `${mode}: the other workspace's transcripts exported`);

    rmSync(gone[HOME]);
    rmSync(gone[OTHER]);
    writeAll("second", 1_700_000_100);
    const seen: Record<string, Set<string>> = { [HOME]: new Set<string>(), [OTHER]: new Set<string>() };
    for (const ws of [HOME, OTHER]) d76Records(replica, ws, seen[ws]!);
    const e = await d76Exporter(mode, s, replica, clock, workspaces, { files: 2, deletes: 1 });
    try {
      const sweep: Record<string, { tr: string[]; trDel: string[] }> = { [HOME]: { tr: [] as string[], trDel: [] as string[] }, [OTHER]: { tr: [] as string[], trDel: [] as string[] } };
      let passes = 0;
      for (let more = true; more; passes++) {
        assert.ok(passes < 20, `${mode}: the sweep ends`);
        clock.now += 10_000;
        more = (await e.pass(passes === 0 ? { ...nothingTold(), transcripts: true } : nothingTold())).more;
        for (const ws of [HOME, OTHER]) {
          const r = d76Records(replica, ws, seen[ws]!);
          sweep[ws]!.tr.push(...r.tr);
          sweep[ws]!.trDel.push(...r.trDel);
        }
      }
      for (const ws of [HOME, OTHER]) {
        assert.deepEqual(sweep[ws]!.tr, kept[ws], `${mode} ${ws}: every changed transcript exported once, in order`);
        assert.deepEqual(sweep[ws]!.trDel, [gone[ws]], `${mode} ${ws}: the deleted transcript dropped`);
        assert.deepEqual(d76Rows(replica, ws), kept[ws], `${mode} ${ws}: rows`);
      }

      // Cut short once more, then new generations: they are written whole, from the first path, not from the cut.
      writeAll("third", 1_700_000_200);
      clock.now += 10_000;
      assert.equal((await e.pass({ ...nothingTold(), transcripts: true })).more, true, `${mode}: cut short`);
      clock.now += 10_000;
      await e.newGenerations(clock.now - 1);
      for (const ws of [HOME, OTHER]) seen[ws]!.clear();
      let regen = 0;
      const fresh: Record<string, string[]> = { [HOME]: [] as string[], [OTHER]: [] as string[] };
      for (let more = true; more; regen++) {
        assert.ok(regen < 20, `${mode}: the new generations catch up`);
        clock.now += 10_000;
        more = (await e.pass(nothingTold())).more;
        for (const ws of [HOME, OTHER]) fresh[ws]!.push(...d76Records(replica, ws, seen[ws]!).tr);
      }
      for (const ws of [HOME, OTHER]) {
        assert.deepEqual(fresh[ws], kept[ws], `${mode} ${ws}: the new generation holds every transcript, the first path too`);
        assert.deepEqual(d76Rows(replica, ws), kept[ws], `${mode} ${ws}: rows after new generations`);
      }
      byMode[mode] = { sweep, passes, regen };
    } finally {
      await e.close();
    }
  }
  if (byMode.mb !== undefined) assert.deepEqual(byMode.mb, byMode.ts, "MoonBit and the TS reference pass for pass");
});

/// A caught-up first export of `s` to `replica`, by an exporter of its own.
async function d76CaughtUp(mode: "ts" | "mb", s: { db: string; data: string }, replica: string, clock: { now: number }) {
  const first = await d76Exporter(mode, s, replica, clock, [{ workspace: HOME, name: "src" }]);
  try {
    let p = await first.pass(nothingTold());
    for (let i = 0; i < 5 && p.more; i++) p = await first.pass(nothingTold());
    assert.equal(p.more, false, `${mode}: caught up`);
  } finally {
    await first.close();
  }
}

function d76Row(replica: string, ws: string, path: string): { size: number; chunks_json: string } | undefined {
  const state = new DatabaseSync(join(replica, "export.db"), { readOnly: true });
  try {
    return state.prepare("SELECT size, chunks_json FROM transcript_files WHERE ws = ? AND path = ?").get(ws, path) as { size: number; chunks_json: string } | undefined;
  } finally {
    state.close();
  }
}

test("D76: transcripts found but gone (an annotation, a .db-wal) are dropped by the sweep, behind its cursor too (TS + MoonBit)", async () => {
  const s = makeAgyBrainStation();
  closing.push(async () => s.store.close());
  const modes: ("ts" | "mb")[] = binary !== null ? ["ts", "mb"] : ["ts"];
  const pbtxt = join(s.cli, "annotations", `${s.agyId}.pbtxt`);
  const wal = join(s.cli, "conversations", `${s.agyId}.db-wal`);
  const changed = [join(s.brain, "notes", "scratch", "b.txt"), join(s.brain, "task.md")];
  const byMode: Record<string, { trDel: string[]; passes: number }> = {};
  for (const mode of modes) {
    const replica = join(s.data, `replica-d76-gone-${mode}`);
    const clock = { now: 1_700_000_000_000 };
    writeFileSync(pbtxt, "annotation\n");
    writeFileSync(wal, "wal\n");
    for (const p of changed) writeFileSync(p, `first:${p}\n`);
    await d76CaughtUp(mode, s, replica, clock);
    assert.ok(d76Rows(replica, HOME).includes(pbtxt) && d76Rows(replica, HOME).includes(wal), `${mode}: both exported`);

    // Both go (the annotation before the cursor, the .db-wal after a scan done), and the sweep is cut twice.
    rmSync(pbtxt);
    rmSync(wal);
    for (const p of changed) writeFileSync(p, `second:${p}\n`);
    const seen = new Set<string>();
    d76Records(replica, HOME, seen);
    const e = await d76Exporter(mode, s, replica, clock, [{ workspace: HOME, name: "src" }], { files: 1, deletes: 1 });
    const trDel: string[] = [];
    let passes = 0;
    try {
      for (let more = true; more; passes++) {
        assert.ok(passes < 10, `${mode}: the sweep ends`);
        clock.now += 10_000;
        more = (await e.pass(passes === 0 ? { ...nothingTold(), transcripts: true } : nothingTold())).more;
        trDel.push(...d76Records(replica, HOME, seen).trDel);
      }
    } finally {
      await e.close();
    }
    assert.ok(passes >= 3, `${mode}: the sweep was cut by its files and its deletes (${passes} passes)`);
    assert.deepEqual(trDel, [pbtxt, wal], `${mode}: tr_del for both by the end of the first sweep`);
    const rows = d76Rows(replica, HOME);
    assert.ok(!rows.includes(pbtxt) && !rows.includes(wal), `${mode}: no row left for either`);
    byMode[mode] = { trDel, passes };
  }
  if (byMode.mb !== undefined) assert.deepEqual(byMode.mb, byMode.ts, "MoonBit and the TS reference pass for pass");
});

test("D76: a pass told of transcripts during a sweep brings another sweep after it, and each whole sweep collects chunks (TS + MoonBit)", async () => {
  const s = makeAgyBrainStation();
  closing.push(async () => s.store.close());
  const modes: ("ts" | "mb")[] = binary !== null ? ["ts", "mb"] : ["ts"];
  const active = join(s.cli, "annotations", `${s.agyId}.pbtxt`);
  const tail = join(s.cli, "conversations", `${s.agyId}.db`);
  const byMode: Record<string, D76Pass[]> = {};
  for (const mode of modes) {
    const replica = join(s.data, `replica-d76-resweep-${mode}`);
    const clock = { now: 1_700_000_000_000 };
    writeFileSync(active, "a".repeat(100));
    writeFileSync(tail, "z".repeat(100));
    await d76CaughtUp(mode, s, replica, clock);
    const firstChunks = JSON.parse(d76Row(replica, HOME, active)!.chunks_json) as string[];
    assert.equal(firstChunks.length, 1);
    const firstChunk = join(replica, "chunks", firstChunks[0]!);

    writeFileSync(active, "a".repeat(200));
    writeFileSync(tail, "z".repeat(200));
    const seen = new Set<string>();
    d76Records(replica, HOME, seen);
    const e = await d76Exporter(mode, s, replica, clock, [{ workspace: HOME, name: "src" }], { files: 1, grace: 0 });
    const passes: D76Pass[] = [];
    try {
      const pass = async (told: ReturnType<typeof nothingTold>) => {
        clock.now += 10_000;
        const p = await e.pass(told);
        passes.push({ ...d76Records(replica, HOME, seen), more: p.more });
      };
      await pass({ ...nothingTold(), transcripts: true });
      assert.deepEqual(passes[0], { tr: [active], trDel: [], more: true }, `${mode}: cut after the first transcript`);
      assert.ok(existsSync(firstChunk), `${mode}: no chunk collected in the middle of a sweep`);
      // Written again behind the cursor, and told of in the middle of the sweep.
      writeFileSync(active, "a".repeat(500));
      await pass({ ...nothingTold(), transcripts: true });
      assert.deepEqual(passes[1], { tr: [tail], trDel: [], more: true }, `${mode}: the sweep ends at the tail, another to follow`);
      assert.ok(!existsSync(firstChunk), `${mode}: the whole sweep collected the chunk no longer named`);
      for (let i = 0; i < 5 && passes.at(-1)!.more; i++) await pass(nothingTold());
      assert.deepEqual(passes.slice(2), [{ tr: [active], trDel: [], more: false }], `${mode}: the next sweep exports what was told of`);
      assert.equal(d76Row(replica, HOME, active)!.size, 500, `${mode}: the last write is in the copy`);
    } finally {
      await e.close();
    }
    byMode[mode] = passes;
  }
  if (byMode.mb !== undefined) assert.deepEqual(byMode.mb, byMode.ts, "MoonBit and the TS reference pass for pass");
});

test("D76: a generation lost in the middle of a sweep is written again whole (TS + MoonBit)", async () => {
  const s = makeAgyBrainStation();
  closing.push(async () => s.store.close());
  const modes: ("ts" | "mb")[] = binary !== null ? ["ts", "mb"] : ["ts"];
  const byMode: Record<string, number> = {};
  for (const mode of modes) {
    const replica = join(s.data, `replica-d76-lost-${mode}`);
    const clock = { now: 1_700_000_000_000 };
    for (const p of s.keptFiles) writeFileSync(p, `first:${p}\n`);
    await d76CaughtUp(mode, s, replica, clock);
    for (const p of s.keptFiles) writeFileSync(p, `second:${p}\n`);
    const e = await d76Exporter(mode, s, replica, clock, [{ workspace: HOME, name: "src" }], { files: 1 });
    let passes = 0;
    try {
      clock.now += 10_000;
      assert.equal((await e.pass({ ...nothingTold(), transcripts: true })).more, true, `${mode}: cut short`);
      const all = d76Rows(replica, HOME);
      assert.deepEqual(all, [...s.keptFiles].sort());
      rmSync(join(replica, "own", HOME), { recursive: true, force: true });
      for (let more = true; more; passes++) {
        assert.ok(passes < 20, `${mode}: the new generation catches up`);
        clock.now += 10_000;
        more = (await e.pass(nothingTold())).more;
      }
      assert.deepEqual(d76Rows(replica, HOME), all, `${mode}: every transcript in the new generation, those before the cursor too`);
      const fresh = d76Records(replica, HOME, new Set());
      assert.deepEqual(fresh.tr, all, `${mode}: written in the new generation's batches`);
    } finally {
      await e.close();
    }
    byMode[mode] = passes;
  }
  if (byMode.mb !== undefined) assert.equal(byMode.mb, byMode.ts, "MoonBit and the TS reference take the same passes");
});

test("D76: an empty workspace's generation, made again each pass, asks for no transcript scan (TS + MoonBit)", async () => {
  const s = makeAgyBrainStation();
  closing.push(async () => s.store.close());
  const modes: ("ts" | "mb")[] = binary !== null ? ["ts", "mb"] : ["ts"];
  const workspaces = [
    { workspace: HOME, name: "home" },
    { workspace: OTHER, name: "empty" },
  ];
  const written = join(s.brain, "task.md");
  const byMode: Record<string, D76Pass[]> = {};
  for (const mode of modes) {
    const replica = join(s.data, `replica-d76-empty-${mode}`);
    const clock = { now: 1_700_000_000_000 };
    const e = await d76Exporter(mode, s, replica, clock, workspaces);
    const passes: D76Pass[] = [];
    try {
      let p = await e.pass(nothingTold());
      for (let i = 0; i < 5 && p.more; i++) p = await e.pass(nothingTold());
      assert.equal(p.more, false, `${mode}: caught up`);
      assert.ok(!existsSync(join(replica, "own", OTHER)), `${mode}: the empty workspace has no generation directory`);
      const seen = new Set<string>();
      d76Records(replica, HOME, seen);
      for (let i = 1; i <= 4; i++) {
        writeFileSync(written, `written ${i}\n`.repeat(i));
        clock.now += 1_000;
        const q = await e.pass(nothingTold());
        passes.push({ ...d76Records(replica, HOME, seen), more: q.more });
      }
    } finally {
      await e.close();
    }
    assert.deepEqual(passes, Array(4).fill({ tr: [], trDel: [], more: false }), `${mode}: chat passes scan no transcript`);
    assert.ok(!existsSync(join(replica, "own", OTHER)), `${mode}: nothing written for the empty workspace`);
    byMode[mode] = passes;
  }
  if (byMode.mb !== undefined) assert.deepEqual(byMode.mb, byMode.ts, "MoonBit and the TS reference pass for pass");
});

test("D76: a sweep's last pass failing to write leaves the transcripts to scan, and the retry exports them (TS + MoonBit)", {
  skip: process.getuid?.() === 0 ? "root writes into a read-only directory" : false,
}, async () => {
  const s = makeAgyBrainStation();
  closing.push(async () => s.store.close());
  const modes: ("ts" | "mb")[] = binary !== null ? ["ts", "mb"] : ["ts"];
  const a = join(s.cli, "annotations", `${s.agyId}.pbtxt`);
  const z = join(s.cli, "conversations", `${s.agyId}.db`);
  const byMode: Record<string, number> = {};
  for (const mode of modes) {
    const replica = join(s.data, `replica-d76-failed-${mode}`);
    const clock = { now: 1_700_000_000_000 };
    writeFileSync(a, "a\n");
    writeFileSync(z, "z\n");
    await d76CaughtUp(mode, s, replica, clock);
    writeFileSync(a, "a".repeat(777));
    writeFileSync(z, "z".repeat(888));
    const e = await d76Exporter(mode, s, replica, clock, [{ workspace: HOME, name: "src" }], { files: 1 });
    let retries = 0;
    try {
      clock.now += 10_000;
      assert.equal((await e.pass({ ...nothingTold(), transcripts: true })).more, true, `${mode}: cut after the first transcript`);
      assert.equal(d76Row(replica, HOME, a)!.size, 777);
      const state = new DatabaseSync(join(replica, "export.db"), { readOnly: true });
      let gen: string;
      try {
        gen = String((state.prepare("SELECT v FROM meta WHERE k = ?").get(`gen:${HOME}`) as { v: string }).v);
      } finally {
        state.close();
      }
      const logDir = join(replica, "own", HOME, gen, "log");
      chmodSync(logDir, 0o555);
      try {
        clock.now += 10_000;
        await assert.rejects(e.pass(nothingTold()), `${mode}: the sweep's last pass fails to write its batch`);
      } finally {
        chmodSync(logDir, 0o755);
      }
      assert.equal(d76Row(replica, HOME, z)!.size, 2, `${mode}: what it said of the transcript rolled back`);
      for (let more = true; more; retries++) {
        assert.ok(retries < 5, `${mode}: the retry catches up`);
        clock.now += 10_000;
        more = (await e.pass(nothingTold())).more;
      }
    } finally {
      await e.close();
    }
    assert.equal(d76Row(replica, HOME, z)!.size, 888, `${mode}: the last transcript is in the copy after the retry`);
    byMode[mode] = retries;
  }
  if (byMode.mb !== undefined) assert.equal(byMode.mb, byMode.ts, "MoonBit and the TS reference take the same passes");
});

test("D77: a pass reads each Claude project and Codex day once, finding what the TS reference finds (TS + MoonBit)", async () => {
  const data = dataDir("d77-finder");
  const db = join(data, "stillfail.db");
  const store = Store.open(db, join(data, "archive"));
  closing.push(async () => store.close());
  const now = 1_700_000_000_000;
  const put = (p: string) => {
    mkdirSync(join(p, ".."), { recursive: true });
    writeFileSync(p, `content:${p}\n`);
    utimesSync(p, new Date(now), new Date(now));
  };
  const session = (key: string, runtime: string, id: string, ws: string | null) => {
    const room = join(data, "sessions", "chat", key, "workspace");
    mkdirSync(room, { recursive: true });
    store.insertSession({ key, connect: "chat", runtime, profile: "p", workspace: room, token: `tok-${key}`, createdAt: 1, lastActiveAt: 1, ws });
    store.setRuntimeSessionId(key, id);
    store.joinThread(store.openThread("chat", "C", `ts-${key}`, key, "p@x").id, key, "chat");
    return room;
  };
  // 160 Claude projects of rooms no session is in, and a file beside them that is no project.
  const claudeRoot = join(data, "transcripts", "claude");
  const projects = Array.from({ length: 160 }, (_, i) => join(claudeRoot, `-elsewhere-${String(i).padStart(3, "0")}`));
  for (const [i, p] of projects.entries()) put(join(p, `other-${String(i).padStart(4, "0")}.jsonl`));
  writeFileSync(join(claudeRoot, ".DS_Store"), "x");
  const expected = new Set<string>();
  // 30 Claude sessions, each a kind of where its transcript is.
  for (let i = 0; i < 30; i++) {
    const id = `cl-${String(i).padStart(4, "0")}`;
    const ws = i % 2 === 0 ? null : OTHER;
    const room = session(`chat:d77-cl-${i}`, "claude", id, ws);
    const project = projects[(i * 5) % projects.length]!;
    const inWs = (p: string) => expected.add(`${ws ?? HOME}\0${p}`);
    switch (i % 5) {
      case 0: // in another project, with a subagent's transcript beside it
        put(join(project, `${id}.jsonl`));
        put(join(project, id, "sub-1.jsonl"));
        inWs(join(project, `${id}.jsonl`));
        inWs(join(project, id, "sub-1.jsonl"));
        break;
      case 1: // in another project, put away
        put(join(project, `${id}.jsonl.zst`));
        inWs(join(project, `${id}.jsonl.zst`));
        break;
      case 2: // nowhere
        break;
      case 3: // a directory named as the transcript is none, its `.zst` beside it not looked at
        mkdirSync(join(project, `${id}.jsonl`), { recursive: true });
        put(join(project, `${id}.jsonl.zst`));
        break;
      case 4: // in its own room's project
        put(join(claudeRoot, claudeProject(room)!, `${id}.jsonl`));
        inWs(join(claudeRoot, claudeProject(room)!, `${id}.jsonl`));
        break;
    }
  }
  // 20 Codex days and 30 Codex sessions over two workspaces: found, put away, or nowhere.
  const codexRoot = join(data, "transcripts", "codex");
  const days = Array.from({ length: 20 }, (_, i) => join(codexRoot, "2026", "11", String(i + 1).padStart(2, "0")));
  for (const d of days) put(join(d, "notes.txt"));
  for (let i = 0; i < 30; i++) {
    const id = `cx-${String(i).padStart(4, "0")}`;
    const ws = i % 2 === 0 ? null : OTHER;
    session(`chat:d77-cx-${i}`, "codex", id, ws);
    const day = days[Math.floor(i / 2) % days.length]!;
    if (i % 3 === 0) {
      put(join(day, `rollout-2026-11-01T00-00-00-${id}.jsonl`));
      expected.add(`${ws ?? HOME}\0${join(day, `rollout-2026-11-01T00-00-00-${id}.jsonl`)}`);
    } else if (i % 3 === 1) {
      put(join(day, `rollout-2026-11-01T00-00-00-${id}.jsonl.zst`));
      expected.add(`${ws ?? HOME}\0${join(day, `rollout-2026-11-01T00-00-00-${id}.jsonl.zst`)}`);
    }
  }
  const twoWs = [
    { workspace: HOME, name: "src" },
    { workspace: OTHER, name: "other" },
  ];
  const rows = (replica: string) => {
    const d = new DatabaseSync(join(replica, "export.db"), { readOnly: true });
    try {
      return new Set((d.prepare("SELECT ws, path FROM transcript_files").all() as { ws: string; path: string }[]).map((r) => `${r.ws}\0${r.path}`));
    } finally {
      d.close();
    }
  };
  // Where each mode's transcripts are once caught up, then with a Claude project and a Codex day unreadable.
  // The Codex day holds rollouts of both workspaces: the one looked at second is told it unreadable from what was kept.
  const unreadable = [projects[0]!, days[0]!];
  const mkErr = (code: string): NodeJS.ErrnoException => Object.assign(new Error(`${code}: injected`), { code });
  const run = async (mode: "ts" | "mb") => {
    const replica = join(data, `replica-d77-${mode}`);
    let faults: { finder_readdir_err?: string[] } = {};
    let pass: (told: ReturnType<typeof nothingTold>) => Promise<{ more: boolean; wrote: number }>;
    let setFaults: (f: { finder_readdir_err?: string[] }) => Promise<void>;
    if (mode === "ts") {
      const exporter = new Exporter({
        db,
        replica,
        dataDir: data,
        origin: sid("a"),
        now: () => now,
        chunkBytes: 4096,
        testFaults: { finderReaddirError: (d) => (faults.finder_readdir_err?.includes(d) ? mkErr("EIO") : null) },
      });
      closing.push(async () => exporter.close());
      exporter.setPlaces({ home: HOME, workspaces: twoWs });
      pass = async (told) => exporter.pass(told);
      setFaults = async (f) => {
        faults = f;
      };
    } else {
      const mb = await makeMbExportHelper(db, replica, data, sid("a"), 4096);
      await mb.places(now, twoWs);
      // Each pass's finder asks the shell about each directory once: 60 sessions over 160 projects and 20 days ask
      // 280 times, where a look through every project for each session not found asked 6,151.
      setFaults = async (f) => {
        await mb.testFaults({ ...f, finder_asked_most: 1000 } as unknown as Record<string, string[]>, now);
      };
      await setFaults({});
      pass = (told) => mb.pass(told, now);
    }
    for (let i = 0; i < 10; i++) if (!(await pass(nothingTold())).more) break;
    const caughtUp = rows(replica);
    await setFaults({ finder_readdir_err: unreadable });
    const cut = await pass({ ...nothingTold(), transcripts: true });
    assert.equal(cut.wrote, 0, `${mode}: an unreadable project or day drops none of the transcripts in it`);
    assert.deepEqual(rows(replica), caughtUp, `${mode}: rows kept while unreadable`);
    await setFaults({});
    return caughtUp;
  };
  const ts = await run("ts");
  assert.deepEqual([...ts].sort(), [...expected].sort(), "TS reference finds each transcript where it is");
  if (binary !== null) assert.deepEqual([...(await run("mb"))].sort(), [...ts].sort(), "MoonBit finds what the TS reference finds");
});
