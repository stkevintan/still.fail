// GET /events: what changed, as it changes, pushed. Changes that come in a burst go out
// as one event per session, and one round of the shared chat list; a thread's entries go out as they are written; `host` adds
// host samples, `job` a job's output as it grows, `live` sessions as they run. Keepalives and host samples only while
// someone follows. The same event names and data as the Rust station's; what is told to everyone also carries an
// `id:`, its number in the log of it (event-log.ts: `<run>.<n>`), which clients from before ignore.
//
// The sessions at work are the station's to follow: a stream asked `running=1` is told what every one its viewer sees
// does as it does it (sessions/live.ts `running`), from where each stood as the stream opened, and a session starting
// asks nothing of any client (FOLLOWS). With `spare=1` and `open=<key>` (cellular networks), only those open sessions'
// live events are sent (SPARED). Nothing of before is told: a device reads what it lacks of a transcript as it
// reads anything it lacks, knowing from a session's summary how far its transcript goes (`transcriptLength`).
//
// A client's stream is replaced by another whenever what it follows changes (a client from before, naming the sessions
// it follows: one starts or stops running; any client: what a page shows of the host, a job's log, a login): what
// was told to everyone between the new one being asked for and its being here went only to the old one, and was lost
// where the client let go of the old one before it had read that. So what is told to everyone is kept a while, and a
// stream asked for `since` the last id its predecessor gave is first told again what came after it (the same ids), or
// `missed` when that is not kept any more (or was another run's): the client then reads the station again.
//
// The same goes for a stream that comes back after its link went down (on a weak link, every minute or so: the link
// moved to a better way, or lost its way): told what it missed, a client reads nothing again, where it used to read all
// the station holds (a slow link's minutes). So while a viewer may come back (KEPT_MS after the last stream went) what is
// told is still made and kept; a viewer's overview is told against what their streams were told last (one telling for
// all their streams, kept like the rest), and the one that comes back is told how it stands now. Each device makes its
// sidebar and a thread's summary itself from what it is told (client/core-ts/src/station/rows-after.ts,
// thread-after.ts): a station makes neither for a viewer (cores before api/oldest.ts OLDEST_CORE, which needed them,
// are refused). Its answer
// says it was (`stillfail-resumed: 1`). Past KEPT_MS with nobody, nothing more is made, and nothing before can be resumed.
//
// The same again when the station process is replaced (an update: on a station 32 a day, each with every device's streams
// cut): what is kept, and what each viewer's streams were told of their overview, go over to the next
// process (`handOver`, `takeUp`), which goes on with the same run and numbers, made and kept as while nobody follows,
// so a stream that comes back to it is resumed as the old one would have. What it is to tell before then waits, and is
// told after what it goes on from. Not resumed there, each device read all the station holds at once, while the new
// process was starting (it stopped answering up to 13 s). A crash hands nothing over: its streams are told they missed
// it; nor does one the next stopped waiting for (what it hands over late is older than what the next told since).
//
// Where the Rust re-read a job's log every second, a log is watched (fs.watch).
//
// What is said in a thread is told as the store wrote it: its entries come with the change, and are made into what the
// pages show here (`said`), with nothing read first. What else a change touches (the shared chat list, a session's
// summary, a job) is read by the station's own reader (`told`: read/pool.ts), which nothing a device asks
// takes: on a station (2026-11-02) both shared two readers, and a message just said was told 50 s late.
import { type FSWatcher, watch } from "node:fs";
import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { type Viewer, managesStation, readOnly } from "../mesh/credential.ts";
import type { Lang } from "../ops/i18n.ts";
import { log } from "../ops/log.ts";
import type { Readers } from "../read/pool.ts";
import { type EntryRow, type StoreChange, sees } from "../store/rows.ts";
import type { Answer } from "./request.ts";
import type { Clock } from "effect";
import { Fibers } from "../ops/fibers.ts";
import { EventLog, KEPT_MS, type Kept } from "./event-log.ts";

const PING_MS = 25_000;
const HOST_MS = 10_000;
/// What the agents spent is told at most this often (the first change at once, the last at the end of the while): it
/// changes with every model call, some seconds apart while agents work, and each telling has a page showing usage read
/// again what changed (every client from before it, all of it: some 200 KB).
const USAGE_EVERY_MS = 60_000;
/// Background overview changes (process state, profile checks, backup progress, decision checks) coalesce so bursts
/// emit one full overview at most this often; direct `overviewChanged()` calls remain immediate.
const OVERVIEW_SOON_MS = 10_000;
/// Low-disk warning threshold matching client/core-ts/src/views/models.ts (`<= 10 GiB` or `<= 10%` of totalBytes).
const LOW_DISK_BYTES = 10 * 1024 * 1024 * 1024;
/// Bucket size for free-disk bytes when truly low (`<= 10 GiB`): matches whole-GB display without per-write churn.
const LOW_DISK_STEP = 512 * 1024 * 1024;
/// Bucket size for drives above 10 GiB free that are still `<= 10%` free (e.g. 94 GiB / 1858 GiB): 1% of the drive,
/// within 2 to 4 GiB, so the free space a warning says is never further off than that.
const PCT_DISK_MIN_STEP = 2 * 1024 * 1024 * 1024;
const PCT_DISK_MAX_STEP = 4 * 1024 * 1024 * 1024;
/// Bucket size for when a healthy backup place was last brought level: the row says it as "N minutes ago"
/// (client/core-ts/src/copies.ts), so it is told again as it moves on, not at every pass.
const COPIES_AT_STEP_MS = 10 * 60_000;

