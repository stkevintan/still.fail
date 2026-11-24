// Tests for clear liquid glass press/drag lens across all four segmented/pill-tab controls:
// `seg_node`, `seg_icons_node`, `seg_fill_node` (mouse press alongside existing finger drag), and `tabs_node(look=Pill)`.
// Verifies in both Light and Dark themes:
// 1. At rest: zero hidden glass instances (`drawn_glass().length() == 0`), solid lifted thumb intact, `audit() == []`.
// 2. While pressed: exactly 1 clear `kind == 6` liquid glass lens (`blur == 0`, `shadow_outside`), solid thumb faded, `audit() == []`.
// 3. On release: lens settles back to 0 glass instances, selection updates cleanly, `audit() == []`.
// 4. `MBUI_GLASS=solid`: zero glass instances while pressed, solid thumb stays opaque.
// 5. `reduced_motion`: zero glass instances while pressed, selection still works.
// 6. `tabs_node(look=Underline)` stays unaffected (zero glass instances while pressed).

///|
fn seg_glass_assert_cycle(
  t : @ui.Tester,
  target : @ui.SemNode,
  verify_selected : () -> Bool,
  solid : Bool,
  reduced : Bool,
  label : String,
) -> Unit raise {
  let has_lifted_thumb = fn() {
    let lifted = @ui.tree_theme().lifted
    t.drawn_rects().iter().any(fn(r) { r.4 == lifted && r.2 > 10.0 && r.3 > 10.0 })
  }
  // 1. Rest: zero glass instances, solid thumb present, and clean audit.
  assert_eq(t.drawn_glass().length(), 0, msg="\{label}: rest must have 0 glass")
  if !label.has_prefix("tabs_node(Underline)") {
    assert_true(has_lifted_thumb(), msg="\{label}: rest must draw solid lifted thumb")
  }
  let rest_audits = t.audit()
  assert_eq(rest_audits, [], msg="\{label}: rest audit: \{Repr(rest_audits)}")
  let (x, y, w, h) = target.rect
  let px = x + w / 2.0
  let py = y + h / 2.0

  // 2. Press and hold to peak of backdrop_press_spring.
  t.press_at(px, py)
  t.run_for(part_whole_ms)
  let glass = t.drawn_glass()
  if solid || reduced {
    assert_eq(glass.length(), 0, msg="\{label}: solid/reduced must have 0 glass while pressed")
    if !label.has_prefix("tabs_node(Underline)") {
      assert_true(has_lifted_thumb(), msg="\{label}: solid/reduced must keep opaque lifted thumb while pressed")
    }
  } else {
    assert_eq(glass.length(), 1, msg="\{label}: pressed must draw exactly 1 glass lens, got \{Repr(glass)}")
    assert_eq(glass[0].4, 6, msg="\{label}: glass lens must be kind == 6 liquid glass")
    let lenses = t.drawn_instances().filter(fn(i) { i[5] == 6.0 })
    assert_eq(lenses.length(), 1, msg="\{label}: pressed must emit 1 kind == 6 instance")
    assert_eq(lenses[0][14], 0.0, msg="\{label}: clear lens must have blur == 0")
    assert_true((lenses[0][7] - -48.0).abs() < 0.01, msg="\{label}: segmented lens must emit droplet_role=3 (slot 7 == -48.0), got \{lenses[0][7]}")
    assert_true(lenses[0][21] > 0.0, msg="\{label}: clear lens must have refraction > 0")
    let p_press = lenses[0][12]
    assert_true(
      (lenses[0][22] - 0.04 * p_press).abs() < 1.0e-4,
      msg="\{label}: segmented lens must emit chroma == 0.04 * p (p=\{p_press}), got \{lenses[0][22]}",
    )
  }
  let pressed_audits = t.audit()
  assert_eq(pressed_audits, [], msg="\{label}: pressed audit: \{Repr(pressed_audits)}")

  // 3. Release and settle back to rest.
  t.release(px, py)
  t.run_for(@ui.move_most_ms)
  assert_eq(t.drawn_glass().length(), 0, msg="\{label}: settled must return to 0 glass")
  assert_true(verify_selected(), msg="\{label}: release must switch selection")
  let settled_audits = t.audit()
  assert_eq(settled_audits, [], msg="\{label}: settled audit: \{Repr(settled_audits)}")
}

