// First-class Remote place (`Place("remote")`), its list made as the chats' list is (sf's list_row_node, its headings and
// rows' slots, a chat's row's grounds and 归档 key): each online station under its heading, its ＋ at the heading's end
// (a new view on that station: a terminal, a tab of its browser), its displays and simulators (always there, one press
// opens them), its browser's tabs and the terminals open on it.
// - 小屏 (`remote_page_node`): the list across the whole screen under the place's glass top bar;
// - 中屏 / 大屏 (`remote_list_node` in sfdesk's remote sidebar, beside `remote_workbench_node`): a row opens a tab of the
//   workbench, the tab shown its selected row; a heading's ＋ opens its new view there.
// (左子健, 2026-11-16: 「感觉左边是不是应该按 station 分组，然后分组右边一个加号用来创建不同的视图？」: no band's
// 新建终端 nor bar's ＋ apart from the stations' headings)

///|
// kept across runs: reset via `remote_agent_seen_reset` (wired in `init`)
let remote_agent_seen : @sf.LiveMap[String, Bool] = @sf.LiveMap::new()

///|
fn init {
  @ui.on_reset(fn() { remote_agent_seen.clear() })
}

///|
/// Whether an agent is known to be driving a remote screen in workspace `ws` without adding idle subscriptions on Home.
pub fn remote_agent_lit(src : Source, ws : String) -> Bool {
  if remote_agent_seen.get(ws) == Some(true) {
    return true
  }
  match @sfbase.app.nav.top() {
    Chat(r) =>
      match @sfbase.chat_view_now(src, r) {
        Some(v) => @sfbase.chat_screens_driven(v.screens)
        None => false
      }
    _ => false
  }
}

///|
/// Online full stations `(address, name)` in workspace `ws`.
fn remote_online_stations(src : Source, ws : String) -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  match @sfbase.station_rows(src, ws).value {
    Some(Array(rows)) =>
      for r in rows {
        let rv = Some(r)
        let addr = text(rv, "station")
        if addr != "" && flag(rv, "online") && text(rv, "mode") != "tasks" {
          let nm = text(rv, "name")
          out.push((addr, if nm != "" { nm } else { addr }))
        }
      }
    _ => ()
  }
  out
}

///|
/// Close a remote workbench tab and release its underlying session unless popped out to a standalone window.
pub fn remote_close_tab_clean(src : Source, ws : String, key : String) -> Unit {
  match @sfbase.remote_tab_parse(key) {
    Some(Screen(at)) => {
      @sfbase.remote_tab_close(src, ws, key)
      screen_left(src, at.station, at.screen)
    }
    Some(Terminal(at)) => {
      @sfbase.remote_tab_close(src, ws, key)
      terminal_left(at.station, at.terminal)
    }
    None => @sfbase.remote_tab_close(src, ws, key)
  }
}

///|
/// Open a browser tab on `station` into workspace `ws`'s remote workbench (reusing last seen or creating a new tab).
pub fn remote_open_station_browser_tab(src : Source, ws : String, station : String) -> Unit {
  let sval = @signals.untracked(fn() {
    src.topic("screens", { "station": Json::string(station) }).get().value
  })
  let listed = items(sval, "screens")
    .filter(fn(sc) { flag(Some(sc), "userTab") || text(Some(sc), "id").has_prefix("browser:u_") })
    .map(fn(sc) { text(Some(sc), "id") })
  let target = match @settings.browser_tab_to_open(station, listed) {
    Some(id) => id
    None => @settings.new_browser_tab(src.call, station, listed, failed_said(@sf.t("web-pages.screen.openBrowserWhat")))
  }
  remote_tab_show(src, ws, @sfbase.RemoteTab::Screen({ station, screen: target, title: "", until_gone: false }))
}

///|
/// A line of the remote list (remote_list_node's): the room over it, an online station's heading, one of its rows,
/// nothing online, the room under it.
#derive(Eq)
priv enum RemoteLine {
  Top
  Head(String, String)
  Row(RemoteRow)
  Empty
  Foot
}

///|
/// A row of the remote list: a station's display or simulator (always there, one press opens it), a tab of its
/// browser, a terminal open on it; what it says on its two lines, whether an agent drives it, whether it can be closed
/// from here, and whether it is its station's last (no room under it).
#derive(Eq)
priv struct RemoteRow {
  key : String
  station : String
  kind : String
  id : String
  icon : String
  title : String
  under : String
  agent : Bool
  closable : Bool
  cwd : String
  watch : Bool
  last : Bool
}

///|
/// The line's key in the list (`View::each`'s).
fn remote_line_key(l : RemoteLine) -> String {
  match l {
    Top => "top"
    Head(a, _) => "h/" + a
    Row(r) => r.key
    Empty => "empty"
    Foot => "foot"
  }
}

///|
/// What a screen says under its name when nothing drives it: the core's line, else its size.
fn remote_screen_line(sv : Json?) -> String {
  let line = text(sv, "line")
  if line != "" {
    return line
  }
  let w = count(sv, "width")
  let h = count(sv, "height")
  if w > 0 && h > 0 {
    w.to_string() + " × " + h.to_string()
  } else {
    ""
  }
}

