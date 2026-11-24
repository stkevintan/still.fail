// Routes chat messages to session actors and creates sessions. Several connects share one hub;
// each has its own chat connection and its own sessions.
//
// A connect's mode decides the sessions: multi-session gives each thread its own session (started by an @mention);
// single-session sends every thread the connect sees into the one session bound to it, which people can switch or
// replace. Either way every message carries its source and the agent names the thread it answers, so a session never
// assumes it belongs to one conversation; replies go out through whichever connect the thread came in on.
//
// Everything said in a thread is recorded once (the store): people's messages are delivered to every session in the
// thread, and what agents and the station post there is recorded after the platform takes it.
//
// The Rust hub is one 2500-line type; here it is this core (actors, routing, holds, handover, eviction) and modules
// beside it, each a group of what the hub does: accounts.ts (which profile), conversations.ts (what agents post and
// read in their chats), others.ts (other chats), messages.ts (session_send), titles.ts, lifecycle.ts (sessions and
// chats made, archived, deleted), review.ts (the archive suggestion). The tools (src/tools/) are built on it.
//
// Redesigned where asks: no settle-by-polling and no handing over of processes: at a handover the
// hub holds turns, waits until every actor's queue has run what it had (`flushed`, pushed, not polled), and snapshots
// every actor into <data>/run/handover.json; the runners keep the processes. A starting hub takes them up from that
// file (`takeUp`), and from the runners a crashed station left (no snapshot), then `recover` resumes the turns marked
// running that nothing took up.
import { randomBytes } from "node:crypto";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { homedir } from "node:os";
import { Clock, Effect, Fiber } from "effect";
import { liveClock, wall, within } from "../ops/fibers.ts";
import { recordTracePayload, type Traces } from "../mesh/traces.ts";
import { RUNTIME_KINDS, type AgentDriver, type AgentSession, type RuntimeKind } from "../agents/runtime.ts";
import { billedPerUse } from "../agents/profiles.ts";
import { endRunner, runnerId } from "../agents/process.ts";
import { RUNNER_LEFT_MS, allLeft, isTerminalRunner, liveRunners, type RunnerInfo } from "../agents/runner.ts";
import { log } from "../ops/log.ts";
import { type UpkeepState, readUpkeepState as defaultReadUpkeepState } from "../ops/upkeep-state.ts";
import { tr, stationLang } from "../ops/i18n.ts";
import { iso, sessionPlaces } from "../read/transcript.ts";
import type { ReaderSelectConfig } from "../read/reader-select.ts";
import * as titles from "../../../client/core-ts/src/titles.ts";
import { transcriptSourcesSoon } from "../read/transcript-soon.ts";
import { type ArchivedWorkspace, type Attachment, MANUAL, type SessionRow, type Store, STILLFAIL_SURFACE, feishuSurface, commaSurface, groupSurface, slackSurface, type MessageRow, type ThreadRow, type ThreadSummary } from "../store/store.ts";
import type { DeliveryCardState, InWorkspace, PendingMessage } from "../store/rows.ts";
import { comingWs, handedWs, sees } from "../store/rows.ts";
import { isNotice, markNotice } from "./chat.ts";
import { runShown } from "./run-change.ts";
import type { PolicyChecks } from "./archive-policy.ts";
import type { ChatListFilter, RecentChatList } from "../store/chat-list.ts";
import { Accounts } from "./accounts.ts";
import { type Actor, type SessionDeps, type Snapshot, linkSkills, openOptions } from "./actor.ts";
import { ActorsProgram } from "./mb-actor.ts";
import { Places } from "../ops/places.ts";
import { threadCommand, type Args } from "./args.ts";
import type { CardPage } from "../logins/index.ts";
import type { ChatEvent, ChatSurface, InboundFile, InboundMessage, ModelChoice, Person, ThreadRef } from "./chat.ts";
import { toolStatus } from "./chat.ts";
import { type Connect, type HubConfig, type Profile, allowedIn, profilesFor, runtimeNamed, runtimeTitle, sameModel } from "./config.ts";
import { FEW_MOST, USED_WITHIN_MS, candidates as modelsRun, few } from "./model-choice.ts";
import { CHAT_KEY, INTERNAL_CONNECT, type InternalChat, nextTsAt } from "./internal.ts";
import { LiveHub } from "./live.ts";
import type { Jobs } from "./neighbours.ts";
import { agentHomePaths, workspaceAgentHome, workspaceAgentHomePath } from "./agent-home.ts";
import { Presets, RepoIndex } from "./presets.ts";
import { BoardDrafts } from "./board-drafts.ts";
import { Clones } from "./clones.ts";
import { type Roots, roots as machineRoots } from "../read/machine.ts";
import { carrySubagents, goesAfresh, startsAfresh, toldCleared, toldLongChat, toldResumeLost } from "./afresh.ts";
import { serves } from "./pool.ts";
import { archive } from "./lifecycle.ts";
import { settled } from "./opened.ts";
import { untitledChat } from "./titles.ts";
import { shownFactsSoon } from "./image-size.ts";
import { sandboxIndexEnabled } from "../store/sandbox-index.ts";
import { SandboxNameBuilder } from "./sandbox-name-builder.ts";
import { SessionDirectoryBuilder } from "./session-directory-builder.ts";
import { ProcessJobsBuilder } from "../jobs/process-jobs-builder.ts";

type Json = any;

/// A multi-session connect's session for one thread.
export const sessionKey = (connect: string, channel: string, threadTs: string) => `${connect}:${channel}:${threadTs}`;

/// A new session for a single-session connect.
export const newSingleSessionKey = (connect: string) => `${connect}:s-${randomBytes(4).toString("hex")}`;

/// A new session talked to in the station's chat.
export const newChatKey = () => `${CHAT_KEY}:c-${randomBytes(5).toString("hex")}`;

/// The bearer token a session presents to the MCP endpoint.
export const newToken = () => randomBytes(24).toString("base64url");

/// Why turns are held. Each is taken back on its own: a station drained for a restart while in no workspace takes no
/// turns once the drain ends either.
/// - drain: a restart or handover is coming.
/// - unbound: the station is in no workspace (never joined one, or removed from it): it does no work until it is.
/// - starting: the agents' door (their MCP endpoint) is not open yet: a runtime started now has no station tools.
export type Hold = "drain" | "unbound" | "starting";

/// A chat of another workspace shared with this one, as chat_list lists it (xshare/index.ts `Borrowed`).
export type OutsideChat = { workspace: string; workspaceName: string; station: string; chat: string; title: string; link: string; write: boolean };

/// Cold storage of archived sessions' files (archive.rs): an archived, idle session's workspace and
/// transcripts packed, and restored before its runtime starts again or when it is shown again. The station's is
/// cold.ts; the default keeps nothing cold.
export interface ColdStorage {
  isCold(key: string): Promise<boolean>;
  restore(key: string, opts?: { onlyIfUnarchived?: boolean }): void | Promise<void>;
  /// Cancels any in-flight `workspace.pack` for this session.
  cancelPack?(key: string): void;
  /// Packs what it can of an archived, idle session.
  pack(key: string): void | Promise<void>;
  /// Whether an archived session's directory holds more than its chat's files, and empties it of that.
  holdsMore?(key: string): Promise<boolean>;
  expire?(key: string, before: number): Promise<void>;
  /// Whether an archived session still lacks its `cold` mark and is eligible to be packed now.
  needsPack?(key: string): Promise<boolean>;
  /// Removes rebuildable build/install directories from an idle unarchived session without packing or marking cold.
  /// Returns removed bytes (>= 0) when measured, or null when skipped before measuring (not cleanable / shared / job).
  cleanIdleRebuildable?(key: string): Promise<number | null>;
}

/// The most of a shared file the station fetches, as much as an agent may attach.
const MAX_INBOUND_FILE = 50 * 1024 * 1024;
/// How long transcripts' lengths are gathered before they are written (`noteLength`).
export const LENGTHS_GATHER_MS = 5_000;

const NOTHING_COLD: ColdStorage = { isCold: async () => false, restore: () => {}, pack: () => {} };

/// What the hub hands to the next station: each actor's snapshot (handover.json).
export type Handover = { sessions: Snapshot[] };

export type BilledFallback = { session: string; workspace: string | null; runtime: RuntimeKind; profile: Profile };

export type HubOptions = {
  /// Read on every use, so edits apply to the next decision.
  config: () => HubConfig;
  readers?: () => ReaderSelectConfig;
  store: Store;
  /// The connected connects by id; configured connects without one are offline.
  chats: (connect: string) => ChatSurface | undefined;
  drivers: AgentDriver[];
  /// The agents' MCP endpoint (a function when it is known only once its server listens).
  mcpUrl: string | (() => string);
  /// How many requests a session's token made of that endpoint (mcp.ts `heard`); absent where unknown.
  toolsHeard?: (session: string) => number;
  /// The station's own chat on its pages; sessions can be talked to there too.
  internal?: InternalChat | null;
  /// How the directories and files people and agents name are looked at (ops/places.ts: never on this thread in a
  /// folder macOS protects); default: without still.fail Helper.
  places?: Places;
  /// A session's page in still.fail (its /o/ link), when the station is in a workspace.
  link?: (key: string) => string | undefined;
  /// The workspaces the station is in now, its home one first; none outside any.
  workspaces?: () => string[];
  /// This station's id in its workspaces (null: none yet, outside any).
  station?: () => string | null;
  /// The name this station knows another station of its workspaces by (its mark's, else its roster's); null: none.
  stationName?: (id: string) => string | null;
  /// The runners alive on this machine now, by id (default: <data>/run/runners).
  runners?: () => string[];
  /// How a runner of an agent's that nobody holds is ended (`takeUp`, `endOrphan`; default: process.ts `endRunner`, that
  /// runner alone).
  endRunner?: (info: RunnerInfo) => Promise<unknown>;
  /// Another session being taken up: the launcher hears the station gets on with it (ops/launcher.ts `taking`).
  taking?: () => void;
  cold?: ColdStorage;
  /// Its time, and its sessions' (a TestClock in tests).
  clock?: Clock.Clock;
  /// Where the machine's own Claude Code and Codex keep their sessions (default: read/machine.ts `roots`).
  machineRoots?: () => Roots;
  /// Detached cleanup begun by the hub, for an owner of its environment to await before removing that environment.
  background?: (work: Promise<void>) => void;
  /// The previous station has released its foreground writes.
  previous?: Promise<void>;
  /// What the deployment adds to every session's instructions, as the station read it at its start
  /// (agents/instructions.ts `readSiteInstructions`); none by default.
  siteInstructions?: string;
  /// Whether moving to another station is on here (every station's; a test's may say not); on where none is said.
  moveOn?: () => boolean;
  /// Reader for `<data>/upkeep-state.json` (default: `ops/upkeep-state.ts` `readUpkeepState`).
  readUpkeepState?: (dataDir: string) => Promise<UpkeepState>;
  /// Called when a session automatically falls back to a pay-as-you-go profile while subscriptions exist.
  onBilledFallback?: (info: BilledFallback) => void;
  /// Active OTLP traces batcher for internal spans (`agent.open`, `turn.run`).
  traces?: () => Traces | null;
};

/// The handover file, in the data directory.
export const handoverFile = (dataDir: string) => join(dataDir, "run", "handover.json");

/// A message refused, unrecorded, by a station handing its chats of that workspace to another (Hub `quiet`).
export class Retiring extends Error {
  constructor() {
    super("this station is handing its chats of this workspace to another station");
  }
}

/// What a station retired from `ws` says its chats there are of once the station they went to took them: no workspace
/// it is in, so they are out of every device's sight here (replica/retire.ts).
export const retiredWs = (ws: string) => `retired:${ws}`;
export { comingWs, handedWs } from "../store/rows.ts";

