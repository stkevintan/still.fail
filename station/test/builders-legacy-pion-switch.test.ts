// Real dual-engine production switch, Fallback repair loop, 6-site session-backfill DI wiring,
// all-19-kinds 0-diff, cross-engine CJK/emoji UTF-16 login_card_meta.offset hot-swap resume,
// and static transaction guard tests for `builders_legacy` (W5-C):
//   legacy-edits, legacy-said, session-backfill (all 19 kinds).
import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
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
import { ProcessJobsBuilder } from "../src/jobs/process-jobs-builder.ts";
import { hearLines, type Line } from "../src/ops/log.ts";
import { platform } from "../src/platform/index.ts";
import {
  mbReaderBinary,
  pionBinary,
  probePionSupportedModes,
  resetReaderSelectionStateForTest,
} from "../src/read/mb-reader.ts";
import { Readers } from "../src/read/pool.ts";
import { type ReaderMode, readerModeEnvKey, type ReaderSelectConfig } from "../src/read/reader-select.ts";
import { SandboxNameBuilder } from "../src/sessions/sandbox-name-builder.ts";
import { SessionDirectoryBuilder } from "../src/sessions/session-directory-builder.ts";
import { buildWorkspaceActivity } from "../src/sessions/workspace-activity-builder.ts";
import { buildLegacySaid } from "../src/store/legacy-said-builder.ts";
import { repairMergedEditLookup } from "../src/store/schema.ts";
import { Store } from "../src/store/store.ts";
import { ChatShareIndexBuilder } from "../src/xshare/index-builder.ts";
import { installArchivePolicyIndex } from "./reference/backfill/archive-policy-index.ts";
import { installLegacyAgent } from "./reference/backfill/legacy-agent-build.ts";
import { installDecisionSessionIndex } from "./reference/backfill/legacy-decision-session.ts";
import { installDecisionTimeIndex } from "./reference/backfill/legacy-decision-time.ts";
import { installLegacyLoginCards } from "./reference/backfill/legacy-login-cards.ts";
import { installLegacySaid } from "./reference/backfill/legacy-said-build.ts";
import { installPageLetterIndex } from "./reference/backfill/page-letter-index.ts";

const LEGACY_MODES: readonly ReaderMode[] = ["legacy-edits", "legacy-said", "session-backfill"];
const ASK_TIMEOUT_MS = 30_000;
const MB_FAIL_PREFIX = /^\S+:\d+:\d+-\d+:\d+@\S+ FAILED: /;

const tempDirs: string[] = [];
after(() => {
  for (const dir of tempDirs) rmSync(dir, { recursive: true, force: true });
});

