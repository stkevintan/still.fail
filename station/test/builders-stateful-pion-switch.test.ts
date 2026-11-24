// Real dual-engine production switch, stateful trigger/schema-change, SIGKILL restart,
// Int64 saturation, SQLITE_BUSY, and static transaction guard tests for `builders_stateful`:
//   archive-last, page-letters.
//
// Invariants verified WITHOUT ever passing an explicit `binary` override to any production builder:
// 1. Default `mb` genuinely spawns the real MoonBit `stillfail-reader` binary (never `stillfail-pion`).
// 2. Switching via `STILLFAIL_READER_ARCHIVE_LAST=pion` or `config.readers["page-letters"]="pion"`
//    (once the non-blocking `--version` capability probe resolves) genuinely spawns the real
//    `stillfail-pion` binary through `Readers.prepareArchiveLast` / `Readers.preparePageLetters`
//    and produces 0-diff SQLite tables + `sqlite_master` (including trigger DDL) against MoonBit.
// 3. A legacy `stillfail-pion` binary omitting `modes:` from `--version` safely falls back to MB
//    and logs one deduped `pion-binary-unsupported-mode` warning per mode.
// 4. Within one long-lived builder process, an external trigger drop/tamper (bumping
//    `PRAGMA schema_version`) invalidates the cached install state, triggers automatic reinstall
//    with a new epoch, and keeps full tables + `sqlite_master` 0-diff against MoonBit.
// 5. Mid-flight `SIGKILL` during multi-batch execution followed by process restart resumes cleanly
//    to `done === true` with 0-diff tables + `sqlite_master`.
// 6. Int64 upper-bound saturation (`9223372036854775808`, `1e400`), invalid/duplicate-key requests,
//    and deterministic `SQLITE_BUSY` held-lock recovery match MoonBit 0-diff.
// 7. Single-pass SQLite lexical transaction guard scans `builders_stateful/src/*.pion` with zero
//    violations and catches real in-memory mutations (`tx_db.exec("COMMIT")`) on both files.
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
import { Store } from "../src/store/store.ts";

const STATEFUL_MODES: readonly ReaderMode[] = ["archive-last", "page-letters"];
const ASK_TIMEOUT_MS = 30_000;
const MB_FAIL_PREFIX = /^\S+:\d+:\d+-\d+:\d+@\S+ FAILED: /;
const HEX32_RE = /^[0-9a-f]{32}$/;

const tempDirs: string[] = [];
after(() => {
  for (const dir of tempDirs) rmSync(dir, { recursive: true, force: true });
});

function freshDir(prefix = "builders-stateful-switch-"): string {
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

  async sigkill(): Promise<void> {
    this.#ending = true;
    this.#rejectAll(new Error("killed"));
    // Deliver SIGKILL before tearing down stdin so the child cannot observe EOF and exit 0 first.
    this.#child.kill("SIGKILL");
    const { signal } = await this.#closed;
    this.#child.stdin!.destroy();
    assert.equal(signal, "SIGKILL", `expected SIGKILL exit, got signal=${signal}`);
  }

  async cleanup(): Promise<void> {
    this.#ending = true;
    this.#rejectAll(new Error("cleanup"));
    if (this.#child.exitCode === null && this.#child.signalCode === null) {
      this.#child.kill("SIGKILL");
    }
    await this.#closed;
    this.#child.stdin!.destroy();
  }
}

function makeArchiveLastSeed(dir: string, label: string): { seedPath: string; threads: number[] } {
  const seedPath = join(dir, `${label}-seed.db`);
  const store = Store.open(seedPath, join(dir, `${label}-archive`));
  try {
    const put = store.db.prepare(
      "INSERT INTO entries(thread,n,kind,author_kind,author,text,ts,at,letter) VALUES(?,?,?,'person','me','x',?,?,?)",
    );
    const threads = [260, 150, 3, 0, -1].map((tail, i) => {
      const thread = store.openThread("ember", "CHAT", `${label}-${i}`, null, "me").id;
      store.db.exec("BEGIN");
      if (tail >= 0) put.run(thread, 1, "message", `m${i}`, 100 + i, null);
      for (let n = 2; n <= Math.max(tail, 3) + 1 && tail !== 0; n++) {
        put.run(thread, n, "edit", `e${i}-${n}`, n, n % 3 === 0 ? "{}" : null);
      }
      store.db.exec("COMMIT");
      return thread;
    });
    store.db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
    return { seedPath, threads };
  } finally {
    store.close();
  }
}

function makePageLettersSeed(dir: string, label: string, dropIndex = false): { seedPath: string; threads: number[] } {
  const seedPath = join(dir, `${label}-seed.db`);
  const store = Store.open(seedPath, join(dir, `${label}-archive`));
  try {
    const put = store.db.prepare(
      "INSERT INTO entries(thread,n,kind,letter,ts,author_kind,author,text,at) VALUES(?,?,?,?,?,'agent','a','x',?)",
    );
    const threads = [320, 180, 3].map((size, i) => {
      const thread = store.openThread("ember", "CHAT", `${label}-${i}`, null, null).id;
      store.db.exec("BEGIN");
      for (let n = 1; n <= size; n++) {
        put.run(thread, n, n % 4 === 0 ? "status" : "message", n % 3 === 0 ? null : "{}", `t${i}-${n}`, n);
      }
      store.db.exec("COMMIT");
      return thread;
    });
    if (dropIndex) store.db.exec("DROP INDEX entries_letters");
    store.db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
    return { seedPath, threads };
  } finally {
    store.close();
  }
}

function snapshotArchiveLast(dbPath: string): string {
  const db = new DatabaseSync(dbPath);
  try {
    const master = db.prepare("SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name").all();
    const meta = db.prepare("SELECT id, version, epoch FROM archive_last_meta ORDER BY id").all() as {
      id: number;
      version: number;
      epoch: string;
    }[];
    assert.equal(meta.length, 1, "archive_last_meta must have 1 row");
    assert.match(meta[0]!.epoch, HEX32_RE, `archive_last_meta.epoch must be 32-char hex, got ${meta[0]!.epoch}`);
    const guards = db.prepare(
      "SELECT typeof(thread) AS ty, CAST(thread AS TEXT) AS thread, epoch, before_n, at, ready FROM archive_last_guard ORDER BY thread",
    ).all() as { ty: string; thread: string; epoch: string; before_n: number | null; at: number | null; ready: number }[];
    for (const g of guards) {
      assert.equal(g.epoch, meta[0]!.epoch, `guard epoch must match current meta epoch for thread ${g.thread}`);
    }
    return JSON.stringify({
      master,
      metaVersion: meta[0]!.version,
      guards: guards.map(({ ty, thread, before_n, at, ready }) => ({ ty, thread, before_n, at, ready })),
    });
  } finally {
    db.close();
  }
}

