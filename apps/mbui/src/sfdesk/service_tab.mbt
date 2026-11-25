// A web service an agent started, or a visualization it posted, in a tab of the chat's side panel on the desktop (still.fail
// web/src/pages/ChatPage.tsx's `service:<job>` and `file:[…]` tabs; Preview.tsx ServiceFrame, FileFrame, PreviewBar,
// Restart; Preview.css.ts): the bar over it (back, forward, reload; how far the page's resources came; where it is, its
// name then its path, typed to go elsewhere — a visualization's only its name), the page under it, what is said over it
// while its service starts again. A service stopped, or failed, is said in its place. What serves the page and what it
// keeps is sfbase's (service_page.mbt, viz_file.mbt); closing its tab lets it go.

///|
/// A tab's service, `service:<job>` (None: none).
pub fn tab_service(tab : String) -> String? {
  if tab.has_prefix("service:") {
    Some(tab.exact_view(start="service:".length()).to_owned())
  } else {
    None
  }
}

///|
/// A tab's visualization, `file:["<session>","<path>","<name>"]` (chat-tabs.ts): its session,
/// its path and its name (None: none, or one that does not read).
pub fn tab_file(tab : String) -> (String, String, String)? {
  if !tab.has_prefix("file:") {
    return None
  }
  match (try Some(@json.parse(tab.exact_view(start="file:".length()).to_owned())) catch { _ => None }) {
    Some(Array([String(session), String(path), String(name)])) if !@sfbase.is_mbui_viz(name) && !@sfbase.is_mbui_viz(path) =>
      Some((session, path, name))
    _ => None
  }
}

///|
/// The tab of a visualization `path` named `name` that session `session` sent.
pub fn file_tab(session : String, path : String, name : String) -> String {
  "file:" + Json::array([Json::string(session), Json::string(path), Json::string(name)]).stringify()
}

///|
/// A service's or a visualization's page key among the service pages (sfbase's service_page_for): as the phone's are.
fn tab_job(tab : String) -> String? {
  match (tab_service(tab), tab_file(tab)) {
    (Some(job), _) => Some(job)
    (_, Some((session, path, _))) => Some("file:" + session + "\n" + path)
    _ => None
  }
}

///|
/// Its tab closed: what its page asked of the station stopped, its view gone (web: closePreview), once it is no longer
/// drawn (the panel shows what it showed as it slides out: sfbase's service_page_held, service_left waiting for the
/// last node drawing it); opened again before, kept (tab_kept).
fn tab_let_go(src : Source, r : ChatRef, tab : String) -> Unit {
  // (in a window of its own: that window's now, let go of as it closes, tab_window_left)
  if @signals.untracked(fn() { @sfbase.window_has_tab(r.station, r.session, tab) }) {
    return
  }
  // (over the whole window: put away, as it is gone already, closed by what let it go)
  if @signals.untracked(fn() { @sfbase.tab_full_is(r.station, r.session, tab) }) {
    @sfbase.tab_full_beside()
  }
  panel_screen_pages.remove(tabs_key(r) + "/" + tab)
  panel_terminal_pages.remove(tabs_key(r) + "/" + tab)
  match station_tab(tab) {
    Some(("screen", station, screen)) => @sfpages.screen_left(src, station, screen)
    Some(("terminal", station, terminal)) => @sfpages.terminal_left(station, terminal)
    _ => ()
  }
  // (a file in the viewer: what it read)
  @sfbase.tab_viewer_let_go(tabs_key(r), tab)
  match tab_job(tab) {
    Some(job) => {
      service_left(src, r.station, job)
      jobs_handed.remove(service_key(r.station, job))
    }
    None => ()
  }
}

///|
fn tab_kept(r : ChatRef, tab : String) -> Unit {
  @sfbase.tab_viewer_kept(tabs_key(r), tab)
  match tab_job(tab) {
    Some(job) => @sfbase.service_left_called_off(r.station, job)
    None => ()
  }
}

///|
fn sv_reset() -> Unit {
  jobs_handed.clear()
  held_beside.clear()
  held_full.clear()
  held_window.clear()
  tab_window_srcs.clear()
}

///|
/// The jobs a press opened a service's tab on (the 任务 tab's row: jobs_tab_node), as the chat's jobs said each then,
/// by station and job (service_key): what its tab and its page show till the core says the job itself (job_now).
// kept across runs: put back by sv_reset (reset), each let go as its tab is (tab_let_go)
let jobs_handed : Map[String, Json] = Map([])

///|
/// Job `job` of `station` as the press that opens its service's tab has it (the chat's jobs' row): its tab opens on
/// it, named and showing its page, never on 服务 and 正在连接 while the core is asked the job (main's switches sweep,
/// 2026-11-16: the tab named 服务, then the job's name and its page 800 ms later).
fn job_handed(station : String, job : String, row : Json?) -> Unit {
  match row {
    Some(Object(_) as j) => jobs_handed[service_key(station, job)] = j
    _ => ()
  }
}

