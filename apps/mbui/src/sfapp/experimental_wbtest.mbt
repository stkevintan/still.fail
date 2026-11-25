// 设置 › 实验性功能 (sfpages' experimental.mbt, settings' features.mbt over the core's features.ts): the device's last
// row, saying how many are on; found by the settings' search by each switch's words; each switch taking effect at once
// where what it changes is shown (看板 put back to the list on 小屏, 中屏 and 大屏), and a station's own features (远程终端, 迁移)
// as that station's channel says, whatever the app's. (A mode's -stable is an app and Willow both on stable.)

///|
/// The app over `mode` in a window `w` × `h` (`platform`: 2 a phone's), what the mode opens open, at rest.
fn exp_at(mode : String, w : Double, h : Double, platform? : Int = 0) -> (@ui.Tester, Source) {
  new_run()
  let src = fixture(mode)
  open_fixture_over(mode, src)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform~)
  t.run_for(@ui.move_most_ms)
  (t, src)
}

///|
/// The switches of 实验性功能 turned on (`on`) or off as the core is asked, at rest.
fn exp_set(t : @ui.Tester, src : Source, ids : Array[String], on : Bool) -> Unit {
  let m : Map[String, Json] = Map([])
  for id in ids {
    m[id] = if on { Json::boolean(true) } else { Json::null() }
  }
  (src.call)("prefs.set", { "experimental": Json::object(m) }, fn(_) {  })
  t.run_for(@ui.move_most_ms)
}

///|
/// 实验性功能 opened over what is shown, `label`'s switch pressed, and back to what was shown.
fn exp_pressed(t : @ui.Tester, label : String) -> Unit raise {
  app.nav.push(Settings)
  app.nav.push(Setting(@settings.Route::Experimental))
  t.draw()
  t.run_for(@ui.move_most_ms)
  t.click(Switch, label~)
  t.run_for(@ui.move_most_ms)
  app.nav.pop() |> ignore
  app.nav.pop() |> ignore
  t.run_for(@ui.move_most_ms)
}

///|
/// Words `w`'s top, as drawn.
fn exp_top(t : @ui.Tester, w : String) -> Double raise {
  guard t.rect_of(w) is Some((_, y, _, _)) else { fail("no \{w} drawn: " + t.words().map(fn(x) { x.0 }).join("|")) }
  y
}

///|
test "设置: 实验性功能 the device's last row, under 本机缓存 and over 关于, 已开 N 项 as some are on, on a small screen's page and a large one's sidebar" {
  for large in [false, true] {
    let (t, src) = if large {
      let held : Ref[Source?] = Ref(None)
      let t = wide_tester([], mode="settings", h=1200.0, before=fn(s) { held.val = Some(s) })
      t.key(@ui.key_of_char(','), mods=@ui.mod_cmd)
      t.run_for(@ui.move_most_ms)
      (t, held.val.unwrap())
    } else {
      exp_at("settings-home", 390.0, 2400.0, platform=2)
    }
    let at = if large { "large" } else { "small" }
    assert_true(exp_top(t, "本机缓存") < exp_top(t, "实验性功能"), msg="\{at}: under 本机缓存")
    assert_true(exp_top(t, "实验性功能") < exp_top(t, "关于"), msg="\{at}: over 关于")
    assert_true(t.find("已开 2 项") is None && t.find("已开 1 项") is None, msg="\{at}: none on, no count")
    exp_set(t, src, ["board", "selectionIntent"], true)
    assert_true(t.find("已开 2 项") is Some(_), msg="\{at}: two on")
    exp_set(t, src, ["board"], false)
    assert_true(t.find("已开 1 项") is Some(_), msg="\{at}: one on")
  }
}

