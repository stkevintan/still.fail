// A station of the real-size workspace (real-size.ts: Maple's sessions, threads, its chat list as it makes it for
// everyone, and marks of them all) answering a core started on it, and what rows-changed.test.ts holds of what the core
// makes of it: its chat list as stored, against what is made of what it holds anew (rows-made.ts with an empty memo);
// and what one change makes the core do (work.ts), measured in a worker thread a size (`workerData.rowsChanged`).
import assert from "node:assert/strict";
import { isMainThread, parentPort, workerData } from "node:worker_threads";
import { worded } from "../src/chat-row.ts";
import { digest } from "../src/digest.ts";
import { OwnHeld, marksOf, rowWords, rowsShared, sharedPlace } from "../src/station/rows-made.ts";
import { glanced, work } from "../src/work.ts";
import type { HttpRequest } from "../src/host.ts";
import { CHAT, SIZE, address, fixture } from "./real-size.ts";
import { base, stationReplies, started, status } from "./station-fixture.ts";
import { Core } from "../src/core.ts";
import { HostWire } from "../src/station/wire.ts";

// deno-lint-ignore no-explicit-any
type J = any;

export const ST = "ws/st";
/// The viewer, as station-fixture's core is signed in (helpers.ts `signIn`); the workspace's owner in real-size.ts is
/// made them.
const ME = "a@x.com";
/// When the workspace is made.
const BASE = 1_794_000_000_000;