function snapshotPageLetters(dbPath: string): string {
  const db = new DatabaseSync(dbPath);
  try {
    const master = db.prepare("SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name").all();
    const meta = db.prepare("SELECT id, version, epoch FROM page_letter_meta ORDER BY id").all() as {
      id: number;
      version: number;
      epoch: number;
    }[];
    assert.equal(meta.length, 1, "page_letter_meta must have 1 row");
    const scopes = db.prepare(
      "SELECT typeof(thread) AS ty, CAST(thread AS TEXT) AS thread, token, epoch, cursor_n, end_n, complete FROM page_letter_scopes ORDER BY thread",
    ).all() as {
      ty: string;
      thread: string;
      token: string;
      epoch: number;
      cursor_n: number | null;
      end_n: number | null;
      complete: number;
    }[];
    const tokenByThread = new Map<string, string>();
    for (const s of scopes) {
      assert.match(s.token, HEX32_RE, `scope token must be 32-char hex, got ${s.token}`);
      tokenByThread.set(s.thread, s.token);
    }
    const rows = db.prepare(
      "SELECT CAST(thread AS TEXT) AS thread, token, n FROM page_letter_rows ORDER BY thread, n",
    ).all() as { thread: string; token: string; n: number }[];
    const dirty = db.prepare(
      "SELECT CAST(thread AS TEXT) AS thread, token, n FROM page_letter_dirty ORDER BY thread, n",
    ).all() as { thread: string; token: string; n: number }[];
    const garbage = db.prepare(
      "SELECT CAST(thread AS TEXT) AS thread, token FROM page_letter_garbage ORDER BY thread, token",
    ).all() as { thread: string; token: string }[];
    // Map each active token to "active" and non-active tokens (e.g. from older epochs in garbage) to "stale",
    // then sort deterministically by (thread, n, tok) so random hex token ordering never perturbs ties.
    const tagToken = (thread: string, token: string) => (tokenByThread.get(thread) === token ? "active" : "stale");
    for (const g of garbage) {
      assert.match(g.token, HEX32_RE, `garbage token must be 32-char hex, got ${g.token}`);
      assert.equal(
        tagToken(g.thread, g.token),
        "stale",
        `active token must never be queued in page_letter_garbage (thread=${g.thread})`,
      );
    }
    const cmpTagged = (
      a: { thread: string; tok: string; n: number },
      b: { thread: string; tok: string; n: number },
    ) => (a.thread < b.thread ? -1 : a.thread > b.thread ? 1 : a.n - b.n || (a.tok < b.tok ? -1 : a.tok > b.tok ? 1 : 0));
    return JSON.stringify({
      master,
      meta,
      scopes: scopes.map(({ ty, thread, epoch, cursor_n, end_n, complete }) => ({
        ty,
        thread,
        epoch,
        cursor_n,
        end_n,
        complete,
      })),
      rows: rows.map((r) => ({ thread: r.thread, tok: tagToken(r.thread, r.token), n: r.n })).sort(cmpTagged),
      dirty: dirty.map((d) => ({ thread: d.thread, tok: tagToken(d.thread, d.token), n: d.n })).sort(cmpTagged),
      garbageCountByThread: garbage.reduce<Record<string, number>>((acc, g) => {
        acc[g.thread] = (acc[g.thread] ?? 0) + 1;
        return acc;
      }, {}),
    });
  } finally {
    db.close();
  }
}

test("builders_stateful: real MB default, real Pion switch (env + config.readers) via Readers with 0-diff, and legacy stub fallback", { skip: skipPosix }, async (t) => {
  const bins = resolveBinaries(t);
  if (!bins) return;

  const dir = freshDir();
  const mbLog = join(dir, "mb-spawns.log");
  const pionLog = join(dir, "pion-spawns.log");
  const legacyLog = join(dir, "legacy-pion-spawns.log");
  const mbWrap = makeRecordingWrapper(dir, "wrap-mb", bins.realMb, mbLog);
  const pionWrap = makeRecordingWrapper(dir, "wrap-pion", bins.realPion, pionLog);
  const legacyStub = makeLegacyPionStub(dir, "stub-legacy-pion", legacyLog);

  const archiveSeed = makeArchiveLastSeed(dir, "switch-al");
  const lettersSeed = makePageLettersSeed(dir, "switch-pl");

  const cleanEnv: Record<string, string | undefined> = {
    STILLFAIL_MB_READER: mbWrap,
    STILLFAIL_PION_READER: pionWrap,
    STILLFAIL_READER_ENGINE: undefined,
    [readerModeEnvKey("archive-last")]: undefined,
    [readerModeEnvKey("page-letters")]: undefined,
  };

  type ModeCase = {
    readonly mode: ReaderMode;
    readonly seedPath: string;
    readonly useConfig: boolean;
    readonly run: (dataDir: string, cfg?: () => ReaderSelectConfig) => Promise<void>;
    readonly snap: (dbPath: string) => string;
  };

  const cases: readonly ModeCase[] = [
    {
      mode: "archive-last",
      seedPath: archiveSeed.seedPath,
      useConfig: false, // via STILLFAIL_READER_ARCHIVE_LAST=pion
      run: async (dataDir, cfg) => {
        const readers = new Readers(dataDir, 1, undefined, 1, cfg ? { readers: cfg } : {});
        try {
          await readers.prepareArchiveLast(archiveSeed.threads);
        } finally {
          readers.close();
        }
      },
      snap: snapshotArchiveLast,
    },
    {
      mode: "page-letters",
      seedPath: lettersSeed.seedPath,
      useConfig: true, // via config.readers["page-letters"] = "pion"
      run: async (dataDir, cfg) => {
        const readers = new Readers(dataDir, 1, undefined, 1, cfg ? { readers: cfg } : {});
        try {
          await readers.preparePageLetters(lettersSeed.threads);
        } finally {
          readers.close();
        }
      },
      snap: snapshotPageLetters,
    },
  ];

  for (const c of cases) {
    // 1. Default `mb`: spawns MB reader only, never Pion.
    clearSpawns(mbLog);
    clearSpawns(pionLog);
    const mbDir = join(dir, `${c.mode}-mb`);
    mkdirSync(mbDir, { recursive: true });
    const mbDb = join(mbDir, "stillfail.db");
    copyFileSync(c.seedPath, mbDb);
    await withEnv(cleanEnv, () => c.run(mbDir));
    const mbSpawns = readSpawns(mbLog);
    const pionSpawnsDefault = readSpawns(pionLog);
    assert.ok(
      mbSpawns.some((l) => l.includes(`--builder ${c.mode}`)),
      `${c.mode}: default mb must spawn MB reader, got ${JSON.stringify(mbSpawns)}`,
    );
    assert.equal(pionSpawnsDefault.length, 0, `${c.mode}: default mb must not spawn Pion`);
    const mbSnap = c.snap(mbDb);

    // 2. Switch to Pion via env (`STILLFAIL_READER_ARCHIVE_LAST=pion`) or `config.readers["page-letters"]="pion"`.
    clearSpawns(mbLog);
    clearSpawns(pionLog);
    const pionDir = join(dir, `${c.mode}-pion`);
    mkdirSync(pionDir, { recursive: true });
    const pionDb = join(pionDir, "stillfail.db");
    copyFileSync(c.seedPath, pionDb);
    const envForPion: Record<string, string | undefined> = { ...cleanEnv };
    if (!c.useConfig) envForPion[readerModeEnvKey(c.mode)] = "pion";
    const cfgForPion: (() => ReaderSelectConfig) | undefined = c.useConfig
      ? () => ({ readers: { [c.mode]: "pion" } })
      : undefined;

    await withEnv(envForPion, async () => {
      const supported = await probePionSupportedModes(pionWrap);
      assert.ok(supported !== null && supported.has(c.mode), `${c.mode}: probed stillfail-pion must advertise ${c.mode}`);
      clearSpawns(pionLog);
      await c.run(pionDir, cfgForPion);
    });
    const mbSpawnsPion = readSpawns(mbLog);
    const pionSpawns = readSpawns(pionLog);
    assert.equal(mbSpawnsPion.length, 0, `${c.mode}: pion switch must NOT spawn MB reader, got ${JSON.stringify(mbSpawnsPion)}`);
    assert.ok(
      pionSpawns.some((l) => l.includes(`--builder ${c.mode}`)),
      `${c.mode}: pion switch must spawn real stillfail-pion, got ${JSON.stringify(pionSpawns)}`,
    );
    assert.equal(c.snap(pionDb), mbSnap, `${c.mode}: Pion tables + sqlite_master must match MB 0-diff`);
  }

  // 3. Legacy Pion stub omitting `modes:` -> safe fallback to MB + deduped `pion-binary-unsupported-mode`.
  const logs: Line[] = [];
  hearLines((l) => logs.push(l));
  try {
    await withEnv(
      {
        ...cleanEnv,
        STILLFAIL_PION_READER: legacyStub,
        STILLFAIL_READER_ENGINE: "pion",
      },
      async () => {
        const supported = await probePionSupportedModes(legacyStub);
        assert.ok(supported !== null, "legacy stub --version probe must succeed");
        for (const mode of STATEFUL_MODES) {
          assert.equal(supported.has(mode), false, `legacy stub must not advertise ${mode}`);
        }
        clearSpawns(legacyLog);
        for (const c of cases) {
          clearSpawns(mbLog);
          const fbDir = join(dir, `${c.mode}-fb`);
          mkdirSync(fbDir, { recursive: true });
          copyFileSync(c.seedPath, join(fbDir, "stillfail.db"));
          await c.run(fbDir);
          const mbSpawns = readSpawns(mbLog);
          assert.ok(
            mbSpawns.some((l) => l.includes(`--builder ${c.mode}`)),
            `${c.mode}: legacy stub must fall back to MB reader`,
          );
        }
        assert.equal(readSpawns(legacyLog).length, 0, "legacy stub must never be spawned for unsupported modes");
      },
    );
    const warns = logs.filter(
      (l) => l.level === "WARN" && l.message === "reader engine fallback" && l.fields.reason === "pion-binary-unsupported-mode",
    );
    assert.deepStrictEqual(
      warns.map((w) => w.fields.mode).sort(),
      [...STATEFUL_MODES].sort(),
      `expected exactly 1 deduped fallback warn per mode, got ${JSON.stringify(warns.map((w) => w.fields.mode))}`,
    );
  } finally {
    hearLines(null);
  }
});

