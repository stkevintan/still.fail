// A chat's own tabs beside it on 中屏 (the tape's panel, tape_side_node) and 大屏 (beside the page, side_panel_node),
// made as nodes of the window's tree (sfdesk's jobs_tab_node, letters_tab_node; sfpages' things_node): 任务's list,
// a job picked and its output, a service opening its own tab; agent 往来's chats, one opened and back; 图片、文件和链接's
// kinds, chosen here and by things_choose; 文件 and a station's 文件 (sfdesk's drive_tab_node.mbt), a folder gone into,
// a file picked and added to the draft, back to the places; and a station's page (sfpages' station_node).

///|
/// 大屏 beside the page, 中屏 the tape's panel (corners_wbtest's windows).
let side_tab_windows : Array[(String, Double, Double, Int, String)] = [
  ("wide", 1280.0, 800.0, 0, ""),
  ("medium", 800.0, 800.0, 0, ""),
]

///|
let side_tab_chat : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }

///|
/// The fixture's chat in `mode` open in window `win`, its side panel the one in use (on the tape, what shows of it at the
/// window's right tapped till it comes over: from the sidebar the page, then the panel).
fn side_tab_at(mode : String, win : (String, Double, Double, Int, String)) -> @ui.Tester raise {
  let t = screen_in(mode, win, "zh")
  if @sf.layout(win.1) is Medium {
    for _ in 0..<2 {
      if @sfdesk.wide.tape_at.get() != @sfdesk.TapePane::Panel {
        t.tap(win.1 - @sfdesk.tape_shows / 2.0, 400.0)
        t.run_for(@ui.move_most_ms)
      }
    }
    assert_eq(@sfdesk.wide.tape_at.get(), @sfdesk.TapePane::Panel)
  }
  t
}

///|
/// What the audit finds of the tabs' own nodes (their edge drawn over the panel's column, as every panel's: none of theirs).
fn side_tab_faults(t : @ui.Tester) -> Array[String] {
  t
  .audit()
  .filter(fn(f) {
    (f.contains("jobs_tab_node") || f.contains("sfdesk/letters.mbt") || f.contains("sfpages/things.mbt") || f.contains("message_static_node")) &&
    !f.contains("edge_node.mbt")
  })
}

///|
test "中屏, 大屏: 任务 beside the chat, nodes: its services and jobs, the job picked's notices; 输出 its output; a service pressed opens its own tab" {
  for win in side_tab_windows {
    let t = side_tab_at("chat-jobs-side", win)
    assert_eq(side_tab_faults(t), [], msg=win.0)
    for w in ["服务", "web", "后台任务", "在盯着 · 第 3 步通过", "gh run watch 4821 --exit-status", "第 3 步通过：单元测试全部通过", "… waiting for deploy"] {
      assert_true(t.find(w) is Some(_), msg="\{win.0}: \{w}")
    }
    t.tap_text("输出")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("第 3 步通过：单元测试全部通过") is None, msg="\{win.0}: its notices gone")
    assert_eq(side_tab_faults(t), [], msg="\{win.0}: its output")
    t.tap_text("通知")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("第 3 步通过：单元测试全部通过") is Some(_), msg="\{win.0}: its notices again")
    t.tap_text("web")
    t.run_for(@ui.move_most_ms)
    assert_true(side_now(side_tab_chat).0.contains("service:j-web"), msg="\{win.0}: \{Repr(side_now(side_tab_chat))}")
  }
}

///|
test "中屏, 大屏: agent 往来 beside the chat, nodes: the chats written with; one pressed opens its letters under its title; back to the list" {
  for win in side_tab_windows {
    let t = side_tab_at("chat-letters-side", win)
    assert_eq(side_tab_faults(t), [], msg=win.0)
    assert_true(t.find("接手监督 mbui") is Some(_), msg=win.0)
    assert_true(t.find("3 条 · 5 分钟前") is Some(_), msg=win.0)
    t.tap_text("BFT 备份尺寸分析")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("接手监督 mbui") is None, msg="\{win.0}: the list gone")
    assert_true(t.find("BFT 备份尺寸分析") is Some(_), msg="\{win.0}: its title")
    assert_true(t.find("补充一点：系统自带的 tar 能直接解 zstd") is Some(_), msg="\{win.0}: its letters")
    assert_eq(side_tab_faults(t), [], msg="\{win.0}: opened")
    t.click(Button, label=@sf.t("web-main.letters.back"))
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("接手监督 mbui") is Some(_), msg="\{win.0}: the list again")
  }
}

