// Farview (AFK-surf/farview-legacy, a browser whose pages run on a host and draw on the person's device) as a chat's browser,
// in place of its Chrome context (src/browser/farview.ts): config.json `browser: { farview?: "<the unpacked release>" |
// false, engine?: "chrome" | "farview", sessions?: [<session>...] }`. With no `farview`, a station on a system Farview
// is released for has it all the same: the release its version names, downloaded and unpacked the first time a chat's
// Farview starts (farview_release.mbt); `farview: false` is none. Released to chats one at a time (the lead,
// 2026-11-16): `engine: "farview"` makes it every chat's; else Chrome stays the chats' browser but for the sessions
// listed and those whose agent chose Farview (kept in the chat's directory).
//
// A chat's Farview is a tab or several, each a host process (`host.exe --tab`) that lasts with nobody connected, in a
// directory of its own (<data>/browser/farview/<chat>/tabs/<n>), all of them one profile (<chat>/profile), gone with
// the chat. A host listens on 127.0.0.1 only: its agent port and its frame port (farview_screen.mbt). It is started as a
// job is, in a group of its own, and outlives a station process: the next one takes it up by the `host.json` it wrote.
// Sign-ins go into the tab as they go into a chat's Chrome context: cookies set in the host's jar, taken out again as
// the grant ends; a card's sign-in fills the tab's form (farview_form.mbt). A sign-in's passkeys go into the profile's
// own authenticator (the host's passkeys.json) and come out with its cookies; a host from before it had one (no
// PublicKeyCredential in its pages) is asked none of them.

///|
/// Where Farview is and whose browser it is, as the config says it; `release`: the release `dir` is to be unpacked
/// from where it is not there yet (target, release).
pub(all) struct FarviewConfig {
  dir : String
  host : String
  agent : String
  engine : String
  sessions : Array[String]
  release : (String, FarviewRelease)?
}

///|
pub fn FarviewConfig::to_j(self : FarviewConfig) -> J {
  let fs : Array[(String, J)] = [
    ("dir", js(self.dir)),
    ("host", js(self.host)),
    ("agent", js(self.agent)),
    ("engine", js(self.engine)),
    ("sessions", jsa(self.sessions)),
  ]
  match self.release {
    Some((t, r)) => fs.push(("release", jo([("target", js(t)), ("rev", js(r.rev)), ("sha256", js(r.sha256))])))
    None => ()
  }
  jo(fs)
}

///|
/// The config's Farview: the directory `browser.farview` names; else, unless it says `false`, the release for
/// `target` (this system) in `releases`, kept in the machine's cache of native parts (`native_cache`).
pub fn farview_config(
  raw : J?,
  target : String,
  releases : Array[(String, FarviewRelease)],
  native_cache : String,
) -> FarviewConfig? {
  let b = match at(raw, "browser") {
    Some(Obj(_) | Arr(_) as x) => Some(x)
    _ => None
  }
  if at(b, "farview") is Some(Bool(false)) {
    return None
  }
  let sessions = match at(b, "sessions") {
    Some(Arr(xs)) => xs.filter_map(s => match s {
      Str(u) if u.length() > 0 => Some(@jsjson.sanitize_str(u))
      _ => None
    })
    _ => []
  }
  let engine = if is_str(at(b, "engine"), "farview") { "farview" } else { "chrome" }
  let at_dir = (dir : String) => {
    dir,
    host: pjoin([dir, "bin", "host.exe"]),
    agent: pjoin([dir, "bin", "agent.exe"]),
    engine,
    sessions,
    release: None,
  }
  match at(b, "farview") {
    Some(Str(u)) if u.length() > 0 => return Some(at_dir(@jsjson.sanitize_str(u)))
    _ => ()
  }
  match releases.search_by(r => r.0 == target) {
    Some(i) => {
      let release = releases[i].1
      Some({ ..at_dir(farview_cache_dir(native_cache, target, release)), release: Some((target, release)) })
    }
    None => None
  }
}

///|
/// Whether `session`'s chat has Farview for its browser: what its agent chose where it chose, else every chat's where
/// the config says so, else the sessions it lists.
pub fn farview_for(config : FarviewConfig?, session : String, chosen : String?) -> Bool {
  guard config is Some(c) else { return false }
  match chosen {
    Some(e) => e == "farview"
    None => c.engine == "farview" || c.sessions.contains(session)
  }
}

///|
/// No link to a tab that asked for this one.
let no_meta : OpenTabMeta = { window: "", opener: "", origin: "" }

///|
/// What a host writes into its state directory once it listens: its process and its ports; `closed` once its page
/// closed its tab.
pub(all) struct HostFile {
  pid : Int
  port : Int
  agent : Int
  frame : Int
  closed : Bool
}

