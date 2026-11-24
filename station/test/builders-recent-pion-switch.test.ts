// Real dual-engine production switch, 4-scope parity, invalid-scope & lone-surrogate rejection,
// version/missing-table secondary check, nested savepoint partial rollback, cross-scope fair
// round-robin rotation, >64 fanout, SIGKILL restart, and static transaction guard tests for
// `builders_recent` (`--builder recent-chat`).
import assert from "node:assert/strict";
import { execFileSync, spawn, type ChildProcess } from "node:child_process";
import {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { after, test } from "node:test";
import { fileURLToPath } from "node:url";
import { hearLines, type Line } from "../src/ops/log.ts";
import { platform } from "../src/platform/index.ts";
import {
  mbReaderBinary,
  pionBinary,
  probePionSupportedModes,
  resetReaderSelectionStateForTest,
} from "../src/read/mb-reader.ts";
import { RecentChatBuilder, type RecentChatScope } from "../src/read/recent-chat-builder.ts";
import { readerModeEnvKey, type ReaderSelectConfig } from "../src/read/reader-select.ts";
import { recentChatIds } from "../src/store/chat-list.ts";
import { Store } from "../src/store/store.ts";
import { readPreparedRecentHome } from "./reference/chat-list/chat-list-home-overlap.ts";
import { readGlobalRecentChatIndex } from "./reference/chat-list/chat-list-index.ts";
import { readPreparedRecentWorkspace } from "./reference/chat-list/chat-list-scope-rows.ts";

const ASK_TIMEOUT_MS = 30_000;
const MB_FAIL_PREFIX = /^\S+:\d+:\d+-\d+:\d+@\S+ FAILED: /;

const tempDirs: string[] = [];
after(() => {
  for (const dir of tempDirs) rmSync(dir, { recursive: true, force: true });
});

function freshDir(prefix = "builders-recent-switch-"): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  tempDirs.push(dir);
  return dir;
}

const skipPosix = platform.os === "windows" ? "POSIX shell wrappers are not directly spawnable on Windows" : false;

function makeRecordingWrapper(dir: string, name: string, realBin: string, logFile: string): string {
  const wrapper = join(dir, name);
  const sh = [
    "#!/bin/sh",
    `printf '%s\\n' "$*" >> ${JSON.stringify(logFile)}`,
    `exec ${JSON.stringify(realBin)} "$@"`,
    "",
  ].join("\n");
  writeFileSync(wrapper, sh, "utf8");
  chmodSync(wrapper, 0o755);
  return wrapper;
}

function makeLegacyPionStub(dir: string, name: string, logFile: string): string {
  const stub = join(dir, name);
  const sh = [
    "#!/bin/sh",
    `printf '%s\\n' "$*" >> ${JSON.stringify(logFile)}`,
    'if [ "${1:-}" = "--version" ]; then',
    '  printf "stillfail-pion 0.0.1-legacy (linux-x64)\\n"',
    "  exit 0",
    "fi",
    'echo "legacy stub does not support SQLite builder $*" >&2',
    "exit 2",
    "",
  ].join("\n");
  writeFileSync(stub, sh, "utf8");
  chmodSync(stub, 0o755);
  return stub;
}

function readSpawns(logFile: string): string[] {
  if (!existsSync(logFile)) return [];
  return readFileSync(logFile, "utf8").split("\n").map((s) => s.trim()).filter(Boolean);
}

function clearSpawns(logFile: string): void {
  writeFileSync(logFile, "", "utf8");
}

