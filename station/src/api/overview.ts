// GET /overview: the station as its settings pages show it — still.fail cloud, connects,
// profiles, the agents' processes, counts, the disk, logins, updates — as the viewer sees it. Answered on the main
// thread from what is in memory and the config; told again on /events when it changes (`overview`).
import { statfs } from "node:fs/promises";
import { homedir } from "node:os";
import type { Accounts } from "../accounts/index.ts";
import { facts } from "../accounts/catalog.ts";
import type { Cloud } from "../cloud/state.ts";
import { type Viewer, managesStation, readOnly } from "../mesh/credential.ts";
import { platform } from "../platform/index.ts";
import type { Lang } from "../ops/i18n.ts";
import type { Hub } from "../sessions/hub.ts";
import type { Store } from "../store/store.ts";
import { DecisionSessionsUnavailable } from "../store/legacy-decision-session.ts";
import { sessionChatReadable } from "../store/session-chat-index.ts";
import type { Updates } from "../updates/updates.ts";
import { type RootView, rootView, rootsOf } from "../drive/drive.ts";
import { sees } from "../store/rows.ts";
import { titleOf } from "../read/views.ts";
import { type PolicyChecks, policySince, policyView } from "../sessions/archive-policy.ts";
import { agentEnvView } from "./routes/agent-env.ts";
import { networkView } from "../mesh/settings.ts";
import { contextView } from "./routes/context.ts";
import { CONTEXT_LEAST, CONTEXT_RUNTIMES } from "../sessions/context-cap.ts";
import { diagnosticsView } from "./routes/diagnostics.ts";
import type { ConnectKind } from "../connects/connections.ts";

export type OverviewDeps = {
  store: Store;
  hub: Hub;
  cloud: Cloud;
  config: () => any;
  accounts?: Accounts;
  updates?: Updates;
  /// How each kind's connects show (connects/part.ts), by kind; a kind not there shows as just its config.
  connectKinds?: Map<string, ConnectKind>;
  /// What macOS lets still.fail Helper do here, as the viewer is told it (routes/permissions.ts); none where there is no
  /// helper (not a Mac), or before the first look.
  permissions?: (viewer: Viewer) => unknown;
  /// A pinned root as the drive shows it (drive.ts `rootViewThrough`: one in a folder macOS protects by what still.fail
  /// Helper's grant is known to be, never listed by the station); default `rootView`.
  rootView?: (path: string) => Promise<RootView>;
  /// Unix ms timestamp when this station release was built (ops/version.ts `builtAt`); undefined in development.
  builtAt?: () => number | undefined;
};

/// This station's link to still.fail cloud, as the pages show it (server.rs MeshFile::status): in the viewer's workspace
///, its home one for no one in particular.
export function meshStatus(cloud: Cloud, viewer?: Viewer): Record<string, unknown> {
  const s = cloud.state;
  if (s === null) return { state: "off", origin: null, station: null, workspace: null, workspaceId: null, name: null };
  const m = viewer === undefined ? null : cloud.membership(viewer.workspace);
  const v: Record<string, unknown> = {
    state: s.removed_at !== undefined ? "removed" : "running",
    origin: s.origin ?? null,
    station: s.station ?? null,
    workspace: m?.workspace_name ?? s.workspace_name ?? null,
    workspaceId: m?.workspace ?? s.workspace ?? null,
    name: m?.name ?? s.name ?? null,
    // Whether it hears still.fail cloud now: cut off from it, it goes on with the stations it was told last, and the
    // pages say so.
    reached: cloud.reached,
  };
  if (s.removed_at !== undefined) v.removedAt = s.removed_at;
  return v;
}

/// Memory of each recorded runtime process group (kB).
async function processMemory(pgids: number[]): Promise<Map<number, number>> {
  return pgids.length === 0 ? new Map() : platform.groupMemory(pgids);
}

