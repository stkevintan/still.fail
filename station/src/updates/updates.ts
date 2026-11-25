// Which versions this station and the machine's runtimes (Claude Code, Codex) are, whether newer ones are out, and
// updating them from the pages (whose rules this keeps):
// - The station: its release says its version in BUILD (`0.1.<n>`); the latest is what still.fail cloud serves as
//   releases/station.json, or on the test channel (`updateChannel: "beta"` in config.json; a release installed from the
//   beta and not told otherwise is on it) releases/station-beta.json, only as its signature verifies (signed.ts,
//   scripts/release-sign.ts: a feed that does not is no newer release). Switched back from the beta, the older stable
//   release is offered as going back (`downgrade`), only then. It is updated as `stillfail update` does (release.ts):
//   by the installer this release carries, told what the new one must hash to, run apart from the station; only a
//   release the installer put in <data>/app is (the desktop app's comes with the desktop app, a clone's with the
//   clone). With `autoUpdate: true` it does so by itself (never back from the beta). A reported installer failure gets
//   one delayed retry, then waits for a newer release; vault work still holds both attempts back.
//   With a delta from the build it runs (release.ts takeDelta), the station downloads it and applies it first (the
//   applying in a process apart, release.ts applyApart), shown as the installer's download step is, and hands the
//   installer what it made (STILLFAIL_ARCHIVE in a temporary stillfail-handed directory); the update is answered as
//   started meanwhile. A delta not used is a line in the log, and the installer downloads the release as without.
// - Claude Code and Codex: `--version`, and the latest their npm packages say (Devin: its installer's manifest); updated
//   the way each was installed.
//   Cursor is no command: its SDK's package, in the station's own npm prefix (agents/cursor.ts), its version the package's.
//   Running agents go on with what they started with; the next process starts the new one.
//
// The TS release is updated by the same files as the Rust one was:
// run/update.started (this side's, so the process that runs after a handover or restart follows the update to its
// end), run/update.step (download | handoff | drain | restart, the installer's), run/update.log and run/update.exit,
// and the installer is given STILLFAIL_CHANNEL and STILLFAIL_DATA as it was (and now what release.ts
// gives it). Where it
// differs (see also the report in the station-ts work):
// - The release is `--app` (Paths.app), not two up from dist/admin; BUILD and CHANNEL are read from it the same way.
// - The installer's handoff (swap <data>/app, SIGUSR2 to the pid in run/station.json) reaches the launcher, which
//   starts a new Node from the swapped-in <app>/node/bin/node <app>/station/main.js and lets this one go; the launcher
//   binary itself is not replaced (pid kept: that is what the installer checks). The new Node follows update.started
//   as the Rust binary did after exec. The old Node never sees update.exit (written after the handover).
// - The installer is started in a session of its own (Node's `detached`, setsid) rather than a process group of its
//   own: either way launchd/systemd stopping the station does not take it along. On Windows by a scheduled task of
//   its own (startInstaller).
// - The installer's progress is heard by watching run/ (fs.watch), with a slow look as a safety net and for the
//   drain's count of running turns, in place of a look every second.
// - Words the pages show are kept as catalog keys and said in each reader's language (the Rust said them once, in the
//   language of whoever caused the reading).
// - `stillfail-station channel` reaches this process as the launcher's `{"op":"hup"}` (it holds SIGHUP for it):
//   `answerChannelAsk`.

import { CLOUD_ORIGIN, CloudTransport, cloudEntry } from "../cloud/transport.ts";
import { createHash, randomBytes } from "node:crypto";
import { access, mkdir, readFile, realpath, rename, rm, stat, writeFile } from "node:fs/promises";
import { type FSWatcher, createReadStream, createWriteStream, realpathSync, watch } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, parse } from "node:path";
import { type Clock, Effect, Fiber, Schedule } from "effect";
import { Fibers } from "../ops/fibers.ts";
import type { ConfigFile } from "../ops/config.ts";
import { type Lang, stationLang, tr } from "../ops/i18n.ts";
import { log } from "../ops/log.ts";
import { forgetShellPaths, withShellCommand } from "../ops/shell-path.ts";
import type { RuntimeKind } from "../agents/runtime.ts";
import { platform as machine } from "../platform/index.ts";
import { holding, onLetGo } from "./holds.ts";
import { AGY_MANIFESTS, watchAgyDownload } from "./agy-download.ts";
import { type Back, applyApart, backTo, earlierIn, planBack, planUpdate, readFeed, readIncluded, takeArchive, takeDelta, verifiedOrNull, type Plan } from "./release.ts";
import { allowed, type Release } from "../../../shared/release-signed.ts";
import {
  type AutoUpdateWhen, type OverrideMeta, type ReleaseIncluded, type WaitCondition,
  conditionsMet, formatWaitCondition, needsIncluded, parseAutoUpdateWhen, parseWaitCondition, readOverrideSoon, readOverrideSync,
} from "./override.ts";
import { SDK_PACKAGE, sdkPrefix, sdkVersionSoon } from "../agents/cursor.ts";
import { canSwitchCodexSoon, captureCodexSoon, codexBinarySoon, hasCodexHostSoon, missingCodexHost, restoreCodex, switchCodex, type CodexEntry } from "./codex-repair.ts";
import {
  DEVIN_MANIFEST, type Env, type How, type Kind, KINDS, NotFinished, type OwnNode, RUNTIMES, Unable, findCommandSoon, howToInstallSoon, howToUpdateSoon,
  isNpmInstall, kindCommand, kindName, kindPackage, linkBesideNpm, npmInstallSoon, ownNode, ownNodeHome, pinNpmVersion, putOwnNodes, putOwnNodesSoon,
  removeOwnNodeLinks, run, runLines,
} from "./runtimes.ts";
import {
  type Channel, type Words, INSTALLING, channelFrom, downloading, newer, offer, platform, releaseChannel, sameWords, say, stationDownloadPercent,
  stationVersion, stationVersionSoon, stepOf, tail, versionIn,
} from "./versions.ts";

/// A line of what the pages show (client/core-ts/src/shapes/schema.ts SoftwareVersion; fields that are none are left out, as serde does).
export type SoftwareVersion = {
  id: string;
  name: string;
  installed: boolean;
  version?: string;
  latest?: string;
  newer: boolean;
  downgrade: boolean;
  /// The station's: the releases it can go back to (older than the one it runs, which its channel's feed names as
  /// before its latest), newest first.
  earlier?: string[];
  channel?: string;
  auto?: boolean;
  /// The station's, updating by itself turned off as it went back: the release it left, past which it turns on again.
  autoAfter?: string;
  overridden?: true;
  overrideBase?: string;
  overrideKind?: "bundle" | "overlay";
  overrideNote?: string;
  autoWhen?: string[];
  autoHeld?: true;
  updatable: boolean;
  repairable?: boolean;
  note?: string;
  state: "idle" | "updating" | "failed";
  progress?: string;
  percent?: number;
  done?: string;
  message?: string;
  checkedAt?: number;
};

/// How long things take, given so tests can be quick.
export type Timing = {
  /// How often the runtimes' latest versions (other registries': npm, Devin's manifest) are read again. The station's
  /// own release is read as still.fail cloud says one is out (`check`), never on a timer.
  every: number;
  /// How long a runtime's update may take; the station's installer.
  runtimeLimit: number;
  stationLimit: number;
  /// How long how a station's update went is shown after it ended.
  doneShown: number;
  /// The slow look at an update under way (beside the watch on run/).
  followLook: number;
  /// How long the station's delta may take (its download and applying) before the installer downloads the release.
  deltaLimit: number;
};

export const TIMING: Timing = {
  every: 6 * 3600_000,
  runtimeLimit: 10 * 60_000,
  stationLimit: 20 * 60_000,
  doneShown: 10 * 60_000,
  followLook: 5_000,
  deltaLimit: 10 * 60_000,
};

/// A transient handover failure can clear; try once more without repeatedly starting a broken release.
const STATION_RETRY_MS = 60_000;
const STATION_RETRY_BACKOFF = Schedule.min([Schedule.exponential("2 minutes"), Schedule.spaced("15 minutes")]); // timer: backoff after a failed update

export type UpdatesOptions = {
  /// The release this station runs from (`--app`).
  app: string;
  data: string;
  config: ConfigFile;
  /// The still.fail cloud it is in, when it is (cloud.json's origin).
  origin: () => string | null | undefined;
  /// The station's environment (its PATH finds the runtimes); process.env when none.
  env?: Env;
  /// Where the runtimes' latest versions are read: npm's registry.
  registry?: string;
  /// Where the Devin CLI's latest version is read: its installer's manifest (runtimes.ts DEVIN_MANIFEST).
  devinManifest?: string;
  /// Where Claude Code's builds are said (its installer's downloads, for how much of one is in).
  claudeReleases?: string;
  /// Where the Antigravity CLI's installer reads its builds (agy-download.ts AGY_MANIFESTS), for how much of one is in.
  agyManifests?: string;
  /// Where Node's builds are (nodejs.org's), for npm where the machine has none (runtimes.ts OwnNode).
  nodeDist?: string;
  /// How many turns run now (the hub's), for what a drain waits on and an automatic update waits for.
  running?: () => number;
  /// The station's own release only (a rig runs no runtime: rig/main.ts): the runtimes' versions are not read.
  stationOnly?: boolean;
  /// Told when a runtime was installed or updated here (the machine's logins read again), and whether it is there now.
  runtimeChanged?: (kind: RuntimeKind, installed: boolean, replaced: boolean) => void;
  /// The Codex installation's code-mode host (tests can supply a probe).
  codexHostProbe?: typeof missingCodexHost;
  /// How the station's installer is started (`startInstaller`; tests give one that ends before it returns).
  startInstaller?: typeof startInstaller;
  /// The launcher's start of the installer, where it offers one (launcher.ts `runInstaller`): what starts it when this
  /// process's own start does not.
  launcherInstaller?: (script: string, env: Record<string, string>) => void;
  timing?: Partial<Timing>;
  /// Its time (a TestClock in tests).
  clock?: Clock.Clock;
  /// The keys its releases are signed with, by id (signed.ts trustedKeys: tests give their own).
  trusted?: Map<string, string>;
};

type Item = {
  installed: boolean;
  version: string | null;
  latest: string | null;
  how: How | null;
  repairable: boolean;
  /// Why it cannot be updated from here.
  note: Words | null;
  /// When an update started, while it runs.
  updating: number | null;
  /// A runtime's, while it updates: where it is.
  progress: Words | null;
  /// The station's, while it updates: the installer's step (its words are said as the pages read them).
  step: string | null;
  /// While what it downloads comes in: how much of it is (0–100).
  percent: number | null;
  /// The station's, a while after an update ended well: how it went.
  done: Words | null;
  failed: Words | null;
  /// The station's: the channel whose latest `latest` is.
  channel: Channel | null;
  /// The station's: the releases before the latest its feed names, verified (release.ts earlierIn).
  earlier: Release[];
};

const empty = (): Item => ({ installed: false, version: null, latest: null, how: null, repairable: false, note: null, updating: null, progress: null, step: null, percent: null, done: null, failed: null, channel: null, earlier: [] });

