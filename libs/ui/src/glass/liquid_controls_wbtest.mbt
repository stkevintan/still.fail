// White-box tests for Stage 1 S1-3A optical & interaction alignment in `ui/glass`:
// 1. `liquid_segmented_node(glass_track=true)`:
//    - Clear refraction lens is mounted AFTER the label row (Z-order above text glyphs).
//    - Resting selected pill uses iOS 26 lifted fill (Light 0xFFFFFFFF, Dark 0x5A5A60FF) + outer shadow (2, 1, 0x0000001F).
//    - Held lens scales to 1.15x (`ctrl_seg_held_scale == 1.15`) with zero relayout (`laid == 0`).
// 2. `liquid_slider_node`:
//    - Track & active fill elastically thicken from 6pt at rest to 10pt while held/dragged in paint layer (`laid == 0`),
//      centered vertically and returning to 6pt on release.

///|
/// Declared hold and drag durations for liquid control white-box assertions (past press spring peak).
let glass_ctrl_hold_ms : Double = 300.0

///|
let glass_ctrl_drag_ms : Double = 250.0

///|
test "liquid_segmented_node(glass_track=true): lens Z-order above text, lifted idle pill, 1.15x scale, laid == 0" {
  for dark in [false, true] {
    let seg_idx = @signals.signal(0)
    let t = glass_case(dark, false, fn(page) {
      liquid_segmented_node(
        page,
        fn() { ["Day", "Week", "Month"] },
        fn() { seg_idx.get() },
        fn(i) { seg_idx.set(i) },
        width=360.0,
        height=44.0,
        glass_track=true,
      )
      |> ignore
    })
    t.run_for(glass_springs_out)
    // 1. Resting state: 1 liquid glass instance (track only), bright lifted idle pill with exact fill color.
    let expected_idle = if dark { 0x5A5A60FFL } else { 0xFFFFFFFFL }
    let idle_pills = t.drawn_rects().filter(fn(r) { r.4 == expected_idle && r.2 > 80.0 && r.3 > 30.0 })
    assert_eq(idle_pills.length(), 1, msg="dark=\{dark}: rest must draw 1 lifted idle pill with expected color")
    assert_eq(t.drawn_glass().length(), 1, msg="dark=\{dark}: rest must draw only the track glass (0 hidden lens)")
    assert_eq(t.audit(), [], msg="dark=\{dark}: rest audit must be empty")

    // 2. Press and drag to "Week" -> lens must be mounted AFTER text glyphs (Z-order above labels) and scaled ~1.15x.
    let r0 = t.get(Tab, label="Day").rect
    let r1 = t.get(Tab, label="Week").rect
    let cy = r0.1 + r0.3 / 2.0
    t.press_at(r0.0 + r0.2 / 2.0, cy)
    t.run_for(glass_ctrl_hold_ms)
    t.tree_frames_from_now()
    t.move_to(r1.0 + r1.2 / 2.0, cy)
    t.run_for(glass_ctrl_drag_ms)
    for f in t.tree_frames() {
      assert_eq(f.laid, 0, msg="dark=\{dark}: dragging liquid_segmented_node must not relayout: \{Repr(f)}")
    }
    let insts = t.drawn_instances()
    let mut last_glyph_idx = -1
    let mut lens_idx = -1
    let mut lens_h = 0.0
    for idx, inst in insts {
      // kind == 1 is text glyph; kind == 6 with blur == 0.0 (slot 14) is clear refraction lens.
      if inst[5] == 1.0 {
        last_glyph_idx = idx
      } else if inst[5] == 6.0 && inst[14] == 0.0 {
        lens_idx = idx
        lens_h = inst[3]
      }
    }
    assert_true(last_glyph_idx >= 0, msg="dark=\{dark}: must draw label glyphs")
    assert_true(lens_idx > last_glyph_idx, msg="dark=\{dark}: clear lens (idx=\{lens_idx}) must draw AFTER text glyphs (last=\{last_glyph_idx})")
    assert_true(
      lens_h >= 44.0 + 9.0 && lens_h <= 44.0 + 16.0,
      msg="dark=\{dark}: held lens height \{lens_h} must overhang 44pt track by ~12pt (6pt top/bottom)",
    )
    assert_eq(t.audit(), [], msg="dark=\{dark}: held audit must be empty")

    // 3. Release and settle back to rest -> 1 glass (track only), selection switched to 1 ("Week").
    t.release(r1.0 + r1.2 / 2.0, cy)
    t.run_for(glass_springs_out)
    assert_eq(seg_idx.untracked(), 1, msg="dark=\{dark}: release on Week must select index 1")
    assert_eq(t.drawn_glass().length(), 1, msg="dark=\{dark}: settled must return to track glass only")
    assert_eq(t.audit(), [], msg="dark=\{dark}: settled audit must be empty")
  }
  set_dark(None)
}

