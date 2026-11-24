// Moving a station's things to another, module by module (sfpages station_move_node.mbt, the core's `stationMove`): its
// ⋯'s 迁移到另一台 station only where it is online and offers moving, its page a step further in; the station it goes to chosen
// in one row before anything else shows; the modules that have items in their order with their needs and their counts;
// one open by itself, its items each in its state with its action at its end, why under it; nothing but 停止 while a
// turn runs; each press the core's call with what it needs (the settings' fixture refuses one without it), a refusal
// said on the row pressed; 全部迁移 asked once, naming the station and how many; its station's page showing 迁移 only
// while something of it is not simply here.

///|
/// Willow in the fixture's `mode` (settings-station-move…), its calls kept in `calls`, on a phone's screen unless said.
fn move_tester(calls : Array[Made], mode : String, w? : Double = 390.0, h? : Double = 844.0, platform? : Int = 2) -> @ui.Tester {
  let t = wide_tester(calls, mode~, w~, h~, platform~)
  open_fixture_mode(mode)
  t.draw()
  t.run_for(@ui.move_most_ms)
  t
}

///|
/// Every rule at once (t.audit), each fault said where it fails.
fn move_audit(t : @ui.Tester, at : String) -> Unit {
  // (but the wide frame's own: the sidebar's edge over what its pane shows by 6, sfdesk/pane_view.mbt's, which the
  // station's page has too, this page none of its own)
  let faults = t.audit().filter(fn(f) { !f.contains("ui/src/controls/edge_node.mbt:37, in what was asked for at stillfail/src/sfdesk/pane_view.mbt:") })
  if faults.length() > 0 {
    @halt.saying(at + ": " + faults.join("\n"))
  }
}

///|
/// The words drawn (an action's place kept empty while a turn runs is not: drawn faded to nothing).
fn move_seen(t : @ui.Tester) -> Array[(String, Double, Double, Double, Double, Double)] {
  t.words().filter(fn(x) { x.5 > 0.01 })
}

///|
fn move_said(t : @ui.Tester, w : String) -> Bool {
  move_seen(t).iter().any(fn(x) { x.0 == w })
}

///|
fn move_all_words(t : @ui.Tester) -> String {
  t.words().map(fn(x) { x.0 }).join("|")
}

///|
/// Words `w`, drawn as words of their own: (x, y, width, height).
fn move_at(t : @ui.Tester, w : String) -> (Double, Double, Double, Double) {
  match move_seen(t).iter().find_first(fn(x) { x.0 == w }) {
    Some(x) => (x.1, x.2, x.3, x.4)
    None => @halt.saying("no words \"\{w}\": " + move_all_words(t))
  }
}

///|
/// Presses words `w` (the `nth` drawn so), and lets what it opens come.
fn move_press(t : @ui.Tester, w : String, nth? : Int = 0) -> Unit {
  let found = move_seen(t).filter(fn(x) { x.0 == w })
  guard nth < found.length() else { @halt.saying("no words \"\{w}\" to press: " + move_all_words(t)) }
  let x = found[nth]
  t.tap(x.1 + x.3 / 2.0, x.2 + x.4 / 2.0)
  t.draw()
  t.run_for(@ui.move_most_ms)
}

///|
/// The page scrolled down by `dy`, at rest.
fn move_scroll(t : @ui.Tester, dy : Double, x? : Double = 195.0) -> Unit {
  t.wheel(x, 500.0, dy)
  t.run_for(@ui.move_most_ms)
}

///|
/// Words `w` on the first line of the row `label` names, after it: (x, y, width, height).
fn move_on(t : @ui.Tester, w : String, label : String) -> (Double, Double, Double, Double) {
  let l = move_at(t, label)
  let mid = l.1 + l.3 / 2.0
  match move_seen(t).iter().find_first(fn(x) { x.0 == w && x.1 > l.0 + l.2 && (x.2 + x.4 / 2.0 - mid).abs() <= 2.0 }) {
    Some(x) => (x.1, x.2, x.3, x.4)
    None => @halt.saying("no \"\{w}\" on \"\{label}\"'s line: " + move_all_words(t))
  }
}