function dropStatefulObjects(db: DatabaseSync): void {
  const trigs = db.prepare(
    "SELECT name FROM sqlite_master WHERE type='trigger' AND (name LIKE 'archive_last_%' OR name LIKE 'page_letter_%')",
  ).all() as { name: string }[];
  for (const t of trigs) db.exec(`DROP TRIGGER IF EXISTS "${t.name}"`);
  db.exec("DROP INDEX IF EXISTS page_letter_scope_epoch");
  const tables = db.prepare(
    "SELECT name FROM sqlite_master WHERE type='table' AND (name LIKE 'archive_last_%' OR name LIKE 'page_letter_%')",
  ).all() as { name: string }[];
  for (const tbl of tables) db.exec(`DROP TABLE IF EXISTS "${tbl.name}"`);
  const left = (db.prepare(
    "SELECT COUNT(*) AS n FROM sqlite_master WHERE name LIKE 'archive_last_%' OR name LIKE 'page_letter_%'",
  ).get() as { n: number }).n;
  assert.equal(left, 0, `expected all stateful tables/indexes/triggers dropped, ${left} remained`);
}

function readArchiveLastEpoch(dbPath: string): string {
  const db = new DatabaseSync(dbPath);
  try {
    return (db.prepare("SELECT epoch FROM archive_last_meta WHERE id=1").get() as { epoch: string }).epoch;
  } finally {
    db.close();
  }
}

function readPageLetterToken(dbPath: string, thread: number): string {
  const db = new DatabaseSync(dbPath);
  try {
    return (db.prepare("SELECT token FROM page_letter_scopes WHERE thread=?").get(thread) as { token: string }).token;
  } finally {
    db.close();
  }
}

function readPageLetterGarbageTokens(dbPath: string, thread: number): string[] {
  const db = new DatabaseSync(dbPath);
  try {
    return (
      db.prepare("SELECT token FROM page_letter_garbage WHERE thread=? ORDER BY token").all(thread) as { token: string }[]
    ).map((r) => r.token);
  } finally {
    db.close();
  }
}

async function runUntilDonePair(
  mbProc: BuilderProc,
  pionProc: BuilderProc,
  thread: number,
  label: string,
): Promise<void> {
  const ask = JSON.stringify({ thread });
  for (let step = 0; step < 20; step++) {
    const [mbRes, pionRes] = await Promise.all([mbProc.ask(ask), pionProc.ask(ask)]);
    assert.deepStrictEqual(pionRes, mbRes, `${label} step ${step}`);
    if (mbRes.done === true) return;
  }
  assert.fail(`${label}: did not converge to done=true within 20 steps`);
}

