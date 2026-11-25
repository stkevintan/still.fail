// Thread entries, letters, session transcripts, log caches/spans/revisions, room eviction, and message search (account.ts).
import type { SqlValue } from "../host.ts";
import { lowerBound, upperBound } from "../ordered.ts";
import { work } from "../work.ts";
import { Cache, type DbEnv, type J, K, type LogTable, frozen, like, logColumns, logId, parse } from "./collection.ts";
import { LogIndex, LogIndices } from "./log-index.ts";
import { ensureKept, ensureSaid } from "./schema.ts";
import type { SlackSaidStore } from "./slack-said.ts";

/// How many items of a log a read takes from SQLite one by one, beside those parsed already; more, it reads the range.
const LOG_READ_ALONE = 16;
/// How many entries a statement reads by their numbers at once (`peopleEntries`): a few hundred parameters, well within
/// what any SQLite of the hosts binds.
const PEOPLE_READ_AT_ONCE = 400;
/// How many searches' messages found are kept (`findSaid`).
const SAID_FOUND_KEPT = 4;
/// What a search's messages found were, as of which change of the entries (`#saidRev`).
type SaidKept = { rev: number; found: { station: string; thread: number; seq: number; at: number | null; text: string }[] };
/// A search's messages found are kept by: its stations in any order (as its rows are), its words and how many.
const saidKey = (stations: string[], terms: string[], limit: number) => JSON.stringify([[...stations].sort(), terms, limit]);
/// How many changes of a log are kept said (`logPutSince`), and of how many logs.
const LOG_PUTS_KEPT = 64;
const LOG_PUTS_LOGS = 512;

export class LogsStore {
  readonly #env: DbEnv;
  readonly #slack: SlackSaidStore;
  /// Whether what was said can be found (`said` is there; it could not be made without room).
  #said = false;
  /// The logs let go for room (`log_use`), by K(kind, station, id).
  readonly #evicted = new Set<string>();
  readonly #logCache = new Cache(8192);
  readonly #logIndices = new LogIndices();
  /// Each log's span (`logSpan`) as read, kept as items are put in it (putLog), let go as anything else changes it:
  /// a long chat's count was read from SQLite again on every view of it (four times to open one, 2026-11-08).
  readonly #logSpans = new Map<string, { min: number; max: number; count: number } | null>();
  /// What was put in each log lately (`logPutSince`), so what is made of a long log reads again only what changed: by
  /// the log, each change's number (`#logRev`, one count for every log) and the numbers it put (null: another change,
  /// a cut or a delete). Of the changes before `from` (a log's, else `#logPutsFrom`) nothing is known.
  #logRev = 0;
  #logPutsFrom = 0;
  /// What `findSaid` found last and for what, kept while no thread's entries changed (`#saidRev`): a search is made
  /// again as each station answers and as the sidebar's rows change, and each scan reads the whole of `said`.
  #saidRev = 0;
  /// (a few: each search shown, and the one typed before, keeps its own)
  readonly #saidFound = new Map<string, SaidKept>();
  readonly #logPuts = new Map<string, { from: number; puts: { rev: number; put: number[] | null }[] }>();

  constructor(env: DbEnv, slack: SlackSaidStore) {
    this.#env = env;
    this.#slack = slack;
  }

  openSaid(readOnly: boolean): void {
    const sql = this.#env.sql;
    if (!readOnly) {
      try {
        ensureSaid(sql);
        this.#said = true;
      } catch {
        // No room to make it: messages are not found by their words this time.
      }
      return;
    }
    if (sql.all("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'said'").length > 0) {
      this.#said = true;
    }
  }

  openEvicted(): void {
    const sql = this.#env.sql;
    try {
      ensureKept(sql);
      // A chat's messages are no longer let go for room: those an earlier core let go are the sync's to bring again.
      sql.run("UPDATE log_use SET evicted = 0 WHERE kind = 'entry' AND evicted = 1");
      for (const r of sql.all("SELECT kind, station, id FROM log_use WHERE evicted = 1")) this.#evicted.add(K(String(r[0]), String(r[1]), String(r[2])));
    } catch {
      // No room to make it: nothing is let go this time.
    }
  }

