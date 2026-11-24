// Real dual-engine production switch tests, stateful search-scope turn-rotation/restart parity,
// and SQLite lexical static transaction guard for `pion/station/packages/builders_index`
// (`session-up-jobs`, `workspace-up-jobs`, `outflow-chats`, `search-scope`, `session-list`).
import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
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
import { OutflowChatIndex } from "../src/read/chat-index-builder.ts";
import {
  mbReaderBinary,
  pionBinary,
  probePionSupportedModes,
  resetReaderSelectionStateForTest,
} from "../src/read/mb-reader.ts";
import { SessionListBuilder } from "../src/read/session-list-builder.ts";
import { JobNameFirstBuilder, SessionUpJobsBuilder } from "../src/read/session-up-jobs-builder.ts";
import { WorkspaceUpJobsBuilder } from "../src/read/workspace-up-jobs-builder.ts";
import { SearchScopeBuilder } from "../src/search/scope-builder.ts";
import { Store } from "../src/store/store.ts";
import { outflowChatIndexReady } from "./reference/backfill/outflow-index.ts";
import { installSessionListIndex, sessionListReady } from "./reference/backfill/session-list-index.ts";
import { installSessionUpJobs, sessionUpJobsReady, sessionUpJobsStep } from "./reference/backfill/session-up-jobs.ts";
import { installWorkspaceUpJobs, workspaceUpJobsReady } from "./reference/backfill/workspace-up-jobs.ts";

const tempDirs: string[] = [];
after(() => {
  for (const dir of tempDirs) {
    rmSync(dir, { recursive: true, force: true });
  }
});

function freshDir(prefix = "builders-index-switch-"): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  tempDirs.push(dir);
  return dir;
}

const skipPosix = platform.os === "windows"
  ? "POSIX shell wrappers are not directly spawnable without shell: true on Windows"
  : false;