///|
/// Presses words `w` on the first line of the row `label` names, and lets what it does come.
fn move_press_on(t : @ui.Tester, w : String, label : String) -> Unit {
  let x = move_on(t, w, label)
  t.tap(x.0 + x.2 / 2.0, x.1 + x.3 / 2.0)
  t.draw()
  t.run_for(@ui.move_most_ms)
}

///|
/// `label` chosen in what is put up over the page (a menu, a sheet of it, a question), and what that opens let come.
fn move_pick(t : @ui.Tester, label : String) -> Unit raise {
  let over = try t.get(Dialog) catch { _ => t.get(Menu) }
  t.click(Button, label~, within=over) catch {
    _ => t.click(MenuItem, label~, within=over)
  }
  t.draw()
  t.run_for(@ui.move_most_ms)
}

///|
fn move_calls(calls : Array[Made], name : String) -> Array[Json] {
  calls.filter(fn(m) { m.name == name }).map(fn(m) { m.params })
}

///|
test "its ⋯: 迁移到另一台 station only while the station offers moving; pressed, its page a step further in" {
  // (a station that does not offer it: no such row, nothing asked of it)
  let calls : Array[Made] = []
  let t = move_tester(calls, "settings-station")
  t.click(Button, label="更多")
  t.run_for(@ui.move_most_ms)
  move_audit(t, "")
  assert_true(move_said(t, "从 workspace 移除"), msg=move_all_words(t))
  assert_true(!move_said(t, "迁移到另一台 station"), msg=move_all_words(t))
  // one that offers it
  let calls : Array[Made] = []
  let t = move_tester(calls, "settings-station-move-offered")
  assert_true(!move_said(t, "迁移"), msg="nothing of it moved: no 迁移 on its page: " + move_all_words(t))
  t.click(Button, label="更多")
  t.run_for(@ui.move_most_ms)
  move_audit(t, "")
  assert_true(move_said(t, "迁移到另一台 station"), msg=move_all_words(t))
  move_press(t, "迁移到另一台 station")
  move_audit(t, "")
  assert_true(move_said(t, "迁移 · Willow") || move_said(t, "迁移"), msg=move_all_words(t))
  assert_true(move_said(t, "迁到"), msg=move_all_words(t))
  // offline: none
  let calls : Array[Made] = []
  let t = move_tester(calls, "settings-station-away")
  @settings.fixture_move(stage="")
  t.draw()
  t.click(Button, label="更多")
  t.run_for(@ui.move_most_ms)
  assert_true(!move_said(t, "迁移到另一台 station"), msg=move_all_words(t))
}

///|
test "no station chosen: the row to choose it alone, its choices each with its room; chosen, kept on this device and the modules shown" {
  let calls : Array[Made] = []
  let t = move_tester(calls, "settings-station-move-none")
  move_audit(t, "")
  assert_true(move_said(t, "迁到") && move_said(t, "选择 station"), msg=move_all_words(t))
  assert_true(!move_said(t, "账号") && !move_said(t, "聊天") && !move_said(t, "全部迁移"), msg="nothing else till one is chosen: " + move_all_words(t))
  move_press(t, "选择 station")
  assert_true(move_said(t, "Maple") && move_said(t, "空闲 120 GB") && move_said(t, "Cedar") && move_said(t, "空闲 2.1 TB"), msg=move_all_words(t))
  // (Birch, offline: after them, faint, why under it; pressed, nothing chosen)
  assert_true(move_said(t, "Birch") && move_said(t, "离线：它上线后可选"), msg=move_all_words(t))
  assert_true(move_at(t, "Cedar").1 < move_at(t, "Birch").1, msg=move_all_words(t))
  move_press(t, "Birch")
  assert_eq(move_calls(calls, "prefs.set").length(), 0)
  move_press(t, "Maple")
  move_audit(t, "")
  assert_eq(move_calls(calls, "prefs.set").map(fn(p) { text(field(Some(p), "moveTo"), "ws1/st1") }), ["st2"])
  assert_true(move_said(t, "Maple") && move_said(t, "账号") && move_said(t, "聊天"), msg=move_all_words(t))
  // none it may go to: each other station still listed, saying why and what makes it one, none to be chosen
  let calls : Array[Made] = []
  let t = move_tester(calls, "settings-station-move-none")
  @settings.fixture_move(stage="half", targets=false)
  t.draw()
  t.run_for(@ui.move_most_ms)
  assert_true(move_said(t, "选择 station") && !move_said(t, "没有可迁往的 station"), msg=move_all_words(t))
  move_press(t, "选择 station")
  assert_true(move_said(t, "正式版：在它的「软件与更新」里打开「测试版」后可选") && move_said(t, "离线：它上线后可选"), msg=move_all_words(t))
  move_press(t, "Maple")
  assert_eq(move_calls(calls, "prefs.set").length(), 0)
}

