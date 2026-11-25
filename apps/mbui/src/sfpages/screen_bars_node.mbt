// What a screen's page has round its picture, as nodes of the window's tree (screen_view.mbt's screen_node arranges
// them): the bar over it upright, the compact row beside a chat, the viewer's bar with keyboard and mouse, the rail
// sideways, 全屏's tools folded into one button over its corner, the foot's actions and the keys row under it, the keys
// row floating over its foot while the keyboard is up, 接管 while someone else drives it, and the mouse's two buttons
// floating at its foot. Each shows what the view's state and what was done here say as that is told; each press does
// its work in its handler.

///|
/// A round button in `parent` (`side`, 40 by default, its icon 20 in the ink: @sf.tool_round_node's), its name `label` read out and its tip;
/// the ink at 10% under it while `lit` (the keyboard up, 控制, 全屏), the hover's under the hand; pressed, `press`. The
/// node (what a panel it opens stands beside). In a pane's own bar (ScreenPage's `tab_pads`, 远程's), a bar's key: 32,
/// its icon 16, its corner the window's where it stands there (sf's bar_keys_link), as a page's bar's keys.
fn screen_round_node(
  parent : @view.View,
  pg : ScreenPage,
  icon : () -> String,
  label : () -> String,
  press : (@view.View) -> Unit,
  lit? : () -> Bool = fn() { false },
  side? : Double = round_side,
) -> @view.View {
  @sf.action_box_node(parent, label, on=lit, press, fn(v) {
    let pane = pg.tab_pads is Some(_) && side == round_side
    let side = if pane { round_bar_side } else { side }
    v
    .width(Is(Some(side)))
    .height(Is(Some(side)))
    .radius(
      if pane {
        By(fn() {
          match @sf.bar_keys_link() {
            Some(link) => link.radius(@ui.tree_corner_roots_now())
            None => side / 2.0
          }
        })
      } else {
        Is(side / 2.0)
      },
    )
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .ground(By(fn() { if lit() { @sf.alpha(@ui.tree_theme().color(Fg), 0.1) } else { 0L } }))
    |> ignore
    @sf.hover_ground_node(v, lit=Some(fn() { v.pointed() || v.pressed() || v.focus_shown() }))
    @sf.icon_node(v, "", if pane { round_bar_icon } else { round_icon }, By(fn() { @ui.tree_theme().color(Fg) }), name_now=icon)
    |> ignore
    @sf.tip_node(pg.tips, v, label) |> ignore
  })
}

///|
/// A panel asked of the page by what is outside it (a fixture's, a test's: as if pressed), `keys` the ones `from` opens,
/// opened beside `from` as it is made or as it is asked, at that moment (what it stands beside laid out by then).
fn screen_asked(from : @view.View, pg : ScreenPage, keys : Array[String], open : (String) -> Unit) -> Unit {
  let u = pg.u
  from.reacts(fn() { u.asked_panel.get() }, fn(asked) {
    if keys.contains(asked) {
      u.asked_panel.set("")
      from.at_moment(from.cause_at(), fn() { open(asked) }) |> ignore
    }
  })
}

///|
/// 控制中心 as a round button (the bar's, the rail's, the folded tools') in `parent`: pressed, its panel beside it; or a
/// simulator's 日志 or 重启 App where a fixture asked for them.
fn center_button_node(parent : @view.View, pg : ScreenPage) -> Unit {
  let b = screen_round_node(parent, pg, fn() { "sliders" }, fn() { @sf.t("web-pages.screen.panel") }, fn(b) {
    center_open(pg, Node(b), "center")
  })
  screen_asked(b, pg, ["center", "logs", "apps"], fn(asked) { center_open(pg, Node(b), asked) })
}

///|
/// 控制中心's panel beside what opened it (`from`); a fixture's asked `logs` or `apps`, a simulator's panel in its place.
fn center_open(pg : ScreenPage, from : @sf.Anchor, asked : String) -> Unit {
  let s = pg.s
  let u = pg.u
  if asked == "logs" {
    debug_logs_open(s, u, from)
    return
  }
  if asked == "apps" {
    debug_apps_open(s, u, from)
    return
  }
  let open = fn() {
    screen_panel_toggle(u, "center", fn() {
      @sf.panel_nodes(@sf.t("web-pages.screen.panel"), fn(v, done) { center_node(v, s, u, from, pg.close, done) }, from~, side=screen_panel_side(), focus=false)
    })
  }
  // (pressed again while it waits: given up, nothing opened; up already: closed at once)
  match center_wait.val {
    Some(w) if w.waiting() => {
      center_wait.val = None
      w.give_up()
      return
    }
    _ => center_wait.val = None
  }
  if screen_panel_on(u, "center") {
    open()
    return
  }
  // (once what it reads as it is first made is answered, the screen as it was meanwhile: how its station is reached,
  // read while the screen is live (screen_net), comes with it, never changing its 连接 line after it came)
  let asks : Array[(String, Map[String, Json])] = [
    ("prefs", {}),
    ..if @signals.untracked(fn() { s.phase() == "live" }) {
      [("stationNet", { "station": Json::string(s.station) })]
    } else {
      []
    },
  ]
  let w = @sfbase.present_answered(s.src, asks, open)
  if w.waiting() {
    center_wait.val = Some(w)
  }
}

///|
/// What waits for 控制中心's first read, pressed (center_open): one at a time, given up as it is pressed again, as the
/// page's panels close (screen_panels_close) and between runs (pages.mbt reset).
// kept across runs: put back by reset
let center_wait : Ref[@sfbase.PressWait?] = Ref(None)

///|
/// 按键 as a round button (the foot's, the rail's, the folded tools') in `parent`: pressed, its panel beside it; on while
/// it is open. Only while driving a screen that is no simulator's (its device's buttons are beside its picture).
fn keys_button_node(parent : @view.View, pg : ScreenPage) -> Unit {
  let s = pg.s
  let u = pg.u
  parent.show(at_once=true, fn() { s.driving_now() && !s.simulator() }, fn(k) {
    let b = screen_round_node(k, pg, fn() { "keycap" }, fn() { @sf.t("web-pages.screen.keysPanel") }, fn(b) {
      keys_open(s, u, Node(b))
    }, lit=fn() {
      screen_panel_on_now(u, "keys")
    })
    screen_asked(b, pg, ["keys"], fn(_) { keys_open(s, u, Node(b)) })
  })
}

///|
/// 麦克风 as a round button in `parent`, lit while this device's microphone is shared into the screen's virtual one:
/// there only while something on the screen records it or it is shared (ScreenSess::mic_bar_shown), so a bar says
/// nothing of it otherwise (控制中心's tile switches it then); pressed, shared or no more.
fn mic_button_node(parent : @view.View, pg : ScreenPage, along_row? : Bool = false) -> Unit {
  let s = pg.s
  parent.show(along_row~, fn() { s.mic_bar_shown() }, fn(k) {
    screen_round_node(k, pg, fn() { s.mic_icon() }, fn() { s.mic_label() }, fn(_) { s.toggle_mic() }, lit=fn() {
      s.mic_on.get()
    })
    |> ignore
  })
}

///|
/// 只看/控制 as one round button (the rail's, the folded tools') in `parent`: the pointer while driving, an eye while
/// looking; where it may be chosen.
fn mode_button_node(parent : @view.View, pg : ScreenPage) -> Unit {
  let s = pg.s
  let u = pg.u
  let on = fn() {
    s.said.get() |> ignore
    s.controlling()
  }
  parent.show(at_once=true, fn() { s.said.get() |> ignore; s.choosable() }, fn(k) {
    screen_round_node(
      k,
      pg,
      fn() { if on() { "cursor" } else { "eye" } },
      fn() { @sf.t(if on() { "android-misc.screen.drive" } else { "android-misc.screen.look" }) },
      fn(_) { control_chosen(s, u, !s.controlling()) },
      lit=on,
    )
    |> ignore
  })
}