///|
pub fn HostFile::to_j(self : HostFile) -> J {
  jo(
    [("pid", ji(self.pid)), ("port", ji(self.port)), ("agent", ji(self.agent)), ("frame", ji(self.frame))] +
    (if self.closed { [("closed", jb(true))] } else { [] }),
  )
}

///|
pub fn host_file_of(v : J?) -> HostFile? {
  let port = (n : J?) => is_integer(n) && js_num(n) > 0.0 && js_num(n) < 65536.0
  guard v is Some(Obj(_) | Arr(_)) &&
    is_integer(at(v, "pid")) &&
    js_num(at(v, "pid")) > 0.0 &&
    port(at(v, "port")) &&
    port(at(v, "agent")) &&
    port(at(v, "frame")) else {
    return None
  }
  Some({
    pid: js_num(at(v, "pid")).to_int(),
    port: js_num(at(v, "port")).to_int(),
    agent: js_num(at(v, "agent")).to_int(),
    frame: js_num(at(v, "frame")).to_int(),
    closed: at(v, "closed") is Some(Bool(true)),
  })
}

///|
/// A chat's directory name: its session key is not one (`chat:c-…`, a Slack thread's address).
pub fn chat_dir(session : String) -> String {
  slice(@cloud_net.sha256_hex(session), 0, b=24)
}

///|
/// The page a new tab opens on.
pub let first_page : String = "about:blank"

///|
let host_start_ms : Double = 20_000.0

///|
let host_end_ms : Double = 5_000.0

///|
let host_look_ms : Double = 100.0

///|
priv struct Host {
  file : HostFile
  started : Double?
  dir : String
  n : Int
  screen : FarviewScreen
  unscreen : () -> Unit
  /// whether its host has an authenticator of its own (None: not asked yet)
  mut authenticator : Bool?
}

///|
/// A tab of a chat's Farview as the `browser` tool lists it: its id (as its screen's after `browser:`), and the port
/// its agent drives it on.
pub(all) struct FarviewTab {
  info : TabInfo
  agent : Int
}

///|
pub fn FarviewTab::to_j(self : FarviewTab) -> J {
  put(self.info.to_j(), "agent", ji(self.agent))
}

///|
pub(all) struct FarviewOptions {
  /// <data>/browser/farview: a directory a chat.
  dir : String
  config : () -> FarviewConfig?
  screens : Screens?
  /// How a release's tarball is downloaded, and from where.
  fetch : async (String) -> Bytes?
  sources : (String) -> Array[String]
  machine : Machine
  files : Files
  net : FarviewNet
  release_io : ReleaseIo
  log : Log
  /// The station's environment, which a host is started with besides its own.
  env : Array[(String, String)]
}

///|
pub struct FarviewTabs {
  priv o : FarviewOptions
  /// Each chat's tabs that run, by session and number.
  priv hosts : Map[String, Map[Int, Host]]
  /// Starts under way, by session and number: asked again meanwhile, the same one.
  priv starting : Map[String, Later[Host]]
  /// What each chat's agent chose (`engine` in its directory).
  priv chosen : Map[String, String]
  /// A chat's tabs opened one at a time (each takes the next number).
  priv opening : Map[String, Later[FarviewTab]]
  /// A release being unpacked, by where it goes.
  priv unpacking : Map[String, Later[Unit]]
}

///|
pub fn FarviewTabs::new(o : FarviewOptions) -> FarviewTabs {
  { o, hosts: {}, starting: {}, chosen: {}, opening: {}, unpacking: {} }
}

///|
/// Where Farview is, where the config names it (whoever's browser it is).
pub fn FarviewTabs::active(self : FarviewTabs) -> FarviewConfig? {
  (self.o.config)()
}

///|
/// Whether `session`'s chat has Farview for its browser (its tabs, sign-ins and form are here, not in Chrome).
pub fn FarviewTabs::active_for(self : FarviewTabs, session : String) -> Bool {
  farview_for(self.active(), session, self.chosen.get(session))
}

///|
fn FarviewTabs::chat_of(self : FarviewTabs, session : String) -> String {
  join(self.o.dir, chat_dir(session))
}

///|
fn FarviewTabs::tab_dir(self : FarviewTabs, session : String, n : Int) -> String {
  pjoin([self.chat_of(session), "tabs", n.to_string()])
}

///|
fn FarviewTabs::profile_of(self : FarviewTabs, session : String) -> String {
  join(self.chat_of(session), "profile")
}