///|
test "the modules one card, a row each in their order: its name, done of total and its one action on its first line, what it needs under it; those with items all on a wide window, none empty" {
  // (wide, nothing open, nothing moving: every module's row shows at once)
  let calls : Array[Made] = []
  let t = move_tester(calls, "settings-station-move", w=1280.0, h=800.0, platform=0)
  move_audit(t, "1280")
  // (in the order the core gives them, move.ts MODULES: 连接 between 账号 and 仓库缓存 checked apart, the settings'
  // sidebar having a row of it too; 后台任务 has nothing here)
  let names = ["账号", "仓库缓存", "密钥库", "Station 设置", "聊天"]
  for i in 1..<names.length() {
    assert_true(move_at(t, names[i - 1]).1 < move_at(t, names[i]).1, msg="1280: \{names[i]}: " + move_all_words(t))
  }
  // (连接 is the settings' sidebar's row too beside it: two of it, the module's between 账号 and 仓库缓存, on the card)
  assert_true(
    t.words().iter().any(fn(x) { x.0 == "连接" && x.1 > move_at(t, "账号").0 - 2.0 && x.2 > move_at(t, "账号").1 && x.2 < move_at(t, "仓库缓存").1 }),
    msg="1280: " + move_all_words(t),
  )
  // (后台任务 has nothing: not shown)
  assert_true(!move_said(t, "后台任务") && !move_said(t, "空"), msg="1280: " + move_all_words(t))
  assert_true(move_said(t, "0 / 2"), msg=move_all_words(t))
  // (one card: its rows closer than cards of their own would stand)
  let a = move_at(t, "账号")
  let b = move_at(t, "仓库缓存")
  assert_true(b.1 - a.1 < 140.0, msg="1280: a row each on one card: \{a.1} \{b.1}")
  for size in [(390.0, 844.0, 2), (1280.0, 800.0, 0)] {
    let (w, h, platform) = size
    let calls : Array[Made] = []
    let t = move_tester(calls, "settings-station-move", w~, h~, platform~)
    move_audit(t, "\{w}")
    for x in ["2 / 3", "1 / 1", "0 / 1", "2 / 4"] {
      assert_true(move_said(t, x), msg="\{w}: \{x}: " + move_all_words(t))
    }
    assert_eq(move_seen(t).filter(fn(x) { x.0 == "迁回" }).length(), 1, msg="\{w}: 密钥库 all there: " + move_all_words(t))
    assert_eq(t.words().filter(fn(x) { x.0.has_suffix("…") }).map(fn(x) { x.0 }), [], msg="\{w}")
    // (the page's main action at the end of the row it goes to)
    let to = move_at(t, "迁到")
    let all = move_at(t, "全部迁移")
    assert_true((all.1 + all.3 / 2.0 - (to.1 + to.3 / 2.0)).abs() <= 2.0, msg="\{w}: 全部迁移 on its first card's line")
    move_scroll(t, 300.0, x=w - 200.0)
    move_audit(t, "\{w} scrolled")
    assert_true(t.find("依赖 账号、连接、仓库缓存、密钥库") is Some(_), msg="\{w}: " + move_all_words(t))
    // (closed: nothing of it moving, failed or stopped)
    assert_true(!move_said(t, "整理发布清单"), msg="\{w}: " + move_all_words(t))
    let chats = move_at(t, "聊天")
    let count = move_at(t, "2 / 5")
    assert_true((count.1 + count.3 / 2.0 - (chats.1 + chats.3 / 2.0)).abs() <= 2.0, msg="\{w}: its count on its first line: \{count.1} \{chats.1}")
    assert_true(count.0 > chats.0 + chats.2, msg="\{w}: its count at its end")
    match t.words().iter().find_first(fn(x) { x.0.has_prefix("依赖 账号") }) {
      Some(x) => assert_true(x.2 > chats.1 + chats.3 - 1.0, msg="\{w}: what it needs under its name")
      None => @halt.saying("\{w}: no needs line: " + move_all_words(t))
    }
    // (its action on its first line, after its count)
    let act = move_on(t, "迁移", "聊天")
    assert_true(act.0 > count.0 + count.2, msg="\{w}: 迁移 after its count")
  }
  // every module empty: the card's one line
  let calls : Array[Made] = []
  let t = move_tester(calls, "settings-station-move-empty")
  move_audit(t, "empty")
  assert_true(move_said(t, "没有要迁移的") && !move_said(t, "账号") && !move_said(t, "全部迁移"), msg=move_all_words(t))
}