///|
/// Pasting the device's clipboard (where the station carries text or pictures) as a round button in `parent`, lit
/// while a paste goes.
fn paste_button_node(parent : @view.View, pg : ScreenPage) -> Unit {
  let s = pg.s
  let u = pg.u
  parent.show(at_once=true, fn() { s.said.get() |> ignore; s.pastes() }, fn(k) {
    screen_round_node(k, pg, fn() { "paste" }, fn() { @sf.t("android-misc.screen.paste") }, fn(_) { paste_asked(s, u) }, lit=fn() {
      s.pasting.get()
    })
    |> ignore
  })
}

///|
/// The keyboard as a round button in `parent`, lit while the keys go to the screen; while driving it.
fn keyboard_button_node(parent : @view.View, pg : ScreenPage) -> Unit {
  let s = pg.s
  parent.show(at_once=true, fn() { s.driving_now() }, fn(k) {
    screen_round_node(k, pg, fn() { "keyboard" }, fn() { @sf.t("android-misc.screen.keyboard") }, fn(_) { keyboard_toggled(pg) }, lit=fn() {
      pg.catching()
    })
    |> ignore
  })
}

///|
/// 全屏 (lit while it is) as a round button in `parent`.
fn full_button_node(parent : @view.View, pg : ScreenPage) -> Unit {
  let u = pg.u
  screen_round_node(
    parent,
    pg,
    fn() { "landscape" },
    fn() { @sf.t(if u.full.get() { "android-misc.screen.unfull" } else { "android-misc.screen.full" }) },
    // (lit, out of it; else as 控制中心's 全屏)
    fn(_) {
      if u.full.untracked() {
        screen_panels_close(u)
        screen_unfull(u)
      } else {
        full_asked(u)
      }
    },
    lit=fn() { u.full.get() },
  )
  |> ignore
}

///|
/// Its close as a round button in `parent`.
fn close_button_node(parent : @view.View, pg : ScreenPage) -> Unit {
  screen_round_node(parent, pg, fn() { "close" }, fn() { @sf.t("android-misc.screen.close") }, fn(_) { (pg.close)() }) |> ignore
}

///|
/// The screen's name (where `named`) and the core's line under it in `parent` (who else is on it; while another drives
/// it, who does is said with 接管, not twice), cut short where the bar's buttons leave them less.
fn screen_bar_words_node(parent : @view.View, pg : ScreenPage, named : Bool) -> Unit {
  let s = pg.s
  parent.box(fn(w) {
    @sf.style_node(w, fn() { screen_bar_words }, in_row=true)
    w.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
    if named {
      @sf.words_node(w, fn() { pg.said_title() }, fn() { screen_title_words }) |> ignore
    }
    let line = fn() {
      let st = s.state_now()
      if s.open_said() && !s.can_take_over() {
        text(st, "line")
      } else {
        ""
      }
    }
    w.show(at_once=true, fn() { line() != "" }, fn(l) { @sf.words_node(l, line, fn() { screen_line_words }) |> ignore })
  })
  |> ignore
}

///|
/// The view's tabs folded into one button counting them in `parent`, where it has them (a desktop's windows; a browser's
/// pages where its bar has no room for them).
fn tabs_count_node(parent : @view.View, pg : ScreenPage) -> Unit {
  let s = pg.s
  parent.show(at_once=true, fn() {
    s.said.get() |> ignore
    !view_tabs(s).0.is_empty()
  }, fn(k) { tabs_button_node(k, pg) })
}

///|
/// Upright (the user, 2026-11-13: 「连带着远程控制的 UI 一起重构」) in `p`: one row, close, then the screen's name and the
/// core's line (only looking, who else is on it), the view's tabs folded into a button counting them where it has them
/// (a desktop's windows), 控制中心 (只看, pasting, sending files, 全屏, how the view goes: all there); a tab of the
/// station's browser has ← and its address bar in its name's place (screen_browser.mbt). A panel's bar of its own: the
/// panel's close at its end, beside what it closes.
fn screen_top_bar_node(p : @view.View, pg : ScreenPage) -> Unit {
  let s = pg.s
  let u = pg.u
  u.narrow_bar = true
  p.box(fn(bar) {
    @sf.style_node(bar, fn() {
      match pg.own_bar {
        Some(own) => own
        None => if pg.in_tab { screen_bar_in_tabs } else { screen_bar }
      }
    })
    if !pg.in_tab {
      close_button_node(bar, pg)
    }
    bar.pick(at_once=true, fn() { browser_shown_now(s) }, fn(m, browser) {
      m.row(Is(true)).lines_up(Is(Some(Middle))).grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))).gap(Is(@ui.Space::S2.px())) |> ignore
      if browser {
        browser_seen(s)
        m.box(fn(t) {
          @sf.style_node(t, fn() { screen_bar_tools }, in_row=true)
          browser_tools_node(t, pg, narrow=fn() { true })
        })
        |> ignore
      } else {
        // (among a panel's tabs, the tab in front names it)
        screen_bar_words_node(m, pg, !pg.in_tab || pg.own_bar is Some(_))
        tabs_count_node(m, pg)
        // (driving with a finger: the trackpad or the finger itself, a press away, lit while it is the trackpad)
        m.show(at_once=true, fn() { @sf.soft_keyboard() && s.driving_now() && !s.simulator() }, fn(k) {
          screen_round_node(k, pg, fn() { "trackpad" }, fn() {
            @sf.t(if s.pad(s.src) { "web-pages.remote.touchPadShort" } else { "web-pages.remote.touchDirectShort" })
          }, fn(_) { pad_chosen(s, u, !s.pad(s.src)) }, lit=fn() { s.pad(s.src) })
          |> ignore
        })
      }
    })
    mic_button_node(bar, pg, along_row=true)
    bar.show(at_once=true, fn() { s.open_said() }, fn(k) { center_button_node(k, pg) })
    // (a panel's bar of its own: the panel's close at its end, beside what it closes, where the system has bars too:
    // among the chat's actions in them it read as another thing's; the user, 2026-11-06)
    if pg.own_bar is Some(_) {
      close_button_node(bar, pg)
    }
  })
  |> ignore
}