///|
/// Station `address`'s rows (remote_lines'): its displays and simulators, then its browser's tabs, then the terminals
/// open on it (where the app asks for them, `asks_t`).
fn remote_station_rows(src : Source, address : String, asks_t : Bool) -> Array[RemoteRow] {
  let rows : Array[RemoteRow] = []
  let screens = items(src.topic("screens", { "station": Json::string(address) }).get().value, "screens")
  let agent_said = @sf.t("web-pages.remote.agentDriving")
  for sc in screens {
    let sv = Some(sc)
    let kind = text(sv, "kind")
    if kind != "desktop" && kind != "simulator" {
      continue
    }
    let id = text(sv, "id")
    let agent = flag(sv, "agent")
    let title = if kind == "desktop" {
      @sf.t("core-views.screen.kind.desktop")
    } else {
      let t = text(sv, "title")
      if t != "" { t } else { @sf.t("core-views.screen.kind.simulator") }
    }
    rows.push({
      key: "s/" + address + "/" + id,
      station: address,
      kind,
      id,
      icon: if kind == "simulator" { "phone" } else { "monitor" },
      title,
      under: if agent { agent_said } else { remote_screen_line(sv) },
      agent,
      closable: false,
      cwd: "",
      watch: false,
      last: false,
    })
  }
  for sc in screens {
    let sv = Some(sc)
    if text(sv, "kind") != "browser" {
      continue
    }
    let id = text(sv, "id")
    let agent = flag(sv, "agent")
    let site = text(sv, "site")
    let title = {
      let t = text(sv, "title")
      if t != "" {
        t
      } else if site != "" {
        site
      } else {
        @sf.t("core-views.screen.kind.browser")
      }
    }
    let under = if agent {
      if site != "" { agent_said + " · " + site } else { agent_said }
    } else if site != "" {
      site
    } else {
      let u = text(sv, "url")
      if u != "" { u } else { text(sv, "line") }
    }
    rows.push({
      key: "s/" + address + "/" + id,
      station: address,
      kind: "browser",
      id,
      icon: "web",
      title,
      under,
      agent,
      closable: flag(sv, "closable"),
      cwd: "",
      watch: false,
      last: false,
    })
  }
  if asks_t {
    let tv_root = src.topic("terminals", { "station": Json::string(address) }).get().value
    let watch = !flag(tv_root, "open")
    for tm in items(tv_root, "terminals") {
      let tv = Some(tm)
      if flag(tv, "ended") {
        continue
      }
      let id = text(tv, "id")
      let cwd = text(tv, "cwd")
      let title = {
        let l = terminal_title(tv)
        if l != "" { l } else { @sf.t("web-pages.terminal.title") }
      }
      let typing = {
        let who = text(tv, "typing")
        if who != "" { @sf.t("web-pages.terminal.typing", args=[("name", who)]) } else { "" }
      }
      // (never its title again, nor nothing: the folder whole where its name is only its last part, who types beside
      // it; else who types, else who opened it)
      let under = if cwd != "" && cwd != title {
        if typing != "" { cwd + " · " + typing } else { cwd }
      } else if typing != "" {
        typing
      } else {
        let by = text(tv, "by")
        if by != "" { by } else { @sf.t("web-pages.terminal.title") }
      }
      rows.push({
        key: "t/" + address + "/" + id,
        station: address,
        kind: "terminal",
        id,
        icon: "terminal",
        title,
        under,
        agent: false,
        closable: !watch,
        cwd,
        watch,
        last: false,
      })
    }
  }
  rows
}

///|
/// The remote list's lines in workspace `ws` as the core says them now: each online station under its heading, or
/// nothing online.
fn remote_lines(src : Source, ws : String, asks_t : Bool) -> Array[RemoteLine] {
  let out : Array[RemoteLine] = [Top]
  let stations = remote_online_stations(src, ws)
  if stations.is_empty() {
    out.push(Empty)
  }
  for st in stations {
    out.push(Head(st.0, st.1))
    let rows = remote_station_rows(src, st.0, asks_t)
    for i, r in rows {
      out.push(Row({ ..r, last: i == rows.length() - 1 }))
    }
  }
  out.push(Foot)
  out
}

///|
/// The workbench's tab row `r` shows (its page's: a window of its own takes it, window_opens_for).
fn remote_row_tab(r : RemoteRow) -> @sfbase.RemoteTab {
  if r.kind == "terminal" {
    Terminal({ station: r.station, terminal: r.id, watch: r.watch, cwd: r.cwd })
  } else {
    Screen({ station: r.station, screen: r.id, title: r.title, until_gone: false })
  }
}

///|
/// Whether row `r` is what tab `tab` shows (by its station and its screen's or terminal's id).
fn remote_row_shows(r : RemoteRow, tab : @sfbase.RemoteTab) -> Bool {
  match tab {
    Screen(a) => r.kind != "terminal" && a.station == r.station && a.screen == r.id
    Terminal(a) => r.kind == "terminal" && a.station == r.station && a.terminal == r.id
  }
}

///|
/// The rows of the remote list's `lines`, in their order.
fn remote_rows_of(lines : Array[RemoteLine]) -> Array[RemoteRow] {
  let out : Array[RemoteRow] = []
  for l in lines {
    if l is Row(r) {
      out.push(r)
    }
  }
  out
}

///|
/// What the workbench shows in workspace `ws` beside the list of `lines` (its key and tab): its tab in front, else (none
/// in front yet, or the one in front closed) the list's first row's, so 远程 opens on a screen and never on nothing while
/// there is a row to show.
fn remote_front_in(src : Source, ws : String, lines : Array[RemoteLine]) -> (String, @sfbase.RemoteTab)? {
  let (tabs, act) = @sfbase.remote_tabs_of(src, ws)
  match tabs.iter().find_first(fn(p) { p.0 == act }) {
    Some(p) => Some(p)
    None =>
      match remote_rows_of(lines).get(0) {
        Some(r) => {
          let tab = remote_row_tab(r)
          Some((tab.key(), tab))
        }
        None => None
      }
  }
}

