// The station's accounts: its profiles as the pages edit them, their checks and
// allowances, sign-ins, profiles on the machine's own login, the machine login's renewed token, and the models the
// automatic decisions may use (the Rust station's admin/edits.rs and decision.rs, the profile parts of admin/mod.rs and
// views.rs, and what server.rs wires for them).
//
// What changes is pushed: `onChange` hears each change the overview shows (a check, an allowance, a sign-in, the
// machine's logins); config.json's own changes are the ConfigFile's to tell. Kept on a timer only where nothing says
// when it changed:
// - allowances: every 5 minutes, while someone follows the events or a turn runs (`following`); the providers do not
//   tell when an allowance moves, and the pool picks by them. `followed()` asks the stale ones at once when the first
//   follower comes.
// - every profile checked 3 s after start (what changed while the station was off: keys revoked, logins expired).
// - the machine's logins: read again when the overview is read with a reading over 2 minutes old (machine.ts).
// - a sign-in times out after 15 minutes; a finished sign-in for a new profile is kept 15 minutes for its page.
// - an OpenCode Go profile signed in to the OpenCode Console: its token renewed some days before it runs out, looked at
//   shortly after start and every few hours (console.ts).
// - a Kimi Code profile signed in to Kimi: its token (minutes) renewed with half its life left, looked at every minute
//   (kimi.ts).
import { shareRefusal } from "../share/index.ts";
import { HERMES_MODEL_LIMIT } from "../agents/hermes.ts";
import { agyAccountFile, agyCompany, agyEmailIn, agyToken, classifyFailure as agyClassifyFailure, type AgyCatalog } from "../agents/agy.ts";
import { expandDevinFusion } from "../agents/devin.ts";
import { runtimeKind, runtimeLabel } from "../agents/runtime.ts";
import type { Clock } from "effect";
import { createHash, randomBytes } from "node:crypto";
import { access as accessFile, mkdir, readdir, readFile, rename, rm, stat } from "node:fs/promises";
import { hostname } from "node:os";
import { join } from "node:path";
import type { Env, MachineToken } from "../agents/machine-logins.ts";
import { linkCodexAuthSoon } from "../agents/machine-logins.ts";
import { type AccessKind, accessKind, KIMI_CODE, kimiSignedIn, profileVia, type Runtime, takesFast, fastNeedsCredits, type Via } from "../agents/profiles.ts";
import { cleanEndpoint, endpoints, find, groupOf, LEGACY, SOURCES } from "../agents/providers.ts";
import { type Viewer, managesStation } from "../mesh/credential.ts";
import { maskValue, startEnv } from "../ops/agent-env.ts";
import type { ConfigFile } from "../ops/config.ts";
import { type Lang, stationLang, tr } from "../ops/i18n.ts";
import { log } from "../ops/log.ts";
import { allowedIn, hubConfig, type HubConfig, type Profile } from "../sessions/config.ts";
import { type Capability, discover as discoverDecisions, fingerprint, resolvedModel } from "../sessions/decision.ts";
import { type ProfileHealth, serves, usable } from "../sessions/pool.ts";
import type { Store } from "../store/store.ts";
import { paceView, type PaceView } from "./pace.ts";
import { HOUR_MS, PACE_HOURS, SPEED_QUARTER_HOURS, type QuotaHour, type SpeedQuarter, type SpendHour } from "../store/profile-hours.ts";
import { joinPath } from "../ops/paths.ts";
import { modelName } from "../ops/model-name.ts";
import { titleOf } from "../read/views.ts";
import { LEGACY_OPTIONS, policyFrom, savePolicy } from "../sessions/archive-policy.ts";
import { Fibers, wall } from "../ops/fibers.ts";
import { checkAutomaticDecisions } from "./check.ts";
import { CONSOLE_FILE, type ConsoleLogin, consoleIn, readConsole, RenewRefused, renewToken, writeConsole } from "./console.ts";
import { CURSOR, authFile as cursorAuthFile, cursorIn } from "./cursor.ts";
import { KIMI_AUTH, kimiDue, readKimi, renewKimiToken, writeKimi } from "./kimi.ts";
import { LOGIN_BROWSER_FILE, type LoginCommands, type LoginJob, LoginManager } from "./login.ts";
import { codexAccountIdentity, codexClaimsIn, type MachineLogin, MachineLogins } from "./machine.ts";
import { facts } from "./catalog.ts";
import { uncheckOutdated } from "./models.ts";
import { type Bound, LEND_BOUND_MS, claudeOAuthToken } from "./oauth.ts";
import { accessKinds, checkProfile, devinAccountFile, devinNotedIn, grokAuthFile, grokEmailIn, keyed, loginCommand, needsKey, type ProfileCheck, type ProfileQuota, runtimesFor, runtimesOf, URLS, type Urls } from "./profiles.ts";
import { checkQuota, codexUsage, lentCodexUsage, machineUsage } from "./quota.ts";
import { claudeResetWith } from "./claude-reset.ts";
import { DEFAULT_SERVICES, serviceOf, type ServiceRegistry } from "./services.ts";
import { Refused as Refusal } from "../api/request.ts";

/// How long GET /profiles/pace goes on the last two hours' spending read again each minute before it reads all
/// PACE_HOURS of the spending and the allowances again: what lands in an older hour (the calls from before taken in,
/// usagefill; a home workspace's moved, usage-15m.ts moveUsage15m; a call written late) and what another process wrote
/// (the station before, in a handover) show by then.
const SPEND_FULL_REFRESH_MS = 15 * 60_000;
/// By profile, then hour, as the store's reads give them (store/profile-hours.ts); a stable sort keeps each hour's in theirs.
const byProfileHour = (a: { profile: string; hour: number }, b: { profile: string; hour: number }): number =>
  (a.profile < b.profile ? -1 : a.profile > b.profile ? 1 : 0) || a.hour - b.hour;

export { checkConfig } from "./check.ts";
export { LOGIN_BROWSER_FILE };
export type { LoginJob, MachineLogin, ProfileCheck, ProfileQuota };

type Json = any;

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

/// How often allowances are asked again while someone follows.
const QUOTA_EVERY_MS = 5 * 60_000;
/// How long an allowance read stands while its provider gives no answer (six rounds): past it the failure is said, so
/// a station long off the network says that, not an allowance of hours ago (the user, 2026-11-11).
const QUOTA_STANDS_MS = 30 * 60_000;
/// How long a borrowed subscription's previous `ok` check stands while its host does not answer (e.g. during a host
/// handover or transient drop), before background checks mark it failed.
const BORROWED_HOST_STANDS_MS = 10 * 60_000;
/// A Claude token handed to a process (or lent to another station) that cannot renew it is renewed first when it would
/// last less than this, so it is not swapped soon after.
const HANDED_MARGIN_MS = 3600_000;
const CHECK_ON_START_MS = 3_000;
/// How long what a profile's home says (`HomeSays`) is shown as last read before it is read again (off the thread).
const HOMES_EVERY_MS = 10_000;
/// An OpenCode Console token (30 days) is renewed when it has less than this left, looked at this often: renewing ends
/// the token the runtimes were given, so it is done seldom, long before it would run out.
const CONSOLE_RENEW_BEFORE_MS = 7 * 86_400_000;
const CONSOLE_RENEW_EVERY_MS = 6 * 3600_000;
/// How often the Kimi Code sign-ins' tokens (minutes) are looked at (kimi.ts kimiDue says which to renew).
const KIMI_RENEW_EVERY_MS = 60_000;
const PENDING_KEPT_MS = 15 * 60_000;
/// Default active-session cap automatically applied to newly signed-in subscription profiles.
export const DEFAULT_NEW_SUBSCRIPTION_MAX_CONCURRENT_SESSIONS = 8;
/// The checks the policy page counts: of the last days, and the chats it names for each option at most.
const POLICY_DAYS = 7;
const POLICY_CHATS = 20;

/// What the pages are refused, and with which status (admin/mod.rs `http_error`): the routes' own.
export { Refusal };

/// What a check is asked: the account and where it signs in (its home, or a trial one for a key being tried).
export type CheckRequest = { runtime?: Runtime; kind: AccessKind; key: string; via: Via; service?: string; profile?: Profile; home: string; machine: boolean; login?: boolean; recheck?: boolean };

/// The subscription runtimes whose allowance is read (quota.ts): a login of theirs still good answers it.
const QUOTA_RUNTIMES: readonly (Runtime | undefined)[] = ["claude", "codex", "agy", "cursor", "grok"];

/// A subscription's login found over here, for the workspace's managers to sign it in again (`station`: the station
/// whose login it is, a borrowed one's host).
export type LoginLost = { id: string; profile: Profile; station: string | null };

/// The profile's codex app-server, for what only it says (the agents' CodexDriver: rateLimits, resetQuota, models).
export type CodexAccess = {
  rateLimits(profile: Profile): Promise<Json>;
  resetQuota(profile: Profile, key: string): Promise<Json>;
  models(profile: Profile): Promise<{ models: string[]; efforts: Map<string, string[]>; defaults?: Map<string, string>; ultrafastModels?: string[] }>;
  loginChanged?(profileId: string): Promise<void>;
};

export type AccountsDeps = {
  data: string;
  store: Store;
  config: ConfigFile;
  /// The hub, whose account pool picks profiles by their checks and allowances (and knows which ran out lately).
  /// Starts reviewing the done chats no decision has answered (review.ts): how many, or null without a usable model.
  reviewUndecided?: () => number | null | Promise<number | null>;
  hub?: {
    accounts: { setHealth(health: (id: string) => ProfileHealth): void; healthOf(id: string): ProfileHealth; setRecheck?(recheck: (id: string, force?: boolean) => Promise<unknown>): void; setQuotaAgain?(read: (id: string) => Promise<unknown>): void };
    /// A profile was deleted: its sessions are taken on by another, or stopped.
    profileGone?(id: string): Promise<void>;
    /// A manual reset lets sessions waiting on this account continue.
    allowanceReset?(id: string): void | Promise<void>;
    /// A profile signed in anew (here, or on the station it is borrowed from): its sessions' processes, which keep the
    /// sign-in they started with, are started again (an idle one now, a busy one once its turn is over).
    profileLoginChanged?(id: string): void | Promise<void>;
  };
  /// The codex driver, once there.
  codex?: () => CodexAccess | undefined;
  /// Hermes reports its configured providers and model IDs in ACP session/new (no model turn).
  hermes?: () => { models(profile: Profile): Promise<string[]> } | undefined;
  /// The Antigravity CLI says whether it is signed in, and the models it offers, in ACP session/new (no model turn).
  agy?: () => { models(profile: Profile): Promise<string[]>; catalog?(profile: Profile): Promise<AgyCatalog> } | undefined;
  /// Copilot's SDK lists every model its GitHub account may use (agents/copilot.ts).
  copilot?: () => { models(profile: Profile): Promise<string[]> } | undefined;
  /// Whether someone follows the events or a turn runs (allowances are asked again on a round only then).
  following?: () => boolean;
  /// The station's environment (where the machine's logins are, and the CLIs found); process.env by default.
  env?: Env;
  /// The installed Claude Code's version (updates.ts), which a Claude subscription's limit resets are asked as.
  claudeVersion?: () => string | null;
  loginCommands?: LoginCommands;
  urls?: Urls;
  /// Tests: how a profile is checked, its allowance read (null: nobody can ask), its reset asked, its decisions found.
  check?: (request: CheckRequest, lang: Lang) => Promise<ProfileCheck>;
  quota?: ((profile: Profile) => Promise<ProfileQuota>) | null;
  resetQuota?: ((profile: Profile, key: string, kind: string | null) => Promise<Json>) | null;
  discover?: (profile: Profile, check: ProfileCheck) => Promise<Capability>;
  /// The machine's logins (null: none to read); read in `env` with their allowances by default.
  machine?: MachineLogins | null;
  /// Check every profile shortly after start (the real station; tests leave it off).
  checkOnStart?: boolean;
  /// Its time (a TestClock in tests).
  clock?: Clock.Clock;
  /// The workspaces the station is in, its home one first; none by default.
  workspaces?: () => string[];
  /// Service profile adapters for non-agent-runtime accounts (`access.kind === "service"`).
  services?: ServiceRegistry;
  /// A subscription's login newly found over (one that had signed in, or a runtime was refused on): the workspace's
  /// managers are told to sign it in again (cloud/notify.ts `notifyProfileLogin`). A borrowed one's only where its host
  /// did not say so itself (a host from before, or one not answering), as the host tells its own.
  loginLost?: (lost: LoginLost) => void;
  /// Its login good again (signed in anew, or checked so): told again at once the next time it is over.
  loginBack?: (id: string) => void;
  /// Profiles other stations share with this one (share/index.ts): how they are doing is their host's to say, and
  /// what the overview says of each profile's sharing. `recheck`: its host asks its provider again first.
  shared?: {
    status(profile: Profile, recheck?: boolean): Promise<{ check: Json; quota: Json }>;
    /// `workspace`: the viewer's, whose stations alone it names (null: all).
    view(profile: Json, workspace: string | null): Json | null;
    lendCodex?(profile: Profile, rejected: boolean): Promise<number>;
    /// A borrowed Antigravity CLI subscription's sign-in written with what its host lends now.
    lendAgy?(profile: Profile, rejected: boolean): Promise<number>;
    quotaReset?(profile: Profile, key: string): Promise<void>;
    /// A borrowed Claude subscription's token, lent by its host (to use one of its resets with).
    lendClaude?(profile: Profile, rejected?: string): Promise<MachineToken>;
    /// A sign-in changed here: its copies on other stations are told (`profileId`: a profile signed in anew).
    loginUpdated?(profileId?: string): void;
    /// Whether the station the profile is another's of did not answer lately.
    hostName?(profile: Json): string | null;
  };
};

/// A sign-in with no profile yet: its runtime, its home while signing in, who started it, what it made.
/// `access`: an OpenCode Go profile signed in to the OpenCode Console, or a Kimi Code one to Kimi (absent: the runtime's
/// subscription).
type Pending = { runtime?: Runtime; service?: string; access?: "opencode-go" | "kimi-code" | "agy-enterprise"; home: string; by: Viewer; created: string | null; error: string | null };

const isObject = (v: unknown): v is Record<string, any> => v !== null && typeof v === "object" && !Array.isArray(v);
const manages = managesStation;
const runtimeOf = (v: unknown): Runtime | undefined => runtimeKind(v);
const ACCESS_KINDS: AccessKind[] = ["subscription", "opencode-go", "anthropic-api", "env", "api-provider", "service"];
const accessKindOf = (v: unknown): AccessKind | undefined => (ACCESS_KINDS.includes(v as AccessKind) ? (v as AccessKind) : undefined);
/// admin/mod.rs Input::text: JavaScript's String(x ?? "").
const text = (v: unknown) => (v === undefined || v === null ? "" : typeof v === "string" ? v : JSON.stringify(v));
const named = (runtime: Runtime) => runtimeLabel(runtime);
/// A copy of a profile another station shares (share/index.ts): edited, checked and signed in only there.
export const borrowed = (p: Json): boolean => isObject(p?.share) && p.share.borrowed === true;

/// Which login a borrowed Codex process will read, without keeping its tokens in memory or logs.
async function lentLoginVersion(home: string): Promise<string | null> {
  try {
    const tokens = JSON.parse(await readFile(join(home, "auth.json"), "utf8"))?.tokens;
    return createHash("sha256").update(JSON.stringify([tokens?.id_token, tokens?.access_token, tokens?.account_id])).digest("hex");
  } catch {
    return null;
  }
}

/// What a profile's home says, as the overview shows it: whether it is there, and whose account its files say (a
/// subscription's, or a console sign-in's).
type HomeSays = { exists: boolean; email: string | null };

/// What a profile's home is read for: the home, and what in it says whose account it is.
function homeAsked(p: Json): { home: string; runtime?: Runtime; service?: string; files: "account" | "console" | "service" | null } {
  const kind = accessKind(p);
  const service = serviceOf(p);
  const files =
    kind === "service"
      ? (service !== undefined ? "service" : null)
      : kind === "subscription"
        ? (borrowed(p) ? null : "account")
        : isObject(p.access) && p.access.login === true
          ? "console"
          : null;
  return {
    home: String(p.home ?? ""),
    ...(p.runtime !== undefined ? { runtime: p.runtime } : {}),
    ...(service !== undefined ? { service } : {}),
    files,
  };
}

/// `homeAsked`'s answer, read off the thread (fs/promises).
async function homeSaysSoon(p: Json, services: ServiceRegistry = DEFAULT_SERVICES): Promise<HomeSays> {
  const { home, runtime, service, files } = homeAsked(p);
  const email =
    files === "account" && runtime !== undefined
      ? await accountEmailSoon(runtime, home)
      : files === "console"
        ? await emailInSoon([consoleFile(home)])
        : files === "service" && service !== undefined
          ? ((await services.get(service)?.identity(home)) ?? null)
          : null;
  return { exists: await accessFile(home).then(() => true, () => false), email };
}