///|
test "a module with something moving opens by itself: what moves now over it, each item where it stands at its end and why under it" {
  for size in [(390.0, 844.0, 2), (1280.0, 800.0, 0)] {
    let (w, h, platform) = size
    let calls : Array[Made] = []
    let t = move_tester(calls, "settings-station-move-chats", w~, h~, platform~)
    move_audit(t, "\{w}")
    assert_true(move_said(t, "聊天 · 修复登录后首页闪白 · 12 MB / 40 MB"), msg="\{w}: " + move_all_words(t))
    let now = move_at(t, "聊天 · 修复登录后首页闪白 · 12 MB / 40 MB")
    let stop = move_at(t, "停止")
    assert_true((stop.1 + stop.3 / 2.0 - (now.1 + now.3 / 2.0)).abs() <= 2.0, msg="\{w}: 停止 on its line")
    move_scroll(t, 500.0, x=w - 200.0)
    move_audit(t, "\{w}")
    let states = [
      ("整理发布清单", "已迁移"),
      ("修复登录后首页闪白", "迁移中 · 12 MB / 40 MB"),
      ("发版前跑一遍回归", "已停 · 等「Slack · 星火」"),
      ("整理设计稿", "失败"),
      ("周报", "无法迁移"),
    ]
    for s in states {
      let (label, state) = s
      let l = move_at(t, label)
      let at = move_at(t, state)
      // (at the row's end, on its first line)
      assert_true(at.0 > l.0 + l.2, msg="\{w}: \{state} after \{label}")
      assert_true((at.1 + at.3 / 2.0 - (l.1 + l.3 / 2.0)).abs() <= 2.0, msg="\{w}: \{state} on \{label}'s line: \{at.1} \{l.1}")
    }
    // (why, under it)
    for s in [("整理设计稿", "Maple 的磁盘只剩 2.1 GB，这个聊天的文件要 3.4 GB：在 Maple 上腾出空间再试"), ("周报", "它的工作目录在 station 之外（/Volumes/Work）：把目录移进 station 的工作区再迁")] {
      let (_, why) = s
      assert_true(t.find(why) is Some(_), msg="\{w}: \{why}: " + move_all_words(t))
    }
    assert_true(move_said(t, "草稿"))
    // (while it runs 停止 is the only action: no 全部迁移, no module's or item's 迁移, 迁回 or 重试, nothing to choose
    // where it goes)
    for x in ["全部迁移", "迁移", "迁回", "重试"] {
      assert_true(!move_said(t, x), msg="\{w}: \{x} while a turn runs: " + move_all_words(t))
    }
    // pressed shut, and open again
    // (the station it goes to: no choice while it runs)
    move_scroll(t, -2000.0, x=w - 200.0)
    move_press(t, "迁到")
    assert_true(!move_said(t, "Cedar · 空闲 2.1 TB"), msg="\{w}: no choice while a turn runs: " + move_all_words(t))
    move_scroll(t, 500.0, x=w - 200.0)
    move_press(t, "聊天")
    assert_true(!move_said(t, "草稿"), msg="\{w}: " + move_all_words(t))
    move_press(t, "聊天")
    assert_true(move_said(t, "草稿"), msg="\{w}: " + move_all_words(t))
    // the turn ended: the actions back, the counts and states as they were
    @settings.fixture_move(stage="ended")
    t.draw()
    t.run_for(@ui.move_most_ms)
    move_audit(t, "\{w} ended")
    for x in ["迁移", "迁回", "重试"] {
      assert_true(move_said(t, x), msg="\{w}: \{x} once the turn ended: " + move_all_words(t))
    }
  }
}

