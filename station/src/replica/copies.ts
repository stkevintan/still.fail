// This station's copies as the station keeps them going (replica/AGENTS.md), on its main thread: what the store says
// changed gathered and handed to the export's thread (runner.ts) a moment later, what it wrote brought to the stations
// that keep this one's copies, the copies this station keeps of others handed over where they are not its to keep any
// more, and a lost station's copy brought back into a new one (restore.ts). Nothing here reads stillfail.db; what it does
// on this thread is a few messages per change and the files' bytes passed to the mesh as they are read.
import { randomBytes } from "node:crypto";
import { mkdir, open, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { log } from "../ops/log.ts";
import type { Fibers } from "../ops/fibers.ts";
import type { StoreChange } from "../store/rows.ts";
import { type Places, type Told, nothingTold } from "./export.ts";
import { GEN, type Head, STATION, WORKSPACE, genMade } from "./format.ts";
import { loadLocalTranscriptFiles, loadTranscriptManifest, readStreamBounded } from "./manifest.ts";
import { FolderPlace, type Held, type Known, type Levelled, type Place, handOver, holdsAllLogical, level } from "./places.ts";
import { type Ask, COPIES, MOST, PeerPlace, keepers, ranked, serve } from "./peers.ts";
import { Refused } from "../mesh/bus.ts";
import { readBytes } from "../mesh/files.ts";
import type { Traces } from "../mesh/traces.ts";
import { NotEmpty, type Outcome, type Ready, copyDir, outcomeFile, readyFile } from "./restore.ts";
import type { Runner, WorkPassed } from "./runner.ts";
import { type BackupView, type NormalizedBackupConfig, type NormalizedS3Target, buildBackupView } from "./backup-config.ts";
import { type S3ClientOptions, S3HttpError, S3Place } from "./s3.ts";

const DEFAULT_BACKUP: NormalizedBackupConfig = { mode: "auto", stations: [], acceptOthers: true, s3: [] };
export type RestoreFrom = { station: string } | { s3: string };

/// What the store says is gathered this long before the export's thread is told (a burst of changes, one pass).
export const GATHER_MS = 1_000;
/// Transcript scans are debounced separately so chat sync stays sub-second while active turns write transcripts.
export const TRANSCRIPT_GATHER_MS = 30_000;
/// A place that could not be brought level is tried again after this, twice as long each time, up to RETRY_MOST_MS.
export const RETRY_MS = 5_000;
export const RETRY_MOST_MS = 10 * 60_000;
/// Quiet period after the last incoming `replica.put`/`replica.drop` before handing over and removing a non-keeper copy.
export const HANDOVER_QUIET_MS = 15_000;
/// How often at most the station's settings are told the copies went further (a pass a second while agents work);
/// what went wrong or came right, at once; a restore's progress, every second.
export const TELL_MS = 30_000;
export const TELL_RESTORE_MS = 1_000;

/// Where the stations this one keeps copies of are kept, and which station this one was (it took a lost one's place).
export const keptDir = (data: string) => join(data, "replicas");
export const formerlyFile = (data: string) => join(data, "replica", "formerly.json");
export const historyFile = (data: string) => join(data, "replica", "history.json");
export const HISTORY_MAX = 50;

export type BackupRecord = {
  id: string;
  at: number;
  kind: "sync" | "restore";
  targetKind: "station" | "s3";
  target: string;
  targetName: string;
  status: "ok" | "error";
  chats: number;
  messages: number;
  batches: number;
  bytes: number;
  reason: RestoreReason | null;
  error: string | null;
};

const VALID_REASONS = new Set<string>(["offline", "old", "error", "gone", "notEmpty"]);

function parseBackupRecord(raw: unknown): BackupRecord | null {
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return null;
  const r = raw as Record<string, unknown>;
  if (typeof r.id !== "string" || r.id === "") return null;
  if (typeof r.at !== "number" || !Number.isFinite(r.at)) return null;
  if (r.kind !== "sync" && r.kind !== "restore") return null;
  if (r.targetKind !== "station" && r.targetKind !== "s3") return null;
  if (typeof r.target !== "string") return null;
  if (typeof r.targetName !== "string") return null;
  if (r.status !== "ok" && r.status !== "error") return null;
  const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) && v >= 0 ? Math.trunc(v) : 0);
  const reason = typeof r.reason === "string" && VALID_REASONS.has(r.reason) ? (r.reason as RestoreReason) : null;
  const error = typeof r.error === "string" ? r.error : null;
  return {
    id: r.id,
    at: r.at,
    kind: r.kind,
    targetKind: r.targetKind,
    target: r.target,
    targetName: r.targetName,
    status: r.status,
    chats: num(r.chats),
    messages: num(r.messages),
    batches: num(r.batches),
    bytes: num(r.bytes),
    reason,
    error,
  };
}

function parseHistoryFile(raw: unknown): Map<string, BackupRecord[]> {
  const out = new Map<string, BackupRecord[]>();
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return out;
  const obj = raw as Record<string, unknown>;
  if (obj.v !== 1 || obj.workspaces === null || typeof obj.workspaces !== "object" || Array.isArray(obj.workspaces)) return out;
  for (const [ws, list] of Object.entries(obj.workspaces as Record<string, unknown>)) {
    if (!Array.isArray(list)) continue;
    const parsed: BackupRecord[] = [];
    for (const item of list) {
      const rec = parseBackupRecord(item);
      if (rec !== null) parsed.push(rec);
    }
    parsed.sort((a, b) => b.at - a.at);
    if (parsed.length > HISTORY_MAX) parsed.length = HISTORY_MAX;
    if (parsed.length > 0) out.set(ws, parsed);
  }
  return out;
}

/// The stations this one took the place of, as `formerly.json` says (written before its store opens, never after: read
/// once as it starts).
export function formerlyOf(data: string): string[] {
  try {
    const list = JSON.parse(readFileSync(formerlyFile(data), "utf8")); // sync: read once, before the station serves
    return Array.isArray(list) ? list.filter((s) => typeof s === "string" && STATION.test(s)) : [];
  } catch {
    return [];
  }
}

export type CopiesDeps = {
  data: string;
  /// This station's id (null before it is enrolled).
  here: () => string | null;
  /// The workspaces it is in, its name in each.
  places: () => Places;
  /// The stations of `ws` (this one too) with their names, as its roster says now; null while the roster is not current.
  roster: (ws: string) => { id: string; name: string }[] | null;
  ask: Ask;
  runner: Runner;
  fibers: Fibers;
  /// What the station's settings show changed.
  changed: () => void;
  /// Asks the station's launcher to start it again (ops/restart.ts); null where there is none to ask.
  restart: () => Promise<(() => Promise<void>) | null>;
  /// The stations whose chats this one is taking (retire.ts): what it keeps of them is not handed over meanwhile.
  taking?: () => Set<string>;
  /// Current backup target configuration (`config.json` `backup`).
  backup?: () => NormalizedBackupConfig;
  /// Optional S3 client overrides (deterministic clock / multipart thresholds in tests).
  s3ClientOptions?: S3ClientOptions;
  /// Active OTLP traces batcher for `replica.export` and `replica.level` spans.
  traces?: () => Traces | null;
};

/// How a place for this station's copies stands: how far it goes, when it was brought level last, what went wrong.
/// `known`: what it holds, as this station left it (null: to be asked); `head`: the head it was brought level with.
/// How it stands at a place (`to`, `at`: as far as the place's head goes and when it went there): `partial` while that
/// head is a partial one, the chats there and `lacking` transcripts still to send (places.ts `partialHead`).
type Keeping = { to: number; at: number | null; error: string | null; reason: Reason | null; missing: number; busy: boolean; again: (() => void) | null; tries: number; asked: boolean; known: Known | null; head: string | null; partial: boolean; lacking: number };

/// Why a station is not brought level, as the settings say it: it is not reached, it is from before copies (it answers
/// none of `replica.*`), or something else (its words in the log).
export type Reason = "offline" | "old" | "error";

/// A restore under way, as the station's settings show it; one that failed says why (`reason`; `error` the log's words).
export type Restoring = { origin: string; name: string; workspace: string; gen: string; from: string; done: number; total: number; error: string | null; reason: RestoreReason | null; restart: boolean };

/// Why a restore failed, as the settings say it: the station it came from not reached or from before copies, the copy
/// no longer kept there, this station got a chat of its own first, or something else.
export type RestoreReason = Reason | "gone" | "notEmpty";

/// A copy that the place asked for does not keep (any more).
class Gone extends Error {}

/// A retired station's copy put in beside this one's chats (restore.ts `Ready`).
type Merge = { merge: true; connects: Record<string, string>; ws: string | null };

