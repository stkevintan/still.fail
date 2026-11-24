// Farview (AFK-surf/farview-legacy, a browser whose pages run on a host and draw on the person's device) as a chat's browser,
// in place of its Chrome context: config.json `browser: { farview?: "<the unpacked release: bin/host.exe,
// bin/agent.exe, lib/>" | false, engine?: "chrome" | "farview", sessions?: [<session>...] }`. With no `farview`, a
// station on a system Farview is released for has it all the same: the release its version names, downloaded and
// unpacked the first time a chat's Farview starts (farview-release.ts); `farview: false` is none, the chats' browser
// Chrome alone. Released to chats one at a time (the lead, 2026-11-16): `engine: "farview"` makes it every chat's; else
// Chrome stays the chats' browser but for the sessions listed and those whose agent chose Farview (the `browser`
// tool's `engine`, kept in the chat's directory).
//
// A chat's Farview is a tab or several, each a host process (`host.exe --tab`) that lasts with nobody connected, in a
// directory of its own (<data>/browser/farview/<chat>/tabs/<n>: its address, host.json while it runs), all of them
// one profile (<chat>/profile: cookies and local storage, shared as they change, FV_PROFILE_DIR), gone with the chat.
// Tab 0 is the chat's first, started as its agent asks for its browser; the others are opened by the agent or by a
// page (a link to a new window, window.open: the host says `openTab` on its frame port, FV_NEW_TABS), each one of the
// screens. Each tab's host knows its own id among the profile's (FV_TAB_ID) and, for a window a page opened with a
// handle to it (an OAuth popup), the tab that opened it and its origin (FV_OPENER_ID, FV_OPENER_ORIGIN): the two talk
// through the profile (postMessage, window.opener). A page that closes its tab (window.close()) has it closed here
// (`closeTab` on its frame port, and `closed: true` in its host.json for a station process that takes it up later).
// A host listens on 127.0.0.1 only: its agent port (driven with `agent.exe`, which the `browser` tool tells the agent
// of) and its frame port (JSON lines; what the tab's screen is made of, farview-screen.ts). It is started as
// a job is, in a group of its own, and outlives a station process: the next one takes it up by the `host.json` it
// wrote.
//
// Sign-ins ( 登录态) go into the tab as they go into a chat's Chrome context (browsers.ts): a sign-in the vault grants
// is its cookies set in the host's jar, taken out again as the grant ends; one kept is read from it; a card's sign-in
// fills the tab's form (farview-form.ts). A sign-in's passkeys go into the profile's own authenticator (the host's: its
// passkeys.json, which a page's navigator.credentials signs with) and come out with its cookies; a host from before
// it had one (no PublicKeyCredential in its pages) is asked none of them, so nothing is sent that it would not read.
// Not yet: the login pages a station opens of its own are Chrome's.
import { createHash } from "node:crypto";
import { access, mkdir, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import { connect } from "node:net";
import { join } from "node:path";
import { Clock, Effect } from "effect";
import { liveClock, wall } from "../ops/fibers.ts";
import { endGroup, groupAlive, startTimeOf } from "../ops/group.ts";
import { log } from "../ops/log.ts";
import { startLasting } from "../ops/processes.ts";
import type { Screens } from "../screens/source.ts";
import type { BrowserStatus } from "./browser.ts";
import { askTab } from "./farview-agent.ts";
import { FARVIEW_RELEASES, type FarviewRelease, farviewCacheDir, farviewSources, farviewAsset, farviewTarget, unpackRelease, type Fetch } from "./farview-release.ts";
import { FarviewForm } from "./farview-form.ts";
import { FarviewScreen, type OpenTabMeta } from "./farview-screen.ts";
import { type Passkey, passkeyOf, sitePasskeys } from "./passkeys.ts";
import { type CookieParam, allCookies, ofSites } from "./signins.ts";
import type { TabInfo } from "./tabs.ts";

export type Engine = "chrome" | "farview";

/// Where Farview is and whose browser it is, as the config says it; null: the chats have Chrome. `release`: the release
/// `dir` is to be unpacked from where it is not there yet (none: a directory the config names).
export type FarviewConfig = {
  dir: string;
  host: string;
  agent: string;
  engine: Engine;
  sessions: string[];
  release?: { target: string; rev: string; sha256: string };
};

/// The config's Farview: the directory `browser.farview` names; else, unless it says `false`, the release for
/// `target` (this system) in `releases`, kept in the machine's cache of native parts.
export function farviewConfig(
  raw: any,
  target: string = farviewTarget(),
  releases: Readonly<Record<string, FarviewRelease>> = FARVIEW_RELEASES,
  env: NodeJS.ProcessEnv = process.env,
): FarviewConfig | null {
  const b = raw?.browser !== null && typeof raw?.browser === "object" ? raw.browser : {};
  if (b.farview === false) return null;
  const sessions = Array.isArray(b.sessions) ? b.sessions.filter((s: unknown): s is string => typeof s === "string" && s !== "") : [];
  const engine: Engine = b.engine === "farview" ? "farview" : "chrome";
  const at = (dir: string) => ({ dir, host: join(dir, "bin", "host.exe"), agent: join(dir, "bin", "agent.exe"), engine, sessions });
  if (typeof b.farview === "string" && b.farview !== "") return at(b.farview);
  const release = Object.hasOwn(releases, target) ? releases[target] : undefined;
  if (release === undefined) return null;
  return { ...at(farviewCacheDir(target, release, env)), release: { target, ...release } };
}

/// Whether `session`'s chat has Farview for its browser: what its agent chose (`chosen`) where it chose, else every
/// chat's where the config says so, else the sessions it lists. A chat the config gives Farview goes back to Chrome
/// by choosing it.
export function farviewFor(config: FarviewConfig | null, session: string, chosen: Engine | undefined): boolean {
  if (config === null) return false;
  if (chosen !== undefined) return chosen === "farview";
  return config.engine === "farview" || config.sessions.includes(session);
}

/// What a host writes into its state directory once it listens: its process and its ports; `closed` once its page
/// closed its tab.
export type HostFile = { pid: number; port: number; agent: number; frame: number; closed?: true };

export function hostFileOf(v: any): HostFile | null {
  const port = (n: unknown) => typeof n === "number" && Number.isInteger(n) && n > 0 && n < 65536;
  return v && typeof v === "object" && Number.isInteger(v.pid) && v.pid > 0 && port(v.port) && port(v.agent) && port(v.frame)
    ? { pid: v.pid, port: v.port, agent: v.agent, frame: v.frame, ...(v.closed === true ? { closed: true as const } : {}) }
    : null;
}

/// A chat's directory name: its session key is not one (`chat:c-…`, a Slack thread's address).
export const chatDir = (session: string): string => createHash("sha256").update(session).digest("hex").slice(0, 24);

/// The page a new tab opens on.
export const FIRST_PAGE = "about:blank";
/// How long a host is given to say it listens, and to end once asked.
const START_MS = 20_000;
const END_MS = 5_000;
const LOOK_MS = 100;

type Host = HostFile & { started: number | null; dir: string; n: number; screen: FarviewScreen; unscreen: () => void; authenticator?: boolean };

/// A tab of a chat's Farview as the `browser` tool lists it: its id (as its screen's after `browser:`), and the port
/// its agent drives it on.
export type FarviewTab = TabInfo & { agent: number };

export type FarviewOptions = {
  /// <data>/browser/farview: a directory a chat.
  dir: string;
  config: () => FarviewConfig | null;
  screens?: Screens;
  /// How a release's tarball is downloaded (a test's own; else over HTTPS), and from where.
  fetch?: Fetch;
  sources?: (name: string) => string[];
};

/// Whether something answers on a port of 127.0.0.1.
function answers(port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const s = connect({ host: "127.0.0.1", port });
    const done = (ok: boolean) => {
      s.destroy();
      resolve(ok);
    };
    s.once("connect", () => done(true));
    s.once("error", () => done(false));
  });
}