/// Comparable snapshot of an overview for `overviewTold` deduplication: omits volatile machine telemetry, process
/// RSS drift, and healthy backup progress ticks (when a place was last level is kept in steps: the row says it), and
/// normalizes free-disk bytes while preserving low-disk warning transitions. The emitted event still carries the exact
/// overview.
export function overviewComparable(value: unknown): string {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return JSON.stringify(value);
  const src = value as Record<string, unknown>;
  const out: Record<string, unknown> = { ...src };
  delete out.machine;
  const disk = src.disk;
  if (disk !== null && typeof disk === "object" && !Array.isArray(disk)) {
    const d = disk as Record<string, unknown>;
    const free = d.freeBytes;
    if (typeof free === "number") {
      const total = typeof d.totalBytes === "number" ? d.totalBytes : 0;
      let bucket: string;
      if (free <= LOW_DISK_BYTES) bucket = `low:${Math.floor(free / LOW_DISK_STEP)}`;
      else if (total > 0 && free * 10 <= total) bucket = `pct:${Math.floor(free / Math.min(PCT_DISK_MAX_STEP, Math.max(PCT_DISK_MIN_STEP, Math.floor(total / 100))))}`;
      else bucket = "ok";
      out.disk = { ...d, freeBytes: bucket };
    }
  }
  if (Array.isArray(src.processes)) {
    out.processes = src.processes.map((p) => {
      if (p === null || typeof p !== "object" || Array.isArray(p)) return p;
      const { rssMb: _, ...rest } = p as Record<string, unknown>;
      return rest;
    });
  }
  const copies = src.copies;
  if (copies !== null && typeof copies === "object" && !Array.isArray(copies)) {
    const c = copies as Record<string, unknown>;
    const headTo = typeof c.to === "number" ? c.to : 0;
    const normTarget = (item: unknown) => {
      if (item === null || typeof item !== "object" || Array.isArray(item)) return item;
      const t = item as Record<string, unknown>;
      const { to: tTo, at: tAt, ...rest } = t;
      const synced = typeof tTo === "number" && headTo > 0 ? tTo >= headTo : tTo === headTo;
      return { ...rest, synced, at: typeof tAt === "number" ? Math.floor(tAt / COPIES_AT_STEP_MS) : (tAt ?? null) };
    };
    // (whether it has chats at all decides what is offered on it: the count beyond that is progress)
    const { to: _to, chats, ...restCopies } = c;
    const normCopies: Record<string, unknown> = { ...restCopies, hasData: headTo > 0, hasChats: typeof chats === "number" ? chats > 0 : (chats ?? null) };
    if (Array.isArray(c.keepers)) normCopies.keepers = c.keepers.map(normTarget);
    if (c.backup !== null && typeof c.backup === "object" && !Array.isArray(c.backup)) {
      const b = c.backup as Record<string, unknown>;
      normCopies.backup = Array.isArray(b.s3) ? { ...b, s3: b.s3.map(normTarget) } : b;
    }
    out.copies = normCopies;
  }
  return JSON.stringify(out);
}
/// What the streams tell is read by the station's own reader (read/pool.ts), never behind what a device asked.
const TOLD = { told: true };
/// A stream's answer when it was told first what came after `since` (the client then reads nothing again).
export const RESUMED = "stillfail-resumed";
/// With RESUMED: where the log was as the stream joined (`<run>.<n>`). What it tells up to it is told again, what came
/// while the client was not here; after it, as it happens (the client's app moves only what happens as it is watched).
export const HEAD = "stillfail-head";
/// A stream's answer when it was asked `running=1` and is told what every session at work its viewer sees does, as it
/// does it, without asking for any (`live` events, from where each stood as it was opened; nothing of before): the
/// client then follows no session by name, and reads what it lacks of a transcript as it reads anything it lacks.
export const FOLLOWS = "stillfail-follows";
/// A running-session snapshot includes each current output rate, and a quiet rate is cleared.
export const LIVE_RATES = "stillfail-live-rates";
/// A stream's answer when it was asked `running=1&spare=1` and is told `live` events only for the open sessions it named.
export const SPARED = "stillfail-spared";

/// Where what is told goes over to the next process at a handover (`handOver`), in the data directory: beside the hub's
/// sessions (sessions/hub.ts `handoverFile`).
export const eventsHandoverFile = (dataDir: string) => join(dataDir, "run", "events.json");

/// What the events need of the rest of the station.
export type EventsDeps = {
  readers: Readers;
  /// What was just said in a thread (its entries, or its letters, as the store wrote them), as the pages show it (read/
  /// views.ts `entryViews`: with its authors' names), in `lang`: made on this thread, nothing waited on.
  said(thread: number, entries: EntryRow[], lang: Lang): unknown[];
  /// Its time (a TestClock in tests).
  clock?: Clock.Clock;
  subscribe(listener: (change: StoreChange) => void): () => void;
  /// A host sample (GET /host's answer).
  host(): Promise<unknown>;
  /// A job's log path (watched for changes), and its last `lines` as GET /jobs/:id/log answers them, read by the
  /// readers (null: the job is not there).
  jobLog(id: string): string | null;
  logNow(id: string, lines: number): Promise<{ text: string; outputAt: number | null } | null>;
  /// A session's live steps, from `from`, to `send`, until the returned function is called; its transcript
  /// entries in brief (`brief`, read/transcript.ts) for a client that asks so.
  live?(key: string, from: number, last: number | null, send: (message: unknown) => void, brief: boolean): () => void;
  /// The sessions at work the station follows itself (sessions/live.ts `running`), and each as it is now (where its
  /// transcript ends, the steps in flight): what a stream that follows them is told as it opens.
  held?(): string[];
  heldNow?(keys: string[]): Promise<Record<string, unknown[]>>;
  /// Whether a session is still there (a summary is told only of one that is).
  sessionExists(key: string): boolean;
  /// Whether a live result still belongs to a session visible to this viewer, in one lookup when available.
  liveSeen?(viewer: Viewer, key: string): boolean;
  /// The overview as `viewer` sees it, in `lang` (GET /overview); none until the agents' side is up.
  overview?(viewer: Viewer, lang: Lang): Promise<unknown>;
  /// A session's process state (the overview counts running and warm ones).
  processState?(key: string): string;
  /// Someone follows again, after nobody did (allowances are read again then).
  followed?(): void;
  /// Whether `viewer` sees a session, a thread or a job: those of their workspace's chats.
  /// None: every one.
  seen?(viewer: Viewer, of: { session: string } | { thread: number } | { job: string }): boolean;
  /// `seen` of every viewer, what it names looked up once (seen.ts `seerOf`): asked once for what is told to every stream.
  seer?(of: { session: string } | { thread: number } | { job: string }): (viewer: Viewer) => boolean;
  /// A login's terminal: `send` given its screen now and as it changes, until the returned
  /// function is called.
  loginScreen?(id: string, send: (screen: { rows: string[]; cursor: { x: number; y: number }; echo: boolean; live: boolean }) => void): () => void;
  /// Whether `viewer` is a member of that vault of their workspace now (vault/secrets.ts `inVault`): whom its requests
  /// are told to. None: of none.
  inVault?(viewer: Viewer, vault: string): boolean;
  /// Where what is told goes over to the next process (`eventsHandoverFile`), and the process before this one
  /// (ops/previous.ts: its pid, none when none held the station, and its end): what that one handed over is taken up
  /// once it is gone, and only what it did. None: nothing goes over.
  handover?: { file: string; previous: { pid: number | null; gone: Promise<void> } };
};

/// A viewer's streams in one language: what their sidebar and overview are told by. A person in two of the station's
/// workspaces is two viewers.
const viewerKey = (viewer: Viewer, lang: Lang) => `${viewer.email}\0${viewer.workspace}\0${lang}`;

/// Whom an event is for, as data (what is kept goes over to the next process with it): the streams all it says holds
/// of; nothing said, every one.
export type To = {
  /// Asked in that language.
  lang?: Lang;
  /// That viewer's in that language (`viewerKey`): their sidebar, their overview, a thread as they have it.
  viewer?: string;
  /// Whose viewer has that email (in any case), is in that workspace, is one of those people (`sub`), may only read or
  /// not (`readOnly`), or manages the station (`managers`: workspace owner or admin).
  email?: string;
  workspace?: string;
  subs?: string[];
  readOnly?: boolean;
  managers?: boolean;
  /// Whose viewer is a member of that vault of their workspace (`inVault`) as it is told: one who left it is not told
  /// of it again.
  vault?: string;
  /// Whose viewer sees that session, thread or job (`seen`), or the chats of that workspace (store/rows.ts `sees`; null:
  /// the home one).
  sees?: { session: string } | { thread: number } | { job: string } | { ws: string | null };
};