test("builders_stateful: cold install 0-diff and 3 independent reinstall scenarios (drop-1, strip-mark, missing-meta)", async (t) => {
  const bins = resolveBinaries(t);
  if (!bins) return;
  const dir = freshDir("builders-stateful-schema-");

  // 0. Cold install 0-diff: drop every archive_last_* and page_letter_* table/index/trigger before
  //    running MB and Pion cold so full DDL creation is verified against sqlite_master 0-diff.
  {
    const alSeed = makeArchiveLastSeed(dir, "cold-al");
    const plSeed = makePageLettersSeed(dir, "cold-pl");
    for (const seedPath of [alSeed.seedPath, plSeed.seedPath]) {
      const db = new DatabaseSync(seedPath);
      try {
        dropStatefulObjects(db);
        db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
      } finally {
        db.close();
      }
    }

    const alMb = join(dir, "cold-al-mb.db");
    const alPion = join(dir, "cold-al-pion.db");
    copyFileSync(alSeed.seedPath, alMb);
    copyFileSync(alSeed.seedPath, alPion);
    const alMbProc = new BuilderProc(bins.realMb, "archive-last", alMb);
    const alPionProc = new BuilderProc(bins.realPion, "archive-last", alPion);
    try {
      await runUntilDonePair(alMbProc, alPionProc, alSeed.threads[0]!, "cold archive-last");
      assert.equal(snapshotArchiveLast(alPion), snapshotArchiveLast(alMb), "cold archive-last sqlite_master + tables 0-diff");
    } finally {
      await Promise.all([alMbProc.end(), alPionProc.end()]);
    }

    const plMb = join(dir, "cold-pl-mb.db");
    const plPion = join(dir, "cold-pl-pion.db");
    copyFileSync(plSeed.seedPath, plMb);
    copyFileSync(plSeed.seedPath, plPion);
    const plMbProc = new BuilderProc(bins.realMb, "page-letters", plMb);
    const plPionProc = new BuilderProc(bins.realPion, "page-letters", plPion);
    try {
      await runUntilDonePair(plMbProc, plPionProc, plSeed.threads[0]!, "cold page-letters");
      assert.equal(snapshotPageLetters(plPion), snapshotPageLetters(plMb), "cold page-letters sqlite_master + tables 0-diff");
    } finally {
      await Promise.all([plMbProc.end(), plPionProc.end()]);
    }
  }

  // (a) Drop ONLY 1 trigger (keep the other 3 intact) -> live process detects schema_version bump and reinstalls.
  // (b) Keep all 4 trigger names, strip ONLY 1 trigger's version mark comment -> live process reinstalls.
  for (const scenario of ["drop-one", "strip-mark"] as const) {
    // archive-last
    {
      const { seedPath, threads } = makeArchiveLastSeed(dir, `reinstall-al-${scenario}`);
      const mbDb = join(dir, `reinstall-al-${scenario}-mb.db`);
      const pionDb = join(dir, `reinstall-al-${scenario}-pion.db`);
      copyFileSync(seedPath, mbDb);
      copyFileSync(seedPath, pionDb);

      const mbProc = new BuilderProc(bins.realMb, "archive-last", mbDb);
      const pionProc = new BuilderProc(bins.realPion, "archive-last", pionDb);
      try {
        await runUntilDonePair(mbProc, pionProc, threads[0]!, `archive-last ${scenario} initial`);
        const mbEpochBefore = readArchiveLastEpoch(mbDb);
        const pionEpochBefore = readArchiveLastEpoch(pionDb);

        for (const p of [mbDb, pionDb]) {
          const ext = new DatabaseSync(p);
          try {
            if (scenario === "drop-one") {
              ext.exec("DROP TRIGGER archive_last_update;");
            } else {
              ext.exec("DROP TRIGGER archive_last_delete;");
              ext.exec("CREATE TRIGGER archive_last_delete BEFORE DELETE ON entries BEGIN SELECT 1; END;");
            }
          } finally {
            ext.close();
          }
        }

        await runUntilDonePair(mbProc, pionProc, threads[1]!, `archive-last ${scenario} thread 1`);
        assert.notEqual(readArchiveLastEpoch(mbDb), mbEpochBefore, `MB archive-last must rotate epoch (${scenario})`);
        assert.notEqual(readArchiveLastEpoch(pionDb), pionEpochBefore, `Pion archive-last must rotate epoch (${scenario})`);
        await runUntilDonePair(mbProc, pionProc, threads[0]!, `archive-last ${scenario} thread 0 re-run`);
        assert.equal(
          snapshotArchiveLast(pionDb),
          snapshotArchiveLast(mbDb),
          `archive-last (${scenario}) tables + sqlite_master 0-diff`,
        );
      } finally {
        await Promise.all([mbProc.end(), pionProc.end()]);
      }
    }

    // page-letters (with exact oldToken identity assertions in page_letter_garbage)
    {
      const { seedPath, threads } = makePageLettersSeed(dir, `reinstall-pl-${scenario}`);
      const mbDb = join(dir, `reinstall-pl-${scenario}-mb.db`);
      const pionDb = join(dir, `reinstall-pl-${scenario}-pion.db`);
      copyFileSync(seedPath, mbDb);
      copyFileSync(seedPath, pionDb);

      const mbProc = new BuilderProc(bins.realMb, "page-letters", mbDb);
      const pionProc = new BuilderProc(bins.realPion, "page-letters", pionDb);
      try {
        await runUntilDonePair(mbProc, pionProc, threads[0]!, `page-letters ${scenario} initial`);
        const mbOldToken = readPageLetterToken(mbDb, threads[0]!);
        const pionOldToken = readPageLetterToken(pionDb, threads[0]!);

        for (const p of [mbDb, pionDb]) {
          const ext = new DatabaseSync(p);
          try {
            if (scenario === "drop-one") {
              ext.exec("DROP TRIGGER page_letter_delete;");
            } else {
              ext.exec("DROP TRIGGER page_letter_insert;");
              ext.exec("CREATE TRIGGER page_letter_insert BEFORE INSERT ON entries BEGIN SELECT 1; END;");
            }
          } finally {
            ext.close();
          }
        }

        await runUntilDonePair(mbProc, pionProc, threads[1]!, `page-letters ${scenario} thread 1`);
        await runUntilDonePair(mbProc, pionProc, threads[0]!, `page-letters ${scenario} thread 0 re-run`);

        for (const [label, p, oldToken] of [
          ["mb", mbDb, mbOldToken],
          ["pion", pionDb, pionOldToken],
        ] as const) {
          const db = new DatabaseSync(p);
          try {
            const meta = db.prepare("SELECT epoch FROM page_letter_meta WHERE id=1").get() as { epoch: number };
            assert.equal(meta.epoch, 2, `${label} (${scenario}): page_letter_meta.epoch must increment to 2`);
          } finally {
            db.close();
          }
          const activeToken = readPageLetterToken(p, threads[0]!);
          const garbageTokens = readPageLetterGarbageTokens(p, threads[0]!);
          assert.notEqual(activeToken, oldToken, `${label} (${scenario}): activeToken must rotate`);
          assert.deepStrictEqual(
            garbageTokens,
            [oldToken],
            `${label} (${scenario}): page_letter_garbage for thread 0 must contain exact [oldToken]`,
          );
          assert.equal(
            garbageTokens.includes(activeToken),
            false,
            `${label} (${scenario}): activeToken must not appear in page_letter_garbage`,
          );
        }
        assert.equal(
          snapshotPageLetters(pionDb),
          snapshotPageLetters(mbDb),
          `page-letters (${scenario}) tables + sqlite_master 0-diff`,
        );
      } finally {
        await Promise.all([mbProc.end(), pionProc.end()]);
      }
    }
  }

  // (c) Missing archive_last_meta row without bumping PRAGMA schema_version:
  //     1st ask clears cached schema_version and returns {done:false}; subsequent asks reinstall,
  //     rotate epoch, and converge to {done:true} with 0-diff.
  {
    const { seedPath, threads } = makeArchiveLastSeed(dir, "reinstall-al-missing-meta");
    const mbDb = join(dir, "reinstall-al-missing-meta-mb.db");
    const pionDb = join(dir, "reinstall-al-missing-meta-pion.db");
    copyFileSync(seedPath, mbDb);
    copyFileSync(seedPath, pionDb);

    const mbProc = new BuilderProc(bins.realMb, "archive-last", mbDb);
    const pionProc = new BuilderProc(bins.realPion, "archive-last", pionDb);
    try {
      await runUntilDonePair(mbProc, pionProc, threads[0]!, "missing-meta initial");
      const mbEpochBefore = readArchiveLastEpoch(mbDb);
      const pionEpochBefore = readArchiveLastEpoch(pionDb);

      for (const p of [mbDb, pionDb]) {
        const ext = new DatabaseSync(p);
        try {
          const svBefore = (ext.prepare("PRAGMA schema_version").get() as { schema_version: number }).schema_version;
          ext.exec("DELETE FROM archive_last_meta;");
          const svAfter = (ext.prepare("PRAGMA schema_version").get() as { schema_version: number }).schema_version;
          assert.equal(svAfter, svBefore, "DELETE FROM archive_last_meta must not bump PRAGMA schema_version");
        } finally {
          ext.close();
        }
      }

      // First ask hits cached schema_version -> sees meta missing -> clears cache & returns {done:false}.
      const askThread2 = JSON.stringify({ thread: threads[2] }); // short thread (3 edits) would finish in 1 step if meta existed
      const [mbFirst, pionFirst] = await Promise.all([mbProc.ask(askThread2), pionProc.ask(askThread2)]);
      assert.deepStrictEqual(pionFirst, { done: false }, "Pion must return {done:false} when archive_last_meta is deleted");
      assert.deepStrictEqual(pionFirst, mbFirst, "missing-meta 1st response must match MB 0-diff");

      // Subsequent ask reinstalls meta with a rotated epoch and finishes thread 2.
      await runUntilDonePair(mbProc, pionProc, threads[2]!, "missing-meta recover thread 2");
      assert.notEqual(readArchiveLastEpoch(mbDb), mbEpochBefore, "MB must rotate epoch after missing-meta recovery");
      assert.notEqual(readArchiveLastEpoch(pionDb), pionEpochBefore, "Pion must rotate epoch after missing-meta recovery");
      await runUntilDonePair(mbProc, pionProc, threads[0]!, "missing-meta re-run thread 0");
      assert.equal(
        snapshotArchiveLast(pionDb),
        snapshotArchiveLast(mbDb),
        "archive-last missing-meta recovery tables + sqlite_master 0-diff",
      );
    } finally {
      await Promise.all([mbProc.end(), pionProc.end()]);
    }
  }
});