///|
/// With keyboard and mouse inside a chat's side panel in `p`: one row, no traffic-light indent, no `< 返回`, and (where
/// the panel's tab row stands above) no name or close of its own: a browser's controls, or the desktop's line, its
/// tabs, 组合键 while driving it; 控制中心. None while the view is not open, where the panel names it.
fn screen_tab_bar_node(p : @view.View, pg : ScreenPage) -> Unit {
  let s = pg.s
  let u = pg.u
  let narrow = fn() { view_narrow(p, u) }
  p.reacts(narrow, fn(n) { u.narrow_bar = n })
  // (a login screen opened until it is gone (`until_gone`) closes its side tab as soon as phase becomes "gone"; keep
  // its bar in place while the panel slides shut instead of yanking 48px out from over the stage mid-slide)
  let closing_gone = fn() {
    match u.at {
      Some(at) => at.until_gone && s.phase_now() == "gone"
      None => false
    }
  }
  p.show(at_once=true, fn() { s.open_said() || closing_gone() || pg.own_bar is Some(_) || pg.tab_pads is Some(_) }, fn(bar) {
    match (pg.own_bar, pg.tab_pads) {
      (Some(own), _) => @sf.style_node(bar, fn() { own })
      // (the pane's own bar (远程's): a page's height, its line's room under it, its keys as far in as the pane says,
      // its empty part dragging the window)
      (None, Some(pads)) => {
        @sf.style_node(bar, fn() { screen_pane_bar })
        bar
        .padding(By(fn() {
          let (start, end) = pads()
          (start, 0.0, end, 1.0)
        }))
        .moves_window(By(@ui.window_inset_now))
        |> ignore
      }
      (None, None) =>
        @sf.style_node(bar, fn() { if browser_shown_now(s) { screen_tab_browser_bar } else { screen_tab_status_bar } })
    }
    bar.pick(at_once=true, fn() { browser_shown_now(s) }, fn(m, browser) {
      m.row(Is(true)).lines_up(Is(Some(Middle))).grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))).gap(Is(@ui.Space::S2.px())) |> ignore
      if browser {
        browser_seen(s)
        m.box(fn(t) {
          @sf.style_node(t, fn() { screen_bar_tools }, in_row=true)
          browser_tools_node(t, pg, narrow~)
        })
        |> ignore
      } else {
        screen_bar_words_node(m, pg, pg.own_bar is Some(_))
        tabs_count_node(m, pg)
        // 组合键 while driving a desktop
        m.show(at_once=true, fn() { s.driving_now() && !s.simulator() }, fn(k) {
          let b = screen_round_node(k, pg, fn() { "keycap" }, fn() { @sf.t("web-pages.screen.combos") }, fn(b) {
            keys_open(s, u, Node(b), combos_only=true)
          }, lit=fn() {
            screen_panel_on_now(u, "keys")
          })
          ignore(b)
        })
      }
    })
    mic_button_node(bar, pg, along_row=true)
    // (a window of its own, where one takes it: beside 控制中心, as a chat's bar has it)
    if pg.on_window is Some(handed) {
      let page = fn() -> @sfbase.Page? { u.at.map(fn(at) { Screen(at) }) }
      bar.show(at_once=true, fn() { page().map_or(false, @sfbase.window_opens_for) }, fn(k) {
        screen_round_node(k, pg, fn() { "external" }, fn() { @sf.t("web-pages.chat.openInWindow") }, fn(_) {
          match page() {
            Some(p) => if @sfbase.open_window(p) { handed() }
            None => ()
          }
        })
        |> ignore
      })
    }
    bar.show(at_once=true, fn() { s.open_said() }, fn(k) { center_button_node(k, pg) })
    if pg.own_bar is Some(_) {
      close_button_node(bar, pg)
    }
  })
}

///|
/// Whether the link to the screen's station is poor now (its round trip slow, or a share of what goes lost: amber or
/// red): the viewer's bar says so then, and only then (its figures are 控制中心's). Read as the view's state is told.
fn net_poor(s : ScreenSess) -> Bool {
  let level = screen_link_level(s.state_now(), screen_net(s))
  level == "amber" || level == "red"
}

///|
/// With keyboard and mouse in `p`: the viewer's bar across the window's top (@sf.viewer_bar_node), one row (the user,
/// 2026-11-13): back by its name, the view's tabs in the name's place where it has them (all browser pages on the
/// station, ＋ after them when allowed; a desktop's whole screen and its windows), else the screen's name and the
/// core's line; at its end the link's figures only while it is poor, 组合键 while driving a desktop, 控制中心 (只看 is
/// there), and 接管 while someone else drives it, who does said in the line's place. Narrow, the tabs fold into a
/// button counting them.
fn screen_viewer_bar_node(p : @view.View, pg : ScreenPage) -> Unit {
  let s = pg.s
  let u = pg.u
  let narrow = fn() { view_narrow(p, u) }
  p.reacts(narrow, fn(n) { u.narrow_bar = n })
  let line = fn() {
    let st = s.state_now()
    if !s.open_said() {
      ""
    } else if s.can_take_over() {
      drives_words(s)
    } else {
      text(st, "line")
    }
  }
  let tabs_shown = fn() {
    s.said.get() |> ignore
    !view_tabs(s).0.is_empty() && !narrow()
  }
  let ink = fn() { @sf.page_viewer_ink() }
  p.box(fn(room) {
    room.height(Is(Some(@sf.viewer_bar_h))) |> ignore
    @sf.viewer_bar_node(
      room,
      // (alone in a window of its own, nowhere to go back to: its window's close and 控制中心's 断开 close it)
      fn() { if pg.lone { "" } else { @sf.t("common.back") } },
      fn() { pg.said_title() },
      line,
      fn() { "" },
      fn() { false },
      fn(_) { 1.0 },
      fn() { 0.0 },
      fn() { p.window_w() },
      ink,
      fn(r, corner) {
        // how the view goes, while the link is poor
        r.show(at_once=true, fn() { s.phase_now() == "live" && net_poor(s) }, fn(k) { net_chip_node(k, pg) })
        // narrow, the tabs folded into the button counting them (a browser's is by its address bar)
        r.show(at_once=true, fn() { narrow() && !browser_shown_now(s) && !view_tabs(s).0.is_empty() }, fn(k) { tabs_button_node(k, pg, side=@sf.tool_side) })
        // (组合键 while driving: the keyboard has the rest)
        r.show(at_once=true, fn() { s.driving_now() && !s.simulator() }, fn(k) {
          let t = @sf.tool_node(k, fn() { { icon: "keycap", label: @sf.t("web-pages.screen.combos"), on: false, disabled: false } }, ink, corner, fn() {  }, tip=pg.tips)
          t.on_press(fn() { keys_open(s, u, Node(t), combos_only=true) }) |> ignore
        })
        // (whole window or a window of its own: another of the station's screens, its browser or a terminal of it, in
        // its place)
        r.show(at_once=true, fn() {
          !pg.in_tab && s.open_said() && terminals_here() && @signals.untracked(fn() { (s.src.asks_terminals)() })
        }, fn(k) {
          let t = @sf.tool_node(k, fn() { { icon: "terminal", label: @sf.t("web-pages.remote.switchSession"), on: false, disabled: false } }, ink, corner, fn() {  }, tip=pg.tips)
          t.on_press(fn() { station_sessions_open(pg, t) }) |> ignore
        })
        // (麦克风 while something on the screen records it, or this device's is shared: ScreenSess::mic_bar_shown)
        r.show(along_row=true, fn() { s.mic_bar_shown() }, fn(k) {
          let t = @sf.tool_node(k, fn() { { icon: s.mic_icon(), label: s.mic_label(), on: s.mic_on.get(), disabled: false } }, ink, corner, fn() {  }, tip=pg.tips)
          t.on_press(fn() { s.toggle_mic() }) |> ignore
        })
        r.show(at_once=true, fn() { s.open_said() }, fn(k) {
          let t = @sf.tool_node(k, fn() { { icon: "sliders", label: @sf.t("web-pages.screen.panel"), on: false, disabled: false } }, ink, corner, fn() {  }, tip=pg.tips)
          t.on_press(fn() { center_open(pg, Node(t), "center") }) |> ignore
          screen_asked(t, pg, ["center", "logs", "apps"], fn(asked) { center_open(pg, Node(t), asked) })
        })
        r.show(at_once=true, fn() { s.taking_over_now() }, fn(k) { take_over_node(k, pg, in_bar=true, placed=false) })
      },
      fn() { (pg.close)() },
      pg.tips,
      capsule_now=fn() { s.taking_over_now() },
      middle=fn(m) { tabs_row_node(m, pg) },
      middle_shown=tabs_shown,
    )
    |> ignore
  })
  |> ignore
}

///|
/// How the view goes, in the viewer's bar (the web's NetChip) in `parent`: the signal mark on its tile, coloured as the
/// round trip and what it lost are (screen_link_level), and how long it has been seen; pressed, the view's figures under it.
fn net_chip_node(parent : @view.View, pg : ScreenPage) -> Unit {
  let s = pg.s
  let u = pg.u
  let b = @sf.action_box_node(parent, fn() { @sf.t("web-pages.screen.stats") }, fn(b) { net_panel_open(s, u, Node(b)) }, fn(b) {
    @sf.style_node(b, fn() { net_chip_box }, in_row=true)
    @sf.hover_ground_node(b)
    b.box(fn(t) {
      @sf.style_node(t, fn() { net_mark_tile }, in_row=true)
      signal_bars_node(t, fn() { screen_link_level(s.state_now(), screen_net(s)) })
    })
    |> ignore
    @sf.words_node(b, fn() { seen_for(u) }, fn() { screen_time_words }) |> ignore
  })
  // (asked from elsewhere, a fixture's: opened as this is made)
  screen_asked(b, pg, ["net"], fn(_) { net_panel_open(s, u, Node(b)) })
}