///|
test "liquid_slider_node: crisp 6pt track while held/dragged with laid == 0" {
  let slider_val = @signals.signal(40.0)
  let t = glass_case(false, false, fn(page) {
    page.box(fn(s) {
      s.width(Is(Some(320.0))) |> ignore
      liquid_slider_node(s, fn() { slider_val.get() }, fn(v) { slider_val.set(v) }, fn() { "Brightness" }) |> ignore
    })
    |> ignore
  })
  t.run_for(glass_springs_out)
  let track_col = colors().track
  let accent_col = colors().accent
  let track_rect = fn() raise {
    let rs = t.drawn_rects().filter(fn(r) { r.4 == track_col && r.2 > 200.0 })
    assert_eq(rs.length(), 1, msg="expected 1 slider background track rect")
    rs[0]
  }
  let fill_rect = fn() raise {
    let rs = t.drawn_rects().filter(fn(r) { r.4 == accent_col && r.2 > 20.0 })
    assert_eq(rs.length(), 1, msg="expected 1 slider active fill rect")
    rs[0]
  }
  // 1. At rest: track and fill are 6.0pt high.
  let rest_tr = track_rect()
  let rest_fl = fill_rect()
  assert_true((rest_tr.3 - 6.0).abs() < 0.05, msg="rest track height must be 6pt, got \{rest_tr.3}")
  assert_true((rest_fl.3 - 6.0).abs() < 0.05, msg="rest fill height must be 6pt, got \{rest_fl.3}")
  let rest_cy = rest_tr.1 + rest_tr.3 / 2.0

  // 2. Press and drag: track and fill thicken smoothly to ~10.0pt centered at rest_cy, with laid == 0.
  let sl_rect = t.get(Slider, label="Brightness").rect
  let y = sl_rect.1 + sl_rect.3 / 2.0
  let x0 = sl_rect.0 + sl_rect.2 * 0.4
  let x1 = sl_rect.0 + sl_rect.2 * 0.7
  t.press_at(x0, y)
  t.run_for(glass_ctrl_hold_ms)
  t.tree_frames_from_now()
  t.move_to(x1, y)
  t.run_for(glass_ctrl_drag_ms)
  for f in t.tree_frames() {
    assert_eq(f.laid, 0, msg="liquid_slider_node drag must not trigger relayout: \{Repr(f)}")
  }
  let held_tr = track_rect()
  let held_fl = fill_rect()
  assert_true((held_tr.3 - 6.0).abs() < 0.05, msg="held track height must stay crisp 6pt, got \{held_tr.3}")
  assert_true((held_fl.3 - 6.0).abs() < 0.05, msg="held fill height must stay crisp 6pt, got \{held_fl.3}")
  let held_cy = held_tr.1 + held_tr.3 / 2.0
  assert_true((held_cy - rest_cy).abs() < 0.1, msg="thickened track must stay vertically centered (\{held_cy} vs \{rest_cy})")

  // 3. Release and settle: track and fill return to 6.0pt.
  t.release(x1, y)
  t.run_for(glass_springs_out)
  let done_tr = track_rect()
  let done_fl = fill_rect()
  assert_true((done_tr.3 - 6.0).abs() < 0.05, msg="settled track height must return to 6pt, got \{done_tr.3}")
  assert_true((done_fl.3 - 6.0).abs() < 0.05, msg="settled fill height must return to 6pt, got \{done_fl.3}")
  set_dark(None)
}

///|
test "built-in droplet recipes assign exact unscaled droplet_role IDs (1..4) and public knob stays 0" {
  assert_eq(slider_glass(1.0).droplet_role, 1)
  assert_eq(slider_glass(1.0).at_strength(0.5).droplet_role, 1)
  assert_eq(toggle_glass(1.0).droplet_role, 2)
  assert_eq(toggle_glass(1.0).at_strength(0.5).droplet_role, 2)
  assert_eq(ctrl_segmented_lens_glass(1.0).droplet_role, 3)
  assert_eq(ctrl_segmented_compact_lens_glass(1.0).droplet_role, 3)
  assert_eq(liquid_tab_lens_glass(1.0).droplet_role, 4)
  assert_eq(liquid_tab_lens_glass(1.0, droplet_role=3).droplet_role, 3)
  assert_eq(liquid_knob_glass().droplet_role, 0)
}