///|
test "each item's own action at its row's end, after where it stands: 迁移 here, 迁回 there, 重试 failed, none stopped or where it cannot move" {
  for size in [(390.0, 844.0, 2), (1280.0, 800.0, 0)] {
    let (w, h, platform) = size
    let calls : Array[Made] = []
    let t = move_tester(calls, "settings-station-move-ended", w~, h~, platform~)
    move_scroll(t, 500.0, x=w - 200.0)
    move_audit(t, "\{w}")
    // (each at its row's end: ending where 周报's 无法迁移 ends, a row with no action)
    let end = fn(x : (Double, Double, Double, Double)) { x.0 + x.2 }
    let chats = end(move_on(t, "无法迁移", "周报"))
    for s in [("整理发布清单", "迁回"), ("整理设计稿", "重试"), ("草稿", "迁移")] {
      let (label, act) = s
      let a = move_on(t, act, label)
      assert_true((end(a) - chats).abs() <= 2.0, msg="\{w}: \{act} at \{label}'s end: \{end(a)}, 无法迁移 \{chats}")
    }
    // (a label never cut short beside where it stands: that goes under it where both have not the room)
    for label in ["发版前跑一遍回归", "周会纪要：本周发布前要逐项确认的事情和每一项的负责人"] {
      let l = move_at(t, label)
      assert_true(l.2 >= 100.0, msg="\{w}: \{label} drawn whole: \{l.2} wide")
    }
    assert_true(move_seen(t).iter().all(fn(x) { !x.0.has_suffix("…") }), msg="\{w}: " + move_all_words(t))
    // (where it stands, then its action)
    assert_true(move_on(t, "迁回", "整理发布清单").0 > move_on(t, "已迁移", "整理发布清单").0, msg="\{w}: 已迁移 then 迁回")
    assert_true(move_on(t, "重试", "整理设计稿").0 > move_on(t, "失败", "整理设计稿").0, msg="\{w}: 失败 then 重试")
    // (its action on its label's line where where it stands went under it, never across the middle of both)
    move_on(t, "迁回", "周会纪要：本周发布前要逐项确认的事情和每一项的负责人") |> ignore
    // (none where it is stopped or cannot move)
    for label in ["发版前跑一遍回归", "周报"] {
      let l = move_at(t, label)
      let mid = l.1 + l.3 / 2.0
      assert_true(
        !move_seen(t).iter().any(fn(x) { (x.0 == "迁移" || x.0 == "迁回" || x.0 == "重试") && (x.2 + x.4 / 2.0 - mid).abs() <= 2.0 }),
        msg="\{w}: no action on \{label}: " + move_all_words(t),
      )
    }
  }
}