///|
/// The tab shown by default (remote_front_in's first row) made one of workspace `ws`'s tabs before another is brought to
/// the front, so that it stays open behind as every tab opened does (its screen covered, its terminal kept).
fn remote_keep_front(src : Source, ws : String) -> Unit {
  let asks_t = (src.asks_terminals)()
  @signals.untracked(fn() {
    let (tabs, _) = @sfbase.remote_tabs_raw(src, ws)
    match remote_front_in(src, ws, remote_lines(src, ws, asks_t)) {
      Some((k, tab)) if !tabs.contains(k) => @sfbase.remote_tab_open(src, ws, tab) |> ignore
      _ => ()
    }
  })
}

///|
/// Tab `tab` brought to the front of workspace `ws`'s workbench (opened if it is not yet), what was shown kept behind.
fn remote_tab_show(src : Source, ws : String, tab : @sfbase.RemoteTab) -> Unit {
  remote_keep_front(src, ws)
  @sfbase.remote_tab_open(src, ws, tab) |> ignore
}

///|
/// The row `delta` rows on from the one the workbench shows in workspace `ws` (round from the last to the first),
/// brought to the front: ⌘⇧] and ⌘⇧[ going down and up the list as a press on its rows does.
pub fn remote_row_step(src : Source, ws : String, delta : Int) -> Unit {
  let asks_t = (src.asks_terminals)()
  let (rows, front) = @signals.untracked(fn() {
    let lines = remote_lines(src, ws, asks_t)
    (remote_rows_of(lines), remote_front_in(src, ws, lines))
  })
  guard !rows.is_empty() else { return }
  let at = match front {
    Some((_, tab)) => rows.search_by(fn(r) { remote_row_shows(r, tab) })
    None => None
  }
  let n = rows.length()
  let next = match at {
    Some(i) => (i + delta % n + n) % n
    None => if delta > 0 { 0 } else { n - 1 }
  }
  remote_tab_show(src, ws, remote_row_tab(rows[next]))
}

///|
/// Row `r` opened: across the whole screen its own page (a screen's, a terminal's); in a side column a tab of the
/// workbench beside it, brought to the front.
fn remote_row_open(src : Source, ws : String, at : @sf.ListAt, r : RemoteRow) -> Unit {
  match (at, r.kind) {
    (Whole, "terminal") => @sfbase.open_terminal(r.station, r.id, r.cwd, "", watch=r.watch)
    (Whole, _) => @sfbase.open_screen(r.station, r.id, Some(r.title))
    _ => remote_tab_show(src, ws, remote_row_tab(r))
  }
}

///|
/// Row `r` closed (its tab of the browser closed, its terminal ended), with the workbench's tabs showing it.
fn remote_row_close(src : Source, ws : String, r : RemoteRow) -> Unit {
  let on : Map[String, Json] = { "station": Json::string(r.station) }
  if r.kind == "terminal" {
    on["terminal"] = Json::string(r.id)
    (src.call)("terminal.end", Json::object(on), @sfbase.answer_unread)
  } else {
    on["screen"] = Json::string(r.id)
    (src.call)("screen.close", Json::object(on), failed_said(@sf.t("web-pages.screen.closeTabWhat")))
  }
  let (tabs, _) = @signals.untracked(fn() { @sfbase.remote_tabs_of(src, ws) })
  for p in tabs {
    if remote_row_shows(r, p.1) {
      remote_close_tab_clean(src, ws, p.0)
    }
  }
}

///|
/// Row `r`'s menu (right clicked, or held by a finger): 在新窗口打开 where a window of its own takes it; a terminal's
/// folder in 文件; 关闭标签页 or 结束会话 where it can be closed.
fn remote_row_menu_items(src : Source, ws : String, r : RemoteRow) -> Array[@sf.MenuItem?] {
  let out : Array[@sf.MenuItem?] = []
  if r.kind == "terminal" && r.cwd != "" {
    out.push(
      Some(
        @sf.menu_item_of(@sf.t("web-pages.remote.openInFiles"), icon="folder", fn() {
          @sfbase.open_page(Drive({ station: r.station, root: Some(r.cwd), path: "" }))
        }),
      ),
    )
  }
  let page = remote_row_tab(r).page()
  if @sfbase.window_opens_for(page) {
    out.push(
      Some(
        @sf.menu_item_of(@sf.t("web-pages.screen.window"), icon="external", fn() {
          if @sfbase.open_window(page) {
            // (handed to its window: its tab here goes, what it shows kept for that window)
            let (tabs, _) = @signals.untracked(fn() { @sfbase.remote_tabs_of(src, ws) })
            for p in tabs {
              if p.1.page() == page {
                @sfbase.remote_tab_close(src, ws, p.0)
              }
            }
          }
        }),
      ),
    )
  }
  if r.closable {
    if !out.is_empty() {
      out.push(None)
    }
    let label = if r.kind == "terminal" { @sf.t("web-pages.terminal.end") } else { @sf.t("web-pages.screen.closeTab") }
    out.push(Some(@sf.menu_item_of(label, icon="close", danger=true, fn() { remote_row_close(src, ws, r) })))
  }
  out
}