///|
/// How far a floating capsule (the folded tools, the mouse's buttons) was dragged from its corner, and from where a drag
/// of it began: told as it is dragged (what places it reads it).
priv struct Afloat {
  moved : @signals.Signal[(Double, Double)]
  /// how far it was moved as the drag began, and where in the window the drag began
  mut from : (Double, Double)
  mut start : (Double, Double)
  /// where it was laid out with no drag, as the drag began (its window's: to keep it inside the window)
  mut laid : (Double, Double, Double, Double)
}

///|
fn afloat_new() -> Afloat {
  { moved: @signals.signal((0.0, 0.0), same=fn(a, b) { a == b }), from: (0.0, 0.0), start: (0.0, 0.0), laid: (0.0, 0.0, 0.0, 0.0) }
}

///|
/// Capsule `cap` floated as `f` says: drawn as far from its place as it was dragged, a hold on it (on one of its buttons
/// too) moved past the slop taking it with the finger, kept inside the window as it is laid out (moved past its edge,
/// opened longer); a press on it that does not move is a tap of what is under it. The window turned or resized: back
/// to its corner.
fn afloat_node(cap : @view.View, f : Afloat) -> Unit {
  cap.offset(By(fn() { f.moved.get() })) |> ignore
  cap.reacts(fn() { cap.window() }, fn(_) { f.moved.set((0.0, 0.0)) }, at_start=false)
  cap
  .claims(fn(dx, dy) { dx * dx + dy * dy > screen_slop * screen_slop })
  .on_drag(fn(d) {
    match d.kind {
      Down => {
        f.from = f.moved.untracked()
        f.start = (d.wx, d.wy)
        let (x, y, w, h) = cap.rect()
        f.laid = (x - f.from.0, y - f.from.1, w, h)
      }
      Moved | Up => {
        let dx = f.from.0 + d.wx - f.start.0
        let dy = f.from.1 + d.wy - f.start.1
        let (x0, y0, w, h) = f.laid
        let (ww, wh) = cap.window()
        // (its panel still past the window's edge, on the tape: nothing to keep it inside of yet)
        if x0 < 0.0 || x0 + w > ww {
          f.moved.set((dx, dy))
        } else {
          f.moved.set((dmax(-x0, dmin(ww - w - x0, dx)), dmax(-y0, dmin(wh - h - y0, dy))))
        }
      }
      Off => f.moved.set(f.from)
    }
  })
  |> ignore
}

///|
/// 全屏's tools in `fill` (a layer over the picture), folded into one round button over the frame's corner (in the
/// letterbox, as a screen wider than the device leaves one): open, the same as the rail's down from it — 只看/控制, 按键,
/// pasting, the keyboard, 控制中心, 退出全屏. Its button dragged, they go where it is let go, kept inside the window (what
/// is under the corner in sight again).
fn full_tools_node(fill : @view.View, pg : ScreenPage) -> Unit {
  let s = pg.s
  let u = pg.u
  fill.box(fn(place) {
    place.over(Is(true)) |> ignore
    @sf.style_node(place, fn() { screen_corner_end(screen_top_end) })
    place.box(fn(cap) {
      @sf.style_node(cap, fn() { full_tools_box })
      floats_capsule_node(cap, trigger=true)
      // a round button 4 in from the capsule's edge: its corner 20 + 4
      let open = fn() { u.tools_open.get() }
      let b = screen_round_node(
        cap,
        pg,
        fn() { if open() { "close" } else { "more" } },
        fn() { @sf.t(if open() { "android-misc.screen.toolsClose" } else { "android-misc.screen.tools" }) },
        fn(_) { u.tools_open.set(!u.tools_open.untracked()) },
        lit=open,
      )
      ignore(b)
      afloat_node(cap, u.tools_moved)
      cap.show(open, fn(t) {
        t.lines_up(Is(Some(Middle))).gap(Is(@ui.Space::S1.px())) |> ignore
        mode_button_node(t, pg)
        keys_button_node(t, pg)
        paste_button_node(t, pg)
        keyboard_button_node(t, pg)
        mic_button_node(t, pg)
        center_button_node(t, pg)
        full_button_node(t, pg)
      })
      ignore(s)
    })
    |> ignore
  })
  |> ignore
}