///|
test "迁移, 迁回 and 重试 pressed: the core called with the station, where to and what; an item's at its row's end" {
  let calls : Array[Made] = []
  let t = move_tester(calls, "settings-station-move-ended")
  // (账号's 迁移: what is still here of it, its needs first; 密钥库's 迁回)
  move_press(t, "迁移")
  move_press(t, "迁回")
  let asked = @settings.fixture_move_asked.map(fn(a) {
    let p = Some(a.1)
    (a.0, text(p, "station"), text(p, if a.0 == "move.back" { "from" } else { "to" }), text(p, "module"), text(p, "item"), flag(p, "all"))
  })
  assert_eq(asked, [("move.start", "ws1/st1", "st2", "accounts", "", true), ("move.back", "ws1/st1", "st2", "vault", "", false)])
  // an item's own, at its row's end
  move_scroll(t, 500.0)
  move_audit(t, "")
  move_press_on(t, "迁移", "草稿")
  let p = Some(move_calls(calls, "move.start")[1])
  assert_eq((text(p, "to"), text(p, "module"), text(p, "item"), flag(p, "withNeeds")), ("st2", "chats", "k7", true))
  move_press_on(t, "重试", "整理设计稿")
  let p = Some(move_calls(calls, "move.start")[2])
  assert_eq((text(p, "to"), text(p, "module"), text(p, "item"), flag(p, "withNeeds")), ("st2", "chats", "k5", true))
  move_press_on(t, "迁回", "整理发布清单")
  let p = Some(move_calls(calls, "move.back")[1])
  assert_eq((text(p, "from"), text(p, "module"), text(p, "item")), ("st2", "chats", "k1"))
  // (pressing a row's name starts nothing)
  let moves = fn() { move_calls(calls, "move.start").length() + move_calls(calls, "move.back").length() }
  let before = moves()
  move_press(t, "周会纪要：本周发布前要逐项确认的事情和每一项的负责人")
  assert_eq(moves(), before)
}

///|
test "a move refused (moving off where it goes): its words on the row pressed, not in a dialog" {
  let calls : Array[Made] = []
  let t = move_tester(calls, "settings-station-move-ended")
  @settings.fixture_move(stage="ended", off=true)
  t.draw()
  t.run_for(@ui.move_most_ms)
  move_scroll(t, 500.0)
  move_press_on(t, "迁移", "草稿")
  move_audit(t, "")
  let why = "这台 station 还没开放在 station 之间迁移聊天：没有迁移任何内容。"
  match t.find(why) {
    Some(_) => ()
    None => @halt.saying("not said: " + move_all_words(t))
  }
  assert_true(move_at(t, "草稿").1 < move_at(t, why).1, msg="under the row pressed")
  assert_true(!move_said(t, "确定"), msg="no dialog: " + move_all_words(t))
}

///|
test "全部迁移 at the first card's end, asked once naming the station and how many, then the core called for all of it; 全部迁回 in its ⋯; all of it there, 移出 workspace in its place" {
  let calls : Array[Made] = []
  let t = move_tester(calls, "settings-station-move")
  move_press(t, "全部迁移")
  move_audit(t, "")
  // (how many, and on the same line how many cannot move)
  assert_true(move_said(t, "全部迁移到 Maple") && move_said(t, "9 项 · 1 项无法迁移"), msg=move_all_words(t))
  move_pick(t, "全部迁移")
  let asked = move_calls(calls, "move.start")
  assert_eq(asked.length(), 1)
  assert_eq((text(Some(asked[0]), "station"), text(Some(asked[0]), "to"), flag(Some(asked[0]), "all")), ("ws1/st1", "st2", true))
  // (its ⋯: 全部迁回 alone)
  t.click(Button, label="更多")
  t.run_for(@ui.move_most_ms)
  assert_true(move_said(t, "全部迁回"), msg=move_all_words(t))
  // (the fixture's mode puts it up too: what the sweeps see)
  let calls : Array[Made] = []
  let t = move_tester(calls, "settings-station-move-all")
  move_audit(t, "")
  assert_true(move_said(t, "全部迁移到 Maple") && move_said(t, "9 项 · 1 项无法迁移"), msg=move_all_words(t))
  // all of it there: 移出 workspace, asked as the station's ⋯ asks it
  let calls : Array[Made] = []
  let t = move_tester(calls, "settings-station-move")
  @settings.fixture_move(stage="done")
  t.draw()
  t.run_for(@ui.move_most_ms)
  move_audit(t, "done")
  assert_true(!move_said(t, "全部迁移") && move_said(t, "移出 workspace"), msg=move_all_words(t))
  move_press(t, "移出 workspace")
  assert_true(move_said(t, "移除「Willow」？"), msg=move_all_words(t))
}