///|
test "实验性功能's page: its switches, each off by default and on and off as pressed, kept in the core's prefs; audit clean on a phone and a large window" {
  for win in [(390.0, 844.0, 2), (1280.0, 800.0, 0)] {
    let (w, h, platform) = win
    let (t, src) = exp_at("settings-experimental", w, h, platform~)
    let at = "\{w}"
    let kept = fn(id : String) { field(field(src.topic("prefs", {}).get().value, "experimental"), id) is Some(True) }
    for label in ["对话列表看板视图", "戳一下", "按住 ⌘/Ctrl 点击引用文本"] {
      assert_true(t.query(Switch, label~) is Some(_), msg="\{at}: \{label}")
    }
    // (those three alone: the new chat page, its composer and the new-chat page are the only ones, no switch of their own)
    assert_eq(t.all(Switch).length(), 3, msg="\{at}: \{Repr(t.all(Switch).map(fn(n) { n.label }))}")
    assert_true(t.query(Switch, label="试用新对话页") is None, msg="\{at}: no 试用新对话页")
    assert_true(t.query(Switch, label="试用新输入框") is None, msg="\{at}: no 试用新输入框")
    assert_true(!kept("board") && !kept("selectionIntent") && !kept("cmdQuote"), msg="\{at}: all off by default")
    // (but the wide frame's own: the sidebar's edge over what its pane shows by 6, sfdesk/pane_view.mbt's, as
    // station_move_wbtest's move_audit has it)
    let faults = t.audit().filter(fn(f) { !f.contains("ui/src/controls/edge_node.mbt:37, in what was asked for at stillfail/src/sfdesk/pane_view.mbt:") })
    assert_true(faults.is_empty(), msg="\{at}: " + faults.join("\n"))
    t.click(Switch, label="对话列表看板视图")
    t.run_for(@ui.move_most_ms)
    assert_true(kept("board"), msg="\{at}: 看板 on")
    t.click(Switch, label="对话列表看板视图")
    t.run_for(@ui.move_most_ms)
    assert_false(kept("board"), msg="\{at}: 看板 off again")
  }
}

///|
test "settings search finds each experimental switch by its words, on 实验性功能; 外观 no longer has 试用新对话页" {
  for words in ["对话列表看板视图", "戳一下"] {
    let t = settings_search_tester(390.0, 2)
    t.tap_text("搜索设置")
    t.type_text(words)
    // (what the change brings or takes away makes its way, the list's: looked at once that is over)
    t.run_for(@ui.move_most_ms)
    assert_true(t.find(words) is Some(_), msg=words)
    t.tap_text(words)
    t.run_for(@ui.move_most_ms)
    assert_true(app.nav.top() == Setting(@settings.Route::Experimental), msg=words)
  }
  let (t, _) = exp_at("settings-appearance", 390.0, 2400.0, platform=2)
  assert_true(t.find("主题") is Some(_), msg="外观")
  assert_true(t.find("试用新对话页") is None, msg="外观 without it")
  let (t, _) = exp_at("settings-experimental", 390.0, 2400.0, platform=2)
  assert_true(t.find("对话列表看板视图") is Some(_), msg="实验性功能")
  assert_true(t.find("试用新对话页") is None, msg="实验性功能 without it")
}

///|
test "看板 off by default on 小屏, 中屏 and 大屏: no key to it (none in the rail); turned on, there; on the board and turned off, Home back to its list at once" {
  for win in [(390.0, 844.0, 2), (800.0, 800.0, 0), (1280.0, 800.0, 0)] {
    let (w, h, platform) = win
    let (t, src) = exp_at("home", w, h, platform~)
    let at = "\{w}"
    assert_true(t.query(Button, label="看板") is None, msg="\{at}: no 看板 by default")
    // (on 小屏 by its switch in 实验性功能; on the wide frames as the core keeps the switch pressed there, the settings
    // there a page of the pane's of their own: exp_pressed's)
    let turn = fn(on : Bool) raise {
      if platform == 2 {
        exp_pressed(t, "对话列表看板视图")
      } else {
        exp_set(t, src, ["board"], on)
      }
    }
    turn(true)
    assert_true(t.query(Button, label="看板") is Some(_), msg="\{at}: 看板 once on: " + t.semantics().map(fn(n) { n.label }).join("|"))
    t.click(Button, label="看板")
    t.run_for(@ui.move_most_ms)
    assert_true(@sfbase.board_on_now(src), msg="\{at}: on the board")
    // (小屏: Home's own 列表; 中屏 and 大屏: the rail's 对话 and 看板, no 列表 in the board's bar; on the tape (中屏) the
    // rail is the sidebar's, beside the board's panel brought over)
    if platform == 2 {
      assert_true(t.query(Button, label="列表") is Some(_), msg="\{at}: its way back to the list")
    } else {
      assert_true(t.query(Button, label="列表") is None, msg="\{at}: no 列表")
      assert_eq(@sfdesk.lit_place(), "board")
      if !@sfdesk.wide.tape.get() {
        assert_true(t.query(Button, label="对话") is Some(_) && t.query(Button, label="看板") is Some(_), msg="\{at}: the rail's")
      }
    }
    // turned off while it shows: the list again, with nothing pressed
    turn(false)
    assert_false(@sfbase.board_on_now(src), msg="\{at}: off: not the board")
    assert_true(t.query(Button, label="看板") is None && t.query(Button, label="列表") is None, msg="\{at}: no key either way")
    assert_true(t.find("整理发布清单") is Some(_), msg="\{at}: the chats' list shown")
    let faults = board_faults(t)
    assert_true(faults.is_empty(), msg="\{at}: " + faults.join("\n"))
  }
}