export class Hub {
  readonly options: HubOptions;
  readonly store: Store;
  readonly internal: InternalChat | null;
  readonly drivers: Map<string, AgentDriver>;
  readonly link: (key: string) => string | undefined;
  readonly workspaces: () => string[];
  readonly station: () => string | null;
  readonly cold: ColdStorage;
  readonly readUpkeepState: (dataDir: string) => Promise<UpkeepState>;
  readonly accounts: Accounts;
  /// The last profile access scopes seen by `profilesChanged`, kept apart from config.json's mutable objects.
  private profileScopes: Profile[] | null = null;
  readonly clock: Clock.Clock;
  readonly places: Places;
  readonly machineRoots: () => Roots;
  /// Told when a session's runtime was not found on PATH as it started (the pages read it again).
  private runtimeMissing: (runtime: RuntimeKind) => void = () => {};
  /// What running turns are doing, for the pages' live view.
  readonly live: LiveHub;
  /// Every thread as lists have it, read by the readers (agents.ts sets it): chat_list's, not read on the main thread
  /// (some 15 queries a thread, 1,200 threads on a station: 10 seconds held while memory was short). Unset (tests): the store.
  threadList: (() => Promise<ThreadSummary[]>) | null = null;
  /// A recent, unfiltered chat_list, with details for its page alone.
  recentChatList: ((ws: string | null, home: string | null, limit: number, signal?: AbortSignal) => Promise<RecentChatList>) | null = null;
  /// The matching chats and count for a chat_list search.
  searchChatList: ((ws: string | null, home: string | null, limit: number, query: string, filter?: ChatListFilter) => Promise<RecentChatList>) | null = null;
  /// A thread's latest `limit` messages, oldest first, read by the readers (agents.ts sets it): the archive review's
  /// (review.ts), up to 400 of them through the merged view, 3 seconds held on a station. Unset (tests): the store.
  latestMessages: ((thread: number, limit: number) => Promise<MessageRow[]>) | null = null;
  /// How a session's skills are linked where it runs before its process opens; none: on the disk (actor.ts
  /// `linkSkills`). A test's hub, whose sessions run nowhere, links none.
  skillsLinker: ((row: SessionRow) => Promise<string>) | null = null;
  /// What a week's checks say of a workspace's chats, counted by the readers (null: on the main thread, as the store is
  /// still preparing their lookups); none (tests): counted here.
  policyChecks: ((since: number, viewer: InWorkspace) => Promise<PolicyChecks | null>) | null = null;
  /// Check whether a chat's opener wrote among its latest messages without reading their edits.
  openedChatSaid: ((thread: number, author: string, agentOnly: boolean) => Promise<boolean>) | null = null;
  /// Read a chat_history page and its optional before-message boundary off the station thread.
  historyMessages: ((thread: number, before: string | null, limit: number) => Promise<MessageRow[] | null>) | null = null;
  /// Read a chat history's pending card post off the station thread.
  historyPendingCard: ((thread: number) => Promise<number | null>) | null = null;
  prepareCardPosts: ((threads: readonly number[], signal?: AbortSignal) => Promise<void>) | null = null;
  /// Check a named need against its visible question off the station thread.
  stateQuestion: ((key: string, threads: number[], ts: string) => Promise<import("../read/store.ts").StateQuestion>) | null = null;
  /// The pending card used by a need which does not name its question.
  statePendingCard: ((threads: number[]) => Promise<[number, number, string] | null>) | null = null;
  /// Card state accompanying a person's message to an agent.
  deliveryCardState: ((thread: number, n: number, signal?: AbortSignal) => Promise<DeliveryCardState | null>) | null = null;
  /// A session's undelivered messages and letters, merged by a reader.
  pendingDeliveries: ((key: string, signal?: AbortSignal) => Promise<PendingMessage[]>) | null = null;
  /// Read the pending post and its card for the background archive review.
  reviewPendingCard: ((thread: number) => Promise<[MessageRow, Json] | null>) | null = null;
  /// Prepare an old session's up-job lookup before its archived actor stops its jobs.
  prepareSessionUpJobs: ((session: string) => Promise<void>) | null = null;
  /// The station's logins (logins/module.ts sets it): the page a Slack login card opens for one (null: no card there,
  /// as for a loopback login), and the code from that page handed to it, entered by `by` on its card. Unset: no logins
  /// here. `deadline`: when one under way runs out of time (its ask's push says so).
  logins: { page(id: string): CardPage | null; answer(id: string, code: string, by?: Person): void; deadline?(id: string): number | null } | null = null;
  /// Stops following the store's sessions starting and stopping (live.ts `running`).
  private unlistenRunning: () => void = () => {};
  readonly actors = new Map<string, Actor>();
  /// The MoonBit program its actors run in (mb-actor.ts), where it is built: opened with the first.
  private actorsProgram: ActorsProgram | null | undefined;
  /// Latest concurrency limit set on this hub (null: read from config() when actorsProgram opens).
  private maxConcurrentTurnsOverride: number | null = null;
  /// Installed by the agents' side: older stores finish indexing active keys without holding the station thread.
  waitForWorkspaceActivity: (() => Promise<boolean>) | null = null;
  /// An older store's session totals are built in bounded batches after handover.
  waitForSessionCounts: (() => Promise<boolean>) | null = null;
  /// An old thread's requested message suffix is indexed off the station thread before delivery.
  preparePostsAfter: ((messages: readonly { thread: number; n: number }[], signal?: AbortSignal) => Promise<void>) | null = null;
  /// The message files needed to identify an old widget's source.
  prepareWidgetSources: ((threads: readonly number[], signal?: AbortSignal) => Promise<void>) | null = null;
  /// Prepare an old store's merged-message lookup before accepting a platform edit.
  prepareLegacyEdits: ((signal?: AbortSignal) => Promise<void>) | null = null;
  /// The sessions whose old copy destinations are needed before posting a copy.
  prepareCcSessions: ((sessions: readonly string[], signal?: AbortSignal) => Promise<void>) | null = null;
  /// The sessions whose old conversation order is needed to name them.
  prepareSessionChatNames: ((sessions: readonly string[], signal?: AbortSignal) => Promise<void>) | null = null;
  /// The sessions whose latest conversation must be ready before an asynchronous operation can continue.
  prepareLatestThreads: ((sessions: readonly string[], signal?: AbortSignal) => Promise<void>) | null = null;
  /// Cross-round cursor for `packUnfinishedArchived` (`lifecycle.ts`).
  packBackfillCursor: ArchivedWorkspace | null = null;
  /// When this Hub instance started (by its clock), used for the short startup grace before periodic archive upkeep.
  readonly startedAt: number;
  /// Last time periodic archive backfill & idle rebuildable cleanup ran (`lifecycle.ts` `runArchiveUpkeepIfDue`),
  /// loaded lazily from `<data>/upkeep-state.json`.
  lastArchiveUpkeepAt: number | null = null;
  /// Bounded `sessionKey -> lastActiveAt` memo for idle rebuildable cleanup (`lifecycle.ts`), persisted in
  /// `<data>/upkeep-state.json` and cleared on archive/delete.
  readonly idleMeasured = new Map<string, number>();
  /// Single-flight loader promise for `<data>/upkeep-state.json` into this Hub instance.
  upkeepStateLoad: Promise<void> | null = null;
  /// Whether `idleMeasured` has unpersisted mutations since the last write to `<data>/upkeep-state.json`.
  idleMeasuredDirty = false;
  /// Last time a full low-disk reclamation pass completed (`lifecycle.ts` `relieveLowDiskFull`), persisted in
  /// `<data>/upkeep-state.json`.
  lastFullRelieveAt: number | null = null;

  /// Drops a session's cached idle-rebuildable measurement (called on archive or delete).
  forgetIdleMeasured(key: string): void {
    if (this.idleMeasured.delete(key)) this.idleMeasuredDirty = true;
  }
  private awaitingWorkspaceActivity = new Set<string>();
  private sandboxNames: SandboxNameBuilder | null = null;
  private sessionDirectories: SessionDirectoryBuilder | null = null;
  private processJobs: ProcessJobsBuilder | null = null;
  /// When each idle process is next looked at for eviction.
  private deadlines = new Map<string, Fiber.Fiber<void>>();
  /// Fibers of the hub's own (archive reviews): interrupted at shutdown.
  readonly fibers = new Set<Fiber.Fiber<void>>();
  /// Why turns are held (SessionDeps.held): held while any reason stands.
  private holdsNow = new Set<Hold>();
  /// Sessions taken up from the previous station: their turns run on, not cut off.
  private adopted = new Set<string>();
  /// Whether `takeUp` found no handover.json (crash / OOM / machine reboot, not an update handover).
  private nonUpdateRestart = false;
  /// Sessions whose turns were cut off by a non-update restart and still await manual resume or dismissal.
  private readonly interruptedByRestart = new Set<string>();
  private interruptedHook: (() => void) | null = null;
  /// Whether its drivers hold every agent's process of this station's that goes on (`ownsRunner`): from the end of
  /// `takeUp` to a handover or the end.
  private holdsRunners = false;
  /// The runners `takeUp` found that nobody took up, being ended (tests wait for it).
  orphansEnded: Promise<void> = Promise.resolve();
  /// Chats made lately by session key: the key their client gave them, and when (NewChat.clientKey).
  readonly clientKeysMade = new Map<string, [string, number]>();
  /// Conversations a chat was relayed to whose agent has not posted there yet, by thread: the session and the station's
  /// first message there, which that post goes into (relay.ts). Kept in memory: after a restart it is a reply.
  readonly openings = new Map<number, { session: string; ts: string; claimed?: boolean }>();
  /// Posts chat_post held back because messages the agent had not read came in their thread first (conversations.ts),
  /// by session and then by id, until it sends them with send or the station restarts.
  readonly heldPosts = new Map<string, Map<string, Args>>();
  heldCount = 0;
  /// One incoming message or edit at a time per thread: Slack also sends a mention twice (app_mention and message).
  readonly gates = new Map<string, { tail: Promise<{ error: unknown } | null>; waiting: number }>();
  private readonly incoming = new AbortController();
  /// Work waiting to start an external write must stop when this hub is handed over or shut down.
  get stoppingSignal(): AbortSignal { return this.incoming.signal; }
  /// The station's background jobs (made after the hub, which tells their agents).
  jobs: Jobs | null = null;
  /// Each workspace's presets, in its agent home (presets.ts).
  readonly presets = new Presets((ws) => workspaceAgentHomePath(this.config().agentHome, ws, this.workspaces()[0] ?? null), () => this.now(), {
    station: () => this.station(),
    workspace: (ws) => ws ?? this.workspaces()[0] ?? null,
    stationName: (id) => this.options.stationName?.(id) ?? null,
  });
  /// Each person's drafts of 待派发 and the files of those to run here (board-drafts.ts).
  readonly boardDrafts = new BoardDrafts({
    store: () => this.store,
    dir: () => join(this.config().dataDir, "board-files"),
    uploads: () => join(this.config().dataDir, "uploads"),
    now: () => wall.now(),
  });
  /// The repositories on the machine, offered as a preset's folders (presets.ts).
  readonly repoIndex = new RepoIndex({ roots: () => [homedir()], file: () => join(this.config().dataDir, "repo-index.json"), now: () => this.now(), besides: () => [this.config().dataDir] });
  /// Repositories cloned from git into the repository cache, for presets to name (clones.ts).
  readonly clones = new Clones({ reposDir: () => this.reposDir(), now: () => this.now(), index: this.repoIndex });
  private closedHook: ((key: string) => void) | null = null;
  private peersHook: ((station: string, request: Json) => Promise<Json>) | null = null;
  private outsideHook: ((ws: string | null) => OutsideChat[]) | null = null;
  onBilledFallback: ((info: BilledFallback) => void) | null = null;
  readonly deps: SessionDeps;

  constructor(options: HubOptions) {
    this.options = options;
    this.onBilledFallback = options.onBilledFallback ?? null;
    this.clock = options.clock ?? liveClock;
    this.startedAt = this.now();
    this.store = options.store;
    this.internal = options.internal ?? null;
    this.drivers = new Map(options.drivers.map((d) => [d.runtime(), d]));
    this.link = options.link ?? (() => undefined);
    this.workspaces = options.workspaces ?? (() => []);
    this.station = options.station ?? (() => null);
    this.cold = options.cold ?? NOTHING_COLD;
    this.readUpkeepState = options.readUpkeepState ?? defaultReadUpkeepState;
    this.machineRoots = options.machineRoots ?? machineRoots;
    this.places = options.places ?? new Places();
    this.accounts = new Accounts({
      config: () => this.config(),
      store: this.store,
      running: (except) => [...this.actors.values()].filter((a) => a.key !== except && a.processState() !== "cold").flatMap((a) => this.store.getSession(a.key)?.profile ?? []),
      active: (except) => [...this.actors.values()].filter((a) => a.key !== except && a.processState() === "running").flatMap((a) => this.store.getSession(a.key)?.profile ?? []),
      clock: this.clock,
      allows: (key, profile) => allowedIn(profile, this.wsOf(key), this.workspaces()[0] ?? null),
      // Moved to another account by the station (its allowance ran out, its login is over, its profile deleted): said in
      // its chat as a change by hand is (lifecycle.ts `configure`).
      moved: (key, was) => {
        const now = this.store.getSession(key);
        // (one handed to another station as this one was retired says nothing here: it goes on there)
        if (!now || this.handedOver(key)) return;
        const named = (id: string) => {
          const name = this.accounts.profile(id)?.name;
          return typeof name === "string" ? name : null;
        };
        void this.actor(now).runChanged({ was: runShown(was, named), now: runShown(now, named) }).catch(() => {});
      },
      billedFallback: (info) => this.noteBilledFallback(info),
    });
    this.live = new LiveHub(
      async (key) => {
        const row = this.store.getSession(key);
        const runtime = row && runtimeNamed(row.runtime);
        if (!row || !runtime || this.store.runtimeSessionSources(key).length === 0) return null;
        const { dataDir, profiles } = this.config();
        // In its places alone, as the live view asks it (read/transcript.ts `anywhere`).
        const { paths, current } = await transcriptSourcesSoon(dataDir, profiles, this.store.runtimeSessionSources(key), sessionPlaces(row), { anywhere: false });
        return paths.length === 0 ? null : { runtime, paths, current };
      },
      this.clock,
      () => this.program(),
    );
    // The sessions at work are followed by the station itself (live.ts `running`): as the store says each starts and
    // stops, and those at work now. Each transcript's length goes where its summary reads it (its usage, the usage
    // part keeps: usage/module.ts), gathered (`noteLength`).
    this.live.lengths = (key, n) => this.noteLength(key, n);
    this.unlistenRunning = this.store.subscribe((change) => {
      // Its summary is told now: with its transcript's length as read.
      if (change.type === "session" && this.lengths.has(change.key)) this.writeLengths([change.key]);
      if (change.type === "session") {
        const row = this.store.getSession(change.key);
        this.live.running(change.key, row?.running === true);
        if (this.interruptedByRestart.has(change.key) && (row === null || row.running || row.archivedAt !== null)) {
          this.interruptedByRestart.delete(change.key);
          this.interruptedHook?.();
        }
      } else if (change.type === "sessionRemoved") {
        this.live.running(change.key, false);
        if (this.interruptedByRestart.delete(change.key)) this.interruptedHook?.();
      }
    });
    this.deps = this.sessionDeps();
  }

  /// The sessions at work as the station starts are followed (live.ts `running`): once where their history is read
  /// is set (agents.ts), so none is read on the main thread.
  followRunning() {
    for (const row of this.store.runningSessions()) this.live.running(row.key, true);
  }

  config(): HubConfig {
    return this.options.config();
  }

  /// Now, by its clock.
  now(): number {
    return this.clock.currentTimeMillisUnsafe();
  }

  /// A Slack-style ts for something said now.
  nextTs(): string {
    return nextTsAt(this.now());
  }

  reposDir(): string {
    return join(this.config().dataDir, "repos");
  }

  // ── holds ──────────────────────────────────────────────────────────────────────────────────────────────────────

  /// Holds turns for `reason`: none starts from now on, and messages stay pending. Those running go on.
  hold(reason: Hold) {
    this.holdsNow.add(reason);
  }