/// The store's change put into `t`, what the next pass is to read again (a few keys, nothing read); false where it
/// says nothing of what is copied.
export function tell(t: Told, change: StoreChange): boolean {
  switch (change.type) {
    case "session":
    case "conversation":
      t.sessions.push(change.key);
      return true;
    case "sessionRemoved":
      t.removedSessions.push({ key: change.key, ws: change.ws ?? null });
      return true;
    case "thread":
      // (its entries are found by their rowid; only what else of it changed is read by its id)
      if (change.entries.length === 0 || change.closed !== undefined) t.threads.push(change.id);
      return true;
    case "letters":
      return true;
    case "threadRemoved":
      t.removedThreads.push({ id: change.id, ws: change.ws ?? null });
      return true;
    case "read":
      t.marks.push({ table: "reads", key: { viewer: change.viewer, thread: change.thread } });
      return true;
    case "hidden":
      t.marks.push({ table: "hidden_chats", key: { viewer: change.viewer, thread: change.thread } });
      return true;
    case "muted":
      t.marks.push({ table: "muted_chats", key: { viewer: change.viewer, thread: change.thread } });
      return true;
    case "pins":
      if (change.session !== undefined) t.marks.push({ table: "pins", key: { viewer: change.viewer, session: change.session } });
      return true;
    case "dismissed":
      if (change.card !== undefined) t.marks.push({ table: "dismissed", key: { viewer: change.viewer, thread: change.card.thread, n: change.card.n } });
      if (change.kept !== undefined) t.marks.push({ table: "kept_chats", key: { viewer: change.viewer, thread: change.kept.thread } });
      return true;
    case "chatMark":
      if (change.opened !== undefined) t.sessions.push(change.session);
      if (change.thread !== null) t.threads.push(change.thread);
      return true;
    default:
      return false;
  }
}

/// Times a place is brought level again with a newer head where a batch or chunk the last named went meanwhile.
const STALE_HEADS_MOST = 2;

function isEnoent(e: unknown): boolean {
  return (e as { code?: unknown } | null)?.code === "ENOENT" || (e instanceof Error && e.message.startsWith("ENOENT:"));
}

function headSaid(head: Head): string {
  return `${head.gen}:${head.to}:${head.made}`;
}

async function levelNewest(
  head: Head,
  newest: (cur: Head) => Promise<Head | undefined>,
  go: (head: Head) => Promise<Levelled>,
): Promise<{ head: Head; done: Levelled }> {
  let cur = head;
  let again = 0;
  for (;;) {
    try {
      return { head: cur, done: await go(cur) };
    } catch (e) {
      if (isEnoent(e) && again < STALE_HEADS_MOST) {
        const next = await newest(cur);
        if (next !== undefined && next.batches.length > 0 && headSaid(next) !== headSaid(cur)) {
          again++;
          cur = next;
          continue;
        }
      }
      throw e;
    }
  }
}

export class Copies {
  readonly #d: CopiesDeps;
  readonly kept: FolderPlace;
  #told: Told = nothingTold();
  #gathering: (() => void) | null = null;
  #transcriptGathering: (() => void) | null = null;
  #configSeq = 0;
  readonly #manifestMemo = new Map<string, Promise<Record<string, number>>>();
  #retrying: (() => void) | null = null;
  #wantTranscripts = false;
  #passing: Promise<void> | null = null;
  #again = false;
  #closed = false;
  #passed: WorkPassed | null = null;
  readonly #keeping = new Map<string, Keeping>();
  /// What other stations said they once were, by workspace: the lost station's id, the one that took its place.
  readonly #formerly = new Map<string, Map<string, string>>();
  #handing: Promise<void> | null = null;
  #handAgain: (() => void) | null = null;
  #handTries = 0;
  /// Per `(ws, origin)` incoming write tracking and atomic rename gate for safe handover removal.
  readonly #activeWrites = new Map<string, number>();
  readonly #writeSeq = new Map<string, number>();
  readonly #lastWriteAt = new Map<string, number>();
  readonly #removing = new Map<string, Promise<void>>();
  #restoring: Restoring | null = null;
  /// Why the export is not going (its thread ended, a pass failing), and how many times in a row.
  #exportError: string | null = null;
  #exportTries = 0;
  /// The stations found to be from before copies: they answered `replica.hello` with a refusal.
  readonly #old = new Set<string>();
  /// Whether each peer accepts copies of other stations (from `replica.hello`; absent means true).
  readonly #peerAccepts = new Map<string, boolean>();
  /// Peers recently heard from (online).
  readonly #online = new Set<string>();
  /// Cached S3Place instances keyed by target id + config signature.
  readonly #s3Places = new Map<string, { sig: string; place: S3Place }>();
  #telling: (() => void) | null = null;
  /// Persisted backup & restore history per workspace (at most HISTORY_MAX entries, newest first).
  readonly #history: Map<string, BackupRecord[]>;
  #historySeq = 0;
  #savingHistory: Promise<void> | null = null;
  #saveHistoryAgain = false;

  /// What came of the restore this station was started again for (null: none): written before its store opened and
  /// never after, so read once.
  readonly #restored: Outcome | null;
  /// The stations this one took the place of (formerlyOf, read once).
  readonly #was: string[];

  constructor(d: CopiesDeps) {
    this.#d = d;
    this.kept = new FolderPlace(keptDir(d.data));
    let restored: Outcome | null = null;
    try {
      restored = JSON.parse(readFileSync(outcomeFile(d.data), "utf8")) as Outcome; // sync: read once, before the station serves
    } catch {}
    this.#restored = restored;
    this.#was = formerlyOf(d.data);
    let history = new Map<string, BackupRecord[]>();
    try {
      history = parseHistoryFile(JSON.parse(readFileSync(historyFile(d.data), "utf8"))); // sync: read once, before the station serves
    } catch {}
    this.#history = history;
  }