export class FarviewTabs {
  readonly #o: FarviewOptions;
  /// Each chat's tabs that run, by session and number.
  readonly #hosts = new Map<string, Map<number, Host>>();
  /// Starts under way, by session and number: asked again meanwhile, the same one.
  readonly #starting = new Map<string, Promise<Host>>();
  /// What each chat's agent chose (`engine` in its directory), read as the station starts and as it is chosen.
  readonly #chosen = new Map<string, Engine>();
  /// A chat's tabs opened one at a time (each takes the next number).
  readonly #opening = new Map<string, Promise<unknown>>();
  /// A release being unpacked, by where it goes: asked again meanwhile, the same one.
  readonly #unpacking = new Map<string, Promise<void>>();

  constructor(o: FarviewOptions) {
    this.#o = o;
  }

  /// Where Farview is, where the config names it (whoever's browser it is).
  active(): FarviewConfig | null {
    return this.#o.config();
  }

  /// Whether `session`'s chat has Farview for its browser (its tabs, sign-ins and form are here, not in Chrome).
  activeFor(session: string): boolean {
    return farviewFor(this.active(), session, this.#chosen.get(session));
  }

  /// `session`'s agent chose `engine` for its chat's browser: kept in its directory, for this station process and the
  /// next. Choosing Chrome ends its Farview tabs (their profile stays).
  async choose(session: string, engine: Engine): Promise<void> {
    const config = this.active();
    if (config === null) throw new Error("Farview is not on this station (config.json `browser.farview`, or no release for this system): this chat's browser is Chrome.");
    if (engine === "farview") await this.ready(config);
    const chat = this.#chatOf(session);
    await mkdir(chat, { recursive: true, mode: 0o700 });
    await writeFile(join(chat, "session"), session, { mode: 0o600 });
    await writeFile(join(chat, "engine"), engine, { mode: 0o600 });
    this.#chosen.set(session, engine);
    if (!this.activeFor(session)) await this.stop(session);
  }

  /// Farview's release unpacked where `config` says, downloaded the first time (once, however many ask meanwhile; one
  /// that failed is tried again the next time it is asked). A directory the config names is as it is.
  async ready(config: FarviewConfig): Promise<void> {
    const r = config.release;
    if (r === undefined) return;
    let made = this.#unpacking.get(config.dir);
    if (made === undefined) {
      const name = farviewAsset(r.target, r);
      made = unpackRelease(config.dir, r.target, r, this.#o.sources?.(name) ?? farviewSources(name), this.#o.fetch).then(
        () => log.info("browser", "Farview's release unpacked", { dir: config.dir, rev: r.rev }),
        (e) => {
          this.#unpacking.delete(config.dir);
          throw e;
        },
      );
      this.#unpacking.set(config.dir, made);
    }
    await made;
  }

  #chatOf(session: string): string {
    return join(this.#o.dir, chatDir(session));
  }

  #tabDir(session: string, n: number): string {
    return join(this.#chatOf(session), "tabs", String(n));
  }

  #profileOf(session: string): string {
    return join(this.#chatOf(session), "profile");
  }

  #tabsOf(session: string): Map<number, Host> {
    let m = this.#hosts.get(session);
    if (m === undefined) {
      m = new Map();
      this.#hosts.set(session, m);
    }
    return m;
  }

