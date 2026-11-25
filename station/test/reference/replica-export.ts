// The export as the station did it in TypeScript before it was the MoonBit program's (station/mb src/replica
// export.mbt, started by src/replica/runner.ts `exportThread`): the tests' only, their own stations' export
// (replica-work.ts `InlineRunner`) and what mb-replica.test.ts holds the program to, line for line.
//
// The export (replica/AGENTS.md): what must survive of this station's conversations, read from stillfail.db over a
// read-only connection of its own and written as batches, a generation of them per workspace, under
// <data>/replica/own/<workspace>/<gen>/. It runs in a worker thread (worker.ts), woken as the store says what changed;
// nothing of it is on the main thread's way to the database, and the main thread's writes run no statement more for it.
//
// What changed is found without anything written for it:
// - the logs that are only added to (entries, letters, turns) by their rowid, past the highest exported; a turn's end
//   by the turns_ended index; what a turn says after it ended (a card chosen, a wait stopped) is its session's latest,
//   read again when the store says the session changed;
// - the small tables whose rows change in place (sessions, threads, who is in which, the marks) by what the store says
//   changed, a row read again by its key and written only when it differs from what was written of it last (a digest
//   kept in <data>/replica/export.db, the exporter's own); and, as the exporter starts, every row of them once, so what
//   changed while it was not running is found too (some ten thousand rows on a busy station, read a page at a time);
// - a session or thread deleted, as the store says it (and, at that first reading, a session or thread written before
//   and there no more): a `gone` record.
// A batch is read inside one read transaction: what it says is the database at one moment.
import { createHash, randomBytes } from "node:crypto";
import { closeSync, existsSync, fsyncSync, lstatSync, mkdirSync, openSync, opendirSync, readFileSync, readSync, readdirSync, realpathSync, renameSync, rmSync, statSync, writeSync } from "node:fs";
import { dirname, join, relative, resolve, sep } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { zstdCompressSync } from "node:zlib";
import { runtimeKind } from "../../src/agents/runtime.ts";
import { type Places, type Passed, type Told, nothingTold } from "../../src/replica/export.ts";
import { MANIFEST_GC_GRACE_MS, encodeTranscriptManifest } from "../../src/replica/manifest.ts";
import { type Head, type Rec, type Row, BATCH, BATCH_BYTES, Folded, TABLES, VERSION, attachedPaths, batchName, batchSpan, decodeBatch, encodeBatch, genName, keyOf, runsOf } from "./replica-format.ts";
import { type Look, type Looking, storage, transcriptSourcesLooking } from "./transcript-paths.ts";
export * from "../../src/replica/export.ts";

export const CHUNK_PLAIN_BYTES = 4 * 1024 * 1024;
export const TRANSCRIPT_PASS_FILES = 512;
export const TRANSCRIPT_PASS_BYTES = 32 * 1024 * 1024;
export const TRANSCRIPT_PASS_DELETES = 2000;
export const CHUNK_GC_GRACE_MS = 10 * 60_000;

const ONE_SEGMENT = /^[A-Za-z0-9][A-Za-z0-9_.@+-]*$/;

function isMissingError(err: unknown): boolean {
  const code = (err as { code?: unknown } | null)?.code;
  return code === "ENOENT" || code === "ENOTDIR";
}

function isPrunedBrainRel(relParts: readonly string[]): boolean {
  return (
    (relParts.length === 1 && relParts[0] === "scratch") ||
    (relParts.length === 2 && relParts[0] === ".system_generated" && relParts[1] === "steps") ||
    (relParts.length === 3 && relParts[0] === ".system_generated" && relParts[1] === "logs" && relParts[2] === "chunks")
  );
}

function isPrunedBrainPath(dataDir: string, p: string): boolean {
  const rel = relative(dataDir, p);
  if (rel === "" || rel.startsWith("..")) return false;
  const parts = rel.split(sep);
  if (
    parts.length < 8 ||
    parts[0] !== "homes" ||
    !ONE_SEGMENT.test(parts[1]!) ||
    parts[2] !== "agy" ||
    parts[3] !== ".gemini" ||
    parts[4] !== "antigravity-cli" ||
    parts[5] !== "brain" ||
    !ONE_SEGMENT.test(parts[6]!)
  ) {
    return false;
  }
  if (parts[7] === "scratch") return true;
  if (parts.length >= 9 && parts[7] === ".system_generated" && parts[8] === "steps") return true;
  if (parts.length >= 10 && parts[7] === ".system_generated" && parts[8] === "logs" && parts[9] === "chunks") return true;
  return false;
}

function pathUnderAnyDir(p: string, dirs: Set<string>): boolean {
  for (const d of dirs) {
    const prefix = d.endsWith(sep) ? d : d + sep;
    if (p === d || p.startsWith(prefix)) return true;
  }
  return false;
}

function isTranscriptPath(dataDir: string, path: string): boolean {
  const rel = relative(dataDir, path);
  if (rel === "" || rel.startsWith("..")) return false;
  const parts = rel.split(/[\\/]/);
  if (parts.some((p) => p === "" || p === "." || p === "..")) return false;
  if (parts.length > 1 && parts[0]!.startsWith("transcripts")) return true;
  return (
    parts.length >= 7 &&
    parts[0] === "homes" &&
    parts[2] === "agy" &&
    parts[3] === ".gemini" &&
    parts[4] === "antigravity-cli" &&
    (parts[5] === "conversations" || parts[5] === "brain" || parts[5] === "annotations")
  );
}

/// Rows read by one statement at most, and by one pass at most before it writes what it has and goes on in the next.
export const PAGE = 500;
export const PASS_ROWS = 5_000;
/// Batches folded into one when this many of about the same size follow each other at the end of a generation.
export const FOLD_RUN = 4;
/// Batches this small together are folded as they build up; bigger ones only with all the rest (a deletion).
export const FOLD_SMALL = 1 << 20;

/// Where each generation's batches and head are kept: `<root>/<ws>/<gen>/` (`own`), and the exporter's own state.
export const ownDir = (replica: string) => join(replica, "own");
export const genDir = (root: string, ws: string, gen: string) => join(root, ws, gen);
export const headFile = (dir: string) => join(dir, "head.json");

/// Written beside and renamed into place, synced unless `sync === false`: a reader sees it whole or not at all.
export function writeWhole(path: string, bytes: Uint8Array | string, sync = true): void {
  mkdirSync(dirname(path), { recursive: true }); // sync: in the export's own thread (worker.ts)
  const tmp = `${path}.${process.pid}.${randomBytes(4).toString("hex")}.tmp`;
  const fd = openSync(tmp, "w"); // sync: in the export's own thread (worker.ts)
  try {
    writeSync(fd, typeof bytes === "string" ? Buffer.from(bytes) : bytes); // sync: in the export's own thread (worker.ts)
    if (sync) fsyncSync(fd); // sync: in the export's own thread (worker.ts)
  } finally {
    closeSync(fd); // sync: in the export's own thread (worker.ts)
  }
  renameSync(tmp, path); // sync: in the export's own thread (worker.ts)
}

export function readHead(dir: string): Head | null {
  try {
    return JSON.parse(readFileSync(headFile(dir), "utf8")) as Head; // sync: in the export's own thread (worker.ts)
  } catch {
    return null;
  }
}

const STATE = `
CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT NOT NULL) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS digests (ws TEXT NOT NULL, k TEXT NOT NULL, d TEXT NOT NULL, PRIMARY KEY (ws, k)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS threads (ws TEXT NOT NULL, thread INTEGER NOT NULL, PRIMARY KEY (ws, thread)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS files (path TEXT PRIMARY KEY, size INTEGER NOT NULL, mtime INTEGER NOT NULL, hash TEXT NOT NULL) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS files_hash ON files (hash);
CREATE TABLE IF NOT EXISTS sent (ws TEXT NOT NULL, path TEXT NOT NULL, PRIMARY KEY (ws, path)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS entering (ws TEXT NOT NULL, thread INTEGER NOT NULL, tbl TEXT NOT NULL, after INTEGER NOT NULL, upto INTEGER NOT NULL, PRIMARY KEY (ws, thread, tbl)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS transcript_files (ws TEXT NOT NULL, path TEXT NOT NULL, room TEXT, size INTEGER NOT NULL, mtime INTEGER NOT NULL, mode INTEGER NOT NULL, chunks_json TEXT NOT NULL, PRIMARY KEY (ws, path)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS transcript_chunks (plain_hash TEXT PRIMARY KEY, chunk_hash TEXT NOT NULL, comp_size INTEGER NOT NULL) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS transcript_chunks_hash ON transcript_chunks (chunk_hash);
CREATE TABLE IF NOT EXISTS transcript_chunk_gc (chunk_hash TEXT PRIMARY KEY, gone_at INTEGER NOT NULL) WITHOUT ROWID;
`;