///|
test "real liquid_toggle_node held: frost=0 keeps slot 7 (-32), frost>0 frosts monotonically, contrast=true, and glass_solid=true" {
  let on = @signals.signal(true)
  let t = glass_case(false, false, fn(page) {
    liquid_toggle_node(page, fn() { on.get() }, fn(v) { on.set(v) }, fn() { "Wi-Fi" }) |> ignore
  })
  t.run_for(glass_springs_out)
  let sw = t.get(Switch, label="Wi-Fi").rect
  t.press_at(sw.0 + sw.2 / 2.0, sw.1 + sw.3 / 2.0)
  t.run_for(glass_ctrl_hold_ms)

  let find_glass = fn() -> (Double, Double, Double)? {
    for inst in t.drawn_instances() {
      if inst[5] == 6.0 {
        return Some((inst[7], inst[11], inst[21]))
      }
    }
    None
  }

  // frost == 0.0 keeps crystal droplet (slot7=-32, alpha=0, refr~9)
  @ui.set_glass_frost(0.0)
  t.draw()
  guard find_glass() is Some((slot7_0, alpha_0, refr_0)) else {
    fail("real liquid_toggle_node missing droplet at frost=0.0")
  }
  assert_true((slot7_0 - -32.0).abs() < 0.01, msg="frost=0.0 slot7=\{slot7_0}")
  assert_true(alpha_0 < 0.001, msg="frost=0.0 alpha=\{alpha_0}")
  assert_true(refr_0 > 7.5 && refr_0 <= 9.01, msg="frost=0.0 slot21=\{refr_0}")

  // C0 continuity across 0 -> 0.0001 -> 0.00011 -> 0.05 -> 0.10: slot7 stays -32.0 while alpha rises monotonically
  let low_frosts = [0.0001, 0.00011, 0.05, 0.10]
  let mut prev_low_a = alpha_0
  for f in low_frosts {
    @ui.set_glass_frost(f)
    t.draw()
    guard find_glass() is Some((s7, al, _)) else {
      fail("real liquid_toggle_node missing glass at frost=\{f}")
    }
    assert_true((s7 - -32.0).abs() < 0.01, msg="frost=\{f} must preserve slot7=-32.0 while a_frac<=0.12, got \{s7}")
    assert_true(al >= prev_low_a - 0.0001, msg="frost=\{f} alpha non-monotonic: \{al} < \{prev_low_a}")
    prev_low_a = al
  }
  assert_true(prev_low_a > 0.08 && prev_low_a < 0.12, msg="frost=0.10 alpha should be ~0.094, got \{prev_low_a}")

  // frost = 0.3 -> 0.5 monotonically frosts (blur > 0, alpha > 0)
  @ui.set_glass_frost(0.3)
  t.draw()
  guard find_glass() is Some((slot7_30, alpha_30, _)) else {
    fail("real liquid_toggle_node missing glass at frost=0.3")
  }
  assert_true(slot7_30 > 0.5 && alpha_30 > prev_low_a, msg="frost=0.3 should frost: slot7=\{slot7_30} alpha=\{alpha_30}")

  @ui.set_glass_frost(0.5)
  t.draw()
  guard find_glass() is Some((slot7_50, alpha_50, _)) else {
    fail("real liquid_toggle_node missing glass at frost=0.5")
  }
  assert_true(slot7_50 > slot7_30 && alpha_50 > alpha_30, msg="frost=0.5 must exceed 0.3: (\{slot7_50},\{alpha_50}) vs (\{slot7_30},\{alpha_30})")

  // Returning to frost == 0.0 restores crystal droplet (slot7=-32, alpha=0)
  @ui.set_glass_frost(0.0)
  t.draw()
  guard find_glass() is Some((slot7_back, alpha_back, refr_back)) else {
    fail("real liquid_toggle_node missing droplet restored at frost=0.0")
  }
  assert_true((slot7_back - -32.0).abs() < 0.01, msg="restored frost=0.0 slot7=\{slot7_back}")
  assert_true(alpha_back < 0.001, msg="restored frost=0.0 alpha=\{alpha_back}")
  assert_true(refr_back > 7.5 && refr_back <= 9.01, msg="restored frost=0.0 slot21=\{refr_back}")

  // contrast=true: droplet must NOT be exempted (receives contrast modulation -> blur > 0 so slot 7 > 0)
  @ui.set_glass_frost(0.0)
  t.set_increase_contrast(true)
  t.draw()
  let mut saw_contrast_glass = false
  for inst in t.drawn_instances() {
    if inst[5] == 6.0 {
      assert_true(inst[7] >= 0.0, msg="contrast=true must not keep exempt role slot7=\{inst[7]}")
      saw_contrast_glass = true
    }
  }
  assert_true(saw_contrast_glass, msg="contrast=true must still draw modulated glass")
  t.set_increase_contrast(false)

  // glass_solid=true: zero kind-6 glass instances
  @ui.set_glass_solid(Some(true))
  t.draw()
  assert_eq(t.drawn_glass().length(), 0, msg="glass_solid=true must emit 0 glass instances")
  @ui.set_glass_solid(None)
  @ui.set_glass_frost(0.0)
  t.release(sw.0 + sw.2 / 2.0, sw.1 + sw.3 / 2.0)
  t.run_for(glass_springs_out)
  set_dark(None)
}

