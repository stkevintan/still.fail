// A station's card, from a chat's agent: whether it
// is up and what its agents do, its machine and network at a glance, and where to go on: its files where it lends some,
// its page.

///|
/// The card of the station at `address` (`ws/station`) over the page: the library's panel, titled its name, opened
/// `from` what was pressed (its tag in a chat's bar: a sheet with touch short of Large, else beside it), what it holds
/// nodes of the window's tree made once as it opens (@sf.panel_nodes), with the frame's core (panels_core: as it is
/// said, where it was put up before it was, a fixture's).
pub fn open_station_peek(address : String, from~ : @sf.Anchor, offline_note? : () -> String = fn() { "" }) -> Unit {
  @sf.panel_nodes(
    "",
    fn(v, close) {
      // (with the frame's core as it is said: made with it as one comes (put up before it was said: coming in then, as
      // anything coming down a column does), made again with another workspace's as that one is said; none, nothing)
      v.pick(fn() { panels_core.get().map(fn(p) { p.0 }) }, fn(b, workspace) {
        match (workspace, panels_core_as_is()) {
          (Some(_), Some(core)) => station_peek_node(b, core, address, close, offline_note)
          _ => ()
        }
      })
    },
    from~,
    live=fn() {
      match panels_core_now() {
        Some(core) => (peek_name(core, address), "", "")
        None => ("", "", "")
      }
    },
  )
}

///|
/// Its head as an agent card's: its mark's square and its name, 10 apart, in their middle.
// kept across runs: a value (no field of it changes)
let peek_part_head : @ui.Style = @ui.css("row w=Full gap=S2_5 align=ACenter")