///|
test "seg_node: clear liquid glass lens on press in light/dark, solid, and reduced_motion" {
  for dark in [false, true] {
    for mode in [0, 1, 2] {
      let solid = mode == 1
      let reduced = mode == 2
      let chosen = @signals.signal(0)
      let t = @ui.Tester::new(fn(_c) {  }, w=420.0, h=200.0, dark~, platform=0)
      set_dark(Some(dark))
      @ui.set_glass_solid(if solid { Some(true) } else { None })
      if reduced {
        t.set_reduce_motion(true)
      }
      @ui.set_view_app(
        fn(root) {
          root.box(fn(page) {
            page.grow(Is(1.0)).padding(Is((24.0, 24.0, 24.0, 24.0))).ground(By(fn() { theme().p.bg })) |> ignore
            seg_node(page, fn() { ["今天", "7 天", "30 天"] }, fn() { chosen.get() }, fn(k) { chosen.set(k) }, said="时间")
            |> ignore
          })
          |> ignore
        },
        theme=ui_theme_now,
      )
      t.draw()
      let target = t.get(Radio, label="30 天")
      seg_glass_assert_cycle(t, target, fn() { chosen.get() == 2 }, solid, reduced, "seg_node dark=\{dark} mode=\{mode}")
      @ui.set_glass_solid(None)
    }
  }
  set_dark(None)
}

///|
test "seg_icons_node: clear liquid glass lens on press in light/dark, solid, and reduced_motion" {
  for dark in [false, true] {
    for mode in [0, 1, 2] {
      let solid = mode == 1
      let reduced = mode == 2
      let chosen = @signals.signal("list")
      let t = @ui.Tester::new(fn(_c) {  }, w=420.0, h=200.0, dark~, platform=0)
      set_dark(Some(dark))
      @ui.set_glass_solid(if solid { Some(true) } else { None })
      if reduced {
        t.set_reduce_motion(true)
      }
      @ui.set_view_app(
        fn(root) {
          root.box(fn(page) {
            page.grow(Is(1.0)).padding(Is((24.0, 24.0, 24.0, 24.0))).ground(By(fn() { theme().p.bg })) |> ignore
            page.box(fn(row) {
              row.row(Is(true)).lines_up(Is(Some(Start))) |> ignore
              row.box(fn(slot) {
                seg_icons_node(
                  slot,
                  fn() { [("list", "list", "列表"), ("grid", "view-columns", "看板")] },
                  fn() { chosen.get() },
                  fn(k) { chosen.set(k) },
                  said="视图",
                )
                |> ignore
              })
              |> ignore
            })
            |> ignore
          })
          |> ignore
        },
        theme=ui_theme_now,
      )
      t.draw()
      let active = t.get(Radio, label="列表")
      let (ax, ay, aw, ah) = active.rect
      let acx = ax + aw / 2.0
      let acy = ay + ah / 2.0
      let lifted = @ui.tree_theme().lifted
      let thumbs = t.drawn_rects().filter(fn(r) { r.4 == lifted && r.2 > 10.0 && r.3 > 10.0 })
      assert_eq(thumbs.length(), 1, msg="seg_icons_node rest thumb count: \{Repr(thumbs)}")
      let tcx = thumbs[0].0 + thumbs[0].2 / 2.0
      let tcy = thumbs[0].1 + thumbs[0].3 / 2.0
      assert_true(
        (tcx - acx).abs() < 0.5 && (tcy - acy).abs() < 0.5,
        msg="seg_icons_node rest thumb center (\{tcx}, \{tcy}) must match active option center (\{acx}, \{acy})",
      )
      if mode == 0 {
        t.press_at(acx, acy)
        t.run_for(part_whole_ms)
        let lenses = t.drawn_instances().filter(fn(i) { i[5] == 6.0 })
        assert_eq(lenses.length(), 1, msg="seg_icons_node pressed lens count")
        let lcx = lenses[0][0] + lenses[0][2] / 2.0
        let lcy = lenses[0][1] + lenses[0][3] / 2.0
        assert_true(
          (lcx - acx).abs() < 0.5 && (lcy - acy).abs() < 0.5,
          msg="seg_icons_node pressed lens center (\{lcx}, \{lcy}) must match active option center (\{acx}, \{acy})",
        )
        t.release(acx, acy)
        t.run_for(@ui.move_most_ms)
      }
      let target = t.get(Radio, label="看板")
      seg_glass_assert_cycle(
        t,
        target,
        fn() { chosen.get() == "grid" },
        solid,
        reduced,
        "seg_icons_node dark=\{dark} mode=\{mode}",
      )
      @ui.set_glass_solid(None)
    }
  }
  set_dark(None)
}