/// The reads the export makes of stillfail.db, each by an index (or the rowid) and a limit, or by a key
/// (replica-export-bounded.test.ts reads each one's plan).
export const READS = {
  maxEntry: "SELECT MAX(rowid) AS m FROM entries",
  entries: "SELECT rowid AS _rowid, * FROM entries WHERE rowid > ? ORDER BY rowid LIMIT ?",
  letters: "SELECT rowid AS _rowid, * FROM letters WHERE rowid > ? ORDER BY rowid LIMIT ?",
  turns: "SELECT rowid AS _rowid, * FROM turns WHERE rowid > ? ORDER BY rowid LIMIT ?",
  ended: "SELECT rowid AS _rowid, * FROM turns INDEXED BY turns_ended WHERE ended_at > ?1 OR (ended_at = ?1 AND rowid > ?2) ORDER BY ended_at, rowid LIMIT ?3",
  threadWs: "SELECT s.ws AS ws FROM thread_sessions ts JOIN sessions s ON s.key = ts.session WHERE ts.thread = ?",
  sessionWs: "SELECT ws FROM sessions WHERE key = ?",
  session: "SELECT * FROM sessions WHERE key = ?",
  sessionThreads: "SELECT * FROM thread_sessions WHERE session = ?",
  sessionRuns: "SELECT * FROM runtime_sessions WHERE session_key = ?",
  sessionTurns: "SELECT rowid AS _rowid, * FROM turns WHERE session_key = ? ORDER BY started_at DESC LIMIT 2",
  sessionOpened: "SELECT * FROM opened_chats WHERE child_station = '' AND child = ?",
  thread: "SELECT * FROM threads WHERE id = ?",
  threadSessions: "SELECT * FROM thread_sessions WHERE thread = ?",
  threadCards: "SELECT * FROM closed_cards WHERE thread = ?",
  threadEntries: "SELECT rowid AS _rowid, * FROM entries WHERE thread = ? AND n > ? ORDER BY n LIMIT ?",
  threadLetters: "SELECT rowid AS _rowid, * FROM letters WHERE thread = ? AND n > ? ORDER BY n LIMIT ?",
} as const;

/// The small tables read whole as the exporter starts, a page at a time by rowid.
export const SMALL = ["sessions", "threads", "thread_sessions", "runtime_sessions", "closed_cards", "reads", "hidden_chats", "muted_chats", "kept_chats", "dismissed", "pins", "opened_chats"] as const;
export const pageOf = (table: string) => `SELECT rowid AS _rowid, * FROM ${table} WHERE rowid > ? ORDER BY rowid LIMIT ?`;
/// A viewer's marks of one thread (or pins of one session): the table's viewers one by one (a few), each its row by key.
export const marksOf = (table: string, column: string) => `WITH RECURSIVE viewers(viewer) AS (
  SELECT (SELECT viewer FROM ${table} ORDER BY viewer LIMIT 1)
  UNION ALL SELECT (SELECT viewer FROM ${table} WHERE viewer > v.viewer ORDER BY viewer LIMIT 1) FROM viewers v WHERE v.viewer IS NOT NULL
) SELECT m.* FROM viewers v CROSS JOIN ${table} m ON m.viewer = v.viewer AND m.${column} = ? WHERE v.viewer IS NOT NULL`;
export const byKey = (table: string, cols: readonly string[]) => `SELECT * FROM ${table} WHERE ${cols.map((c) => `${c} = ?`).join(" AND ")}`;

/// The marks a viewer keeps of a thread, and of a session.
const THREAD_MARKS = ["reads", "hidden_chats", "muted_chats", "kept_chats", "dismissed"];

const digest = (row: Row) => createHash("sha1").update(JSON.stringify(row)).digest("hex").slice(0, 16);
const strip = (row: Row): Row => {
  const { _rowid, ...rest } = row;
  return rest;
};
const num = (v: unknown) => (typeof v === "bigint" ? Number(v) : typeof v === "number" ? v : 0);

/// A workspace's generation as it is being written: its head and what this pass adds to it, as record lines (`bytes`
/// of them), the files they name and whether one deletes a session or a thread.
type Out = { head: Head; lines: Buffer[]; bytes: number; files: Record<string, number>; gone: boolean; messages: number };

export type ExporterOptions = {
  /// stillfail.db, read only.
  db: string;
  /// <data>/replica: the generations under own/, the exporter's state.
  replica: string;
  /// The data directory as the paths in this station's rows begin with it.
  dataDir: string;
  /// This station's id.
  origin: string;
  now: () => number;
  /// The database to read, where a test gives its own (a count of what is read).
  open?: (path: string) => DatabaseSync;
  /// How much a batch holds at most (BATCH_BYTES; a test's smaller, its memory with it).
  batchBytes?: number;
  /// Plaintext chunk size for transcript CAS (default 4 MiB; smaller in tests to verify multi-chunk dedup).
  chunkBytes?: number;
  /// Max changed transcript files processed per pass before yielding (default 64).
  transcriptPassFiles?: number;
  /// Max changed transcript bytes processed per pass before yielding (default 32 MiB).
  transcriptPassBytes?: number;
  /// Max deleted transcript records (`tr_del`) processed per pass before yielding (default 2000).
  transcriptPassDeletes?: number;
  /// Grace period (ms) before orphan transcript chunks are removed from disk (default 10 minutes; 0 for immediate GC).
  chunkGcGraceMs?: number;
  /// False: batches left as they were written, never folded (a test's, to restore a generation from them as written).
  fold?: boolean;
  /// True: emit compact `transcriptManifest` heads in IPC `pass()` results (TS runner enables via `--compact-heads`; default false for MoonBit compatibility).
  compactHeads?: boolean;
  /// Optional test-only hooks to inject deterministic filesystem faults (works even when running as root).
  testFaults?: {
    onReaddir?: (dir: string) => void;
    readdirError?: (path: string) => NodeJS.ErrnoException | null;
    finderReaddirError?: (path: string) => NodeJS.ErrnoException | null;
    lstatError?: (path: string) => NodeJS.ErrnoException | null;
    readShort?: (path: string, offset: number) => boolean;
    otherKind?: (path: string) => boolean;
  };
};

