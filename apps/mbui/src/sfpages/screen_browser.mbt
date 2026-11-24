// A tab of the station's browser, shown as a browser shows one (the user, 2026-11-13: 「更像普通浏览器」「操作太复杂了，
// 而且不够符合直觉」): over the page, all browser pages on the station as a row of tabs, the one shown pressed, each
// closable one closed by its ×, ＋ a new one when the station allows opening browser tabs; under them ← → ⟳ and the
// address bar, its whole address shown, the words typed there gone to (or searched for, the station's `addressOrSearch`)
// on Enter. Where the page is narrow the tabs fold into a button that counts them, its panel listing them. A new tab is
// there as it is pressed (the user, 2026-11-13: 「会等 station 开了这边才开，点个按钮要半天」): its id made here
// (@settings.new_browser_tab), its view opened at once on its blank page, its address bar taking the keys, while its
// station makes it. That a tab sleeps while nobody looks at it is the station's own and never shown: pressed, it is
// woken.
//
// With keyboard and mouse, a browser's keys: ⌘L (Ctrl+L) the address bar, ⌘T a new tab (when allowed), ⌘W this one
// closed (when closable), ⌘[ ⌘] back and forward, ⌘R again (screen_view's screen_keys_in).

///|
/// Whether the viewer shows the browser's bar: a tab of the station's browser (driven or watch-only, so the bar stays
/// in place with its address read-only and its navigation keys dimmed while an agent operates it).
fn browser_shown(s : ScreenSess) -> Bool {
  let tab = s.screen.has_prefix("browser:") || text(s.state, "kind") == "browser"
  s.open_now() && tab && (s.user_tab() || flag(s.state, "openUrl") || text(s.state, "address") != "")
}

///|
/// All browser pages on the station, in the order they were opened (the station's list keeps it), along with the raw
/// `screens` topic value so callers can inspect station flags (`browser`, `control`).
fn browser_tabs_of(s : ScreenSess) -> (Json?, Array[Json]) {
  let sc = s.src.topic("screens", { "station": Json::string(s.station) }).get().value
  (sc, items(sc, "screens").filter(fn(item) { is_browser_screen(Some(item)) }))
}

///|
/// A tab's name: its page's title; a new tab's blank page (no title, `about:blank`) 新标签页.
fn tab_words(title : String) -> String {
  if title == "" || title == "about:blank" {
    @sf.t("web-pages.screen.newTab")
  } else {
    title
  }
}

///|
/// What the address bar shows of a tab's address: none for a new tab's blank page (its placeholder then).
fn address_shown(s : ScreenSess) -> String {
  let a = text(s.state, "address")
  if a == "about:blank" {
    ""
  } else {
    a
  }
}

///|
/// One of a view's tabs (view_tabs): a browser page on the station, or the whole of a desktop or one of its windows;
/// its words, what its tip says, whether it is the one shown, what pressing it does, and its × (none: kept). What is
/// done is said as a value and done by tab_do in the press's handler, never as a frame is built.
priv struct ViewTab {
  key : String
  words : String
  note : String
  current : Bool
  press : TabAct
  close : TabAct?
}

///|
/// What one of the view's tabs does pressed: a browser page shown (its id, its title), a desktop's window shown alone
/// (none: the whole display), a page closed (its id), a new tab.
priv enum TabAct {
  Show(String, String)
  Window(Double?)
  Close(String)
  Add
}

///|
/// Tab action `act` done (in a press's handler): `close` closes the viewer where its last tab closes.
fn tab_do(s : ScreenSess, u : ScreenUi, act : TabAct, close : () -> Unit) -> Unit {
  match act {
    Show(id, title) => if id != s.screen { switch_screen_to(s, u, id, title, false) }
    Window(window) => {
      let p : Map[String, Json] = { "t": Json::string("window") }
      match window {
        Some(n) => p["id"] = Json::number(n)
        None => ()
      }
      s.input(s.src, Json::object(p))
    }
    Close(id) => close_tab(s, u, id, browser_tabs_of(s).1, close)
    Add => new_tab_from(s, u)
  }
}