export class Accounts {
  readonly logins: LoginManager;
  readonly machine: MachineLogins | null;
  private checks = new Map<string, ProfileCheck>();
  private quotas = new Map<string, ProfileQuota>();
  private quotaBusy = new Map<string, Promise<void>>();
  /// The checks devices asked that are under way, by what was asked (`askedCheck`).
  private checksAsked = new Map<string, Promise<ProfileCheck>>();
  /// The profiles whose allowance was last asked without an answer while the one read before stood: what was said of
  /// it (told to a person who asks it again: askedQuota) and when (it is not asked again before the next round).
  private quotaUnanswered = new Map<string, { detail: string; at: number }>();
  /// A host on an older version may know the reset count but not the cards' expiries. Try the borrowed login at most
  /// once a round for the same count, including when the provider cannot supply all of the details.
  private resetDetailsAsked = new Map<string, { at: number; count: number }>();
  /// A quota read started before a Codex sign-in must not replace the new login's status.
  private loginGeneration = new Map<string, number>();
  /// The last changed borrowed login whose app-servers were told to reload it.
  private borrowedLogin = new Map<string, string | null>();
  /// Logins a runtime was refused on and a recheck found over (FB-44), with what is said and the allowance's `checkedAt`
  /// then: kept signed out through checks that say otherwise (a borrowed one's host from before answers what it had)
  /// until it signs in anew, its share changes, or an allowance read after says it works.
  private authRevoked = new Map<string, { detail: string; quota: ProfileQuota | undefined; quotaAt: number }>();
  /// OpenCode Console and Kimi tokens being renewed, by profile (a refresh token is spent once).
  private renewing = new Map<string, Promise<void>>();
  /// The sign-ins for new profiles being settled (pendingChanged), by id: whether it was told again meanwhile.
  private settling = new Map<string, boolean>();
  private pending = new Map<string, Pending>();
  /// Ids of profiles being made (their home moved or linked, not yet saved): taken, as a saved one's.
  private readonly making = new Set<string>();
  /// Which Codex account each Codex subscription profile is signed in to, as its auth.json last said (read off the
  /// thread: `codexAccountRead`), and the reads under way.
  private readonly codexAccounts = new Map<string, { home: string; account: string | null }>();
  private readonly codexAccountReads = new Map<string, { home: string; read: Promise<void> }>();
  private borrowedUnreachableSince = new Map<string, number>();
  /// What each profile's home said when last read (`HomeSays`), by profile, with what it was read for: the overview is
  /// made again at each change for each viewer, and read every profile's files on the thread each time (a few dozen
  /// calls; seconds on a machine short of memory). Read again off the thread as it is made, at most every
  /// HOMES_EVERY_MS, and as a sign-in ends.
  private homes = new Map<string, { asked: string; says: HomeSays }>();
  private homesRead = 0;
  private homesReading = false;
  /// The reads of a home under way, by profile and what it is read for: begun at `since` (`homesChanged`), and whether
  /// what it finds is to be told (one asked by a view that showed nothing yet).
  private readonly homeReads = new Map<string, { since: number; tell: boolean; read: Promise<void> }>();
  /// Closed: nothing read after is told.
  private closed = false;
  /// Bumped as a sign-in changes what a home says: a reading begun before is not kept.
  private homesChanged = 0;
  private listeners = new Set<() => void>();
  private background: Fibers;
  private stops: (() => void)[] = [];
  private readonly urls: Urls;
  private readonly services: ServiceRegistry;
  private readonly checkFn: (request: CheckRequest, lang: Lang) => Promise<ProfileCheck>;
  private readonly quotaFn: ((profile: Profile) => Promise<ProfileQuota>) | null;
  private readonly resetFn: ((profile: Profile, key: string, kind: string | null) => Promise<Json>) | null;
  private readonly discoverFn: (profile: Profile, check: ProfileCheck) => Promise<Capability>;

  private deps: AccountsDeps;

  /// The station's environment with the variables set for what it starts for its agents (ops/agent-env.ts): the CLIs
  /// it checks profiles with run in it.
  private get env(): Env {
    return this.deps.env ?? (startEnv() as Env);
  }

  constructor(deps: AccountsDeps) {
    this.deps = deps;
    this.background = new Fibers("accounts", deps.clock);
    this.urls = deps.urls ?? URLS;
    this.services = deps.services ?? DEFAULT_SERVICES;
    // A Cursor sign-in's key is named for this machine in the person's Cursor dashboard (accounts/cursor.ts).
    this.logins = new LoginManager(deps.data, deps.loginCommands, undefined, deps.clock, this.urls.console, this.urls.cursor ?? CURSOR, () => `still.fail · ${hostname()}`, this.urls.kimi ?? KIMI_AUTH);
    this.logins.setStateFile((id) => this.loginStateFile(id));
    this.machine =
      deps.machine !== undefined ? deps.machine : new MachineLogins(this.env, (runtime, env) => machineUsage(runtime, env, this.urls, undefined, deps.claudeVersion?.() ?? null), undefined, deps.clock);
    this.checkFn =
      deps.check ?? ((request, lang) => checkProfile({ ...request, services: this.services, env: this.env, machineToken: (env, rejected) => this.machineToken(env, rejected), urls: this.urls, lang, claudeVersion: deps.claudeVersion?.() ?? null }));
    this.quotaFn =
      deps.quota !== undefined
        ? deps.quota
        : (profile) => {
            const codex = deps.codex?.();
            return checkQuota(profile, this.env, codex ? (p) => codex.rateLimits(p) : undefined, this.urls, stationLang(), deps.claudeVersion?.() ?? null, this.services);
          };
    this.resetFn =
      deps.resetQuota !== undefined
        ? deps.resetQuota
        : (profile, key, kind) => {
            if (profile.runtime === "claude") return this.claudeReset(profile, key, kind);
            const codex = deps.codex?.();
            if (!codex) throw new Refusal(503, tr(stationLang(), "station.quota.resetUnsupported"));
            return codex.resetQuota(profile, key);
          };
    this.discoverFn = deps.discover ?? ((profile, check) => discoverDecisions(profile, check, this.background.clock));
    // What the last run learned about profiles shows until they are checked again.
    for (const [id, status] of deps.store.profileStatus()) {
      if (isObject(status.check)) {
        this.checks.set(id, status.check as ProfileCheck);
        this.checksChanged++;
      }
      if (isObject(status.quota)) this.quotas.set(id, status.quota as ProfileQuota);
    }
  }

  /// Starts what runs on its own: the pool told of profiles' health, the outdated models unchecked, sign-ins
  /// followed, the checks after start, the allowance rounds, the machine's logins read.
  start() {
    this.deps.hub?.accounts.setHealth((id) => this.health(id));
    // (which Codex account each is on, for the pool's first picks)
    void this.codexAccountsRead().catch(() => {});
    this.deps.hub?.accounts.setRecheck?.((id, force) => this.recheckProfile(id, force === true));
    // Asked after a turn failed for no reason its words gave: the one on its way waited for, else a new one.
    this.deps.hub?.accounts.setQuotaAgain?.(async (id) => {
      const busy = this.quotaBusy.get(id);
      if (busy) await busy;
      else await this.readQuota(id, false);
    });
    this.#unchecking = this.uncheckOutdated().catch(() => {});
    // A finished sign-in changes what the profile can do; it is checked again right away.
    this.stops.push(
      this.logins.changes((id) => {
        // What its home says, read anew at the next view.
        this.homes.delete(id);
        this.homesChanged++;
        const pending = this.pending.has(id);
        const job = this.logins.get(id);
        this.changed();
        if (pending) this.background.spawn(() => this.pendingChanged(id));
        else if (job?.state === "done")
          this.background.spawn(async () => {
            // An OpenCode sign-in of a profile there is: its token is its key from now on, before it is checked.
            if (job.provider === "opencode" && (await this.signedInConsole(id, job.startedAt))) this.changed();
            this.afterSignIn(id);
          });
      }),
    );
    if (this.machine) {
      // A profile on the machine's login is as that login is: one signed in, out or to another account in a terminal is
      // checked again, so its last check (signed out, say) does not outlive the login it was of. The first reading
      // after start is the start's checks'.
      const said = (runtime: string) => JSON.stringify(this.machine!.get().filter((l) => l.runtime === runtime).map((l) => [l.loggedIn, l.email, l.plan, l.usable]));
      let last: Map<string, string> | null = null;
      this.stops.push(
        this.machine.changes(() => {
          this.changed();
          const before = last;
          last = new Map(["claude", "codex"].map((r) => [r, said(r)]));
          // The first reading can arrive after sharing starts; its identity and later sign-ins must reach borrowers.
          if (before === null || [...last].some(([runtime, value]) => before.get(runtime) !== value)) this.deps.shared?.loginUpdated?.();
          if (before === null) {
            // The first reading can finish after a start-up check. If it knows a more specific tier, recheck that
            // profile so its view and any borrowed copy get the machine login's tier.
            for (const p of this.profiles()) {
              if (p.machine !== true) continue;
              const check = this.checks.get(p.id);
              const login = this.machine!.get().find((l) => l.runtime === p.runtime && l.loggedIn);
              if (check?.state === "ok" && login?.plan && check.plan !== login.plan) this.afterSignIn(p.id);
            }
            return;
          }
          for (const p of this.profiles()) if (p.machine === true && p.runtime !== undefined && before.get(p.runtime) !== last.get(p.runtime)) this.afterSignIn(p.id);
        }),
      );
      this.background.spawn(() => this.machine!.refresh());
    }
    if (this.deps.checkOnStart !== false) {
      this.background.after(CHECK_ON_START_MS, () => {
        for (const p of this.profiles()) if (p.enabled !== false) this.background.spawn(() => this.check(p.id, stationLang(), false, true));
        this.renewConsoles();
      });
    }
    this.background.every(CONSOLE_RENEW_EVERY_MS, () => this.renewConsoles());
    this.background.every(KIMI_RENEW_EVERY_MS, () => this.renewKimis());
    this.background.every(QUOTA_EVERY_MS, () => {
      if (this.deps.following?.() === true) this.refreshQuotas(false);
    });
  }

  async close() {
    this.closed = true;
    for (const stop of this.stops.splice(0)) stop();
    await this.logins.close();
    await this.background.close();
    await this.#unchecking;
  }