///|
test "a stable station: its page has no terminals (屏幕与浏览器), the test channel's has them; both ⋯ offer 迁移到另一台 station (moving graduated)" {
  let calls : Array[Made] = []
  let t = move_tester(calls, "settings-station-terminals")
  assert_true(t.find("屏幕、浏览器与终端") is Some(_), msg="beta: " + move_all_words(t))
  let t = move_tester(calls, "settings-station-terminals-stable")
  assert_true(t.find("屏幕与浏览器") is Some(_), msg="stable: " + move_all_words(t))
  assert_true(t.find("屏幕、浏览器与终端") is None, msg="stable: " + move_all_words(t))
  // 迁移: its ⋯'s 迁移到另一台 station, on either channel (its overview's `move.offered`; its page's row is what a move left
  // there: station_move_wbtest's)
  let t = move_tester(calls, "settings-station-move-offered")
  t.click(Button, label="更多")
  t.run_for(@ui.move_most_ms)
  assert_true(move_said(t, "迁移到另一台 station"), msg="beta: " + move_all_words(t))
  let t = move_tester(calls, "settings-station-move-offered-stable")
  t.click(Button, label="更多")
  t.run_for(@ui.move_most_ms)
  assert_true(move_said(t, "迁移到另一台 station"), msg="stable: " + move_all_words(t))
  assert_true(move_said(t, "从 workspace 移除"), msg="stable: its ⋯ as ever: " + move_all_words(t))
}

///|
test "a station's terminals are as the station's channel says, never the app's, and its 迁移 as the station offers it: a stable app sees a beta station's, a beta app a stable one's 迁移 but no terminals" {
  let calls : Array[Made] = []
  // the app on stable, Willow on the test channel
  let t = move_tester(calls, "settings-station-terminals-stable")
  @settings.fixture_station_channel(true)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("屏幕、浏览器与终端") is Some(_), msg="stable app, beta station: " + move_all_words(t))
  let t = move_tester(calls, "settings-station-move-offered-stable")
  @settings.fixture_station_channel(true)
  t.run_for(@ui.move_most_ms)
  t.click(Button, label="更多")
  t.run_for(@ui.move_most_ms)
  assert_true(move_said(t, "迁移到另一台 station"), msg="stable app, beta station: " + move_all_words(t))
  // the app on the test channel, Willow on stable
  let t = move_tester(calls, "settings-station-terminals")
  @settings.fixture_station_channel(false)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("屏幕与浏览器") is Some(_) && t.find("屏幕、浏览器与终端") is None, msg="beta app, stable station: " + move_all_words(t))
  let t = move_tester(calls, "settings-station-move-offered")
  @settings.fixture_station_channel(false)
  t.run_for(@ui.move_most_ms)
  t.click(Button, label="更多")
  t.run_for(@ui.move_most_ms)
  assert_true(move_said(t, "迁移到另一台 station"), msg="beta app, stable station: " + move_all_words(t))
}

///|
test "a stable app's 实验性功能: 对话列表看板视图 present, graduated/removed switches absent" {
  let (t, _) = exp_at("settings-experimental-stable", 390.0, 844.0, platform=2)
  assert_true(t.query(Switch, label="对话列表看板视图") is Some(_), msg="stable: " + t.words().map(fn(x) { x.0 }).join("|"))
  assert_true(t.query(Switch, label="试用新对话页") is None, msg="stable: no 试用新对话页")
}