/// processMemory, as measured within MEMORY_KEPT_MS for the same groups: every overview (each viewer's, at each change)
/// asked it of `ps` anew. Overviews that miss it at once share the one measuring under way.
const MEMORY_KEPT_MS = 5_000;
const memoryKept = new WeakMap<object, { at: number; pgids: string; memory: Map<number, number> }>();
const memoryPending = new WeakMap<object, { pgids: string; promise: Promise<Map<number, number>> }>();
async function keptMemory(d: OverviewDeps, pgids: number[]): Promise<Map<number, number>> {
  const key = pgids.join(",");
  const kept = memoryKept.get(d.store);
  const now = d.store.now();
  if (kept !== undefined && kept.pgids === key && now - kept.at < MEMORY_KEPT_MS) return kept.memory;
  const pending = memoryPending.get(d.store);
  if (pending !== undefined && pending.pgids === key) return pending.promise;
  const promise: Promise<Map<number, number>> = processMemory(pgids)
    .then((memory) => {
      memoryKept.set(d.store, { at: now, pgids: key, memory });
      return memory;
    })
    .finally(() => {
      if (memoryPending.get(d.store)?.promise === promise) memoryPending.delete(d.store);
    });
  memoryPending.set(d.store, { pgids: key, promise });
  return promise;
}

/// The data disk's room: what clients warn of when it runs low.
async function diskRoom(path: string): Promise<unknown> {
  if (process.env.STILLFAIL_TEST_HOST === "1") return { freeBytes: 50_000_000_000, totalBytes: 100_000_000_000 };
  try {
    const s = await statfs(path);
    return { freeBytes: s.bavail * s.bsize, totalBytes: s.blocks * s.bsize };
  } catch {
    return null;
  }
}