///|
test "real slider, segmented, and tab lens controls emit exact drawlist slot 7 (-16, -48, -64) and slot 21" {
  // 1. Real liquid_slider_node -> slot 7 == -16.0
  {
    let v = @signals.signal(50.0)
    let t = glass_case(false, false, fn(page) {
      page.box(fn(s) {
        s.width(Is(Some(300.0))) |> ignore
        liquid_slider_node(s, fn() { v.get() }, fn(x) { v.set(x) }, fn() { "Volume" }) |> ignore
      }) |> ignore
    })
    t.run_for(glass_springs_out)
    let r = t.get(Slider, label="Volume").rect
    t.press_at(r.0 + r.2 * 0.5, r.1 + r.3 * 0.5)
    t.run_for(glass_ctrl_hold_ms)
    let mut found = false
    for inst in t.drawn_instances() {
      if inst[5] == 6.0 && (inst[7] - -16.0).abs() < 0.01 {
        assert_true(inst[21] > 7.5 && inst[21] <= 9.01, msg="slider slot21=\{inst[21]}")
        found = true
      }
    }
    assert_true(found, msg="real liquid_slider_node must emit slot 7 == -16.0")
    t.release(r.0 + r.2 * 0.5, r.1 + r.3 * 0.5)
    t.run_for(glass_springs_out)
  }
  // 2. Real liquid_segmented_node -> slot 7 == -48.0
  {
    let idx = @signals.signal(0)
    let t = glass_case(false, false, fn(page) {
      liquid_segmented_node(
        page,
        fn() { ["One", "Two", "Three"] },
        fn() { idx.get() },
        fn(i) { idx.set(i) },
        width=320.0,
        height=36.0,
        glass_track=false,
      ) |> ignore
    })
    t.run_for(glass_springs_out)
    let r = t.get(Tab, label="One").rect
    t.press_at(r.0 + r.2 / 2.0, r.1 + r.3 / 2.0)
    t.run_for(glass_ctrl_hold_ms)
    let mut found = false
    for inst in t.drawn_instances() {
      if inst[5] == 6.0 && (inst[7] - -48.0).abs() < 0.01 {
        assert_true(inst[21] > 7.0 && inst[21] <= 9.01, msg="segmented slot21=\{inst[21]}")
        found = true
      }
    }
    assert_true(found, msg="real liquid_segmented_node must emit slot 7 == -48.0")
    t.release(r.0 + r.2 / 2.0, r.1 + r.3 / 2.0)
    t.run_for(glass_springs_out)
  }
  // 3. Real bottom tab lens overlay (liquid_lens_overlay_node default droplet_role=4) -> slot 7 == -64.0
  {
    let lens = @signals.signal(0.0)
    let t = glass_case(false, false, fn(page) {
      page.box(fn(bar) {
        bar.width(Is(Some(240.0))).height(Is(Some(54.0))) |> ignore
        liquid_lens_overlay_node(
          bar,
          fn() { lens.get() },
          fn() { 48.0 },
          rect=fn() { Some((8.0, 3.0, 76.0, 48.0)) },
          width=fn() { 76.0 },
        )
      }) |> ignore
    })
    t.draw()
    lens.set(1.0)
    t.draw()
    let mut found = false
    for inst in t.drawn_instances() {
      if inst[5] == 6.0 && (inst[7] - -64.0).abs() < 0.01 {
        assert_true(inst[21] > 8.5 && inst[21] <= 9.01, msg="tab lens slot21=\{inst[21]}")
        found = true
      }
    }
    assert_true(found, msg="real tab liquid_lens_overlay_node must emit slot 7 == -64.0")
  }
  set_dark(None)
}