test("builders_stateful: page-letters dirty_overflow exact 64 vs 65 threshold on both scan-completion and reconcile exits (0-diff)", async (t) => {
  const bins = resolveBinaries(t);
  if (!bins) return;
  const dir = freshDir("builders-stateful-dirty-");

  for (const dirtyCount of [64, 65] as const) {
    // Exit 1: incomplete scan finishing (rows.length() < 64) with exactly 64 vs 65 dirty rows.
    {
      const seedPath = join(dir, `dirty-scan-${dirtyCount}-seed.db`);
      let threadId = 0;
      {
        const store = Store.open(seedPath, join(dir, `dirty-scan-${dirtyCount}-arch`));
        try {
          threadId = store.openThread("ember", "CHAT", `dirty-scan-${dirtyCount}`, null, null).id;
          const put = store.db.prepare(
            "INSERT INTO entries(thread,n,kind,letter,ts,author_kind,author,text,at) VALUES(?,?,?,?,?,'agent','a','x',?)",
          );
          store.db.exec("BEGIN");
          // 80 letter entries: batch 1 scans 64 (complete=0), batch 2 scans 16 (< 64, complete becomes 1).
          for (let n = 1; n <= 80; n++) put.run(threadId, n, "message", "{}", `ds-${n}`, n);
          store.db.exec("COMMIT");
          store.db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
        } finally {
          store.close();
        }
      }
      const mbDb = join(dir, `dirty-scan-${dirtyCount}-mb.db`);
      const pionDb = join(dir, `dirty-scan-${dirtyCount}-pion.db`);
      copyFileSync(seedPath, mbDb);
      copyFileSync(seedPath, pionDb);

      const mbProc = new BuilderProc(bins.realMb, "page-letters", mbDb);
      const pionProc = new BuilderProc(bins.realPion, "page-letters", pionDb);
      try {
        const ask = JSON.stringify({ thread: threadId });
        const [m1, p1] = await Promise.all([mbProc.ask(ask), pionProc.ask(ask)]);
        assert.deepStrictEqual(p1, { done: false });
        assert.deepStrictEqual(p1, m1);

        // Inject exactly 64 or 65 dirty rows for the active scope token before batch 2 completes the scan.
        for (const p of [mbDb, pionDb]) {
          const tok = readPageLetterToken(p, threadId);
          const ext = new DatabaseSync(p);
          try {
            const ins = ext.prepare("INSERT INTO page_letter_dirty(thread,token,n) VALUES(?,?,?)");
            ext.exec("BEGIN");
            for (let n = 1; n <= dirtyCount; n++) ins.run(threadId, tok, n);
            ext.exec("COMMIT");
          } finally {
            ext.close();
          }
        }

        const [m2, p2] = await Promise.all([mbProc.ask(ask), pionProc.ask(ask)]);
        assert.deepStrictEqual(
          p2,
          { done: dirtyCount === 64 },
          `scan-completion exit with ${dirtyCount} dirty rows must return done=${dirtyCount === 64}`,
        );
        assert.deepStrictEqual(p2, m2, `scan-completion exit (${dirtyCount}) must match MB 0-diff`);
        assert.equal(snapshotPageLetters(pionDb), snapshotPageLetters(mbDb), `scan-completion (${dirtyCount}) DB 0-diff`);
      } finally {
        await Promise.all([mbProc.end(), pionProc.end()]);
      }
    }

    // Exit 2: reconcile exit (complete=1) where 64 rows are reconciled, leaving exactly 64 vs 65 remaining.
    {
      const seedPath = join(dir, `dirty-rec-${dirtyCount}-seed.db`);
      let threadId = 0;
      {
        const store = Store.open(seedPath, join(dir, `dirty-rec-${dirtyCount}-arch`));
        try {
          threadId = store.openThread("ember", "CHAT", `dirty-rec-${dirtyCount}`, null, null).id;
          store.db.prepare(
            "INSERT INTO entries(thread,n,kind,letter,ts,author_kind,author,text,at) VALUES(?,1,'message','{}','dr-1','agent','a','x',1)",
          ).run(threadId);
          store.db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
        } finally {
          store.close();
        }
      }
      const mbDb = join(dir, `dirty-rec-${dirtyCount}-mb.db`);
      const pionDb = join(dir, `dirty-rec-${dirtyCount}-pion.db`);
      copyFileSync(seedPath, mbDb);
      copyFileSync(seedPath, pionDb);

      const mbProc = new BuilderProc(bins.realMb, "page-letters", mbDb);
      const pionProc = new BuilderProc(bins.realPion, "page-letters", pionDb);
      try {
        const ask = JSON.stringify({ thread: threadId });
        const [m1, p1] = await Promise.all([mbProc.ask(ask), pionProc.ask(ask)]);
        assert.deepStrictEqual(p1, { done: true });
        assert.deepStrictEqual(p1, m1);

        // Insert 64 + dirtyCount dirty keys so one 64-key reconcile batch leaves exactly dirtyCount (64 or 65) remaining.
        const totalDirty = 64 + dirtyCount;
        for (const p of [mbDb, pionDb]) {
          const tok = readPageLetterToken(p, threadId);
          const ext = new DatabaseSync(p);
          try {
            const ins = ext.prepare("INSERT INTO page_letter_dirty(thread,token,n) VALUES(?,?,?)");
            ext.exec("BEGIN");
            for (let n = 1; n <= totalDirty; n++) ins.run(threadId, tok, n);
            ext.exec("COMMIT");
          } finally {
            ext.close();
          }
        }

        const [m2, p2] = await Promise.all([mbProc.ask(ask), pionProc.ask(ask)]);
        assert.deepStrictEqual(
          p2,
          { done: dirtyCount === 64 },
          `reconcile exit leaving ${dirtyCount} dirty rows must return done=${dirtyCount === 64}`,
        );
        assert.deepStrictEqual(p2, m2, `reconcile exit (${dirtyCount}) must match MB 0-diff`);
        assert.equal(snapshotPageLetters(pionDb), snapshotPageLetters(mbDb), `reconcile (${dirtyCount}) DB 0-diff`);
      } finally {
        await Promise.all([mbProc.end(), pionProc.end()]);
      }
    }
  }
});