///|
/// The view's tabs (the user, 2026-11-13: 「远程控制也支持按窗口查看，类似浏览器按 tab 查看」): all browser pages on
/// the station while any browser page is shown, each closable one closed by its × (`add` then 新标签页 when allowed);
/// a desktop's whole screen and each window its station says it has (`windows`, `window` the one shown alone), pressed
/// shown alone; else none (a simulator: its name in their place).
fn view_tabs(s : ScreenSess) -> (Array[ViewTab], Bool) {
  if browser_shown(s) {
    let (sc, listed) = browser_tabs_of(s)
    guard sc is Some(_) else { return ([], false) }
    let can_add = flag(sc, "browser") && flag(sc, "control")
    let tabs = listed.map(fn(item) {
      let id = text(Some(item), "id")
      let current = id == s.screen
      let title = if current {
        match opt_text(s.state, "title") {
          Some(t) if t != "" => t
          _ => text(Some(item), "title")
        }
      } else {
        text(Some(item), "title")
      }
      {
        key: id,
        words: tab_words(title),
        note: text(Some(item), "site"),
        current,
        press: Show(id, title),
        close: if flag(Some(item), "closable") { Some(Close(id)) } else { None },
      }
    })
    if !tabs.iter().any(fn(t) { t.current }) {
      let title = opt_text(s.state, "title").unwrap_or("")
      let closable = (s.user_tab() || s.opens_url()) && flag(sc, "control")
      tabs.push({
        key: s.screen,
        words: tab_words(title),
        note: text(s.state, "site"),
        current: true,
        press: Show(s.screen, title),
        close: if closable { Some(Close(s.screen)) } else { None },
      })
    }
    return (tabs, can_add)
  }
  let windows = items(s.state, "windows")
  if windows.is_empty() || !s.open_now() {
    return ([], false)
  }
  let shown = match field(s.state, "window") {
    Some(Number(n, ..)) => Some(n)
    _ => None
  }
  let tabs : Array[ViewTab] = [
    {
      key: "screen",
      words: @sf.t("web-pages.screen.wholeScreen"),
      note: "",
      current: shown is None,
      press: Window(None),
      close: None,
    },
  ]
  for w in windows {
    let id = match field(Some(w), "id") {
      Some(Number(n, ..)) => n
      _ => continue
    }
    let app = text(Some(w), "app")
    let title = text(Some(w), "title")
    tabs.push({
      key: "w\{id}",
      words: if title == "" { app } else if app == "" { title } else { app + " – " + title },
      note: app,
      current: shown == Some(id),
      press: Window(Some(id)),
      close: None,
    })
  }
  (tabs, false)
}

///|
/// Whether the viewer shows the browser's bar now (browser_shown), followed as the state is told.
fn browser_shown_now(s : ScreenSess) -> Bool {
  s.said.get() |> ignore
  s.failure.get() |> ignore
  s.finished.get() |> ignore
  browser_shown(s)
}

///|
/// The view's tabs in a row in `m` (the viewer's bar's middle with keyboard and mouse; @sf.tab_bar_node's capsules, one
/// tab list: Tab stopping at the one shown, ← → showing each): the one shown on the selected ground, each that closes
/// its × at its end, then ＋ where there is one to add.
fn tabs_row_node(m : @view.View, pg : ScreenPage) -> Unit {
  let s = pg.s
  let u = pg.u
  let tabs = fn() {
    s.said.get() |> ignore
    view_tabs(s)
  }
  let tab_of = fn(key : String) -> ViewTab? {
    let all = tabs().0
    match all.search_by(fn(t) { t.key == key }) {
      Some(i) => Some(all[i])
      None => None
    }
  }
  m.box(fn(row) {
    @sf.style_node(row, fn() { browser_tabs_row }, in_row=true)
    row.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
    @sf.tab_bar_node(
      row,
      fn() { @sf.t(if browser_shown(s) { "web-pages.screen.tabs" } else { "web-pages.screen.windows" }) },
      fn() { tabs().0.map(fn(t) { t.key }) },
      fn() {
        let all = tabs().0
        match all.search_by(fn(t) { t.current }) {
          Some(i) => all[i].key
          None => ""
        }
      },
      // (what pressing it does looked up as it is pressed)
      fn(key) {
        match @signals.untracked(fn() { tab_of(key) }) {
          Some(t) => tab_do(s, u, t.press, pg.close)
          None => ()
        }
      },
      fn(key) { tab_of(key).map(fn(t) { t.words }).unwrap_or("") },
      fn(b, key, shown) { @sf.tab_words_node(b, fn() { tab_of(key).map(fn(t) { t.words }).unwrap_or("") }, shown) |> ignore },
      close=fn(key) {
        match @signals.untracked(fn() { tab_of(key) }) {
          Some({ close: Some(a), .. }) => tab_do(s, u, a, pg.close)
          _ => ()
        }
      },
      closes=fn(key) { tab_of(key).map(fn(t) { t.close is Some(_) }).unwrap_or(false) },
      close_label=fn(_) { @sf.t("web-pages.screen.closeTab") },
      trail=fn(e) {
        e.show(at_once=true, fn() { tabs().1 }, fn(k) {
          // (as tall as the tabs beside it: what is pressed side by side is one height)
          screen_round_node(k, pg, fn() { "plus" }, fn() { @sf.t("web-pages.screen.newTab") }, fn(_) {
            tab_do(s, u, Add, pg.close)
          }, side=@sf.side_tab_side)
          |> ignore
        })
        |> ignore
      },
      at_once=true,
      tips=pg.tips,
      tip=fn(_) { true },
    )
    .grow(Is(1.0))
    .min_width(Is(Some(0.0)))
    |> ignore
  })
  |> ignore
}