export async function overview(d: OverviewDeps, viewer: Viewer, lang: Lang): Promise<unknown> {
  const raw = d.config() ?? {};
  // What is of the viewer's workspace: its chats, and the connects added in it.
  // (Counted by connect from the viewer's workspace in the index; the processes not cold are the hub's few.)
  const visibleConnects = (Array.isArray(raw.connects) ? raw.connects : []).filter((c: any) => sees(viewer, typeof c?.workspace === "string" && c.workspace !== "" ? c.workspace : null));
  const ids = visibleConnects.map((c: any) => c.id);
  let counted = d.store.overviewSessionCounts(viewer, ids);
  if (counted === null) {
    if (d.hub.waitForSessionCounts == null || !await d.hub.waitForSessionCounts()) throw new Error("session counts are not ready");
    counted = d.store.overviewSessionCounts(viewer, ids);
    if (counted === null) throw new Error("session counts are not ready");
  }
  const counts = counted;
  const sessionsOf = (connect: unknown) => connect === null ? counts.total : typeof connect === "string" ? counts.byConnect.get(connect) ?? 0 : 0;
  const states = [...d.hub.processes()].filter(([key]) => sees(viewer, d.store.sessionWs(key) ?? null)).map(([, state]) => state);
  // The agents' runtime processes; background jobs' groups are recorded too (to be reaped), but they are jobs.
  const processes = d.store.listProcesses().filter((p) => p.runtime !== "job");
  // (The disk's room asked meanwhile: it never fails.)
  const disk = diskRoom(d.hub.config().dataDir);
  const memory = await keptMemory(d, processes.map((p) => p.pgid));
  const connects = visibleConnects.map((c: any) => {
    const mode = c.mode ?? "multi-session";
    const runtime = c.bind?.runtime;
    const nonEmpty = (v: unknown) => (typeof v === "string" && v !== "" ? v : null);
    const kind = typeof c.kind === "string" && c.kind !== "" ? c.kind : "slack";
    const bindProfiles: string[] = Array.isArray(c.bind?.profiles)
      ? [...new Set<string>(c.bind.profiles.filter((x: unknown): x is string => typeof x === "string" && x.trim() !== "").map((x: string) => x.trim()))]
      : [];
    const singleProfile = nonEmpty(c.bind?.profile) ?? (bindProfiles.length === 1 ? bindProfiles[0]! : null);
    const startsOnAuto = c.autoStation === true;
    const startsOn = startsOnAuto ? null : nonEmpty(c.station);
    const rawStartsOnStations: string[] = !startsOnAuto && Array.isArray(c.stations)
      ? [...new Set<string>(c.stations.filter((x: unknown): x is string => typeof x === "string" && x.trim() !== "").map((x: string) => x.trim()))]
      : [];
    const startsOnStations = startsOnAuto ? null : rawStartsOnStations.length > 0 ? rawStartsOnStations : startsOn !== null ? [startsOn] : null;
    const shown = {
      id: c.id,
      // What it is known by (its bot's name on its platform, and its workspace there), as its kind says: its id till then.
      name: c.id,
      team: null,
      botImage: null,
      enabled: c.enabled ?? true,
      kind,
      mode,
      requireMention: mode === "multi-session" ? true : (c.requireMention ?? true),
      bind: {
        runtime,
        model: nonEmpty(c.bind?.model),
        effort: nonEmpty(c.bind?.effort),
        profile: singleProfile,
        ...(bindProfiles.length > 1 ? { profiles: bindProfiles } : {}),
      },
      // Every connect has Slack's tokens for the pages (masked: connects/part.ts; none for another kind's).
      slack: { appToken: "", botToken: "" },
      connection: c.enabled === false ? { state: "disabled" } : { state: "starting" },
      createdBy: c.createdBy?.id ? c.createdBy : null,
      sessions: sessionsOf(c.id),
      session: mode === "single-session" ? d.store.binding(c.id) : null,
      // The station(s) of its workspace its new conversations run on (null: this one), and that it can be moved to
      // another (connects/workspace.ts; a station from before says neither).
      startsOn,
      startsOnStations,
      ...(startsOnAuto ? { startsOnAuto: true } : {}),
      moves: true,
    };
    const own = d.connectKinds?.get(kind);
    return own === undefined ? shown : { ...shown, ...own.shown(c), connection: own.connection(c) ?? shown.connection };
  });
  // (what each profile's home says read off the thread first: accounts/index.ts `homeSays`)
  await d.accounts?.homesReadSoon?.();
  const profiles = d.accounts?.profilesView(viewer) ?? [];
  const built = d.builtAt?.();
  const interrupted = d.hub.interruptedIn?.(viewer);
  return {
    ...(typeof built === "number" && Number.isSafeInteger(built) && built > 0 ? { builtAt: built } : {}),
    ...(interrupted && interrupted.count > 0 ? { interrupted } : {}),
    automaticDecisions: d.accounts ? await decisionsView(d, viewer) : null,
    archiving: archivingView(raw, viewer),
    autoChats: autoChatsView(raw, viewer),
    viewer: { via: "mesh", ...viewer },
    mesh: meshStatus(d.cloud, viewer),
    connects,
    profiles,
    sessionRuntimeChange: true,
    connectRuntimeChange: true,
    accountSubsets: true,
    modelSpeeds: true,
    claudeTui: true,
    // Who made each model its profiles run, and its series, as the model catalog says (accounts/catalog.ts): the
    // clients group and mark models by them, and by the names alone where it says none.
    modelMakers: modelMakers(profiles),
    // What a chat can be kept to less context on (sessions/context-cap.ts): the runtimes that take it, and each model's
    // whole window as the model catalog says it, the most it can be. A station from before says none: none offered.
    contextCaps: { runtimes: CONTEXT_RUNTIMES, least: CONTEXT_LEAST, windows: modelWindows(profiles) },
    processes: processes.map((p) => {
      const kb = memory.get(p.pgid);
      return { ...p, rssMb: kb === undefined ? null : Math.round(kb / 1024) };
    }),
    counts: { sessions: sessionsOf(null), running: states.filter((s) => s === "running").length, warm: states.filter((s) => s === "warm").length },
    slackUsers: d.store.slackIdentities(viewer.email),
    disk: await disk,
    logins: d.accounts?.loginsView(viewer) ?? [],
    apiProviders: d.accounts?.apiProviders() ?? [],
    profileServices: d.accounts?.profileServices?.() ?? [],
    machineLogins: d.accounts?.machineLogins() ?? [],
    // An OpenCode Go profile can be signed in to the OpenCode Console (accounts/console.ts) rather than given a key.
    consoleSignIn: d.accounts !== undefined,
    // It shares profiles and skills with its workspaces' other stations (share/index.ts).
    sharing: d.accounts !== undefined,
    // A profile's stations can follow the workspace's whitelist (share/index.ts `allowAuto`).
    shareAllowAuto: d.accounts !== undefined,
    updates: d.updates?.get(lang) ?? [],
    // The folders pinned in its drive (drive/drive.ts), each with whether it can be browsed now; a member who may write
    // browses every folder from the home (`anywhere`).
    // Those of a joined workspace browse only its pinned folders, never the whole machine.
    // The variables everything it starts for its agents runs with (ops/agent-env.ts): a proxy, mostly.
    agentEnv: agentEnvView(raw),
    // How a session whose prompt cache is over goes on (routes/context.ts): afresh, by itself, when set.
    context: contextView(raw),
    // Whether it sends its log to still.fail (routes/diagnostics.ts).
    diagnostics: diagnosticsView(raw),
    network: networkView(raw),
    drive: { roots: await Promise.all(rootsOf(raw, viewer.home === false ? viewer.workspace : null).map((p) => (d.rootView ?? rootView)(p))), ...(readOnly(viewer) ? {} : { anywhere: true, home: homedir() }) },
    // What its search finds of the machine: its files through Spotlight (macOS) or walked as asked, and
    // whether the person's own mail, messages and the like too.
    search: { files: platform.hasSpotlight ? "spotlight" : "walk", personal: raw?.search?.personal === true },
    // macOS's grants to still.fail Helper (a Mac's station only; a station from before them says none: not shown).
    ...withPermissions(d, viewer),
  };
}