///|
/// Its mark's square: 28, the neutral ground, its mark in its middle (an agent card's mark's: agent_mark's tile).
// kept across runs: a value (no field of it changes)
let peek_part_square : @ui.Style = @ui.css("w=S7 h=S7 bg=Neutral align=ACenter justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let peek_part_name : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Fg, wrap=false, w=Cut)

///|
/// Where it stands, as an agent card's: a dot 6 across 6 down, 6 before its words, 2 in.
// kept across runs: a value (no field of it changes)
let peek_part_status : @ui.Style = @ui.css("row w=Full gap=S1_5 align=AStart pl=S0_5")

///|
// kept across runs: a value (no field of it changes)
let peek_part_dot_room : @ui.Style = @ui.css("pt=S1_5")

///|
// kept across runs: a value (no field of it changes)
let peek_part_dot : @ui.Style = @ui.css("w=S1_5 h=S1_5 radius=Full")

///|
// kept across runs: a value (no field of it changes)
let peek_part_words : @ui.TextStyle = @ui.text_style(size=Ui, color=Fg, w=Full, max_lines=3)

///|
/// The hover card's: its words 10 in from its padding, 8 apart, its rows at its padding.
// kept across runs: a value (no field of it changes)
let peek_card : @ui.Style = @ui.css("w=Full")

///|
// kept across runs: a value (no field of it changes)
let peek_card_words : @ui.Style = @ui.css("w=Full p=S2_5 gap=S2")

///|
/// Its dot, its mark and its name in a line, 8 apart.
// kept across runs: a value (no field of it changes)
let peek_card_head : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter")

///|
let peek_card_mark : Double = 16.0

///|
// kept across runs: a value (no field of it changes)
let peek_card_name : @ui.TextStyle = @ui.text_style(size=Ui, weight=Semibold, color=Fg, wrap=false, w=Cut)

///|
/// The station's name, as the workspace's stations say it once they are read: none before (its id is no name, not
/// said in its place meanwhile); its id only where they are read and give it none (not among them, or unnamed).
fn peek_name(core : Core, address : String) -> String {
  peek_name_of((core.topic)("stations", { "scope": str(peek_scope(address)) }).get().value, address)
}

///|
/// The station's name (peek_name's), of the workspace's stations as the core says them (`stations`).
fn peek_name_of(stations : Json?, address : String) -> String {
  guard stations is Some(_) else { return "" }
  match text(peek_station_of(stations, address), "name") {
    "" => station_name(address)
    name => name
  }
}

///|
/// The card's body: its words, then its rows, 10 apart.
// kept across runs: a value (no field of it changes)
let peek_body : @ui.Style = @ui.css("w=Full gap=S2_5")

///|
/// Its rows, as far apart as its words and them (peek_body).
// kept across runs: a value (no field of it changes)
let peek_rows : @ui.Style = @ui.css("w=Full gap=S2_5")

///|
/// Its words, 10 apart.
// kept across runs: a value (no field of it changes)
let peek_words : @ui.Style = @ui.css("w=Full gap=S2_5")

///|
/// What it says of itself, and that it is offline (13 on 18, muted).
// kept across runs: a value (no field of it changes)
let peek_said : @ui.TextStyle = @sf.meta.then(@sf.full_words)

///|
/// A station down, why and what comes of it, as the core says it: down for a security mode, why (its `blocked`); gone
/// for its update, that it comes back by itself (its first problem's words); else how to bring it back.
fn peek_down(s : Json?) -> String {
  let blocked = text(s, "blocked")
  if blocked != "" {
    return blocked
  }
  match field(s, "problems") {
    Some(Array([first, ..])) if text(Some(first), "key") == "updating" => text(Some(first), "text")
    _ => fill("android-settings.stations.offline", [("app", @sf.product())])
  }
}

///|
/// The tab of each station's browser a person looked at last, here (the viewer says it as it shows one): what 浏览器
/// opens to next.
let browser_tabs_seen : Map[String, String] = Map([])

///|
/// The viewer shows tab `screen` of station `address`'s browser: 浏览器 opens to it next.
pub fn browser_tab_seen(address : String, screen : String) -> Unit {
  if browser_tabs_seen.get(address) != Some(screen) {
    browser_tabs_seen[address] = screen
  }
}

///|
/// How many tabs this run made (one more each): a new tab's id is worked out of it with the station's tabs.
let tabs_made : Ref[Int] = Ref(0)

///|
/// A new tab of station `address`'s browser (＋, ⌘T, 浏览器 with none open): its id made here (`u_` and 12 hex digits,
/// a hash of the station, the tabs it has (`listed`, their screen ids: none of them again) and this run's count),
/// asked of the station by it (`screen.openBrowser` with `id`), and its
/// screen (`browser:<id>`) answered at once, so its view opens as it is pressed, the core listing it till its station
/// does (the user, 2026-11-13: 「会等 station 开了这边才开，点个按钮要半天」).
pub fn new_browser_tab(
  call : (String, Json, (Result[Json, Json]) -> Unit) -> Unit,
  address : String,
  listed : Array[String],
  done : (Result[Json, Json]) -> Unit,
  url? : String = "",
) -> String {
  let digits = "0123456789abcdef"
  let made = fn() {
    tabs_made.val += 1
    let n = @ui.stable_hash(address + "|" + listed.join(",") + "|\{tabs_made.val}")
    let hex = StringBuilder()
    for i = 11; i >= 0; i = i - 1 {
      hex.write_char(digits[((n >> (i * 4)) & 0xFL).to_int()].unsafe_to_char())
    }
    "u_" + hex.to_string()
  }
  let mut id = made()
  while listed.contains("browser:" + id) {
    id = made()
  }
  call("screen.openBrowser", obj([("station", str(address)), ("url", str(url)), ("id", str(id))]), done)
  "browser:" + id
}

///|
/// 浏览器 (the station's page, its card's 屏幕, a chat's screens): the station's browser opened at once on the tab looked
/// at last, else its newest, else a new one; never a question first.
pub fn open_station_browser(core : Core, address : String, from? : @sf.Anchor = Unanchored) -> Unit {
  ignore(from)
  let listed = items((core.topic)("screens", { "station": str(address) }).get().value, "screens").filter(fn(sc) {
    flag(Some(sc), "userTab") || text(Some(sc), "id").has_prefix("browser:u_")
  }).map(fn(sc) { text(Some(sc), "id") })
  let screen = match browser_tab_to_open(address, listed) {
    Some(screen) => screen
    None =>
      new_browser_tab(core.call, address, listed, fn(r) {
        if r is Err(e) {
          (core.say)(fill("android-misc.act.failed", [("what", tr("web-pages.screen.openBrowserWhat")), ("error", error_text(e))]))
        }
      })
  }
  (core.open_screen)(address, screen)
}

///|
/// Of station `address`'s tabs (`listed`, its screen ids in the order opened), the one its browser opens to: the one looked
/// at last, else the newest; none where it has none.
pub fn browser_tab_to_open(address : String, listed : Array[String]) -> String? {
  let seen = browser_tabs_seen.get(address).unwrap_or("")
  if seen != "" && listed.contains(seen) {
    Some(seen)
  } else {
    listed.last()
  }
}

///|
/// Its screens as its card's 屏幕 offers them (`screens`, the core's for it): its browser (a person's own pages there, one
/// item opening it), agent pages, and physical/simulator screens; none, why (the core's note) or that it has none, not to be chosen.
fn peek_screen_items(core : Core, address : String, screens : Json?, close : () -> Unit) -> Array[@sf.MenuItem?] {
  let screen_items : Array[@sf.MenuItem?] = []
  let user_tabs : Array[Json] = []
  let agent_tabs : Array[Json] = []
  let other_screens : Array[Json] = []
  for screen in items(screens, "screens") {
    let sc = Some(screen)
    if flag(sc, "userTab") || text(sc, "id").has_prefix("browser:u_") {
      user_tabs.push(screen)
    } else if text(sc, "kind") == "browser" {
      agent_tabs.push(screen)
    } else {
      other_screens.push(screen)
    }
  }
  let can_open = flag(screens, "browser") && flag(screens, "control")
  let has_user = !user_tabs.is_empty() || can_open
  // (its browser one part, as a chat's 远程 menu has it: the pages an agent drives in it and the way to its own tabs,
  // under 浏览器. Headed only while an agent drives pages, which need it said what they are: else each part is one kind
  // of row its icon tells, and a heading 屏幕 would only say again the row this menu came out of)
  let headed = !agent_tabs.is_empty() && !other_screens.is_empty()
  if !other_screens.is_empty() {
    if headed {
      screen_items.push(Some(@sf.menu_item_of(tr("android-misc.screen.section"), heading=true, fn() { })))
    }
    for screen in other_screens {
      let sc = Some(screen)
      let icon = if text(sc, "kind") == "simulator" { "phone" } else { "monitor" }
      screen_items.push(Some(@sf.menu_item_of(text(sc, "title"), icon~, fn() {
        close()
        (core.open_screen)(address, text(sc, "id"))
      })))
    }
  }
  if has_user || !agent_tabs.is_empty() {
    if !screen_items.is_empty() {
      screen_items.push(None)
    }
    if headed {
      screen_items.push(Some(@sf.menu_item_of(tr("web-pages.screen.browser"), heading=true, fn() { })))
    }
    for screen in agent_tabs {
      let sc = Some(screen)
      screen_items.push(Some(@sf.menu_item_of(text(sc, "title"), icon="web", fn() {
        close()
        (core.open_screen)(address, text(sc, "id"))
      })))
    }
    if has_user {
      screen_items.push(Some(@sf.menu_item_of(tr("web-pages.screen.openBrowserRow"), icon="web", fn() {
        close()
        open_station_browser(core, address)
      })))
    }
  }
  if (core.terminals_on)() {
    let terms = (core.topic)("terminals", { "station": str(address) }).get().value
    if flag(terms, "known") && !flag(terms, "outdated") {
      let open_terms = items(terms, "terminals").filter(fn(t) { !flag(Some(t), "ended") })
      let can_term = flag(terms, "open")
      if !open_terms.is_empty() || can_term {
        if !screen_items.is_empty() {
          screen_items.push(None)
        }
        for t in open_terms {
          let tv = Some(t)
          let tid = text(tv, "id")
          let cwd = text(tv, "cwd")
          let parts = cwd.split("/").collect().filter(fn(p) { p.length() > 0 })
          let label = match parts.last() { Some(last) => last.to_owned(); None => if cwd == "" { tr("web-pages.remote.openTerminal") } else { cwd } }
          screen_items.push(Some(@sf.menu_item_of(label, icon="terminal", fn() {
            close()
            (open_terminal_of.val)(address, tid, cwd)
          })))
        }
        if can_term {
          screen_items.push(Some(@sf.menu_item_of(tr("web-pages.remote.openTerminal"), icon="terminal", fn() {
            close()
            (open_terminal_of.val)(address, "new", "")
          })))
        }
      }
    }
  }
  if screen_items.is_empty() {
    let note = text(screens, "note")
    screen_items.push(Some(@sf.menu_item_of(if note == "" { tr("web-pages.screen.none") } else { note }, disabled=true, fn() { })))
  }
  screen_items
}

///|
/// Its files as its card's 文件 offers them (`drive`, its overview's): all of them; where it lends only some folders,
/// under a heading each of those. Pressed, opened (the card closed first).
fn peek_file_items(core : Core, address : String, drive : Json?, close : () -> Unit) -> Array[@sf.MenuItem?] {
  let files : Array[@sf.MenuItem?] = [Some(@sf.menu_item_of(tr("web-pages.drive.viewAll"), icon="folder", fn() {
    close()
    (core.open_drive)(address)
  }))]
  let roots = items(drive, "roots")
  if !flag(drive, "anywhere") && !roots.is_empty() {
    files.push(None)
    files.push(Some(@sf.menu_item_of(tr("web-pages.drive.pinnedFolders"), heading=true, fn() { })))
    for root in roots {
      let r = Some(root)
      files.push(Some(@sf.menu_item_of(text(r, "name"), icon="folder", fn() {
        close()
        (core.open_folder)(address, text(r, "path"))
      })))
    }
  }
  files
}

///|
/// The machine in brief (StationFigures with `peek`), faded while it is reconnecting (as last heard).
// kept across runs: a value (no field of it changes)
let peek_figures_box : @ui.Style = @ui.css("w=Full")

///|
/// What is left of it in the allowance's boxes: 4 over and under them.
// kept across runs: a value (no field of it changes)
let peek_meters_room : @ui.Style = @ui.css("w=Full py=S1")

///|
/// 20 high, 8 apart (MeterChips).
// kept across runs: a value (no field of it changes)
let peek_meters : @ui.Style = @ui.css("row w=Full h=S5 gap=S2 align=ACenter")

///|
/// It said what this core cannot read: no reading is on its way, so nothing shows as if one were.
fn unreadable(s : Json?) -> Bool {
  items(s, "problems").iter().any(fn(p) { text(Some(p), "key") == "incompatible" })
}

///|
/// Its network 6 under the boxes.
// kept across runs: a value (no field of it changes)
let peek_net : @ui.Style = @ui.css("w=Full pt=S1_5")

///|
/// How this device reaches a station of the workspace's `stations`: `direct`,
/// `relay`, `waiting` (coming back, or a way still being chosen), `offline`, or "" while there is no reading of it.
/// One answer wherever a station's dot says it: its tile in a chat's bar, its card.
pub fn station_via(s : Json?) -> String {
  if !flag(s, "online") {
    "offline"
  } else if flag(s, "reconnecting") {
    "waiting"
  } else {
    match text(field(s, "way"), "via") {
      "direct" => "direct"
      "relay" => "relay"
      "choosing" => "waiting"
      _ => ""
    }
  }
}

///|
/// The card's body in node `v` (the panel's, made once as it opens), with `core`: what the station says of itself and,
/// up, its machine in brief (else why it is down), as its stations say it now; then where to go on, the panel's rows at
/// a dialog's foot (concentric with its foot corners there), their words on its line. Each part followed as what it
/// shows changes.
fn station_peek_node(v : @view.View, core : Core, address : String, close : () -> Unit, offline_note : () -> String) -> Unit {
  let stations = (core.topic)("stations", { "scope": str(peek_scope(address)) })
  let screens = (core.topic)("screens", { "station": str(address) })
  let net = (core.topic)("stationNet", { "station": str(address) })
  let s = fn() { peek_station_of(stations.get().value, address) }
  v.box(fn(b) {
    @sf.style_node(b, fn() { peek_body })
    b.show(fn() { s() is Some(_) || offline_note() != "" }, fn(w) {
      // (its words as far in as its rows' words: a dialog's, a small panel's)
      @sf.style_node(w, fn() { peek_words.then(@sf.panel_words_in_node(w)) })
      w.show(fn() { text(s(), "summary") != "" }, at_once=true, fn(sm) {
        @sf.words_node(sm, fn() { text(s(), "summary") }, fn() { peek_said }) |> ignore
      })
      // (what its agents' processes are is on its page, a tap away)
      w.pick(fn() { flag(s(), "online") && offline_note() == "" }, fn(x, online) {
        if online {
          peek_figures_node(x, core, s, fn() { station_net_of(net.get().value) })
        } else {
          @sf.words_node(x, fn() {
            let note = offline_note()
            if note != "" { note } else { peek_down(s()) }
          }, fn() { peek_said }) |> ignore
        }
      })
    })
    // where to go on: the panel's rows, their grounds out across its sides, their words on its line (in a dialog, at
    // its foot: concentric with its foot corners)
    @sf.dialog_foot_rows_node(b, peek_rows, fn(r) {
      @sf.submenu_row_node(r, fn() { tr("android-misc.screen.section") }, fn() {
        peek_screen_items(core, address, screens.get().value, close)
      })
      r.show(fn() { field(field(s(), "overview"), "drive") is Some(Object(_)) }, fn(d) {
        @sf.submenu_row_node(d, fn() { tr("android-misc.drive.title") }, fn() {
          peek_file_items(core, address, field(field(s(), "overview"), "drive"), close)
        })
      })
      @sf.panel_row_node(r, fn() { tr("android-chat.station.details") }, fn() {
        close()
        (core.push)(Station(address))
      }, end="panel-open", plain=true)
    })
  })
  |> ignore
}

///|
/// The workspace of station `address` (`ws/station`).
fn peek_scope(address : String) -> String {
  match address.find("/") {
    Some(i) => address.exact_view(end=i).to_owned()
    None => address
  }
}

///|
/// The station of `address` in the workspace's stations as the core says them (`stations`), once they are read.
fn peek_station_of(stations : Json?, address : String) -> Json? {
  match stations {
    Some(Array(a)) =>
      for x in a {
        if text(Some(x), "station") == address {
          return Some(x)
        }
      }
    _ => ()
  }
  None
}

///|
/// How this device reaches a station now, as its `stationNet` view says it (station_net's): none before a connection of
/// its own is open.
fn station_net_of(v : Json?) -> Json? {
  match v {
    Some(Object(_)) => v
    _ => None
  }
}

///|
/// The machine in brief in `p`, station `s` and its network `net` as they are now: what is
/// left of it in the allowance's boxes (in their bones until it is read, none where it said what this core cannot
/// read), its network under them (in its bones until it is read); faded while it is reconnecting.
fn peek_figures_node(p : @view.View, core : Core, s : () -> Json?, net : () -> Json?) -> Unit {
  // (its chips as this device says a CPU: idle or busy, meters_said; told again only as what they say changes)
  let busy = @signals.computed(fn(_) { cpu_busy(core) })
  let meters = @signals.computed(fn(_) { meters_said(items(field(s(), "host"), "meters"), busy.get()) })
  p.box(fn(f) {
    @sf.style_node(f, fn() { peek_figures_box })
    f.alpha(By(fn() { if flag(s(), "reconnecting") { peek_faded } else { 1.0 } })) |> ignore
    f.box(fn(m) {
      @sf.style_node(m, fn() { peek_meters_room })
      // (read: its chips; not yet: made-up ones in their bones; what this core cannot read: none)
      let way = fn() {
        match field(s(), "host") {
          Some(Object(_)) => 1
          _ => if unreadable(s()) { 0 } else { 2 }
        }
      }
      // (one in the other's place: the chips read in their bones' place, from as tall as those were)
      m.pick(way, fn(x, k) {
        match k {
          1 =>
            x.box(fn(r) {
              @sf.style_node(r, fn() { peek_meters })
              @sf.meter_line_node(r, fn() { meters.get() }, in_row=true)
            })
            |> ignore
          2 => sample_meters_node(x)
          _ => ()
        }
      })
    })
    |> ignore
    f.box(fn(n) {
      @sf.style_node(n, fn() { peek_net })
      // (the room under the 6, the bars laid over that alone)
      n.box(fn(w) {
        @sf.style_node(w, fn() { @sf.full_width })
        // (until it is read, a made-up one's in its bones)
        w.pick(fn() { net() is Some(_) }, fn(x, read) {
          if read {
            station_net_line_node(x, net, look=Peek, egress=fn() { text(field(s(), "host"), "egressText") })
          } else {
            @sf.waiting_node(x, fn(b) { station_net_line_node(b, fn() { None }, look=Peek) })
          }
        })
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// How faint the machine in brief is while it is reconnecting.
let peek_faded : Double = 0.45

///|
/// A machine's CPU, memory and disk made up, in their bones, in `p`.
fn sample_meters_node(p : @view.View) -> Unit {
  @sf.waiting_node(p, fn(b) {
    b.box(fn(r) {
      @sf.style_node(r, fn() { peek_meters })
      for n in [50, 60, 40] {
        @sf.fill_chip_node(r, fn() { 100 - n }, fn() { "" }, fn() { @sf.sample_words(1) }, fn() { @sf.sample_words(3) }) |> ignore
      }
    })
    |> ignore
  })
}