  /// Takes back `reason` to hold turns; once none is left, turns start again and what waited meanwhile goes on.
  release(reason: Hold) {
    if (!this.holdsNow.delete(reason) || this.holdsNow.size > 0) return;
    // (an actor released goes on with what waits for it itself, a recovery it put off or its messages: kicked as well,
    // it would start a turn on them again after one that failed to start, 2026-11-19)
    const released = new Set(this.actors.keys());
    for (const actor of this.actors.values()) void actor.release();
    for (const key of this.store.sessionsWithPending()) {
      if (released.has(key)) continue;
      const row = this.store.getSession(key);
      if (row) void this.actor(row).kick();
    }
  }

  /// Whether turns are held for `reason`.
  holds(reason: Hold): boolean {
    return this.holdsNow.has(reason);
  }

  /// The station left its workspace (turns are held first): every runtime process ends, running or idle, then what the
  /// drivers run themselves (codex's app-servers), so no agent goes on outside the workspace. Turns cut off stay marked
  /// running and messages given to them pending again (mb-actor.ts `suspend`): `recover` resumes them once the station
  /// is back in its workspace.
  async suspendAll() {
    for (const fiber of this.deadlines.values()) this.interrupt(fiber);
    this.deadlines.clear();
    // Taken up from the previous station or not, what was cut off now resumes the usual way.
    this.adopted.clear();
    await Promise.all([...this.actors.values()].map((a) => a.suspend()));
    await Promise.all([...this.drivers.values()].map((d) => d.shutdown(true)));
  }

  /// Whether a session's workspace is one the station is in now (a joined one may have taken it out): held otherwise.
  /// Outside every workspace the "unbound" hold says so instead. A workspace whose chats this station is handing to
  /// another (`quiet`) is one it is not in.
  private inAWorkspace(key: string): boolean {
    const all = this.workspaces();
    const ws = this.store.sessionWs(key) ?? null;
    if (this.quieted.has(ws ?? all[0] ?? "")) return false;
    if (all.length === 0) return true;
    return ws === null || all.includes(ws);
  }

  /// The workspaces whose chats this station hands to another as it is retired from them (replica/retire.ts).
  private readonly quieted = new Set<string>();

  /// Whether session `key` is one of `ws`'s chats here: its workspace, a home one's saying none (as `inAWorkspace`
  /// reads it), or one put out of sight as the station was retired from `ws` (`retiredWs`).
  ofWorkspace(key: string, ws: string): boolean {
    const was = this.store.sessionWs(key);
    if (was === undefined) return false;
    return (was ?? this.workspaces()[0] ?? null) === ws || was === retiredWs(ws);
  }

  /// This station's chats of `ws` go to another (replica/retire.ts): from now on none of them takes a turn, those
  /// running end as the station's leaving a workspace ends them (their deadlines with them), and what their platforms
  /// say is not taken here (`acceptInTurn` refuses it, unrecorded; connects/workspace.ts keeps it for that station).
  async quiet(ws: string) {
    this.quieted.add(ws);
    const keys = new Set([...this.deadlines.keys(), ...this.actors.keys()].filter((key) => this.ofWorkspace(key, ws)));
    for (const [key, fiber] of this.deadlines) if (keys.has(key)) (this.interrupt(fiber), this.deadlines.delete(key));
    await Promise.all([...this.actors.values()].filter((a) => keys.has(a.key)).map((a) => a.suspend("its workspace's chats go to another station")));
  }

  /// `quiet` taken back (the retirement cancelled): what it cut off resumes and what waited goes on, as `backIn` does.
  unquiet(ws: string) {
    if (!this.quieted.delete(ws)) return;
    // (the home one's chats say no workspace, which the index of a workspace's activity does not name)
    if (ws !== (this.workspaces()[0] ?? null)) return this.backIn(ws);
    const keys = new Set([...this.store.runningSessions().map((row) => row.key), ...this.store.sessionsWithPending()]);
    const rows = [...keys].filter((key) => this.ofWorkspace(key, ws)).map((key) => this.store.getSession(key)).filter((row): row is SessionRow =>
      row !== null && (row.running || this.store.hasPending(row.key))).sort((a, b) => b.lastActiveAt - a.lastActiveAt);
    for (const row of rows) {
      if (!this.online(row)) continue;
      if (row.running) void this.actor(row).recover();
      else void this.actor(row).kick();
    }
  }

  /// Whether this station is handing `ws`'s chats to another.
  quietIn(ws: string): boolean {
    return this.quieted.has(ws);
  }

  /// Whether session `key` is one of the chats this station hands, or handed, to another: of a workspace quiet here, put
  /// out of sight (`retiredWs`, `handedWs`, one coming here and not shown yet, `comingWs`), or held one at a time
  /// (`holdChat`).
  handedOver(key: string): boolean {
    const ws = this.store.sessionWs(key);
    if (ws === undefined) return false;
    if (this.heldChats.has(key)) return true;
    if (ws !== null && (ws.startsWith(retiredWs("")) || ws.startsWith(handedWs("")) || ws.startsWith(comingWs("")))) return true;
    return this.quieted.has(ws ?? this.workspaces()[0] ?? "");
  }

  /// The chats held one at a time (replica/handover.ts: one being handed to another station; move/: one stopped as what
  /// it needs moved away), each with why: no turn starts, its process is ended as the station's leaving a workspace
  /// ends it (its turn cut off stays marked running, its messages pending), what is said to it is kept in its threads'
  /// logs, delivered where it ends up.
  private readonly heldChats = new Map<string, string>();

  /// What a chat stopped by a move says once, as a person next speaks in it (`stoppedNotice`): its words, made as it
  /// is said, and whether they were said in this stop. Nothing is said by the stop itself: a login moved away never posts
  /// into every chat that used it.
  private readonly stopNotices = new Map<string, { words: () => string; told: boolean }>();

  /// Holds session `key` (`why`: for the status), at once: none of its turns starts from now on. `notice`: what it
  /// answers, once in this hold, as a person speaks in it (a chat stopped by a move: what it waits for and where).
  async holdChat(key: string, why: string, notice?: () => string): Promise<void> {
    this.heldChats.set(key, why);
    // (a stop anew, or what it waits for now: said once in it)
    if (notice !== undefined) this.stopNotices.set(key, { words: notice, told: false });
    const fiber = this.deadlines.get(key);
    if (fiber) (this.interrupt(fiber), this.deadlines.delete(key));
    // (held for what it is: moving to another station, or stopped as what it needs moved away)
    await this.actors.get(key)?.suspend(`the chat is held: ${why}`);
  }

  /// `holdChat` taken back: what it cut off resumes and what waited goes on, as `unquiet` does. False: it was not held.
  releaseChat(key: string): boolean {
    this.stopNotices.delete(key);
    if (!this.heldChats.delete(key)) return false;
    this.wakeChat(key);
    return true;
  }

  /// A chat that may take turns now (let go, shown here): what was cut off resumes, what waited goes on.
  wakeChat(key: string): void {
    const row = this.store.getSession(key);
    if (row === null || this.heldChats.has(key) || this.holdsNow.size > 0 || !this.online(row) || !this.inAWorkspace(key)) return;
    if (row.running) void this.actor(row).recover();
    else if (this.store.hasPending(key)) void this.actor(row).kick();
  }

  /// Whether session `key` is in a turn now.
  busy(key: string): boolean {
    return this.actors.get(key)?.processState() === "running";
  }

  /// Once session `key`'s turn ended, as the store says it (at once where none runs).
  turnEnded(key: string): Promise<void> {
    if (!this.busy(key)) return Promise.resolve();
    return new Promise((resolve) => {
      const off = this.store.subscribe((change) => {
        if (change.type !== "session" || change.key !== key || this.busy(key)) return;
        off();
        resolve();
      });
    });
  }

  /// Why session `key` is held one at a time (null: it is not).
  chatHeld(key: string): string | null {
    return this.heldChats.get(key) ?? null;
  }

  /// What a connect's platform said in a thread, as far as it came, taken (`accept`'s turn of that thread waited for):
  /// a chat handed over sends the rest of its log after it.
  async drained(connectId: string, channel: string, threadTs: string): Promise<void> {
    await this.inThread(`${this.surface(connectId)}\0${channel}\0${threadTs}`, async () => {});
  }

  /// The station a chat of `connect`'s thread was handed to (store `handedTo`): what it says there goes there.
  movedTo(connect: string, channel: string, threadTs: string): string | null {
    const thread = this.store.threadAt(this.surface(connect), channel, threadTs);
    if (thread === null) return null;
    for (const m of this.store.threadSessions(thread.id)) {
      // (one being handed back here takes what comes here: it is to go on here)
      if (m.connect !== connect || this.store.sessionWs(m.session)?.startsWith(comingWs("")) === true) continue;
      const to = this.store.handedTo(m.session);
      if (to !== null) return to.station;
    }
    return null;
  }

  /// The station left one of its workspaces but is still in others: that workspace's
  /// sessions end their processes as `suspendAll` ends everyone's; `backIn` resumes them once it is back.
  async leftWorkspace(ws: string) {
    // Only actors and their eviction deadlines have anything to suspend. Historical sessions have neither.
    const candidates = new Set([...this.deadlines.keys(), ...this.actors.keys()]);
    const keys = new Set([...candidates].filter((key) => this.store.sessionWs(key) === ws));
    for (const [key, fiber] of this.deadlines) if (keys.has(key)) (this.interrupt(fiber), this.deadlines.delete(key));
    await Promise.all([...this.actors.values()].filter((a) => keys.has(a.key)).map((a) => a.suspend("the station left its workspace")));
  }

  /// The station is in a workspace again: its sessions' cut-off turns resume, and what waited goes on.
  backIn(ws: string) {
    let rows = this.store.returningSessionsIn(ws);
    if (rows === null && this.waitForWorkspaceActivity !== null) {
      if (!this.awaitingWorkspaceActivity.has(ws)) {
        this.awaitingWorkspaceActivity.add(ws);
        void this.waitForWorkspaceActivity().then((ready) => {
          this.awaitingWorkspaceActivity.delete(ws);
          if (ready && this.workspaces().includes(ws)) this.backIn(ws);
        }).catch((error) => {
          this.awaitingWorkspaceActivity.delete(ws);
          log.warn("hub", "could not find a rejoined workspace's active sessions", { error: (error as Error).message });
        });
      }
      return;
    }
    // A standalone hub without the agents' worker can still open an older store.
    if (rows === null) {
      const keys = new Set([...this.store.runningSessions().map((row) => row.key), ...this.store.sessionsWithPending()]);
      rows = [...keys].map((key) => this.store.getSession(key)).filter((row): row is SessionRow =>
        row !== null && row.ws === ws && (row.running || this.store.hasPending(row.key))).sort((a, b) => b.lastActiveAt - a.lastActiveAt);
    }
    for (const row of rows) {
      if (!this.online(row)) continue;
      if (row.running) void this.actor(row).recover();
      else void this.actor(row).kick();
    }
  }

  /// How many turns are running.
  running(): number {
    return [...this.actors.values()].filter((a) => a.processState() === "running").length;
  }

  anyRunning(): boolean {
    return this.running() > 0;
  }

  // ── handover ───────────────────────────────────────────────────────────────────────────────────────────────────

  /// Hands the sessions to the next station: turns held, every queue run out, each actor's snapshot written to
  /// <data>/run/handover.json, and the drivers let go of their processes (the runners keep them). Until the snapshot
  /// is taken it can fail (the queues did not settle within `limitMs`) and turns are released again; after, this hub
  /// does nothing more.
  async handOver(limitMs = 30_000): Promise<Handover> {
    this.hold("drain");
    // (what its drivers let go is the next station's)
    this.holdsRunners = false;
    try {
      await this.settled(limitMs);
    } catch (error) {
      this.release("drain");
      throw error;
    }
    // What the MoonBit program reads of the processes (agents/mb-agents.ts) held from here: what it said before is
    // taken in too, and the snapshots say where each stands then.
    const frozen = [...this.drivers.values()].filter((d) => d.freeze !== undefined);
    if (frozen.length > 0) {
      try {
        await Promise.all(frozen.map((d) => d.freeze!()));
        await this.settled(limitMs);
      } catch (error) {
        for (const d of frozen) d.thaw?.();
        this.release("drain");
        throw error;
      }
    }
    // Settled: leave incoming events waiting for old preparation unacknowledged for the next station.
    this.incoming.abort();
    // Snapshotted at once, before anything else is taken in.
    const taking: (Snapshot | Promise<Snapshot>)[] = [];
    for (const actor of this.actors.values()) {
      if (actor.processState() !== "cold" || actor.holdsState()) taking.push(actor.snapshot());
      else actor.close();
    }
    const sessions: Snapshot[] = await Promise.all(taking);
    await this.actorsProgram?.close();
    for (const driver of this.drivers.values()) driver.detach();
    // The next station attaches to their runners once this file is there: every ack is in by then.
    await allLeft();
    this.stopTimers();
    const handed: Handover = { sessions };
    const file = handoverFile(this.config().dataDir);
    await mkdir(join(file, ".."), { recursive: true });
    await writeFile(file, JSON.stringify(handed));
    log.info("hub", "handed over", { sessions: sessions.length });
    return handed;
  }

  /// Resolves once no actor has a task queued or running: each queue is run out, and again while new tasks came
  /// meanwhile (a runtime's events). Fails after `limitMs`.
  private async settled(limitMs: number) {
    const runOut = async () => {
      for (;;) {
        await Promise.all([...this.actors.values()].map((a) => a.flushed()));
        if ([...this.actors.values()].every((a) => a.settled())) return;
      }
    };
    await within(this.clock, limitMs, runOut(), () => new Error(`sessions did not settle within ${Math.round(limitMs / 1000)} s`));
  }

