// Signing a subscription profile in from the pages. The runtime's own login command runs here,
// on the station's machine, so the credentials land in the profile's home; the page only relays what the person has to
// do in their browser:
// - Claude: `claude auth login` prints an authorize link; after approving, the browser shows a code, which the person
//   pastes back and the station types in.
// - Codex: `codex login --device-auth` prints a link and a one-time code; the person enters the code on that page and
//   the command finishes by itself.
// - Grok Build: `grok login --device-auth` the same, its link at accounts.x.ai with the code in it; its home is the
//   profile's grok/ (agents/grok.ts).
// - Devin: `devin auth login --force-manual-token-flow` prints a link at app.devin.ai; after signing in, the page shows a
//   code the person pastes back, as Claude's. It reads the code only from a terminal: it runs in one (platform.terminalSoon).
//   Its sign-in lands in the profile's devin/data/ (XDG_DATA_HOME, agents/devin.ts).
// - Antigravity CLI: no login command; `agy` itself, in a terminal of its own as Devin's, with an empty directory of its
//   own as its HOME (<data>/run/agy-login/<profile>-<run>, removed as it ends) and told to keep its sign-in in a file
//   there (`AGY_FILE_TOKENS`: none of the keychain's), asks how to sign in (the station answers its first choice, Google
//   OAuth; for a company's Google account, `enterprise`, its second, a Google Cloud project, then Continue with Google
//   Cloud), prints a link at accounts.google.com and reads back the code the page shows, which the person pastes, as
//   Claude's. Not in the profile's agy/: finding a sign-in there (signing in again) it asks nothing and goes straight into
//   its interface (1.5.9), and a sign-in given up or failed would have overwritten the one there. Told it is a remote
//   session's, it first asks the terminal what it is (`ESC [ c`), which the station answers as a terminal would. It goes
//   on into its interface once signed in: the sign-in is done when its file is written whole (agents/agy.ts
//   agyTokenReady), then copied into the profile's agy/, and the command and those between stopped. A company's
//   account writes the file first with only its token, then fetches its licences: the first is chosen; with none, it
//   asks how to pay (Pay As You Go chosen) and for a Google Cloud project, which the person gives (`needs_project`,
//   taken as a code is).
// - OpenCode Go (`startConsole`): no command; the station asks the OpenCode Console for a code itself (console.ts) and
//   keeps asking until it is approved, then leaves the tokens in the profile's home. The page shows it as Codex's.
// - Kimi Code (`startKimi`): the same with Kimi's device grant (kimi.ts).
// - Cursor (`startCursor`): no command either; the station makes the login's page itself (accounts/cursor.ts), with no
//   code to enter: the person confirms it there, the station mints the profile's key and keeps it in its home.
// A stand-in `open` on PATH keeps the commands from opening a browser on the server; it writes down the page a command
// would have opened, which the station's own browser opens when a person asks (logins/pages.ts: Claude's comes back
// to the command's loopback port, with no code to paste). Who follows hears each change of a job (`changes`): pushed,
// not asked again.
import type { Clock } from "effect";
import { type ChildProcess, spawn } from "node:child_process";
import { mkdir, readdir, readFile, rm } from "node:fs/promises";
import { join } from "node:path";
import { fileCredentialsSoon } from "../agents/no-keychain.ts";
import { CONSOLE, type ConsoleLogin, type Device, type DeviceAnswer, deviceToken, startDevice, type Token, whoIs, writeConsole } from "./console.ts";
import { KIMI_AUTH, kimiDeviceToken, newDeviceId, readKimi, startKimiDevice, writeKimi } from "./kimi.ts";
import { CURSOR, type CursorUrls, cursorHandshake, mintCursorKey, pollCursor, writeCursor } from "./cursor.ts";
import { copilotDeviceToken, startCopilotDevice, writeCopilotToken } from "./copilot.ts";
import { cleanEnv } from "../agents/runtime.ts";
import { devinData } from "../agents/devin.ts";
import { AGY_FILE_TOKENS, agyToken, agyTokenIn, agyTokenReady, noteAgyEmail } from "../agents/agy.ts";
import { writePrivateSoon } from "../ops/files.ts";
import type { Runtime } from "../agents/profiles.ts";
import { type Lang, stationLang, tr } from "../ops/i18n.ts";
import { log } from "../ops/log.ts";
import { withShellCommand } from "../ops/shell-path.ts";
import { Fibers, wall } from "../ops/fibers.ts";
import { platform } from "../platform/index.ts";
import { started } from "../platform/processes.ts";
import { loopbackOf, urlsIn, webPage } from "../ops/command-output.ts";
import type { LoginPages } from "../logins/pages.ts";

export type LoginState = "starting" | "needs_code" | "needs_project" | "needs_approval" | "verifying" | "done" | "failed" | "cancelled";

export type LoginJob = {
  profile: string;
  runtime?: Runtime;
  /// Service id when signing in a non-agent service profile.
  service?: string;
  /// Signing in to OpenCode (an OpenCode Go profile) or Kimi (a Kimi Code profile) rather than the runtime's
  /// subscription (absent: the runtime's).
  provider?: "opencode" | "kimi" | "copilot";
  state: LoginState;
  url: string | null;
  userCode: string | null;
  error: string | null;
  startedAt: number;
  expiresAt: number;
  /// Its page can be opened in the station's browser now (`openPage`).
  browser?: boolean;
  /// The screen of the tab its page is open in, in the station's browser, while it is.
  screen?: string;
};

/// A sign-in's tab in the station's browser (logins/pages.ts) is known by this.
const pageKey = (profile: string) => `profile:${profile}`;

const TIMEOUT_MS = 15 * 60_000;
/// How long Claude's and Devin's commands are given to take a pasted code and end: past it the sign-in fails, saying to
/// start again, rather than showing 正在完成登录 till the sign-in's own 15 minutes run out.
export const VERIFY_WAIT_MS = 90_000;
/// What `claude auth login` says of a pasted code it would not take (2.1.321: no `#`, or nothing on one side of it); it
/// then waits for Enter and another code, never ending by itself.
const CLAUDE_CODE_REFUSED = "make sure the full code was copied";
/// Variables that would make the login command talk to something other than the subscription.
const SCRUBBED = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CONFIG_DIR", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CODEX_HOME", "OPENAI_API_KEY", "GROK_HOME", "GROK_AUTH", "GROK_AUTH_PATH", "XAI_API_KEY", "WINDSURF_API_KEY", "XDG_DATA_HOME", "GEMINI_API_KEY", "GOOGLE_API_KEY", "AGY_ADC_AUTH", "AGY_ACCOUNT", "ANTIGRAVITY_GEMINI_DIR"];
/// The terminal Devin's login runs in: wide, so that its link is printed on one line.
const DEVIN_COLS = 1000;
const DEVIN_ROWS = 40;