///|
/// A row of the remote list (a chat's row's makings: sf's list_row_node) in `parent`, as `item` says it now, `on` the
/// one shown beside the list, `at` where its list stands: its mark beside its first line, its name (bolder, with a dot,
/// while an agent drives it), what it is under it; pressed, opened (remote_row_open, then `on_pick`); right clicked or
/// held by a finger, its menu; with a mouse over it, its × at its top end concentric with its corner where it can be
/// closed (a chat's 归档's place).
fn remote_row_node(
  parent : @view.View,
  src : Source,
  ws : () -> String,
  at : @sf.ListAt,
  tips : @sf.TipLayer,
  item : () -> RemoteRow,
  on : () -> Bool,
  on_pick : () -> Unit,
) -> Unit {
  let t = fn() { @sf.theme() }
  let finger = !@sf.pointer_rests()
  let first = @signals.untracked(item)
  parent.box(fn(slot) {
    // (its slot, cut to its corners where its list stands, the room under it its margin but under its station's last)
    @sf.style_node(slot, fn() {
      if item().last {
        @sf.list_row_slot(at)
      } else {
        @sf.list_row_slot(at).then(@ui.style(mb?=@sf.list_more(at).base.pb))
      }
    })
    let row = slot.box(fn(_) {  })
    // (pressed by a finger, shown so once it has stayed tap_indication_ms: one going on to scroll lights nothing)
    let (press_lit, press_down, press_up) = @sf.press_late(row)
    // its ground: the pointer's eased in and out, the selected one's while it is the tab shown beside the list
    // (nav_ground_by's); a finger's press the ink at 5%
    let hand = if !finger {
      @motion.hover_fade(row, fn() { @sf.lit_in_node(slot) }, duration_ms=@sf.dur_ms)
    } else {
      fn() { 0.0 }
    }
    let chosen = @motion.hover_fade(row, on, duration_ms=@sf.dur_ms)
    let ground = fn() {
      let p = t().p
      let h = hand()
      let o = chosen()
      let base = if h <= 0.0 && o <= 0.0 {
        0L
      } else {
        @sf.over(@sf.alpha(p.hover, h * (1.0 - o)), @sf.alpha(p.selected, o))
      }
      if finger && press_lit() {
        @sf.over(base, @sf.alpha(p.text, 0.05))
      } else {
        base
      }
    }
    // (its × while a mouse is over it, where it can be closed)
    let key_shows = fn() { !finger && item().closable && @sf.lit_in_node(slot) }
    let close_label = fn() {
      if item().kind == "terminal" {
        @sf.t("web-pages.terminal.end")
      } else {
        @sf.t("web-pages.screen.closeTab")
      }
    }
    let open_menu = fn(x : Double, y : Double, from_row : Bool) {
      let r = @signals.untracked(item)
      let menu = remote_row_menu_items(src, @signals.untracked(ws), r)
      guard !menu.is_empty() else { return }
      let from = if from_row {
        let (rx, ry, rw, rh) = row.placed_window_now()
        @sf.Beside::At(rx, ry, rw, rh)
      } else {
        @sf.at_point(x, y)
      }
      // (held by a finger: felt as it opens)
      if from_row {
        @ui.haptic(LongPress)
      }
      @sf.menu(menu, from~)
    }
    @sf.list_row_node(
      row,
      at,
      ground~,
      high=true,
      // (its × over its first line's end: a chat's 归档's room)
      end_room=fn() { if key_shows() { @sf.row_keys_room(1) } else { 0.0 } },
      // (in the slot, its corners the slot's, its own ground square)
      slotted=true,
      mark=fn(k) {
        @sf.icon_node(k, first.icon, remote_row_mark, By(fn() { if item().agent { t().p.primary } else { t().p.muted } }))
        |> ignore
      },
      fn(h) {
        h.box(fn(n) {
          n.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
          @sf.words_node(n, fn() { item().title }, fn() {
            if item().agent {
              t().chat_list.title_unread
            } else {
              t().chat_list.title
            }
          })
          |> ignore
        })
        |> ignore
        // (an agent driving it: a dot at its first line's end, in the column a chat's marks stand in)
        h.show(fn() { item().agent }, fn(s) {
          @sf.style_node(s, fn() { kind_slot }, in_row=true)
          s.says(By(fn() { Some(@view.said(Image, label=@sf.t("web-pages.remote.agentDriving"))) })) |> ignore
          s.box(fn(dot) {
            dot
            .width(Is(Some(remote_dot)))
            .height(Is(Some(remote_dot)))
            .radius(Is(remote_dot / 2.0))
            .ground(By(fn() { t().p.primary }))
            |> ignore
          })
          |> ignore
        })
      },
      fn(u) {
        @sf.list_row_line_node(u, fn(m) {
          m.box(fn(s) {
            s.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
            @sf.words_node(s, fn() { item().under }, fn() { t().chat_list.last }) |> ignore
          })
          |> ignore
        })
      },
    )
    // its × at the row's top end while a mouse points at it (concentric with the row's corner: a chat's 归档's)
    slot.show(key_shows, fn(o) {
      o
      .over(Is(true))
      .lines_up(Is(Some(End)))
      .padding(Is((0.0, @ui.capsule_in(@sf.row_corner, row_key_side), @ui.capsule_in(@sf.row_corner, row_key_side), 0.0)))
      |> ignore
      @sf.action_box_node(o, fn() { close_label() + " " + item().title }, fn(_) {
        remote_row_close(src, @signals.untracked(ws), @signals.untracked(item))
      }, fn(k) {
        k
        .width(Is(Some(row_key_side)))
        .height(Is(Some(row_key_side)))
        .radius(Is(1.0e6))
        .lines_up(Is(Some(Middle)))
        .lies_along(Is(Middle))
        |> ignore
        @sf.hover_ground_node(k)
        k.on_menu(fn(m) { open_menu(m.wx, m.wy, false) }) |> ignore
        @sf.icon_node(k, "close", row_icon, By(fn() { if @sf.lit_node(k) { t().p.text } else { t().p.muted } })) |> ignore
        @sf.tip_node(tips, k, close_label) |> ignore
      })
      |> ignore
    })
    // pressed: opened; right clicked, its menu at the pointer; held long by a finger, its menu from the row
    row
    .says(By(fn() { Some(@view.said(Link, label=item().title)) }))
    .on_menu(fn(m) { open_menu(m.wx, m.wy, false) })
    |> ignore
    @sf.presses_held_node(
      row,
      fn() {
        remote_row_open(src, @signals.untracked(ws), at, @signals.untracked(item))
        on_pick()
      },
      @ui.long_press_ms,
      fn(d) { if finger { open_menu(d.wx, d.wy, true) } },
      down=fn(_) { press_down() },
      up=press_up,
    )
  })
  |> ignore
}