///|
/// `session`'s agent chose `engine` for its chat's browser: kept in its directory, for this station process and the
/// next. Choosing Chrome ends its Farview tabs (their profile stays).
pub async fn FarviewTabs::choose(self : FarviewTabs, session : String, engine : String) -> Unit {
  guard self.active() is Some(config) else {
    raise fail_(
      "Farview is not on this station (config.json `browser.farview`, or no release for this system): this chat's browser is Chrome.",
    )
  }
  if engine == "farview" {
    self.ready(config)
  }
  let chat = self.chat_of(session)
  (self.o.files.mkdir)(chat, 0o700)
  (self.o.files.write)(join(chat, "session"), session, 0o600)
  (self.o.files.write)(join(chat, "engine"), engine, 0o600)
  self.chosen[session] = engine
  if !self.active_for(session) {
    self.stop(session)
  }
}

///|
/// Farview's release unpacked where `config` says, downloaded the first time (once, however many ask meanwhile; one
/// that failed is tried again the next time it is asked). A directory the config names is as it is.
pub async fn FarviewTabs::ready(self : FarviewTabs, config : FarviewConfig) -> Unit {
  guard config.release is Some((target, release)) else { return }
  let made = match self.unpacking.get(config.dir) {
    Some(m) => m
    None => {
      let name = farview_asset(target, release)
      let m = Later::start(self.o.net.clock, async fn() {
        let r = attempt(async fn() {
          unpack_release(
            config.dir,
            target,
            release,
            (self.o.sources)(name),
            self.o.fetch,
            self.o.files,
            self.o.release_io,
          )
        })
        match r {
          Ok(_) =>
            (self.o.log.info)(
              "browser",
              "Farview's release unpacked",
              fields([("dir", js(config.dir)), ("rev", js(release.rev))]),
            )
          Err(e) => {
            self.unpacking.remove(config.dir)
            raise e
          }
        }
      })
      self.unpacking[config.dir] = m
      m
    }
  }
  made.wait()
}

///|
fn FarviewTabs::tabs_of(self : FarviewTabs, session : String) -> Map[Int, Host] {
  match self.hosts.get(session) {
    Some(m) => m
    None => {
      let m = {}
      self.hosts[session] = m
      m
    }
  }
}

///|
/// The host `dir` says runs, if it is still that process and answers on its agent port.
async fn FarviewTabs::find(self : FarviewTabs, session : String, n : Int, dir : String) -> Host? {
  guard self.alive(dir) is Some(file) else { return None }
  Some(self.up(session, n, dir, file, (self.o.machine.start_time_of)(file.pid)))
}

///|
async fn FarviewTabs::file_of(self : FarviewTabs, dir : String) -> HostFile? {
  match (self.o.files.read)(join(dir, "host.json")) {
    Some(t) =>
      match (try Some(parse(t)) catch { _ => None }) {
        Some(v) => host_file_of(Some(v))
        None => None
      }
    None => None
  }
}

///|
async fn FarviewTabs::alive(self : FarviewTabs, dir : String) -> HostFile? {
  match self.file_of(dir) {
    Some(f) if (self.o.machine.group_alive)(f.pid) && (self.o.machine.answers)(f.agent) => Some(f)
    _ => None
  }
}

///|
fn FarviewTabs::up(
  self : FarviewTabs,
  session : String,
  n : Int,
  dir : String,
  file : HostFile,
  started : Double?,
) -> Host {
  let screen = FarviewScreen::new(session, file.frame, n, self.o.net, self.o.log)
  // (a page that asks for a new tab: opened beside it, one of the screens, linked to this one where it is a window
  // the page holds)
  screen.opened = (url, meta) => (self.o.net.clock.spawn)(async fn() {
    ignore(self.open(session, url, meta~)) catch {
      e =>
        (self.o.log.warn)(
          "browser",
          "a tab a page asked for could not be opened",
          fields([("session", js(session)), ("error", js(message_of(e)))]),
        )
    }
  })
  // (a page that closed its tab: closed here, back to the tab that opened it; never the chat's first)
  screen.closed_by_page = () => if n != 0 {
    (self.o.net.clock.spawn)(async fn() {
      self.close_tab(session, screen.id) catch {
        e =>
          (self.o.log.warn)(
            "browser",
            "a tab its page closed could not be closed",
            fields([("session", js(session)), ("error", js(message_of(e)))]),
          )
      }
    })
  }
  let unscreen = match self.o.screens {
    Some(s) => (s.add)(screen.source())
    None => () => ()
  }
  screen.watch()
  let host : Host = { file, started, dir, n, screen, unscreen, authenticator: None }
  self.tabs_of(session)[n] = host
  host
}

