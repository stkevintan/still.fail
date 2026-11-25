// One signed-in account's database: the tables of db/schema.ts, read by indexed queries, written by
// one writer. Everything here is synchronous (the host's SQLite is), on the core's one thread.
//
// The writer: every change opens the burst's transaction (BEGIN IMMEDIATE) if none is open and runs in it, so what
// is read next sees it; the database's write fiber commits the burst once the work at hand has run (a burst of
// events is one transaction), then tells what changed in it: the topics whose values changed, the chat rows before
// and after, the logs that grew. A write that may wait (`soon`: a station's event cursor, a transcript nothing shows)
// is run at once too, so every read sees it and it is in the burst of what it came with, but does not ask for the
// commit by itself: its burst is committed with the next write that may not wait, or as its wait ends. A row that did
// not change is not written. When the disk or the browser's quota is full, the burst is rolled back and what this
// device did itself (the outbox, chats asked for, drafts, …) is written again on its own; the rest comes again from
// the stations.
//
// Reads: a row asked for by key is kept (by identity, frozen) until it is written; a station's list a view shows (its
// chats, sessions, threads, jobs) is loaded by one indexed query the first time it is asked for and from then on kept
// current by the writer, row by row, until no topic reads it. Nothing is loaded at start.
import { Deferred, Effect, type Fiber, Queue } from "effect";
import type { Said } from "../elsewhere.ts";
import type { Sql, SqlRow, SqlValue } from "../host.ts";
import { SqlError, sqlError } from "../host.ts";
import { topicKey, type Topic } from "../protocol.ts";
import type { Runner } from "../runtime.ts";
import { timed } from "../spent.ts";
import { work } from "../work.ts";
import type { ChatRead } from "./chat-reads.ts";
import type { SharedSidecar } from "../chat-row.ts";
import { ChatsStore, type SharedMarkKind, type SharedMarksSnapshot, type SharedMeta } from "./chats.ts";
import {
  Cache,
  type Changes,
  type ChatFound,
  Collection,
  type DbEnv,
  type Derive,
  type HeadRow,
  type J,
  K,
  LIST_OF,
  type ListKind,
  type ListRow,
  type LogTable,
  MD_SHOWN_EVERY,
  type MdPut,
  type MovedTo,
  PRECIOUS,
  type RowChange,
  TOPIC_OF,
  foundOf,
  frozen,
  idText,
  membersOf,
  parse,
  placesFor,
} from "./collection.ts";
import { DocsStore } from "./docs.ts";
import { JobsStore } from "./jobs.ts";
import { KEPT_ALL, KeptValues } from "./kept.ts";
import { KeptCacheStore } from "./kept-cache.ts";
import { LogsStore } from "./logs.ts";
import { type ChatColumnsMade, ensureChatColumns, ensureLetters, giveBackRoomStep, migrate, versionOf } from "./schema.ts";
import { SessionsThreadsStore, counted, placeTurn, sameTurns } from "./sessions-threads.ts";
import { SlackSaidStore } from "./slack-said.ts";

export {
  Collection,
  LIST_OF,
  MD_SHOWN_EVERY,
  counted,
  foundOf,
  frozen,
  idText,
  membersOf,
  placeTurn,
  placesFor,
  sameTurns,
  type Changes,
  type ChatFound,
  type Derive,
  type HeadRow,
  type ListKind,
  type ListRow,
  type LogTable,
  type MdPut,
  type MovedTo,
  type RowChange,
};

export class AccountDb {
  readonly sub: string;
  readonly name: string;
  readonly sql: Sql;
  /// Written by a newer core: read, never written.
  readonly readOnly: boolean;
  /// Its version as found (before migrating): 0 for a database made now.
  readonly found: number;
  /// What is made of a record and kept beside it (db/kept.ts): a chat list's rows, the overviews' verdicts, the
  /// accounts' rows.
  readonly kept: KeptValues;
  readonly #runner: Runner;
  #inTx = false;
  /// A write of this database was lost since it was opened (no transaction could begin for it, or its burst was
  /// rolled back): what the stations' events changed may not be kept, so where the device is in them is written no
  /// more (`putCursor`). The core that opens it next takes up from the last one written, and is told those events again.
  #lost = false;
  /// The burst under way failed and no transaction could be begun again for the rest of it: nothing more of it is
  /// run until one can, so that no statement of it is committed alone.
  #noTx = false;
  /// The burst under way holds only writes that may wait (`soon`): no commit is asked for yet.
  #waits = false;
  /// How long the write being run may wait for its commit (`soon`); null: it is committed as the work at hand has run.
  #soonMs: number | null = null;
  /// The waits whose end is still to come, by their length: one timer each, whatever the bursts that pass.
  readonly #waitEnds = new Set<number>();
  /// What failed in this burst: it is rolled back.
  #failed: SqlError | null = null;
  #changes: Changes = { topics: new Map(), chats: new Map(), readChats: new Map(), logs: new Map(), firstChats: new Set(), freed: [], came: [] };
  /// The statements of this burst that are what the device did itself, to be written again if the burst fails.
  #precious: [string, readonly SqlValue[]][] = [];
  /// What could not be written even so, written again with the next burst.
  #unwritten: [string, readonly SqlValue[]][] = [];
  readonly #bursts: Queue.Queue<void>;
  readonly #writer: Fiber.Fiber<never, never>;
  #waiting: Deferred.Deferred<void>[] = [];
  readonly #cache = new Cache(4096);
  readonly #lists = new Map<string, Collection>();
  readonly #docs: DocsStore;
  readonly #chats: ChatsStore;
  readonly #sessions: SessionsThreadsStore;
  readonly #jobs: JobsStore;
  readonly #slack: SlackSaidStore;
  readonly #logs: LogsStore;
  readonly #keptCache: KeptCacheStore;
  #closed = false;
  /// Told after each burst is written, with what it changed.
  onCommit: (changes: Changes) => void = () => {};
  /// Told when a burst could not be written for want of room (true), and once one could again (false).
  onFull: (full: boolean, error: string | null) => void = () => {};
  #full = false;
  /// What deriving the chat columns again took as this database was opened (schema.ts ensureChatColumns).
  chatColumnsMade: ChatColumnsMade | null = null;