  /// Hears each change the overview shows of the accounts; gives the function that stops it.
  onChange(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private changed() {
    for (const listener of this.listeners) {
      try {
        listener();
      } catch (e) {
        log.warn("accounts", "an accounts listener failed", { error: (e as Error).message });
      }
    }
  }

  /// config.json as the hub reads it (parse_config), each profile running the models its check found. Made again only
  /// when the config or a check changed: health, decisionModels, the hub's settings and the overview ask it for every
  /// profile of every viewer, and parsing the config each time held the main thread for seconds on a station of many
  /// profiles and devices.
  settings(): HubConfig {
    const raw = this.deps.config.raw();
    const made = this.settingsMade;
    if (made !== null && made.raw === raw && made.checks === this.checksChanged) return made.settings;
    const settings = hubConfig(raw, this.deps.data, this.found);
    this.settingsMade = { raw, checks: this.checksChanged, settings };
    return settings;
  }
  private settingsMade: { raw: unknown; checks: number; settings: HubConfig } | null = null;

  /// The profiles as the config has them now (`settings`).
  profiles(): Profile[] {
    return this.settings().profiles;
  }
  /// Counts the changes of `checks` (what `found` reads), for `profiles`.
  private checksChanged = 0;

  /// The models profile `id`'s last check found (null: none listed), which it runs besides those config.json names.
  readonly found = (id: string): readonly string[] | null => this.checks.get(id)?.models ?? null;

  private profile(id: string): Profile | undefined {
    return this.profiles().find((p) => p.id === id);
  }

  /// How a profile is doing, for the pool: its last check and allowance, and which Codex account the allowance is of.
  health(id: string): ProfileHealth {
    const profile = this.profile(id);
    const account = profile?.runtime === "codex" && accessKind(profile) === "subscription" ? this.codexAccount(profile) : null;
    return { check: this.checks.get(id) ?? null, quota: this.quotas.get(id) ?? null, ...(account === null ? {} : { account: `codex:${account}` }) };
  }

  /// Which Codex account `profile` is signed in to, as last read; read again off the thread for the next ask (a login
  /// changed under it), the pool's picks never waiting on its file. Not read yet: none said (`codexAccountsRead`).
  private codexAccount(profile: Profile): string | null {
    void this.codexAccountRead(profile);
    const kept = this.codexAccounts.get(profile.id);
    return kept?.home === profile.home ? kept.account : null;
  }

  /// `again`: its login just changed, so one read under way may have read the file before: a read after it, kept last.
  private codexAccountRead(profile: Profile, again = false): Promise<void> {
    const under = this.codexAccountReads.get(profile.id);
    if (under && !again && under.home === profile.home) return under.read;
    const read: Promise<void> = (under?.read ?? Promise.resolve())
      .catch(() => {})
      .then(() => codexAccountIdentity(profile.home))
      .then((account) => void this.codexAccounts.set(profile.id, { home: profile.home, account }))
      .finally(() => {
        if (this.codexAccountReads.get(profile.id)?.read === read) this.codexAccountReads.delete(profile.id);
      });
    this.codexAccountReads.set(profile.id, { home: profile.home, read });
    return read;
  }

  /// Every Codex subscription profile's account read again (the station starting; a test after it changed one).
  async codexAccountsRead(): Promise<void> {
    const codex = this.profiles().filter((p) => p.runtime === "codex" && accessKind(p) === "subscription");
    await Promise.all(codex.map((p) => this.codexAccountRead(p, true)));
  }

  /// How a profile is doing, told to a station borrowing it: its allowance asked again first when older than a round
  /// (the rounds run only while someone follows this station, and the borrower is not someone).
  /// `recheck`: the borrower was refused on it, so it is asked of its provider again first (`recheckProfile`).
  async lentHealth(id: string, recheck = false): Promise<ProfileHealth> {
    if (recheck) {
      await this.recheckProfile(id).catch(() => {});
      return this.health(id);
    }
    if (!this.quotas.has(id) || this.background.now() - this.quotaAskedAt(id) >= QUOTA_EVERY_MS) await this.refreshQuota(id).catch(() => null);
    return this.health(id);
  }

  /// The machine login's current Claude token, renewed when about to run out (the Claude driver's `machineToken`).
  async machineToken(env: Env = this.env, rejected?: string, lent = false): Promise<MachineToken> {
    const [token, expiresAt] = await claudeOAuthToken(env, null, rejected ?? null, this.urls.claudeToken, stationLang(), HANDED_MARGIN_MS, lent ? this.lendBound() : undefined, this.deps.claudeVersion?.() ?? null);
    return { token, expiresAt };
  }

  /// A Claude profile's current token, renewed when about to run out: handed to its local sessions (`subscriptionToken`)
  /// and lent when another station shares it (`lent`: its renewal waited for LEND_BOUND_MS at most, then the token it has
  /// is lent while it lasts the usual margin, the renewal going on behind).
  async claudeToken(profile: Json, rejected?: string, lent = false): Promise<MachineToken> {
    if (profile.machine === true) return this.machineToken(this.env, rejected, lent);
    const home = String(profile.home ?? "");
    const [token, expiresAt] = await claudeOAuthToken(this.env, joinPath(this.deps.data, home), rejected ?? null, this.urls.claudeToken, stationLang(), HANDED_MARGIN_MS, lent ? this.lendBound() : undefined, this.deps.claudeVersion?.() ?? null);
    return { token, expiresAt };
  }

  private lendBound(): Bound {
    return { ms: LEND_BOUND_MS, after: (ms, f) => this.background.after(ms, f) };
  }

  /// One of a Claude subscription's limit resets used (claude-reset.ts), with its token (a borrowed one's lent by its
  /// host), renewed and asked again once when the provider says it is not good.
  private async claudeReset(profile: Profile, key: string, kind: string | null): Promise<Json> {
    const version = this.deps.claudeVersion?.() ?? null;
    if (version === null) throw new Refusal(503, tr(stationLang(), "station.quota.resetUnsupported"));
    const token = (rejected?: string) => {
      if (!borrowed(profile)) return this.claudeToken(profile, rejected);
      if (!this.deps.shared?.lendClaude) throw new Refusal(503, tr(stationLang(), "station.quota.resetUnsupported"));
      return this.deps.shared.lendClaude(profile, rejected);
    };
    const first = await token();
    const result = await claudeResetWith(this.urls.anthropic, first.token, version, key, kind);
    if (result?.unauthorized !== true) return result;
    const renewed = await token(first.token);
    const again = await claudeResetWith(this.urls.anthropic, renewed.token, version, key, kind);
    if (again?.unauthorized === true) throw new Refusal(502, tr(stationLang(), "station.quota.signInExpired"));
    return again;
  }

  /// Refused for a copy of another station's profile: it is changed there.
  private own(id: string, lang: Lang) {
    const p = this.rawProfile(id);
    if (p && borrowed(p)) throw new Refusal(409, tr(lang, "station.share.borrowedEdit"));
  }

  /// Profile `id` as config.json has it (undefined: none).
  private rawProfile(id: string): Json | undefined {
    return (Array.isArray(this.deps.config.raw()?.profiles) ? this.deps.config.raw().profiles : []).find((x: Json) => x?.id === id);
  }

  // ── edits ──

  /// Edits config.json (refused as 400 when the result does not pass), said in the log as `what`.
  private async save(viewer: Viewer, what: string, edit: (raw: Json) => void): Promise<void> {
    try {
      await this.deps.config.updateSoon(edit);
    } catch (e) {
      throw new Refusal(400, (e as Error).message);
    }
    log.info("accounts", "config changed from the admin page", { what, by: viewer.email });
  }

  /// PUT /profiles/:id: a profile made or edited. Its new state is checked after (in the background). `workspaces`: the
  /// joined workspaces whose sessions may run on it ([] or null: the home one's only), set by
  /// those who manage the station only; kept as those of the station's joined workspaces withheld from it, so one it
  /// joins later runs on it too.
  async putProfile(id: string, given: Record<string, unknown>, viewer: Viewer, lang: Lang = stationLang()): Promise<void> {
    if (given.enabled !== undefined && typeof given.enabled !== "boolean") throw new Refusal(400, "enabled must be a boolean");
    // A copy of another station's is edited there; only whether this station uses it is its own to say (paused here,
    // kept as its host's copy is refreshed: share/index.ts placeProfile).
    const pausing = Object.keys(given).every((k) => k === "enabled") && given.enabled !== undefined;
    if (!pausing) this.own(id, lang);
    const before = this.profile(id);
    if (given.enabled !== undefined && before?.machine === true) throw new Refusal(400, "a machine login cannot be paused here");
    if (pausing && before !== undefined && borrowed(this.rawProfile(id))) {
      await this.save(viewer, `profile ${id}`, (raw) => {
        const list: Json[] = Array.isArray(raw.profiles) ? raw.profiles : [];
        const existing = list.find((p) => p?.id === id);
        if (!existing) return;
        // Disabled by its host: said so (`hostOff`, share/index.ts placeProfile), or disabled with no pause here, as a
        // copy placed before `hostOff` was written has it (only its host disabled one then).
        const hostOff = existing.share.hostOff === true || (existing.enabled === false && existing.share.paused !== true);
        if (hostOff) existing.share.hostOff = true;
        if (given.enabled === false) existing.share.paused = true;
        else delete existing.share.paused;
        if (given.enabled === false || hostOff) existing.enabled = false;
        else delete existing.enabled;
        raw.profiles = list;
      });
      if (before.enabled !== false && given.enabled === false) {
        this.deps.hub?.profileGone?.(id).catch((error) => log.warn("accounts", "moving sessions off a paused copy failed", { profile: id, error: (error as Error).message }));
      }
      return;
    }
    const givenWorkspaces = given.workspaces;
    if (givenWorkspaces !== undefined && !manages(viewer)) throw new Refusal(403, tr(lang, "station.share.managersOnly"));
    if (givenWorkspaces !== undefined && givenWorkspaces !== null && (!Array.isArray(givenWorkspaces) || !givenWorkspaces.every((w) => typeof w === "string" && /^[0-9A-Za-z_-]{1,128}$/.test(w)))) {
      throw new Refusal(400, "workspaces must be workspace ids");
    }
    await this.save(viewer, `profile ${id}`, (raw) => {
      const list: Json[] = Array.isArray(raw.profiles) ? raw.profiles : [];
      const existing: Json | undefined = list.find((p) => p?.id === id);
      const machine = existing?.machine === true;
      // One on the machine's login is the machine's: only which of its models are used, and how it runs, are chosen.
      const get = (key: string): unknown => (machine && !["model", "models", "backgroundOnMessage", "fast", "maxConcurrentSessions", "newAccountProtection", "directQuota"].includes(key) ? undefined : given[key]);
      // env: a string sets the value; null removes the key; an omitted key keeps it (so masked secrets survive edits).
      const env: Record<string, string> = isObject(existing?.env) ? { ...existing.env } : {};
      const givenEnv = get("env");
      if (isObject(givenEnv)) {
        for (const [key, value] of Object.entries(givenEnv)) {
          if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) throw new Error(`invalid environment variable name ${key}`);
          if (value === null) delete env[key];
          else if (typeof value === "string") env[key] = value;
        }
      }
      const access = get("access");
      const oldAccess = isObject(existing?.access) ? existing.access : undefined;
      const kind = accessKindOf(isObject(access) ? access.kind : undefined) ?? accessKindOf(oldAccess?.kind);
      const givenKey = isObject(access) && typeof access.key === "string" && access.key.trim() !== "" ? access.key.trim() : undefined;
      const keep = oldAccess !== undefined && oldAccess.kind === kind ? oldAccess : undefined;
      const key: string | undefined = givenKey ?? (typeof keep?.key === "string" ? keep.key : undefined);
      // An API provider stays the one it was made for; its address can be changed.
      const provider: string | undefined = typeof keep?.provider === "string" ? keep.provider : undefined;
      let endpoint: string | undefined = typeof keep?.endpoint === "string" ? keep.endpoint : undefined;
      if (isObject(access) && typeof access.endpoint === "string") {
        endpoint = cleanEndpoint(access.endpoint);
        if (endpoint === undefined) throw new Refusal(400, tr(lang, "station.profile.addressNeeded"));
      }
      const protocol: string | undefined = typeof keep?.protocol === "string" ? keep.protocol : undefined;
      const service: string | undefined =
        typeof keep?.service === "string"
          ? keep.service
          : isObject(access) && typeof access.service === "string" && access.service.trim() !== ""
            ? access.service.trim()
            : undefined;
      const givenName = get("name");
      const name = typeof givenName === "string" ? givenName.trim() : typeof existing?.name === "string" ? existing.name : undefined;
      const givenModel = get("model");
      let model = typeof givenModel === "string" ? givenModel.trim() : givenModel !== undefined ? undefined : typeof existing?.model === "string" ? existing.model : undefined;
      if (model === "") model = undefined;
      const givenModels = get("models");
      let models: string[] | undefined;
      if (Array.isArray(givenModels)) {
        const seen = new Set<string>();
        models = givenModels
          .map((m) => (typeof m === "string" ? m : JSON.stringify(m)).trim())
          .filter((m) => m !== "" && !seen.has(m) && (seen.add(m), true))
          .slice(0, 200);
      } else if (givenModels === undefined && Array.isArray(existing?.models)) {
        models = [...existing.models];
      }
      if (models !== undefined && models.length === 0) models = undefined;
      // One model named by hand (a provider that does not list its models): added to those enabled.
      const added = get("addModel");
      if (typeof added === "string" && added.trim() !== "") {
        const one = added.trim();
        models ??= [];
        if (!models.includes(one)) models.push([...one].slice(0, 200).join(""));
      }
      const givenFast = get("fast");
      let fast: boolean | undefined;
      if (typeof givenFast === "boolean") fast = givenFast;
      else if (givenFast !== undefined) throw new Refusal(400, "fast must be a boolean");
      else fast = typeof existing?.fast === "boolean" ? existing.fast : undefined;
      const givenBackground = get("backgroundOnMessage");
      const background = typeof givenBackground === "boolean" ? givenBackground : typeof existing?.backgroundOnMessage === "boolean" ? existing.backgroundOnMessage : undefined;
      // An Antigravity CLI profile's quota asked of Google's API beside its CLI (agy-quota.ts `agyQuota` `direct`).
      const givenDirect = get("directQuota");
      if (givenDirect !== undefined && typeof givenDirect !== "boolean") throw new Refusal(400, "directQuota must be a boolean");
      const directQuota = typeof givenDirect === "boolean" ? givenDirect : existing?.directQuota === false ? false : undefined;
      const givenMaxSessions = get("maxConcurrentSessions");
      let maxConcurrentSessions: number | undefined;
      if (givenMaxSessions === undefined) {
        maxConcurrentSessions = typeof existing?.maxConcurrentSessions === "number" && Number.isInteger(existing.maxConcurrentSessions) && existing.maxConcurrentSessions > 0 ? existing.maxConcurrentSessions : undefined;
      } else if (givenMaxSessions === null || givenMaxSessions === 0) {
        maxConcurrentSessions = undefined;
      } else if (typeof givenMaxSessions === "number" && Number.isInteger(givenMaxSessions) && givenMaxSessions > 0) {
        maxConcurrentSessions = givenMaxSessions;
      } else {
        throw new Refusal(400, "maxConcurrentSessions must be a positive integer or null");
      }
      const givenProtection = get("newAccountProtection");
      let newAccountProtection: boolean | undefined;
      if (givenMaxSessions !== undefined || givenProtection === false) {
        newAccountProtection = undefined;
      } else if (givenProtection === true) {
        newAccountProtection = maxConcurrentSessions !== undefined ? true : undefined;
      } else if (givenProtection !== undefined) {
        throw new Refusal(400, "newAccountProtection must be a boolean");
      } else {
        newAccountProtection = maxConcurrentSessions !== undefined && existing?.newAccountProtection === true ? true : undefined;
      }
      const joined = this.joined();
      const withheld: string[] = Array.isArray(givenWorkspaces) ? joined.filter((w) => !givenWorkspaces.includes(w)) : givenWorkspaces === null ? joined : Array.isArray(existing?.withheld) ? existing.withheld : [];
      const givenHome = get("home");
      const home = typeof givenHome === "string" && givenHome.trim() !== "" ? givenHome.trim() : typeof existing?.home === "string" ? existing.home : `homes/${id}`;
      const api = kind === "api-provider";
      const next: Json = { id };
      if (name !== undefined && name !== "") next.name = name;
      const runtime = runtimeOf(get("runtime")) ?? runtimeOf(existing?.runtime);
      if (kind !== "service" && runtime !== undefined) next.runtime = runtime;
      if (kind !== undefined) {
        next.access = { kind };
        if (key !== undefined) next.access.key = key;
        if (api && provider !== undefined) next.access.provider = provider;
        if (api && endpoint !== undefined) next.access.endpoint = endpoint;
        if (api && protocol !== undefined) next.access.protocol = protocol;
        if (kind === "service" && service !== undefined) next.access.service = service;
        // Signed in to the OpenCode Console or to Kimi: still, unless a key was given in place of its token.
        const signsIn = kind === "opencode-go" || (api && provider === KIMI_CODE);
        if (signsIn && keep?.login === true && givenKey === undefined) next.access.login = true;
      }
      next.home = home;
      next.env = env;
      if (model !== undefined) next.model = model;
      if (models !== undefined) next.models = models;
      if (machine) next.machine = true;
      // Shared with other stations: still (share/index.ts keeps this).
      if (isObject(existing?.share)) next.share = existing.share;
      // Only the default's opposite is written.
      if (background === false) next.backgroundOnMessage = false;
      if (directQuota === false) next.directQuota = false;
      if (maxConcurrentSessions !== undefined) next.maxConcurrentSessions = maxConcurrentSessions;
      if (newAccountProtection === true && maxConcurrentSessions !== undefined) next.newAccountProtection = true;
      if (fast === true) next.fast = true;
      if ((given.enabled ?? existing?.enabled) === false) next.enabled = false;
      if (withheld.length > 0) next.withheld = withheld;
      if (existing) {
        const kept = runtimesFor(next.access, next.runtime);
        for (const r of runtimesFor(existing.access, existing.runtime)) if (!kept.includes(r)) lastOfRuntime(raw, r, id, lang);
      }
      raw.profiles = list;
      const at = list.findIndex((p) => p?.id === id);
      if (at >= 0) list[at] = next;
      else list.push(next);
    });
    if (before?.enabled !== false && given.enabled === false) {
      this.deps.hub?.profileGone?.(id).catch((error) => log.warn("accounts", "moving sessions off a disabled profile failed", { profile: id, error: (error as Error).message }));
    }
  }