///|
/// Job `job` of `station`: as the core says it (the `job` topic, read), else as the press that opened its tab had it
/// (job_handed), and the core's error where it found none.
fn job_now(src : Source, station : String, job : String) -> (Json?, Json?) {
  let found = src.topic("job", { "station": Json::string(station), "id": Json::string(job) }).get().snapshot()
  match (found.value, found.error) {
    (None, None) | (Some(Null), None) => (jobs_handed.get(service_key(station, job)), None)
    (v, e) => (v, e)
  }
}

///|
/// The service `job` of chat `r`'s station beside the chat, in node `q` (its tab, as large as the panel under its bar;
/// service_pane's): the page while it is up (and as it starts again), what stopped it said otherwise, that it is not
/// found, or that the station is asked. `close`: what closes the panel it is alone in (its bar the panel's, its
/// corners `round`); `full`: what puts it over the whole window (its bar's 全屏).
fn service_tab_node(
  q : @view.View,
  src : Source,
  r : ChatRef,
  job : String,
  close : (() -> Unit)?,
  full : (() -> Unit)?,
  round : FixedArray[@ui.CornerOf]?,
  tips : @sf.TipLayer,
  beside? : (() -> Unit)? = None,
  bar? : ((@view.View) -> Unit)? = None,
) -> Unit {
  let now = fn() { job_now(src, r.station, job) }
  // (a window of its own's bar over what is said while the page is not up: `bar`; up, its page's own bar the window's,
  // its 移到侧边 `beside`)
  let barred = fn(b : @view.View) {
    match bar {
      Some(make) => make(b)
      None => ()
    }
  }
  let name = fn() {
    match text(now().0, "name") {
      "" => svc("android-chat.preview.service")
      n => n
    }
  }
  // what it shows: 0 asked, 1 not found, 2 up, 3 stopped or failed
  let state = fn() {
    let (j, error) = now()
    let port = number(j, "port").to_int()
    let st = text(j, "state")
    match j {
      None | Some(Null) => if error is Some(_) { 1 } else { 0 }
      _ if port > 0 && flag(j, "open") && (st == "running" || st == "exited") => 2
      _ => 3
    }
  }
  q.pick(at_once=true, state, fn(b, what) {
    b.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
    match what {
      0 => {
        sv_wait_node(b, fn() { @sf.t("common.connecting") })
        barred(b)
      }
      1 => {
        sv_said_node(b, fn() { svc("android-chat.preview.notFound", args=[("error", text(now().1, "message"))]) })
        barred(b)
      }
      2 => {
        @sfpages.service_view_node(
          b,
          src,
          r.station,
          job,
          fn() {
            let j = now().0
            {
              port: number(j, "port").to_int(),
              name: name(),
              restarting: text(j, "state") == "exited",
              restarts: number(j, "restarts").to_int(),
              session: text(j, "session"),
            }
          },
          fn() { b.window_w() },
          close~,
          full~,
          round~,
          tips~,
          beside~,
        )
      }
      _ => {
        sv_said_node(b, fn() {
          @sf.t(if text(now().0, "state") == "failed" { "web-pages.chat.serviceFailed" } else { "web-pages.chat.serviceStopped" }, args=[
            ("name", name()),
          ])
        })
        barred(b)
      }
    }
  })
}

///|
/// The visualization `path` named `name` of session `session` on chat `r`'s station beside the chat, in node `q` (its
/// tab; file_pane's, FileFrame): the file in the web's stylesheet with what its widget kept; nowhere else to go, its bar
/// names it; its 全屏 `full`.
fn file_tab_node(
  q : @view.View,
  src : Source,
  r : ChatRef,
  session : String,
  path : String,
  name : String,
  full : (() -> Unit)?,
  tips : @sf.TipLayer,
  beside? : (() -> Unit)? = None,
  bar? : ((@view.View) -> Unit)? = None,
) -> Unit {
  @sfpages.file_view_node(q, src, r.station, session, path, name, None, full~, tips~, beside~, bar~)
}

///|
/// What is said in the page's place in `parent` (sv_said's, Empty, previewMissing): in the middle, muted.
fn sv_said_node(parent : @view.View, words : () -> String) -> Unit {
  @sf.empty_node(parent, fn(b) { @sf.words_node(b, words, fn() { sv_said_words }) |> ignore })
}

///|
/// What it waits on in the page's place in `parent`: in the middle.
fn sv_wait_node(parent : @view.View, words : () -> String) -> Unit {
  parent.box(fn(b) {
    @sf.style_node(b, fn() { sv_wait })
    @sf.wait_line_node(b, words) |> ignore
  })
  |> ignore
}