///|
/// `session`'s chat's tab `n` (0: its first): the one that runs (this process's, or one an earlier station process
/// left), else started.
async fn FarviewTabs::host(self : FarviewTabs, session : String, n? : Int = 0) -> Host {
  match self.hosts.get(session) {
    Some(m) =>
      match m.get(n) {
        Some(had) => {
          if (self.o.machine.group_alive)(had.file.pid) {
            return had
          }
          self.forget(session, n)
        }
        None => ()
      }
    None => ()
  }
  let key = "\{n}\n\{session}"
  match self.starting.get(key) {
    Some(s) => return s.wait()
    None => ()
  }
  let made = Later::start(self.o.net.clock, async fn() {
    let r = attempt(async fn() { self.start(session, n, None, no_meta) })
    self.starting.remove(key)
    match r {
      Ok(h) => h
      Err(e) => raise e
    }
  })
  self.starting[key] = made
  made.wait()
}

///|
/// A chat's directory as a station from before kept it (one tab, its profile and address beside its host.json): its
/// host ended, its profile and address moved where they go now.
async fn FarviewTabs::move_old(self : FarviewTabs, session : String) -> Unit {
  let chat = self.chat_of(session)
  match self.alive(chat) {
    Some(old) => self.end(old.pid)
    None => ()
  }
  (self.o.files.rm)(join(chat, "host.json"), false)
  let profile = self.profile_of(session)
  let tab = self.tab_dir(session, 0)
  for pair in [("cookies.txt", profile), ("storage.json", profile), ("url", tab)] {
    let (name, to) = pair
    if !(self.o.files.exists)(join(chat, name)) {
      continue
    }
    (self.o.files.mkdir)(to, 0o700)
    (self.o.files.rename)(join(chat, name), join(to, name))
  }
}

///|
async fn FarviewTabs::start(
  self : FarviewTabs,
  session : String,
  n : Int,
  url0 : String?,
  meta : OpenTabMeta,
) -> Host {
  guard self.active() is Some(config) else {
    raise fail_("Farview is not this station's browser (config.json `browser`).")
  }
  self.ready(config)
  if !(self.o.files.exists)(config.host) {
    raise fail_(
      "Farview's host is not at \{config.host}: unpack its release there, or say `browser.farview: false` in config.json for Chrome.",
    )
  }
  let dir = self.tab_dir(session, n)
  match self.find(session, n, dir) {
    Some(found) => return found
    None => ()
  }
  let chat = self.chat_of(session)
  if n == 0 {
    self.move_old(session)
  }
  (self.o.files.mkdir)(dir, 0o700)
  (self.o.files.mkdir)(self.profile_of(session), 0o700)
  (self.o.files.rm)(join(dir, "host.json"), false)
  // (whose chat it is, for the next station process to take its hosts up as it starts: `resume`)
  (self.o.files.write)(join(chat, "session"), session, 0o600)
  let url = match url0 {
    Some(u) => u
    None =>
      match (self.o.files.read)(join(dir, "url")) {
        Some(t) => {
          let u = trim(t)
          if u == "" {
            first_page
          } else {
            u
          }
        }
        None => first_page
      }
  }
  // (its id among the profile's tabs: the window id its opener's page holds, else its screen's)
  let tab_id = if meta.window != "" {
    meta.window
  } else {
    "fv_\{chat_dir(session)}" + (if n != 0 { "_\{n}" } else { "" })
  }
  let child = (self.o.machine.start_lasting)(
    config.host,
    ["--tab", "0", url],
    dir,
    self.o.env +
    [
      ("FV_STATE_DIR", dir),
      ("FV_PROFILE_DIR", self.profile_of(session)),
      ("FV_NEW_TABS", "1"),
      ("FV_AGENT_PORT", "0"),
      ("FV_FRAME_PORT", "0"),
      ("FV_BIND", "127.0.0.1"),
      ("FV_TAB_ID", tab_id),
    ] +
    (if meta.opener != "" { [("FV_OPENER_ID", meta.opener), ("FV_OPENER_ORIGIN", meta.origin)] } else { [] }),
  )
  let pid = child.pid
  // timer: a deadline for a process that tells nothing until it wrote its file.
  let mut waited = 0.0
  while true {
    match (child.ended)() {
      Some(code) => raise fail_("Farview's host ended as it started (exit \{code}); its log: \{dir}")
      None => ()
    }
    if waited >= host_start_ms {
      match pid {
        Some(p) => self.end(p)
        None => ()
      }
      raise fail_("Farview's host did not open its ports within \{dnum(host_start_ms / 1000.0)} s")
    }
    (self.o.machine.sleep)(host_look_ms)
    match (self.o.files.read)(join(dir, "host.json")) {
      Some(t) =>
        match (try Some(parse(t)) catch { _ => None }) {
          Some(v) =>
            match host_file_of(Some(v)) {
              Some(file) if pid is None || pid == Some(file.pid) => {
                (self.o.log.info)(
                  "browser",
                  "a chat's Farview tab started",
                  fields([
                    ("session", js(session)),
                    ("tab", ji(n)),
                    ("pid", ji(file.pid)),
                    ("agent", ji(file.agent)),
                  ]),
                )
                let started = match pid {
                  Some(p) => (self.o.machine.start_time_of)(p)
                  None => None
                }
                return self.up(session, n, dir, file, started)
              }
              _ => ()
            }
          None => ()
        }
      None => ()
    }
    waited += host_look_ms
  }
  raise fail_("unreachable")
}