  /// An allowance read kept, and as its hour's (store.ts setProfileQuota).
  #keepQuota(id: string, quota: Json): void {
    this.deps.store.setProfileQuota(id, quota);
    this.#dirtyQuotaProfiles.add(id);
  }

  /// DELETE /profiles/:id. Its home stays. Taken even while sessions or connects use it (the pages say so first): its
  /// sessions go on on another profile of their runtime, or stop when there is none.
  async deleteProfile(id: string, viewer: Viewer, lang: Lang = stationLang()): Promise<void> {
    this.own(id, lang);
    await this.save(viewer, `delete profile ${id}`, (raw) => {
      const list: Json[] = Array.isArray(raw.profiles) ? raw.profiles : [];
      if (!list.some((p) => p?.id === id)) throw new Error(`unknown profile ${id}`);
      raw.profiles = list.filter((p) => p?.id !== id);
    });
    this.deps.store.forgetProfileHours(id);
    this.#dirtyQuotaProfiles.add(id);
    this.deps.hub?.profileGone?.(id).catch((error) => log.warn("accounts", "moving sessions off a deleted profile failed", { profile: id, error: (error as Error).message }));
  }

  /// POST /profiles: a new keyed profile, made only once its key is checked and works. Its id.
  async newKeyedProfile(input: Record<string, unknown>, viewer: Viewer, lang: Lang = stationLang()): Promise<string> {
    const t = (key: string, args?: Record<string, unknown>) => tr(lang, key, args);
    const access = isObject(input.access) ? input.access : undefined;
    const kind = accessKindOf(access?.kind);
    if (kind === undefined) throw new Refusal(400, `unknown access ${access?.kind === undefined ? "" : JSON.stringify(access.kind)}`);
    if (kind === "subscription") throw new Refusal(400, t("station.profile.subscriptionBySignIn"));
    const field = (k: string) => (typeof access?.[k] === "string" && access[k].trim() !== "" ? (access[k].trim() as string) : undefined);
    const [provider, givenEndpoint, givenProtocol] = [field("provider"), field("endpoint"), field("protocol")];
    // An API provider is the one named, at the address given where the provider has none of its own; the two kinds
    // that came before the list are added as they were.
    let source = undefined as ReturnType<typeof find>;
    if (kind === "api-provider") {
      source = provider !== undefined && !(provider in LEGACY) ? find(provider) : undefined;
      if (!source) throw new Refusal(400, t("station.profile.unknownProvider"));
      const chosen = source.endpointRequired ? (givenProtocol ?? (source.protocols.length === 1 ? source.protocols[0] : undefined)) : undefined;
      if (endpoints(source, givenEndpoint, chosen) === undefined) throw new Refusal(400, t("station.profile.addressNeeded"));
    }
    const endpoint = source && givenEndpoint !== undefined ? cleanEndpoint(givenEndpoint) : undefined;
    // Of one at the reader's own address: the protocol it speaks there (the one chosen, else its first).
    const protocol = source?.endpointRequired ? (source.protocols.find((p) => p === givenProtocol) ?? source.protocols[0]) : undefined;
    // A key runs every runtime it can; custom variables are for the runtime given.
    const runtimes: Runtime[] = source ? runtimesFor({ kind, provider: source.id, endpoint, protocol }, undefined) : runtimesOf(kind, runtimeOf(input.runtime));
    if ((runtimes.length === 0 && !source) || !runtimes.every((r) => accessKinds(r).includes(kind))) throw new Refusal(400, `unknown access ${kind}`);
    const runtime = runtimes[0] ?? "claude";
    const key = typeof access?.key === "string" ? access.key.trim() : "";
    if (needsKey(kind, source?.id) && key === "") throw new Refusal(400, t("station.profile.keyRequired"));
    const homes = join(this.deps.data, "homes");
    const trial = join(homes, `new-${randomBytes(4).toString("hex")}`);
    await mkdir(trial, { recursive: true });
    const check = await this.checkFn({ runtime, kind, key, via: { provider: source?.id, endpoint, protocol }, home: trial, machine: false }, lang);
    // A provider with no model list leaves its key unchecked (state unknown); a refused key is what stops it.
    const refused = source ? check.state === "failed" : check.state !== "ok" && keyed(kind);
    if (refused) {
      await rm(trial, { recursive: true, force: true });
      throw new Refusal(400, t("station.profile.checkFailed", { detail: check.detail }));
    }
    const label = source
      ? source.name
      : kind === "opencode-go"
        ? "OpenCode Go"
        : kind === "anthropic-api"
          ? "Anthropic API"
          : t("station.profile.envName", { runtime: named(runtime) });
    const base = source ? source.id : kind === "env" ? `${runtime}-env` : kind;
    // (its id held from the homes' listing to its save: another made meanwhile takes another)
    const id = unique(base, await this.takenIdsSoon());
    this.making.add(id);
    try {
      await rename(trial, join(homes, id));
    } catch (e) {
      this.making.delete(id);
      await rm(trial, { recursive: true, force: true });
      throw e;
    }
    try {
      await this.save(viewer, `profile ${id}`, (raw) => {
        const made: Json = { id, name: label };
        if (kind === "env") made.runtime = runtime;
        made.access = { kind };
        if (key !== "") made.access.key = key;
        if (source) made.access.provider = source.id;
        if (endpoint !== undefined) made.access.endpoint = endpoint;
        if (protocol !== undefined) made.access.protocol = protocol;
        Object.assign(made, { home: `homes/${id}`, env: {} });
        raw.profiles = [...(Array.isArray(raw.profiles) ? raw.profiles : []), made];
      });
    } finally {
      this.making.delete(id);
    }
    this.keepCheck(id, check);
    // All a check finds out beyond its key is found once the profile is made, a request to add not waiting on that: what
    // the automatic decisions can use, and the levels Codex offers on it, without which it holds every other account of
    // those models to the runtime's usual ones.
    const profile = this.profile(id);
    if (profile?.runtime === "hermes") this.afterSignIn(id);
    else if (profile) this.background.spawn(() => this.check(id, lang).catch(() => undefined));
    return id;
  }

  /// POST /profiles/machine: a profile on the machine's own login of a runtime, when that login is one a profile can
  /// use (kept in a file). Named by its account. Its id.
  async newMachineProfile(input: Record<string, unknown>, viewer: Viewer, lang: Lang = stationLang()): Promise<string> {
    const t = (key: string, args?: Record<string, unknown>) => tr(lang, key, args);
    const runtime = runtimeOf(input.runtime);
    if (!runtime) throw new Refusal(400, `unknown runtime ${text(input.runtime)}`);
    const id = `machine-${runtime}`;
    // (one being made by another request meanwhile is as one made)
    const used = () => this.making.has(id) || this.profiles().some((p) => p.id === id);
    if (used()) throw new Refusal(409, t("station.machine.alreadyUsed"));
    const machine = this.machine;
    if (!machine) throw new Refusal(400, t("station.machine.unreadable"));
    await machine.refresh();
    const login = machine.get().find((l) => l.runtime === runtime);
    if (!login?.loggedIn) throw new Refusal(400, t("station.machine.notSignedIn", { runtime: named(runtime) }));
    if (!login.usable) throw new Refusal(400, t("station.machine.keychain"));
    if (used()) throw new Refusal(409, t("station.machine.alreadyUsed"));
    this.making.add(id);
    try {
      const home = join(this.deps.data, "homes", id);
      await mkdir(home, { recursive: true });
      if (runtime === "codex") await linkCodexAuthSoon(home, machine.env);
      // Its account, not "this machine": the profile is listed with the workspace's, read from other machines.
      const name = login.email ?? named(runtime);
      log.info("accounts", "profile on the machine's login made", { profile: id, runtime, by: viewer.email });
      await this.save(viewer, `profile ${id} on the machine's login`, (raw) => {
        const made = { id, name, runtime, access: { kind: "subscription" }, home: `homes/${id}`, env: {}, machine: true };
        raw.profiles = [...(Array.isArray(raw.profiles) ? raw.profiles : []), made];
      });
    } finally {
      this.making.delete(id);
    }
    this.afterSignIn(id);
    return id;
  }

  // ── sign-ins ──

  /// Where `id`'s isolated sign-in browser context keeps its cookies and passkeys: inside the profile's own home, or
  /// the pending login's (following its rename once `pendingChanged` creates the profile; null once dropped or failed).
  private loginStateFile(id: string): string | null {
    const profile = this.profile(id);
    if (profile) return profile.machine === true || borrowed(profile) ? null : join(profile.home, LOGIN_BROWSER_FILE);
    const pending = this.pending.get(id);
    if (!pending) return null;
    if (pending.created !== null) {
      const made = this.profile(pending.created);
      return made ? join(made.home, LOGIN_BROWSER_FILE) : null;
    }
    const state = this.logins.get(id)?.state;
    if (state === "failed" || state === "cancelled") return null;
    return join(pending.home, LOGIN_BROWSER_FILE);
  }

  /// POST /profiles/:id/login: a subscription profile signed in (again).
  async startLogin(id: string, viewer: Viewer, lang: Lang = stationLang()): Promise<LoginJob> {
    const profile = this.profile(id);
    if (!profile) throw new Refusal(404, `unknown profile ${id}`);
    const kind = accessKind(profile);
    const kimi = kimiSignedIn(profile);
    if (kind === "service") {
      if (borrowed(profile)) throw new Refusal(409, tr(lang, "station.share.borrowedEdit"));
      const sid = serviceOf(profile);
      const adapter = sid !== undefined ? this.services.get(sid) : undefined;
      if (!adapter?.login) throw new Refusal(400, tr(lang, "station.admin.loginSubscriptionOnly"));
      log.info("accounts", "service login started from the admin page", { profile: id, service: sid, by: viewer.email });
      const email = await adapter.identity(profile.home).catch(() => null);
      return adapter.login({ id, home: profile.home, email }, { env: this.env, lang, logins: this.logins });
    }
    if (kind !== "subscription" && kind !== "opencode-go" && !kimi) throw new Refusal(400, tr(lang, "station.admin.loginSubscriptionOnly"));
    if (profile.machine === true) throw new Refusal(400, tr(lang, "station.admin.loginOnMachine"));
    if (borrowed(profile)) throw new Refusal(409, tr(lang, "station.share.borrowedEdit"));
    log.info("accounts", "login started from the admin page", { profile: id, by: viewer.email });
    // An OpenCode Go one signs in to the OpenCode Console (its key replaced by the token once it is done).
    if (kind === "opencode-go") return this.logins.startConsole({ id, home: profile.home }, lang);
    if (kimi) return this.logins.startKimi({ id, home: profile.home }, lang);
    if (profile.runtime === "cursor") return this.logins.startCursor({ id, home: profile.home }, lang);
    if (profile.runtime === "copilot") return this.logins.startCopilot({ id, home: profile.home }, lang);
    let email: string | null = null;
    // A company's Google account signs in again the way it did (as it was made, or as its sign-in's file says).
    if (profile.runtime === "agy") {
      const access = profile.access as { enterprise?: unknown } | undefined;
      const enterprise = access?.enterprise === true || agyCompany(await readFile(agyToken(profile.home), "utf8").catch(() => ""));
      return this.logins.start({ id, runtime: "agy", home: profile.home, ...(enterprise ? { enterprise } : {}) }, lang);
    }
    if (profile.runtime === "claude") {
      const fromHome = await accountEmailSoon("claude", profile.home);
      const fallback = EMAIL_RE.test(profile.name.trim()) ? profile.name.trim() : null;
      const candidate = (fromHome ?? fallback)?.trim() ?? "";
      email = EMAIL_RE.test(candidate) ? candidate : null;
    }
    if (profile.runtime === undefined) throw new Refusal(400, tr(lang, "station.admin.loginSubscriptionOnly"));
    return this.logins.start({ id, runtime: profile.runtime, home: profile.home, ...(email ? { email } : {}) }, lang);
  }

  /// POST /logins: signing a subscription in before there is a profile; the profile is made once it succeeds.
  /// `access: "opencode-go"`: an OpenCode Go profile signed in to the OpenCode Console instead (no runtime given);
  /// `access: "kimi-code"`: a Kimi Code profile signed in to Kimi; `access: "agy-enterprise"`: an Antigravity CLI one
  /// signed in to a company's Google account.
  async newLogin(input: Record<string, unknown>, viewer: Viewer, lang: Lang = stationLang()): Promise<{ id: string; job: LoginJob }> {
    const id = `login-${randomBytes(4).toString("hex")}`;
    const home = join(this.deps.data, "homes", id);
    if (typeof input.service === "string" && input.service !== "") {
      const adapter = this.services.get(input.service);
      if (!adapter?.login) throw new Refusal(400, `unknown service ${text(input.service)}`);
      this.pending.set(id, { service: input.service, home, by: viewer, created: null, error: null });
      log.info("accounts", "service sign-in for a new profile started", { login: id, service: input.service, by: viewer.email });
      return { id, job: await adapter.login({ id, home }, { env: this.env, lang, logins: this.logins }) };
    }
    if (input.access === "opencode-go") {
      this.pending.set(id, { access: "opencode-go", home, by: viewer, created: null, error: null });
      log.info("accounts", "OpenCode sign-in for a new profile started", { login: id, by: viewer.email });
      return { id, job: await this.logins.startConsole({ id, home }, lang) };
    }
    if (input.access === "kimi-code") {
      this.pending.set(id, { access: "kimi-code", home, by: viewer, created: null, error: null });
      log.info("accounts", "Kimi sign-in for a new profile started", { login: id, by: viewer.email });
      return { id, job: await this.logins.startKimi({ id, home }, lang) };
    }
    if (input.access === "agy-enterprise") {
      this.pending.set(id, { runtime: "agy", access: "agy-enterprise", home, by: viewer, created: null, error: null });
      log.info("accounts", "company Google sign-in for a new profile started", { login: id, by: viewer.email });
      return { id, job: await this.logins.start({ id, runtime: "agy", home, enterprise: true }, lang) };
    }
    const runtime = runtimeOf(input.runtime);
    if (!runtime) throw new Refusal(400, `unknown runtime ${text(input.runtime)}`);
    this.pending.set(id, { runtime, home, by: viewer, created: null, error: null });
    log.info("accounts", "sign-in for a new profile started", { login: id, runtime, by: viewer.email });
    const job = runtime === "cursor" ? await this.logins.startCursor({ id, home }, lang) : runtime === "copilot" ? await this.logins.startCopilot({ id, home }, lang) : await this.logins.start({ id, runtime, home }, lang);
    return { id, job };
  }

  /// Whether a sign-in for a new profile is under that id.
  hasPending(id: string): boolean {
    return this.pending.has(id);
  }

  /// A sign-in for a new profile, dropped (DELETE /logins/:id): its command stopped, its home removed unless it made one.
  /// Gone from the list at once; a profile being made of it meanwhile takes its home away itself (`pendingSettled`).
  async dropLogin(id: string): Promise<void> {
    const pending = this.pending.get(id);
    if (!pending) return;
    this.pending.delete(id);
    this.logins.cancel(id);
    this.changed();
    if (pending.created === null) await rm(pending.home, { recursive: true, force: true });
  }

  /// A sign-in for a new profile moved on: once it succeeds the profile is made, named by the account signed in.
  private async pendingChanged(id: string) {
    // One at a time for an id: told again while its files are read, it would make the profile twice. What it is told
    // meanwhile is settled once the one under way is.
    if (this.settling.has(id)) {
      this.settling.set(id, true);
      return;
    }
    try {
      do {
        this.settling.set(id, false);
        await this.pendingSettled(id);
      } while (this.settling.get(id) === true);
    } finally {
      this.settling.delete(id);
    }
  }

  private async pendingSettled(id: string) {
    const p = this.pending.get(id);
    if (!p) return;
    const state = this.logins.get(id)?.state;
    if (state === "failed" || state === "cancelled") {
      await rm(p.home, { recursive: true, force: true });
      return;
    }
    if (state !== "done" || p.created !== null || p.error !== null) return;
    const lang = stationLang();
    // Dropped, or made, while its files were read: nothing more of it.
    const gone = () => this.pending.get(id) !== p || p.created !== null || p.error !== null;
    const signedIn = p.access === "opencode-go" ? await readConsole(p.home) : null;
    if (gone()) return;
    if (p.access === "opencode-go" && !signedIn) return this.pendingFailed(id, tr(lang, "station.login.consoleUnreadable"));
    const kimi = p.access === "kimi-code";
    const kimiLogin = kimi ? await readKimi(p.home) : null;
    if (gone()) return;
    if (kimi && !kimiLogin) return this.pendingFailed(id, tr(lang, "station.login.kimiUnreadable"));
    const email = signedIn
      ? signedIn.email
      : kimi
        ? null
        : p.service !== undefined
          ? ((await this.services.get(p.service)?.identity(p.home)) ?? null)
          : p.runtime !== undefined
            ? await accountEmailSoon(p.runtime, p.home)
            : null;
    if (gone()) return;
    const base = signedIn
      ? "opencode-go"
      : kimi
        ? KIMI_CODE
        : p.service !== undefined
          ? (slug(email ?? p.service, 40) || p.service)
          : (slug(email ?? `${p.runtime ?? "account"}-subscription`, 40) || p.runtime || "account");
    const taken = await this.takenIdsSoon();
    if (gone()) return;
    // (its id held from the homes' listing to its save: another made meanwhile takes another)
    const profileId = unique(base, taken);
    const target = join(this.deps.data, "homes", profileId);
    this.making.add(profileId);
    try {
      await this.madeOfLogin(id, p, profileId, target, signedIn, kimi, email, lang, gone);
    } finally {
      this.making.delete(profileId);
    }
  }

  /// `pendingSettled`'s profile `profileId` made of sign-in `id`: its home moved to `target`, the profile saved.
  private async madeOfLogin(id: string, p: Pending, profileId: string, target: string, signedIn: ConsoleLogin | null, kimi: boolean, email: string | null, lang: Lang, gone: () => boolean) {
    try {
      await rename(p.home, target);
    } catch (e) {
      if (gone()) return;
      log.warn("accounts", "could not move a new profile's home", { login: id, error: (e as Error).message });
      return this.pendingFailed(id, tr(lang, "station.login.homeFailed", { error: (e as Error).message }));
    }
    // Dropped while it moved (`dropLogin` found nothing at its old place): taken away here.
    if (gone()) {
      await rm(target, { recursive: true, force: true });
      return;
    }
    const enterprise = p.access === "agy-enterprise";
    const subscriptionName = () => {
      if (p.runtime === "claude") return tr(lang, "station.profile.claudeSubscription");
      if (p.runtime === "codex") return tr(lang, "station.profile.chatgptSubscription");
      if (p.runtime === "grok") return tr(lang, "station.profile.grokSubscription");
      if (p.runtime === "cursor") return tr(lang, "station.profile.cursorSubscription");
      if (p.runtime === "devin") return tr(lang, "station.profile.devinSubscription");
      if (p.runtime === "agy") return tr(lang, "station.profile.agySubscription");
      return profileId;
    };
    const name = signedIn
      ? (email ?? "OpenCode Go")
      : kimi
        ? "Kimi Code"
        : p.service !== undefined
          ? (email ?? this.services.get(p.service)?.name ?? p.service)
          : enterprise
            ? (email ?? tr(lang, "station.profile.agyEnterpriseSubscription"))
            : (email ?? subscriptionName());
    try {
      await this.save(p.by, `profile ${profileId} from a sign-in`, (raw) => {
        // An OpenCode Go one runs every runtime its key does (it has none of its own).
        // A Kimi Code one runs Claude Code, its token read from its home (kimi.ts), never kept here.
        const maxConcurrentSessions = DEFAULT_NEW_SUBSCRIPTION_MAX_CONCURRENT_SESSIONS;
        const made = signedIn
          ? { id: profileId, name, access: { kind: "opencode-go", key: signedIn.access, login: true }, home: `homes/${profileId}`, env: {}, maxConcurrentSessions, newAccountProtection: true }
          : kimi
            ? { id: profileId, name, access: { kind: "api-provider", provider: KIMI_CODE, login: true }, home: `homes/${profileId}`, env: {}, maxConcurrentSessions, newAccountProtection: true }
            : p.service !== undefined
              ? { id: profileId, name, access: { kind: "service", service: p.service }, home: `homes/${profileId}`, env: {} }
              : { id: profileId, name, ...(p.runtime !== undefined ? { runtime: p.runtime } : {}), access: enterprise ? { kind: "subscription", enterprise: true } : { kind: "subscription" }, home: `homes/${profileId}`, env: {}, maxConcurrentSessions, newAccountProtection: true };
        raw.profiles = [...(Array.isArray(raw.profiles) ? raw.profiles : []), made];
      });
    } catch (e) {
      log.warn("accounts", "the signed-in profile was not saved", { login: id, error: (e as Error).message });
      await rename(target, p.home).catch(() => {});
      return this.pendingFailed(id, tr(lang, "station.login.saveFailed", { error: (e as Error).message }));
    }
    p.created = profileId;
    this.changed();
    this.afterSignIn(profileId);
    // Kept a while for the page that started it to follow it to the profile.
    this.background.after(PENDING_KEPT_MS, () => void this.dropLogin(id));
  }

  private pendingFailed(id: string, error: string) {
    const p = this.pending.get(id);
    if (p) p.error = error;
    this.changed();
  }

  /// An OpenCode Go profile just signed in to the OpenCode Console: the token left in its home is its key now.
  /// Whether its key was set: not once the profile, or the sign-in that started at `startedAt`, changed while its file
  /// was read (edited to another access, deleted, signed in again).
  private async signedInConsole(id: string, startedAt: number): Promise<boolean> {
    const profile = this.profile(id);
    const login = profile ? await readConsole(profile.home) : null;
    const now = this.profile(id);
    const job = this.logins.get(id);
    if (!now || accessKind(now) !== "opencode-go" || job?.state !== "done" || job.startedAt !== startedAt) return false;
    if (!login) {
      log.warn("accounts", "an OpenCode sign-in left no token", { profile: id });
      return false;
    }
    try {
      await this.setConsoleKey(id, login.access, "signed in to OpenCode");
      return true;
    } catch (e) {
      log.warn("accounts", "the OpenCode sign-in was not saved", { profile: id, error: (e as Error).message });
      return false;
    }
  }

  /// The key of a profile signed in to the OpenCode Console, set to its current token (the runtimes are given it).
  private async setConsoleKey(id: string, key: string, why: string): Promise<void> {
    await this.deps.config.updateSoon((raw) => {
      const p = (Array.isArray(raw.profiles) ? raw.profiles : []).find((x: Json) => x?.id === id);
      if (!p) throw new Error(`unknown profile ${id}`);
      p.access = { kind: "opencode-go", key, login: true };
    });
    log.info("accounts", "OpenCode token saved as the profile's key", { profile: id, why });
  }

  /// Each profile signed in to the OpenCode Console whose token runs out within CONSOLE_RENEW_BEFORE_MS, renewed (only
  /// where it is signed in: a copy another station shares gets the new key from it).
  private renewConsoles() {
    for (const p of this.profiles()) {
      if (accessKind(p) !== "opencode-go" || (p.access as Json)?.login !== true || borrowed(p)) continue;
      this.background.spawn(async () => {
        const login = await readConsole(p.home);
        if (!login || login.expiresAt - wall.now() > CONSOLE_RENEW_BEFORE_MS) return;
        await this.renewConsole(p.id);
      });
    }
  }

  /// Renews a profile's OpenCode Console token now (once at a time: its refresh token is spent).
  renewConsole(id: string): Promise<void> {
    const busy = this.renewing.get(id);
    if (busy) return busy;
    const run = (async () => {
      const profile = this.profile(id);
      const login = profile ? await readConsole(profile.home) : null;
      if (!profile || !login) return;
      let token;
      try {
        token = await renewToken(this.urls.console, login.refresh);
      } catch (e) {
        log.warn("accounts", "could not renew an OpenCode token", { profile: id, error: (e as Error).message });
        // Refused: signed out there; its check says it needs signing in again.
        if (e instanceof RenewRefused) await this.check(id).catch(() => undefined);
        return;
      }
      // The refresh token was spent: the new one is written before anything else can fail.
      await writeConsole(profile.home, { ...login, access: token.access, refresh: token.refresh, expiresAt: wall.now() + token.expiresInMs, org: token.org ?? login.org });
      // Given another key, or deleted, while it was renewed: what was given stays.
      const now = this.profile(id);
      if (!now || accessKind(now) !== "opencode-go" || (now.access as Json)?.login !== true) {
        log.info("accounts", "an OpenCode token renewed for a profile no longer signed in to it; its key left as it is", { profile: id });
        return;
      }
      await this.setConsoleKey(id, token.access, "renewed");
    })().finally(() => this.renewing.delete(id));
    this.renewing.set(id, run);
    return run;
  }

  /// Each profile signed in to Kimi whose token is due (kimi.ts kimiDue), renewed (only on its station: it is not lent).
  private renewKimis() {
    for (const p of this.profiles()) {
      if (!kimiSignedIn(p) || borrowed(p)) continue;
      this.background.spawn(async () => {
        const login = await readKimi(p.home);
        if (!login || !kimiDue(login, wall.now())) return;
        await this.renewKimi(p.id);
      });
    }
  }

  /// Renews a profile's Kimi token now (once at a time: its refresh token is spent); a token not yet due stays, and one
  /// signed out (its refresh token refused, then dropped) is not asked again until it is signed in again.
  renewKimi(id: string): Promise<void> {
    const busy = this.renewing.get(id);
    if (busy) return busy;
    let refused = false;
    const run = (async () => {
      const profile = this.profile(id);
      const login = profile ? await readKimi(profile.home) : null;
      if (!profile || !login || login.refresh === "" || !kimiDue(login, wall.now())) return;
      let token;
      try {
        token = await renewKimiToken(this.urls.kimi ?? KIMI_AUTH, login.refresh, login.deviceId);
      } catch (e) {
        log.warn("accounts", "could not renew a Kimi token", { profile: id, error: (e as Error).message });
        if (e instanceof RenewRefused) {
          await writeKimi(profile.home, { ...login, refresh: "" });
          refused = true;
        }
        return;
      }
      // The refresh token was spent: the new one is written before anything else can fail.
      await writeKimi(profile.home, { ...login, access: token.access, refresh: token.refresh, expiresAt: wall.now() + token.expiresInMs, lifeMs: token.expiresInMs });
    })().finally(() => this.renewing.delete(id));
    this.renewing.set(id, run);
    // Refused: signed out there; its check (which renews first, so not within this) says it needs signing in again.
    return run.then(async () => {
      if (refused) await this.check(id).catch(() => undefined);
    });
  }

  /// A profile just signed in: checked (which lists its models, all of them run) and its allowance read, so its page
  /// shows them at once.
  private afterSignIn(id: string) {
    this.authRevoked.delete(id);
    const profile = this.profile(id);
    // A completed Codex sign-in replaces the login which the provider refused. If the allowance service happens to be
    // unreachable now, keep the new sign-in's status; a new refusal will mark it again.
    if (profile?.runtime === "codex" && accessKind(profile) === "subscription") {
      this.loginGeneration.set(id, (this.loginGeneration.get(id) ?? 0) + 1);
      this.codexLogin(id, false);
      // Which account it is on now, for the pool's next pick.
      void this.codexAccountRead(profile, true).catch(() => {});
    }
    // Its copies on other stations take the new sign-in (share/index.ts `loginUpdated`).
    if (profile && accessKind(profile) === "subscription" && !borrowed(profile)) this.deps.shared?.loginUpdated?.(id);
    this.background.spawn(async () => {
      const profile = this.profile(id);
      // A running `agy` never reads its sign-in's file again (agents/agy.ts AGY_LENT_RENEW_MS): its sessions' processes
      // start again on the new one.
      if (profile?.runtime === "agy") {
        try {
          await this.deps.hub?.profileLoginChanged?.(id);
        } catch (e) {
          log.warn("accounts", "could not restart the Antigravity CLI's sessions after sign-in", { profile: id, error: (e as Error).message });
        }
      }
      if (profile?.runtime === "codex") {
        try {
          await this.deps.codex?.()?.loginChanged?.(id);
        } catch (e) {
          log.warn("accounts", "could not replace the codex app-server after sign-in", { profile: id, error: (e as Error).message });
        }
      }
      try {
        await this.check(id);
      } catch (e) {
        log.warn("accounts", "check after sign-in failed", { profile: id, error: (e as Error).message });
      }
      // A reading started before the new sign-in must finish before its own is asked.
      await this.readQuota(id, true);
    });
  }

  /// The models outdated on this station's profiles (models.ts) unchecked, each once: config.json keeps which were
  /// (`outdatedUnchecked`), so one checked again by hand stays. Worked out at the start and again as a check finds other
  /// models (a newer one offered, an old one gone).
  private async uncheckOutdated(): Promise<void> {
    const found = (id: string) => {
      const c = this.checks.get(id);
      return c?.models ? [...c.models, ...expandDevinFusion(c.fusion)] : null;
    };
    const unchecked = (raw: Json) => {
      const done = new Set<string>(Array.isArray(raw?.outdatedUnchecked) ? raw.outdatedUnchecked.filter((k: unknown) => typeof k === "string") : []);
      const { changes, unchecked } = uncheckOutdated(raw, found, done);
      return { changes, now: [...new Set([...done, ...unchecked])].sort() };
    };
    // Worked out on a copy first: config.json is written only when something changes.
    if (unchecked(structuredClone(this.deps.config.raw())).changes.length === 0) return;
    let changes: ReturnType<typeof unchecked>["changes"] = [];
    try {
      await this.deps.config.updateSoon((raw) => {
        const done = unchecked(raw);
        changes = done.changes;
        raw.outdatedUnchecked = done.now;
      });
    } catch (e) {
      log.warn("accounts", "could not uncheck the outdated models", { error: (e as Error).message });
      return;
    }
    for (const c of changes) log.info("accounts", "outdated models unchecked", { profile: c.profile, removed: c.removed.join(" "), added: c.added.join(" ") });
  }

  /// The catalog named models it had not (models/module.ts): the profiles whose check found a model of one of their
  /// makers are checked again, so a model a provider has just begun to offer is offered here, and replaces the one before
  /// it, without the station starting again (Fable 5.2 came out with the stations up, 2026-11-09).
  newModels(keys: readonly string[]) {
    const makers = new Set(keys.flatMap((k) => facts(k)?.maker ?? []));
    if (makers.size === 0) return;
    const ids = this.profiles()
      .filter((p) => p.enabled !== false && (this.checks.get(p.id)?.models ?? []).some((m) => makers.has(facts(m)?.maker ?? "")))
      .map((p) => p.id);
    if (ids.length === 0) return;
    log.info("accounts", "new models in the catalog: their makers' profiles checked again", { models: keys.join(" "), profiles: ids.join(" ") });
    this.background.spawn(() => this.checkEach(ids, stationLang()).catch(() => undefined));
  }

  /// Checks the profiles, four at a time; throws the first refusal once all are done.
  private async checkEach(ids: readonly string[], lang: Lang) {
    const errors: unknown[] = [];
    let next = 0;
    const worker = async () => {
      while (next < ids.length) {
        const id = ids[next++]!;
        try {
          await this.check(id, lang);
        } catch (e) {
          errors.push(e);
        }
      }
    };
    await Promise.all([worker(), worker(), worker(), worker()]);
    if (errors.length > 0) throw errors[0];
  }

  // ── checks and allowances ──

  /// `forced`: a login found over here whatever its check says (`revoke`).
  private keepCheck(id: string, check: ProfileCheck, forced = false) {
    check.checkedAt = this.background.now();
    const before = this.checks.get(id);
    const revoked = this.authRevoked.get(id);
    if (revoked !== undefined && check.state !== "login" && check.state !== "failed") {
      // Good again only by an allowance read since it was found over (a sign-in anew forgets it: afterSignIn): one read
      // here is one kept since; a borrowed one's host's is one it read later (a host from before answers what it had).
      const quota = this.quotas.get(id);
      const since = quota !== undefined && typeof quota.checkedAt === "number" &&
        (borrowed(this.profile(id)) ? quota.checkedAt > revoked.quotaAt : quota !== revoked.quota && quota.checkedAt >= revoked.quotaAt);
      if (quota?.state === "ok" && since) this.authRevoked.delete(id);
      else {
        check = { ...check, state: "login", detail: revoked.detail };
        forced = true;
      }
    }
    if (check.state === "login" && before?.state !== "login") this.lost(id, before, forced);
    else if (check.state === "ok" && before?.state !== "ok") this.deps.loginBack?.(id);
    const foundBefore = this.found(id);
    this.checks.set(id, check);
    // The hub's config takes only the models a check found (`found`): a check that found the same keeps it, as one
    // stamped anew on every round made every profile's config again for each overview and pick (0.1.11070).
    if (!sameModels(foundBefore, this.found(id))) this.checksChanged++;
    this.deps.store.setProfileCheck(id, check);
    // Other models found: one may now replace one the profile names.
    if (
      JSON.stringify(before?.models ?? null) !== JSON.stringify(check.models) ||
      JSON.stringify(before?.fusion ?? null) !== JSON.stringify(check.fusion ?? null)
    ) {
      this.#unchecking = this.uncheckOutdated().catch(() => {});
    }
    this.changed();
  }

  /// A subscription's login newly over, told to the managers where it had signed in (or was found over here): a profile
  /// made and never signed in is not. A borrowed one's host tells its own, unless it was found over here alone.
  private lost(id: string, before: ProfileCheck | undefined, forced: boolean) {
    const profile = this.profile(id);
    if (!profile || profile.enabled === false || accessKind(profile) !== "subscription") return;
    if (borrowed(profile) ? !forced : !(forced || before?.state === "ok" || this.quotas.has(id))) return;
    this.deps.loginLost?.({ id, profile, station: borrowed(profile) ? (this.deps.shared?.hostName?.(profile) ?? null) : null });
  }

  /// Its login taken as over (a runtime refused on it, and its recheck found it so; or its host said so): its check says
  /// to sign in again, and the pool passes it over (sessions/pool.ts `signsIn`) until it signs in anew. `seen`: the
  /// newest allowance reading its host gave meanwhile (a borrowed one's), which an allowance must be newer than to undo it.
  private revoke(id: string, notify: boolean, seen = 0) {
    const profile = this.profile(id);
    if (!profile || profile.enabled === false || accessKind(profile) !== "subscription") return;
    const detail = tr(stationLang(), "station.quota.signInExpired");
    const quota = this.quotas.get(id);
    const had = this.authRevoked.get(id)?.quotaAt ?? 0;
    this.authRevoked.set(id, { detail, quota, quotaAt: Math.max(quota?.checkedAt ?? 0, seen, had) });
    const before = this.checks.get(id);
    if (before?.state === "login") return;
    this.keepCheck(id, { ...(before ?? { models: null, checkedAt: 0 }), state: "login", detail, ...(profile.runtime === "codex" ? { codexRevoked: true } : {}) }, notify);
  }

  /// A borrowed profile's host said its login is over (share/index.ts LOGIN_OVER): the host tells its own managers.
  markLoginExpired(id: string) {
    const profile = this.profile(id);
    this.revoke(id, profile !== undefined && !borrowed(profile));
  }

  /// Profile `id` asked again after a runtime on it was refused (sessions/accounts.ts `recheck`): its login is good only
  /// where its check says so and, for a runtime whose allowance is read, an allowance read now does too; a borrowed one
  /// where its host says so having read it again (a host from before answers what it had: not taken for a reading). Else
  /// it is over (`revoke`). `force`: refused again after a recheck and a retry in the same turn, it is over.
  async recheckProfile(id: string, force = false): Promise<void> {
    const profile = this.profile(id);
    if (!profile || profile.enabled === false) return;
    if (accessKind(profile) !== "subscription") {
      await this.check(id).catch(() => undefined);
      return;
    }
    const quotaRead = QUOTA_RUNTIMES.includes(profile.runtime);
    const readAt = (got: { quota: Json } | null) => (isObject(got?.quota) && typeof got.quota.checkedAt === "number" ? got.quota.checkedAt : 0);
    const saysOver = (got: { check: Json } | null) => isObject(got?.check) && got.check.state === "login";
    if (borrowed(profile) && this.deps.shared) {
      // What its host has read already (here never asked yet, or asked before the host's own round read it again): a
      // reading after a refusal is one newer than that, never what a host from before answers it had.
      const prior = await this.deps.shared.status(profile).catch(() => null);
      const before = Math.max(this.quotas.get(id)?.checkedAt ?? 0, readAt(prior));
      // (the host saying so itself tells its own managers)
      if (force) return this.revoke(id, !saysOver(prior), before);
      const got = await this.deps.shared.status(profile, true).catch(() => null);
      const check = got?.check;
      const quota = got?.quota;
      const good = isObject(check) && check.state === "ok" &&
        (!quotaRead || (isObject(quota) && quota.state === "ok" && typeof quota.checkedAt === "number" && quota.checkedAt > before));
      if (good) {
        this.authRevoked.delete(id);
        await this.checkBorrowed(profile, stationLang()).catch(() => undefined);
        return;
      }
      return this.revoke(id, !saysOver(got), Math.max(before, readAt(got)));
    }
    if (force) return this.revoke(id, true);
    const generation = this.loginGeneration.get(id) ?? 0;
    const quota = quotaRead && this.quotaFn ? await this.readQuota(id, true).catch(() => null) : undefined;
    const check = await this.check(id, stationLang(), true).catch(() => null);
    // (signed in anew meanwhile: what was asked is of the login before)
    if ((this.loginGeneration.get(id) ?? 0) !== generation) return;
    const good = check?.state === "ok" && (quota === undefined || quota?.state === "ok" || quota?.state === "unsupported");
    if (good) {
      this.authRevoked.delete(id);
      if (this.checks.get(id)?.state !== "ok") this.keepCheck(id, { ...check! });
      return;
    }
    this.revoke(id, true);
  }

  /// A Codex provider refusal outlives `codex login status`, which only sees that a local token exists. A successful
  /// provider allowance read clears it. Keep the last known models and capabilities for the account pool.
  private codexLogin(id: string, revoked: boolean, lang: Lang = stationLang()) {
    const before = this.checks.get(id);
    if (revoked) {
      this.keepCheck(id, { ...(before ?? { models: null, checkedAt: 0 }), state: "login", detail: tr(lang, "station.quota.codexLogin"), codexRevoked: true });
    } else if (before?.codexRevoked) {
      const { codexRevoked: _, ...kept } = before;
      this.keepCheck(id, { ...kept, state: "ok", detail: tr(lang, "station.profile.signedIn") });
    }
  }

  /// `check` as a device asks it (POST /profiles/:id/check): asked again while the same is under way for the same
  /// profile and sign-in, the answer is that one's. Every device that sees a profile not checked yet asks at once
  /// (core-ts choose-calls.ts): 20 probes, 20 stored checks and 20 overviews read again for one (2026-11-23).
  async askedCheck(id: string, lang: Lang = stationLang()): Promise<ProfileCheck> {
    const profile = this.profile(id);
    if (!profile || profile.enabled === false) return this.check(id, lang);
    const key = JSON.stringify([id, lang, this.loginGeneration.get(id) ?? 0, fingerprint(profile)]);
    const asked = this.checksAsked.get(key);
    if (asked !== undefined) return asked;
    const now = this.check(id, lang);
    this.checksAsked.set(key, now);
    try {
      return await now;
    } finally {
      if (this.checksAsked.get(key) === now) this.checksAsked.delete(key);
    }
  }

  /// POST /profiles/:id/check: asks the provider or runtime whether the profile works, its models, its reasoning levels
  /// (Codex) and what it can decide with.
  /// `recheck`: asked again after a runtime on it was refused (profiles.ts `CheckOptions.recheck`).
  async check(id: string, lang: Lang = stationLang(), recheck = false, stands = false): Promise<ProfileCheck> {
    const profile = this.profile(id);
    if (!profile) throw new Refusal(404, `unknown profile ${id}`);
    if (profile.enabled === false) throw new Refusal(409, tr(lang, "station.profile.disabled", { profile: profile.name }));
    const kind = accessKind(profile);
    if (borrowed(profile) && kind === "subscription" && this.deps.shared) return this.checkBorrowed(profile, lang, stands);
    // Signed in to Kimi: asked with its current token (renewed first where due), none once signed out.
    const kimi = kimiSignedIn(profile);
    if (kimi) await this.renewKimi(id);
    const kimiLogin = kimi ? await readKimi(profile.home) : null;
    const key = kimi ? (kimiLogin?.access ?? "") : String((profile.access as Json)?.key ?? "").trim();
    const signedOut = kimi && (kimiLogin?.refresh ?? "") === "";
    const check = await this.checkFn(
      { runtime: profile.runtime, kind, key: signedOut ? "" : key, via: profileVia(profile), service: serviceOf(profile), profile, home: profile.home, machine: profile.machine === true, login: (profile.access as Json)?.login === true, ...(recheck ? { recheck: true } : {}) },
      lang,
    );
    // Codex capabilities kept for each account, including providers whose model ids came from their API.
    const codexSubscription = kind === "subscription" && profile.runtime === "codex";
    const codex = this.deps.codex?.();
    if ((check.state === "ok" || check.state === "unknown") && profile.runtimes.includes("codex") && codex) {
      try {
        const catalog = await codex.models(profile);
        if (codexSubscription && check.models === null) check.models = catalog.models;
        check.modelEfforts = { codex: Object.fromEntries(catalog.efforts) };
        if (catalog.defaults !== undefined) check.modelEffortDefaults = { codex: Object.fromEntries(catalog.defaults) };
        if (catalog.ultrafastModels !== undefined) check.codexUltrafastModels = catalog.ultrafastModels;
      } catch (e) {
        // A temporary listing failure does not erase a saved selection in the clients.
        const previous = this.checks.get(id);
        if (previous) {
          if (previous.modelEfforts !== undefined) check.modelEfforts = previous.modelEfforts;
          if (previous.modelEffortDefaults !== undefined) check.modelEffortDefaults = previous.modelEffortDefaults;
          if (previous.codexUltrafastModels !== undefined) check.codexUltrafastModels = previous.codexUltrafastModels;
          if (codexSubscription && check.models === null) check.models = previous.models;
        }
        check.detail = tr(lang, "station.profile.modelsStale", { detail: check.detail });
        log.warn("accounts", "could not list codex model capabilities", { profile: id, error: (e as Error).message });
      }
    }
    if (profile.runtime === "hermes" && this.deps.hermes?.()) {
      try {
        check.models = await this.deps.hermes()!.models(profile);
        check.state = check.models.length > 0 ? "ok" : "unknown";
        check.detail = tr(lang, check.models.length >= HERMES_MODEL_LIMIT ? "station.profile.hermesModelsLimited" : check.models.length > 0 ? "station.profile.works" : "station.profile.hermesModelsEmpty", { n: check.models.length, limit: HERMES_MODEL_LIMIT });
      } catch (e) {
        check.models = this.checks.get(id)?.models ?? null;
        check.state = "unknown";
        check.detail = tr(lang, "station.profile.hermesModelsFailed", { error: (e as Error).message });
      }
    }
    // (One signed out of its Google account is said so by its check: no session asked; a subscription whose keychain
    // sign-in was revoked or removed is found signed out here, while an already-failed key check keeps its refusal.)
    if (profile.runtime === "copilot" && this.deps.copilot?.()) {
      try {
        check.models = await this.deps.copilot()!.models(profile);
        check.state = check.models.length > 0 ? "ok" : "login";
        check.detail = check.models.length > 0 ? tr(lang, "station.profile.works", { n: check.models.length }) : tr(lang, "station.profile.signedOut");
      } catch (e) {
        check.models = this.checks.get(id)?.models ?? null;
        check.state = "login";
        check.detail = tr(lang, "station.profile.signedOut");
        log.warn("accounts", "could not list Copilot models", { profile: id, error: (e as Error).message });
      }
    }
    if (profile.runtime === "agy" && (check.state === "ok" || check.state === "unknown") && this.deps.agy?.()) {
      try {
        const agy = this.deps.agy()!;
        if (agy.catalog) {
          const catalog = await agy.catalog(profile);
          check.models = catalog.models;
          check.modelEfforts = { agy: catalog.efforts };
          // Its plan as `agy` said it, else as its sign-in's file does (profiles.ts).
          const company = (profile.access as { enterprise?: unknown } | undefined)?.enterprise === true;
          if (catalog.plan !== undefined) check.plan = catalog.plan;
          else if (company && check.plan === undefined) check.plan = "Enterprise";
          if (Object.keys(catalog.defaults).length > 0) check.modelEffortDefaults = { agy: catalog.defaults };
        } else {
          check.models = await agy.models(profile);
        }
        check.state = "ok";
        check.detail = tr(lang, "station.profile.works", { n: check.models.length });
      } catch (e) {
        const error = (e as Error).message;
        check.models = null;
        if (kind === "subscription" && agyClassifyFailure(error) === "auth") {
          check.state = "login";
          check.detail = tr(lang, "station.profile.signedOut");
        } else {
          check.state = "failed";
          check.detail = tr(lang, "station.profile.agyFailed", { error });
        }
      }
    }
    if (kind !== "service") check.decision = await this.discoverFn(profile, check);
    // A profile edited during the probe does not inherit the previous account's capabilities.
    const now = this.profile(id);
    if (!now || fingerprint(now) !== fingerprint(profile)) throw new Refusal(409, tr(lang, "station.profile.changedRecheck"));
    // A machine profile's token-only Claude check may omit the specific tier. Read its own login at the end of the
    // check, including when the login is held in the keychain and its first reading finished during the check.
    if (profile.machine === true && kind === "subscription" && check.state === "ok") {
      const login = this.machineLogins().find((l) => l.runtime === profile.runtime && l.loggedIn);
      if (typeof login?.plan === "string" && login.plan.trim() !== "") check.plan = login.plan.trim();
    }
    const previous = this.checks.get(id);
    // A list not read this time (the provider not answering a moment, a check that failed) does not take away the models
    // the profile was found to run: the pickers' liked and frequent models are only those it runs.
    if (check.models === null && previous !== undefined && previous.models !== null) {
      check.models = previous.models;
      if (check.modelEfforts === undefined && previous.modelEfforts !== undefined) check.modelEfforts = previous.modelEfforts;
      if (check.modelEffortDefaults === undefined && previous.modelEffortDefaults !== undefined) check.modelEffortDefaults = previous.modelEffortDefaults;
      if (check.codexUltrafastModels === undefined && previous.codexUltrafastModels !== undefined) check.codexUltrafastModels = previous.codexUltrafastModels;
      if (check.fusion === undefined && previous.fusion !== undefined) check.fusion = previous.fusion;
    }
    if (codexSubscription && previous?.codexRevoked) {
      check.state = "login";
      check.detail = previous.detail;
      check.codexRevoked = true;
    }
    this.keepCheck(id, check);
    // One never asked yet (just made, however): its allowance now, not at the next round.
    if (check.state === "ok" && !this.quotas.has(id)) this.background.spawn(() => this.refreshQuota(id));
    return check;
  }

  /// A copy of another station's subscription: how it is doing is what its host says (unusable while it does not answer,
  /// after a transient grace period for background checks).
  private async checkBorrowed(profile: Profile, lang: Lang, stands = false): Promise<ProfileCheck> {
    let check: ProfileCheck;
    try {
      const got = await this.deps.shared!.status(profile);
      this.borrowedUnreachableSince.delete(profile.id);
      check = isObject(got.check) ? (got.check as ProfileCheck) : { state: "unknown", detail: "", models: null, checkedAt: 0 };
      // Unless what the borrowed login read here is newer.
      const local = this.checks.get(profile.id);
      const mine = this.quotas.get(profile.id);
      // Keep a recent detailed reading when an older host can only supply the same reset count. It is refreshed after
      // a reset and every quota round; a host's clock may be ahead of ours.
      const now = this.background.now();
      const completeHere = this.missingBorrowedResetDetails(profile, got.quota) && mine !== undefined &&
        !this.missingBorrowedResetDetails(profile, mine) && mine.resetCount === got.quota.resetCount &&
        mine.checkedAt <= now && now - mine.checkedAt < QUOTA_EVERY_MS;
      // A reading the same as the one kept (rechecks while the host has not read again) is not written again.
      const same = mine !== undefined && JSON.stringify(got.quota) === JSON.stringify(mine);
      if (isObject(got.quota) && !local?.codexRevoked && !completeHere && !same && !(mine !== undefined && Number(got.quota.checkedAt ?? 0) < mine.checkedAt)) {
        this.quotas.set(profile.id, got.quota as ProfileQuota);
        this.#keepQuota(profile.id, got.quota);
      }
      this.refreshMissingBorrowedResetDetails(profile);
    } catch (e) {
      const host = this.deps.shared!.hostName?.(profile) ?? "";
      const previous = this.checks.get(profile.id);
      const now = this.background.now();
      if (stands && previous?.state === "ok" && !previous.codexRevoked) {
        let since = this.borrowedUnreachableSince.get(profile.id);
        if (since === undefined) {
          since = now;
          this.borrowedUnreachableSince.set(profile.id, since);
        }
        if (now - since < BORROWED_HOST_STANDS_MS) {
          log.warn("accounts", "borrowed profile host did not answer; keeping previous check", { profile: profile.id, host, error: e instanceof Error ? e.message : String(e) });
          return previous;
        }
      }
      check = { state: "failed", detail: tr(lang, "station.share.hostOffline", { host }), models: null, checkedAt: 0 };
      if (previous !== undefined && previous.models !== null) {
        check.models = previous.models;
        if (previous.modelEfforts !== undefined) check.modelEfforts = previous.modelEfforts;
        if (previous.modelEffortDefaults !== undefined) check.modelEffortDefaults = previous.modelEffortDefaults;
        if (previous.codexUltrafastModels !== undefined) check.codexUltrafastModels = previous.codexUltrafastModels;
        if (previous.fusion !== undefined) check.fusion = previous.fusion;
      }
    }
    // The host's login can work while this station still has an independently refused borrowed token. Keep that
    // evidence through an offline check as well, so the host coming back cannot make the old token usable again.
    const local = this.checks.get(profile.id);
    if (local?.codexRevoked) {
      check = check.state === "failed"
        ? { ...check, codexRevoked: true }
        : { ...check, state: "login", detail: local.detail, codexRevoked: true };
    }
    this.keepCheck(profile.id, check);
    return check;
  }

  private missingBorrowedResetDetails(profile: Profile, q: ProfileQuota | null | undefined): boolean {
    return profile.runtime === "codex" && borrowed(profile) && q != null && Number.isInteger(q.resetCount) &&
      q.resetCount! > 0 && (!Array.isArray(q.resetExpiries) || q.resetExpiries.length < q.resetCount!);
  }

  /// An older host's fresh count is not a fresh reading of the expiry details. Read those with the lent login, and
  /// retain the host's count if it cannot be read. In-flight reads also call checkBorrowed on failure, so do not start
  /// another one from that check.
  private refreshMissingBorrowedResetDetails(profile: Profile) {
    const q = this.quotas.get(profile.id);
    if (!this.deps.shared || !this.missingBorrowedResetDetails(profile, q) || this.quotaBusy.has(profile.id)) return;
    const now = this.background.now();
    const count = q!.resetCount!;
    const last = this.resetDetailsAsked.get(profile.id);
    if (last && last.count === count && now - last.at < QUOTA_EVERY_MS) return;
    this.resetDetailsAsked.set(profile.id, { at: now, count });
    this.background.spawn(() => this.refreshQuota(profile.id));
  }

  /// POST /profiles/:id/quota: a profile's allowance asked again (unless a question is on its way already: then the
  /// last one).
  refreshQuota(id: string): Promise<ProfileQuota | null> {
    return this.readQuota(id, false);
  }

  /// When a profile's allowance was last asked, answered or not (what stands through a question unanswered keeps the
  /// time it was read: askQuota).
  private quotaAskedAt(id: string): number {
    return Math.max(this.quotas.get(id)?.checkedAt ?? 0, this.quotaUnanswered.get(id)?.at ?? 0);
  }

  /// The same asked by a person (the route's), who is told what came of it: the question on its way waited for, and
  /// one that got no answer refused saying so, the allowance read before left standing.
  async askedQuota(id: string): Promise<ProfileQuota | null> {
    const busy = this.quotaBusy.get(id);
    if (busy) await busy;
    else await this.readQuota(id, false);
    const unanswered = this.quotaUnanswered.get(id);
    if (unanswered !== undefined) throw new Refusal(502, unanswered.detail);
    return this.quotas.get(id) ?? null;
  }

  private readQuota(id: string, afterReset: boolean): Promise<ProfileQuota | null> {
    const busy = this.quotaBusy.get(id);
    if (busy && !afterReset) return Promise.resolve(this.quotas.get(id) ?? null);
    // A read after a reset waits for any older one, so an in-flight snapshot from before cannot win.
    const read = (async () => {
      if (busy) await busy;
      // (asked because it changed, a reset used or signed in anew: what was read before is not what stands)
      return this.askQuota(id, !afterReset);
    })();
    const done: Promise<void> = read.then(
      () => {},
      () => {},
    );
    this.quotaBusy.set(id, done);
    void done.then(() => {
      if (this.quotaBusy.get(id) === done) this.quotaBusy.delete(id);
    });
    return read;
  }

  /// `stands`: whether the allowance read before stands where this question gets no answer.
  private async askQuota(id: string, stands: boolean): Promise<ProfileQuota | null> {
    const profile = this.profile(id);
    if (!profile) throw new Refusal(404, `unknown profile ${id}`);
    if (profile.enabled === false) {
      this.quotaUnanswered.delete(id);
      return this.quotas.get(id) ?? null;
    }
    const generation = this.loginGeneration.get(id) ?? 0;
    // Another station's subscription: a Codex one's is read with the login its host lent while that is good; otherwise
    // (none lent yet, run out, refused) it comes with its host's check.
    if (borrowed(profile) && accessKind(profile) === "subscription" && this.deps.shared) {
      const now = this.background.now();
      let own = profile.runtime === "codex" ? await lentCodexUsage(profile.home, now, this.urls).catch(() => null) : null;
      if (profile.runtime === "codex" && (own === null || own.signedOut) && this.deps.shared.lendCodex) {
        try {
          // A revoked token may still have days until its expiry. Ask the host now, without falling back to that token.
          await this.deps.shared.lendCodex(profile, true);
          const refreshed = await lentCodexUsage(profile.home, this.background.now(), this.urls);
          if (refreshed?.state === "ok") {
            own = refreshed;
            await this.deps.codex?.()?.loginChanged?.(id);
          } else if (refreshed?.signedOut) own = refreshed;
        } catch {
          // Keep a refusal from the token actually used here, even when the host is unavailable.
        }
      }
      if (own?.state === "ok") {
        const { signedOut: _, ...asked } = own;
        const read = { ...asked, checkedAt: now };
        this.quotas.set(id, read);
        this.#keepQuota(id, read);
        if (profile.runtime === "codex") this.codexLogin(id, false);
        this.changed();
        return read;
      }
      if (own?.signedOut) {
        const { signedOut: _, ...asked } = own;
        const read = { ...asked, checkedAt: this.background.now() };
        this.quotas.set(id, read);
        this.#keepQuota(id, read);
        this.codexLogin(id, true);
        this.changed();
        return read;
      }
      await this.checkBorrowed(profile, stationLang(), true).catch(() => {});
      return this.quotas.get(id) ?? null;
    }
    if (!this.quotaFn) return this.quotas.get(id) ?? null;
    const { signedOut, unanswered, recheck, ...asked } = await this.quotaFn(profile);
    if ((this.loginGeneration.get(id) ?? 0) !== generation) return this.quotas.get(id) ?? null;
    // No answer (the provider not reached, or in trouble itself) says nothing of the allowance: the one read before
    // stands, with when it was read, till an answer comes or it is too old to show. One such miss took every Claude
    // account's allowance and resets off their pages for a round (2026-11-11). Asked again each round as ever: what
    // stands keeps its `checkedAt`.
    const before = this.quotas.get(id);
    if (stands && unanswered === true && before?.state === "ok" && this.background.now() - before.checkedAt < QUOTA_STANDS_MS) {
      this.quotaUnanswered.set(id, { detail: asked.detail ?? "", at: this.background.now() });
      return before;
    }
    this.quotaUnanswered.delete(id);
    let current = asked;
    let refused = signedOut === true;
    if (profile.runtime === "codex" && accessKind(profile) === "subscription" && refused) {
      // An app-server can still hold the pre-login token. Check the file directly before marking the account unusable.
      const fresh = await codexUsage(join(profile.home, "auth.json"), this.urls).catch(() => null);
      if ((this.loginGeneration.get(id) ?? 0) !== generation) return this.quotas.get(id) ?? null;
      if (fresh?.state === "ok") {
        await this.deps.codex?.()?.loginChanged?.(id);
        if ((this.loginGeneration.get(id) ?? 0) !== generation) return this.quotas.get(id) ?? null;
        current = fresh;
        refused = false;
      }
    }
    const read = { ...current, checkedAt: this.background.now() };
    this.quotas.set(id, read);
    this.#keepQuota(id, read);
    this.changed();
    // Its login found over: its check says so, and the pool passes it over (as a Console or Kimi sign-in refused).
    if (profile.runtime === "codex" && accessKind(profile) === "subscription") {
      if (refused) this.codexLogin(id, true);
      else if (read.state === "ok") this.codexLogin(id, false);
    } else if (signedOut && this.checks.get(id)?.state !== "login") {
      // Checked before this answers (asked again with its login renewed), so a host lending it says it signed out with
      // the allowance that found it so, never `ok` from before (share/index.ts `share.status`).
      await this.check(id, stationLang(), true).catch(() => undefined);
    } else if (recheck && this.checks.get(id)?.state === "ok") {
      this.background.spawn(() => this.check(id).catch(() => undefined));
    } else if (
      (profile.runtime !== "codex" || this.authRevoked.has(id)) &&
      accessKind(profile) === "subscription" &&
      read.state === "ok" &&
      (this.checks.get(id)?.state === "failed" || this.checks.get(id)?.state === "login")
    ) {
      this.background.spawn(() => this.check(id).catch(() => undefined));
    }
    return read;
  }

  /// Asks again every profile's allowance older than a round (all of them, `all`).
  refreshQuotas(all: boolean) {
    if (!this.quotaFn) return;
    const now = this.background.now();
    for (const p of this.profiles()) {
      if (p.enabled === false) continue;
      const fresh = this.quotas.has(p.id) && now - this.quotaAskedAt(p.id) < QUOTA_EVERY_MS - 1000;
      if (fresh && !all) {
        this.refreshMissingBorrowedResetDetails(p);
        continue;
      }
      this.background.spawn(() => this.refreshQuota(p.id));
    }
  }

  /// Copies of other stations' subscriptions checked again (their host answers again, or may).
  recheckBorrowed() {
    for (const p of this.profiles()) {
      if (borrowed(p) && accessKind(p) === "subscription") this.background.spawn(() => this.check(p.id, stationLang(), false, true).catch(() => {}));
    }
  }

  /// A shared profile newly copied onto this station: check it once so its models and status appear without a restart.
  sharedAdded(id: string): void {
    const profile = this.profile(id);
    if (!profile || !borrowed(profile) || profile.enabled === false) return;
    this.background.spawn(() => this.check(id, stationLang(), false, true).catch(() => undefined));
  }

  /// A shared profile changed on its host. Get the new login even when the old access token has not expired yet, and
  /// retire app-servers that cached it after their current turns. A reset also wakes sessions once its allowance is read.
  async sharedChanged(id: string, reset: boolean): Promise<void> {
    // (changed on its host, signed in anew there perhaps: what its host says is asked again, nothing kept against it)
    this.authRevoked.delete(id);
    const profile = this.profile(id);
    if (profile?.enabled === false) await this.deps.hub?.profileGone?.(id);
    if (!profile || !borrowed(profile)) return;
    if (accessKind(profile) !== "subscription") {
      if (profile.enabled !== false) await this.check(id, stationLang()).catch(() => undefined);
      return;
    }
    if (!this.deps.shared) return;
    // A host that signed out may have no login to lend; its status must still reach the copy.
    await this.checkBorrowed(profile, stationLang(), true);
    if (profile.runtime === "codex" && this.deps.shared.lendCodex) {
      const before = this.borrowedLogin.has(id) ? this.borrowedLogin.get(id) : await lentLoginVersion(profile.home);
      if (!this.borrowedLogin.has(id)) this.borrowedLogin.set(id, before ?? null);
      await this.deps.shared.lendCodex(profile, true);
      const after = await lentLoginVersion(profile.home);
      if (before !== after) {
        this.loginGeneration.set(id, (this.loginGeneration.get(id) ?? 0) + 1);
        await this.codexAccountRead(profile, true).catch(() => {});
        await this.deps.codex?.()?.loginChanged?.(id);
      }
      this.borrowedLogin.set(id, after);
      await this.readQuota(id, true);
      if (reset) await this.deps.hub?.allowanceReset?.(id);
    }
    // What the host lends now written to its file; its sessions' processes, which never read it again (agents/agy.ts
    // AGY_LENT_RENEW_MS), start again on it: another account signed in on the host is used from their next turn.
    if (profile.runtime === "agy" && this.deps.shared.lendAgy) {
      await this.deps.shared.lendAgy(profile, true).catch(() => {});
      await this.deps.hub?.profileLoginChanged?.(id);
    }
    await this.checkBorrowed(profile, stationLang(), true);
  }

  /// Another station redeemed a reset on a subscription hosted here.
  async sharedQuotaReset(id: string): Promise<void> {
    await this.readQuota(id, true);
    await this.deps.hub?.allowanceReset?.(id);
  }

  /// The first follower of the events came: allowances older than a round are asked again now.
  followed() {
    this.refreshQuotas(false);
  }

  /// POST /profiles/:id/reset-quota: a subscription's rate-limit reset redeemed (OpenAI's, Claude's), under the request's
  /// key; `kind`, of the allowance's `resets` (none: any, as a core from before kinds asks).
  async resetQuota(id: string, key: string, lang: Lang = stationLang(), kind: string | null = null): Promise<Json> {
    const t = (k: string) => tr(lang, k);
    const profile = this.profile(id);
    if (!profile) throw new Refusal(404, t("station.profile.notFound"));
    if ((profile.runtime !== "codex" && profile.runtime !== "claude") || accessKind(profile) !== "subscription") throw new Refusal(400, t("station.quota.resetSubscriptionOnly"));
    if (!this.resetFn) throw new Refusal(503, t("station.quota.resetUnsupported"));
    const result = await this.resetFn(profile, key, kind);
    const quota = await this.readQuota(id, true).catch((error) => {
      log.warn("accounts", "could not read the allowance after a reset", { profile: id, error: (error as Error).message });
      return null;
    });
    const outcome = result?.outcome;
    if (outcome === "reset" || outcome === "alreadyRedeemed") {
      // An old idempotency key may be replayed after the account has run out again.
      if (outcome === "reset" || (quota?.state === "ok" && quota.windows.every((w) => w.usedPercent < 100))) {
        await this.deps.shared?.quotaReset?.(profile, key).catch((error) => {
          log.warn("accounts", "could not record a shared allowance reset", { profile: id, error: (error as Error).message });
        });
        await this.deps.hub?.allowanceReset?.(id);
      }
      return result;
    }
    if (outcome === "nothingToReset") throw new Refusal(409, t("station.quota.nothingToReset"));
    if (outcome === "noCredit") throw new Refusal(409, t("station.quota.noCredit"));
    if (outcome === "unavailable") throw new Refusal(409, t("station.quota.resetUnavailable"));
    throw new Refusal(502, t("station.quota.resetUnconfirmed"));
  }

  // ── the automatic decisions ──

  /// The models the decisions may ask: each a usable profile's verified one, with the profiles that have it.
  decisionModels(): { id: string; name: string; profiles: string[] }[] {
    const models = new Map<string, string[]>();
    for (const profile of this.profiles()) {
      if (profile.enabled === false) continue;
      const health = this.deps.hub?.accounts.healthOf(profile.id) ?? this.health(profile.id);
      if (!usable(health)) continue;
      const capability: Capability | undefined = health.check?.decision;
      if (!capability) continue;
      for (const model of [...(capability.models ?? []), ...(capability.model ? [capability.model] : [])]) {
        if (!resolvedModel(profile, capability, model)) continue;
        const names = models.get(model) ?? [];
        if (!names.includes(profile.name)) names.push(profile.name);
        models.set(model, names);
      }
    }
    return [...models.entries()].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)).map(([id, profiles]) => ({ id, name: modelName(id), profiles }));
  }

  /// PUT /automatic-decisions (a workspace manager's).
  async putAutomaticDecisions(input: Record<string, unknown>, viewer: Viewer, lang: Lang = stationLang()): Promise<void> {
    if (!manages(viewer)) throw new Refusal(403, tr(lang, "station.decisions.managersOnly"));
    try {
      checkAutomaticDecisions(input);
    } catch {
      throw new Refusal(400, tr(lang, "station.decisions.badSettings"));
    }
    const rule: Json = isObject(input.completion) ? input.completion : {};
    const config = { completion: { enabled: rule.enabled === true, model: typeof rule.model === "string" ? rule.model : null } };
    if (config.completion.enabled && !this.decisionModels().some((m) => m.id === config.completion.model)) {
      throw new Refusal(400, tr(lang, "station.decisions.pickVerified"));
    }
    await this.save(viewer, "automatic decisions", (raw) => {
      raw.automaticDecisions = config;
    });
  }

  /// PUT /archiving (a workspace manager's): how chats go to the archive on their own (sessions/lifecycle.ts
  /// autoArchive): `days` idle (0: never), `slackDays` for Slack's sessions stopped at a block, and `reviewed`: only
  /// those the archive review recommended.
  async putArchiving(input: Record<string, unknown>, viewer: Viewer, lang: Lang = stationLang()): Promise<void> {
    if (!manages(viewer)) throw new Refusal(403, tr(lang, "station.archiving.managersOnly"));
    const days = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v) && v >= 0 && v <= 365;
    if (!days(input.days) || !days(input.slackDays) || typeof input.reviewed !== "boolean") throw new Refusal(400, tr(lang, "station.archiving.badSettings"));
    const { days: idle, slackDays, reviewed } = input;
    await this.save(viewer, "archiving", (raw) => {
      raw.autoArchiveDays = idle;
      raw.slackArchiveDays = slackDays;
      raw.autoArchiveReviewed = reviewed;
    });
  }

  /// PUT /auto-chats (a workspace manager's): whether this station accepts automatically assigned new chats and presets
  /// (`acceptAutoChats` in config.json; opt-in, defaults to false).
  async putAutoChats(input: Record<string, unknown>, viewer: Viewer, lang: Lang = stationLang()): Promise<void> {
    if (!manages(viewer)) throw new Refusal(403, tr(lang, "station.autoChats.managersOnly"));
    if (typeof input.enabled !== "boolean") throw new Refusal(400, tr(lang, "station.autoChats.badSettings"));
    const enabled = input.enabled;
    await this.save(viewer, "auto chats", (raw) => {
      raw.acceptAutoChats = enabled;
    });
  }

  /// POST /automatic-decisions/review: the done chats no decision has answered, reviewed now in the background; how many.
  async reviewUndecided(viewer: Viewer, lang: Lang = stationLang()): Promise<number> {
    if (!manages(viewer)) throw new Refusal(403, tr(lang, "station.decisions.managersOnlyReview"));
    const review = this.deps.reviewUndecided;
    if (!review) throw new Refusal(503, tr(lang, "station.decisions.reviewUnsupported"));
    if (!this.settings().automaticDecisions.completion.enabled) throw new Refusal(409, tr(lang, "station.decisions.enableFirst"));
    const queued = await review();
    if (!this.settings().automaticDecisions.completion.enabled) throw new Refusal(409, tr(lang, "station.decisions.enableFirst"));
    if (queued === null) throw new Refusal(409, tr(lang, "station.decisions.modelUnavailable"));
    return queued;
  }

  /// POST /automatic-decisions/refresh: every profile checked again (four at a time).
  async refreshDecisionModels(viewer: Viewer, lang: Lang = stationLang()) {
    if (!manages(viewer)) throw new Refusal(403, tr(lang, "station.decisions.managersOnlyRefresh"));
    await this.checkEach(this.profiles().filter((p) => p.enabled !== false).map((p) => p.id), lang);
  }

  // ── what the overview shows of the accounts ──

  /// What the session's chat is called in the chat list; its key only where it has no chat.
  private chatTitleOf(session: string): string {
    const chat = this.deps.store.sessionChat(session);
    if (chat) return titleOf(chat.thread, chat.firstText, null);
    return this.deps.store.getSession(session)?.title ?? session;
  }

  /// The overview's `automaticDecisions`. A workspace overview supplies its own policy and names, and filters the
  /// already limited recent checks before naming them; direct callers keep the station-wide policy and checks.
  automaticDecisionsView(viewer: Viewer, options: { includePolicy?: boolean; visible?: (session: string) => boolean; title?: (session: string) => string } = {}): Json {
    if (!manages(viewer)) return { canEdit: false, settings: {}, models: [], recent: [] };
    const lang = stationLang();
    const titles = new Map<string, string>();
    const title = (session: string) => {
      let t = titles.get(session);
      if (t === undefined) titles.set(session, (t = options.title?.(session) ?? this.chatTitleOf(session)));
      return t;
    };
    // For pages from before the policy: the checks one by one.
    const recent = this.deps.store.recentDecisions().filter((row: Json) => options.visible?.(typeof row.session === "string" ? row.session : "") ?? true).map((row: Json) => {
      const d = row.detail ?? {};
      const session = typeof row.session === "string" ? row.session : "";
      return {
        id: row.id, session, title: title(session), at: row.at, label: checkLabel(d, lang),
        accepted: d.accepted ?? null, model: d.model ?? null, profile: d.profile ?? null, elapsedMs: d.elapsedMs ?? null, error: d.error ?? null,
      };
    });
    const settings = this.deps.config.raw()?.automaticDecisions;
    const completion = isObject(settings?.completion) ? settings.completion : {};
    return {
      canEdit: true,
      canReview: this.deps.reviewUndecided !== undefined,
      settings: { completion: { enabled: completion.enabled === true, model: typeof completion.model === "string" ? completion.model : null } },
      models: this.decisionModels(),
      recent,
      ...(options.includePolicy === false ? {} : { policy: this.policyView(title) }),
    };
  }

  /// The archive policy as the pages show it: its words, its options each with the chats the checks of the last days
  /// put there (by their latest check), who changed it last, and how many checks failed.
  private policyView(title: (session: string) => string): Json {
    const store = this.deps.store;
    const saved = store.archivePolicy();
    const policy = policyFrom(saved);
    const latest = new Map<string, Json>();
    for (const row of store.latestDecisionsSince(store.now() - POLICY_DAYS * 86_400_000)) if (typeof row.session === "string") latest.set(row.session, row);
    const byOption = new Map<string, Json[]>();
    let failed = 0;
    for (const [session, row] of [...latest.entries()].reverse()) {
      const picked = pickedOf(row.detail);
      if (picked === null) {
        failed++;
        continue;
      }
      const list = byOption.get(picked) ?? [];
      list.push({ session, at: row.at, recommended: row.detail?.accepted === true });
      byOption.set(picked, list);
    }
    const by = saved?.change.by;
    return {
      text: policy.policy,
      options: policy.options.map((o) => {
        const chats = byOption.get(o.id) ?? [];
        // Named only as shown: each name is a lookup of the chat's (a week's checks came to many chats on a station).
        return { ...o, count: chats.length, chats: chats.slice(0, POLICY_CHATS).map(({ session, ...c }) => ({ session, title: title(session), ...c })) };
      }),
      days: POLICY_DAYS,
      checked: latest.size,
      failed,
      edited: saved !== null,
      change: saved
        ? { at: saved.change.at, summary: saved.change.summary, by: by?.kind === "agent" ? { kind: "agent", session: by.session, title: title(by.session), runtime: store.getSession(by.session)?.runtime ?? null } : { kind: "person", email: by?.email ?? null, name: by?.name ?? null } }
        : null,
    };
  }

  /// PUT /automatic-decisions/policy (a workspace manager's): the policy in words and its options; the done chats are
  /// checked again under it.
  putArchivePolicy(input: Record<string, unknown>, viewer: Viewer, lang: Lang = stationLang()) {
    if (!manages(viewer)) throw new Refusal(403, tr(lang, "station.decisions.managersOnlyPolicy"));
    let changed: string | null;
    try {
      changed = savePolicy(this.deps.store, input, { kind: "person", email: viewer.email, name: viewer.name || null });
    } catch (e) {
      throw new Refusal(400, (e as Error).message);
    }
    if (changed !== null) this.deps.reviewUndecided?.();
  }

  /// The overview's `profiles`: the station's own to the members of every workspace it is in alike (`serves` says
  /// whether the viewer's may run on each, so a manager can still turn a withheld one on), and a copy of another
  /// station's only to the workspaces that station lends it in: its account is not theirs to see elsewhere.
  /// `workspaces` says which joined ones' chats run on each. With no viewer, all of them.
  profilesView(viewer?: Viewer): Json[] {
    const config = this.settings();
    const joined = viewer !== undefined && viewer.home === false ? viewer.workspace : null;
    const home = this.deps.workspaces?.()[0] ?? null;
    const others = this.joined();
    const visible = viewer === undefined
      ? config.profiles
      : config.profiles.filter((p) => !borrowed(p) || allowedIn(p, joined, home ?? viewer.workspace));
    this.readHomesSoon(visible);
    const views = visible.map((p) => {
      const says = this.homeSays(p);
      const kind = accessKind(p);
      const a: Json = isObject(p.access) ? p.access : {};
      const via = profileVia(p);
      const custom: Record<string, string> = isObject(p.env) ? (p.env as Record<string, string>) : {};
      const env = Object.keys(custom)
        .sort()
        .map((key) => ({ key, secret: secretKey(key), value: secretKey(key) ? mask(custom[key]!) : custom[key] }));
      const check = this.checks.get(p.id);
      let checkView: Json = null;
      if (check) {
        // A copy of its top alone, what is left out taken off it (made for each viewer each time the overview is: a deep
        // copy of every profile's models held the main thread, 2026-11-23); what it shares is never written in place.
        const { fusion: _, ...shown } = check as Json;
        checkView = shown;
        if (isObject(checkView.decision)) {
          const { fingerprint: _fingerprint, ...decision } = checkView.decision;
          checkView.decision = decision;
        }
        if (check.decision && check.decision.fingerprint !== fingerprint(p)) checkView.decision = { state: "pending", detail: "Profile 已修改，等待自动检查", reason: "changed" };
      }
      return {
        id: p.id, name: p.name, runtime: p.runtime ?? null, service: p.service ?? null, runtimes: p.runtimes,
        email: kind === "subscription" ? this.email(p, says) : kind === "service" || a.login === true ? says.email : null,
        // A provider's key says `env` where an older core reads it; the provider next to it tells a newer core it is not.
        access: {
          kind: kind === "api-provider" ? "env" : kind, key: mask(String(a.key ?? "").trim()),
          provider: via.provider ?? null, endpoint: via.endpoint ?? null, protocol: via.protocol ?? null,
          service: p.service ?? null,
          // Its key is the token of a sign-in to the OpenCode Console or to Kimi (signed in again, not replaced).
          login: (kind === "opencode-go" || kimiSignedIn(p)) && a.login === true,
        },
        home: p.home, homeExists: says.exists, model: p.model ?? null,
        // What it runs, and of those what config.json names (by hand where its provider lists none: those can be taken off).
        models: p.models, named: p.named,
        env,
        // Connects whose sessions can run on it: of its runtime, and its models have theirs.
        usedBy: p.enabled === false ? [] : config.connects.filter((c) => p.runtimes.includes(c.bind.runtime) && serves(p, c.bind.model)).map((c) => c.id),
        loginCommand: kind === "subscription" ? loginCommand(p.runtime, p.home, p.machine === true) : "",
        machine: p.machine === true,
        enabled: p.enabled !== false,
        backgroundOnMessage: p.backgroundOnMessage,
        // Whether its quota is asked of Google's API beside the CLI: an Antigravity CLI subscription's alone.
        ...(kind === "subscription" && p.runtime === "agy" ? { directQuota: p.directQuota !== false } : {}),
        ...(p.maxConcurrentSessions !== undefined ? { maxConcurrentSessions: p.maxConcurrentSessions } : {}),
        ...(p.newAccountProtection === true && p.maxConcurrentSessions !== undefined ? { newAccountProtection: true } : {}),
        fast: takesFast(p) && (!fastNeedsCredits(p) || this.quotas.get(p.id)?.extraUsage === true) ? p.fast === true : null,
        check: checkView,
        login: this.logins.get(p.id),
        quota: this.quotas.get(p.id) ?? null,
        // Shared with the workspace's other stations, or another station's (absent: neither; old clients ignore it).
        share: this.deps.shared?.view(p, viewer?.workspace ?? null) ?? null,
        // Whether its login can be lent to the workspace's other stations (share/index.ts shareRefusal): its page says
        // so where it cannot, rather than a switch that is refused.
        shareable: shareRefusal(p, this.services) === null,
        // The joined workspaces whose sessions may run on it, and whether the viewer's may.
        workspaces: others.filter((w) => allowedIn(p, w, home)),
        serves: allowedIn(p, joined, home),
      };
    });
    if (joined === null) return views;
    // The connects it runs of the viewer's workspace (those of others are not shown there).
    const connects = new Set(config.connects.filter((c) => c.workspace === joined).map((c) => c.id));
    return views.map((v) => ({ ...v, usedBy: v.usedBy.filter((c: string) => connects.has(c)) }));
  }

  /// GET /profiles/pace: the hours of the accounts the viewer's workspace may run on (as `serves` says in profilesView).
  /// What it read is kept (`#paceRead`): an allowance kept or a profile deleted reads that profile's hours again alone;
  /// the calls' are read again once a minute at most, the last two hours of them (what is still written to); both all
  /// PACE_HOURS every SPEND_FULL_REFRESH_MS or when the clock goes back.
  paceView(viewer?: Viewer): PaceView {
    const now = this.deps.store.now();
    const minute = Math.floor(now / 60_000);
    const nowHour = Math.floor(now / HOUR_MS);
    const fromHour = nowHour - PACE_HOURS;
    const read = this.#paceRead;
    // (each mark of a profile's allowance let go only once what it asks for is read: a read that throws leaves it)
    if (read === null) {
      const { quotas, spend, speed } = this.deps.store.profileHours(nowHour);
      this.#paceRead = { now, quotaHour: nowHour, quotas, spendMinute: minute, spendHour: nowHour, spendFullAt: now, spend, speed };
      this.#dirtyQuotaProfiles.clear();
    } else {
      let updated = false;
      const nextMinute = read.spendMinute !== minute;
      // All PACE_HOURS read again: every SPEND_FULL_REFRESH_MS, and when the clock went back (a jump of two hours on
      // is past SPEND_FULL_REFRESH_MS too).
      const full = nextMinute && (now - read.spendFullAt >= SPEND_FULL_REFRESH_MS || now < read.spendFullAt || nowHour < read.spendHour);
      if (full || nowHour < read.quotaHour) {
        // (the allowances' hours too: what another process wrote, the station before in a handover, shows by then)
        read.quotas = this.deps.store.profileQuotaHours(fromHour);
        read.quotaHour = nowHour;
        this.#dirtyQuotaProfiles.clear();
        updated = true;
      } else {
        if (nowHour > read.quotaHour) {
          read.quotas = read.quotas.filter((q) => q.hour >= fromHour);
          read.quotaHour = nowHour;
          updated = true;
        }
        if (this.#dirtyQuotaProfiles.size > 0) {
          const dirty = [...this.#dirtyQuotaProfiles];
          const fresh = dirty.flatMap((id) => this.deps.store.profileQuotaHoursFor(id, fromHour));
          const gone = new Set(dirty);
          read.quotas = [...read.quotas.filter((q) => !gone.has(q.profile)), ...fresh].sort(byProfileHour);
          for (const id of dirty) this.#dirtyQuotaProfiles.delete(id);
          updated = true;
        }
      }
      if (nextMinute) {
        if (full) {
          read.spend = this.deps.store.profileSpendHours(fromHour);
          read.spendFullAt = now;
        } else {
          // (the hours before the last two as read, those that are still in PACE_HOURS; the last two read again)
          const tailFrom = Math.max(fromHour, nowHour - 1);
          const tail = this.deps.store.profileSpendHours(tailFrom);
          read.spend = [...read.spend.filter((s) => s.hour >= fromHour && s.hour < tailFrom), ...tail].sort(byProfileHour);
        }
        read.speed = this.deps.store.profileSpeedQuarters((nowHour - SPEED_QUARTER_HOURS) * 4);
        read.spendMinute = minute;
        read.spendHour = nowHour;
        updated = true;
      }
      if (updated) read.now = now;
    }
    const joined = viewer !== undefined && viewer.home === false ? viewer.workspace : null;
    const home = this.deps.workspaces?.()[0] ?? null;
    const config = this.settings();
    const serves = new Set(config.profiles.filter((p) => allowedIn(p, joined, home)).map((p) => p.id as string));
    const kept = this.#paceRead!;
    return paceView(kept.now, kept, (id) => serves.has(id));
  }

  /// What GET /profiles/pace last read of the store: the allowances' hours as of `quotaHour`, the calls' as of the
  /// minute `spendMinute` (in the hour `spendHour`; all PACE_HOURS of them read at `spendFullAt`), and `now`, when it
  /// last changed.
  #paceRead: {
    now: number;
    quotaHour: number;
    quotas: QuotaHour[];
    spendMinute: number;
    spendHour: number;
    spendFullAt: number;
    spend: SpendHour[];
    speed: SpeedQuarter[];
  } | null = null;
  /// The profiles whose allowances' hours were kept or forgotten since GET /profiles/pace read them.
  #dirtyQuotaProfiles = new Set<string>();
  /// The outdated models' last unchecking, its config.json edit waited for as the accounts close.
  #unchecking: Promise<void> = Promise.resolve();

  /// GET /profiles/:id/fusion: the Devin Fusion catalog from the profile's last check (null on borrowed or non-Devin profiles).
  fusionView(id: string): Json {
    const profile = this.profile(id);
    if (!profile) throw new Refusal(404, `unknown profile ${id}`);
    if (borrowed(profile)) return null;
    return this.checks.get(id)?.fusion ?? null;
  }

  /// The workspaces the station joined, its home one left out.
  private joined(): string[] {
    return (this.deps.workspaces?.() ?? []).slice(1);
  }

  /// The account a subscription profile is signed in as: a borrowed one's as its host said, one on the machine's login
  /// the machine's (Claude's is in the keychain, not its home), the rest their home's. The workspace's list tells the
  /// same account on several stations by it.
  private email(p: Json, says: HomeSays): string | null {
    if (borrowed(p)) return typeof (p.share as Json)?.email === "string" ? (p.share as Json).email : null;
    if (p.machine === true) return this.machineLogins().find((l) => l.runtime === p.runtime)?.email ?? says.email;
    return says.email;
  }

  /// What profile `p`'s home says, as last read. One not read yet (or since what it is read for changed) is read off the
  /// thread, what it found told (`homesReadSoon`, which the overview waits for first, has it read by then); meanwhile
  /// nothing said of its account, its home taken as there.
  private homeSays(p: Profile): HomeSays {
    const asked = JSON.stringify(homeAsked(p));
    const kept = this.homes.get(p.id);
    if (kept?.asked === asked) return kept.says;
    void this.homeRead(p, true);
    return { exists: true, email: null };
  }

  /// The homes of the profiles not read yet (or since what they are read for changed), read off the thread: what the
  /// overview waits for before it is made.
  async homesReadSoon(): Promise<void> {
    const profiles = this.profiles().filter((p) => this.homes.get(p.id)?.asked !== JSON.stringify(homeAsked(p)));
    await Promise.all(profiles.map((p) => this.homeRead(p, false)));
  }

  /// Profile `p`'s home read off the thread and kept, unless a sign-in changed it meanwhile (read again at the next
  /// view); `tell`: what it found told, as the view that asked showed nothing yet.
  private homeRead(p: Profile, tell: boolean): Promise<void> {
    const asked = JSON.stringify(homeAsked(p));
    const key = `${p.id}\n${asked}`;
    const since = this.homesChanged;
    const under = this.homeReads.get(key);
    // One begun before a sign-in changed the home finds what is let go: a new one is begun, not waited for.
    if (under && under.since === since) {
      under.tell ||= tell;
      return under.read;
    }
    const entry = { since, tell, read: Promise.resolve() };
    entry.read = homeSaysSoon(p, this.services)
      .then((says) => {
        if (this.homesChanged !== since) return;
        this.homes.set(p.id, { asked, says });
        if (entry.tell && !this.closed) this.changed();
      })
      .catch(() => {})
      .finally(() => {
        if (this.homeReads.get(key) === entry) this.homeReads.delete(key);
      });
    this.homeReads.set(key, entry);
    return entry.read;
  }

  /// Every profile's home read again off the thread, once HOMES_EVERY_MS have passed since the last time; what changed
  /// is told (the overview is made again).
  private readHomesSoon(profiles: Profile[]): void {
    const now = this.background.now();
    if (this.homesReading || now - this.homesRead < HOMES_EVERY_MS) return;
    this.homesReading = true;
    this.homesRead = now;
    void (async () => {
      let changed = false;
      for (const p of profiles) {
        const asked = JSON.stringify(homeAsked(p));
        const since = this.homesChanged;
        const says = await homeSaysSoon(p, this.services).catch(() => null);
        const kept = this.homes.get(p.id);
        // Not shown yet (read as it is), or changed meanwhile: left as it is.
        if (says === null || kept === undefined || kept.asked !== asked || this.homesChanged !== since) continue;
        if (kept.says.exists === says.exists && kept.says.email === says.email) continue;
        this.homes.set(p.id, { asked, says });
        changed = true;
      }
      return changed;
    })()
      .then((changed) => changed && this.changed())
      .catch(() => {})
      .finally(() => (this.homesReading = false));
  }

  /// The overview's `logins`: sign-ins for new profiles.
  loginsView(_viewer?: Viewer): Json[] {
    return [...this.pending.entries()].map(([id, p]) => ({ id, runtime: p.runtime ?? null, ...(p.service !== undefined ? { service: p.service } : {}), job: this.logins.get(id), created: p.created, error: p.error }));
  }

  /// The overview's `machineLogins`.
  machineLogins(): MachineLogin[] {
    return this.machine?.get() ?? [];
  }

  /// The overview's `apiProviders`: the providers a key can be added for (not the two kinds from before the list).
  apiProviders(): Json[] {
    return SOURCES.filter((s) => !(s.id in LEGACY)).map((s) => ({ id: s.id, name: s.name, group: groupOf(s.id) }));
  }

  /// The overview's `profileServices`: the registered non-agent service profile adapters.
  profileServices(): string[] {
    return [...this.services.keys()];
  }

  /// Ids a new profile may not take: the profiles' own, those being made, and every home on disk (a deleted profile's
  /// home stays). The profiles looked at once the homes are listed.
  private async takenIdsSoon(): Promise<Set<string>> {
    const homes = await readdir(join(this.deps.data, "homes")).catch(() => [] as string[]);
    return new Set([...this.profiles().map((p) => p.id), ...this.making, ...homes]);
  }
}