  constructor(sub: string, name: string, sql: Sql, runner: Runner, derive: Derive) {
    this.sub = sub;
    this.name = name;
    this.sql = sql;
    this.#runner = runner;
    this.found = versionOf(sql);
    this.kept = new KeptValues({
      sql,
      write: (fn) => this.#write(fn),
      run: (q, params) => void this.#run(q, params),
      cache: this.#cache,
      held: (source, owner) => {
        const v = this.#cache.get(source === "chat" ? K("chat", owner[0], 0, owner[1]) : source === "station" ? K("st", owner[0], "overview") : K("profiled", owner[0]));
        return v === null ? undefined : v;
      },
      record: (source, owner) => (source === "chat" ? this.chat(owner[0], owner[1]) : source === "station" ? this.stationDoc(owner[0], "overview") : this.overviewProfiled(owner[0])),
    });
    this.readOnly = !migrate(sql);

    const env: DbEnv = {
      sql,
      readOnly: this.readOnly,
      kept: this.kept,
      cache: this.#cache,
      derive,
      full: () => this.#full,
      failed: () => this.#failed !== null,
      write: (fn) => this.#write(fn),
      run: (q, params) => this.#run(q, params),
      tell: (topic) => this.#tell(topic),
      tellChat: (station, id, before, after) => this.#tellChat(station, id, before, after),
      tellChatRead: (station, archived, id, before, after, ordBefore, ordAfter) => this.#tellChatRead(station, archived, id, before, after, ordBefore, ordAfter),
      tellLogChange: (key, entry) => void this.#changes.logs.set(key, entry),
      tellFreed: (station, session) => void this.#changes.freed.push([station, session]),
      tellCame: (station, session) => void this.#changes.came.push([station, session]),
      listed: (station, list) => this.listed(station, list),
      markListed: (station, list, confirmed, changed) => this.#markListed(station, list, confirmed, changed),
      bumpRev: (station, list) => this.#bumpRev(station, list),
      loadedList: (station, kind) => this.#loadedList(station, kind),
      byKey: (found, all, byKey, keyOf, make) => this.#byKey(found, all, byKey, keyOf, make),
      cached: (key, json, make, read) => this.#cached(key, json, make, read),
    };

    this.#docs = new DocsStore(env);
    this.#slack = new SlackSaidStore(env);
    this.#logs = new LogsStore(env, this.#slack);
    this.#keptCache = new KeptCacheStore(env, this.#logs);
    this.#jobs = new JobsStore(env);
    this.#chats = new ChatsStore(env, (station, key) => this.#sessions.summary(station, key));
    this.#sessions = new SessionsThreadsStore(env, {
      summaryCame: (station, key, summary) => this.#chats.summaryCame(station, key, summary),
      readRows: (station, thread, n) => this.#chats.readRows(station, thread, n),
      tellLog: (table, station, id, put) => this.#logs.tellLog(table, station, id, put),
      forgetEntries: (station, thread) => this.#logs.forgetEntries(station, thread),
    });

    if (!this.readOnly) {
      try {
        this.sql.exec("PRAGMA journal_size_limit = 8388608");
      } catch {
        // Ignore on custom/mock Sql adapters that do not implement journal_size_limit.
      }
      const was = this.sql.all("SELECT value FROM meta WHERE key = 'account'")[0]?.[0];
      if (was === undefined) this.sql.run("INSERT INTO meta (key, value) VALUES ('account', ?)", [sub]);
      ensureLetters(sql);
      this.#chats.openMoved();
      this.#chats.openSharedSidecar();
      this.#logs.openSaid(false);
      this.#docs.openParts(false);
      this.#sessions.openDetail(false);
      // (after the tables they are kept beside, station_part's: ensureOverviewParts)
      this.kept.open(KEPT_ALL);
      try {
        this.chatColumnsMade = ensureChatColumns(sql, (agents) => ({ state: derive.state({ agents }), watched: derive.watched({ agents }) }));
      } catch (e) {
        // No room to derive them: the rows another core wrote are read by the columns they have, this time.
        console.error("still.fail core: a chat's columns could not be derived:", e instanceof Error ? e.message : String(e));
      }
      this.#slack.open();
      this.#logs.openEvicted();
      this.#keptCache.openLogBytes();
      this.#keptCache.openMediaTables();
    } else {
      this.#logs.openSaid(true);
      this.#docs.openParts(true);
      this.#sessions.openDetail(true);
    }
    this.#bursts = Effect.runSync(Queue.unbounded<void>());
    // The one write fiber: a burst is committed once what started it has run.
    this.#writer = runner.fork(Effect.forever(Effect.andThen(Queue.take(this.#bursts), Effect.andThen(Effect.yieldNow, Effect.sync(() => this.#commit())))));
  }

  // ── writing ──

  /// Runs `fn` in the burst's transaction (opened now if none is). A database only read does nothing.
  #write(fn: () => void): void {
    if (this.readOnly || this.#closed) return;
    try {
      const soon = this.#soonMs;
      if (!this.#inTx) {
        // (a burst is one only once its transaction began: where none can, nothing is left open, this write is not
        // made, as ever, and the next one tries again)
        this.sql.exec("BEGIN IMMEDIATE");
        this.#inTx = true;
        if (soon === null) Queue.offerUnsafe(this.#bursts, undefined);
        else {
          this.#waits = true;
          this.#waitEnd(soon);
        }
      } else {
        if (this.#noTx) {
          this.sql.exec("BEGIN IMMEDIATE");
          this.#noTx = false;
        }
        if (soon === null) this.#hurry();
        else if (this.#waits) this.#waitEnd(soon);
      }
      fn();
    } catch (e) {
      if (!(e instanceof SqlError)) throw e;
      this.#lost = true;
      if (!this.#inTx) return this.#said(e);
      // SQLite could not write (no room, the file gone): the burst is rolled back as it is committed, and said.
      this.#failed ??= e;
      // SQLite may have ended the transaction itself (a full disk does): what the burst still runs is run in one
      // begun again, rolled back with it, so that nothing of a burst that failed (a cursor past what it lost) is
      // committed alone. Where none can be begun, nothing more of it is run until one can.
      try {
        this.sql.exec("ROLLBACK");
      } catch {
        // Ended already.
      }
      try {
        this.sql.exec("BEGIN IMMEDIATE");
        this.#noTx = false;
      } catch {
        this.#noTx = true;
      }
      this.#hurry();
    }
  }

  /// What SQLite could not do, said: a full disk as the database's note (until a burst is written again), else logged.
  #said(error: SqlError): void {
    if (error.kind === "full" && !this.#full) {
      this.#full = true;
      this.onFull(true, error.message);
    } else if (error.kind !== "full") console.error("still.fail core: a write failed:", error.message);
  }

  /// Runs `fn`, whose writes may wait `ms` for their commit: they are in the burst under way, or open one that is
  /// committed with the next write that may not wait, or after `ms` (one commit for a burst of them).
  soon(ms: number, fn: () => void): void {
    const was = this.#soonMs;
    this.#soonMs = ms;
    try {
      fn();
    } finally {
      this.#soonMs = was;
    }
  }

  /// A burst that waits is committed as the work at hand has run, as any other.
  #hurry(): void {
    if (!this.#inTx || !this.#waits) return;
    this.#waits = false;
    Queue.offerUnsafe(this.#bursts, undefined);
  }

  #waitEnd(ms: number): void {
    if (this.#waitEnds.has(ms)) return;
    this.#waitEnds.add(ms);
    this.#runner.fork(
      Effect.andThen(
        Effect.sleep(ms), // timer: debounce a burst of writes that may wait into one commit
        Effect.sync(() => {
          this.#waitEnds.delete(ms);
          this.#hurry();
        }),
      ),
    );
  }

  #run(sql: string, params: readonly SqlValue[]): number {
    // (a write that may wait is not what the device did itself: a station's cursor written again alone, its burst
    // rolled back, would say the events that burst lost were heard)
    if (this.#soonMs === null && PRECIOUS.test(sql)) this.#precious.push([sql, params]);
    return this.sql.run(sql, params);
  }

  /// The writer's turn for a burst that asked for its commit. One that waits asked for none: what is in the queue
  /// then is of a burst committed before its turn (`commitNow`, `close`), and the wait's end or the next write asks.
  #commit(): void {
    if (this.#inTx && this.#waits) return;
    this.#commitTimed();
  }

  #commitTimed(): void {
    timed("db.commit", () => this.#commitNow());
  }

  #commitNow(): void {
    if (!this.#inTx) return this.#settled();
    const changes = this.#changes;
    const precious = this.#precious;
    this.#changes = { topics: new Map(), chats: new Map(), readChats: new Map(), logs: new Map(), firstChats: new Set(), freed: [], came: [] };
    this.#precious = [];
    this.#inTx = false;
    this.#waits = false;
    this.#noTx = false;
    const failed = this.#failed;
    this.#failed = null;
    try {
      if (failed) throw failed;
      // What could not be written before goes first.
      if (this.#unwritten.length > 0) {
        for (const [sql, params] of this.#unwritten) this.sql.run(sql, params);
      }
      this.sql.exec("COMMIT");
      this.#unwritten = [];
      if (this.#full) {
        this.#full = false;
        this.onFull(false, null);
      }
    } catch (e) {
      const error = sqlError(e);
      this.#lost = true;
      try {
        this.sql.exec("ROLLBACK");
      } catch {
        // Rolled back already.
      }
      // A row change tells noticing what was committed. The retry below only keeps this device's own tables, not
      // the station's chat rows, so none of the rolled-back rows or first-list marker can be announced.
      changes.chats.clear();
      changes.firstChats.clear();
      // What was read is not what is kept any more.
      this.#cache.clear();
      this.kept.forget();
      this.#logs.onRollback();
      this.#lists.clear();
      this.#chats.onRollback();
      this.#slack.onRollback();
      this.#keptCache.onRollback();
      const again = [...this.#unwritten, ...precious];
      this.#unwritten = [];
      if (again.length > 0) {
        try {
          this.sql.exec("BEGIN IMMEDIATE");
          for (const [sql, params] of again) this.sql.run(sql, params);
          this.sql.exec("COMMIT");
        } catch {
          try {
            this.sql.exec("ROLLBACK");
          } catch {
            // Rolled back already.
          }
          this.#unwritten = again;
        }
      }
      this.#said(error);
    }
    this.onCommit(changes);
    this.#settled();
  }

  #settled(): void {
    const waiting = this.#waiting;
    this.#waiting = [];
    for (const d of waiting) Deferred.doneUnsafe(d, Effect.void);
  }

  /// Resolves once what was written so far is committed.
  get written(): Effect.Effect<void> {
    return Effect.suspend(() => {
      if (!this.#inTx) return Effect.void;
      this.#hurry();
      return Effect.flatMap(Deferred.make<void>(), (d) => {
        this.#waiting.push(d);
        return Deferred.await(d);
      });
    });
  }

  /// Whether a write is waiting for room.
  get full(): boolean {
    return this.#full;
  }

  #tell(topic: Topic): void {
    this.#changes.topics.set(topicKey(topic), topic);
  }

  #tellChat(station: string, id: string, before: J | undefined, after: J | undefined): void {
    let m = this.#changes.chats.get(station);
    if (!m) {
      m = new Map();
      this.#changes.chats.set(station, m);
    }
    const was = m.get(id);
    m.set(id, { id, before: was ? was.before : before, after });
  }

  #tellChatRead(station: string, archived: number, id: string, before: J | undefined, after: J | undefined, ordBefore: number | undefined, ordAfter: number | undefined): void {
    let rows = this.#changes.readChats.get(station);
    if (!rows) {
      rows = new Map();
      this.#changes.readChats.set(station, rows);
    }
    const key = K(String(archived), id);
    const was = rows.get(key);
    if (was) {
      if (was.after !== undefined) (was.between ??= []).push(was.after);
      was.after = after;
      was.ordAfter = ordAfter;
    } else rows.set(key, { id, archived: archived !== 0, before, after, ordBefore, ordAfter });
  }

  /// The numbers put in a log since change `since` (`rev` of an answer before; 0: none), and the change it is at now;
  /// `put` null where that is not known (it changed otherwise, or long ago): all of it is to be read again.
  logPutSince(table: LogTable, station: string, id: string, since: number): { rev: number; put: number[] | null } {
    return this.#logs.logPutSince(table, station, id, since);
  }

  /// Free pages waiting to be returned to the OS (`PRAGMA freelist_count`).
  freelistPages(): number {
    if (this.readOnly || this.#closed) return 0;
    try {
      return Number(this.sql.all("PRAGMA freelist_count")[0]?.[0] ?? 0);
    } catch {
      return 0;
    }
  }

  /// Releases idle SQLite page-cache memory (best effort; called when the UI leaves view).
  shrinkMemory(): void {
    if (this.#closed || this.#inTx) return;
    try {
      this.sql.exec("PRAGMA shrink_memory");
    } catch {
      // Ignore on custom/mock Sql adapters that do not implement shrink_memory.
    }
  }

  /// One step of giving unused pages back to the device (schema.ts `giveBackRoomStep`). Returns true while more steps
  /// remain, including when a write transaction is open so the writer commits before vacuum runs.
  giveBackRoomStep(pages?: number, minFree?: number): boolean {
    if (this.readOnly || this.#closed) return false;
    if (this.#inTx) {
      this.#hurry();
      return true;
    }
    try {
      return giveBackRoomStep(this.sql, pages, minFree);
    } catch {
      return false;
    }
  }

  /// The burst under way committed now, not as its writer next runs: what a core closing wrote (Data.closing).
  commitNow(): void {
    if (this.#inTx && !this.#closed) this.#commitTimed();
  }

  close(): void {
    if (this.#closed) return;
    if (this.#inTx) this.#commitTimed();
    this.#closed = true;
    this.#runner.interrupt(this.#writer as Fiber.Fiber<unknown, unknown>);
    this.sql.close();
  }

  // ── documents: one JSON value by key ──

  accountDoc(name: string): J { return this.#docs.accountDoc(name); }
  putAccountDoc(name: string, value: J, confirmed: number | null, topic: Topic | null): void { this.#docs.putAccountDoc(name, value, confirmed, topic); }
  dropAccountDoc(name: string, topic: Topic | null): void { this.#docs.dropAccountDoc(name, topic); }
  workspace(id: string): J { return this.#docs.workspace(id); }
  putWorkspace(id: string, value: J, confirmed: number | null): void { this.#docs.putWorkspace(id, value, confirmed); }
  dropWorkspace(id: string): void { this.#docs.dropWorkspace(id); }
  workspaceIds(): string[] { return this.#docs.workspaceIds(); }
  stationDoc(station: string, kind: string): J { return this.#docs.stationDoc(station, kind); }
  putStationDoc(station: string, kind: string, value: J, confirmed: number | null, topic: Topic | null): void { this.#docs.putStationDoc(station, kind, value, confirmed, topic); }
  dropStationDoc(station: string, kind: string, topic: Topic | null): void { this.#docs.dropStationDoc(station, kind, topic); }
  overviewPart(station: string): J { return this.#docs.overviewPart(station); }
  overviewRow(station: string): J { return this.#docs.overviewRow(station); }
  overviewChat(station: string): J { return this.#docs.overviewChat(station); }
  overviewFormerly(station: string): J { return this.#docs.overviewFormerly(station); }
  overviewSoftware(station: string): J { return this.#docs.overviewSoftware(station); }
  overviewProfiled(station: string): J { return this.#docs.overviewProfiled(station); }
  overviewConnects(station: string): J { return this.#docs.overviewConnects(station); }
  overviewSettings(station: string): J { return this.#docs.overviewSettings(station); }
  overviewProfile(station: string, id: string): J { return this.#docs.overviewProfile(station, id); }
  overviewHeld(station: string): boolean { return this.#docs.overviewHeld(station); }
  boundStationDocs(station: string, prefix: string, most: number): void { this.#docs.boundStationDocs(station, prefix, most); }
  slackApp(station: string, connect: string): J { return this.#docs.slackApp(station, connect); }
  putSlackApp(station: string, connect: string, value: J, confirmed: number | null): void { this.#docs.putSlackApp(station, connect, value, confirmed); }
  draft(station: string, chat: string): J { return this.#docs.draft(station, chat); }
  putDraft(station: string, chat: string, value: J | undefined): void { this.#docs.putDraft(station, chat, value); }
  workspacePref(workspace: string, key: string): J { return this.#docs.workspacePref(workspace, key); }
  putWorkspacePref(workspace: string, key: string, value: J | undefined, topic: Topic | null = null): void { this.#docs.putWorkspacePref(workspace, key, value, topic); }
  /// Where the device is in a station's events, kept as a workspace's value: its commit may wait up to `ms` (`soon`),
  /// and it is not written once a write of this database was lost (`#lost`).
  putCursor(ms: number, workspace: string, key: string, value: J, topic: Topic | null = null): void {
    if (this.#lost) return;
    this.soon(ms, () => this.#docs.putWorkspacePref(workspace, key, value, topic));
  }
  locals(table: "outbox" | "pending" | "first" | "changing"): [string, string, J][] { return this.#docs.locals(table); }
  putLocal(table: "outbox" | "pending" | "first" | "changing", station: string, key: string, value: J | undefined): void { this.#docs.putLocal(table, station, key, value); }

  // ── lists ──

  /// Whether a station's list has been read (else it is not known: undefined, not empty).
  listed(station: string, list: ListKind): boolean {
    const key = K("listed", station, list);
    if (this.#cache.has(key)) return this.#cache.get(key) === true;
    const known = this.sql.all("SELECT 1 FROM list WHERE station = ? AND list = ?", [station, list]).length > 0;
    this.#cache.set(key, known);
    return known;
  }

  /// How often a station's sidebar rows changed (what a change made here waits on: views/local.ts).
  rowsRev(station: string): number {
    const v = this.sql.all("SELECT rev FROM list WHERE station = ? AND list = 'chats'", [station])[0]?.[0];
    return typeof v === "number" ? v : 0;
  }

  #markListed(station: string, list: ListKind, confirmed: number | null, changed: boolean): void {
    const known = this.listed(station, list);
    this.#run("INSERT INTO list (station, list, confirmed, rev) VALUES (?, ?, ?, ?) ON CONFLICT (station, list) DO UPDATE SET confirmed = coalesce(excluded.confirmed, confirmed), rev = rev + ?", [station, list, confirmed, changed ? 1 : 0, changed ? 1 : 0]);
    this.#cache.set(K("listed", station, list), true);
    if (!known) {
      this.#tell({ topic: TOPIC_OF[list], station });
      if (list === "chats") this.#changes.firstChats.add(station);
    }
  }

  #bumpRev(station: string, list: ListKind): void {
    this.#run("INSERT INTO list (station, list, confirmed, rev) VALUES (?, ?, NULL, 1) ON CONFLICT (station, list) DO UPDATE SET rev = rev + 1", [station, list]);
  }

  /// A list as a topic shows it: its rows in order, undefined while it was never read. Loaded the first time.
  list(station: string, kind: ListKind): J[] | undefined {
    if (!this.listed(station, kind)) return undefined;
    return this.#collection(station, kind).array();
  }

  /// Lets go of a list nobody reads (its topic went).
  release(station: string, kind: ListKind): void {
    this.#lists.delete(K(kind, station));
  }

  /// Whether a list is loaded (a view reads it at once).
  loaded(station: string, kind: ListKind): boolean {
    return this.#lists.has(K(kind, station));
  }

  #collection(station: string, kind: ListKind): Collection {
    const key = K(kind, station);
    let c = this.#lists.get(key);
    if (c) return c;
    c = new Collection(kind === "threads");
    switch (kind) {
      case "chats":
      case "archived": {
        // (each kept row as it is kept: account.ts #byKey)
        const a = kind === "archived" ? 1 : 0;
        const found = this.sql.all("SELECT station, id, ord FROM chat WHERE station = ? AND archived = ?", [station, a]);
        const made = this.#chats.chatRowsFound(found, a, () => this.sql.all("SELECT station, id, json, unread FROM chat WHERE station = ? AND archived = ?", [station, a]));
        found.forEach((r, i) => {
          if (made[i] !== undefined) c.set(String(r[1]), made[i], [r[2] as number]);
        });
        break;
      }
      case "sessions": {
        const found = this.sql.all("SELECT key, ord FROM session WHERE station = ? AND listed = 1", [station]);
        const key = (r: SqlRow) => K("sum", station, String(r[0]));
        const made = this.#byKey(
          found.map((r) => [key(r), r[0]]),
          () => this.sql.all("SELECT key, summary FROM session WHERE station = ? AND listed = 1", [station]),
          (keys) => this.sql.all("SELECT s.key, s.summary FROM json_each(?) AS k CROSS JOIN session AS s WHERE s.station = ? AND s.key = k.value", [keys, station]),
          key,
          (r) => this.#cached(key(r), r[1]),
        );
        found.forEach((r, i) => c.set(String(r[0]), made[i], [r[1] as number]));
        break;
      }
      case "threads": {
        const found = this.sql.all("SELECT id, sort_at, created_at FROM thread WHERE station = ? AND listed = 1", [station]);
        const made = this.#sessions.threadsFound(station, found, () => this.sql.all("SELECT id, json, last, read, unread FROM thread WHERE station = ? AND listed = 1", [station]));
        found.forEach((r, i) => {
          if (made[i] !== undefined) c.set(String(r[0]), made[i], [r[1] as number, r[2] as number, r[0] as number]);
        });
        break;
      }
      case "jobs": {
        const found = this.sql.all("SELECT id, ord FROM job WHERE station = ? AND open = 1", [station]);
        const key = (r: SqlRow) => K("jobitem", station, String(r[0]));
        const made = this.#byKey(
          found.map((r) => [key(r), r[0]]),
          () => this.sql.all("SELECT id, json, chat FROM job WHERE station = ? AND open = 1", [station]),
          (keys) => this.sql.all("SELECT j.id, j.json, j.chat FROM json_each(?) AS k CROSS JOIN job AS j WHERE j.station = ? AND j.id = k.value", [keys, station]),
          key,
          (r) => this.#jobs.jobItem(station, String(r[0]), r[1], r[2]),
        );
        found.forEach((r, i) => {
          if (made[i] !== undefined) c.set(String(r[0]), made[i], [r[1] as number]);
        });
        break;
      }
    }
    this.#lists.set(key, c);
    return c;
  }

  /// The rows a query found by their keys alone (`found`: each one's key in the cache, and what `byKey` finds it again
  /// by), in its order, undefined where none was read: each one kept by its key as it is kept, read from the database
  /// only where none is. A list asked for again, a workspace's mark made again, read every row's JSON to take the one
  /// kept (5.6 ms in Hermes for a mark of 123 rows, every one kept, 2026-11-11). The JSON of those not kept is read by one
  /// more query: where they are most of what was found (more than half: a list read cold), `all`, the query again with
  /// its JSON, so that a cold read costs one query more of keys alone; otherwise `byKey`, given their keys as one JSON
  /// array (json_each: one statement whatever their number, never near SQLite's variable limit, and one statement kept
  /// prepared), each found by its primary key. Each row read: `keyOf` its key, `make` it into the row (which keeps it).
  #byKey(found: [string, unknown][], all: () => SqlRow[], byKey: (keys: string) => SqlRow[], keyOf: (r: SqlRow) => string, make: (r: SqlRow) => J): (J | undefined)[] {
    const out: (J | undefined)[] = found.map(([key]) => this.#cache.get(key) ?? undefined);
    let missing = 0;
    for (const v of out) if (v === undefined) missing++;
    if (missing === 0) return out;
    const whole = missing * 2 > found.length;
    const rows = whole ? all() : byKey(JSON.stringify(found.flatMap(([, at], i) => (out[i] === undefined ? [at] : []))));
    const read = new Map<string, SqlRow>();
    for (const r of rows) read.set(keyOf(r), r);
    for (let i = 0; i < found.length; i++) {
      if (out[i] !== undefined) {
        // (read again with the rest, for nothing)
        if (whole && read.has(found[i][0])) work.rowJson++;
        continue;
      }
      const r = read.get(found[i][0]);
      if (r !== undefined) out[i] = make(r);
    }
    return out;
  }

  #loadedList(station: string, kind: ListKind): Collection | undefined {
    return this.#lists.get(K(kind, station));
  }

  /// A row parsed once and kept by its key until written. `json` as read from the database (counted: work.rowJson, read
  /// for nothing where the row is kept), else as written here (`read` false).
  #cached(key: string, json: SqlValue, make?: (parsed: J) => J, read = true): J {
    if (read && typeof json === "string") work.rowJson++;
    const hit = this.#cache.get(key);
    if (hit !== undefined && hit !== null) return hit;
    const v = frozen(make ? make(parse(json)) : parse(json));
    this.#cache.set(key, v);
    return v;
  }

  // ── chats & moved chats ──

  setChats(station: string, archived: boolean, rows: J[], confirmed: number | null, places?: readonly number[]): void { this.#chats.setChats(station, archived, rows, confirmed, places); }
  putChat(station: string, row: J, place?: number): void { this.#chats.putChat(station, row, place); }
  dropChat(station: string, id: string): void { this.#chats.dropChat(station, id); }
  sharedMeta(station: string): SharedMeta | null { return this.#chats.sharedMeta(station); }
  setSharedNoRouteBuild(station: string, build: string | null): void { this.#chats.setSharedNoRouteBuild(station, build); }
  sharedDigests(station: string): Map<string, string> { return this.#chats.sharedDigests(station); }
  sharedSidecar(station: string, id: string): SharedSidecar | null { return this.#chats.sharedSidecar(station, id); }
  sharedSidecars(station: string): Map<string, SharedSidecar> { return this.#chats.sharedSidecars(station); }
  clearSharedBaseline(station: string): void { this.#chats.clearSharedBaseline(station); }
  setSharedChats(station: string, rows: J[], confirmed: number | null, places: readonly number[], sidecars: ReadonlyMap<string, SharedSidecar>, marks: SharedMarksSnapshot, meta: SharedMeta): void { this.#chats.setSharedChats(station, rows, confirmed, places, sidecars, marks, meta); }
  putSharedChat(station: string, row: J, place: number, sidecar: SharedSidecar | null): void { this.#chats.putSharedChat(station, row, place, sidecar); }
  putSharedBatch(station: string, updates: readonly { row: J; place: number; sidecar: SharedSidecar | null }[], drops: readonly string[], markUpdates: readonly { kind: SharedMarkKind; k: string; v: string | null }[], scopedMarks: { scope: { sessions: readonly string[]; threads: readonly number[] }; marks: SharedMarksSnapshot } | null): void { this.#chats.putSharedBatch(station, updates, drops, markUpdates, scopedMarks); }
  applySharedChanged(station: string, changed: readonly { row: J; place: number; sidecar: SharedSidecar }[], gone: readonly string[], reprojectAll: boolean, reproject: (row: J, sidecar: SharedSidecar) => { row: J; place: number }, newMarks: SharedMarksSnapshot, confirmed: number | null, meta: SharedMeta, extraReproject?: { ids?: Iterable<string>; threads?: Iterable<number> }): void { this.#chats.applySharedChanged(station, changed, gone, reprojectAll, reproject, newMarks, confirmed, meta, extraReproject); }
  moved(station: string, session: string): MovedTo | undefined { return this.#chats.moved(station, session); }
  movedThread(station: string, thread: number): string | undefined { return this.#chats.movedThread(station, thread); }
  movedFrom(station: string): string[] { return this.#chats.movedFrom(station); }
  putMoved(station: string, session: string, to: MovedTo | null): boolean { return this.#chats.putMoved(station, session, to); }
  dropChatsOf(station: string, session: string): void { this.#chats.dropChatsOf(station, session); }
  chatFound<P>(read: ChatRead<P>, p: P, wants: (cols: SqlRow) => boolean = () => true): ChatFound[] { return this.#chats.chatFound(read, p, wants); }
  chatRecords(found: ChatFound[]): void { this.#chats.chatRecords(found); }
  chatCounted<P>(read: ChatRead<P>, p: P): SqlRow[] { return this.#chats.chatCounted(read, p); }
  heldChat(station: string, id: string): J { return this.#chats.heldChat(station, id); }
  chat(station: string, id: string): J { return this.#chats.chat(station, id); }
  chatNamed(station: string, id: string): { row: J; archived: boolean } | undefined { return this.#chats.chatNamed(station, id); }
  chatOfThread(station: string, thread: number): J { return this.#chats.chatOfThread(station, thread); }
  chatsOf(station: string, of: { thread: number } | { session: string }): J[] { return this.#chats.chatsOf(station, of); }
  chatOfSession(station: string, session: string): J { return this.#chats.chatOfSession(station, session); }
  chatOfAgent(station: string, session: string): J { return this.#chats.chatOfAgent(station, session); }
  chatOfClientKey(station: string, key: string): J { return this.#chats.chatOfClientKey(station, key); }
  chatHead(stations: string[], limit: number, mine = false): [string, J][] { return this.#chats.chatHead(stations, limit, mine); }
  listHead(stations: string[], limit: number, mine: boolean, keys: Map<string, string>): HeadRow[] { return this.#chats.listHead(stations, limit, mine, keys); }
  chatCount(stations: string[]): number { return this.#chats.chatCount(stations); }
  marked(stations: string[]): [string, J][] { return this.#chats.marked(stations); }
  recentThreads(station: string, since: number, most: number): number[] { return this.#chats.recentThreads(station, since, most); }

  // ── sessions & threads ──

  summary(station: string, key: string): J { return this.#sessions.summary(station, key); }
  listedSummary(station: string, key: string): J { return this.#sessions.listedSummary(station, key); }
  setSessions(station: string, list: J[], confirmed: number | null, changed?: ReadonlySet<string>): void { this.#sessions.setSessions(station, list, confirmed, changed); }
  putSummary(station: string, summary: J): boolean { return this.#sessions.putSummary(station, summary); }
  dropSession(station: string, key: string): void { this.#sessions.dropSession(station, key); }
  detail(station: string, key: string): J { return this.#sessions.detail(station, key); }
  hasDetail(station: string, key: string): boolean { return this.#sessions.hasDetail(station, key); }
  setDetail(station: string, key: string, answer: J): void { this.#sessions.setDetail(station, key, answer); }
  patchDetail(station: string, key: string, change: (detail: J) => void): void { this.#sessions.patchDetail(station, key, change); }
  sessionKeys(station: string): string[] { return this.#sessions.sessionKeys(station); }
  sessionsToRead(station: string, keys?: readonly string[]): [string, boolean][] { return this.#sessions.sessionsToRead(station, keys); }
  thread(station: string, id: number): J { return this.#sessions.thread(station, id); }
  listedThread(station: string, id: number): J { return this.#sessions.listedThread(station, id); }
  threadOf(station: string, session: string): number | null { return this.#sessions.threadOf(station, session); }
  threadIds(station: string): number[] { return this.#sessions.threadIds(station); }
  threadsBehind(station: string): number[] { return this.#sessions.threadsBehind(station); }
  threadLast(station: string, id: number): number { return this.#sessions.threadLast(station, id); }
  setThreads(station: string, list: J[], confirmed: number | null, changed?: ReadonlySet<string>): void { this.#sessions.setThreads(station, list, confirmed, changed); }
  putThread(station: string, view: J): void { this.#sessions.putThread(station, view); }
  dropThread(station: string, id: number): void { this.#sessions.dropThread(station, id); }
  raiseLast(station: string, id: number, n: number): void { this.#sessions.raiseLast(station, id, n); }
  setRead(station: string, id: number, n: number): boolean { return this.#sessions.setRead(station, id, n); }
  readPosition(station: string, id: number): number | null { return this.#sessions.readPosition(station, id); }
  threadSessions(station: string, thread: number): string[] { return this.#sessions.threadSessions(station, thread); }

  // ── jobs ──

  job(station: string, id: string): J { return this.#jobs.job(station, id); }
  setJobs(station: string, list: J[], confirmed: number | null): void { this.#jobs.setJobs(station, list, confirmed); }
  putJob(station: string, job: J, open: boolean): boolean { return this.#jobs.putJob(station, job, open); }
  dropJob(station: string, id: string): boolean { return this.#jobs.dropJob(station, id); }
  closeSessionJobs(station: string, session: string): void { this.#jobs.closeSessionJobs(station, session); }

  // ── logs, search, eviction & slack_said ──

  findSaid(stations: string[], terms: string[], limit: number): { station: string; thread: number; seq: number; at: number | null; text: string }[] { return this.#logs.findSaid(stations, terms, limit); }
  saidFoundKept(stations: string[], terms: string[], limit: number): ReturnType<LogsStore["saidFoundKept"]> { return this.#logs.saidFoundKept(stations, terms, limit); }
  findSaidInThreads(targets: readonly { station: string; thread: number }[], terms: string[]): Map<string, { seq: number; at: number | null; text: string }> { return this.#logs.findSaidInThreads(targets, terms); }
  messageAt(station: string, thread: number, ts: string): number | null { return this.#logs.messageAt(station, thread, ts); }
  findInThread(station: string, thread: number, terms: string[]): { seq: number; text: string }[] { return this.#logs.findInThread(station, thread, terms); }
  used(): number { return this.#logs.used(); }
  evicted(kind: LogTable, station: string, id: string): boolean { return this.#logs.evicted(kind, station, id); }
  opened(kind: LogTable, station: string, id: string, at: number): boolean { return this.#logs.opened(kind, station, id, at); }
  openedHere(kind: LogTable, station: string, id: string): boolean { return this.#logs.openedHere(kind, station, id); }
  noteOpened(kind: LogTable, station: string, id: string, at: number): void { this.#logs.noteOpened(kind, station, id, at); }
  lastOpened(kind: LogTable, station: string, id: string): number | null { return this.#logs.lastOpened(kind, station, id); }
  transcriptsByUse(limit: number): { station: string; id: string }[] { return this.#logs.transcriptsByUse(limit); }
  evict(station: string, session: string): void { this.#logs.evict(station, session); }
  logNumbers(table: LogTable, station: string, id: string): readonly number[] { return this.#logs.logNumbers(table, station, id); }
  logRange(table: LogTable, station: string, id: string, from: number, to: number): Map<number, J> { return this.#logs.logRange(table, station, id, from, to); }
  peopleEntries(station: string, thread: number, upTo: number): { held: Map<number, J>; edits: Map<number, number[]> } { return this.#logs.peopleEntries(station, thread, upTo); }
  logSpan(table: LogTable, station: string, id: string): { min: number; max: number; count: number } | null { return this.#logs.logSpan(table, station, id); }
  logCount(table: LogTable, station: string, id: string, from: number, to: number): number { return this.#logs.logCount(table, station, id, from, to); }
  putLog(table: LogTable, station: string, id: string, items: [number, J][], cutAfter: number | null = null, keep = false): void { this.#logs.putLog(table, station, id, items, cutAfter, keep); }
  /// As `putLog`, its commit waiting up to `ms` (`soon`).
  putLogSoon(ms: number, table: LogTable, station: string, id: string, items: [number, J][]): void { this.soon(ms, () => this.#logs.putLog(table, station, id, items, null)); }
  forgetLog(table: LogTable, station: string, id: string): void { this.#logs.forgetLog(table, station, id); }
  slackSaid(station: string, session: string): Said[] { return this.#slack.slackSaid(station, session); }
  slackNames(station: string): [string, string][] { return this.#slack.slackNames(station); }

  // ── kept media, markdown cache & cache usage ──

  keptFile(station: string, session: string, name: string, kind: string, at: number): { type: string; bytes: string } | null { return this.#keptCache.keptFile(station, session, name, kind, at); }
  hasKeptFile(station: string, session: string, name: string, kind: string): boolean { return this.#keptCache.hasKeptFile(station, session, name, kind); }
  keepFile(station: string, session: string, name: string, kind: string, type: string, bytes: string, at: number): void { this.#keptCache.keepFile(station, session, name, kind, type, bytes, at); }
  hasMd(station: string, key: string): boolean { return this.#keptCache.hasMd(station, key); }
  oldMdOwners(reading: number, after: { station: string; of: string }): { station: string; of: string }[] { return this.#keptCache.oldMdOwners(reading, after); }
  hasOldMd(station: string, of: string, reading: number): boolean { return this.#keptCache.hasOldMd(station, of, reading); }
  mdSourcePage(station: string, of: string, before: number): { n: number; json: unknown }[] { return this.#keptCache.mdSourcePage(station, of, before); }
  keptMd(station: string, key: string): { used: number; json: string } | null { return this.#keptCache.keptMd(station, key); }
  keptMdMany(station: string, keys: readonly string[]): Map<string, { used: number; json: string }> { return this.#keptCache.keptMdMany(station, keys); }
  keepMd(station: string, of: string, key: string, json: string, at: number, replaces?: string): void { this.#keptCache.keepMd(station, of, key, json, at, replaces); }
  flushMd(station: string, puts: readonly MdPut[], touches: readonly { key: string; at: number }[]): void { this.#keptCache.flushMd(station, puts, touches); }
  countLogs(): boolean { return this.#keptCache.countLogs(); }
  cacheUsage(): { station: string; thread: number; view: J | null; sessions: string[]; bytes: number }[] { return this.#keptCache.cacheUsage(); }
  forgetChat(station: string, thread: number): void { this.#keptCache.forgetChat(station, thread); }

  // ── what goes ──

  /// Every station this database holds anything of.
  stations(): string[] {
    const out = new Set<string>();
    for (const [table, column] of [["station", "address"], ["list", "station"], ["chat", "station"], ["session", "station"], ["thread", "station"], ["job", "station"], ["slack_app", "station"], ["outbox", "station"], ["pending", "station"], ["first", "station"], ["changing", "station"], ["draft", "station"]]) {
      for (const r of this.sql.all(`SELECT DISTINCT ${column} FROM ${table}`)) out.add(String(r[0]));
    }
    return [...out].sort();
  }

  /// What is held of a station goes, every table of it.
  forgetStation(station: string): void {
    this.#write(() => {
      for (const [table, column] of [["station", "address"], ["slack_app", "station"], ["list", "station"], ["chat", "station"], ["session", "station"], ["thread", "station"], ["thread_member", "station"], ["entry", "station"], ["letter", "station"], ["transcript", "station"], ["job", "station"], ["outbox", "station"], ["pending", "station"], ["first", "station"], ["changing", "station"], ["draft", "station"]]) {
        this.sql.run(`DELETE FROM ${table} WHERE ${column} = ?`, [station]);
      }
      if (this.sql.all("SELECT 1 FROM sqlite_master WHERE name = 'log_use'").length > 0) this.sql.run("DELETE FROM log_use WHERE station = ?", [station]);
      this.#slack.forgetStation(station, (session) => this.#logs.tellLog("slack", station, session));
      this.#sessions.forgetStation(station);
      this.#keptCache.forgetStation(station);
      this.#logs.forgetStation(station);
      this.kept.forgetStation(station);
      this.#cache.clear();
      for (const key of [...this.#lists.keys()]) if (key.endsWith(`\u0001${station}`)) this.#lists.delete(key);
      this.#chats.forgetStation(station);
      this.#tell({ topic: "$station-reset", station });
      for (const topic of ["overview", "stationUsage", "chatRows", "archivedRows", "sessions", "threads", "jobs"]) this.#tell({ topic, station });
    });
  }

  // ── the meta table ──

  meta(key: string): string | null {
    const v = this.sql.all("SELECT value FROM meta WHERE key = ?", [key])[0]?.[0];
    return typeof v === "string" ? v : null;
  }

  setMeta(key: string, value: string): void {
    this.#write(() => void this.sql.run("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", [key, value]));
  }

  /// Several writes as one (an import): run now, in the burst's transaction.
  batch(fn: () => void): void {
    this.#write(fn);
  }

  /// A read only database's error, for a test.
  static isSqlError(e: unknown): e is SqlError {
    return e instanceof SqlError;
  }
}
