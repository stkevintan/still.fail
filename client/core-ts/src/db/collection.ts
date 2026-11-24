// Shared database types, pure value/ordering helpers, in-memory sorted collections, LRU cache, and the environment
// interface shared by the account database's subsystem stores (account.ts).
import type { Sql, SqlRow, SqlValue } from "../host.ts";
import type { Topic } from "../protocol.ts";
import { OWN_SURFACES } from "../titles.ts";
import { isObject } from "../util.ts";
import type { KeptValues, ListRow } from "./kept.ts";
import { CHAT_COLUMNS, CHAT_MADE, CHAT_MADE_ALT } from "./schema.ts";

// deno-lint-ignore no-explicit-any
export type J = any;

/// The station's own chats' surfaces, as SQL's list.
export const OWN_IN = OWN_SURFACES.map((s) => `'${s}'`).join(", ");

/// What the core finds a chat row by that only it can say (views/marks.ts, decisions.ts): how urgent the row is for
/// its person, whether it asks something.
/// `state`: what its agents are doing as its list's row says it (present.rowState: "block", "run", "failed", or null), of its
/// `agents` alone (a row derived again at open is given those alone: schema.ts ensureChatColumns); `watched`, whether one
/// of its agents keeps watch (present.watches), of them too.
export type Derive = { tone(row: J): string | null; asks(row: J): boolean; state(row: J): string | null; watched(row: J): boolean };

/// What a list reads first of a chat (listHead): its row kept beside it under the key in force, else its record.
export type HeadRow = { station: string; id: string; pinnedAt: number | null; row: ListRow | null; record: J };
export type { ListRow };

/// A chat row before and after a burst (undefined: not there).
export type RowChange = { id: string; before: J | undefined; after: J | undefined };
/// A row written, for the declared reads (chat-reads.ts): its records and its place (`ord`) before and after.
export type ReadChatChange = RowChange & { archived: boolean; between?: J[]; ordBefore: number | undefined; ordAfter: number | undefined };

/// What a burst changed.
export type Changes = {
  /// The held topics whose values changed.
  topics: Map<string, Topic>;
  /// Each station's sidebar rows (archived = 0) that changed.
  chats: Map<string, Map<string, RowChange>>;
  /// Changed rows, including archived ones: indexed readers must refresh after a commit or a rollback.
  readChats: Map<string, Map<string, ReadChatChange>>;
  /// The logs that changed: [table, station, thread or session].
  logs: Map<string, [string, string, string]>;
  /// The stations whose sidebar rows were read for the first time (where noticing starts from).
  firstChats: Set<string>;
  /// A chat a station said went elsewhere (`moved`) and now came back to it (station, session): its row made again
  /// (views/moved.ts).
  freed: [string, string][];
  /// Where a chat went that the station it went to said it came from (chats.ts `came`): the one it left, its session.
  came: [string, string][];
};

/// Where a station said a chat of its went (schema.ts ensureMoved): the station it is on now (its address), its thread
/// on the one it left and there.
export type MovedTo = { station: string; thread: number | null; there: number | null; at: number | null; came?: true };

/// A station's list a view reads: which rows, in what order.
export type ListKind = "chats" | "archived" | "sessions" | "threads" | "jobs";

export const LIST_OF: Record<string, ListKind> = { chatRows: "chats", archivedRows: "archived", sessions: "sessions", threads: "threads", jobs: "jobs" };
export const TOPIC_OF: Record<ListKind, string> = { chats: "chatRows", archived: "archivedRows", sessions: "sessions", threads: "threads", jobs: "jobs" };

export const u64 = (v: unknown): number | null => (typeof v === "number" && Number.isInteger(v) && v >= 0 ? v : null);
export const str = (v: unknown): string | null => (typeof v === "string" ? v : null);
export const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);
export const get = (v: unknown, k: string): J => (isObject(v) ? (v as J)[k] : undefined);

/// Frozen all through: a row as it is kept, shared by every reader (rule 7: a row that did not change is the same
/// object from one read to the next).
export function frozen<T>(v: T): T {
  if (v !== null && typeof v === "object" && !Object.isFrozen(v)) {
    for (const k of Object.keys(v)) frozen((v as Record<string, unknown>)[k]);
    Object.freeze(v);
  }
  return v;
}