export function modelMakers(profiles: { models?: unknown }[]): Record<string, { maker: string; makerName?: string; family?: string }> {
  const out: Record<string, { maker: string; makerName?: string; family?: string }> = {};
  for (const m of profiles.flatMap((p) => (Array.isArray(p.models) ? p.models : []))) {
    const f = typeof m === "string" && !(m in out) ? facts(m) : null;
    if (f?.maker === undefined) continue;
    out[m] = { maker: f.maker, ...(f.makerName !== undefined ? { makerName: f.makerName } : {}), ...(f.family !== undefined ? { family: f.family } : {}) };
  }
  return out;
}

/// Each model its profiles run (as they spell it) with its context window, as the model catalog says it; those it does
/// not say left out.
export function modelWindows(profiles: { models?: unknown }[]): Record<string, number> {
  const out: Record<string, number> = {};
  for (const m of profiles.flatMap((p) => (Array.isArray(p.models) ? p.models : []))) {
    const window = typeof m === "string" && !(m in out) ? facts(m)?.context : undefined;
    if (window !== undefined && window > 0) out[m as string] = window;
  }
  return out;
}

/// How its chats go to the archive on their own (sessions/lifecycle.ts autoArchive): after so many days idle (0: never),
/// Slack's sessions stopped at a block after theirs, and whether only those the archive review recommended. Everyone
/// sees it (why their chats went); its managers change it (PUT /archiving).
function archivingView(raw: any, viewer: Viewer) {
  const days = (v: unknown, fallback: number) => (typeof v === "number" && Number.isFinite(v) ? Math.max(0, v) : fallback);
  return { days: days(raw?.autoArchiveDays, 1), slackDays: days(raw?.slackArchiveDays, 3), reviewed: raw?.autoArchiveReviewed === true, canEdit: managesStation(viewer) };
}