/// What the station's update started from the pages leaves in <data>/run/update.started, for whichever process runs
/// the station when it ends.
type Started = { at: number; from: string | null };

/// Starts the installer `script` apart from the station (platform.startInstaller: in the background of a shell, or on
/// Windows by a scheduled task of its own), its exit to run/update.exit and what it said to run/update.log. Whether it
/// was started.
export const startInstaller = (script: string, runDir: string, env: Record<string, string>, app: string): Promise<boolean> =>
  machine.startInstaller(script, runDir, env, app);

const UA = { "user-agent": "stillfail-station" };

/// The build of a station's version (0.<m>.<n>: n), when it is one.
const buildOf = (version: string | null | undefined): number | null => {
  const n = Number(/^0\.\d+\.(\d+)$/.exec(version ?? "")?.[1] ?? NaN);
  return Number.isSafeInteger(n) ? n : null;
};

async function fetchJson(url: string, ms = 15_000): Promise<any> {
  const response = await fetch(url, { headers: UA, signal: AbortSignal.timeout(ms) });
  if (!response.ok) throw new Error(`${url}: ${response.status}`);
  return response.json();
}

/// A file's SHA-256, as SHASUMS256.txt says it (hex).
function sha256(file: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const hash = createHash("sha256");
    createReadStream(file)
      .on("data", (chunk) => hash.update(chunk))
      .on("end", () => resolve(hash.digest("hex")))
      .on("error", reject);
  });
}

async function fetchText(url: string): Promise<string> {
  const response = await fetch(url, { headers: UA, signal: AbortSignal.timeout(15_000) });
  if (!response.ok) throw new Error(`${url}: ${response.status}`);
  return response.text();
}

/// A runtime's install that failed, its words said in each reader's language.
class Failed extends Error {
  readonly words: Words;
  constructor(words: Words) {
    super(say(words, "en"));
    this.words = words;
  }
}

/// An error whose words are said in the asker's language.
const refused = (lang: Lang, key: string, args?: Record<string, unknown>) => new Error(tr(lang, key, args));

const canonical = (p: string): Promise<string | null> => realpath(p).catch(() => null);

/// `canonical` as the part is made, before it serves.
const canonicalNow = (p: string): string | null => {
  try {
    return realpathSync(p); // sync: read once as the station starts, before it serves (Updates' first line)
  } catch {
    return null;
  }
};

/// Why the station cannot be updated from here (none where it can): its release is not the one the installer put in
/// <data>/app, or it is in no still.fail cloud.
function stationNote(app: string, real: string | null, installed: string | null, origin: string | null): Words | null {
  const note: Words | null =
    real !== null && real === installed ? null
    : app.includes(".app/Contents") ? { key: "station.updates.withDesktop" }
    : { key: "station.updates.notInstaller" };
  return note === null && origin === null ? { key: "station.updates.notJoined" } : note;
}

/// How long the first reading waits to be tried again after it failed (a later one waits `every`).
const FIRST_RETRY_MS = 60_000;
/// How often a download's progress is told at most: every `changed` reaches `events.overviewChanged`, which sends each
/// connected stream its whole overview again, so a download told at every percent sent a hundred overviews to every
/// viewer within seconds. Its start, its end and every other change are told at once.
const PROGRESS_NOTIFY_MS = 2_000;

/// Words saying how much of a download is in (versions.ts `downloading`).
const isDownloadWords = (w: Words | null): boolean => w !== null && "key" in w && (w.key === "station.updates.downloadingSized" || w.key === "station.updates.downloadingSoFar");

export class Updates {
  readonly app: string;
  readonly data: string;
  private config: ConfigFile;
  private cloudTransport: CloudTransport;
  private cloudRequest = (url: string, init?: RequestInit): Promise<Response> => this.origin() === CLOUD_ORIGIN ? this.cloudTransport.fetch(url, init) : fetch(url, init);
  private origin: () => string | null | undefined;
  private env: Env;
  private registry: string;
  private devinManifest: string;
  private claudeReleases: string;
  private agyManifests: string;
  private nodeDist: string;
  /// Node being put in place for npm (installNode), while it is.
  private nodeInstalling: Promise<void> | null = null;
  private timing: Timing;
  private trusted: Map<string, string> | undefined;
  /// The channel the running release came from: as it says (CHANNEL), else the channel it started on.
  readonly installed: Channel;
  /// What the running release's CHANNEL says (null: none), read as it is made: the release is the process's own, so
  /// what the pages read each time (`channel`) looks at no file.
  private readonly release: Channel | null;
  /// The Node version npm is installed with where the machine has none (`ownNodeSoon`), read once.
  private nodeVersion: Promise<string> | null = null;
  /// The asks of `stillfail-station channel` answered one after another (two SIGHUPs never interleave).
  private answering: Promise<void> = Promise.resolve();
  private items: Record<Kind, Item> = { station: empty(), claude: empty(), codex: empty(), dsh: empty(), grok: empty(), cursor: empty(), devin: empty(), hermes: empty(), agy: empty(), pi: empty(), copilot: { ...empty(), installed: true } };
  private checkedAt: number | null = null;
  private checking: Promise<void> | null = null;
  /// The reading asked for while one went on, after it (`check`).
  private again: Promise<void> | null = null;
  /// Version refusals from several conversations join one update of the machine's Codex.
  private codexRecovery: Promise<void> | null = null;
  private codexUpdateSerial = 0;
  private listeners = new Set<() => void>();
  /// The version the station's last update in this process went for.
  tried: string | null = null;
  /// A failed version whose retry is due, and the version whose retry was attempted in this process.
  private retryDue: string | null = null;
  private retried: string | null = null;
  private retrySerial = 0;
  private lastCheck: number | null = null;
  private running: () => number;
  private runtimeChanged: (kind: RuntimeKind, installed: boolean, replaced: boolean) => void;
  private codexHostProbe: typeof missingCodexHost;
  private startInstaller: typeof startInstaller;
  private launcherInstaller: ((script: string, env: Record<string, string>) => void) | null;
  // Long-lived work, and time: fibers in this part's scope on its clock, ended with it.
  private fibers: Fibers;
  private closed = false;
  /// When a download's progress was last told (`notifyProgress`), and the telling of a later one held back till then.
  private progressTold = -Infinity;
  private progressLater: (() => void) | null = null;
  /// Started: it reads on its own (made but not started, as in tests, it reads only when asked).
  private started = false;
  private tick: Fiber.Fiber<unknown, unknown> | null = null;
  private unlisten: (() => void) | null = null;
  private unhold: (() => void) | null = null;
  private lastSetting = "";
  /// The update of the station followed now: what ends following it.
  private following: (() => void) | null = null;
  /// How many updates this process has followed (`follow`): one started here while `followStarted` read run/ is the
  /// one to follow, not what it read.
  private follows = 0;

  /// The runtimes whose versions are read (none on a rig).
  private readonly kinds: readonly RuntimeKind[];
  /// Local override metadata (<app>/OVERRIDE), read at construction and refreshed in readStation.
  private override: OverrideMeta | null;
  /// Verified latest release on the active channel, and its verified included manifest (when needed by autoUpdateWhen).
  private latestRelease: Release | null = null;
  private latestIncluded: ReleaseIncluded | null = null;
  private includedCache = new Map<string, ReleaseIncluded>();

  constructor(o: UpdatesOptions) {
    this.app = o.app;
    this.data = o.data;
    this.config = o.config;
    this.origin = o.origin;
    this.cloudTransport = new CloudTransport(() => cloudEntry(this.config.raw()), o.clock);
    this.env = o.env ?? process.env;
    // The Nodes it installed for npm, on its PATH (and what it starts): what they installed is found there.
    removeOwnNodeLinks(this.env, this.data);
    putOwnNodes(this.env, this.data);
    this.registry = o.registry ?? "https://registry.npmjs.org";
    this.devinManifest = o.devinManifest ?? DEVIN_MANIFEST;
    this.claudeReleases = o.claudeReleases ?? "https://downloads.claude.ai/claude-code-releases";
    this.agyManifests = o.agyManifests ?? AGY_MANIFESTS;
    this.nodeDist = o.nodeDist ?? "https://nodejs.org/dist";
    this.timing = { ...TIMING, ...o.timing };
    this.trusted = o.trusted;
    this.running = o.running ?? (() => 0);
    this.kinds = o.stationOnly === true ? [] : RUNTIMES;
    this.runtimeChanged = o.runtimeChanged ?? (() => {});
    this.codexHostProbe = o.codexHostProbe ?? missingCodexHost;
    this.startInstaller = o.startInstaller ?? startInstaller;
    this.launcherInstaller = o.launcherInstaller ?? null;
    // Read before an update can replace the release.
    this.release = releaseChannel(this.app);
    this.installed = this.release ?? channelFrom(this.config.raw(), null);
    this.override = readOverrideSync(this.app);
    // The station itself is there from the start: what it runs and whether it is updated from here are its own, read
    // now (the pages said 未安装 until every runtime's version was read, and for good where one of those never ended).
    this.items.station = {
      ...empty(),
      installed: true,
      version: stationVersion(this.app) ?? null,
      note: stationNote(this.app, canonicalNow(this.app), canonicalNow(join(this.data, "app")), this.origin() || null),
    };
    this.fibers = new Fibers("updates", o.clock);
  }

  // ---- what is wired in after it is made (the hub, the event streams, the machine's logins) ----

  /// How many turns run now, for what an update waits on when it has to restart the station.
  countRunning(running: () => number) {
    this.running = running;
  }

  /// What to do when a runtime was installed or updated from here.
  onRuntimeChanged(f: (kind: RuntimeKind, installed: boolean, replaced: boolean) => void) {
    this.runtimeChanged = f;
  }

  /// A runtime a session found not on PATH: read again when the pages still say it is there (removed since the last
  /// check), so what they offer is installing it.
  missing(kind: RuntimeKind) {
    if (!this.items[kind].installed || this.items[kind].updating !== null) return;
    this.spawn(async () => {
      const read = await this.readRuntime(kind);
      if (this.items[kind].updating === null) this.set(kind, (i) => Object.assign(i, read));
    });
  }

