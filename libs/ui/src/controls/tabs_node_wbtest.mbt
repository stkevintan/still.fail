// The library's tabs (tabs_node.mbt): a tab list of tabs, the chosen one read out selected and its panel the one shown;
// a press or the arrow keys choosing (or, manual, moving the focus alone till Space or Enter); a panel kept
// (keep_mounted) keeping what it holds across another's being chosen, taking no room meanwhile; the bar or the capsule
// sliding under the chosen tab, there by move_most_ms; both looks, nothing the audit finds.

///|
/// What a tabs case keeps: its window, the tab chosen (the caller's), the keys told, how many times each panel was made.
struct Tabs2 {
  t : @ui.Tester
  chosen : @signals.Signal[String]
  told : Array[String]
  made : Map[String, Int]
}

///|
/// Tabs 对话, 文件 and 任务 (对话 chosen) in a window `w` wide, each panel's words "<name>面板", `look`, `manual` and
/// `keep_mounted` as given.
fn tabs2(look? : TabsLook = Underline, manual? : Bool = false, keep_mounted? : Bool = false, w? : Double = 600.0) -> Tabs2 {
  let chosen = @signals.signal("chat")
  let told : Array[String] = []
  let made : Map[String, Int] = Map([])
  let names = [("chat", "对话"), ("files", "文件"), ("jobs", "任务")]
  let t = w2_case(w~, fn(root) {
    tabs_node(
      root,
      fn() { "页面" },
      names.map(fn(n) { (n.0, fn() { n.1 }) }),
      fn() { chosen.get() },
      fn(k) {
        told.push(k)
        chosen.set(k)
      },
      fn(p, k) {
        made[k] = made.get(k).unwrap_or(0) + 1
        let name = names.search_by(fn(n) { n.0 == k }).map(fn(i) { names[i].1 }).unwrap_or("")
        words_node(p, fn() { name + "面板" }, fn() { paragraph }) |> ignore
      },
      look~,
      manual~,
      keep_mounted~,
    )
    |> ignore
  })
  { t, chosen, told, made }
}

///|
/// The tab read out selected, and the panels read out.
fn tabs2_said(t : @ui.Tester) -> (Array[String], Array[String]) {
  (t.all(Tab, selected=true).map(fn(s) { s.label }), t.all(TabPanel).map(fn(s) { s.label }))
}

///|
/// The bar's or the capsule's place along the list and its width, as drawn: the rectangle drawn `h` high (within half
/// a point) in the tab list's band.
fn tabs2_mark(t : @ui.Tester, h : Double) -> (Int, Int) raise {
  let list = t.get(TabList, label="页面")
  match
    t
    .drawn_rects()
    .search_by(fn(r) { (r.3 - h).abs() <= 0.5 && r.1 >= list.rect.1 - 0.5 && r.1 + r.3 <= list.rect.1 + list.rect.3 + 0.5 }) {
    Some(i) => {
      let r = t.drawn_rects()[i]
      (r.0.round().to_int(), r.2.round().to_int())
    }
    None => (-1, -1)
  }
}

///|
test "tabs: the chosen one read out selected, its panel the one read out and shown; a press on another chooses it, its panel shown in place of the other; the bar under the chosen tab, there by move_most_ms; nothing the audit finds" {
  let k = tabs2()
  assert_eq(tabs2_said(k.t), (["对话"], ["对话"]))
  assert_true(k.t.rect_of("对话面板") is Some(_))
  let tab = fn(name : String) raise {
    let r = k.t.get(Tab, label=name).rect
    (r.0.round().to_int(), r.2.round().to_int())
  }
  assert_eq(tabs2_mark(k.t, tabs_bar_h), tab("对话"))
  assert_eq(k.t.audit(), [])
  k.t.click(Tab, label="任务")
  k.t.run_for(@ui.move_most_ms)
  assert_eq(tabs2_said(k.t), (["任务"], ["任务"]))
  assert_true(k.t.rect_of("对话面板") is None && k.t.rect_of("任务面板") is Some(_))
  assert_eq(tabs2_mark(k.t, tabs_bar_h), tab("任务"))
  assert_eq(k.told, ["jobs"])
  assert_eq(k.t.audit(), [])
}

