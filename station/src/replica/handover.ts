// One chat handed from this station to another of its workspace while both are up (the owner, 2026-11-14: a
// whole-station move is every chat handed over, then its connects and logins; the reverse hand-over is the way back;
// replica/AGENTS.md). The unit: a session, its agent, its room and transcripts, with the threads it takes part in, and
// the sessions that share its still.fail home chat with it. A platform thread is routed per connect, so two bots'
// sessions in one Slack thread move each on its own, and each station keeps its own copy of that thread's log.
//
// Driven by the station that has it (A), each step said to the one that takes it (B) by `handover.*`, each side's state
// in a file of its own (`handover/out/<id>.json`, `handover/in/<id>.json`: a file a hand-over, written whole, as
// retire.ts keeps its own; no table, so nothing of it is in the copies' export or the schema), so that either started
// again goes on, or undoes what it put in:
// 1. checks, refused in words that say what to do (`check`);
// 2. the chat held here (sessions/hub.ts `holdChat`): its turn not cut (a busy one refused, or waited for), no new one,
//    its process ended, its jobs stopped and kept (what the jobs module starts there, move/jobs.ts); what is said to it
//    meanwhile is kept in its threads' logs, delivered where it ends up;
// 3. its files gathered alone (carry.ts `gatherSoon` with its keys, a scratch of its own), what B lacks sent
//    (sending.ts), each checked by its hash there, placed (what B made kept, to take away where it fails);
// 4. its rows sent a bounded page at a time (store/handover.ts), put in through B's store, hidden (`comingWs`);
// 5. B counts what it has; A compares; only then A says it went (store `handOff`, durably, before anyone is told),
//    sends what was said meanwhile (its logs' rest, its threads' platforms' events waited for), tells B to show it, and
//    re-points each of its platform threads where the connect runs (connects/workspace.ts `route`).
// A failure before A said it went: B takes out what it put in, the chat goes on here, its jobs started again. After,
// nothing is undone: A tells B again until it answers (on start, on failure with a backoff; never polled).
// Nothing is posted in its threads nor said in the chat; its agent is told once as its next turn starts (moved_notes).
import { createHash, randomBytes } from "node:crypto";
import { createReadStream, readFileSync, readdirSync } from "node:fs";
import { appendFile, link, lstat, mkdir, open, readFile, readdir, realpath, rename, rm, rmdir, stat, statfs, writeFile } from "node:fs/promises";
import { uptime } from "node:os";
import { createInterface } from "node:readline";
import { basename, dirname, isAbsolute, join, relative, sep } from "node:path";
import { type Bytes, Refused, bytesOf, withBytes } from "../mesh/bus.ts";
import { stopBytes } from "../mesh/files.ts";
import { type Fibers, wall } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { PREVIOUS_LIMIT_MS } from "../ops/previous.ts";
import { knownOf } from "../connects/remote.ts";
import type { Described, Known } from "../connects/remote.ts";
import { CHAT_TABLES, BY_N, MARKS, USAGE_TABLES, type ChatTable, type Counts, type HandedUsage, type ImportCtx, afterOf, handedStations, handedWithUsage, hasUsage, importHandedUsage, newCtx, threadOfRef, threadRefs, type ThreadRef } from "../store/handover.ts";
import { usageNow } from "../read/usage.ts";
import type { Store } from "../store/store.ts";
import type { SessionRow } from "../store/rows.ts";
import { STILLFAIL_SURFACE, comingWs, handedWs } from "../store/rows.ts";
import { type CarriedJob, type CarryIndex, type Gathered, carriedPlace, cliKept, listFile } from "./carry.ts";
import { HASH, STATION, WORKSPACE } from "./format.ts";
import type { Ask } from "./peers.ts";
import { Gone, type Need, Said, UNANSWERED, sayOf } from "../move/module.ts";
import type { KeptSend } from "../api/admin.ts";
import { LACK_MOST, type MadeGit, RETRY_MOST_MS, RETRY_MS, connectsThere, gatherSoon, placeSoon, rebuildGits } from "./retire.ts";
import { PACK_ENCODING, flushOnce, flushesOnce, lackingIn, receiveFile, receivePack, sendGathered } from "./sending.ts";
import { carriedTo, moved } from "./restore.ts";
import type { Told } from "../move/told.ts";
import { stationLang, tr } from "../ops/i18n.ts";

type Json = any;

/// How long a hand-over waits for a busy chat's turn to end, where it was asked to wait.
export const TURN_WAIT_MS = 10 * 60_000;

/// What `handover.begin` answers where several tables' pages go in one `handover.rows` (`tables`), and the most rows
/// one request takes in all, as one page of a table takes.
export const ROWS_BATCHED = "batched";
export const ROWS_MOST = 500;

/// What a chat's station sends after it was shown where it went: what was said there meanwhile, and what its agents
/// were counted to have spent as it went (the usage counter reads a transcript a while after its turn ended).
const AFTER_SHOWN: readonly ChatTable[] = ["entries", "letters", "deliveries", ...USAGE_TABLES];

/// Why a chat cannot go to station `name`: a chat of its key is live there (`keys`), one that went on there apart from
/// this one (the copy a retirement taken back left there, 2026-11-14): never merged into, whichever had more.
export const liveHereWords = (_keys: readonly string[], name: string) => why("liveThere", { station: name });

/// Why a hand-over did not go, in the station's language (`station.move.why.*`): every reason the chat's failure gives.
const why = (key: string, args: Record<string, unknown> = {}) => tr(stationLang(), `station.move.why.${key}`, args);

/// What carrying a chat's files failed of, in the station's words (`station.move.why.*`), what happened and what to do:
/// what a person can act on of its own (a file this station cannot read, no room left), the other station not
/// answering as they went (its connection gone, no answer, no answer in time), else that they could not be carried;
/// what the other station said, or the move's own words, as they are. The error as it came is the log's alone.
const carryWords = (e: unknown): Error => {
  // (the other found gone as its files went, `#ask`'s: said as what it means here)
  if (e instanceof Gone) return new Said(why("carryUnanswered"));
  if (e instanceof Refused || e instanceof Said) return e;
  const err = e as NodeJS.ErrnoException;
  if (err?.code === "EACCES" || err?.code === "EPERM") return new Said(why("cannotRead", { path: err.path ?? "", count: 1 }));
  if (err?.code === "ENOSPC") return new Said(why("noSpace"));
  const cause = err?.message ?? String(e);
  log.warn("handover", "a chat's files could not be carried", { error: cause, code: err?.code ?? null });
  // (mesh/peer.ts PeerGone says its connection was gone and the request got no answer)
  return new Said(why(UNANSWERED.test(cause) ? "carryUnanswered" : "carryFailed"));
};

/// What a session's account is known by across the workspace: the share it is a copy of or the host of (`share`), the
/// key it runs with (`key`, a hash of it), or a login not shared, by its id where it is (`own`: `<id>@<station>`, the
/// id it keeps where it moves); null: this machine's own login, which cannot be had elsewhere.
export type AccountOf = { share?: string; key?: string; own?: string; name: string };

/// A step of a hand-over on the station it leaves:
/// - `held`: checked and held, its jobs stopped and kept;
/// - `files`, `rows`: being sent;
/// - `gone`: it went (B counted what it has); B is told the rest and to show it, its threads re-pointed (`told`);
/// - `failed`: it did not go, and goes on here (B is told to take out what it put in, `dropOwed`);
/// - `done`: it is there, and every thread re-pointed.
export type OutStep = "held" | "files" | "rows" | "gone" | "failed" | "done";
export type Out = {
  id: string; keys: string[]; to: string; toName: string; ws: string; at: number; step: OutStep; error: string | null;
  jobs: CarriedJob[]; dropOwed: boolean;
  /// Of each thread (by its id here): the last entry and letter sent; and what B said it has.
  sent: Record<string, { entries: number; letters: number }>; counts: Counts | null;
  /// Each session's home thread here and there (B's answer), its threads' platforms' (connect, channel, ts), and those
  /// re-pointed already.
  there: Record<string, { thread: number | null; there: number | null }>; routes: { connect: string; channel: string; threadTs: string }[]; routed: number;
  /// Whether B showed it; and whether what was taken here between its rows' last sending and its going out of sight
  /// here (`shownThere`) was sent after it and B took it up (`caught`).
  shown: boolean; caught?: boolean;
  /// Its chat came back here since (`#endOuts`): over for good, nothing of it replayed or told. `v`: written by a station
  /// that ends its records so (2); one of before is judged by whether its chat came back (`#cameBack`).
  ended?: boolean; v?: 2;
  /// What was sent and placed of its files (bytes), for the status; of them, the bytes of the room's own files that
  /// went (what was in place there already did not).
  done: number; total: number; sentBytes?: number;
  /// How far its placing there is (files), as that station tells it (move/told.ts): while its files are placed.
  placing?: { done: number; total: number };
  /// The told step there it waits on now (move/told.ts), let go as it is given up (`abandon`).
  waitsOn?: string;
  /// When each of its steps began (the station's clock, the wall's: a step of that clock as it runs skews one step's ms,
  /// which a log line can bear), in order: `begin`, `first` (the first pass's gathering and sending),
  /// `turn`, `hold`, `held` (the held pass), `rows`, `counts`, `gone`: what its line at gone says each took; then `show`
  /// (asked there to show it, to its answer) and `done`, kept for whoever reads the record.
  began?: Record<string, number>;
  /// Whether the chat is held: not while its files go a first time, the chat working (`handOver`); none said: held
  /// (one from before there were two passes).
  held?: boolean;
  /// The move it is part of was asked to stop: given up at its next step, until it is gone (`abandon`).
  abandoned?: boolean;
  /// The station it goes to takes its calls (`handover.begin`'s `usage`): they go with its rows; and each session's last
  /// call sent (its `at` and id), what is sent after it.
  usage?: boolean; usageSent?: Record<string, [number, string] | null>;
  /// The station it goes to takes several tables' pages in one request (`handover.begin`'s `rows: "batched"`): a small
  /// chat's rows go in a request or two, not one a table (real run, 2026-11-20: a chat of 3 entries held 30 s toward a
  /// busy station, a dozen round trips of 2-3 s each).
  batched?: boolean;
};
/// A step of one on the station it goes to: being put in (`coming`), shown (`shown`), taken out (`dropped`).
/// `stoppedFor`: it arrives stopped, waiting for that; `bindings`: the single-session connects (as known here) bound to
/// its sessions.
export type In = { id: string; origin: string; keys: string[]; ws: string; at: number; step: "coming" | "shown" | "dropped"; ctx: ImportCtx; carry: string | null; error: string | null; stoppedFor?: Need | null; bindings?: Record<string, string>;
  /// What answering it took here (the clock's ms), by request (`begin`, `lacking`, `put`, `place`, `rows`, `prune`,
  /// `counts`, `show`), each request of a kind added: what its line says it took.
  spent?: Record<string, number>;
  /// The last page of rows taken (`handover.rows`'s `page`): the same page asked again (its answer lost on the way,
  /// its sender's process or this one's stopping as it went: mesh/peer.ts PeerStopped) is answered as taken, not
  /// counted twice.
  page?: string;
  /// Its drop was asked (`handover.drop`, or a newer hand-over of the chat begun): its rows taken out as it was asked,
  /// nothing more of it taken, its files taken out after what it was doing to them; one this station's process stopped
  /// before that ended is ended as the next starts.
  dropping?: boolean;
  /// When this machine started, as it began here (`bootHere`): one still coming as it starts under another boot is
  /// dropped (`#load`); none, one begun by a station from before, its files flushed one by one.
  boot?: number };

/// What a hand-over's steps took (ms), from when each began to when the next did, the last to `end`; and the whole.
function tookOf(began: Record<string, number> | undefined, end: number): { ms: Record<string, number>; total: number } {
  const steps = Object.entries(began ?? {});
  const ms: Record<string, number> = {};
  steps.forEach(([step, at], n) => void (ms[step] = Math.round((n + 1 < steps.length ? steps[n + 1]![1] : end) - at)));
  return { ms, total: steps.length === 0 ? 0 : Math.round(end - steps[0]![1]) };
}

export type HandoverDeps = {
  data: string;
  here: () => string | null;
  home: () => string | null;
  /// The whole stations of `ws` with their names (null while not current).
  roster: (ws: string) => { id: string; name: string; tasks?: boolean }[] | null;
  ask: Ask;
  fibers: Fibers;
  store: Store;
  /// The hub (sessions/hub.ts): a chat held one at a time and let go, its turn's state, what a thread's platform said
  /// waited for, a chat woken, a connect's surface.
  hub: {
    holdChat(key: string, why: string, notice?: () => string): Promise<void>;
    releaseChat(key: string): boolean;
    wakeChat(key: string): void;
    busy(key: string): boolean;
    /// Once its turn ended (at once where none runs).
    turnEnded(key: string): Promise<void>;
    drained(connect: string, channel: string, threadTs: string): Promise<void>;
    wsOf(key: string | SessionRow): string | null;
  };
  /// The workspace's connects (connects/workspace.ts): a thread re-pointed where its connect runs, what one says of
  /// itself and where it runs, learnt from another station, and how one goes (null: not known here).
  connects: {
    route(id: string, channel: string, threadTs: string, station: string): Promise<void>;
    describedFor(id: string): { station: string; described: Described } | null;
    learnOf(known: Known, station: string, described: Described): void;
    kindOf(id: string): { kind: string; mode: string } | null;
    own(): string[];
    /// The station connect `id` runs on (null: this one, or not known).
    runsOn(id: string): string | null;
  } | null;
  /// The jobs of sessions here up now (with what it takes to run them again), and stopping them; one started again
  /// here (a hand-over that failed).
  jobs: { of(keys: string[]): CarriedJob[]; stop(keys: string[], why: string): Promise<void>; start(job: CarriedJob): void };
  /// What a profile here is known by elsewhere (null: none here), and the profile here of one so known (null: none).
  /// `present`: whether profile `id` is one of this station's (in its config): one that is not is a login of no
  /// station's to its chats unless the station they go to has it (the plan's rule, move/accounts.ts), no need of them.
  accounts: { of(id: string): AccountOf | null; here(a: AccountOf): string | null; present?(id: string): boolean };
  reposDir: string;
  room?: () => Promise<{ free: number | null; total?: number | null }>;
  hasGit?: () => Promise<boolean>;
  /// What a placing here took written out to the drive, once, before it says it placed it (sending.ts `flushOnce`);
  /// null: no such flush here (Windows), each file flushed as it is taken.
  flush?: ((dir: string) => Promise<void>) | null;
  /// When this machine started (wall ms; none: `bootHere`), a test's another.
  boot?: () => number;
  git?: (dir: string, args: string[]) => Promise<string>;
  lackMost?: number;
  /// The most bytes one `handover.lacking` hashes here (HASH_MOST; a test's smaller).
  hashMost?: number;
  /// The most files and bytes of one pack sent from here (sending.ts PACK_MAX_FILES, PACK_MAX_BYTES; a test's smaller).
  packMost?: { files?: number; bytes?: number };
  /// The work done here of a hand-over's files: gathered, placed; `drop`, a test's: waited for before a drop takes its
  /// files out.
  work?: { gather: typeof gatherSoon; place: typeof placeSoon; drop?: (id: string) => Promise<void> };
  /// The steps asked of another station that are told back, and those it asks of this one (move/told.ts).
  told: Told;
  /// Told as a hand-over's state changes (the scheduler, move/).
  changed?: (id: string) => void;
  /// A chat that arrived here stopped, waiting for `need` (move/scheduler.ts `noteStopped`), held before it is shown.
  arrivedStopped?: (keys: string[], need: Need & { label?: string; at?: string }, ws: string) => Promise<void>;
  /// The messages written under a client's key to these threads here, each to its thread there (api/admin.ts
  /// `keptSends`), and those of a chat handed here kept as if written here (`keepSends`).
  keptSends?: (threads: ReadonlyMap<number, number>) => KeptSend[];
  keepSends?: (sends: readonly KeptSend[]) => void;
  /// What keeps the station from updating itself while a chat comes here (updates/holds.ts `hold`): its let-go.
  hold?: () => () => void;
  /// Chats `keys` shown here (what their connect kept for them while they were on their way, taken: move/station.ts).
  shown?: (keys: string[], from?: string) => Promise<void> | void;
  /// Chats `keys` went from here (`gone`): what kept them stopped here is no longer this station's (the scheduler's
  /// stopped set): one that comes back is stopped anew as it arrives.
  went?: (keys: string[]) => Promise<void> | void;
  /// The single-session connects bound to sessions here (store `binding`), by connect.
  bindingsOf?: (keys: string[]) => Record<string, string>;
  /// For a test: a step's failure made there (`files`, `rows`, `counts`, `show`; taking: `put`, `import`).
  fail?: (step: string) => void | Promise<void>;
  /// The station process this one took over from gone (ops/previous.ts `previousExited`): until then this one acts on
  /// no hand-over, begins none and answers none of another station's (none: no process before it).
  previous?: Promise<void>;
  /// That process's pid, for what is said of it while it is waited for.
  previousPid?: number | null;
};