///|
/// A new tab of `session`'s chat on `url` (its agent's, or a page's that asked for one, `meta` linking it to the tab
/// that did): the next number after every tab its directory holds.
pub async fn FarviewTabs::open(
  self : FarviewTabs,
  session : String,
  url : String,
  meta? : OpenTabMeta = no_meta,
) -> FarviewTab {
  let before = self.opening.get(session)
  let me : Ref[Later[FarviewTab]?] = Ref(None)
  let made = Later::start(self.o.net.clock, async fn() {
    match before {
      Some(b) => ignore(b.wait()) catch { _ => () }
      None => ()
    }
    let mut n = 1
    match attempt(async fn() { (self.o.files.readdir)(join(self.chat_of(session), "tabs")) }) {
      Ok(names) =>
        for name in names {
          if all_digits(name) {
            let k = js_num(Some(js(name))).to_int() + 1
            if k > n {
              n = k
            }
          }
        }
      Err(_) => ()
    }
    match self.hosts.get(session) {
      Some(m) =>
        for k, _ in m {
          if k + 1 > n {
            n = k + 1
          }
        }
      None => ()
    }
    let host = self.start(session, n, Some(if url == "" { first_page } else { url }), meta)
    self.tab_of(session, host)
  })
  me.val = Some(made)
  self.opening[session] = made
  let r = attempt(async fn() { made.wait() })
  match self.opening.get(session) {
    Some(o) if o.same(made) => self.opening.remove(session)
    _ => ()
  }
  match r {
    Ok(t) => t
    Err(e) => raise e
  }
}

///|
/// Closes tab `id` of `session`'s chat (not its first: `stop` closes the browser); its directory goes.
pub async fn FarviewTabs::close_tab(self : FarviewTabs, session : String, id : String) -> Unit {
  guard self.by_id(session, id) is Some(host) else {
    raise fail_("no such tab in this chat's browser: \{id}")
  }
  if host.n == 0 {
    raise fail_("the chat's first tab stays: `stop` closes the browser")
  }
  self.forget(session, host.n)
  self.end(host.file.pid)
  (self.o.files.rm)(host.dir, true)
}

///|
fn strip_browser(id : String) -> String {
  if id.has_prefix("browser:") {
    slice(id, 8)
  } else {
    id
  }
}

///|
fn FarviewTabs::by_id(self : FarviewTabs, session : String, id : String) -> Host? {
  let want = strip_browser(id)
  match self.hosts.get(session) {
    Some(m) => {
      for _, host in m {
        if strip_browser(host.screen.id) == want {
          return Some(host)
        }
      }
      None
    }
    None => None
  }
}

///|
async fn FarviewTabs::end(self : FarviewTabs, pid : Int) -> Unit {
  if (self.o.machine.group_alive)(pid) {
    (self.o.machine.end_group)(pid, host_end_ms)
  }
}

///|
fn FarviewTabs::forget(self : FarviewTabs, session : String, n : Int) -> Unit {
  guard self.hosts.get(session) is Some(tabs) && tabs.get(n) is Some(host) else { return }
  tabs.remove(n)
  if tabs.length() == 0 {
    self.hosts.remove(session)
  }
  (host.unscreen)()
  host.screen.close()
}

///|
/// Takes up the hosts an earlier station process left running, as this one starts: their tabs stay among the screens a
/// person has open. Each chat's directory says whose it is and what its agent chose.
pub async fn FarviewTabs::resume(self : FarviewTabs) -> Unit {
  if self.active() is None {
    return
  }
  let dirs = (self.o.files.readdir)(self.o.dir) catch { _ => return }
  for name in dirs {
    let chat = join(self.o.dir, name)
    guard (self.o.files.read)(join(chat, "session")) is Some(s) else { continue }
    let session = trim(s)
    if session == "" || chat_dir(session) != name {
      continue
    }
    match (self.o.files.read)(join(chat, "engine")) {
      Some(e) => {
        let engine = trim(e)
        if engine == "farview" || engine == "chrome" {
          self.chosen[session] = engine
        }
      }
      None => ()
    }
    let tabs = match attempt(async fn() { (self.o.files.readdir)(join(chat, "tabs")) }) {
      Ok(ts) => ts.filter(t => all_digits(t))
      Err(_) => []
    }
    for t in tabs {
      let n = js_num(Some(js(t))).to_int()
      match self.hosts.get(session) {
        Some(m) => if m.contains(n) { continue }
        None => ()
      }
      // (a tab its page closed while no station process held it: closed now, never taken up again, its host ended
      // where it still runs and answers)
      let tab_dir = pjoin([chat, "tabs", t])
      if n != 0 && self.file_of(tab_dir) is Some(file) && file.closed {
        if self.alive(tab_dir) is Some(_) {
          self.end(file.pid)
        }
        (self.o.files.rm)(tab_dir, true)
        (self.o.log.info)(
          "browser",
          "a chat's Farview tab its page closed, closed",
          fields([("session", js(session)), ("tab", ji(n)), ("pid", ji(file.pid))]),
        )
        continue
      }
      let found = self.find(session, n, pjoin([chat, "tabs", t])) catch { _ => None }
      match found {
        Some(f) =>
          (self.o.log.info)(
            "browser",
            "a chat's Farview tab taken up",
            fields([("session", js(session)), ("tab", ji(n)), ("pid", ji(f.file.pid))]),
          )
        None => ()
      }
    }
  }
}