/// Makes the station's accounts (start() it once wired).
export const makeAccounts = (deps: AccountsDeps) => new Accounts(deps);

/// A profile moved to another runtime: refused when it is the last one of a runtime that
/// connects run.
function lastOfRuntime(raw: Json, runtime: Runtime, id: string, lang: Lang) {
  const profiles: Json[] = Array.isArray(raw?.profiles) ? raw.profiles : [];
  if (profiles.some((p) => p?.id !== id && runtimesFor(p?.access, p?.runtime).includes(runtime))) return;
  const users = (Array.isArray(raw?.connects) ? raw.connects : [])
    .filter((c: Json) => c?.bind?.runtime === runtime)
    .map((c: Json) => (typeof c?.slack?.botName === "string" && c.slack.botName !== "" ? c.slack.botName : c.id));
  if (users.length > 0) throw new Error(tr(lang, "station.profile.lastForRuntime", { runtime, users: users.join(tr(lang, "station.list.separator")) }));
}

/// The account a subscription home is signed in as, when its files say (Codex's id token, Claude's account record),
/// read without holding the station's thread (fs/promises), as `emailKept` keeps it.
export const accountEmailSoon = (runtime: Runtime, home: string): Promise<string | null> => emailInSoon(accountFiles(runtime, home));

/// What the first of `files` that names an account says, as `emailKept` keeps it.
async function emailInSoon(files: AccountFile[]): Promise<string | null> {
  for (const file of files) {
    let stamp: string;
    try {
      const st = await stat(file.path);
      stamp = `${st.size}:${st.mtimeMs}`;
    } catch {
      continue;
    }
    const kept = emails.get(file.path);
    const text = kept?.stamp === stamp ? null : await readFile(file.path, "utf8").catch(() => null);
    const email = emailKept(file, stamp, () => text ?? "");
    if (email !== null) return email;
  }
  return null;
}