///|
/// Whether the view's bar is laid out narrow: in a narrow window (`v`'s), followed. (Beside its chat with keyboard and
/// mouse the panel's bar is its own, narrow whatever the window: screen_tab_bar_node.)
fn view_narrow(v : @view.View, _u : ScreenUi) -> Bool {
  v.window_w() < browser_wide_at
}

///|
/// The browser's row over the page in `b` (see the file's head): ← → ⟳ and the address bar; narrow, ← and the address
/// bar, the tabs folded into the button counting them at its end.
fn browser_bar_node(b : @view.View, pg : ScreenPage) -> Unit {
  browser_seen(pg.s)
  b.box(fn(bar) {
    @sf.style_node(bar, fn() { browser_bar_box })
    bar.box(fn(row) {
      @sf.style_node(row, fn() { browser_tools_row })
      let narrow = fn() { view_narrow(row, pg.u) }
      // (控制中心 offers → and ⟳ where it is narrow: center_node)
      row.reacts(narrow, fn(n) { pg.u.narrow_bar = n })
      browser_tools_node(row, pg, narrow~)
    })
    |> ignore
  })
  |> ignore
}

///|
/// ← (→ ⟳ where there is the room, not `narrow`) and the address bar in `row`; narrow, the tabs' button after it.
fn browser_tools_node(row : @view.View, pg : ScreenPage, narrow~ : () -> Bool) -> Unit {
  let s = pg.s
  let u = pg.u
  // (@sf.address_bar_node's: the page's whole address while it is not written in, as the station last said it; picked
  // whole as it is pressed into, as a browser's is; Escape giving the writing up; what is written gone to on Enter)
  let field = @ui.Field::new()
  u.address_field = Some(field)
  let shown = fn() {
    s.said.get() |> ignore
    address_shown(s)
  }
  let can_drive = fn() {
    s.said.get() |> ignore
    flag(s.state, "openUrl")
  }
  let bar = @sf.address_bar_node(
    row,
    field,
    shown,
    fn(go) {
      let p : Map[String, Json] = {
        "station": Json::string(s.station),
        "screen": Json::string(s.screen),
        "url": Json::string(go),
      }
      (s.src.call)("screen.openUrl", Json::object(p), screen_act(@sf.t("web-pages.screen.goUrlWhat")))
    },
    fn() { @sf.t("web-pages.screen.addressHint") },
    fn() { browser_act(s, "screen.back", @sf.t("web-pages.screen.backWhat")) },
    fn() { browser_act(s, "screen.forward", @sf.t("web-pages.screen.forwardWhat")) },
    fn() { browser_act(s, "screen.reload", @sf.t("web-pages.screen.reloadWhat")) },
    can_back=can_drive,
    can_forward=can_drive,
    can_reload=can_drive,
    editable=can_drive,
    keys_shown=fn() { !narrow() },
    placeholder=fn() { @sf.t("web-pages.screen.addressHint") },
    tips=pg.tips,
    // (on the viewer's bar, the canvas's ground: the card's with its line, as its field was)
    framed=true,
  )
  bar.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
  // asked to take the keys (⌘L, a new tab), here as it is made or as it is asked
  bar.reacts(fn() { u.address_asked.get() }, fn(n) {
    if n > u.address_done {
      u.address_done = n
      if @signals.untracked(can_drive) {
        field.focus()
      }
    }
  })
  // (the tabs in a row of their own only in the viewer's bar with keyboard and mouse: screen_viewer_bar_node)
  let tabs = fn() {
    s.said.get() |> ignore
    !view_tabs(s).0.is_empty()
  }
  let bar_holds = fn() { narrow() || @sf.soft_keyboard() || pg.in_tab }
  row.show(at_once=true, fn() { bar_holds() && tabs() }, fn(k) { tabs_button_node(k, pg) })
  // (where the tabs have no row of their own the address keeps the room: ⟳ is the 控制中心's, a new tab the tabs'
  // panel's first row, ＋ here only where there is no tabs' button to hold it)
  row.show(at_once=true, fn() {
    s.said.get() |> ignore
    let (tabs, add) = view_tabs(s)
    bar_holds() && tabs.is_empty() && add
  }, fn(k) {
    screen_round_node(k, pg, fn() { "plus" }, fn() { @sf.t("web-pages.screen.newTab") }, fn(_) {
      tab_do(s, pg.u, Add, pg.close)
    })
    |> ignore
  })
}