const dir = (data: string) => join(data, "replica", "handover");
/// When this machine started (wall ms).
const bootHere = () => wall.now() - uptime() * 1000;
/// Two boots this close are one (the wall clock is set as it runs; a machine never starts again that soon).
const BOOT_SLACK_MS = 60_000;
const outFile = (data: string, id: string) => join(dir(data), "out", `${id}.json`);
const inFile = (data: string, id: string) => join(dir(data), "in", `${id}.json`);
const inFiles = (data: string, id: string) => join(dir(data), "in", id, "files");
/// How a hand-over from here ended, decided once (`decided`): gone, or failed.
const endFile = (data: string, id: string) => join(dir(data), "out", `${id}.end`);

/// The one end of hand-over `id`, whichever process asks first: `want` where none was decided yet, else the one that was.
/// A file linked into place (link fails where one is there): two processes of this station never both decide, so
/// `gone` never follows a failure of the same hand-over, nor a failure its `gone` (the real run, 2026-11-15: the next
/// process failed a hand-over the one before was still running, which then said it went; the chat on neither station).
async function decided(data: string, id: string, want: "gone" | "failed"): Promise<"gone" | "failed"> {
  const path = endFile(data, id);
  await mkdir(dirname(path), { recursive: true });
  const tmp = `${path}.${randomBytes(4).toString("hex")}.tmp`;
  await writeFile(tmp, want);
  try {
    await link(tmp, path);
    return want;
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code !== "EEXIST") throw e;
    const was = (await readFile(path, "utf8").catch(() => "")).trim();
    return was === "gone" ? "gone" : "failed";
  } finally {
    await rm(tmp, { force: true });
  }
}

const inMade = (data: string, id: string) => join(dir(data), "in", id, "made.txt");
/// What was here that a hand-over coming in replaced or pruned, kept until it is shown (put back where it is dropped).
const inAside = (data: string, id: string) => join(dir(data), "in", id, "aside");
/// The linked worktrees git made for a hand-over coming here, a line each (retire.ts `MadeGit`).
const inGits = (data: string, id: string) => join(dir(data), "in", id, "gits.jsonl");
const scratch = (data: string, id: string) => join(dir(data), "out", id);
/// How far the calls of the chats handed from here before their calls went with them were sent, by the station they
/// went to: the last session sent (`#syncHandedUsage`).
const usageSyncedFile = (data: string) => join(dir(data), "usage-synced.json");

async function writeJson(path: string, v: unknown): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  const tmp = `${path}.${randomBytes(4).toString("hex")}.tmp`;
  await writeFile(tmp, JSON.stringify(v));
  await rename(tmp, path);
}

function readAll<T>(at: string): T[] {
  let names: string[] = [];
  try {
    names = readdirSync(at); // sync: read once, before the station serves
  } catch {}
  const out: T[] = [];
  for (const name of names) {
    if (!name.endsWith(".json")) continue;
    try {
      out.push(JSON.parse(readFileSync(join(at, name), "utf8")) as T); // sync: read once, before the station serves
    } catch {}
  }
  return out;
}

/// The most bytes one `handover.lacking` reads to hash what lies here where its time differs from what was sent: a request
/// is answered within 30 s (mesh/peer.ts ANSWER_MS), and a room left here by another station's copy has its files at
/// other times, so each is read whole (the rest is said `unchecked`, asked again). A file larger than it alone is not
/// read: said lacking, it is sent, a piece at a time.
export const HASH_MOST = 256 * 1024 ** 2;

/// The key of a told step a request names (move/told.ts): none from a station from before told steps, answered as
/// before, by its result.
const toldKey = (request: Json): string | null => (typeof request?.told === "string" && request.told.length > 0 && request.told.length <= 300 ? request.told : null);

const uncheckedOf = (answer: Json): string[] => (Array.isArray(answer?.unchecked) ? answer.unchecked.filter((h: unknown): h is string => typeof h === "string") : []);

/// What this station's disk failing a write it was sent is (full, over its quota, read-only): the hand-over's own end
/// here, told the asker in numbers.
const WRITE_FAILED = new Set(["ENOSPC", "EDQUOT", "EROFS"]);

export const roomHere = (data: string) => async () => {
  const s = await statfs(data).catch(() => null);
  return { free: s === null ? null : Number(s.bavail) * Number(s.bsize), total: s === null ? null : Number(s.blocks) * Number(s.bsize) };
};
const gb = (n: number) => `${(n / 1024 ** 3).toFixed(1)} GB`;

/// What a move leaves free on the station it goes to, at the least: the larger of FLOOR_MIN and FLOOR_SHARE of its
/// volume (`total`; one that does not say it, FLOOR_MIN). A station whose disk fills stops every chat on it, not only
/// those that came (its database, transcripts and jobs' output are written there), and what its chats build and log
/// is gigabytes a day: 1 GiB (retire.ts HEADROOM) was minutes of it. A tenth keeps a large disk's margin in proportion
/// (macOS itself purges and slows below about that).
export const FLOOR_MIN = 20 * 1024 ** 3;
export const FLOOR_SHARE = 0.1;
export const floorOf = (total: number | null | undefined) => Math.max(FLOOR_MIN, Math.floor((total ?? 0) * FLOOR_SHARE));

/// The hand-over's id: of when, its sessions and the station it goes to, and a part of its own (two of the same chat
/// to the same station in the same millisecond are two: the second was refused there as "shown already").
export const handoverId = (keys: string[], to: string, at: number) => `${at.toString(36)}-${Buffer.from(keys[0] ?? "").toString("hex").slice(0, 24)}-${to.slice(0, 8)}-${randomBytes(4).toString("hex")}`;

/// What `together`, `accountsOf` and `check` read of sessions: the store's, a statement each, or a page's read at once
/// (store.ts `SessionPage`, a plan's).
export type SessionReads = {
  session(key: string): SessionRow | null;
  /// The sessions of `key`'s still.fail home chat (null: it is the home of none).
  homeMembers(key: string): string[] | null;
  /// The accounts its runtime sessions ran on, in the order they are kept.
  ranOn(key: string): string[];
};

export class Handover {
  readonly #d: HandoverDeps;
  readonly #outs = new Map<string, Out>();
  /// Each session's hand-overs from here, the latest first (`outs`, by session).
  readonly #outsOf = new Map<string, Out[]>();
  readonly #reads: SessionReads;
  readonly #ins = new Map<string, In>();
  /// Each session's hand-overs coming here (`ins`, by session): what is done for one chat looks at its own records
  /// through these two, never at all a station keeps (a whole move back showed each chat slower by the chats back).
  readonly #insOf = new Map<string, In[]>();
  /// The hand-overs coming here not shown nor dropped yet (a few at a time), as each is kept and saved.
  readonly #comingIns = new Set<In>();
  /// The hand-overs from here with something owed to the station they went to (gone, or a drop owed), as each is kept
  /// and saved: what `reached` tells, as every request another station makes here says it is heard from.
  readonly #owedOuts = new Set<Out>();
  /// The records looked at so far by what looked (a test's count of what a hand-over reads, `looked`).
  readonly #looked = new Map<string, number>();
  /// The chats coming here, each holding the station's self-update until it is shown or dropped.
  readonly #inHeld = new Map<string, () => void>();
  /// What a hand-over coming here does to its files, one at a time (its placing, its pruning, its drop): a drop waits
  /// for the placing under way, so nothing it places is left after it.
  readonly #inWork = new Map<string, Promise<unknown>>();
  /// The hand-overs coming here whose drop was asked: from then on nothing more of them is taken (`#dropIn` may still
  /// wait for a placing under way).
  readonly #dropping = new Set<string>();
  readonly #runs = new Map<string, Promise<void>>();
  /// The hand-overs from here under way in this process (`handOver`, begun to its end, gone or stayed), by id.
  readonly #active = new Map<string, Out>();
  readonly #again = new Map<string, () => void>();
  readonly #tries = new Map<string, number>();
  readonly #work: NonNullable<HandoverDeps["work"]>;
  readonly #flush: ((dir: string) => Promise<void>) | null;
  /// The drops under way here, by hand-over: `marked` once its rows are out and its record says it drops, `files` once
  /// its files are out too.
  readonly #drops = new Map<string, { marked: Promise<void>; files: Promise<void> }>();
  #closed = false;