async function withEnv<T>(overrides: Record<string, string | undefined>, fn: () => Promise<T>): Promise<T> {
  const saved = new Map<string, string | undefined>();
  for (const [k, v] of Object.entries(overrides)) {
    saved.set(k, process.env[k]);
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  resetReaderSelectionStateForTest();
  try {
    return await fn();
  } finally {
    for (const [k, v] of saved) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
    resetReaderSelectionStateForTest();
  }
}

function normalizeErr(res: Record<string, unknown>): Record<string, unknown> {
  if (typeof res.error === "string") {
    return { ...res, error: res.error.replace(MB_FAIL_PREFIX, "") };
  }
  return res;
}

function resolveBinaries(t: { skip: (msg: string) => void }): { realMb: string; realPion: string } | null {
  const realMb = mbReaderBinary();
  const explicitPion = process.env.STILLFAIL_PION_READER?.trim();
  const realPion = pionBinary();

  if (realMb === null) {
    if (process.env.CI) assert.fail("stillfail-reader binary is required in CI");
    t.skip("stillfail-reader not built here");
    return null;
  }
  if (explicitPion) {
    assert.ok(realPion !== null, `STILLFAIL_PION_READER is set (${explicitPion}) but resolved to null`);
  } else if (realPion === null) {
    t.skip("STILLFAIL_PION_READER / built stillfail-pion binary not present in this environment");
    return null;
  }
  return { realMb: resolve(realMb), realPion: resolve(realPion!) };
}

type Waiter = {
  resolve: (res: { raw: Record<string, unknown>; normalized: Record<string, unknown> }) => void;
  reject: (err: Error) => void;
  timer: NodeJS.Timeout;
};

class BuilderProc {
  readonly #child: ChildProcess;
  readonly #waiting: Waiter[] = [];
  #carry: Buffer = Buffer.alloc(0);
  #stderr = "";
  #ending = false;
  #protocolError: Error | null = null;
  readonly #closed: Promise<{ code: number | null; signal: NodeJS.Signals | null }>;

  constructor(binary: string, dbPath: string) {
    const child = spawn(binary, ["--builder", "recent-chat", "--db", dbPath], {
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
    });
    this.#child = child;
    child.stdin!.on("error", () => {});
    child.stderr!.on("data", (c: Buffer) => { this.#stderr += c.toString("utf8"); });
    child.stdout!.on("data", (c: Buffer) => this.#onData(c));
    this.#closed = new Promise((done) => {
      let ended = false;
      const finish = (code: number | null, signal: NodeJS.Signals | null) => {
        if (ended) return;
        ended = true;
        if (!this.#ending) {
          this.#fail(`builder recent-chat exited unexpectedly (code=${code}, signal=${signal}); stderr=${this.#stderr}`);
        }
        this.#rejectAll(new Error(`builder recent-chat exited (code=${code}, signal=${signal}); stderr=${this.#stderr}`));
        done({ code, signal });
      };
      child.on("error", (err) => {
        this.#fail(`builder recent-chat spawn error: ${err.message}`);
        if (child.pid === undefined) finish(null, null);
      });
      child.on("close", (code, signal) => finish(code, signal));
    });
  }

  #rejectAll(err: Error) {
    for (const w of this.#waiting.splice(0)) {
      clearTimeout(w.timer);
      w.reject(err);
    }
  }

  #fail(msg: string) {
    if (this.#protocolError === null) this.#protocolError = new Error(msg);
    this.#rejectAll(this.#protocolError);
    this.#child.kill("SIGKILL");
  }

  #onData(chunk: Buffer) {
    this.#carry = this.#carry.length === 0 ? chunk : Buffer.concat([this.#carry, chunk]);
    for (let nl = this.#carry.indexOf(0x0a); nl >= 0; nl = this.#carry.indexOf(0x0a)) {
      const line = this.#carry.subarray(0, nl).toString("utf8");
      this.#carry = this.#carry.subarray(nl + 1);
      let raw: Record<string, unknown>;
      try {
        raw = JSON.parse(line) as Record<string, unknown>;
      } catch {
        return this.#fail(`stdout emitted non-JSON line: ${JSON.stringify(line.slice(0, 200))}`);
      }
      const w = this.#waiting.shift();
      if (w === undefined) return this.#fail(`stdout emitted unsolicited line: ${line.slice(0, 200)}`);
      clearTimeout(w.timer);
      w.resolve({ raw, normalized: normalizeErr(raw) });
    }
  }

  askDetailed(rawLine: string): Promise<{ raw: Record<string, unknown>; normalized: Record<string, unknown> }> {
    if (this.#protocolError !== null) return Promise.reject(this.#protocolError);
    return new Promise((resolveAsk, rejectAsk) => {
      const timer = setTimeout(() => {
        this.#fail(`ask timed out after ${ASK_TIMEOUT_MS}ms; stderr=${this.#stderr}`);
      }, ASK_TIMEOUT_MS);
      this.#waiting.push({ resolve: resolveAsk, reject: rejectAsk, timer });
      this.#child.stdin!.write(`${rawLine}\n`, (err) => {
        if (err) this.#fail(`stdin write failed: ${err.message}`);
      });
    });
  }

  async ask(rawLine: string): Promise<Record<string, unknown>> {
    return (await this.askDetailed(rawLine)).normalized;
  }

  async end(): Promise<void> {
    this.#ending = true;
    try {
      if (this.#protocolError !== null) throw this.#protocolError;
      assert.equal(this.#waiting.length, 0, "no ask left unanswered");
      this.#child.stdin!.end();
      const { code, signal } = await this.#closed;
      assert.equal(signal, null, `ended by signal ${signal}; stderr=${this.#stderr}`);
      assert.equal(code, 0, `exit code ${code}; stderr=${this.#stderr}`);
      assert.equal(this.#carry.length, 0, `trailing stdout bytes: ${this.#carry.toString("utf8")}`);
    } finally {
      this.#rejectAll(new Error("proc ended"));
      if (this.#child.exitCode === null && this.#child.signalCode === null) this.#child.kill("SIGKILL");
    }
  }

  async sigkill(): Promise<void> {
    this.#ending = true;
    this.#rejectAll(new Error("killed"));
    this.#child.kill("SIGKILL");
    const { signal } = await this.#closed;
    this.#child.stdin!.destroy();
    assert.equal(signal, "SIGKILL", `expected SIGKILL exit, got signal=${signal}`);
  }
}

function addSession(store: Store, key: string, ws: string | null, connect = "ember") {
  store.insertSession({
    key,
    connect,
    runtime: "claude",
    profile: "cc",
    workspace: "/w",
    token: key,
    createdAt: 1,
    lastActiveAt: 1,
    ws,
  } as Parameters<Store["insertSession"]>[0]);
}

function makeRecentSeed(dir: string, label: string, shared = 70): { seedPath: string; threads: number[]; wide: number } {
  const seedPath = join(dir, `${label}-seed.db`);
  const store = Store.open(seedPath, join(dir, `${label}-archive`));
  try {
    const db = store.db;
    for (const [key, ws] of [["a", "A"], ["b", "B"], ["h", null], ["a2", "A"]] as const) addSession(store, key, ws);
    for (let i = 0; i < shared; i++) addSession(store, `w${i}`, `W${i}`, `c${i}`);
    db.exec("BEGIN");
    const threads: number[] = [];
    for (let i = 0; i < 180; i++) {
      const owner = ["a", "b", "h", "a2"][i % 4]!;
      const thread = store.openThreadOf("ember", "CHAT", `${label}-chat-${i}`, `chat ${i}`, "ann@x", i % 3 === 0 ? null : owner).id;
      if (i % 5 === 0) db.prepare("UPDATE threads SET home = ? WHERE id = ?").run(["b", "a", "h", "nobody"][i % 4], thread);
      else store.joinThread(thread, owner, "ember");
      if (i % 7 === 0) store.joinThread(thread, "b", "ember");
      if (i % 11 === 0) store.joinThread(thread, "missing", "ember");
      db.prepare("UPDATE threads SET created_at = ? WHERE id = ?").run(i, thread);
      if (i % 4 !== 0) {
        db.prepare("INSERT INTO entries (thread,n,kind,author_kind,author,text,at) VALUES (?,1,'message','person','ann@x','body',?)").run(
          thread,
          1000 + (i * 37) % 300,
        );
      }
      threads.push(thread);
    }
    const wide = store.openThread("ember", "CHAT", `${label}-wide`, "wide", "ann@x").id;
    for (let i = 0; i < shared; i++) store.joinThread(wide, `w${i}`, "ember");
    store.joinThread(wide, "a", "ember");
    db.prepare("UPDATE threads SET created_at = 400 WHERE id = ?").run(wide);
    threads.push(wide);
    db.exec("COMMIT");
    db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
    return { seedPath, threads, wide };
  } finally {
    store.close();
  }
}

function snapshotRecent(dbPath: string): string {
  const db = new DatabaseSync(dbPath);
  try {
    const master = db.prepare(
      "SELECT type, name, tbl_name, sql FROM sqlite_master WHERE name LIKE 'recent%' ORDER BY type, name",
    ).all();
    const tableNames = (
      db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'recent%' ORDER BY name").all() as {
        name: string;
      }[]
    ).map((r) => r.name);
    const tables: Record<string, string[]> = {};
    for (const name of tableNames) {
      tables[name] = (db.prepare(`SELECT * FROM ${name}`).all() as object[]).map((r) => JSON.stringify(r)).sort();
    }
    return JSON.stringify({ master, tables });
  } finally {
    db.close();
  }
}

function readPage(db: DatabaseSync, { ws, home }: RecentChatScope) {
  return ws === null
    ? readGlobalRecentChatIndex(db, 400)
    : ws === home
      ? readPreparedRecentHome(db, ws, 400)
      : readPreparedRecentWorkspace(db, ws, 400);
}

test("builders_recent: real MB default, real Pion switch (env + config.readers) via RecentChatBuilder for all 4 scope shapes, and legacy stub fallback", { skip: skipPosix }, async (t) => {
  const bins = resolveBinaries(t);
  if (!bins) return;

  const dir = freshDir();
  const mbLog = join(dir, "mb-spawns.log");
  const pionLog = join(dir, "pion-spawns.log");
  const legacyLog = join(dir, "legacy-pion-spawns.log");
  const mbWrap = makeRecordingWrapper(dir, "wrap-mb", bins.realMb, mbLog);
  const pionWrap = makeRecordingWrapper(dir, "wrap-pion", bins.realPion, pionLog);
  const legacyStub = makeLegacyPionStub(dir, "stub-legacy-pion", legacyLog);

  const { seedPath } = makeRecentSeed(dir, "switch", 12);

  const allScopes: readonly RecentChatScope[] = [
    { ws: null, home: null },
    { ws: null, home: "A" },
    { ws: "B", home: null },
    { ws: "B", home: "A" },
    { ws: "A", home: "A" },
  ];

  const cleanEnv: Record<string, string | undefined> = {
    STILLFAIL_MB_READER: mbWrap,
    STILLFAIL_PION_READER: pionWrap,
    STILLFAIL_READER_ENGINE: undefined,
    [readerModeEnvKey("recent-chat")]: undefined,
  };

  async function runProduction(dbPath: string, cfg?: () => ReaderSelectConfig): Promise<void> {
    const builder = new RecentChatBuilder(dbPath, cfg ? { readers: cfg } : {});
    try {
      for (const scope of allScopes) {
        await builder.readyScope(scope);
      }
    } finally {
      await builder.close();
    }
  }

  // 1. Default `mb`: spawns MB reader only, never Pion.
  clearSpawns(mbLog);
  clearSpawns(pionLog);
  const mbDb = join(dir, "default-mb.db");
  copyFileSync(seedPath, mbDb);
  await withEnv(cleanEnv, () => runProduction(mbDb));
  assert.ok(readSpawns(mbLog).some((l) => l.includes("--builder recent-chat")), "default mb must spawn MB reader");
  assert.equal(readSpawns(pionLog).length, 0, "default mb must not spawn Pion");
  const mbSnap = snapshotRecent(mbDb);

  // 2a. Switch via STILLFAIL_READER_RECENT_CHAT=pion.
  clearSpawns(mbLog);
  clearSpawns(pionLog);
  const pionEnvDb = join(dir, "pion-env.db");
  copyFileSync(seedPath, pionEnvDb);
  await withEnv({ ...cleanEnv, [readerModeEnvKey("recent-chat")]: "pion" }, async () => {
    const supported = await probePionSupportedModes(pionWrap);
    assert.ok(supported !== null && supported.has("recent-chat"), "stillfail-pion must advertise recent-chat");
    clearSpawns(pionLog);
    await runProduction(pionEnvDb);
  });
  assert.equal(readSpawns(mbLog).length, 0, "pion env switch must not spawn MB");
  assert.ok(readSpawns(pionLog).some((l) => l.includes("--builder recent-chat")), "pion env switch must spawn Pion");
  assert.equal(snapshotRecent(pionEnvDb), mbSnap, "pion env switch sqlite_master + tables 0-diff against MB");

  // 2b. Switch via config.readers["recent-chat"] = "pion".
  clearSpawns(mbLog);
  clearSpawns(pionLog);
  const pionCfgDb = join(dir, "pion-cfg.db");
  copyFileSync(seedPath, pionCfgDb);
  await withEnv(cleanEnv, async () => {
    const supported = await probePionSupportedModes(pionWrap);
    assert.ok(supported !== null && supported.has("recent-chat"));
    clearSpawns(pionLog);
    await runProduction(pionCfgDb, () => ({ readers: { "recent-chat": "pion" } }));
  });
  assert.equal(readSpawns(mbLog).length, 0, "pion config switch must not spawn MB");
  assert.ok(readSpawns(pionLog).some((l) => l.includes("--builder recent-chat")), "pion config switch must spawn Pion");
  assert.equal(snapshotRecent(pionCfgDb), mbSnap, "pion config switch sqlite_master + tables 0-diff against MB");

  // Verify prepared pages match recentChatIds for all 5 scope shapes.
  const verifyDb = new DatabaseSync(pionCfgDb);
  try {
    for (const scope of allScopes) {
      assert.deepStrictEqual(
        readPage(verifyDb, scope),
        recentChatIds(verifyDb, scope.ws, scope.home, 400),
        `prepared page matches recentChatIds for ${JSON.stringify(scope)}`,
      );
    }
  } finally {
    verifyDb.close();
  }

  // 3. Legacy Pion stub omitting `modes:` -> safe fallback to MB + 1 deduped warn.
  const logs: Line[] = [];
  hearLines((l) => logs.push(l));
  try {
    await withEnv(
      { ...cleanEnv, STILLFAIL_PION_READER: legacyStub, STILLFAIL_READER_ENGINE: "pion" },
      async () => {
        const supported = await probePionSupportedModes(legacyStub);
        assert.ok(supported !== null && !supported.has("recent-chat"));
        clearSpawns(legacyLog);
        clearSpawns(mbLog);
        const fbDb = join(dir, "legacy-fb.db");
        copyFileSync(seedPath, fbDb);
        await runProduction(fbDb);
        assert.ok(readSpawns(mbLog).some((l) => l.includes("--builder recent-chat")), "legacy stub must fall back to MB");
        assert.equal(readSpawns(legacyLog).length, 0, "legacy stub must never be spawned for unsupported mode");
      },
    );
    const warns = logs.filter(
      (l) => l.level === "WARN" && l.message === "reader engine fallback" && l.fields.reason === "pion-binary-unsupported-mode",
    );
    assert.deepStrictEqual(warns.map((w) => w.fields.mode), ["recent-chat"]);
  } finally {
    hearLines(null);
  }
});

test("builders_recent: invalid scope (missing, non-string, malformed JSON, lone surrogate, wrong arity/type) & version/missing-table secondary check 0-diff against MB", async (t) => {
  const bins = resolveBinaries(t);
  if (!bins) return;
  const dir = freshDir("builders-recent-invalid-");
  const { seedPath } = makeRecentSeed(dir, "inv", 4);

  const mbDb = join(dir, "inv-mb.db");
  const pionDb = join(dir, "inv-pion.db");
  copyFileSync(seedPath, mbDb);
  copyFileSync(seedPath, pionDb);

  const mbProc = new BuilderProc(bins.realMb, mbDb);
  const pionProc = new BuilderProc(bins.realPion, pionDb);
  try {
    // 1. Missing or non-string scope -> "invalid recent chat preparation request"
    for (const rawLine of [
      "{}",
      '{"scope":null}',
      '{"scope":123}',
      '{"scope":["A","A"]}',
      '{"scope":true}',
      "not-json",
    ]) {
      const [m, p] = await Promise.all([mbProc.askDetailed(rawLine), pionProc.askDetailed(rawLine)]);
      assert.deepStrictEqual(p.raw, m.raw, `raw mismatch for ${rawLine}`);
      assert.deepStrictEqual(p.raw, { done: false, error: "invalid recent chat preparation request" });
    }

    // 2. Invalid inner scope string -> exact "invalid recent chat scope" with NO `FAILED:` prefix on either engine!
    const badScopes = [
      "",
      "{bad",
      "null",
      "{}",
      "[]",
      '["A"]',
      '["A","B","C"]',
      "[1,2]",
      "[true,null]",
      '[null,123]',
      '["A",{}]',
      '["\\uD800",null]',
      '[null,"\\uDFFF"]',
      '["\\uD800\\u0041","A"]',
    ];
    for (const badScope of badScopes) {
      const req = JSON.stringify({ scope: badScope });
      const [m, p] = await Promise.all([mbProc.askDetailed(req), pionProc.askDetailed(req)]);
      assert.deepStrictEqual(p.raw, m.raw, `raw mismatch for bad scope ${badScope}`);
      assert.deepStrictEqual(p.raw, { done: false, error: "invalid recent chat scope" });
      assert.equal(String(p.raw.error).includes("FAILED:"), false, "must have no FAILED: prefix");
    }

    // 3. Valid surrogate pair inside scope string is accepted and installs cleanly after fresh missing-table check.
    const emojiReq = JSON.stringify({ scope: '["\\uD83D\\uDE80",null]' });
    let emojiDone = false;
    for (let step = 0; step < 30; step++) {
      const [m, p] = await Promise.all([mbProc.ask(emojiReq), pionProc.ask(emojiReq)]);
      assert.equal(m.error, undefined, `MB valid surrogate scope step ${step} error: ${JSON.stringify(m)}`);
      assert.equal(p.error, undefined, `Pion valid surrogate scope step ${step} error: ${JSON.stringify(p)}`);
      assert.deepStrictEqual(p, m, `valid surrogate scope step ${step}`);
      if (m.done === true) {
        emojiDone = true;
        break;
      }
    }
    assert.equal(emojiDone, true, "valid surrogate scope must converge to done=true");
    for (const [label, dbPath] of [["mb", mbDb], ["pion", pionDb]] as const) {
      const db = new DatabaseSync(dbPath);
      try {
        const row = db.prepare(
          "SELECT ws, complete, scan_done FROM recent_scope_tracked WHERE kind = 1 AND ws = ?",
        ).get("🚀") as { ws: string; complete: number; scan_done: number } | undefined;
        assert.deepStrictEqual(
          row ? { ...row } : undefined,
          { ws: "🚀", complete: 1, scan_done: 1 },
          `${label}: surrogate-pair workspace 🚀 must be tracked and complete`,
        );
      } finally {
        db.close();
      }
    }
    assert.equal(snapshotRecent(pionDb), snapshotRecent(mbDb), "valid surrogate scope 0-diff");
  } finally {
    await Promise.all([mbProc.end(), pionProc.end()]);
  }

  // 4. Incompatible version (version = 2) and component-without-versions-table (triggers `no such table: recent_chat_versions` secondary check).
  for (const scenario of ["wrong-version", "missing-versions-table"] as const) {
    const sMb = join(dir, `${scenario}-mb.db`);
    const sPion = join(dir, `${scenario}-pion.db`);
    copyFileSync(seedPath, sMb);
    copyFileSync(seedPath, sPion);
    for (const p of [sMb, sPion]) {
      const db = new DatabaseSync(p);
      try {
        if (scenario === "wrong-version") {
          db.exec("CREATE TABLE recent_chat_versions (part TEXT PRIMARY KEY, version INTEGER NOT NULL) WITHOUT ROWID;");
          db.exec("CREATE TABLE recent_chat_meta (id INTEGER PRIMARY KEY);");
          db.exec("INSERT INTO recent_chat_versions(part, version) VALUES ('global', 2);");
        } else {
          // Component table exists, recent_chat_versions does NOT -> hits `no such table: recent_chat_versions` catch + TABLES_QUERY!
          db.exec("CREATE TABLE recent_chat_meta (id INTEGER PRIMARY KEY);");
        }
      } finally {
        db.close();
      }
    }
    const mp = new BuilderProc(bins.realMb, sMb);
    const pp = new BuilderProc(bins.realPion, sPion);
    try {
      const req = JSON.stringify({ scope: "[null,null]" });
      const [m, p] = await Promise.all([mp.ask(req), pp.ask(req)]);
      assert.deepStrictEqual(p, m, `${scenario}: error must match MB`);
      assert.deepStrictEqual(p, {
        done: false,
        error: "recent chat global index has an incompatible or missing version",
      });
    } finally {
      await Promise.all([mp.end(), pp.end()]);
    }
  }
});

test("builders_recent: nested savepoint_err partial rollback preserves outer tx writes (via --smoke-sql-db)", (t) => {
  const bins = resolveBinaries(t);
  if (!bins) return;
  const dir = freshDir("builders-recent-sp-");
  const out = execFileSync(bins.realPion, ["--smoke-sql-db", join(dir, "smoke.db")], { encoding: "utf8" }).trim();
  const parsed = JSON.parse(out) as { ok?: boolean; suite?: string };
  assert.equal(parsed.ok, true);
  assert.ok(parsed.suite?.includes("builders_recent"), `expected builders_recent in smoke-sql-db suite, got ${out}`);
});

test("builders_recent: Int64 >2^53 thread IDs stay distinct, ordered, and 0-diff against MB", async (t) => {
  const bins = resolveBinaries(t);
  if (!bins) return;
  const dir = freshDir("builders-recent-i64-");
  const seedPath = join(dir, "i64-seed.db");
  const store = Store.open(seedPath, join(dir, "i64-archive"));
  try {
    addSession(store, "a", "A");
    addSession(store, "h", null);
    const db = store.db;
    db.exec("BEGIN");
    // Adjacent >2^53 integers: 9007199254740992 (2^53) and 9007199254740993 (2^53 + 1), which
    // collapse if rounded through IEEE-754 double without CAST(... AS TEXT).
    db.exec(
      "INSERT INTO threads(id, surface, channel, thread_ts, title, created_by, home, created_at) VALUES " +
      "(9007199254740992, 'ember', 'CHAT', 'i64-0', 't0', 'ann@x', 'a', 1000), " +
      "(9007199254740993, 'ember', 'CHAT', 'i64-1', 't1', 'ann@x', 'a', 1000), " +
      "(9007199254740994, 'ember', 'CHAT', 'i64-2', 't2', 'ann@x', 'h', 1000);",
    );
    db.exec(
      "INSERT INTO entries(thread, n, kind, author_kind, author, text, at) VALUES " +
      "(9007199254740992, 1, 'message', 'person', 'ann@x', 'm0', 5000), " +
      "(9007199254740993, 1, 'message', 'person', 'ann@x', 'm1', 5000), " +
      "(9007199254740994, 1, 'message', 'person', 'ann@x', 'm2', 5000);",
    );
    db.exec("COMMIT");
    db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
  } finally {
    store.close();
  }

  const mbDb = join(dir, "i64-mb.db");
  const pionDb = join(dir, "i64-pion.db");
  copyFileSync(seedPath, mbDb);
  copyFileSync(seedPath, pionDb);

  const mbProc = new BuilderProc(bins.realMb, mbDb);
  const pionProc = new BuilderProc(bins.realPion, pionDb);
  try {
    for (const scope of [
      { ws: null, home: null },
      { ws: "A", home: null },
      { ws: "A", home: "A" },
    ] as const) {
      const req = JSON.stringify({ scope: JSON.stringify([scope.ws, scope.home]) });
      let done = false;
      for (let step = 0; step < 30; step++) {
        const [m, p] = await Promise.all([mbProc.ask(req), pionProc.ask(req)]);
        assert.deepStrictEqual(p, m, `i64 scope ${JSON.stringify(scope)} step ${step}`);
        if (m.done === true) {
          done = true;
          break;
        }
      }
      assert.equal(done, true, `i64 scope ${JSON.stringify(scope)} must converge`);
    }
  } finally {
    await Promise.all([mbProc.end(), pionProc.end()]);
  }

  const readExact = (dbPath: string) => {
    const db = new DatabaseSync(dbPath);
    try {
      return {
        globalRows: db.prepare(
          "SELECT CAST(thread AS TEXT) AS tid, CAST(at AS TEXT) AS at, CAST(said_at AS TEXT) AS said_at, CAST(created_at AS TEXT) AS created_at FROM recent_chat_rows ORDER BY at DESC, said_at DESC, created_at DESC, thread DESC",
        ).all().map((r) => ({ ...r })),
        globalMeta: db.prepare(
          "SELECT CAST(cursor AS TEXT) AS cursor, CAST(through AS TEXT) AS through, total, complete FROM recent_chat_meta WHERE id = 1",
        ).all().map((r) => ({ ...r })),
        scopeRows: db.prepare(
          "SELECT ws, CAST(thread AS TEXT) AS tid, CAST(at AS TEXT) AS at, CAST(said_at AS TEXT) AS said_at, CAST(created_at AS TEXT) AS created_at FROM recent_scope_rows ORDER BY ws, at DESC, said_at DESC, created_at DESC, thread DESC",
        ).all().map((r) => ({ ...r })),
        homeRows: db.prepare(
          "SELECT CAST(thread AS TEXT) AS tid, CAST(at AS TEXT) AS at, CAST(said_at AS TEXT) AS said_at, CAST(created_at AS TEXT) AS created_at FROM recent_home_rows ORDER BY at DESC, said_at DESC, created_at DESC, thread DESC",
        ).all().map((r) => ({ ...r })),
        homeMeta: db.prepare(
          "SELECT CAST(cursor AS TEXT) AS cursor, CAST(through AS TEXT) AS through, scan_done, total FROM recent_home_meta WHERE id = 1",
        ).all().map((r) => ({ ...r })),
      };
    } finally {
      db.close();
    }
  };

  const mbExact = readExact(mbDb);
  const pionExact = readExact(pionDb);
  assert.deepStrictEqual(pionExact, mbExact, "Int64 >2^53 exact CAST(... AS TEXT) state 0-diff");
  assert.deepStrictEqual(
    pionExact.globalRows.map((r) => r.tid),
    ["9007199254740994", "9007199254740993", "9007199254740992"],
    "adjacent >2^53 IDs must stay distinct and ordered descending by integer id",
  );
  assert.deepStrictEqual(
    pionExact.scopeRows.map((r) => r.tid),
    ["9007199254740993", "9007199254740992"],
    "workspace A must preserve both adjacent >2^53 IDs without collapsing",
  );
  assert.deepStrictEqual(
    pionExact.homeRows.map((r) => r.tid),
    ["9007199254740994"],
  );
  assert.equal(pionExact.globalMeta[0]?.cursor, "9007199254740994");
  assert.equal(pionExact.globalMeta[0]?.through, "9007199254740994");
  assert.equal(pionExact.homeMeta[0]?.cursor, "9007199254740994");
  assert.equal(pionExact.homeMeta[0]?.through, "9007199254740994");
});

test("builders_recent: cross-scope fair round-robin rotation (including w:A vs h:A), concurrent writes, >64 fanout, and SIGKILL restart while unfinished 0-diff against MB", async (t) => {
  const bins = resolveBinaries(t);
  if (!bins) return;
  const dir = freshDir("builders-recent-fair-");
  const { seedPath, threads, wide } = makeRecentSeed(dir, "fair", 70);

  const mbDb = join(dir, "fair-mb.db");
  const pionDb = join(dir, "fair-pion.db");
  copyFileSync(seedPath, mbDb);
  copyFileSync(seedPath, pionDb);

  const scopes: RecentChatScope[] = [
    { ws: null, home: "A" },
    { ws: "A", home: null },
    { ws: "B", home: "A" },
    { ws: "A", home: "A" },
  ];

  let mbProc = new BuilderProc(bins.realMb, mbDb);
  let pionProc = new BuilderProc(bins.realPion, pionDb);
  try {
    let killed = false;
    let open = [...scopes];
    for (let round = 0; open.length > 0 && round < 400; round++) {
      // Interleave concurrent writes on both DBs between rounds.
      if (round === 2 || round === 5) {
        for (const p of [mbDb, pionDb]) {
          const ext = new DatabaseSync(p);
          try {
            if (round === 2) {
              ext.prepare("INSERT INTO entries (thread,n,kind,author_kind,author,text,at) VALUES (?,2,'message','person','ann@x','m2',5000)").run(threads[3]!);
              ext.prepare("UPDATE sessions SET ws = NULL WHERE key = 'b'").run();
            } else {
              ext.prepare("UPDATE sessions SET ws = 'A' WHERE key = 'h'").run();
              ext.prepare("DELETE FROM threads WHERE id = ?").run(threads[8]!);
            }
          } finally {
            ext.close();
          }
        }
      }

      const next: RecentChatScope[] = [];
      for (const scope of open) {
        const req = JSON.stringify({ scope: JSON.stringify([scope.ws, scope.home]) });
        const [m, p] = await Promise.all([mbProc.ask(req), pionProc.ask(req)]);
        assert.deepStrictEqual(p, m, `round ${round} scope ${JSON.stringify(scope)}`);
        if (m.done !== true) next.push(scope);
      }
      assert.equal(snapshotRecent(pionDb), snapshotRecent(mbDb), `tables 0-diff after round ${round}`);
      open = next;

      // SIGKILL + restart after round 3 while unfinished scopes still remain.
      if (round === 3 && !killed && open.length > 0) {
        killed = true;
        await Promise.all([mbProc.sigkill(), pionProc.sigkill()]);
        mbProc = new BuilderProc(bins.realMb, mbDb);
        pionProc = new BuilderProc(bins.realPion, pionDb);
      }
    }
    assert.equal(open.length, 0, "all scopes must converge to done=true");
    assert.equal(killed, true, "SIGKILL restart must have exercised while unfinished");

    // Verify >64 connections triggered scan_rowids = 1 on both engines.
    for (const [label, p] of [["mb", mbDb], ["pion", pionDb]] as const) {
      const db = new DatabaseSync(p);
      try {
        const rows = db.prepare("SELECT ws, scan_rowids FROM recent_scope_tracked WHERE kind = 1 ORDER BY ws").all();
        assert.deepStrictEqual(
          rows.map((r) => ({ ...r })),
          [{ ws: "A", scan_rowids: 1 }, { ws: "B", scan_rowids: 1 }],
          `${label}: scan_rowids must be 1 past 64 connections`,
        );
      } finally {
        db.close();
      }
    }

    // >64 workspaces fanout on `wide` chat -> recent_scope_order_dispatch batching 0-diff.
    const wideScopes: RecentChatScope[] = [{ ws: "A", home: "A" }];
    for (let i = 0; i < 70; i++) wideScopes.push({ ws: `W${i}`, home: "A" });
    let pendingWide = [...wideScopes];
    for (let r = 0; pendingWide.length > 0 && r < 400; r++) {
      const left: RecentChatScope[] = [];
      for (const scope of pendingWide) {
        const req = JSON.stringify({ scope: JSON.stringify([scope.ws, scope.home]) });
        const [m, p] = await Promise.all([mbProc.ask(req), pionProc.ask(req)]);
        assert.deepStrictEqual(p, m, `wide settle r=${r} scope=${JSON.stringify(scope)}`);
        if (m.done !== true) left.push(scope);
      }
      pendingWide = left;
    }
    assert.equal(pendingWide.length, 0);

    for (const p of [mbDb, pionDb]) {
      const ext = new DatabaseSync(p);
      try {
        ext.prepare("INSERT INTO entries (thread,n,kind,author_kind,author,text,at) VALUES (?,1,'message','person','ann@x','wide-msg',8888)").run(wide);
        const n = (ext.prepare("SELECT COUNT(*) AS n FROM recent_scope_order_dispatch").get() as { n: number }).n;
        assert.equal(n, 1, "message on >64-workspace chat must enqueue recent_scope_order_dispatch");
      } finally {
        ext.close();
      }
    }
    let dispatchOpen = [...wideScopes];
    for (let r = 0; dispatchOpen.length > 0 && r < 400; r++) {
      const left: RecentChatScope[] = [];
      for (const scope of dispatchOpen) {
        const req = JSON.stringify({ scope: JSON.stringify([scope.ws, scope.home]) });
        const [m, p] = await Promise.all([mbProc.ask(req), pionProc.ask(req)]);
        assert.deepStrictEqual(p, m, `wide dispatch r=${r} scope=${JSON.stringify(scope)}`);
        if (m.done !== true) left.push(scope);
      }
      dispatchOpen = left;
    }
    assert.equal(dispatchOpen.length, 0);
    assert.equal(snapshotRecent(pionDb), snapshotRecent(mbDb), ">64 fanout dispatch 0-diff");
  } finally {
    await Promise.all([mbProc.end(), pionProc.end()]);
  }
});

// ── Static transaction guard with real in-closure mutation detection on `builders_recent/src/*.pion` ──

type SqlTok = { kind: "word"; upper: string } | { kind: "ident" } | { kind: "str" } | { kind: "semi" } | { kind: "other" };

function extractPionStringExprs(source: string): { line: number; value: string }[] {
  const exprs: { line: number; value: string }[] = [];
  const n = source.length;
  let i = 0;
  let line = 1;

  const skipWsAndComments = () => {
    while (i < n) {
      const ch = source[i]!;
      if (ch === " " || ch === "\t" || ch === "\r") { i++; continue; }
      if (ch === "\n") { line++; i++; continue; }
      if (ch === "/" && source[i + 1] === "/") {
        i += 2;
        while (i < n && source[i] !== "\n") i++;
        continue;
      }
      if (ch === "/" && source[i + 1] === "*") {
        i += 2;
        while (i + 1 < n && !(source[i] === "*" && source[i + 1] === "/")) {
          if (source[i] === "\n") line++;
          i++;
        }
        i += 2;
        continue;
      }
      break;
    }
  };

  const readStringLiteral = (): string => {
    i++;
    let out = "";
    while (i < n) {
      const ch = source[i]!;
      if (ch === '"') { i++; return out; }
      if (ch === "\\") {
        i++;
        if (i >= n) return out;
        const esc = source[i++]!;
        if (esc === "n") out += "\n";
        else if (esc === "r") out += "\r";
        else if (esc === "t") out += "\t";
        else out += esc;
      } else {
        if (ch === "\n") line++;
        out += ch;
        i++;
      }
    }
    return out;
  };

  while (i < n) {
    skipWsAndComments();
    if (i >= n) break;
    if (source[i] === '"') {
      const startLine = line;
      let combined = readStringLiteral();
      for (;;) {
        const savedI = i;
        const savedLine = line;
        skipWsAndComments();
        if (source[i] === "+") {
          i++;
          skipWsAndComments();
          if (source[i] === '"') {
            combined += readStringLiteral();
            continue;
          }
          if (i < n && /[A-Za-z_(]/.test(source[i]!)) {
            let depth = 0;
            while (i < n) {
              const ch = source[i]!;
              if (ch === "(" || ch === "[" || ch === "{") { depth++; i++; continue; }
              if (ch === ")" || ch === "]" || ch === "}") {
                if (depth === 0) break;
                depth--;
                i++;
                continue;
              }
              if (depth === 0 && (ch === "+" || ch === "," || ch === ";" || ch === "\n")) break;
              if (ch === '"') { readStringLiteral(); continue; }
              i++;
            }
            combined += " __expr__ ";
            continue;
          }
        }
        i = savedI;
        line = savedLine;
        break;
      }
      exprs.push({ line: startLine, value: combined });
      continue;
    }
    i++;
  }
  return exprs;
}

function tokenizeSql(sql: string): SqlTok[] {
  const out: SqlTok[] = [];
  let i = sql.startsWith("\uFEFF") ? 1 : 0;
  const n = sql.length;
  while (i < n) {
    const ch = sql[i]!;
    if (ch === " " || ch === "\t" || ch === "\r" || ch === "\n") { i++; continue; }
    if (ch === "-" && sql[i + 1] === "-") { i += 2; while (i < n && sql[i] !== "\n") i++; continue; }
    if (ch === "/" && sql[i + 1] === "*") { i += 2; while (i + 1 < n && !(sql[i] === "*" && sql[i + 1] === "/")) i++; i += 2; continue; }
    if (ch === "'") {
      i++;
      while (i < n) { if (sql[i] === "'") { i++; if (sql[i] === "'") { i++; continue; } break; } i++; }
      out.push({ kind: "str" });
      continue;
    }
    if (ch === '"' || ch === "`") {
      const q = ch;
      i++;
      while (i < n) { if (sql[i] === q) { i++; if (sql[i] === q) { i++; continue; } break; } i++; }
      out.push({ kind: "ident" });
      continue;
    }
    if (ch === "[") { i++; while (i < n && sql[i] !== "]") i++; if (i < n) i++; out.push({ kind: "ident" }); continue; }
    if (ch === ";") { out.push({ kind: "semi" }); i++; continue; }
    if (/[A-Za-z_]/.test(ch)) {
      const start = i;
      while (i < n && /[A-Za-z0-9_$]/.test(sql[i]!)) i++;
      out.push({ kind: "word", upper: sql.slice(start, i).toUpperCase() });
      continue;
    }
    out.push({ kind: "other" });
    i++;
  }
  return out;
}

function findRawTxControlViolations(filename: string, source: string): string[] {
  const violations: string[] = [];
  const forbiddenHeads = new Set(["BEGIN", "COMMIT", "END", "SAVEPOINT", "RELEASE", "ROLLBACK"]);
  for (const expr of extractPionStringExprs(source)) {
    const tokens = tokenizeSql(expr.value);
    let atStmtStart = true;
    let inTriggerHeader = false;
    let inTriggerBody = false;
    let atTriggerStmtStart = false;
    for (let t = 0; t < tokens.length; t++) {
      const tok = tokens[t]!;
      if (inTriggerBody) {
        if (tok.kind === "semi") atTriggerStmtStart = true;
        else if (atTriggerStmtStart && tok.kind === "word" && tok.upper === "END") {
          inTriggerBody = false;
          atTriggerStmtStart = false;
          atStmtStart = false;
        } else atTriggerStmtStart = false;
        continue;
      }
      if (inTriggerHeader) {
        if (tok.kind === "word" && tok.upper === "BEGIN") {
          inTriggerHeader = false;
          inTriggerBody = true;
          atTriggerStmtStart = true;
        } else if (tok.kind === "semi") {
          inTriggerHeader = false;
          atStmtStart = true;
        }
        continue;
      }
      if (tok.kind === "semi") { atStmtStart = true; continue; }
      if (!atStmtStart) continue;
      atStmtStart = false;
      if (tok.kind !== "word") continue;
      if (tok.upper === "CREATE") {
        const t1 = tokens[t + 1];
        const t2 = tokens[t + 2];
        if (
          (t1?.kind === "word" && t1.upper === "TRIGGER") ||
          (t1?.kind === "word" && (t1.upper === "TEMP" || t1.upper === "TEMPORARY") && t2?.kind === "word" && t2.upper === "TRIGGER")
        ) {
          inTriggerHeader = true;
        }
        continue;
      }
      if (!forbiddenHeads.has(tok.upper)) continue;
      if (
        (tok.upper === "RELEASE" || tok.upper === "SAVEPOINT") &&
        tokens[t + 1]?.kind !== "word" &&
        tokens[t + 1]?.kind !== "ident" &&
        tokens[t + 1]?.kind !== "str"
      ) {
        continue;
      }
      violations.push(`${filename}:${expr.line}: forbidden raw transaction SQL "${tok.upper}" in literal ${JSON.stringify(expr.value)}`);
    }
  }
  return violations;
}

test("builders_recent static transaction guard + real in-closure mutation detection", () => {
  const srcDir = resolve(fileURLToPath(new URL("../../pion/station/packages/builders_recent/src", import.meta.url)));
  assert.ok(existsSync(srcDir), `expected ${srcDir} to exist`);
  const files = readdirSync(srcDir).filter((f) => f.endsWith(".pion") && !f.endsWith("_test.pion")).sort();
  assert.deepStrictEqual(files, ["db.pion", "global.pion", "home.pion", "prepare.pion", "schema.pion", "scope.pion"]);

  for (const file of files) {
    const content = readFileSync(join(srcDir, file), "utf8");
    assert.deepStrictEqual(
      findRawTxControlViolations(file, content),
      [],
      `${file} must contain zero raw transaction SQL violations`,
    );
  }

  // Real in-closure mutation test on `global.pion`, `home.pion`, `schema.pion`, and `scope.pion`.
  for (const file of ["global.pion", "home.pion", "schema.pion", "scope.pion"]) {
    const content = readFileSync(join(srcDir, file), "utf8");
    const closureRe = /(fn\((?:tx_db|sp_db) : sql_db::Db\) -> [^\n{]+\{\n)/;
    assert.match(content, closureRe, `${file}: expected tx_err/savepoint_err closure`);
    for (const { stmt, want } of [
      { stmt: 'let _ = tx_db.exec("COMMIT")', want: "COMMIT" },
      { stmt: 'let _ = tx_db.exec("BEGIN IMMEDIATE")', want: "BEGIN" },
      { stmt: 'let _ = tx_db.exec("SAVEPOINT sp")', want: "SAVEPOINT" },
      { stmt: 'let _ = tx_db.exec("ROLL" + "BACK")', want: "ROLLBACK" },
    ]) {
      const mutated = content.replace(closureRe, `$1      ${stmt}\n`);
      assert.notEqual(mutated, content);
      const hits = findRawTxControlViolations(file, mutated);
      assert.equal(hits.length, 1, `${file}: injected ${stmt} must be detected`);
      assert.ok(hits[0]!.includes(`"${want}"`), `${file}: expected "${want}", got ${hits[0]}`);
    }
  }
});