///|
/// Nothing online to reach (list_empty's) in `v`: across the whole screen the stations' illustration and where to add
/// one; in a side column the sidebar's words and their link to the stations.
fn remote_empty_node(v : @view.View, at : @sf.ListAt) -> Unit {
  if at == Whole {
    v.box(fn(b) {
      @sf.style_node(b, fn() { empty_first })
      @sf.drawable_node(b, if @sf.theme().dark { "illus_no_station_dark" } else { "illus_no_station" }, illustration_w) |> ignore
      @sf.words_node(b, fn() { @sf.t("web-pages.remote.noStations") }, fn() { empty_title }) |> ignore
      @sf.note_link_node(b, fn() { @sf.t("web-main.sidebar.noStation.before") }, fn() { @sf.t("web-main.sidebar.noStation.link") }, fn() {
        @sfbase.open_page(Place("stations"))
      })
    })
    |> ignore
  } else {
    v.box(fn(b) {
      @sf.style_node(b, fn() { said_box })
      @sf.note_link_node(b, fn() { @sf.t("web-main.sidebar.noStation.before") }, fn() { @sf.t("web-main.sidebar.noStation.link") }, fn() {
        @sfbase.open_page(Place("stations"))
      })
    })
    |> ignore
  }
}

///|
/// The remote list (the chats' list's makings: its lines, headings and rows) of the workspace in view (`ws`) in node
/// `v`, standing `at` (across the whole screen on 小屏, in the sidebar's column on 中屏 and 大屏): each online station
/// under its heading, its displays and simulators, its browser's tabs and the terminals open on it; the room `top`
/// keeps over it (what covers it: a bar, a band), `foot` under it. In a side column the tab shown in the workbench beside
/// it is its selected row, and a row pressed is opened there, then `on_pick`.
pub fn remote_list_node(
  v : @view.View,
  src : Source,
  ws : () -> String,
  at : @sf.ListAt,
  tips : @sf.TipLayer,
  top~ : () -> Double,
  foot~ : () -> Double,
  on_pick? : () -> Unit = fn() {  },
) -> Unit {
  let asks_t = (src.asks_terminals)()
  // (an agent driving a screen anywhere in it: the bar's and the rail's dot, remote_agent_lit)
  v.reacts(
    fn() {
      let cur_ws = ws()
      let mut any_agent = false
      for st in remote_online_stations(src, cur_ws) {
        let sval = src.topic("screens", { "station": Json::string(st.0) }).get().value
        if items(sval, "screens").any(fn(sc) { flag(Some(sc), "agent") }) {
          any_agent = true
        }
      }
      (cur_ws, any_agent)
    },
    fn(pair) { remote_agent_seen.set(pair.0, pair.1) },
  )
  let lines = @signals.computed(fn(_) { remote_lines(src, ws(), asks_t) }, same=fn(a, b) { a == b })
  // (what the workbench beside a side column's list shows: its selected row)
  let shown = @signals.computed(
    fn(_) {
      if at == Whole {
        None
      } else {
        remote_front_in(src, ws(), lines.get()).map(fn(p) { p.1 })
      }
    },
    same=fn(a, b) { a == b },
  )
  v.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
  v.scrolls(
    @view.Scroll::list(),
    slop=@ui.touch_slop(),
    bar=@ui.tree_scroll_bar(),
    top_covered=top,
    bar_clear=fn() { (top(), foot()) },
    fn(col) {
      col.each(fn() { lines.get() }, remote_line_key, fn(line, now) {
        @sf.style_node(line, fn() { @sf.list_line(at) })
        match now.untracked() {
          Top => line.height(By(fn() { Some(top() + @sf.theme().chat_list.top_in) })) |> ignore
          Foot => line.height(By(fn() { Some(foot() + @sf.list_foot_in(at)) })) |> ignore
          Empty => remote_empty_node(line, at)
          Head(address, _) =>
            remote_station_head_node(
              line,
              src,
              ws,
              at,
              tips,
              address,
              fn() {
                match now.get() {
                  Head(_, name) => name
                  _ => ""
                }
              },
              on_pick,
            )
          Row(first) => {
            let item = fn() {
              match now.get() {
                Row(r) => r
                _ => first
              }
            }
            let on = fn() {
              match shown.get() {
                Some(tab) => remote_row_shows(item(), tab)
                None => false
              }
            }
            remote_row_node(line, src, ws, at, tips, item, on, on_pick)
          }
        }
      })
    },
  )
  |> ignore
}

///|
/// 小屏's first-class `Place("remote")` page: the remote list across the whole screen under the place's top bar (the
/// narrow shell's, on its glass: 远程, settings at its end), over the bottom bar (no ＋ in its notch: each station's
/// heading has its own, remote_station_head_node).
pub fn remote_page_node(
  v : @view.View,
  src : Source,
  ws : () -> String,
  frame~ : () -> @sf.PageFrame,
  stint? : () -> Int = fn() { 0 },
) -> Unit {
  ignore(stint)
  let tips = @sf.TipLayer::new(fn() { None })
  v.grow(Is(1.0)).min_height(Is(Some(0.0))).ground(By(fn() { @sf.theme().p.bg })) |> ignore
  remote_list_node(v, src, ws, Whole, tips, top=fn() { frame().top }, foot=fn() { frame().foot })
}