/// The login commands, by runtime.
export type LoginCommands = { claude: string; codex: string; grok?: string; devin?: string; agy?: string };
/// How often the Antigravity CLI's sign-in file is looked for once its code went in, and for how long.
const AGY_POLL_MS = 500;
const AGY_WAIT_MS = 90_000;
/// Between the arrow down and Enter in its menus.
const AGY_KEY_GAP_MS = 50;
/// What the Antigravity CLI says when a company's sign-in fails after its code or project went in (1.5.9).
/// (Its own errors say `[Auth Error]`.)
const AGY_FAILURES = ["[Auth Error]", "Couldn't sign in", "Failed to select license", "Failed to save GCP settings", "Permission denied"];
/// What it says where a Google Cloud account may not list its licences: no failure, it goes on to ask how to pay.
const AGY_NO_LICENCES = "Could not fetch licenses";
/// What it asks the terminal as a remote session's (its primary attributes, `ESC [ c`), and the answer it is given: a
/// VT100 with advanced video (and, for the secondary attributes it asks with it, a VT220's).
const AGY_TERMINAL_ASKED = "\u001b[c";
const AGY_TERMINAL_ANSWER = "\u001b[?1;2c\u001b[>0;276;0c";

/// Where a profile keeps the cookies and passkeys of its sign-in tab in the station's browser, inside its own home.
export const LOGIN_BROWSER_FILE = ".stillfail-login-state.json";

/// What a sign-in is for: a profile's id, the runtime it signs in to, its home, and (for Claude) the account email to
/// pre-populate on the authorize page when known.
/// `enterprise`: an Antigravity CLI sign-in to a company's Google account (Google Workspace, Gemini Enterprise, Google
/// Cloud) rather than a person's.
export type LoginProfile = { id: string; runtime: Runtime; home: string; email?: string | null; enterprise?: boolean };

/// A sign-in under way: its command (none for OpenCode's, which `stop` ends), and the file its stand-in browser writes
/// the pages it opens to.
/// `said`: what Claude's command said since its code went in (absent before), read for its refusal.
type Running = {
  run: number;
  job: LoginJob;
  child: ChildProcess | null;
  raw: string;
  output: string;
  cancelTimer: () => void;
  exited: boolean;
  lang: Lang;
  stop?: () => void;
  opened?: string;
  back?: string;
  home?: string;
  chose?: boolean;
  agy?: AgySteps;
  said?: string;
  validateCode?: (rawCode: string, lang: Lang) => string;
  onCode?: (code: string, lang: Lang) => Promise<void>;
  callbackCode?: (tabUrl: string | null) => string | null;
};

/// Where an Antigravity CLI sign-in is in its menus: which it answered, and what it said since its code (or project)
/// went in (`after`, null before), which is where its licences, how to pay and the project are asked. `stage`: its HOME,
/// an empty directory of this sign-in's; `terminal`: whether its question to the terminal was answered.
type AgySteps = { enterprise: boolean; cloud: boolean; license: boolean; billing: boolean; after: string | null; stage: string; terminal: boolean };

export class LoginManager {
  private jobs = new Map<string, Running>();
  private finished = new Map<string, LoginJob>();
  private listeners = new Set<(profile: string) => void>();
  private runs = 0;
  private noBrowserDir: string;
  /// Where the Antigravity CLI's sign-ins each have their HOME (`run`: what runs, bounded-ephemeral).
  private agyLoginDir: string;
  private commands: LoginCommands;
  private background: Fibers;
  /// The environment the commands start from; variables that point a login elsewhere are removed at start.
  private env: () => Record<string, string>;

  /// The OpenCode Console signed in to (console.ts CONSOLE; a test's stand-in).
  private console: string;
  /// Kimi's sign-in server (kimi.ts KIMI_AUTH; a test's stand-in).
  private kimi: string;
  /// Cursor signed in to (cursor.ts CURSOR; a test's stand-in), and the name its key is given (the station's).
  private cursor: CursorUrls;
  private keyName: () => string;
  /// Where a sign-in's page opens in the station's browser (none until the browser's part attaches it).
  private pages: LoginPages | null = null;
  /// Where each profile's isolated sign-in browser context keeps its cookies and passkeys across re-logins.
  private stateFile: (profile: string) => string | null;

  constructor(data: string, commands: LoginCommands = { claude: "claude", codex: "codex" }, env: () => Record<string, string> = () => cleanEnv([]), clock?: Clock.Clock, console = CONSOLE, cursor: CursorUrls = CURSOR, keyName: () => string = () => "still.fail", kimi = KIMI_AUTH) {
    this.console = console;
    this.kimi = kimi;
    this.cursor = cursor;
    this.keyName = keyName;
    this.background = new Fibers("login", clock);
    this.noBrowserDir = join(data, "run", "no-browser");
    this.agyLoginDir = join(data, "run", "agy-login");
    this.commands = commands;
    this.env = env;
    this.stateFile = (profile) => {
      const home = this.jobs.get(profile)?.home;
      return home ? join(home, LOGIN_BROWSER_FILE) : null;
    };
  }

  /// Overrides how a profile's sign-in browser state file is located (accounts/index.ts: follows a new profile's home
  /// once `newLogin` renames it).
  setStateFile(resolve: (profile: string) => string | null) {
    this.stateFile = resolve;
  }