  /// Where each side stood, read before the station serves: a chat being handed over is held again before its agents
  /// are taken up.
  constructor(d: HandoverDeps) {
    this.#d = d;
    this.#work = d.work ?? { gather: gatherSoon, place: placeSoon };
    this.#flush = d.flush !== undefined ? d.flush : flushesOnce ? flushOnce : null;
    this.#reads = {
      session: (k) => d.store.getSession(k),
      homeMembers: (k) => d.store.stillfailHomes([k]).get(k) ?? null,
      ranOn: (k) => [...new Set(d.store.chatPage("runtime_sessions", k, null, 500).flatMap((r) => (typeof r.profile === "string" ? [r.profile as string] : [])))],
    };
    this.#load();
    // (a station process handing over to this one may still be acting on its hand-overs: nothing of them is acted on
    // here, nor a hand-over begun or answered, until it is gone, every record then read again as it left them)
    this.#loaded = d.previous === undefined ? Promise.resolve() : d.previous.then(() => this.#reload(), () => this.#reload());
    this.#ready = d.previous === undefined;
    void this.#loaded.then(() => void (this.#ready = true));
  }

  /// Gone (`previous`) and read again: what this process acts on of its hand-overs only once the one before it is gone.
  readonly #loaded: Promise<void>;
  #ready: boolean;
  /// The chats held as the records were read, by the records that held them.
  #heldAtLoad = new Set<string>();

  /// The records read: each hand-over's chats held again as it stood (before their agents are taken up).
  #load(): void {
    const d = this.#d;
    for (const o of readAll<Out>(join(dir(d.data), "out"))) this.#keepOut(o);
    const boot = (d.boot ?? bootHere)();
    for (const i of readAll<In>(join(dir(d.data), "in"))) {
      // (what its rows' pages put in, as kept with them: newer than its file where a stop came between the two)
      if (i.step === "coming") i.ctx = d.store.importCtx(i.id) ?? i.ctx;
      // (begun under another boot of this machine: what it took came unflushed, `flushOnce`, and may never have reached
      // the drive, its names whole and its bytes not: refused from now, dropped as this station starts)
      const rebooted = i.step === "coming" && i.dropping !== true && i.boot !== undefined && Math.abs(i.boot - boot) > BOOT_SLACK_MS;
      if (rebooted) {
        this.#rebooted.add(i.id);
        this.#dropping.add(i.id);
      } else if (i.step === "coming" && i.dropping !== true) this.#unsure.add(i.id);
      if (i.step === "coming" && i.dropping === true) this.#dropping.add(i.id);
      this.#keepIn(i);
      this.#holdIn(i);
    }
    const held = new Set<string>();
    for (const o of this.#everyOut("start")) if ((o.step === "held" || o.step === "files" || o.step === "rows") && o.held !== false) for (const key of o.keys) held.add(key);
    // (one that went and is not shown there yet, or went as this process stopped before its rows here said so: held
    // until `start` says so, or it is shown there)
    for (const o of this.#everyOut("start")) for (const key of this.#notOff(o)) held.add(key);
    for (const key of held) void d.hub.holdChat(key, `moving to ${this.#outsOf.get(key)?.[0]?.toName || this.#outsOf.get(key)?.[0]?.to.slice(0, 8) || ""}`);
    this.#heldAtLoad = held;
    this.#unmended.clear();
    for (const o of this.#outs.values()) {
      if (o.v === 2 && (o.step === "failed" || o.step === "gone") && !o.shown && o.ended !== true && o.keys.some((k) => this.#outsOf.get(k)?.[0] === o && d.store.handedTo(k)?.station === o.to)) this.#unmended.add(o);
    }
  }

  /// The records read again, the process before gone: what it moved on since is as it left it, and a chat held here
  /// for a record it ended meanwhile let go.
  #reload(): void {
    const before = this.#heldAtLoad;
    for (const letGo of this.#inHeld.values()) letGo();
    this.#inHeld.clear();
    this.#outs.clear();
    this.#outsOf.clear();
    this.#ins.clear();
    this.#insOf.clear();
    this.#comingIns.clear();
    this.#owedOuts.clear();
    this.#unsure.clear();
    this.#dropping.clear();
    this.#rebooted.clear();
    this.#load();
    for (const key of before) if (!this.#heldAtLoad.has(key)) this.#d.hub.releaseChat(key);
  }

  /// Begun (the mesh attached): each hand-over goes on where it stood. One cut before it went did not go: undone.
  /// The sessions of `o`, gone, still in sight here: not shown there yet, or shown and this process stopped before its
  /// rows here said so. A record of a trip is acted on only while its chat has not come here since from where it went
  /// (a hand-over from there shown here after this one began): one that came back is here, whatever the record says
  /// (a start hid every chat that went and came back, the drill of 2026-11-14).
  #notOff(o: Out): string[] {
    if (o.ended === true || (o.step !== "gone" && o.step !== "done")) return [];
    return o.keys.filter((k) => this.#d.store.getSession(k) !== null && this.#d.store.sessionWs(k)?.startsWith(handedWs("")) !== true && (o.v === 2 || !this.#cameBack(o, k)));
  }

  /// Whether chat `k` came here since `o` took it away, from where it went.
  #cameBack(o: Out, k: string): boolean {
    return this.#insAt([k], "cameBack").some((i) => i.step === "shown" && i.origin === o.to && i.at >= o.at);
  }

  async start(): Promise<void> {
    // (only once the process before is gone, every record read again as it left them: one process of this station
    // acts on a hand-over at a time)
    await this.#loaded;
    // (cut as this station stopped: failed, but one whose end was decided gone (the process before stopped between that
    // and saying so) went, what it went with kept before that)
    for (const o of this.#everyOut("start")) {
      if (o.step !== "held" && o.step !== "files" && o.step !== "rows") continue;
      if (o.counts !== null && (await decided(this.#d.data, o.id, "failed")) === "gone") {
        o.step = "gone";
        o.error = null;
        await this.#save(o);
        log.info("handover", "a chat went as this station stopped: it went", { id: o.id, to: o.to });
      } else await this.#fail(o, tr(stationLang(), "station.move.restartedMidway", { station: o.toName || o.to.slice(0, 12) }));
    }
    // (what was coming here under another boot of this machine: dropped, before anything of it is asked or answered)
    for (const id of this.#rebooted) {
      const i = this.#ins.get(id);
      if (i === undefined) continue;
      log.warn("handover", "a chat coming here was begun before this machine started again: what it took may not be on the drive: dropped here", { id: i.id, from: i.origin.slice(0, 12) });
      await this.#dropSoon(i).marked;
    }
    this.#rebooted.clear();
    // (what was being taken out here as this station stopped: taken out now)
    for (const i of [...this.#comingIns]) if (i.dropping === true) void this.#dropSoon(i);
    // (what was coming here as this station stopped: asked of where it came from whether it still goes on)
    for (const id of this.#unsure) {
      const i = this.#ins.get(id);
      if (i !== undefined) this.#askStill(i);
    }
    // (what was left to remove as a chat came here was shown, where this process stopped before it was gone)
    for (const name of await readdir(join(dir(this.#d.data), "in")).catch(() => [] as string[])) if (name.startsWith(".gone-")) void rm(join(dir(this.#d.data), "in", name), { recursive: true, force: true }).catch(() => {});
    // (gone, where it went said first, before anything else; shown there, out of sight here and let go as a hand-over
    // lets go once it is shown there; not shown yet, still held, its reads served here, until it is)
    for (const o of this.#everyOut("start")) {
      const off = this.#notOff(o);
      if (off.length === 0) continue;
      this.#d.store.goneTo(off, o.to, o.there);
      await this.#d.went?.(off);
      if (!o.shown) continue;
      this.#d.store.shownThere(off, this.#d.home());
      for (const k of off) this.#d.hub.releaseChat(k);
    }
    for (const o of this.#everyOut("start")) {
      // (one whose chat came back since is over: nothing of it is told any more, as its arrival ended it)
      if (o.step === "gone" && o.v !== 2 && o.keys.every((k) => this.#cameBack(o, k))) {
        o.step = "done";
        o.ended = true;
        await this.#save(o);
      } else if (o.step === "gone" || (o.step === "failed" && o.dropOwed)) this.#go(o);
    }
    void this.#mend();
    this.#syncHandedUsage();
  }

  /// Once the process before is gone and the records read again (`previous`), for what a person or another station
  /// waits for (a move turn, a request of theirs): PREVIOUS_LIMIT_MS at most on the station's clock, then refused in
  /// words, ask again (a pid `run/hub.json` names that another program has after a reboot would else hold every move
  /// for good, saying nothing). What this process acts on itself (its start, its records read again) waits as long as
  /// it takes.
  async loadedWithin(): Promise<void> {
    if (this.#ready) return;
    let late: () => void = () => {};
    const deadline = new Promise<"late">((resolve) => (late = this.#d.fibers.after(PREVIOUS_LIMIT_MS, () => resolve("late")))); // timer: a deadline for the process before to be gone
    const came = await Promise.race([this.#loaded.then(() => "loaded" as const), deadline]);
    late();
    if (came === "loaded") return;
    if (!this.#saidStill) {
      this.#saidStill = true;
      log.warn("handover", "the station process before this one is still there: moves are refused until it is gone", { pid: this.#d.previousPid ?? null, waitedMs: PREVIOUS_LIMIT_MS });
    }
    throw new Refused(tr(stationLang(), "station.move.previousStill"));
  }
  #saidStill = false;

  /// The chats this station says went to a station (`handed_over`) where their latest hand-over from here failed and was
  /// never shown there: asked of that station, which either holds it in sight (the record completed: it went) or does
  /// not (in sight here again, as a failure leaves it, said no more to be there). As this station starts, and as
  /// `only` is heard from. Only a v2 record that is its chat's latest from here: an older one whose chat went later by
  /// another hand-over, or came back, is over (the real run, 2026-11-15: a chat failed by this station's next process
  /// while the one before said it went, seen by neither station).
  async #mend(only?: string): Promise<void> {
    for (const o of [...this.#unmended]) {
      if ((only !== undefined && o.to !== only) || this.#mending.has(o.id)) continue;
      const keys = o.keys.filter((k) => this.#outsOf.get(k)?.[0] === o && this.#d.store.handedTo(k)?.station === o.to);
      if (keys.length === 0) {
        this.#unmended.delete(o);
        continue;
      }
      this.#mending.add(o.id);
      try {
        // (one said gone and not shown yet: only where that station says it does not hold the hand-over (it dropped
        // it, or never had it) is it looked at more; a show not answered yet, that station away or slow, is left to
        // its retries)
        if (o.step === "gone") {
          const held = await this.#d.ask(o.to, { method: "handover.held", workspace: o.ws, origin: this.#d.here(), id: o.id });
          if (held?.held !== false) {
            if (held?.held === true) this.#unmended.delete(o);
            continue;
          }
        }
        const answer = await this.#d.ask(o.to, { method: "move.chats.live", keys });
        const live = new Set<string>(Array.isArray(answer?.live) ? answer.live : []);
        const there = keys.filter((k) => live.has(k));
        const here = keys.filter((k) => !live.has(k));
        if (there.length > 0) {
          // (it is there: it went, as it was decided there)
          o.step = "done";
          o.shown = true;
          o.ended = true;
          o.error = null;
          o.dropOwed = false;
          await this.#save(o);
          this.#d.store.shownThere(there, this.#d.home());
          for (const k of there) this.#d.hub.releaseChat(k);
          log.info("handover", "a chat said gone whose hand-over failed here is there after all: it went", { id: o.id, to: o.to, keys: there.length });
        }
        if (here.length > 0) {
          if (o.step === "gone" && there.length === 0) {
            // (said gone, dropped there: it did not go. Over as a failure, told nothing more (`#go`), its jobs started
            // again as a failure starts them (kept ones only: one the next process already started again is not kept))
            this.#again.get(o.id)?.();
            this.#again.delete(o.id);
            o.step = "failed";
            o.error = tr(stationLang(), "station.move.restartedMidway", { station: o.toName || o.to.slice(0, 12) });
            o.ended = true;
            o.dropOwed = false;
            await this.#save(o);
            for (const j of o.jobs) {
              try {
                this.#d.jobs.start(j);
              } catch (e) {
                log.warn("handover", "a job of a chat taken back not started again", { job: j.name, error: (e as Error).message });
              }
            }
          }
          const back = this.#d.store.notGone(here, o.to);
          for (const k of back) this.#d.hub.releaseChat(k);
          log.warn("handover", "a chat said gone whose hand-over failed is not there: in sight here again", { id: o.id, to: o.to, keys: back.length });
        }
        this.#unmended.delete(o);
      } catch (e) {
        log.info("handover", "a chat said gone whose hand-over failed: its station not asked yet", { id: o.id, to: o.to, error: (e as Error).message });
      } finally {
        this.#mending.delete(o.id);
      }
    }
  }
  readonly #mending = new Set<string>();
  /// What `#mend` looks at, found as the records are read: few, each its chat's latest record from here.
  readonly #unmended = new Set<Out>();

  async close(): Promise<void> {
    this.#closed = true;
    for (const letGo of this.#inHeld.values()) letGo();
    this.#inHeld.clear();
    for (const done of [...this.#settledIn.values()].flat()) done();
    this.#settledIn.clear();
    for (const stop of this.#again.values()) stop();
    this.#again.clear();
    await Promise.all([...this.#runs.values(), ...this.#usageRuns.values()].map((p) => p.catch(() => {})));
  }

  /// What is under way brought to rest (a test's).
  async settle(): Promise<void> {
    for (;;) {
      await this.#d.told.settle();
      if (this.#runs.size === 0 && this.#drops.size === 0 && this.#usageRuns.size === 0) return;
      await Promise.all([...this.#runs.values(), ...this.#usageRuns.values(), ...[...this.#drops.values()].map((d) => d.files)].map((p) => p.catch(() => {})));
    }
  }

  /// The hand-overs from here, the latest of each chat first.
  outs(): Out[] {
    return [...this.#outs.values()].sort((a, b) => b.at - a.at);
  }

  /// A hand-over kept (`#outs`), and among its sessions' (`#outsOf`) by when it began, the latest first (one of the
  /// same time after those before it, as `outs` sorts them).
  #keepOut(o: Out): void {
    this.#outs.set(o.id, o);
    this.#owedNow(o);
    for (const k of o.keys) {
      const list = (this.#outsOf.get(k) ?? []).filter((x) => x.id !== o.id);
      const at = list.findIndex((x) => x.at < o.at);
      list.splice(at < 0 ? list.length : at, 0, o);
      this.#outsOf.set(k, list);
    }
  }
  ins(): In[] {
    return [...this.#ins.values()];
  }

  /// A hand-over coming here kept (`#ins`), and among its sessions' (`#insOf`).
  #keepIn(i: In): void {
    this.#ins.set(i.id, i);
    this.#comingNow(i);
    for (const k of i.keys) {
      const list = this.#insOf.get(k) ?? [];
      if (!list.includes(i)) list.push(i);
      this.#insOf.set(k, list);
    }
  }
  #forgetIn(i: In): void {
    this.#ins.delete(i.id);
    this.#comingIns.delete(i);
    for (const k of i.keys) {
      const list = (this.#insOf.get(k) ?? []).filter((x) => x.id !== i.id);
      if (list.length > 0) this.#insOf.set(k, list);
      else this.#insOf.delete(k);
    }
  }
  #comingNow(i: In): void {
    if (i.step === "coming") this.#comingIns.add(i);
    else this.#comingIns.delete(i);
  }
  /// Every hand-over from here (counted as looked at): for what is done once a start, a stop or a link opening.
  #everyOut(kind: string): Out[] {
    this.#look(kind, this.#outs.size);
    return [...this.#outs.values()];
  }
  #owedNow(o: Out): void {
    if (o.step === "gone" || o.dropOwed === true) this.#owedOuts.add(o);
    else this.#owedOuts.delete(o);
  }
  #forgetOut(o: Out): void {
    this.#outs.delete(o.id);
    this.#owedOuts.delete(o);
    for (const k of o.keys) {
      const list = (this.#outsOf.get(k) ?? []).filter((x) => x.id !== o.id);
      if (list.length > 0) this.#outsOf.set(k, list);
      else this.#outsOf.delete(k);
    }
  }
  /// The hand-overs from here of any of sessions `keys`, each once, the latest first per session (read by `#outsOf`).
  #outsAt(keys: readonly string[], kind: string): Out[] {
    const out = new Set<Out>();
    for (const k of keys) for (const o of this.#outsOf.get(k) ?? []) (this.#look(kind, 1), out.add(o));
    return [...out];
  }
  /// The hand-overs coming here of any of sessions `keys`, each once (read by `#insOf`).
  #insAt(keys: readonly string[], kind: string): In[] {
    const out = new Set<In>();
    for (const k of keys) for (const i of this.#insOf.get(k) ?? []) (this.#look(kind, 1), out.add(i));
    return [...out];
  }
  /// What answering a request of kind `kind` of hand-over `i` took here, since `t0`, added to what it took before.
  #spent(i: In | undefined, kind: string, t0: number): void {
    if (i === undefined) return;
    const spent = (i.spent ??= {});
    spent[kind] = (spent[kind] ?? 0) + Math.round(this.#d.fibers.now() - t0);
  }
  /// Step `step` of hand-over `o` begins now (its line says what each took).
  #mark(o: Out, step: string): void {
    (o.began ??= {})[step] = this.#d.fibers.now();
  }
  /// How many records what was done so far looked at, by what looked (a test's: what one chat's hand-over costs).
  looked(): Record<string, number> {
    return Object.fromEntries(this.#looked);
  }
  #look(kind: string, n: number): void {
    if (n > 0) this.#looked.set(kind, (this.#looked.get(kind) ?? 0) + n);
  }
  /// The chats going from here now (`handOver` under way, its first pass with the chat working or held), each with
  /// its sessions, where it goes and whether it is held yet: the overview's `move.chats`, which a device's chat page
  /// shows over a composer shut till it ends. One at a time as a turn moves them; a handful at most.
  moving(): { sessions: string[]; ws: string; to: string; toName: string; held: boolean }[] {
    return [...this.#active.values()].map((o) => ({ sessions: [...o.keys], ws: o.ws, to: o.to, toName: o.toName, held: o.held === true }));
  }

  /// The latest hand-over of session `key` from here (none: never).
  outOf(key: string): Out | null {
    return this.#outsOf.get(key)?.[0] ?? null;
  }

  /// The hand-overs waiting for a chat's turn to end before they hold it (by id): known here while they wait.
  readonly #waitingTurn = new Set<string>();
  /// Whether hand-over `o` waits for its chat's turn to end now.
  waitsForTurn(o: Out): boolean {
    return this.#waitingTurn.has(o.id);
  }

  // ── the station it leaves ──

  /// The move under way asked to stop: each hand-over not gone yet gives up at its next step, undone as a failure there
  /// is (the chat goes on here); one gone completes.
  abandon(): void {
    for (const o of this.#everyOut("abandon")) {
      if (o.step !== "files" && o.step !== "held" && o.step !== "rows") continue;
      o.abandoned = true;
      // (a step there waited on, its placing or its pruning, is let go now: a stop never waits for work that grows with
      // the chat; that station takes out what it put as its drop comes, after the step ends there)
      if (o.waitsOn !== undefined) this.#d.told.letGo(o.to, o.waitsOn, new Said(why("abandoned")));
    }
  }

  /// Told step `key` of hand-over `o`'s asked there and waited on (`make` its request), as given up where it was asked to
  /// stop.
  async #waitStep(o: Out, key: string, make: () => Json, progress?: (p: Json) => void): Promise<Json> {
    this.#given(o);
    o.waitsOn = key;
    try {
      return await this.#d.told.asked(o.to, key, make, progress);
    } finally {
      if (o.waitsOn === key) delete o.waitsOn;
    }
  }

  /// Thrown where hand-over `o` was asked to stop.
  #given(o: Out): void {
    if (o.abandoned === true) throw new Said(why("abandoned"));
  }

  /// The sessions handed over with `key`: those that share its still.fail home chat (threads.home) and its conversation.
  /// `reads`: what reads the sessions (a plan's page, batch-loading home & conversation members).
  together(key: string, reads: SessionReads = this.#reads): string[] {
    const keys = new Set([key]);
    for (const m of reads.homeMembers(key) ?? []) keys.add(m);
    return [...keys].sort();
  }

  /// The chat session `key` goes with, by the first of its keys (`together`): a member of another's still.fail home
  /// chat or conversation goes with that chat (as the chats' plan lists it), else its own.
  chatOf(key: string): string {
    const home = this.#d.store.sessionThreads(key, 64).find((m) => m.thread.surface === STILLFAIL_SURFACE && m.thread.home !== null && m.thread.home !== key)?.thread.home;
    return this.together(home ?? key)[0] ?? key;
  }

  /// Why chat `key` cannot be handed to `to` now, in words that say what to do (null: it can). `ignoreFiles`: one whose
  /// room is not the station's own goes without its files.
  /// Chat `key` as people call it: its title, else its key without still.fail's own prefix.
  #chatName(key: string): string {
    return this.#d.store.getSession(key)?.title ?? key.replace(/^chat:/, "");
  }

  /// `planning`: as a plan lists it (a chat of a connect that is not routed needs that connect there, which the plan
  /// says by its needs); else as it is to go now (`stoppedFor`: it may go while that is not there).
  check(key: string, to: string, opts: { ignoreFiles?: boolean; planning?: boolean; stoppedFor?: Need | null; reads?: SessionReads } = {}): string | null {
    const reads = opts.reads ?? this.#reads;
    const here = this.#d.here();
    const row = reads.session(key);
    if (here === null || row === null) return why("noSuchChat");
    const ws = this.#d.hub.wsOf(row);
    if (ws === null || row.ws?.startsWith(handedWs("")) || row.ws?.startsWith(comingWs(""))) return why("notInWorkspaceNow");
    if (!WORKSPACE.test(ws) || !STATION.test(to) || to === here) return why("nameAnother");
    const target = this.#d.roster(ws)?.find((s) => s.id === to);
    if (target === undefined) return why("notOfWorkspace");
    if (target.tasks === true) return why("tasksOnly", { station: target.name });
    const busy = this.#outsAt([key], "check").find((o) => o.step === "held" || o.step === "files" || o.step === "rows" || o.step === "gone");
    if (busy !== undefined) return busy.step === "gone" ? why("goingAlready", { station: busy.toName || busy.to.slice(0, 8) }) : why("handingAlready");
    for (const k of this.together(key, reads)) {
      const s = reads.session(k);
      if (s === null) continue;
      const kind = isInternal(s.connect) ? null : this.#d.connects?.kindOf(s.connect) ?? null;
      // (a chat of a connect that is not routed runs where the connect runs: it goes once its connect is there, or
      // arrives there stopped, waiting for it)
      if (kind !== null && !routed(kind) && !opts.planning && opts.stoppedFor?.module !== "connects" && this.#d.connects?.runsOn(s.connect) !== to) {
        return why("connectFirst", { chat: this.#chatName(k), connect: s.connect, kind: kind.mode === "single-session" ? why("oneSession") : kind.kind });
      }
      if (!opts.ignoreFiles && s.archivedAt === null && !s.workspace.startsWith(join(this.#d.data, "sessions"))) {
        return why("filesOutside", { chat: this.#chatName(k), dir: s.workspace });
      }
    }
    return null;
  }

  /// The accounts sessions `keys` run on (their sessions' and runtime sessions' profiles), as they are known across the
  /// workspace (`AccountOf`; null: this machine's own, which cannot go).
  accountsOf(keys: string[], reads: SessionReads = this.#reads): Map<string, AccountOf | null> {
    const out = new Map<string, AccountOf | null>();
    for (const key of keys) {
      const row = reads.session(key);
      if (row === null) continue;
      const ids = new Set<string>([row.profile, ...(row.profiles ?? []), ...reads.ranOn(key)]);
      for (const id of ids) if (!out.has(id)) out.set(id, this.#d.accounts.of(id));
    }
    return out;
  }

  /// Of `accounts` (`accountsOf(keys)`), the logins sessions `keys` only ran on before or list, none of them runs on now,
  /// that cannot go: this machine's own (null). No need of the chat's: it goes on the login it runs on, what was that
  /// login's staying here, and there it is as one whose account is missing for it (the owner, 2026-11-16: 「只是以前用过、
  /// 又迁不走的登录不再卡住聊天，聊天带着现在的登录过去，那个旧登录下的旧会话记录留在 VM-1」). The login one runs on now
  /// stays its need, refused as before where it cannot go; one that can go (shared, lent, moved whole) stays one too.
  pastLeft(accounts: Map<string, AccountOf | null>, keys: string[], reads: SessionReads = this.#reads): string[] {
    const now = new Set(keys.map((k) => reads.session(k)?.profile).filter((p): p is string => typeof p === "string"));
    return [...accounts].filter(([pid, a]) => a === null && !now.has(pid)).map(([pid]) => pid);
  }

  /// Hands chat `key` (and those sharing its home chat) to `to`: checked, held, sent, switched; what happened said back.
  /// `wait`: a busy chat's turn is waited for (TURN_WAIT_MS at most), else refused. `progress`: how far its files went.
  /// `stoppedFor`: what it needs is not usable there yet (the scheduler says so): it arrives there stopped, waiting for
  /// that, its accounts there or not.
  async handOver(key: string, to: string, opts: { wait?: boolean; ignoreFiles?: boolean; progress?: (p: { done: number; total: number; unit: string }) => void; stoppedFor?: Need } = {}): Promise<Out> {
    // (begun only once the process before is gone: never two processes of this station on one chat's hand-over)
    await this.loadedWithin();
    const refused = this.check(key, to, { ...opts, stoppedFor: opts.stoppedFor ?? null });
    if (refused !== null) throw new Refused(refused);
    const keys = this.together(key);
    const ws = this.#d.hub.wsOf(key)!;
    if (opts.wait !== true) for (const k of keys) if (this.#d.hub.busy(k)) throw new Refused(why("inTurn", { chat: this.#chatName(k) }));
    const name = this.#d.roster(ws)?.find((s) => s.id === to)?.name ?? "";
    const o: Out = {
      id: handoverId(keys, to, this.#d.fibers.now()), keys, to, toName: name, ws, at: this.#d.fibers.now(), step: "files", error: null, jobs: [], dropOwed: false,
      sent: {}, counts: null, there: {}, routes: [], routed: 0, shown: false, done: 0, total: 0, held: false, v: 2,
    };
    this.#keepOut(o);
    // (said as moving from here on, its page's composer shut, till it went or stayed: `moving`)
    this.#active.set(o.id, o);
    await this.#save(o);
    try {
      let begun: Json;
      try {
        // A first pass, the chat working all along: begun there, its files sent and placed, so that the second, held,
        // sends only what changed since (its pause does not grow with its room).
        this.#given(o);
        this.#mark(o, "begin");
        begun = await this.#beginThere(o, opts.stoppedFor ?? null);
        // (one from before calls went with a chat takes none: they stay here, and go as it is heard from once it does,
        // `#syncHandedUsage`)
        o.usage = begun?.usage === true;
        o.batched = begun?.rows === ROWS_BATCHED;
        this.#mark(o, "first");
        await this.#files(o, begun, opts.progress, false);
        this.#mark(o, "turn");
        for (const k of keys) {
          if (!this.#d.hub.busy(k)) continue;
          if (opts.wait !== true) throw new Said(why("inTurn", { chat: this.#chatName(k) }));
          let late: () => void = () => {};
          const deadline = new Promise<"late">((resolve) => (late = this.#d.fibers.after(TURN_WAIT_MS, () => resolve("late")))); // timer: a deadline for the turn's end
          this.#waitingTurn.add(o.id);
          const ended = await Promise.race([this.#d.hub.turnEnded(k).then(() => "ended" as const), deadline]).finally(() => this.#waitingTurn.delete(o.id));
          late();
          if (ended === "late") throw new Said(why("turnLate", { chat: this.#chatName(k), minutes: TURN_WAIT_MS / 60_000 }));
        }
      } catch (e) {
        const error = sayOf(e, `chat ${keys[0] ?? ""}`);
        if (this.#closed) throw new Refused(tr(stationLang(), "station.move.stoppedMidway", { station: name || to.slice(0, 12) }));
        await this.#fail(o, error);
        throw new Refused(tr(stationLang(), "station.move.chatStayed", { station: name || to.slice(0, 12), why: error }));
      }
      try {
        this.#given(o);
      } catch (e) {
        const error = sayOf(e, `chat ${keys[0] ?? ""}`);
        await this.#fail(o, error);
        throw new Refused(tr(stationLang(), "station.move.chatStayed", { station: name || to.slice(0, 12), why: error }));
      }
      this.#mark(o, "hold");
      for (const k of keys) await this.#d.hub.holdChat(k, `moving to ${name || to.slice(0, 8)}`);
      o.held = true;
      o.step = "held";
      o.jobs = this.#d.jobs.of(keys);
      await this.#save(o);
      this.#d.fail?.("held");
      await this.#d.jobs.stop(keys, `its chat is being handed to ${name || "another station"}`);
      try {
        await this.#send(o, opts.progress, begun);
      } catch (e) {
        const error = sayOf(e, `chat ${keys[0] ?? ""}`);
        // (this process stopping: the next goes on from where it stood, `start`)
        if (this.#closed) throw new Refused(tr(stationLang(), "station.move.stoppedHeld", { station: name || to.slice(0, 12) }));
        await this.#fail(o, error);
        throw new Refused(tr(stationLang(), "station.move.chatStayed", { station: name || to.slice(0, 12), why: error }));
      }
      // (what is told after it went is told until it answers: by itself, on failure with a backoff)
      await this.#afterGone(o).catch((e) => {
        log.warn("handover", "a chat that went is not all told there yet", { id: o.id, error: (e as Error).message });
        this.#retry(o);
      });
      return o;
    } finally {
      this.#active.delete(o.id);
      this.#d.changed?.(o.id);
    }
  }

  /// Begun there: its accounts there, its connects as they are known there, said first (refused there in words).
  async #beginThere(o: Out, stoppedFor: Need | null): Promise<Json> {
    const here = this.#d.here()!;
    const d = this.#d;
    const ask = (request: Json) => d.ask(o.to, { ...request, workspace: o.ws, origin: here, id: o.id });
    // Its accounts there, its connects as they are known there, said first (refused there in words).
    const accounts = Object.fromEntries([...this.accountsOf(o.keys)].map(([id, a]) => [id, a]));
    const used = [...new Set(o.keys.flatMap((k) => [d.store.getSession(k)?.connect ?? "", ...d.store.sessionThreads(k).map((t) => t.connect)]).filter((c) => c !== ""))];
    // (every connect named but still.fail's own chats' is one the workspace knows by its id here: one moved away since
    // is named so still)
    const connects = connectsThere(used.filter((c) => !isInternal(c)), used, here, o.to);
    const described: { known: Known; station: string; described: Described }[] = [];
    for (const id of used) {
      const it = d.connects?.describedFor(id);
      if (it) described.push({ known: knownOf(id, here), station: it.station, described: it.described });
    }
    // (those no profile here, told so: where the other has none of them either, no need of the chat's; so too this
    // machine's own logins it only ran on before or lists, which cannot go (`pastLeft`): it goes on the one it runs on)
    const left = new Set(this.pastLeft(this.accountsOf(o.keys), o.keys));
    const nowhere = Object.keys(accounts).filter((pid) => d.accounts.present?.(pid) === false || left.has(pid));
    return await ask({ method: "handover.begin", keys: o.keys, ws: o.ws, dataDir: d.data, accounts, nowhere, connects, described, stoppedFor, bindings: this.#bindingsOf(o.keys) });
  }

  /// Its files: gathered alone (what the first pass hashed taken by path, size and time: its lists in the same
  /// scratch), what is not in place there sent, placed and checked there. `held`: the second pass, the chat held: a
  /// file that changes as it is sent fails it (gathered again), and every file must be there. The first, the chat
  /// working, leaves one that changed for the second, and tells how far it went (the second sends what changed since,
  /// told as done).
  async #files(o: Out, begun: Json, progress: ((p: { done: number; total: number; unit: string }) => void) | undefined, held: boolean): Promise<void> {
    const here = this.#d.here()!;
    const d = this.#d;
    const ask = (request: Json) => d.ask(o.to, { ...request, workspace: o.ws, origin: here, id: o.id });
    o.step = "files";
    await this.#save(o);
    const db = join(d.data, "stillfail.db");
    const g: Gathered = await this.#work.gather(d.data, db, o.ws, false, scratch(d.data, o.id), undefined, null, o.keys).catch((e) => Promise.reject(carryWords(e)));
    // (a file of its room this station cannot read: the chat does not go, rather than go without it)
    if ((g.unreadableCount ?? 0) > 0) throw new Said(why("cannotRead", { path: (g.unreadable ?? []).join("、"), count: g.unreadableCount }));
    const floor = floorOf(typeof begun?.total === "number" ? begun.total : null);
    // (what it adds there, held before it is placed: what that station lacks of it, a twentieth more for what placing
    // makes; what it has in place already, a room left there before, is not sent and adds nothing)
    const fits = (adds: number) => {
      const need = adds + Math.ceil(adds / 20);
      if (typeof begun?.free === "number" && begun.free - need < floor) throw new Said(why("noRoom", { station: o.toName || o.to.slice(0, 12), free: gb(begun.free), need: gb(need), floor: gb(floor) }));
    };
    if (g.gits > 0 && begun?.git === false) throw new Said(why("noGit", { station: o.toName || o.to.slice(0, 12), n: g.gits }));
    d.fail?.("files");
    const carry = await sendGathered(g, {
      // (where each goes and how big, so that what is in place there already is not sent again)
      lacking: async (hashes, files) => {
        const asked = files.map((f) => ({ hash: f.hash, path: f.path, size: f.size, mtimeMs: f.mtimeMs ?? null, ...(f.room !== undefined ? { room: f.room } : {}) }));
        const answer = await ask({ method: "handover.lacking", hashes, files: asked });
        const lacking = new Set<string>(Array.isArray(answer?.lacking) ? answer.lacking : hashes);
        // (what it had no time to read there, asked again alone, until each was looked at: it is said lacking meanwhile)
        for (let rest = uncheckedOf(answer); rest.length > 0; ) {
          const of = new Set(rest);
          const again = await ask({ method: "handover.lacking", hashes: rest, files: asked.filter((f) => of.has(f.hash)) });
          const said = new Set<string>(Array.isArray(again?.lacking) ? again.lacking : rest);
          for (const h of rest) if (!said.has(h)) lacking.delete(h);
          const next = uncheckedOf(again);
          if (next.length >= rest.length) break;
          rest = next;
        }
        // (whether it takes packs: a station from before says nothing, and is sent a file a request)
        return { lacking: [...lacking], ...(answer?.pack === PACK_ENCODING ? { pack: PACK_ENCODING } : {}) };
      },
      put: async (hash, bytes, path, size) => {
        const answer = await d.ask(o.to, withBytes({ method: "handover.put", workspace: o.ws, origin: here, id: o.id, name: hash }, bytes));
        if (carriedPlace(d.data, path)) o.sentBytes = (o.sentBytes ?? 0) + size;
        return answer;
      },
      // (a pack of one names its file, as a file's request does)
      putPack: (entries, bytes, strict) => d.ask(o.to, withBytes({
        method: "handover.put", workspace: o.ws, origin: here, id: o.id, pack: PACK_ENCODING, strict, count: entries.length,
        ...(entries.length === 1 ? { name: entries[0]!.hash } : {}),
      }, bytes)),
      took: (f) => void (carriedPlace(d.data, f.path) && (o.sentBytes = (o.sentBytes ?? 0) + f.size)),
      ...(d.packMost !== undefined ? { packMost: d.packMost } : {}),
      most: d.lackMost ?? LACK_MOST,
      // (what it lacks there asked first only where all of it might not fit: else no more is asked than it sends)
      ...(held || typeof begun?.free !== "number" || begun.free - (g.bytes + Math.ceil(g.bytes / 20)) >= floor ? {} : { adds: fits }),
      stopping: () => this.#closed || o.abandoned === true,
      total: (bytes) => void (held || (o.total = bytes, o.done = 0, progress?.({ done: 0, total: bytes, unit: "bytes" }))),
      done: (bytes) => void (held || (o.done += bytes, progress?.({ done: o.done, total: o.total, unit: "bytes" }))),
    }, held, [], true).catch((e) => Promise.reject(carryWords(e)));
    this.#given(o);
    if (carry === null) throw new Said(why("stopping"));
    // (placed there by itself, told back as it goes and as it ends: a placing of minutes waits on no request's answer)
    const key = `place:${o.id}:${held ? "held" : "first"}:${carry}`;
    const placed = await this.#waitStep(o, key, () => ({ method: "handover.place", workspace: o.ws, origin: here, id: o.id, carry, held, told: key }), (p) => {
      if (typeof p?.done !== "number" || typeof p?.total !== "number") return;
      o.placing = { done: p.done, total: p.total };
      d.changed?.(o.id);
    }).finally(() => void delete o.placing);
    if (held && typeof placed?.missing === "number" && placed.missing > 0) throw new Said(why("filesMissing", { n: placed.missing }));
  }

  /// Held, steps 3 to 5 up to `gone`: its files again (what changed since the first pass), its rows, the counts.
  async #send(o: Out, progress: ((p: { done: number; total: number; unit: string }) => void) | undefined, begun: Json): Promise<void> {
    const here = this.#d.here()!;
    const d = this.#d;
    const ask = (request: Json) => d.ask(o.to, { ...request, workspace: o.ws, origin: here, id: o.id });
    this.#mark(o, "held");
    await this.#files(o, begun, progress, true);
    // Its rows, a page at a time, then what B has compared with what was sent.
    this.#given(o);
    this.#mark(o, "rows");
    o.step = "rows";
    await this.#save(o);
    d.fail?.("rows");
    const sent = await this.#sendRows(o, ask, null);
    // (what the room there has that this one's lists no longer name goes there: a mirror of it)
    const pruning = `prune:${o.id}`;
    await this.#waitStep(o, pruning, () => ({ method: "handover.prune", workspace: o.ws, origin: here, id: o.id, told: pruning }));
    this.#mark(o, "counts");
    const counts = (await ask({ method: "handover.counts" }))?.counts as Counts | undefined;
    d.fail?.("counts");
    this.#given(o);
    const differs = counts === undefined ? "it said nothing" : differ(sent, counts);
    if (differs !== null) throw new Said(why("notWhatSent", { what: differs }));
    // Gone: said here first, durably, before anything else is told.
    o.counts = counts!;
    o.there = Object.fromEntries(o.keys.map((k) => [k, { thread: d.store.homeChat(k)?.id ?? null, there: typeof (counts as Json).homes?.[k] === "number" ? (counts as Json).homes[k] : null }]));
    o.routes = [];
    for (const k of o.keys) {
      for (const t of d.store.sessionThreads(k)) {
        if (t.thread.surface === STILLFAIL_SURFACE || isInternal(t.connect)) continue;
        // (a connect that is not routed runs its chats where it runs: none of its threads is re-pointed)
        const kind = d.connects?.kindOf(t.connect) ?? null;
        if (kind !== null && !routed(kind)) continue;
        o.routes.push({ connect: t.connect, channel: t.thread.channel, threadTs: t.thread.threadTs });
      }
    }
    // (what it went with kept first, then its end decided once: where this station's next process failed it meanwhile
    // (`decided`), it did not go, and nothing of it is said gone)
    await this.#save(o);
    // (a test's: what another process of this station does as this one is about to decide, waited for)
    await d.fail?.("decide");
    if ((await decided(d.data, o.id, "gone")) !== "gone") throw new Said(tr(stationLang(), "station.move.restartedMidway", { station: o.toName || o.to.slice(0, 12) }));
    this.#mark(o, "gone");
    o.step = "gone";
    await this.#save(o);
    d.fail?.("gone");
    // (where it went, for what its platforms say; still in sight here, held, until it is shown there: a device is
    // pointed there only once it is there to be read, `#afterGone`)
    d.store.goneTo(o.keys, o.to, o.there);
    // (gone without its calls, to a station from before they went: they go once it takes them, as it is heard from)
    if (o.usage !== true) await this.#usageAgainFor(o.to).catch((e) => log.warn("handover", "the calls of chats handed before not looked at again", { to: o.to.slice(0, 12), error: (e as Error).message }));
    await d.went?.(o.keys);
    await rm(scratch(d.data, o.id), { recursive: true, force: true });
    // (what each step took, `gone` its own work here to now: the show's is the other's, said in its line)
    const { ms, total } = tookOf(o.began, this.#d.fibers.now());
    log.info("handover", "a chat went to another station", { id: o.id, to: o.to, keys: o.keys.length, ms, total });
  }

  /// The chat's rows sent a page at a time (`from`: each thread's entries and letters after what was sent, alone):
  /// what was sent, counted as the station it goes to counts it.
  async #sendRows(o: Out, ask: (r: Json) => Promise<Json>, from: Out["sent"] | null): Promise<Counts> {
    const store = this.#d.store;
    const sent: Counts = { sessions: 0, entries: {}, letters: {}, rows: {} };
    const counted = (table: ChatTable, rows: Json[]) => {
      if (table === "sessions") sent.sessions += rows.length;
      else if (table === "entries" || table === "letters") for (const r of rows) sent[table][String(r.thread)] = (sent[table][String(r.thread)] ?? 0) + 1;
      else if (table !== "threads") sent.rows[table] = (sent.rows[table] ?? 0) + rows.length;
    };
    // (pages of several tables held for one request, in the order they were read, at most ROWS_MOST rows in all, where
    // that station takes them so: `batched`. Not after it went (`from`): there what was sent is kept as each page goes
    // (`o.sent`, `usageSent`), and a page held when a request fails would be counted sent and never go)
    const batching = o.batched === true && from === null;
    let held: { table: ChatTable; rows: Json[] }[] = [];
    let heldRows = 0;
    const flush = async () => {
      if (held.length === 0) return;
      const tables = held;
      held = [];
      heldRows = 0;
      // (a page of its own: asked again, as its answer was lost, it is not taken twice there)
      const id = randomBytes(8).toString("hex");
      if (tables.length === 1) await ask({ method: "handover.rows", table: tables[0]!.table, rows: tables[0]!.rows, page: id });
      else await ask({ method: "handover.rows", tables, page: id });
      for (const t of tables) counted(t.table, t.rows);
    };
    const page = async (table: ChatTable, rows: Json[]) => {
      if (rows.length === 0) return;
      if (!batching) {
        await ask({ method: "handover.rows", table, rows, page: randomBytes(8).toString("hex") });
        counted(table, rows);
        return;
      }
      if (heldRows + rows.length > ROWS_MOST) await flush();
      held.push({ table, rows });
      heldRows += rows.length;
      if (heldRows >= ROWS_MOST) await flush();
    };
    // (the last row sent: of the page before where the last is empty)
    const pages = async (table: ChatTable, of: number | string, after: Json = null) => {
      let last: Json;
      for (;;) {
        const rows = store.chatPage(table, of, after, 500, o.keys);
        await page(table, rows);
        last = rows.at(-1) ?? last;
        if (rows.length < 500 || table === "threads" || table === "sessions" || table === "thread_sessions" || table === "opened_chats" || table === "session_usage") return last;
        after = afterOf(table, rows.at(-1)!);
      }
    };
    if (from === null) for (const k of o.keys) await pages("sessions", k);
    for (let after = 0; ; ) {
      const threads = store.chatThreads(o.keys, after, 200);
      for (const t of threads) {
        if (from === null) await pages("threads", t);
        if (from === null) await pages("thread_sessions", t);
        const was = from?.[String(t)] ?? { entries: 0, letters: 0 };
        const lastE = await pages("entries", t, from === null ? null : was.entries);
        const lastL = await pages("letters", t, from === null ? null : was.letters);
        o.sent[String(t)] = { entries: Math.max(was.entries, Number(lastE?.n ?? 0)), letters: Math.max(was.letters, Number(lastL?.n ?? 0)) };
        if (from === null) for (const table of [...BY_N.filter((x) => x === "closed_cards"), ...MARKS]) await pages(table, t);
      }
      if (threads.length < 200) break;
      after = threads.at(-1)!;
    }
    for (const k of o.keys) {
      for (const table of (from === null ? ["turns", "runtime_sessions", "pins", "opened_chats", "deliveries"] : ["deliveries"]) as ChatTable[]) await pages(table, k);
    }
    // (its calls, after its threads: those they name are known there by then. After it went, those counted since)
    if (o.usage === true) {
      const was = o.usageSent ?? {};
      const last: Record<string, [number, string] | null> = {};
      for (const k of o.keys) {
        const after = from === null ? null : (was[k] ?? null);
        const end = await pages("usage", k, after);
        last[k] = end === undefined ? after : [Number(end.at), String(end.id)];
        await pages("usage_files", k);
        await pages("session_usage", k);
      }
      o.usageSent = last;
    }
    await flush();
    void CHAT_TABLES;
    return sent;
  }

  /// After it went: what was said meanwhile (its logs' rest, its platforms' events waited for), then B told to show it,
  /// then each of its platform threads re-pointed where its connect runs; told until each answers.
  async #afterGone(o: Out): Promise<void> {
    const d = this.#d;
    // (the chat came back here since: nothing of this one is said or sent any more)
    if (o.step === "done" || o.ended === true) return;
    const here = d.here()!;
    const ask = (request: Json) => d.ask(o.to, { ...request, workspace: o.ws, origin: here, id: o.id });
    if (!o.shown) {
      this.#mark(o, "show");
      // (its threads of this station's own connects point there at once: what comes from now on goes there; what came
      // before is waited for, and goes with the rest of its logs)
      for (const r of o.routes) {
        if (d.connects?.describedFor(r.connect)?.station === here) await d.connects.route(r.connect, r.channel, r.threadTs, o.to);
        await d.hub.drained(r.connect, r.channel, r.threadTs);
      }
      await this.#sendRows(o, ask, o.sent);
      d.fail?.("show");
      // (with the messages written here under a client's key, so that one asked again there is not posted twice)
      const threads = new Map<number, number>();
      for (const t of Object.values(o.there)) if (t.thread !== null && t.there !== null) threads.set(t.thread, t.there);
      await ask({ method: "handover.show", sends: d.keptSends?.(threads) ?? [] });
      o.shown = true;
      await this.#save(o);
    }
    // Shown there: out of sight here and devices told where, in one step; then what was taken here since its rows
    // were last sent goes after it (a message sent here meanwhile), and it is shown again there, to take that up.
    d.store.shownThere(o.keys, d.home());
    for (const k of o.keys) d.hub.releaseChat(k);
    if (!o.caught) {
      // (only where something was taken: one page a thread and session at most to know it)
      const since = Object.entries(o.sent).some(([t, was]) => d.store.chatPage("entries", Number(t), was.entries, 1, o.keys).length > 0 || d.store.chatPage("letters", Number(t), was.letters, 1, o.keys).length > 0)
        || o.keys.some((k) => d.store.chatPage("deliveries", k, null, 1, o.keys).length > 0)
        || (o.usage === true && o.keys.some((k) => d.store.chatPage("usage", k, o.usageSent?.[k] ?? null, 1).length > 0));
      if (since) {
        await this.#sendRows(o, ask, o.sent);
        await ask({ method: "handover.show", sends: [] });
      }
      d.store.deliveredThere(o.keys);
      o.caught = true;
      await this.#save(o);
    }
    for (; o.routed < o.routes.length; o.routed++) {
      const r = o.routes[o.routed]!;
      await d.connects?.route(r.connect, r.channel, r.threadTs, o.to);
      await this.#save(o);
    }
    this.#mark(o, "done");
    o.step = "done";
    await this.#save(o);
  }

  /// It did not go: B told to take out what it put in (told until it answers), the chat back to work here, its jobs
  /// started again; why kept.
  async #fail(o: Out, error: string): Promise<void> {
    // (one decided gone already, by this process or the one before, is not failed: it went)
    if ((await decided(this.#d.data, o.id, "failed")) === "gone") {
      log.warn("handover", "a hand-over that went is not failed", { id: o.id, to: o.to, error });
      return;
    }
    log.warn("handover", "a chat was not handed over: it goes on here", { id: o.id, to: o.to, error });
    o.step = "failed";
    o.error = error;
    o.dropOwed = true;
    await this.#save(o);
    // (one not held yet goes on as it was)
    if (o.held !== false) for (const k of o.keys) if (!this.#d.hub.releaseChat(k)) this.#d.hub.wakeChat(k);
    for (const j of o.jobs) {
      try {
        this.#d.jobs.start(j);
      } catch (e) {
        log.warn("handover", "a job of a chat not handed over not started again", { job: j.name, error: (e as Error).message });
      }
    }
    await rm(scratch(this.#d.data, o.id), { recursive: true, force: true });
    await this.#drop(o).catch(() => this.#retry(o));
  }

  async #drop(o: Out): Promise<void> {
    const here = this.#d.here()!;
    await this.#d.ask(o.to, { method: "handover.drop", workspace: o.ws, origin: here, id: o.id });
    o.dropOwed = false;
    await this.#save(o);
  }

  /// What is owed to B told (after it went: the rest; failed: the drop), again until it answers.
  #go(o: Out): void {
    if (this.#closed || this.#runs.has(o.id) || o.ended === true) return;
    this.#again.get(o.id)?.();
    this.#again.delete(o.id);
    const run = (o.step === "gone" ? this.#afterGone(o) : o.dropOwed ? this.#drop(o) : Promise.resolve())
      .then(() => void this.#tries.delete(o.id), () => this.#retry(o))
      .finally(() => void this.#runs.delete(o.id));
    this.#runs.set(o.id, run);
  }

  #retry(o: Out): void {
    if (this.#closed || o.ended === true) return;
    const n = this.#tries.get(o.id) ?? 0;
    this.#tries.set(o.id, n + 1);
    this.#again.set(o.id, this.#d.fibers.after(Math.min(RETRY_MS * 2 ** n, RETRY_MOST_MS), () => this.#go(o))); // timer: a retry after a failure
  }

  /// The hand-overs coming here that were under way as this station started: whether each still goes on is asked of
  /// the station it comes from as this one starts and as that one is heard from, and one that does not is dropped here
  /// (its sender failed and its drop never came, or it lost its record). One begun in this process is the sender's
  /// own to drop, as it does on failure, told until it is answered.
  readonly #unsure = new Set<string>();
  /// Those of them begun under another boot of this machine (`#load`): dropped as it starts.
  readonly #rebooted = new Set<string>();
  #asking = new Set<string>();

  #askStill(i: In): void {
    if (i.step !== "coming" || i.dropping === true || this.#asking.has(i.id) || this.#inWork.has(i.id)) return;
    this.#asking.add(i.id);
    void this.#d.ask(i.origin, { method: "handover.still", workspace: i.ws, origin: this.#d.here(), id: i.id })
      .then(async (a) => {
        this.#unsure.delete(i.id);
        if (a?.going === false && i.step === "coming") {
          log.info("handover", "a chat coming here no longer goes on where it came from: dropped here", { id: i.id, from: i.origin.slice(0, 12) });
          await this.#dropSoon(i).marked;
        }
      })
      .catch(() => {})
      .finally(() => void this.#asking.delete(i.id));
  }

  /// The other station came up (its link opened): what is owed to it told now.
  reached(station: string): void {
    // (the process before not gone yet: `start` tells what is owed, once it is)
    if (!this.#ready) return;
    void this.#mend(station);
    this.#syncHandedUsage(station);
    for (const id of this.#unsure) {
      const i = this.#ins.get(id);
      if (i === undefined || i.step !== "coming") this.#unsure.delete(id);
      else if (i.origin === station) this.#askStill(i);
    }
    this.#look("reached", this.#owedOuts.size);
    for (const o of [...this.#owedOuts]) {
      if (o.step !== "gone" && !o.dropOwed) continue;
      // (shown there, only its threads' re-pointing is owed: to the stations their connects run on)
      const owed = o.step === "gone" && o.shown
        ? o.routes.slice(o.routed).some((r) => this.#d.connects?.runsOn(r.connect) === station)
        : o.to === station;
      if (owed) this.#go(o);
    }
  }

  async #save(o: Out): Promise<void> {
    this.#owedNow(o);
    await writeJson(outFile(this.#d.data, o.id), o);
    this.#d.changed?.(o.id);
  }
  async #saveIn(i: In): Promise<void> {
    this.#comingNow(i);
    await writeJson(inFile(this.#d.data, i.id), i);
    this.#d.changed?.(i.id);
  }

  #bindingsOf(keys: string[]): Record<string, string> {
    return this.#d.bindingsOf?.(keys) ?? {};
  }

  // ── the station it goes to ──

  /// What this station answers of it (`handover.*`), from stations of the chat's workspace, of their own chats.
  answers(inWorkspace: (peer: string, ws: string) => boolean) {
    return async (peer: string, request: Json, workspace?: string): Promise<Json> => {
      // (answered once the process before is gone: it may be answering the same hand-over still; meanwhile the asker
      // waits the seconds a hand-over between processes takes, refused in words past PREVIOUS_LIMIT_MS)
      await this.loadedWithin();
      const bytes = bytesOf(request);
      try {
        const ws = typeof request?.workspace === "string" ? request.workspace : "";
        const id = typeof request?.id === "string" ? request.id : "";
        if (!WORKSPACE.test(ws) || (workspace !== undefined && workspace !== ws) || !inWorkspace(peer, ws) || request?.origin !== peer) throw new Refused(why("notStationOfWs"));
        if (!/^[0-9a-z-]{1,80}$/.test(id)) throw new Refused(why("badRequest", { detail: "not a hand-over" }));
        if (request.method === "handover.begin") {
          const t0 = this.#d.fibers.now();
          const answer = await this.#begin(peer, ws, id, request);
          this.#spent(this.#ins.get(id), "begin", t0);
          return answer;
        }
        // (whether a hand-over of this station's to the one asking still goes on: one asked as that station starts, or
        // hears from this one again, holding what it began to take of it)
        if (request.method === "handover.still") {
          const o = this.#outs.get(id);
          return { going: o !== undefined && o.to === peer && o.step !== "failed" };
        }
        // (whether this station holds a hand-over of the one asking: coming or shown here, not dropped. Its own word
        // that it does not is what lets that station take back a chat it said went (`#mend`))
        if (request.method === "handover.held") {
          const i = this.#ins.get(id);
          return { held: i !== undefined && i.origin === peer && i.step !== "dropped" && i.dropping !== true && !this.#dropping.has(id) };
        }
        // (the calls of a chat handed here before they went with it: no hand-over of its own)
        if (request.method === "handover.usage") return this.#takeUsage(peer, ws, request);
        const i = this.#ins.get(id);
        // (answered as it is marked, its rows out: its files are taken out after what it was doing to them, by this
        // station itself, as its next process starts where this one stops first; the asker needs nothing more of it)
        if (request.method === "handover.drop") {
          if (i === undefined || i.step === "dropped") return { ok: true };
          if (i.step === "shown") throw new Refused(why("shownHere"));
          await this.#dropSoon(i).marked;
          return { ok: true };
        }
        if (i === undefined || i.origin !== peer) throw new Refused(why("badRequest", { detail: "not begun: handover.begin first" }));
        // (dropped here, by its own drop or a newer hand-over of the chat: nothing more of it is taken)
        if (i.step === "dropped" || i.dropping === true || this.#dropping.has(i.id)) throw new Refused(why("droppedThere"));
        const t0 = this.#d.fibers.now();
        const kind = String(request.method).slice("handover.".length);
        // (what answering it took, by request: the show's own said in its line, as it ends)
        const answer = async (): Promise<Json> => {
          switch (request.method) {
            case "handover.lacking": {
              const hashes = Array.isArray(request.hashes) ? request.hashes : [];
              if (hashes.length > (this.#d.lackMost ?? LACK_MOST) || !hashes.every((h: unknown) => typeof h === "string" && HASH.test(h))) throw new Refused(why("badRequest", { detail: "too many hashes" }));
              const lacking = new Set(await lackingIn(inFiles(this.#d.data, id), hashes));
              // (an older hand-over of the chat still being taken out here may take away what is in place now: none is
              // taken as in place until it is out)
              const olderOut = this.#insAt(i.keys, "lacking").some((o) => o.id !== i.id && this.#drops.has(o.id));
              // (one in place here already, the same bytes where it goes, is not lacking: a room kept here, or placed
              // by a hand-over before. Only where every path of it the request names is: the same bytes at two paths,
              // one of them not in place, are sent, or that one could not be placed (the real run, 2026-11-16: two
              // pairs of uploads, one of each pair left there by a retirement, "2 files sent are not there"). A path
              // of a hash already found missing is not looked at: no more than before where no bytes are at two paths)
              const files = (Array.isArray(request.files) ? request.files : []).slice(0, this.#d.lackMost ?? LACK_MOST);
              const rooms = new Map<string, string>();
              const placed = new Set<string>();
              const missing = new Set<string>();
              // (what one request reads to hash, at most: the rest said unchecked, lacking until it is asked again)
              const unchecked = new Set<string>();
              const budget = { left: this.#d.hashMost ?? HASH_MOST, most: this.#d.hashMost ?? HASH_MOST };
              for (const f of files) {
                if (olderOut) break;
                if (!lacking.has(f?.hash) || missing.has(f?.hash) || unchecked.has(f?.hash) || typeof f?.path !== "string") continue;
                // (where it lies here by the same answer its placing gives: restore.ts `carriedTo`)
                let room: string | null = null;
                if (typeof f.room === "string") {
                  room = rooms.get(f.room) ?? (await realOfSoon(moved(f.room, i.ctx.fromData, this.#d.data)));
                  rooms.set(f.room, room);
                }
                const is = await inPlace(carriedTo(f.path, i.ctx.fromData, this.#d.data, room), this.#d.data, f, budget);
                if (is === "yes") placed.add(f.hash);
                else if (is === "later") unchecked.add(f.hash);
                else missing.add(f.hash);
              }
              // (one unchecked is said lacking too: an asker from before sends it rather than take it as in place)
              // (`pack`: what it lacks it takes a pack at a time, pack.ts `receivePack`)
              return {
                lacking: hashes.filter((h: string) => lacking.has(h) && (olderOut || missing.has(h) || unchecked.has(h) || !placed.has(h))),
                ...(unchecked.size > 0 ? { unchecked: [...unchecked].filter((h) => !missing.has(h)) } : {}),
                pack: PACK_ENCODING,
              };
            }
            case "handover.prune":
              return await this.#step(peer, i, request, () => this.#serialIn(i, () => this.#prune(i)));
            case "handover.put": {
              // (a pack: its files taken as they come, each checked as one is; `fail`, a test's, as each begins)
              if (request.pack === PACK_ENCODING) {
                const named = request.name === undefined ? undefined : String(request.name);
                if (bytes === null || (named !== undefined && !HASH.test(named))) throw new Refused(why("badRequest", { detail: "not a pack" }));
                await receivePack(inFiles(this.#d.data, id), bytes as Bytes, {
                  strict: request.strict !== false, flush: this.#flush === null, ...(named !== undefined ? { name: named } : {}),
                  ...(typeof request.count === "number" ? { count: request.count } : {}), onFile: () => this.#d.fail?.("put"),
                });
                return { ok: true };
              }
              const name = String(request.name ?? "");
              if (bytes === null || !HASH.test(name)) throw new Refused(why("badRequest", { detail: "not a file's hash" }));
              this.#d.fail?.("put");
              // (not flushed a file at a time where its placing flushes once what it took: `#place`)
              await receiveFile(inFiles(this.#d.data, id), name, bytes as Bytes, this.#flush === null);
              return { ok: true };
            }
            case "handover.place": {
              const carry = String(request.carry ?? "");
              if (!HASH.test(carry)) throw new Refused(why("badRequest", { detail: "not a copy's name" }));
              const place = () => this.#serialIn(i, () => this.#place(i, carry)).catch((e) => Promise.reject(carryWords(e)));
              return await this.#step(peer, i, request, place, this.#placing(i, carry));
            }
            case "handover.rows": {
              // (one table's page, or several tables' pages in the order they go: `rows: "batched"`, at most ROWS_MOST
              // rows in all)
              const pages: { table: ChatTable; rows: Json[] }[] = Array.isArray(request.tables)
                ? request.tables.map((t: Json) => ({ table: String(t?.table ?? "") as ChatTable, rows: t?.rows }))
                : [{ table: String(request.table ?? "") as ChatTable, rows: request.rows }];
              let all = 0;
              for (const p of pages) {
                // (shown: only what was said there after its rows went, its log's and what it has yet to be handed)
                if (i.step !== "coming" && (i.step !== "shown" || !AFTER_SHOWN.includes(p.table))) throw new Refused(why("shownAlready"));
                if (!CHAT_TABLES.includes(p.table) || !Array.isArray(p.rows)) throw new Refused(why("badRequest", { detail: "not a page of a chat's rows" }));
                all += p.rows.length;
              }
              if (pages.length === 0 || all > ROWS_MOST) throw new Refused(why("badRequest", { detail: "not a page of a chat's rows" }));
              const page = typeof request.page === "string" ? request.page : null;
              if (page !== null && i.page === page) return { ok: true };
              this.#d.fail?.("import");
              this.#d.store.importPages(i.ctx, pages, i.step === "coming" ? i.id : undefined);
              // (calls counted there after it was shown here: its usage as all its calls here say it)
              if (i.step === "shown" && pages.some((p) => USAGE_TABLES.includes(p.table))) this.#usageOf(i.keys, false);
              this.#d.fail?.("imported");
              if (page !== null) i.page = page;
              await this.#saveIn(i);
              return { ok: true };
            }
            case "handover.counts": {
              const homes: Record<string, number | null> = {};
              for (const k of i.keys) homes[k] = this.#d.store.homeChat(k)?.id ?? null;
              return { counts: { ...i.ctx.counts, homes } };
            }
            case "handover.show":
              return await this.#show(i, Array.isArray(request.sends) ? request.sends : []);
          }
          throw new Refused(why("badRequest", { detail: "no such hand-over request" }));
        };
        try {
          return await answer();
        } catch (e) {
          throw await this.#written(i, e);
        } finally {
          if (kind !== "show") this.#spent(i, kind, t0);
        }
      } finally {
        if (bytes !== null) await stopBytes(bytes).catch(() => {});
      }
    };
  }

  /// What failed of hand-over `i` here as it is answered, as the asker is told it: this station's own disk failing what
  /// it is sent (full, over its quota, read-only), nothing of the chat is kept here, dropped now by this station itself,
  /// and the asker told so in numbers, never as a stream reset (a write of the program's, placing, says its code in its
  /// words); anything else as it is.
  async #written(i: In, e: unknown): Promise<unknown> {
    const code = (e as NodeJS.ErrnoException)?.code ?? /\b(ENOSPC|EDQUOT|EROFS)\b/.exec((e as Error)?.message ?? "")?.[1] ?? "";
    if (!WRITE_FAILED.has(code)) return e;
    log.warn("handover", "a chat coming here could not be written: dropped here", { id: i.id, error: (e as Error).message });
    this.#dropSoon(i).marked.catch((d) => log.warn("handover", "a chat coming here not dropped after its write failed", { id: i.id, error: (d as Error).message }));
    const room = await (this.#d.room ?? roomHere(this.#d.data))().catch(() => ({ free: null }));
    const name = this.#d.roster(i.ws)?.find((s) => s.id === this.#d.here())?.name || (this.#d.here() ?? "").slice(0, 12);
    return new Refused(why("fullThere", { station: name, free: typeof room.free === "number" ? gb(room.free) : "?", error: code }));
  }

  /// Work of hand-over `i` that grows with its chat (its placing, its pruning), as `request` asks it: a told step
  /// (move/told.ts), started and answered at once, told back as it goes and as it ends; asked by a station from before
  /// told steps, answered by its result as before.
  async #step(peer: string, i: In, request: Json, run: () => Promise<Json>, measure?: () => Promise<Json>): Promise<Json> {
    const key = toldKey(request);
    if (key === null) return await run();
    const kind = String(request.method).slice("handover.".length);
    return this.#d.told.run(peer, key, async () => {
      const t0 = this.#d.fibers.now();
      try {
        return await run();
      } catch (e) {
        throw await this.#written(i, e);
      } finally {
        this.#spent(i, kind, t0);
      }
    }, { measure });
  }

  /// How far hand-over `i`'s placing of `carry` is, as each beat of its step asks: the lines its program added to
  /// `placed.txt` since it began (a file each, put or found in place), read from where the last beat left off, of the
  /// files its index names.
  #placing(i: In, carry: string): () => Promise<Json> {
    const at = join(dir(this.#d.data), "in", i.id, "placed.txt");
    const from = stat(at).then((s) => s.size, () => 0);
    const total = readFile(join(inFiles(this.#d.data, i.id), carry), "utf8").then((t) => Number((JSON.parse(t) as CarryIndex).files) || 0, () => 0);
    let offset: number | null = null;
    let done = 0;
    return async () => {
      offset ??= await from;
      const f = await open(at, "r").catch(() => null);
      if (f !== null) {
        try {
          const piece = Buffer.alloc(1 << 20);
          for (;;) {
            const { bytesRead } = await f.read(piece, 0, piece.length, offset);
            offset += bytesRead;
            for (let k = 0; k < bytesRead; k++) if (piece[k] === 10) done++;
            if (bytesRead < piece.length) break;
          }
        } finally {
          await f.close();
        }
      }
      return { done, total: await total, unit: "files" };
    };
  }

  async #begin(origin: string, ws: string, id: string, request: Json): Promise<Json> {
    const was = this.#ins.get(id);
    if (was !== undefined && was.step !== "coming") throw new Refused(why("wasAlready", { step: was.step }));
    if (was?.dropping === true) throw new Refused(why("droppedThere"));
    const keys: string[] = Array.isArray(request.keys) ? request.keys.filter((k: unknown): k is string => typeof k === "string") : [];
    if (keys.length === 0) throw new Refused(why("badRequest", { detail: "no chat named" }));
    // (a chat of the same key that is live here went on apart from it: never merged into, nothing written)
    const live = this.#d.store.liveOf(keys);
    if (live.length > 0) throw new Refused(liveHereWords(live, this.#d.roster(ws)?.find((s) => s.id === this.#d.here())?.name || "this station"));
    // (an older hand-over of the chat still coming here was given up where it began, its drop maybe not here yet: it is
    // dropped now, its rows out before this one's come, so that its drop, coming late, takes nothing this one counted;
    // its files after what it was doing to them, before this one places anything (`#serialIn`), not in this answer)
    for (const old of this.#insAt(keys, "begin")) {
      if (old.id !== id && old.origin === origin && old.step === "coming") await this.#dropSoon(old).marked;
    }
    // Its accounts as they are here: each the profile of the same share, or of the same key; one not here refused,
    // named.
    const profiles: Record<string, string> = {};
    const missing: string[] = [];
    const nowhere = new Set<string>(Array.isArray(request.nowhere) ? request.nowhere.filter((x: unknown): x is string => typeof x === "string") : []);
    for (const [pid, a] of Object.entries((request.accounts ?? {}) as Record<string, AccountOf | null>)) {
      const here = a === null ? null : this.#d.accounts.here(a);
      // (a login of no station's, here neither: no need of the chat's, which goes on as one whose account is missing)
      if (here === null && nowhere.has(pid)) continue;
      if (here === null) missing.push(a?.name || pid);
      else profiles[pid] = here;
    }
    const stoppedFor = request.stoppedFor !== null && typeof request.stoppedFor?.module === "string" && typeof request.stoppedFor?.id === "string" ? { module: request.stoppedFor.module, id: request.stoppedFor.id, ...(typeof request.stoppedFor.label === "string" ? { label: request.stoppedFor.label } : {}) } as Need : null;
    // (one that arrives stopped, waiting for its account, goes on its ids as they are until it comes)
    if (missing.length > 0 && stoppedFor === null) throw new Refused(why("accountsMissing", { names: missing.join(", ") }));
    for (const x of Array.isArray(request.described) ? request.described : []) {
      if (x?.known && typeof x.station === "string" && x.described) this.#d.connects?.learnOf(x.known, x.station, x.described);
    }
    const strings = (v: Json) => Object.fromEntries(Object.entries(v ?? {}).filter((e): e is [string, string] => typeof e[1] === "string"));
    const bindings: Record<string, string> = {};
    for (const [c, k] of Object.entries((request.bindings ?? {}) as Record<string, string>)) if (typeof k === "string") bindings[strings(request.connects)[c] ?? c] = k;
    const i: In = was ?? {
      id, origin, keys, ws, at: this.#d.fibers.now(), step: "coming", carry: null, error: null, stoppedFor, bindings, boot: (this.#d.boot ?? bootHere)(),
      ctx: newCtx({ from: origin, here: this.#d.here() ?? undefined, fromData: String(request.dataDir ?? ""), toData: this.#d.data, connects: strings(request.connects), profiles, ws: comingWs(ws) }),
    };
    this.#keepIn(i);
    this.#holdIn(i);
    await this.#saveIn(i);
    const [room, git] = await Promise.all([(this.#d.room ?? roomHere(this.#d.data))().catch(() => ({ free: null, total: null })), (this.#d.hasGit ?? (async () => true))().catch(() => false)]);
    // (`usage`: its calls are taken with its rows, and a chat's handed before as `handover.usage` brings them)
    return { ok: true, free: room.free, total: room.total ?? null, git, usage: true, rows: ROWS_BATCHED };
  }

  async #place(i: In, carry: string): Promise<Json> {
    if (!HASH.test(carry)) throw new Refused(why("badRequest", { detail: "not a copy's name" }));
    const files = inFiles(this.#d.data, i.id);
    const index = join(files, carry);
    // (what the first pass placed stays placed: the second looks only at what the lists say otherwise of)
    const placed = await this.#work.place(this.#d.data, index, files, inMade(this.#d.data, i.id), inAside(this.#d.data, i.id), join(dir(this.#d.data), "in", i.id, "placed.txt"), true);
    const c = JSON.parse(await readFile(index, "utf8")) as CarryIndex;
    // (each worktree git makes for it kept, as the files it makes are: a drop takes it out again)
    const gits = inGits(this.#d.data, i.id);
    if (c.gits.length > 0 && this.#d.git !== undefined) await rebuildGits(this.#d.data, this.#d.reposDir, c, files, this.#d.git, { clone: false, made: (m) => appendFile(gits, `${JSON.stringify(m)}\n`) });
    // (what it took and placed written out once, before the sender is told it is placed: its files came unflushed,
    // as a drive's flush a file was 70% of taking a small one, 2026-11-16; failing, the placing fails)
    await this.#flush?.(join(dir(this.#d.data), "in", i.id));
    i.carry = carry;
    await this.#saveIn(i);
    return { ok: true, placed: placed.placed, missing: placed.missing };
  }

  /// What the chat's room here holds that the lists sent no longer name, removed: this station's own gathering of its
  /// sessions (as the rows put in say them) against the lists sent, so nothing is touched that a gathering leaves out
  /// (what a build makes again, what git ignores) nor anything outside its room; and so what an Antigravity CLI keeps of
  /// its conversations (carry.ts `cliKept`), by that gathering (under the profile it runs on here) and by what this
  /// hand-over placed (`placed.txt`: under the profile it ran on there, which a login lent here names otherwise). A
  /// first pass sends a conversation's `.db-wal` as it is written; its CLI ended, the second finds it checkpointed into
  /// the `.db` and gone: left beside the newer `.db`, the CLI replayed it into a malformed database (2026-11-16).
  async #prune(i: In): Promise<Json> {
    if (i.carry === null) return { ok: true, removed: 0 };
    const files = inFiles(this.#d.data, i.id);
    const index = JSON.parse(await readFile(join(files, i.carry), "utf8")) as CarryIndex;
    const named = new Set<string>();
    const mine = join(dir(this.#d.data), "in", i.id, "mine");
    await mkdir(join(mine, "lists"), { recursive: true });
    for (const s of index.sessions) {
      const list = await readFile(join(files, s.list), "utf8").catch(() => "");
      const here: string[] = [];
      const roomHere = await realOfSoon(moved(s.workspace, index.dataDir, this.#d.data));
      for (const line of list.split("\n")) {
        if (line === "") continue;
        try {
          const f = JSON.parse(line);
          f.path = carriedTo(f.path, index.dataDir, this.#d.data, roomHere);
          named.add(f.path);
          here.push(JSON.stringify(f));
        } catch {}
      }
      // (what was sent, as its gathering here would list it before: what is in place by its size and time is not read
      // again to be hashed, so this gathering only walks the room)
      await writeFile(listFile(mine, s.key), here.length === 0 ? "" : `${here.join("\n")}\n`);
    }
    const g = await this.#work.gather(this.#d.data, join(this.#d.data, "stillfail.db"), i.ws, false, mine, undefined, null, i.keys);
    const own = JSON.parse(await readFile(g.index, "utf8")) as CarryIndex;
    let removed = 0;
    const cli = (path: string) => {
      const rel = relative(this.#d.data, path);
      return rel !== "" && !rel.startsWith("..") && !isAbsolute(rel) && cliKept(rel.split(sep));
    };
    const prune = async (path: string) => {
      // (put aside, not removed: one that is dropped puts it back)
      if (!(await this.#putAside(i, path))) return;
      removed++;
      // (a conversation's `brain/<id>/` left empty goes too; a room's directories stay as they are)
      if (cli(path)) await this.#emptied(dirname(path));
    };
    for (const s of own.sessions) {
      for (const line of (await readFile(s.at, "utf8").catch(() => "")).split("\n")) {
        if (line === "") continue;
        let path: string;
        try {
          path = JSON.parse(line).path;
        } catch {
          continue;
        }
        if (named.has(path) || !(path.startsWith(s.room + sep) || cli(path))) continue;
        // (a linked worktree's `.git`, which this station's git made as the chat's worktree was added here, names a
        // repository of this station's: the lists sent never name it, and it stays)
        if (basename(path) === ".git") continue;
        named.add(path);
        await prune(path);
      }
    }
    // (what this hand-over placed of a CLI's conversation that the lists sent now no longer name: a line a file placed,
    // `<path>\t<hash, size, time>`, read a line at a time, as a room's are as many)
    const placed = join(dir(this.#d.data), "in", i.id, "placed.txt");
    if (await stat(placed).then(() => true, () => false)) {
      for await (const line of createInterface({ input: createReadStream(placed), crlfDelay: Infinity })) {
        const path = line.slice(0, line.indexOf("\t"));
        if (path === "" || named.has(path) || !cli(path)) continue;
        named.add(path);
        await prune(path);
      }
    }
    await rm(mine, { recursive: true, force: true });
    return { ok: true, removed };
  }

  /// Shown: of its workspace here, its agents told once where it runs now; its jobs are the jobs module's to start.
  async #show(i: In, sends: KeptSend[]): Promise<Json> {
    const t0 = this.#d.fibers.now();
    // (asked again after it was shown, too: what is kept of its messages there may have grown)
    // (only of its own threads here: another's are not this hand-over's to keep)
    const homes = new Set(i.keys.map((k) => this.#d.store.homeChat(k)?.id));
    this.#d.keepSends?.(sends.filter((x) => typeof x?.thread === "number" && homes.has(x.thread)));
    // (shown again, after what was said where it was meanwhile came: taken up)
    if (i.step === "shown") {
      for (const k of i.keys) this.#d.hub.wakeChat(k);
      return { ok: true };
    }
    const home = this.#d.home();
    // (one that arrives stopped is held before it is shown: no turn starts)
    // (what it waits for is where it came from)
    if (i.stoppedFor) await this.#d.arrivedStopped?.(i.keys, { ...i.stoppedFor, at: i.origin }, i.ws);
    for (const [connect, key] of Object.entries(i.bindings ?? {})) if (this.#d.store.binding(connect) === null) this.#d.store.setBinding(connect, key);
    // (its usage as all its calls here say it, those it came with and any it had here before: told as it is shown)
    this.#usageOf(i.keys, true);
    this.#d.store.showChat(i.keys, i.ws === home ? null : i.ws);
    if ((i.ctx.counts.rows.usage ?? 0) > 0) this.#d.store.usageChanged(i.keys);
    await this.#endOuts(i.keys);
    await this.#trimIns(i);
    const from = this.#d.roster(i.ws)?.find((s) => s.id === i.origin)?.name || i.origin.slice(0, 12);
    for (const k of i.keys) {
      const row = this.#d.store.getSession(k);
      if (row === null) continue;
      this.#d.store.setMovedNote(k, movedHere(from, row.workspace, i.ctx.fromData, this.#d.data));
    }
    i.step = "shown";
    await this.#saveIn(i);
    this.#letIn(i.id);
    this.#d.store.forgetImport(i.id);
    // (what came for it, a file a hash as many as its room has, removed after it is shown, not while it waits: moved
    // out of the way first)
    const gone = join(dir(this.#d.data), "in", `.gone-${i.id}`);
    await rename(join(dir(this.#d.data), "in", i.id), gone).catch(() => {});
    void rm(gone, { recursive: true, force: true }).catch(() => {});
    for (const k of i.keys) this.#d.hub.wakeChat(k);
    await this.#d.shown?.(i.keys, i.origin);
    this.#spent(i, "show", t0);
    const ms = { ...(i.spent ?? {}) };
    log.info("handover", "a chat handed here goes on here", { id: i.id, origin: i.origin, keys: i.keys.length, ms, total: Math.round(this.#d.fibers.now() - i.at) });
    return { ok: true };
  }

  /// Sessions `keys`' usage as all their calls here say it (usage/module.ts `keepUsage`): the calls a chat came with and
  /// any it had here before, added up, its context the latest call's. One with no call here keeps what it came with.
  /// `quiet`: not told as a change of the session.
  #usageOf(keys: readonly string[], quiet: boolean): void {
    for (const k of keys) {
      if (!hasUsage(this.#d.store.db, k)) continue;
      const usage = usageNow(this.#d.store, k);
      if (usage !== null) this.#d.store.setSessionUsage(k, usage, quiet);
    }
  }

  // ── the calls of chats handed away before their calls went with them ──

  /// The stations caught up with (none left to send them), and those being sent to now (one run a station).
  readonly #usageCaughtUp = new Set<string>();
  readonly #usageRuns = new Map<string, Promise<void>>();
  /// The last session sent to each station (`usageSyncedFile`), read once; its writes one after another.
  #usageSynced: Promise<Record<string, string>> | null = null;
  #usageSaving: Promise<void> = Promise.resolve();

  /// The calls kept here of the chats handed from here to `station` (every station chats went to, where none is
  /// named) before they went with them (a station from before, the real run of 2026-11-16: 2,489 chats' calls left on
  /// Office-VM-1, none on Office-Host-2), sent there: as this station starts and as that one is heard from, a chat at a
  /// time from where the last run left off, each a page of calls at a time, put in there only where it is the chat's
  /// (`handover.usage`). Nothing asked where none of them has a call; one that does not take them yet (a station from
  /// before) ends the run, to be taken up as it is heard from again.
  #syncHandedUsage(station?: string): void {
    if (this.#closed || !this.#ready) return;
    if (station !== undefined && (this.#usageCaughtUp.has(station) || this.#usageRuns.has(station))) return;
    for (const to of station !== undefined ? [station] : handedStations(this.#d.store.db)) {
      if (to === this.#d.here() || this.#usageCaughtUp.has(to) || this.#usageRuns.has(to)) continue;
      const run = this.#usageWith(to)
        .catch((e) => log.warn("handover", "the calls of chats handed before not sent", { to: to.slice(0, 12), error: (e as Error).message }))
        .finally(() => void this.#usageRuns.delete(to));
      this.#usageRuns.set(to, run);
    }
  }

  /// The stations whose chats are looked at again from the first (`#usageAgainFor`): taken up by the run to them.
  readonly #usageAgain = new Set<string>();

  #usageCursor(): Promise<Record<string, string>> {
    return (this.#usageSynced ??= readFile(usageSyncedFile(this.#d.data), "utf8").then((t): Record<string, string> => {
      const v = JSON.parse(t);
      return v !== null && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, string>) : {};
    }).catch(() => ({} as Record<string, string>)));
  }

  /// How far the calls were sent to each station, written (one write after another).
  async #saveUsageCursor(synced: Record<string, string>): Promise<void> {
    const save = this.#usageSaving.then(() => writeJson(usageSyncedFile(this.#d.data), synced));
    this.#usageSaving = save.catch(() => {});
    await save;
  }

  /// A chat went to `to` without its calls (a station from before): its chats looked at again from the first, as the
  /// sessions' keys are in no order of when they went (one before where the last run stopped would be passed for
  /// good). What is there already is not put in again (`putUsage`): only what lacks there is sent and taken.
  async #usageAgainFor(to: string): Promise<void> {
    this.#usageCaughtUp.delete(to);
    this.#usageAgain.add(to);
    const synced = await this.#usageCursor();
    if (synced[to] === undefined) return;
    delete synced[to];
    await this.#saveUsageCursor(synced);
  }

  async #usageWith(to: string): Promise<void> {
    const synced = await this.#usageCursor();
    let sent = 0;
    for (;;) {
      if (this.#closed) return;
      if (this.#usageAgain.delete(to) && synced[to] !== undefined) {
        delete synced[to];
        await this.#saveUsageCursor(synced);
      }
      const batch = handedWithUsage(this.#d.store.db, to, typeof synced[to] === "string" ? synced[to] : "", 10);
      if (batch.length === 0) break;
      for (const h of batch) {
        if (this.#closed) return;
        if (!(await this.#sendUsage(h, to, h.there, 0))) return;
        // (looked at again from the first meanwhile: not past this one)
        if (this.#usageAgain.has(to)) break;
        synced[to] = h.session;
        sent++;
        await this.#saveUsageCursor(synced);
        await new Promise<void>((resolve) => setImmediate(resolve));
      }
    }
    this.#usageCaughtUp.add(to);
    if (sent > 0) log.info("handover", "the calls of chats handed before sent", { to: to.slice(0, 12), chats: sent });
  }

  /// The calls of chat `h` handed from here sent to `to` (`there`: its home thread there), a page at a time: whether
  /// that station took them, or said they are not its (none of the chat's there: where it went on from there, followed
  /// there, `hop` the stations followed); false where it did not answer them (not reached, from before).
  async #sendUsage(h: HandedUsage, to: string, there: number | null, hop: number): Promise<boolean> {
    const d = this.#d;
    const here = d.here();
    const ws = h.ws ?? d.home();
    if (here === null || ws === null || !WORKSPACE.test(ws)) return true;
    // (one that went with its calls: there already)
    const latest = this.#outsOf.get(h.session)?.[0];
    if (hop === 0 && latest !== undefined && latest.to === to && latest.usage === true && (latest.step === "gone" || latest.step === "done")) return true;
    const id = `usage-${createHash("sha256").update(h.session).digest("hex").slice(0, 32)}`;
    const db = d.store.db;
    const connect = d.store.getSession(h.session)?.connect ?? "";
    let usageAfter: Json = null;
    let filesAfter: Json = null;
    let usageDone = false;
    let filesDone = false;
    for (;;) {
      const usage: Json[] = usageDone ? [] : d.store.chatPage("usage", h.session, usageAfter, 500);
      const files: Json[] = filesDone ? [] : d.store.chatPage("usage_files", h.session, filesAfter, 500);
      usageDone = usage.length < 500;
      filesDone = files.length < 500;
      if (usage.length > 0) usageAfter = afterOf("usage", usage.at(-1)!);
      if (files.length > 0) filesAfter = afterOf("usage_files", files.at(-1)!);
      const last = usageDone && filesDone;
      const threads: ThreadRef[] = threadRefs(db, h.session, usage.flatMap((r: Json) => (typeof r.thread === "number" ? [r.thread as number] : [])));
      const used = [...new Set([connect, ...threads.map((t) => t.connect ?? "")].filter((c) => c !== ""))];
      const connects = connectsThere(used.filter((c) => !isInternal(c)), used, here, to);
      const accounts = Object.fromEntries([...new Set<string>(usage.flatMap((r: Json) => (typeof r.profile === "string" ? [r.profile as string] : [])))].map((p) => [p, d.accounts.of(p)]));
      const sessionUsage = last ? ((d.store.chatPage("session_usage", h.session, null)[0]?.usage as string | undefined) ?? null) : null;
      let answer: Json;
      try {
        answer = await d.ask(to, { method: "handover.usage", workspace: ws, origin: here, id, session: h.session, thread: h.thread, there, threads, connects, accounts, dataDir: d.data, usage, files, sessionUsage, last });
      } catch (e) {
        log.info("handover", "the calls of a chat handed before not taken there yet", { to: to.slice(0, 12), error: (e as Error).message });
        return false;
      }
      if (answer?.skipped === true) {
        const next = typeof answer.forwardedTo === "string" && STATION.test(answer.forwardedTo) ? answer.forwardedTo : null;
        // (gone on from there: followed, two stations at most; one that does not take them is left, not waited for)
        if (next !== null && next !== here && hop < 2 && !(await this.#sendUsage(h, next, typeof answer.there === "number" ? answer.there : null, hop + 1))) {
          log.info("handover", "the calls of a chat handed on from where it went not sent", { to: next.slice(0, 12) });
        }
        return true;
      }
      if (last) return true;
    }
  }

  /// A page of the calls of a chat handed here before they went with it, put in where the chat is this station's now:
  /// its threads found here (its home by `there`, the rest by their place), its accounts as they are here, its usage
  /// as all its calls here say it (none here: as that station kept it, where none is kept here). Where it is not
  /// (gone on from here, not here at all, on its way): said `skipped`, with where it went on to.
  async #takeUsage(peer: string, ws: string, request: Json): Promise<Json> {
    const store = this.#d.store;
    const session = typeof request.session === "string" ? request.session : "";
    const usage = Array.isArray(request.usage) ? request.usage : [];
    const files = Array.isArray(request.files) ? request.files : [];
    const refs = Array.isArray(request.threads) ? request.threads : [];
    if (session === "" || usage.length > 500 || files.length > 500 || refs.length > 500) throw new Refused(why("badRequest", { detail: "not a page of a chat's calls" }));
    const handed = store.handedTo(session);
    if (store.liveOf([session]).length === 0 || handed !== null || this.#d.hub.wsOf(session) !== ws) {
      return { ok: true, skipped: true, ...(handed !== null && handed.station !== peer ? { forwardedTo: handed.station, there: handed.there } : {}) };
    }
    const strings = (v: Json) => Object.fromEntries(Object.entries(v ?? {}).filter((e): e is [string, string] => typeof e[1] === "string"));
    const connects = strings(request.connects);
    const threads: Record<string, number | null> = {};
    for (const r of refs) {
      if (typeof r?.id !== "number" || typeof r.surface !== "string" || typeof r.channel !== "string" || typeof r.threadTs !== "string") continue;
      threads[String(r.id)] = r.id === request.thread && typeof request.there === "number" ? request.there : threadOfRef(store.db, session, r as ThreadRef, connects);
    }
    const profiles: Record<string, string> = {};
    for (const [pid, a] of Object.entries((request.accounts ?? {}) as Record<string, AccountOf | null>)) {
      const there = a !== null && typeof a === "object" ? this.#d.accounts.here(a) : null;
      if (there !== null) profiles[pid] = there;
    }
    const took = importHandedUsage(store.db, { session, threads, profiles, fromData: String(request.dataDir ?? ""), toData: this.#d.data, usage, files });
    // (its last page, too, though nothing was new: one taken before as this station stopped is kept as its calls say)
    if (took.added > 0 || (request.last === true && hasUsage(store.db, session))) {
      this.#usageOf([session], false);
      if (took.added > 0) store.usageChanged([session]);
    } else if (typeof request.sessionUsage === "string" && !hasUsage(store.db, session) && store.sessionUsage(session) === null) {
      // (none of its calls here, nor its usage: as that station kept it)
      try {
        store.setSessionUsage(session, JSON.parse(request.sessionUsage));
      } catch {}
    }
    return { ok: true, added: took.added, files: took.files };
  }

  #holdIn(i: In): void {
    if (i.step === "coming" && !this.#inHeld.has(i.id) && this.#d.hold !== undefined) this.#inHeld.set(i.id, this.#d.hold());
  }

  /// Chats `keys` came here: every hand-over of them from here before is over for good, whatever its step (none replayed
  /// as a start, none told again).
  /// What is kept of them is bounded: an ended record is dropped once a newer ended one names all its chats (a chat
  /// handed about for a year keeps one), never the newest.
  async #endOuts(keys: readonly string[]): Promise<void> {
    const theirs = this.#outsAt(keys, "end");
    for (const o of theirs) {
      if (o.ended === true || (o.step !== "gone" && o.step !== "done")) continue;
      o.step = "done";
      o.ended = true;
      this.#again.get(o.id)?.();
      this.#again.delete(o.id);
      await this.#save(o);
    }
    // (of these chats' records, as they were looked at: one newer that names all of a record's chats names the one of
    // them that came here, so it is among these)
    const ended = theirs.filter((o) => o.ended === true);
    for (const o of ended) {
      const newer = ended.some((n) => n !== o && n.at >= o.at && n.id !== o.id && o.keys.every((k) => n.keys.includes(k)) && (n.at > o.at || n.id > o.id));
      if (!newer) continue;
      this.#forgetOut(o);
      await rm(outFile(this.#d.data, o.id), { force: true });
      await rm(endFile(this.#d.data, o.id), { force: true });
    }
  }

  /// Of a chat's arrivals here the newest record is kept (`i`, shown): an older one, shown or dropped, goes, never one
  /// still coming, nor while a record from before (no `v: 2`) of that chat that `#cameBack` judges by it stands unended.
  async #trimIns(i: In): Promise<void> {
    const judged = (k: string) => this.#outsAt([k], "trimJudged").some((o) => o.v !== 2 && o.ended !== true);
    // (one whose chats are all `i`'s is among `i`'s chats' own)
    for (const old of this.#insAt(i.keys, "trim")) {
      if (old.id === i.id || old.step === "coming" || !old.keys.every((k) => i.keys.includes(k)) || old.keys.some(judged)) continue;
      this.#forgetIn(old);
      await rm(inFile(this.#d.data, old.id), { force: true });
    }
  }

  #letIn(id: string): void {
    this.#inHeld.get(id)?.();
    this.#inHeld.delete(id);
    for (const done of this.#settledIn.get(id) ?? []) done();
    this.#settledIn.delete(id);
  }

  /// What waits for a hand-over coming here to be shown here or dropped (by its id).
  readonly #settledIn = new Map<string, (() => void)[]>();

  /// The chats of workspace `ws` coming here now (by their keys, sorted): a hand-over begun here, not shown nor dropped
  /// yet. Few at a time, read from the records kept of them.
  comingIn(ws: string): string[][] {
    this.#look("comingIn", this.#comingIns.size);
    return [...this.#comingIns].filter((i) => i.step === "coming" && i.ws === ws).map((i) => [...i.keys].sort());
  }

  /// The station chat `key` is coming here from now (a hand-over of it begun here, not shown nor dropped yet): it waits
  /// for that station to go on with it. Null: none.
  comingFrom(key: string): string | null {
    return this.#insAt([key], "comingFrom").find((i) => i.step === "coming")?.origin ?? null;
  }

  /// Once no hand-over of chat `key` coming here is still coming: each shown here (its rows the chat's, `showChat`) or
  /// dropped. What brought it back waits for this: the station it came from may have gone on without having been
  /// answered that it is shown here (its word lost on the way), telling it again by its retry.
  /// `withinMs`: waited no longer (the clock's): false where one is still coming then.
  async arrived(key: string, withinMs?: number): Promise<boolean> {
    for (const i of this.#insAt([key], "arrived")) {
      if (i.step !== "coming" || this.#closed) continue;
      let late = () => {};
      const shown = new Promise<boolean>((resolve) => {
        const list = this.#settledIn.get(i.id) ?? [];
        list.push(() => resolve(true));
        this.#settledIn.set(i.id, list);
        if (withinMs !== undefined) late = this.#d.fibers.after(withinMs, () => resolve(false)); // timer: the most a move back waits for its chat to be shown
      });
      const ok = await shown;
      late();
      if (!ok) return false;
    }
    return true;
  }

  /// `path`, replaced or pruned by hand-over `i`, moved aside the first time (`inAside`'s list says where it was).
  /// The directories a placing made for what it put, left empty as that is taken out: removed, up to the rooms'
  /// roots (one that holds anything stays, and so does everything above it).
  async #emptied(at: string): Promise<void> {
    for (let d = at; ; d = dirname(d)) {
      const parts = relative(this.#d.data, d).split(sep);
      // (never the data directory's own, `sessions/` nor a runtime's `transcripts*/<runtime>/`, nor a profile's home up
      // to where its Antigravity CLI keeps a conversation, carry.ts `cliKept`)
      if (parts[0] === "" || parts[0] === ".." || isAbsolute(parts[0]!) || parts.length <= (parts[0]!.startsWith("transcripts") ? 2 : parts[0] === "homes" ? 6 : 1)) return;
      if (!(await rmdir(d).then(() => true, () => false))) return;
    }
  }

  /// Whether there was one.
  async #putAside(i: In, path: string): Promise<boolean> {
    if (!(await lstat(path).then(() => true, () => false))) return false;
    const aside = inAside(this.#d.data, i.id);
    const list = join(aside, "list.txt");
    const had = await readFile(list, "utf8").catch(() => "");
    const made = await readFile(inMade(this.#d.data, i.id), "utf8").catch(() => "");
    if (had.split("\n").some((l) => l.split("\t")[0] === path) || made.split("\n").includes(path)) {
      await rm(path, { force: true });
      return true;
    }
    await mkdir(aside, { recursive: true });
    const name = `${createHash("sha256").update(path).digest("hex").slice(0, 32)}-${randomBytes(4).toString("hex")}`;
    try {
      await rename(path, join(aside, name));
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code === "ENOENT") return false;
      throw e;
    }
    await writeFile(list, `${path}\t${name}\n`, { flag: "a" });
    return true;
  }

  /// What a hand-over that did not go put in here, taken out: its rows (store `dropImport`) and the files placed where
  /// nothing was; what it replaced or pruned put back.
  /// Hand-over `i` dropped: nothing more of it taken from now, its rows out and its record saying so (`marked`), then
  /// its files taken out once what it was doing to them ended (`files`), by this station itself: what asked it waits
  /// only for `marked`, whatever its files.
  #dropSoon(i: In): { marked: Promise<void>; files: Promise<void> } {
    const was = this.#drops.get(i.id);
    if (was !== undefined) return was;
    this.#dropping.add(i.id);
    let marked: Promise<void> = Promise.resolve();
    if (i.dropping !== true) {
      this.#d.store.dropImport(i.ctx);
      this.#d.store.forgetImport(i.id);
      i.dropping = true;
      marked = this.#saveIn(i);
    }
    const drop = { marked, files: Promise.resolve() };
    drop.files = marked.then(() => this.#serialIn(i, () => this.#dropIn(i), true)).then(
      () => void this.#dropping.delete(i.id),
      (e) => log.warn("handover", "a chat coming here not all taken out: its next start takes out the rest", { id: i.id, error: (e as Error)?.message ?? String(e) }),
    ).finally(() => void (this.#drops.get(i.id) === drop && this.#drops.delete(i.id)));
    this.#drops.set(i.id, drop);
    return drop;
  }

  /// `f`, after what hand-over `i` was doing to its files here ended, and (but for a drop's own) after the drops of
  /// older hand-overs of its chat under way here: what they take out is never what it puts.
  #serialIn<T>(i: In, f: () => Promise<T>, drop = false): Promise<T> {
    const older = drop ? [] : this.#insAt(i.keys, "serial").flatMap((o) => (o.id !== i.id ? [this.#drops.get(o.id)?.files ?? null] : [])).filter((p): p is Promise<void> => p !== null);
    const before = Promise.all([this.#inWork.get(i.id) ?? Promise.resolve(), ...older]);
    const run = before.then(f, f);
    const settled = run.catch(() => {});
    this.#inWork.set(i.id, settled);
    void settled.then(() => {
      if (this.#inWork.get(i.id) === settled) this.#inWork.delete(i.id);
    });
    return run;
  }

  async #dropIn(i: In): Promise<Json> {
    if (i.step === "dropped") return { ok: true };
    if (i.step === "shown") throw new Refused(why("shownHere"));
    await this.#work.drop?.(i.id);
    // What git made for it: each worktree's own `.git` taken out and its registration with it (`worktree prune`), the
    // branch and the ref it made there deleted; the repository and all it had before stay.
    const gits = new Map<string, MadeGit>();
    for (const line of (await readFile(inGits(this.#d.data, i.id), "utf8").catch(() => "")).split("\n")) {
      try {
        const m = JSON.parse(line) as MadeGit;
        const was = gits.get(m.dir);
        gits.set(m.dir, { ...m, branch: m.branch ?? was?.branch ?? null, ref: m.ref ?? was?.ref ?? null });
      } catch {}
    }
    for (const m of gits.values()) {
      if (this.#d.git === undefined || !carriedPlace(this.#d.data, join(m.dir, ".git"))) continue;
      // (its registration is the directory its `.git` names in the repository: that one alone, never a prune of others)
      for (const at of [join(m.dir, ".git"), join(`${m.dir}.git-carrying`, ".git")]) {
        const named = /^gitdir: (.+)$/m.exec(await readFile(at, "utf8").catch(() => ""))?.[1]?.trim();
        const ours = named === undefined ? false : (await realpath(dirname(named)).catch(() => "")) === (await realpath(join(m.repo, ".git", "worktrees")).catch(() => null));
        if (ours) await rm(named!, { recursive: true, force: true }).catch(() => {});
        await rm(at, { force: true }).catch(() => {});
      }
      await rm(`${m.dir}.git-carrying`, { recursive: true, force: true }).catch(() => {});
      if (m.branch !== null) await this.#d.git(m.repo, ["branch", "-D", m.branch]).catch(() => {});
      if (m.ref !== null) await this.#d.git(m.repo, ["update-ref", "-d", m.ref]).catch(() => {});
      await this.#emptied(m.dir);
    }
    const made = await readFile(inMade(this.#d.data, i.id), "utf8").catch(() => "");
    for (const path of made.split("\n")) {
      if (path === "") continue;
      await rm(path, { force: true }).catch(() => {});
      await this.#emptied(dirname(path));
    }
    const aside = inAside(this.#d.data, i.id);
    for (const line of (await readFile(join(aside, "list.txt"), "utf8").catch(() => "")).split("\n")) {
      const [path, name] = line.split("\t");
      if (path === undefined || name === undefined || path === "") continue;
      await rm(path, { recursive: true, force: true }).catch(() => {});
      await mkdir(dirname(path), { recursive: true }).catch(() => {});
      await rename(join(aside, name), path).catch(() => {});
    }
    i.step = "dropped";
    this.#letIn(i.id);
    await this.#saveIn(i);
    await rm(join(dir(this.#d.data), "in", i.id), { recursive: true, force: true });
    return { ok: true };
  }
}

/// `path`'s real path, the part of it not there yet as it is (station/mb carry.mbt `real_of`, off the main thread's way).
async function realOfSoon(path: string): Promise<string> {
  const rest: string[] = [];
  for (let at = path; ; at = dirname(at)) {
    const real = await realpath(at).catch(() => null);
    if (real !== null) return join(real, ...rest.reverse());
    if (dirname(at) === at) return path;
    rest.push(basename(at));
  }
}

/// Whether the file at `path` (under `data`'s rooms) is the one described already: of its size, and of its time or its
/// bytes' hash (read off the main thread's way, a stream), the bytes read taken from `budget`: `later` where they would
/// take more than is left of it, `no` for a file larger than all of it (not read: sent).
async function inPlace(path: string, data: string, f: { hash: string; size: number; mtimeMs?: number | null }, budget: { left: number; most: number }): Promise<"yes" | "no" | "later"> {
  if (!carriedPlace(data, path)) return "no";
  const st = await stat(path).catch(() => null);
  if (st === null || !st.isFile() || st.size !== f.size) return "no";
  if (typeof f.mtimeMs === "number" && Math.trunc(st.mtimeMs) === Math.trunc(f.mtimeMs)) return "yes";
  if (st.size > budget.most) return "no";
  if (st.size > budget.left) return "later";
  budget.left -= st.size;
  const h = createHash("sha256");
  for await (const piece of createReadStream(path)) h.update(piece as Buffer);
  return h.digest("hex") === f.hash ? "yes" : "no";
}

/// Where what was sent and what it has differ, in words (null: they do not).
function differ(sent: Counts, there: Counts): string | null {
  if (sent.sessions !== there.sessions) return why("countSessions", { sent: sent.sessions, there: there.sessions });
  for (const k of ["entries", "letters"] as const) {
    for (const [t, n] of Object.entries(sent[k])) if ((there[k][t] ?? 0) !== n) return why("countThread", { sent: n, what: k, there: there[k][t] ?? 0 });
  }
  for (const [t, n] of Object.entries(sent.rows)) if ((there.rows[t] ?? 0) !== n) return why("countRows", { sent: n, table: t, there: there.rows[t] ?? 0 });
  return null;
}

/// Still.fail's own chats' connect (sessions/internal.ts), and the one of before.
const isInternal = (c: string) => c === "ember" || c === "chat";
/// Whether a connect's chats are routed to the station a chat of it runs on (connects/remote.ts ROUTED).
const routed = (k: { kind: string; mode: string }) => k.mode !== "single-session" && (k.kind === "slack" || k.kind === "feishu");

/// What a chat handed here is told once, as its next turn starts: where it runs now, where its files are.
export function movedHere(from: string, workspace: string, fromData: string, toData: string): string {
  const lines = [`<chat-moved>This chat was handed here from station ${from}: it goes on on this station.`];
  if (fromData !== "" && fromData !== toData) lines.push(`Its files were under ${fromData} and are under ${toData} now: a path you noted under the old one is the same under the new one (your working directory is ${moved(workspace, fromData, toData)}).`);
  lines.push("Its background jobs are started again here as they move; nobody asked anything of you by this, and it is said once.</chat-moved>");
  return lines.join("\n");
}