/// Whether `to` is for a stream of `viewer`'s in `lang`. `whose`: whether its viewer sees a session, a thread or a job
/// (none: every one), and is a member of a vault (none: of none).
export const isFor = (to: To, { viewer, lang }: { viewer: Viewer; lang: Lang }, whose: Pick<EventsDeps, "seen" | "inVault"> = {}): boolean =>
  (to.lang === undefined || to.lang === lang) &&
  (to.viewer === undefined || to.viewer === viewerKey(viewer, lang)) &&
  (to.email === undefined || to.email.toLowerCase() === viewer.email.toLowerCase()) &&
  (to.workspace === undefined || to.workspace === viewer.workspace) &&
  (to.subs === undefined || to.subs.includes(viewer.sub)) &&
  (to.readOnly === undefined || to.readOnly === readOnly(viewer)) &&
  (to.managers === undefined || to.managers === managesStation(viewer)) &&
  (to.vault === undefined || whose.inVault?.(viewer, to.vault) === true) &&
  (to.sees === undefined || ("ws" in to.sees ? sees(viewer, to.sees.ws) : (whose.seen?.(viewer, to.sees) ?? true)));

/// What goes over to the next process (`eventsHandoverFile`), by whom (`pid`) and when it was written: what the log
/// keeps, what each viewer's streams were told last of their overview, by `viewerKey`, who followed last, and the shared
/// chat list as it was told last.
type Handed = {
  pid: number; at: number; log: Kept<To>; overviews: [string, string][]; last: { viewer: Viewer; lang: Lang } | null;
  shared?: { rows: [string, string][]; until: number };
};

/// Removes what was handed over (taken up, or not to be): never a throw, as a stream waits on the taking up.
async function removeHanded(file: string): Promise<void> {
  try {
    await rm(file, { force: true });
  } catch (error) {
    log.warn("events", "what was handed over is not removed", { error: (error as Error).message });
  }
}

type Client = {
  id: number;
  viewer: Viewer;
  lang: Lang;
  host: boolean;
  /// Told what every session at work its viewer sees does (`running=1`, FOLLOWS).
  running: boolean;
  /// When non-null (`spare=1`), only these open session keys receive `live` events.
  spare: Set<string> | null;
  /// What is told of those it is told as they are now meanwhile, until it is (`heldNow`): then, after it.
  heldWaits?: Map<string, unknown[]>;
  send(event: string, data: unknown): void;
  raw(text: string): void;
  /// What it follows besides (live sessions, job logs): ended with it.
  stops: (() => void)[];
  /// Ends its stream from this side: its client opens another.
  end(): void;
};

export class Events {
  private clients: Client[] = [];
  private next = 1;
  /// What is told to everyone, kept for a stream that takes over from another or comes back (event-log.ts), or the
  /// process before this one's, gone on with (`takeUp`).
  private log = new EventLog<To>();
  /// With nobody following, the end of the while one may come back (KEPT_MS): what is told is still made until then.
  private lingering: (() => void) | null = null;
  /// Who followed last: whose names a thread's entries are read with while nobody does.
  private last: { viewer: Viewer; lang: Lang } | null = null;
  /// What each viewer's streams were last told of their overview (JSON), by viewer and language (`viewerKey`): what
  /// changes is told against it.
  /// The chat list as it was told last to every stream (row id → JSON). Kept while a stream may return, and handed over
  /// with the event log so changes during a handover are told too.
  private sharedTold: Map<string, string> | null = null;
  private sharedReading: Promise<void> | null = null;
  private openingShared = 0;
  private overviewTold = new Map<string, string>();
  private deps: EventsDeps;
  /// What changed since the last round: sessions (their events), the overview, and the sessions and threads whose rows
  /// of the shared chat list to read again (`items`), or all of it (`whole`).
  private dirty = Events.clean();
  private static clean() {
    return { sessions: new Set<string>(), overview: false, overviewOf: new Set<string>(), whole: false, items: { sessions: new Set<string>(), threads: new Set<number>() } };
  }
  /// The process state last told per session.
  private states = new Map<string, string>();
  /// How many times each session's taking of its messages was told (`session-pending`): a summary read across one is
  /// older than it.
  private taken = new Map<string, number>();
  private flushing: Promise<void> | null = null;
  private time: Fibers;
  private timers: (() => void)[] = [];
  private lastHost = "";
  /// When usage was last told, the telling waiting for the end of the while (USAGE_EVERY_MS), and when the earliest of
  /// the calls recorded since it was told was made (null: one was recorded without saying when).
  private usageTold = -Infinity;
  private usageLater: (() => void) | null = null;
  private usageFrom: number | null | undefined = undefined;
  /// When a broadcast overview was last flushed and any pending coalesced flush for background changes.
  private overviewToldAt = -Infinity;
  private overviewLater: (() => void) | null = null;
  /// What is read to be told once read (a thread's entries, a job): waited for before what is told goes over.
  private reading = new Set<Promise<void>>();
  /// Until what the process before this one handed over is taken up (`takeUp`): no stream is answered before, and what
  /// is to be told waits (`early`, in order), to be told after what it goes on from.
  private taking: Promise<void> | null = null;
  /// The taking up itself, once the process before is gone (a read of a file): a handover meanwhile waits for it, so
  /// that what is there is either taken up or left for the next, never removed under it.
  private takingUp: Promise<void> | null = null;
  /// What the handovers wrote, numbered: a second write of this process's never shares the first's file beside.
  private handings = 0;
  private early: (() => void)[] = [];
  /// Handed over to the next process: nothing more is told.
  private handed = false;

  constructor(deps: EventsDeps) {
    this.deps = deps;
    this.time = new Fibers("events", deps.clock);
    deps.subscribe((change) => this.storeChanged(change));
    const handover = deps.handover;
    if (handover) {
      const take = () => (this.takingUp = this.takeUp(handover.file, handover.previous.pid));
      // Never fails: every stream waits on it, and a failure nobody waits on would end the process.
      this.taking = handover.previous.gone.then(take, take).catch((error) => log.warn("events", "what the process before told is not taken up", { error: (error as Error).message }));
    }
  }