/// Where a home keeps whose account it is signed in to, by its runtime, and how each file says it, in the order looked
/// at.
type AccountFile = { path: string; email: (text: string) => string | null };
/// Where an OpenCode Console sign-in says whose account it is (console.ts).
const consoleFile = (home: string): AccountFile => ({ path: join(home, CONSOLE_FILE), email: (text) => consoleIn(text)?.email ?? null });
function accountFiles(runtime: Runtime, home: string): AccountFile[] {
  if (runtime === "grok") return [{ path: grokAuthFile(home), email: grokEmailIn }];
  if (runtime === "cursor") return [{ path: cursorAuthFile(home), email: (text) => cursorIn(text)?.email ?? null }];
  if (runtime === "devin") return [{ path: devinAccountFile(home), email: devinNotedIn }];
  if (runtime === "agy") return [{ path: agyToken(home), email: agyEmailIn }, { path: agyAccountFile(home), email: devinNotedIn }];
  if (runtime === "codex") {
    const email = (text: string) => {
      const claims = codexClaimsIn(text);
      const said = claims?.email ?? claims?.["https://api.openai.com/profile"]?.email;
      return typeof said === "string" ? said : null;
    };
    return [{ path: join(home, "auth.json"), email }];
  }
  const email = (text: string) => {
    const said = JSON.parse(text)?.oauthAccount?.emailAddress;
    return typeof said === "string" ? said : null;
  };
  return [join(home, ".claude.json"), join(home, "claude.json")].map((path) => ({ path, email }));
}