test("builders_stateful: SIGKILL between batches and restart resumes cleanly with 0-diff", async (t) => {
  const bins = resolveBinaries(t);
  if (!bins) return;
  const dir = freshDir("builders-stateful-kill-");

  // 1. archive-last: 260-edit thread needs 5 batches; SIGKILL after 2 batches, restart, finish to done=true.
  {
    const { seedPath, threads } = makeArchiveLastSeed(dir, "kill-al");
    const mbDb = join(dir, "kill-al-mb.db");
    const pionDb = join(dir, "kill-al-pion.db");
    copyFileSync(seedPath, mbDb);
    copyFileSync(seedPath, pionDb);

    const ask = JSON.stringify({ thread: threads[0] });
    const mb1 = new BuilderProc(bins.realMb, "archive-last", mbDb);
    const pion1 = new BuilderProc(bins.realPion, "archive-last", pionDb);
    try {
      for (let i = 0; i < 2; i++) {
        const [m, p] = await Promise.all([mb1.ask(ask), pion1.ask(ask)]);
        assert.deepStrictEqual(p, { done: false });
        assert.deepStrictEqual(p, m);
      }
      await Promise.all([mb1.sigkill(), pion1.sigkill()]);
    } finally {
      await Promise.all([mb1.cleanup(), pion1.cleanup()]);
    }

    const mb2 = new BuilderProc(bins.realMb, "archive-last", mbDb);
    const pion2 = new BuilderProc(bins.realPion, "archive-last", pionDb);
    try {
      let finished = false;
      for (let i = 0; i < 20; i++) {
        const [m, p] = await Promise.all([mb2.ask(ask), pion2.ask(ask)]);
        assert.deepStrictEqual(p, m, `archive-last post-SIGKILL step ${i}`);
        if (m.done === true) {
          finished = true;
          break;
        }
      }
      assert.equal(finished, true, "archive-last must finish after SIGKILL restart");
      assert.equal(snapshotArchiveLast(pionDb), snapshotArchiveLast(mbDb), "archive-last post-SIGKILL 0-diff");
    } finally {
      await Promise.all([mb2.end(), pion2.end()]);
    }
  }

  // 2. page-letters (both with and without entries_letters index): SIGKILL after 2 batches, restart, finish.
  for (const dropIndex of [false, true]) {
    const label = dropIndex ? "kill-pl-noindex" : "kill-pl-idx";
    const { seedPath, threads } = makePageLettersSeed(dir, label, dropIndex);
    const mbDb = join(dir, `${label}-mb.db`);
    const pionDb = join(dir, `${label}-pion.db`);
    copyFileSync(seedPath, mbDb);
    copyFileSync(seedPath, pionDb);

    const ask = JSON.stringify({ thread: threads[0] });
    const mb1 = new BuilderProc(bins.realMb, "page-letters", mbDb);
    const pion1 = new BuilderProc(bins.realPion, "page-letters", pionDb);
    try {
      for (let i = 0; i < 2; i++) {
        const [m, p] = await Promise.all([mb1.ask(ask), pion1.ask(ask)]);
        assert.deepStrictEqual(p, { done: false });
        assert.deepStrictEqual(p, m);
      }
      await Promise.all([mb1.sigkill(), pion1.sigkill()]);
    } finally {
      await Promise.all([mb1.cleanup(), pion1.cleanup()]);
    }

    const mb2 = new BuilderProc(bins.realMb, "page-letters", mbDb);
    const pion2 = new BuilderProc(bins.realPion, "page-letters", pionDb);
    try {
      let finished = false;
      for (let i = 0; i < 20; i++) {
        const [m, p] = await Promise.all([mb2.ask(ask), pion2.ask(ask)]);
        assert.deepStrictEqual(p, m, `${label} post-SIGKILL step ${i}`);
        if (m.done === true) {
          finished = true;
          break;
        }
      }
      assert.equal(finished, true, `${label} must finish after SIGKILL restart`);
      assert.equal(snapshotPageLetters(pionDb), snapshotPageLetters(mbDb), `${label} post-SIGKILL 0-diff`);
    } finally {
      await Promise.all([mb2.end(), pion2.end()]);
    }
  }
});