///|
test "停止 at the end of what moves now: the core asked once, 正在停止… and not to be pressed again" {
  let calls : Array[Made] = []
  let t = move_tester(calls, "settings-station-move-chats")
  move_press(t, "停止")
  t.run_for(@ui.move_most_ms)
  move_audit(t, "")
  assert_eq(move_calls(calls, "move.stop").map(fn(p) { text(Some(p), "station") }), ["ws1/st1"])
  assert_true(move_said(t, "正在停止…") && !move_said(t, "停止"), msg=move_all_words(t))
  move_press(t, "正在停止…")
  assert_eq(move_calls(calls, "move.stop").length(), 1)
}

///|
test "its station's page shows one row of it only while a move runs, something is stopped or a turn failed: where, how far, what stands out, opening its page; something of it there alone, none" {
  let calls : Array[Made] = []
  let t = move_tester(calls, "settings-station-move-section")
  move_audit(t, "")
  assert_true(move_said(t, "迁移到 Maple") && move_said(t, "7 / 18"), msg=move_all_words(t))
  assert_true(t.find("1 项失败 · 1 项已停 · 迁移中 · 聊天「修复登录后首页闪白」") is Some(_), msg=move_all_words(t))
  assert_true(move_at(t, "迁移到 Maple").1 < move_at(t, "概览").1, msg="under its head, over its parts")
  // (one row: no module of it named on the station's page)
  assert_true(!move_said(t, "账号") && !move_said(t, "仓库缓存"), msg=move_all_words(t))
  let count = move_at(t, "7 / 18")
  let title = move_at(t, "迁移到 Maple")
  assert_true((count.1 + count.3 / 2.0 - (title.1 + title.3 / 2.0)).abs() <= 2.0, msg="its count on its first line")
  move_press(t, "迁移到 Maple")
  assert_true(move_said(t, "迁到"), msg=move_all_words(t))
  // (all of it here: none, the switch on or off)
  for stage in [(true, ""), (false, "")] {
    let calls : Array[Made] = []
    let t = move_tester(calls, "settings-station")
    @settings.fixture_move(offered=stage.0, stage=stage.1)
    t.draw()
    t.run_for(@ui.move_most_ms)
    assert_true(!move_said(t, "迁移") && !move_said(t, "迁移到 Maple"), msg=move_all_words(t))
  }
  // (something there alone, nothing moving, stopped or failed: none, the switch on or off; reached by its ⋯)
  for offered in [true, false] {
    let calls : Array[Made] = []
    let t = move_tester(calls, "settings-station")
    @settings.fixture_move(offered~, stage="half")
    t.draw()
    t.run_for(@ui.move_most_ms)
    assert_true(!move_said(t, "迁移") && !move_said(t, "迁移到 Maple"), msg=move_all_words(t))
  }
  // (a turn that left something stopped and something failed, the switch off: shown all the same)
  let calls : Array[Made] = []
  let t = move_tester(calls, "settings-station")
  @settings.fixture_move(offered=false, stage="ended")
  t.draw()
  t.run_for(@ui.move_most_ms)
  assert_true(move_said(t, "迁移到 Maple") && t.find("1 项失败 · 1 项已停") is Some(_), msg=move_all_words(t))
}

///|
test "an item's state takes a line more under its label where it has not the room on one, its words whole: a stopped one's at words 1.3 in English" {
  let t = screen_in("settings-station-move-chats", ("phone", 390.0, 844.0, 2, ""), "en", font_scale=1.3)
  move_audit(t, "en 1.3")
  // (聊天 the last module, its items under it: down to the stopped one)
  move_scroll(t, 400.0)
  move_audit(t, "en 1.3, scrolled")
  let words = t.words()
  // (none of it cut short, and all of it there: what it waits for, its name whole, on the line its words end on)
  assert_true(!words.iter().any(fn(x) { x.0.has_prefix("Stopped") && x.0.has_suffix("…") }), msg=move_all_words(t))
  assert_true(words.iter().any(fn(x) { x.0.has_prefix("Stopped") }), msg=move_all_words(t))
  assert_true(words.iter().any(fn(x) { x.0.has_suffix("星火”") }), msg=move_all_words(t))
  // (under its label, which is whole)
  let label = move_at(t, "发版前跑一遍回归")
  let stopped = match words.iter().find_first(fn(x) { x.0.has_prefix("Stopped") }) {
    Some(x) => x
    None => @halt.saying("no Stopped: " + move_all_words(t))
  }
  assert_true(stopped.2 > label.1, msg="under its label: \{stopped.2} \{label.1}")
}