function freshDir(prefix = "builders-legacy-switch-"): string {
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
  resolve: (res: Record<string, unknown>) => void;
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

  constructor(binary: string, mode: ReaderMode, dbPath: string) {
    const child = spawn(binary, ["--builder", mode, "--db", dbPath], {
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
          this.#fail(`builder ${mode} exited unexpectedly (code=${code}, signal=${signal}); stderr=${this.#stderr}`);
        }
        this.#rejectAll(new Error(`builder ${mode} exited (code=${code}, signal=${signal}); stderr=${this.#stderr}`));
        done({ code, signal });
      };
      child.on("error", (err) => {
        this.#fail(`builder ${mode} spawn error: ${err.message}`);
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
      let parsed: Record<string, unknown>;
      try {
        parsed = normalizeErr(JSON.parse(line) as Record<string, unknown>);
      } catch {
        return this.#fail(`stdout emitted non-JSON line: ${JSON.stringify(line.slice(0, 200))}`);
      }
      const w = this.#waiting.shift();
      if (w === undefined) return this.#fail(`stdout emitted unsolicited line: ${line.slice(0, 200)}`);
      clearTimeout(w.timer);
      w.resolve(parsed);
    }
  }

  writeRaw(data: string): void {
    this.#child.stdin!.write(data);
  }

  ask(rawLine: string): Promise<Record<string, unknown>> {
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
}

const bareSql = (sql: string | null) => (sql ?? "").replace(/\s+/g, "");

function snapshotAllTables(dbPath: string, skipTables: ReadonlySet<string> = new Set()): string {
  const db = new DatabaseSync(dbPath);
  try {
    const master = (
      db.prepare("SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name").all() as {
        type: string;
        name: string;
        tbl_name: string;
        sql: string | null;
      }[]
    ).map((r) => ({ ...r, sql: bareSql(r.sql) }));
    const tables = (
      db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name").all() as {
        name: string;
      }[]
    ).map((r) => r.name);
    const data: Record<string, string[]> = {};
    for (const tbl of tables) {
      if (skipTables.has(tbl)) continue;
      data[tbl] = (db.prepare(`SELECT * FROM "${tbl}"`).all() as object[]).map((r) => JSON.stringify(r)).sort();
    }
    return JSON.stringify({ master, data });
  } finally {
    db.close();
  }
}

// ── Test 1: legacy-edits Fallback -> permit release -> writer repair() -> retry loop + legacy-said/session-backfill no-fallback ──

test("legacy-edits Fallback -> permit release -> writer repair() -> retry succeeds on Pion; legacy-said and session-backfill never emit fallback", { skip: skipPosix }, async (t) => {
  const bins = resolveBinaries(t);
  if (!bins) return;

  const dir = freshDir("legacy-fallback-");
  const mbLog = join(dir, "mb-spawns.log");
  const pionLog = join(dir, "pion-spawns.log");
  const legacyLog = join(dir, "legacy-pion-spawns.log");
  const mbWrap = makeRecordingWrapper(dir, "wrap-mb", bins.realMb, mbLog);
  const pionWrap = makeRecordingWrapper(dir, "wrap-pion", bins.realPion, pionLog);
  const legacyStub = makeLegacyPionStub(dir, "stub-legacy-pion", legacyLog);

  const dataDir = join(dir, "data");
  mkdirSync(dataDir, { recursive: true });
  const dbPath = join(dataDir, "stillfail.db");
  const store = Store.open(dbPath, join(dataDir, "archive"));
  try {
    const th = store.openThread("ember", "CHAT", "fb-1", null, null).id;
    store.db.exec("BEGIN");
    for (let n = 1; n <= 90; n++) {
      const isEdit = n % 3 === 0;
      store.db.prepare(
        "INSERT INTO entries(thread,n,kind,target,author_kind,author,text,at,ts) VALUES(?,?,?,?,?,?,?,?,?)",
      ).run(th, n, isEdit ? "edit" : "message", isEdit ? n - 1 : null, "agent", "a1", `msg-${n}`, n, `ts-${n}`);
    }
    store.db.exec("COMMIT");
    // Drop native edit index WITHOUT repairing merged view -> forces Fallback on first legacy-edits ask.
    store.db.exec("DROP INDEX entries_edits");
    installLegacySaid(store.db);
    store.db.exec("PRAGMA wal_checkpoint(TRUNCATE)");

    let repairCalls = 0;
    const repairEdits = () => {
      repairCalls++;
      // Verify permit is NOT held during writer repair (backfillPriority[1] === 0).
      assert.equal(new Int32Array(store.backfillPriority)[1], 0, "permit must be released before writer repair()");
      repairMergedEditLookup(store.db);
    };

    const envPion: Record<string, string | undefined> = {
      STILLFAIL_MB_READER: mbWrap,
      STILLFAIL_PION_READER: pionWrap,
      STILLFAIL_READER_ENGINE: undefined,
      [readerModeEnvKey("legacy-edits")]: "pion",
      [readerModeEnvKey("legacy-said")]: "pion",
    };

    await withEnv(envPion, async () => {
      const supported = await probePionSupportedModes(pionWrap);
      assert.ok(supported !== null && supported.has("legacy-edits") && supported.has("legacy-said") && supported.has("session-backfill"));
      clearSpawns(mbLog);
      clearSpawns(pionLog);

      const readers = new Readers(dataDir, 1, undefined, 1, {
        priority: store.backfillPriority,
      });
      readers.repairEdits = repairEdits;
      try {
        await readers.prepareLegacyEdits();
        assert.equal(repairCalls, 1, "writer repairEdits must be invoked once via Fallback loop");
        assert.equal(new Int32Array(store.backfillPriority)[1], 0, "no permit leaked after prepareLegacyEdits");

        await readers.prepareLegacySaid();
        assert.equal(new Int32Array(store.backfillPriority)[1], 0, "no permit leaked after prepareLegacySaid");
      } finally {
        readers.close();
      }

      const mbSpawns = readSpawns(mbLog);
      const pionSpawns = readSpawns(pionLog);
      assert.equal(mbSpawns.length, 0, `expected 0 MB spawns, got ${JSON.stringify(mbSpawns)}`);
      assert.ok(pionSpawns.some((l) => l.includes("--builder legacy-edits")), "must spawn Pion legacy-edits");
      assert.ok(pionSpawns.some((l) => l.includes("--builder legacy-said")), "must spawn Pion legacy-said");
    });

    // Verify directly at protocol level: legacy-said and session-backfill NEVER emit {"fallback":true}.
    const brokenPath = join(dir, "broken.db");
    const brokenStore = Store.open(brokenPath, join(dir, "broken-archive"));
    try {
      brokenStore.db.exec("DROP INDEX entries_edits");
      brokenStore.db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
    } finally {
      brokenStore.close();
    }

    const editsProc = new BuilderProc(bins.realPion, "legacy-edits", brokenPath);
    const saidProc = new BuilderProc(bins.realPion, "legacy-said", brokenPath);
    const backfillProc = new BuilderProc(bins.realPion, "session-backfill", brokenPath);
    try {
      assert.deepStrictEqual(await editsProc.ask('{"thread":0}'), { fallback: true }, "legacy-edits must emit fallback");
      const saidRes = await saidProc.ask('{"thread":0}');
      assert.equal(saidRes.fallback, undefined, "legacy-said must never emit fallback");
      assert.equal(saidRes.done, true);
      const bfEditsRes = await backfillProc.ask('{"kind":"legacy-edits"}');
      assert.equal(bfEditsRes.fallback, undefined, "session-backfill legacy-edits must never emit fallback");
      const bfUnknownRes = await backfillProc.ask('{"kind":"does-not-exist"}');
      assert.equal(bfUnknownRes.fallback, undefined, "session-backfill unknown kind must never emit fallback");
      assert.equal(bfUnknownRes.error, "invalid session backfill preparation request");
    } finally {
      await Promise.all([editsProc.end(), saidProc.end(), backfillProc.end()]);
    }

    // Legacy Pion stub fallback test
    const logs: Line[] = [];
    hearLines((l) => logs.push(l));
    try {
      await withEnv(
        {
          STILLFAIL_MB_READER: mbWrap,
          STILLFAIL_PION_READER: legacyStub,
          STILLFAIL_READER_ENGINE: "pion",
        },
        async () => {
          const supported = await probePionSupportedModes(legacyStub);
          assert.ok(supported !== null);
          for (const m of LEGACY_MODES) assert.equal(supported.has(m), false);
          clearSpawns(mbLog);
          clearSpawns(legacyLog);
          const readers = new Readers(dataDir, 1, undefined, 1, { priority: store.backfillPriority });
          readers.repairEdits = repairEdits;
          try {
            await readers.prepareLegacyEdits();
            await readers.prepareLegacySaid();
          } finally {
            readers.close();
          }
          assert.equal(readSpawns(legacyLog).length, 0, "legacy stub must not be spawned");
          assert.ok(readSpawns(mbLog).some((l) => l.includes("--builder legacy-edits")));
          assert.ok(readSpawns(mbLog).some((l) => l.includes("--builder legacy-said")));
        },
      );
    } finally {
      hearLines(null);
    }
  } finally {
    store.close();
  }
});

// ── Test 2: All 6 production `session-backfill` TS spawn sites switch to Pion ──

test("all 6 production session-backfill TS spawn sites spawn real stillfail-pion when enabled", { skip: skipPosix }, async (t) => {
  const bins = resolveBinaries(t);
  if (!bins) return;

  const dir = freshDir("session-backfill-6sites-");
  const mbLog = join(dir, "mb-spawns.log");
  const pionLog = join(dir, "pion-spawns.log");
  const mbWrap = makeRecordingWrapper(dir, "wrap-mb", bins.realMb, mbLog);
  const pionWrap = makeRecordingWrapper(dir, "wrap-pion", bins.realPion, pionLog);

  const envPion: Record<string, string | undefined> = {
    STILLFAIL_MB_READER: mbWrap,
    STILLFAIL_PION_READER: pionWrap,
    STILLFAIL_READER_ENGINE: undefined,
    [readerModeEnvKey("session-backfill")]: "pion",
  };

  await withEnv(envPion, async () => {
    const supported = await probePionSupportedModes(pionWrap);
    assert.ok(supported !== null && supported.has("session-backfill"));

    // Site 1: buildWorkspaceActivity (sessions/workspace-activity-builder.ts)
    {
      clearSpawns(mbLog);
      clearSpawns(pionLog);
      const sub = join(dir, "site1");
      mkdirSync(sub, { recursive: true });
      const store = Store.open(join(sub, "stillfail.db"), join(sub, "archive"));
      try {
        store.insertSession({ key: "s1", connect: "ember", runtime: "claude", profile: "cc", workspace: "/w", token: "s1", createdAt: 1, lastActiveAt: 1, ws: "W1" });
        store.db.exec("UPDATE sessions SET running = 1 WHERE key = 's1'");
        store.db.exec("DELETE FROM workspace_activity; UPDATE workspace_activity_meta SET cursor = NULL, complete = 0 WHERE id = 1");
        const handle = buildWorkspaceActivity(store, Promise.resolve());
        try {
          assert.equal(await handle.ready, true, "site1: workspace activity ready");
        } finally {
          await handle.close();
        }
        assert.equal(readSpawns(mbLog).length, 0, "site1: no MB spawn");
        assert.ok(readSpawns(pionLog).some((l) => l.includes("--builder session-backfill")), "site1: spawned Pion");
      } finally {
        store.close();
      }
    }

    // Site 2: SessionDirectoryBuilder (sessions/session-directory-builder.ts)
    {
      clearSpawns(mbLog);
      clearSpawns(pionLog);
      const sub = join(dir, "site2");
      mkdirSync(sub, { recursive: true });
      const store = Store.open(join(sub, "stillfail.db"), join(sub, "archive"));
      try {
        store.insertSession({ key: "s1", connect: "ember", runtime: "claude", profile: "cc", workspace: "/w/dir1", token: "s1", createdAt: 1, lastActiveAt: 1, ws: null });
        const builder = new SessionDirectoryBuilder(store, Promise.resolve());
        try {
          builder.find("/w/dir1");
          await builder.settled();
        } finally {
          await builder.close();
        }
        assert.equal(readSpawns(mbLog).length, 0, "site2: no MB spawn");
        assert.ok(readSpawns(pionLog).some((l) => l.includes("--builder session-backfill")), "site2: spawned Pion");
      } finally {
        store.close();
      }
    }

    // Site 3: SandboxNameBuilder (sessions/sandbox-name-builder.ts)
    {
      clearSpawns(mbLog);
      clearSpawns(pionLog);
      const sub = join(dir, "site3");
      mkdirSync(sub, { recursive: true });
      const store = Store.open(join(sub, "stillfail.db"), join(sub, "archive"));
      try {
        store.insertSession({ key: "s-sb-1", connect: "ember", runtime: "claude", profile: "cc", workspace: "/w", token: "s1", createdAt: 1, lastActiveAt: 1, ws: null });
        const builder = new SandboxNameBuilder(store, Promise.resolve());
        try {
          const res = await builder.sessions(["s-none"]);
          assert.ok(res instanceof Map, "site3: sandbox sessions map returned");
        } finally {
          await builder.close();
        }
        assert.equal(readSpawns(mbLog).length, 0, "site3: no MB spawn");
        assert.ok(readSpawns(pionLog).some((l) => l.includes("--builder session-backfill")), "site3: spawned Pion");
      } finally {
        store.close();
      }
    }

    // Site 4: ProcessJobsBuilder (jobs/process-jobs-builder.ts)
    {
      clearSpawns(mbLog);
      clearSpawns(pionLog);
      const sub = join(dir, "site4");
      mkdirSync(sub, { recursive: true });
      const store = Store.open(join(sub, "stillfail.db"), join(sub, "archive"));
      try {
        for (const r of store.db.prepare("SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'process_job_%'").all() as { name: string }[]) {
          store.db.exec(`DROP TRIGGER ${r.name}`);
        }
        store.db.exec("DROP TABLE IF EXISTS process_job_meta; DROP TABLE IF EXISTS process_job_rows; DROP TABLE IF EXISTS process_job_replaced");
        store.db.prepare(
          "INSERT INTO jobs(id,token,session_key,state,pgid,name,command,cwd,port,started_at,log) VALUES('j1','t1','s1','running',123,'n','','',NULL,1,'')",
        ).run();
        const builder = new ProcessJobsBuilder(store, Promise.resolve());
        try {
          builder.consider(40);
          await builder.settled();
        } finally {
          await builder.close();
        }
        assert.equal(readSpawns(mbLog).length, 0, "site4: no MB spawn");
        assert.ok(readSpawns(pionLog).some((l) => l.includes("--builder session-backfill")), "site4: spawned Pion");
      } finally {
        store.close();
      }
    }

    // Site 5: ChatShareIndexBuilder (xshare/index-builder.ts)
    {
      clearSpawns(mbLog);
      clearSpawns(pionLog);
      const sub = join(dir, "site5");
      mkdirSync(sub, { recursive: true });
      const store = Store.open(join(sub, "stillfail.db"), join(sub, "archive"));
      try {
        store.db.exec("BEGIN");
        for (let i = 0; i < 40; i++) {
          store.db.prepare("INSERT INTO chat_shares(session, shared, by, at) VALUES (?, ?, 'me', ?)").run(
            `cs-${i}`,
            JSON.stringify([{ workspace: `W${i % 3}`, used: 1000 + i }]),
            1000 + i,
          );
        }
        store.db.exec("COMMIT");
        const builder = new ChatShareIndexBuilder(store, Promise.resolve());
        try {
          builder.request();
          await builder.settled();
        } finally {
          await builder.close();
        }
        assert.equal(readSpawns(mbLog).length, 0, "site5: no MB spawn");
        assert.ok(readSpawns(pionLog).some((l) => l.includes("--builder session-backfill")), "site5: spawned Pion");
      } finally {
        store.close();
      }
    }

    // Site 6: buildLegacySaid (store/legacy-said-builder.ts) — verify injected `cfg` alone switches to Pion
    // with both STILLFAIL_READER_SESSION_BACKFILL and STILLFAIL_READER_ENGINE cleared.
    await withEnv(
      {
        STILLFAIL_MB_READER: mbWrap,
        STILLFAIL_PION_READER: pionWrap,
        STILLFAIL_READER_ENGINE: undefined,
        [readerModeEnvKey("session-backfill")]: undefined,
      },
      async () => {
        const supportedCfg = await probePionSupportedModes(pionWrap);
        assert.ok(supportedCfg !== null && supportedCfg.has("session-backfill"));
        clearSpawns(mbLog);
        clearSpawns(pionLog);
        const sub = join(dir, "site6");
        mkdirSync(sub, { recursive: true });
        const store = Store.open(join(sub, "stillfail.db"), join(sub, "archive"));
        try {
          const th = store.openThread("ember", "CHAT", "ls-1", null, null).id;
          store.db.prepare("INSERT INTO entries(thread,n,kind,author_kind,author,text,at,ts) VALUES(?,1,'message','agent','a','hi',1,'ts1')").run(th);
          installLegacySaid(store.db);
          const cfg: () => ReaderSelectConfig = () => ({ readers: { "session-backfill": "pion" } });
          const handle = buildLegacySaid(store, Promise.resolve(), undefined, cfg);
          try {
            assert.equal(await handle.ready, true, "site6: legacy said ready");
          } finally {
            await handle.close();
          }
          assert.equal(readSpawns(mbLog).length, 0, "site6: cfg-only switch must not spawn MB");
          assert.ok(readSpawns(pionLog).some((l) => l.includes("--builder session-backfill")), "site6: cfg-only switch must spawn Pion");
        } finally {
          store.close();
        }
      },
    );
  });
});

// ── Test 3: All 19 session-backfill kinds dual-engine 0-diff (including conversation-backfill) ──

function seedAll19KindsDb(path: string, archiveDir: string): void {
  const store = Store.open(path, archiveDir);
  try {
    const db = store.db;
    const th1 = store.openThread("ember", "CHAT", "k-1", null, null).id;
    const th2 = store.openThread("ember", "CHAT", "k-2", null, null).id;
    // Slack birth thread + home thread for conversation-backfill
    const slackTh = store.openThread("slack", "C99", "1700000.1", null, null).id;
    const homeTh = store.openThread("ember", "CHAT", "home-s1", null, null).id;
    db.prepare("UPDATE threads SET home = 'slack:C99:1700000.1' WHERE id = ?").run(homeTh);

    db.exec("BEGIN");
    for (let i = 0; i < 80; i++) {
      const key = i === 0 ? "slack:C99:1700000.1" : i === 1 ? "bot2:C99:1700000.1" : i === 2 ? "lone:C88:1800000.2" : `s-${String(i).padStart(3, "0")}-${i % 2 === 0 ? "😀" : "Kİ"}`;
      store.insertSession({
        key,
        connect: i < 3 ? "slack" : "ember",
        runtime: "claude",
        profile: "cc",
        workspace: `/w/${i}`,
        cwd: i % 2 === 0 ? `/cwd/${i}` : null,
        token: `tok-${i}`,
        createdAt: 1000 + i,
        lastActiveAt: 1000 + i,
        ws: i % 4 === 0 ? null : `W${i % 3}`,
      });
      if (i < 3) {
        db.prepare("UPDATE sessions SET scope = 'thread', conv = NULL WHERE key = ?").run(key);
      }
      if (i % 3 === 0) db.prepare("UPDATE sessions SET running = 1 WHERE key = ?").run(key);
      if (i % 5 === 0) db.prepare("INSERT INTO deliveries(thread,n,session,delivered_at) VALUES (1,?,?,NULL)").run(i, key);
      if (i % 7 === 0) {
        db.prepare("INSERT INTO turns(id,session_key,kind,started_at,ended_at,outcome,declared,wait_seconds) VALUES (?,?,'user',?,?,'completed','waiting',60)").run(`t-${i}`, key, i, i + 1);
      }
      // Leave i < 3 (the conversation-backfill merge pair + lone session) without chat_shares so
      // `settle_conversation_in_tx` genuinely merges `bot2` into `slack:C99:1700000.1` and joins `homeTh`.
      if (i >= 3 && i < 18) {
        db.prepare("INSERT INTO chat_shares(session, shared, by, at) VALUES (?, ?, 'me', ?)").run(
          key,
          i === 17 ? JSON.stringify([{ workspace: "W1", used: 9007199254740991 }]) : JSON.stringify([{ workspace: `W${i % 2}`, used: 5000 + i }]),
          5000 + i,
        );
      }
    }
    db.prepare("INSERT INTO thread_sessions(thread,session,connect,joined_at,left_at) VALUES (?,?,?,?,NULL)").run(slackTh, "slack:C99:1700000.1", "slack", 1000);
    db.prepare("INSERT INTO thread_sessions(thread,session,connect,joined_at,left_at) VALUES (?,?,?,?,NULL)").run(slackTh, "bot2:C99:1700000.1", "slack", 1001);
    db.prepare("INSERT INTO thread_sessions(thread,session,connect,joined_at,left_at) VALUES (?,?,?,?,NULL)").run(homeTh, "slack:C99:1700000.1", "chat", 1000);

    for (let n = 1; n <= 80; n++) {
      const isEdit = n % 3 === 0;
      const card = n % 4 === 0 ? `你好🚀{"LOGIN":"User${n}","login":"tok${n}"}` : null;
      db.prepare("INSERT INTO entries(thread,n,kind,target,author_kind,author,text,at,ts,card) VALUES(?,?,?,?,?,?,?,?,?,?)").run(
        n % 2 === 0 ? th1 : th2,
        n,
        isEdit ? "edit" : "message",
        isEdit ? n - 1 : null,
        n % 2 === 0 ? "agent" : "person",
        "a",
        `txt-${n}`,
        n * 10,
        `ts-${n}`,
        card,
      );
    }
    for (let i = 1; i <= 80; i++) {
      db.prepare("INSERT INTO archive_policy(id,at,policy,author,summary,ws) VALUES (?,?,?,?,?,?)").run(i, i, "p", "a", "s", `W${i % 2}`);
      db.prepare("INSERT INTO decision_checks(id,session,created_at,result) VALUES (?,?,?,?)").run(i, `s-${i}`, i * 2, "ok");
      db.prepare("INSERT INTO jobs(rowid,id,token,session_key,state,watch,pgid,name,command,cwd,port,started_at,log) VALUES(?,?,?,?,?,?,?,?,'','',NULL,?,'')").run(
        i,
        i % 5 === 0 ? `remote_${i}` : `j${i}`,
        `jt${i}`,
        `s-${i % 5}`,
        i % 3 === 0 ? "exited" : "running",
        i % 4 === 0 ? 1 : 0,
        i % 2 === 0 ? 200 + i : null,
        `job-${i}`,
        i,
      );
    }
    db.exec("COMMIT");

    // Reset activity/recovery/awake
    db.exec(`DELETE FROM workspace_activity; UPDATE workspace_activity_meta SET cursor = NULL, complete = 0 WHERE id = 1;
      DELETE FROM session_recover_waits; UPDATE session_recover_wait_meta SET cursor = NULL, complete = 0 WHERE id = 1;
      UPDATE session_awake_wait_meta SET cursor = NULL, complete = 0 WHERE id = 1`);

    // Drop & install legacy lookups
    db.exec("DROP INDEX entries_edits");
    repairMergedEditLookup(db);
    installLegacySaid(db);
    installLegacyAgent(db);
    installLegacyLoginCards(db);
    installPageLetterIndex(db);
    const epoch = (db.prepare("SELECT epoch FROM page_letter_meta WHERE id=1").get() as { epoch: number }).epoch;
    db.prepare("INSERT INTO page_letter_scopes(thread,token,epoch,cursor_n,end_n,complete) VALUES (?,?,?,NULL,NULL,1)").run(th1, "stale-tok", epoch - 1);
    for (let n = 1; n <= 70; n++) {
      db.prepare("INSERT INTO page_letter_rows(thread,token,n) VALUES (?,?,?)").run(th1, "stale-tok", n);
    }
    db.exec("DROP INDEX IF EXISTS archive_policy_by_ws; DROP INDEX IF EXISTS decision_checks_lately; DROP INDEX IF EXISTS decision_checks_session");
    installArchivePolicyIndex(db);
    installDecisionTimeIndex(db);
    installDecisionSessionIndex(db);
    db.exec("DROP INDEX legacy_decision_session_by_session");
    installDecisionSessionIndex(db);

    // Drop active_watch_jobs / active_other_jobs and process_job_* so active-jobs and process-jobs run cold
    for (const r of db.prepare("SELECT name FROM sqlite_master WHERE type='trigger' AND (name LIKE 'process_job_%' OR name LIKE 'active_%')").all() as { name: string }[]) {
      db.exec(`DROP TRIGGER "${r.name}"`);
    }
    db.exec("DROP TABLE IF EXISTS process_job_meta; DROP TABLE IF EXISTS process_job_rows; DROP TABLE IF EXISTS process_job_replaced");
    db.exec("DROP TABLE IF EXISTS active_watch_jobs; DROP TABLE IF EXISTS active_other_jobs; DROP TABLE IF EXISTS active_job_upgrade; DROP TABLE IF EXISTS active_job_upgrade_replaced; DROP TABLE IF EXISTS active_remote_job_meta; DROP TABLE IF EXISTS active_remote_job_rows");

    db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
  } finally {
    store.close();
  }
}

test("all 19 session-backfill kinds + unknown/default/empty lines match MB 0-diff", async (t) => {
  const bins = resolveBinaries(t);
  if (!bins) return;

  const dir = freshDir("all-19-kinds-");
  const seedPath = join(dir, "seed.db");
  seedAll19KindsDb(seedPath, join(dir, "seed-archive"));

  const mbPath = join(dir, "mb.db");
  const pionPath = join(dir, "pion.db");
  copyFileSync(seedPath, mbPath);
  copyFileSync(seedPath, pionPath);

  const mbProc = new BuilderProc(bins.realMb, "session-backfill", mbPath);
  const pionProc = new BuilderProc(bins.realPion, "session-backfill", pionPath);

  const ALL_19_KINDS = [
    "activity",
    "recovery",
    "awake",
    "legacy-said",
    "legacy-edits",
    "legacy-policy",
    "directory",
    "chat-share",
    "sandbox",
    "sandbox-off",
    "active-jobs",
    "process-jobs",
    "legacy-agent",
    "legacy-login",
    "page-letter-gc",
    "legacy-decision-time",
    "legacy-decision-session",
    "legacy-decision-session-repair",
    "conversation-backfill",
  ] as const;

  const tBefore = Date.now();
  try {
    // Empty line silently skipped, bad JSON / missing kind / non-string kind route to activity, unknown string errors.
    mbProc.writeRaw("\n");
    pionProc.writeRaw("\n");
    for (const edge of ['{"kind":"bogus-kind"}', '{"kind":123}', '{}', 'not-json']) {
      const [mbR, pionR] = await Promise.all([mbProc.ask(edge), pionProc.ask(edge)]);
      assert.deepStrictEqual(pionR, mbR, `edge request ${edge} must match MB 0-diff`);
    }

    for (const kind of ALL_19_KINDS) {
      const req = JSON.stringify({ kind });
      let done = false;
      for (let step = 0; step < 30 && !done; step++) {
        const [mbR, pionR] = await Promise.all([mbProc.ask(req), pionProc.ask(req)]);
        assert.deepStrictEqual(pionR, mbR, `kind=${kind} step=${step} reply 0-diff`);
        assert.equal(pionR.error, undefined, `kind=${kind} step=${step} no error`);
        assert.equal(pionR.fallback, undefined, `kind=${kind} step=${step} no fallback`);
        done = mbR.done === true;
      }
      assert.equal(done, true, `kind=${kind} must converge to done=true`);
    }
  } finally {
    await Promise.all([mbProc.end(), pionProc.end()]);
  }
  const tAfter = Date.now();

  // Compare all tables except `thread_sessions` (whose `joined_at` uses wall clock for conversation-backfill).
  assert.equal(
    snapshotAllTables(pionPath, new Set(["thread_sessions"])),
    snapshotAllTables(mbPath, new Set(["thread_sessions"])),
    "all 19 kinds full SQLite tables + sqlite_master must match MB 0-diff",
  );

  // Verify `thread_sessions` content 0-diff + deterministic wall-clock range [tBefore - 1000, tAfter + 1000] for conversation-backfill.
  const readThreadSessions = (p: string) => {
    const db = new DatabaseSync(p);
    try {
      return db.prepare("SELECT thread, session, connect, joined_at, left_at FROM thread_sessions ORDER BY thread, session").all() as {
        thread: number;
        session: string;
        connect: string;
        joined_at: number;
        left_at: number | null;
      }[];
    } finally {
      db.close();
    }
  };
  const mbTs = readThreadSessions(mbPath);
  const pionTs = readThreadSessions(pionPath);
  assert.equal(pionTs.length, mbTs.length, "thread_sessions row count must match");
  // Explicitly verify that conversation-backfill genuinely merged `bot2:C99:1700000.1` into the
  // anchor's home thread (`connect = 'chat'`) in BOTH DBs and populated `joined_at` in wall range.
  const mbHomeBot2 = mbTs.filter((r) => r.session === "bot2:C99:1700000.1" && r.connect === "chat");
  const pionHomeBot2 = pionTs.filter((r) => r.session === "bot2:C99:1700000.1" && r.connect === "chat");
  assert.equal(mbHomeBot2.length, 1, "MB must insert unique home thread_sessions row for merged bot2");
  assert.equal(pionHomeBot2.length, 1, "Pion must insert unique home thread_sessions row for merged bot2");
  assert.equal(pionHomeBot2[0]!.thread, mbHomeBot2[0]!.thread, "merged bot2 home thread id must match");
  assert.ok(
    pionHomeBot2[0]!.joined_at >= tBefore - 1000 && pionHomeBot2[0]!.joined_at <= tAfter + 1000,
    `Pion joined_at ${pionHomeBot2[0]!.joined_at} must fall in wall window [${tBefore - 1000}, ${tAfter + 1000}]`,
  );
  // Note: MB `main.mbt:1060` passes `@host.now()` (CLOCK_MONOTONIC ms), whereas Pion passes
  // `host_shim::wall_ms()` (UTC epoch ms, matching TS `conversations.ts`); verify MB wrote a positive timestamp.
  assert.ok(
    Number.isSafeInteger(mbHomeBot2[0]!.joined_at) && mbHomeBot2[0]!.joined_at > 0,
    `MB joined_at ${mbHomeBot2[0]!.joined_at} must be a positive integer timestamp`,
  );
  for (let i = 0; i < mbTs.length; i++) {
    const m = mbTs[i]!;
    const p = pionTs[i]!;
    assert.equal(p.thread, m.thread);
    assert.equal(p.session, m.session);
    assert.equal(p.connect, m.connect);
    assert.equal(p.left_at, m.left_at);
    if (!(p.session === "bot2:C99:1700000.1" && p.connect === "chat")) {
      assert.equal(p.joined_at, m.joined_at);
    }
  }
});

// ── Test 3b: chat-share lone UTF-16 surrogate & 1e400 overflow dual-engine 0-diff ──

test("chat-share lone UTF-16 surrogate escapes and 1e400 overflow match MB 0-diff", async (t) => {
  const bins = resolveBinaries(t);
  if (!bins) return;

  const dir = freshDir("chat-share-surrogate-");
  const seedPath = join(dir, "seed.db");
  const store = Store.open(seedPath, join(dir, "seed-archive"));
  try {
    const ins = store.db.prepare("INSERT INTO chat_shares(session, shared, by, at) VALUES (?, ?, 'me', ?)");
    // 1. Lone surrogate in note + valid workspace "W1" -> MB @json.parse rejects whole doc -> 0 targets.
    ins.run("s-note-lone", '[{"note":"\\uD800","workspace":"W1"}]', 5000);
    // 2. Lone surrogate in workspace itself -> MB @json.parse rejects whole doc -> 0 targets.
    ins.run("s-ws-lone", '[{"workspace":"\\uD800"}]', 5000);
    // 3. Normal control row -> both engines write target "W1".
    ins.run("s-control", '[{"workspace":"W1","used":5000}]', 5000);
    // 4. Overflow numeric literal 1e400 (raw string literal, not JSON.stringify).
    ins.run("s-overflow", '[{"workspace":"W1","used":1e400}]', 5000);
    store.db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
  } finally {
    store.close();
  }

  const mbPath = join(dir, "mb.db");
  const pionPath = join(dir, "pion.db");
  copyFileSync(seedPath, mbPath);
  copyFileSync(seedPath, pionPath);

  const mbProc = new BuilderProc(bins.realMb, "session-backfill", mbPath);
  const pionProc = new BuilderProc(bins.realPion, "session-backfill", pionPath);
  try {
    const [mbR, pionR] = await Promise.all([
      mbProc.ask('{"kind":"chat-share"}'),
      pionProc.ask('{"kind":"chat-share"}'),
    ]);
    assert.deepStrictEqual(pionR, mbR, "chat-share reply 0-diff");
    assert.equal(pionR.done, true);
  } finally {
    await Promise.all([mbProc.end(), pionProc.end()]);
  }

  for (const [label, p] of [["mb", mbPath], ["pion", pionPath]] as const) {
    const db = new DatabaseSync(p);
    try {
      const targets = (
        db.prepare("SELECT session, ordinal, workspace, used FROM chat_share_targets ORDER BY session, ordinal").all() as Record<string, unknown>[]
      ).map((r) => ({ ...r }));
      const uncertain = (
        db.prepare("SELECT session FROM chat_share_uncertain ORDER BY session").all() as Record<string, unknown>[]
      ).map((r) => ({ ...r }));
      assert.deepStrictEqual(
        targets,
        [{ session: "s-control", ordinal: 0, workspace: "W1", used: 5000 }],
        `${label}: only control row may emit target W1; lone-surrogate & 1e400 rows must emit 0 targets`,
      );
      assert.deepStrictEqual(
        uncertain,
        [{ session: "s-overflow" }],
        `${label}: 1e400 overflow must be uncertain while lone-surrogate JSON parse fallback is empty targets`,
      );
    } finally {
      db.close();
    }
  }
  assert.equal(snapshotAllTables(pionPath), snapshotAllTables(mbPath), "chat-share lone surrogate & 1e400 tables 0-diff");
});

// ── Test 4: CJK/emoji UTF-16 login_card_meta.offset cross-engine hot-swap resume (MB -> Pion -> MB) ──

test("CJK/emoji login_card_meta.offset cross-engine hot-swap (MB -> Pion -> MB) produces 0-diff vs all-MB and all-Pion", async (t) => {
  const bins = resolveBinaries(t);
  if (!bins) return;

  const dir = freshDir("utf16-login-hotswap-");
  const seedPath = join(dir, "seed.db");
  const store = Store.open(seedPath, join(dir, "seed-archive"));
  try {
    const th = store.openThread("ember", "CHAT", "utf16-card", null, null).id;
    // Build one huge card with 150 login tokens interleaved with multi-byte CJK + 4-byte emoji (2 UTF-16 units each).
    const parts: string[] = [];
    for (let i = 0; i < 150; i++) {
      parts.push(`"note${i}":"中文测试🚀🎉${i}","LOGIN":"Tok${i}"`);
    }
    const hugeCard = `{${parts.join(",")}}`;
    store.db.prepare(
      "INSERT INTO entries(thread,n,kind,author_kind,author,text,at,ts,card) VALUES(?,1,'message','agent','a','x',100,'ts-1',?)",
    ).run(th, hugeCard);
    for (const r of store.db.prepare("SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'login_card_%'").all() as { name: string }[]) {
      store.db.exec(`DROP TRIGGER "${r.name}"`);
    }
    store.db.exec("DROP TABLE IF EXISTS login_card_meta; DROP TABLE IF EXISTS login_card_keys");
    installLegacyLoginCards(store.db);
    assert.equal(
      (store.db.prepare("SELECT scanned FROM login_card_meta WHERE id=1").get() as { scanned: number }).scanned,
      0,
      "login_card_meta must start unscanned for hot-swap test",
    );
    store.db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
  } finally {
    store.close();
  }

  const allMb = join(dir, "all-mb.db");
  const allPion = join(dir, "all-pion.db");
  const mixed = join(dir, "mixed.db");
  copyFileSync(seedPath, allMb);
  copyFileSync(seedPath, allPion);
  copyFileSync(seedPath, mixed);

  const runAll = async (bin: string, p: string) => {
    const proc = new BuilderProc(bin, "session-backfill", p);
    try {
      let steps = 0;
      for (; steps < 10; steps++) {
        const res = await proc.ask('{"kind":"legacy-login"}');
        assert.equal(res.error, undefined);
        if (res.done === true) break;
      }
      assert.ok(steps >= 2, `expected multi-batch login scan (>=3 steps for 150 tokens), got ${steps + 1}`);
    } finally {
      await proc.end();
    }
  };

  await runAll(bins.realMb, allMb);
  await runAll(bins.realPion, allPion);

  // Hot-swap mid-card: step 1 on MB -> check offset -> step 2 on Pion -> check offset -> finish on MB.
  {
    const p1 = new BuilderProc(bins.realMb, "session-backfill", mixed);
    try {
      const r1 = await p1.ask('{"kind":"legacy-login"}');
      assert.equal(r1.done, false, "batch 1 (MB) must pause mid-card after 64 tokens");
    } finally {
      await p1.end();
    }
    const db1 = new DatabaseSync(mixed);
    const off1 = (db1.prepare("SELECT offset FROM login_card_meta WHERE id=1").get() as { offset: number | null }).offset;
    db1.close();
    assert.ok(typeof off1 === "number" && off1 > 0, `expected positive UTF-16 offset after batch 1, got ${off1}`);

    const p2 = new BuilderProc(bins.realPion, "session-backfill", mixed);
    try {
      const r2 = await p2.ask('{"kind":"legacy-login"}');
      assert.equal(r2.done, false, "batch 2 (Pion) must resume at UTF-16 offset and pause after 128 tokens");
    } finally {
      await p2.end();
    }
    const db2 = new DatabaseSync(mixed);
    const off2 = (db2.prepare("SELECT offset FROM login_card_meta WHERE id=1").get() as { offset: number | null }).offset;
    db2.close();
    assert.ok(typeof off2 === "number" && off2 > off1!, `expected UTF-16 offset to advance (${off1} -> ${off2})`);

    const p3 = new BuilderProc(bins.realMb, "session-backfill", mixed);
    try {
      const r3 = await p3.ask('{"kind":"legacy-login"}');
      assert.equal(r3.done, true, "batch 3 (MB) must finish remaining 22 tokens cleanly");
    } finally {
      await p3.end();
    }
  }

  const snapMb = snapshotAllTables(allMb);
  assert.equal(snapshotAllTables(allPion), snapMb, "all-Pion login_card_keys + meta must match all-MB 0-diff");
  assert.equal(snapshotAllTables(mixed), snapMb, "MB->Pion->MB hot-swap must match all-MB 0-diff (0 lost, 0 corrupted)");

  const checkDb = new DatabaseSync(mixed);
  try {
    const cnt = (checkDb.prepare("SELECT COUNT(*) AS n FROM login_card_keys").get() as { n: number }).n;
    assert.equal(cnt, 150, "all 150 login tokens must be extracted across CJK/emoji hot-swap");
  } finally {
    checkDb.close();
  }
});

// ── Test 5: Static SQLite transaction guard + real in-closure & string-concat mutation tests ──

type PionStringExpr = { line: number; value: string };

function extractPionStringExprs(source: string): PionStringExpr[] {
  const exprs: PionStringExpr[] = [];
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
        else if (esc === '"') out += '"';
        else if (esc === "\\") out += "\\";
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

type SqlTok = { kind: "word"; upper: string } | { kind: "ident" } | { kind: "str" } | { kind: "semi" } | { kind: "other" };

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
      while (i < n) {
        if (sql[i] === "'") { i++; if (sql[i] === "'") { i++; continue; } break; }
        i++;
      }
      out.push({ kind: "str" });
      continue;
    }
    if (ch === '"' || ch === "`") {
      const q = ch;
      i++;
      while (i < n) {
        if (sql[i] === q) { i++; if (sql[i] === q) { i++; continue; } break; }
        i++;
      }
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
      violations.push(`${filename}:${expr.line}: forbidden raw transaction SQL "${tok.upper}" in literal ${JSON.stringify(expr.value)}`);
    }
  }
  return violations;
}