  /// Takes up what the previous station left: the snapshots of its handover, then the runners it left without one (it
  /// crashed). Sessions taken up with their runtime run on; a turn marked running whose runtime is gone is `recover`'s.
  async takeUp() {
    const file = handoverFile(this.config().dataDir);
    let handed: Handover = { sessions: [] };
    const text = await readFile(file, "utf8").catch((error: NodeJS.ErrnoException) => (error.code === "ENOENT" ? null : error));
    this.nonUpdateRestart = text === null;
    if (text !== null) {
      try {
        if (text instanceof Error) throw text;
        handed = JSON.parse(text);
      } catch (error) {
        log.warn("hub", "the handover file does not read; sessions resume the usual way", { error: (error as Error).message });
      }
      await rm(file, { force: true });
    }
    // Found before anything is taken up or started: what nobody takes up of these is ended, nothing started meanwhile.
    const before = (this.options.runners ? this.options.runners().map((id) => ({ id }) as RunnerInfo) : await liveRunners(this.config().dataDir, { strict: true })).filter((r) => !isTerminalRunner(r.id));
    await this.adopt(handed);
    // A crash left runners without a snapshot: what they keep is taken up as it stands.
    const runners = new Set(before.map((r) => r.id));
    const taken = new Set(handed.sessions.map((s) => s.key));
    // A shared Codex host can only have a session to recover when that session was marked running. Without a
    // session-owned runner there is no reason to load the station's idle and archived sessions.
    const ownRunners = [...runners].some((id) => !id.startsWith("codex-"));
    const parts = [...runners].flatMap((id) => {
      const kind = RUNTIME_KINDS.find((k) => k !== "codex" && id.startsWith(`${k}-`));
      return kind === undefined ? [] : [id.slice(kind.length + 1)];
    });
    const found = ownRunners ? this.sandboxNameLookup().takeUp(parts) : null;
    const candidates = !ownRunners ? this.store.runningSessions() : found === "fallback" ? this.store.listSessions() : found!;
    for (const row of candidates) {
      if (taken.has(row.key)) continue;
      const runtime = runtimeNamed(row.runtime);
      // Claude's and dsh's runner is the session's own (an idle one is taken up too); codex sessions share their
      // profile's host, which its driver finds, for a turn that was running.
      if (!runtime || (runtime !== "codex" ? !runners.has(runnerId(runtime, row.key)) : !row.running)) continue;
      // Its latest turn alone: every one it had read for it, the main thread took 254 ms for many on a station (2026-11-03).
      const turn = row.running ? (this.store.latestTurn(row.key) ?? undefined) : undefined;
      const snap: Snapshot = {
        key: row.key,
        runtime,
        agent: null,
        turn: turn && turn.summary.endedAt === null ? { id: turn.id, authRetried: turn.summary.kind === "auth_retry", codexRetried: turn.summary.kind === "codex_retry", by: { profile: null, person: null, thread: null }, declared: turn.summary.declared, wait: turn.summary.waitSeconds } : null,
        workingFor: [],
        notices: [],
        waitingMs: null,
        waitingSeconds: 0,
        nudges: 0,
        stopRequested: false,
        // Idle since its session was last active (its turn's end set it), not from now: one found idle for hours is not
        // kept warmMs more. (A turn it has running sets its idle time again as it ends.)
        idleMs: Math.max(0, this.now() - row.lastActiveAt),
      };
      await this.adoptOne(row, snap, true);
    }
    this.holdsRunners = true;
    this.orphansEnded = this.endOrphans(before);
  }

  /// What a station left running that nobody took up (a session deleted or moved to another station since, one whose
  /// taking up failed, an app-server none of whose sessions had a turn): ended, off the way of what goes on. A runner
  /// left so went on for good, nothing ever asking for it again (a `claude -p` of 109 MB idle 35 hours, 2026-11-15).
  private async endOrphans(found: RunnerInfo[]) {
    const ending = found.filter((info) => !this.ownsRunner(info.id)).map(async (info) => {
      log.info("hub", "a runtime process nobody took up, ended", { runner: info.id });
      try {
        await this.endRunnerOf(info);
      } catch (error) {
        log.warn("hub", "a runtime process nobody took up was not ended", { runner: info.id, error: (error as Error).message });
      }
    });
    await Promise.all(ending);
  }

  private endRunnerOf(info: RunnerInfo): Promise<unknown> {
    return this.options.endRunner ? this.options.endRunner(info) : endRunner(this.config().dataDir, info.id, "a runtime process nobody took up", info);
  }

  /// Whether one of its drivers holds runner `id` (or may: a driver that does not say holds every one of its runtime's).
  ownsRunner(id: string): boolean {
    for (const driver of this.drivers.values()) {
      const owned = driver.ownedRunners?.();
      if (owned === undefined ? id.startsWith(`${driver.runtime()}-`) : owned.has(id)) return true;
    }
    return false;
  }

  /// A runner of an agent's alive past what takes it up that none of its drivers holds, while they hold all that goes on
  /// (Upkeep's sweep, agents/runner.ts `sweepRunners`): ended. One started RUNNER_LEFT_MS ago or less is left, its driver
  /// may not hold it yet. Whether it was.
  async endOrphan(info: RunnerInfo, now: number): Promise<boolean> {
    if (!this.holdsRunners || isTerminalRunner(info.id) || now - info.startedAt < RUNNER_LEFT_MS || this.ownsRunner(info.id)) return false;
    log.info("hub", "a runtime process nobody holds, ended", { runner: info.id });
    await this.endRunnerOf(info);
    return true;
  }

  /// Takes up a handover's snapshots (sessions handed over by the previous station).
  async adopt(handed: Handover) {
    for (const snap of handed.sessions) {
      const row = this.store.getSession(snap.key);
      if (!row) {
        log.warn("hub", "session handed over is gone", { session: snap.key });
        continue;
      }
      await this.adoptOne(row, snap, snap.agent !== null);
    }
  }

  private async adoptOne(row: SessionRow, snap: Snapshot, withProcess: boolean) {
    this.options.taking?.();
    let actor: Actor;
    try {
      actor = this.actor(row);
    } catch (error) {
      log.warn("hub", "session handed over could not be taken up; it resumes the usual way", { session: row.key, error: (error as Error).message });
      return;
    }
    // Its process runs on the profile it was started on (the one its runtime session last ran on), which the session may
    // have been moved off since: taken up there, not moved, it moves before its next turn (actor.ts `ensureAgent`).
    const ranOn = (row.runtimeSessionId ? this.store.ranOn(row.key, row.runtimeSessionId) : null) ?? row.profile;
    let agent: AgentSession | null = null;
    if (withProcess) {
      const generation = actor.nextGeneration();
      const router = actor.beginAdopt(generation);
      try {
        const driver = this.sessionDriver(snap.runtime);
        const memory = await this.deps.linkSkills(row);
        const options = await openOptions(row, this.accounts.profile(ranOn) ?? this.accounts.runOn(row.key), this.deps, memory);
        agent = await driver.adopt({ ...options, router }, snap.agent, actor.listener(generation));
      } catch (error) {
        actor.cancelAdopt(generation);
        log.warn("hub", "a session's runtime could not be taken up; it resumes the usual way", { session: row.key, error: (error as Error).message });
      }
      if (!agent) actor.cancelAdopt(generation);
    }
    // Its runtime not taken up: a turn it had is resumed the usual way (recover).
    if (withProcess && !agent) return;
    // (taken up whole before its idle time is looked at: `idleNow`)
    await actor.adopt(snap, agent, ranOn);
    log.info("hub", "session taken up from the previous station", { session: row.key, withAgent: agent !== null });
    if (agent) {
      this.adopted.add(row.key);
      if (!snap.turn) this.idleNow(row.key);
    }
    if (snap.notices.length > 0) void actor.release();
  }

  // ── messages in ────────────────────────────────────────────────────────────────────────────────────────────────

  /// Takes one event from a connect's platform. Resolves once it is durably recorded (or deliberately ignored).
  async receive(connectId: string, event: ChatEvent) {
    if (event.type === "message") return this.accept(connectId, event.message);
    if (event.type === "loginCode") return this.enterCode(connectId, event);
    if (event.type === "stop") {
      const thread = this.store.threadAt(this.surface(connectId), event.channel, event.threadTs);
      if (!thread) return;
      for (const member of this.store.threadSessions(thread.id)) {
        if (member.connect !== connectId) continue;
        const row = this.store.getSession(member.session);
        if (row) await this.actor(row).stopFromSlack(connectId, event.channel, event.threadTs, event.ts, event.localAt);
      }
      return;
    }
    const prepare = this.prepareLegacyEdits;
    if (prepare === null) {
      this.store.editMessage(this.surface(connectId), event.channel, event.threadTs, event.ts, event.text);
      return;
    }
    const surface = this.surface(connectId), at = `${surface}\0${event.channel}\0${event.threadTs}`;
    return this.inThread(at, async () => {
      for (;;) {
        this.incoming.signal.throwIfAborted();
        const changed = this.store.editMessageIfReady(surface, event.channel, event.threadTs, event.ts, event.text);
        if (changed !== undefined) return;
        await prepare(this.incoming.signal);
      }
    }, true);
  }

  /// A login card's field answered on a platform (Slack): the code goes to the login that card is of, and only if the
  /// message is one of the thread's with that card. Never recorded as a message. Throws what refused it.
  private async enterCode(connectId: string, event: Extract<ChatEvent, { type: "loginCode" }>) {
    const thread = this.store.threadAt(this.surface(connectId), event.channel, event.threadTs);
    const card = thread ? this.store.cardAt(thread.id, event.ts) : null;
    if (card?.type !== "login" || typeof card.login !== "string" || card.station !== undefined) throw new Error("this message is no login card");
    if (!this.logins) throw new Error("this station has no logins");
    const chat = this.chatOf(connectId);
    const email = (await chat?.userEmail?.(event.user).catch(() => null)) ?? null;
    const name = (await chat?.userName?.(event.user).catch(() => null)) ?? null;
    this.logins.answer(card.login, event.code, email ? { name: name ?? email, email } : undefined);
  }

  /// Accepts one message seen by a connect, one at a time per thread. Resolves once it is durably recorded (or
  /// deliberately ignored).
  async accept(connectId: string, message: InboundMessage) {
    const at = `${this.surface(connectId)}\0${message.channel}\0${message.threadTs}`;
    return this.inThread(at, () => this.acceptInTurn(connectId, message));
  }

  private async inThread<T>(at: string, run: () => Promise<T>, blockFollowingOnError = false): Promise<T> {
    let gate = this.gates.get(at);
    if (!gate) this.gates.set(at, (gate = { tail: Promise.resolve(null), waiting: 0 }));
    gate.waiting++;
    const previous = gate.tail;
    const turn = previous.then((blocked) => {
      if (blocked) throw blocked.error;
      return run();
    });
    // An unrecorded edit must be redelivered before the events already waiting behind it. Ordinary message failures
    // keep the previous behavior; once this queue has drained, a new delivery may try again.
    gate.tail = turn.then(
      () => null,
      async (error) => (await previous) ?? (blockFollowingOnError ? { error } : null),
    );
    try {
      return await turn;
    } finally {
      // No one waits on it any more.
      if (--gate.waiting === 0 && this.gates.get(at) === gate) this.gates.delete(at);
    }
  }

  /// A single-session connect's session made or chosen, by the connect: one at a time. A person's later binding must
  /// not be replaced by a session still being made for an earlier choice or the connect's first message.
  private readonly singles = new Map<string, Promise<unknown>>();
  oneSingle<T>(connect: string, f: () => Promise<T>): Promise<T> {
    const run = (this.singles.get(connect) ?? Promise.resolve()).then(f, f);
    const done = run.then(() => {}, () => {});
    this.singles.set(connect, done);
    void done.then(() => {
      if (this.singles.get(connect) === done) this.singles.delete(connect);
    });
    return run;
  }