///|
test "tabs, the pill look: the lifted capsule under the chosen tab, sliding to another chosen, there by move_most_ms; nothing the audit finds" {
  for dark in [false, true] {
    set_dark(Some(dark))
    let k = tabs2(look=Pill)
    let tab = fn(name : String) raise {
      let r = k.t.get(Tab, label=name).rect
      (r.0.round().to_int(), r.2.round().to_int())
    }
    let (px, pw) = tabs2_mark(k.t, tabs_pill_h)
    assert_eq((px, pw), tab("对话"))
    let pill_rects = k.t.drawn_rects().filter(fn(r) {
      r.4 == @ui.tree_theme().lifted && (r.3 - tabs_pill_h).abs() <= 0.5 && (r.0 - px.to_double()).abs() < 1.0
    })
    assert_eq(pill_rects.length(), 1, msg="dark=\{dark}: resting tabs Pill must draw 1 lifted pill")
    let pr = pill_rects[0]
    let pill_insts = k.t.drawn_instances().filter(fn(a) {
      a.length() > 6 && a[5] == 0.0 && (a[0] - pr.0).abs() < 1.0 && (a[1] - pr.1).abs() < 1.0 && (a[2] - pr.2).abs() < 1.0 && (a[3] - pr.3).abs() < 1.0
    })
    assert_true(pill_insts.length() >= 1, msg="dark=\{dark}: resting tabs Pill rect instance must be present")
    assert_eq(pill_insts.filter(fn(a) { a[6] > 0.0 }).length(), 0, msg="dark=\{dark}: resting tabs Pill must draw zero border")
    assert_eq(k.t.drawn_instances().filter(fn(a) { a.length() > 6 && a[5] == 2.0 }).length(), 0, msg="dark=\{dark}: resting tabs Pill must draw zero shadow")
    assert_eq(k.t.audit(), [])
    k.t.click(Tab, label="文件")
    k.t.run_for(@ui.move_most_ms)
    assert_eq(tabs2_mark(k.t, tabs_pill_h), tab("文件"))
    assert_eq(k.t.audit(), [])
  }
  set_dark(None)
}

///|
test "tabs, chosen by the keys: Tab stops at the chosen tab, → and ← choose along them round the ends, Home and End the first and last" {
  let k = tabs2()
  k.t.act(Button, Focus, label="别处")
  k.t.tab()
  let at = fn() { k.t.focused().map(fn(s) { s.label }).unwrap_or("none") }
  let first = at()
  k.t.key(@ui.key_code_right)
  let right = (at(), k.chosen.get())
  k.t.key(@ui.key_code_left)
  k.t.key(@ui.key_code_left)
  let round = (at(), k.chosen.get())
  k.t.key(@ui.key_code_home)
  let home = k.chosen.get()
  k.t.key(@ui.key_code_end)
  k.t.run_for(@ui.move_most_ms)
  assert_eq(first, "对话")
  assert_eq(right, ("文件", "files"))
  assert_eq(round, ("任务", "jobs"))
  assert_eq((home, k.chosen.get()), ("chat", "jobs"))
  assert_eq(tabs2_said(k.t), (["任务"], ["任务"]))
}

///|
test "tabs, manual: the arrow keys move the focus alone, Space or Enter choosing the tab the keyboard is on" {
  let k = tabs2(manual=true)
  k.t.act(Button, Focus, label="别处")
  k.t.tab()
  k.t.key(@ui.key_code_right)
  let moved = (k.t.focused().map(fn(s) { s.label }).unwrap_or("none"), k.chosen.get())
  k.t.key(@ui.key_space)
  let spaced = k.chosen.get()
  k.t.key(@ui.key_code_right)
  k.t.enter()
  k.t.run_for(@ui.move_most_ms)
  assert_eq(moved, ("文件", "chat"))
  assert_eq((spaced, k.chosen.get()), ("files", "jobs"))
  assert_eq(tabs2_said(k.t), (["任务"], ["任务"]))
}

///|
test "tabs, kept panels: each made once and kept as another is chosen, hidden and taking no room meanwhile; not kept, made again each time its tab is chosen" {
  let kept = tabs2(keep_mounted=true)
  kept.t.click(Tab, label="文件")
  kept.t.run_for(@ui.move_most_ms)
  kept.t.click(Tab, label="对话")
  kept.t.run_for(@ui.move_most_ms)
  assert_eq(tabs2_said(kept.t), (["对话"], ["对话"]))
  assert_eq((kept.made.get("chat"), kept.made.get("files"), kept.made.get("jobs")), (Some(1), Some(1), Some(1)))
  // (the chosen one's words where they were before another was chosen: the kept ones take no room)
  let at_first = kept.t.rect_of("对话面板").unwrap()
  assert_true(kept.t.rect_of("文件面板") is None)
  assert_eq(kept.t.audit(), [])
  let plain = tabs2()
  let plain_at = plain.t.rect_of("对话面板").unwrap()
  plain.t.click(Tab, label="文件")
  plain.t.run_for(@ui.move_most_ms)
  plain.t.click(Tab, label="对话")
  plain.t.run_for(@ui.move_most_ms)
  assert_eq((plain.made.get("chat"), plain.made.get("files"), plain.made.get("jobs")), (Some(2), Some(1), None))
  assert_eq(at_first, plain_at)
}