///|
test "in English the modules and what they need are said in English, from the tables by each module's id" {
  // (as the sweeps open a screen in English: the device's language said, the fixture's mode opened)
  let t = screen_in("settings-station-move", ("phone", 390.0, 844.0, 2, ""), "en")
  move_audit(t, "en")
  for x in ["Accounts", "Vault", "Station settings", "Repository cache"] {
    assert_true(move_said(t, x), msg="\{x}: " + move_all_words(t))
  }
  move_scroll(t, 300.0)
  assert_true(t.find("Needs accounts, connects, the repository cache, the vault") is Some(_), msg=move_all_words(t))
  assert_true(t.words().iter().all(fn(x) { !x.0.contains("依赖") && x.0 != "聊天" && x.0 != "账号" }), msg=move_all_words(t))
}

///|
test "a chat's menu: 迁移到另一台 station to the workspace's owners and admins alone; its stations picked among, the one picked asked of its station (the chat by its session, with what it needs)" {
  // (one who may not move it: no such item)
  let calls : Array[Made] = []
  let t = wide_tester(calls)
  t.draw()
  let (x, y) = t.find("整理发布清单").unwrap()
  t.right_click(x, y)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("重命名") is Some(_), msg=move_all_words(t))
  assert_true(!move_said(t, "迁移到另一台 station"), msg=move_all_words(t))
  // an owner
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="home-move")
  t.draw()
  let (x, y) = t.find("整理发布清单").unwrap()
  t.right_click(x, y)
  t.run_for(@ui.move_most_ms)
  move_pick(t, "迁移到另一台 station")
  move_audit(t, "picked among")
  // (each with its room; one it may not go to faint, why under it)
  assert_true(move_said(t, "Cedar") && move_said(t, "Maple") && move_said(t, "Birch"), msg=move_all_words(t))
  assert_true(move_said(t, "离线：它上线后可选"), msg=move_all_words(t))
  assert_eq(move_calls(calls, "move.start").length(), 0)
  move_press(t, "Cedar")
  let asked = move_calls(calls, "move.start")
  assert_eq(asked.length(), 1)
  let p = Some(asked[0])
  assert_eq(
    (text(p, "station"), text(p, "to"), text(p, "module"), text(p, "item"), flag(p, "withNeeds")),
    ("ws1/st1", "st3", "chats", "s-c1", true),
  )
}

///|
test "a chat going to another station: its bar says where, its composer shut saying so; what is typed and sent goes nowhere" {
  for w in [1280.0, 390.0] {
    let calls : Array[Made] = []
    let t = wide_tester(calls, mode="chat-moving", w~, h=844.0, platform=if w < 600.0 { 2 } else { 0 })
    t.draw()
    t.run_for(@ui.move_most_ms)
    let at = "\{w}"
    assert_true(t.find("正在迁移到「Cedar」，迁完前暂不能发送") is Some(_), msg=at + ": " + move_all_words(t))
    assert_true(t.find("迁移到 Cedar") is Some(_), msg=at + ": " + move_all_words(t))
    let (x, y) = t.find("正在迁移到「Cedar」，迁完前暂不能发送").unwrap()
    t.tap(x, y)
    t.type_text("发不出去的话")
    // (send pressed where there is one to press: out of reach, nothing)
    t.click(Button, label=@sf.t("web-main.composer.send")) catch {
      _ => ()
    }
    t.run_for(@ui.move_most_ms)
    assert_eq(move_calls(calls, "chat.send").length(), 0, msg=at)
  }
}