///|
test "中屏 and 大屏: 看板 turned off from 实验性功能 while the board was Home's: 实验性功能 stays where it is; back, Home's list, not the board" {
  for win in [(800.0, 800.0, 0), (1280.0, 800.0, 0)] {
    let (w, h, platform) = win
    let (t, src) = exp_at("home", w, h, platform~)
    let at = "\{w}"
    exp_set(t, src, ["board"], true)
    t.click(Button, label="看板")
    t.run_for(@ui.move_most_ms)
    assert_true(@sfbase.board_on_now(src), msg="\{at}: on the board")
    app.nav.push(Settings)
    app.nav.push(Setting(@settings.Route::Experimental))
    t.draw()
    t.run_for(@ui.move_most_ms)
    let panel = @sfdesk.wide.tape_at.get()
    t.click(Switch, label="对话列表看板视图")
    t.run_for(@ui.move_most_ms)
    assert_true(app.nav.top() == Setting(@settings.Route::Experimental), msg="\{at}: still on 实验性功能")
    assert_true(@sfdesk.wide.tape_at.get() == panel, msg="\{at}: the tape's panel where it was")
    assert_false(@sfbase.board_on_now(src), msg="\{at}: the board off")
    // back to the chats (返回会话 where the settings have it beside them, else the stack's back)
    match t.query(Button, label="返回会话") {
      Some(_) => t.click(Button, label="返回会话")
      None => {
        app.nav.pop() |> ignore
        app.nav.pop() |> ignore
      }
    }
    t.run_for(@ui.move_most_ms)
    assert_false(@sfbase.board_on_now(src), msg="\{at}: back, not the board")
    assert_true(t.query(Button, label="看板") is None && t.query(Button, label="列表") is None, msg="\{at}: no key either way")
    assert_true(t.find("整理发布清单") is Some(_), msg="\{at}: the chats' list")
  }
}

///|
test "设置: no 实验性功能 row where the core says the channel shows none (experimentalItems empty), on a small screen and a large one" {
  for win in [(390.0, 2400.0, 2), (1280.0, 2400.0, 0)] {
    let (w, h, platform) = win
    new_run()
    let base = fixture("settings-home")
    let src : Source = {
      ..base,
      topic_read: fn(name, params) {
        let got = base.topic(name, params).get().snapshot()
        match (name, got.value) {
          ("prefs", Some(Object(m))) => {
            let m = m.copy()
            m["experimentalItems"] = Json::array([])
            { ..got, value: Some(Json::object(m)) }
          }
          _ => got
        }
      },
    }
    open_fixture_over("settings-home", src)
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform~)
    t.run_for(@ui.move_most_ms)
    if w > 1000.0 {
      app.nav.push(Settings)
      t.draw()
      t.run_for(@ui.move_most_ms)
    }
    assert_true(t.find("本机缓存") is Some(_), msg="\{w}: the device's rows")
    assert_true(t.find("实验性功能") is None, msg="\{w}: no 实验性功能 row")
  }
}

///|
test "迁移's page opened by its route stays on a stable station as on the test channel's (moving graduated)" {
  let calls : Array[Made] = []
  let t = move_tester(calls, "settings-station-move")
  assert_true(app.nav.top() is Setting(StationMove(_)), msg="beta: 迁移's page")
  assert_true(move_said(t, "迁到"), msg="beta: " + move_all_words(t))
  let t = move_tester(calls, "settings-station-move-stable")
  assert_true(app.nav.top() is Setting(StationMove(_)), msg="stable: 迁移's page")
  assert_true(move_said(t, "迁到"), msg="stable: " + move_all_words(t))
}

///|
/// The thin lines drawn (2 high at most, 60 wide at least).
fn exp_rules(t : @ui.Tester) -> Int {
  t.drawn_rects().filter(fn(d) { d.3 <= 2.0 && d.2 >= 60.0 }).length()
}

///|
test "a station's ⋯: one line, over what takes it away, never two, on the test channel and a stable station, up or away, on a phone and a large window" {
  for mode in ["settings-station-move-offered", "settings-station-move-offered-stable", "settings-station-away", "settings-station-offline"] {
    for win in [(390.0, 844.0, 2), (1280.0, 800.0, 0)] {
      let (w, h, platform) = win
      let calls : Array[Made] = []
      let t = move_tester(calls, mode, w~, h~, platform~)
      let before = exp_rules(t)
      t.click(Button, label="更多")
      t.run_for(@ui.move_most_ms)
      assert_true(move_said(t, "从 workspace 移除"), msg="\{mode} \{w}: " + move_all_words(t))
      assert_eq(exp_rules(t) - before, 1, msg="\{mode} \{w}: one line in its menu")
    }
  }
}