///|
test "tabs in a phone's width, both looks: nothing the audit finds" {
  for look in [Underline, Pill] {
    let k = tabs2(look~, w=390.0)
    assert_eq(k.t.audit(), [], msg=if look is Pill { "pill" } else { "underline" })
  }
}

///|
test "tabs_node: indicator slide animation causes zero relayout (laid == 0)" {
  for look in [Underline, Pill] {
    let k = tabs2(look~, keep_mounted=true)
    k.t.click(Tab, label="任务")
    k.t.draw()
    k.t.tree_frames_from_now()
    k.t.run_for(@ui.move_most_ms)
    for f in k.t.tree_frames() {
      assert_eq(f.laid, 0, msg="tabs_node indicator slide relaid out: \{Repr(f)}")
    }
  }
}

///|
test "tabs_node: panel content enters in sync with indicator direction and settles cleanly" {
  for kept in [false, true] {
    let k = tabs2(keep_mounted=kept)
    let rest_x = k.t.rect_of("对话面板").unwrap().0
    // (switch rightward: 对话 -> 任务; panel starts shifted right (+dx) and fades in)
    k.t.click(Tab, label="任务")
    if !@ui.test_at_a_rate() {
      k.t.frame()
      let w_mid = k.t.words().iter().find_first(fn(w) { w.0 == "任务面板" }).unwrap()
      assert_true(w_mid.1 > rest_x, msg="rightward switch enters from +x: rest=\{rest_x}, mid=\{w_mid.1}")
      assert_true(w_mid.5 > 0.0 && w_mid.5 < 1.0, msg="rightward switch fades in: alpha=\{w_mid.5}")
    }
    k.t.run_for(@ui.move_most_ms)
    let w_end = k.t.words().iter().find_first(fn(w) { w.0 == "任务面板" }).unwrap()
    assert_true((w_end.1 - rest_x).abs() < 0.5, msg="settled x matches rest: rest=\{rest_x}, end=\{w_end.1}")
    assert_true((w_end.5 - 1.0).abs() < 0.01, msg="settled alpha is 1: \{w_end.5}")
    assert_eq(k.t.audit(), [])

    // (switch leftward: 任务 -> 对话; panel starts shifted left (-dx) and fades in)
    k.t.click(Tab, label="对话")
    if !@ui.test_at_a_rate() {
      k.t.frame()
      let w_left = k.t.words().iter().find_first(fn(w) { w.0 == "对话面板" }).unwrap()
      assert_true(w_left.1 < rest_x, msg="leftward switch enters from -x: rest=\{rest_x}, mid=\{w_left.1}")
      assert_true(w_left.5 > 0.0 && w_left.5 < 1.0, msg="leftward switch fades in: alpha=\{w_left.5}")
    }
    k.t.run_for(@ui.move_most_ms)
    let w_back = k.t.words().iter().find_first(fn(w) { w.0 == "对话面板" }).unwrap()
    assert_true((w_back.1 - rest_x).abs() < 0.5, msg="settled back x matches rest: rest=\{rest_x}, back=\{w_back.1}")
    assert_true((w_back.5 - 1.0).abs() < 0.01, msg="settled back alpha is 1: \{w_back.5}")
    assert_eq(k.t.audit(), [])
  }
}