///|
test "seg_fill_node: clear liquid glass lens on mouse press in light/dark, solid, and reduced_motion" {
  for dark in [false, true] {
    for mode in [0, 1, 2] {
      let solid = mode == 1
      let reduced = mode == 2
      let chosen = @signals.signal(0)
      let t = @ui.Tester::new(fn(_c) {  }, w=420.0, h=200.0, dark~, platform=0, pointing=Mouse, native=Mouse)
      set_dark(Some(dark))
      @ui.set_glass_solid(if solid { Some(true) } else { None })
      if reduced {
        t.set_reduce_motion(true)
      }
      @ui.set_view_app(
        fn(root) {
          root.box(fn(page) {
            page.grow(Is(1.0)).padding(Is((24.0, 24.0, 24.0, 24.0))).ground(By(fn() { theme().p.bg })) |> ignore
            seg_fill_node(page, fn() { ["系统", "浅色", "深色"] }, fn() { chosen.get() }, fn(k) { chosen.set(k) }, said="主题")
            |> ignore
          })
          |> ignore
        },
        theme=ui_theme_now,
      )
      t.draw()
      let target = t.get(Radio, label="深色")
      seg_glass_assert_cycle(
        t,
        target,
        fn() { chosen.get() == 2 },
        solid,
        reduced,
        "seg_fill_node dark=\{dark} mode=\{mode}",
      )
      @ui.set_glass_solid(None)
    }
  }
  set_dark(None)
}

///|
test "tabs_node(Pill): clear liquid glass lens on press in light/dark, solid, and reduced_motion; Underline stays glass-free" {
  for dark in [false, true] {
    for mode in [0, 1, 2] {
      let solid = mode == 1
      let reduced = mode == 2
      let chosen = @signals.signal("a")
      let t = @ui.Tester::new(fn(_c) {  }, w=480.0, h=240.0, dark~, platform=0)
      set_dark(Some(dark))
      @ui.set_glass_solid(if solid { Some(true) } else { None })
      if reduced {
        t.set_reduce_motion(true)
      }
      @ui.set_view_app(
        fn(root) {
          root.box(fn(page) {
            page.grow(Is(1.0)).padding(Is((24.0, 24.0, 24.0, 24.0))).ground(By(fn() { theme().p.bg })) |> ignore
            tabs_node(
              page,
              fn() { "分类" },
              [("a", fn() { "概览" }), ("b", fn() { "文件" }), ("c", fn() { "任务" })],
              fn() { chosen.get() },
              fn(k) { chosen.set(k) },
              fn(p, k) { words_node(p, fn() { k }, fn() { paragraph }) |> ignore },
              look=Pill,
            )
            |> ignore
          })
          |> ignore
        },
        theme=ui_theme_now,
      )
      t.draw()
      let target = t.get(Tab, label="任务")
      seg_glass_assert_cycle(
        t,
        target,
        fn() { chosen.get() == "c" },
        solid,
        reduced,
        "tabs_node(Pill) dark=\{dark} mode=\{mode}",
      )
      @ui.set_glass_solid(None)
    }
  }
  // Underline variant must never mount a glass lens on press.
  let chosen = @signals.signal("a")
  let t = @ui.Tester::new(fn(_c) {  }, w=480.0, h=240.0, dark=false, platform=0)
  set_dark(Some(false))
  @ui.set_view_app(
    fn(root) {
      root.box(fn(page) {
        page.grow(Is(1.0)).padding(Is((24.0, 24.0, 24.0, 24.0))).ground(By(fn() { theme().p.bg })) |> ignore
        tabs_node(
          page,
          fn() { "下划线" },
          [("a", fn() { "概览" }), ("b", fn() { "任务" })],
          fn() { chosen.get() },
          fn(k) { chosen.set(k) },
          fn(p, k) { words_node(p, fn() { k }, fn() { paragraph }) |> ignore },
          look=Underline,
        )
        |> ignore
      })
      |> ignore
    },
    theme=ui_theme_now,
  )
  t.draw()
  let target = t.get(Tab, label="任务")
  seg_glass_assert_cycle(t, target, fn() { chosen.get() == "b" }, true, false, "tabs_node(Underline)")
  set_dark(None)
}