/// Whether this station is opted into automatic assignment for new chats and presets (`acceptAutoChats`, default false).
/// Everyone sees it; its managers change it (PUT /auto-chats).
function autoChatsView(raw: any, viewer: Viewer) {
  return { enabled: raw?.acceptAutoChats === true, canEdit: managesStation(viewer) };
}

function withPermissions(d: OverviewDeps, viewer: Viewer): { permissions?: unknown } {
  const permissions = d.permissions?.(viewer);
  return permissions === null || permissions === undefined ? {} : { permissions };
}

/// The automatic decisions as the viewer sees them: the checks of their workspace's chats only, and the archive policy of
/// their workspace (one each), which its owners and admins edit (`canEditPolicy`). The rest
/// (the rule, its model) is the station's, its workspaces' managers' alike.
async function decisionsView(d: OverviewDeps, viewer: Viewer): Promise<unknown> {
  // Made again only once a check or the policy is written, the rule or its models change, or DECISIONS_KEPT_MS on (the
  // last days' window moves, a chat is renamed): each making reads the checks of the last days and names their chats.
  const stamp = decisionsStamp(d);
  // Kept by what the view is made of: whether the viewer manages the station, its home flag and its workspace (never
  // who it is, so a workspace's managers share one).
  const manages = viewer.role === "owner" || viewer.role === "admin";
  const whose = `${manages ? "1" : "0"}\0${viewer.home}\0${viewer.workspace ?? ""}`;
  let kept = decisionsKept.get(d.store);
  if (kept === undefined) decisionsKept.set(d.store, (kept = new Map()));
  const was = kept.get(whose);
  if (was !== undefined && was.stamp === stamp && d.store.now() - was.at < DECISIONS_KEPT_MS) return structuredClone(was.view);
  // Overviews that miss it at once (every device told the same change) share the one making under way for this stamp.
  let pending = decisionsPending.get(d.store);
  if (pending === undefined) decisionsPending.set(d.store, (pending = new Map()));
  const making = pending.get(whose);
  if (making !== undefined && making.stamp === stamp) return structuredClone(await making.promise);
  const promise = makeDecisionsView(d, viewer, manages, whose, kept);
  pending.set(whose, { stamp, promise });
  const shared = pending;
  try { return structuredClone(await promise); }
  finally { if (shared.get(whose)?.promise === promise) shared.delete(whose); }
}

function decisionsStamp(d: OverviewDeps): string {
  return JSON.stringify([d.store.decisionsVersion(), d.config()?.automaticDecisions ?? null, d.accounts!.decisionModels()]);
}