  /// Hears the profile id of each login job that changes; gives the function that stops it.
  changes(listener: (profile: string) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  /// The station's browser, for the pages of sign-ins (logins/module.ts): a tab coming or going is told as a change.
  attach(pages: LoginPages) {
    this.pages = pages;
    pages.changes((key) => {
      const profile = key.startsWith("profile:") ? key.slice("profile:".length) : null;
      if (profile === null) return;
      const running = this.jobs.get(profile);
      if (running === undefined) return;
      // The Antigravity CLI's page come back with its code in the station's browser: taken from there, its tab closed,
      // nothing to paste (its code goes to antigravity.google alone, never back to this machine).
      if (running.job.state === "needs_code") {
        const code =
          running.callbackCode !== undefined
            ? running.callbackCode(pages.urlOf(key))
            : running.job.runtime === "agy"
              ? agyCallbackCode(pages.urlOf(key), running.job.url)
              : null;
        if (code !== null) {
          pages.close(key);
          void this.submitCode(profile, code, running.lang).catch((error) => log.warn("login", "a code read off the station's browser was not taken", { profile, error: (error as Error).message }));
          return;
        }
      }
      this.emit(profile);
    });
  }

  get(profile: string): LoginJob | null {
    const running = this.jobs.get(profile);
    if (running) {
      const job: LoginJob = { ...running.job };
      if (this.pages !== null) {
        const screen = this.pages.screenOf(pageKey(profile));
        if (screen !== null) job.screen = screen;
        if ((screen !== null || this.hasPage(running)) && this.pages.can()) job.browser = true;
      }
      return job;
    }
    const done = this.finished.get(profile);
    return done ? { ...done } : null;
  }

  /// The page a sign-in under way opens in the station's browser: the one its command opened where that comes back to
  /// it here (Claude's loopback one), else the one it gives to open; null when it has none (yet).
  private async stationPage(running: Running): Promise<string | null> {
    const { job } = running;
    if (job.state !== "needs_code" && job.state !== "needs_approval") return null;
    if (running.opened) {
      const opened = urlsIn(await readFile(running.opened, "utf8").catch(() => ""));
      const back = opened.findLast((u) => loopbackOf(u) !== null);
      if (back !== undefined) return (running.back = back);
    }
    return webPage(job.url) ? job.url : null;
  }

  /// Whether it has a page to open (`stationPage`) as far as is known without reading what its command opened: the
  /// page it gives (every command's is one), or the one it opened as it was last read.
  private hasPage(running: Running): boolean {
    const { job } = running;
    return (job.state === "needs_code" || job.state === "needs_approval") && (running.back !== undefined || webPage(job.url));
  }

  /// Opens the page of `profile`'s sign-in in the station's browser (the tab open already, if there is one): its
  /// screen.
  async openPage(profile: string, lang: Lang = stationLang()): Promise<string> {
    const running = this.jobs.get(profile);
    if (!running) throw new Error(tr(lang, "station.loginPage.nothing"));
    if (this.pages === null || !this.pages.can()) throw new Error(tr(lang, "station.loginPage.noBrowser"));
    const url = await this.stationPage(running);
    if (this.jobs.get(profile) !== running) throw new Error(tr(lang, "station.loginPage.nothing"));
    if (url === null && this.pages.screenOf(pageKey(profile)) === null) throw new Error(tr(lang, "station.loginPage.nothing"));
    let screen: string;
    try {
      screen = await this.pages.open(pageKey(profile), url ?? "about:blank", { stateFile: () => this.stateFile(profile) });
    } catch (error) {
      throw new Error(tr(lang, "station.loginPage.failed", { error: (error as Error).message }));
    }
    // Ended (or started again) meanwhile: its tab goes too.
    if (this.jobs.get(profile) !== running) {
      this.pages.close(pageKey(profile));
      throw new Error(tr(lang, "station.loginPage.nothing"));
    }
    return screen;
  }

  /// Starts a sign-in for a subscription profile, replacing any running one.
  async start(profile: LoginProfile, lang: Lang = stationLang()): Promise<LoginJob> {
    // (a pseudo-terminal where its command reads only from one: looked for first, before anything is recorded)
    const terminal =
      profile.runtime === "devin" ? await platform.terminalSoon(this.commands.devin ?? "devin", ["auth", "login", "--force-manual-token-flow"], DEVIN_COLS, DEVIN_ROWS)
      : profile.runtime === "agy" ? await platform.terminalSoon(this.commands.agy ?? "agy", [], DEVIN_COLS, DEVIN_ROWS)
      : null;
    this.cancel(profile.id);
    this.finished.delete(profile.id);
    const noBrowser = this.noBrowserDir;
    const sourceEnv = this.env();
    const clean = Object.fromEntries(Object.entries(sourceEnv).filter(([k]) => !SCRUBBED.includes(k)));
    let env = platform.prependPath(clean, noBrowser) as Record<string, string>;
    const run = ++this.runs;
    // The pages it opens, written down for the station's browser (one file a sign-in: one ended before is taken away
    // off this thread, never this one's).
    const opened = join(noBrowser, `${profile.id}-${run}.opened`);
    env.STILLFAIL_LOGIN_OPENED = opened;
    /// The directories it needs, made once it is recorded.
    const dirs = [profile.home];
    let command: string;
    let args: string[];
    let pathCommand: string | undefined;
    // The Antigravity CLI's HOME: an empty directory of this sign-in's (the top of this file says why).
    const stage = profile.runtime === "agy" ? join(this.agyLoginDir, `${profile.id}-${run}`) : null;
    if (profile.runtime === "claude") {
      env.CLAUDE_CONFIG_DIR = profile.home;
      const email = typeof profile.email === "string" && profile.email.trim() !== "" ? profile.email.trim() : null;
      [command, args] = [this.commands.claude, ["auth", "login", "--claudeai", ...(email ? ["--email", email] : [])]];
    } else if (profile.runtime === "grok") {
      env.GROK_HOME = join(profile.home, "grok");
      env.GROK_DISABLE_AUTOUPDATER = "1";
      dirs.push(env.GROK_HOME);
      [command, args] = [this.commands.grok ?? "grok", ["login", "--device-auth"]];
    } else if (profile.runtime === "devin") {
      env.XDG_DATA_HOME = devinData(profile.home);
      dirs.push(env.XDG_DATA_HOME);
      pathCommand = this.commands.devin ?? "devin";
      if (terminal === null) return this.refused(profile.id, profile.runtime, tr(lang, "station.login.devinNoTerminal"));
      [command, args] = terminal;
    } else if (stage !== null) {
      env.HOME = stage;
      // (Windows: its home is USERPROFILE's, HOME aside)
      env.USERPROFILE = stage;
      // Its sign-in kept in a file in that HOME, none of the keychain's (as a remote session's: it then asks the terminal
      // what it is, which `agyAnswer` answers).
      Object.assign(env, AGY_FILE_TOKENS);
      delete env.SSH_CONNECTION;
      env.AGY_CLI_DISABLE_AUTO_UPDATE = "1";
      pathCommand = this.commands.agy ?? "agy";
      if (terminal === null) return this.refused(profile.id, profile.runtime, tr(lang, "station.login.agyNoTerminal"));
      [command, args] = terminal;
    } else {
      env.CODEX_HOME = profile.home;
      [command, args] = [this.commands.codex, ["login", "--device-auth"]];
    }
    const now = this.background.now();
    const job: LoginJob = { profile: profile.id, runtime: profile.runtime, state: "starting", url: null, userCode: null, error: null, startedAt: now, expiresAt: now + TIMEOUT_MS };
    const id = profile.id;
    // The shell lookup can take time. Record the sign-in first so cancelling or replacing it stops this start too.
    const running: Running = {
      run, job, child: null, raw: "", output: "", exited: true, opened, lang, home: profile.home,
      ...(stage !== null ? { agy: { enterprise: profile.enterprise === true, cloud: false, license: false, billing: false, after: null, stage, terminal: false } } : {}),
      cancelTimer: this.background.after(TIMEOUT_MS, () => this.failRun(id, run, tr(lang, "station.login.timedOut"))),
    };
    this.jobs.set(id, running);
    this.emit(id);
    try {
      // (Claude Code kept off the keychain: its sign-in in the profile's home)
      const keychain = profile.runtime === "claude" ? fileCredentialsSoon(env) : null;
      const [open] = await Promise.all([this.noBrowser(), rm(opened, { force: true }), keychain, ...dirs.map((d) => mkdir(d, { recursive: true }))]);
      env.BROWSER = open;
    } catch (e) {
      if (this.jobs.get(id) !== running) return { ...job, state: "cancelled" };
      const error = tr(lang, "station.login.cannotRun", { error: (e as Error).message });
      this.finish(id, "failed", error);
      return { ...job, state: "failed", error };
    }
    if (this.jobs.get(id) !== running) return { ...job, state: "cancelled" };
    const dropStage = () => (stage !== null ? rm(stage, { recursive: true, force: true }).catch(() => {}) : Promise.resolve());
    if (stage !== null) {
      // Those an earlier sign-in of this profile left (the station ended under it) go first; never a later one's, made
      // while this listing was read.
      const left = await readdir(this.agyLoginDir).catch(() => [] as string[]);
      if (this.jobs.get(id) !== running) return { ...job, state: "cancelled" };
      const mine = (name: string) => {
        if (!name.startsWith(`${profile.id}-`)) return false;
        const rest = name.slice(profile.id.length + 1);
        const n = Number(rest);
        return /^\d+$/.test(rest) && Number.isInteger(n) && n >= 0 && n < run;
      };
      await Promise.all(left.filter(mine).map((name) => rm(join(this.agyLoginDir, name), { recursive: true, force: true }).catch(() => {})));
      try {
        await mkdir(stage, { recursive: true });
      } catch (e) {
        if (this.jobs.get(id) !== running) return { ...job, state: "cancelled" };
        const error = tr(lang, "station.login.cannotRun", { error: (e as Error).message });
        this.finish(id, "failed", error);
        return { ...job, state: "failed", error };
      }
      if (this.jobs.get(id) !== running) {
        await dropStage();
        return { ...job, state: "cancelled" };
      }
    }
    const foundEnv = await withShellCommand(pathCommand ?? command, env, sourceEnv);
    if (this.jobs.get(id) !== running) {
      await dropStage();
      return { ...job, state: "cancelled" };
    }
    // The browser stand-ins must stay ahead of any Node bin added for the login command.
    if (foundEnv !== env) env = platform.prependPath(foundEnv, noBrowser) as Record<string, string>;
    let child: ChildProcess;
    try {
      const r = await platform.runnableSoon(command, args, env);
      if (this.jobs.get(id) !== running) {
        await dropStage();
        return { ...job, state: "cancelled" };
      }
      child = spawn(r.file, r.args, { cwd: stage ?? profile.home, env, stdio: ["pipe", "pipe", "pipe"], windowsVerbatimArguments: r.windowsVerbatimArguments, windowsHide: true });
    } catch (e) {
      if (this.jobs.get(id) !== running) {
        await dropStage();
        return { ...job, state: "cancelled" };
      }
      void dropStage();
      running.exited = true;
      const error = tr(lang, "station.login.cannotRun", { error: (e as Error).message });
      this.finish(id, "failed", error);
      return { ...job, state: "failed", error };
    }
    running.child = child;
    running.exited = false;
    // Its HOME goes with it, whatever its end (what it signed in is copied out before it is stopped).
    if (stage !== null) child.once("close", () => void dropStage());
    const spawned = await started(child);
    if (this.jobs.get(id) !== running) {
      void dropStage();
      return { ...job, state: "cancelled" };
    }
    if (spawned) {
      void dropStage();
      // Recorded like any other failure, so the page shows why.
      running.exited = true;
      const error = tr(lang, "station.login.cannotRun", { error: spawned.message });
      this.finish(id, "failed", error);
      return { ...job, state: "failed", error };
    }
    // A later failure to write (the command gone) is its end's to say.
    child.stdin?.on("error", () => {});
    for (const stream of [child.stdout, child.stderr]) stream?.on("data", (chunk: Buffer) => this.output(id, run, chunk.toString("utf8")));
    // Everything it said is in before its end is judged: `close` comes after its output ends.
    child.once("close", (code, signal) => {
      const current = this.jobs.get(id);
      if (!current || current.run !== run) return;
      current.exited = true;
      if (code === 0) return this.finish(id, "done", null);
      const said = lastLines(current.output);
      const shown = code !== null ? String(code) : signal ? "signal" : "signal";
      this.finish(id, "failed", said !== "" ? said : tr(lang, "station.login.exited", { code: shown }));
    });
    log.info("login", "login started", { profile: id, runtime: profile.runtime });
    this.emit(id);
    return { ...job };
  }

  /// Starts signing an OpenCode Go profile in to the person's OpenCode Console account, replacing any running sign-in:
  /// a code from the Console, then asked about at the interval it gives until it is approved, refused or runs out.
  startConsole(profile: { id: string; home: string }, lang: Lang = stationLang()): Promise<LoginJob> {
    return this.deviceSignIn(profile, "opencode", lang, {
      start: () => startDevice(this.console),
      ask: (code) => deviceToken(this.console, code),
      keep: async (token) => {
        const who = await whoIs(this.console, token.access, token.org);
        return () => writeConsole(profile.home, { access: token.access, refresh: token.refresh, expiresAt: wall.now() + token.expiresInMs, org: token.org, ...who } satisfies ConsoleLogin);
      },
    });
  }

  /// Starts signing a Kimi Code profile in to the person's Kimi account the same way (kimi.ts), for a device of its own:
  /// the one it signed in on before where it has one (Kimi renews a token only for the device it was given to).
  /// Starts signing a Copilot profile in to GitHub (the Copilot CLI's OAuth app): a code for
  /// github.com/login/device, then the token the profile keeps for its SDK sessions.
  startCopilot(profile: { id: string; home: string }, lang: Lang = stationLang()): Promise<LoginJob> {
    return this.deviceSignIn(profile, "copilot", lang, {
      start: () => startCopilotDevice(),
      ask: (code) => copilotDeviceToken(code),
      keep: async (token) => () => writeCopilotToken(profile.home, token.access),
    });
  }

  async startKimi(profile: { id: string; home: string }, lang: Lang = stationLang()): Promise<LoginJob> {
    const deviceId = (await readKimi(profile.home))?.deviceId ?? newDeviceId();
    return this.deviceSignIn(profile, "kimi", lang, {
      start: () => startKimiDevice(this.kimi, deviceId),
      ask: (code) => kimiDeviceToken(this.kimi, code, deviceId),
      keep: async (token) => () => writeKimi(profile.home, { access: token.access, refresh: token.refresh, expiresAt: wall.now() + token.expiresInMs, lifeMs: token.expiresInMs, deviceId }),
    });
  }

  /// A device authorization grant (RFC 8628) the station follows itself: a code, then asked about at the interval given
  /// until it is approved, refused or runs out; then what `keep` makes of the tokens written to the profile's home.
  private async deviceSignIn(
    profile: { id: string; home: string },
    provider: "opencode" | "kimi" | "copilot",
    lang: Lang,
    steps: { start: () => Promise<Device>; ask: (deviceCode: string) => Promise<DeviceAnswer>; keep: (token: Token) => Promise<() => void | Promise<void>> },
  ): Promise<LoginJob> {
    const [failed, expired, denied, unreachable] =
      provider === "kimi"
        ? ["station.login.kimiFailed", "station.login.kimiExpired", "station.login.kimiDenied", "could not ask Kimi about a sign-in"]
        : provider === "copilot"
          ? ["station.login.copilotFailed", "station.login.copilotExpired", "station.login.copilotDenied", "could not ask GitHub about a sign-in"]
          : ["station.login.consoleFailed", "station.login.consoleExpired", "station.login.consoleDenied", "could not ask the OpenCode Console about a sign-in"];
    this.cancel(profile.id);
    this.finished.delete(profile.id);
    const id = profile.id;
    const now = this.background.now();
    const job: LoginJob = { profile: id, provider, state: "starting", url: null, userCode: null, error: null, startedAt: now, expiresAt: now + TIMEOUT_MS };
    const run = ++this.runs;
    const running: Running = { run, job, child: null, raw: "", output: "", exited: true, lang, home: profile.home, cancelTimer: () => {} };
    this.jobs.set(id, running);
    this.emit(id);
    const current = () => this.jobs.get(id)?.run === run;
    let device: Device;
    try {
      await mkdir(profile.home, { recursive: true });
      if (!current()) return this.get(id)!;
      device = await steps.start();
    } catch (e) {
      if (current()) this.finish(id, "failed", tr(lang, failed, { error: (e as Error).message }));
      return this.get(id)!;
    }
    if (!current()) return this.get(id)!;
    Object.assign(job, { state: "needs_approval", url: device.url, userCode: device.userCode, expiresAt: now + Math.min(device.expiresInMs, TIMEOUT_MS) });
    running.cancelTimer = this.background.after(job.expiresAt - now, () => this.failRun(id, run, tr(lang, expired)));
    let interval = device.intervalMs;
    const ask = async () => {
      if (!current()) return;
      let answer: DeviceAnswer;
      try {
        answer = await steps.ask(device.deviceCode);
      } catch (e) {
        // The network, for once: asked again at the next interval.
        log.warn("login", unreachable, { profile: id, error: (e as Error).message });
        answer = { pending: true as const, slowDown: false };
      }
      if (!current()) return;
      if ("pending" in answer) {
        if (answer.slowDown) interval += 5_000;
        running.stop = this.background.after(interval, ask);
        return;
      }
      if ("error" in answer) {
        if (answer.error === "access_denied") return this.finish(id, "failed", tr(lang, denied));
        return this.finish(id, "failed", answer.error === "expired_token" ? tr(lang, expired) : tr(lang, failed, { error: answer.error }));
      }
      job.state = "verifying";
      this.emit(id);
      const write = await steps.keep(answer.token);
      if (!current()) return;
      try {
        await write();
      } catch (e) {
        if (current()) this.finish(id, "failed", tr(lang, "station.login.homeFailed", { error: (e as Error).message }));
        return;
      }
      if (current()) this.finish(id, "done", null);
    };
    running.stop = this.background.after(interval, ask);
    log.info("login", "device sign-in started", { profile: id, provider });
    this.emit(id);
    return { ...job };
  }

  /// Starts signing a Cursor profile in to the person's Cursor account, replacing any running sign-in: a page to confirm
  /// the login on (no code), asked about until it is confirmed or runs out; then the key minted for the station.
  async startCursor(profile: { id: string; home: string }, lang: Lang = stationLang()): Promise<LoginJob> {
    this.cancel(profile.id);
    this.finished.delete(profile.id);
    const id = profile.id;
    const now = this.background.now();
    const handshake = cursorHandshake(this.cursor);
    const job: LoginJob = { profile: id, runtime: "cursor", state: "needs_approval", url: handshake.url, userCode: null, error: null, startedAt: now, expiresAt: now + TIMEOUT_MS };
    const run = ++this.runs;
    const running: Running = { run, job, child: null, raw: "", output: "", exited: true, lang, home: profile.home, cancelTimer: () => {} };
    this.jobs.set(id, running);
    running.cancelTimer = this.background.after(TIMEOUT_MS, () => this.failRun(id, run, tr(lang, "station.login.timedOut")));
    const current = () => this.jobs.get(id)?.run === run;
    try {
      await mkdir(profile.home, { recursive: true });
    } catch (e) {
      if (current()) this.finish(id, "failed", tr(lang, "station.login.homeFailed", { error: (e as Error).message }));
      return this.get(id)!;
    }
    if (!current()) return this.get(id)!;
    // Asked often at first (the person is on the page), less as it goes on.
    let interval = 1_000;
    const ask = async () => {
      if (!current()) return;
      let answer;
      try {
        answer = await pollCursor(this.cursor, handshake);
      } catch (e) {
        // The network, for once: asked again at the next interval.
        log.warn("login", "could not ask Cursor about a sign-in", { profile: id, error: (e as Error).message });
        answer = { pending: true as const };
      }
      if (!current()) return;
      if ("pending" in answer) {
        interval = Math.min(Math.round(interval * 1.2), 5_000);
        running.stop = this.background.after(interval, ask);
        return;
      }
      job.state = "verifying";
      this.emit(id);
      let minted;
      try {
        minted = await mintCursorKey(this.cursor, answer.accessToken, this.keyName());
      } catch (e) {
        if (current()) this.finish(id, "failed", tr(lang, "station.login.cursorKeyFailed", { error: (e as Error).message }));
        return;
      }
      if (!current()) return;
      try {
        await writeCursor(profile.home, { apiKey: minted.apiKey, email: minted.email, keyName: this.keyName(), createdAt: wall.now() });
      } catch (e) {
        if (current()) this.finish(id, "failed", tr(lang, "station.login.homeFailed", { error: (e as Error).message }));
        return;
      }
      if (current()) this.finish(id, "done", null);
    };
    running.stop = this.background.after(interval, ask);
    log.info("login", "Cursor sign-in started", { profile: id });
    this.emit(id);
    return { ...job };
  }

  /// Starts an OAuth2 authorization-code sign-in for a service profile (no CLI child process).
  async startOAuthCode(
    profile: { id: string; home: string; service: string },
    flow: {
      authUrl: string;
      validate?: (rawCode: string, lang: Lang) => string;
      exchange: (code: string, lang: Lang) => Promise<void>;
      callbackCode?: (tabUrl: string | null) => string | null;
    },
    lang: Lang = stationLang(),
  ): Promise<LoginJob> {
    this.cancel(profile.id);
    this.finished.delete(profile.id);
    const id = profile.id;
    const now = this.background.now();
    const job: LoginJob = {
      profile: id,
      service: profile.service,
      state: "needs_code",
      url: flow.authUrl,
      userCode: null,
      error: null,
      startedAt: now,
      expiresAt: now + TIMEOUT_MS,
    };
    const run = ++this.runs;
    const running: Running = {
      run,
      job,
      child: null,
      raw: "",
      output: "",
      exited: true,
      lang,
      home: profile.home,
      ...(flow.validate !== undefined ? { validateCode: flow.validate } : {}),
      onCode: flow.exchange,
      ...(flow.callbackCode !== undefined ? { callbackCode: flow.callbackCode } : {}),
      cancelTimer: this.background.after(TIMEOUT_MS, () => this.failRun(id, run, tr(lang, "station.login.timedOut"))),
    };
    this.jobs.set(id, running);
    try {
      await mkdir(profile.home, { recursive: true });
    } catch (e) {
      if (this.jobs.get(id) === running) this.finish(id, "failed", tr(lang, "station.login.homeFailed", { error: (e as Error).message }));
      return this.get(id)!;
    }
    if (this.jobs.get(id) !== running) return this.get(id) ?? { ...job, state: "cancelled" };
    log.info("login", "OAuth code sign-in started", { profile: id, service: profile.service });
    this.emit(id);
    return { ...job };
  }

  /// A sign-in that cannot be started here, recorded like any other failure, so the page shows why.
  private refused(id: string, runtime: Runtime | undefined, error: string, service?: string): LoginJob {
    const now = this.background.now();
    const failed: LoginJob = { profile: id, ...(runtime !== undefined ? { runtime } : {}), ...(service !== undefined ? { service } : {}), state: "failed", url: null, userCode: null, error, startedAt: now, expiresAt: now };
    this.finished.set(id, failed);
    this.emit(id);
    return { ...failed };
  }

  /// Claude and Devin: the code the browser showed after approving. The Antigravity CLI's company account with no
  /// licence: its Google Cloud project, the same way (`needs_project`).
  async submitCode(profile: string, code: string, lang: Lang = stationLang()): Promise<LoginJob> {
    const running = this.jobs.get(profile);
    if (!running || (running.job.state !== "needs_code" && running.job.state !== "needs_project")) throw new Error(tr(lang, "station.login.notWaitingForCode"));
    const trimmed = code.trim();
    if (trimmed === "") throw new Error(tr(lang, "station.login.emptyCode"));
    if (running.onCode !== undefined) {
      const clean = running.validateCode ? running.validateCode(trimmed, lang) : trimmed;
      running.stop?.();
      running.stop = this.background.after(VERIFY_WAIT_MS, () => { // timer: a deadline for OAuth code exchange
        if (this.jobs.get(profile) === running && running.job.state === "verifying") this.finish(profile, "failed", tr(running.lang, "station.login.verifyTimedOut"));
      });
      running.job.state = "verifying";
      const job = { ...running.job };
      this.emit(profile);
      try {
        await running.onCode(clean, lang);
        if (this.jobs.get(profile) === running && running.job.state === "verifying") this.finish(profile, "done", null);
      } catch (e) {
        if (this.jobs.get(profile) === running && running.job.state === "verifying") this.finish(profile, "failed", (e as Error).message);
      }
      return this.get(profile) ?? job;
    }
    // Claude's is checked before it goes in: one it would not take is refused here, the sign-in still waiting for a code.
    const clean = running.job.runtime === "claude" ? claudeCodeOf(trimmed, running.job.url, lang) : trimmed;
    // What it says from here on is read for what comes next (its question for the project, which was said, not again).
    if (running.agy) running.agy.after = "";
    running.stop?.();
    running.stop = undefined;
    running.job.state = "verifying";
    if (running.job.runtime === "claude") running.said = "";
    if (running.job.runtime === "claude" || running.job.runtime === "devin") {
      running.stop = this.background.after(VERIFY_WAIT_MS, () => { // timer: a deadline for the command to take the code
        if (this.jobs.get(profile) === running && running.job.state === "verifying") this.finish(profile, "failed", tr(running.lang, "station.login.verifyTimedOut"));
      });
    }
    const job = { ...running.job };
    await new Promise<void>((resolve, reject) => {
      const stdin = running.child?.stdin;
      if (!stdin || stdin.destroyed) return resolve();
      // Devin and the Antigravity CLI read it in a terminal of their own, where Enter is a carriage return.
      const terminal = running.job.runtime === "devin" || running.job.runtime === "agy";
      stdin.write(`${clean}${terminal ? "\r" : "\n"}`, (error) => (error ? reject(error) : resolve()));
    });
    if (running.job.runtime === "agy") this.awaitAgy(profile, running);
    this.emit(profile);
    return job;
  }

  /// The Antigravity CLI goes on into its interface once signed in: done when it has written its sign-in whole in its
  /// HOME (a company's account writes it first with only its token, its licence or project after: `agyTokenReady`),
  /// which is then written into the profile's agy/ (the one there kept until then: a sign-in given up or failed leaves
  /// it as it was); failed when it has not in a while (a code it did not take: it says nothing a program can read of
  /// it). While it waits for a project from the person it is not timed (the sign-in's own expiry still holds).
  private awaitAgy(profile: string, running: Running) {
    const until = this.background.now() + AGY_WAIT_MS;
    const steps = running.agy!;
    const signedIn = agyTokenIn(join(steps.stage, ".gemini"));
    const look = async () => {
      if (this.jobs.get(profile) !== running || running.job.state !== "verifying") return;
      const home = running.home;
      if (home !== undefined) {
        const text = await readFile(signedIn, "utf8").catch(() => "");
        if (this.jobs.get(profile) !== running || running.job.state !== "verifying") return;
        if (agyTokenReady(text, steps.enterprise)) {
          try {
            await writePrivateSoon(agyToken(home), text);
          } catch (e) {
            if (this.jobs.get(profile) === running) this.finish(profile, "failed", tr(running.lang, "station.login.homeFailed", { error: (e as Error).message }));
            return;
          }
          await noteAgyEmail(home, text).catch(() => null);
          if (this.jobs.get(profile) === running && running.job.state === "verifying") this.finish(profile, "done", null);
          return;
        }
      }
      if (this.background.now() > until) return this.finish(profile, "failed", tr(running.lang, "station.login.agyCodeRefused"));
      running.stop = this.background.after(AGY_POLL_MS, () => void look());
    };
    void look();
  }

  /// What the Antigravity CLI asks, answered (`output`): how to sign in, and for a company's account the way into
  /// Google Cloud; once its code went in, its licence (the first), how to pay (as it goes) and the project (asked of the
  /// person); what it says of a failure ends the sign-in at once, saying it.
  private agyAnswer(profile: string, running: Running, chunk: string) {
    const steps = running.agy!;
    const write = (keys: string) => running.child?.stdin?.write(keys);
    // A choice further down: the arrow, then Enter a moment later (it reads the two apart).
    const second = () => {
      write("\u001b[B");
      const run = running.run;
      this.background.after(AGY_KEY_GAP_MS, () => {
        if (this.jobs.get(profile)?.run === run) write("\r");
      });
    };
    // Its question to the terminal, as a remote session's, answered once, before it asks anything else.
    if (running.job.state === "starting" && !running.chose && !steps.terminal && running.raw.includes(AGY_TERMINAL_ASKED)) {
      steps.terminal = true;
      write(AGY_TERMINAL_ANSWER);
    }
    if (running.job.state === "starting" && !running.chose && running.output.includes("Select login method")) {
      running.chose = true;
      if (steps.enterprise) second();
      else write("\r");
      return;
    }
    if (steps.enterprise && !steps.cloud && running.job.state === "starting" && (running.output.includes("Google Cloud sign-in method") || running.output.includes("Continue with Google Cloud"))) {
      steps.cloud = true;
      write("\r");
      return;
    }
    if (steps.after === null) return;
    // Read whole: an escape can be cut between two pieces.
    const raw = [...(steps.after + chunk)];
    steps.after = raw.slice(Math.max(0, raw.length - 16000)).join("");
    const said = stripAnsi(steps.after);
    // (a line of its licences not listed is no failure, whatever it says: it goes on)
    const failed = said.split(/\r?\n/).find((l) => !l.includes(AGY_NO_LICENCES) && AGY_FAILURES.some((f) => l.includes(f)));
    if (failed !== undefined && (running.job.state === "verifying" || running.job.state === "needs_project")) {
      const line = failed.trim().replace(/^\[Auth Error\]\s*/, "").trim();
      return this.finish(profile, "failed", tr(running.lang, "station.login.agyFailed", { error: line.slice(0, 300) }));
    }
    if (!steps.license && said.includes("Can't find your subscription?")) {
      steps.license = true;
      write("\r");
      return;
    }
    if (!steps.billing && said.includes("Pay only for the tokens you use")) {
      steps.billing = true;
      second();
      return;
    }
    if (running.job.state === "verifying" && said.includes("Provide Google Cloud project")) {
      running.stop?.();
      running.stop = undefined;
      running.job.state = "needs_project";
      this.emit(profile);
    }
  }

  cancel(profile: string) {
    if (this.jobs.has(profile)) this.finish(profile, "cancelled", null);
  }

  stopAll() {
    for (const id of [...this.jobs.keys()]) this.cancel(id);
  }

  /// Stops every sign-in and what waits on them.
  async close() {
    this.stopAll();
    await this.background.close();
  }

  private output(profile: string, run: number, chunk: string) {
    const running = this.jobs.get(profile);
    if (!running || running.run !== run) return;
    // Read whole: an escape can be cut between two pieces.
    running.raw += chunk;
    const raw = [...running.raw];
    if (raw.length > 16000) running.raw = raw.slice(raw.length - 16000).join("");
    running.output = stripAnsi(running.raw);
    if (running.agy) {
      this.agyAnswer(profile, running, chunk);
      if (this.jobs.get(profile) !== running) return;
    }
    if (running.said !== undefined && running.job.state === "verifying") {
      const said = [...(running.said + chunk)];
      running.said = said.slice(Math.max(0, said.length - 4000)).join("");
      // It waits on for Enter and another code: ended here, saying what to paste.
      if (stripAnsi(running.said).toLowerCase().includes(CLAUDE_CODE_REFUSED)) return this.finish(profile, "failed", tr(running.lang, "station.login.claudeIncompleteCode"));
    }
    if (parse(running.job, running.output)) this.emit(profile);
  }

  private failRun(profile: string, run: number, error: string) {
    if (this.jobs.get(profile)?.run === run) this.finish(profile, "failed", error);
  }

  private finish(profile: string, state: LoginState, error: string | null) {
    const running = this.jobs.get(profile);
    if (!running) return;
    this.jobs.delete(profile);
    running.cancelTimer();
    running.stop?.();
    if (!running.exited && running.child) {
      const child = running.child;
      // The Antigravity CLI does not end by itself once signed in, in a terminal of its own: the processes between
      // (macOS: a shell, `cat`, script) end with it, all of them found first, as they would be left behind.
      if (running.job.runtime === "agy" && child.pid !== undefined) {
        const pid = child.pid;
        void platform.descendants(pid).then((pids) => {
          for (const p of [pid, ...pids]) {
            try {
              process.kill(p, "SIGTERM");
            } catch {}
          }
        });
      } else {
        try {
          child.kill("SIGTERM");
        } catch {}
      }
    }
    if (running.opened) void rm(running.opened, { force: true }).catch(() => {});
    this.pages?.close(pageKey(profile));
    this.finished.set(profile, { ...running.job, state, error });
    log.info("login", "login ended", { profile, state, error });
    this.emit(profile);
  }

  private emit(profile: string) {
    for (const listener of this.listeners) {
      try {
        listener(profile);
      } catch (e) {
        log.warn("login", "a login listener failed", { error: (e as Error).message });
      }
    }
  }

  /// Makes the directory whose `open` and `xdg-open` open nothing, put first on the login command's PATH
  /// (`noBrowserDir`); gives what `open` is to be called by (BROWSER). Each writes the pages it is given to the file
  /// STILLFAIL_LOGIN_OPENED names (on Windows it does nothing).
  private async noBrowser(): Promise<string> {
    await mkdir(this.noBrowserDir, { recursive: true });
    const script = `#!/bin/sh\n# A browser for a sign-in run by still.fail (station/src/accounts/login.ts): the page goes to the station.\n[ -n "$STILLFAIL_LOGIN_OPENED" ] || exit 0\nfor a in "$@"; do printf '%s\\n' "$a" >> "$STILLFAIL_LOGIN_OPENED"; done\nexit 0\n`;
    const [open] = await Promise.all(["open", "xdg-open"].map((name) => platform.makeCommandSoon(join(this.noBrowserDir, name), script, true)));
    return open!;
  }
}

/// Reads where to sign in from what the command said so far. Whether the job changed.
export function parse(job: LoginJob, output: string): boolean {
  if (job.state !== "starting") return false;
  const urls = output
    .split(/\s+/)
    .filter((w) => w.includes("https://"))
    .map((w) => w.slice(w.indexOf("https://")));
  if (job.runtime === "claude") {
    const url = urls.find((u) => u.includes("/oauth/authorize?") && !u.endsWith("?"));
    if (url !== undefined && output.toLowerCase().includes("paste code")) {
      job.url = url;
      job.state = "needs_code";
      return true;
    }
  } else if (job.runtime === "agy") {
    const url = urls.find((u) => u.startsWith("https://accounts.google.com/o/oauth2/") && u.includes("antigravity.google%2Foauth-callback"));
    if (url !== undefined && output.toLowerCase().includes("authorization code")) {
      job.url = url;
      job.state = "needs_code";
      return true;
    }
  } else if (job.runtime === "devin") {
    const url = urls.find((u) => u.startsWith("https://app.devin.ai/auth/cli/") && u.includes("code_challenge="));
    if (url !== undefined && output.toLowerCase().includes("paste it")) {
      job.url = url;
      job.state = "needs_code";
      return true;
    }
  } else {
    const site = job.runtime === "grok" ? "https://accounts.x.ai/" : "https://auth.openai.com/";
    const url = urls.find((u) => u.startsWith(site) && u.includes("device"));
    const code = deviceCode(output);
    if (url !== undefined && code !== null) {
      job.url = url;
      job.userCode = code;
      job.state = "needs_approval";
      return true;
    }
  }
  return false;
}

/// The code to type into `claude auth login` of what was pasted (trimmed): `code#state` as its page shows it, or the
/// address that page was at (`…/callback?code=…&state=…`), made `code#state`. Refused, saying what to paste instead,
/// where the command would not take it (no `#`, nothing on a side of it: it says so and waits on, 2.1.321) or where its
/// state is another sign-in's than `authUrl`'s.
export function claudeCodeOf(clean: string, authUrl: string | null, lang: Lang): string {
  let expected = "";
  try {
    expected = authUrl !== null ? (new URL(authUrl).searchParams.get("state")?.trim() ?? "") : "";
  } catch {}
  let pasted: URL | null = null;
  if (/^https?:\/\//i.test(clean)) {
    try {
      pasted = new URL(clean);
    } catch {}
  }
  let code: string;
  let state: string;
  if (pasted !== null) {
    // (the authorize link itself, pasted back, says `code=true` and the state: no code of the person's)
    const authorize = /\/authorize\/?$/.test(pasted.pathname);
    code = authorize ? "" : (pasted.searchParams.get("code")?.trim() ?? "");
    state = pasted.searchParams.get("state")?.trim() ?? "";
  } else {
    const parts = clean.split("#");
    if (parts.length !== 2) throw new Error(tr(lang, "station.login.claudeIncompleteCode"));
    code = parts[0]!.trim();
    state = parts[1]!.trim();
  }
  if (code === "" || state === "") throw new Error(tr(lang, "station.login.claudeIncompleteCode"));
  if (expected !== "" && state !== expected) throw new Error(tr(lang, "station.login.claudeWrongState"));
  return `${code}#${state}`;
}

/// The code Google gave an Antigravity CLI sign-in, read off the page its browser came back to
/// (https://antigravity.google/oauth-callback?code=…&state=…), when that is its sign-in's (`authUrl`'s `state`); else null.
export function agyCallbackCode(tabUrl: string | null, authUrl: string | null): string | null {
  if (tabUrl === null) return null;
  let back: URL;
  try {
    back = new URL(tabUrl);
  } catch {
    return null;
  }
  if (back.origin !== "https://antigravity.google" || back.pathname.replace(/\/+$/, "") !== "/oauth-callback") return null;
  const code = back.searchParams.get("code")?.trim() ?? "";
  if (code === "") return null;
  let state = "";
  try {
    state = authUrl !== null ? (new URL(authUrl).searchParams.get("state") ?? "") : "";
  } catch {}
  if (state !== "" && back.searchParams.get("state") !== state) return null;
  return code;
}

/// A one-time code like ABCD-12345: four capitals or digits, a dash, four to six more.
export function deviceCode(output: string): string | null {
  const code = (s: string, min: number, max: number) => s.length >= min && s.length <= max && /^[A-Z0-9]+$/.test(s);
  for (const word of output.split(/[^A-Za-z0-9_-]/)) {
    const parts = word.split("-");
    for (let i = 0; i + 1 < parts.length; i++) {
      if (code(parts[i]!, 4, 4) && code(parts[i + 1]!, 4, 6)) return `${parts[i]}-${parts[i + 1]}`;
    }
  }
  return null;
}

/// Drops terminal escapes (colours, cursor moves): ESC [ parameters letter; and ESC ] … ended by BEL or ESC \ (a
/// link's target, as Devin writes its sign-in page: the page's address is in the text too).
export function stripAnsi(text: string): string {
  let out = "";
  const chars = [...text];
  for (let i = 0; i < chars.length; i++) {
    const c = chars[i]!;
    if (c === "\u001b" && chars[i + 1] === "]") {
      i += 1;
      while (i + 1 < chars.length && chars[i + 1] !== "\u0007" && !(chars[i + 1] === "\u001b" && chars[i + 2] === "\\")) i += 1;
      i += chars[i + 1] === "\u0007" ? 1 : 2;
      continue;
    }
    if (c === "\u001b" && chars[i + 1] === "[") {
      i += 1;
      while (i + 1 < chars.length) {
        const p = chars[i + 1]!;
        i += 1;
        if (/[A-Za-z]/.test(p)) break;
        if (!/[0-9;?]/.test(p)) break;
      }
      continue;
    }
    out += c;
  }
  return out;
}

function lastLines(output: string): string {
  const lines = output
    .trim()
    .split(/\r?\n/)
    .filter((l) => l.trim() !== "");
  return [...lines.slice(Math.max(0, lines.length - 4)).join("\n")].slice(0, 600).join("");
}