///|
/// A web service asked as a page whose job the station does not find, in node `v` (the pane's or the tape's page):
/// said so, in its middle (one found is never on top here: beside_follow puts its chat in its place, with it beside it);
/// till the station says, nothing.
fn service_beside_node(v : @view.View, src : Source, station : String, job : String) -> Unit {
  let src = src.owned_by(v)
  let found = fn() { src.topic("job", { "station": Json::string(station), "id": Json::string(job) }).get().snapshot() }
  v.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
  v.show(at_once=true, fn() {
    let f = found()
    text(f.value, "session") == "" && f.error is Some(_)
  }, fn(b) {
    b.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
    sv_said_node(b, fn() { svc("android-chat.preview.notFound", args=[("error", text(found().error, "message"))]) })
  })
}

///|
/// A chat's detail asked as a page (laid_beside: an agent's history, a web service, a visualization), on top of the
/// stack in the wide frame, in node `v` (the frame's, made as the window comes to be 中屏 or 大屏): its chat put in its
/// place with it beside it, in front, at the change that put it on top (opened, pushed, come back to, or on top as the
/// frame is made), before any frame builds it. So such a page is never built as a chat's page here. A service waits for
/// the station to say whose chat runs it (its job's session), the page as it is till then; one not found stays, said
/// so (service_beside_node). Its chat's tabs as they are then are read with it (side_change_from): held while it is on top,
/// let go as it goes, never by the frame's node for as long as that lives.
fn beside_follow(v : @view.View, src : Source) -> Unit {
  let src = src.owned_by(v)
  let tabs_of = fn(station : String, session : String) { side_now(src, { station, session, title: "", station_name: "" }) }
  v.reacts(
    fn() {
      match app.nav.top() {
        Service(station, job) as p => {
          let session = text(src.topic("job", { "station": Json::string(station), "id": Json::string(job) }).get().value, "session")
          Some((p, session, if session == "" { ([], "") } else { tabs_of(station, session) }))
        }
        History(r, _, _) as p => Some((p, "", side_now(src, r)))
        PreviewFile(station, key, _, _) as p => Some((p, "", tabs_of(station, key)))
        _ => None
      }
    },
    fn(top) {
      match top {
        Some((History(r, key, entry), _, now)) => {
          app.nav.replace(Chat(r))
          match entry {
            Some(e) => @sfpages.history_focus(r.station, key, e)
            None => ()
          }
          side_change_from(src, r, "open", Some(key), now)
        }
        Some((Service(station, job) as p, session, now)) if session != "" =>
          tab_beside(src, station, session, "service:" + job, now, full=@sfbase.page_full_taken(p))
        Some((PreviewFile(station, key, path, name) as p, _, now)) => {
          let tab = if @sfbase.is_mbui_viz(name) || @sfbase.is_mbui_viz(path) {
            let a : @sfbase.Attachment = {
              name: if name != "" { name } else { @sfbase.viz_base_name(path) },
              path,
              size: 0.0,
              width: 0.0,
              height: 0.0,
              thumbhash: "",
              owner: "",
              upload: "",
              duration: 0.0,
              frames: 0,
              held: false,
            }
            @sfbase.view_tab_key(station, key, a, None, false)
          } else {
            file_tab(key, path, name)
          }
          tab_beside(src, station, key, tab, now, full=@sfbase.page_full_taken(p))
        }
        _ => ()
      }
    },
  )
}

///|
/// Tab `tab` opened in front beside chat `session` on `station` (its tabs as they are `now`), the page the chat's in
/// place of the one on top that asked: the chat under it where it was asked from there (as it mostly is: a chat's link,
/// its jobs), else that chat; over the whole window where `full` asks it (sfbase's tab_full.mbt).
fn tab_beside(
  src : Source,
  station : String,
  session : String,
  tab : String,
  now : (Array[String], String),
  full~ : Bool,
) -> Unit {
  let (r, under) = match app.nav.pages() {
    [.., Chat(u), _] if u.station == station && u.session == session => (u, true)
    _ => ({ station, session, title: "", station_name: "" }, false)
  }
  if under {
    app.nav.pop() |> ignore
  } else {
    app.nav.replace(Chat(r))
  }
  // (in a window of its own: that window to the front instead, sfbase's tab_window_front)
  if @sfbase.tab_window_front(r, tab) is Some(_) {
    return
  }
  // (over the whole window and not in the panel yet: put there under it, only to go there, lone)
  if full && !now.0.contains(tab) {
    side_under(src, r, "open", tab)
    @sfbase.tab_full_open(r, tab, lone=true)
    return
  }
  side_change_from(src, r, "open", Some(tab), now)
  if full {
    @sfbase.tab_full_open(r, tab)
  }
}

///|
// kept across runs: a value (no field of it changes)
let sv_wait : @ui.Style = @ui.css("w=Full h=Full align=ACenter justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let sv_said_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, center=true)