///|
test "中屏, 大屏: 图片、文件和链接 beside the chat, nodes: its pictures by the day; 文件 pressed its files; another chosen by things_choose as it shows" {
  for win in side_tab_windows {
    let t = side_tab_at("chat-things-side", win)
    assert_eq(side_tab_faults(t), [], msg=win.0)
    assert_true(t.find("列表高度改前改后") is Some(_), msg="\{win.0}: its pictures")
    t.tap_text("文件 2")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("build.log") is Some(_), msg="\{win.0}: its files")
    assert_true(t.find("列表高度改前改后") is None, msg="\{win.0}: its pictures gone")
    assert_eq(side_tab_faults(t), [], msg="\{win.0}: its files")
    // (its info's 全部 N 个: its pull requests, told as it shows)
    @sfpages.things_choose(side_tab_chat, "pulls")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("build.log") is None, msg="\{win.0}: its files gone")
    assert_true(t.find("首页列表按天分组") is Some(_), msg="\{win.0}: its pull requests")
  }
}

///|
/// The panel's tabs as a screen reader has them (their bar's: side_bar_node), each its name, whether it is in front,
/// and where it is.
fn side_tabs_said(t : @ui.Tester) -> Array[(String, Bool, (Double, Double, Double, Double))] {
  t.semantics().filter(fn(s) { s.role == @ui.Role::Tab && !s.hidden }).map(fn(s) { (s.label, s.selected == Some(true), s.rect) })
}

///|
test "大屏: the panel's bar, nodes: a tab pressed comes in front; one's × closes it alone, the one in front staying; its empty part drags the window" {
  // (a Mac's window: no title bar of the system's, the app's top row moving it)
  let t = wide_tester([], mode="chat-tabs-side", window_inset=true)
  t.run_for(@ui.move_most_ms)
  let tabs = side_tabs_said(t)
  assert_eq(tabs.length(), 2, msg="\{Repr(tabs)}")
  assert_eq(side_now(side_tab_chat), (["s-c1", "jobs"], "jobs"))
  let (agent, agent_front, (ax, ay, _, ah)) = tabs[0]
  assert_true(!agent_front && tabs[1].1, msg="\{Repr(tabs)}")
  // (pressed: in front)
  t.tap(ax + 16.0, ay + ah / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(side_now(side_tab_chat).1, "s-c1")
  assert_eq(side_tabs_said(t).map(fn(x) { (x.0, x.1) }), [(agent, true), (tabs[1].0, false)])
  // (任务's × behind: revealed on hover, it closes, the agent's history staying in front)
  let (jx, jy, jw, jh) = side_tabs_said(t)[1].2
  t.move_to(jx + jw / 2.0, jy + jh / 2.0)
  t.draw()
  let x = t.get(Button, label=@sf.t("web-pages.chat.closeJobs")).rect
  t.tap(x.0 + x.2 / 2.0, x.1 + x.3 / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(side_now(side_tab_chat), (["s-c1"], "s-c1"))
  assert_eq(side_tabs_said(t).map(fn(x) { (x.0, x.1) }), [(agent, true)])
  // (its empty part, past the tabs, before the panel's switch: the window's)
  let close_panel = t.get(Button, label=@sf.t("web-pages.chat.closePanel")).rect
  let (bx, _, bw, _) = side_tabs_said(t)[0].2
  let empty = (bx + bw + close_panel.0) / 2.0
  assert_true(t.drags_window_at(empty, ay + ah / 2.0), msg="the bar's empty part at \{empty}")
  assert_true(!t.drags_window_at(ax + 16.0, ay + ah / 2.0), msg="a tab")
  assert_true(!t.drags_window_at(close_panel.0 + close_panel.2 / 2.0, close_panel.1 + close_panel.3 / 2.0), msg="the switch")
}

///|
test "中屏: on the tape's panel a tab alone is its bar's title, a heading with no × of its own, the bar's close its only one; two are tabs, each its own ×" {
  let t = side_tab_at("chat-history-side", side_tab_windows[1])
  assert_eq(side_tabs_said(t), [])
  assert_eq(side_now(side_tab_chat).0.length(), 1)
  assert_true(t.query(Heading, label="Claude · Opus 5.5") is Some(_), msg="its title")
  assert_true(t.semantics().filter(fn(s) { s.role == @ui.Role::Button && s.label.has_prefix("关闭") && !s.hidden }).length() == 0, msg="no tab's ×")
  t.click(Button, label=@sf.t("web-pages.chat.closePanel"))
  t.run_for(@ui.move_most_ms)
  assert_eq(side_now(side_tab_chat).0, [])
  let t = side_tab_at("chat-tabs-side", side_tab_windows[1])
  assert_eq(side_tabs_said(t).length(), 2)
  assert_true(t.query(Button, label=@sf.t("web-pages.chat.closeJobs")) is Some(_), msg="任务's ×")
}

///|
/// `words` tapped where they are furthest right (in the panel, not the chat's or the sidebar's).
fn side_tap_rightmost(t : @ui.Tester, words : String) -> Unit {
  let at = t.locate(words)
  guard at.length() > 0 else { @halt.saying("no \{words}") }
  let mut best = at[0]
  for p in at {
    if p.0 > best.0 {
      best = p
    }
  }
  t.tap(best.0, best.1)
}

///|
/// What the audit finds of 文件's and a station's page's own nodes beside the chat (their edge drawn over the panel's
/// column, as every panel's: none of theirs).
fn side_files_faults(t : @ui.Tester) -> Array[String] {
  t
  .audit()
  .filter(fn(f) {
    (f.contains("drive_tab_node") || f.contains("drive_row_node") || f.contains("drive_views_node") || f.contains("station_node")) &&
    !f.contains("edge_node.mbt")
  })
}

///|
test "中屏, 大屏: 文件 beside the chat, nodes: its station's home, a folder gone into and starred (lit at rest), a file pressed picked, 添加 1 个 puts it into the draft; the trail's station back to the places" {
  for win in side_tab_windows {
    let t = side_tab_at("chat-files-side", win)
    assert_eq(side_files_faults(t), [], msg=win.0)
    for w in ["整个文件夹", "下载", "文档", "项目"] {
      assert_true(t.find(w) is Some(_), msg="\{win.0}: \{w}")
    }
    side_tap_rightmost(t, "文档")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("说明.txt") is Some(_), msg="\{win.0}: 文档's files")
    assert_true(t.find("下载") is None, msg="\{win.0}: the home's gone")
    // (the folder starred: its star lit at rest, the pointer gone from it, as the old tab's lit button)
    // (the fixture's 文档 kept at hand already: lit; taken off, quiet; kept again, lit)
    assert_eq(side_star_lit(t, "从个人收藏移除「文档」"), true, msg="\{win.0}: starred, lit at rest")
    t.click(Button, label="从个人收藏移除「文档」")
    t.move_to(10.0, win.2 - 10.0)
    t.run_for(@ui.move_most_ms)
    assert_eq(side_star_lit(t, "把「文档」加入个人收藏"), false, msg="\{win.0}: not starred, quiet")
    t.click(Button, label="把「文档」加入个人收藏")
    t.move_to(10.0, win.2 - 10.0)
    t.run_for(@ui.move_most_ms)
    assert_eq(side_star_lit(t, "从个人收藏移除「文档」"), true, msg="\{win.0}: starred again, lit at rest")
    side_tap_rightmost(t, "说明.txt")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("添加 1 个") is Some(_), msg="\{win.0}: picked")
    assert_eq(side_files_faults(t), [], msg="\{win.0}: a file picked")
    side_tap_rightmost(t, "添加 1 个")
    t.run_for(@ui.move_most_ms)
    assert_true(draft_files().contains("说明.txt"), msg="\{win.0}: \{draft_files()}")
    assert_true(t.find("添加 1 个") is None, msg="\{win.0}: the picks let go")
    side_tap_rightmost(t, "Willow")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("整个文件夹") is None, msg="\{win.0}: the places")
    assert_eq(side_files_faults(t), [], msg="\{win.0}: the places")
  }
}