///|
/// `session`'s chat's first tab, started if it does not run.
pub async fn FarviewTabs::endpoint(self : FarviewTabs, session : String) -> BrowserStatus {
  ignore(self.host(session))
  self.status(session)
}

///|
fn FarviewTabs::hosts_of(self : FarviewTabs, session : String) -> Array[Host] {
  let out = []
  match self.hosts.get(session) {
    Some(m) => for _, h in m {
      out.push(h)
    }
    None => ()
  }
  out
}

///|
pub fn FarviewTabs::status(self : FarviewTabs, session : String) -> BrowserStatus {
  let tabs = self.hosts_of(session).filter(h => (self.o.machine.group_alive)(h.file.pid))
  if tabs.length() == 0 {
    return BrowserStatus::off()
  }
  let mut viewing = 0
  for h in tabs {
    viewing += h.screen.viewing()
  }
  {
    running: true,
    http: None,
    ws: None,
    binary: Some("Farview"),
    headless: Some(true),
    pid: Some(Some(tabs[0].file.pid)),
    tabs: Some(tabs.length()),
    viewing: Some(viewing),
    last_use: None,
  }
}

///|
/// The port of the host whose tab is screen `id` that a person's client speaks Farview's protocol on (None: none
/// runs): an app that draws the tab itself is carried to it (`{"farview": …}` streams, module.mbt).
pub fn FarviewTabs::client_port(self : FarviewTabs, id : String) -> Int? {
  for _, tabs in self.hosts {
    for _, host in tabs {
      if host.screen.id == id && (self.o.machine.group_alive)(host.file.pid) {
        return Some(host.file.port)
      }
    }
  }
  None
}

///|
/// The agent port of `session`'s chat's tab `id` (its first where none is said), for the agent's `agent.exe`.
pub fn FarviewTabs::agent_port(self : FarviewTabs, session : String, id? : String) -> Int? {
  let host = match id {
    None | Some("") => self.hosts.get(session).bind(m => m.get(0))
    Some(i) => self.by_id(session, i)
  }
  host.map(h => h.file.agent)
}

///|
fn FarviewTabs::tab_of(_self : FarviewTabs, session : String, host : Host) -> FarviewTab {
  let page = host.screen.page()
  {
    info: {
      id: strip_browser(host.screen.id),
      title: page.title,
      url: page.url,
      attached: false,
      session: Some(session),
    },
    agent: host.file.agent,
  }
}

///|
/// Its tabs that run, its first first, each by the id its screen goes by after `browser:`.
pub fn FarviewTabs::tabs(self : FarviewTabs, session : String) -> Array[FarviewTab] {
  let hs = self.hosts_of(session)
  hs.sort_by((a, b) => a.n.compare(b.n))
  hs.map(h => self.tab_of(session, h))
}

///|
async fn FarviewTabs::cookies_ask(self : FarviewTabs, session : String, verb : String, arg : String) -> String {
  let host = self.host(session)
  match ask_tab(self.o.net, host.file.agent, Cookies(verb, arg)) {
    Value(v) => {
      if v.has_prefix("error:") {
        raise fail_("Farview: \{v}")
      }
      v
    }
    _ => raise fail_("Farview's tab did not give its cookies")
  }
}

///|
/// The cookies of the chat's profile, as its first tab has them (its host started if it is not running).
pub async fn FarviewTabs::cookies(self : FarviewTabs, session : String) -> Array[J] {
  let read = match attempt(async fn() { parse(self.cookies_ask(session, "get", "")) }) {
    Ok(v) => v
    Err(_) => ja([])
  }
  all_cookies(Some(read))
}