///|
/// Sideways in `p`: the same as the bar down the side (close, who else is on it, 只看/控制, 按键, pasting, the keyboard,
/// 控制中心, 全屏), the line said when the people on it are tapped (there while others are). What says the line (pressed:
/// said for rail_say_ms from then) and whether it is said.
fn screen_rail_node(p : @view.View, pg : ScreenPage) -> (() -> Unit, () -> Bool) {
  let s = pg.s
  let said = Ref((fn() {  }, fn() { false }))
  p.box(fn(rail) {
    @sf.style_node(rail, fn() { rail_box }, in_row=true)
    said.val = rail.holds_for(rail_say_ms, later=true)
    let (say, saying) = said.val
    if !pg.in_tab {
      close_button_node(rail, pg)
    }
    rail.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
    let others = fn() { items(s.state_now(), "others").length() }
    rail.show(at_once=true, fn() { text(s.state_now(), "line") != "" && s.open_said() && others() > 0 }, fn(people) {
      let b = screen_round_node(people, pg, fn() { "users" }, fn() { @sf.t("android-misc.screen.people") }, fn(_) { say() }, lit=saying)
      ignore(b)
      // the count of the others on it: over the button's top right, 4 out and 2 up
      people.box(fn(place) {
        @sf.style_node(place, fn() { rail_badge_place })
        place.over(Is(true)) |> ignore
        place.box(fn(badge) {
          @sf.style_node(badge, fn() { rail_badge }, in_row=true)
          badge.offset(Is((rail_badge_out, -rail_badge_up))) |> ignore
          @sf.mark_words_node(badge, fn() { "\{others()}" }, fn() { rail_badge_words }) |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    mode_button_node(rail, pg)
    keys_button_node(rail, pg)
    paste_button_node(rail, pg)
    keyboard_button_node(rail, pg)
    mic_button_node(rail, pg)
    rail.show(at_once=true, fn() { s.open_said() }, fn(k) {
      k.lines_up(Is(Some(Middle))).gap(Is(@ui.Space::S1.px())) |> ignore
      center_button_node(k, pg)
      full_button_node(k, pg)
    })
  })
  |> ignore
  said.val
}

///|
/// Where the count of the others on it sits past the rail's people button's top right corner.
let rail_badge_out : Double = 4.0

///|
let rail_badge_up : Double = 2.0

///|
/// The rail's line in `p` (a layer over the page), said beside the rail over its foot while `said` holds it (the
/// people on it tapped), while the state has one.
fn rail_said_node(p : @view.View, pg : ScreenPage, said : (() -> Unit, () -> Bool)) -> Unit {
  let s = pg.s
  let (_, saying) = said
  p.show(at_once=true, fn() { saying() && s.state_now() is Some(_) }, fn(o) {
    o.over(Is(true)) |> ignore
    o.box(fn(place) {
      @sf.style_node(place, fn() { rail_say_place })
      place.box(fn(b) {
        @sf.style_node(b, fn() { rail_say_box })
        floats_panel_node(b)
        @sf.words_node(b, fn() { text(s.state_now(), "line") }, fn() { rail_say_words }) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
}

///|
/// Upright, under the frame while driving it in `f` (the user, 2026-11-13: 「小屏下面的操作…不够直观，不够方便」). Not
/// typing: a few large actions, each its mark over its name — 键盘, 粘贴 (where the station takes the clipboard), 按键
/// (组合键, F1–F12…; not a simulator's), and with the trackpad 左键 and 右键 (directly, a tap clicks and a press held clicks
/// right). Typing: what a phone's keyboard has not (Esc, Tab, ⌘ ⌃ ⌥ ⇧, the arrows) over it, the keyboard put away at
/// its end, as a keyboard's row of keys over a phone's own.
fn foot_node(f : @view.View, pg : ScreenPage) -> Unit {
  let s = pg.s
  let u = pg.u
  f.pick(at_once=true, fn() { pg.catching() || u.typing.get() }, fn(slot, typing) {
    if typing {
      slot.box(fn(row) {
        @sf.style_node(row, fn() { screen_foot })
        // (按键 first: what the row and the keyboard have not, 组合键 and F1–F12)
        keys_button_node(row, pg)
        row.box(fn(k) {
          @sf.style_node(k, fn() { screen_fill_w }, in_row=true)
          k.row(Is(true)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
          keys_row_node(k, pg, mouse=false)
        })
        |> ignore
        // the keyboard put away, and the row with it (already down, the system's own: the row alone)
        screen_round_node(row, pg, fn() { "keyboard" }, fn() { @sf.t("android-misc.screen.keyboard") }, fn(_) {
          screen_panels_close(u)
          match u.catcher {
            Some(k) => @ui.key_catcher_focus_set(k, false)
            None => ()
          }
          u.typing.set(false)
        }, lit=fn() { true })
        |> ignore
      })
      |> ignore
    } else {
      slot.box(fn(row) {
        @sf.style_node(row, fn() { screen_foot_actions })
        foot_action_node(row, pg, "keyboard", fn() { @sf.t("android-misc.screen.keyboard") }, fn() { @sf.t("android-misc.screen.keyboard") }, fn(_) {
          keyboard_toggled(pg)
        })
        |> ignore
        row.show(at_once=true, fn() { s.said.get() |> ignore; s.pastes() }, fn(k) {
          // (its share of the row, as each action's)
          k.row(Is(true)).grow(Is(1.0)).basis(Is(Some(0.0))) |> ignore
          foot_action_node(k, pg, "paste", fn() { @sf.t("web-pages.screen.paste") }, fn() { @sf.t("android-misc.screen.paste") }, lit=fn() {
            s.pasting.get()
          }, fn(_) { paste_asked(s, u) })
          |> ignore
        })
        row.show(at_once=true, fn() { s.said.get() |> ignore; !s.simulator() }, fn(kk) {
          kk.row(Is(true)).grow(Is(1.0)).basis(Is(Some(0.0))) |> ignore
          let k = foot_action_node(kk, pg, "keycap", fn() { @sf.t("web-pages.screen.keysPanel") }, fn() { @sf.t("web-pages.screen.keysPanel") }, lit=fn() {
            screen_panel_on_now(u, "keys")
          }, fn(b) { keys_open(s, u, Node(b)) })
          // (a fixture's, asked as it is made)
          screen_asked(k, pg, ["keys"], fn(_) { keys_open(s, u, Node(k)) })
        })
        row.show(at_once=true, fn() { !(mouse_shown_now(s) && s.pad(s.src)) && s.driving_now() && !s.simulator() }, fn(m) {
          m.row(Is(true)).grow(Is(1.0)).basis(Is(Some(0.0))) |> ignore
          let words = fn() { @sf.t("web-pages.remote.touchPadShort") }
          foot_action_node(m, pg, "trackpad", words, words, fn(_) { pad_chosen(s, u, true) }) |> ignore
        })
        row.show(at_once=true, fn() { mouse_shown_now(s) && s.pad(s.src) }, fn(m) {
          m.row(Is(true)).grow(Is(2.0)).basis(Is(Some(0.0))).gap(Is(@ui.Space::S1.px())) |> ignore
          let left = @sf.t("android-misc.screen.key.mouseLeft")
          let right = @sf.t("android-misc.screen.key.mouseRight")
          let took = Ref(false)
          let l = foot_action_node(m, pg, "mouse-left", fn() { left }, fn() { left }, lit=fn() { u.left_locked.get() }, felt=btn_primary, fn(_) {
            left_pressed_on(s, u, took)
          })
          left_hold_node(l, s, u, took)
          foot_action_node(m, pg, "mouse-right", fn() { right }, fn() { right }, felt=btn_secondary, fn(_) {
            button_clicked(s, u, btn_secondary)
          })
          |> ignore
        })
      })
      |> ignore
    }
  })
}

///|
/// One of the foot's actions in `parent`: its mark over its name (`words`), as wide as its share of the row, lit while
/// `lit`; its name for those who cannot see it `label` (粘贴's says whose clipboard); a mouse's button (`felt`) felt as a
/// press goes down on it. Pressed, `press`. The node.
fn foot_action_node(
  parent : @view.View,
  pg : ScreenPage,
  icon : String,
  words : () -> String,
  label : () -> String,
  lit? : () -> Bool = fn() { false },
  felt? : Int = 0,
  press : (@view.View) -> Unit,
) -> @view.View {
  ignore(pg)
  @sf.action_box_node(parent, label, on=lit, press, fn(v) {
    @sf.style_node(v, fn() { foot_action_box }, in_row=true)
    v.ground(By(fn() { if lit() { @sf.alpha(@ui.tree_theme().color(Fg), 0.1) } else { 0L } })) |> ignore
    @sf.hover_ground_node(v, lit=Some(fn() { v.pressed() }))
    @sf.icon_node(v, icon, round_icon, By(fn() { @ui.tree_theme().color(Fg) })) |> ignore
    @sf.words_node(v, words, fn() { foot_action_words }) |> ignore
    if felt != 0 {
      button_felt_node(v, felt)
    }
  })
}

///|
/// A mouse button `v` felt as a press goes down on it (the click itself goes as it is let go): the right button as a
/// context click, the left as a key.
fn button_felt_node(v : @view.View, button : Int) -> Unit {
  let kind : @ui.Haptic = if button == btn_secondary { ContextClick } else { KeyboardTap }
  v.reacts(fn() { v.pressed() }, fn(down) {
    if down {
      @ui.haptic(kind)
    }
  }, at_start=false)
}

///|
/// A key of the keys row: what it sends, or a modifier held for the next key (`mod`, its bit).
priv struct RowKey {
  label : String
  name : String
  key : String
  code : String
  mod_ : Int
  icon : String
  /// where the row has not the room for every key: the k-th to leave it for its ⋯ (View::drops; 0: never)
  drop : Int
  /// a mouse button (btn_primary, btn_secondary) clicked where the pointer is, instead of a key; 0 a key
  button : Int
}

///|
fn screen_row_keys() -> Array[RowKey] {
  let k = fn(label, name, key, code, mod_, icon, drop) -> RowKey { { label, name, key, code, mod_, icon, drop, button: 0 } }
  let b = fn(name, icon, button) -> RowKey {
    { label: "", name, key: "", code: "", mod_: 0, icon, drop: 0, button }
  }
  // (short of room the least used leave first: ⌥, ⌃, ⇧, Tab, ⌘, then up and down, left and right last; the mouse's
  // buttons and Esc stay)
  [
    b(@sf.t("android-misc.screen.key.mouseLeft"), "mouse-left", btn_primary),
    b(@sf.t("android-misc.screen.key.mouseRight"), "mouse-right", btn_secondary),
    k("Esc", "Esc", "Escape", "Escape", 0, "", 0),
    k("Tab", "Tab", "Tab", "Tab", 0, "", 4),
    k("⌘", @sf.t("android-misc.screen.key.command"), "", "", mod_meta, "", 5),
    k("⌃", @sf.t("android-misc.screen.key.control"), "", "", mod_ctrl, "", 2),
    k("⌥", @sf.t("android-misc.screen.key.option"), "", "", mod_alt, "", 1),
    k("⇧", @sf.t("android-misc.screen.key.shift"), "", "", mod_shift, "", 3),
    k("", @sf.t("android-misc.screen.key.left"), "ArrowLeft", "ArrowLeft", 0, "arrow-left", 7),
    k("", @sf.t("android-misc.screen.key.up"), "ArrowUp", "ArrowUp", 0, "arrow-up", 6),
    k("", @sf.t("android-misc.screen.key.down"), "ArrowDown", "ArrowDown", 0, "arrow-down", 6),
    k("", @sf.t("android-misc.screen.key.right"), "ArrowRight", "ArrowRight", 0, "arrow-right", 7),
  ]
}

///|
/// The mouse's two buttons (clicked where the pointer is: the trackpad's, else the screen's own), the keys a phone's
/// keyboard has not (Esc, Tab, the arrows) and the modifiers (⌘ ⌃ ⌥ ⇧: held, shown solid, for the next key or click,
/// typed or here), in a row in `parent`. Where it has not the room for them all, the least used leave it (RowKey's
/// `drop`; a modifier held never), and a ⋯ key at its end turns the row to them, as a keyboard turns to its other keys
/// (lit while turned; pressed again, on to those that had not the room there either, or back): nothing scrolled,
/// nothing wrapped, nothing over the keyboard.
fn keys_row_node(parent : @view.View, pg : ScreenPage, mouse? : Bool = true) -> Unit {
  let s = pg.s
  let u = pg.u
  let keys = screen_row_keys()
    .filter(fn(k) { k.button == 0 || mouse })
    .map(fn(k) -> @sf.KeyPadKey {
      {
        cap: k.label,
        name: k.name,
        icon: k.icon,
        drop: k.drop,
        // (a modifier: solid while held for the next key, which keeps it in the row)
        // (左键 too: solid while held down from it)
        held: if k.mod_ != 0 {
          Some(fn() { (u.held.held_said() & k.mod_) != 0 })
        } else if k.button == btn_primary {
          Some(fn() { u.left_locked.get() })
        } else {
          None
        },
        felt: button_felt(k.button),
        // pressed, a modifier held or let go, a mouse button clicked where the pointer is, or the key sent with what
        // is held
        press: fn() {
          if k.mod_ != 0 {
            u.held.toggle(k.mod_)
          } else if k.button != 0 {
            button_clicked(s, u, k.button)
          } else {
            let mods = u.held.take()
            stroke(fn(j) { s.input(s.src, j) }, k.key, k.code, mods)
          }
        },
      }
    })
  @sf.key_pad_row_node(parent, keys, u.keys_turned, look=fn() { keys_row_box }) |> ignore
}

///|
/// How a mouse button `button` is felt as a press goes down on it (button_felt_node's); none for a key.
fn button_felt(button : Int) -> @ui.Haptic? {
  if button == 0 {
    None
  } else if button == btn_secondary {
    Some(ContextClick)
  } else {
    Some(KeyboardTap)
  }
}

///|
/// Mouse button `button` clicked where the pointer is (the trackpad's, else the screen's own; the station saying none,
/// where a finger last pressed on the picture, else the trackpad's), the modifiers the keys row holds round it.
fn button_clicked(s : ScreenSess, u : ScreenUi, button : Int) -> Unit {
  if button == btn_primary {
    left_pressed(s, u)
    return
  }
  let mods = u.held.take()
  click(fn(j) { s.input(s.src, j) }, button_at(s, u), button, mods)
}

///|
/// Where a mouse button of the foot clicks: where the pointer is (the trackpad's, else the screen's own; the station
/// saying none, where a finger last pressed on the picture, else the trackpad's).
fn button_at(s : ScreenSess, u : ScreenUi) -> (Double, Double) {
  match @signals.untracked(fn() { pointer_now(s, u) }) {
    Some(at) => at
    None => u.tapped_at.unwrap_or(u.pad.at())
  }
}

///|
/// 左键 pressed (the keys row's, the foot's or the floating one): held down from it, let go of; else a click where the
/// pointer is, the modifiers the keys row holds round it (two quick presses a double click there, as a mouse's). The
/// press of a button that held it (left_hold_node's `took`) comes to nothing more.
fn left_pressed(s : ScreenSess, u : ScreenUi) -> Unit {
  if u.left_locked.untracked() {
    left_let_go(s, u, None)
    return
  }
  let mods = u.held.take()
  click(fn(j) { s.input(s.src, j) }, button_at(s, u), btn_primary, mods)
}

///|
/// 左键's button `v` (the foot's, the floating one) held a press's hold (screen_hold_ms): 左键 held down where the
/// pointer is, felt so, a finger on the stage then dragging with it (a window moved, words chosen, one hand on the
/// button and the other on the screen) till the button or a tap on the stage lets it go; `took` set for its press,
/// whose let go then clicks nothing (left_pressed_on). Held while it is already held: nothing.
fn left_hold_node(v : @view.View, s : ScreenSess, u : ScreenUi, took : Ref[Bool]) -> Unit {
  // (the moment the press under way went down; none while none is)
  let since : @signals.Signal[Double?] = @signals.signal(None)
  v.reacts(fn() { v.pressed() }, fn(down) {
    since.set(if down { Some(v.cause_at()) } else { None })
    if down {
      took.val = false
    }
  }, at_start=false)
  // (held a hold's length: the moment come as it is drawn, as a finger held on the stage is told its own)
  v.reacts(fn() {
    match since.get() {
      Some(t0) => v.drawn_while(fn(now) { now < t0 + screen_hold_ms }) >= t0 + screen_hold_ms
      None => false
    }
  }, fn(held) {
    if held && !u.left_locked.untracked() && s.driving() {
      took.val = true
      left_hold(s, u)
    }
  }, at_start=false)
}

///|
/// 左键's button pressed (let go on it): nothing where its press held 左键 down (`took`), else left_pressed.
fn left_pressed_on(s : ScreenSess, u : ScreenUi, took : Ref[Bool]) -> Unit {
  if took.val {
    took.val = false
  } else {
    left_pressed(s, u)
  }
}

///|
/// 左键 held down where the pointer is, the modifiers the keys row holds round it till it is let go of.
fn left_hold(s : ScreenSess, u : ScreenUi) -> Unit {
  let send = fn(j) { s.input(s.src, j) }
  let at = button_at(s, u)
  let mods = u.held.take()
  u.lock_at = at
  u.lock_mods = mods
  mods_round(send, mods, "down")
  send(pointer_input("down", at, btn_primary))
  u.left_locked.set(true)
  @ui.haptic(LongPress)
}

///|
/// 左键 held from its button let go of, at `at` (None: where the drag with it has got to, else where it went down), no
/// button held after it (as a mouse's let go: screen_mouse_drag's), the keys held round it let go of after it; nothing
/// while it is not held.
fn left_let_go(s : ScreenSess, u : ScreenUi, at : (Double, Double)?) -> Unit {
  guard u.left_locked.untracked() else { return }
  let send = fn(j) { s.input(s.src, j) }
  u.left_locked.set(false)
  send(pointer_input("up", at.unwrap_or(u.lock_at), 0))
  mods_round(send, u.lock_mods, "up")
  u.lock_mods = 0
}

///|
/// Whether the mouse's buttons show while driving a screen that is no simulator's: the keys row's two, and their
/// floating pair in 全屏 and sideways. Never turned off (pengxiao, 2026-11-12: nobody does, and the keys row folds what
/// has not the room).
fn mouse_shown(s : ScreenSess) -> Bool {
  s.driving() && !s.simulator()
}

///|
/// 左键 and 右键 side by side at the end of the frame's foot in `row` (the system bar's, 全屏 and sideways, the keyboard
/// down: the keys row is not there; screen_stage_foot, what else is there laid out clear of them), each a round button
/// floating on its own, the two dragged anywhere together by either, as the folded tools are.
fn mouse_float_node(row : @view.View, pg : ScreenPage) -> Unit {
  let s = pg.s
  let u = pg.u
  row.box(fn(end) {
    @sf.style_node(end, fn() { mouse_pair_end }, in_row=true)
    end.box(fn(cap) {
      @sf.style_node(cap, fn() { mouse_pair_box }, in_row=true)
      u.mouse_pair = Some(cap)
      mouse_left_round_node(cap, s, u)
      @sf.tool_round_node(cap, "mouse-right", fn() { @sf.t("android-misc.screen.key.mouseRight") }, fn() {
        button_clicked(s, u, btn_secondary)
      }, look=Floating, felt?=button_felt(btn_secondary))
      |> ignore
      afloat_node(cap, u.mouse_moved)
    })
    |> ignore
  })
  |> ignore
}

///|
/// 左键 floating in `cap` (mouse_float_node's): a round tool floating over the picture as 右键 beside it is
/// (@sf.tool_round_node's Floating look: 44, on the floating ground with its shadow, the ink at 8% pressed, its mark
/// 20 in the ink); held down from it (left_hold_node), solid as the keys row's held key is (the ink, its mark in the
/// page's colour, no shadow nor hover over it) and read out pressed.
fn mouse_left_round_node(cap : @view.View, s : ScreenSess, u : ScreenUi) -> Unit {
  let held = fn() { u.left_locked.get() }
  let took = Ref(false)
  let label = fn() { @sf.t("android-misc.screen.key.mouseLeft") }
  let key = @sf.action_box_node(cap, label, on=held, fn(_) { left_pressed_on(s, u, took) }, fn(v) {
    @sf.style_node(v, fn() { mouse_round }, in_row=true)
    @sf.glass_capsule_node(
      v,
      min_height=Some(44.0),
      radius=Some(22.0),
      sharing=true,
      interactive=true,
      panel=true,
      active=fn() { !held() },
    )
    |> ignore
    v.ground(By(fn() { if held() { @ui.tree_theme().color(Fg) } else { 0L } })) |> ignore
    @sf.hover_ground_node(v, lit=Some(fn() { v.pressed() && !held() }))
    @sf.icon_node(v, "mouse-left", round_icon, By(fn() { @ui.tree_theme().color(if held() { Bg } else { Fg }) })) |> ignore
    button_felt_node(v, btn_primary)
  })
  left_hold_node(key, s, u, took)
}

///|
/// The keys row floating over the frame's foot in `fill` (sideways, 全屏 and the system's bars', while the keyboard is up
/// and it drives the screen); `sides`: clear of what the system has at the sides (全屏's).
fn keys_capsule_over_node(fill : @view.View, pg : ScreenPage, sides~ : Bool) -> Unit {
  let s = pg.s
  fill.show(at_once=true, fn() { s.driving_now() && typing_now(fill) }, fn(o) {
    o.over(Is(true)) |> ignore
    o.box(fn(place) {
      @sf.style_node(place, fn() { if sides { screen_foot_center.then(@sf.sides_clear(@ui.Space::S2.px())) } else { screen_foot_center } })
      place.box(fn(cap) {
        @sf.style_node(cap, fn() { keys_capsule_box }, in_row=true)
        floats_capsule_node(cap)
        keys_row_node(cap, pg)
      })
      |> ignore
    })
    |> ignore
  })
}

///|
/// Who drives it and 接管 floating over the top of the frame in `fill` (sideways, 全屏, the system's bars'), while
/// someone else drives it.
fn take_over_over_node(fill : @view.View, pg : ScreenPage) -> Unit {
  let s = pg.s
  fill.show(at_once=true, fn() { s.taking_over_now() }, fn(o) {
    o.over(Is(true)) |> ignore
    o.box(fn(place) {
      @sf.style_node(place, fn() { screen_top_center })
      take_over_node(place, pg, in_bar=false, placed=false)
    })
    |> ignore
  })
}

///|
/// Who else drives it, as the state names them.
fn drivers_of(s : ScreenSess) -> Array[String] {
  items(s.state, "controllers").filter_map(fn(j) {
    match j {
      String(n) => Some(n)
      _ => None
    }
  })
}

///|
/// 「<who> 正在控制」, or 「他人正在控制」 where the state names nobody.
fn drives_words(s : ScreenSess) -> String {
  let who = drivers_of(s)
  if who.is_empty() {
    @sf.t("android-misc.screen.someoneDrives")
  } else {
    @sf.t("android-misc.screen.drives", args=[("who", who.join(@sf.t("web-main.list.separator")))])
  }
}

///|
/// Someone else drives it (an agent at work) and this view only looks, in `parent`: who, and 接管 in one tap
/// (`screen.control` true: their input waits while this person drives; the line then says so). `in_bar`: in the
/// viewer's bar, a row of its tools, who drives said by the bar's line; else a capsule floating still (`placed`: upright
/// under the bar, 12 from the sides).
fn take_over_node(parent : @view.View, pg : ScreenPage, in_bar~ : Bool, placed~ : Bool) -> Unit {
  let made = fn(at : @view.View) { take_over_capsule_node(at, pg, in_bar, placed) }
  if placed {
    parent.box(fn(p) {
      @sf.style_node(p, fn() { take_over_place })
      made(p)
    })
    |> ignore
  } else {
    made(parent)
  }
}

///|
/// What take_over_node makes in `at`.
fn take_over_capsule_node(at : @view.View, pg : ScreenPage, in_bar : Bool, placed : Bool) -> Unit {
  let s = pg.s
  let u = pg.u
  ignore(placed)
  at.box(fn(b) {
    // a capsule round a 32 high button 6 in from its edge: its corner 6 + 16
    @sf.style_node(b, fn() { if in_bar { take_over_bar_row } else { take_over_box } })
    let shake : Ref[@motion.ShakeWay?] = Ref(None)
    b.reacts(fn() { u.held_nudge.get() }, at_start=false, fn(_) {
      @ui.haptic(Reject)
      if @ui.reduced_motion() {
        return
      }
      let way = match shake.val {
        Some(w) => w
        None => {
          let w = @motion.ShakeWay::new(amplitude=@sf.refused_reach, duration_ms=@sf.refused_ms, cycles=1.5)
          shake.val = Some(w)
          w.shakes(b) |> ignore
          w
        }
      }
      way.shake(at=b.cause_at())
    })
    if !in_bar {
      floats_capsule_node(b)
      @sf.first_line_node(b, Ui, fn(l) { l.box(fn(d) { @sf.style_node(d, fn() { take_over_dot }, in_row=true) }) |> ignore }) |> ignore
      b.box(fn(w) {
        @sf.style_node(w, fn() { take_over_words_box }, in_row=true)
        @sf.words_node(w, fn() { s.said.get() |> ignore; drives_words(s) }, fn() { take_over_words }) |> ignore
      })
      |> ignore
    }
    // the main solid button, as the web's primary (dark in the light theme, light in the dark one), not the accent
    // (whole, what says who drives cut short beside it)
    let button = @sf.action_box_node(b, fn() { @sf.t("android-misc.screen.takeOver") }, fn(_) { control_chosen(s, u, true) }, fn(v) {
      @sf.style_node(v, fn() { take_over_button }, in_row=true)
      v.shrink(Is(0.0)) |> ignore
      @sf.hover_ground_node(v)
      @sf.words_node(v, fn() { @sf.t("android-misc.screen.takeOver") }, fn() { take_over_button_words }) |> ignore
    })
    // what it does: their input waits while this person drives
    @sf.tip_node(pg.tips, button, fn() {
      s.said.get() |> ignore
      let who = drivers_of(s)
      let names = if who.is_empty() { @sf.t("web-pages.screen.someone") } else { who.join(@sf.t("web-pages.screen.and")) }
      @sf.t("web-pages.screen.takeOverTip", args=[("names", names)])
    })
    |> ignore
  })
  |> ignore
}

///|
/// The station's other screens, its browser and its terminals in a menu beside `from` (the viewer's bar's, whole window
/// or a window of its own), each shown in this one's place as chosen; asks the station's `terminals` and `screens` only
/// as it is pressed, the menu opened once both are answered.
fn station_sessions_open(pg : ScreenPage, from : @view.View) -> Unit {
  let s = pg.s
  let label = @sf.t("web-pages.remote.switchSession")
  let scope = "screen-sw/" + s.station
  let sub_t = @sfbase.hold(s.src, scope, "terminals", { "station": str(s.station) })
  let sub_s = @sfbase.hold(s.src, scope, "screens", { "station": str(s.station) })
  @sfbase.press_wait(
    fn() { @sfbase.opens_answered(sub_t.get()) && @sfbase.opens_answered(sub_s.get()) },
    fn() {
      let tval = @signals.untracked(fn() { sub_t.get().value })
      let sval = @signals.untracked(fn() { sub_s.get().value })
      @sfbase.let_go(s.src, scope)
      let go_page = fn(next : @sfbase.Page) {
        if pg.lone {
          @sfbase.lone_page_replace(next)
        } else {
          @sfbase.app.nav.replace(next)
        }
      }
      let scs = items(sval, "screens")
      let others = scs.filter(fn(sc) { text(Some(sc), "kind") != "browser" })
      let user_ids = scs
        .filter(fn(sc) { flag(Some(sc), "userTab") || text(Some(sc), "id").has_prefix("browser:u_") })
        .map(fn(sc) { text(Some(sc), "id") })
      let can_term = flag(tval, "open")
      let can_browse = flag(sval, "browser") && flag(sval, "control")
      let menu_items : Array[@sf.MenuItem?] = []
      for sc in others {
        let sid = text(Some(sc), "id")
        let title = text(Some(sc), "title")
        let here = sid == s.screen
        let icon = if here { "check" } else if text(Some(sc), "kind") == "simulator" { "phone" } else { "monitor" }
        menu_items.push(Some(@sf.menu_item_of(title, icon~, fn() {
          if !here {
            go_page(Screen({ station: s.station, screen: sid, title, until_gone: false }))
          }
        })))
      }
      if !user_ids.is_empty() || can_browse {
        let in_browser = s.screen.has_prefix("browser:") || text(s.state, "kind") == "browser"
        menu_items.push(Some(@sf.menu_item_of(@sf.t("web-pages.remote.openBrowser"), icon=if in_browser { "check" } else { "web" }, fn() {
          if !in_browser {
            let target = match @settings.browser_tab_to_open(s.station, user_ids) {
              Some(tid) => tid
              None => @settings.new_browser_tab(s.src.call, s.station, user_ids, failed_said(@sf.t("web-pages.screen.openBrowserWhat")))
            }
            go_page(Screen({ station: s.station, screen: target, title: "", until_gone: false }))
          }
        })))
      }
      let open_terms = items(tval, "terminals").filter(fn(t) { !flag(Some(t), "ended") })
      if !open_terms.is_empty() {
        if !menu_items.is_empty() {
          menu_items.push(None)
        }
        for t in open_terms {
          let tv = Some(t)
          let tid = text(tv, "id")
          let cwd = text(tv, "cwd")
          menu_items.push(Some(@sf.menu_item_of(terminal_title(tv), icon="terminal", fn() {
            go_page(Terminal({ station: s.station, terminal: tid, watch: !can_term, cwd }))
          })))
        }
      }
      if can_term || can_browse {
        if !menu_items.is_empty() {
          menu_items.push(None)
        }
        let open_new_terminal = fn() {
          go_page(Terminal({ station: s.station, terminal: "new", watch: false, cwd: "" }))
        }
        let open_new_browser = fn() {
          let target = @settings.new_browser_tab(
            s.src.call,
            s.station,
            user_ids,
            failed_said(@sf.t("web-pages.screen.openBrowserWhat")),
          )
          let nu = screen_ui(screen_key(s.station, target))
          nu.address_asked.set(nu.address_asked.untracked() + 1)
          go_page(Screen({ station: s.station, screen: target, title: "", until_gone: false }))
        }
        if can_term && can_browse {
          menu_items.push(Some(@sf.menu_item_of(@sf.t("web-pages.remote.newSession"), icon="plus", further=true, fn() {
            @sf.menu(
              [
                Some(@sf.menu_item_of(@sf.t("web-pages.terminal.new"), icon="terminal", open_new_terminal)),
                Some(@sf.menu_item_of(@sf.t("web-pages.remote.newBrowser"), icon="web", open_new_browser)),
              ],
              from=@sf.Beside::Node(from),
              title=@sf.t("web-pages.remote.newSession"),
              along=End,
            )
          })))
        } else if can_term {
          menu_items.push(Some(@sf.menu_item_of(@sf.t("web-pages.terminal.new"), icon="plus", open_new_terminal)))
        } else if can_browse {
          menu_items.push(Some(@sf.menu_item_of(@sf.t("web-pages.remote.newBrowser"), icon="plus", open_new_browser)))
        }
      }
      if !menu_items.is_empty() {
        @sf.menu(menu_items, from=@sf.Beside::Node(from), title=label, along=End)
      }
    },
    let_go=fn() { @sfbase.let_go(s.src, scope) },
    most=@sf.open_hold_ms,
  )
  |> ignore
}

///|
/// Bottom "new remote session" row(s) for control-center `switchSession` groups (`terminal_view_node.mbt`): when both
/// terminal and browser are available, opens a submenu with 新建终端 / 新建浏览器 via
/// `@sf.panel_row_opens_node` (keeping the same icon column as sibling `panel_row_node` rows); otherwise shows the
/// single available creation row directly.
fn remote_new_session_rows_node(
  parent : @view.View,
  can_term : () -> Bool,
  can_browser : () -> Bool,
  done : () -> Unit,
  open_terminal : () -> Unit,
  open_browser : () -> Unit,
) -> Unit {
  parent.show(fn() { can_term() && can_browser() }, fn(n) {
    @sf.panel_row_opens_node(
      n,
      fn() { @sf.t("web-pages.remote.newSession") },
      fn(from) {
        let beside : @sf.Beside = match from {
          Node(r) => Node(r)
          At(x, y, w, h) => At(x, y, w, h)
          Unanchored => return
        }
        @sf.menu(
          [
            Some(@sf.menu_item_of(@sf.t("web-pages.terminal.new"), icon="terminal", fn() {
              done()
              open_terminal()
            })),
            Some(@sf.menu_item_of(@sf.t("web-pages.remote.newBrowser"), icon="web", fn() {
              done()
              open_browser()
            })),
          ],
          from=beside,
          title=@sf.t("web-pages.remote.newSession"),
          along=End,
        )
      },
      icon=fn() { "plus" },
    )
  })
  parent.show(fn() { can_term() && !can_browser() }, fn(n) {
    @sf.panel_row_node(
      n,
      fn() { @sf.t("web-pages.terminal.new") },
      fn() {
        done()
        open_terminal()
      },
      icon=fn() { "plus" },
    )
  })
  parent.show(fn() { !can_term() && can_browser() }, fn(n) {
    @sf.panel_row_node(
      n,
      fn() { @sf.t("web-pages.remote.newBrowser") },
      fn() {
        done()
        open_browser()
      },
      icon=fn() { "plus" },
    )
  })
}

///|
/// What waits for 控制中心 (center_wait) given up, nothing opened.
fn center_wait_give_up() -> Unit {
  match center_wait.val {
    Some(w) => {
      center_wait.val = None
      w.give_up()
    }
    None => ()
  }
}