/// A deterministic stream of numbers in [0, 1) (mulberry32).
export function seeded(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/// What the station holds and says: Maple's of the real-size workspace, its owner the viewer.
export class Station {
  readonly sessions = new Map<string, J>();
  readonly threads = new Map<number, J>();
  /// Its chat list as it makes it for everyone (chat-row.ts), by row id.
  readonly shared = new Map<string, J>();
  marks: J;
  changedSharedCalls = 0;
  wholeSharedCalls = 0;
  marksOwnCalls = 0;
  constructor() {
    const of = (topic: string) => JSON.parse(JSON.stringify(fixture(BASE).find(([t]) => t.topic === topic && t.station === address(0))![1]).replaceAll("me@x.com", ME)) as J[];
    for (const s of of("sessions")) this.sessions.set(s.key, s);
    for (const t of of("threads")) this.threads.set(t.id, t);
    const rows = of("chatRows");
    const marks: J = {
      card: {}, need: {}, answered: {}, suggested: [], verdicts: {}, reviews: true, kept: [], hidden: [], muted: [], pins: {}, openers: {}, opened: {}, shares: {}, clientKeys: {},
      teams: { "c-slack-1": "Acme" }, selves: ["U04A1B2C3D4"], dismissed: [], reads: {},
    };
    rows.forEach((r, i) => {
      const id = String(r.thread);
      if (r.card !== undefined) marks.card[id] = r.card;
      else if (i % 7 === 2) marks.need[id] = { seq: r.last.seq, text: "需要你看一下", at: r.lastActiveAt };
      if (i % 9 === 4) marks.answered[id] = [{ seq: r.last.seq - 1, label: "可以" }];
      if (r.archiveRecommended) marks.suggested.push(r.thread);
      if (i % 8 === 6) marks.verdicts[id] = { done: i % 16 === 6, why: "看起来做完了" };
      if (i % 12 === 7) marks.kept.push(r.thread);
      if (i % 15 === 11) marks.hidden.push(r.thread);
      if (i % 17 === 13) marks.muted.push(r.thread);
      if (r.pinned !== null) marks.pins[r.id] = r.pinned;
      if (r.opened !== undefined) marks.opened[r.id] = r.opened;
      if (r.xshare !== undefined) marks.shares[r.id] = r.xshare;
      if (i % 19 === 3) marks.openers[r.id] = { session: CHAT.keys[0], title: "从这里开的" };
      if (i % 23 === 5) marks.clientKeys[r.id] = `ck-${i}`;
      if (i % 10 === 1) marks.reads[id] = r.last.seq - 1;
      // (as a station makes it for everyone: what its last message was, and what was said after the viewer's own)
      this.shared.set(r.id, { ...r, said: r.last ? { n: r.last.seq, other: r.last.seq - (i % 3) } : null });
    });
    this.marks = marks;
  }

  /// The marks of some chats (GET /chats?marks=1&session=…&thread=…), or all of them.
  marksOf(sessions: Set<string> | null, threads: Set<number> | null): J {
    const m = this.marks;
    if (sessions === null || threads === null) return structuredClone(m);
    const ofThreads = (o: Record<string, J>) => Object.fromEntries(Object.entries(o).filter(([k]) => threads.has(Number(k))));
    const ofSessions = (o: Record<string, J>) => Object.fromEntries(Object.entries(o).filter(([k]) => sessions.has(k)));
    const ids = (a: number[]) => a.filter((t) => threads.has(t));
    return structuredClone({
      card: ofThreads(m.card), need: ofThreads(m.need), answered: ofThreads(m.answered), verdicts: ofThreads(m.verdicts), reads: ofThreads(m.reads),
      suggested: ids(m.suggested), kept: ids(m.kept), hidden: ids(m.hidden), muted: ids(m.muted),
      dismissed: m.dismissed.filter((d: string) => threads.has(Number(d.slice(0, d.indexOf(":"))))),
      pins: ofSessions(m.pins), openers: ofSessions(m.openers), opened: ofSessions(m.opened), shares: ofSessions(m.shares), clientKeys: ofSessions(m.clientKeys),
      teams: m.teams, selves: m.selves, reviews: m.reviews,
    });
  }

  /// Its answer to a request of the core's (undefined: station-fixture's table's).
  reply(req: HttpRequest): unknown {
    const path = req.url.replace("https://stillfail.test/admin/api", "");
    if (req.method === "POST" && path === "/changed/shared") {
      this.changedSharedCalls++;
      const held = (req.body ? (JSON.parse(new TextDecoder().decode(req.body)) as { held?: Record<string, string> }).held : undefined) ?? {};
      const all = [...this.shared.values()];
      return {
        order: all.map((r) => String(r.id)),
        rows: all.filter((r) => held[String(r.id)] !== digest(r)),
      };
    }
    if (req.method !== "GET") return undefined;
    if (path === "/sessions") return [...this.sessions.values()];
    if (path === "/threads") return [...this.threads.values()];
    if (path === "/chats?shared=1") {
      this.wholeSharedCalls++;
      return [...this.shared.values()];
    }
    const thread = /^\/threads\/(\d+)$/.exec(path);
    if (thread) return this.threads.get(Number(thread[1])) ?? status(404, { error: "no such chat" });
    if (path.startsWith("/chats?marks=1")) {
      const q = new URLSearchParams(path.slice(path.indexOf("?") + 1));
      const scoped = q.has("session") || q.has("thread");
      if (q.get("own") === "1") {
        this.marksOwnCalls++;
        const m = this.marks;
        return structuredClone({
          kept: m.kept, hidden: m.hidden, muted: m.muted, pins: m.pins,
          selves: m.selves, dismissed: m.dismissed, reads: m.reads,
        });
      }
      return this.marksOf(scoped ? new Set(q.getAll("session")) : null, scoped ? new Set(q.getAll("thread").map(Number)) : null);
    }
    return undefined;
  }
}

/// A core started on `station`, everything read.
export async function startedOn(station: Station) {
  const s = await started({ ...base(), "GET /chats?archived=1": [] }, 0, undefined, (s) => {
    stationReplies(s.host, (req) => station.reply(req));
  });
  await s.host.time.pass(3000, 100);
  return s;
}
export type Started = Awaited<ReturnType<typeof startedOn>>;

/// A row as the chat table keeps it: its id, its JSON (`unread` apart), `unread`, and its place (rows-made.ts
/// `sharedPlace`).
export type Row = { id: string; json: string; unread: number | null; ord?: number };

/// A row as the chat table keeps it: its JSON (`unread` apart) and `unread`.
const asStored = (row: J): { json: string; unread: number | null } => {
  const { unread, ...rest } = row;
  return { json: JSON.stringify(rest), unread: typeof unread === "boolean" ? (unread ? 1 : 0) : null };
};

/// The station's chat list as the core stored it, in the order every read reads it in (`ORDER BY ord, id`), with its
/// places.
export function stored(s: Started): Row[] {
  return s.core.inner.data.of(ST)!.sql.all("SELECT id, json, unread, ord FROM chat WHERE station = ? AND archived = 0 ORDER BY ord, id", [ST])
    .map((r) => ({ id: String(r[0]), json: String(r[1]), unread: r[2] as number | null, ord: r[3] as number }));
}

/// Pure canonical deep equality for JSON values (independent of object key order and of production `digest`).
function sameJsonValue(a: unknown, b: unknown): boolean {
  if (Object.is(a, b)) return true;
  if (a === null || b === null || typeof a !== "object" || typeof b !== "object") return false;
  if (Array.isArray(a) || Array.isArray(b)) {
    return Array.isArray(a) && Array.isArray(b) && a.length === b.length && a.every((v, i) => sameJsonValue(v, b[i]));
  }
  const ao = a as Record<string, unknown>;
  const bo = b as Record<string, unknown>;
  const ak = Object.keys(ao);
  const bk = Object.keys(bo);
  if (ak.length !== bk.length) return false;
  return ak.every((k) => Object.prototype.hasOwnProperty.call(bo, k) && sameJsonValue(ao[k], bo[k]));
}

/// Independent station ground truth: built solely from the fixture's authoritative `station.shared` and `station.marks`
/// (never reading `link.sharedRows` or `link.own`), for verifying converged state after whole/reconnect reconciliation.
export function madeFromStation(station: Station): Row[] {
  const words = rowWords();
  const own = new OwnHeld(marksOf(station.marks)!, ME);
  const rows = rowsShared(station.shared.values(), own, ME, words);
  const seen = new Set<string>();
  return rows.flatMap((r) => {
    if (seen.has(r.id)) return [];
    seen.add(r.id);
    return [{ id: r.id, ...asStored(worded(r, words)), ord: sharedPlace(r) }];
  });
}

/// What a core started anew makes of the station's shared list and the in-process viewer's marks: rows-made.ts with an
/// empty memo, in the viewer's words, each id once.
export function madeAnew(s: Started, station?: Station): Row[] {
  const link = s.core.inner.stations.link(ST)!;
  const words = rowWords();
  const source: Iterable<J> = station
    ? station.shared.values()
    : link.sharedRows!.values();
  const rows = rowsShared(source, link.own!, ME, words);
  const seen = new Set<string>();
  return rows.flatMap((r) => {
    if (seen.has(r.id)) return [];
    seen.add(r.id);
    return [{ id: r.id, ...asStored(worded(r, words)), ord: sharedPlace(r) }];
  });
}

/// Where two lists of rows differ: an id at a place, or a field of a row (canonical deep equality; none: the same).
export function differences(stored: Row[], made: Row[]): string[] {
  const out: string[] = [];
  for (let i = 0; i < Math.max(stored.length, made.length); i++) {
    const a = stored[i];
    const b = made[i];
    if (a?.id !== b?.id) {
      out.push(`at ${i}: stored ${a?.id ?? "nothing"}, made ${b?.id ?? "nothing"}`);
      continue;
    }
    if (a!.unread !== b!.unread) out.push(`${a!.id} unread: stored ${a!.unread}, made ${b!.unread}`);
    if (a!.ord !== b!.ord) out.push(`${a!.id} place: stored ${a!.ord}, made ${b!.ord}`);
    if (a!.json === b!.json) continue;
    const x = JSON.parse(a!.json) as J;
    const y = JSON.parse(b!.json) as J;
    for (const k of new Set([...Object.keys(x), ...Object.keys(y)])) {
      if (!sameJsonValue(x[k], y[k])) out.push(`${a!.id} ${k}: stored ${JSON.stringify(x[k])}, made ${JSON.stringify(y[k])}`);
    }
  }
  return out;
}

// ── what the station tells ──

const pick = <T>(r: () => number, a: readonly T[]): T => a[Math.floor(r() * a.length)]!;

/// A message said in thread `t` (`person`: by a person, else by its first agent), as the station tells it and keeps it.
export function said(station: Station, s: Started, t: J, person: boolean, text = "好的，我先跑一遍测试再合。"): void {
  const n = t.last + 1;
  const at = s.host.nowMs();
  const author = person ? "lina@acme.dev" : t.sessions[0]?.session ?? "k";
  const entry = { thread: t.id, n, kind: "message", target: null, ts: `${t.id}.${n}`, authorKind: person ? "person" : "agent", author, authorName: person ? "Lina Park" : null, text, at };
  station.threads.set(t.id, {
    ...t, last: n, unread: (t.unread ?? 0) + 1,
    lastMessage: { seq: n, thread: t.id, ts: entry.ts, authorKind: entry.authorKind, author, authorName: entry.authorName, text, attachments: [], quotes: [], declared: null, createdAt: at, editedAt: null },
  });
  s.push("thread", { id: t.id, entries: [entry] });
}

/// A session's summary as its station tells it changed (`turn`: its last turn now asks a person).
export function summary(station: Station, s: Started, key: string, change: J): void {
  const now = { ...station.sessions.get(key)!, lastActiveAt: s.host.nowMs(), ...change };
  if (now.archivedAt !== null && now.archivedAt !== undefined) station.sessions.delete(key);
  else station.sessions.set(key, now);
  s.push("session", now);
}

/// A message said in the chat of row `row` of a station that makes its list, as it tells it: what was said (`thread`,
/// `said`) and the row it makes of it, on top (`at`: when, else now).
export function sharedSaid(station: Station, s: Started, row: J, person: boolean, at = s.host.nowMs()): void {
  const t = station.threads.get(row.thread);
  if (t !== undefined) said(station, s, t, person, person ? "这个先别合" : "好的");
  const seq = (t?.last ?? row.last.seq) + 1;
  const now = { ...row, lastActiveAt: at, last: { ...row.last, seq, text: `第 ${seq} 条`, createdAt: at }, said: { n: seq, other: person ? seq - 1 : seq } };
  station.shared.set(row.id, now);
  s.push("chat-shared", now);
}

/// One of the changes a station that makes its chat list for everyone tells, picked by `r`: each kind the sync takes
/// by key, and those it takes whole (the marks read whole, whose rows they are, a reconnect).
export const SHARED_KINDS = ["row", "row", "top", "tie", "new", "new", "removed", "read", "pin", "kept", "hidden", "muted", "dismiss", "said", "marked", "renamed", "summary", "turn", "whole", "reconnect"] as const;
export function anySharedChange(station: Station, s: Started, r: () => number, which?: (typeof SHARED_KINDS)[number]): string {
  const rows = [...station.shared.values()];
  const row = pick(r, rows);
  const m = station.marks;
  const kind = which ?? pick(r, SHARED_KINDS);
  switch (kind) {
    case "row": {
      // (what it says changed, where it is not)
      const now = { ...row, title: `改了 ${Math.floor(r() * 1000)}`, said: { n: row.said.n, other: r() < 0.5 ? row.said.n : row.said.n - 1 } };
      station.shared.set(row.id, now);
      s.push("chat-shared", now);
      break;
    }
    case "top":
      sharedSaid(station, s, row, r() < 0.5);
      break;
    case "tie":
      // (active at the very time another is: their ids say which is first)
      sharedSaid(station, s, row, false, pick(r, rows).lastActiveAt);
      break;
    case "new": {
      const id = `k-new-${Math.floor(r() * 1e9)}`;
      const now = { ...row, id, session: id, thread: 900_000 + Math.floor(r() * 1e5), lastActiveAt: s.host.nowMs() };
      station.shared.set(id, now);
      s.push("chat-shared", now);
      break;
    }
    case "removed":
      station.shared.delete(row.id);
      s.push("chat-shared-removed", { id: row.id });
      break;
    case "read":
      m.reads[String(row.thread)] = Math.max(m.reads[String(row.thread)] ?? 0, row.last.seq);
      s.push("read", { thread: row.thread, n: row.last.seq });
      break;
    case "pin": {
      const at = r() < 0.6 ? s.host.nowMs() : null;
      if (at === null) delete m.pins[row.id];
      else m.pins[row.id] = at;
      s.push("pin", { session: row.id, at });
      break;
    }
    case "kept":
    case "hidden":
    case "muted": {
      const on = r() < 0.5;
      m[kind] = [...m[kind].filter((x: number) => x !== row.thread), ...(on ? [row.thread] : [])];
      s.push(kind, { thread: row.thread, [kind]: on });
      break;
    }
    case "dismiss": {
      const waits = rows.filter((x) => (x.card ?? x.need) !== undefined);
      if (waits.length === 0) return anySharedChange(station, s, r);
      const row = pick(r, waits);
      const c = row.card ?? row.need;
      if (!m.dismissed.includes(`${row.thread}:${c.seq}`)) m.dismissed.push(`${row.thread}:${c.seq}`);
      s.push("dismiss", { thread: row.thread, n: c.seq });
      break;
    }
    case "said": {
      // (what was said, told before its row is: the marks of its chat read again)
      const t = station.threads.get(row.thread);
      if (t === undefined) return anySharedChange(station, s, r);
      m.reads[String(row.thread)] = Math.max(0, (m.reads[String(row.thread)] ?? 0) - 1);
      said(station, s, t, true, "我看看");
      break;
    }
    case "marked":
      m.reads[String(row.thread)] = row.last.seq - 1;
      if (r() < 0.5) m.pins[row.id] = s.host.nowMs();
      s.push("chat-mark", { session: row.id, thread: row.thread });
      break;
    case "renamed":
      m.kept = r() < 0.5 ? [...m.kept.filter((x: number) => x !== row.thread), row.thread] : m.kept.filter((x: number) => x !== row.thread);
      s.push("chat-changed", { thread: row.thread });
      break;
    case "summary":
    case "turn": {
      const key = station.sessions.has(row.id) ? row.id : pick(r, [...station.sessions.keys()]);
      summary(station, s, key, kind === "summary" ? { process: pick(r, ["cold", "warm", "running"]) } : { lastTurn: { id: `turn-${Math.floor(r() * 1e6)}`, kind: "chat", outcome: "done", declared: "block", ending: "need_help", need: "要你看一下", detail: null, startedAt: s.host.nowMs() - 60_000, endedAt: s.host.nowMs() } });
      if (kind === "turn" && key === row.id) m.dismissed = m.dismissed.filter((d: string) => !d.startsWith(`${row.thread}:`));
      break;
    }
    case "whole":
      m.selves = r() < 0.5 ? ["U04A1B2C3D4"] : ["U04A1B2C3D4", "U05J9K0L1M2"];
      if (r() < 0.5) m.hidden = m.hidden.slice(1);
      s.push("chat-changed", { thread: null });
      break;
    case "reconnect":
      // (its stream ends, and the next is not one that goes on from it: the station read again)
      s.end();
      break;
  }
  return kind;
}

// ── what one change makes the core do ──

/// What a change made the core do: rows made, serialised; chat records' JSON read; and what it only looked at
/// (work.ts `glanced`, each by its name).
export type Did = { made: number; serialised: number; chatJson: number; glanced: Record<keyof typeof glanced, number> };

/// Counts the rows of the chat table's JSON the core's database reads.
function counting(s: Started): () => number {
  const sql = s.core.inner.data.of(ST)!.sql as J;
  const all = sql.all.bind(sql);
  let rows = 0;
  sql.all = (q: string, params?: unknown[]) => {
    const out = all(q, params);
    if (/^\s*SELECT\b/i.test(q) && /\b(FROM|JOIN) chat\b/.test(q) && /\bjson\b/.test(q)) rows += out.length;
    return out;
  };
  return () => rows;
}

/// The `i`th row of the list a station makes (the same at every size).
const nth = (station: Station, i: number): J => [...station.shared.values()][i];

/// The changes a station that makes its list tells, measured one at a time: each of one row.
export const SHARED_PROBES: Record<string, (station: Station, s: Started, r: () => number) => void> = {
  // (what a row says changed, where it is)
  "row changed": (station, s) => {
    const row = { ...nth(station, 6), title: "迁移演练" };
    station.shared.set(row.id, row);
    s.push("chat-shared", row);
  },
  // (a new message: what was said, then its row on top)
  "row on top": (station, s) => sharedSaid(station, s, nth(station, 8), false),
  "row new": (station, s) => {
    const row = { ...nth(station, 3), id: "k-probe-new", session: "k-probe-new", thread: 990_001, lastActiveAt: s.host.nowMs() };
    station.shared.set(row.id, row);
    s.push("chat-shared", row);
  },
  "row removed": (station, s) => {
    const id = nth(station, 12).id;
    station.shared.delete(id);
    s.push("chat-shared-removed", { id });
  },
  "read": (station, s) => {
    const row = nth(station, 10);
    station.marks.reads[String(row.thread)] = row.last.seq;
    s.push("read", { thread: row.thread, n: row.last.seq });
  },
  "pin": (station, s) => {
    const id = nth(station, 14).id;
    station.marks.pins[id] = s.host.nowMs();
    s.push("pin", { session: id, at: s.host.nowMs() });
  },
  "hidden": (station, s) => {
    const thread = nth(station, 15).thread;
    station.marks.hidden.push(thread);
    s.push("hidden", { thread, hidden: true });
  },
  "muted": (station, s) => {
    const thread = nth(station, 16).thread;
    station.marks.muted.push(thread);
    s.push("muted", { thread, muted: true });
  },
  "kept": (station, s) => {
    const thread = nth(station, 17).thread;
    station.marks.kept.push(thread);
    s.push("kept", { thread, kept: true });
  },
  "dismiss": (station, s) => {
    const row = [...station.shared.values()].find((x) => x.card !== undefined)!;
    station.marks.dismissed.push(`${row.thread}:${row.card.seq}`);
    s.push("dismiss", { thread: row.thread, n: row.card.seq });
  },
  // (a person's message told before its row: the marks of its chat read again)
  "said": (station, s) => said(station, s, station.threads.get(nth(station, 20).thread)!, true),
  "marked": (station, s) => {
    const row = nth(station, 22);
    station.marks.reads[String(row.thread)] = row.last.seq - 1;
    s.push("chat-mark", { session: row.id, thread: row.thread });
  },
  "renamed": (station, s) => s.push("chat-changed", { thread: nth(station, 24).thread }),
  // (a session's summary: no row of the list reads it)
  "summary": (station, s) => summary(station, s, nth(station, 26).id, { process: "running" }),
  "turn": (station, s) => summary(station, s, nth(station, 27).id, { lastTurn: { id: "turn-new", kind: "chat", outcome: "done", declared: "block", ending: "need_help", detail: null, startedAt: 1, endedAt: 2 } }),
  // (whole: all the marks read again, whose rows they are changed; the station read again)
  "whole": (station, s) => {
    station.marks.selves = ["U04A1B2C3D4", "U05J9K0L1M2"];
    s.push("chat-changed", { thread: null });
  },
  "reconnect": (_, s) => s.end(),
};
/// Of those, what is read whole, and so looks at the whole list.
export const SHARED_WHOLE = new Set(["whole", "reconnect"]);
/// How long a change is given to be taken: a stream ended opens again after its retry (3 s) and reads all again.
export const settled = (kind: string): number => (kind === "reconnect" ? 6000 : 1500);

/// Each probe on one core, in turn, with what it did, and whether the list stored was what is made anew after each.
export async function probed(): Promise<{ chats: number; did: Record<string, Did>; differ: string[] }> {
  const station = new Station();
  const s = await startedOn(station);
  const chatJson = counting(s);
  const differ: string[] = [];
  const did: Record<string, Did> = {};
  const r = seeded(7);
  for (const [name, probe] of Object.entries(SHARED_PROBES)) {
    const from = { made: work.chatRowsMade, serialised: work.chatRowsSerialised, chatJson: chatJson(), glanced: { ...glanced } };
    probe(station, s, r);
    // (the station read again: all of it)
    await s.host.time.pass(settled(name), 100);
    const looked = Object.fromEntries(Object.entries(glanced).map(([k, n]) => [k, n - from.glanced[k as keyof typeof glanced]])) as Did["glanced"];
    did[name] = { made: work.chatRowsMade - from.made, serialised: work.chatRowsSerialised - from.serialised, chatJson: chatJson() - from.chatJson, glanced: looked };
    const expected = SHARED_WHOLE.has(name) ? madeFromStation(station) : madeAnew(s, station);
    for (const d of differences(stored(s), expected)) differ.push(`${name}: ${d}`);
  }
  const chats = stored(s).length;
  s.core.close();
  return { chats, did, differ };
}

/// What the first whole write of a list its station makes did to a device that held it in the places of before (as
/// placesFor gave them: its rows' order as numbers), on a core started anew there after an update: the records put
/// whole, the places written alone, the rows kept beside them that went, the chats' JSON read; and whether what is
/// stored is then what is made anew (its places as sharedPlace says).
export async function movedOnce(): Promise<{ chats: number; put: number; placed: number; keptBefore: number; keptAfter: number; chatJson: number; differ: string[] }> {
  const station = new Station();
  const s = await startedOn(station);
  const sql = s.core.inner.data.of(ST)!.sql as J;
  const ids = stored(s).map((r) => r.id);
  // (the places of before, and a row kept beside each record as a list keeps the rows it shows: db/kept.ts listRow;
  // an older core before sharedPlace also has no shared_sidecar/shared_meta/shared_mark baseline)
  ids.forEach((id, i) => sql.run("UPDATE chat SET ord = ? WHERE station = ? AND archived = 0 AND id = ?", [i, ST, id]));
  sql.run("DELETE FROM shared_sidecar WHERE station = ?", [ST]);
  sql.run("DELETE FROM shared_meta WHERE station = ?", [ST]);
  sql.run("DELETE FROM shared_mark WHERE station = ?", [ST]);
  sql.run("INSERT OR REPLACE INTO chat_row (station, id, key, state, whole, sent) SELECT station, id, 'k', NULL, '{}', '{}' FROM chat WHERE station = ? AND archived = 0", [ST]);
  const kept = () => sql.all("SELECT count(*) FROM chat_row WHERE station = ?", [ST])[0][0] as number;
  const keptBefore = kept();
  s.core.close();
  assert(differences(stored(s), madeAnew(s)).length > 0, "held in the places of before");
  let put = 0;
  let placed = 0;
  let chatJson = 0;
  // (the device's databases as the host keeps them: what a core started anew opens)
  for (const db of s.host.sqls.values() as Iterable<J>) {
    const run = db.run.bind(db);
    const all = db.all.bind(db);
    db.run = (q: string, params?: unknown[]) => {
      if (/^INSERT (OR REPLACE )?INTO chat \(/.test(q)) put++;
      if (/^UPDATE chat SET ord = /.test(q)) placed++;
      return run(q, params);
    };
    db.all = (q: string, params?: unknown[]) => {
      const out = all(q, params);
      if (/^\s*SELECT\b/i.test(q) && /\b(FROM|JOIN) chat\b/.test(q) && /\bjson\b/.test(q)) chatJson += out.length;
      return out;
    };
  }
  const core = await Core.create(s.host, { clock: s.host.time.clock, sample: 0, wire: () => new HostWire(s.host) });
  await s.host.time.pass(3000, 100);
  const again = { ...s, core };
  const out = { chats: ids.length, put, placed, keptBefore, keptAfter: kept(), chatJson, differ: differences(stored(again), madeAnew(again)) };
  core.close();
  return out;
}

/// A real cold restart with the SQLite sidecar baseline intact and 1 shared row changed on the station while offline:
/// verifies `POST /changed/shared` + `GET /chats?marks=1&own=1` reconcile in O(1) without calling `GET /chats?shared=1`
/// and converge to independent station ground truth (`madeFromStation`).
export async function coldDeltaOnce(): Promise<{
  chats: number;
  changedSharedCalls: number;
  wholeSharedCalls: number;
  marksOwnCalls: number;
  made: number;
  serialised: number;
  put: number;
  chatJson: number;
  glanced: Record<string, number>;
  differ: string[];
}> {
  const station = new Station();
  const s = await startedOn(station);
  const chats = stored(s).length;
  s.core.close();
  // Mutate exactly 1 shared row on the station while the client is closed (leaving SQLite sidecar baseline intact).
  const target = nth(station, 6);
  const updated = {
    ...target,
    title: "冷启动增量标题",
    named: { ...(target.named ?? {}), thread: { ...(target.named?.thread ?? {}), title: "冷启动增量标题" }, firstText: null },
  };
  station.shared.set(updated.id, updated);
  const changedSharedBefore = station.changedSharedCalls;
  const wholeSharedBefore = station.wholeSharedCalls;
  const marksOwnBefore = station.marksOwnCalls;
  const madeBefore = work.chatRowsMade;
  const serialisedBefore = work.chatRowsSerialised;
  const glancedBefore = { ...glanced };
  let put = 0;
  let chatJson = 0;
  for (const db of s.host.sqls.values() as Iterable<J>) {
    const run = db.run.bind(db);
    const all = db.all.bind(db);
    db.run = (q: string, params?: unknown[]) => {
      if (/^INSERT (OR REPLACE )?INTO chat \(/.test(q)) put++;
      return run(q, params);
    };
    db.all = (q: string, params?: unknown[]) => {
      const out = all(q, params);
      if (/^\s*SELECT\b/i.test(q) && /\b(FROM|JOIN) chat\b/.test(q) && /\bjson\b/.test(q)) chatJson += out.length;
      return out;
    };
  }
  const core = await Core.create(s.host, { clock: s.host.time.clock, sample: 0, wire: () => new HostWire(s.host) });
  await s.host.time.pass(3000, 100);
  const again = { ...s, core };
  const looked = Object.fromEntries(
    Object.entries(glanced)
      .map(([k, n]) => [k, n - glancedBefore[k as keyof typeof glanced]])
      .filter(([, n]) => n !== 0),
  );
  const out = {
    chats,
    changedSharedCalls: station.changedSharedCalls - changedSharedBefore,
    wholeSharedCalls: station.wholeSharedCalls - wholeSharedBefore,
    marksOwnCalls: station.marksOwnCalls - marksOwnBefore,
    made: work.chatRowsMade - madeBefore,
    serialised: work.chatRowsSerialised - serialisedBefore,
    put,
    chatJson,
    glanced: looked,
    differ: differences(stored(again), madeFromStation(station)),
  };
  core.close();
  return out;
}

if (!isMainThread && (workerData as J)?.rowsChanged === true) {
  const mode = (workerData as J).coldDelta === true ? coldDeltaOnce() : (workerData as J).moved === true ? movedOnce() : probed();
  mode.then((found) => parentPort!.postMessage({ size: SIZE, ...found }), (e) => parentPort!.postMessage({ error: String(e?.stack ?? e) }));
}