test("builders_stateful: Int64 saturation (2^63, 1e400, -2^63-1, -1e400), fractional truncation (1.9), invalid asks, and deterministic SQLITE_BUSY", async (t) => {
  const bins = resolveBinaries(t);
  if (!bins) return;
  const dir = freshDir("builders-stateful-edge-");

  for (const mode of STATEFUL_MODES) {
    const seedPath = join(dir, `edge-${mode}-seed.db`);
    let truncThread = 0;
    let busyThread = 0;
    {
      const store = Store.open(seedPath, join(dir, `edge-${mode}-archive`));
      try {
        truncThread = store.openThread("ember", "CHAT", `edge-${mode}-trunc`, null, "me").id;
        assert.equal(truncThread, 1, "first opened thread must be id=1 for fractional 1.9 truncation check");
        busyThread = store.openThread("ember", "CHAT", `edge-${mode}-busy`, null, "me").id;
        const put = store.db.prepare(
          "INSERT INTO entries(thread,n,kind,author_kind,author,text,ts,at,letter) VALUES(?,1,'message','agent','a','hi',?,?,?)",
        );
        put.run(truncThread, "t-trunc", 555, "{}");
        put.run(busyThread, "t-busy", 666, "{}");
        // Seed at INT64_MAX (9223372036854775807n): 2^63 / 1e400 saturates to INT64_MAX whose to_double() is 2^63
        // (binds as REAL 9.223372036854776e18), so it must NOT match INT64_MAX.
        put.run(9223372036854775807n, "t-max", 999, "{}");
        // Seed at INT64_MIN (-9223372036854775808n): -2^63-1 / -1e400 saturates to INT64_MIN whose to_double() is -2^63
        // (exact in IEEE-754, binds as INTEGER INT64_MIN), so it MUST match INT64_MIN.
        put.run(-9223372036854775808n, "t-min", 777, "{}");
        store.db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
      } finally {
        store.close();
      }
    }

    const mbDb = join(dir, `edge-${mode}-mb.db`);
    const pionDb = join(dir, `edge-${mode}-pion.db`);
    copyFileSync(seedPath, mbDb);
    copyFileSync(seedPath, pionDb);

    const mbProc = new BuilderProc(bins.realMb, mode, mbDb);
    const pionProc = new BuilderProc(bins.realPion, mode, pionDb);
    try {
      // 1. Int64 upper/lower saturation + fractional truncation (1.9 -> 1) + invalid/duplicate asks.
      const asks = [
        '{"thread":9223372036854775808}',
        '{"thread":1e400}',
        '{"thread":-9223372036854775809}',
        '{"thread":-1e400}',
        '{"thread":1.9}',
        "{}",
        '{"thread":"1"}',
        "{bad json",
        '{"thread":1,"thread":"bad"}',
      ];
      for (const ask of asks) {
        const [m, p] = await Promise.all([mbProc.ask(ask), pionProc.ask(ask)]);
        assert.deepStrictEqual(p, m, `${mode}: ask=${ask} response must match MB 0-diff`);
      }

      if (mode === "archive-last") {
        assert.equal(snapshotArchiveLast(pionDb), snapshotArchiveLast(mbDb), "archive-last saturation/truncation DB 0-diff");
        const db = new DatabaseSync(pionDb);
        try {
          const minRow = db.prepare(
            "SELECT typeof(thread) AS ty, at, ready FROM archive_last_guard WHERE thread = -9223372036854775808",
          ).get() as { ty: string; at: number | null; ready: number } | undefined;
          assert.ok(minRow !== undefined, "archive-last -2^63-1/-1e400 must hit INT64_MIN");
          assert.deepStrictEqual({ ...minRow }, { ty: "integer", at: 777, ready: 1 }, "archive-last -2^63-1/-1e400 must hit INT64_MIN");
          const truncRow = db.prepare(
            "SELECT typeof(thread) AS ty, at, ready FROM archive_last_guard WHERE thread = 1",
          ).get() as { ty: string; at: number | null; ready: number } | undefined;
          assert.ok(truncRow !== undefined, "archive-last 1.9 must truncate to thread=1");
          assert.deepStrictEqual({ ...truncRow }, { ty: "integer", at: 555, ready: 1 }, "archive-last 1.9 must truncate to thread=1");
          const maxRow = db.prepare(
            "SELECT at FROM archive_last_guard WHERE thread = 9223372036854775807",
          ).get();
          assert.equal(maxRow, undefined, "archive-last 2^63/1e400 must not match INT64_MAX");
        } finally {
          db.close();
        }
      } else {
        assert.equal(snapshotPageLetters(pionDb), snapshotPageLetters(mbDb), "page-letters saturation/truncation DB 0-diff");
        const db = new DatabaseSync(pionDb);
        try {
          const matchedThreads = (
            db.prepare("SELECT CAST(thread AS TEXT) AS t, n FROM page_letter_rows ORDER BY thread, n").all() as { t: string; n: number }[]
          ).map((r) => ({ ...r }));
          assert.deepStrictEqual(
            matchedThreads,
            [
              { t: "-9223372036854775808", n: 1 },
              { t: "1", n: 1 },
            ],
            "page-letters must match INT64_MIN and thread=1 (from 1.9), never INT64_MAX",
          );
        } finally {
          db.close();
        }
      }

      // 2. Deterministic SQLITE_BUSY: hold BEGIN IMMEDIATE on external connections, send valid ask for busyThread,
      // assert both MB and Pion return `{"done":false}` with no error, then release and verify recovery.
      const mbLock = new DatabaseSync(mbDb);
      const pionLock = new DatabaseSync(pionDb);
      const busyAsk = JSON.stringify({ thread: busyThread });
      try {
        mbLock.exec("BEGIN IMMEDIATE");
        pionLock.exec("BEGIN IMMEDIATE");
        const [mbBusy, pionBusy] = await Promise.all([mbProc.ask(busyAsk), pionProc.ask(busyAsk)]);
        assert.deepStrictEqual(pionBusy, { done: false }, `${mode}: Pion must return retryable busy {done:false}`);
        assert.deepStrictEqual(pionBusy, mbBusy, `${mode}: busy response must match MB 0-diff`);
      } finally {
        mbLock.exec("ROLLBACK");
        pionLock.exec("ROLLBACK");
        mbLock.close();
        pionLock.close();
      }

      // After releasing the lock, the same builder processes must recover and finish cleanly.
      const [mbAfter, pionAfter] = await Promise.all([mbProc.ask(busyAsk), pionProc.ask(busyAsk)]);
      assert.deepStrictEqual(pionAfter, { done: true }, `${mode}: Pion must recover to done=true after lock release`);
      assert.deepStrictEqual(pionAfter, mbAfter, `${mode}: recovery response must match MB 0-diff`);

      if (mode === "archive-last") {
        assert.equal(snapshotArchiveLast(pionDb), snapshotArchiveLast(mbDb), "archive-last post-busy 0-diff");
      } else {
        assert.equal(snapshotPageLetters(pionDb), snapshotPageLetters(mbDb), "page-letters post-busy 0-diff");
      }
    } finally {
      await Promise.all([mbProc.end(), pionProc.end()]);
    }
  }
});

// ── Static SQLite transaction guard + real file mutation test ──

type SqlToken =
  | { kind: "word"; upper: string }
  | { kind: "semi" }
  | { kind: "other" };

function unescapePionString(raw: string): string {
  let out = "";
  for (let i = 0; i < raw.length; i++) {
    const ch = raw[i]!;
    if (ch === "\\" && i + 1 < raw.length) {
      const next = raw[i + 1]!;
      if (next === "n") out += "\n";
      else if (next === "r") out += "\r";
      else if (next === "t") out += "\t";
      else out += next;
      i++;
    } else {
      out += ch;
    }
  }
  return out;
}

function isSqlIdentStart(code: number): boolean {
  return (
    (code >= 65 && code <= 90) ||
    (code >= 97 && code <= 122) ||
    code === 95 ||
    (code >= 0x80 && code !== 0xfeff)
  );
}

function isSqlIdentPart(code: number): boolean {
  return isSqlIdentStart(code) || (code >= 48 && code <= 57) || code === 36; // digits and '$'
}

function tokenizeSql(sql: string): SqlToken[] {
  const tokens: SqlToken[] = [];
  let i = 0;
  const n = sql.length;
  while (i < n) {
    const ch = sql[i]!;
    const code = sql.charCodeAt(i);
    if (
      ch === " " ||
      ch === "\t" ||
      ch === "\r" ||
      ch === "\n" ||
      ch === "\f" ||
      ch === "\v" ||
      code === 0xfeff
    ) {
      i++;
      continue;
    }
    if (ch === "-" && i + 1 < n && sql[i + 1] === "-") {
      i += 2;
      while (i < n && sql[i] !== "\n") i++;
      continue;
    }
    if (ch === "/" && i + 1 < n && sql[i + 1] === "*") {
      i += 2;
      while (i + 1 < n && !(sql[i] === "*" && sql[i + 1] === "/")) i++;
      i = Math.min(i + 2, n);
      continue;
    }
    if (ch === "'" || ch === '"' || ch === "`") {
      const quote = ch;
      i++;
      while (i < n) {
        if (sql[i] === quote) {
          if (i + 1 < n && sql[i + 1] === quote) {
            i += 2;
            continue;
          }
          i++;
          break;
        }
        i++;
      }
      tokens.push({ kind: "other" });
      continue;
    }
    if (ch === "[") {
      i++;
      while (i < n && sql[i] !== "]") i++;
      if (i < n) i++;
      tokens.push({ kind: "other" });
      continue;
    }
    if (ch === ";") {
      tokens.push({ kind: "semi" });
      i++;
      continue;
    }
    if (isSqlIdentStart(code)) {
      const start = i;
      i++;
      while (i < n && isSqlIdentPart(sql.charCodeAt(i))) {
        i++;
      }
      tokens.push({ kind: "word", upper: sql.slice(start, i).toUpperCase() });
      continue;
    }
    tokens.push({ kind: "other" });
    i++;
  }
  return tokens;
}