///|
/// Whether a new terminal can be opened on station `address` from here: asked for, and the station letting this person
/// type (or not said yet).
fn remote_can_term(src : Source, address : String) -> Bool {
  guard (src.asks_terminals)() else { return false }
  let tval = src.topic("terminals", { "station": Json::string(address) }).get().value
  tval is None || flag(tval, "open")
}

///|
/// Whether station `address`'s browser can be reached from here: a tab of its own made where it lets this person drive
/// it, else the tabs it has.
fn remote_can_browse(src : Source, address : String) -> Bool {
  let sv = src.topic("screens", { "station": Json::string(address) }).get().value
  (flag(sv, "browser") && flag(sv, "control")) || items(sv, "screens").any(fn(sc) { text(Some(sc), "kind") == "browser" })
}

///|
/// The online stations of workspace `ws` a new terminal can be opened on (⌘T's).
fn remote_terminal_stations(src : Source, ws : String) -> Array[(String, String)] {
  @signals.untracked(fn() { remote_online_stations(src, ws).filter(fn(st) { remote_can_term(src, st.0) }) })
}

///|
/// A new view of station `address`'s browser: a new tab of its own where it lets this person drive it, else (its tabs
/// only to look at) the one last seen or its last; across the whole screen (`at` Whole) its page, in a side column a tab
/// of workspace `ws`'s workbench brought to the front.
fn remote_new_browser_view(src : Source, ws : String, at : @sf.ListAt, address : String) -> Unit {
  let sv = @signals.untracked(fn() { src.topic("screens", { "station": Json::string(address) }).get().value })
  let listed = items(sv, "screens")
    .filter(fn(sc) { flag(Some(sc), "userTab") || text(Some(sc), "id").has_prefix("browser:u_") })
    .map(fn(sc) { text(Some(sc), "id") })
  let target = if flag(sv, "browser") && flag(sv, "control") {
    @settings.new_browser_tab(src.call, address, listed, failed_said(@sf.t("web-pages.screen.openBrowserWhat")))
  } else {
    match @settings.browser_tab_to_open(address, listed) {
      Some(id) => id
      None =>
        items(sv, "screens")
        .filter(fn(sc) { text(Some(sc), "kind") == "browser" })
        .map(fn(sc) { text(Some(sc), "id") })
        .last()
        .unwrap_or("")
    }
  }
  guard target != "" else { return }
  if at == Whole {
    @sfbase.open_screen(address, target, None)
  } else {
    remote_tab_show(src, ws, @sfbase.RemoteTab::Screen({ station: address, screen: target, title: "", until_gone: false }))
  }
}

///|
/// Station `address`'s heading's ＋ menu (remote_station_head_node's): 新建终端 where a terminal can be opened on it,
/// 新建浏览器标签页 where its browser can be reached; picked, across the whole screen (`at` Whole) its page, in a side
/// column a tab of workspace `ws`'s workbench brought to the front, then `on_pick`.
fn remote_station_add_menu(
  src : Source,
  ws : String,
  at : @sf.ListAt,
  address : String,
  on_pick : () -> Unit,
) -> Array[@sf.MenuItem?] {
  let (term, browse) = @signals.untracked(fn() { (remote_can_term(src, address), remote_can_browse(src, address)) })
  let out : Array[@sf.MenuItem?] = []
  if term {
    out.push(
      Some(
        @sf.menu_item_of(@sf.t("web-pages.terminal.new"), icon="terminal", fn() {
          if at == Whole {
            @sfbase.open_terminal(address, "new", "", "")
          } else {
            remote_tab_show(src, ws, @sfbase.RemoteTab::Terminal({ station: address, terminal: "new", watch: false, cwd: "" }))
            on_pick()
          }
        }),
      ),
    )
  }
  if browse {
    out.push(
      Some(
        @sf.menu_item_of(@sf.t("web-pages.remote.newBrowserTab"), icon="web", fn() {
          remote_new_browser_view(src, ws, at, address)
          if at != Whole {
            on_pick()
          }
        }),
      ),
    )
  }
  out
}

///|
/// An online station's heading in the remote list (sf's list_heading_node's room and words, `at` where its list stands)
/// in `parent`: its name (`name`), on one line, and at its end, where a view can be made on it (a terminal, its
/// browser), its ＋ (remote_station_add_menu from it), named by the station so each station's reads apart. The ＋ stands
/// on the heading's line, centred on it and reaching over and under it without making it taller (a box of no height in
/// its middle): its end where the rows' × stands under a mouse (concentric with their corner), where their words end
/// under a finger in a side column, at the rows' end across the whole screen.
fn remote_station_head_node(
  parent : @view.View,
  src : Source,
  ws : () -> String,
  at : @sf.ListAt,
  tips : @sf.TipLayer,
  address : String,
  name : () -> String,
  on_pick : () -> Unit,
) -> Unit {
  let finger = !@sf.pointer_rests()
  let side = if finger { remote_add_finger } else { row_key_side }
  let icon = if finger { remote_add_finger_icon } else { row_icon }
  // (how far past the heading's end its ＋'s end stands: to the rows' × (a mouse's), their end (across the screen))
  let past = match at {
    Whole => remote_whole_heading_in - remote_whole_row_end
    Side | Tape => if finger { 0.0 } else { @sf.heading_in_at(at) - @ui.capsule_in(@sf.row_corner, side) }
  }
  parent.box(fn(h) {
    @sf.style_node(h, fn() { @sf.theme().chat_list.heading.then(@sf.list_heading_in(at)) })
    h.box(fn(line) {
      line.row(Is(true)).lines_up(Is(Some(Middle))) |> ignore
      line.box(fn(n) {
        n.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
        @sf.words_node(n, name, fn() { @sf.theme().chat_list.heading_words }) |> ignore
      })
      |> ignore
      line.show(fn() { remote_can_term(src, address) || remote_can_browse(src, address) }, fn(k) {
        k
        .width(Is(Some(side)))
        .height(Is(Some(0.0)))
        .shrink(Is(0.0))
        .lines_up(Is(Some(Middle)))
        .lies_along(Is(Middle))
        .margin(Is((remote_add_gap, 0.0, -past, 0.0)))
        |> ignore
        let label = fn() { @sf.t("web-pages.remote.newViewOn", args=[("station", name())]) }
        let plus : Ref[@view.View?] = Ref(None)
        plus.val = Some(
          @sf.icon_button_node(
            k,
            "plus",
            label,
            fn() {
              guard plus.val is Some(b) else { return }
              let menu = remote_station_add_menu(src, @signals.untracked(ws), at, address, on_pick)
              guard !menu.is_empty() else { return }
              @sf.menu(menu, from=Node(b))
            },
            tips~,
            size=side,
            icon_size=icon,
          ),
        )
      })
    })
    |> ignore
  })
  |> ignore
}