function injectIntoTxErrClosure(source: string, stmt: string): string {
  const re = /(fn\(tx_db : sql_db::Db\) -> [^\n{]+\{\n)/;
  assert.match(source, re, "expected db.tx_err closure `fn(tx_db : sql_db::Db) -> ... {`");
  return source.replace(re, `$1      ${stmt}\n`);
}

test("builders_legacy static transaction guard + real in-closure & string-concat mutation tests", () => {
  const srcDir = resolve(fileURLToPath(new URL("../../pion/station/packages/builders_legacy/src", import.meta.url)));
  assert.ok(existsSync(srcDir), `expected ${srcDir} to exist`);
  const files = readdirSync(srcDir).filter((f) => f.endsWith(".pion") && !f.endsWith("_test.pion")).sort();
  assert.deepStrictEqual(files, ["activity.pion", "conversations.pion", "dispatch.pion", "helpers.pion", "jobs.pion", "legacy.pion"]);

  const txFiles = new Set(["activity.pion", "conversations.pion", "jobs.pion", "legacy.pion"]);
  for (const file of files) {
    const content = readFileSync(join(srcDir, file), "utf8");
    assert.deepStrictEqual(
      findRawTxControlViolations(file, content),
      [],
      `${file} must contain zero raw transaction SQL violations`,
    );
    if (txFiles.has(file)) {
      for (const mut of [
        { stmt: 'let _ = tx_db.exec("COMMIT")', want: "COMMIT" },
        { stmt: 'let _ = tx_db.exec("BEGIN IMMEDIATE")', want: "BEGIN" },
        { stmt: 'let _ = tx_db.exec("ROLL" + "BACK")', want: "ROLLBACK" },
        { stmt: 'let _ = tx_db.exec("SAVE" + "POINT sp1")', want: "SAVEPOINT" },
      ]) {
        const mutated = injectIntoTxErrClosure(content, mut.stmt);
        assert.notEqual(mutated, content, `${file}: mutation must modify source`);
        const hits = findRawTxControlViolations(file, mutated);
        assert.equal(hits.length, 1, `${file}: injected ${mut.stmt} must be detected`);
        assert.ok(hits[0]!.includes(`"${mut.want}"`), `${file}: expected "${mut.want}", got ${hits[0]}`);
      }
    }
  }
});