///|
test "tabs_node: 1.0x and 1.3x keep exact tab height; 2.0x scales tabs and indicator with zero fixed_outgrown or squeeze_faults" {
  for look in [Underline, Pill] {
    let base_h = match look {
      Underline => tabs_line_h
      Pill => tabs_pill_h
    }
    let k = tabs2(look~)
    assert_eq(k.t.get(Tab, label="对话").rect.3, base_h, msg="1.0x tab height \{Repr(look)}")
    assert_eq(k.t.fixed_outgrown(), [], msg="1.0x fixed_outgrown \{Repr(look)}")
    assert_eq(k.t.squeeze_faults(), [], msg="1.0x squeeze_faults \{Repr(look)}")
    k.t.set_font_scale(1.3)
    k.t.draw()
    assert_eq(k.t.get(Tab, label="对话").rect.3, base_h, msg="1.3x tab height \{Repr(look)}")
    assert_eq(k.t.fixed_outgrown(), [], msg="1.3x fixed_outgrown \{Repr(look)}")
    assert_eq(k.t.squeeze_faults(), [], msg="1.3x squeeze_faults \{Repr(look)}")
    k.t.set_font_scale(2.0)
    k.t.draw()
    let h2 = k.t.get(Tab, label="对话").rect.3
    if look is Pill {
      assert_true(h2 > base_h, msg="2.0x pill tab height grew: \{h2}")
    } else {
      assert_true(h2 >= base_h, msg="2.0x underline tab height: \{h2}")
    }
    assert_eq(k.t.fixed_outgrown(), [], msg="2.0x fixed_outgrown \{Repr(look)}")
    assert_eq(k.t.squeeze_faults(), [], msg="2.0x squeeze_faults \{Repr(look)}")
    k.t.set_font_scale(3.0)
    k.t.draw()
    let h3 = k.t.get(Tab, label="对话").rect.3
    assert_true(h3 > base_h, msg="3.0x tab height grew \{Repr(look)}: \{h3}")
    assert_eq(k.t.fixed_outgrown(), [], msg="3.0x fixed_outgrown \{Repr(look)}")
    assert_eq(k.t.squeeze_faults(), [], msg="3.0x squeeze_faults \{Repr(look)}")
  }
}

///|
test "tabs_node(Pill): shared thumb primitive keeps rest 0 glass, held kind==6 lens, solid/reduced fallback, laid==0, and manual tab/panel semantics" {
  let k = tabs2(look=Pill, manual=true)
  // Rest: 0 glass, Tab & TabPanel semantics intact.
  assert_eq(k.t.drawn_glass().length(), 0, msg="Pill rest must have 0 glass")
  assert_eq(tabs2_said(k.t), (["对话"], ["对话"]))
  // Manual keyboard semantics preserved: arrow moves focus without switching, Space commits.
  k.t.act(Button, Focus, label="别处")
  k.t.tab()
  k.t.key(@ui.key_code_right)
  assert_eq(k.t.focused().map(fn(s) { s.label }), Some("文件"))
  assert_eq(k.chosen.get(), "chat")
  assert_eq(tabs2_said(k.t), (["对话"], ["对话"]))
  k.t.key(@ui.key_space)
  k.t.run_for(@ui.move_most_ms)
  assert_eq(k.chosen.get(), "files")
  assert_eq(tabs2_said(k.t), (["文件"], ["文件"]))
  // Held drag on Pill mounts 1 kind==6 clear lens (blur==0, droplet_role=3) with laid==0.
  let r_files = k.t.get(Tab, label="文件").rect
  let r_jobs = k.t.get(Tab, label="任务").rect
  let cy = r_files.1 + r_files.3 / 2.0
  k.t.press_at(r_files.0 + r_files.2 / 2.0, cy)
  k.t.run_for(part_whole_ms)
  let lenses = k.t.drawn_instances().filter(fn(i) { i[5] == 6.0 })
  assert_eq(lenses.length(), 1, msg="held Pill must emit 1 kind==6 lens")
  assert_eq(lenses[0][14], 0.0, msg="held Pill lens must have blur==0")
  assert_true((lenses[0][7] - -48.0).abs() < 0.01, msg="held Pill lens must have droplet_role=3 (slot7=-48)")
  k.t.tree_frames_from_now()
  k.t.move_to(r_jobs.0 + r_jobs.2 / 2.0, cy)
  k.t.run_for(part_whole_ms / 2.0)
  for f in k.t.tree_frames() {
    assert_eq(f.laid, 0, msg="Pill drag must not relayout: \{Repr(f)}")
  }
  // glass_solid() and reduced_motion() both drop glass to 0.
  @ui.set_glass_solid(Some(true))
  k.t.draw()
  assert_eq(k.t.drawn_glass().length(), 0, msg="glass_solid must draw 0 glass")
  @ui.set_glass_solid(None)
  k.t.set_reduce_motion(true)
  k.t.draw()
  assert_eq(k.t.drawn_glass().length(), 0, msg="reduced_motion must draw 0 glass")
  k.t.set_reduce_motion(false)
  k.t.release(r_jobs.0 + r_jobs.2 / 2.0, cy)
  k.t.run_for(@ui.move_most_ms)
  assert_eq(k.chosen.get(), "jobs")
  assert_eq(k.t.drawn_glass().length(), 0)
  assert_eq(tabs2_said(k.t), (["任务"], ["任务"]))
  assert_eq(k.t.audit(), [])
}