  private async acceptInTurn(connectId: string, message: InboundMessage) {
    const config = this.config();
    // What a bot of this station posted is its agent's, recorded and handed to the thread as it was posted: Slack's
    // copy of it, seen through another connect, is not a message of its own.
    if (this.ownBot(config, message.user)) return;
    // (a notice of another station's, come back through another bot's connect: no person said it)
    if (this.stationNotice(config, message)) return;
    const connect = connectOf(config, connectId);
    // (a workspace whose chats go to another station: not taken here, so that it is said there)
    if (this.quieted.size > 0 && this.quieted.has(connect.workspace ?? this.workspaces()[0] ?? "")) throw new Retiring();
    const chat = this.chat(connectId);
    const surface = this.surface(connectId);
    const single = connect.mode === "single-session";
    const bound = single ? this.store.binding(connect.id) : null;
    const existing = this.store.threadAt(surface, message.channel, message.threadTs);
    const members = existing ? this.store.threadSessions(existing.id) : [];
    // A thread this connect's bot already takes part in (a chat relayed there) is its session's: the bot mentioned
    // there goes to the one still following it, never to a second agent of the same bot (relay.ts refuses the other
    // way round), and one that left stays out while another follows.
    const own = single ? null : sessionKey(connect.id, message.channel, message.threadTs);
    const sameBot = single ? [] : members.filter((m) => m.connect === connect.id);
    const taken = sameBot.find((m) => m.leftAt === null) ?? sameBot.find((m) => m.session === own) ?? sameBot[0];
    let key = bound ?? taken?.session ?? own ?? newSingleSessionKey(connect.id);
    const sessionRow = this.store.getSession(key);
    const exists = sessionRow !== null;
    // Left (chat_leave), or archived by hand, the session or the thread itself: it hears the thread again only once
    // someone mentions it. What is said meanwhile is recorded.
    const left = members.some((m) => m.session === key && m.leftAt !== null);
    const selfManuallyArchived = sessionRow?.archivedBy === MANUAL;
    const threadHiddenByHand = existing !== null && existing.hiddenBy === MANUAL;
    const out = left || selfManuallyArchived || threadHiddenByHand;
    const wanted = message.addressed || (!out && (single ? !connect.requireMention || (exists && members.some((m) => m.session === key)) : exists));
    // Chatter this connect is not part of, in a thread no session takes part in.
    if (!wanted && members.length === 0) return;
    const here: ThreadRef = { channel: message.channel, threadTs: message.threadTs };
    let restored = false;
    if (message.addressed && (selfManuallyArchived || (existing !== null && existing.hiddenAt !== null))) {
      // One this session was given before (a platform sends again what it was slow to hear of): no one mentions it anew.
      const seen = existing === null ? null : this.store.messageNumberAt(existing.id, message.ts);
      if (existing !== null && seen !== null && this.store.wasDelivered(existing.id, seen, key)) return;
      // Mentioned: shown again as by hand, its whole conversation. Another bot's first mention here leaves it archived.
      if (sessionRow !== null && sessionRow.archivedAt !== null) archive(this, key, false);
      if (existing !== null && existing.hiddenAt !== null) this.store.setThreadHidden(existing.id, false, MANUAL);
      restored = true;
    }
    const createdBy = `slack:${connect.id}:${message.user}`;
    if (wanted && !exists) {
      try {
        if (!single) await this.createSession(config, key, connect, "thread", message, null, createdBy);
        else {
          // A single-session connect's one session, made once: messages of two channels at once (each its own
          // thread's turn) find the one the first made and bound.
          const making = key;
          key = await this.oneSingle(connect.id, async () => {
            const now = this.store.binding(connect.id);
            if (now !== null && this.store.getSession(now) !== null) return now;
            await this.createSession(config, making, connect, "all", message, null, createdBy);
            this.store.setBinding(connect.id, making);
            return making;
          });
        }
      } catch (error) {
        log.error("hub", "cannot create session", { session: key, error: (error as Error).message });
        await chat.post(here, markNotice(`⚠️ ${tr(stationLang(), "station.slack.sessionFailed", { error: (error as Error).message })}`), []);
        return;
      }
      // As the broker did: a new session says first where it can be followed. Once, as it starts; not waited for. In
      // Slack's own link form: what the station posts is sent as written.
      const link = single ? undefined : this.link(key);
      const said = link === undefined ? null : chat.sessionLink ? chat.sessionLink(link, tr(stationLang(), "station.slack.viewSession")) : `<${link}|${tr(stationLang(), "station.slack.viewSession")}>`;
      if (said !== null) {
        chat.post(here, markNotice(said), []).catch((error) => log.warn("hub", "session link not posted", { session: key, error: (error as Error).message }));
      }
    }
    const thread = existing ?? (await this.openSlackThread(chat, surface, message, createdBy, key));
    if (wanted) this.store.joinThread(thread.id, key, connect.id);
    // Its files go where a session of the thread reads them; once (Slack sends a message again it was slow to hear of).
    // Never to one archived by hand, whose workspace is put away: with no other there, they are only named.
    const shown = wanted || threadHiddenByHand ? [] : members.filter((m) => this.store.getSession(m.session)?.archivedBy !== MANUAL);
    const into = wanted ? key : ((shown.find((m) => m.leftAt === null) ?? shown[0])?.session ?? null);
    const at = this.store.messageNumberAt(thread.id, message.ts);
    // Recorded with its files only named, and now one it mentions is there (another bot's connect saw it first).
    const late = wanted && at !== null && this.unfetched.has(`${thread.id}:${at}`);
    // Edited on its platform since (an edit of the thread waits its turn, `receive`), it reads as edited.
    const words = late ? (this.store.editedText(thread.id, at) ?? message.text) : message.text;
    let said: { text: string; attachments: Attachment[] } = { text: words, attachments: [] };
    if (into === null) said.text = [message.text, ...(message.files ?? []).map((f) => tr(stationLang(), "station.slack.fileNotFetched", { name: f.name, error: tr(stationLang(), "station.slack.fileWhileArchived") }))].filter((t) => t !== "").join("\n\n");
    else if (at === null || late) said = await this.fetched(chat, into, words, message.files);
    if (into !== null && wanted && (at === null || late)) said = await this.withQuoted(chat, thread.id, here, into, message, said);
    const [n, fresh] = this.store.insertMessage({ thread: thread.id, ts: message.ts, authorKind: "person", author: message.user, ...said });
    if (late) {
      this.store.completeMessage(thread.id, n, said.text, said.attachments);
      this.unfetched.delete(`${thread.id}:${n}`);
    } else if (fresh && into === null && ((message.files ?? []).length > 0 || message.quoted !== undefined)) {
      this.unfetched.add(`${thread.id}:${n}`);
      if (this.unfetched.size > 2000) this.unfetched.delete(this.unfetched.keys().next().value!);
    }
    // A message seen by a second connect is already delivered to the thread; only a session it brings in lacks it, and
    // those restored with it. The thread itself archived by hand, no one is given it.
    const everyone = restored || (fresh && (wanted || !threadHiddenByHand));
    const targets = everyone ? this.store.threadSessions(thread.id).map((m) => m.session) : wanted ? [key] : [];
    // Its own words, never the quote's: a quoted `-stop` is no command.
    this.deliver(thread.id, n, targets, words);
  }

  /// The messages recorded with what they carry (files, a quote) left out, no one there to read it, as `thread:n` (the newest;
  /// a restart forgets them). Brought in should another connect of theirs bring an agent it mentions (`acceptInTurn`).
  private readonly unfetched = new Set<string>();

  /// The quoted messages already brought in, as `thread:message` (the newest; a restart forgets them, and one is brought once more).
  private readonly quotedIn = new Set<string>();

  /// A message that quotes one the conversation does not have (Feishu's 回复, `InboundMessage.quoted`) brings it in:
  /// its words as a blockquote before the message's, its files fetched before the message's own.
  private async withQuoted(chat: ChatSurface, thread: number, here: ThreadRef, into: string, message: InboundMessage, said: { text: string; attachments: Attachment[] }): Promise<{ text: string; attachments: Attachment[] }> {
    if (message.quoted === undefined || !chat.quoted || this.store.messageNumberAt(thread, message.quoted) !== null) return said;
    // Once a conversation: every reply in a Feishu thread names the thread's first message as what it replies to.
    const once = `${thread}:${message.quoted}`;
    if (this.quotedIn.has(once)) return said;
    this.quotedIn.add(once);
    if (this.quotedIn.size > 2000) this.quotedIn.delete(this.quotedIn.keys().next().value!);
    const quoted = await chat.quoted(here, message.quoted);
    if (quoted === null || (quoted.text === "" && (quoted.files ?? []).length === 0)) return said;
    const its = await this.fetched(chat, into, quoted.text, quoted.files);
    const block = its.text === "" ? "" : its.text.split("\n").map((line) => `> ${line}`).join("\n");
    return { text: [block, said.text].filter((t) => t !== "").join("\n\n"), attachments: [...its.attachments, ...said.attachments] };
  }

  /// A Slack thread the station starts following. When that happens mid-thread, what was said before is recorded first
  /// (without deliveries), so the thread on the pages and chat_history are complete and the log keeps Slack's order.
  private async openSlackThread(chat: ChatSurface, surface: string, message: InboundMessage, createdBy: string, key: string): Promise<ThreadRow> {
    let earlier: { ts: string; user: string; text: string; files?: InboundFile[] }[] = [];
    if (message.ts !== message.threadTs) {
      try {
        earlier = (await chat.history?.({ channel: message.channel, threadTs: message.threadTs }, message.ts, 200)) ?? [];
      } catch (error) {
        log.warn("hub", "cannot read what the thread said before; continuing without it", { channel: message.channel, threadTs: message.threadTs, error: (error as Error).message });
      }
    }
    // Asked before the thread exists, so a connect seeing the same message meanwhile cannot record it ahead of these.
    const said = [];
    for (const m of earlier) said.push({ ...m, ...(await this.fetched(chat, key, m.text, m.files)) });
    const thread = this.store.openThread(surface, message.channel, message.threadTs, null, createdBy);
    for (const m of said) this.store.insertMessage({ thread: thread.id, ts: m.ts, authorKind: "person", author: m.user, text: m.text, attachments: m.attachments });
    return thread;
  }

  /// A message's text and its shared files, fetched into the session's uploads (as files sent in the station's own
  /// chats are). A file that cannot be fetched is named in the text with why, so its reader knows one was there.
  async fetched(chat: ChatSurface, key: string, text: string, files: InboundFile[] | undefined): Promise<{ text: string; attachments: Attachment[] }> {
    const row = files && files.length > 0 ? this.store.getSession(key) : null;
    if (!files || !row) return { text, attachments: [] };
    // Just shown again (`archiveBy`): what is written as its workspace comes back could go with the one it replaces.
    await this.waitRestore(key);
    const dir = join(row.workspace, "uploads");
    const attachments: Attachment[] = [];
    const missing: string[] = [];
    for (const file of files) {
      try {
        if (!chat.download) throw new Error("this platform does not give files");
        if (file.size > MAX_INBOUND_FILE) throw new Error("over 50 MB");
        const bytes = await chat.download(file);
        await mkdir(dir, { recursive: true });
        const safe = Array.from(file.name)
          .map((c) => (c === "\\" || c === "/" || c.codePointAt(0)! < 0x20 ? "_" : c))
          .join("");
        const path = join(dir, `${iso(this.now()).slice(0, 19).replace(/[:.]/g, "-")}-${file.id}-${safe}`);
        // written and measured off the main thread: a file of up to 50 MB, a film's moov read from its end
        await writeFile(path, bytes);
        const attachment: Attachment = { name: file.name, path, size: bytes.length, ...(await shownFactsSoon(path)) };
        attachments.push(attachment);
      } catch (error) {
        log.warn("hub", "shared file not fetched", { session: key, file: file.id, error: (error as Error).message });
        missing.push(tr(stationLang(), "station.slack.fileNotFetched", { name: file.name, error: (error as Error).message }));
      }
    }
    return { text: [text, ...missing].filter((t) => t !== "").join("\n\n"), attachments };
  }

  /// Gives sessions a message they have not had: each runs it, or stops for `-stop`, compacts its
  /// context for `-compact`, clears it for `-clear` (saying in the thread why not, when it cannot now).
  /// A session archived by hand hears nothing until shown again.
  deliver(thread: number, n: number, sessions: string[], text: string, options: { retryPending?: boolean; workspace?: string | null } = {}) {
    // Neither archived by hand nor gone from the thread (chat_leave).
    const left = new Set(this.store.threadSessions(thread).filter((m) => m.leftAt !== null).map((m) => m.session));
    const hearing = sessions.filter((key) => !left.has(key) && this.store.getSession(key)?.archivedBy !== MANUAL);
    const workspace = options.workspace === undefined ? undefined : { expected: options.workspace, fallback: this.wsOf(null) };
    const added = this.store.deliver(thread, n, hearing, workspace);
    const command = threadCommand(text);
    const give = (key: string) => {
      this.store.touch(key);
      const row = this.store.getSession(key);
      if (!row) return;
      const actor = this.actor(row);
      if (command === null) {
        void actor.kick();
        return;
      }
      // Another process can be retrying the same delivery; only the one that marks it runs the command.
      const marked = this.store.markDelivered(key, [{ thread, n, apart: false }]);
      if (options.workspace !== undefined && marked === 0) return;
      if (command === "stop") void actor.stop();
      else if (command === "compact") void actor.compact(true);
      else void actor.clear(true);
    };
    for (const key of added) give(key);
    // A process may have stopped after queuing a delivery but before waking its actor. Retry only what still waits.
    if (options.retryPending === true) {
      const fresh = new Set(added);
      for (const key of new Set(hearing)) {
        if (fresh.has(key) || !this.store.deliveryPending(thread, n, key)) continue;
        give(key);
      }
    }
  }

  /// Gives sessions a letter of their chat's own log (store/schema.ts LETTERS) they have not had: each runs it. A letter
  /// is no command (`-stop` and the like are a person's, in the thread). Archived by hand, as `deliver`.
  deliverLetter(thread: number, n: number, sessions: string[]) {
    const hearing = sessions.filter((key) => this.store.getSession(key)?.archivedBy !== MANUAL);
    for (const key of this.store.deliverLetter(thread, n, hearing)) {
      this.store.touch(key);
      const row = this.store.getSession(key);
      if (row) void this.actor(row).kick();
    }
  }

  /// An agent's post reaches the other sessions of its thread, as a person's would: agents work together there.
  shared(thread: number, n: number, author: string, text: string) {
    const others = this.store.threadSessions(thread).map((m) => m.session).filter((s) => s !== author);
    if (others.length > 0) this.deliver(thread, n, others, text);
  }

  /// The station's tools are open at `url`: a process taken up that was told another address (the station before had
  /// them elsewhere) starts again, as it can (actor_run.mbt `tools_at`).
  toolsAt(url: string) {
    for (const actor of this.actors.values()) void actor.toolsAt(url);
  }

  /// Called whenever the set of sessions interrupted by a non-update restart changes (pushes `/overview`).
  onInterruptedChanged(f: () => void) {
    this.interruptedHook = f;
  }

  /// Sessions interrupted by a non-update restart visible to `viewer`, newest active first (items capped at 20).
  interruptedIn(viewer: InWorkspace): { count: number; items: { key: string; thread: number | null; title: string }[] } {
    const rows: SessionRow[] = [];
    for (const key of this.interruptedByRestart) {
      const row = this.store.getSession(key);
      if (!row || row.running || row.archivedAt !== null || this.handedOver(key)) continue;
      if (!sees(viewer, row.ws ?? null)) continue;
      rows.push(row);
    }
    rows.sort((a, b) => (b.lastActiveAt ?? 0) - (a.lastActiveAt ?? 0));
    return {
      count: rows.length,
      items: rows.slice(0, 20).map((row) => {
        // Named by the chat list's rule (client/core-ts/src/titles.ts chatTitle: a chat its agent named has only
        // `auto_title`), with no words of the station's: "" where it has no name, said by the device in its own language.
        const chat = this.store.sessionChat(row.key);
        const title = (chat ? titles.chatTitle(chat.thread, chat.firstText, null, { untitled: "", directMessage: "" }) : "") || (row.title ?? "");
        return { key: row.key, thread: chat?.thread.id ?? null, title };
      }),
    };
  }