///|
/// What the viewer shows of a person's own page is the one their station's browser opens to next (@settings's).
fn browser_seen(s : ScreenSess) -> Unit {
  if s.user_tab() {
    @settings.browser_tab_seen(s.station, s.screen)
  }
}

///|
/// Where the bar is narrow, in `k`: the view's tabs folded into one button counting them; pressed, they are listed in a
/// panel (each pressed shown) with 新标签页 at its head (when allowed) and, when the current tab is closable, 关闭此标签页
/// at its foot.
fn tabs_button_node(k : @view.View, pg : ScreenPage, side? : Double) -> Unit {
  let s = pg.s
  let u = pg.u
  let label = fn() {
    s.said.get() |> ignore
    @sf.t(if browser_shown(s) { "web-pages.screen.tabs" } else { "web-pages.screen.windows" })
  }
  let count = fn() {
    s.said.get() |> ignore
    view_tabs(s).0.length()
  }
  let open = fn(from : @view.View) {
    let l = @signals.untracked(label)
    screen_panel_toggle(u, "tabs", fn() {
      @sf.panel_nodes(l, fn(v, done) { tabs_node(v, s, u, done, pg.close) }, from=Node(from), side=screen_panel_side(), focus=false)
    })
  }
  let b = @sf.action_box_node(k, fn() { label() + " \{count()}" }, open, fn(b) {
    @sf.style_node(b, fn() { browser_count_box }, in_row=true)
    // (in a bar of tools, as big as they are: what is pressed side by side is one height; in a pane's own bar, its keys')
    let side = match side {
      Some(d) => Some(d)
      None => if pg.tab_pads is Some(_) { Some(round_bar_side) } else { None }
    }
    if side is Some(d) {
      b.width(Is(Some(d))).height(Is(Some(d))) |> ignore
    }
    @sf.hover_ground_node(b)
    b.box(fn(sq) {
      @sf.style_node(sq, fn() { browser_count_square }, in_row=true)
      sq.shapes(By(fn() { browser_count_square_shapes(@sf.theme().p.text, @sf.radii.sm) })) |> ignore
      @sf.mark_words_node(sq, fn() { "\{count()}" }, fn() { browser_count_words }) |> ignore
    })
    |> ignore
  })
  @sf.tip_node(pg.tips, b, label) |> ignore
  // (asked from elsewhere, a fixture's: opened as it is made)
  screen_asked(b, pg, ["tabs"], fn(_) { open(b) })
}