///|
/// `cookies` set in the chat's profile (a sign-in granted): every tab of it has them.
pub async fn FarviewTabs::put_cookies(self : FarviewTabs, session : String, cookies : Array[J]) -> Unit {
  if cookies.length() > 0 {
    ignore(self.cookies_ask(session, "set", stringify(ja(cookies))))
  }
}

///|
/// Whether the host of `host` has an authenticator of its own (a page of it sees PublicKeyCredential), asked once a
/// host: one from before it had one would not read a passkeys ask.
async fn FarviewTabs::authenticator(self : FarviewTabs, host : Host) -> Bool {
  match host.authenticator {
    Some(b) => b
    None => {
      let has = match
        attempt(async fn() {
          ask_tab(
            self.o.net,
            host.file.agent,
            Eval("typeof PublicKeyCredential === 'function' && typeof navigator.credentials.get === 'function'"),
          )
        }) {
        Ok(Value(v)) => v == "true"
        _ => false
      }
      host.authenticator = Some(has)
      has
    }
  }
}

///|
/// The passkeys ask `verb` of the chat's first tab (its host started if it is not running); None where its host has no
/// authenticator.
async fn FarviewTabs::passkeys_ask(self : FarviewTabs, session : String, verb : String, arg : String) -> String? {
  let host = self.host(session)
  if !self.authenticator(host) {
    return None
  }
  match ask_tab(self.o.net, host.file.agent, Passkeys(verb, arg)) {
    Value(v) => {
      if v.has_prefix("error:") {
        raise fail_("Farview: \{v}")
      }
      Some(v)
    }
    _ => raise fail_("Farview's tab did not give its passkeys")
  }
}

///|
/// The passkeys of the chat's profile, as its first tab has them (its host started if it is not running): none where
/// its host has no authenticator or does not answer.
pub async fn FarviewTabs::passkeys(self : FarviewTabs, session : String) -> Array[Passkey] {
  let read = match attempt(async fn() { parse(self.passkeys_ask(session, "get", "").unwrap_or("[]")) }) {
    Ok(v) => v
    Err(_) => ja([])
  }
  match read {
    Arr(list) => list.filter_map(p => passkey_of(Some(p)))
    _ => []
  }
}

///|
/// `passkeys` put into the chat's profile (a sign-in granted): every tab of it signs with them. Where its host has no
/// authenticator they are not put in, and the log says so.
pub async fn FarviewTabs::put_passkeys(self : FarviewTabs, session : String, passkeys : Array[Passkey]) -> Unit {
  if passkeys.length() == 0 {
    return
  }
  if self.passkeys_ask(session, "set", stringify(ja(passkeys.map(p => p.to_j())))) is None {
    (self.o.log.warn)(
      "browser",
      "a sign-in's passkeys not put into a chat's Farview: its host has no authenticator",
      fields([("session", js(session)), ("passkeys", ji(passkeys.length()))]),
    )
  }
}

///|
/// The cookies and passkeys of `sites` taken out of the chat's profile where its first tab runs (a sign-in's grant
/// ended): them, as they were.
pub async fn FarviewTabs::take_out(
  self : FarviewTabs,
  session : String,
  sites : Array[String],
) -> (Array[J], Array[Passkey]) {
  let has_first = match self.hosts.get(session) {
    Some(m) => m.contains(0)
    None => false
  }
  if !has_first {
    match self.find(session, 0, self.tab_dir(session, 0)) {
      Some(_) => ()
      None => return ([], [])
    }
  }
  let taken = self.cookies(session).filter(c => of_sites(text(at(Some(c), "domain")), sites))
  // (Farview clears a host's cookies and its parent domains': each of theirs by its own, the site's among them)
  let domains = []
  for c in taken {
    let d = text(at(Some(c), "domain"))
    let d = if d.has_prefix(".") { slice(d, 1) } else { d }
    if !domains.contains(d) {
      domains.push(d)
    }
  }
  for d in domains {
    ignore(self.cookies_ask(session, "clear", d))
  }
  let passkeys = site_passkeys(self.passkeys(session), sites)
  // (a site's passkeys cleared by the site: its own relying party and those under it, as site_passkeys has them)
  for site in sites {
    if passkeys.iter().any(p => of_sites(p.rp_id, [site])) {
      ignore(self.passkeys_ask(session, "clear", site))
    }
  }
  (taken, passkeys)
}

///|
/// The sign-in form of the chat's tab `id` (its first where none is said), filled from a card.
pub async fn FarviewTabs::form(self : FarviewTabs, session : String, id? : String) -> SignInForm {
  let host = match id {
    Some(i) => self.by_id(session, i)
    None => None
  }
  let port = match host {
    Some(h) => h.file.agent
    None => self.host(session).file.agent
  }
  farview_form(self.o.net, port)
}