export const parse = (text: SqlValue): J => (typeof text === "string" ? JSON.parse(text) : undefined);

/// An id as text (a station's ids are strings, threads' numbers).
export function idText(id: unknown): string | null {
  if (typeof id === "string") return id;
  if (typeof id === "number") return String(id);
  return null;
}

/// The session keys taking part in a thread.
export function membersOf(thread: J): string[] {
  const out: string[] = [];
  for (const m of Array.isArray(get(thread, "sessions")) ? thread.sessions : []) if (typeof get(m, "session") === "string") out.push(m.session);
  return out;
}

/// Places for rows given in a new order: those already placed in an order the new one keeps (the longest such run)
/// stay where they are; the others go between their neighbours. So a row put on top, or moved, writes that row alone.
export function placesFor(was: (number | null)[]): number[] {
  const n = was.length;
  const keep = longestRun(was);
  const out = new Array<number>(n);
  for (let i = 0; i < n; i++) if (keep.has(i)) out[i] = was[i]!;
  let i = 0;
  while (i < n) {
    if (keep.has(i)) {
      i++;
      continue;
    }
    let j = i;
    while (j < n && !keep.has(j)) j++;
    const lo = i > 0 ? out[i - 1] : null;
    const hi = j < n ? out[j] : null;
    const count = j - i;
    for (let k = 0; k < count; k++) {
      if (lo === null && hi === null) out[i + k] = k;
      else if (lo === null) out[i + k] = hi! - (count - k);
      else if (hi === null) out[i + k] = lo + k + 1;
      else out[i + k] = lo + ((hi - lo) * (k + 1)) / (count + 1);
    }
    i = j;
  }
  // Places worn too fine to tell apart: all of them anew.
  for (let k = 1; k < n; k++) if (!(out[k] > out[k - 1])) return out.map((_, x) => x);
  return out;
}

function longestRun(values: (number | null)[]): Set<number> {
  const tails: number[] = [];
  const prev = new Array<number>(values.length).fill(-1);
  for (let i = 0; i < values.length; i++) {
    const p = values[i];
    if (p === null) continue;
    let lo = 0;
    let hi = tails.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if ((values[tails[mid]] as number) < p) lo = mid + 1;
      else hi = mid;
    }
    if (lo > 0) prev[i] = tails[lo - 1];
    tails[lo] = i;
  }
  const out = new Set<number>();
  for (let i = tails.length > 0 ? tails[tails.length - 1] : -1; i >= 0; i = prev[i]) out.add(i);
  return out;
}

/// A list loaded: its rows by id and where each sorts.
export class Collection {
  readonly items = new Map<string, J>();
  readonly sort = new Map<string, number[]>();
  /// The rows in order, and their ids: made once, then each change put in its place on copies of them (one row of 1400
  /// changed sorted all of them again, as each chat's new message did, 2026-11-08).
  #array: J[] | null = null;
  #ids: string[] | null = null;
  readonly descending: boolean;
  constructor(descending: boolean) {
    this.descending = descending;
  }