async function withEnv<T>(overrides: Record<string, string | undefined>, fn: () => Promise<T>): Promise<T> {
  const saved = new Map<string, string | undefined>();
  for (const [k, v] of Object.entries(overrides)) {
    saved.set(k, process.env[k]);
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  try {
    return await fn();
  } finally {
    for (const [k, v] of saved) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
}

/// Thin wrapper around a real binary that records `<tag>\t<argv...>` on each invocation and `exec`s it.
function makeRecordingWrapper(dir: string, name: string, tag: string, realBin: string, logPath: string): string {
  const shPath = join(dir, name);
  const body = [
    "#!/bin/sh",
    `printf '%s' ${JSON.stringify(tag)} >> ${JSON.stringify(logPath)}`,
    'for arg in "$@"; do',
    `  printf '\\t%s' "$arg" >> ${JSON.stringify(logPath)}`,
    "done",
    `printf '\\n' >> ${JSON.stringify(logPath)}`,
    `exec ${JSON.stringify(realBin)} "$@"`,
    "",
  ].join("\n");
  writeFileSync(shPath, body, "utf8");
  chmodSync(shPath, 0o755);
  return shPath;
}

function makeOldVersionStub(dir: string, name: string, logPath: string): string {
  const shPath = join(dir, name);
  const body = [
    "#!/bin/sh",
    `printf 'old-stub\\t%s\\n' "$*" >> ${JSON.stringify(logPath)}`,
    'if [ "$1" = "--version" ]; then',
    '  printf "stillfail-pion 0.1.0 linux-x64\\n"',
    "  exit 0",
    "fi",
    "exit 99",
    "",
  ].join("\n");
  writeFileSync(shPath, body, "utf8");
  chmodSync(shPath, 0o755);
  return shPath;
}

function readSpawnLog(logPath: string): string[] {
  if (!existsSync(logPath)) return [];
  return readFileSync(logPath, "utf8")
    .split("\n")
    .filter((l) => l.length > 0);
}

function resolveRealBinaries(): { mbBin: string; pionBin: string } | { skip: string } {
  const explicitPion = process.env.STILLFAIL_PION_READER?.trim();
  const pionBin = pionBinary();
  const mbBin = mbReaderBinary();
  if (explicitPion) {
    assert.ok(pionBin !== null, `STILLFAIL_PION_READER is set (${explicitPion}) but resolved to null`);
    assert.ok(mbBin !== null, "STILLFAIL_PION_READER is set so real MoonBit stillfail-reader must also be available");
    assert.notEqual(
      realpathSync(pionBin),
      realpathSync(mbBin),
      "real dual-engine switch test requires distinct MB and Pion binaries",
    );
    return { mbBin: resolve(mbBin), pionBin: resolve(pionBin) };
  }
  if (pionBin === null || mbBin === null) {
    return { skip: "real both stillfail-reader and stillfail-pion binaries not present in this environment" };
  }
  if (realpathSync(pionBin) === realpathSync(mbBin)) {
    return { skip: "MB and Pion resolved to the same binary" };
  }
  return { mbBin: resolve(mbBin), pionBin: resolve(pionBin) };
}

// ── Seed DB builders + full state snapshots for 0-diff verification ──

function createSessionUpJobsSeed(dir: string): string {
  const seedPath = join(dir, "seed-session-up-jobs.db");
  const store = Store.open(seedPath, join(dir, "archive-suj"));
  try {
    const db = store.db;
    for (const row of db.prepare("SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'session_up_job_%'").all() as { name: string }[]) {
      db.exec(`DROP TRIGGER ${row.name}`);
    }
    db.exec("DROP TABLE session_up_job_rows; DROP TABLE session_up_job_replaced; DROP TABLE session_up_job_scopes; DROP TABLE session_up_job_meta");
    const put = db.prepare(
      "INSERT INTO jobs(id, token, session_key, state, port, name, command, cwd, started_at, log) VALUES (?, ?, ?, ?, ?, '', '', '', ?, '')",
    );
    db.exec("BEGIN");
    for (let i = 0; i < 650; i++) {
      put.run(`long-${i}`, `long-${i}`, "long", i % 3 === 0 ? "exited" : "running", i % 6 === 0 ? 8000 + i : null, i);
    }
    for (let i = 0; i < 5; i++) put.run(`short-${i}`, `short-${i}`, "short", "running", null, i);
    db.exec("DELETE FROM jobs WHERE rowid % 17 = 0");
    db.exec("COMMIT");
    installSessionUpJobs(db);
    db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
  } finally {
    store.close();
  }
  return seedPath;
}

function snapshotSessionUpJobs(path: string): string {
  const db = new DatabaseSync(path);
  try {
    return JSON.stringify([
      db.prepare("SELECT session, job_rowid FROM session_up_job_rows ORDER BY session, job_rowid").all(),
      db.prepare("SELECT session, last_rowid, end_rowid, complete FROM session_up_job_scopes ORDER BY session").all(),
    ]);
  } finally {
    db.close();
  }
}

function createJobNameFirstSeed(dir: string): { seedPath: string; thread: number } {
  const seedPath = join(dir, "seed-job-name-first.db");
  const store = Store.open(seedPath, join(dir, "archive-jnf"));
  let thread = 0;
  try {
    const db = store.db;
    for (const row of db.prepare("SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'session_up_job_%'").all() as { name: string }[]) {
      db.exec(`DROP TRIGGER ${row.name}`);
    }
    db.exec("DROP TABLE session_up_job_rows; DROP TABLE session_up_job_replaced; DROP TABLE session_up_job_scopes; DROP TABLE session_up_job_meta");
    const put = db.prepare(
      "INSERT INTO jobs(id, token, session_key, state, port, name, command, cwd, started_at, log) VALUES (?, ?, ?, ?, ?, '', '', '', ?, '')",
    );
    for (let i = 0; i < 10; i++) put.run(`long-${i}`, `long-${i}`, "long", "running", null, i);
    installSessionUpJobs(db);
    while (!sessionUpJobsStep(db, "long").done);
    thread = store.openThread("ember", "CHAT", "many", null, null).id;
    const joinStmt = db.prepare("INSERT INTO thread_sessions(thread, session, connect, joined_at) VALUES (?, ?, 'ember', ?)");
    db.exec("BEGIN");
    for (let i = 0; i < 150; i++) {
      joinStmt.run(thread, `member-${String(i).padStart(3, "0")}`, ((i * 37) % 151) + 10);
    }
    joinStmt.run(thread, "long", 50);
    db.exec("COMMIT");
    db.exec("DELETE FROM job_name_first");
    db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
  } finally {
    store.close();
  }
  return { seedPath, thread };
}

function snapshotJobNameFirst(path: string): string {
  const db = new DatabaseSync(path);
  try {
    return JSON.stringify(
      db.prepare("SELECT owner, thread, best, after_session, through_session, restart, ready FROM job_name_first ORDER BY owner").all(),
    );
  } finally {
    db.close();
  }
}

function createWorkspaceUpJobsSeed(dir: string): string {
  const seedPath = join(dir, "seed-workspace-up-jobs.db");
  const store = Store.open(seedPath, join(dir, "archive-wuj"));
  try {
    const db = store.db;
    for (const row of db.prepare("SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'workspace_up_%'").all() as { name: string }[]) {
      db.exec(`DROP TRIGGER ${row.name}`);
    }
    db.exec("DROP TABLE workspace_up_session_replaced; DROP TABLE workspace_up_sessions; DROP TABLE workspace_up_meta");
    db.exec("DELETE FROM session_up_job_rows; UPDATE session_up_job_meta SET fresh = 0");
    for (const [key, ws] of [["a", "WA"], ["b", "WB"], ["home", null], ["oddé", "WA"]] as const) {
      store.insertSession({ key, connect: "ember", runtime: "claude", profile: "cc", workspace: "/w", token: key, createdAt: 1, lastActiveAt: 1, ws });
    }
    const put = db.prepare(
      "INSERT INTO jobs(id, token, session_key, state, port, name, command, cwd, started_at, log) VALUES (?, ?, ?, ?, ?, '', '', '', ?, '')",
    );
    const sessions = ["a", "b", "home", "oddé", "gone"];
    db.exec("BEGIN");
    for (let i = 0; i < 400; i++) put.run(`run-${i}`, `run-${i}`, sessions[i % 5], "running", null, i);
    for (let i = 0; i < 2300; i++) put.run(`svc-${i}`, `svc-${i}`, sessions[i % 5], "exited", 9000 + (i % 700), i);
    for (let i = 0; i < 100; i++) put.run(`done-${i}`, `done-${i}`, sessions[i % 5], "exited", null, i);
    db.exec("COMMIT");
    installWorkspaceUpJobs(db);
    db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
  } finally {
    store.close();
  }
  return seedPath;
}

function snapshotWorkspaceUpJobs(path: string): string {
  const db = new DatabaseSync(path);
  try {
    return JSON.stringify([
      db.prepare("SELECT session, job_rowid FROM session_up_job_rows ORDER BY session, job_rowid").all(),
      db.prepare("SELECT session, scope, ws FROM workspace_up_sessions ORDER BY session").all(),
      db.prepare("SELECT version, phase, last_port, last_rowid, running_end, guard_end, guard_last, port_batches, ready FROM workspace_up_meta").all(),
      db.prepare("SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'workspace_up_%' ORDER BY name").all(),
    ]);
  } finally {
    db.close();
  }
}

function createOutflowSeed(dir: string): string {
  const seedPath = join(dir, "seed-outflow.db");
  const store = Store.open(seedPath, join(dir, "archive-outflow"));
  try {
    for (const [key, ws] of [["a", "A"], ["b", "B"], ["h", undefined]] as const) {
      store.insertSession({ key, connect: "ember", runtime: "claude", profile: "cc", workspace: "/w", token: key, createdAt: 1, lastActiveAt: 1, ws } as Parameters<Store["insertSession"]>[0]);
    }
    store.db.exec("BEGIN");
    for (let i = 0; i < 160; i++) {
      const owner = ["a", "b", "h"][i % 3]!;
      const thread = store.openThreadOf("ember", "CHAT", `chat-${i}`, `chat ${i}`, "ann@x", owner);
      store.joinThread(thread.id, owner, "ember");
      if (i % 10 === 0) store.joinThread(thread.id, "b", "ember");
      store.db.prepare("UPDATE threads SET created_at=? WHERE id=?").run(i, thread.id);
      if (i % 4 !== 0) {
        store.db.prepare("INSERT INTO entries (thread,n,kind,author_kind,author,text,at) VALUES (?,1,'message','person','ann@x','body',?)").run(thread.id, 1000 + i);
      }
    }
    store.db.exec("COMMIT");
    store.db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
  } finally {
    store.close();
  }
  return seedPath;
}

function snapshotOutflow(path: string): string {
  const db = new DatabaseSync(path);
  try {
    return JSON.stringify([
      db.prepare("SELECT thread, scope, at, dirty FROM outflow_chat_order ORDER BY thread, scope").all(),
      db.prepare("SELECT cursor, last, done FROM outflow_chat_progress").all(),
    ]);
  } finally {
    db.close();
  }
}

function createSearchScopeSeed(dir: string): { seedPath: string; threads: number[]; key: (i: number) => string } {
  const seedPath = join(dir, "seed-search-scope.db");
  const store = Store.open(seedPath, join(dir, "archive-ss"));
  const key = (i: number) => (i % 37 === 0 ? `with\u0000nul-${i}` : i % 41 === 0 ? `ключ-${i}` : `session-${i}`);
  const threads: number[] = [];
  try {
    for (let i = 0; i < 180; i++) {
      store.insertSession({
        key: key(i),
        connect: "ember",
        runtime: "claude",
        profile: "cc",
        workspace: "/work",
        token: `t-${i}`,
        createdAt: i,
        lastActiveAt: i,
        ws: i % 4 === 3 ? null : i % 29 === 0 ? `wś-${i % 3}` : `ws-${i % 3}`,
      } as Parameters<Store["insertSession"]>[0]);
    }
    for (let i = 0; i < 260; i++) {
      threads.push(store.openThread("ember", "CHAT", `t-${i}`, `T${i}`, null).id);
    }
    for (let i = 0; i < 260; i++) {
      if (i % 9 === 0) continue;
      for (let j = 0; j < 1 + (i % 3); j++) {
        store.joinThread(threads[i]!, j === 2 && i % 5 === 0 ? `gone-${i}` : key((i * 7 + j * 13) % 180), "ember");
      }
    }
    store.db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
  } finally {
    store.close();
  }
  return { seedPath, threads, key };
}

function snapshotSearchScope(path: string): string {
  const db = new DatabaseSync(path);
  try {
    return [
      JSON.stringify(db.prepare("SELECT thread, hex(session) AS session, kind, ws FROM search_scope_members ORDER BY thread, session").all()),
      JSON.stringify(db.prepare("SELECT kind, ws, thread, refs FROM search_scope_threads ORDER BY kind, ws, thread").all()),
      JSON.stringify(db.prepare("SELECT thread FROM search_scope_orphans ORDER BY thread").all()),
      JSON.stringify(db.prepare("SELECT thread, hex(session) AS session FROM search_scope_members_dirty ORDER BY thread, session").all()),
      JSON.stringify(db.prepare("SELECT thread FROM search_scope_threads_dirty ORDER BY thread").all()),
      JSON.stringify(db.prepare("SELECT hex(session) AS session, after_rowid FROM search_scope_sessions_dirty ORDER BY session").all()),
      JSON.stringify(db.prepare("SELECT * FROM search_scope_meta").all()),
    ].join("\n");
  } finally {
    db.close();
  }
}

function createSessionListSeed(dir: string): string {
  const seedPath = join(dir, "seed-session-list.db");
  const store = Store.open(seedPath, join(dir, "archive-sl"));
  try {
    const db = store.db;
    for (const row of db.prepare("SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'session_list_%'").all() as { name: string }[]) {
      db.exec(`DROP TRIGGER ${row.name}`);
    }
    db.exec("DROP TABLE session_list_rows; DROP TABLE session_list_replaced; DROP TABLE session_list_meta");
    for (let i = 0; i < 600; i++) {
      const key = i % 50 === 0 ? `with\u0000nul-${i}` : `session-${i}`;
      store.insertSession({
        key,
        connect: i % 2 === 0 ? "ember" : "slack",
        runtime: "claude",
        profile: "cc",
        workspace: "/work",
        token: `token-${i}`,
        createdAt: i,
        lastActiveAt: i,
        ws: i % 4 === 3 ? undefined : `ws-${i % 3}`,
      } as Parameters<Store["insertSession"]>[0]);
    }
    db.exec("UPDATE sessions SET archived_at = 5 WHERE rowid % 7 = 0");
    db.exec("DELETE FROM sessions WHERE rowid % 13 = 0");
    installSessionListIndex(db);
    db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
  } finally {
    store.close();
  }
  return seedPath;
}

function snapshotSessionList(path: string): string {
  const db = new DatabaseSync(path);
  try {
    const hasAudit = db.prepare("SELECT 1 FROM sqlite_master WHERE name='search_job_session_audit'").get() !== undefined;
    return JSON.stringify([
      db.prepare("SELECT hex(session) AS session, kind, ws, archived, connect FROM session_list_rows ORDER BY session, kind, ws, archived, connect").all(),
      db.prepare("SELECT id, version, last_rowid, end_rowid, complete FROM session_list_meta").all(),
      hasAudit ? db.prepare("SELECT id, version, last_rowid, end_rowid, complete FROM search_job_session_audit").all() : "no-audit",
    ]);
  } finally {
    db.close();
  }
}

// ── Minimal line-JSON subprocess driver for stateful batch-by-batch parity ──

class LineProc {
  readonly #child: ChildProcess;
  #carry: Buffer = Buffer.alloc(0);
  #stderr = "";
  readonly #waiters: Array<{ resolve: (v: any) => void; reject: (e: Error) => void }> = [];
  readonly #closed: Promise<void>;

  constructor(binary: string, args: string[]) {
    const child = spawn(binary, args, { stdio: ["pipe", "pipe", "pipe"], windowsHide: true });
    this.#child = child;
    child.stderr!.on("data", (c: Buffer) => { this.#stderr += c.toString("utf8"); });
    child.stdout!.on("data", (c: Buffer) => {
      this.#carry = this.#carry.length === 0 ? c : Buffer.concat([this.#carry, c]);
      for (let nl = this.#carry.indexOf(0x0a); nl >= 0; nl = this.#carry.indexOf(0x0a)) {
        const line = this.#carry.subarray(0, nl).toString("utf8");
        this.#carry = this.#carry.subarray(nl + 1);
        const w = this.#waiters.shift();
        if (w) w.resolve(JSON.parse(line));
      }
    });
    this.#closed = new Promise((done) => {
      child.once("close", () => {
        for (const w of this.#waiters.splice(0)) w.reject(new Error(`process exited; stderr: ${this.#stderr}`));
        done();
      });
    });
  }

  ask(payload: unknown): Promise<{ done: boolean; error?: string }> {
    return new Promise((resolve, reject) => {
      this.#waiters.push({ resolve, reject });
      this.#child.stdin!.write(`${JSON.stringify(payload)}\n`);
    });
  }

  async close(): Promise<void> {
    this.#child.stdin!.end();
    await this.#closed;
  }

  async kill(): Promise<void> {
    this.#child.stdin!.destroy();
    this.#child.kill("SIGKILL");
    await this.#closed;
  }
}

// ── Test 1: All 6 production builder classes switch MB <-> Pion with real binaries (no explicit binary override) ──

test("all 6 production index/job builder classes switch cleanly between real MB and real Pion with 0-diff DB state", { skip: skipPosix }, async (t) => {
  const bins = resolveRealBinaries();
  if ("skip" in bins) {
    t.skip(bins.skip);
    return;
  }

  const dir = freshDir("builders-index-prod-switch-");
  const logPath = join(dir, "spawns.log");
  const mbWrap = makeRecordingWrapper(dir, "wrap-mb", "mb", bins.mbBin, logPath);
  const pionWrap = makeRecordingWrapper(dir, "wrap-pion", "pion", bins.pionBin, logPath);
  const oldStub = makeOldVersionStub(dir, "old-pion-stub", logPath);

  resetReaderSelectionStateForTest();
  const probed = await probePionSupportedModes(pionWrap);
  assert.ok(probed !== null, "real stillfail-pion --version capability probe must succeed");
  for (const mode of ["session-up-jobs", "workspace-up-jobs", "outflow-chats", "search-scope", "session-list"]) {
    assert.ok(probed.has(mode), `expected stillfail-pion --version modes: to include ${mode}`);
  }

  const baseEnv = {
    STILLFAIL_MB_READER: mbWrap,
    STILLFAIL_PION_READER: pionWrap,
    STILLFAIL_READER_ENGINE: undefined,
    STILLFAIL_READER_SESSION_UP_JOBS: undefined,
    STILLFAIL_READER_WORKSPACE_UP_JOBS: undefined,
    STILLFAIL_READER_OUTFLOW_CHATS: undefined,
    STILLFAIL_READER_SEARCH_SCOPE: undefined,
    STILLFAIL_READER_SESSION_LIST: undefined,
  };

  const clearLog = () => writeFileSync(logPath, "", "utf8");

  // 1. SessionUpJobsBuilder: default mb vs STILLFAIL_READER_SESSION_UP_JOBS=pion
  {
    const seed = createSessionUpJobsSeed(dir);
    const mbDb = join(dir, "suj-mb.db");
    const pionDb = join(dir, "suj-pion.db");
    copyFileSync(seed, mbDb);
    copyFileSync(seed, pionDb);

    clearLog();
    await withEnv(baseEnv, async () => {
      const b = new SessionUpJobsBuilder(mbDb, {});
      try { await b.ready(["long", "short", "none"]); } finally { await b.close(); }
    });
    const mbSpawns = readSpawnLog(logPath);
    assert.ok(mbSpawns.some((l) => l.startsWith("mb\t--builder\tsession-up-jobs\t")), `expected mb spawn, got ${JSON.stringify(mbSpawns)}`);
    assert.ok(!mbSpawns.some((l) => l.startsWith("pion\t")), `unexpected pion spawn on default mb: ${JSON.stringify(mbSpawns)}`);

    clearLog();
    await withEnv({ ...baseEnv, STILLFAIL_READER_SESSION_UP_JOBS: "pion" }, async () => {
      const b = new SessionUpJobsBuilder(pionDb, {});
      try { await b.ready(["long", "short", "none"]); } finally { await b.close(); }
    });
    const pionSpawns = readSpawnLog(logPath);
    assert.ok(pionSpawns.some((l) => l.startsWith("pion\t--builder\tsession-up-jobs\t")), `expected pion spawn, got ${JSON.stringify(pionSpawns)}`);
    assert.ok(!pionSpawns.some((l) => l.startsWith("mb\t")), `unexpected mb spawn on pion env: ${JSON.stringify(pionSpawns)}`);

    assert.equal(snapshotSessionUpJobs(pionDb), snapshotSessionUpJobs(mbDb), "SessionUpJobsBuilder MB vs Pion 0-diff");
    const verifyDb = new DatabaseSync(pionDb);
    try {
      assert.equal(sessionUpJobsReady(verifyDb, "long"), true);
      assert.equal(sessionUpJobsReady(verifyDb, "short"), true);
    } finally {
      verifyDb.close();
    }
  }

  // 2. JobNameFirstBuilder: default mb vs config.readers["session-up-jobs"]="pion"
  {
    const { seedPath, thread } = createJobNameFirstSeed(dir);
    const mbDb = join(dir, "jnf-mb.db");
    const pionDb = join(dir, "jnf-pion.db");
    copyFileSync(seedPath, mbDb);
    copyFileSync(seedPath, pionDb);
    const key = JSON.stringify(["long", thread]);

    clearLog();
    await withEnv(baseEnv, async () => {
      const b = new JobNameFirstBuilder(mbDb, {});
      try { await b.ready([key]); } finally { await b.close(); }
    });
    assert.ok(readSpawnLog(logPath).some((l) => l.startsWith("mb\t--builder\tsession-up-jobs\t")));

    clearLog();
    await withEnv(baseEnv, async () => {
      const b = new JobNameFirstBuilder(pionDb, { readers: () => ({ readers: { "session-up-jobs": "pion" } }) });
      try { await b.ready([key]); } finally { await b.close(); }
    });
    const pionSpawns = readSpawnLog(logPath);
    assert.ok(pionSpawns.some((l) => l.startsWith("pion\t--builder\tsession-up-jobs\t")), `expected pion spawn via config.readers, got ${JSON.stringify(pionSpawns)}`);
    assert.ok(!pionSpawns.some((l) => l.startsWith("mb\t")));
    assert.equal(snapshotJobNameFirst(pionDb), snapshotJobNameFirst(mbDb), "JobNameFirstBuilder MB vs Pion 0-diff");

    // 2b. restart=1 with a newly joined earlier member -> both engines re-scan and converge 0-diff.
    for (const dbPath of [mbDb, pionDb]) {
      const db = new DatabaseSync(dbPath);
      try {
        db.prepare("INSERT INTO thread_sessions(thread, session, connect, joined_at) VALUES (?, 'aaa-earliest', 'ember', 1)").run(thread);
        db.exec("UPDATE job_name_first SET restart = 1, ready = 0 WHERE owner = 'long'");
      } finally {
        db.close();
      }
    }
    await withEnv(baseEnv, async () => {
      const b = new JobNameFirstBuilder(mbDb, {});
      try { await b.ready([key]); } finally { await b.close(); }
    });
    await withEnv({ ...baseEnv, STILLFAIL_READER_SESSION_UP_JOBS: "pion" }, async () => {
      const b = new JobNameFirstBuilder(pionDb, {});
      try { await b.ready([key]); } finally { await b.close(); }
    });
    assert.equal(snapshotJobNameFirst(pionDb), snapshotJobNameFirst(mbDb), "JobNameFirstBuilder restart=1 MB vs Pion 0-diff");
    {
      const db = new DatabaseSync(pionDb);
      try {
        const row = db.prepare("SELECT restart, ready FROM job_name_first WHERE owner = 'long'").get() as { restart: number; ready: number };
        assert.deepEqual({ ...row }, { restart: 0, ready: 1 });
      } finally {
        db.close();
      }
    }

    // 2c. Existing owner asked for a different thread (`same = 0`) while `ready = 0` -> completes immediately
    // without overwriting row or flipping `ready` to 1 (discriminating against removing the `same` guard).
    for (const dbPath of [mbDb, pionDb]) {
      const db = new DatabaseSync(dbPath);
      try {
        db.exec("UPDATE job_name_first SET ready = 0 WHERE owner = 'long'");
      } finally {
        db.close();
      }
    }
    const otherKey = JSON.stringify(["long", thread + 999]);
    const beforeSame0 = snapshotJobNameFirst(pionDb);
    await withEnv(baseEnv, async () => {
      const b = new JobNameFirstBuilder(mbDb, {});
      try { await b.ready([otherKey]); } finally { await b.close(); }
    });
    await withEnv({ ...baseEnv, STILLFAIL_READER_SESSION_UP_JOBS: "pion" }, async () => {
      const b = new JobNameFirstBuilder(pionDb, {});
      try { await b.ready([otherKey]); } finally { await b.close(); }
    });
    assert.equal(snapshotJobNameFirst(pionDb), beforeSame0, "same=0 must leave existing job_name_first row unchanged");
    assert.equal(snapshotJobNameFirst(pionDb), snapshotJobNameFirst(mbDb), "JobNameFirstBuilder same=0 MB vs Pion 0-diff");
    {
      const db = new DatabaseSync(pionDb);
      try {
        const row = db.prepare("SELECT ready FROM job_name_first WHERE owner = 'long'").get() as { ready: number };
        assert.equal(row.ready, 0, "same=0 with ready=0 must not flip ready to 1");
      } finally {
        db.close();
      }
    }
  }

  // 3. WorkspaceUpJobsBuilder: default mb vs STILLFAIL_READER_WORKSPACE_UP_JOBS=pion
  {
    const seed = createWorkspaceUpJobsSeed(dir);
    const mbDb = join(dir, "wuj-mb.db");
    const pionDb = join(dir, "wuj-pion.db");
    copyFileSync(seed, mbDb);
    copyFileSync(seed, pionDb);

    clearLog();
    await withEnv(baseEnv, async () => {
      const b = new WorkspaceUpJobsBuilder(mbDb, {});
      try { await b.ready(["all"]); } finally { await b.close(); }
    });
    assert.ok(readSpawnLog(logPath).some((l) => l.startsWith("mb\t--builder\tworkspace-up-jobs\t")));

    clearLog();
    await withEnv({ ...baseEnv, STILLFAIL_READER_WORKSPACE_UP_JOBS: "pion" }, async () => {
      const b = new WorkspaceUpJobsBuilder(pionDb, {});
      try { await b.ready(["all"]); } finally { await b.close(); }
    });
    const pionSpawns = readSpawnLog(logPath);
    assert.ok(pionSpawns.some((l) => l.startsWith("pion\t--builder\tworkspace-up-jobs\t")));
    assert.ok(!pionSpawns.some((l) => l.startsWith("mb\t")));
    assert.equal(snapshotWorkspaceUpJobs(pionDb), snapshotWorkspaceUpJobs(mbDb), "WorkspaceUpJobsBuilder MB vs Pion 0-diff");
    const verifyDb = new DatabaseSync(pionDb);
    try { assert.equal(workspaceUpJobsReady(verifyDb), true); } finally { verifyDb.close(); }
  }

  // 4. OutflowChatIndex: default mb vs STILLFAIL_READER_OUTFLOW_CHATS=pion
  {
    const seed = createOutflowSeed(dir);
    const mbDb = join(dir, "outflow-mb.db");
    const pionDb = join(dir, "outflow-pion.db");
    copyFileSync(seed, mbDb);
    copyFileSync(seed, pionDb);

    clearLog();
    await withEnv(baseEnv, async () => {
      const idx = new OutflowChatIndex(mbDb, {});
      try { await idx.ready({ workspace: "A", home: true }); } finally { await idx.close(); }
    });
    assert.ok(readSpawnLog(logPath).some((l) => l.startsWith("mb\t--builder\toutflow-chats\t")));

    clearLog();
    await withEnv({ ...baseEnv, STILLFAIL_READER_OUTFLOW_CHATS: "pion" }, async () => {
      const idx = new OutflowChatIndex(pionDb, {});
      try { await idx.ready({ workspace: "A", home: true }); } finally { await idx.close(); }
    });
    const pionSpawns = readSpawnLog(logPath);
    assert.ok(pionSpawns.some((l) => l.startsWith("pion\t--builder\toutflow-chats\t")));
    assert.ok(!pionSpawns.some((l) => l.startsWith("mb\t")));
    assert.equal(snapshotOutflow(pionDb), snapshotOutflow(mbDb), "OutflowChatIndex MB vs Pion 0-diff");
    const verifyDb = new DatabaseSync(pionDb);
    try { assert.equal(outflowChatIndexReady(verifyDb, { workspace: "A", home: true }), true); } finally { verifyDb.close(); }
  }

  // 5. SearchScopeBuilder: default mb vs STILLFAIL_READER_SEARCH_SCOPE=pion
  {
    const { seedPath } = createSearchScopeSeed(dir);
    const mbDb = join(dir, "ss-mb.db");
    const pionDb = join(dir, "ss-pion.db");
    copyFileSync(seedPath, mbDb);
    copyFileSync(seedPath, pionDb);

    clearLog();
    await withEnv(baseEnv, async () => {
      const b = new SearchScopeBuilder(mbDb, {});
      try { await b.prepare(); } finally { await b.close(); }
    });
    assert.ok(readSpawnLog(logPath).some((l) => l.startsWith("mb\t--builder\tsearch-scope\t")));

    clearLog();
    await withEnv({ ...baseEnv, STILLFAIL_READER_SEARCH_SCOPE: "pion" }, async () => {
      const b = new SearchScopeBuilder(pionDb, {});
      try { await b.prepare(); } finally { await b.close(); }
    });
    const pionSpawns = readSpawnLog(logPath);
    assert.ok(pionSpawns.some((l) => l.startsWith("pion\t--builder\tsearch-scope\t")));
    assert.ok(!pionSpawns.some((l) => l.startsWith("mb\t")));
    assert.equal(snapshotSearchScope(pionDb), snapshotSearchScope(mbDb), "SearchScopeBuilder MB vs Pion 0-diff");
  }

  // 6. SessionListBuilder: default mb vs STILLFAIL_READER_SESSION_LIST=pion (readySearch covers step && audit)
  {
    const seed = createSessionListSeed(dir);
    const mbDb = join(dir, "sl-mb.db");
    const pionDb = join(dir, "sl-pion.db");
    copyFileSync(seed, mbDb);
    copyFileSync(seed, pionDb);

    clearLog();
    await withEnv(baseEnv, async () => {
      const b = new SessionListBuilder(mbDb, {});
      try { await b.readySearch(); } finally { await b.close(); }
    });
    assert.ok(readSpawnLog(logPath).some((l) => l.startsWith("mb\t--builder\tsession-list\t")));

    clearLog();
    await withEnv({ ...baseEnv, STILLFAIL_READER_SESSION_LIST: "pion" }, async () => {
      const b = new SessionListBuilder(pionDb, {});
      try { await b.readySearch(); } finally { await b.close(); }
    });
    const pionSpawns = readSpawnLog(logPath);
    assert.ok(pionSpawns.some((l) => l.startsWith("pion\t--builder\tsession-list\t")));
    assert.ok(!pionSpawns.some((l) => l.startsWith("mb\t")));
    assert.equal(snapshotSessionList(pionDb), snapshotSessionList(mbDb), "SessionListBuilder MB vs Pion 0-diff");
    const verifyDb = new DatabaseSync(pionDb);
    try { assert.equal(sessionListReady(verifyDb), true); } finally { verifyDb.close(); }
  }

  // 7. Old Pion binary without `modes:` safely falls back to MB with `pion-binary-unsupported-mode`
  {
    const seed = join(dir, "seed-session-list.db");
    const fallbackDb = join(dir, "sl-fallback.db");
    copyFileSync(seed, fallbackDb);

    resetReaderSelectionStateForTest();
    const oldModes = await probePionSupportedModes(oldStub);
    assert.ok(oldModes !== null && !oldModes.has("session-list"));

    const logs: Line[] = [];
    hearLines((l) => logs.push(l));
    clearLog();
    try {
      await withEnv({
        ...baseEnv,
        STILLFAIL_PION_READER: oldStub,
        STILLFAIL_READER_SESSION_LIST: "pion",
      }, async () => {
        const b = new SessionListBuilder(fallbackDb, {});
        try { await b.readyIndex(); } finally { await b.close(); }
      });
    } finally {
      hearLines(null);
    }
    const spawns = readSpawnLog(logPath);
    assert.ok(spawns.some((l) => l.startsWith("mb\t--builder\tsession-list\t")), "expected fallback to MB on old Pion stub");
    assert.ok(!spawns.some((l) => l.startsWith("old-stub\t--builder\t")), "old stub must not be spawned for unsupported mode");
    assert.ok(
      logs.some((l) => l.message === "reader engine fallback" && l.fields.reason === "pion-binary-unsupported-mode"),
      "expected pion-binary-unsupported-mode warning",
    );
  }
});

// ── Test 2: search-scope stateful turn rotation + mid-run kill & restart 0-diff parity ──

test("search-scope: per-batch stateful turn rotation and mid-run process kill+restart match real MB 0-diff", { skip: skipPosix }, async (t) => {
  const bins = resolveRealBinaries();
  if ("skip" in bins) {
    t.skip(bins.skip);
    return;
  }

  const dir = freshDir("search-scope-stateful-");
  const { seedPath, threads, key } = createSearchScopeSeed(dir);
  const mbPath = join(dir, "mb.db");
  const pionPath = join(dir, "pion.db");
  copyFileSync(seedPath, mbPath);
  copyFileSync(seedPath, pionPath);

  const mutate = (dbPath: string, at: number) => {
    const db = new DatabaseSync(dbPath);
    try {
      if (at === 2) db.prepare("UPDATE sessions SET ws = 'moved' WHERE key IN (?, ?, ?)").run(key(5), key(37), key(6));
      if (at === 4) {
        db.prepare("INSERT OR IGNORE INTO thread_sessions(thread, session, connect, joined_at) VALUES (?, ?, 'ember', 999)").run(threads[9]!, key(1));
        db.prepare("INSERT OR IGNORE INTO thread_sessions(thread, session, connect, joined_at) VALUES (?, 'never', 'ember', 999)").run(threads[18]!);
      }
      if (at === 6) db.prepare("DELETE FROM thread_sessions WHERE thread = ?").run(threads[1]!);
      if (at === 8) db.prepare("DELETE FROM threads WHERE id = ?").run(threads[2]!);
    } finally {
      db.close();
    }
  };

  let mbProc = new LineProc(bins.mbBin, ["--builder", "search-scope", "--db", mbPath]);
  let pionProc = new LineProc(bins.pionBin, ["--builder", "search-scope", "--db", pionPath]);
  let restarted = false;

  try {
    let steps = 0;
    let finalDone = false;
    for (let i = 0; i < 300; i++) {
      const [mbRes, pionRes] = await Promise.all([
        mbProc.ask({ scope: "all" }),
        pionProc.ask({ scope: "all" }),
      ]);
      assert.equal(mbRes.error, undefined);
      assert.equal(pionRes.error, undefined);
      assert.deepStrictEqual(pionRes, mbRes, `step ${i} response parity`);
      assert.equal(snapshotSearchScope(pionPath), snapshotSearchScope(mbPath), `step ${i} DB state 0-diff`);
      steps++;
      finalDone = mbRes.done;

      mutate(mbPath, i);
      mutate(pionPath, i);

      // Mid-run crash/restart after step 7 (while still in progress) to verify both restart with turn=0 and converge 0-diff.
      if (i === 7 && !mbRes.done) {
        await Promise.all([mbProc.kill(), pionProc.kill()]);
        mbProc = new LineProc(bins.mbBin, ["--builder", "search-scope", "--db", mbPath]);
        pionProc = new LineProc(bins.pionBin, ["--builder", "search-scope", "--db", pionPath]);
        restarted = true;
      }

      if (mbRes.done && i > 10) break;
    }
    assert.ok(restarted, "must have exercised mid-run kill+restart before completion");
    assert.ok(steps > 10, `expected >10 batches, got ${steps}`);
    assert.equal(finalDone, true, "search-scope must converge to done=true");
    for (const [label, dbPath] of [["mb", mbPath], ["pion", pionPath]] as const) {
      const db = new DatabaseSync(dbPath);
      try {
        const meta = db.prepare("SELECT threads_done, members_done FROM search_scope_meta WHERE id = 1").get() as {
          threads_done: number;
          members_done: number;
        };
        assert.deepEqual({ ...meta }, { threads_done: 1, members_done: 1 }, `${label}: scan completion flags must both be 1`);
        for (const dirtyTable of ["search_scope_sessions_dirty", "search_scope_members_dirty", "search_scope_threads_dirty"]) {
          const cnt = (db.prepare(`SELECT COUNT(*) AS n FROM ${dirtyTable}`).get() as { n: number }).n;
          assert.equal(cnt, 0, `${label}: ${dirtyTable} must be empty after convergence`);
        }
      } finally {
        db.close();
      }
    }
  } finally {
    await Promise.all([mbProc.close().catch(() => {}), pionProc.close().catch(() => {})]);
  }
});

// ── Test 2b: job_name_first_step Int64 upper-bound saturation & REAL binding parity with MB ──

test("session-up-jobs job_name_first: Int64 upper-bound & overflow numbers (INT64_MAX, 2^63, 1e400) match real MB typeof(thread) and best", { skip: skipPosix }, async (t) => {
  const bins = resolveRealBinaries();
  if ("skip" in bins) {
    t.skip(bins.skip);
    return;
  }

  const dir = freshDir("job-name-first-int64-");
  const rawFirstCases = ["9223372036854775807", "9223372036854775808", "1e400"];

  for (const rawNum of rawFirstCases) {
    const seedPath = join(dir, `seed-${rawNum}.db`);
    const store = Store.open(seedPath, join(dir, `arch-${rawNum}`));
    try {
      const db = store.db;
      db.prepare("INSERT INTO jobs(id, token, session_key, state, port, name, command, cwd, started_at, log) VALUES ('j1', 'j1', 'long', 'running', NULL, '', '', '', 1, '')").run();
      while (!sessionUpJobsStep(db, "long").done);
      // Seed a thread_sessions row with rowid/thread = INT64_MAX so INTEGER vs REAL binding is distinguishable on `best`.
      db.exec("INSERT INTO thread_sessions(thread, session, connect, joined_at) VALUES (9223372036854775807, 'm1', 'ember', 1)");
      db.exec("DELETE FROM job_name_first");
      db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
    } finally {
      store.close();
    }

    const mbPath = join(dir, `mb-${rawNum}.db`);
    const pionPath = join(dir, `pion-${rawNum}.db`);
    copyFileSync(seedPath, mbPath);
    copyFileSync(seedPath, pionPath);

    const askRaw = async (bin: string, dbPath: string): Promise<{ done: boolean; error?: string }> => {
      const child = spawn(bin, ["--builder", "session-up-jobs", "--db", dbPath], { stdio: ["pipe", "pipe", "pipe"], windowsHide: true });
      const out = await new Promise<string>((resolveOut, rejectOut) => {
        let buf = "";
        child.stdout!.on("data", (c: Buffer) => {
          buf += c.toString("utf8");
          const nl = buf.indexOf("\n");
          if (nl >= 0) resolveOut(buf.slice(0, nl));
        });
        child.once("error", rejectOut);
        child.stdin!.write(`{"session":"long","first":${rawNum}}\n`);
      });
      child.stdin!.end();
      await new Promise<void>((done) => child.once("close", () => done()));
      return JSON.parse(out) as { done: boolean; error?: string };
    };

    const mbRes = await askRaw(bins.mbBin, mbPath);
    const pionRes = await askRaw(bins.pionBin, pionPath);
    assert.deepStrictEqual(pionRes, mbRes, `raw first=${rawNum}: response parity`);

    const inspect = (dbPath: string) => {
      const db = new DatabaseSync(dbPath);
      try {
        return db.prepare("SELECT owner, typeof(thread) AS thread_type, CAST(thread AS TEXT) AS thread_text, best, ready FROM job_name_first ORDER BY owner").all();
      } finally {
        db.close();
      }
    };
    const mbRow = inspect(mbPath);
    const pionRow = inspect(pionPath);
    assert.deepStrictEqual(pionRow, mbRow, `raw first=${rawNum}: typeof(thread), thread, and best must match MB 0-diff`);
  }
});

// ── Test 3: session-list short-circuit `step && audit` discriminating check ──

test("session-list: scope='search' short-circuits audit until session_list_step finishes (discriminating trigger test)", { skip: skipPosix }, async (t) => {
  const bins = resolveRealBinaries();
  if ("skip" in bins) {
    t.skip(bins.skip);
    return;
  }

  const dir = freshDir("session-list-shortcircuit-");
  const seedPath = join(dir, "seed-257.db");
  const store = Store.open(seedPath, join(dir, "archive-257"));
  try {
    const db = store.db;
    for (const row of db.prepare("SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'session_list_%'").all() as { name: string }[]) {
      db.exec(`DROP TRIGGER ${row.name}`);
    }
    db.exec("DROP TABLE session_list_rows; DROP TABLE session_list_replaced; DROP TABLE session_list_meta");
    db.exec("BEGIN");
    for (let i = 0; i < 257; i++) {
      store.insertSession({
        key: `s-${i}`,
        connect: "ember",
        runtime: "claude",
        profile: "cc",
        workspace: "/work",
        token: `tok-${i}`,
        createdAt: i,
        lastActiveAt: i,
        ws: "ws-0",
      } as Parameters<Store["insertSession"]>[0]);
    }
    db.exec("COMMIT");
    installSessionListIndex(db);
    // Delete session_list_meta immediately after the first partial batch (`complete = 0`).
    // If `scope: "search"` failed to short-circuit and invoked `audit(db)` on request 1,
    // `audit(db)` would fail on request 1 instead of request 2.
    db.exec("CREATE TRIGGER drop_meta_after_first_batch AFTER UPDATE OF last_rowid ON session_list_meta WHEN NEW.complete = 0 BEGIN DELETE FROM session_list_meta; END;");
    db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
  } finally {
    store.close();
  }

  const mbPath = join(dir, "mb.db");
  const pionPath = join(dir, "pion.db");
  copyFileSync(seedPath, mbPath);
  copyFileSync(seedPath, pionPath);

  const mbProc = new LineProc(bins.mbBin, ["--builder", "session-list", "--db", mbPath]);
  const pionProc = new LineProc(bins.pionBin, ["--builder", "session-list", "--db", pionPath]);
  const mbPrefix = /^\S+:\d+:\d+-\d+:\d+@\S+ FAILED: /;
  try {
    // Request 1: writes 256 rows and returns { done: false } with NO error on both MB and Pion.
    const [mb1, pion1] = await Promise.all([mbProc.ask({ scope: "search" }), pionProc.ask({ scope: "search" })]);
    assert.deepStrictEqual(mb1, { done: false });
    assert.deepStrictEqual(pion1, { done: false });
    for (const [label, dbPath] of [["mb", mbPath], ["pion", pionPath]] as const) {
      const db = new DatabaseSync(dbPath);
      try {
        const rowCnt = (db.prepare("SELECT COUNT(*) AS n FROM session_list_rows").get() as { n: number }).n;
        assert.equal(rowCnt, 256, `${label}: first batch must write exactly 256 rows`);
        const auditExists = db.prepare("SELECT 1 FROM sqlite_master WHERE name='search_job_session_audit'").get();
        assert.equal(auditExists, undefined, `${label}: audit table must NOT be created while session_list_step returns false`);
      } finally {
        db.close();
      }
    }

    // Request 2: NOW sees missing marker error on both MB and Pion.
    const [mb2, pion2] = await Promise.all([mbProc.ask({ scope: "search" }), pionProc.ask({ scope: "search" })]);
    assert.equal(mb2.done, false);
    assert.equal(pion2.done, false);
    assert.equal(pion2.error, mb2.error?.replace(mbPrefix, ""));
    assert.equal(pion2.error, "session list index version marker is missing");

    // Invalid request returns exact protocol error.
    const bad = await pionProc.ask({ scope: "nope" });
    assert.deepStrictEqual(bad, { done: false, error: "invalid session list preparation request" });
  } finally {
    await Promise.all([mbProc.close(), pionProc.close()]);
  }
});

// ── Test 4: SQLite lexical static transaction guard over pion/station/packages/builders_index/src/*.pion ──

function unescapePionString(raw: string): string {
  let out = "";
  for (let i = 0; i < raw.length; i++) {
    const ch = raw[i]!;
    if (ch === "\\" && i + 1 < raw.length) {
      const next = raw[i + 1]!;
      if (next === "n") { out += "\n"; i++; continue; }
      if (next === "r") { out += "\r"; i++; continue; }
      if (next === "t") { out += "\t"; i++; continue; }
      if (next === '"' || next === "\\") { out += next; i++; continue; }
    }
    out += ch;
  }
  return out;
}

type SqlTok = { kind: "word"; upper: string } | { kind: "semi" } | { kind: "other" };

function isSqlIdentStart(c: number): boolean {
  return (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c === 95 || c >= 0x80;
}

function isSqlIdentPart(c: number): boolean {
  return isSqlIdentStart(c) || (c >= 48 && c <= 57) || c === 36;
}

function tokenizeSql(sql: string): SqlTok[] {
  const tokens: SqlTok[] = [];
  let i = 0;
  const n = sql.length;
  while (i < n) {
    const ch = sql[i]!;
    const code = sql.charCodeAt(i);
    if (ch === " " || ch === "\t" || ch === "\r" || ch === "\n" || ch === "\f" || ch === "\v" || code === 0xfeff) {
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
          if (i + 1 < n && sql[i + 1] === quote) { i += 2; continue; }
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
      while (i < n && isSqlIdentPart(sql.charCodeAt(i))) i++;
      tokens.push({ kind: "word", upper: sql.slice(start, i).toUpperCase() });
      continue;
    }
    tokens.push({ kind: "other" });
    i++;
  }
  return tokens;
}

/// Expression-scoped SQLite lexical static guard for `pion/station/packages/builders_index/src/*.pion`:
/// - Never leaks `inTriggerHeader`/`inTriggerBody` across statements, array elements, or functions:
///   trigger state only spans `+`-concatenated literals within the same expression (reset on `,`/`;`/`}`/`]`
///   or any newline whose previous line did not end with `+`).
/// - Inside a trigger body, an interpolated helper call (`+ helper(...) +`) is treated as completing a SQL
///   statement so the matching `" END;"` closes `inTriggerBody`, while any subsequent `BEGIN`/`COMMIT`/`END`/
///   `SAVEPOINT`/`RELEASE`/`ROLLBACK` outside the trigger body is immediately flagged.
function findRawTxControlViolations(filename: string, source: string): string[] {
  const violations: string[] = [];
  const forbiddenHeads = new Set(["BEGIN", "COMMIT", "END", "SAVEPOINT", "RELEASE", "ROLLBACK"]);
  const lines = source.split("\n");
  let inTriggerHeader = false;
  let inTriggerBody = false;
  let atTriggerStmtStart = false;
  let triggerParenDepth = 0;
  let prevLineEndedWithPlus = false;
  let parenDepth = 0;

  const resetTrigger = () => {
    inTriggerHeader = false;
    inTriggerBody = false;
    atTriggerStmtStart = false;
  };

  const scanGap = (gap: string) => {
    let sawTriggerBoundary = false;
    let sawTriggerPlus = false;
    for (let i = 0; i < gap.length; i++) {
      const ch = gap[i]!;
      if (ch === "(") {
        parenDepth++;
      } else if (ch === ")") {
        if ((inTriggerHeader || inTriggerBody) && parenDepth <= triggerParenDepth) sawTriggerBoundary = true;
        parenDepth = Math.max(0, parenDepth - 1);
      } else if ((inTriggerHeader || inTriggerBody) && parenDepth <= triggerParenDepth) {
        if (ch === ";" || ch === "}" || ch === "]" || ch === ",") sawTriggerBoundary = true;
        else if (ch === "+") sawTriggerPlus = true;
      }
    }
    if (sawTriggerBoundary) resetTrigger();
    else if (inTriggerBody && sawTriggerPlus) atTriggerStmtStart = true;
  };

  for (let idx = 0; idx < lines.length; idx++) {
    const line = lines[idx]!;
    const trimmed = line.trim();
    if (trimmed.startsWith("//")) continue;
    if (!prevLineEndedWithPlus && parenDepth <= triggerParenDepth) resetTrigger();

    // Scan string literals on this line along with the non-string code gaps between them.
    const litRe = /"((?:\\.|[^"\\])*)"/g;
    let lastEnd = 0;
    let m: RegExpExecArray | null;
    while ((m = litRe.exec(line)) !== null) {
      const gap = line.slice(lastEnd, m.index);
      lastEnd = m.index + m[0].length;
      scanGap(gap);

      const literal = m[1]!;
      const tokens = tokenizeSql(unescapePionString(literal));
      // Only treat literals at the trigger's own paren depth as part of the outer trigger DDL.
      if ((inTriggerHeader || inTriggerBody) && parenDepth > triggerParenDepth) {
        // Still check nested call string arguments with fresh non-trigger state so injected tx SQL in args is caught.
        let argStmtStart = true;
        for (let t = 0; t < tokens.length; t++) {
          const tok = tokens[t]!;
          if (tok.kind === "semi") { argStmtStart = true; continue; }
          if (!argStmtStart) continue;
          argStmtStart = false;
          if (tok.kind === "word" && forbiddenHeads.has(tok.upper)) {
            violations.push(`${filename}:${idx + 1}: forbidden raw transaction SQL "${tok.upper}" in literal "${literal}"`);
          }
        }
        continue;
      }
      let atStmtStart = true;

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
            (t1?.kind === "word" && (t1.upper === "TEMP" || t1.upper === "TEMPORARY") && t2?.kind === "word" && t2.upper === "TRIGGER")
          ) {
            inTriggerHeader = true;
            triggerParenDepth = parenDepth;
          }
          continue;
        }

        if (forbiddenHeads.has(tok.upper)) {
          if (tok.upper === "END") {
            const next = tokens[t + 1];
            const isTxEnd = next === undefined || next.kind === "semi" || (next.kind === "word" && next.upper === "TRANSACTION");
            if (!isTxEnd) continue;
          }
          violations.push(`${filename}:${idx + 1}: forbidden raw transaction SQL "${tok.upper}" in literal "${literal}"`);
        }
      }
    }
    const tail = line.slice(lastEnd);
    scanGap(tail);
    prevLineEndedWithPlus = tail.trimEnd().endsWith("+");
    if (!prevLineEndedWithPlus && parenDepth <= triggerParenDepth) resetTrigger();
  }
  return violations;
}