///|
test "seg_node (each_own=true): pressing unselected option moves lens onto pressed option, mouse drag switches with laid == 0, and keyboard switch keeps 0 glass" {
  let chosen = @signals.signal(1)
  let t = @ui.Tester::new(fn(_c) {  }, w=460.0, h=200.0, dark=false, platform=0, pointing=Mouse, native=Mouse)
  set_dark(Some(false))
  @ui.set_view_app(
    fn(root) {
      root.box(fn(page) {
        page.grow(Is(1.0)).padding(Is((24.0, 24.0, 24.0, 24.0))).ground(By(fn() { theme().p.bg })) |> ignore
        seg_node(
          page,
          fn() { ["本机", "所有 station"] },
          fn() { chosen.get() },
          fn(k) { chosen.set(k) },
          each_own=true,
          said="模型范围",
        )
        |> ignore
      })
      |> ignore
    },
    theme=ui_theme_now,
  )
  t.draw()
  let r0 = t.get(Radio, label="本机").rect
  let r1 = t.get(Radio, label="所有 station").rect
  let c0x = r0.0 + r0.2 / 2.0
  let c1x = r1.0 + r1.2 / 2.0
  let cy = r0.1 + r0.3 / 2.0
  let mid_x = (c0x + c1x) / 2.0
  let lens_center = fn() {
    let lenses = t.drawn_instances().filter(fn(i) { i[5] == 6.0 })
    (lenses.length(), if lenses.is_empty() { -1.0 } else { lenses[0][0] + lenses[0][2] / 2.0 })
  }
  // 1. Press unselected "本机" while "所有 station" is selected -> lens must move onto "本机".
  t.press_at(c0x, cy)
  t.run_for(part_whole_ms)
  let (n_hold, hold_cx) = lens_center()
  assert_eq(n_hold, 1, msg="holding unselected seg_node must show 1 clear glass lens")
  assert_true(
    (hold_cx - c0x).abs() < 4.0,
    msg="lens center \{hold_cx} must move onto pressed 本机 (\{c0x}), not stay on 所有 station (\{c1x})",
  )
  // 2. Drag continuously to midpoint and back to "所有 station" with zero relayout.
  t.tree_frames_from_now()
  t.move_to(mid_x, cy)
  t.run_for(part_whole_ms / 2.0)
  let (n_mid, mid_cx) = lens_center()
  assert_eq(n_mid, 1, msg="mid-drag must keep 1 clear glass lens")
  assert_true(
    mid_cx > c0x + 8.0 && mid_cx < c1x - 8.0,
    msg="mid-drag lens center \{mid_cx} must sit between \{c0x} and \{c1x}",
  )
  for f in t.tree_frames() {
    assert_eq(f.laid, 0, msg="seg_node drag relaid out: \{Repr(f)}")
  }
  t.move_to(c1x, cy)
  t.run_for(part_whole_ms / 2.0)
  t.release(c1x, cy)
  t.run_for(@ui.move_most_ms)
  assert_eq(chosen.get(), 1, msg="releasing on 所有 station keeps 1")
  assert_eq(t.drawn_glass().length(), 0, msg="settled after drag must have 0 glass")
  assert_eq(t.audit(), [])
  // 3. Drag from "所有 station" to "本机" and release -> switches to 0.
  t.press_at(c1x, cy)
  t.run_for(part_whole_ms / 2.0)
  t.move_to(mid_x, cy)
  t.run_for(part_whole_ms / 2.0)
  t.move_to(c0x, cy)
  t.run_for(part_whole_ms / 2.0)
  t.release(c0x, cy)
  t.run_for(@ui.move_most_ms)
  assert_eq(chosen.get(), 0, msg="drag from 所有 station to 本机 must switch chosen to 0")
  assert_eq(t.drawn_glass().length(), 0, msg="settled after switching drag must have 0 glass")
  assert_eq(t.audit(), [])
  // 4. Keyboard switch slides solid thumb without mounting glass lens.
  t.key(@ui.key_tab)
  t.draw()
  t.key(@ui.key_code_right)
  t.run_for(part_whole_ms / 3.0)
  assert_eq(t.drawn_glass().length(), 0, msg="keyboard switch must keep 0 glass mid-slide")
  t.run_for(@ui.move_most_ms)
  assert_eq(chosen.get(), 1, msg="keyboard right must switch to 1")
  assert_eq(t.drawn_glass().length(), 0, msg="keyboard switch settled must keep 0 glass")
  set_dark(None)
}