  #before(x: number[], a: string, y: number[], b: string): number {
    const d = this.descending ? -1 : 1;
    for (let i = 0; i < x.length; i++) if (x[i] !== y[i]) return (x[i]! - y[i]!) * d;
    return a < b ? -1 : a > b ? 1 : 0;
  }

  /// Where id with `sort` is, or goes, in the ids in order.
  #at(ids: string[], id: string, sort: number[]): number {
    let lo = 0;
    let hi = ids.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (this.#before(this.sort.get(ids[mid]!)!, ids[mid]!, sort, id) < 0) lo = mid + 1;
      else hi = mid;
    }
    return lo;
  }

  #out(id: string): { ids: string[]; rows: J[] } | null {
    if (!this.#ids || !this.#array) return null;
    const ids = this.#ids.slice();
    const rows = this.#array.slice();
    const was = this.sort.get(id);
    if (was !== undefined) {
      const at = this.#at(ids, id, was);
      if (ids[at] === id) {
        ids.splice(at, 1);
        rows.splice(at, 1);
      } else return null;
    }
    return { ids, rows };
  }

  set(id: string, row: J, sort: number[]): void {
    const kept = this.#out(id);
    this.items.set(id, row);
    this.sort.set(id, sort);
    if (kept === null) {
      this.#array = null;
      this.#ids = null;
      return;
    }
    const at = this.#at(kept.ids, id, sort);
    kept.ids.splice(at, 0, id);
    kept.rows.splice(at, 0, row);
    this.#ids = kept.ids;
    this.#array = kept.rows;
  }

  delete(id: string): void {
    if (!this.items.has(id)) return;
    const kept = this.#out(id);
    this.items.delete(id);
    this.sort.delete(id);
    this.#ids = kept?.ids ?? null;
    this.#array = kept?.rows ?? null;
  }

  /// The rows in order (the same array while nothing changed).
  array(): J[] {
    if (this.#array) return this.#array;
    const ids = [...this.items.keys()];
    ids.sort((a, b) => this.#before(this.sort.get(a)!, a, this.sort.get(b)!, b));
    this.#ids = ids;
    this.#array = ids.map((id) => this.items.get(id));
    return this.#array;
  }
}

/// Rows read by key, kept until written; the oldest go past `cap`.
export class Cache {
  readonly #map = new Map<string, J>();
  readonly cap: number;
  constructor(cap: number) {
    this.cap = cap;
  }
  get(key: string): J | undefined {
    const v = this.#map.get(key);
    if (v !== undefined) {
      this.#map.delete(key);
      this.#map.set(key, v);
    }
    return v;
  }
  has(key: string): boolean {
    return this.#map.has(key);
  }
  set(key: string, v: J): void {
    this.#map.delete(key);
    this.#map.set(key, v);
    if (this.#map.size > this.cap) this.#map.delete(this.#map.keys().next().value!);
  }
  delete(key: string): void {
    this.#map.delete(key);
  }
  clear(): void {
    this.#map.clear();
  }
}

export const K = (...parts: (string | number)[]) => parts.join("\u0001");
/// A Slack person's id as a mention of them is written: a bot heard as its mention (`<@U…>`), its id out of it.
export const slackId = (user: string): string => user.replace(/^<@(.+)>$/, "$1");
/// Of `slack_said`, the rows that name who was heard (slack_who's).
export const HEARD = "out = 0 AND user IS NOT NULL AND who IS NOT NULL AND who != ''";
/// A word looked for, as `LIKE ? ESCAPE '\'` takes it: anywhere in the text, its own `%` `_` `\` as they are.
export const like = (term: string) => `%${term.replace(/[\\%_]/g, (c) => `\\${c}`)}%`;

export const MD_SHOWN_EVERY = 86_400_000;

/// A tree read, to be kept (`flushMd`).
export type MdPut = { of: string; key: string; json: string; at: number; replaces?: string };

/// The tables of what this device did itself: written again on their own when a burst could not be (a full disk).
export const PRECIOUS = /^(INSERT|DELETE|UPDATE)[^(]*\b(outbox|pending|first|changing|draft|workspace_pref)\b/i;

/// Where a document is kept (`putDoc`): its table, the columns of its key and their values, and when its source confirmed
/// it (null: not now; undefined: the table keeps none).
export type Doc = { table: string; keys: string[]; of: SqlValue[]; confirmed?: number | null };

/// The chat columns of a row, and its JSON without them.
export type ChatCols = { json: string; unread: number | null; thread: number | null; session: string | null; clientKey: string | null; lastActive: number; pinnedAt: number | null; mine: number; running: number; tone: string | null; asks: number; state: string | null; watched: number };

/// A chat row a declared read found (chat-reads.ts): its keys, the read's own columns after them (`cols`, from the
/// fourth), and its record where the read asked for it (read by its key, from the cache where held).
export type ChatFound = { station: string; archived: boolean; id: string; cols: SqlRow; record: J | undefined };

/// The rows a declared read's statement gave, each a ChatFound of its own (its record not read).
export const foundOf = (rows: readonly SqlRow[]): ChatFound[] => rows.map((r) => ({ station: String(r[0]), archived: r[1] === 1, id: String(r[2]), cols: r.slice(3), record: undefined }));

/// The statement that puts a chat's record: the columns every core writes, `state` and `made` this core's, and those
/// SQLite makes of its JSON (schema.ts CHAT_COLUMNS), of the JSON given last. Uses `ON CONFLICT DO UPDATE` rather than
/// `INSERT OR REPLACE` so updating an existing chat keeps its `rowid` and skips rewriting unchanged secondary indexes
/// (`chat_ord`, `chat_thread`, `chat_session`, `chat_client`, `chat_marks`, `chat_unmade`, `chat_agent`).
export const PUT_CHAT = `INSERT INTO chat (station, id, archived, ord, thread, session, client_key, last_active, pinned_at, unread, mine, running, tone, asks, state, watched, made, json, ${CHAT_COLUMNS.map(([c]) => c).join(", ")})
  SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ${CHAT_MADE}, r.json, ${CHAT_COLUMNS.map(([, of]) => of("r.json")).join(", ")} FROM (SELECT ? AS json) AS r WHERE true
  ON CONFLICT (station, archived, id) DO UPDATE SET
    ord = excluded.ord, thread = excluded.thread, session = excluded.session, client_key = excluded.client_key,
    last_active = excluded.last_active, pinned_at = excluded.pinned_at, unread = excluded.unread,
    mine = excluded.mine, running = excluded.running, tone = excluded.tone, asks = excluded.asks,
    state = excluded.state, watched = excluded.watched,
    made = CASE WHEN chat.made = ${CHAT_MADE} THEN ${CHAT_MADE_ALT} ELSE ${CHAT_MADE} END,
    json = excluded.json,
    ${CHAT_COLUMNS.map(([c]) => `${c} = excluded.${c}`).join(", ")}`;

/// A chat row as a station's list was last written (`setChats`): the row as it was given (null: only read), and its
/// place.
export type HeldChat = { row: J; ord: number };

/// The logs a station's channels are held in (station/channel-kinds.ts): a thread's entries, its letters (their own log
/// beside its entries), a session's transcript.
export type LogTable = "entry" | "letter" | "transcript";

/// A log's id column and item number column.
export const logColumns = (table: LogTable): [string, string] => (table === "transcript" ? ["session", "i"] : ["thread", "n"]);

/// A log's id as its id column holds it (a thread's a number).
export const logId = (table: LogTable, id: string): SqlValue => (table === "transcript" ? id : Number(id));

/// Shared database transaction, cache, and change-reporting primitives passed to each subsystem store.
export type DbEnv = {
  readonly sql: Sql;
  readonly readOnly: boolean;
  readonly kept: KeptValues;
  readonly cache: Cache;
  readonly derive: Derive;
  full(): boolean;
  failed(): boolean;
  write(fn: () => void): void;
  run(sql: string, params: readonly SqlValue[]): number;
  tell(topic: Topic): void;
  tellChat(station: string, id: string, before: J | undefined, after: J | undefined): void;
  tellChatRead(station: string, archived: number, id: string, before: J | undefined, after: J | undefined, ordBefore: number | undefined, ordAfter: number | undefined): void;
  tellLogChange(key: string, entry: [string, string, string]): void;
  tellFreed(station: string, session: string): void;
  tellCame(station: string, session: string): void;
  listed(station: string, list: ListKind): boolean;
  markListed(station: string, list: ListKind, confirmed: number | null, changed: boolean): void;
  bumpRev(station: string, list: ListKind): void;
  loadedList(station: string, kind: ListKind): Collection | undefined;
  byKey(found: [string, unknown][], all: () => SqlRow[], byKey: (keys: string) => SqlRow[], keyOf: (r: SqlRow) => string, make: (r: SqlRow) => J): (J | undefined)[];
  cached(key: string, json: SqlValue, make?: (parsed: J) => J, read?: boolean): J;
};