/// Makes the decisions' view and keeps it for `whose`, making it again (never waiting on another making) where old data
/// had to be prepared first, the viewer's chats moved or the stamp changed meanwhile.
async function makeDecisionsView(d: OverviewDeps, viewer: Viewer, manages: boolean, whose: string,
  kept: Map<string, { at: number; stamp: string; view: unknown }>): Promise<unknown> {
  const notReady = Symbol("decision sessions not ready");
  for (;;) {
    const stamp = decisionsStamp(d);
    // The policy's checks counted by a reader, before the view is made (none: counted as it is made).
    const checks = manages && d.hub.policyChecks != null ? await d.hub.policyChecks(policySince(d.store.now()), viewer) : null;
    const make = (name: (session: string) => string, visible?: Map<string, boolean>) => {
      try { return madeDecisionsView(d, viewer, name, visible, checks ?? undefined); }
      catch (error) { if (error instanceof DecisionSessionsUnavailable) return notReady; throw error; }
    };
    let view: unknown;
    if (d.hub.prepareSessionChatNames == null) {
      view = make((session) => chatTitleOf(d.store, session));
      if (view === notReady) { await d.store.prepareDecisionSessions(); continue; }
    }
    else {
      // The policy and checks already select the names they show. Collect those names as placeholders while making the
      // view once, prepare them together, and replace only the placeholders after their bounded reads are ready.
      const placeholders = new Map<string, object>();
      const sessions = new WeakMap<object, string>();
      const pendingTitle = (session: string): string => {
        let placeholder = placeholders.get(session);
        if (placeholder === undefined) {
          placeholder = {};
          placeholders.set(session, placeholder);
          sessions.set(placeholder, session);
        }
        return placeholder as unknown as string;
      };
      const visible = new Map<string, boolean>();
      view = make(pendingTitle, visible);
      if (view === notReady) { await d.store.prepareDecisionSessions(); continue; }
      const names = new Map<string, string>();
      let waited = false;
      let moved = false;
      for (;;) {
        const missing: string[] = [];
        names.clear();
        // Read readiness and all names in one snapshot; a writer cannot make a name fall back to the old scan between
        // the readiness check and sessionChat(). Do not hold a database snapshot while waiting for the worker.
        d.store.db.exec("SAVEPOINT overview_chat_names"); // deferred: only reads (names and readiness)
        try {
          if (waited) for (const [session, was] of visible) {
            if (sees(viewer, d.store.sessionWs(session) ?? null) !== was) { moved = true; break; }
          }
          if (!moved) for (const session of placeholders.keys()) {
            // A historical check can name a session deleted while the worker was preparing it. It has no scope to
            // prepare; retain the original title fallback rather than waiting for that scope forever.
            if (d.store.getSession(session) === null) names.set(session, chatTitleOf(d.store, session));
            else if (!sessionChatReadable(d.store.db, session)) missing.push(session);
            else names.set(session, chatTitleOf(d.store, session));
          }
        } finally { d.store.db.exec("RELEASE overview_chat_names"); }
        if (moved || missing.length === 0) break;
        await d.hub.prepareSessionChatNames(missing);
        waited = true;
      }
      if (moved) continue;
      const fill = (value: any): any => {
        if (value === null || typeof value !== "object") return value;
        const session = sessions.get(value);
        if (session !== undefined) return names.get(session)!;
        if (Array.isArray(value)) return value.map(fill);
        for (const key of Object.keys(value)) value[key] = fill(value[key]);
        return value;
      };
      view = fill(view);
      // Checks or policy may have changed during old-data preparation. Build their view again instead of caching an
      // obsolete selection with the old stamp.
      if (decisionsStamp(d) !== stamp) continue;
    }
    kept.set(whose, { at: d.store.now(), stamp, view: structuredClone(view) });
    return view;
  }
}

/// How long the automatic decisions are kept as they were made at most (decisionsView).
const DECISIONS_KEPT_MS = 60_000;
const decisionsKept = new WeakMap<object, Map<string, { at: number; stamp: string; view: unknown }>>();
/// The making of each kept view under way, with the stamp it was started at (decisionsView).
const decisionsPending = new WeakMap<object, Map<string, { stamp: string; promise: Promise<unknown> }>>();

function madeDecisionsView(d: OverviewDeps, viewer: Viewer, name: (session: string) => string,
  visible = new Map<string, boolean>(), checks?: PolicyChecks): unknown {
  const mine = (session: unknown) => {
    if (typeof session !== "string") return false;
    let isMine = visible.get(session);
    if (isMine === undefined) visible.set(session, (isMine = sees(viewer, d.store.sessionWs(session) ?? null)));
    return isMine;
  };
  const titles = new Map<string, string>();
  const title = (session: string) => {
    let named = titles.get(session);
    if (named === undefined) titles.set(session, (named = name(session)));
    return named;
  };
  const view = d.accounts!.automaticDecisionsView(viewer, { includePolicy: false, visible: mine, title });
  const manages = viewer.role === "owner" || viewer.role === "admin";
  if (manages) {
    view.policy = policyView(d.store, viewer.home === false ? viewer.workspace : null, mine, title, viewer, checks);
    view.canEditPolicy = manages;
  }
  return view;
}

/// What a session's chat is called in the chat list; its key only where it has no chat.
function chatTitleOf(store: Store, session: string): string {
  const chat = store.sessionChat(session);
  if (chat) return titleOf(chat.thread, chat.firstText, null);
  return store.getSession(session)?.title ?? session;
}