///|
/// Whether the workspace's `Place("remote")` holds or fronts `station`'s `screen`.
pub fn remote_has_screen(src : Source, station : String, screen : String) -> Bool {
  guard @signals.untracked(fn() { @sfbase.workspace_in_view(src).0 }) is Some(w) else { return false }
  let matches = fn(t : @sfbase.RemoteTab) {
    t is Screen(x) && x.station == station && x.screen == screen
  }
  let front = @signals.untracked(fn() { remote_front_in(src, w.id, remote_lines(src, w.id, (src.asks_terminals)())) })
  if front is Some((_, t)) && matches(t) {
    return true
  }
  let (tabs, _) = @signals.untracked(fn() { @sfbase.remote_tabs_raw(src, w.id) })
  tabs.any(fn(k) { @sfbase.remote_tab_parse(k) is Some(t) && matches(t) })
}

///|
/// 中屏 and 大屏's `Place("remote")` beside its list (remote_list_node, its selected row the one shown here): the tab in
/// front (remote_front_in: the list's first row while none is), its page made here with its own one bar for the pane's
/// top, as the chats' and the stations' pages are: no row of tabs over it (the list beside it is that row: 左子健,
/// 2026-11-16, 「为啥左边 list 了，上头那个 tab 干啥的」). `start_pad` and `end_pad`: how far in from the pane's ends
/// that bar's first and last keys stand (clear of the folded sidebar's keys, concentric with the window's or the
/// panel's corner); `foot_pad`: the room a screen keeps under what it has at its foot (a finger's 键盘, 右键…), clear of
/// the pane's foot corners where they are round. The tabs opened stay open behind as another is shown (a screen covered, a terminal kept) till their
/// row's × closes them; none online, the stations to add one from.
pub fn remote_workbench_node(
  v : @view.View,
  src : Source,
  ws : () -> String,
  tips : @sf.TipLayer,
  start_pad? : () -> Double = fn() { 12.0 },
  end_pad? : () -> Double = fn() { 12.0 },
  foot_pad? : () -> Double = fn() { 0.0 },
  width? : () -> Double,
  shown? : () -> Bool = fn() { true },
  keep_screen? : (String, String) -> Bool = fn(_, _) { false },
) -> Unit {
  let asks_t = (src.asks_terminals)()
  let pads = fn() { (start_pad(), end_pad()) }
  let lines = @signals.computed(fn(_) { remote_lines(src, ws(), asks_t) }, same=fn(a, b) { a == b })
  let front = @signals.computed(fn(_) { remote_front_in(src, ws(), lines.get()) }, same=fn(a, b) { a == b })
  let front_key = fn() { front.get().map_or("", fn(p) { p.0 }) }
  // (a screen shown covered as another is brought to the front while its tab stays open, let go once it is closed)
  let prev_front : Ref[(String, @sfbase.RemoteTab)?] = Ref(None)
  v.reacts(
    fn() { (front.get(), @sfbase.remote_tabs_raw(src, ws()).0, shown()) },
    fn(cur) {
      let (now, tabs, is_shown) = cur
      match prev_front.val {
        Some((old_k, Screen(old_at))) => {
          let still_same = is_shown && (match now {
            Some((_, Screen(now_at))) => now_at.station == old_at.station && now_at.screen == old_at.screen
            _ => false
          })
          if !still_same {
            let kept = !is_shown ||
              tabs.any(fn(k) {
                k == old_k ||
                (@sfbase.remote_tab_parse(k) is Some(Screen(x)) && x.station == old_at.station && x.screen == old_at.screen)
              })
            if kept {
              screen_covered(src, old_at.station, old_at.screen, true)
            } else {
              screen_left(src, old_at.station, old_at.screen)
            }
          }
        }
        _ => ()
      }
      if is_shown && now is Some((_, Screen(now_at))) {
        screen_covered(src, now_at.station, now_at.screen, false)
      }
      prev_front.val = if is_shown { now } else { prev_front.val }
    },
  )
  v.owns(fn() {
    let seen : Array[(String, String)] = []
    let take = fn(at : ScreenAt) {
      if !seen.contains((at.station, at.screen)) {
        seen.push((at.station, at.screen))
      }
    }
    match prev_front.val {
      Some((_, Screen(at))) => take(at)
      _ => ()
    }
    for k in @signals.untracked(fn() { @sfbase.remote_tabs_raw(src, ws()).0 }) {
      if @sfbase.remote_tab_parse(k) is Some(Screen(at)) {
        take(at)
      }
    }
    for pair in seen {
      let (st, sc) = pair
      if keep_screen(st, sc) {
        screen_covered(src, st, sc, false)
      } else {
        screen_left(src, st, sc)
      }
    }
  })
  |> ignore
  v
  .grow(Is(1.0))
  .min_height(Is(Some(0.0)))
  .ground(By(fn() { @sf.theme().p.bg }))
  .key_context("Remote")
  // ⌘T: a new terminal, on the station of the one shown (else the first online), shown
  .on_action("remote.tab_new", fn(_) {
    let cur_ws = @signals.untracked(ws)
    let station = match @signals.untracked(fn() { front.get() }) {
      Some((_, tab)) => tab.station()
      None => @signals.untracked(fn() { remote_online_stations(src, cur_ws) }).get(0).map_or("", fn(s) { s.0 })
    }
    guard station != "" else { return false }
    if remote_terminal_stations(src, cur_ws).any(fn(s) { s.0 == station }) {
      remote_tab_show(src, cur_ws, @sfbase.RemoteTab::Terminal({ station, terminal: "new", watch: false, cwd: "" }))
    } else {
      remote_open_station_browser_tab(src, cur_ws, station)
    }
    true
  })
  // ⌘W: the tab shown closed (one opened only: the first row shown by default has none to close)
  .on_action("remote.tab_close", fn(_) {
    let cur_ws = @signals.untracked(ws)
    let key = @signals.untracked(front_key)
    let (tabs, _) = @signals.untracked(fn() { @sfbase.remote_tabs_raw(src, cur_ws) })
    guard key != "" && tabs.contains(key) else { return false }
    remote_close_tab_clean(src, cur_ws, key)
    true
  })
  // ⌘⇧] and ⌘⇧[ (⌃⇥, ⌃⇧⇥): the list's next and previous row shown, as pressed
  .on_action("remote.tab_next", fn(_) {
    remote_row_step(src, @signals.untracked(ws), 1)
    true
  })
  .on_action("remote.tab_back", fn(_) {
    remote_row_step(src, @signals.untracked(ws), -1)
    true
  })
  |> ignore
  v.pick(at_once=true, front_key, fn(body, key) {
    body.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
    guard @sfbase.remote_tab_parse(key) is Some(tab) else {
      // (nothing to show: none online, the stations' illustration and where to add one; else nothing till the
      // stations say their screens)
      body.lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
      body.show(fn() { remote_online_stations(src, ws()).is_empty() }, fn(e) { remote_empty_node(e, Whole) })
      return
    }
    // (the tab's key as it is now: a new terminal's becomes its own as the station names it)
    let tab_key = Ref(key)
    let close_tab = fn() { remote_close_tab_clean(src, @signals.untracked(ws), tab_key.val) }
    // (handed to a window of its own: its tab goes, what it shows kept for that window)
    let to_window = fn() { @sfbase.remote_tab_close(src, @signals.untracked(ws), tab_key.val) }
    let switch_in_workbench = fn(next : @sfbase.Page) {
      let cur_ws = @signals.untracked(ws)
      match next {
        Screen(at) => remote_tab_show(src, cur_ws, @sfbase.RemoteTab::Screen(at))
        Terminal(at) => remote_tab_show(src, cur_ws, @sfbase.RemoteTab::Terminal(at))
        other => @sfbase.open_page(other)
      }
    }
    match tab {
      Screen(at) =>
        screen_pane_node(
          body,
          src,
          at,
          fn() { { back: None, top: 0.0, foot: foot_pad(), named: false } },
          on_close=close_tab,
          in_tab=true,
          tab_pads=pads,
          on_window=to_window,
        )
      Terminal(at) =>
        terminal_pane_node(
          body,
          src,
          at,
          back=fn() { @sf.t("web-main.rail.remote") },
          on_back=close_tab,
          top=fn() { 0.0 },
          width?,
          in_tab=true,
          bar_pads=pads,
          on_window=to_window,
          tips~,
          keep_open=fn() {
            let (tabs, _) = @signals.untracked(fn() { @sfbase.remote_tabs_of(src, @signals.untracked(ws)) })
            tabs.any(fn(p) {
              p.0 == tab_key.val ||
              (p.1 is Terminal(x) && x.station == at.station && x.terminal == at.terminal && !at.terminal.has_prefix("new"))
            })
          },
          on_resolved=fn(real_id, real_cwd) {
            tab_key.val = @sfbase.remote_tab_replace(
              src,
              @signals.untracked(ws),
              tab_key.val,
              @sfbase.RemoteTab::Terminal({ ..at, terminal: real_id, cwd: if real_cwd != "" { real_cwd } else { at.cwd } }),
            )
          },
          on_switch_page=switch_in_workbench,
        )
    }
  })
}

///|
// kept across runs: a value (no field of it changes)
let remote_row_mark : Double = 18.0

///|
/// The dot at a row's first line's end while an agent drives it.
// kept across runs: a value (no field of it changes)
let remote_dot : Double = 8.0

///|
/// A heading's ＋ under a finger: its side and its icon's (a mouse's: a row's ×'s, row_key_side and row_icon).
// kept across runs: a value (no field of it changes)
let remote_add_finger : Double = 32.0

///|
// kept across runs: a value (no field of it changes)
let remote_add_finger_icon : Double = 18.0

///|
/// The room between a heading's name and its ＋.
// kept across runs: a value (no field of it changes)
let remote_add_gap : Double = 8.0

///|
/// Across the whole screen, how far in a heading's words are (sf's list_heading_in: S5) and a row's end (list_row_in's
/// pr: S4), its ＋'s end on the rows'.
// kept across runs: a value (no field of it changes)
let remote_whole_heading_in : Double = 20.0

///|
// kept across runs: a value (no field of it changes)
let remote_whole_row_end : Double = 16.0