/// Extract string literal expressions from Pion source, folding adjacent string literals joined
/// by `+` (ignoring comments and whitespace between them) while keeping separate expressions
/// strictly isolated so trigger state never leaks across statements or functions.
function extractPionStringExprs(source: string): { line: number; value: string }[] {
  const out: { line: number; value: string }[] = [];
  let i = 0;
  let line = 1;
  const n = source.length;

  const skipWsAndComments = () => {
    while (i < n) {
      const ch = source[i]!;
      if (ch === "\n") {
        line++;
        i++;
      } else if (ch === " " || ch === "\t" || ch === "\r") {
        i++;
      } else if (ch === "/" && i + 1 < n && source[i + 1] === "/") {
        i += 2;
        while (i < n && source[i] !== "\n") i++;
      } else if (ch === "/" && i + 1 < n && source[i + 1] === "*") {
        i += 2;
        while (i + 1 < n && !(source[i] === "*" && source[i + 1] === "/")) {
          if (source[i] === "\n") line++;
          i++;
        }
        i = Math.min(i + 2, n);
      } else {
        break;
      }
    }
  };

  const readString = (): string => {
    i++; // opening '"'
    const start = i;
    while (i < n) {
      const ch = source[i]!;
      if (ch === "\\" && i + 1 < n) {
        if (source[i + 1] === "\n") line++;
        i += 2;
        continue;
      }
      if (ch === '"') {
        const raw = source.slice(start, i);
        i++;
        return unescapePionString(raw);
      }
      if (ch === "\n") line++;
      i++;
    }
    return unescapePionString(source.slice(start));
  };

  while (i < n) {
    skipWsAndComments();
    if (i >= n) break;
    if (source[i] === '"') {
      const startLine = line;
      let combined = readString();
      while (true) {
        const savedI = i;
        const savedLine = line;
        skipWsAndComments();
        if (i < n && source[i] === "+") {
          i++;
          skipWsAndComments();
          if (i < n && source[i] === '"') {
            combined += readString();
            continue;
          }
        }
        i = savedI;
        line = savedLine;
        break;
      }
      out.push({ line: startLine, value: combined });
      continue;
    }
    i++;
  }
  return out;
}

/// Single-pass SQLite lexical transaction guard:
/// Each string-literal expression (with adjacent `+`-concatenated literals folded) is scanned
/// independently (trigger state NEVER carries across expressions or functions), handling UTF-8 BOM,
/// SQLite `$` identifiers, and trigger statement boundary `END` inside `CREATE [TEMP|TEMPORARY] TRIGGER ... BEGIN ... END`.
function findRawTxControlViolations(filename: string, source: string): string[] {
  const violations: string[] = [];
  const forbiddenHeads = new Set(["BEGIN", "COMMIT", "END", "SAVEPOINT", "RELEASE", "ROLLBACK"]);
  const exprs = extractPionStringExprs(source);
  for (const expr of exprs) {
    const tokens = tokenizeSql(expr.value);
    let atStmtStart = true;
    let inTriggerHeader = false;
    let inTriggerBody = false;
    let atTriggerStmtStart = false;

    for (let t = 0; t < tokens.length; t++) {
      const tok = tokens[t]!;
      if (inTriggerBody) {
        if (tok.kind === "semi") {
          atTriggerStmtStart = true;
        } else if (atTriggerStmtStart && tok.kind === "word" && tok.upper === "END") {
          inTriggerBody = false;
          atTriggerStmtStart = false;
          atStmtStart = false;
        } else {
          atTriggerStmtStart = false;
        }
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
      if (tok.kind === "semi") {
        atStmtStart = true;
        continue;
      }
      if (!atStmtStart) continue;
      atStmtStart = false;
      if (tok.kind !== "word") continue;

      if (tok.upper === "CREATE") {
        const t1 = tokens[t + 1];
        const t2 = tokens[t + 2];
        if (
          (t1?.kind === "word" && t1.upper === "TRIGGER") ||
          (t1?.kind === "word" &&
            (t1.upper === "TEMP" || t1.upper === "TEMPORARY") &&
            t2?.kind === "word" &&
            t2.upper === "TRIGGER")
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

test("builders_stateful static transaction guard + in-closure real file mutation test on archive_last.pion and page_letters.pion", () => {
  // Lexer edge-case checks (UTF-8 BOM, `$` identifiers, `+` literal folding, trigger boundary END, no cross-expr state).
  assert.ok(findRawTxControlViolations("t.pion", 'let _ = tx_db.exec("\uFEFFBEGIN IMMEDIATE")').length > 0);
  assert.ok(findRawTxControlViolations("t.pion", 'let _ = tx_db.exec("ROLL" + "BACK")').length > 0);
  assert.ok(findRawTxControlViolations("t.pion", 'let _ = tx_db.exec("CREATE TRIGGER x BEGIN SELECT NEW.use$case; END; COMMIT")').length > 0);
  assert.ok(
    findRawTxControlViolations("t.pion", 'let a = "CREATE TRIGGER x BEGIN"\nlet _ = tx_db.exec("COMMIT")').length > 0,
    "unclosed trigger literal must never suppress COMMIT in a subsequent literal",
  );
  assert.equal(
    findRawTxControlViolations("t.pion", 'let _ = tx_db.exec("CREATE TRIGGER x BEGIN SELECT CASE WHEN 1 THEN 2 END; END;")').length,
    0,
  );

  // Scan all real business files in pion/station/packages/builders_stateful/src/.
  const srcDir = resolve(fileURLToPath(new URL("../../pion/station/packages/builders_stateful/src", import.meta.url)));
  assert.ok(existsSync(srcDir), `expected ${srcDir} to exist`);
  const files = readdirSync(srcDir).filter((f) => f.endsWith(".pion") && !f.endsWith("_test.pion")).sort();
  assert.deepStrictEqual(files, ["archive_last.pion", "page_letters.pion"]);

  for (const file of files) {
    const content = readFileSync(join(srcDir, file), "utf8");
    assert.deepStrictEqual(
      findRawTxControlViolations(file, content),
      [],
      `${file} must have zero raw transaction SQL violations`,
    );

    // Real in-closure mutation test: inject raw transaction SQL directly inside the real `db.tx_err(...)`
    // closure body of both files in memory and assert 100% detection.
    const mutations: readonly { stmt: string; wantKeyword: string }[] = [
      { stmt: 'let _ = tx_db.exec("COMMIT")', wantKeyword: "COMMIT" },
      { stmt: 'let _ = tx_db.exec("BEGIN IMMEDIATE")', wantKeyword: "BEGIN" },
      { stmt: 'let _ = tx_db.exec("ROLL" + "BACK")', wantKeyword: "ROLLBACK" },
    ];
    for (const mut of mutations) {
      const mutated = injectIntoTxErrClosure(content, mut.stmt);
      assert.notEqual(mutated, content, `${file}: mutation must modify source`);
      const hits = findRawTxControlViolations(file, mutated);
      assert.equal(hits.length, 1, `${file}: injected ${mut.stmt} inside db.tx_err closure must be detected`);
      assert.ok(hits[0]!.includes(`"${mut.wantKeyword}"`), `${file}: expected "${mut.wantKeyword}", got ${hits[0]}`);
    }
  }
});