///|
/// Ends `session`'s chat's tabs; its profile and its first tab's address stay for when it asks again, the others go.
pub async fn FarviewTabs::stop(self : FarviewTabs, session : String) -> Unit {
  for host in self.hosts_of(session) {
    self.forget(session, host.n)
    self.end(host.file.pid)
    if host.n != 0 {
      (self.o.files.rm)(host.dir, true)
    }
  }
}

///|
/// `session`'s chat was archived or deleted: its tabs end and its directory goes, its sign-ins with it.
pub async fn FarviewTabs::close_of(self : FarviewTabs, session : String) -> Unit {
  let chat = self.chat_of(session)
  let pids : Array[Int] = []
  for h in self.hosts_of(session) {
    if !pids.contains(h.file.pid) {
      pids.push(h.file.pid)
    }
  }
  let ns = []
  match self.hosts.get(session) {
    Some(m) => for n, _ in m {
      ns.push(n)
    }
    None => ()
  }
  for n in ns {
    self.forget(session, n)
  }
  // (and those no process of this station took up)
  let tabs = match attempt(async fn() { (self.o.files.readdir)(join(chat, "tabs")) }) {
    Ok(ts) => ts
    Err(_) => []
  }
  for dir in [chat] + tabs.map(t => pjoin([chat, "tabs", t])) {
    match self.alive(dir) {
      Some(f) => if !pids.contains(f.pid) { pids.push(f.pid) }
      None => ()
    }
  }
  for pid in pids {
    self.end(pid)
  }
  self.chosen.remove(session)
  (self.o.files.rm)(chat, true)
}

///|
/// This station process ends: the hosts go on for the next one to take up.
pub fn FarviewTabs::close(self : FarviewTabs) -> Unit {
  let all = []
  for session, tabs in self.hosts {
    for n, _ in tabs {
      all.push((session, n))
    }
  }
  for p in all {
    self.forget(p.0, p.1)
  }
}

///|
/// What the `browser` tool tells an agent of its chat's Farview: its tabs, each with the port it is driven on.
pub fn farview_how_to(config : FarviewConfig, tabs : Array[FarviewTab]) -> String {
  let first_port = if tabs.length() > 0 { tabs[0].agent } else { 0 }
  let run = (port : Int) => "\{config.agent} 127.0.0.1 \{port}"
  let lines = [
    "This chat's browser runs: Farview (a browser whose pages run on this station and draw on people's devices).", "Its tabs (`browser` action tabs lists them again):",
  ]
  for t in tabs {
    let title = if t.info.title != "" { " " + quote(t.info.title) } else { "" }
    let url = if t.info.url != "" { t.info.url } else { first_page }
    lines.push("- \{t.info.id}\{title} \{url} — agent port \{t.agent}")
  }
  lines.push(
    "Drive a tab with: `\{run(first_port)} <step>...` (that tab's agent port) — each step prints what the page says after it (its address, title and an outline of its content).",
  )
  lines.push(
    "Steps: `look`, `go:<address>`, `click:<selector>`, `fill:<selector>=<words>`, `submit:<selector>`, `key:<key>` or `key:<key>@<selector>`, `back`, `forward`, `reload`, `wait:<ms>`, `shot:<file.png>`, `eval:<js>` (its result as JSON).",
  )
  lines.push(
    "Files: `upload:<selector>=<file>[,<file>...]` gives a file input those files of this machine, as if a person chose them (the page sees them chosen: its input and change events, input.files, a form's upload). What a page downloads is saved, not shown, in its tab's own `downloads/` directory; the step `downloads` lists each file saved there, its name, size and path.",
  )
  lines.push("For example: `\{run(first_port)} go:https://example.com look`.")
  lines.push(
    "More tabs: `browser` action open (with `url`) opens one and gives its port; action close (with `tab`) closes one. A page that opens a new window (a link to _blank, window.open) gets a tab of its own: action tabs shows it.",
  )
  lines.push("There is no DevTools address: Playwright and chrome-devtools-mcp do not drive it.")
  lines.push(
    "Its tabs share one profile: cookies, storage and passkeys are this chat's alone and stay until the chat is archived. A site's sign-in: `sign_in` puts one the vault keeps into it, or asks a person on a card, as with Chrome. A site's passkey sign-in (or its \"add a passkey\") is done by Farview's own authenticator with no prompt, as Chrome's is.",
  )
  lines.push(
    "A person can see and drive each tab from their app (the `screen` tool gives the link, by the tab's id); when they act on it, it is theirs: the agent is told \"the person took the tab back\" and waits until they say it is done.",
  )
  lines.push("`browser` with engine chrome gives this chat Chrome instead (Farview's tabs end; its profile stays).")
  lines.join("\n")
}