  /// Resumes sessions interrupted by a non-update restart visible to `viewer` (optionally narrowed to `keys`),
  /// gently staggered on the hub clock so a batch click does not spike the machine all at once.
  resumeInterrupted(viewer: InWorkspace, keys?: string[]): number {
    const wanted = keys ? new Set(keys) : null;
    const rows: SessionRow[] = [];
    for (const key of [...this.interruptedByRestart]) {
      if (wanted !== null && !wanted.has(key)) continue;
      const row = this.store.getSession(key);
      if (!row || row.running || row.archivedAt !== null || this.handedOver(key)) {
        this.interruptedByRestart.delete(key);
        continue;
      }
      if (!sees(viewer, row.ws ?? null)) continue;
      this.interruptedByRestart.delete(key);
      rows.push(row);
    }
    if (rows.length === 0) return 0;
    this.interruptedHook?.();
    rows.sort((a, b) => (b.lastActiveAt ?? 0) - (a.lastActiveAt ?? 0));
    const eligible = rows.filter((row) => this.online(row));
    if (eligible.length === 0) return 0;
    void this.actor(eligible[0]!).recover();
    if (eligible.length > 1) {
      const rest = eligible.slice(1);
      const self = this;
      this.fork(
        Effect.gen(function* () {
          for (const row of rest) {
            // timer: stagger batch manual resume after non-update restart
            yield* Effect.sleep(250);
            const now = self.store.getSession(row.key);
            if (!now || now.running || now.archivedAt !== null || self.handedOver(row.key) || !self.online(now)) continue;
            void self.actor(now).recover();
          }
        }),
      );
    }
    return eligible.length;
  }

  /// Dismisses sessions interrupted by a non-update restart visible to `viewer` (optionally narrowed to `keys`).
  dismissInterrupted(viewer: InWorkspace, keys?: string[]): number {
    const wanted = keys ? new Set(keys) : null;
    let removed = 0;
    for (const key of [...this.interruptedByRestart]) {
      if (wanted !== null && !wanted.has(key)) continue;
      const row = this.store.getSession(key);
      if (row && !sees(viewer, row.ws ?? null)) continue;
      if (this.interruptedByRestart.delete(key)) removed++;
    }
    if (removed > 0) this.interruptedHook?.();
    return removed;
  }

  /// After a restart: resume cut-off turns (those not taken up with their runtime), then deliver whatever is still
  /// pending. On a non-update restart (no handover.json), cut-off turns are ended cleanly and await manual resume
  /// instead of auto-spawning every runtime process at once.
  recover() {
    const manualResume = this.nonUpdateRestart;
    this.nonUpdateRestart = false;
    const recovering = new Set<string>();
    const running = [...this.store.runningSessions()].sort((a, b) => (b.lastActiveAt ?? 0) - (a.lastActiveAt ?? 0));
    for (const row of running) {
      // Taken up from the previous station: its turn runs on.
      if (this.adopted.has(row.key) || !this.online(row)) continue;
      if (manualResume) {
        log.info("hub", "turn cut off by non-update restart; awaiting manual resume", { session: row.key });
        void this.actor(row).cutOffByRestart().then((interrupted) => {
          if (!interrupted) return;
          const now = this.store.getSession(row.key);
          if (!now || now.running || now.archivedAt !== null || this.handedOver(row.key)) return;
          if (!this.interruptedByRestart.has(row.key)) {
            this.interruptedByRestart.add(row.key);
            this.interruptedHook?.();
          }
        }).catch(() => {});
        continue;
      }
      log.info("hub", "recovering a turn cut off by restart", { session: row.key });
      recovering.add(row.key);
      void this.actor(row).recover();
    }
    // A turn resumed takes what waits for it with it; while turns are held, `release` gives the rest theirs.
    if ((this.holdsNow?.size ?? 0) === 0) {
      for (const key of this.store.sessionsWithPending()) {
        if (recovering.has(key)) continue;
        const row = this.store.getSession(key);
        if (row && this.online(row)) void this.actor(row).kick();
      }
    }
    // Waits on record that were not handed over: taken up so each asks again when it would have, or put right by the
    // actor. An old store retains its original recovery path until its lookup has been prepared.
    const indexed = this.store.recoveryWaits?.();
    if (indexed != null) {
      for (const { row, refill } of indexed) {
        if (!this.online(row)) continue;
        if (refill) void this.actor(row).takeRefill();
        else void this.actor(row).takeWait();
      }
      return;
    }
    // Preserve the first recovery's timing while an older store's lookup is still being prepared.
    const live = this.store.liveSessions();
    const turns = this.store.lastTurnsOf(live.map((s) => s.key));
    for (const row of live) {
      const last = turns.get(row.key);
      if (row.running || last?.endedAt === null) continue;
      const refill = last?.outcome === "failed" && last.detail?.startsWith("rate_limit:");
      const waiting = last?.declared === "waiting";
      if ((!refill && !waiting) || !this.online(row)) continue;
      if (refill) void this.actor(row).takeRefill();
      else void this.actor(row).takeWait();
    }
  }

  /// What to do when a session's runtime was not found as it started.
  onRuntimeMissing(f: (runtime: RuntimeKind) => void) {
    this.runtimeMissing = f;
  }

  /// A runtime installed here (from the pages): the sessions on it whose messages wait (their start found it missing)
  /// take them now.
  installed(runtime: RuntimeKind) {
    for (const key of this.store.sessionsWithPending()) {
      const row = this.store.getSession(key);
      if (row && row.runtime === runtime && this.online(row)) void this.actor(row).kick();
    }
  }

  private copyProfileScopes(profiles: Profile[]): Profile[] {
    return profiles.map((p) => ({ ...p, runtimes: [...p.runtimes], withheld: p.withheld?.slice(), share: structuredClone(p.share) }));
  }

  /// A profile newly became available to a workspace: retry its failed starts without a second message. A profile
  /// belonging to another workspace is not available, even when its copy has arrived at this station.
  profilesChanged() {
    const before = this.profileScopes;
    const after = this.config().profiles;
    this.profileScopes = this.copyProfileScopes(after);
    if (before === null) return;
    const scope = (p: Profile) => {
      const share = p.share as { borrowed?: unknown; workspaces?: unknown } | undefined;
      return JSON.stringify([p.runtimes, p.enabled !== false, p.withheld ?? [], share?.borrowed, share?.workspaces]);
    };
    const previous = new Map(before.map((p) => [p.id, p]));
    const changed = after.filter((p) => !previous.has(p.id) || scope(previous.get(p.id)!) !== scope(p));
    if (changed.length === 0) return;
    const home = this.workspaces()[0] ?? null;
    for (const actor of this.actors.values()) {
      const row = this.store.getSession(actor.key);
      if (!row || row.archivedAt !== null || this.handedOver(row.key) || !this.store.hasPending(row.key) || !this.online(row)) continue;
      const allowed = (p: Profile) => p.enabled !== false && p.runtimes.includes(actor.runtime) && allowedIn(p, row.ws ?? null, home);
      const added = new Set(changed.filter((p) => allowed(p) && (!previous.has(p.id) || !allowed(previous.get(p.id)!))).map((p) => p.id));
      if (added.size === 0) continue;
      // A start may still be in flight when the profile arrives. Once its queue reaches this barrier, retry only if
      // it actually failed and the profile still serves the workspace. Ordinary queued wakes retain their deduplication.
      void actor.flushed().then(() => {
        const now = this.store.getSession(actor.key);
        if (!now || now.archivedAt !== null || this.actors.get(actor.key) !== actor || this.handedOver(actor.key) ||
          !actor.startFailed() || !this.store.hasPending(actor.key) || !this.online(now)) return;
        const stillAllowed = this.config().profiles.some((p) => added.has(p.id) && p.enabled !== false && p.runtimes.includes(actor.runtime) &&
          allowedIn(p, now.ws ?? null, this.workspaces()[0] ?? null));
        if (stillAllowed) return actor.kick();
      }).catch((error) => log.warn("hub", "could not retry after a profile became available", { session: actor.key, error: (error as Error).message }));
    }
  }

  // ── warm processes ─────────────────────────────────────────────────────────────────────────────────────────────

  /// Ends idle claude and dsh processes (one per session) beyond the warm limit (immediately, oldest first), and any
  /// remaining idle processes once they have idled past warmMs (when warmMs > 0). Codex threads share a process and
  /// stay. Runs when a process goes idle (the count grew) and at each idle process's deadline.
  private evictIdle() {
    const config = this.config();
    const now = this.now();
    const idle = [...this.actors.values()]
      .filter((a) => a.runtime !== "codex")
      .flatMap((a) => {
        const ms = a.idleMs(now);
        return ms === null ? [] : [[a, ms] as const];
      })
      .sort((a, b) => b[1] - a[1]);
    const cap = Math.max(0, Math.trunc(config.maxWarmClaude));
    let excess = idle.length - cap;
    for (const [actor, ms] of idle) {
      if (excess > 0) {
        void actor.evict();
        excess--;
      } else if (config.warmMs > 0 && ms >= config.warmMs) {
        void actor.evict();
      } else {
        break;
      }
    }
  }

  /// The session-name lookup of runners, whose ids use the session-key part (it served sessions' sandboxes before
  /// sandboxes as station_task's targets took their place: no longer prepared).
  private sandboxNameLookup(): SandboxNameBuilder {
    return this.sandboxNames ??= new SandboxNameBuilder(this.store, this.options?.previous ?? Promise.resolve(), () => false, undefined, this.options?.readers);
  }

  runnerNameSessions(runners: readonly { id: string; part: string }[]): Map<string, string> | "fallback" {
    return runners.length === 0 && this.sandboxNames === null ? new Map() : this.sandboxNameLookup().runners(runners);
  }

  sessionInDirectory(dir: string) {
    return (this.sessionDirectories ??= new SessionDirectoryBuilder(this.store, this.options?.previous ?? Promise.resolve(), undefined, this.options?.readers)).find(dir);
  }

  sessionsInArguments(lines: readonly string[], home: string) {
    return (this.sessionDirectories ??= new SessionDirectoryBuilder(this.store, this.options?.previous ?? Promise.resolve(), undefined, this.options?.readers)).findArguments(lines, home);
  }

  processJobLookup(): ProcessJobsBuilder {
    return this.processJobs ??= new ProcessJobsBuilder(this.store, this.options?.previous ?? Promise.resolve(), undefined, this.options?.readers);
  }

  /// The lookup of sessions by their sandbox's name a station kept while sessions ran in sandboxes, taken down (its
  /// triggers on sessions with it). Every `SWEEP_MS` (agents.ts), till there is none.
  async sweepSandboxes() {
    if (sandboxIndexEnabled(this.store.db)) await this.sandboxNameLookup().disable();
  }

  /// A process went idle: look again when it has idled past warmMs.
  idleNow(key: string) {
    // A manual archive may have arrived during the last turn. Finish that archive when the turn ends; any archive whose
    // packing did not finish is backfilled periodically by `packUnfinishedArchived` (bounded per round, with a cursor,
    // only for sessions not yet past `archivedWorkspaceMs`), never via a one-shot full sweep at startup.
    const row = this.store.getSession(key);
    if (row && row.archivedAt !== null) {
      const actor = this.actor(row);
      // (what it left in the background ends with it: an archived session keeps nothing running)
      void actor.evict(true).then(() => actor.cleanArchive());
    }
    const old = this.deadlines.get(key);
    if (old) this.interrupt(old);
    // When it will have idled long enough: from when it went idle (one taken up from the previous station may have been
    // idle a while already).
    const limit = this.config().warmMs;
    const idleFor = this.actors.get(key)?.idleMs(this.now()) ?? 0;
    const fiber = this.runFork(
      Effect.sleep(Math.max(0, limit - idleFor)).pipe(
        Effect.andThen(
          Effect.sync(() => {
            this.deadlines.delete(key);
            this.evictIdle();
          }),
        ),
      ),
    );
    this.deadlines.set(key, fiber);
    this.evictIdle();
  }

  /// The machine short of memory (high, critical: ops/self-memory.ts): every idle claude and dsh process let go now,
  /// whatever the warm limit and however briefly idle; then what the drivers keep running with no turn on it (Codex's
  /// app-servers: `evictIdle`); how many were asked to end. Each session's ends only if still idle as its queue reaches
  /// it, and keeps what it runs in the background (`holding`); its conversation resumes on its next message.
  async evictAllIdle(): Promise<number> {
    const now = this.now();
    let asked = 0;
    for (const actor of this.actors.values()) {
      if (actor.runtime === "codex" || actor.idleMs(now) === null) continue;
      void actor.evict();
      asked++;
    }
    const ended = await Promise.all([...this.drivers.values()].map((d) => d.evictIdle?.().catch((error) => {
      log.warn("hub", "what a driver keeps idle was not ended", { runtime: d.runtime(), error: (error as Error).message });
      return 0;
    }) ?? 0));
    return ended.reduce((a, b) => a + b, asked);
  }

  /// Ends the session's runtime process if it is idle; the conversation resumes on the next message.
  async evict(key: string) {
    await this.actors.get(key)?.evict();
  }

  /// How a session runs changed: its process ends now if idle, else before its next turn (the actor's `changed`); `restart`:
  /// what changed is what its process started with, which only a new one takes.
  async changed(key: string, restart = false) {
    await this.actors.get(key)?.changed(restart);
  }

  /// A manual allowance reset lets every waiting session on the same account, or left to the station and able to move
  /// to it, go on now.
  allowanceReset(profile: string) {
    this.accounts.resetAllowance(profile);
    const waiting = [...this.actors.values()].filter((actor) => {
      const row = this.store.getSession(actor.key);
      return row !== null && this.accounts.goesOnWith(row, profile);
    });
    for (const actor of waiting) void actor.allowanceReset().catch((error) => {
      log.warn("hub", "could not resume a session after its allowance was reset", { session: actor.key, error: (error as Error).message });
    });
    this.drainCapQueue();
  }

  /// What every runtime process starts with changed (the station's variables for its agents, ops/agent-env.ts): each
  /// session's process ends now if idle, else before its next turn, and the next starts with it (none retuned in place).
  everyChanged() {
    for (const actor of [...this.actors.values()]) void actor.changed(true).catch(() => {});
  }

  /// A runtime updated here (from the pages): the processes of its sessions still run the old executable, which the
  /// service may refuse from then on (a model a version before does not support), so each ends now if idle, else before
  /// its next turn, and the next starts on the new one, resuming. Codex's app-servers are its driver's (codex.ts
  /// `runtimeChanged`).
  runtimeUpdated(runtime: RuntimeKind) {
    for (const actor of [...this.actors.values()]) if (actor.runtime === runtime) void actor.changed(true).catch(() => {});
  }