export class Exporter {
  readonly #o: ExporterOptions;
  readonly #db: DatabaseSync;
  readonly #state: DatabaseSync;
  #places: Places = { home: null, workspaces: [] };
  /// Whether this run has read the small tables whole yet.
  #known = false;
  /// Whether a transcript scan was deferred or truncated by budget and must continue in the next pass.
  #transcriptsPending = false;
  readonly #tfCache = new Map<string, Record<string, number>>();
  /// Where a transcript sweep cut short by the pass budget goes on, by workspace: the first path it did not get to.
  readonly #transcriptCursor = new Map<string, string>();
  /// Workspaces whose paths this sweep has gone through to the end; only their `tr_del`s may be left.
  readonly #transcriptScanDone = new Set<string>();
  /// Workspaces this sweep is done with, `tr_del`s too.
  readonly #transcriptWsDone = new Set<string>();
  /// A pass told of transcripts while a sweep was under way: what it told of may lie behind the cursor, so another
  /// sweep follows this one.
  #transcriptResweep = false;
  readonly #manifestCache = new Map<string, { rootHash: string; leafHashes: string[] }>();
  #manifestLive = new Set<string>();
  readonly #manifestSupersededAt = new Map<string, number>();
  #closed = false;
  /// This run of the exporter: a generation's head lists the runs that wrote it (a copy that holds a run this station's
  /// own does not know was written by one rolled back).
  readonly run = randomBytes(4).toString("hex");
  readonly #prepared = new Map<string, ReturnType<DatabaseSync["prepare"]>>();
  /// Rows of stillfail.db read in this pass.
  #read = 0;
  get #most(): number {
    return this.#o.batchBytes ?? BATCH_BYTES;
  }
  get #chunkBytes(): number {
    return this.#o.chunkBytes !== undefined && this.#o.chunkBytes > 0 ? this.#o.chunkBytes : CHUNK_PLAIN_BYTES;
  }
  get #transcriptPassFiles(): number {
    return this.#o.transcriptPassFiles !== undefined && this.#o.transcriptPassFiles > 0 ? this.#o.transcriptPassFiles : TRANSCRIPT_PASS_FILES;
  }
  get #transcriptPassBytes(): number {
    return this.#o.transcriptPassBytes !== undefined && this.#o.transcriptPassBytes > 0 ? this.#o.transcriptPassBytes : TRANSCRIPT_PASS_BYTES;
  }
  get #transcriptPassDeletes(): number {
    return this.#o.transcriptPassDeletes !== undefined && this.#o.transcriptPassDeletes > 0 ? this.#o.transcriptPassDeletes : TRANSCRIPT_PASS_DELETES;
  }
  get #chunkGcGraceMs(): number {
    return this.#o.chunkGcGraceMs !== undefined && this.#o.chunkGcGraceMs >= 0 ? this.#o.chunkGcGraceMs : CHUNK_GC_GRACE_MS;
  }

  constructor(o: ExporterOptions) {
    this.#o = o;
    this.#db = o.open ? o.open(o.db) : new DatabaseSync(o.db, { readOnly: true, timeout: 5000 });
    mkdirSync(o.replica, { recursive: true }); // sync: in the export's own thread (worker.ts)
    this.#state = new DatabaseSync(join(o.replica, "export.db"), { timeout: 5000 });
    this.#state.exec("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;");
    this.#state.exec(STATE);
    // A database rolled back under its exporter (a backup put back): what it says now was never exported as it is.
    const at = this.#meta("entries");
    const max = num((this.#q(READS.maxEntry).get() as Row | undefined)?.m);
    if (at !== null && Number(at) > max) this.#forget();
  }

  close(): void {
    if (this.#closed) return;
    this.#closed = true;
    this.#db.close();
    this.#state.close();
  }

  #q(sql: string) {
    let s = this.#prepared.get(sql);
    if (s === undefined) this.#prepared.set(sql, (s = this.#db.prepare(sql)));
    return s;
  }

  #meta(k: string): string | null {
    return (this.#state.prepare("SELECT v FROM meta WHERE k = ?").get(k) as { v: string } | undefined)?.v ?? null;
  }
  #setMeta(k: string, v: string): void {
    this.#state.prepare("INSERT INTO meta (k, v) VALUES (?, ?) ON CONFLICT (k) DO UPDATE SET v = excluded.v").run(k, v);
  }

  /// Everything exported is forgotten: the next pass writes it all again, in new generations.
  #forget(): void {
    this.#state.exec("DELETE FROM meta WHERE k <> 'after'; DELETE FROM digests; DELETE FROM threads; DELETE FROM sent; DELETE FROM entering; DELETE FROM transcript_files; DELETE FROM transcript_chunk_gc;");
    this.#known = false;
    this.#transcriptsPending = false;
    this.#forgetSweep();
    this.#tfCache.clear();
    this.#manifestCache.clear();
    this.#manifestLive.clear();
    this.#manifestSupersededAt.clear();
  }

  #forgetSweep(): void {
    this.#endSweep();
    this.#transcriptResweep = false;
  }

  /// A sweep over: the next starts from each workspace's first path.
  #endSweep(): void {
    this.#transcriptCursor.clear();
    this.#transcriptScanDone.clear();
    this.#transcriptWsDone.clear();
  }

  #inTranscriptSweep(): boolean {
    return this.#transcriptCursor.size > 0 || this.#transcriptScanDone.size > 0 || this.#transcriptWsDone.size > 0;
  }

  setPlaces(places: Places): void {
    this.#places = places;
  }

  /// A new generation for each workspace: this station's own copy was found behind one held elsewhere (rolled back),
  /// and what it has is written again from the start, beside what is held. `after`: when the latest generation held
  /// there began, which the new ones begin after whatever this machine's clock says.
  newGenerations(after = 0): void {
    this.#forget();
    this.#setMeta("after", String(after));
  }

  #root() {
    return ownDir(this.#o.replica);
  }

  /// The generation being written for `ws`, made where there is none.
  #genOf(ws: string): string {
    const known = this.#meta(`gen:${ws}`);
    if (known !== null && existsSync(genDir(this.#root(), ws, known))) return known; // sync: in the export's own thread (worker.ts)
    const gen = genName(Math.max(this.#o.now(), Number(this.#meta("after") ?? 0) + 1), randomBytes(4).toString("hex"));
    this.#setMeta(`gen:${ws}`, gen);
    // (what was written of this workspace before belongs to another generation)
    this.#state.prepare("DELETE FROM digests WHERE ws = ?").run(ws);
    this.#state.prepare("DELETE FROM threads WHERE ws = ?").run(ws);
    this.#state.prepare("DELETE FROM sent WHERE ws = ?").run(ws);
    this.#state.prepare("DELETE FROM entering WHERE ws = ?").run(ws);
    const dropped = Number(this.#state.prepare("DELETE FROM transcript_files WHERE ws = ?").run(ws).changes);
    this.#tfCache.delete(ws);
    this.#manifestCache.delete(ws);
    // Its transcripts are written again, all of them: none is behind a cursor of the generation before. A workspace
    // with none exported (one with nothing written has no generation directory, so comes here every pass) asks for no scan.
    this.#transcriptCursor.delete(ws);
    this.#transcriptScanDone.delete(ws);
    this.#transcriptWsDone.delete(ws);
    if (dropped > 0) this.#transcriptsPending = true;
    return gen;
  }

  /// The heads of this station's generations now, by workspace.
  heads(): Record<string, Head> {
    const out: Record<string, Head> = {};
    for (const { workspace } of this.#places.workspaces) {
      const gen = this.#meta(`gen:${workspace}`);
      const head = gen === null ? null : readHead(genDir(this.#root(), workspace, gen));
      if (head !== null) out[workspace] = head;
    }
    return out;
  }

  /// One pass: what changed, as told and as found, written as batches for each workspace it is of. `more`: there is
  /// more already, for the next pass. What the exporter keeps of where it is (export.db) is one transaction with the
  /// pass, committed once the heads that name its batches are written: a pass stopped or failing before that leaves
  /// export.db as it was, and the next one reads the same rows again (said twice where the heads were written: a fold
  /// keeps the last of a key).
  pass(told: Told): Passed {
    const { home, workspaces } = this.#places;
    if (home === null || workspaces.length === 0) return { heads: {}, more: false, wrote: 0, read: 0 };
    // A pass that fails leaves what it was to do as it found it: it may have said the transcripts were done.
    const known = this.#known;
    const pending = this.#transcriptsPending;
    this.#state.exec("BEGIN IMMEDIATE");
    try {
      const passed = this.#pass(told, home, workspaces);
      this.#state.exec("COMMIT");
      return passed;
    } catch (e) {
      this.#state.exec("ROLLBACK");
      this.#tfCache.clear();
      this.#manifestCache.clear();
      this.#forgetSweep();
      this.#known = known;
      this.#transcriptsPending = pending;
      throw e;
    }
  }

  #pass(told: Told, home: string, workspaces: Places["workspaces"]): Passed {
    const names = new Map(workspaces.map((w) => [w.workspace, w.name]));
    const wsOfSession = (ws: unknown) => (typeof ws === "string" && ws !== "" ? ws : home);
    // Brought up to date before anything is read: a generation begun now has nothing of before, and is read whole.
    const outs = new Map<string, Out>();
    for (const ws of names.keys()) {
      const gen = this.#genOf(ws);
      const dir = genDir(this.#root(), ws, gen);
      const head: Head = readHead(dir) ?? {
        v: VERSION, origin: this.#o.origin, workspace: ws, gen, name: names.get(ws) ?? "", dataDir: this.#o.dataDir, made: 0, to: 0,
        batches: [], files: {}, chats: 0, messages: 0, bytes: 0, runs: [],
      };
      outs.set(ws, { head, lines: [], bytes: 0, files: {}, gone: false, messages: 0 });
    }
    if (this.#meta("entries") === null) {
      // (a generation begun: everything again, from the start)
      for (const k of ["entries", "letters", "turns"]) this.#setMeta(k, "0");
      this.#setMeta("ended", JSON.stringify([-1, 0]));
      this.#known = false;
    }
    const say = (ws: string, rec: Rec) => {
      const out = outs.get(ws);
      if (out === undefined) return;
      const line = Buffer.from(JSON.stringify(rec) + "\n", "utf8");
      out.lines.push(line);
      out.bytes += line.length;
      if ("gone" in rec) out.gone = true;
      if ("file" in rec) out.files[rec.file] = rec.size;
    };
    /// Whether this pass has as much as a batch holds, or read as much as a pass reads: the rest is the next pass's.
    const enough = () => this.#read >= PASS_ROWS || [...outs.values()].some((o) => o.bytes >= this.#most);
    const getDigest = this.#state.prepare("SELECT d FROM digests WHERE ws = ? AND k = ?");
    const putDigest = this.#state.prepare("INSERT INTO digests (ws, k, d) VALUES (?, ?, ?) ON CONFLICT (ws, k) DO UPDATE SET d = excluded.d");
    const dropDigest = this.#state.prepare("DELETE FROM digests WHERE ws = ? AND k = ?");
    const hasThread = this.#state.prepare("SELECT 1 FROM threads WHERE ws = ? AND thread = ?");
    const addThread = this.#state.prepare("INSERT OR IGNORE INTO threads (ws, thread) VALUES (?, ?)");
    const dropThread = this.#state.prepare("DELETE FROM threads WHERE ws = ? AND thread = ?");
    this.#read = 0;
    const all = (sql: string, ...args: (string | number | null)[]) => {
      const rows = this.#q(sql).all(...args) as Row[];
      this.#read += rows.length;
      return rows;
    };
    /// A row of a table that changes in place, written where it differs from what was written of it.
    const changed = (ws: string, table: string, row: Row) => {
      const clean = strip(row);
      const k = `${table}|${keyOf(table, clean)}`;
      const d = digest(clean);
      if ((getDigest.get(ws, k) as { d: string } | undefined)?.d === d) return;
      putDigest.run(ws, k, d);
      say(ws, { r: table, row: clean });
    };
    // The workspaces a thread is in (those of its sessions; one with none is the home one's), as of this pass.
    const threadWs = new Map<number, string[]>();
    const wsOfThread = (thread: number): string[] => {
      let ws = threadWs.get(thread);
      if (ws === undefined) {
        const of = all(READS.threadWs, thread).map((r) => wsOfSession(r.ws));
        ws = of.length === 0 ? [home] : [...new Set(of)];
        ws = ws.filter((w) => outs.has(w));
        threadWs.set(thread, ws);
      }
      return ws;
    };
    const filesSaid = new Map<string, Set<string>>();
    const attached = (ws: string, row: Row) => {
      for (const path of attachedPaths(row)) {
        let s = filesSaid.get(ws);
        if (s === undefined) filesSaid.set(ws, (s = new Set()));
        s.add(path);
      }
    };
    // What of a thread a workspace is told of all at once, as the thread is first of it (a chat whose session came
    // into it, or every chat of a generation begun): its rows as they are, and its logs up to where this pass began.
    const cursor = { entries: Number(this.#meta("entries")), letters: Number(this.#meta("letters")) };
    const threadRows = (ws: string, thread: number) => {
      const t = all(READS.thread, thread)[0];
      if (t !== undefined) changed(ws, "threads", t);
      for (const r of all(READS.threadSessions, thread)) changed(ws, "thread_sessions", r);
      for (const r of all(READS.threadCards, thread)) changed(ws, "closed_cards", r);
      for (const table of THREAD_MARKS) for (const r of all(marksOf(table, "thread"), thread)) changed(ws, table, r);
    };
    // (its logs up to there a page at a time, in this pass and those after it, as a batch has room: `entering`)
    const entering = this.#state.prepare("INSERT OR IGNORE INTO entering (ws, thread, tbl, after, upto) VALUES (?, ?, ?, 0, ?)");
    const enter = (thread: number) => {
      for (const ws of wsOfThread(thread)) {
        if (hasThread.get(ws, thread) !== undefined) continue;
        addThread.run(ws, thread);
        threadRows(ws, thread);
        if (cursor.entries > 0) entering.run(ws, thread, "entries", cursor.entries);
        if (cursor.letters > 0) entering.run(ws, thread, "letters", cursor.letters);
      }
    };
    const drainEntering = () => {
      const next = this.#state.prepare("SELECT ws, thread, tbl, after, upto FROM entering LIMIT 1");
      const moved = this.#state.prepare("UPDATE entering SET after = ? WHERE ws = ? AND thread = ? AND tbl = ?");
      const done = this.#state.prepare("DELETE FROM entering WHERE ws = ? AND thread = ? AND tbl = ?");
      for (;;) {
        if (enough()) return true;
        const e = next.get() as { ws: string; thread: number; tbl: "entries" | "letters"; after: number; upto: number } | undefined;
        if (e === undefined) return false;
        if (!outs.has(e.ws)) {
          done.run(e.ws, e.thread, e.tbl);
          continue;
        }
        const rows = all(e.tbl === "entries" ? READS.threadEntries : READS.threadLetters, e.thread, e.after, PAGE);
        for (const r of rows) {
          if (num(r._rowid) > e.upto) continue;
          say(e.ws, { r: e.tbl, row: strip(r) });
          attached(e.ws, r);
          if (e.tbl === "entries" && r.kind === "message") outs.get(e.ws)!.messages++;
        }
        if (rows.length < PAGE) done.run(e.ws, e.thread, e.tbl);
        else moved.run(num(rows[rows.length - 1]!.n), e.ws, e.thread, e.tbl);
      }
    };
    const sessionRows = (key: string) => {
      const s = all(READS.session, key)[0];
      if (s === undefined) return;
      const ws = wsOfSession(s.ws);
      if (!outs.has(ws)) return;
      changed(ws, "sessions", s);
      for (const r of all(READS.sessionThreads, key)) {
        changed(ws, "thread_sessions", r);
        enter(num(r.thread));
      }
      for (const r of all(READS.sessionRuns, key)) changed(ws, "runtime_sessions", r);
      for (const r of all(READS.sessionTurns, key)) changed(ws, "turns", r);
      for (const r of all(READS.sessionOpened, key)) changed(ws, "opened_chats", r);
      for (const r of all(marksOf("pins", "session"), key)) changed(ws, "pins", r);
    };
    let more = false;
    const wantTranscripts = told.transcripts === true;
    const scanTranscripts = !this.#known || wantTranscripts || this.#transcriptsPending;
    const sessRows: Row[] = [];
    const runRows = new Map<string, Row[]>();
    /// Whether `sessRows` and `runRows` hold the sessions already (the small tables were read whole this pass).
    let loadedTranscriptSessions = false;
    this.#db.exec("BEGIN");
    try {
      // What was deleted, as told.
      for (const { key, ws } of told.removedSessions) {
        const w = wsOfSession(ws);
        say(w, { gone: "session", key });
        this.#state.prepare("DELETE FROM digests WHERE ws = ? AND k >= ? AND k < ?").run(w, `sessions|${JSON.stringify([key])}`, `sessions|${JSON.stringify([key])}￿`);
      }
      for (const { id, ws } of told.removedThreads) {
        for (const w of ws === null || ws === undefined ? [...outs.keys()] : [wsOfSession(ws)]) {
          if (hasThread.get(w, id) === undefined) continue;
          say(w, { gone: "thread", id });
          dropThread.run(w, id);
        }
      }
      // The small tables whole, once a run: what changed while no exporter ran, and what went.
      if (!this.#known) {
        const seen = new Map<string, Set<string>>();
        for (const table of SMALL) {
          for (let after = 0; ; ) {
            const rows = all(pageOf(table), after, PAGE);
            for (const r of rows) {
              if (table === "sessions") sessRows.push(r);
              else if (table === "runtime_sessions" && typeof r.session_key === "string") {
                let xs = runRows.get(r.session_key);
                if (xs === undefined) runRows.set(r.session_key, (xs = []));
                xs.push(r);
              }
              const wss = table === "sessions" || table === "runtime_sessions" || table === "pins" || table === "opened_chats"
                ? this.#sessionWs(table, r, wsOfSession)
                : wsOfThread(num(table === "threads" ? r.id : r.thread));
              for (const ws of wss) {
                if (!outs.has(ws)) continue;
                if (table === "threads") enter(num(r.id));
                changed(ws, table, r);
                let s = seen.get(ws);
                if (s === undefined) seen.set(ws, (s = new Set()));
                s.add(`${table}|${keyOf(table, strip(r))}`);
              }
            }
            if (rows.length < PAGE) break;
            after = num(rows[rows.length - 1]!._rowid);
          }
        }
        // What was written of before and is not there now: gone.
        for (const ws of outs.keys()) {
          const s = seen.get(ws) ?? new Set();
          for (const { k } of this.#state.prepare("SELECT k FROM digests WHERE ws = ?").all(ws) as { k: string }[]) {
            if (s.has(k) || k.startsWith("turns|")) continue;
            const bar = k.indexOf("|");
            const table = k.slice(0, bar);
            const key = JSON.parse(k.slice(bar + 1)) as unknown[];
            dropDigest.run(ws, k);
            if (table === "sessions") say(ws, { gone: "session", key: String(key[0]) });
            else if (table === "threads") {
              say(ws, { gone: "thread", id: num(key[0]) });
              dropThread.run(ws, num(key[0]));
            } else {
              const named: Row = {};
              keyColumns(table).forEach((c, i) => (named[c] = key[i] ?? null));
              say(ws, { del: table, key: named });
            }
          }
        }
        this.#known = true;
        loadedTranscriptSessions = true;
      }
      // What changed in place, as told.
      for (const key of told.sessions) sessionRows(key);
      for (const thread of told.threads) {
        enter(thread);
        for (const ws of wsOfThread(thread)) threadRows(ws, thread);
      }
      for (const { table, key } of told.marks) {
        const cols = keyColumns(table);
        const row = all(byKey(table, cols), ...cols.map((c) => key[c] as string | number))[0];
        const wss = table === "pins" ? this.#sessionWs("pins", key, wsOfSession) : wsOfThread(num(key.thread));
        for (const ws of wss) {
          const k = `${table}|${keyOf(table, key)}`;
          if (row !== undefined) changed(ws, table, row);
          else if (getDigest.get(ws, k) !== undefined) {
            dropDigest.run(ws, k);
            say(ws, { del: table, key });
          }
        }
      }
      // A thread new to a workspace: its logs before.
      if (drainEntering()) more = true;
      // The logs, past where they were exported.
      for (const [table, sql] of [["entries", READS.entries], ["letters", READS.letters]] as const) {
        let at = cursor[table];
        for (;;) {
          if (enough()) {
            more = true;
            break;
          }
          const rows = all(sql, at, PAGE);
          for (const r of rows) {
            const thread = num(r.thread);
            enter(thread);
            for (const ws of wsOfThread(thread)) {
              say(ws, { r: table, row: strip(r) });
              attached(ws, r);
              if (table === "entries" && r.kind === "message") outs.get(ws)!.messages++;
            }
            at = num(r._rowid);
          }
          if (rows.length < PAGE) break;
        }
        this.#setMeta(table, String(at));
      }
      for (const [k, sql] of [["turns", READS.turns], ["ended", READS.ended]] as const) {
        let at: [number, number] = k === "turns" ? [Number(this.#meta("turns")), 0] : (JSON.parse(this.#meta("ended")!) as [number, number]);
        for (;;) {
          if (enough()) {
            more = true;
            break;
          }
          const rows = k === "turns" ? all(sql, at[0], PAGE) : all(sql, at[0], at[1], PAGE);
          for (const r of rows) {
            const ws = this.#sessionWs("turns", r, wsOfSession)[0];
            if (ws !== undefined && outs.has(ws)) changed(ws, "turns", r);
            at = k === "turns" ? [num(r._rowid), 0] : [num(r.ended_at), num(r._rowid)];
          }
          if (rows.length < PAGE) break;
        }
        this.#setMeta(k, k === "turns" ? String(at[0]) : JSON.stringify(at));
      }
    } finally {
      this.#db.exec("COMMIT");
    }
    // The files the rows name, each once in a generation: by the hash of what it holds.
    for (const [ws, paths] of filesSaid) {
      const sent = this.#state.prepare("SELECT 1 FROM sent WHERE ws = ? AND path = ?");
      for (const path of paths) {
        if (sent.get(ws, path) !== undefined) continue;
        const f = this.#hashed(path);
        if (f === null) continue;
        this.#state.prepare("INSERT OR IGNORE INTO sent (ws, path) VALUES (?, ?)").run(ws, path);
        say(ws, { file: f.hash, size: f.size, path });
      }
    }
    let sweepCompleted = false;
    if (scanTranscripts) {
      if (wantTranscripts && this.#inTranscriptSweep()) this.#transcriptResweep = true;
      if (more) {
        this.#transcriptsPending = true;
      } else {
        // The sessions the transcripts are found by, read only once the logs are caught up and outside the pass's row
        // budget: read before, on a station with more sessions than PASS_ROWS, they used up every pass's budget ahead
        // of the logs, so `more` never came false and nothing after them (logs, transcripts) was exported again.
        if (!loadedTranscriptSessions) this.#transcriptSessions(sessRows, runRows);
        const transcriptsMore = this.#exportTranscripts(outs, sessRows, runRows, wsOfSession, say);
        if (transcriptsMore) {
          this.#transcriptsPending = true;
          more = true;
        } else {
          sweepCompleted = true;
          if (this.#transcriptResweep) {
            this.#transcriptResweep = false;
            this.#transcriptsPending = true;
            more = true;
          } else {
            this.#transcriptsPending = false;
          }
        }
      }
    }
    let wrote = 0;
    const heads: Record<string, Head> = {};
    for (const [ws, out] of outs) {
      if (out.lines.length > 0) {
        this.#write(ws, out);
        wrote++;
      }
      heads[ws] = this.#o.compactHeads === true ? this.#compactHead(ws, out.head) : out.head;
    }
    if (this.#o.compactHeads === true) {
      this.#gcManifests(outs);
    }
    // After each whole sweep, a sweep to follow or not: never in the middle of one.
    if (sweepCompleted) {
      this.#gcTranscriptChunks();
    }
    return { heads, more, wrote, read: this.#read };
  }

  /// Every session and runtime session, for finding transcripts by: in a short read of their own, not counted in the
  /// pass's rows.
  #transcriptSessions(sessRows: Row[], runRows: Map<string, Row[]>): void {
    this.#db.exec("BEGIN");
    try {
      for (const table of ["sessions", "runtime_sessions"] as const) {
        for (let after = 0; ; ) {
          const rows = this.#q(pageOf(table)).all(after, PAGE) as Row[];
          for (const r of rows) {
            if (table === "sessions") sessRows.push(r);
            else if (typeof r.session_key === "string") {
              let xs = runRows.get(r.session_key);
              if (xs === undefined) runRows.set(r.session_key, (xs = []));
              xs.push(r);
            }
          }
          if (rows.length < PAGE) break;
          after = num(rows[rows.length - 1]!._rowid);
        }
      }
    } finally {
      this.#db.exec("COMMIT");
    }
  }

  #sessionWs(table: string, row: Row, wsOf: (ws: unknown) => string): string[] {
    const key = table === "sessions" ? row.key : table === "pins" ? row.session : table === "opened_chats" ? row.child : row.session_key;
    if (table === "opened_chats" && row.child_station !== "") return [];
    if (table === "sessions") return [wsOf(row.ws)];
    const s = this.#q(READS.sessionWs).get(key as string) as Row | undefined;
    if (s !== undefined) this.#read++;
    return s === undefined ? [] : [wsOf(s.ws)];
  }

  /// The hash and size of the file at `path`, read once while it is as it was; null where it is not there.
  #hashed(path: string): { hash: string; size: number } | null {
    let st;
    try {
      st = statSync(path, { bigint: true }); // sync: in the export's own thread (worker.ts)
    } catch {
      return null;
    }
    if (!st.isFile()) return null;
    const known = this.#state.prepare("SELECT size, mtime, hash FROM files WHERE path = ?").get(path) as { size: number; mtime: number; hash: string } | undefined;
    const size = Number(st.size);
    const mtime = Number(st.mtimeNs / 1_000_000n);
    if (known !== undefined && known.size === size && known.mtime === mtime) return { hash: known.hash, size: known.size };
    const h = createHash("sha256");
    const fd = openSync(path, "r"); // sync: in the export's own thread (worker.ts)
    try {
      const buf = Buffer.alloc(1 << 20);
      for (let n; (n = readSync(fd, buf, 0, buf.length, null)) > 0; ) h.update(buf.subarray(0, n)); // sync: in the export's own thread (worker.ts)
    } finally {
      closeSync(fd); // sync: in the export's own thread (worker.ts)
    }
    const hash = h.digest("hex");
    this.#state.prepare("INSERT INTO files (path, size, mtime, hash) VALUES (?, ?, ?, ?) ON CONFLICT (path) DO UPDATE SET size = excluded.size, mtime = excluded.mtime, hash = excluded.hash").run(path, size, mtime, hash);
    return { hash, size };
  }

  /// Batches of what `out` says (as many as BATCH_BYTES makes it), then the head that names them; folded as batches
  /// build up.
  #write(ws: string, out: Out): void {
    const head = out.head;
    const dir = genDir(this.#root(), ws, head.gen);
    const made = this.#o.now();
    let n = head.to;
    const names: string[] = [];
    const first = n + 1;
    for (const run of runsOf(out.lines, this.#most)) {
      n++;
      const bytes = encodeBatch({ v: VERSION, gen: head.gen, from: n, to: n, made }, [], run);
      const name = batchName(n, n, bytes);
      writeWhole(join(dir, "log", name), bytes);
      names.push(name);
    }
    const runs = [...head.runs];
    if (runs.length === 0 || runs[runs.length - 1]!.run !== this.run) runs.push({ run: this.run, from: first });
    let tf = this.#tfCache.get(ws);
    if (tf === undefined) {
      tf = this.#transcriptFilesMap(ws);
      this.#tfCache.set(ws, tf);
    }
    const next: Head = {
      ...head, made, to: n, batches: [...head.batches, ...names], runs: runs.slice(-RUNS_KEPT), files: { ...head.files, ...out.files },
      chats: (this.#state.prepare("SELECT COUNT(*) AS n FROM threads WHERE ws = ?").get(ws) as { n: number }).n,
      messages: head.messages + out.messages,
    };
    let hasTf = false;
    for (const _ in tf) {
      hasTf = true;
      break;
    }
    if (hasTf) next.transcriptFiles = tf;
    else delete next.transcriptFiles;
    out.head = this.#fold(dir, next, out.gone);
  }

  /// The generation's batches folded where they built up: all of them where something was deleted (so a deletion
  /// deletes in the copies too, its files with it), else the last FOLD_RUN where they are small and of about one size.
  /// Folded through a working database on disk (`Folded`), written back as batches of at most BATCH_BYTES: nothing of
  /// it in memory grows with the copy.
  #fold(dir: string, head: Head, all: boolean): Head {
    const size = (b: string) => statSync(join(dir, "log", b)).size; // sync: in the export's own thread (worker.ts)
    const level = (b: string) => Math.floor(Math.log(Math.max(size(b), 4096) / 4096) / Math.log(FOLD_RUN));
    let h = head;
    for (;;) {
      if (this.#o.fold === false) break;
      const bs = h.batches;
      let take: string[];
      if (all) {
        if (bs.length === 0) break;
        take = bs;
      } else {
        if (bs.length < FOLD_RUN) break;
        const tail = bs.slice(-FOLD_RUN);
        const l = level(tail[0]!);
        // (a run as big as a batch is not folded again but with all of them)
        if (!tail.every((b) => level(b) === l) || tail.reduce((n, b) => n + size(b), 0) >= FOLD_SMALL) break;
        take = tail;
      }
      const work = join(this.#o.replica, "fold.db");
      rmSync(work, { force: true }); // sync: in the export's own thread (worker.ts)
      const folded = new Folded(work);
      try {
        for (const b of take) for (const line of decodeBatch(readFileSync(join(dir, "log", b))).lines) folded.apply(line); // sync: in the export's own thread (worker.ts)
        const from = batchSpan(take[0]!)!.from;
        const to = batchSpan(take[take.length - 1]!)!.to;
        const whole = take.length === bs.length;
        const names: string[] = [];
        for (const run of runsOf(whole ? folded.records() : folded.partial(), this.#most)) {
          const bytes = encodeBatch({ v: VERSION, gen: h.gen, from, to, made: h.made }, [], run);
          const name = batchName(from, to, bytes);
          writeWhole(join(dir, "log", name), bytes);
          names.push(name);
        }
        const files: Record<string, number> = {};
        if (whole) for (const f of folded.namedFiles()) files[f.hash] = f.size;
        const counts = whole ? folded.counts() : { chats: h.chats, messages: h.messages };
        h = { ...h, batches: [...bs.slice(0, bs.length - take.length), ...names], files: whole ? files : h.files, ...counts };
        writeWhole(headFile(dir), JSON.stringify(h, null, 1));
        for (const b of take) if (!names.includes(b)) rmSync(join(dir, "log", b), { force: true }); // sync: in the export's own thread (worker.ts)
      } finally {
        folded.close();
        rmSync(work, { force: true }); // sync: in the export's own thread (worker.ts)
      }
      // (done, or a run that folds into as many batches as it was, each as full as BATCH_BYTES lets it be: compressed
      // small, raw full; folding it again would make it again)
      if (all || h.batches.length >= bs.length) break;
    }
    h = { ...h, bytes: this.#bytes(dir, h) };
    writeWhole(headFile(dir), JSON.stringify(h, null, 1));
    // (a batch written by a run that ended before its head was, or half of one: never named, let go)
    for (const b of readdirSync(join(dir, "log"))) if (!h.batches.includes(b)) rmSync(join(dir, "log", b), { force: true }); // sync: in the export's own thread (worker.ts)
    return h;
  }

  #bytes(dir: string, h: Head): number {
    let n = 0;
    for (const b of h.batches) {
      try {
        n += statSync(join(dir, "log", b)).size; // sync: in the export's own thread (worker.ts)
      } catch {}
    }
    const seen = new Set<string>();
    for (const [k, size] of Object.entries(h.files)) {
      seen.add(k);
      n += size;
    }
    for (const [k, size] of Object.entries(h.transcriptFiles ?? {})) {
      if (!seen.has(k)) {
        seen.add(k);
        n += size;
      }
    }
    return n;
  }

  /// Whether this station has no chat of its own yet (a copy is taken back only into such a one).
  empty(): boolean {
    return this.#q("SELECT 1 FROM sessions LIMIT 1").get() === undefined && this.#q("SELECT 1 FROM threads LIMIT 1").get() === undefined;
  }

  /// Where the file of `hash` is now on this station, for a place that lacks it; null where none is.
  sourceOf(hash: string): string | null {
    for (const { path } of this.#state.prepare("SELECT path FROM files WHERE hash = ?").all(hash) as { path: string }[]) {
      try {
        if (statSync(path).isFile()) return path; // sync: in the export's own thread (worker.ts)
      } catch {}
    }
    const chunk = join(this.#o.replica, "chunks", hash);
    try {
      if (statSync(chunk).isFile()) return chunk; // sync: in the export's own thread (worker.ts)
    } catch {}
    const manifest = join(this.#o.replica, "manifests", hash);
    try {
      if (statSync(manifest).isFile()) return manifest; // sync: in the export's own thread (worker.ts)
    } catch {}
    return null;
  }

  #lstatPath(p: string) {
    const err = this.#o.testFaults?.lstatError?.(p);
    if (err) throw err;
    return lstatSync(p, { bigint: true }); // sync: in the export's own thread (worker.ts)
  }

  #readdirEntries(dir: string) {
    this.#o.testFaults?.onReaddir?.(dir);
    const err = this.#o.testFaults?.readdirError?.(dir);
    if (err) throw err;
    return readdirSync(dir, { withFileTypes: true }).sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0)); // sync: in the export's own thread (worker.ts)
  }

  #dirUnreadableChecked(dir: string): boolean {
    this.#o.testFaults?.onReaddir?.(dir);
    const faultErr = this.#o.testFaults?.readdirError?.(dir);
    if (faultErr) return !isMissingError(faultErr);
    try {
      const d = opendirSync(dir); // sync: in the export's own thread (worker.ts)
      d.closeSync();
      return false;
    } catch (e) {
      return !isMissingError(e);
    }
  }

  #walkTranscriptDir(
    dir: string,
    add: (path: string) => void,
    onError: (dir: string) => void = () => {},
    onUnreadablePath: (path: string) => void = () => {},
  ): void {
    let entries;
    try {
      entries = this.#readdirEntries(dir);
    } catch (e) {
      if (!isMissingError(e)) onError(dir);
      return;
    }
    for (const e of entries) {
      const p = join(dir, e.name);
      const forceOther = this.#o.testFaults?.otherKind?.(p) === true;
      if (!forceOther && e.isDirectory()) this.#walkTranscriptDir(p, add, onError, onUnreadablePath);
      else if (!forceOther && e.isFile()) add(p);
      else if (forceOther || !e.isSymbolicLink()) {
        try {
          const st = this.#lstatPath(p);
          if (st.isFile()) add(p);
          else if (st.isDirectory()) this.#walkTranscriptDir(p, add, onError, onUnreadablePath);
        } catch (err) {
          if (!isMissingError(err)) {
            onUnreadablePath(p);
            onError(p);
          }
        }
      }
    }
  }

  #walkBrainDir(
    brainRoot: string,
    dir: string,
    relParts: string[],
    add: (path: string) => void,
    onError: (dir: string) => void,
    onUnreadablePath: (path: string) => void,
  ): void {
    if (isPrunedBrainRel(relParts)) return;
    let entries;
    try {
      entries = this.#readdirEntries(dir);
    } catch (e) {
      if (!isMissingError(e)) onError(dir);
      return;
    }
    for (const e of entries) {
      const p = join(dir, e.name);
      const forceOther = this.#o.testFaults?.otherKind?.(p) === true;
      if (!forceOther && e.isDirectory()) {
        const nextRel = [...relParts, e.name];
        if (isPrunedBrainRel(nextRel)) continue;
        this.#walkBrainDir(brainRoot, p, nextRel, add, onError, onUnreadablePath);
      } else if (!forceOther && e.isFile()) {
        add(p);
      } else if (forceOther || !e.isSymbolicLink()) {
        try {
          const st = this.#lstatPath(p);
          if (st.isFile()) add(p);
          else if (st.isDirectory()) {
            const nextRel = [...relParts, e.name];
            if (!isPrunedBrainRel(nextRel)) this.#walkBrainDir(brainRoot, p, nextRel, add, onError, onUnreadablePath);
          }
        } catch (err) {
          if (!isMissingError(err)) {
            onUnreadablePath(p);
            onError(p);
          }
        }
      }
    }
  }

  #lookTranscriptSources<T>(looking: Looking<T>, onUnreadableDir: (dir: string) => void): T {
    const rolloutUnder = (dir: string, id: string): string | null => {
      let entries;
      try {
        const finderFault = this.#o.testFaults?.finderReaddirError?.(dir);
        if (finderFault) throw finderFault;
        entries = this.#readdirEntries(dir);
      } catch (e) {
        if (!isMissingError(e)) onUnreadableDir(dir);
        return null;
      }
      for (const entry of entries) {
        const name = entry.name;
        const p = join(dir, name);
        let isSubDir = entry.isDirectory();
        if (!isSubDir && !entry.isFile()) {
          try {
            isSubDir = statSync(p).isDirectory(); // sync: in the export's own thread (worker.ts)
          } catch {
            isSubDir = false;
          }
        }
        if (isSubDir) {
          const found = rolloutUnder(p, id);
          if (found !== null) return found;
        } else if (name.startsWith("rollout-") && name.endsWith(`${id}.jsonl`)) {
          return p;
        } else if (name.startsWith("rollout-") && name.endsWith(`${id}.jsonl.zst`)) {
          return p.slice(0, -".zst".length);
        }
      }
      return null;
    };
    const answer = (look: Look): unknown => {
      switch (look.ask) {
        case "there":
          return existsSync(look.path); // sync: in the export's own thread (worker.ts)
        case "file":
          try {
            return statSync(look.path).isFile(); // sync: in the export's own thread (worker.ts)
          } catch {
            return false;
          }
        case "names":
          try {
            this.#o.testFaults?.onReaddir?.(look.path);
            const faultErr = this.#o.testFaults?.finderReaddirError?.(look.path) ?? this.#o.testFaults?.readdirError?.(look.path);
            if (faultErr) throw faultErr;
            return readdirSync(look.path); // sync: in the export's own thread (worker.ts)
          } catch (e) {
            if (!isMissingError(e)) onUnreadableDir(look.path);
            return null;
          }
        case "real":
          try {
            return realpathSync(look.path); // sync: in the export's own thread (worker.ts)
          } catch {
            return null;
          }
        case "rollout":
          return rolloutUnder(look.path, look.id);
      }
    };
    for (let step = looking.next(); ; step = looking.next(answer(step.value))) {
      if (step.done) return step.value;
    }
  }

  #exportTranscripts(
    outs: Map<string, Out>,
    sessRows: Row[],
    runRows: Map<string, Row[]>,
    wsOfSession: (ws: unknown) => string,
    say: (ws: string, rec: Rec) => void,
  ): boolean {
    const byWs = new Map<string, Map<string, string | null>>();
    const unreadableDirsByWs = new Map<string, Set<string>>();
    const unreadablePathsByWs = new Map<string, Set<string>>();
    for (const ws of outs.keys()) {
      byWs.set(ws, new Map());
      unreadableDirsByWs.set(ws, new Set());
      unreadablePathsByWs.set(ws, new Set());
    }
    // The brains walked in each workspace: sessions of one workspace sharing a brain walk it once.
    const walkedBrains = new Map<string, Set<string>>();
    for (const sess of sessRows) {
      const ws = wsOfSession(sess.ws);
      const foundMap = byWs.get(ws);
      if (foundMap === undefined) continue;
      // A workspace whose transcripts are all exported this sweep is not looked at again until the next one.
      if (this.#transcriptWsDone.has(ws)) continue;
      const unreadableDirs = unreadableDirsByWs.get(ws)!;
      const unreadablePathsWs = unreadablePathsByWs.get(ws)!;
      const addUnreadableDir = (d: string) => {
        unreadableDirs.add(d);
      };
      const addUnreadablePath = (p: string) => {
        unreadablePathsWs.add(p);
      };
      const key = typeof sess.key === "string" ? sess.key : "";
      const sRuntime = typeof sess.runtime === "string" ? sess.runtime : "";
      const origRuntime = typeof sess.original_runtime === "string" ? sess.original_runtime : sRuntime;
      const sProfile = typeof sess.profile === "string" ? sess.profile : null;
      const sWorkspace = typeof sess.workspace === "string" ? sess.workspace : "";
      const sCwd = typeof sess.cwd === "string" && sess.cwd !== "" ? sess.cwd : null;
      const room = sCwd ?? (sWorkspace !== "" ? sWorkspace : null);
      const places: string[] = [];
      if (sCwd !== null && sCwd !== sWorkspace) places.push(sCwd);
      if (sWorkspace !== "") places.push(sWorkspace);
      const sources: { id: string; runtime: string; profile: string | null }[] = [];
      const seenIds = new Set<string>();
      for (const r of runRows.get(key) ?? []) {
        const id = typeof r.id === "string" ? r.id : "";
        if (id === "") continue;
        const rt = typeof r.runtime === "string" ? r.runtime : origRuntime;
        const prof = typeof r.profile === "string" ? r.profile : sProfile;
        sources.push({ id, runtime: rt, profile: prof });
        seenIds.add(id);
      }
      if (typeof sess.runtime_session_id === "string" && sess.runtime_session_id !== "" && !seenIds.has(sess.runtime_session_id)) {
        sources.push({ id: sess.runtime_session_id, runtime: sRuntime, profile: sProfile });
      }
      if (sources.length === 0) continue;
      const addPath = (p: string) => {
        if (isTranscriptPath(this.#o.dataDir, p) && !foundMap.has(p)) foundMap.set(p, room);
      };
      const validSources = sources
        .filter((r) => runtimeKind(r.runtime) !== null)
        .map((r) => ({ id: r.id, runtime: runtimeKind(r.runtime)!, profile: r.profile }));
      if (validSources.length > 0) {
        const found = this.#lookTranscriptSources(
          transcriptSourcesLooking(this.#o.dataDir, [], validSources, places, { anywhere: true }),
          addUnreadableDir,
        );
        for (const t of found.paths) {
          addPath(storage(t.path));
          if (t.runtime === "claude") {
            const id = t.path.slice(t.path.lastIndexOf(sep) + 1).replace(/\.jsonl$/, "");
            const sub = join(dirname(t.path), id);
            try {
              if (this.#lstatPath(sub).isDirectory()) this.#walkTranscriptDir(sub, addPath, addUnreadableDir, addUnreadablePath);
            } catch (e) {
              if (!isMissingError(e)) addUnreadableDir(sub);
            }
          }
        }
      }
      for (const r of sources) {
        if (r.runtime !== "agy" || r.profile === null || !ONE_SEGMENT.test(r.profile) || !ONE_SEGMENT.test(r.id)) continue;
        const cli = join(this.#o.dataDir, "homes", r.profile, "agy", ".gemini", "antigravity-cli");
        addPath(join(cli, "conversations", `${r.id}.db`));
        addPath(join(cli, "conversations", `${r.id}.db-wal`));
        addPath(join(cli, "annotations", `${r.id}.pbtxt`));
        const brain = join(cli, "brain", r.id);
        let walked = walkedBrains.get(ws);
        if (walked === undefined) walkedBrains.set(ws, (walked = new Set()));
        if (walked.has(brain)) continue;
        walked.add(brain);
        try {
          if (this.#lstatPath(brain).isDirectory()) this.#walkBrainDir(brain, brain, [], addPath, addUnreadableDir, addUnreadablePath);
        } catch (e) {
          if (!isMissingError(e)) addUnreadableDir(brain);
        }
      }
    }
    const chunkBytes = this.#chunkBytes;
    const maxFiles = this.#transcriptPassFiles;
    const maxBytes = this.#transcriptPassBytes;
    const maxDeletes = this.#transcriptPassDeletes;
    const chunksDir = join(this.#o.replica, "chunks");
    let doneFiles = 0;
    let doneBytes = 0;
    let doneDeletes = 0;
    let truncated = false;
    const parentUnreadableCache = new Map<string, boolean>();
    const ancestorLstatCache = new Map<string, "dir" | "other" | "err">();
    const byCodeUnits = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);
    for (const ws of [...byWs.keys()].sort(byCodeUnits)) {
      if (truncated) break;
      if (this.#transcriptWsDone.has(ws)) continue;
      const foundMap = byWs.get(ws)!;
      const unreadableDirs = unreadableDirsByWs.get(ws)!;
      const unreadablePaths = unreadablePathsByWs.get(ws)!;
      const paths = [...foundMap.keys()].sort(byCodeUnits);
      const existingByPath = new Map<string, { room: string | null; size: number; mtime: number }>();
      for (const row of this.#state.prepare("SELECT path, room, size, mtime FROM transcript_files WHERE ws = ?").all(ws) as { path: string; room: string | null; size: number; mtime: number }[]) {
        existingByPath.set(row.path, { room: row.room, size: row.size, mtime: row.mtime });
      }
      const active = new Set<string>();
      let wsTruncated = false;
      const scanDone = this.#transcriptScanDone.has(ws);
      const cursor = this.#transcriptCursor.get(ws);
      for (const path of paths) {
        // A path is found whether or not it is there (a `.db-wal`, an annotation): one gone is not kept.
        let st;
        try {
          st = this.#lstatPath(path);
        } catch (e) {
          if (!isMissingError(e)) unreadablePaths.add(path);
          continue;
        }
        if (!st.isFile()) continue;
        // Gone through already in this sweep: kept as found, not read again until the next sweep.
        if (scanDone || (cursor !== undefined && path < cursor)) {
          active.add(path);
          continue;
        }
        const room = foundMap.get(path) ?? null;
        const size = Number(st.size);
        const mtime = Number(st.mtimeNs / 1_000_000n);
        const mode = Number(st.mode) & 0o777;
        const existing = existingByPath.get(path);
        if (existing !== undefined && existing.size === size && existing.mtime === mtime && existing.room === room) {
          active.add(path);
          continue;
        }
        if (doneFiles > 0 && (doneFiles >= maxFiles || doneBytes >= maxBytes)) {
          truncated = true;
          wsTruncated = true;
          this.#transcriptCursor.set(ws, path);
          break;
        }
        const chunks: string[] = [];
        let readBytes = 0;
        let readFailed = false;
        let fd: number | null = null;
        try {
          fd = openSync(path, "r"); // sync: in the export's own thread (worker.ts)
          const buf = Buffer.allocUnsafe(Math.min(chunkBytes, Math.max(size, 1)));
          for (let offset = 0; offset < size; ) {
            const want = Math.min(chunkBytes, size - offset);
            const n = this.#o.testFaults?.readShort?.(path, offset) ? 0 : readSync(fd, buf, 0, want, offset); // sync: in the export's own thread (worker.ts)
            if (n <= 0) {
              readFailed = true;
              break;
            }
            const plain = buf.subarray(0, n);
            const plainHash = createHash("sha256").update(plain).digest("hex");
            const known = this.#state.prepare("SELECT chunk_hash FROM transcript_chunks WHERE plain_hash = ?").get(plainHash) as { chunk_hash: string } | undefined;
            let ch: string;
            if (known !== undefined && existsSync(join(chunksDir, known.chunk_hash))) { // sync: in the export's own thread (worker.ts)
              ch = known.chunk_hash;
            } else {
              const zst = zstdCompressSync(plain); // sync: in the export's own thread (worker.ts)
              ch = createHash("sha256").update(zst).digest("hex");
              const chunkPath = join(chunksDir, ch);
              if (!existsSync(chunkPath)) writeWhole(chunkPath, zst, false); // sync: in the export's own thread (worker.ts)
              this.#state.prepare("INSERT OR REPLACE INTO transcript_chunks (plain_hash, chunk_hash, comp_size) VALUES (?, ?, ?)").run(plainHash, ch, zst.length);
            }
            chunks.push(ch);
            offset += n;
            readBytes = offset;
          }
        } catch {
          readFailed = true;
        } finally {
          if (fd !== null) closeSync(fd); // sync: in the export's own thread (worker.ts)
        }
        if (readFailed || readBytes !== size) {
          unreadablePaths.add(path);
          continue;
        }
        active.add(path);
        this.#state.prepare("INSERT OR REPLACE INTO transcript_files (ws, path, room, size, mtime, mode, chunks_json) VALUES (?, ?, ?, ?, ?, ?, ?)").run(ws, path, room, size, mtime, mode, JSON.stringify(chunks));
        this.#tfCache.delete(ws);
        this.#manifestCache.delete(ws);
        say(ws, { tr: path, room, size, mtime, mode, chunks });
        doneFiles++;
        doneBytes += readBytes;
      }
      const oldPaths = [...existingByPath.keys()].sort(byCodeUnits);
      if (wsTruncated) {
        // The derived caches no longer exported go whatever else is found: by their path alone, so a sweep that keeps
        // being cut short still lets them go. That path says it, not the disk: no readability check is needed.
        let deletedInWs = false;
        for (const oldPath of oldPaths) {
          if (active.has(oldPath) || !isPrunedBrainPath(this.#o.dataDir, oldPath)) continue;
          if (doneDeletes >= maxDeletes) break;
          this.#state.prepare("DELETE FROM transcript_files WHERE ws = ? AND path = ?").run(ws, oldPath);
          deletedInWs = true;
          say(ws, { tr_del: oldPath });
          doneDeletes++;
        }
        if (deletedInWs) {
          this.#tfCache.delete(ws);
          this.#manifestCache.delete(ws);
        }
      } else {
        this.#transcriptCursor.delete(ws);
        this.#transcriptScanDone.add(ws);
        let deletedInWs = false;
        let deletesCut = false;
        for (const oldPath of oldPaths) {
          if (active.has(oldPath) || unreadablePaths.has(oldPath) || pathUnderAnyDir(oldPath, unreadableDirs)) continue;
          if (!isPrunedBrainPath(this.#o.dataDir, oldPath)) {
            const dataRoot = resolve(this.#o.dataDir);
            const rel = relative(dataRoot, resolve(oldPath));
            if (rel !== "" && !rel.startsWith("..")) {
              const parts = rel.split(sep);
              const ancestors: string[] = [];
              let cur = dataRoot;
              let keep = false;
              let allRealDirs = true;
              for (let i = 0; i + 1 < parts.length; i++) {
                cur = join(cur, parts[i]!);
                let kind = ancestorLstatCache.get(cur);
                if (kind === undefined) {
                  try {
                    const st = this.#lstatPath(cur);
                    kind = st.isDirectory() ? "dir" : "other";
                  } catch (e) {
                    kind = isMissingError(e) ? "other" : "err";
                  }
                  ancestorLstatCache.set(cur, kind);
                }
                if (kind === "err") {
                  keep = true;
                  break;
                }
                if (kind !== "dir") {
                  allRealDirs = false;
                  break;
                }
                ancestors.push(cur);
              }
              if (keep) continue;
              if (allRealDirs) {
                let existsOnDisk = false;
                try {
                  this.#lstatPath(oldPath);
                  existsOnDisk = true;
                } catch (e) {
                  if (!isMissingError(e)) continue;
                }
                if (existsOnDisk) {
                  const checkDir = (d: string): boolean => {
                    let bad = parentUnreadableCache.get(d);
                    if (bad === undefined) {
                      bad = this.#dirUnreadableChecked(d);
                      parentUnreadableCache.set(d, bad);
                    }
                    return bad;
                  };
                  let ancestorUnreadable = checkDir(dataRoot);
                  if (!ancestorUnreadable) {
                    for (const a of ancestors) {
                      if (checkDir(a)) {
                        ancestorUnreadable = true;
                        break;
                      }
                    }
                  }
                  if (ancestorUnreadable) continue;
                }
              }
            }
          }
          if (doneDeletes >= maxDeletes) {
            truncated = true;
            deletesCut = true;
            break;
          }
          this.#state.prepare("DELETE FROM transcript_files WHERE ws = ? AND path = ?").run(ws, oldPath);
          deletedInWs = true;
          say(ws, { tr_del: oldPath });
          doneDeletes++;
        }
        if (deletedInWs) {
          this.#tfCache.delete(ws);
          this.#manifestCache.delete(ws);
        }
        if (!deletesCut) this.#transcriptWsDone.add(ws);
      }
    }
    if (!truncated) this.#endSweep();
    return truncated;
  }

  #transcriptFilesMap(ws: string): Record<string, number> {
    const rows = this.#state.prepare("SELECT chunks_json FROM transcript_files WHERE ws = ?").all(ws) as { chunks_json: string }[];
    if (rows.length === 0) return {};
    const chunkSizes = new Map<string, number>();
    for (const r of this.#state.prepare("SELECT chunk_hash, comp_size FROM transcript_chunks").all() as { chunk_hash: string; comp_size: number }[]) {
      if (!chunkSizes.has(r.chunk_hash)) chunkSizes.set(r.chunk_hash, num(r.comp_size));
    }
    const sizes = new Map<string, number>();
    for (const row of rows) {
      const chunks = JSON.parse(row.chunks_json) as string[];
      for (const ch of chunks) {
        if (sizes.has(ch)) continue;
        let sz = chunkSizes.get(ch);
        if (sz === undefined) {
          sz = 0;
          try {
            sz = statSync(join(this.#o.replica, "chunks", ch)).size; // sync: in the export's own thread (worker.ts)
          } catch {}
        }
        sizes.set(ch, sz);
      }
    }
    const out: Record<string, number> = {};
    for (const k of [...sizes.keys()].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0))) out[k] = sizes.get(k)!;
    return out;
  }

  #gcTranscriptChunks(): void {
    const now = this.#o.now();
    const graceMs = this.#chunkGcGraceMs;
    const chunksDir = join(this.#o.replica, "chunks");
    const live = new Set<string>();
    for (const row of this.#state.prepare("SELECT chunks_json FROM transcript_files").all() as { chunks_json: string }[]) {
      for (const ch of JSON.parse(row.chunks_json) as string[]) live.add(ch);
    }
    const pending = new Map<string, number>();
    for (const row of this.#state.prepare("SELECT chunk_hash, gone_at FROM transcript_chunk_gc").all() as { chunk_hash: string; gone_at: number }[]) {
      pending.set(row.chunk_hash, num(row.gone_at));
    }
    for (const ch of pending.keys()) {
      if (live.has(ch)) {
        this.#state.prepare("DELETE FROM transcript_chunk_gc WHERE chunk_hash = ?").run(ch);
      }
    }
    const keptOnDisk = new Set<string>();
    try {
      for (const name of readdirSync(chunksDir)) { // sync: in the export's own thread (worker.ts)
        if (live.has(name)) continue;
        if (graceMs <= 0) {
          rmSync(join(chunksDir, name), { force: true }); // sync: in the export's own thread (worker.ts)
          if (pending.has(name)) {
            this.#state.prepare("DELETE FROM transcript_chunk_gc WHERE chunk_hash = ?").run(name);
          }
          continue;
        }
        const goneAt = pending.get(name);
        if (goneAt === undefined) {
          this.#state.prepare("INSERT OR REPLACE INTO transcript_chunk_gc (chunk_hash, gone_at) VALUES (?, ?)").run(name, now);
          keptOnDisk.add(name);
        } else if (now - goneAt >= graceMs) {
          rmSync(join(chunksDir, name), { force: true }); // sync: in the export's own thread (worker.ts)
          this.#state.prepare("DELETE FROM transcript_chunk_gc WHERE chunk_hash = ?").run(name);
        } else {
          keptOnDisk.add(name);
        }
      }
    } catch {}
    for (const ch of pending.keys()) {
      if (!live.has(ch) && !keptOnDisk.has(ch)) {
        this.#state.prepare("DELETE FROM transcript_chunk_gc WHERE chunk_hash = ?").run(ch);
      }
    }
    for (const row of this.#state.prepare("SELECT plain_hash, chunk_hash FROM transcript_chunks").all() as { plain_hash: string; chunk_hash: string }[]) {
      if (!live.has(row.chunk_hash) && !keptOnDisk.has(row.chunk_hash)) {
        this.#state.prepare("DELETE FROM transcript_chunks WHERE plain_hash = ?").run(row.plain_hash);
      }
    }
  }

  #compactHead(ws: string, head: Head): Head {
    const tf = head.transcriptFiles;
    let hasTf = false;
    if (tf !== undefined) {
      for (const _ in tf) {
        hasTf = true;
        break;
      }
    }
    if (!hasTf || tf === undefined) {
      this.#manifestCache.delete(ws);
      const { transcriptManifest: _, ...rest } = head;
      return rest;
    }
    const manifestsDir = join(this.#o.replica, "manifests");
    const cached = this.#manifestCache.get(ws);
    let rootHash: string;
    if (cached !== undefined && existsSync(join(manifestsDir, cached.rootHash))) { // sync: in the export's own thread (worker.ts)
      rootHash = cached.rootHash;
    } else {
      const enc = encodeTranscriptManifest(tf);
      const leafHashes: string[] = [];
      for (const [lh, { bytes }] of enc.leaves) {
        leafHashes.push(lh);
        const lp = join(manifestsDir, lh);
        if (!existsSync(lp)) writeWhole(lp, bytes, true); // sync: in the export's own thread (worker.ts)
      }
      const rp = join(manifestsDir, enc.rootHash);
      if (!existsSync(rp)) writeWhole(rp, enc.rootBytes, true); // sync: in the export's own thread (worker.ts)
      this.#manifestCache.set(ws, { rootHash: enc.rootHash, leafHashes });
      rootHash = enc.rootHash;
    }
    const { transcriptFiles: _, ...rest } = head;
    return { ...rest, transcriptManifest: rootHash };
  }

  #gcManifests(outs: Map<string, Out>): void {
    const now = this.#o.now();
    const manifestsDir = join(this.#o.replica, "manifests");
    const live = new Set<string>();
    for (const [ws, out] of outs) {
      const cached = this.#manifestCache.get(ws);
      if (cached !== undefined) {
        live.add(cached.rootHash);
        for (const lh of cached.leafHashes) live.add(lh);
      } else if (out.head.transcriptFiles !== undefined) {
        let hasTf = false;
        for (const _ in out.head.transcriptFiles) {
          hasTf = true;
          break;
        }
        if (hasTf) {
          const enc = encodeTranscriptManifest(out.head.transcriptFiles);
          live.add(enc.rootHash);
          for (const lh of enc.leaves.keys()) live.add(lh);
        }
      }
    }
    for (const h of live) this.#manifestSupersededAt.delete(h);
    for (const prev of this.#manifestLive) {
      if (!live.has(prev) && !this.#manifestSupersededAt.has(prev)) {
        this.#manifestSupersededAt.set(prev, now);
      }
    }
    this.#manifestLive = live;
    let names: string[];
    try {
      const faultErr = this.#o.testFaults?.readdirError?.(manifestsDir);
      if (faultErr) throw faultErr;
      names = readdirSync(manifestsDir); // sync: in the export's own thread (worker.ts)
    } catch {
      return;
    }
    const onDisk = new Set<string>();
    for (const name of names) {
      onDisk.add(name);
      if (live.has(name)) continue;
      const supersededAt = this.#manifestSupersededAt.get(name);
      if (supersededAt === undefined) {
        // First time this process observes an unreferenced file on disk (e.g. after restart):
        // record `now` and grant a full 10-minute grace period before reclaiming.
        this.#manifestSupersededAt.set(name, now);
      } else if (now - supersededAt >= MANIFEST_GC_GRACE_MS) {
        const p = join(manifestsDir, name);
        try {
          rmSync(p, { force: true }); // sync: in the export's own thread (worker.ts)
        } catch {}
        this.#manifestSupersededAt.delete(name);
      }
    }
    for (const k of [...this.#manifestSupersededAt.keys()]) {
      if (!onDisk.has(k)) this.#manifestSupersededAt.delete(k);
    }
  }

  /// The batches of a generation of this station's, by name (what is in its log directory).
  static batchesIn(dir: string): string[] {
    try {
      return readdirSync(join(dir, "log")).filter((b) => BATCH.test(b)).sort(); // sync: in the export's own thread (worker.ts)
    } catch {
      return [];
    }
  }
}

/// The runs a head remembers (one a start of the exporter).
export const RUNS_KEPT = 512;

function keyColumns(table: string): readonly string[] {
  const cols = TABLES[table];
  if (cols === undefined) throw new Error(`no such table in a copy: ${table}`);
  return cols;
}