  /// Hears each change of what `get` says; gives the function that stops it.
  changes(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  /// The channel the station is updated on now.
  channel(): Channel {
    return channelFrom(this.config.raw(), this.release);
  }

  /// Whether the station updates itself (`autoUpdate` in its config; off unless someone turned it on).
  auto(): boolean {
    return this.config.raw()?.autoUpdate === true;
  }

  /// The release the station went back from while it updated itself (`autoUpdateAfter`): updating by itself is off
  /// until a newer one than it is out, then on again (resumeAuto). Only while it is off.
  autoAfter(): string | null {
    const after = this.config.raw()?.autoUpdateAfter;
    return !this.auto() && typeof after === "string" && buildOf(after) !== null ? after : null;
  }

  /// Conditional auto-update rule (`autoUpdateWhen` in config.json), when set.
  autoWhen(): AutoUpdateWhen | null {
    return parseAutoUpdateWhen(this.config.raw());
  }

  /// Local override metadata (<app>/OVERRIDE), when this station runs a locally replaced build.
  overrideMeta(): OverrideMeta | null {
    return this.override;
  }

  // ---- the life of the part ----

  /// Reads them at once and every few hours after (every ten minutes while the station updates itself); an update of
  /// the station started before this process (by the one it took over from, or the one before a restart) is followed
  /// to its end. The config edited elsewhere (the channel, updating by itself) is heard as it changes.
  start() {
    if (this.closed) return;
    this.lastSetting = this.setting();
    this.unlisten = this.config.listen(() => {
      const now = this.setting();
      if (now === this.lastSetting) return;
      this.lastSetting = now;
      this.changed();
      this.schedule();
    });
    // What held an update back (holds.ts) let go: one that waited goes ahead.
    this.unhold = onLetGo(() => {
      if (!this.closed) this.autoUpdate("what held the update back ended");
    });
    this.started = true;
    this.spawn(() => this.reconcileOverrideWait());
    this.spawn(() => this.followStarted());
    this.schedule();
  }

  /// Stops what it does on its own (an installer it started goes on: it is not this process's).
  async close() {
    if (this.closed) return;
    this.closed = true;
    this.unlisten?.();
    this.unhold?.();
    this.following?.();
    this.following = null;
    this.progressLater?.();
    this.progressLater = null;
    await this.cloudTransport.close();
    await this.fibers.close();
  }

  private setting() {
    return `${this.channel()} ${this.auto()} ${this.autoAfter()} ${JSON.stringify(this.autoWhen())}`;
  }

  private spawn(f: () => Promise<unknown>) {
    if (this.closed) return;
    this.fibers.spawn(f);
  }

  /// Runs `f` after `ms` in this part's scope; the function returned cancels it.
  private later(ms: number, f: () => unknown): () => void {
    if (this.closed) return () => {};
    return this.fibers.after(ms, f);
  }

  /// The next look: when the next reading is due.
  private schedule() {
    if (this.closed || !this.started) return;
    if (this.tick) void Effect.runFork(Fiber.interrupt(this.tick));
    // Not read yet (the first reading failed): tried again within a minute, not hours later.
    const every = this.checkedAt === null ? Math.min(FIRST_RETRY_MS, this.timing.every) : this.timing.every;
    const due = this.lastCheck === null ? 0 : Math.max(0, this.lastCheck + every - this.fibers.now());
    this.tick = this.fibers.fork(Effect.sleep(due).pipe(Effect.andThen(Effect.promise(() => this.look()))));
  }

  private async look() {
    this.tick = null;
    try {
      const every = this.timing.every;
      // A reading under way (asked from a page) is waited for, not looked at again and again. Until the station's release
      // was read (the first reading, or one that failed), it is read too; those after, the runtimes'.
      if (this.checking) await this.checking;
      else if (this.lastCheck === null || this.items.station.channel === null) await this.check();
      else if (this.fibers.now() - this.lastCheck >= every) await this.check(false);
      this.autoUpdate("a newer release read");
    } catch (e) {
      // Not read: tried again when the next reading is due (within a minute while none was), not at once.
      this.lastCheck = this.fibers.now();
      log.warn("updates", "the updates not looked at", { error: (e as Error).message });
      // Always: `tick` may still name the fiber this look runs in (one due at once runs it as it is forked, before
      // `schedule` keeps it), and a first reading that failed was then never looked at again.
      this.schedule();
      return;
    }
    if (this.tick === null) this.schedule();
  }

  private changed() {
    // (what it tells includes any progress held back)
    this.progressLater?.();
    this.progressLater = null;
    for (const f of this.listeners) {
      try {
        f();
      } catch {}
    }
  }

  /// Tells a download's progress, already kept in `items`: at once when `immediate`, else at most every
  /// PROGRESS_NOTIFY_MS, the latest told when that much has passed.
  private notifyProgress(immediate = false) {
    if (immediate) {
      this.progressTold = this.fibers.now();
      this.changed();
      return;
    }
    const wait = this.progressTold + PROGRESS_NOTIFY_MS - this.fibers.now();
    if (wait <= 0) {
      this.progressTold = this.fibers.now();
      this.changed();
    } else if (this.progressLater === null) {
      // timer: a debounce of a download's progress.
      this.progressLater = this.later(wait, () => {
        this.progressLater = null;
        if (this.closed) return;
        this.progressTold = this.fibers.now();
        this.changed();
      });
    }
  }

  /// How much of the station's own download (a delta, or a release gone back to) is in.
  private sayStationPercent(percent: number) {
    const item = this.items.station;
    if (item.updating === null || item.percent === percent) return;
    const first = item.percent === null;
    item.percent = percent;
    this.notifyProgress(first || percent === 0 || percent === 100);
  }

  private set(kind: Kind, f: (i: Item) => void) {
    f(this.items[kind]);
    this.changed();
  }

  // ---- what the pages read and ask ----

  /// What the pages show, one line each, in `lang`.
  get(lang: Lang = stationLang()): SoftwareVersion[] {
    const channel = this.channel();
    const own = KINDS.map((kind) => {
      const item = this.items[kind];
      const station = kind === "station";
      // Read from another channel than the one it is on now: not yet known.
      const latest = station && item.channel !== channel ? null : item.latest;
      const [isNewer, downgrade] = station
        ? offer(item.version, latest, channel, this.installed)
        : [item.version !== null && latest !== null && newer(item.version, latest), false];
      // Only where it can be updated from here.
      const here = station && item.note === null && (item.version !== null || this.override !== null);
      const when = station ? this.autoWhen() : null;
      const autoWhen = when && when.wait.length > 0 ? when.wait.map(formatWaitCondition) : undefined;
      const autoHeld = station && ((this.override !== null && (when === null || when.wait.length === 0)) || (when !== null && when.wait.length === 0)) ? true : undefined;
      const progress = item.updating === null ? null : station ? this.progressOf(item.step) : item.progress;
      const line: SoftwareVersion = {
        id: kind,
        name: kindName(kind),
        installed: item.installed,
        version: item.version ?? undefined,
        latest: latest ?? undefined,
        newer: isNewer,
        downgrade,
        earlier: here && station ? this.earlier() : undefined,
        channel: here ? channel : undefined,
        auto: here ? this.auto() : undefined,
        autoAfter: here ? (this.autoAfter() ?? undefined) : undefined,
        overridden: station && this.override !== null ? true : undefined,
        overrideBase: station ? (this.override?.baseVersion ?? undefined) : undefined,
        overrideKind: station ? this.override?.kind : undefined,
        overrideNote: station ? this.override?.note : undefined,
        autoWhen,
        autoHeld,
        updatable: item.how !== null || here,
        repairable: item.repairable || undefined,
        note: item.note ? say(item.note, lang) : undefined,
        state: item.updating !== null ? "updating" : item.failed !== null ? "failed" : "idle",
        progress: progress ? say(progress, lang) : undefined,
        percent: item.updating !== null && item.percent !== null ? item.percent : undefined,
        done: item.done ? say(item.done, lang) : undefined,
        message: item.failed ? say(item.failed, lang) : undefined,
        checkedAt: this.checkedAt ?? undefined,
      };
      if (line.earlier?.length === 0) delete line.earlier;
      for (const k of Object.keys(line) as (keyof SoftwareVersion)[]) if (line[k] === undefined) delete line[k];
      return line;
    });
    return own;
  }

  /// The releases the station can go back to now (release.ts backTo), as read from the channel it is on.
  private earlier(): string[] {
    const item = this.items.station;
    if (item.channel !== this.channel()) return [];
    return backTo(item.earlier, buildOf(item.version), platform()).map((r) => r.version);
  }

  /// Reads every version and what is out, now (once at a time); a newer release of the station's channel is installed
  /// when it updates itself. `station`: its own release read too (at the start, asked from a page, a release said to
  /// be out, an update ended), else the runtimes' only. Asked while a reading goes on: the runtimes' alone is that
  /// reading; with the station's, one more after it (that reading took the station's release as it began, maybe before
  /// what this is asked for, and goes on while the runtimes' versions come), every such ask meanwhile the same one.
  check(station = true): Promise<void> {
    if (this.checking) {
      if (!station) return Promise.resolve();
      this.again ??= this.checking.catch(() => {}).then(() => {
        this.again = null;
        return this.check();
      });
      return this.again;
    }
    forgetShellPaths();
    this.checking = this.read(station).finally(() => (this.checking = null));
    return this.checking;
  }

  private async read(withStation: boolean) {
    // The station's release is taken as soon as it is read, and updated to where it updates itself: a runtime whose
    // version is slow to come (a command that hangs) holds back neither it nor the pages.
    const station = withStation
      ? (async () => {
          let read = await this.readStation(this.channel());
          // Put on another channel while it was read: read from that one.
          while (read.channel !== this.channel()) read = await this.readStation(this.channel());
          this.applyRead("station", read);
          this.changed();
          await this.resumeAuto();
          this.autoUpdate("a newer release out");
        })()
      : Promise.resolve();
    const [, ...runtimes] = await Promise.all([station, ...this.kinds.map((kind) => this.safeReadRuntime(kind))]);
    for (const [i, kind] of this.kinds.entries()) this.applyRead(kind, runtimes[i]!);
    this.checkedAt = this.fibers.now();
    this.lastCheck = this.fibers.now();
    this.changed();
    await this.resumeAuto();
    this.autoUpdate("a newer release out");
    this.schedule();
  }

  /// What was read of `kind` taken: one that is updating keeps what it was until it is done; but one not yet read (an
  /// update this process took over following) is read.
  private applyRead(kind: Kind, read: Item) {
    const item = this.items[kind];
    if (item.updating === null) this.items[kind] = { ...read, failed: item.failed, done: item.done };
    else if (!item.installed) this.items[kind] = { ...read, updating: item.updating, progress: item.progress, step: item.step, percent: item.percent };
  }

  /// `readRuntime`, where it fails what it was before: one runtime that cannot be read does not end the reading.
  private async safeReadRuntime(kind: Kind): Promise<Item> {
    try {
      return await this.readRuntime(kind);
    } catch (e) {
      log.warn("updates", "the runtime's version not read", { runtime: kind, error: (e as Error).message });
      return { ...this.items[kind] };
    }
  }

  private async readStation(channel: Channel): Promise<Item> {
    this.override = await readOverrideSoon(this.app);
    const version = (await stationVersionSoon(this.app)) ?? null;
    const app = await canonical(this.app);
    const origin = this.origin() || null;
    const note = stationNote(this.app, app, app === null ? null : await canonical(join(this.data, "app")), origin);
    let latest: string | null = null;
    let earlier: Release[] = [];
    let release: Release | null = null;
    let included: ReleaseIncluded | null = null;
    if (origin !== null) {
      try {
        const said = await readFeed(channel, origin, 15_000, this.cloudRequest);
        // Only a release whose words verify is one (none is newer than a feed that does not).
        const verified = verifiedOrNull(said, this.trusted);
        release = verified.release;
        if (release === null) log.warn("updates", "the station's latest release does not verify: not offered", { channel, why: verified.why });
        latest = release?.version ?? null;
        const before = earlierIn(said, this.trusted);
        if (before.why.length > 0) log.warn("updates", "releases before the latest do not verify: not offered", { channel, why: before.why });
        earlier = before.releases;
        const when = this.autoWhen();
        if (release !== null && when !== null && when.wait.length > 0 && needsIncluded(when.wait) && release.included !== undefined) {
          const cached = this.includedCache.get(release.included.sha256);
          if (cached !== undefined) {
            included = cached;
          } else {
            try {
              included = await readIncluded(origin, release.included, this.cloudRequest);
              if (this.includedCache.size >= 16) this.includedCache.clear();
              this.includedCache.set(release.included.sha256, included);
            } catch (e) {
              log.warn("updates", "the station's included manifest not read", { file: release.included.file, error: (e as Error).message });
            }
          }
        }
      } catch (e) {
        log.warn("updates", "the station's latest release not read", { error: (e as Error).message });
      }
    }
    if (channel === this.channel()) {
      this.latestRelease = release;
      this.latestIncluded = included;
    }
    return { ...empty(), installed: true, version, latest, note, channel, earlier };
  }

  private async readRuntime(kind: Kind): Promise<Item> {
    if (kind === "cursor") return this.readCursor();
    // Copilot runs in-process through the SDK bundled with the station: there is no CLI to find or install.
    if (kind === "copilot") return { ...empty(), installed: true, version: null, latest: null, how: null, note: { key: "station.updates.copilotBundled" } };
    const env = await withShellCommand(kindCommand(kind), this.env);
    const found = await findCommandSoon(kindCommand(kind), env);
    let version: string | null = null;
    if (found) {
      try {
        const [ok, out] = await run(found.onPath, ["--version"], env, 20_000);
        if (ok) version = versionIn(out);
      } catch {}
    }
    let latest: string | null = null;
    if (kind === "hermes") return { ...empty(), installed: found !== null, version, latest: null, how: null, note: { key: "station.updates.hermesExternal" } };
    // The Antigravity CLI says no latest version but to itself (`agy update`, which gets it).
    if (kind === "agy") return { ...empty(), installed: found !== null, version, latest: null, how: found ? ((await howToUpdateSoon(kind, found, env)) as How) : ((await howToInstallSoon(kind, this.env)) as How) };
    try {
      // Devin's builds are its installer's, said in its manifest; the others' npm packages.
      const said = await fetchJson(kind === "devin" ? this.devinManifest : `${this.registry}/${kindPackage(kind)}/latest`);
      latest = typeof said?.version === "string" ? said.version : null;
    } catch (e) {
      log.warn("updates", "the runtime's latest version not read", { runtime: kind, error: (e as Error).message });
    }
    const missing = kind === "codex" && found && version !== null ? await this.codexHostProbe(found, env) : null;
    const npmEnv = missing ? await withShellCommand("npm", env) : env;
    const npm = missing ? await npmInstallSoon(npmEnv, await this.ownNodeSoon(), ["install", "-g", "@openai/codex@latest"], kindName("codex")) : null;
    const repairable = missing !== null && found !== null && !(npm instanceof Unable) && (await canSwitchCodexSoon(found, env));
    const how = missing ? null : found ? await howToUpdateSoon(kind, found, env) : await howToInstallSoon(kind, this.env, await this.ownNodeSoon());
    return {
      ...empty(),
      installed: found !== null,
      version,
      latest,
      how: how instanceof Unable ? null : how,
      repairable,
      note: missing ? { key: repairable ? "station.updates.codexMissingHostRepair" : "station.updates.codexMissingHost", args: { path: missing.helper } } : how instanceof Unable ? { key: how.key, args: how.args } : null,
    };
  }

  /// The Node npm is installed with where the machine has none: the version the station runs on (its release's
  /// NODE_VERSION, read once: the release is the process's own).
  private async ownNodeSoon(): Promise<OwnNode | null> {
    this.nodeVersion ??= readFile(join(this.app, "NODE_VERSION"), "utf8").then((v) => v.trim() || process.versions.node, () => process.versions.node);
    return ownNode(this.data, await this.nodeVersion);
  }

  /// Cursor's SDK, a package npm keeps in the station's own prefix (agents/cursor.ts): installed and updated by the same
  /// npm install there.
  private async readCursor(): Promise<Item> {
    const version = await sdkVersionSoon(this.data);
    let latest: string | null = null;
    try {
      const said = await fetchJson(`${this.registry}/${kindPackage("cursor")}/latest`);
      latest = typeof said?.version === "string" ? said.version : null;
    } catch (e) {
      log.warn("updates", "the runtime's latest version not read", { runtime: "cursor", error: (e as Error).message });
    }
    const how = await npmInstallSoon(this.env, await this.ownNodeSoon(), ["install", "-g", "--prefix", sdkPrefix(this.data), `${SDK_PACKAGE}@latest`], kindName("cursor"));
    return { ...empty(), installed: version !== null, version, latest, how: how instanceof Unable ? null : how, note: how instanceof Unable ? { key: how.key, args: how.args } : null };
  }

  /// Turns updating by itself on or off (as someone asked, from a page): kept in its config; turned on, what is out is
  /// read at once, and a newer release installed.
  async setAuto(on: boolean, lang: Lang = stationLang()) {
    this.refuseStationNote(lang);
    if (this.override !== null && on) throw refused(lang, "station.updates.overrideAutoRefused");
    const existingWhen = this.autoWhen();
    const clearRestore = !on && this.override !== null && existingWhen !== null && existingWhen.restoreAuto;
    const clearWhen = on && this.override === null && this.config.raw()?.autoUpdateWhen !== undefined;
    if (this.auto() !== on || this.config.raw()?.autoUpdateAfter !== undefined || clearWhen || clearRestore) {
      await this.config.updateSoon((raw) => {
        raw.autoUpdate = on;
        delete raw.autoUpdateAfter;
        if (on && this.override === null) delete raw.autoUpdateWhen;
        if (clearRestore && raw.autoUpdateWhen && typeof raw.autoUpdateWhen === "object") {
          (raw.autoUpdateWhen as Record<string, unknown>).restoreAuto = false;
        }
      });
      this.lastSetting = this.setting();
      log.info("updates", "the station's updating by itself set", { on });
      this.changed();
    }
    if (on) await this.check();
    this.schedule();
  }

  /// Sets or clears conditional auto-update wait rules (`autoUpdateWhen`).
  async setWait(wait: WaitCondition[] | null, lang: Lang = stationLang()) {
    this.refuseStationNote(lang);
    const checkAfter = await this.keepWait(wait);
    if (checkAfter) await this.check();
    this.schedule();
  }

  /// Persists `autoUpdateWhen` without refusing on station note (shared by `setWait` and SIGHUP `wait-ask`).
  /// Returns whether a feed check should run next.
  async keepWait(wait: WaitCondition[] | null): Promise<boolean> {
    const existing = this.autoWhen();
    if (wait === null) {
      if (existing === null) return false;
      const restore = this.override === null && existing.restoreAuto;
      await this.config.updateSoon((raw) => {
        delete raw.autoUpdateWhen;
        if (restore) raw.autoUpdate = true;
      });
      this.lastSetting = this.setting();
      log.info("updates", "the station's auto-update wait cleared", { restoredAuto: restore });
      this.changed();
      return restore;
    }
    const restoreAuto = existing !== null ? existing.restoreAuto : this.auto();
    const next: AutoUpdateWhen = {
      wait,
      restoreAuto,
      ...(this.override !== null ? { forOverride: true } : {}),
      setAt: this.fibers.now(),
    };
    await this.config.updateSoon((raw) => {
      raw.autoUpdate = false;
      raw.autoUpdateWhen = next;
    });
    this.lastSetting = this.setting();
    log.info("updates", "the station's auto-update wait set", { wait: wait.map(formatWaitCondition), forOverride: this.override !== null });
    this.changed();
    return true;
  }

  /// Puts the station on `channel` (as someone asked, from a page): kept in its config, and what is out read again from
  /// that channel.
  async setChannel(channel: Channel, lang: Lang = stationLang()) {
    this.refuseStationNote(lang);
    await this.keepChannel(channel);
    await this.check();
  }

  /// Keeps `channel` in the config, when it is another one than now.
  async keepChannel(channel: Channel): Promise<void> {
    if (this.channel() === channel) return;
    await this.config.updateSoon((raw) => {
      raw.updateChannel = channel;
    });
    this.lastSetting = this.setting();
    log.info("updates", "the station's update channel set", { channel });
    this.changed();
  }

  /// `stillfail-station channel <name>` asked the running station (SIGHUP, through the launcher's `hup`): takes the
  /// channel in run/channel-ask, keeps it, reads what is out on it, and answers in run/channel-answer. Asks heard
  /// while one is answered wait for it (each reads the ask the one before left).
  answerChannelAsk(): Promise<void> {
    const runDir = join(this.data, "run");
    const answered = this.answering.then(async () => {
      await answerChannelAsk(runDir, async (channel) => {
        await this.keepChannel(channel);
        this.spawn(() => this.check());
      });
      await answerWaitAsk(runDir, async (wait) => {
        const checkAfter = await this.keepWait(wait);
        if (checkAfter) this.spawn(() => this.check());
      });
    });
    this.answering = answered.catch(() => {});
    return answered;
  }

  private refuseStationNote(lang: Lang) {
    const note = this.items.station.note;
    if (note) throw refused(lang, "station.list.labeled", { name: kindName("station"), note: say(note, lang) });
  }

  // ---- updating by itself ----

  /// The runtime being installed or updated now, when one is: the station is not updated meanwhile (its update hands
  /// over to another process or restarts, and the install would go on unfollowed).
  private runtimeUpdating(): Kind | null {
    return RUNTIMES.find((k) => this.items[k].updating !== null) ?? null;
  }

  /// The version the station updates itself to now, when it does: it updates itself, can be updated from here, is not
  /// updating, and its channel's latest is newer (not an older stable one back from the beta) and not one it already
  /// went for, unless that failure's retry is due. Running turns are not waited for: the update hands them over (or,
  /// restarting, to the next start). What is not handed over is (holds.ts: a command run with a vault grant, whose
  /// proxy would go with this process).
  toUpdateTo(): string | null {
    if (holding() > 0) return null;
    const item = this.items.station;
    if (item.note !== null || item.updating !== null || item.channel !== this.channel() || this.runtimeUpdating() !== null) return null;
    if (item.latest === null) return null;
    const when = this.autoWhen();
    if (this.override !== null) {
      if (when === null || when.wait.length === 0) return null;
      if (this.latestRelease === null || this.latestRelease.version !== item.latest) return null;
      if (!allowed(this.latestRelease, buildOf(item.version), this.channel(), this.installed, this.override.baseBuild)) return null;
      if (!conditionsMet(when.wait, this.latestRelease, this.latestIncluded)) return null;
      return this.tried !== item.latest || this.retryDue === item.latest ? item.latest : null;
    }
    if (when !== null) {
      if (when.wait.length === 0) return null;
      if (this.latestRelease === null || this.latestRelease.version !== item.latest) return null;
      if (!conditionsMet(when.wait, this.latestRelease, this.latestIncluded)) return null;
      const [isNewer] = offer(item.version, item.latest, this.channel(), this.installed);
      return isNewer && (this.tried !== item.latest || this.retryDue === item.latest) ? item.latest : null;
    }
    if (!this.auto()) return null;
    const [isNewer] = offer(item.version, item.latest, this.channel(), this.installed);
    return isNewer && (this.tried !== item.latest || this.retryDue === item.latest) ? item.latest : null;
  }

  /// Clears `autoUpdateWhen` and restores `restoreAuto` once an override is gone or a non-override wait condition is
  /// already satisfied by the running official version.
  private async reconcileOverrideWait() {
    if (this.override !== null) return;
    const when = this.autoWhen();
    if (when === null) return;
    let satisfied = when.forOverride === true;
    if (!satisfied && when.wait.length > 0) {
      const version = this.items.station.version;
      const curBuild = buildOf(version);
      if (version !== null && this.latestRelease !== null && this.latestRelease.version === version && conditionsMet(when.wait, this.latestRelease, this.latestIncluded)) {
        satisfied = true;
      } else if (curBuild !== null && !needsIncluded(when.wait)) {
        satisfied = when.wait.every((c) => {
          if (c.kind === "version") {
            const n = buildOf(c.value);
            return n !== null && curBuild >= n;
          }
          if (c.kind === "after") {
            const n = buildOf(c.value);
            return n !== null && curBuild > n;
          }
          return false;
        });
      }
    }
    if (!satisfied) return;
    await this.config.updateSoon((raw) => {
      delete raw.autoUpdateWhen;
      if (when.restoreAuto) raw.autoUpdate = true;
    });
    this.lastSetting = this.setting();
    log.info("updates", "auto-update wait settled on official release", { restoredAuto: when.restoreAuto, forOverride: when.forOverride === true });
    this.changed();
  }

  /// Updating by itself, turned off as the station went back (backStation), on again once its channel's latest is
  /// newer than the release it left.
  private async resumeAuto() {
    await this.reconcileOverrideWait();
    const after = this.autoAfter();
    const item = this.items.station;
    if (after === null || item.channel !== this.channel() || item.latest === null) return;
    const [latest, left] = [buildOf(item.latest), buildOf(after)];
    if (latest === null || left === null || latest <= left) return;
    await this.config.updateSoon((raw) => {
      raw.autoUpdate = true;
      delete raw.autoUpdateAfter;
    });
    this.lastSetting = this.setting();
    log.info("updates", "a release newer than the one gone back from is out: the station updates itself again", { left: after, latest: item.latest });
    this.changed();
  }

  private autoUpdate(why: string) {
    const to = this.toUpdateTo();
    if (to === null) return;
    log.info("updates", `${why}: the station updates itself`, { to });
    this.updateStation(stationLang()).catch((e) => log.warn("updates", "the station not updated by itself", { error: (e as Error).message }));
  }

  /// Retry one failed installer, rereading the signed feed with backoff if it or the installer's plan is unavailable.
  private retryStation(version: string) {
    const serial = ++this.retrySerial;
    const over = () => this.closed || serial !== this.retrySerial || this.tried !== version || this.retried === version;
    const attempt = Effect.promise(async () => {
      if (over()) return true;
      this.retryDue = version;
      if (this.auto() || this.autoWhen() !== null) {
        try {
          // A runtime-only reading may already be in flight; wait for it, then read the station's feed too.
          if (this.checking) await this.checking.catch(() => {});
          if (over()) return true;
          await this.check();
          if (!over()) this.autoUpdate("retrying a failed update");
        } catch (e) {
          log.warn("updates", "the failed update's release not read", { error: (e as Error).message });
        }
      }
      return over();
    });
    // timer: retry after a failed update, then back off if the release cannot be read or its installer started.
    this.fibers.fork(Effect.sleep(STATION_RETRY_MS).pipe(
      Effect.andThen(attempt.pipe(Effect.repeat({ schedule: STATION_RETRY_BACKOFF, until: (done) => done }))), // timer: retry after a failed update
      Effect.asVoid,
    ));
  }

  // ---- updating ----

  /// Updates one (`station`, `claude`, `codex`, `dsh`), or installs a runtime the machine has not: answers once it has
  /// started; how it goes shows in `get`. Refusals are said in `lang`.
  async update(id: string, lang: Lang = stationLang(), to?: string): Promise<void> {
    if (this.closed) throw new Error("updates are closed");
    const kind = KINDS.find((k) => k === id);
    if (kind === undefined) throw refused(lang, "station.updates.noSuchItem", { id });
    if (to !== undefined && kind !== "station") throw refused(lang, "station.updates.backStationOnly");
    const item = this.items[kind];
    const name = kindName(kind);
    if (item.updating !== null) throw refused(lang, "station.updates.alreadyUpdating", { name });
    if (item.note) throw refused(lang, "station.list.labeled", { name, note: say(item.note, lang) });
    if (kind === "station") {
      const runtime = this.runtimeUpdating();
      if (runtime !== null) throw refused(lang, "station.updates.runtimeBusy", { name: kindName(runtime) });
      return to === undefined ? this.updateStation(lang) : this.backStation(to, lang);
    }
    if (this.items.station.updating !== null) throw refused(lang, item.installed ? "station.updates.stationBusyUpdate" : "station.updates.stationBusyInstall", { name });
    const how = item.how;
    if (how === null) throw refused(lang, "station.updates.notHere", { name });
    if (kind === "codex") this.codexUpdateSerial++;
    this.set(kind, (i) => {
      i.updating = this.fibers.now();
      i.progress = null;
      i.percent = null;
      i.failed = null;
      i.done = null;
    });
    this.spawn(() => this.updateRuntime(kind, how));
  }

  /// Updates the same installation and through the same path as the software page, or joins its update. A stale
  /// app-server may have failed after someone already updated the binary; in that case no second install is needed.
  async updateOldCodex(runningVersion: string | null, lang: Lang = stationLang()): Promise<void> {
    if (this.codexRecovery === null) {
      const work = this.updateOldCodexOnce(runningVersion, lang);
      this.codexRecovery = work;
      void work.finally(() => { if (this.codexRecovery === work) this.codexRecovery = null; }).catch(() => {});
    }
    await this.codexRecovery;
    const actual = this.items.codex.version;
    if (actual === null) throw refused(lang, "station.notice.codexVersionUnknown");
    if (runningVersion !== null && !newer(runningVersion, actual)) throw refused(lang, "station.notice.codexNoNewVersion");
  }

  private async updateOldCodexOnce(runningVersion: string | null, lang: Lang) {
    if (this.items.codex.updating !== null) return this.waitForCodexUpdate(lang);
    // The page's last check may be hours old. Do not overwrite an update that starts while this reading is in flight.
    const serial = this.codexUpdateSerial;
    const read = await this.readRuntime("codex");
    if (this.items.codex.updating !== null) return this.waitForCodexUpdate(lang);
    if (serial === this.codexUpdateSerial) this.set("codex", (item) => Object.assign(item, read));
    const item = this.items.codex;
    if (!item.installed) throw refused(lang, "station.updates.notHere", { name: "Codex" });
    if (item.note) throw new Error(say(item.note, lang));
    if (runningVersion !== null && item.version !== null && newer(runningVersion, item.version)) return;
    const before = item.version;
    await this.update("codex", lang);
    await this.waitForCodexUpdate(lang);
    const after = this.items.codex.version;
    if (after === null) throw refused(lang, "station.notice.codexVersionUnknown");
    if (before !== null && !newer(before, after)) throw refused(lang, "station.notice.codexNoNewVersion");
  }

  private waitForCodexUpdate(lang: Lang): Promise<void> {
    return new Promise((resolve, reject) => {
      const inspect = () => {
        const item = this.items.codex;
        if (item.updating !== null) return;
        unlisten();
        if (item.failed) reject(new Error(say(item.failed, lang)));
        else resolve();
      };
      const unlisten = this.changes(inspect);
      inspect();
    });
  }

  /// A person chose to replace an incomplete Codex with an npm installation. Unknown installations are never changed
  /// by an ordinary update: this separate action preserves the old entry and validates the replacement before use.
  async repairCodex(lang: Lang = stationLang()): Promise<void> {
    const item = this.items.codex;
    if (item.updating !== null) throw refused(lang, "station.updates.alreadyUpdating", { name: "Codex" });
    if (this.items.station.updating !== null) throw refused(lang, "station.updates.stationBusyUpdate", { name: "Codex" });
    // Reserve the runtime before probing: two repair requests, or a station update, must not pass each other here.
    this.set("codex", (i) => {
      i.updating = this.fibers.now();
      i.progress = null;
      i.percent = null;
      i.failed = null;
      i.done = null;
    });
    try {
      const env = await withShellCommand("codex", this.env);
      const found = await findCommandSoon("codex", env);
      if (!item.repairable || !found || !(await canSwitchCodexSoon(found, env)) || !(await this.codexHostProbe(found, env))) {
        throw refused(lang, "station.updates.codexRepairUnavailable");
      }
      const captured = await captureCodexSoon(found, env);
      if (!captured) throw refused(lang, "station.updates.codexRepairUnavailable");
      const npmEnv = await withShellCommand("npm", env);
      const prefix = join(this.data, "runtimes", "codex", `npm-${randomBytes(8).toString("hex")}`);
      const how = await npmInstallSoon(npmEnv, await this.ownNodeSoon(), ["install", "-g", "--prefix", prefix, "@openai/codex@latest"], "Codex");
      if (how instanceof Unable) throw refused(lang, how.key, how.args);
      this.spawn(() => this.repairCodexInBackground(captured, how, prefix, npmEnv));
    } catch (error) {
      this.set("codex", (i) => { i.updating = null; });
      throw error;
    }
  }

  private async repairCodexInBackground(captured: CodexEntry, how: How, prefix: string, npmEnv: Env) {
    const { found } = captured;
    const launcher = join(prefix, "bin", "codex");
    let backup: string | null = null;
    let failure: Words | null = null;
    let keepPrefix = false;
    try {
      const [ok, said] = await this.install("codex", how, npmEnv);
      if (!ok) throw new Error(tail(said, stationLang()));
      const newFound = { onPath: launcher, real: await realpath(launcher) };
      const binary = await codexBinarySoon(newFound);
      const env = how.node ? machine.prependPath(npmEnv, how.node.bin) : npmEnv;
      const [runs, output] = await run(launcher, ["--version"], env, 20_000);
      const [hostRuns] = binary !== null && (await hasCodexHostSoon(binary)) ? await run(join(dirname(binary), machine.exe("codex-code-mode-host")), ["--help"], env, 20_000) : [false];
      if (!runs || versionIn(output) === null || !hostRuns) {
        throw new Failed({ key: "station.updates.codexRepairIncomplete" });
      }
      // (the switch's checks and renames one step, as they must be: nothing may change the entry between them)
      backup = switchCodex(captured, launcher, env);
      const actualEnv = await withShellCommand("codex", this.env);
      const actual = await findCommandSoon("codex", actualEnv);
      if (!actual || actual.real !== newFound.real) throw new Failed({ key: "station.updates.codexRepairNotOnPath" });
      keepPrefix = true;
    } catch (e) {
      failure = e instanceof NotFinished ? { key: "station.updates.timedOut" } : e instanceof Failed ? e.words : { text: (e as Error).message };
      if (backup !== null) {
        try {
          restoreCodex(found.onPath, launcher, backup);
          backup = null;
        } catch (restoreError) {
          keepPrefix = true;
          failure = { text: `${say(failure, stationLang())}; ${(restoreError as Error).message}` };
        }
      }
    }
    if (!keepPrefix) {
      await rm(prefix, { recursive: true, force: true }).catch((error) => log.warn("updates", "the unused Codex repair not removed", { prefix, error: String(error) }));
    }
    // Retire the old app-servers as soon as the switch succeeds; reading the registry below can take longer.
    if (failure === null) {
      try { this.runtimeChanged("codex", true, true); } catch {}
    }
    const read = await this.readRuntime("codex");
    this.set("codex", (i) => Object.assign(i, read, { failed: failure, done: failure === null && backup ? { key: "station.updates.codexRepaired", args: { path: backup } } : null }));
    if (failure !== null) {
      try { this.runtimeChanged("codex", read.installed, false); } catch {}
    }
    this.autoUpdate("a newer release out, waited for a runtime");
  }

  private async updateRuntime(kind: Kind, how: How) {
    log.info("updates", "updating or installing a runtime", { runtime: kind, program: how.program, args: how.args });
    let failed: Words | null = null;
    try {
      const [ok, said, code] = await this.install(kind, how);
      // Its package manager has nothing newer to apply yet (winget's sources behind npm's latest): said as that, with
      // what it said.
      if (!ok && how.noUpdate !== undefined && code === how.noUpdate) failed = { key: "station.updates.noApplicableUpdate", args: { program: parse(how.program).name, said: tail(said, stationLang()) } };
      else if (!ok) failed = { text: tail(said, stationLang()) };
    } catch (e) {
      failed = e instanceof NotFinished ? { key: "station.updates.timedOut" } : e instanceof Failed ? e.words : { text: (e as Error).message };
    }
    if (failed) log.warn("updates", "the runtime not updated", { runtime: kind, failed: say(failed, "en") });
    let read: Item;
    try {
      read = await this.readRuntime(kind);
    } catch (error) {
      this.set(kind, (item) => { item.updating = null; item.progress = null; item.percent = null; item.failed = failed ?? { text: (error as Error).message }; });
      this.autoUpdate("a runtime update ended without a version reading");
      return;
    }
    if (failed === null && !read.installed && (await linkBesideNpm(kind, how, this.env).catch(() => false))) {
      log.info("updates", "the runtime npm installed off PATH linked beside npm", { runtime: kind, npm: how.program });
      try { read = await this.readRuntime(kind); }
      catch (error) {
        this.set(kind, (item) => { item.updating = null; item.progress = null; item.percent = null; item.failed = { text: (error as Error).message }; });
        this.autoUpdate("a runtime update ended without a version reading");
        return;
      }
    }
    // Done without an error but not there, or not newer: installed somewhere the station's PATH does not find.
    if (failed === null) {
      if (!read.installed) failed = { key: "station.updates.notOnPath", args: { program: how.program, command: kindCommand(kind) } };
      else if (read.version !== null && read.latest !== null && newer(read.version, read.latest)) {
        failed = { key: "station.updates.notNewer", args: { program: how.program, command: kindCommand(kind), version: read.version, latest: read.latest } };
      }
    }
    this.set(kind, (i) => Object.assign(i, read, { failed }));
    try {
      this.runtimeChanged(kind as RuntimeKind, read.installed, false);
    } catch {}
    // The station's own update waited for this one.
    this.autoUpdate("a newer release out, waited for a runtime");
  }

  /// Runs `how`, saying where it is as it goes: a download that can be measured, by how much of it is in (Codex's
  /// build for this machine, fetched here first; Claude Code's and the Antigravity CLI's, as their installers write
  /// them), else the step the command says it is at (Homebrew's, Claude Code's installer's).
  private async install(kind: Kind, how: How, givenEnv?: Env): Promise<[boolean, string, number | null]> {
    if (how.node) await this.installNode(kind, how.node);
    const runtimeEnv = givenEnv ?? await withShellCommand(kindCommand(kind), this.env);
    const npm = isNpmInstall(how);
    if (kind === "codex" && npm) {
      const version = await this.fetchCodex(how.program, runtimeEnv);
      // That version, as npm's cache has its build (`latest` from a cached list could be an older one).
      if (version !== null) how = pinNpmVersion(how, kindPackage(kind), version);
    }
    // npm of the station's own Node runs on it (its #! takes the node PATH finds first).
    const env = how.node ? machine.prependPath(runtimeEnv, how.node.bin) : runtimeEnv;
    const installing = { now: false };
    // Claude Code's own installer (not `claude update`, nor Homebrew).
    const own = how.program === "/bin/sh" || how === machine.claudeInstall;
    const stop = kind === "claude" && own ? this.watchClaudeDownload(installing)
      : kind === "agy" && how === machine.agyInstall ? this.watchAgyDownload(env)
      : () => {};
    try {
      return await runLines(how.program, how.args, env, this.timing.runtimeLimit, (line) => {
        const step = stepOf(line);
        if (step === null) return;
        if (sameWords(step, INSTALLING)) installing.now = true;
        this.say(kind, step, null);
      });
    } finally {
      stop();
    }
  }

  /// The Node an npm install runs on where the machine had none (runtimes.ts OwnNode): nodejs.org's build for this
  /// machine, its download measured and checked against the release's SHASUMS256, unpacked in <data>/node once (kept
  /// for the next install, and for npm to update what it installed), and put last on the station's PATH.
  private async installNode(kind: Kind, node: OwnNode) {
    // Two runtimes installed at once: one Node, put there by the first.
    while (this.nodeInstalling) await this.nodeInstalling.catch(() => {});
    const done = this.placeNode(kind, node);
    this.nodeInstalling = done;
    try {
      await done;
    } finally {
      this.nodeInstalling = null;
    }
    await putOwnNodesSoon(this.env, this.data);
  }

  private async placeNode(kind: Kind, node: OwnNode) {
    if (await access(join(node.bin, node.build.npm)).then(() => true, () => false)) return;
    const home = ownNodeHome(this.data);
    await mkdir(home, { recursive: true });
    const { dist, archive } = node.build;
    const file = join(home, archive);
    const unpacked = join(home, `.unpacking-${dist}`);
    try {
      const base = `${this.nodeDist}/v${node.version}`;
      const sums = await fetchText(`${base}/SHASUMS256.txt`);
      const want = sums.split("\n").map((l) => l.trim().split(/\s+/)).find(([, f]) => f === archive)?.[0];
      if (want === undefined) throw new Failed({ key: "station.updates.nodeUnverified" });
      await this.download(kind, `Node ${node.version}`, `${base}/${archive}`, file);
      if ((await sha256(file)) !== want) throw new Failed({ key: "station.updates.nodeUnverified" });
      this.say(kind, INSTALLING, null);
      // (a Node's tree is thousands of files: removed off the station's thread)
      await rm(unpacked, { recursive: true, force: true });
      await mkdir(unpacked);
      const [ok, said] = await run(node.build.tar, ["-xf", file, "-C", unpacked], this.env, 120_000);
      if (!ok) throw new Error(tail(said, stationLang()));
      await rm(node.at, { recursive: true, force: true });
      await rename(join(unpacked, dist), node.at);
      log.info("updates", "Node installed for npm", { runtime: kind, at: node.at });
    } finally {
      await rm(file, { force: true }).catch(() => {});
      await rm(unpacked, { recursive: true, force: true }).catch(() => {});
    }
  }

  /// Where a runtime's update is (while it updates), and how much of a download is in.
  private say(kind: Kind, progress: Words, percent: number | null) {
    const item = this.items[kind];
    if (item.updating === null || (sameWords(item.progress, progress) && item.percent === percent)) return;
    const wasDownload = isDownloadWords(item.progress);
    item.progress = progress;
    item.percent = percent;
    // A download's ticks paced; its first, its end and any other words told at once.
    this.notifyProgress(!(wasDownload && isDownloadWords(progress) && percent !== 0 && percent !== 100));
  }

  private sayDownloading(kind: Kind, version: string, got: number, total: number | null) {
    const [words, percent] = downloading(version, got, total);
    this.say(kind, words, percent);
  }

  /// Codex's build for this machine (nearly all its install downloads), fetched here so how much is in can be said,
  /// and put in npm's cache for the install to take: the version fetched; null when it was not (npm then downloads it
  /// itself, unmeasured).
  private async fetchCodex(npm: string, env: Env): Promise<string | null> {
    const p = platform();
    if (p === null) return null;
    const pkg = kindPackage("codex");
    let version: string;
    let url: string;
    try {
      version = (await fetchJson(`${this.registry}/${pkg}/latest`))?.version;
      url = (await fetchJson(`${this.registry}/${pkg}/${version}-${p}`))?.dist?.tarball;
      if (typeof version !== "string" || typeof url !== "string") return null;
    } catch {
      return null;
    }
    const file = join(tmpdir(), `stillfail-codex-${version}-${p}.tgz`);
    try {
      await this.download("codex", version, url, file);
      this.say("codex", INSTALLING, null);
      const [ok, said] = await run(npm, ["cache", "add", file], env, 120_000);
      if (ok) return version;
      log.warn("updates", "Codex's build not put in npm's cache; npm downloads it", { said: tail(said, "en") });
      return null;
    } catch (e) {
      log.warn("updates", "Codex's build not fetched; npm downloads it", { error: (e as Error).message });
      return null;
    } finally {
      await rm(file, { force: true }).catch(() => {});
    }
  }

  /// Downloads `url` to `to`, saying how much of it is in; a minute without anything coming in ends it.
  private async download(kind: Kind, version: string, url: string, to: string) {
    const stalled = new AbortController();
    const over = new AbortController();
    let stall = this.fibers.after(60_000, () => stalled.abort());
    const limit = this.fibers.after(this.timing.runtimeLimit, () => over.abort(new DOMException("timed out", "TimeoutError")));
    try {
      const response = await fetch(url, { headers: UA, signal: AbortSignal.any([stalled.signal, over.signal]) });
      if (!response.ok || !response.body) throw new Error(`${url}: ${response.status}`);
      const length = Number(response.headers.get("content-length"));
      const total = Number.isFinite(length) && length > 0 ? length : null;
      const out = createWriteStream(to);
      let got = 0;
      this.sayDownloading(kind, version, got, total);
      try {
        for await (const chunk of response.body as unknown as AsyncIterable<Uint8Array>) {
          stall();
          stall = this.fibers.after(60_000, () => stalled.abort());
          if (!out.write(chunk)) await new Promise<void>((r) => out.once("drain", () => r()));
          got += chunk.length;
          this.sayDownloading(kind, version, got, total);
        }
      } catch (e) {
        if (stalled.signal.aborted) throw refused(stationLang(), "station.updates.downloadStalled");
        throw e;
      } finally {
        await new Promise<void>((r) => out.end(() => r()));
      }
    } finally {
      stall();
      limit();
    }
  }

  /// Says how much of the Antigravity CLI's build its own installer has downloaded (agy-download.ts), then that it
  /// installs it.
  private watchAgyDownload(env: Env): () => void {
    return watchAgyDownload({
      manifests: this.agyManifests,
      build: machine.agyBuild,
      staging: (url) => machine.agyStaging(env, url),
      after: (ms, f) => this.fibers.after(ms, f),
      said: (version, got, total) => (got >= total ? this.say("agy", INSTALLING, null) : this.sayDownloading("agy", version, got, total)),
    });
  }

  /// Says how much of Claude Code's build its installer has downloaded (into ~/.claude/downloads, its size in the
  /// release's manifest; the zstd one when the machine has zstd), until it sets it up. Its installer is another
  /// program writing a file: looked at twice a second while it runs. Gives what stops it.
  private watchClaudeDownload(installing: { now: boolean }): () => void {
    const home = this.env.HOME;
    const p = platform();
    if (!home || p === null) return () => {};
    let stopped = false;
    let next: (() => void) | null = null;
    void (async () => {
      let version: string;
      let plain: number | null = null;
      let zst: number | null = null;
      try {
        version = (await fetchText(`${this.claudeReleases}/latest`)).trim();
        const size = (m: any) => (typeof m?.platforms?.[p]?.size === "number" ? m.platforms[p].size : null);
        const [a, b] = await Promise.allSettled([fetchJson(`${this.claudeReleases}/${version}/manifest.json`), fetchJson(`${this.claudeReleases}/${version}/manifest.zst.json`)]);
        plain = a.status === "fulfilled" ? size(a.value) : null;
        zst = b.status === "fulfilled" ? size(b.value) : null;
      } catch {
        return;
      }
      const file = join(home, ".claude/downloads", `claude-${version}-${p}`);
      const len = (f: string) => stat(f).then((s) => s.size, () => null);
      // One look at a time: the next is set going once this one has read the sizes.
      const look = async () => {
        next = null;
        if (stopped || installing.now) return;
        const [gotZst, gotPlain] = await Promise.all([len(`${file}.zst`), len(file)]);
        if (stopped || installing.now) return;
        const got = gotZst !== null ? (zst !== null ? [gotZst, zst] : null) : gotPlain !== null && plain !== null ? [gotPlain, plain] : null;
        if (got) this.sayDownloading("claude", version, got[0]!, got[1]!);
        // timer: a sample of this machine (another program, the installer, writing its download says nothing).
        next = this.fibers.after(500, () => void look());
      };
      await look();
    })();
    return () => {
      stopped = true;
      next?.();
    };
  }

  /// Runs the installer this release carries apart from the station, as `stillfail update` does (release.ts), and
  /// follows it: by this process, and after a handover or a restart by the one that runs then (run/update.started says
  /// to).
  private async updateStation(lang: Lang): Promise<void> {
    const origin = this.origin() || null;
    if (origin === null) throw refused(lang, "station.updates.notJoined");
    const runDir = join(this.data, "run");
    const station = this.items.station;
    // Taken now, so another ask meanwhile finds it updating.
    const before = { updating: station.updating, failed: station.failed, done: station.done };
    station.updating = this.fibers.now();
    try {
      await mkdir(runDir, { recursive: true });
    } catch (e) {
      Object.assign(station, before);
      throw e;
    }
    // Off the station's thread so cleanup does not delay its other work at every update.
    await Promise.all(["update.exit", "update.step"].map((f) => rm(join(runDir, f), { force: true })));
    const channel = this.channel();
    // The release verified, the installer to run and what it is told (refused in `lang`: not left updating).
    let plan: Plan;
    try {
      plan = await planUpdate({ base: origin, channel, app: this.app, installed: this.installed, lang, override: this.override, trusted: this.trusted, request: this.cloudRequest });
    } catch (e) {
      Object.assign(station, before);
      throw e;
    }
    if (plan.delta === null) {
      if (!(await this.startPlanned(plan, {}))) {
        Object.assign(station, before);
        throw refused(lang, "station.updates.couldNotStart");
      }
      return;
    }
    // A delta first: answered now, its download shown as the installer's is, and the installer started after it.
    this.set("station", (i) => {
      i.step = "download";
      i.percent = 0;
    });
    // (told now: the next percent waits PROGRESS_NOTIFY_MS)
    this.progressTold = this.fibers.now();
    this.spawn(async () => {
      if (await this.startPlanned(plan, await this.fromDelta(plan))) return;
      log.warn("updates", "the station's installer not started");
      this.set("station", (i) => Object.assign(i, { updating: null, step: null, percent: null, done: null, failed: { key: "station.updates.couldNotStart" } }));
    });
  }

  /// Puts the station back to `to`, a release older than the one it runs that its channel's feed names (`earlier`):
  /// answered once that is planned; its archive is downloaded and checked here (shown as the installer's download),
  /// then the installer is handed it. Updating by itself, when on, is turned off for it, with the release left kept
  /// (`autoUpdateAfter`): the release gone back to, from before this, knows only that it is off; one that knows it
  /// turns it on again once a newer release than the one left is out (resumeAuto).
  private async backStation(to: string, lang: Lang): Promise<void> {
    const origin = this.origin() || null;
    if (origin === null) throw refused(lang, "station.updates.notJoined");
    const runDir = join(this.data, "run");
    const station = this.items.station;
    // Taken now, so another ask meanwhile finds it updating.
    const before = { updating: station.updating, failed: station.failed, done: station.done };
    station.updating = this.fibers.now();
    let plan: Back;
    try {
      await mkdir(runDir, { recursive: true });
      await Promise.all(["update.exit", "update.step"].map((f) => rm(join(runDir, f), { force: true })));
      plan = await planBack({ base: origin, channel: this.channel(), app: this.app, to, lang, trusted: this.trusted, request: this.cloudRequest });
    } catch (e) {
      Object.assign(station, before);
      throw e;
    }
    this.set("station", (i) => {
      i.step = "download";
      i.percent = 0;
      i.failed = null;
      i.done = null;
    });
    // (told now: the next percent waits PROGRESS_NOTIFY_MS)
    this.progressTold = this.fibers.now();
    this.spawn(async () => {
      let handed: Record<string, string>;
      try {
        handed = await this.archiveFor(plan);
      } catch (e) {
        log.warn("updates", "the release to go back to not downloaded", { to: plan.release.version, error: (e as Error).message });
        this.set("station", (i) => Object.assign(i, { updating: null, step: null, percent: null, done: null, failed: { key: "station.updates.backNotDownloaded", args: { version: plan.release.version, why: (e as Error).message } } }));
        return;
      }
      const left = this.items.station.version;
      const wasAuto = this.auto();
      if (wasAuto && left !== null) await this.holdAuto(left);
      if (await this.startPlanned(plan, handed)) return;
      if (wasAuto && left !== null) {
        await this.config.updateSoon((raw) => {
          raw.autoUpdate = true;
          delete raw.autoUpdateAfter;
        });
        this.lastSetting = this.setting();
      }
      log.warn("updates", "the station's installer not started");
      this.set("station", (i) => Object.assign(i, { updating: null, step: null, percent: null, done: null, failed: { key: "station.updates.couldNotStart" } }));
    });
  }

  /// Updating by itself turned off as the station goes back from `left`, kept to be turned on again past it.
  private async holdAuto(left: string) {
    await this.config.updateSoon((raw) => {
      raw.autoUpdate = false;
      raw.autoUpdateAfter = left;
    });
    this.lastSetting = this.setting();
    log.info("updates", "the station goes back: updating by itself off until a newer release is out", { left });
    this.changed();
  }

  /// The archive of the release `back` goes back to, downloaded (release.ts takeArchive) within the delta's deadline.
  private async archiveFor(back: Back): Promise<Record<string, string>> {
    const over = new AbortController();
    // timer: a deadline of an outside request (the release's download).
    const cancel = this.fibers.after(this.timing.deltaLimit, () => over.abort(new DOMException("timed out", "TimeoutError")));
    try {
      return await takeArchive(back, {
        request: this.cloudRequest,
        signal: over.signal,
        progress: (percent) => this.sayStationPercent(percent),
        wait: (ms) => this.fibers.sleep(ms),
      });
    } finally {
      cancel();
    }
  }

  /// What the installer is told of the release the plan's delta made (release.ts takeDelta), applied apart from the
  /// station; nothing when it was not made.
  private async fromDelta(plan: Plan): Promise<Record<string, string>> {
    const over = new AbortController();
    // timer: a deadline of an outside request (the delta's download) and of the applier; past it the installer
    // downloads the release.
    const cancel = this.fibers.after(this.timing.deltaLimit, () => over.abort(new DOMException("timed out", "TimeoutError")));
    try {
      return await takeDelta(plan, {
        app: this.app,
        apply: applyApart,
        request: this.cloudRequest,
        signal: over.signal,
        progress: (percent) => this.sayStationPercent(percent),
        // (downloaded again after a failure on the way, on this part's clock, within the deadline above)
        wait: (ms) => this.fibers.sleep(ms),
      });
    } finally {
      cancel();
    }
  }

  /// Starts the installer of `plan`, told `handed` (an archive a delta made) too, and follows it; false when it did not
  /// start (what it was handed removed).
  private async startPlanned(plan: Plan, handed: Record<string, string>): Promise<boolean> {
    const runDir = join(this.data, "run");
    const env: Record<string, string> = {};
    for (const [k, v] of Object.entries(this.env)) if (v !== undefined) env[k] = v;
    // Never what an installer gave the station it started (one run without a service passes its own environment on):
    // an archive long taken, a handing that is not this one's.
    delete env.STILLFAIL_ARCHIVE;
    delete env.STILLFAIL_INSTALLER_HANDED;
    Object.assign(env, { STILLFAIL_DATA: this.data }, plan.env, handed);
    // What it updates from, and run/update.started, before the installer runs: a quick one puts the next release's BUILD
    // in place (and may hand over) before anything after its start is read or written.
    const started: Started = { at: this.fibers.now(), from: (await stationVersionSoon(this.app)) ?? null };
    // (an update before this process looked for meanwhile is not this one: followStarted)
    this.follows++;
    const startedFile = join(runDir, "update.started");
    try {
      await writeFile(startedFile, JSON.stringify(started));
    } catch (e) {
      log.warn("updates", "update.started not written; a handover or restart will not say how the update went", { error: (e as Error).message });
    }
    let ok = !this.closed && (await this.startInstaller(plan.script, runDir, env, this.app));
    if (!ok && !this.closed && this.launcherInstaller !== null) {
      // Not started here: the launcher starts it (its exit and log in run/ as one started here), followed as one.
      log.warn("updates", "the station's installer not started here; the launcher starts it", { to: plan.release.version });
      this.launcherInstaller(plan.script, env);
      ok = true;
    }
    if (!ok) {
      await rm(startedFile, { force: true }).catch(() => {});
      if (handed.STILLFAIL_ARCHIVE) await rm(dirname(handed.STILLFAIL_ARCHIVE), { recursive: true, force: true }).catch(() => {});
      return false;
    }
    log.info("updates", "updating the station", { origin: plan.env.STILLFAIL_ORIGIN, channel: plan.env.STILLFAIL_CHANNEL, to: plan.release.version, delta: handed.STILLFAIL_ARCHIVE !== undefined });
    if (this.retryDue === plan.release.version) this.retried = plan.release.version;
    this.retryDue = null;
    this.tried = plan.release.version;
    await this.follow(started);
    return true;
  }

  /// An update started before this process, when one is: followed as if started here (its first look taken).
  async followStarted(): Promise<void> {
    const runDir = join(this.data, "run");
    const follows = this.follows;
    let started: Started;
    try {
      const said = JSON.parse(await readFile(join(runDir, "update.started"), "utf8"));
      if (typeof said?.at !== "number") return;
      started = { at: said.at, from: typeof said.from === "string" ? said.from : null };
    } catch {
      return;
    }
    // (an update started here meanwhile wrote what was read, and may have ended and removed it since)
    if (this.closed || this.follows !== follows) return;
    if (this.fibers.now() - started.at > this.timing.stationLimit) {
      await Promise.all(["update.started", "update.step"].map((f) => rm(join(runDir, f), { force: true })));
      return;
    }
    log.info("updates", "following the station's update started before this process");
    await this.follow(started);
  }

  /// Shows how the station's update goes (the installer's steps, in run/update.step) until it says how it ended in
  /// run/update.exit (and what it said in run/update.log), then how it went for a while. Resolves once its first look
  /// is taken. Its files are read off the station's thread, one look at a time: a look asked for while one reads is
  /// taken once that one is done.
  async follow(started: Started): Promise<void> {
    const followId = ++this.follows;
    this.following?.();
    this.set("station", (i) => {
      i.updating = started.at;
      i.step = null;
      i.progress = null;
      i.percent = null;
      i.failed = null;
      i.done = null;
    });
    const runDir = join(this.data, "run");
    const [exitFile, logFile, stepFile] = ["update.exit", "update.log", "update.step"].map((f) => join(runDir, f)) as [string, string, string];
    const read = (f: string) => readFile(f, "utf8").catch(() => null);
    let over = false;
    let watcher: FSWatcher | null = null;
    let soon: (() => void) | null = null;
    let slow: (() => void) | null = null;
    let lastRunning = this.running();
    const end = () => {
      over = true;
      watcher?.close();
      soon?.();
      slow?.();
    };
    this.following = end;
    const lookOnce = async (): Promise<void> => {
      // The exit first, then the step: the installer writes its last step before it ends, so a step read after its exit
      // is the one it ended on.
      let code = await read(exitFile);
      const step = (await read(stepFile))?.trim() ?? "";
      if (over) return;
      // Made but not yet written (the shell opens it, then writes the code): not ended yet; its write is seen next.
      if (code !== null && code.trim() === "") code = null;
      let failed: Words | null = null;
      let done: Words | null = null;
      if (code !== null && code.trim() === "0") done = await this.done(started, step);
      else if (code !== null) {
        const said = await read(logFile);
        failed = said !== null ? { text: tail(said, stationLang()) } : { key: "station.updates.installerExit", args: { code: code.trim() } };
      } else if (this.fibers.now() - started.at > this.timing.stationLimit) failed = { key: "station.updates.installerTimedOut" };
      else {
        const percent = step === "download" ? await stationDownloadPercent(logFile) : null;
        if (over) return;
        const item = this.items.station;
        const running = this.running();
        const stepChanged = item.step !== (step || null);
        const drainChanged = step === "drain" && running !== lastRunning;
        if (stepChanged || item.percent !== percent || drainChanged) {
          const percentOnly = !stepChanged && !drainChanged;
          const immediate = !percentOnly || item.percent === null || percent === null || percent === 0 || percent === 100;
          item.step = step || null;
          item.percent = percent;
          lastRunning = running;
          if (percentOnly) this.notifyProgress(immediate);
          else {
            if (step === "download" && percent !== null) this.progressTold = this.fibers.now();
            this.changed();
          }
        }
        return;
      }
      if (over) return;
      end();
      if (this.following === end) this.following = null;
      await Promise.all(["update.started", "update.step"].map((f) => rm(join(runDir, f), { force: true }).catch(() => {})));
      // With what the installer said last when it failed (as a runtime's failure is said): the station's own pages
      // are where else it shows, and only to whoever looks at them.
      log.info("updates", "the station's update ended", failed !== null ? { failed: true, why: say(failed, "en") } : { failed: false });
      // (closed, or another update followed since, while the files were removed, which may have ended too: that one
      // says how the station is)
      if (this.closed || this.follows !== followId) return;
      this.set("station", (i) => {
        i.updating = null;
        i.step = null;
        i.progress = null;
        i.percent = null;
        i.failed = failed;
        i.done = done;
      });
      // A timeout alone does not mean the installer exited. It and success also cancel an earlier pending retry.
      if (code === null || failed === null) {
        this.retrySerial++;
        this.retryDue = null;
        this.retried = this.tried;
      } else if (this.tried !== null && this.retried !== this.tried) {
        this.retryDue = null;
        this.retryStation(this.tried);
      }
      this.spawn(() => this.check());
      if (done !== null) {
        const shown = done;
        // Unless another update has said something since.
        this.later(this.timing.doneShown, () => {
          if (sameWords(this.items.station.done, shown)) this.set("station", (i) => (i.done = null));
        });
      }
    };
    let looking: Promise<void> | null = null;
    let again = false;
    const look = (): Promise<void> => {
      soon = null;
      if (over) return Promise.resolve();
      if (looking !== null) {
        again = true;
        return looking;
      }
      looking = (async () => {
        // (every lookOnce reads a file first: this runs on past the assignment below before it ends)
        try {
          do {
            again = false;
            await lookOnce().catch((e) => log.warn("updates", "the station's update not looked at", { error: (e as Error).message }));
          } while (again && !over);
        } finally {
          looking = null;
        }
      })();
      return looking;
    };
    const lookSoon = () => {
      if (!over && soon === null) soon = this.fibers.after(50, () => void look());
    };
    await mkdir(runDir, { recursive: true }).catch(() => {});
    if (over) return;
    try {
      watcher = watch(runDir, (_, name) => {
        if (name === null || name.startsWith("update.")) lookSoon();
      });
      watcher.on("error", () => {});
    } catch (e) {
      log.warn("updates", "run/ not watched; the update is looked at now and then", { error: (e as Error).message });
    }
    slow = this.fibers.every(this.timing.followLook, () => void look()); // timer: another program (the installer) writing its files may go unheard by the watch
    await look();
  }

  /// Where the update is, by the installer's step, as the pages say it.
  private progressOf(step: string | null): Words | null {
    switch (step) {
      case "download":
        return { key: "station.updates.downloadingStation" };
      case "handoff":
        return { key: "station.updates.handoff" };
      case "drain": {
        const n = this.running();
        return n === 0 ? { key: "station.updates.restarting" } : { key: "station.updates.draining", args: { n } };
      }
      case "restart":
        return { key: "station.updates.restarting" };
      default:
        return null;
    }
  }

  /// How an update that ended well went, by the step it ended on.
  private async done(started: Started, step: string): Promise<Words> {
    const now = (await stationVersionSoon(this.app)) ?? null;
    if (now !== null && now === started.from) return { key: "station.updates.upToDate" };
    const [withVersion, without] =
      step === "handoff" ? ["station.updates.doneHandoff", "station.updates.doneHandoffNoVersion"]
      : step === "drain" || step === "restart" ? ["station.updates.doneRestart", "station.updates.doneRestartNoVersion"]
      : ["station.updates.done", "station.updates.doneNoVersion"];
    return now !== null ? { key: withVersion, args: { version: now } } : { key: without };
  }

  // ---- for tests ----

  /// The station's line as if its latest were `latest`, read from the channel it is on.
  stationWith(latest: string, lang: Lang = "zh"): SoftwareVersion {
    const item = this.items.station;
    item.version = stationVersion(this.app) ?? null;
    item.latest = latest;
    item.channel = this.channel();
    return this.get(lang)[0]!;
  }

  /// Updating by itself turned on again if the latest read is past the release gone back from (tests: resumeAuto).
  resumeAutoForTests(): Promise<void> {
    return this.resumeAuto();
  }

  /// Sets a line's state by hand (tests).
  poke(kind: Kind, f: (i: Item) => void) {
    f(this.items[kind]);
  }
}

/// Where `stillfail-station channel` asks the running station for an update channel, and where it answers.
export const CHANNEL_ASK = "channel-ask";
export const CHANNEL_ANSWER = "channel-answer";
/// Where `stillfail replace --wait` asks the running station to set/clear `autoUpdateWhen`, and where it answers.
export const WAIT_ASK = "wait-ask";
export const WAIT_ANSWER = "wait-answer";

/// Writes `text` to `path` whole (a reader never sees half of it).
export async function writeWhole(path: string, text: string): Promise<void> {
  const tmp = `${path}.tmp-${process.pid}`;
  await writeFile(tmp, text);
  await rename(tmp, path);
}

/// The running station's side: takes the channel asked for in <run>/channel-ask (if any), sets it, and answers in
/// <run>/channel-answer (`ok <channel>`, or `error <why>`). One at a time (Updates' `answerChannelAsk`).
export async function answerChannelAsk(runDir: string, set: (channel: Channel) => Promise<void> | void): Promise<void> {
  const ask = join(runDir, CHANNEL_ASK);
  const asked = await readFile(ask, "utf8").catch(() => null);
  if (asked === null) return;
  await rm(ask, { force: true });
  const channel = asked.trim() === "stable" || asked.trim() === "beta" ? (asked.trim() as Channel) : null;
  let answer: string;
  if (channel === null) answer = `error ${tr(stationLang(), "station.cli.unknownChannel", { channel: asked.trim() })}`;
  else {
    try {
      await set(channel);
      answer = `ok ${channel}`;
    } catch (e) {
      answer = `error ${(e as Error).message}`;
    }
  }
  try {
    await writeWhole(join(runDir, CHANNEL_ANSWER), `${answer}\n`);
  } catch (e) {
    log.warn("updates", "the update channel's answer not written", { error: (e as Error).message });
  }
}

/// The running station's side of `stillfail replace --wait`: takes the JSON payload in <run>/wait-ask
/// (`{ wait: WaitCondition[] | null }`), updates config, and answers in <run>/wait-answer (`ok` or `error <why>`).
export async function answerWaitAsk(runDir: string, set: (wait: WaitCondition[] | null) => Promise<void> | void): Promise<void> {
  const ask = join(runDir, WAIT_ASK);
  const asked = await readFile(ask, "utf8").catch(() => null);
  if (asked === null) return;
  await rm(ask, { force: true });
  let answer: string;
  try {
    const parsed = JSON.parse(asked);
    if (parsed?.wait === null) {
      await set(null);
      answer = "ok";
    } else if (Array.isArray(parsed?.wait)) {
      const wait: WaitCondition[] = [];
      for (const item of parsed.wait) {
        const c = parseWaitCondition(item);
        if (c === null) throw new Error("invalid wait condition in wait-ask");
        wait.push(c);
      }
      await set(wait);
      answer = "ok";
    } else {
      throw new Error("wait-ask expects { wait: [...] | null }");
    }
  } catch (e) {
    answer = `error ${(e as Error).message}`;
  }
  try {
    await writeWhole(join(runDir, WAIT_ANSWER), `${answer}\n`);
  } catch (e) {
    log.warn("updates", "the auto-update wait answer not written", { error: (e as Error).message });
  }
}

/// Makes the station's updates: `start` reads them and keeps reading; `close` stops that.
export function makeUpdates(o: UpdatesOptions): Updates {
  return new Updates(o);
}