///|
/// Closed 20×20 rounded-square vector outline (outer radius `outer_r`, 1.5pt stroke inset by 0.75pt) drawn as
/// `kind == 11` shapes so adaptive liquid glass inverts the frame together with its count glyph and `corner_faults`
/// treats it as an icon rather than a nested card.
fn browser_count_square_shapes(color : Int64, outer_r : Double) -> Array[@ui.Shape] {
  let lo = 0.75
  let hi = 19.25
  let r = if outer_r - 0.75 > 0.5 { outer_r - 0.75 } else { 0.5 }
  let c1 = 0.9238795325112867
  let s1 = 0.3826834323650898
  let d = 0.7071067811865476
  let pts : Array[Double] = []
  let push_arc = fn(cx : Double, cy : Double, dirs : Array[(Double, Double)]) {
    for dir in dirs {
      pts.push(cx + r * dir.0)
      pts.push(cy + r * dir.1)
    }
  }
  push_arc(hi - r, lo + r, [(0.0, -1.0), (s1, -c1), (d, -d), (c1, -s1), (1.0, 0.0)])
  push_arc(hi - r, hi - r, [(1.0, 0.0), (c1, s1), (d, d), (s1, c1), (0.0, 1.0)])
  push_arc(lo + r, hi - r, [(0.0, 1.0), (-s1, c1), (-d, d), (-c1, s1), (-1.0, 0.0)])
  push_arc(lo + r, lo + r, [(-1.0, 0.0), (-c1, -s1), (-d, -d), (-s1, -c1), (0.0, -1.0)])
  [@ui.shape_of([(pts, true)], stroke=color, width=1.5)]
}

///|
/// The tabs' panel (tabs_button's): 新标签页 where a tab is added, then each tab, the one shown ticked; 关闭此标签页 under
/// them when the current tab is closable.
fn tabs_node(v : @view.View, s : ScreenSess, u : ScreenUi, done : () -> Unit, close : () -> Unit) -> Unit {
  // (made again as the view's state or the station's tabs change)
  let tabs = fn() {
    s.said.get() |> ignore
    view_tabs(s)
  }
  let current_closable = fn() {
    let (all, _) = tabs()
    match all.search_by(fn(t) { t.current }) {
      Some(i) => all[i].close is Some(_)
      None => false
    }
  }
  @sf.panel_group_node(v, fn() { "" }, fn(g) {
    g.show(at_once=true, fn() { tabs().1 }, fn(n) {
      @sf.panel_row_node(
        n,
        fn() { @sf.t("web-pages.screen.newTab") },
        fn() {
          done()
          tab_do(s, u, Add, close)
        },
        icon=fn() { "plus" },
      )
    })
    // (each by what it shows: its key, words, note and whether it is the one shown; what pressing it does looked up as
    // it is pressed)
    g.each(at_once=true, fn() { tabs().0.map(fn(t) { (t.key, t.words, t.note, t.current) }) }, fn(t) { t.0 }, fn(row, t) {
      @sf.panel_row_node(
        row,
        fn() { t.get().1 },
        fn() {
          done()
          let key = t.untracked().0
          match @signals.untracked(tabs).0.search_by(fn(x) { x.key == key }) {
            Some(i) => tab_do(s, u, @signals.untracked(tabs).0[i].press, close)
            None => ()
          }
        },
        icon=fn() { if browser_shown(s) { "web" } else if t.get().0 == "screen" { "monitor" } else { "square" } },
        note=fn() { if browser_shown(s) { t.get().2 } else { "" } },
        end=if t.untracked().3 { "check" } else { "" },
      )
    })
  })
  // (the page's address copied, or sent to the chat open; a closable tab closed)
  v.show(at_once=true, fn() { s.said.get() |> ignore; address_shown(s) != "" || current_closable() }, fn(f) {
    @sf.panel_group_node(f, fn() { "" }, fn(g) {
      g.show(at_once=true, fn() { s.said.get() |> ignore; address_shown(s) != "" }, fn(ub) {
        @sf.panel_row_node(
          ub,
          fn() { @sf.t("web-pages.remote.copyUrl") },
          fn() {
            let url = address_shown(s)
            if url != "" {
              @ui.clipboard_set(url)
              @sfbase.toast_later(@sf.t("web-pages.remote.urlCopied"))
            }
            done()
          },
          icon=fn() { "copy" },
        )
        @sf.panel_row_node(
          ub,
          fn() { @sf.t("web-pages.remote.sendUrlToChat") },
          fn() {
            let url = address_shown(s)
            if url != "" {
              send_url_to_open_chat(s.src, url)
            }
            done()
          },
          icon=fn() { "send" },
        )
      })
      g.show(at_once=true, fn() { current_closable() }, fn(cl) {
        @sf.panel_row_node(
          cl,
          fn() { @sf.t("web-pages.screen.closeTabFull") },
          fn() {
            done()
            close_tab(s, u, s.screen, browser_tabs_of(s).1, close)
          },
          icon=fn() { "close" },
          danger=true,
        )
      })
    })
  })
}