  onRollback(): void {
    this.#saidRev++;
    this.#logCache.clear();
    this.#logIndices.clear();
    this.#logSpans.clear();
    this.logPutsForgotten();
  }

  clearLogCache(): void {
    this.#logCache.clear();
  }

  forgetStation(station: string): void {
    this.#saidRev++;
    for (const key of [...this.#evicted]) if (key.split("\u0001")[1] === station) this.#evicted.delete(key);
    this.logPutsForgotten();
    this.#logCache.clear();
    this.#logIndices.clear();
    this.#logSpans.clear();
  }

  /// A log changed: `put` the numbers put in it, null for anything else.
  tellLog(table: string, station: string, id: string, put: number[] | null = null): void {
    if (table === "entry") this.#saidRev++;
    this.#logIndices.delete(K(table, station, id));
    this.#logSpans.delete(K(table, station, id));
    this.#env.tellLogChange(K(table, station, id), [table, station, id]);
    if (table === "slack") this.#slack.onSlackTold(station);
    const key = K(table, station, id);
    const was = this.#logPuts.get(key);
    const log = was ?? { from: this.#logPutsFrom, puts: [] };
    log.puts.push({ rev: ++this.#logRev, put });
    if (log.puts.length > LOG_PUTS_KEPT) log.from = log.puts.shift()!.rev;
    this.#logPuts.delete(key);
    this.#logPuts.set(key, log);
    // (the least lately changed logs' let go: of every log's changes up to theirs nothing is known then)
    while (this.#logPuts.size > LOG_PUTS_LOGS) {
      const [oldest, gone] = this.#logPuts.entries().next().value!;
      this.#logPuts.delete(oldest);
      this.#logPutsFrom = Math.max(this.#logPutsFrom, gone.puts[gone.puts.length - 1]?.rev ?? 0);
    }
  }

  /// Nothing known of what was put in any log until now (what is held changed otherwise: rolled back, a station forgotten).
  logPutsForgotten(): void {
    this.#logPuts.clear();
    this.#logPutsFrom = ++this.#logRev;
  }

  /// The numbers put in a log since change `since` (`rev` of an answer before; 0: none), and the change it is at now;
  /// `put` null where that is not known (it changed otherwise, or long ago): all of it is to be read again.
  logPutSince(table: LogTable, station: string, id: string, since: number): { rev: number; put: number[] | null } {
    const rev = this.#logRev;
    const log = this.#logPuts.get(K(table, station, id));
    if (since <= 0 || since < (log?.from ?? this.#logPutsFrom)) return { rev, put: null };
    const put = new Set<number>();
    for (const p of log?.puts ?? []) {
      if (p.rev <= since) continue;
      if (p.put === null) return { rev, put: null };
      for (const n of p.put) put.add(n);
    }
    return { rev, put: [...put] };
  }

  // ── what was said ──

  /// The messages of these stations whose latest text has every one of `terms` (case aside), newest first.
  findSaid(stations: string[], terms: string[], limit: number): { station: string; thread: number; seq: number; at: number | null; text: string }[] {
    if (!this.#said || stations.length === 0 || terms.length === 0) return [];
    const key = saidKey(stations, terms, limit);
    const kept = this.#saidFound.get(key);
    if (kept !== undefined && kept.rev === this.#saidRev) return this.#saidUsed(key, kept).found;
    const where = [`s.station IN (${stations.map(() => "?").join(", ")})`, ...terms.map(() => "s.text LIKE ? ESCAPE '\\'")];
    const params: SqlValue[] = [...stations, ...terms.map(like), limit];
    const found = this.#env.sql
      .all(`SELECT s.station, s.thread, s.seq, s.at, s.text FROM said s WHERE ${where.join(" AND ")} ORDER BY s.at IS NULL, s.at DESC, s.seq DESC LIMIT ?`, params)
      .map((r) => ({ station: String(r[0]), thread: Number(r[1]), seq: Number(r[2]), at: typeof r[3] === "number" ? r[3] : null, text: String(r[4]) }));
    this.#saidFound.delete(key);
    this.#saidFound.set(key, { rev: this.#saidRev, found });
    if (this.#saidFound.size > SAID_FOUND_KEPT) this.#saidFound.delete(this.#saidFound.keys().next().value!);
    return found;
  }

  /// What `findSaid` found for these last (`now`: nothing said since), null where it was never looked for.
  saidFoundKept(stations: string[], terms: string[], limit: number): { found: { station: string; thread: number; seq: number; at: number | null; text: string }[]; now: boolean } | null {
    if (!this.#said || stations.length === 0 || terms.length === 0) return { found: [], now: true };
    const key = saidKey(stations, terms, limit);
    const kept = this.#saidFound.get(key);
    return kept === undefined ? null : { found: this.#saidUsed(key, kept).found, now: kept.rev === this.#saidRev };
  }

  /// A search's messages found read: the last let go of when room is wanted.
  #saidUsed(key: string, kept: SaidKept): SaidKept {
    this.#saidFound.delete(key);
    this.#saidFound.set(key, kept);
    return kept;
  }

  /// The number of the message of thread `thread` said at `ts` (its `ts`, as a quote names it), where it is held; null
  /// where not. Of that thread's entries alone (its key's prefix), a quote's press's.
  messageAt(station: string, thread: number, ts: string): number | null {
    const row = this.#env.sql.all("SELECT n FROM entry WHERE station = ? AND thread = ? AND json_extract(json, '$.kind') = 'message' AND json_extract(json, '$.ts') = ? ORDER BY n LIMIT 1", [station, thread, ts])[0];
    return row ? Number(row[0]) : null;
  }

  /// The messages of one thread whose latest text has every one of `terms` (case aside), oldest first, with their
  /// words (a chat's own find: all of them, as `findSaid` looks).
  findInThread(station: string, thread: number, terms: string[]): { seq: number; text: string }[] {
    if (!this.#said || terms.length === 0) return [];
    const where = ["s.station = ?", "s.thread = ?", ...terms.map(() => "s.text LIKE ? ESCAPE '\\'")];
    const params: SqlValue[] = [station, thread, ...terms.map(like)];
    return this.#env.sql.all(`SELECT s.seq, s.text FROM said s WHERE ${where.join(" AND ")} ORDER BY s.seq`, params).map((r) => ({ seq: Number(r[0]), text: String(r[1]) }));
  }

  /// The latest matching message in each of `targets` whose latest text has every one of `terms` (case aside), keyed
  /// by `${station}\u0001${thread}`. Queries each (station, thread) via `said`'s UNIQUE (station, thread, seq) index
  /// so unrelated threads are never scanned.
  findSaidInThreads(targets: readonly { station: string; thread: number }[], terms: string[]): Map<string, { seq: number; at: number | null; text: string }> {
    const out = new Map<string, { seq: number; at: number | null; text: string }>();
    if (!this.#said || targets.length === 0 || terms.length === 0) return out;
    const where = ["s.station = ?", "s.thread = ?", ...terms.map(() => "s.text LIKE ? ESCAPE '\\'")];
    const sql = `SELECT s.seq, s.at, s.text FROM said s WHERE ${where.join(" AND ")} ORDER BY s.seq DESC LIMIT 1`;
    const termParams = terms.map(like);
    for (const { station, thread } of targets) {
      const key = `${station}\u0001${thread}`;
      if (out.has(key)) continue;
      const r = this.#env.sql.all(sql, [station, thread, ...termParams])[0];
      if (r !== undefined) out.set(key, { seq: Number(r[0]), at: typeof r[1] === "number" ? r[1] : null, text: String(r[2]) });
    }
    return out;
  }

  // ── what is kept within the device's room ──

  /// How much of the database is in use (its pages less the free ones), in bytes.
  used(): number {
    const n = (q: string) => Number(this.#env.sql.all(q)[0]?.[0] ?? 0);
    return (n("PRAGMA page_count") - n("PRAGMA freelist_count")) * n("PRAGMA page_size");
  }

  /// Whether a log's items were let go for room (and not brought back since).
  evicted(kind: LogTable, station: string, id: string): boolean {
    return this.#evicted.has(K(kind, station, id));
  }

  /// A log's chat opened here: the most recently opened, and kept again (its items brought back by the sync). Answers
  /// whether they had been let go.
  opened(kind: LogTable, station: string, id: string, at: number): boolean {
    const was = this.openedHere(kind, station, id);
    this.noteOpened(kind, station, id, at);
    return was;
  }

  /// `opened` as the chat is shown, writing nothing: whether its items had been let go, kept from now on.
  openedHere(kind: LogTable, station: string, id: string): boolean {
    return this.#evicted.delete(K(kind, station, id));
  }

  /// `opened` written: when the log was opened, kept.
  noteOpened(kind: LogTable, station: string, id: string, at: number): void {
    this.#env.write(() => {
      this.#env.sql.run("INSERT INTO log_use (kind, station, id, opened, evicted) VALUES (?, ?, ?, ?, 0) ON CONFLICT (kind, station, id) DO UPDATE SET opened = excluded.opened, evicted = 0", [kind, station, id, at]);
    });
  }

  /// When a log was last opened here (`opened`), null when it never was.
  lastOpened(kind: LogTable, station: string, id: string): number | null {
    const v = this.#env.sql.all("SELECT opened FROM log_use WHERE kind = ? AND station = ? AND id = ?", [kind, station, id])[0]?.[0];
    return typeof v === "number" ? v : null;
  }

  /// The agents' transcripts held, least recently used first: by when their history was last opened here or their agent
  /// last active, whichever is later. (A chat's messages are never let go: they are the chat, and small.)
  transcriptsByUse(limit: number): { station: string; id: string }[] {
    // Seek to each next session in the transcript primary key; DISTINCT would scan every item of every transcript.
    return this.#env.sql
      .all(
        `WITH RECURSIVE x(station, session) AS (
           SELECT station, session FROM (SELECT station, session FROM transcript ORDER BY station, session LIMIT 1)
           UNION ALL
           SELECT t.station, t.session FROM x JOIN transcript t ON (t.station, t.session, t.i) = (
             SELECT z.station, z.session, z.i FROM transcript z WHERE z.station = x.station AND z.session > x.session
             ORDER BY z.station, z.session, z.i LIMIT 1
           )
           UNION ALL
           SELECT t.station, t.session FROM x JOIN transcript t ON (t.station, t.session, t.i) = (
             SELECT z.station, z.session, z.i FROM transcript z WHERE z.station > x.station
             ORDER BY z.station, z.session, z.i LIMIT 1
           ) WHERE NOT EXISTS (SELECT 1 FROM transcript z WHERE z.station = x.station AND z.session > x.session)
         )
         SELECT x.station, x.session FROM x
         LEFT JOIN log_use u ON u.kind = 'transcript' AND u.station = x.station AND u.id = x.session
         LEFT JOIN session s ON s.station = x.station AND s.key = x.session
         ORDER BY max(coalesce(u.opened, 0), coalesce(s.last_active, 0)), x.station, x.session LIMIT ?`,
        [limit],
      )
      .map((r) => ({ station: String(r[0]), id: String(r[1]) }));
  }

  /// A transcript's items let go for room: they are read again when its history is opened. Its session stays.
  evict(station: string, session: string): void {
    this.#evicted.add(K("transcript", station, session));
    this.#env.write(() => {
      this.#logCache.clear();
      if (this.#env.sql.run("DELETE FROM transcript WHERE station = ? AND session = ?", [station, session]) > 0) this.tellLog("transcript", station, session);
      this.#env.sql.run("INSERT INTO log_use (kind, station, id, evicted) VALUES ('transcript', ?, ?, 1) ON CONFLICT (kind, station, id) DO UPDATE SET evicted = 1", [station, session]);
    });
  }

  // ── a thread's entries and a session's transcript ──

  /// The numbers of a log's items held, in order.
  logNumbers(table: LogTable, station: string, id: string): readonly number[] {
    const cacheKey = K(table, station, id);
    const hit = this.#logIndices.get(cacheKey);
    if (hit) return hit.numbers;
    const [key, col] = logColumns(table);
    const numbers = this.#env.sql.all(`SELECT ${col} FROM ${table} WHERE station = ? AND ${key} = ? ORDER BY ${col}`, [station, logId(table, id)]).map((r) => r[0] as number);
    work.logNumbers += numbers.length;
    this.#logIndices.set(cacheKey, new LogIndex(numbers));
    return numbers;
  }

  /// A log's items `from ..= to` held, by number.
  logRange(table: LogTable, station: string, id: string, from: number, to: number): Map<number, J> {
    const [key, col] = logColumns(table);
    const out = new Map<number, J>();
    // Which numbers it holds there: from its index where one is kept, else asked of SQLite (the numbers alone, not their
    // JSON), so a window read again is read from what is parsed (a chat's window read from SQLite on each of its new
    // messages was much of what one cost, 2026-11-08) and a long log's every number is not read to open it.
    const index = this.#logIndices.get(K(table, station, id));
    const numbers = index ? index.numbers : this.#env.sql.all(`SELECT ${col} FROM ${table} WHERE station = ? AND ${key} = ? AND ${col} BETWEEN ? AND ? ORDER BY ${col}`, [station, logId(table, id), from, to]).map((r) => r[0] as number);
    if (!index) work.logNumbers += numbers.length;
    const first = index ? lowerBound(numbers, from) : 0;
    const end = index ? upperBound(numbers, to) : numbers.length;
    const missing: number[] = [];
    for (let i = first; i < end; i++) {
      const n = numbers[i]!;
      const item = this.#logCache.get(K(table, station, id, n));
      if (item === undefined) missing.push(n);
      else out.set(n, item);
    }
    // A hot window is already parsed: do not copy its JSON strings out of SQLite on every view update; what is not (a
    // new item, one let go from the cache) read alone.
    if (missing.length === 0) return out;
    if (missing.length <= LOG_READ_ALONE) {
      const rows = this.#env.sql.all(`SELECT t.${col}, t.json FROM json_each(?) AS k CROSS JOIN ${table} AS t WHERE t.station = ? AND t.${key} = ? AND t.${col} = k.value`, [JSON.stringify(missing), station, logId(table, id)]);
      work.logRows += rows.length;
      const read = new Map(rows.map((r) => [r[0] as number, this.#logItem(table, station, id, r[0] as number, r[1])]));
      // (in order of number, as the range reads: those read alone put in their places)
      const ordered = new Map<number, J>();
      for (let i = first; i < end; i++) {
        const n = numbers[i]!;
        const item = out.get(n) ?? read.get(n);
        if (item !== undefined) ordered.set(n, item);
      }
      return ordered;
    }
    out.clear();
    const rows = this.#env.sql.all(`SELECT ${col}, json FROM ${table} WHERE station = ? AND ${key} = ? AND ${col} BETWEEN ? AND ? ORDER BY ${col}`, [station, logId(table, id), from, to]);
    work.logRows += rows.length;
    for (const r of rows) {
      const n = r[0] as number;
      out.set(n, this.#logItem(table, station, id, n, r[1]));
    }
    return out;
  }

  /// What people said in a chat up to entry `upTo`, as its outline reads it (views.ts #peopleSaid): its people's messages
  /// (`entry_person`) and the edits of those (`entry_edit`) held, by number, and every edit's number by the message it
  /// edits (`edits`, in order). Found by those indexes alone, the JSON read only of those not parsed already: not the
  /// chat's every entry, its agents' replies most of its bytes (672 KB read for an outline of a few, 2026-11-18).
  peopleEntries(station: string, thread: number, upTo: number): { held: Map<number, J>; edits: Map<number, number[]> } {
    const id = String(thread);
    const people = this.#env.sql.all(
      "SELECT n FROM entry INDEXED BY entry_person WHERE station = ? AND thread = ? AND n BETWEEN 1 AND ? AND json_extract(json, '$.kind') = 'message' AND json_extract(json, '$.authorKind') = 'person' ORDER BY n",
      [station, thread, upTo],
    ).map((r) => r[0] as number);
    const editRows = this.#env.sql.all(
      "SELECT n, json_extract(json, '$.target') FROM entry INDEXED BY entry_edit WHERE station = ? AND thread = ? AND json_extract(json, '$.kind') = 'edit' AND n BETWEEN 1 AND ? ORDER BY n",
      [station, thread, upTo],
    );
    work.logNumbers += people.length + editRows.length;
    const edits = new Map<number, number[]>();
    const said = new Set(people);
    const wanted = [...people];
    for (const [n, target] of editRows) {
      if (typeof target !== "number") continue;
      const of = edits.get(target);
      if (of === undefined) edits.set(target, [n as number]);
      else of.push(n as number);
      if (said.has(target)) wanted.push(n as number);
    }
    const held = new Map<number, J>();
    const missing: number[] = [];
    for (const n of wanted) {
      const item = this.#logCache.get(K("entry", station, id, n));
      if (item === undefined) missing.push(n);
      else held.set(n, item);
    }
    for (let i = 0; i < missing.length; i += PEOPLE_READ_AT_ONCE) {
      const some = missing.slice(i, i + PEOPLE_READ_AT_ONCE);
      const rows = this.#env.sql.all("SELECT e.n, e.json FROM json_each(?) AS k CROSS JOIN entry AS e WHERE e.station = ? AND e.thread = ? AND e.n = k.value", [JSON.stringify(some), station, thread]);
      work.logRows += rows.length;
      for (const r of rows) held.set(r[0] as number, this.#logItem("entry", station, id, r[0] as number, r[1]));
    }
    return { held, edits };
  }

  #logItem(table: string, station: string, id: string, n: number, json: SqlValue): J {
    const key = K(table, station, id, n);
    const hit = this.#logCache.get(key);
    if (hit !== undefined) return hit;
    const v = frozen(parse(json));
    this.#logCache.set(key, v);
    return v;
  }

  /// The highest and lowest numbers a log holds, and how many (null when it holds none).
  logSpan(table: LogTable, station: string, id: string): { min: number; max: number; count: number } | null {
    const cacheKey = K(table, station, id);
    const index = this.#logIndices.get(cacheKey);
    if (index) return index.span;
    const kept = this.#logSpans.get(cacheKey);
    if (kept !== undefined) return kept === null ? null : { ...kept };
    const [key, col] = logColumns(table);
    const r = this.#env.sql.all(`SELECT min(${col}), max(${col}), count(*) FROM ${table} WHERE station = ? AND ${key} = ?`, [station, logId(table, id)])[0];
    const span = r && r[2] !== 0 ? { min: r[0] as number, max: r[1] as number, count: r[2] as number } : null;
    work.logSpans += span?.count ?? 0;
    this.#logSpans.set(cacheKey, span);
    return span === null ? null : { ...span };
  }

  /// How many of `from ..= to` a log holds.
  logCount(table: LogTable, station: string, id: string, from: number, to: number): number {
    const index = this.#logIndices.get(K(table, station, id));
    if (index) return index.count(from, to);
    const [key, col] = logColumns(table);
    return (this.#env.sql.all(`SELECT count(*) FROM ${table} WHERE station = ? AND ${key} = ? AND ${col} BETWEEN ? AND ?`, [station, logId(table, id), from, to])[0]?.[0] as number) ?? 0;
  }

  /// Items into a log, by number; those it holds the same are not written. `cutAfter`: nothing past it is kept.
  /// `keep`: what is held stays (an import: what the sync brought is newer).
  putLog(table: LogTable, station: string, id: string, items: [number, J][], cutAfter: number | null = null, keep = false): void {
    if (items.length === 0 && cutAfter === null) return;
    this.#env.write(() => {
      const cacheKey = K(table, station, id);
      const index = this.#logIndices.get(cacheKey);
      const span = this.#logSpans.get(cacheKey);
      // A failed SQL write must never leave a cached index (or span) of a different transaction state.
      this.#logIndices.delete(cacheKey);
      this.#logSpans.delete(cacheKey);
      const added: number[] = [];
      const [key, col] = logColumns(table);
      const k: SqlValue = logId(table, id);
      let changed = false;
      const written: [number, J][] = [];
      if (items.length > 0) {
        let lo = Infinity;
        let hi = -Infinity;
        for (const [n] of items) {
          lo = Math.min(lo, n);
          hi = Math.max(hi, n);
        }
        const held = new Map<number, SqlValue>();
        for (const r of this.#env.sql.all(`SELECT ${col}, json FROM ${table} WHERE station = ? AND ${key} = ? AND ${col} BETWEEN ? AND ?`, [station, k, lo, hi])) held.set(r[0] as number, r[1]);
        for (const [n, value] of items) {
          const json = JSON.stringify(value);
          const was = held.get(n);
          if (was === json || (keep && was !== undefined)) continue;
          this.#env.sql.run(`INSERT OR REPLACE INTO ${table} (station, ${key}, ${col}, json) VALUES (?, ?, ?, ?)`, [station, k, n, json]);
          this.#logCache.delete(K(table, station, id, n));
          if (was === undefined) added.push(n);
          written.push([n, value]);
          changed = true;
        }
      }
      if (cutAfter !== null) {
        for (const r of this.#env.sql.all(`SELECT ${col} FROM ${table} WHERE station = ? AND ${key} = ? AND ${col} > ?`, [station, k, cutAfter])) this.#logCache.delete(K(table, station, id, r[0] as number));
        if (this.#env.sql.run(`DELETE FROM ${table} WHERE station = ? AND ${key} = ? AND ${col} > ?`, [station, k, cutAfter]) > 0) changed = true;
      }
      if (table === "transcript" && this.#slack.hasSlackSaid()) {
        let said = false;
        if (cutAfter !== null && this.#slack.forgetSaid(station, "session = ? AND i > ?", [id, cutAfter])) said = true;
        if (written.length > 0 && this.#slack.readSlackSaid(station, id, written)) said = true;
        if (said) this.tellLog("slack", station, id);
      }
      // (what was put, unless something was cut too)
      if (changed) this.tellLog(table, station, id, cutAfter === null ? written.map(([n]) => n) : null);
      if (index) {
        index.put(written.map(([n]) => n), cutAfter);
        this.#logIndices.set(cacheKey, index);
      }
      // (only what was put in: a cut is read again)
      if (span !== undefined && cutAfter === null) {
        let next = span === null ? null : { ...span };
        for (const n of new Set(added)) next = next === null ? { min: n, max: n, count: 1 } : { min: Math.min(next.min, n), max: Math.max(next.max, n), count: next.count + 1 };
        this.#logSpans.set(cacheKey, next);
      }
    });
  }

  forgetEntries(station: string, thread: number): void {
    if (this.#env.sql.run("DELETE FROM entry WHERE station = ? AND thread = ?", [station, thread]) > 0) this.tellLog("entry", station, String(thread));
    if (this.#env.sql.run("DELETE FROM letter WHERE station = ? AND thread = ?", [station, thread]) > 0) this.tellLog("letter", station, String(thread));
  }

  /// A log known no more.
  forgetLog(table: LogTable, station: string, id: string): void {
    this.#env.write(() => {
      if (table === "entry") this.forgetEntries(station, Number(id));
      else if (table === "letter") {
        if (this.#env.sql.run("DELETE FROM letter WHERE station = ? AND thread = ?", [station, Number(id)]) > 0) this.tellLog("letter", station, id);
      } else {
        if (this.#env.sql.run("DELETE FROM transcript WHERE station = ? AND session = ?", [station, id]) > 0) this.tellLog("transcript", station, id);
        if (this.#slack.hasSlackSaid() && this.#slack.forgetSaid(station, "session = ?", [id])) this.tellLog("slack", station, id);
      }
    });
  }
}