///|
test "seg_icons_node: pressing unselected icon moves lens onto pressed icon and mouse drag switches" {
  let chosen = @signals.signal("grid")
  let t = @ui.Tester::new(fn(_c) {  }, w=420.0, h=200.0, dark=false, platform=0, pointing=Mouse, native=Mouse)
  set_dark(Some(false))
  @ui.set_view_app(
    fn(root) {
      root.box(fn(page) {
        page.grow(Is(1.0)).padding(Is((24.0, 24.0, 24.0, 24.0))).ground(By(fn() { theme().p.bg })) |> ignore
        page.box(fn(row) {
          row.row(Is(true)).lines_up(Is(Some(Start))) |> ignore
          row.box(fn(slot) {
            seg_icons_node(
              slot,
              fn() { [("list", "list", "列表"), ("grid", "view-columns", "看板")] },
              fn() { chosen.get() },
              fn(k) { chosen.set(k) },
              said="视图",
            )
            |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    theme=ui_theme_now,
  )
  t.draw()
  let r0 = t.get(Radio, label="列表").rect
  let r1 = t.get(Radio, label="看板").rect
  let c0x = r0.0 + r0.2 / 2.0
  let c1x = r1.0 + r1.2 / 2.0
  let cy = r0.1 + r0.3 / 2.0
  t.press_at(c0x, cy)
  t.run_for(part_whole_ms)
  let lenses = t.drawn_instances().filter(fn(i) { i[5] == 6.0 })
  assert_eq(lenses.length(), 1)
  let hold_cx = lenses[0][0] + lenses[0][2] / 2.0
  assert_true((hold_cx - c0x).abs() < 4.0, msg="seg_icons_node lens \{hold_cx} must move onto pressed 列表 (\{c0x})")
  t.release(c0x, cy)
  t.run_for(@ui.move_most_ms)
  assert_eq(chosen.get(), "list")
  t.press_at(c0x, cy)
  t.run_for(part_whole_ms / 2.0)
  t.move_to(c1x, cy)
  t.run_for(part_whole_ms / 2.0)
  t.release(c1x, cy)
  t.run_for(@ui.move_most_ms)
  assert_eq(chosen.get(), "grid")
  assert_eq(t.drawn_glass().length(), 0)
  assert_eq(t.audit(), [])
  set_dark(None)
}

///|
test "tabs_node(Pill): pressing unselected tab moves lens onto pressed tab and mouse drag switches" {
  let chosen = @signals.signal("c")
  let t = @ui.Tester::new(fn(_c) {  }, w=480.0, h=240.0, dark=false, platform=0, pointing=Mouse, native=Mouse)
  set_dark(Some(false))
  @ui.set_view_app(
    fn(root) {
      root.box(fn(page) {
        page.grow(Is(1.0)).padding(Is((24.0, 24.0, 24.0, 24.0))).ground(By(fn() { theme().p.bg })) |> ignore
        tabs_node(
          page,
          fn() { "分类" },
          [("a", fn() { "概览" }), ("b", fn() { "文件" }), ("c", fn() { "任务" })],
          fn() { chosen.get() },
          fn(k) { chosen.set(k) },
          fn(p, k) { words_node(p, fn() { k }, fn() { paragraph }) |> ignore },
          look=Pill,
        )
        |> ignore
      })
      |> ignore
    },
    theme=ui_theme_now,
  )
  t.draw()
  let r0 = t.get(Tab, label="概览").rect
  let r1 = t.get(Tab, label="文件").rect
  let c0x = r0.0 + r0.2 / 2.0
  let c1x = r1.0 + r1.2 / 2.0
  let cy = r0.1 + r0.3 / 2.0
  t.press_at(c0x, cy)
  t.run_for(part_whole_ms)
  let lenses = t.drawn_instances().filter(fn(i) { i[5] == 6.0 })
  assert_eq(lenses.length(), 1)
  let hold_cx = lenses[0][0] + lenses[0][2] / 2.0
  assert_true((hold_cx - c0x).abs() < 4.0, msg="tabs_node(Pill) lens \{hold_cx} must move onto pressed 概览 (\{c0x})")
  t.move_to(c1x, cy)
  t.run_for(part_whole_ms / 2.0)
  t.release(c1x, cy)
  t.run_for(@ui.move_most_ms)
  assert_eq(chosen.get(), "b")
  assert_eq(t.drawn_glass().length(), 0)
  assert_eq(t.audit(), [])
  set_dark(None)
}

///|
test "seg_fill_node: mouse press on unselected option moves lens onto pressed option and mouse drag switches" {
  let chosen = @signals.signal(2)
  let t = @ui.Tester::new(fn(_c) {  }, w=420.0, h=200.0, dark=false, platform=0, pointing=Mouse, native=Mouse)
  set_dark(Some(false))
  @ui.set_view_app(
    fn(root) {
      root.box(fn(page) {
        page.grow(Is(1.0)).padding(Is((24.0, 24.0, 24.0, 24.0))).ground(By(fn() { theme().p.bg })) |> ignore
        seg_fill_node(page, fn() { ["系统", "浅色", "深色"] }, fn() { chosen.get() }, fn(k) { chosen.set(k) }, said="主题")
        |> ignore
      })
      |> ignore
    },
    theme=ui_theme_now,
  )
  t.draw()
  let r0 = t.get(Radio, label="系统").rect
  let r1 = t.get(Radio, label="浅色").rect
  let c0x = r0.0 + r0.2 / 2.0
  let c1x = r1.0 + r1.2 / 2.0
  let cy = r0.1 + r0.3 / 2.0
  t.press_at(c0x, cy)
  t.run_for(part_whole_ms)
  let lenses = t.drawn_instances().filter(fn(i) { i[5] == 6.0 })
  assert_eq(lenses.length(), 1)
  let hold_cx = lenses[0][0] + lenses[0][2] / 2.0
  assert_true((hold_cx - c0x).abs() < 4.0, msg="seg_fill_node mouse lens \{hold_cx} must move onto pressed 系统 (\{c0x})")
  t.move_to(c1x, cy)
  t.run_for(part_whole_ms / 2.0)
  t.release(c1x, cy)
  t.run_for(@ui.move_most_ms)
  assert_eq(chosen.get(), 1)
  assert_eq(t.drawn_glass().length(), 0)
  assert_eq(t.audit(), [])
  set_dark(None)
}