  /// Begun: the export told where it is, a first pass (the small tables read whole), the other stations told it is up.
  async start(): Promise<void> {
    // (what each place holds asked of it again as this station starts)
    for (const k of this.#keeping.values()) k.known = null;
    await this.placesChanged();
  }

  async close(): Promise<void> {
    this.#closed = true;
    this.#gathering?.();
    this.#gathering = null;
    this.#transcriptGathering?.();
    this.#transcriptGathering = null;
    this.#retrying?.();
    this.#retrying = null;
    this.#telling?.();
    for (const k of this.#keeping.values()) k.again?.();
    this.#handAgain?.();
    // Close the export runner BEFORE awaiting `#passing` so ProgramRunner's closeGraceMs watchdog can force-kill a
    // hung child process and unblock `#passing`.
    await this.#d.runner.close().catch(() => {});
    await this.#passing?.catch(() => {});
    await this.#handing?.catch(() => {});
    while (this.#savingHistory !== null) await this.#savingHistory.catch(() => {});
  }

  /// The station's settings told the copies changed: within `ms` (0: now).
  #changed(ms: number): void {
    if (ms === 0) {
      this.#telling?.();
      this.#telling = null;
      this.#d.changed();
      return;
    }
    if (this.#telling !== null || this.#closed) return;
    this.#telling = this.#d.fibers.after(ms, () => { // timer: a debounce of a burst (a pass a second while agents work)
      this.#telling = null;
      this.#d.changed();
    });
  }

  // ── what changed ──

  /// The store's change, put with what is to be exported: a few keys, nothing read.
  told(change: StoreChange): void {
    if (tell(this.#told, change)) this.#gather();
    if (change.type === "session" || change.type === "conversation" || change.type === "sessionRemoved") {
      this.#gatherTranscripts();
    }
  }

  /// A pass a moment from now (what else changes meanwhile goes with it).
  #gather(): void {
    if (this.#gathering !== null || this.#retrying !== null || this.#closed) return;
    this.#gathering = this.#d.fibers.after(GATHER_MS, () => { // timer: a debounce of a burst of the store's changes
      this.#gathering = null;
      void this.#pass();
    });
  }

  /// An independently debounced transcript scan (never blocks the 1s chat export pass).
  #gatherTranscripts(): void {
    this.#wantTranscripts = true;
    if (this.#transcriptGathering !== null || this.#retrying !== null || this.#closed) return;
    this.#transcriptGathering = this.#d.fibers.after(TRANSCRIPT_GATHER_MS, () => { // timer: a debounce of a burst of transcript writes
      this.#transcriptGathering = null;
      this.#wantTranscripts = false;
      this.#told.transcripts = true;
      void this.#pass();
    });
  }

  /// One pass at a time; what is told meanwhile goes in the next.
  async #pass(): Promise<void> {
    if (this.#passing !== null) {
      this.#again = true;
      return;
    }
    const told = this.#told;
    this.#told = nothingTold();
    this.#again = false;
    const reason = told.transcripts === true
      ? "transcripts"
      : told.sessions.length > 0 || told.threads.length > 0 || told.marks.length > 0 || told.removedSessions.length > 0 || told.removedThreads.length > 0
      ? "demand"
      : "pass";
    this.#passing = (async () => {
      const traces = this.#d.traces?.() ?? null;
      const span = traces?.startRoot() ?? null;
      try {
        const passed = await this.#d.runner.pass(told);
        if (span && traces) traces.endInternal(span, "replica.export", [["stillfail.reason", reason], ["stillfail.changed", passed.wrote]], false, { alwaysKeep: true });
        this.#passed = passed;
        this.#retrying?.();
        this.#retrying = null;
        if (this.#exportError !== null) {
          this.#exportError = null;
          this.#exportTries = 0;
          this.#changed(0);
        } else if (passed.wrote > 0) this.#changed(TELL_MS);
        for (const [ws, head] of Object.entries(passed.heads)) if (head.batches.length > 0) this.#levelAll(ws);
        if (passed.more) this.#again = true;
      } catch (e) {
        if (span && traces) {
          const msg = ((e as Error).message ?? "").toLowerCase();
          const errType = msg.includes("locked") || msg.includes("busy") ? "locked" : msg.includes("enoent") || msg.includes("no such") ? "enoent" : "export";
          traces.endInternal(span, "replica.export", [["stillfail.reason", reason], ["error.type", errType]], true, { alwaysKeep: true });
        }
        log.warn("copies", "an export failed", { error: (e as Error).message });
        // (what was told goes with the next one, a while from now: its thread started again where it ended)
        this.#merge(told);
        this.#again = false;
        this.#gathering?.();
        this.#gathering = null;
        this.#transcriptGathering?.();
        this.#transcriptGathering = null;
        if (this.#exportError === null) this.#changed(0);
        this.#exportError = (e as Error).message;
        const wait = Math.min(RETRY_MS * 2 ** this.#exportTries, RETRY_MOST_MS);
        this.#exportTries++;
        this.#retrying?.();
        this.#retrying = null;
        if (!this.#closed) {
          this.#retrying = this.#d.fibers.after(wait, () => { // timer: a retry after a failure
            this.#retrying = null;
            if (this.#wantTranscripts && this.#transcriptGathering === null) this.#gatherTranscripts();
            void this.#pass();
          });
        }
      }
    })();
    await this.#passing;
    this.#passing = null;
    if (this.#again && !this.#closed) void this.#pass();
  }

  #merge(told: Told): void {
    const t = this.#told;
    t.sessions.push(...told.sessions);
    t.threads.push(...told.threads);
    t.removedSessions.push(...told.removedSessions);
    t.removedThreads.push(...told.removedThreads);
    t.marks.push(...told.marks);
    if (told.transcripts === true) t.transcripts = true;
  }

  /// The export done now, and the places levelled: what a test waits for (it does not wait on a timer).
  async settle(): Promise<void> {
    this.#gathering?.();
    this.#gathering = null;
    this.#transcriptGathering?.();
    this.#transcriptGathering = null;
    if (this.#wantTranscripts) {
      this.#wantTranscripts = false;
      this.#told.transcripts = true;
    }
    do {
      await this.#pass();
      while (this.#passing !== null) await this.#passing;
    } while (this.#again);
    for (;;) {
      const busy = [...this.#keeping.values()].some((k) => k.busy);
      if (!busy && this.#handing === null && this.#savingHistory === null) break;
      await Promise.all([...this.#levelling.values(), this.#handing, this.#savingHistory]);
    }
  }

  // ── the workspaces and their stations ──

  /// The workspaces or their stations changed (or the station started): the export told, what is no longer this
  /// station's to keep let go, the stations told this one is up, the places brought level.
  async placesChanged(): Promise<void> {
    const places = this.#d.places();
    await this.#d.runner.places(places);
    const ins = new Set(places.workspaces.map((w) => w.workspace));
    // (a workspace this station is not in any more: nothing of it kept here)
    const keptRoot = keptDir(this.#d.data);
    for (const root of [keptRoot, join(this.#d.data, "replica", "own")]) {
      for (const ws of await readdir(root).catch(() => [] as string[])) {
        if (WORKSPACE.test(ws) && !ins.has(ws)) {
          await rm(join(root, ws), { recursive: true, force: true });
          if (root === keptRoot) this.kept.forget(ws);
        }
      }
    }
    for (const k of [...this.#keeping.keys()]) if (!ins.has(k.split("\n")[0]!)) this.#keeping.delete(k);
    const s3Ids = new Set(this.#backup().s3.map((t) => `s3:${t.id}`));
    for (const ws of ins) {
      const peerTargets = this.#targets(ws);
      for (const k of [...this.#keeping.keys()]) {
        const [w, dest] = k.split("\n");
        if (w === ws && !peerTargets.includes(dest!) && !s3Ids.has(dest!)) {
          this.#keeping.get(k)?.again?.();
          this.#keeping.delete(k);
        }
      }
    }
    void this.#pass().then(() => {
      if (this.#passed?.empty === true) for (const ws of ins) void this.look(ws).catch(() => {});
    });
    this.#hello();
    this.#handOverSoon();
  }

  #backup(): NormalizedBackupConfig {
    return this.#d.backup?.() ?? DEFAULT_BACKUP;
  }

  #s3Sig(t: NormalizedS3Target): string {
    return JSON.stringify([t.endpoint, t.region, t.bucket, t.prefix, t.forcePathStyle, t.accessKeyId, t.secretAccessKey, t.encryptionKey, t.includeTranscripts]);
  }

  #s3Place(t: NormalizedS3Target): S3Place {
    const sig = this.#s3Sig(t);
    const cur = this.#s3Places.get(t.id);
    if (cur !== undefined && cur.sig === sig) return cur.place;
    const place = new S3Place(t, this.#d.s3ClientOptions);
    this.#s3Places.set(t.id, { sig, place });
    return place;
  }

  /// Called after `config.json`'s `backup` section changes: prunes removed targets, refreshes S3 places, levels active
  /// targets, re-announces `acceptCopies` to peers, hands over kept copies if `acceptOthers` turned false, and scans
  /// S3 for restorable backups if this station is empty.
  configChanged(): void {
    this.#configSeq++;
    const cfg = this.#backup();
    const s3ById = new Map(cfg.s3.map((t) => [t.id, t]));
    for (const [id, entry] of [...this.#s3Places.entries()]) {
      const next = s3ById.get(id);
      if (next === undefined || this.#s3Sig(next) !== entry.sig) {
        this.#s3Places.delete(id);
        for (const [k, v] of this.#keeping) {
          if (k.endsWith(`\ns3:${id}`)) {
            v.known = null;
            v.head = null;
            v.again?.();
            v.again = null;
          }
        }
      }
    }
    const ins = this.#d.places().workspaces.map((w) => w.workspace);
    const s3Keys = new Set(cfg.s3.map((t) => `s3:${t.id}`));
    for (const ws of ins) {
      const peerTargets = this.#targets(ws);
      for (const k of [...this.#keeping.keys()]) {
        const [w, dest] = k.split("\n");
        if (w === ws && !peerTargets.includes(dest!) && !s3Keys.has(dest!)) {
          this.#keeping.get(k)?.again?.();
          this.#keeping.delete(k);
        }
      }
      this.#levelAll(ws);
      if (this.#passed?.empty === true) void this.look(ws).catch(() => {});
    }
    this.#hello();
    this.#handOverSoon();
    this.#changed(0);
  }

  #keepersOf(ws: string): string[] {
    const here = this.#d.here();
    const roster = this.#d.roster(ws);
    return here === null || roster === null ? [] : keepers(ws, here, roster.map((s) => s.id));
  }

  /// Each other station of each workspace told this one is up (and what it once was): one that keeps this station's
  /// copies is brought level as it answers, one whose copies this one keeps knows to bring them.
  #hello(): void {
    const here = this.#d.here();
    if (here === null) return;
    const formerly = this.#was;
    const acceptCopies = this.#backup().acceptOthers;
    for (const { workspace: ws } of this.#d.places().workspaces) {
      for (const s of this.#d.roster(ws) ?? []) {
        if (s.id === here) continue;
        void this.#d.ask(s.id, { method: "replica.hello", workspace: ws, formerly, acceptCopies }).then(
          (answer) => {
            this.#old.delete(s.id);
            this.#online.add(s.id);
            const accepts = answer?.acceptCopies !== false;
            const prev = this.#peerAccepts.get(s.id);
            this.#peerAccepts.set(s.id, accepts);
            this.#heardFormerly(ws, s.id, Array.isArray(answer?.formerly) ? answer.formerly : []);
            if (prev !== accepts) {
              this.#changed(0);
              if (!accepts && this.#backup().mode === "auto") this.#levelAll(ws);
            }
          },
          (e) => {
            // (one that answers with a refusal is up but knows no `replica.*`: from before copies)
            if (e instanceof Refused) this.#old.add(s.id);
            else this.#online.delete(s.id);
          },
        );
      }
    }
  }

  #heardFormerly(ws: string, station: string, formerly: string[]): void {
    let m = this.#formerly.get(ws);
    if (m === undefined) this.#formerly.set(ws, (m = new Map()));
    for (const f of formerly) if (STATION.test(f)) m.set(f, station);
  }

  /// The station that took the place of `station` (a lost one) in `ws`, as it said; `station` itself where none did.
  now(ws: string | null, station: string): string {
    if (this.#was.includes(station)) return this.#d.here() ?? station;
    for (const [w, m] of this.#formerly) if (ws === null || w === ws) {
      const s = m.get(station);
      if (s !== undefined) return s;
    }
    return station;
  }

  /// Another station is up (`replica.hello`): it is brought what it keeps of this one; what this station keeps and
  /// should hand over may go to it now. What this station once was, said back.
  heard(peer: string, ws: string, formerly: string[], acceptCopies = true): string[] {
    this.#heardFormerly(ws, peer, formerly);
    this.#old.delete(peer);
    this.#online.add(peer);
    const prev = this.#peerAccepts.get(peer);
    this.#peerAccepts.set(peer, acceptCopies);
    if (prev !== acceptCopies) this.#changed(0);
    // (it is up: what it holds asked of it again, and brought level where it is one of those that keep this one's)
    const k = this.#keeping.get(`${ws}\n${peer}`);
    if (k !== undefined) k.known = null;
    if (acceptCopies && (this.#targets(ws).includes(peer) || (this.#backup().mode === "auto" && this.#keepersOf(ws).includes(peer)))) {
      this.#level(ws, peer, { now: true, fresh: true });
    } else if (!acceptCopies && this.#backup().mode === "auto") {
      this.#levelAll(ws);
    }
    this.#handOverSoon();
    return this.#was;
  }

  inWorkspace(peer: string, ws: string): boolean {
    return this.#d.places().workspaces.some((w) => w.workspace === ws) && (this.#d.roster(ws) ?? []).some((s) => s.id === peer);
  }

  async #guardWrite<T>(ws: string, origin: string, fn: () => Promise<T>): Promise<T> {
    const key = `${ws}\n${origin}`;
    while (this.#removing.has(key)) await this.#removing.get(key);
    this.#activeWrites.set(key, (this.#activeWrites.get(key) ?? 0) + 1);
    this.#writeSeq.set(key, (this.#writeSeq.get(key) ?? 0) + 1);
    this.#lastWriteAt.set(key, this.#d.fibers.now());
    try {
      return await fn();
    } finally {
      const left = (this.#activeWrites.get(key) ?? 1) - 1;
      if (left <= 0) this.#activeWrites.delete(key);
      else this.#activeWrites.set(key, left);
      this.#lastWriteAt.set(key, this.#d.fibers.now());
    }
  }

  /// What this station answers of the copies it keeps (`replica.*`).
  answers() {
    return serve({
      place: this.kept,
      inWorkspace: (peer, ws) => this.inWorkspace(peer, ws),
      hello: (peer, ws, formerly, acceptCopies) => this.heard(peer, ws, formerly, acceptCopies),
      acceptOthers: () => this.#backup().acceptOthers,
      guardWrite: (ws, origin, fn) => this.#guardWrite(ws, origin, fn),
    });
  }

  // ── this station's copies, at the stations that keep them ──

  readonly #levelling = new Map<string, Promise<void>>();
  /// A new generation begun for a workspace, from the one found behind: the places that find it so wait on the one.
  readonly #begun = new Map<string, { from: string; done: Promise<void> }>();

  #levelAll(ws: string): void {
    for (const peer of this.#targets(ws)) this.#level(ws, peer, {});
    for (const target of this.#backup().s3) this.#levelS3(ws, target, {});
  }

  /// The stations that should hold this station's copies in `ws` now: in manual mode, the configured station ids in
  /// the roster; in auto mode, those it falls to (`keepers`, skipping peers with `acceptOthers === false`) and, while
  /// one of them is not reached, the next in the same order (`ranked`), so that COPIES reached ones hold it.
  #targets(ws: string): string[] {
    const here = this.#d.here();
    const roster = this.#d.roster(ws);
    if (here === null || roster === null) return [];
    const cfg = this.#backup();
    const rosterIds = new Set(roster.map((r) => r.id));
    if (cfg.mode === "manual") {
      return cfg.stations.filter((s) => s !== here && rosterIds.has(s));
    }
    const out: string[] = [];
    let reached = 0;
    for (const s of ranked(ws, here, roster.map((r) => r.id))) {
      if (this.#peerAccepts.get(s) === false) continue;
      out.push(s);
      if (this.#keeping.get(`${ws}\n${s}`)?.error == null) reached++;
      if (reached >= COPIES) break;
    }
    return out;
  }

  /// Why `error` kept a place from being brought level, as the settings say it.
  #reason(peer: string, error: unknown): Reason {
    if (this.#old.has(peer)) return "old";
    // (a station from before copies answers `replica.*` as a task's request: "session and task key are required")
    if (error instanceof Refused) return /no such replica request|is required|are required|unknown/.test(error.message) ? "old" : "error";
    return "offline";
  }

  async #newestHead(ws: string, current: Head): Promise<Head | undefined> {
    let next = this.#passed?.heads[ws];
    if ((next === undefined || headSaid(next) === headSaid(current)) && this.#passing !== null) {
      await this.#passing.catch(() => {});
      next = this.#passed?.heads[ws];
    }
    return next;
  }

  /// `now`: not waiting for a retry already set; `fresh`: what the place holds asked of it, not taken as known.
  #level(ws: string, peer: string, o: { now?: boolean; fresh?: boolean }): void {
    const now = o.now === true;
    const key = `${ws}\n${peer}`;
    let k = this.#keeping.get(key);
    if (k === undefined) this.#keeping.set(key, (k = { to: 0, at: null, error: null, reason: null, missing: 0, busy: false, again: null, tries: 0, asked: false, known: null, head: null, partial: false, lacking: 0 }));
    if (k.busy) {
      k.asked = true;
      return;
    }
    if (k.again !== null && !now) return;
    // (one from before copies, found so: asked again only once it is heard from, `heard`, never by a pass or a retry)
    if (!now && k.error !== null && k.reason === "old" && this.#old.has(peer)) return;
    k.again?.();
    k.again = null;
    const head = this.#passed?.heads[ws];
    if (head === undefined || head.batches.length === 0) return;
    if (o.fresh === true) k.known = null;
    // (a place level with this head already: nothing to send)
    const said = headSaid(head);
    if (k.known !== null && k.head === said && k.error === null) return;
    k.busy = true;
    const keeping = k;
    const wasError = k.error;
    const prevReason = k.reason;
    const startConfigSeq = this.#configSeq;
    // (the chats there before the transcripts: said as they are, while those go on)
    const onPartial = (to: number, lacking: number) => {
      keeping.to = to;
      keeping.at = this.#d.fibers.now();
      keeping.partial = true;
      keeping.lacking = lacking;
      this.#changed(0);
    };
    const run = (async () => {
      const traces = this.#d.traces?.() ?? null;
      const span = traces?.startRoot() ?? null;
      try {
        const place = new PeerPlace(peer, this.#d.ask);
        let { head: syncedHead, done } = await levelNewest(
          head,
          (cur) => this.#newestHead(ws, cur),
          (h) => level(place, ws, this.#own(h), keeping.known, { onPartial }),
        );
        if (done.behind) {
          // This station's own copy is behind what that station keeps of it: its data was rolled back. A new
          // generation (one for all the places that find it so), written there beside what it keeps.
          let begun = this.#begun.get(ws);
          if (begun === undefined || begun.from !== syncedHead.gen) {
            const fromGen = syncedHead.gen;
            const origin = syncedHead.origin;
            begun = { from: fromGen, done: (async () => {
              const held = await place.held(ws, origin);
              await this.#d.runner.newGenerations(Math.max(0, ...held.gens.map((g) => genMade(g.gen))));
              await this.settleExport();
            })() };
            this.#begun.set(ws, begun);
          }
          await begun.done;
          const next = this.#passed?.heads[ws];
          if (next === undefined) throw new Error("no copy of this workspace's");
          syncedHead = next;
          done = await level(place, ws, this.#own(next), null, { onPartial });
          if (done.behind) throw new Error("that station keeps more of this station's than it has");
        }
        if (this.#configSeq === startConfigSeq) {
          keeping.known = done.known;
          keeping.head = headSaid(syncedHead);
        } else {
          keeping.known = null;
          keeping.head = null;
          keeping.asked = true;
        }
        keeping.reason = null;
        keeping.to = done.to;
        keeping.missing = done.missing;
        keeping.at = this.#d.fibers.now();
        keeping.error = null;
        keeping.tries = 0;
        keeping.partial = false;
        keeping.lacking = 0;
        this.#pruneNonTargets(ws);
        this.#record(ws, {
          at: keeping.at,
          kind: "sync",
          targetKind: "station",
          target: peer,
          targetName: this.#peerName(ws, peer),
          status: "ok",
          chats: syncedHead.chats,
          messages: syncedHead.messages,
          batches: syncedHead.batches.length,
          bytes: syncedHead.bytes,
          reason: null,
          error: null,
        });
        if (span && traces) traces.endInternal(span, "replica.level", [["stillfail.target_kind", "station"], ["stillfail.missing", done.missing]], false, { alwaysKeep: false, slowMs: 500 });
      } catch (e) {
        const reason = this.#reason(peer, e);
        if (span && traces) {
          const msg = ((e as Error).message ?? "").toLowerCase();
          const errType = msg.includes("enoent") || msg.includes("no such") ? "enoent" : reason === "offline" || msg.includes("network") || msg.includes("timeout") || msg.includes("unreached") || msg.includes("reset") ? "network" : reason === "old" ? "old" : "other";
          traces.endInternal(span, "replica.level", [["stillfail.target_kind", "station"], ["error.type", errType]], true, { alwaysKeep: false, slowMs: 500 });
        }
        // (one from before copies, which knows no `replica.*`: nothing to say or retry until it says it is up, as
        // share/memory.ts does; 15 stations said so 49 times an hour, 2026-11-18)
        if (reason === "old") this.#old.add(peer);
        else if (keeping.error === null) log.warn("copies", "a place not brought level", { ws, place: peer, error: (e as Error).message });
        keeping.error = (e as Error).message;
        keeping.reason = reason;
        keeping.known = null;
        if (wasError === null || reason !== prevReason) {
          this.#record(ws, {
            at: this.#d.fibers.now(),
            kind: "sync",
            targetKind: "station",
            target: peer,
            targetName: this.#peerName(ws, peer),
            status: "error",
            chats: 0,
            messages: 0,
            batches: 0,
            bytes: 0,
            reason,
            error: keeping.error,
          });
        }
        if (reason !== "old" && this.#targets(ws).includes(peer)) {
          const wait = Math.min(RETRY_MS * 2 ** keeping.tries, RETRY_MOST_MS);
          keeping.tries++;
          if (!this.#closed) keeping.again = this.#d.fibers.after(wait, () => { // timer: a retry after a failure
            keeping.again = null;
            if (!this.#targets(ws).includes(peer)) return;
            this.#level(ws, peer, { now: true, fresh: true });
          });
        }
        // (one not reached: the next station after those this one's copies fall to holds them meanwhile)
        if (wasError === null && this.#backup().mode === "auto") this.#levelAll(ws);
      } finally {
        keeping.busy = false;
        this.#changed(keeping.error === wasError ? TELL_MS : 0);
      }
    })();
    this.#levelling.set(key, run);
    void run.then(() => {
      if (this.#levelling.get(key) === run) this.#levelling.delete(key);
      if (keeping.asked && !this.#closed) {
        keeping.asked = false;
        if (this.#targets(ws).includes(peer)) this.#level(ws, peer, { now: keeping.error === null });
      }
      if (!keeping.busy && keeping.again === null && !this.#targets(ws).includes(peer)) {
        if (this.#keeping.get(key) === keeping) this.#keeping.delete(key);
      }
    });
  }

  /// Cancels pending retries and drops idle keeping state for peers no longer targeted in `ws` (e.g. overflow keepers
  /// after a primary keeper recovers). Never touches other workspaces or `s3:` targets.
  #pruneNonTargets(ws: string): void {
    const active = new Set(this.#targets(ws));
    for (const [k, v] of [...this.#keeping.entries()]) {
      const [w, dest] = k.split("\n");
      if (w !== ws || dest === undefined || dest.startsWith("s3:") || active.has(dest)) continue;
      v.again?.();
      v.again = null;
      v.asked = false;
      if (!v.busy) this.#keeping.delete(k);
    }
  }

  #levelS3(ws: string, target: NormalizedS3Target, o: { now?: boolean; fresh?: boolean }): void {
    const now = o.now === true;
    const key = `${ws}\ns3:${target.id}`;
    let k = this.#keeping.get(key);
    if (k === undefined) {
      this.#keeping.set(
        key,
        (k = { to: 0, at: null, error: null, reason: null, missing: 0, busy: false, again: null, tries: 0, asked: false, known: null, head: null, partial: false, lacking: 0 }),
      );
    }
    if (k.busy) {
      k.asked = true;
      return;
    }
    if (k.again !== null && !now) return;
    k.again?.();
    k.again = null;
    const head = this.#passed?.heads[ws];
    if (head === undefined || head.batches.length === 0) return;
    if (o.fresh === true) k.known = null;
    const said = headSaid(head);
    if (k.known !== null && k.head === said && k.error === null) return;
    k.busy = true;
    const keeping = k;
    const wasError = k.error;
    const prevReason = k.reason;
    const startConfigSeq = this.#configSeq;
    const run = (async () => {
      const traces = this.#d.traces?.() ?? null;
      const span = traces?.startRoot() ?? null;
      try {
        const place = this.#s3Place(target);
        const opts = {
          includeTranscripts: target.includeTranscripts,
          onPruneError: (err: unknown) => {
            log.warn("copies", "S3 orphan cleanup failed", { ws, target: target.id, error: err instanceof Error ? err.message : String(err) });
          },
        };
        let { head: syncedHead, done } = await levelNewest(
          head,
          (cur) => this.#newestHead(ws, cur),
          (h) => level(place, ws, this.#own(h), keeping.known, opts),
        );
        if (done.behind) {
          let begun = this.#begun.get(ws);
          if (begun === undefined || begun.from !== syncedHead.gen) {
            const fromGen = syncedHead.gen;
            const origin = syncedHead.origin;
            begun = {
              from: fromGen,
              done: (async () => {
                const held = await place.held(ws, origin);
                await this.#d.runner.newGenerations(Math.max(0, ...held.gens.map((g) => genMade(g.gen))));
                await this.settleExport();
              })(),
            };
            this.#begun.set(ws, begun);
          }
          await begun.done;
          const next = this.#passed?.heads[ws];
          if (next === undefined) throw new Error("no copy of this workspace's");
          syncedHead = next;
          done = await level(place, ws, this.#own(next), null, opts);
          if (done.behind) throw new Error("that S3 target keeps more of this station's than it has");
        }
        if (this.#configSeq === startConfigSeq) {
          keeping.known = done.known;
          keeping.head = headSaid(syncedHead);
        } else {
          keeping.known = null;
          keeping.head = null;
          keeping.asked = true;
        }
        keeping.reason = null;
        keeping.to = done.to;
        keeping.missing = done.missing;
        keeping.at = this.#d.fibers.now();
        keeping.error = null;
        keeping.tries = 0;
        this.#record(ws, {
          at: keeping.at,
          kind: "sync",
          targetKind: "s3",
          target: target.id,
          targetName: target.name || target.bucket,
          status: "ok",
          chats: syncedHead.chats,
          messages: syncedHead.messages,
          batches: syncedHead.batches.length,
          bytes: syncedHead.bytes,
          reason: null,
          error: null,
        });
        if (span && traces) traces.endInternal(span, "replica.level", [["stillfail.target_kind", "s3"], ["stillfail.missing", done.missing]], false, { alwaysKeep: false, slowMs: 500 });
      } catch (e) {
        const reason: Reason = e instanceof S3HttpError ? "error" : "offline";
        if (span && traces) {
          const msg = ((e as Error).message ?? "").toLowerCase();
          const errType = msg.includes("enoent") || msg.includes("no such") ? "enoent" : reason === "offline" || msg.includes("network") || msg.includes("timeout") || msg.includes("unreached") || msg.includes("reset") ? "network" : "other";
          traces.endInternal(span, "replica.level", [["stillfail.target_kind", "s3"], ["error.type", errType]], true, { alwaysKeep: false, slowMs: 500 });
        }
        if (keeping.error === null) log.warn("copies", "an S3 place not brought level", { ws, s3: target.id, error: (e as Error).message });
        keeping.error = (e as Error).message;
        keeping.reason = reason;
        keeping.known = null;
        if (wasError === null || reason !== prevReason) {
          this.#record(ws, {
            at: this.#d.fibers.now(),
            kind: "sync",
            targetKind: "s3",
            target: target.id,
            targetName: target.name || target.bucket,
            status: "error",
            chats: 0,
            messages: 0,
            batches: 0,
            bytes: 0,
            reason,
            error: keeping.error,
          });
        }
        const wait = Math.min(RETRY_MS * 2 ** keeping.tries, RETRY_MOST_MS);
        keeping.tries++;
        if (!this.#closed) {
          keeping.again = this.#d.fibers.after(wait, () => { // timer: a retry after a failure
            keeping.again = null;
            const latest = this.#backup().s3.find((t) => t.id === target.id);
            if (latest !== undefined) this.#levelS3(ws, latest, { now: true, fresh: true });
          });
        }
      } finally {
        keeping.busy = false;
        this.#changed(keeping.error === wasError ? TELL_MS : 0);
      }
    })();
    this.#levelling.set(key, run);
    void run.then(() => {
      if (this.#levelling.get(key) === run) this.#levelling.delete(key);
      if (keeping.asked && !this.#closed) {
        keeping.asked = false;
        const latest = this.#backup().s3.find((t) => t.id === target.id);
        if (latest !== undefined) this.#levelS3(ws, latest, { now: keeping.error === null });
      }
    });
  }

  /// The export brought to rest (no pass under way, nothing more waiting).
  async settleExport(): Promise<void> {
    do {
      await this.#pass();
      while (this.#passing !== null) await this.#passing;
    } while (this.#again);
  }

  #loadLocalTranscriptFilesMemo(replicaDir: string, head: Head): Promise<Record<string, number>> {
    if (head.transcriptManifest === undefined) {
      return Promise.resolve(head.transcriptFiles ?? {});
    }
    const key = `${replicaDir}\n${head.gen}\n${head.transcriptManifest}`;
    const existing = this.#manifestMemo.get(key);
    if (existing !== undefined) {
      this.#manifestMemo.delete(key);
      this.#manifestMemo.set(key, existing);
      return existing;
    }
    const p = loadLocalTranscriptFiles(replicaDir, head).catch((err) => {
      if (this.#manifestMemo.get(key) === p) this.#manifestMemo.delete(key);
      throw err;
    });
    while (this.#manifestMemo.size >= 2) {
      const oldest = this.#manifestMemo.keys().next().value;
      if (oldest === undefined) break;
      this.#manifestMemo.delete(oldest);
    }
    this.#manifestMemo.set(key, p);
    return p;
  }

  #own(head: Head) {
    const replicaDir = join(this.#d.data, "replica");
    const dir = join(replicaDir, "own", head.workspace, head.gen);
    return {
      head,
      batch: (name: string) => readFile(join(dir, "log", name)),
      sources: async (hashes: string[]) => new Map(Object.entries(await this.#d.runner.sources(hashes))),
      loadTranscriptFiles: () => this.#loadLocalTranscriptFilesMemo(replicaDir, head),
    };
  }

  // ── what this station keeps of others ──

  #handOverSoon(): void {
    if (this.#handing !== null || this.#closed) return;
    this.#handAgain?.();
    this.#handAgain = null;
    this.#handing = this.#handOver()
      .then((left) => {
        this.#handTries = 0;
        if (left && !this.#closed) this.#retryHand();
      }, (e) => {
        log.warn("copies", "copies not handed over", { error: (e as Error).message });
        this.#retryHand();
      })
      .finally(() => (this.#handing = null));
  }

  #retryHand(): void {
    const wait = Math.min(RETRY_MS * 2 ** this.#handTries, RETRY_MOST_MS);
    this.#handTries++;
    this.#handAgain = this.#d.fibers.after(wait, () => this.#handOverSoon()); // timer: a retry after a failure
  }

  /// The copies this station keeps that are not its to keep now (the stations that keep each are worked out again as
  /// stations come and go): handed to those that should keep them, and let go once each of them says it holds as much.
  /// Whether some are left to hand over (one of those stations not reached).
  async #handOver(): Promise<boolean> {
    const here = this.#d.here();
    if (here === null) return false;
    let left = false;
    for (const { workspace: ws } of this.#d.places().workspaces) {
      const roster = this.#d.roster(ws);
      if (roster === null) continue;
      const taking = this.#d.taking?.() ?? new Set<string>();
      const wsDir = join(keptDir(this.#d.data), ws);
      for (const origin of await readdir(wsDir).catch(() => [] as string[])) {
        if (origin.startsWith(".dropping-")) {
          await rm(join(wsDir, origin), { recursive: true, force: true }).catch(() => {});
          continue;
        }
        if (!STATION.test(origin) || origin === here || taking.has(origin)) continue;
        const acceptOthers = this.#backup().acceptOthers;
        const eligible = acceptOthers
          ? roster.map((s) => s.id)
          : roster.filter((s) => s.id !== here && this.#peerAccepts.get(s.id) !== false).map((s) => s.id);
        const should = keepers(ws, origin, eligible);
        if (should.includes(here)) continue;
        const key = `${ws}\n${origin}`;
        if ((this.#activeWrites.get(key) ?? 0) > 0) {
          left = true;
          continue;
        }
        const lastWrite = this.#lastWriteAt.get(key);
        if (acceptOthers && lastWrite !== undefined && this.#d.fibers.now() - lastWrite < HANDOVER_QUIET_MS) {
          left = true;
          continue;
        }
        const seqBefore = this.#writeSeq.get(key) ?? 0;
        let mine: Held;
        try {
          mine = await this.kept.heldStrict(ws, origin);
        } catch {
          left = true;
          continue;
        }
        if (mine.hasUnverifiedHead === true) {
          left = true;
          continue;
        }
        let all = should.length > 0;
        for (const peer of should) {
          try {
            if (!(await handOver(this.kept, new PeerPlace(peer, this.#d.ask), ws, origin))) all = false;
          } catch {
            all = false;
          }
        }
        if (all) {
          // (each of them holds as much as this one did: asked again just before it goes)
          const readMine = (hash: string, maxBytes: number) => this.kept.readBounded(ws, origin, null, hash, maxBytes);
          const still = await Promise.all(
            should.map(async (p) => {
              const peerPlace = new PeerPlace(p, this.#d.ask);
              try {
                const h = await peerPlace.held(ws, origin);
                const readTheirs = async (hash: string, maxBytes: number) => {
                  try {
                    return await readBytes(await peerPlace.read(ws, origin, null, hash), Math.min(MOST, maxBytes));
                  } catch {
                    return null;
                  }
                };
                return await holdsAllLogical(mine, h, { readMine, readTheirs });
              } catch {
                return false;
              }
            }),
          );
          if (still.every((x) => x)) {
            if ((this.#activeWrites.get(key) ?? 0) > 0 || (this.#writeSeq.get(key) ?? 0) !== seqBefore) {
              left = true;
              continue;
            }
            const dropping = join(wsDir, `.dropping-${origin}-${randomBytes(4).toString("hex")}`);
            let release!: () => void;
            this.#removing.set(key, new Promise<void>((r) => { release = r; }));
            let renamed = false;
            try {
              await rename(join(wsDir, origin), dropping);
              renamed = true;
              this.kept.forget(ws, origin);
              this.#lastWriteAt.delete(key);
            } catch (e) {
              if (!isEnoent(e)) throw e;
            } finally {
              this.#removing.delete(key);
              release();
            }
            if (renamed) {
              await rm(dropping, { recursive: true, force: true }).catch((e) => {
                log.warn("copies", "dropping directory not removed", { ws, origin, error: (e as Error).message });
              });
            }
            log.info("copies", "a station's copies handed over", { ws, origin, to: should });
            continue;
          }
        }
        left = true;
      }
    }
    return left;
  }

  // ── backup & restore history ──

  #peerName(ws: string, peer: string): string {
    const found = (this.#d.roster(ws) ?? []).find((s) => s.id === peer);
    return found !== undefined && found.name !== "" ? found.name : peer.slice(0, 8);
  }

  #s3TargetName(id: string): string {
    const found = this.#backup().s3.find((t) => t.id === id);
    if (found === undefined) return id;
    return found.name !== "" ? found.name : found.bucket;
  }

  #record(ws: string, entry: Omit<BackupRecord, "id">): void {
    const id = `${Math.trunc(entry.at)}-${++this.#historySeq}`;
    const rec: BackupRecord = { id, ...entry };
    let list = this.#history.get(ws);
    if (list === undefined) this.#history.set(ws, (list = []));
    // (a sync that went well after one that went well to the same place takes its place: a place brought level at
    // every pass filled the history in minutes, 2026-11-23)
    if (rec.kind === "sync" && rec.status === "ok") {
      const i = list.findIndex((r) => r.kind === "sync" && r.target === rec.target);
      if (i >= 0 && list[i]!.status === "ok") list.splice(i, 1);
    }
    list.unshift(rec);
    list.sort((a, b) => b.at - a.at);
    if (list.length > HISTORY_MAX) list.length = HISTORY_MAX;
    this.#saveHistory();
  }

  #saveHistory(): void {
    if (this.#savingHistory !== null) {
      this.#saveHistoryAgain = true;
      return;
    }
    this.#saveHistoryAgain = false;
    const path = historyFile(this.#d.data);
    const tmp = `${path}.tmp`;
    const workspaces: Record<string, BackupRecord[]> = {};
    for (const [ws, list] of this.#history) workspaces[ws] = list.slice(0, HISTORY_MAX);
    const payload = JSON.stringify({ v: 1, workspaces });
    const run = (async () => {
      try {
        await mkdir(join(this.#d.data, "replica"), { recursive: true });
        await writeFile(tmp, payload, "utf8");
        await rename(tmp, path);
      } catch (e) {
        log.warn("copies", "backup history not saved", { error: (e as Error).message });
      }
    })();
    this.#savingHistory = run;
    void run.finally(() => {
      if (this.#savingHistory === run) this.#savingHistory = null;
      if (this.#saveHistoryAgain) this.#saveHistory();
    });
  }

  #restoredRecord(ws: string): BackupRecord | null {
    const o = this.#restored;
    if (o === null) return null;
    const isS3 = o.from.startsWith("s3:");
    const target = isS3 ? o.from.slice(3) : o.from;
    const targetName = isS3 ? this.#s3TargetName(target) : target !== "" ? this.#peerName(ws, target) : o.name;
    const reason: RestoreReason | null = o.reason === "full" ? "error" : (o.reason ?? null);
    return {
      id: `restore-${Math.trunc(o.at)}`,
      at: o.at,
      kind: "restore",
      targetKind: isS3 ? "s3" : "station",
      target,
      targetName,
      status: o.error === null ? "ok" : "error",
      chats: typeof o.rows?.sessions === "number" ? o.rows.sessions : 0,
      messages: typeof o.rows?.entries === "number" ? o.rows.entries : 0,
      batches: 0,
      bytes: 0,
      reason,
      error: o.error,
    };
  }

  /// Recent backup & restore records for `ws` (newest first, clamped to 1..50).
  history(ws: string, limit = 30): BackupRecord[] {
    const n = Math.max(1, Math.min(HISTORY_MAX, Number.isFinite(limit) ? Math.trunc(limit) : 30));
    const list = (this.#history.get(ws) ?? []).slice();
    const restored = this.#restoredRecord(ws);
    if (restored !== null && !list.some((r) => r.kind === "restore" && r.at === restored.at)) {
      list.push(restored);
      list.sort((a, b) => b.at - a.at);
    }
    return list.slice(0, n).map((r) => ({ ...r }));
  }

  // ── what the station's settings show ──

  /// Sanitized backup configuration & status view for `overview.copies.backup` and `GET /copies/settings`.
  backupView(ws: string): BackupView {
    const here = this.#d.here();
    const roster = this.#d.roster(ws) ?? [];
    const peers = roster
      .filter((s) => s.id !== here)
      .map((s) => ({
        station: s.id,
        name: s.name,
        acceptOthers: this.#peerAccepts.get(s.id) !== false,
        online: this.#online.has(s.id),
      }));
    return buildBackupView(this.#backup(), peers, (id) => {
      const k = this.#keeping.get(`${ws}\ns3:${id}`);
      return { to: k?.to ?? 0, at: k?.at ?? null, error: k?.error ?? null, reason: k?.reason ?? null };
    });
  }

  /// The copies of this station's chats in `ws`, as its settings show them: the stations that keep them and how far
  /// each goes; on a station with no chat of its own, the backups of stations no longer there it could restore.
  overview(ws: string, manage = false): unknown {
    const here = this.#d.here();
    const head = this.#passed?.heads[ws] ?? null;
    const names = new Map((this.#d.roster(ws) ?? []).map((s) => [s.id, s.name]));
    return {
      to: head?.to ?? 0,
      chats: head?.chats ?? 0,
      keepers: (here === null ? [] : this.#targets(ws)).map((station) => {
        const k = this.#keeping.get(`${ws}\n${station}`);
        return { station, name: names.get(station) ?? "", to: k?.to ?? 0, at: k?.at ?? null, error: k?.error ?? null, reason: k?.reason ?? null, partial: k?.partial ?? false, lacking: k?.lacking ?? 0 };
      }),
      backup: this.backupView(ws),
      // (the export not going: why, and since how many tries)
      stopped: this.#exportError === null ? null : { error: this.#exportError, tries: this.#exportTries, reason: /ENOSPC|disk is full|database or disk is full/i.test(this.#exportError) ? "full" : "error" },
      // (what came of the restore this station started again for: kept after the restart)
      restored: this.#restored,
      empty: this.#passed?.empty ?? false,
      restoring: this.#restoring !== null && this.#restoring.workspace === ws ? this.#restoring : null,
      // (on a station with no chat of its own: the lost stations' copies it could take back, as last looked for)
      restorable: this.#passed?.empty === true ? (this.#looked.get(ws) ?? null) : null,
      manage,
      formerly: this.#was,
    };
  }

  /// The copies a station with no chat of its own could take back, looked for again as it starts and as the
  /// workspace's stations change.
  readonly #looked = new Map<string, { copies: unknown[]; at: number; looking: boolean }>();

  async look(ws: string): Promise<void> {
    if (this.#passed?.empty !== true) return;
    const was = this.#looked.get(ws);
    this.#looked.set(ws, { copies: was?.copies ?? [], at: was?.at ?? 0, looking: true });
    this.#changed(0);
    let copies: unknown[] = [];
    try {
      copies = await this.restorable(ws);
    } finally {
      this.#looked.set(ws, { copies, at: this.#d.fibers.now(), looking: false });
      this.#changed(0);
    }
  }

  // ── a lost station's copy, brought back into this one ──

  /// The copies of stations of `ws` no longer there (none answers for it) that could be brought back here: each one's
  /// latest generation, as far as the furthest of the stations or S3 targets that keep it.
  async restorable(ws: string): Promise<unknown[]> {
    const here = this.#d.here();
    type FromEntry = { key: string; item: { station: string; name: string } | { s3: string; name: string } };
    const found = new Map<string, { head: Head; from: FromEntry[] }>();
    const add = (head: Head, entry: FromEntry) => {
      if (head.origin === here) return;
      const was = found.get(head.origin);
      const newer = was === undefined || genMade(head.gen) > genMade(was.head.gen) || (head.gen === was.head.gen && head.to > was.head.to);
      if (newer) found.set(head.origin, { head, from: [entry] });
      else if (head.gen === was!.head.gen && head.to === was!.head.to && !was!.from.some((f) => f.key === entry.key)) was!.from.push(entry);
    };
    const roster = this.#d.roster(ws) ?? [];
    const names = new Map(roster.map((s) => [s.id, s.name]));
    // (a lost station another already took the place of is not offered: two machines would both take it)
    const taken = new Set(this.#was);
    // (nor a station that is there: it answers, and its chats are its own to keep)
    const there = new Set<string>();
    const acceptCopies = this.#backup().acceptOthers;
    await Promise.all([
      ...roster.filter((s) => s.id !== here).map(async (s) => {
        try {
          const answer = await this.#d.ask(s.id, { method: "replica.hello", workspace: ws, formerly: this.#was, acceptCopies });
          there.add(s.id);
          this.#online.add(s.id);
          this.#peerAccepts.set(s.id, answer?.acceptCopies !== false);
          const said = Array.isArray(answer?.formerly) ? answer.formerly.filter((f: unknown): f is string => typeof f === "string") : [];
          this.#heardFormerly(ws, s.id, said);
          for (const f of said) taken.add(f);
          for (const o of await new PeerPlace(s.id, this.#d.ask).origins(ws)) {
            for (const h of o.heads as Head[]) add(h, { key: `station:${s.id}`, item: { station: s.id, name: names.get(s.id) ?? "" } });
          }
        } catch {}
      }),
      ...this.#backup().s3.map(async (target) => {
        try {
          for (const o of await this.#s3Place(target).origins(ws)) {
            for (const h of o.heads) add(h, { key: `s3:${target.id}`, item: { s3: target.id, name: target.name } });
          }
        } catch {}
      }),
    ]);
    for (const m of this.#formerly.values()) for (const f of m.keys()) taken.add(f);
    for (const f of taken) found.delete(f);
    if (here !== null) {
      for (const o of await this.kept.origins(ws)) {
        for (const h of o.heads) add(h, { key: `station:${here}`, item: { station: here, name: names.get(here) ?? "" } });
      }
    }
    for (const f of taken) found.delete(f);
    for (const f of there) found.delete(f);
    return [...found.values()].map(({ head, from }) => ({
      station: head.origin, name: head.name || names.get(head.origin) || "", gen: head.gen, made: head.made, to: head.to,
      chats: head.chats, messages: head.messages, bytes: head.bytes, from: from.map((f) => f.item),
    }));
  }

  /// The stations this one took the place of.
  formerly(): string[] {
    return this.#was;
  }

  /// What came of the restore this station was started again for (null: none).
  restored(): Outcome | null {
    return this.#restored;
  }

  /// This station's copy of `ws` as it is now, brought to `peer` (a station this one's chats go to as it is retired,
  /// retire.ts): its generation.
  async bringTo(ws: string, peer: string): Promise<string> {
    await this.settleExport();
    const head = this.#passed?.heads[ws];
    if (head === undefined) throw new Error("no copy of this workspace's chats");
    const done = await level(new PeerPlace(peer, this.#d.ask), ws, this.#own(head));
    if (done.behind) throw new Error("that station keeps more of this station's chats than it has");
    return head.gen;
  }

  /// A retired station's copy (`gen`), brought here before (retire.ts), put in beside this station's own chats as it
  /// starts again: `connects`, how the ids of that station's connects go here; `ws`, its sessions' `ws` here.
  takeOver(ws: string, origin: string, gen: string, extra: { connects: Record<string, string>; ws: string | null }): Promise<void> {
    return this.restore(ws, origin, gen, { station: this.#d.here() ?? "" }, { merge: true, connects: extra.connects, ws: extra.ws });
  }

  /// Brings `origin`'s copy (`gen`) here from `from` (a station or an S3 target that keeps it), then has the station
  /// start again to put it in before its store opens. Only into a station with no chat of its own, unless `merge` (takeOver).
  restore(ws: string, origin: string, gen: string, from: RestoreFrom, merge: Merge | null = null): Promise<void> {
    if (!STATION.test(origin) || !GEN.test(gen) || !WORKSPACE.test(ws)) throw new Error("not a copy's name");
    if (merge === null && this.#passed?.empty !== true) throw new NotEmpty();
    if (this.#restoring !== null && this.#restoring.error === null) throw new Error("a restore is under way");
    const fromLabel = "s3" in from ? `s3:${from.s3}` : from.station;
    const r: Restoring = { origin, name: "", workspace: ws, gen, from: fromLabel, done: 0, total: 0, error: null, reason: null, restart: false };
    this.#restoring = r;
    this.#changed(0);
    return this.#bring(r, from, merge).catch((e) => {
      r.error = (e as Error).message;
      r.reason = e instanceof NotEmpty ? "notEmpty" : e instanceof Gone ? "gone" : "s3" in from ? (e instanceof S3HttpError ? "error" : "offline") : this.#reason(from.station, e);
      log.warn("copies", "a copy not brought", { origin, from: r.from, error: r.error });
      this.#record(ws, {
        at: this.#d.fibers.now(),
        kind: "restore",
        targetKind: "s3" in from ? "s3" : "station",
        target: "s3" in from ? from.s3 : from.station,
        targetName: "s3" in from ? this.#s3TargetName(from.s3) : this.#peerName(ws, from.station),
        status: "error",
        chats: 0,
        messages: 0,
        batches: 0,
        bytes: 0,
        reason: r.reason,
        error: r.error,
      });
      this.#changed(0);
      throw e;
    });
  }

  async #bring(r: Restoring, from: RestoreFrom, merge: Merge | null): Promise<void> {
    const { workspace: ws, origin, gen } = r;
    // (each batch and file written to disk as it comes, a piece at a time)
    let stream: (gen: string | null, name: string) => Promise<AsyncIterable<Buffer>>;
    let held: Held;
    if ("s3" in from) {
      const target = this.#backup().s3.find((t) => t.id === from.s3);
      if (target === undefined) throw new Gone(`S3 target ${from.s3} is not configured`);
      const place = this.#s3Place(target);
      held = await place.held(ws, origin);
      stream = (g, name) => place.read(ws, origin, g, name);
    } else if (from.station === this.#d.here()) {
      const place = this.kept;
      held = await place.held(ws, origin);
      stream = async (g, name) => place.stream(ws, origin, g, name);
    } else {
      const place = new PeerPlace(from.station, this.#d.ask);
      held = await place.held(ws, origin);
      stream = (g, name) => place.read(ws, origin, g, name);
    }
    const save = async (path: string, g: string | null, name: string) => {
      const f = await open(`${path}.part`, "w");
      try {
        for await (const piece of await stream(g, name)) await f.write(piece);
        await f.sync();
      } finally {
        await f.close();
      }
      await rename(`${path}.part`, path);
    };
    const holding = held.gens.find((g) => g.gen === gen);
    if (holding?.head == null) throw new Gone("that copy is not kept there");
    const head = holding.head;
    const heldFiles = new Set(held.files);
    const dir = copyDir(this.#d.data);
    await rm(dir, { recursive: true, force: true });
    await mkdir(join(dir, gen, "log"), { recursive: true });
    await mkdir(join(dir, "files"), { recursive: true });
    // If head carries `transcriptManifest`, download and strictly verify root + all bucket leaves first
    // (corrupt/missing manifest aborts restore; prefer manifest over inline `transcriptFiles` for download).
    let transcriptMap: Record<string, number> | undefined;
    if (head.transcriptManifest !== undefined) {
      const manifestBlobs = new Map<string, Buffer>();
      const readManifestBlob = async (hash: string, maxBytes: number): Promise<Buffer | null> => {
        let s: AsyncIterable<Buffer>;
        try {
          s = await stream(null, hash);
        } catch (e) {
          const missing =
            isEnoent(e) ||
            (e instanceof S3HttpError && e.status === 404) ||
            (e instanceof Refused && /not kept here/i.test(e.message));
          if (missing) return null;
          throw e;
        }
        const buf = await readStreamBounded(s, maxBytes);
        manifestBlobs.set(hash, buf);
        return buf;
      };
      const resolved = await loadTranscriptManifest(head.transcriptManifest, readManifestBlob);
      transcriptMap = resolved.files;
      for (const [hash, buf] of manifestBlobs) {
        const target = join(dir, "files", hash);
        const f = await open(`${target}.part`, "w");
        try {
          await f.write(buf);
          await f.sync();
        } finally {
          await f.close();
        }
        await rename(`${target}.part`, target);
      }
    } else {
      transcriptMap = head.transcriptFiles;
    }
    const chatWanted = new Set(Object.keys(head.files));
    const transcriptWanted: string[] = [];
    for (const h of Object.keys(transcriptMap ?? {})) {
      if (!chatWanted.has(h) && heldFiles.has(h)) transcriptWanted.push(h);
    }
    r.name = head.name;
    r.total = head.batches.length + chatWanted.size + transcriptWanted.length;
    this.#changed(0);
    for (const b of head.batches) {
      await save(join(dir, gen, "log", b), gen, b);
      r.done++;
      this.#changed(TELL_RESTORE_MS);
    }
    for (const hash of chatWanted) {
      await save(join(dir, "files", hash), null, hash);
      r.done++;
      this.#changed(TELL_RESTORE_MS);
    }
    // Chat-first fault tolerance: a missing individual transcript chunk does not block chat DB/attachments restore;
    // takeBack records it in `missing`.
    for (const hash of transcriptWanted) {
      try {
        await save(join(dir, "files", hash), null, hash);
      } catch (e) {
        const missingChunk =
          isEnoent(e) ||
          (e instanceof S3HttpError && e.status === 404) ||
          (e instanceof Refused && /not kept here/i.test(e.message));
        if (!missingChunk) throw e;
      }
      r.done++;
      this.#changed(TELL_RESTORE_MS);
    }
    await writeFile(join(dir, gen, "head.json"), JSON.stringify(head, null, 1));
    // (still no chat of its own, as it is about to be put in: one made meanwhile, and it is not)
    await this.settleExport();
    if (merge === null && this.#passed?.empty !== true) throw new NotEmpty();
    const ready: Ready = { origin, workspace: ws, gen, name: head.name, from: r.from, ...(merge ?? {}) };
    await writeFile(readyFile(this.#d.data), JSON.stringify(ready));
    const go = await this.#d.restart();
    r.restart = go === null;
    this.#changed(0);
    if (go !== null) await go();
  }
}

export type { Place };