///|
test "中屏, 大屏: a station's 文件 and its page beside the chat, nodes: its home's folders; its page's head and parts, laid out by the panel's width, 设置 pressed" {
  for win in side_tab_windows {
    let t = side_tab_at("chat-drive-side", win)
    assert_eq(side_files_faults(t), [], msg=win.0)
    assert_true(t.find("文档") is Some(_), msg="\{win.0}: its home's folders")
    let t = side_tab_at("chat-station-side", win)
    assert_eq(side_files_faults(t), [], msg=win.0)
    assert_true(t.find("概览") is Some(_), msg="\{win.0}: its parts")
    // (laid out by the panel's width, as page_node's look has it: 大屏's panel narrow, a section's heading alone; the
    // tape's wide, a section's box of its own made where the page asks for it, section_node's wide way)
    // (its words' own place, the first of what sources_of says)
    let asked = t.sources_of("资源").split("\n").next().map(fn(l) { l.to_owned() }).unwrap_or("")
    let wide_section = asked.contains("sfpages/station_node.mbt")
    assert_eq(wide_section, win.0 == "medium", msg="\{win.0}: \{asked}")
    side_tap_rightmost(t, "设置")
    t.run_for(@ui.move_most_ms)
    assert_eq(side_files_faults(t), [], msg="\{win.0}: 设置")
  }
}

///|
/// Whether the button named `label` is drawn lit at rest: its ground the accent's lit tint (icon_button_node's `on`).
fn side_star_lit(t : @ui.Tester, label : String) -> Bool {
  guard t.query(Button, label~) is Some(n) else { return false }
  let (x, y, w, h) = n.rect
  let lit = @sf.alpha(@sf.theme().p.accent, 0.08)
  t.drawn_rects().iter().any(fn(r) { (r.0 - x).abs() < 1.0 && (r.1 - y).abs() < 1.0 && (r.2 - w).abs() < 1.0 && (r.3 - h).abs() < 1.0 && r.4 == lit })
}