test("builders_index static guard: rejects raw transaction SQL (including injected COMMIT in real outflow.pion & searchscope.pion) and passes on clean files", () => {
  assert.ok(findRawTxControlViolations("x.pion", 'db.exec("BEGIN IMMEDIATE")').length > 0);
  assert.ok(findRawTxControlViolations("x.pion", 'db.exec("COMMIT")').length > 0);
  assert.ok(findRawTxControlViolations("x.pion", 'db.exec("END")').length > 0);
  assert.ok(findRawTxControlViolations("x.pion", 'db.exec("SAVEPOINT s1")').length > 0);
  assert.ok(findRawTxControlViolations("x.pion", 'db.exec("RELEASE s1")').length > 0);
  assert.ok(findRawTxControlViolations("x.pion", 'db.exec("ROLLBACK")').length > 0);
  assert.ok(findRawTxControlViolations("x.pion", 'db.exec("CREATE TRIGGER t AFTER INSERT ON a BEGIN SELECT 1; END; BEGIN IMMEDIATE")').length > 0);
  assert.ok(
    findRawTxControlViolations("x.pion", 'db.exec("CREATE TRIGGER t AFTER INSERT ON a BEGIN " + body + " END; BEGIN IMMEDIATE")').length > 0,
  );
  assert.equal(findRawTxControlViolations("x.pion", 'db.exec("CREATE TRIGGER t AFTER INSERT ON a BEGIN SELECT CASE WHEN 1 THEN 2 END; END;")').length, 0);
  assert.equal(findRawTxControlViolations("x.pion", 'db.exec("CREATE TRIGGER t AFTER INSERT ON a BEGIN " + body + " END;")').length, 0);

  const srcDir = resolve(fileURLToPath(new URL("../../pion/station/packages/builders_index/src", import.meta.url)));
  assert.ok(existsSync(srcDir), `expected ${srcDir} to exist`);
  const files = readdirSync(srcDir).filter((f) => f.endsWith(".pion") && !f.endsWith("_test.pion"));
  assert.deepEqual(files.sort(), ["outflow.pion", "searchscope.pion", "sessions.pion", "upjobs.pion"]);

  const violations: string[] = [];
  for (const file of files) {
    violations.push(...findRawTxControlViolations(file, readFileSync(join(srcDir, file), "utf8")));
  }
  assert.deepStrictEqual(violations, [], `raw transaction SQL found in builders_index:\n${violations.join("\n")}`);

  // Non-vacuous injection proof on real `outflow.pion` and `searchscope.pion`:
  // injecting `tx_db.exec("COMMIT")` inside `outflow_step` / `search_scope_step` MUST be caught.
  const outflowSrc = readFileSync(join(srcDir, "outflow.pion"), "utf8");
  const outflowMutated = outflowSrc.replace("pub fn outflow_step(", 'fn _injected(tx_db : sql_db::Db) -> Unit { let _ = tx_db.exec("COMMIT") }\npub fn outflow_step(');
  assert.notEqual(outflowMutated, outflowSrc);
  const outflowHits = findRawTxControlViolations("outflow.pion", outflowMutated);
  assert.ok(
    outflowHits.some((v) => v.includes('forbidden raw transaction SQL "COMMIT"')),
    `expected guard to catch injected COMMIT in real outflow.pion, got: ${JSON.stringify(outflowHits)}`,
  );

  const searchSrc = readFileSync(join(srcDir, "searchscope.pion"), "utf8");
  const searchMutated = searchSrc.replace("pub fn search_scope_step(", 'fn _injected(tx_db : sql_db::Db) -> Unit { let _ = tx_db.exec("COMMIT") }\npub fn search_scope_step(');
  assert.notEqual(searchMutated, searchSrc);
  const searchHits = findRawTxControlViolations("searchscope.pion", searchMutated);
  assert.ok(
    searchHits.some((v) => v.includes('forbidden raw transaction SQL "COMMIT"')),
    `expected guard to catch injected COMMIT in real searchscope.pion, got: ${JSON.stringify(searchHits)}`,
  );
});