  /// Takes up what the process before this one handed over (`handOver`), once it is gone: the log goes on from it, the
  /// same run and numbers, each viewer's sidebar and overview told against what it told them, and what is told is made
  /// and kept from now as while nobody follows; so a stream that comes back here is resumed as it would have been there.
  /// None (a crash), another's than the process before (`from`), older than KEPT_MS, or not read: a run of its own, as
  /// before. What was to be told meanwhile is told then, after it.
  private async takeUp(file: string, from: number | null): Promise<void> {
    // Stopped before it was its turn: what is there is the next one's, and nothing more is told.
    if (this.handed) return void this.tookUp();
    let text: string | null = null;
    let unread: Error | null = null;
    try {
      text = await readFile(file, "utf8");
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") unread = error as Error;
    }
    if (text !== null || unread !== null) await removeHanded(file);
    // (Only taken up here: a handover waits for this before it looks whether it was its turn.)
    if (this.handed) return void this.tookUp();
    const early = this.tookUp();
    if (text !== null || unread !== null) {
      try {
        if (unread !== null) throw unread;
        const handed: Handed = JSON.parse(text!);
        const now = this.time.now();
        // From the one that held the station before, or, none holding it, the one that let go of it last as it stopped.
        // Another's was written by one waited for in vain, after a process since went on with a run of its own: what
        // that run told is not in it.
        if (from !== null && handed.pid !== from) log.info("events", "what another process than the one before told is not gone on from", { pid: handed.pid, before: from });
        else if (!(now - handed.at <= KEPT_MS)) log.info("events", "what the process before told is too old to go on from", { at: handed.at });
        else {
          const taken = EventLog.from(handed.log, now);
          const overviews = new Map<string, string>(handed.overviews);
          this.log = taken;
          this.overviewTold = overviews;
          this.last = handed.last;
          if (handed.shared && (handed.shared.until === undefined || handed.shared.until === null || now <= handed.shared.until)) {
            this.sharedTold = new Map(handed.shared.rows);
          }
          this.linger();
          log.info("events", "what the process before told goes on here", { ...this.log.state(), viewers: overviews.size });
        }
      } catch (error) {
        log.warn("events", "what the process before told does not read; its streams are not resumed", { error: (error as Error).message });
      }
    }
    // What was to be told meanwhile, as it came: numbered on from what is gone on from (no stream heard any of it).
    for (const tell of early) tell();
  }

  /// The taking up is over: streams are answered from now, and what was to be told meanwhile is given back (in order).
  private tookUp(): (() => void)[] {
    this.taking = null;
    const early = this.early;
    this.early = [];
    return early;
  }

  /// Hands what is told over to the next process, as this one stops (after its sessions are handed over): all being
  /// told is told first (a round, what is read to be told, usage waiting for the end of its while), then nothing more
  /// is; what the log keeps, and what each viewer's streams were told of their overview, are written whole
  /// for the next to go on from (`takeUp`). Nothing while nobody follows or may come back, and what is there is removed
  /// (the one before this one, waited for in vain, wrote it after this one went on without it). Stopped before what the
  /// one before handed over was taken up, it is left for the next.
  async handOver(): Promise<void> {
    const file = this.deps.handover?.file;
    if (file === undefined || this.handed) return;
    if (this.usageLater !== null) {
      this.usageLater();
      this.usageLater = null;
      this.tellUsage();
    }
    if (this.overviewLater !== null) {
      this.overviewLater();
      this.overviewLater = null;
      this.overviewChanged();
    }
    for (;;) {
      const telling = [...this.reading, ...(this.flushing ? [this.flushing] : [])];
      if (telling.length === 0) break;
      await Promise.allSettled(telling);
    }
    // A taking up under way (the file's read) is waited for: whether it was this one's turn is known after it.
    if (this.takingUp !== null) await this.takingUp;
    const listening = this.listening();
    const turn = this.taking === null;
    const at = this.time.now();
    this.handed = true;
    this.stopTimers();
    await this.time.close();
    if (!turn) return;
    if (!listening) return await removeHanded(file);
    // Who followed last, to read a thread's entries with: not their device's lock proof.
    const last = this.last && { viewer: { ...this.last.viewer, lockDevice: undefined }, lang: this.last.lang };
    const shared = this.sharedTold !== null ? { rows: [...this.sharedTold] as [string, string][], until: at + KEPT_MS } : undefined;
    const handed: Handed = { pid: process.pid, at, log: this.log.kept(), overviews: [...this.overviewTold], last, shared };
    try {
      await mkdir(dirname(file), { recursive: true });
      const tmp = `${file}.tmp-${process.pid}.${++this.handings}`;
      await writeFile(tmp, JSON.stringify(handed), { mode: 0o600 });
      await rename(tmp, file);
      log.info("events", "what was told is handed over", { ...this.log.state(), viewers: this.overviewTold.size });
    } catch (error) {
      log.warn("events", "what was told is not handed over; its streams are not resumed", { error: (error as Error).message });
    }
  }

  /// Where `live` sessions are followed from, the overview and process states (the agents' side, once it is made), and
  /// a vault's members (the vault's part).
  follow(more: Partial<Pick<EventsDeps, "live" | "held" | "heldNow" | "overview" | "processState" | "followed" | "loginScreen" | "inVault">>) {
    Object.assign(this.deps, more);
  }

  /// The station's screens changed: `screens` as GET /screens answers it, in each stream's
  /// language (`listed`), the latest alone kept for one coming back.
  screens(listed: (lang: Lang) => unknown) {
    for (const lang of new Set(this.clients.map((c) => c.lang))) this.emit("screens", listed(lang), { lang }, `screens\0${lang}`);
  }

  /// A record changed that only some viewers see (a vault's, routes/vault.ts): `data` told to the streams `to` says, the
  /// latest under `of` kept for one coming back.
  tell(event: string, data: unknown, of: string, to: To) {
    this.emit(event, data, to, of);
  }

  /// Sends an ephemeral event to currently connected matching streams without appending to the resume log.
  sendLive(event: string, data: unknown, to: To = {}) {
    if (this.handed) return;
    const whose = this.whose();
    for (const c of this.clients) if (isFor(to, c, whose)) c.send(event, data);
  }

  /// A login changed: told to everyone as `machine-logins`, a read-only member given `limited`
  /// (how it stands only).
  machineLogins(data: { login: unknown }, limited: { login: unknown }, of: string) {
    this.emit("machine-logins", data, { readOnly: false }, `machine-logins\0${of}`);
    this.emit("machine-logins", limited, { readOnly: true }, `machine-logins-limited\0${of}`);
  }

  /// The presets, or the folders offered for one, changed (routes/presets.ts): told to everyone as `presets`, each
  /// device reading its own workspace's again.
  presetsChanged() {
    this.emit("presets", {}, {}, "presets");
  }

  /// Something the overview shows changed (config, accounts, connects, cloud, updates).
  overviewChanged() {
    this.dirty.overview = true;
    this.wake();
  }

  /// Background overview change (process state, profile checks, backup progress, decision checks): emits at once when
  /// quiet, or coalesces a burst into one trailing overview after OVERVIEW_SOON_MS.
  overviewSoon() {
    if (this.overviewLater !== null) return;
    const wait = this.overviewToldAt + OVERVIEW_SOON_MS - this.time.now();
    if (wait <= 0) {
      this.overviewChanged();
      return;
    }
    this.overviewLater = this.time.after(wait, () => { // timer: burst debounce for background overview changes
      this.overviewLater = null;
      this.overviewChanged();
    });
  }