  /// A profile signed in anew (accounts/index.ts `afterSignIn`, `sharedChanged`): the processes of the sessions on it keep
  /// the sign-in they started with, so each ends now if idle, else once its turn is over, and the next turn resumes in
  /// a new one on the new sign-in. A chat handed to another station is left as it is.
  profileLoginChanged(id: string) {
    for (const row of this.store.listSessions()) {
      if (row.profile !== id || this.handedOver(row.key)) continue;
      void this.actors.get(row.key)?.changed(true).catch(() => {});
    }
  }

  /// A profile was deleted (disabled, moved away): a session on it with a turn under way is taken on by another of its
  /// runtime's (its process ends when the turn is over), or stopped where no other profile can run it; one whose
  /// process is idle only has it ended. A session with no process is left as it is: no one is using it, and its next
  /// turn, if it ever has one, picks another account then (accounts.ts `runOn`), said in its chat as it goes on (the
  /// user, 2026-11-17: 「没人用的 session 为啥要切」「这种系统消息不应该给很久没活跃的 thread 发」, after an account
  /// deleted on the admin page moved every session it had ever run, 554 chats told 已切换账号 in a second, months-old
  /// Slack and group threads among them).
  /// A chat handed to another station as this one is retired is left as it is: it goes on there, and its account moving
  /// away from here (share/index.ts `moveProfile`) says nothing in it.
  async profileGone(id: string) {
    for (const row of this.store.listSessions()) {
      if (row.profile !== id || this.handedOver(row.key)) continue;
      const actor = this.actors.get(row.key);
      const state = actor?.processState() ?? "cold";
      if (!actor || state === "cold") continue;
      if (state === "warm") {
        log.info("hub", "profile deleted under an idle session", { session: row.key, profile: id });
        await actor.changed();
        continue;
      }
      let movable = true;
      try {
        this.accounts.runOn(row.key);
      } catch {
        movable = false;
      }
      log.info("hub", "profile deleted under a session", { session: row.key, profile: id, movedTo: movable ? (this.store.getSession(row.key)?.profile ?? "") : "" });
      if (!movable) await actor.stop();
      await actor.changed();
    }
  }

  /// Chats moved here from a retired station whose accounts came after them (replica/retire.ts `retire.accounts`): those
  /// of `keys` that ran on an account of `map` (its id there) go on on the id it has here, their runtime sessions too, so
  /// that the next turn takes up its runtime session there and nothing is said in the chat; one with a process up takes
  /// it as it is next idle. How many moved.
  followAccounts(keys: string[], map: Map<string, string>): number {
    let n = 0;
    for (const key of keys) {
      if (!this.store.followProfiles(key, map)) continue;
      n++;
      void this.actors.get(key)?.changed().catch(() => {});
    }
    return n;
  }

  /// Starts a session's runtime ahead of a message (the actor's `warm`).
  async warm(key: string) {
    const row = this.store.getSession(key);
    if (row) await this.actor(row).warm();
  }

  /// Interrupts the session's running turn, or what it waits on, as `-stop` in a thread would.
  async stop(key: string) {
    const row = this.store.getSession(key);
    if (!row) throw new Error(`unknown session ${key}`);
    await this.actor(row).stop();
  }

  /// Cancels the retry represented by this particular notice, if it is still waiting.
  async cancelRetry(key: string, thread: number, seq: number) {
    const row = this.store.getSession(key);
    if (!row) throw new Error(`unknown session ${key}`);
    await this.actor(row).cancelRetry(thread, seq);
  }

  /// Takes up again the failed turn this particular notice is about (its 重试), if it is still the last.
  async retryFailed(key: string, thread: number, seq: number) {
    const row = this.store.getSession(key);
    if (!row) throw new Error(`unknown session ${key}`);
    await this.actor(row).retryFailed(thread, seq);
  }

  /// Moves the session whose failed turn this particular notice is about to another account (its 重新分配账号), if it
  /// is still the last.
  async reassign(key: string, thread: number, seq: number) {
    const row = this.store.getSession(key);
    if (!row) throw new Error(`unknown session ${key}`);
    await this.actor(row).reassign(thread, seq);
  }

  /// Compacts the session's context between turns, as `-compact` in a thread would (the actor's `compact`): why not,
  /// when it cannot now.
  async compact(key: string): Promise<string | null> {
    const row = this.store.getSession(key);
    if (!row) throw new Error(`unknown session ${key}`);
    return this.actor(row).compact();
  }

  /// Clears the session's context between turns, as `-clear` in a thread would (the actor's `clear`; `readBack`: to go on
  /// afresh): why not, when it cannot now.
  async clear(key: string, readBack = false): Promise<string | null> {
    const row = this.store.getSession(key);
    if (!row) throw new Error(`unknown session ${key}`);
    return this.actor(row).clear(false, readBack);
  }

  /// A word from the station for a session's agent, outside any conversation (the actor's `notify`).
  notify(key: string, text: string) {
    const row = this.store.getSession(key);
    if (!row) throw new Error(`unknown session ${key}`);
    void this.actor(row).notify(text);
  }

  /// Live process state of a session, for the pages.
  processState(key: string): "running" | "warm" | "cold" {
    return this.actors.get(key)?.processState() ?? "cold";
  }

  /// Every session's process state that is not cold (what the reads are given).
  processes(): Map<string, string> {
    return new Map([...this.actors].flatMap(([key, a]) => (a.processState() === "cold" ? [] : [[key, a.processState()] as [string, string]])));
  }

  /// The readers also need to distinguish a failed start from messages still queued for an agent.
  readProcesses(): Map<string, string> {
    const states = this.processes();
    for (const [key, actor] of this.actors) {
      if (actor.startFailed()) states.set(key, actor.processState() === "warm" ? "warmFailed" : "coldFailed");
    }
    return states;
  }

  /// The key the client that asked for a session gave it (NewChat.clientKey), while it is kept.
  clientKey(key: string): string | undefined {
    const kept = this.clientKeysMade.get(key);
    return kept && this.now() - kept[1] < CLIENT_KEY_KEPT_MS ? kept[0] : undefined;
  }

  clientKeys(): Map<string, string> {
    return new Map([...this.clientKeysMade].filter(([, [, at]]) => this.now() - at < CLIENT_KEY_KEPT_MS).map(([key, [client]]) => [key, client]));
  }

  // ── what goes beside it ────────────────────────────────────────────────────────────────────────────────────────

  /// The station's background jobs, once they are made.
  setJobs(jobs: Jobs) {
    this.jobs = jobs;
  }

  /// What to do when a session is archived or deleted (Remote.closeSession).
  onClose(closed: (key: string) => void) {
    this.closedHook = closed;
  }

  closed(key: string) {
    this.closedHook?.(key);
  }

  /// Hooks session_send up to the other stations of the workspace.
  onPeer(call: (station: string, request: Json) => Promise<Json>) {
    this.peersHook = call;
  }

  peers() {
    return this.peersHook;
  }

  /// Hooks chat_list up to the chats other workspaces share with this one (xshare/index.ts).
  onOutsideChats(list: (ws: string | null) => OutsideChat[]) {
    this.outsideHook = list;
  }

  /// The chats other workspaces share with workspace `ws` (null: the home one).
  outsideChats(ws: string | null = null): OutsideChat[] {
    return this.outsideHook?.(ws) ?? [];
  }

  /// Background cold-storage restores started by `archiveBy(..., false)`, by session key.
  private readonly restores = new Map<string, Set<Promise<void>>>();

  trackRestore(key: string, work: Promise<void>): void {
    let set = this.restores.get(key);
    if (!set) this.restores.set(key, (set = new Set()));
    const settled = work.then(() => {}, () => {});
    set.add(settled);
    void settled.finally(() => {
      set.delete(settled);
      if (set.size === 0) this.restores.delete(key);
    });
  }

  async waitRestore(key: string): Promise<void> {
    for (;;) {
      const set = this.restores.get(key);
      if (!set || set.size === 0) return;
      await Promise.all([...set]);
    }
  }

  async waitRestores(): Promise<void> {
    for (;;) {
      const all = [...this.restores.values()].flatMap((s) => [...s]);
      if (all.length === 0) return;
      await Promise.all(all);
    }
  }

  async shutdown() {
    this.holdsRunners = false;
    this.incoming.abort();
    this.stopTimers();
    this.unlistenRunning();
    await this.live.close();
    await this.sandboxNames?.close();
    await this.sessionDirectories?.close();
    await this.processJobs?.close();
    await Promise.all([...this.actors.values()].map((a) => a.dispose()));
    await this.waitRestores();
    await this.actorsProgram?.close();
    await Promise.all([...this.drivers.values()].map((d) => d.shutdown()));
  }

  /// Transcripts' lengths not written yet, and whether their write is due (`noteLength`).
  private lengths = new Map<string, number>();
  private lengthsDue = false;
  /// The sessions whose length was written in this process.
  private lengthWritten = new Set<string>();

  /// A transcript's length, written with the others' that come within LENGTHS_GATHER_MS: one statement of its own at each
  /// read was one at every step of every agent at work, on the main thread. Only a session's summary reads it (its
  /// entries told as they come say more): its first in this process is written at once, the rest before its summary is
  /// next told (a change of the session), else within LENGTHS_GATHER_MS; one read between says the length before.
  /// Written as the hub stops (a handover, a shutdown); one lost in a crash is read again, as the next station follows
  /// its transcript from the start (live.ts `begin`).
  private noteLength(key: string, n: number) {
    this.lengths.set(key, n);
    if (!this.lengthWritten.has(key)) {
      this.lengthWritten.add(key);
      this.writeLengths([key]);
      return;
    }
    if (this.lengthsDue) return;
    this.lengthsDue = true;
    this.fork(Effect.sleep(LENGTHS_GATHER_MS).pipe(Effect.andThen(Effect.sync(() => this.writeLengths()))));
  }

  private writeLengths(only?: string[]) {
    if (only === undefined) this.lengthsDue = false;
    const lengths = only === undefined ? this.lengths : new Map(only.flatMap((key) => this.lengths.has(key) ? [[key, this.lengths.get(key)!] as const] : []));
    if (only === undefined) this.lengths = new Map();
    else for (const key of only) this.lengths.delete(key);
    if (lengths.size === 0) return;
    try {
      this.store.setTranscriptLengths(lengths);
    } catch (error) {
      log.warn("hub", "transcripts' lengths not written", { error: (error as Error).message });
    }
  }

  private stopTimers() {
    this.writeLengths();
    for (const fiber of [...this.deadlines.values(), ...this.fibers]) this.interrupt(fiber);
    this.deadlines.clear();
    this.fibers.clear();
  }

  /// Runs `effect` as a fiber of the hub's own, interrupted at shutdown or handover.
  fork(effect: Effect.Effect<void>) {
    // It may end before runFork returns.
    const held: { fiber?: Fiber.Fiber<void>; done?: boolean } = {};
    held.fiber = this.runFork(
      effect.pipe(
        Effect.ensuring(
          Effect.sync(() => {
            held.done = true;
            if (held.fiber) this.fibers.delete(held.fiber);
          }),
        ),
      ),
    );
    if (!held.done) this.fibers.add(held.fiber);
  }

  /// Runs `effect` on the hub's clock.
  private runFork<A>(effect: Effect.Effect<A>): Fiber.Fiber<A> {
    return Effect.runFork(effect.pipe(Effect.provideService(Clock.Clock, this.clock)));
  }

  private interrupt(fiber: Fiber.Fiber<void>) {
    Effect.runFork(Fiber.interrupt(fiber));
  }

  // ── chats and connects ─────────────────────────────────────────────────────────────────────────────────────────

  chat(connect: string): ChatSurface {
    const chat = this.chatOf(connect);
    if (!chat) throw new Error(`connect ${connect} is not connected`);
    return chat;
  }

  chatOf(connect: string): ChatSurface | undefined {
    if (connect === INTERNAL_CONNECT) return this.internal ?? undefined;
    return this.options.chats(connect);
  }

  /// Where a connect's threads live; the rule the v10 migration follows too. A Feishu connect's are its own (its people's
  /// ids are the app's own, so another bot's in the same chat are other people).
  surface(connect: string): string {
    if (connect === INTERNAL_CONNECT) return STILLFAIL_SURFACE;
    const kind = this.config().connects.find((c) => c.id === connect)?.kind;
    if (kind === "feishu") return feishuSurface(connect);
    if (kind === "comma") return commaSurface(connect);
    if (kind === "group") return groupSurface(connect);
    return slackSurface(connect, this.chatOf(connect)?.workspace() ?? null);
  }

  /// The bots of the connects the workspace's other stations run, as each told this one (connects/workspace.ts
  /// `connect.bots`, told as they change), by station.
  readonly toldBots = new Map<string, Set<string>>();

  /// A station's own notice (chat.ts `NOTICE_MARK`) from a bot of any connect this station knows of the workspace's: its
  /// own connects', those of other stations it learnt (their surfaces here), and those the other stations told it.
  private stationNotice(config: HubConfig, message: InboundMessage): boolean {
    if (!isNotice(message.text)) return false;
    if (config.connects.some((c) => (this.chatOf(c.id)?.botUserId() ?? "") === message.user && message.user !== "")) return true;
    for (const bots of this.toldBots.values()) if (bots.has(message.user)) return true;
    return false;
  }

  /// A Slack user that is one of this station's connects' bots.
  private ownBot(config: HubConfig, user: string): boolean {
    return config.connects.some((c) => {
      const bot = this.chatOf(c.id)?.botUserId() ?? "";
      return bot !== "" && bot === user;
    });
  }

  private online(row: SessionRow): boolean {
    const via = this.store.latestThread(row.key)?.connect ?? row.connect;
    if (this.chatOf(via)) return true;
    log.warn("hub", "session's latest thread came through a connect that is not connected; leaving it", { session: row.key, connect: via });
    return false;
  }

  /// Which workspace a session's chat is in: its own, or the station's home one for those from before (null outside
  /// any workspace).
  wsOf(row: SessionRow | string | null): string | null {
    const s = typeof row === "string" ? this.store.getSession(row) : row;
    return s?.ws ?? this.workspaces()[0] ?? null;
  }