/// What each account file says, read again only once it changed (its size or time): Claude's is megabytes Claude Code
/// rewrites as it goes, and every overview asks it of every profile.
const emails = new Map<string, { stamp: string; email: string | null }>();
function emailKept(file: AccountFile, stamp: string, text: () => string): string | null {
  const kept = emails.get(file.path);
  if (kept?.stamp === stamp) return kept.email;
  let email: string | null = null;
  try {
    email = file.email(text());
  } catch {}
  emails.set(file.path, { stamp, email });
  return email;
}

/// A slug for an id: lower case, runs of anything else as one dash, at most `max` long.
export function slug(text: string, max: number): string {
  let out = "";
  for (const c of text.toLowerCase()) {
    if (/^[a-z0-9]$/.test(c)) out += c;
    else if (!out.endsWith("-")) out += "-";
  }
  return [...out.replace(/^-+|-+$/g, "")].slice(0, max).join("").replace(/-+$/, "");
}

/// The first of base, base-2, base-3 … not taken.
export function unique(base: string, taken: Set<string>): string {
  let id = base;
  for (let n = 2; taken.has(id); n++) id = `${base}-${n}`;
  return id;
}

/// Whether a variable holds a secret (shown masked).
export const secretKey = (key: string) => ["KEY", "TOKEN", "SECRET", "PASSWORD", "AUTH"].some((w) => key.toUpperCase().includes(w));

/// Masks a secret for the pages: its first five and last four characters.
export const mask = maskValue;

/// A check in a line, for the pages that list them one by one: the option the model picked and what came of it, or
/// that it failed. Checks from before the policy had options name the fixed four's.
export function checkLabel(d: Json, lang: Lang): string {
  const selected = typeof d?.result?.selected === "string" ? d.result.selected : null;
  if (selected === null) return tr(lang, "station.decisions.failed");
  const name = typeof d.option?.name === "string" ? d.option.name : (LEGACY_OPTIONS[selected]?.name ?? selected);
  return `${name} · ${tr(lang, d.accepted === true ? "station.decisions.archive" : "station.decisions.keep")}`;
}

/// The id of the option a check picked, null when it failed.
const pickedOf = (d: Json): string | null => (typeof d?.result?.selected === "string" ? d.result.selected : null);

/// Whether two lists of found models are the same, in order (`Accounts.found`).
function sameModels(a: readonly string[] | null, b: readonly string[] | null): boolean {
  if (a === b) return true;
  if (a === null || b === null || a.length !== b.length) return false;
  return a.every((m, i) => m === b[i]);
}