  inUse(): boolean {
    return this.clients.length > 0;
  }

  /// What a session at work did (sessions/live.ts `heldTold`, its entries in brief): told to every stream that follows the
  /// sessions at work and whose viewer sees it. Not of the log: one that comes back is told each as it is now, and reads
  /// what it lacks.
  heldTold(key: string, message: unknown) {
    const whose = this.whose();
    // Made once for every stream it is told to (each stream's `send` made it again).
    let text: string | undefined;
    for (const c of this.clients) {
      if (!c.running || !(whose.seen?.(c.viewer, { session: key }) ?? true)) continue;
      if (c.spare !== null && !c.spare.has(key)) continue;
      const waits = c.heldWaits?.get(key);
      if (waits !== undefined) waits.push(message);
      else c.raw((text ??= `event: live\ndata: ${JSON.stringify({ ...(message as object), key })}\n\n`));
    }
  }

  /// Whether what is told is made and kept: someone follows, or may come back to what they missed.
  private listening(): boolean {
    return !this.handed && (this.clients.length > 0 || this.lingering !== null || this.openingShared > 0);
  }

  /// Read the baseline before the first stream joins. Changes arriving during the read wait for it in
  /// `tellShared`, so the first change after that stream joins is compared against a current baseline too.
  private prepareShared(): Promise<void> {
    if (this.sharedTold !== null) return Promise.resolve();
    if (this.sharedReading !== null) return this.sharedReading;
    const reading = this.deps.readers.read("sharedOf", { sessions: null, threads: null }, "zh", TOLD).then((text) => {
      const read = JSON.parse(text) as { rows: any[] };
      this.sharedTold = new Map(read.rows.map((r) => [String(r.id ?? ""), JSON.stringify(r)]));
    }).finally(() => { this.sharedReading = null; });
    this.sharedReading = reading;
    this.whenRead(reading);
    return reading;
  }

  /// Nobody follows: what is told is still made a while, for one coming back; past it, nothing before can be.
  private linger() {
    this.lingering = this.time.after(KEPT_MS, () => {
      // A stream is already opening and its baseline read has not finished. Keep the log until it joins or fails.
      if (this.openingShared > 0) return this.linger();
      this.lingering = null;
      this.log.clear();
      this.sharedTold = null;
      this.overviewTold.clear();
    });
  }

  /// What may change which chats there are and what they say, and only the station can say (a chat's sessions, a
  /// viewer's Slack identities): told so (`chat-changed`), a device reads its marks again; `made`: what it is told puts
  /// it in place itself (`pin`, `dismiss`, `kept`, `thread-removed`). With no viewer, the shared chat list is read whole.
  rowsChanged(viewer: string | null, made = false) {
    if (!made) this.emit("chat-changed", {}, viewer === null ? {} : { email: viewer });
    if (viewer !== null) return;
    this.dirty.whole = true;
    this.wake();
  }

  /// The rows of the shared chat list a change of these sessions and threads can touch (read/views.ts `scopeOf`): only
  /// those are read again.
  private itemsChanged(of: { sessions?: string[]; threads?: number[] }) {
    for (const key of of.sessions ?? []) this.dirty.items.sessions.add(key);
    for (const id of of.threads ?? []) this.dirty.items.threads.add(id);
    this.wake();
  }