  /// The host `dir` says runs, if it is still that process and answers on its agent port.
  async #find(session: string, n: number, dir: string): Promise<Host | null> {
    const file = await this.#alive(dir);
    return file === null ? null : this.#up(session, n, dir, file, await startTimeOf(file.pid));
  }

  async #fileOf(dir: string): Promise<HostFile | null> {
    try {
      return hostFileOf(JSON.parse(await readFile(join(dir, "host.json"), "utf8")));
    } catch {
      return null;
    }
  }

  async #alive(dir: string): Promise<HostFile | null> {
    const file = await this.#fileOf(dir);
    return file !== null && groupAlive(file.pid) && (await answers(file.agent)) ? file : null;
  }

  #up(session: string, n: number, dir: string, file: HostFile, started: number | null): Host {
    const screen = new FarviewScreen({ session, port: file.frame, n });
    // (a page that asks for a new tab: opened beside it, one of the screens, linked to this one where it is a window
    // the page holds)
    screen.opened = (url, meta) => {
      void this.open(session, url, meta).catch((e) => log.warn("browser", "a tab a page asked for could not be opened", { session, error: (e as Error).message }));
    };
    // (a page that closed its tab: closed here, back to the tab that opened it; never the chat's first)
    screen.closedByPage = () => {
      if (n !== 0) void this.closeTab(session, screen.id).catch((e) => log.warn("browser", "a tab its page closed could not be closed", { session, error: (e as Error).message }));
    };
    const unscreen = this.#o.screens?.add(screen) ?? (() => {});
    screen.watch();
    const host: Host = { ...file, started, dir, n, screen, unscreen };
    this.#tabsOf(session).set(n, host);
    return host;
  }

  /// `session`'s chat's tab `n` (0: its first): the one that runs (this process's, or one an earlier station process
  /// left), else started.
  async host(session: string, n = 0): Promise<Host> {
    const had = this.#hosts.get(session)?.get(n);
    if (had !== undefined) {
      if (groupAlive(had.pid)) return had;
      this.#forget(session, n);
    }
    const key = `${n}\n${session}`;
    const starting = this.#starting.get(key);
    if (starting) return starting;
    const made = this.#start(session, n).finally(() => this.#starting.delete(key));
    this.#starting.set(key, made);
    return made;
  }

  /// A chat's directory as a station from before kept it (one tab, its profile and address beside its host.json):
  /// its host ended, its profile and address moved where they go now.
  async #moveOld(session: string): Promise<void> {
    const chat = this.#chatOf(session);
    const old = await this.#alive(chat);
    if (old !== null) await this.#end(old.pid);
    await rm(join(chat, "host.json"), { force: true });
    const profile = this.#profileOf(session);
    const tab = this.#tabDir(session, 0);
    for (const [name, to] of [["cookies.txt", profile], ["storage.json", profile], ["url", tab]] as const) {
      try {
        await access(join(chat, name));
      } catch {
        continue;
      }
      await mkdir(to, { recursive: true, mode: 0o700 });
      await rename(join(chat, name), join(to, name));
    }
  }

  async #start(session: string, n: number, url?: string, meta?: OpenTabMeta): Promise<Host> {
    const config = this.active();
    if (config === null) throw new Error("Farview is not this station's browser (config.json `browser`).");
    await this.ready(config);
    try {
      await access(config.host);
    } catch {
      throw new Error(`Farview's host is not at ${config.host}: unpack its release there, or say \`browser.farview: false\` in config.json for Chrome.`);
    }
    const dir = this.#tabDir(session, n);
    const found = await this.#find(session, n, dir);
    if (found !== null) return found;
    const chat = this.#chatOf(session);
    if (n === 0) await this.#moveOld(session);
    await mkdir(dir, { recursive: true, mode: 0o700 });
    await mkdir(this.#profileOf(session), { recursive: true, mode: 0o700 });
    await rm(join(dir, "host.json"), { force: true });
    // (whose chat it is, for the next station process to take its hosts up as it starts: `resume`)
    await writeFile(join(chat, "session"), session, { mode: 0o600 });
    if (url === undefined) {
      try {
        url = (await readFile(join(dir, "url"), "utf8")).trim() || FIRST_PAGE;
      } catch {
        url = FIRST_PAGE;
      }
    }
    // (its id among the profile's tabs: the window id its opener's page holds, else its screen's)
    const tabId = meta?.window ? meta.window : `fv_${chatDir(session)}${n ? `_${n}` : ""}`;
    const child = startLasting(config.host, ["--tab", "0", url], {
      cwd: dir,
      stdio: "ignore",
      env: {
        ...process.env,
        FV_STATE_DIR: dir,
        FV_PROFILE_DIR: this.#profileOf(session),
        FV_NEW_TABS: "1",
        FV_AGENT_PORT: "0",
        FV_FRAME_PORT: "0",
        FV_BIND: "127.0.0.1",
        FV_TAB_ID: tabId,
        ...(meta?.opener ? { FV_OPENER_ID: meta.opener, FV_OPENER_ORIGIN: meta.origin ?? "" } : {}),
      },
    });
    let ended: number | null | undefined;
    child.once("exit", (code) => (ended = code));
    child.once("error", () => (ended = -1));
    const pid = child.pid ?? null;
    // timer: a deadline for a process that tells nothing until it wrote its file.
    for (let waited = 0; ; waited += LOOK_MS) {
      if (ended !== undefined) throw new Error(`Farview's host ended as it started (exit ${ended}); its log: ${dir}`);
      if (waited >= START_MS) {
        if (pid !== null) await this.#end(pid);
        throw new Error(`Farview's host did not open its ports within ${START_MS / 1000} s`);
      }
      await wall.sleep(LOOK_MS);
      try {
        const file = hostFileOf(JSON.parse(await readFile(join(dir, "host.json"), "utf8")));
        if (file !== null && (pid === null || file.pid === pid)) {
          log.info("browser", "a chat's Farview tab started", { session, tab: n, pid: file.pid, agent: file.agent });
          return this.#up(session, n, dir, file, pid === null ? null : await startTimeOf(pid));
        }
      } catch {}
    }
  }

  /// A new tab of `session`'s chat on `url` (its agent's, or a page's that asked for one, `meta` linking it to the
  /// tab that did): the next number after every tab its directory holds.
  async open(session: string, url: string, meta?: OpenTabMeta): Promise<FarviewTab> {
    const before = this.#opening.get(session) ?? Promise.resolve();
    const made = before.catch(() => {}).then(async () => {
      let n = 1;
      try {
        for (const name of await readdir(join(this.#chatOf(session), "tabs"))) if (/^\d+$/.test(name)) n = Math.max(n, Number(name) + 1);
      } catch {}
      for (const k of this.#hosts.get(session)?.keys() ?? []) n = Math.max(n, k + 1);
      const host = await this.#start(session, n, url || FIRST_PAGE, meta);
      return this.#tabOf(session, host);
    });
    this.#opening.set(session, made);
    try {
      return await made;
    } finally {
      if (this.#opening.get(session) === made) this.#opening.delete(session);
    }
  }

  /// Closes tab `id` of `session`'s chat (not its first: `stop` closes the browser); its directory goes.
  async closeTab(session: string, id: string): Promise<void> {
    const host = this.#byId(session, id);
    if (host === undefined) throw new Error(`no such tab in this chat's browser: ${id}`);
    if (host.n === 0) throw new Error("the chat's first tab stays: `stop` closes the browser");
    this.#forget(session, host.n);
    await this.#end(host.pid);
    await rm(host.dir, { recursive: true, force: true });
  }

  #byId(session: string, id: string): Host | undefined {
    const want = id.replace(/^browser:/, "");
    for (const host of this.#hosts.get(session)?.values() ?? []) if (host.screen.id.replace(/^browser:/, "") === want) return host;
    return undefined;
  }

  async #end(pid: number) {
    if (groupAlive(pid)) await Effect.runPromise(endGroup(pid, END_MS).pipe(Effect.provideService(Clock.Clock, liveClock)));
  }

  #forget(session: string, n: number) {
    const tabs = this.#hosts.get(session);
    const host = tabs?.get(n);
    if (tabs === undefined || host === undefined) return;
    tabs.delete(n);
    if (tabs.size === 0) this.#hosts.delete(session);
    host.unscreen();
    host.screen.close();
  }

  /// Takes up the hosts an earlier station process left running, as this one starts: their tabs stay among the
  /// screens a person has open (an update restarted the station, and a person's view of a tab found it gone until its
  /// chat's agent asked for its browser again). Each chat's directory says whose it is and what its agent chose.
  async resume(): Promise<void> {
    if (this.active() === null) return;
    let dirs: string[];
    try {
      dirs = await readdir(this.#o.dir);
    } catch {
      return;
    }
    for (const name of dirs) {
      const chat = join(this.#o.dir, name);
      let session: string;
      try {
        session = (await readFile(join(chat, "session"), "utf8")).trim();
      } catch {
        continue;
      }
      if (session === "" || chatDir(session) !== name) continue;
      try {
        const engine = (await readFile(join(chat, "engine"), "utf8")).trim();
        if (engine === "farview" || engine === "chrome") this.#chosen.set(session, engine);
      } catch {}
      let tabs: string[] = [];
      try {
        tabs = (await readdir(join(chat, "tabs"))).filter((t) => /^\d+$/.test(t));
      } catch {}
      for (const t of tabs) {
        const n = Number(t);
        if (this.#hosts.get(session)?.has(n)) continue;
        // (a tab its page closed while no station process held it: closed now, never taken up again, its host ended
        // where it still runs and answers)
        if (n !== 0) {
          const dir = join(chat, "tabs", t);
          const file = await this.#fileOf(dir);
          if (file?.closed === true) {
            if ((await this.#alive(dir)) !== null) await this.#end(file.pid);
            await rm(dir, { recursive: true, force: true });
            log.info("browser", "a chat's Farview tab its page closed, closed", { session, tab: n, pid: file.pid });
            continue;
          }
        }
        const found = await this.#find(session, n, join(chat, "tabs", t)).catch(() => null);
        if (found !== null) log.info("browser", "a chat's Farview tab taken up", { session, tab: n, pid: found.pid });
      }
    }
  }

  /// `session`'s chat's first tab, started if it does not run.
  async endpoint(session: string): Promise<BrowserStatus> {
    await this.host(session);
    return this.status(session);
  }

  status(session: string): BrowserStatus {
    const tabs = [...(this.#hosts.get(session)?.values() ?? [])].filter((h) => groupAlive(h.pid));
    if (tabs.length === 0) return { running: false };
    return { running: true, binary: "Farview", headless: true, pid: tabs[0]!.pid, tabs: tabs.length, viewing: tabs.reduce((k, h) => k + h.screen.viewing(), 0) };
  }

  /// The port of the host whose tab is screen `id` that a person's client speaks Farview's protocol on (null: none
  /// runs): an app that draws the tab itself is carried to it (`{"farview": …}` streams, module.ts).
  clientPort(id: string): number | null {
    for (const tabs of this.#hosts.values()) for (const host of tabs.values()) if (host.screen.id === id && groupAlive(host.pid)) return host.port;
    return null;
  }

  /// The agent port of `session`'s chat's tab `id` (its first where none is said), for the agent's `agent.exe` (null:
  /// not running).
  agentPort(session: string, id?: string): number | null {
    const host = id === undefined || id === "" ? this.#hosts.get(session)?.get(0) : this.#byId(session, id);
    return host?.agent ?? null;
  }

  #tabOf(session: string, host: Host): FarviewTab {
    const page = host.screen.page();
    return { id: host.screen.id.replace(/^browser:/, ""), title: page.title, url: page.url, attached: false, session, agent: host.agent };
  }

  /// Its tabs that run, its first first, each by the id its screen goes by after `browser:` (as a Chrome tab's: a
  /// sign-in's card opens `browser:<tab>`).
  tabs(session: string): FarviewTab[] {
    return [...(this.#hosts.get(session)?.values() ?? [])].sort((a, b) => a.n - b.n).map((h) => this.#tabOf(session, h));
  }

  async #cookies(session: string, verb: "get" | "set" | "clear", arg: string): Promise<string> {
    const host = await this.host(session);
    const a = await askTab(host.agent, { kind: "cookies", verb, arg });
    if (a.kind !== "value") throw new Error("Farview's tab did not give its cookies");
    if (a.value.startsWith("error:")) throw new Error(`Farview: ${a.value}`);
    return a.value;
  }

  /// The cookies of the chat's profile, as its first tab has them (its host started if it is not running).
  async cookies(session: string): Promise<CookieParam[]> {
    let read: unknown = [];
    try {
      read = JSON.parse(await this.#cookies(session, "get", ""));
    } catch {}
    return allCookies(read);
  }

  /// `cookies` set in the chat's profile (a sign-in granted): every tab of it has them.
  async putCookies(session: string, cookies: CookieParam[]): Promise<void> {
    if (cookies.length > 0) await this.#cookies(session, "set", JSON.stringify(cookies));
  }

  /// The cookies and passkeys of `sites` taken out of the chat's profile where its first tab runs (a sign-in's grant
  /// ended): them, as they were.
  async takeOut(session: string, sites: string[]): Promise<{ cookies: CookieParam[]; passkeys: Passkey[] }> {
    if (!this.#hosts.get(session)?.has(0)) {
      const found = await this.#find(session, 0, this.#tabDir(session, 0));
      if (found === null) return { cookies: [], passkeys: [] };
    }
    const taken = (await this.cookies(session)).filter((c) => ofSites(c.domain, sites));
    // (Farview clears a host's cookies and its parent domains': each of theirs by its own, the site's among them)
    for (const domain of new Set(taken.map((c) => c.domain.replace(/^\./, "")))) await this.#cookies(session, "clear", domain);
    const passkeys = sitePasskeys(await this.passkeys(session), sites);
    // (a site's passkeys cleared by the site: its own relying party and those under it, as sitePasskeys has them)
    for (const site of sites) if (passkeys.some((p) => ofSites(p.rpId, [site]))) await this.#passkeys(session, "clear", site);
    return { cookies: taken, passkeys };
  }

  /// Whether the host of `host` has an authenticator of its own (a page of it sees PublicKeyCredential), asked once a
  /// host: one from before it had one would not read a passkeys ask.
  async #authenticator(host: Host): Promise<boolean> {
    if (host.authenticator === undefined) {
      let has = false;
      try {
        const a = await askTab(host.agent, { kind: "eval", script: "typeof PublicKeyCredential === 'function' && typeof navigator.credentials.get === 'function'" });
        has = a.kind === "value" && a.value === "true";
      } catch {}
      host.authenticator = has;
    }
    return host.authenticator;
  }

  /// The passkeys ask `verb` of the chat's first tab (its host started if it is not running); null where its host has
  /// no authenticator.
  async #passkeys(session: string, verb: "get" | "set" | "clear", arg: string): Promise<string | null> {
    const host = await this.host(session);
    if (!(await this.#authenticator(host))) return null;
    const a = await askTab(host.agent, { kind: "passkeys", verb, arg });
    if (a.kind !== "value") throw new Error("Farview's tab did not give its passkeys");
    if (a.value.startsWith("error:")) throw new Error(`Farview: ${a.value}`);
    return a.value;
  }

  /// The passkeys of the chat's profile, as its first tab has them (its host started if it is not running): none
  /// where its host has no authenticator or does not answer.
  async passkeys(session: string): Promise<Passkey[]> {
    let read: unknown = [];
    try {
      read = JSON.parse((await this.#passkeys(session, "get", "")) ?? "[]");
    } catch {}
    return Array.isArray(read) ? read.map(passkeyOf).filter((p): p is Passkey => p !== null) : [];
  }

  /// `passkeys` put into the chat's profile (a sign-in granted): every tab of it signs with them. Where its host has no
  /// authenticator they are not put in, and the log says so.
  async putPasskeys(session: string, passkeys: Passkey[]): Promise<void> {
    if (passkeys.length === 0) return;
    if ((await this.#passkeys(session, "set", JSON.stringify(passkeys))) === null) {
      log.warn("browser", "a sign-in's passkeys not put into a chat's Farview: its host has no authenticator", { session, passkeys: passkeys.length });
    }
  }

  /// The sign-in form of the chat's tab `id` (its first where none is said), filled from a card.
  async form(session: string, id?: string): Promise<FarviewForm> {
    const host = id === undefined ? undefined : this.#byId(session, id);
    return new FarviewForm((host ?? (await this.host(session))).agent);
  }

  /// Ends `session`'s chat's tabs; its profile and its first tab's address stay for when it asks again, the others go.
  async stop(session: string): Promise<void> {
    const tabs = [...(this.#hosts.get(session)?.values() ?? [])];
    for (const host of tabs) {
      this.#forget(session, host.n);
      await this.#end(host.pid);
      if (host.n !== 0) await rm(host.dir, { recursive: true, force: true });
    }
  }

  /// `session`'s chat was archived or deleted: its tabs end and its directory goes, its sign-ins with it.
  async closeOf(session: string): Promise<void> {
    const chat = this.#chatOf(session);
    const pids = new Set([...(this.#hosts.get(session)?.values() ?? [])].map((h) => h.pid));
    for (const n of [...(this.#hosts.get(session)?.keys() ?? [])]) this.#forget(session, n);
    // (and those no process of this station took up)
    let tabs: string[] = [];
    try {
      tabs = await readdir(join(chat, "tabs"));
    } catch {}
    for (const dir of [chat, ...tabs.map((t) => join(chat, "tabs", t))]) {
      const file = await this.#alive(dir);
      if (file !== null) pids.add(file.pid);
    }
    for (const pid of pids) await this.#end(pid);
    this.#chosen.delete(session);
    await rm(chat, { recursive: true, force: true });
  }

  /// This station process ends: the hosts go on for the next one to take up.
  close(): void {
    for (const [session, tabs] of [...this.#hosts]) for (const n of [...tabs.keys()]) this.#forget(session, n);
  }
}

/// What the `browser` tool tells an agent of its chat's Farview: its tabs, each with the port it is driven on.
export function farviewHowTo(config: FarviewConfig, tabs: FarviewTab[]): string {
  const first = tabs[0];
  const run = (port: number) => `${config.agent} 127.0.0.1 ${port}`;
  return [
    "This chat's browser runs: Farview (a browser whose pages run on this station and draw on people's devices).",
    `Its tabs (\`browser\` action tabs lists them again):`,
    ...tabs.map((t) => `- ${t.id}${t.title ? ` ${JSON.stringify(t.title)}` : ""} ${t.url || FIRST_PAGE} — agent port ${t.agent}`),
    `Drive a tab with: \`${run(first?.agent ?? 0)} <step>...\` (that tab's agent port) — each step prints what the page says after it (its address, title and an outline of its content).`,
    "Steps: `look`, `go:<address>`, `click:<selector>`, `fill:<selector>=<words>`, `submit:<selector>`, `key:<key>` or `key:<key>@<selector>`, `back`, `forward`, `reload`, `wait:<ms>`, `shot:<file.png>`, `eval:<js>` (its result as JSON).",
    "Files: `upload:<selector>=<file>[,<file>...]` gives a file input those files of this machine, as if a person chose them (the page sees them chosen: its input and change events, input.files, a form's upload). What a page downloads is saved, not shown, in its tab's own `downloads/` directory; the step `downloads` lists each file saved there, its name, size and path.",
    `For example: \`${run(first?.agent ?? 0)} go:https://example.com look\`.`,
    "More tabs: `browser` action open (with `url`) opens one and gives its port; action close (with `tab`) closes one. A page that opens a new window (a link to _blank, window.open) gets a tab of its own: action tabs shows it.",
    "There is no DevTools address: Playwright and chrome-devtools-mcp do not drive it.",
    "Its tabs share one profile: cookies, storage and passkeys are this chat's alone and stay until the chat is archived. A site's sign-in: `sign_in` puts one the vault keeps into it, or asks a person on a card, as with Chrome. A site's passkey sign-in (or its \"add a passkey\") is done by Farview's own authenticator with no prompt, as Chrome's is.",
    "A person can see and drive each tab from their app (the `screen` tool gives the link, by the tab's id); when they act on it, it is theirs: the agent is told \"the person took the tab back\" and waits until they say it is done.",
    "`browser` with engine chrome gives this chat Chrome instead (Farview's tabs end; its profile stays).",
  ].join("\n");
}