  /// The profiles sessions of workspace `ws` may run on: every one for the home workspace's.
  profilesIn(ws: string | null): Profile[] {
    const home = this.workspaces()[0] ?? null;
    return this.config().profiles.filter((p) => p.enabled !== false && allowedIn(p, ws, home));
  }

  /// Whether a session's chat is in `workspace` (a viewer's): what a member of one workspace may see and use.
  inWorkspace(row: SessionRow | string | null, workspace: string): boolean {
    const s = typeof row === "string" ? this.store.getSession(row) : row;
    return s !== null && s !== undefined && this.wsOf(s) === workspace;
  }

  /// The models a person can pick for a new chat with a connect (Slack's `/sf`): those its workspace's profiles run, its
  /// own first (what a chat with it runs unless told otherwise).
  modelsFor(connectId: string): ModelChoice[] {
    const config = this.config();
    const connect = connectOf(config, connectId);
    const own: ModelChoice = { runtime: connect.bind.runtime, model: connect.bind.model ?? null };
    const profiles = config.profiles.filter((p) => p.enabled !== false && allowedIn(p, connect.workspace ?? null, this.workspaces()[0] ?? null));
    const same = (c: ModelChoice) => c.runtime === own.runtime && (c.model === null || own.model === null ? c.model === own.model : sameModel(c.model, own.model));
    return [own, ...modelsRun(profiles, null).filter((c) => !same(c))];
  }

  /// Of those, the few `user` (a person as the connect's platform names them) is offered before they type anything
  /// (model-choice.ts `few`): what they started chats on lately counts with any connect, as one person talks to
  /// several bots.
  modelsFirst(connectId: string, user: string): ModelChoice[] {
    const all = this.modelsFor(connectId);
    if (all.length <= FEW_MOST) return all;
    const config = this.config();
    const connect = connectOf(config, connectId);
    const since = this.now() - USED_WITHIN_MS;
    const used = user === "" ? [] : config.connects.flatMap((c) => this.store.modelsUsedBy(`slack:${c.id}:${user}`, since));
    const profiles = config.profiles.filter((p) => p.enabled !== false && allowedIn(p, connect.workspace ?? null, this.workspaces()[0] ?? null));
    return few(all, used, modelsRun(profiles.map((p) => ({ ...p, models: p.named })), null));
  }

  /// A session for a connect: the connect's own profile when it keeps to one (and it still can run it); else any of its
  /// runtime, the model's first (pool.ts). A message sent to a model (`model`) starts one on that model instead, on any
  /// profile of the connect's workspace that runs it.
  async createSession(config: HubConfig, key: string, connect: Connect, scope: "thread" | "all", message: InboundMessage | null, title: string | null, createdBy: string | null): Promise<void> {
    const home = this.workspaces()[0] ?? null;
    const chosen = message?.model ?? null;
    const runtime = chosen === null ? connect.bind.runtime : runtimeNamed(chosen.runtime);
    if (runtime === null) throw new Error(`unknown runtime ${chosen?.runtime}`);
    const model = chosen === null ? (connect.bind.model ?? null) : chosen.model;
    const fits = chosen === null ? profilesFor(config, connect, home) : config.profiles.filter((p) => p.enabled !== false && p.runtimes.includes(runtime) && allowedIn(p, connect.workspace ?? null, home) && serves(p, model));
    if (fits.length === 0 && chosen !== null) throw new Error(tr(stationLang(), "station.session.noProfileForModel", { model: model ?? runtimeTitle(runtime), runtime: runtimeTitle(runtime) }));
    if (fits.length === 0 && profilesFor(config, connect).length > 0) throw new Error(tr(stationLang(), "station.session.noProfileHere", { runtime: runtimeTitle(connect.bind.runtime) }));
    const boundIds = chosen === null && connect.bind.profiles && connect.bind.profiles.length > 0
      ? connect.bind.profiles
      : chosen === null && connect.bind.profile !== undefined
        ? [connect.bind.profile]
        : null;
    const boundFits = boundIds !== null ? fits.filter((p) => boundIds.includes(p.id) && serves(p, model)) : [];
    const savedProfiles = boundFits.length > 0 ? boundFits.map((p) => p.id) : null;
    const profile = boundFits.length === 1 ? boundFits[0]! : this.accounts.pick(boundFits.length > 0 ? boundFits : fits, model, false);
    const dir = scope === "thread" && message ? `${message.channel}-${message.threadTs.replace(".", "-")}` : key.slice(connect.id.length + 1);
    const workspace = join(config.dataDir, "sessions", connect.id, dir, "workspace");
    await Promise.all([mkdir(workspace, { recursive: true }), mkdir(join(config.dataDir, "repos"), { recursive: true })]);
    // (made meanwhile by what was waiting on the same key: as it is)
    if (this.store.getSession(key) !== null) return;
    const now = this.now();
    this.store.insertSession({
      key,
      connect: connect.id,
      scope,
      title,
      createdBy,
      runtime,
      profile: profile.id,
      profilePinned: savedProfiles?.length === 1,
      profiles: savedProfiles,
      model,
      effort: chosen === null ? (connect.bind.effort ?? null) : null,
      fast: null,
      workspace,
      cwd: null,
      runtimeSessionId: null,
      token: newToken(),
      createdAt: now,
      lastActiveAt: now,
      ws: connect.workspace ?? null,
    });
    log.info("hub", "session created", { session: key, connect: connect.id, scope, runtime, model: model ?? "", profile: profile.id });
    const pool = boundFits.length > 0 ? boundFits : fits;
    if (boundFits.length !== 1 && billedPerUse(profile) && pool.some((p) => !billedPerUse(p))) {
      this.noteBilledFallback({ session: key, workspace: connect.workspace ?? null, runtime, profile });
    }
  }

  /// Reports an automatic fallback to a billed-per-use profile unless the session was handed over.
  noteBilledFallback(info: BilledFallback): void {
    if (!this.handedOver(info.session)) this.onBilledFallback?.(info);
  }

  /// Updates the maximum concurrent running turns without restarting the station.
  setMaxConcurrentTurns(n: number) {
    const limit = typeof n === "number" && Number.isFinite(n) && n > 0 ? Math.trunc(n) : 0;
    this.maxConcurrentTurnsOverride = limit;
    if (this.actorsProgram) this.actorsProgram.setMaxConcurrentTurns(limit);
  }

  /// Wakes queued sessions waiting on per-account concurrency caps.
  drainCapQueue() {
    this.actorsProgram?.drainCapQueue();
  }

  /// The program its actors run in, the station's jobs too (jobs/jobs.ts), started for its first use (none: not built
  /// here).
  program(): ActorsProgram | null {
    if (this.actorsProgram === undefined) {
      this.actorsProgram = ActorsProgram.open(this.config().dataDir, this.clock, this.store, this.maxConcurrentTurnsOverride ?? this.config().maxConcurrentTurns);
    }
    return this.actorsProgram;
  }

  /// The session's actor, made on first use.
  actor(row: SessionRow): Actor {
    const existing = this.actors.get(row.key);
    if (existing) return existing;
    const runtime = runtimeNamed(row.runtime);
    if (!runtime) throw new Error(`session ${row.key} runs an unknown runtime ${row.runtime}`);
    const program = this.program();
    // (the program is built for every system the station runs on: a checkout that did not build it cannot run a session)
    if (program === null) throw new Error("the station's MoonBit program is not built here (station/mb: build.sh): no session can run");
    const actor = program.actor(row.key, runtime, this.deps);
    this.actors.set(row.key, actor);
    return actor;
  }

  /// Takes a session's actor out (deleted).
  dropActor(key: string): Actor | undefined {
    const actor = this.actors.get(key);
    this.actors.delete(key);
    const deadline = this.deadlines.get(key);
    if (deadline) this.interrupt(deadline);
    this.deadlines.delete(key);
    return actor;
  }

  private sessionDriver(runtime: string): AgentDriver {
    const driver = this.drivers.get(runtime);
    if (!driver) throw new Error(`no ${runtime} driver`);
    return driver;
  }

  /// What a session needs of the station (SessionDeps).
  private sessionDeps(): SessionDeps {
    return {
      store: this.store,
      emitTrace: (payload) => recordTracePayload(this.options.traces?.(), payload),
      // (its workspace's agent home made first where it is a joined one's not made yet: its memory and skills)
      linkSkills: async (row) => {
        await workspaceAgentHome(this.config().agentHome, this.wsOf(row.key), this.workspaces()[0] ?? null);
        return this.skillsLinker ? this.skillsLinker(row) : linkSkills(row, this.deps);
      },
      pendingDeliveries: async (key, signal) => this.pendingDeliveries
        ? this.pendingDeliveries(key, signal) : this.store.pendingMessages(key),
      deliveryCardState: async (thread, n, signal) => {
        if (this.deliveryCardState) return this.deliveryCardState(thread, n, signal);
        const ended = this.store.cardEndedByMessage(thread, n);
        if (ended === null) return null;
        const current = this.store.pendingCard(thread)?.[0] ?? null;
        return { ended: { author: ended[0].author, ts: ended[0].ts }, card: ended[1],
          current: current === null ? null : { ts: current.ts } };
      },
      preparePostsAfter: (messages, signal) => {
        if (!this.preparePostsAfter) throw new Error("post block builder unavailable");
        return this.preparePostsAfter(messages, signal);
      },
      prepareWidgetSources: (threads, signal) => {
        if (!this.prepareWidgetSources) throw new Error("widget source builder unavailable");
        return this.prepareWidgetSources(threads, signal);
      },
      chat: (connect) => this.chatOf(connect),
      driver: (runtime) => this.sessionDriver(runtime),
      runOn: (key, holding, across, forceCap) => this.accounts.runOn(key, holding, false, across, forceCap),
      spend: (key, ranOn, model) => this.accounts.spend(key, ranOn, model),
      refillsAt: (key) => this.accounts.refillsAt(key),
      recheck: (profile, force) => this.accounts.recheck(profile, force === true),
      canAuthRetry: (key, failedProfile, tried) => this.accounts.canAuthRetry(key, failedProfile, Array.isArray(tried) ? tried.filter((t): t is string => typeof t === "string") : []),
      limitAfter: (profile, model) => this.accounts.limitAfter(profile, model),
      mcpUrl: () => (typeof this.options.mcpUrl === "string" ? this.options.mcpUrl : this.options.mcpUrl()),
      ...(this.options.toolsHeard ? { toolsHeard: this.options.toolsHeard } : {}),
      reposDir: () => this.reposDir(),
      siteInstructions: () => this.options.siteInstructions ?? "",
      moveOn: () => this.options.moveOn?.() ?? true,
      ownName: () => {
        const me = this.options.station?.() ?? null;
        return me === null ? "" : (this.options.stationName?.(me) ?? "");
      },
      memoryPath: (key) => agentHomePaths(workspaceAgentHomePath(this.config().agentHome, this.wsOf(key), this.workspaces()[0] ?? null))[0],
      maxNudges: () => this.config().maxNudges,
      untitled: (key) => (this.config().askToName ? untitledChat(this, key) : null),
      backgroundOnMessage: (key) => {
        const row = this.store.getSession(key);
        if (!row) return true;
        return this.config().profiles.find((p) => p.id === row.profile)?.backgroundOnMessage ?? true;
      },
      live: this.live,
      startsAfresh: (key, id, to, was) => startsAfresh(this, key, id, to, was),
      cleared: (key, readBack) => toldCleared(this, key, readBack),
      coldAfresh: (key, now) => goesAfresh(this, key, now),
      resumeLost: (key) => toldResumeLost(this, key),
      longChat: (key) => toldLongChat(this, key),
      carrySubagents: (from, to, on, ids) => carrySubagents(this, from, to, on, ids),
      ranIn: (key, id, profile) => this.store.ranIn(key, id, profile),
      idle: (key) => this.idleNow(key),
      archiveIsCold: async (key) => this.restores.has(key) || (await this.cold.isCold(key)),
      restoreArchive: async (key) => {
        await this.waitRestore(key);
        if (await this.cold.isCold(key)) await this.cold.restore(key);
      },
      cleanArchive: (key) => this.cold.pack(key),
      held: (key) => this.holdsNow.size > 0 || this.heldChats.has(key) || !this.inAWorkspace(key),
      stoppedNotice: (key) => {
        const n = this.stopNotices.get(key);
        if (n === undefined || n.told || !this.heldChats.has(key)) return null;
        n.told = true;
        return n.words();
      },
      stopJobs: async (key) => {
        const jobs = this.jobs;
        if (!jobs) return;
        for (const id of this.store.runningWaitJobIds(key)) {
          try {
            await jobs.stop(id);
            log.info("hub", "job stopped with its session's wait", { session: key, job: id });
          } catch (error) {
            log.warn("hub", "job not stopped", { session: key, job: id, error: (error as Error).message });
          }
        }
      },
      endJobs: async (key) => {
        const jobs = this.jobs;
        if (!jobs) return;
        let old = false;
        if (this.prepareSessionUpJobs !== null) {
          try {
            if (this.store.sessionHasUpJob(key) === null) await this.prepareSessionUpJobs(key);
          } catch (error) {
            // A failure must not leave an archived session's service running: the old lookup is still exact.
            old = true;
            log.warn("hub", "preparing jobs for archive failed", { session: key, error: (error as Error).message });
          }
        }
        for (const id of this.store.upJobIds(key, old)) {
          try {
            await jobs.stop(id);
            log.info("hub", "job stopped with its session archived", { session: key, job: id });
          } catch (error) {
            log.warn("hub", "job not stopped", { session: key, job: id, error: (error as Error).message });
          }
        }
      },
      settled: (key, state, words) => settled(this, key, state, words),
      toolStatus,
      pageOf: (key) => this.link(key),
      places: this.places,
      runtimeMissing: (runtime) => this.runtimeMissing(runtime),
      nextTs: () => this.nextTs(),
      clock: this.clock,
    };
  }
}

/// How long a new chat's rows say the key its client gave it: long past its answer.
export const CLIENT_KEY_KEPT_MS = 10 * 60 * 1000;

export function connectOf(config: HubConfig, id: string): Connect {
  const connect = config.connects.find((c) => c.id === id);
  if (!connect) throw new Error(`unknown connect ${id}`);
  return connect;
}