  /// Opens a stream for `viewer`: their sidebar's changes are told against what their streams were told of it last.
  /// `since`: the last id the client heard (`<run>.<n>`), from the stream it takes over from or the one it lost; what was
  /// told after it is told first, and their sidebar and overview as they are now (RESUMED says so), or `missed`.
  /// `brief`: the sessions followed have their transcript entries in brief (read/transcript.ts `brief`).
  /// `logins`: those logins' terminals, each a `login-screen` event (all its rows first, then the rows that changed).
  async open(viewer: Viewer, lang: Lang, host: boolean, live: [string, number, number | null][], logs: [string, number][], since: string | null = null, brief = false, logins: string[] = [], running = false, spare: string[] | null = null): Promise<Answer> {
    // Following the sessions at work itself, it follows none by name: a client that asks both is one that does not know
    // yet whether this station does (an older one follows those it names).
    const follows = running && this.deps.held !== undefined;
    const spared = follows && spare !== null ? new Set(spare) : null;
    if (follows) live = [];
    // What the process before this one told goes on here, ids and all: not before it is taken up.
    if (this.taking !== null) await this.taking;
    // An older process did not hand over the shared baseline. Its log cannot promise all shared changes: require a
    // fresh read instead of resuming it. Opening streams share the one initial read.
    const sharedHistory = this.sharedTold !== null;
    this.openingShared++;
    try { while (this.sharedTold === null) await this.prepareShared(); }
    catch (error) { this.openingShared--; throw error; }
    const queue: string[] = [];
    let wakeReader: (() => void) | null = null;
    let closed = false;
    // Given what carries it (`relay`): each piece handed it at once, no queue between.
    let carried: { send: (text: string) => void; ended: () => void } | null = null;
    const push = (text: string) => {
      if (closed) return;
      if (carried !== null) return carried.send(text);
      queue.push(text);
      wakeReader?.();
    };
    const client: Client = {
      id: this.next++,
      viewer,
      lang,
      host,
      running: follows,
      spare: spared,
      // Its own (a session's steps, a log, a host sample, `missed`): not of the log, and without an id (event-log.ts).
      send: (event, data) => push(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`),
      raw: push,
      stops: [],
      end: () => remove(),
    };
    push("retry: 3000\n\n");
    // Said first: it makes its rows from here on, and reads from this station what only the station can say of them.
    client.send("made", { rows: true, marks: true, shared: true });
    // Coming back where all that was told since is kept.
    const k = viewerKey(viewer, lang);
    const resumes = since !== null && sharedHistory && this.log.has(since);
    if (since !== null && !resumes) {
      // Why, for the log: a station whose streams are never resumed has every client read it again each time.
      log.info("events", "a stream is not resumed", { since, ...this.log.state() });
      client.send("missed", {});
    }
    // Afresh: their overview is told as it next is.
    if (!resumes) this.overviewTold.delete(k);
    // The sessions at work its viewer sees, as each is now: from here on what each does comes as it does it (heldTold).
    if (follows && this.deps.heldNow !== undefined) {
      const keys = this.deps.held!().filter((key) => this.sees(client, { session: key }) && (spared === null || spared.has(key)));
      if (keys.length > 0) {
        const waits = new Map(keys.map((key) => [key, [] as unknown[]]));
        client.heldWaits = waits;
        void this.deps.heldNow(keys).catch(() => ({}) as Record<string, unknown[]>).then((now) => {
          if (client.heldWaits !== waits) return;
          client.heldWaits = undefined;
          for (const key of keys) for (const message of [...(now[key] ?? []), ...waits.get(key)!]) client.send("live", { ...(message as object), key });
        });
      }
    }
    // Those sessions as they run, on this same stream: each message a `live` event with its key.
    for (const [key, from, last] of live) {
      const stop = this.deps.live?.(key, from, last, (message) => {
        if (this.deps.liveSeen?.(viewer, key) ?? (this.deps.sessionExists(key) && this.sees(client, { session: key }))) {
          client.send("live", { ...(message as object), key });
        }
      }, brief);
      if (stop) client.stops.push(stop);
    }
    // Those jobs' last lines: a `job-log` event now, and again each time the log changes, until the stream goes.
    for (const [id, lines] of logs) client.stops.push(this.followLog(client, id, lines));
    // Those logins' terminals: never of the log (a stream that takes over asks again, and is told all of it).
    for (const id of logins) {
      let told: string[] | null = null;
      const stop = this.deps.loginScreen?.(id, (screen) => {
        const rows: Record<string, string> = {};
        screen.rows.forEach((row, i) => {
          if (told === null || told[i] !== row) rows[i] = row;
        });
        client.send("login-screen", { id, rows, cursor: screen.cursor, echo: screen.echo, live: screen.live, ...(told === null ? { full: true } : {}) });
        told = screen.rows;
      });
      if (stop) client.stops.push(stop);
    }
    if (host) void this.deps.host().then((info) => client.send("host", info), () => {});
    // Read afresh: where the log is as it joins, an id alone (no event), so the next stream goes on from here even when
    // nothing is told meanwhile. On a quiet station a stream without it had no id to go on from, and each that a weak
    // link cut read the whole station again (a dozen reads). Clients from before skip a block without data.
    if (!resumes) client.raw(`id: ${this.log.at()}\n\n`);
    this.clients.push(client);
    this.openingShared--;
    this.last = { viewer, lang };
    this.lingering?.();
    this.lingering = null;
    // In the same turn as it joins: what was told since is told again, and what is told from now comes as to the rest.
    if (resumes) for (const told of this.log.after(since!)) if (this.reaches(client, told.to)) client.raw(told.text);
    const head = resumes ? this.log.at() : null;
    // Coming back: their overview as it is now, against what their streams were told of it last. Theirs alone: every
    // viewer's made again at each device that came back held the main thread for seconds on a station of many devices.
    if (resumes) {
      this.dirty.overviewOf.add(viewerKey(viewer, lang));
      this.wake();
    }
    if (this.clients.length === 1) {
      this.startTimers();
      this.deps.followed?.();
    }
    const remove = () => {
      if (closed) return;
      closed = true;
      wakeReader?.();
      carried?.ended();
      this.clients = this.clients.filter((c) => c !== client);
      client.stops.forEach((stop) => stop());
      if (this.clients.length > 0) return;
      this.stopTimers();
      this.linger();
    };
    // The stream lasts as long as its reader: when it goes (the mesh stream closed), the client does, at once (an
    // async generator would end only once its pending wait woke up).
    const body: AsyncIterableIterator<Buffer> = {
      [Symbol.asyncIterator]: () => body,
      next: async () => {
        while (!closed && queue.length === 0) await new Promise<void>((resolve) => (wakeReader = resolve));
        wakeReader = null;
        if (queue.length === 0) return { done: true, value: undefined };
        return { done: false, value: Buffer.from(queue.shift()!) };
      },
      return: async () => {
        remove();
        return { done: true, value: undefined };
      },
    };
    // What carries the stream elsewhere (mesh/served.ts: the MoonBit program writes it) takes each piece as it is told,
    // what is waiting first; told when it ends from this side. The same text told several streams at once is one
    // string, which it gives the program once.
    (body as AsyncIterableIterator<Buffer> & { relay?: unknown }).relay = (send: (text: string) => void, ended: () => void) => {
      for (const text of queue.splice(0)) send(text);
      carried = { send, ended };
      if (closed) ended();
    };
    return {
      status: 200,
      headers: { "content-type": "text/event-stream", "cache-control": "no-store", connection: "keep-alive", "x-accel-buffering": "no", ...(head !== null ? { [RESUMED]: "1", [HEAD]: head } : {}), ...(follows ? { [FOLLOWS]: "running", ...(this.deps.heldNow !== undefined ? { [LIVE_RATES]: "1" } : {}), ...(spared !== null ? { [SPARED]: "1" } : {}) } : {}) },
      body,
    };
  }

  /// A job's last `lines` of output (`job-log`: id, lines, text, outputAt): at once, then whenever its log changes.
  private followLog(client: Client, id: string, lines: number): () => void {
    const path = this.deps.jobLog(id);
    if (path === null) return () => {};
    let seen = "";
    let stopped = false;
    // One read at a time (off the station's thread: the readers'); asked meanwhile, read again after it.
    let reading = false;
    let again = false;
    const tell = () => {
      if (reading) {
        again = true;
        return;
      }
      reading = true;
      void (async () => {
        do {
          again = false;
          const got = await this.deps.logNow(id, lines).catch(() => null);
          if (stopped) return;
          const now = got === null ? "none" : JSON.stringify(got);
          if (now === seen) continue;
          seen = now;
          client.send("job-log", { id, lines, text: got?.text ?? "", outputAt: got?.outputAt ?? null });
        } while (again);
      })().finally(() => (reading = false));
    };
    tell();
    let watcher: FSWatcher | null = null;
    let pending: (() => void) | null = null;
    const soon = () => {
      // A burst of writes is one event.
      if (pending) return;
      pending = this.time.after(200, () => {
        pending = null;
        tell();
      });
    };
    const follow = () => {
      if (watcher) return;
      try {
        watcher = watch(path, { persistent: false }, soon);
        watcher.on("error", () => {
          watcher?.close();
          watcher = null;
        });
      } catch {
        // No log yet: the check below finds it once the job writes one.
      }
    };
    follow();
    // A log that was not there yet, or was written anew (its watch then ends), is found again here.
    const check = this.time.every(5_000, () => {
      follow();
      tell();
    });
    return () => {
      stopped = true;
      watcher?.close();
      check();
      pending?.();
    };
  }

  private startTimers() {
    this.timers.push(this.time.every(PING_MS, () => this.clients.forEach((c) => c.raw(": ping\n\n"))));
    this.timers.push(
      this.time.every(HOST_MS, () => {
        if (!this.clients.some((c) => c.host)) return;
        void this.deps.host().then((info: any) => {
          const { checkedAt: _a, uptimeSec: _b, ...shown } = info ?? {};
          const key = JSON.stringify(shown);
          if (key === this.lastHost) return;
          this.lastHost = key;
          for (const c of this.clients) if (c.host) c.send("host", info);
        }, () => {});
      }),
    );
  }

  private stopTimers() {
    for (const stop of this.timers) stop();
    this.timers = [];
    this.lastHost = "";
  }

  /// Tells everyone `to` says: one id for all of them, kept for a stream that takes over from one of them or comes
  /// back. Nothing while nobody follows or may come back; before what the process before told is taken up, once it is.
  private emit(event: string, data: unknown, to: To = {}, of?: string) {
    if (this.taking !== null) return void this.early.push(() => this.emit(event, data, to, of));
    if (!this.listening()) return;
    const { text } = this.log.append(event, data, to, this.time.now(), of);
    const whose = this.whose();
    for (const c of this.clients) if (isFor(to, c, whose)) c.raw(text);
  }

  /// `seen` and `inVault` for one event told to every stream: the session, thread or job it names looked up once
  /// (`seer`), when a stream first asks, not once a stream.
  private whose(): Pick<EventsDeps, "seen" | "inVault"> {
    const seer = this.deps.seer;
    if (seer === undefined) return this.deps;
    let seen: ((viewer: Viewer) => boolean) | undefined;
    return { inVault: this.deps.inVault, seen: (viewer, of) => (seen ??= seer(of))(viewer) };
  }

  /// Whether a stream is one `to` says (`isFor`).
  private reaches(c: Client, to: To): boolean {
    return isFor(to, c, this.deps);
  }

  /// Whether a stream's viewer sees that session, thread or job (`seen`).
  private sees(c: Client, of: { session: string } | { thread: number } | { job: string }): boolean {
    return this.deps.seen?.(c.viewer, of) ?? true;
  }

  /// `told`, a read and the telling of what it reads: among what is being told until it is done.
  private whenRead(told: Promise<void>) {
    this.reading.add(told);
    const done = () => void this.reading.delete(told);
    told.then(done, done);
  }

  private storeChanged(change: StoreChange) {
    // Before what the process before told is taken up, as if it came then: what it tells numbered on from that, a
    // thread's entries read as the one who followed last there has them.
    if (this.taking !== null) return void this.early.push(() => this.storeChanged(change));
    switch (change.type) {
      case "session":
        // Its messages taken: how many it has yet to take, told now (its summary, read after, says it too): read
        // behind the station's other tells can leave a person's message showing that it waits for its agent.
        if (change.pending !== undefined) {
          this.taken.set(change.key, (this.taken.get(change.key) ?? 0) + 1);
          this.emit("session-pending", { key: change.key, pending: change.pending }, { sees: { session: change.key } });
        }
        this.dirty.sessions.add(change.key);
        // Its summary is told (`session`): a device puts it in its rows.
        this.itemsChanged({ sessions: [change.key] });
        break;
      case "sessionRemoved":
        this.dirty.sessions.delete(change.key);
        this.states.delete(change.key);
        this.taken.delete(change.key);
        this.overviewChanged();
        this.emit("session-removed", { key: change.key }, { sees: { ws: change.ws ?? null } }, `session\0${change.key}`);
        this.itemsChanged({ sessions: [change.key] });
        break;
      case "thread": {
        // Told as one who follows (or did last) would have it.
        const who = this.clients[0] ?? this.last;
        if (this.listening() && who && change.entries.length > 0) {
          // What was said, as GET /threads/:id/entries has it, at once.
          this.tellSaid("thread", change.id, change.entries, who.lang);
        }
        // What was said is told (`thread`): a device puts it in its rows. Its sessions changing is not (nor what else
        // changes which rows there are and what they say): told so (`chat-changed`), it reads its rows.
        if (change.entries.length === 0) this.emit("chat-changed", { thread: change.id }, { sees: { thread: change.id } });
        this.itemsChanged({ threads: [change.id] });
        break;
      }
      case "letters": {
        // A chat's letters kept in their own log (store/schema.ts LETTERS): as GET /threads/:id/letters has them, and
        // the thread as each viewer has it (how many letters, how far their log goes).
        const who = this.clients[0] ?? this.last;
        if (this.listening() && who && change.letters.length > 0) {
          this.tellSaid("letters", change.id, change.letters, who.lang);
        }
        break;
      }
      case "moved":
        // A chat handed to another station (replica/handover.ts), or back here (`station` null): a device drops its row
        // here and follows it there (`chat-moved`), its link going to that station.
        this.emit("chat-moved", { session: change.key, station: change.station, thread: change.thread, there: change.there }, { sees: { ws: change.ws } });
        this.rowsChanged(null, true);
        break;
      case "threadRemoved":
        this.emit("thread-removed", { id: change.id }, { sees: { ws: change.ws ?? null } });
        // Told so: a device that makes its rows takes its own out.
        this.rowsChanged(null, true);
        break;
      case "read":
        this.emit("read", { viewer: change.viewer, thread: change.thread, n: change.n }, { email: change.viewer, sees: { thread: change.thread } });
        break;
      case "hidden":
        this.emit("hidden", { thread: change.thread, hidden: change.hidden }, { email: change.viewer, sees: { thread: change.thread } });
        break;
      case "muted":
        this.emit("muted", { thread: change.thread, muted: change.muted }, { email: change.viewer, sees: { thread: change.thread } });
        break;
      case "identities":
        // Who the viewer is on Slack: their overview says it, and their rows count it.
        this.overviewChanged();
        this.rowsChanged(change.viewer);
        break;
      case "pins":
      case "dismissed":
        // What the viewer wrote, as written, to their own streams: a device puts it in place in its rows (`pin`,
        // `dismiss`, `kept`).
        if (change.type === "pins" && change.session !== undefined) this.emit("pin", { session: change.session, at: change.at ?? null }, { email: change.viewer });
        if (change.type === "dismissed" && change.card !== undefined) this.emit("dismiss", change.card, { email: change.viewer, sees: { thread: change.card.thread } });
        if (change.type === "dismissed" && change.kept !== undefined) this.emit("kept", change.kept, { email: change.viewer, sees: { thread: change.kept.thread } });
        this.rowsChanged(change.viewer, (change.type === "pins" && change.session !== undefined) || (change.type === "dismissed" && (change.card !== undefined || change.kept !== undefined)));
        break;
      case "job":
        // A job as GET /jobs/:id answers it, so a client holding it puts it in place without reading anything again.
        this.whenRead(this.deps.readers.read("job", { id: change.id }, "zh", TOLD).then((text) => this.emit("job", JSON.parse(text), { sees: { job: change.id } }, `job\0${change.id}`), () => {}));
        break;
      case "jobRemoved":
        this.emit("job-removed", { id: change.id, session: change.session }, { sees: { session: change.session } }, `job\0${change.id}`);
        break;
      case "usage":
        // Model calls were recorded: a page showing usage reads again what they changed, from the day of the earliest
        // (it is too big to send to everyone).
        this.usageFrom = this.usageFrom === null || change.from === undefined ? null : Math.min(this.usageFrom ?? Infinity, change.from);
        this.usageChanged();
        break;
      case "chatMark": {
        // As written, to those who see the chat (`chat-mark`): a device that makes its sidebar itself puts it in place.
        const { type: _, ...mark } = change;
        this.emit("chat-mark", mark, { sees: change.thread !== null ? { thread: change.thread } : { session: change.session } });
        break;
      }
      case "processes":
      case "decisionChecks":
        this.overviewSoon();
        break;
    }
  }

  /// What was said in a thread (`entries` of `thread`, or its letters), told to every stream whose viewer sees it as the
  /// pages show it (`said`): made from what the store wrote, never waiting on a read.
  private tellSaid(event: "thread" | "letters", id: number, entries: EntryRow[], lang: Lang) {
    let views: unknown[];
    try {
      views = this.deps.said(id, entries, lang);
    } catch (error) {
      return log.warn("events", `${event} event not sent`, { error: (error as Error).message });
    }
    this.emit(event, event === "thread" ? { id, entries: views } : { id, letters: views }, { sees: { thread: id } });
  }

  /// Usage told, at most once a USAGE_EVERY_MS.
  private usageChanged() {
    if (this.usageLater !== null) return;
    const tell = () => {
      this.usageLater = null;
      this.tellUsage();
    };
    const wait = this.usageTold + USAGE_EVERY_MS - this.time.now();
    if (wait <= 0) tell();
    else this.usageLater = this.time.after(wait, tell);
  }

  /// That usage changed, with when the earliest of the calls recorded since it was told last was made (`from`: what a
  /// page holding it reads again, from that day on; none: all of it). Each telling is kept on its own, not as the
  /// latest of them alone: one who comes back is told each it missed, and reads again from the earliest.
  private tellUsage() {
    const from = this.usageFrom;
    this.usageFrom = undefined;
    this.usageTold = this.time.now();
    this.emit("usage", typeof from === "number" ? { from } : {});
  }

  /// Changes gathered into one round: after what happens now, once.
  private wake() {
    if (this.flushing) return;
    this.flushing = new Promise<void>((resolve) => setImmediate(resolve)).then(() => this.flush()).finally(() => {
      this.flushing = null;
      const d = this.dirty;
      if (d.sessions.size > 0 || d.whole || d.overview || d.overviewOf.size > 0 || d.items.sessions.size > 0 || d.items.threads.size > 0) this.wake();
    });
  }

  /// One round: an event per changed session, the overview to each viewer, and the rows of the shared chat list that
  /// changed.
  private async flush() {
    const dirty = this.dirty;
    this.dirty = Events.clean();
    let overview = dirty.overview;
    for (const key of dirty.sessions) {
      if (!this.deps.sessionExists(key)) continue;
      // The overview counts running and warm sessions.
      const state = this.deps.processState?.(key);
      if (state !== undefined && this.states.get(key) !== state) {
        this.states.set(key, state);
        if (this.overviewToldAt + OVERVIEW_SOON_MS <= this.time.now()) overview = true;
        else this.overviewSoon();
      }
    }
    if (!this.listening()) return;
    for (const key of dirty.sessions) {
      if (!this.deps.sessionExists(key)) continue;
      try {
        const taken = this.taken.get(key);
        const summary = await this.deps.readers.read("summary", { key }, "zh", TOLD);
        // Its messages taken while it was read: it has them waiting and the turn before, told after they were taken; the
        // change that told it reads it again in the next round.
        if (this.taken.get(key) !== taken) continue;
        this.emit("session", JSON.parse(summary), { sees: { session: key } }, `session\0${key}`);
      } catch (error) {
        log.warn("events", "session event not sent", { session: key, error: (error as Error).message });
      }
    }
    // The overview to each viewer, in each language their streams were asked in (only to those that came back, where
    // nothing else changed it).
    if ((overview || dirty.overviewOf.size > 0) && this.deps.overview) {
      if (overview) {
        this.overviewToldAt = this.time.now();
        if (this.overviewLater !== null) {
          this.overviewLater();
          this.overviewLater = null;
        }
      }
      const seen = new Set<string>();
      const wanted = (k: string) => overview || dirty.overviewOf.has(k);
      const viewers = this.clients.filter((c) => wanted(viewerKey(c.viewer, c.lang)) && !seen.has(viewerKey(c.viewer, c.lang)) && seen.add(viewerKey(c.viewer, c.lang)));
      await Promise.all(
        viewers.map(async ({ viewer, lang }) => {
          try {
            const value = await this.deps.overview!(viewer, lang);
            // Told only as it changed for them: a stream that comes back has every viewer's made again.
            const k = viewerKey(viewer, lang);
            const text = overviewComparable(value);
            if (this.overviewTold.get(k) === text) return;
            this.overviewTold.set(k, text);
            this.emit("overview", value, { viewer: k }, `overview\0${k}`);
          } catch (error) {
            log.warn("events", "overview not told", { error: (error as Error).message });
          }
        }),
      );
    }
    await this.tellShared(dirty);
  }

  /// The chat list's rows a round's changes touch, made once for everyone (read/views.ts `sharedChats`), each told to
  /// the streams that see it as it changed (`chat-shared`; gone: `chat-shared-removed`), also while one may come back.
  private async tellShared(dirty: ReturnType<typeof Events.clean>) {
    const sessions = [...dirty.items.sessions];
    const threads = [...dirty.items.threads];
    const whole = dirty.whole;
    if (!whole && sessions.length === 0 && threads.length === 0) return;
    if (this.sharedReading !== null) {
      try { await this.sharedReading; } catch { return; }
    }
    if (this.sharedTold === null || !this.listening()) return;
    let read: { rows: any[]; scope: string[] | null };
    try {
      read = JSON.parse(await this.deps.readers.read("sharedOf", whole ? { sessions: null, threads: null } : { sessions, threads }, "zh", TOLD));
    } catch (error) {
      log.warn("events", "the chat list not read; its streams will read again", { error: (error as Error).message });
      this.sharedTold = null;
      this.log.clear();
      for (const c of [...this.clients]) c.end();
      return;
    }
    const told = this.sharedTold;
    const now = new Map(read.rows.map((r) => [String(r.id ?? ""), JSON.stringify(r)]));
    if (told === null) return;
    // A row can move between workspaces. A returning stream must hear the last change for each place it may see,
    // including removal from the old place, even when another place received a newer version of the same row.
    const place = (text: string) => (JSON.parse(text) as { ws?: string | null }).ws ?? null;
    const key = (id: string, ws: string | null) => `chat-shared\0${id}\0${JSON.stringify(ws)}`;
    for (const row of read.rows) {
      const id = String(row.id ?? "");
      if (told.get(id) === now.get(id)) continue;
      const before = told.get(id);
      const ws = row.ws ?? null;
      if (before !== undefined && place(before) !== ws) {
        const old = place(before);
        this.emit("chat-shared-removed", { id }, { sees: { ws: old } }, key(id, old));
      }
      told.set(id, now.get(id)!);
      this.emit("chat-shared", row, { sees: { ws } }, key(id, ws));
    }
    const gone = read.scope === null ? [...told.keys()].filter((id) => !now.has(id)) : read.scope.filter((id) => !now.has(id) && told.has(id));
    for (const id of gone) {
      const ws = place(told.get(id)!);
      told.delete(id);
      this.emit("chat-shared-removed", { id }, { sees: { ws } }, key(id, ws));
    }
  }
}