///|
/// A new tab (＋, ⌘T): there at once on its blank page, its address bar taking the keys, while the station makes it.
fn new_tab_from(s : ScreenSess, u : ScreenUi) -> Unit {
  let listed = browser_tabs_of(s).1.map(fn(t) { text(Some(t), "id") })
  let next = @settings.new_browser_tab(s.src.call, s.station, listed, failed_said(@sf.t("web-pages.screen.openBrowserWhat")))
  let nu = screen_ui(screen_key(s.station, next))
  nu.address_asked.set(nu.address_asked.untracked() + 1)
  switch_screen_to(s, u, next, "", false)
}

///|
/// Tab `id` closed (its ×, ⌘W): where it is the one shown, the one after it is shown in its place (else the one
/// before; none left, the viewer closes), as a browser does.
fn close_tab(s : ScreenSess, u : ScreenUi, id : String, tabs : Array[Json], close : () -> Unit) -> Unit {
  let p : Map[String, Json] = { "station": Json::string(s.station), "screen": Json::string(id) }
  (s.src.call)("screen.close", Json::object(p), failed_said(@sf.t("web-pages.screen.closeTabWhat")))
  if id != s.screen {
    return
  }
  let at = tabs.search_by(fn(t) { text(Some(t), "id") == id }).unwrap_or(-1)
  let rest = tabs.filter(fn(t) { text(Some(t), "id") != id })
  if rest.is_empty() {
    close()
    return
  }
  let next = rest[if at >= 0 && at < rest.length() { at } else { rest.length() - 1 }]
  switch_screen_to(s, u, text(Some(next), "id"), text(Some(next), "title"), false)
}

///|
/// ← → ⟳: asked of the station for the tab shown, what failed said.
fn browser_act(s : ScreenSess, call : String, what : String) -> Unit {
  let p : Map[String, Json] = { "station": Json::string(s.station), "screen": Json::string(s.screen) }
  (s.src.call)(call, Json::object(p), failed_said(what))
}

///|
/// A browser's own keys (⌘ or Ctrl with L, T, W, R, [ and ]) on a tab of the station's browser: what they do here, at
/// their key-down; true where `code` is one of them (its keys not sent to the page).
fn browser_key(s : ScreenSess, u : ScreenUi, code : String, mods : Int, down : Bool) -> Bool {
  if !browser_shown(s) || (mods & (mod_meta | mod_ctrl)) == 0 || (mods & mod_alt) != 0 {
    return false
  }
  let act : String? = match code {
    "KeyL" | "KeyR" | "BracketLeft" | "BracketRight" if flag(s.state, "openUrl") => Some(code)
    "KeyT" if view_tabs(s).1 => Some(code)
    "KeyW" if view_tabs(s).0.iter().any(fn(t) { t.current && t.close is Some(_) }) => Some(code)
    _ => None
  }
  match act {
    Some(key) => {
      if down {
        browser_key_do(s, u, key)
      }
      true
    }
    None => false
  }
}

///|
/// What a browser's key (browser_key's) does.
fn browser_key_do(s : ScreenSess, u : ScreenUi, code : String) -> Unit {
  match code {
    "KeyL" => u.address_asked.set(u.address_asked.untracked() + 1)
    "KeyR" => browser_act(s, "screen.reload", @sf.t("web-pages.screen.reloadWhat"))
    "BracketLeft" => browser_act(s, "screen.back", @sf.t("web-pages.screen.backWhat"))
    "BracketRight" => browser_act(s, "screen.forward", @sf.t("web-pages.screen.forwardWhat"))
    "KeyT" => tab_do(s, u, Add, u.close_page)
    "KeyW" => tab_do(s, u, Close(s.screen), u.close_page)
    _ => ()
  }
}

///|
/// What failed of a call said as a toast (`what` it was meant to do, and why), as screen_act's.
fn failed_said(what : String) -> (Result[Json, Json]) -> Unit {
  fn(r) {
    match r {
      Ok(_) => ()
      Err(e) => @sfbase.toast_later(@sf.t("android-misc.act.failed", args=[("what", what), ("error", error_words(e))]))
    }
  }
}
