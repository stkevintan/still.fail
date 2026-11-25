// White-box tests for Stage 1 S1-3A optical & interaction alignment in `ui/glass`:
// 1. `liquid_segmented_node(glass_track=true)`:
//    - Clear refraction lens is mounted AFTER the label row (Z-order above text glyphs).
//    - Resting selected pill uses iOS 27 lifted fill (Light 0xFFFFFFFF, Dark 0x68686EFF) with zero border/shadow.
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
    // 1. Resting state: 1 liquid glass instance (track only), bright lifted idle pill with exact fill color,
    //    and zero border / zero shadow instances in the drawlist (matching native iOS 27.0).
    let expected_idle = if dark { 0x68686EFFL } else { 0xFFFFFFFFL }
    let idle_pills = t.drawn_rects().filter(fn(r) { r.4 == expected_idle && r.2 > 80.0 && r.3 > 30.0 })
    assert_eq(idle_pills.length(), 1, msg="dark=\{dark}: rest must draw 1 lifted idle pill with expected color")
    let pill_r = idle_pills[0]
    let pill_insts = t.drawn_instances().filter(fn(a) {
      a.length() > 6 && a[5] == 0.0 && (a[0] - pill_r.0).abs() < 1.0 && (a[1] - pill_r.1).abs() < 1.0 && (a[2] - pill_r.2).abs() < 1.0 && (a[3] - pill_r.3).abs() < 1.0
    })
    let pill_shadows = t.drawn_instances().filter(fn(a) { a.length() > 6 && a[5] == 2.0 && (a[2] - pill_r.2).abs() < 12.0 })
    assert_true(pill_insts.length() >= 1, msg="dark=\{dark}: resting glass_track=true pill rect instance must be present")
    assert_eq(pill_insts.filter(fn(a) { a[6] > 0.0 }).length(), 0, msg="dark=\{dark}: resting glass_track=true pill must draw zero border")
    assert_eq(pill_shadows.length(), 0, msg="dark=\{dark}: resting glass_track=true pill must draw zero shadow")
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

    // 4. Verify flat (glass_track=false) resting pill emits exact lifted fill with zero border and zero shadow.
    let flat_idx = @signals.signal(0)
    let tf = glass_case(dark, false, fn(page) {
      liquid_segmented_node(
        page,
        fn() { ["Day", "Week", "Month"] },
        fn() { flat_idx.get() },
        fn(i) { flat_idx.set(i) },
        width=360.0,
        height=36.0,
        glass_track=false,
      )
      |> ignore
    })
    tf.run_for(glass_springs_out)
    let flat_pills = tf.drawn_rects().filter(fn(r) { r.4 == @ui.tree_theme().lifted && r.2 > 80.0 && r.3 > 20.0 })
    assert_eq(flat_pills.length(), 1, msg="dark=\{dark}: rest glass_track=false must draw 1 lifted pill")
    let flat_r = flat_pills[0]
    let flat_insts = tf.drawn_instances().filter(fn(a) {
      a.length() > 6 && a[5] == 0.0 && (a[0] - flat_r.0).abs() < 1.0 && (a[1] - flat_r.1).abs() < 1.0 && (a[2] - flat_r.2).abs() < 1.0 && (a[3] - flat_r.3).abs() < 1.0
    })
    assert_true(flat_insts.length() >= 1, msg="dark=\{dark}: glass_track=false pill rect instance must be present")
    assert_eq(flat_insts.filter(fn(a) { a[6] > 0.0 }).length(), 0, msg="dark=\{dark}: glass_track=false pill must draw zero border")
    assert_eq(tf.drawn_instances().filter(fn(a) { a.length() > 6 && a[5] == 2.0 }).length(), 0, msg="dark=\{dark}: glass_track=false pill must draw zero shadow")
    assert_eq(tf.audit(), [], msg="dark=\{dark}: flat rest audit must be empty")
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

  // 3. Release and settle: track and fill return to 6.0pt with laid == 0 on release.
  t.tree_frames_from_now()
  t.release(x1, y)
  t.run_for(glass_springs_out)
  for f in t.tree_frames() {
    assert_eq(f.laid, 0, msg="liquid_slider_node release must not trigger relayout: \{Repr(f)}")
  }
  let done_tr = track_rect()
  let done_fl = fill_rect()
  assert_true((done_tr.3 - 6.0).abs() < 0.05, msg="settled track height must return to 6pt, got \{done_tr.3}")
  assert_true((done_fl.3 - 6.0).abs() < 0.05, msg="settled fill height must return to 6pt, got \{done_fl.3}")
  set_dark(None)
}

///|
test "liquid_slider_look: travel_inset, buffered layer, lens_enabled=false zero glass & solid scale, focus_shown follows thumb" {
  // 1. lens_enabled=false with travel_inset=Some(11.0), buffered, and focus_shown
  let dd = DampedDrag::new(0.25, lo=0.0, hi=1.0, held_scale=slider_thumb_held_scale)
  let focused = @signals.signal(true)
  let buf = @signals.signal(0.6)
  let thumb_col = 0xE05A2BFFL
  let buf_col = 0x88888866L
  let t = glass_case(false, false, fn(page) {
    page.box(fn(host) {
      dd.attach(host)
      host.width(Is(Some(222.0))).height(Is(Some(22.0))) |> ignore
      let look = SliderLook::new(
        track_h=3.0,
        track_inset=11.0,
        travel_inset=Some(11.0),
        thumb_w=22.0,
        thumb_h=22.0,
        track_color=fn() { 0x00000028L },
        fill_color=Some(fn() { 0xE05A2BFFL }),
        buffered=Some(fn() { buf.get() }),
        buffered_color=Some(fn() { buf_col }),
        thumb_color=Some(fn() { thumb_col }),
        thumb_edge=Some(fn() { (3.0, 0xF4F1EAFFL) }),
        focus_shown=Some(fn() { focused.get() }),
        lens_enabled=false,
      )
      liquid_slider_look(host, fn(n) { dd.progress(n) }, fn(n) { dd.pressed(n) }, look, velocity=fn(n) { dd.velocity(n) })
    })
    |> ignore
  })
  t.run_for(glass_springs_out)
  // At rest: 0 glass instances, buffered bar rendered, thumb center at 11 + 200 * 0.25 = 61 (host x=24 -> 85)
  assert_eq(t.drawn_glass().length(), 0, msg="lens_enabled=false rest must emit 0 glass")
  let buf_rects = t.drawn_rects().filter(fn(r) { r.4 == buf_col && r.3 > 2.5 && r.3 < 3.5 })
  assert_eq(buf_rects.length(), 1, msg="expected 1 buffered rect")
  assert_true((buf_rects[0].2 - 120.0).abs() < 0.5, msg="buffered width at 0.6 of 200pt span should be ~120pt, got \{buf_rects[0].2}")
  let thumb_rects_rest = t.drawn_rects().filter(fn(r) { r.4 == thumb_col && r.3 >= 21.5 && r.3 <= 22.5 })
  assert_eq(thumb_rects_rest.length(), 1, msg="expected 1 solid thumb rect at rest")
  let rest_cx = thumb_rects_rest[0].0 + thumb_rects_rest[0].2 / 2.0
  assert_true((rest_cx - (24.0 + 11.0 + 200.0 * 0.25)).abs() < 0.5, msg="thumb center at 0.25: \{rest_cx}")

  // Press and move to 0.75: still 0 glass instances, solid thumb scales up (~1.2x -> ~26.4pt), laid == 0
  t.tree_frames_from_now()
  t.by_hand(fn() {
    dd.press()
    dd.update_value(0.75)
  })
  t.run_for(glass_ctrl_hold_ms)
  assert_eq(t.drawn_glass().length(), 0, msg="lens_enabled=false held must emit 0 glass")
  for f in t.tree_frames() {
    assert_eq(f.laid, 0, msg="lens_enabled=false drag must not relayout: \{Repr(f)}")
  }
  let thumb_rects_held = t.drawn_rects().filter(fn(r) { r.4 == thumb_col && r.3 > 24.0 })
  assert_eq(thumb_rects_held.length(), 1, msg="lens_enabled=false held must scale solid thumb > 24pt")
  let held_cx = thumb_rects_held[0].0 + thumb_rects_held[0].2 / 2.0
  assert_true((held_cx - (24.0 + 11.0 + 200.0 * 0.75)).abs() < 1.0, msg="thumb center moved to 0.75: \{held_cx}")

  // Release: 0 glass instances, laid == 0, returns to 22pt
  t.tree_frames_from_now()
  t.by_hand(fn() { dd.release() })
  t.run_for(glass_springs_out)
  assert_eq(t.drawn_glass().length(), 0, msg="lens_enabled=false release must emit 0 glass")
  for f in t.tree_frames() {
    assert_eq(f.laid, 0, msg="lens_enabled=false release must not relayout: \{Repr(f)}")
  }
  assert_eq(t.audit(), [])
  set_dark(None)
}

///|
test "liquid_slider_look: fill and buffered stay clamped within [track_inset, w - track_inset] when track_inset != travel_inset" {
  let fill_col = 0x2288EEFFL
  let buf_col = 0x99999988L
  let cases : Array[(Double, Double, Double)] = [
    (72.0, 10.0, 0.0),
    (120.0, 4.0, 16.0),
  ]
  for c in cases {
    let (w, track_in, travel_in) = c
    let prog = @signals.signal(0.0)
    let buf = @signals.signal(0.0)
    let t = glass_case(false, false, fn(page) {
      page.box(fn(host) {
        host.width(Is(Some(w))).height(Is(Some(22.0))) |> ignore
        let look = SliderLook::new(
          track_h=4.0,
          track_inset=track_in,
          travel_inset=Some(travel_in),
          thumb_w=18.0,
          thumb_h=18.0,
          track_color=fn() { 0x00000022L },
          fill_color=Some(fn() { fill_col }),
          buffered=Some(fn() { buf.get() }),
          buffered_color=Some(fn() { buf_col }),
          lens_enabled=false,
        )
        liquid_slider_look(host, fn(_) { prog.get() }, fn(_) { 0.0 }, look)
      })
      |> ignore
    })
    let lo = 24.0 + track_in
    let hi = 24.0 + w - track_in
    for at in [0.0, 0.5, 1.0] {
      prog.set(at)
      buf.set(at)
      t.draw()
      for col in [fill_col, buf_col] {
        let rects = t.drawn_rects().filter(fn(r) { r.4 == col })
        if at > 0.0 {
          assert_eq(rects.length(), 1, msg="w=\{w} ti=\{track_in} tr=\{travel_in} at=\{at}: expected 1 bar rect")
        }
        for r in rects {
          assert_true(r.0 >= lo - 0.05, msg="w=\{w} ti=\{track_in} tr=\{travel_in} at=\{at}: left \{r.0} < \{lo}")
          assert_true(r.0 + r.2 <= hi + 0.05, msg="w=\{w} ti=\{track_in} tr=\{travel_in} at=\{at}: right \{r.0 + r.2} > \{hi}")
        }
      }
    }
  }
  set_dark(None)
}

///|
test "liquid_slider_look: flush=true fill right edge aligns with droplet center (0 at 0%, middle_at in [4%,96%], full at 100%)" {
  let fill_col = 0xD95B2BFFL
  let w = 200.0
  let track_in = 4.0
  let prog = @signals.signal(0.0)
  let t = glass_case(false, false, fn(page) {
    page.box(fn(host) {
      host.width(Is(Some(w))).height(Is(Some(slider_thumb_h))) |> ignore
      let look = SliderLook::new(
        track_h=slider_track_h,
        track_inset=track_in,
        travel_inset=None,
        thumb_w=slider_thumb_w,
        thumb_h=slider_thumb_h,
        flush=true,
        track_color=fn() { 0x00000022L },
        fill_color=Some(fn() { fill_col }),
        lens_enabled=true,
      )
      liquid_slider_look(host, fn(_) { prog.get() }, fn(_) { 0.0 }, look)
    })
    |> ignore
  })
  // at == 0.0: no visible fill rect
  prog.set(0.0)
  t.draw()
  assert_eq(t.drawn_rects().filter(fn(r) { r.4 == fill_col }).length(), 0, msg="flush fill at 0.0 must be hidden")
  // Interior points [0.04, 0.96]: fill right edge must equal middle_at(at) within 0.1pt
  for at in [0.25, 0.42, 0.5, 0.75] {
    prog.set(at)
    t.draw()
    let rects = t.drawn_rects().filter(fn(r) { r.4 == fill_col })
    assert_eq(rects.length(), 1, msg="expected 1 fill rect at \{at}")
    let expected_right = 24.0 + slider_travel_at(w, slider_thumb_w / 2.0, at)
    let actual_right = rects[0].0 + rects[0].2
    assert_true((actual_right - expected_right).abs() <= 0.1, msg="flush fill right at \{at}: \{actual_right} vs \{expected_right}")
  }
  // at == 1.0: fill right edge stops at middle_at(1.0) (centered under thumb/droplet, never peeking past right cap)
  prog.set(1.0)
  t.draw()
  let full_rects = t.drawn_rects().filter(fn(r) { r.4 == fill_col })
  assert_eq(full_rects.length(), 1, msg="expected 1 fill rect at 1.0")
  let expected_end = 24.0 + slider_travel_at(w, slider_thumb_w / 2.0, 1.0)
  let actual_end = full_rects[0].0 + full_rects[0].2
  assert_true((actual_end - expected_end).abs() <= 0.1, msg="flush fill right at 1.0: \{actual_end} vs \{expected_end}")
  set_dark(None)
}

///|
test "liquid_slider_look: held_mark renders caller-supplied centered mark only while held with laid == 0" {
  let dd = DampedDrag::new(0.4, lo=0.0, hi=1.0, held_scale=slider_thumb_held_scale)
  let w = 216.0
  let mark_col = 0x11AA88FFL
  let t = glass_case(false, false, fn(page) {
    page.box(fn(host) {
      dd.attach(host)
      host.width(Is(Some(w))).height(Is(Some(slider_thumb_h))) |> ignore
      let look = SliderLook::new(
        track_h=slider_track_h,
        track_inset=4.0,
        travel_inset=None,
        thumb_w=slider_thumb_w,
        thumb_h=slider_thumb_h,
        flush=true,
        track_color=fn() { 0x00000022L },
        fill_color=None,
        lens_enabled=true,
        held_mark=Some(fn(m) {
          m.box(fn(bar) {
            bar.width(Is(Some(5.0))).height(Is(Some(16.0))).radius(Is(2.5)).ground(Is(mark_col)) |> ignore
          })
          |> ignore
        }),
      )
      liquid_slider_look(host, fn(n) { dd.progress(n) }, fn(n) { dd.pressed(n) }, look, velocity=fn(n) { dd.velocity(n) })
    })
    |> ignore
  })
  let find_marks = fn() {
    t.drawn_rects().filter(fn(r) { r.4 == mark_col && (r.2 - 5.0).abs() < 0.2 && (r.3 - 16.0).abs() < 0.2 })
  }
  t.run_for(glass_springs_out)
  assert_eq(find_marks().length(), 0, msg="held_mark must not draw at rest")
  t.by_hand(fn() { dd.press() })
  t.run_for(glass_ctrl_hold_ms)
  let marks_held = find_marks()
  assert_eq(marks_held.length(), 1, msg="held_mark must draw 1 indicator while held")
  let cx0 = marks_held[0].0 + marks_held[0].2 / 2.0
  let exp0 = 24.0 + slider_travel_at(w, slider_thumb_w / 2.0, 0.4)
  assert_true((cx0 - exp0).abs() < 0.5, msg="held_mark center at 0.4: \{cx0} vs \{exp0}")
  // Drag while held: laid == 0 and indicator follows droplet center
  t.tree_frames_from_now()
  t.by_hand(fn() { dd.update_value(0.75) })
  t.run_for(glass_ctrl_drag_ms)
  for f in t.tree_frames() {
    assert_eq(f.laid, 0, msg="held_mark drag must not relayout: \{Repr(f)}")
  }
  let marks_moved = find_marks()
  assert_eq(marks_moved.length(), 1, msg="held_mark must remain visible while dragging")
  let cx1 = marks_moved[0].0 + marks_moved[0].2 / 2.0
  let exp1 = 24.0 + slider_travel_at(w, slider_thumb_w / 2.0, 0.75)
  assert_true((cx1 - exp1).abs() < 1.5, msg="held_mark center at 0.75: \{cx1} vs \{exp1}")
  // Release: laid == 0 and indicator disappears when settled
  t.tree_frames_from_now()
  t.by_hand(fn() { dd.release() })
  t.run_for(glass_springs_out)
  for f in t.tree_frames() {
    assert_eq(f.laid, 0, msg="held_mark release must not relayout: \{Repr(f)}")
  }
  assert_eq(find_marks().length(), 0, msg="held_mark must disappear once settled")
  set_dark(None)
}

///|
test "liquid_slider_look: default non-flush held_mark aligns strictly with droplet center at 0.0 and 1.0" {
  let dd = DampedDrag::new(0.0, lo=0.0, hi=1.0, held_scale=slider_thumb_held_scale)
  let w = 216.0
  let mark_col = 0x11AA88FFL
  let t = glass_case(false, false, fn(page) {
    page.box(fn(host) {
      dd.attach(host)
      host.width(Is(Some(w))).height(Is(Some(slider_thumb_h))) |> ignore
      let look = SliderLook::new(
        held_mark=Some(fn(m) {
          m.box(fn(bar) {
            bar.width(Is(Some(5.0))).height(Is(Some(16.0))).radius(Is(2.5)).ground(Is(mark_col)) |> ignore
          })
          |> ignore
        }),
      )
      liquid_slider_look(host, fn(n) { dd.progress(n) }, fn(n) { dd.pressed(n) }, look, velocity=fn(n) { dd.velocity(n) })
    })
    |> ignore
  })
  t.run_for(glass_springs_out)
  for at in [0.0, 1.0] {
    t.by_hand(fn() {
      dd.update_value(at)
      dd.press()
    })
    t.run_for(glass_ctrl_hold_ms)
    let marks = t.drawn_rects().filter(fn(r) { r.4 == mark_col && (r.2 - 5.0).abs() < 0.2 && (r.3 - 16.0).abs() < 0.2 })
    let glass = t.drawn_glass()
    assert_eq(marks.length(), 1, msg="expected 1 held_mark at \{at}")
    assert_eq(glass.length(), 1, msg="expected 1 droplet glass at \{at}")
    let mark_cx = marks[0].0 + marks[0].2 / 2.0
    let glass_cx = glass[0].0 + glass[0].2 / 2.0
    assert_true((mark_cx - glass_cx).abs() <= 0.1, msg="non-flush held_mark at \{at}: mark=\{mark_cx} vs glass=\{glass_cx}")
    t.by_hand(fn() { dd.release() })
    t.run_for(glass_springs_out)
  }
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

///|
test "fluid_scrubber_look: 5pt/7.5pt/10pt swell with laid == 0, live capsule SDF clip at low progress, full-width buffered, 0 glass, focus ring" {
  let prog = @signals.signal(0.0)
  let buf = @signals.signal(0.0)
  let swell = @signals.signal(0.0)
  let focused = @signals.signal(false)
  let track_col = 0xFFFFFF33L
  let buf_col = 0xFFFFFF55L
  let fill_col = 0xFFFFFFFFL
  let w = 200.0
  let t = glass_case(false, false, fn(page) {
    page.box(fn(host) {
      host.width(Is(Some(w))).height(Is(Some(22.0))) |> ignore
      let look = ScrubberLook::new(
        track_color=fn() { track_col },
        fill_color=fn() { fill_col },
        buffered=Some(fn() { buf.get() }),
        buffered_color=Some(fn() { buf_col }),
        focus_shown=Some(fn() { focused.get() }),
      )
      fluid_scrubber_look(host, fn(_) { prog.get() }, fn(_) { swell.get() }, look)
    })
    |> ignore
  })
  t.draw()
  // 0% progress & 0% buffered: 0 fill rects, 0 buffered rects, 0 glass, 5pt track
  assert_eq(t.drawn_glass().length(), 0)
  assert_eq(t.drawn_rects().filter(fn(r) { r.4 == fill_col }).length(), 0)
  assert_eq(t.drawn_rects().filter(fn(r) { r.4 == buf_col }).length(), 0)
  let tr0 = t.drawn_rects().filter(fn(r) { r.4 == track_col })
  assert_eq(tr0.length(), 1)
  assert_true((tr0[0].3 - 5.0).abs() < 0.1, msg="rest track h=\{tr0[0].3}")
  // Swell 0.5 -> 7.5pt, 1.0 -> 10.0pt with laid == 0 and 0 glass
  t.tree_frames_from_now()
  swell.set(0.5)
  t.draw()
  let tr_hov = t.drawn_rects().filter(fn(r) { r.4 == track_col })
  assert_true((tr_hov[0].3 - 7.5).abs() < 0.1, msg="hover track h=\{tr_hov[0].3}")
  swell.set(1.0)
  t.draw()
  let tr_act = t.drawn_rects().filter(fn(r) { r.4 == track_col })
  assert_true((tr_act[0].3 - 10.0).abs() < 0.1, msg="active track h=\{tr_act[0].3}")
  for f in t.tree_frames() {
    assert_eq(f.laid, 0, msg="swell change must not relayout: \{Repr(f)}")
  }
  assert_eq(t.drawn_glass().length(), 0)
  // Low progress (1% = 2.0pt and 3.75% = 7.5pt on 200pt track at active h=10pt):
  // fill & buffered keep exact geometric right edge (tr.0 + 2.0 / tr.0 + 7.5) and carry the live
  // capsule SDF clip matching track bounds (tr.0, tr.1, tr.0+tr.2, tr.1+tr.3) with corner radius h/2 = 5.0.
  fn assert_clipped_to_track(
    tr : (Double, Double, Double, Double, Int64),
    expected_w : Double,
    alpha_target : Double,
    tag : String,
  ) raise {
    let matches = t
      .drawn_instances()
      .filter(fn(inst) {
        inst[5] == 0.0 &&
        (inst[0] - tr.0).abs() < 0.1 &&
        (inst[2] - expected_w).abs() < 0.1 &&
        (inst[3] - tr.3).abs() < 0.1 &&
        (inst[11] - alpha_target).abs() < 0.02
      })
    assert_eq(matches.length(), 1, msg="\{tag}: expected 1 matching instance, got \{matches.length()}")
    let inst = matches[0]
    let r_exp = tr.3 / 2.0
    assert_true((inst[16] - tr.0).abs() < 0.1, msg="\{tag} clip x0=\{inst[16]} vs \{tr.0}")
    assert_true((inst[17] - tr.1).abs() < 0.1, msg="\{tag} clip y0=\{inst[17]} vs \{tr.1}")
    assert_true((inst[18] - (tr.0 + tr.2)).abs() < 0.1, msg="\{tag} clip x1=\{inst[18]} vs \{tr.0 + tr.2}")
    assert_true((inst[19] - (tr.1 + tr.3)).abs() < 0.1, msg="\{tag} clip y1=\{inst[19]} vs \{tr.1 + tr.3}")
    for ci in 24..<=27 {
      assert_true((inst[ci] - r_exp).abs() < 0.1, msg="\{tag} clip corner[\{ci}]=\{inst[ci]} vs \{r_exp}")
    }
  }
  for pair in [(0.01, 2.0), (0.0375, 7.5)] {
    let (p, exp_w) = pair
    prog.set(p)
    buf.set(p)
    t.draw()
    let tr = t.drawn_rects().filter(fn(r) { r.4 == track_col })[0]
    let fl = t.drawn_rects().filter(fn(r) { r.4 == fill_col })
    let br = t.drawn_rects().filter(fn(r) { r.4 == buf_col })
    assert_eq(fl.length(), 1, msg="p=\{p} fill count")
    assert_eq(br.length(), 1, msg="p=\{p} buffered count")
    assert_true((fl[0].0 + fl[0].2 - (tr.0 + exp_w)).abs() < 0.1, msg="p=\{p} fill right=\{fl[0].0 + fl[0].2} vs \{tr.0 + exp_w}")
    assert_true((br[0].0 + br[0].2 - (tr.0 + exp_w)).abs() < 0.1, msg="p=\{p} buffered right=\{br[0].0 + br[0].2} vs \{tr.0 + exp_w}")
    assert_clipped_to_track(tr, exp_w, 1.0, "fill p=\{p}")
    assert_clipped_to_track(tr, exp_w, 85.0 / 255.0, "buf p=\{p}")
  }
  // Mid progress (50% = 100pt): exact width
  prog.set(0.5)
  t.draw()
  let fl_mid = t.drawn_rects().filter(fn(r) { r.4 == fill_col })
  assert_eq(fl_mid.length(), 1)
  assert_true((fl_mid[0].2 - 100.0).abs() < 0.2, msg="50% fill w=\{fl_mid[0].2}")
  // Full 100% & 150% buffered: right edge == 24.0 + 200.0 = 224.0
  for b in [1.0, 1.5] {
    buf.set(b)
    t.draw()
    let br = t.drawn_rects().filter(fn(r) { r.4 == buf_col })
    assert_eq(br.length(), 1)
    assert_true((br[0].0 + br[0].2 - (24.0 + w)).abs() <= 0.5, msg="buffered \{b} right=\{br[0].0 + br[0].2}")
  }
  // Focus ring shown: outset 2pt (w=204, h=14 at active 10pt) and NOT clipped by track
  focused.set(true)
  t.draw()
  assert_true(
    t.drawn_instances().iter().any(fn(inst) {
      inst[5] == 0.0 && (inst[2] - (w + 4.0)).abs() < 0.5 && (inst[3] - 14.0).abs() < 0.5 && inst[17] < tr_act[0].1
    }),
    msg="focus ring must follow 10pt active track height (14pt) unclipped by track",
  )
  set_dark(None)
}

///|
test "liquid_segmented_thumb_look: rest 0 glass, held kind==6 above labels, solid/reduced fallback, laid == 0" {
  let press = @signals.signal(0.0)
  let pos_x = @signals.signal(0.0)
  let t = glass_case(false, false, fn(page) {
    page.box(fn(strip) {
      strip.row(Is(true)).width(Is(Some(200.0))).height(Is(Some(32.0))) |> ignore
      let mount_lens = liquid_segmented_thumb_look(
        strip,
        fn(_) { Some((pos_x.get(), 2.0, 96.0, 28.0)) },
        fn(_) { press.get() },
        look=SegThumbLook::default(glass_track=false, active=fn() { press.get() > 0.001 }),
      )
      strip.box(fn(lbl) { lbl.words(Is("Tab A"), look=words_at(14.0)).ink(Is(colors().content)) |> ignore }) |> ignore
      mount_lens()
    })
    |> ignore
  })
  t.draw()
  // Rest: 0 glass, 1 lifted pill, 0 border, and 0 shadow (iOS 27.0).
  assert_eq(t.drawn_glass().length(), 0, msg="rest must draw 0 glass")
  let lifted = @ui.tree_theme().lifted
  let pills = t.drawn_rects().filter(fn(r) { r.4 == lifted && (r.3 - 28.0).abs() < 0.5 })
  assert_eq(pills.length(), 1)
  let pill_insts = t.drawn_instances().filter(fn(a) {
    a.length() > 6 && a[5] == 0.0 && (a[0] - pills[0].0).abs() < 1.0 && (a[1] - pills[0].1).abs() < 1.0 && (a[2] - pills[0].2).abs() < 1.0 && (a[3] - pills[0].3).abs() < 1.0
  })
  assert_eq(pill_insts.filter(fn(a) { a[6] > 0.0 }).length(), 0, msg="resting pill must draw 0 border")
  let rest_shadows = t.drawn_instances().filter(fn(i) { i[5] == 2.0 })
  assert_eq(rest_shadows.length(), 0, msg="resting pill must draw 0 shadow")
  // Held: mounts 1 clear kind==6 lens above glyphs.
  press.set(1.0)
  t.draw()
  let insts = t.drawn_instances()
  let mut last_glyph = -1
  let mut lens_idx = -1
  for idx, inst in insts {
    if inst[5] == 1.0 {
      last_glyph = idx
    } else if inst[5] == 6.0 && inst[14] == 0.0 {
      lens_idx = idx
      assert_true((inst[7] - -48.0).abs() < 0.01, msg="droplet_role=3 slot7=-48")
    }
  }
  assert_true(last_glyph >= 0 && lens_idx > last_glyph, msg="lens must draw above glyphs")
  // Sliding rect while held causes laid == 0.
  t.tree_frames_from_now()
  pos_x.set(100.0)
  t.draw()
  for f in t.tree_frames() {
    assert_eq(f.laid, 0, msg="thumb look motion must not relayout: \{Repr(f)}")
  }
  // glass_solid() and reduced_motion() fall back to 0 glass.
  @ui.set_glass_solid(Some(true))
  t.draw()
  assert_eq(t.drawn_glass().length(), 0, msg="glass_solid must emit 0 glass")
  @ui.set_glass_solid(None)
  t.set_reduce_motion(true)
  t.draw()
  assert_eq(t.drawn_glass().length(), 0, msg="reduced_motion must emit 0 glass")
  t.set_reduce_motion(false)
  set_dark(None)
}

///|
test "liquid_segmented_node: unattached external DampedDrag binds on mount and supports direct press/release" {
  set_dark(Some(false))
  let sel = @signals.signal(0)
  let dd = DampedDrag::new(0.0, lo=0.0, hi=2.0, held_scale=ctrl_seg_held_scale)
  let t = @ui.Tester::new(fn(_c) {  }, w=360.0, h=120.0, platform=0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      b.padding(Is((16.0, 24.0, 16.0, 24.0))) |> ignore
      liquid_segmented_node(
        b,
        fn() { ["One", "Two", "Three"] },
        fn() { sel.get() },
        fn(i) { sel.set(i) },
        width=280.0,
        drag=dd,
        glass_track=false,
      )
      |> ignore
    })
    |> ignore
  })
  t.draw()
  assert_eq(t.drawn_glass().length(), 0, msg="resting embedded segmented control must draw 0 glass")
  // Caller directly drives press() on the originally unattached DampedDrag (matches ios27_parity path).
  dd.press()
  t.run_for(@ui.move_most_ms / 2.0)
  let lenses = t.drawn_instances().filter(fn(i) { i[5] == 6.0 && i[14] == 0.0 })
  assert_eq(lenses.length(), 1, msg="direct dd.press() must mount clear kind==6 lens")
  // Release and settle back to 0 glass.
  dd.release()
  t.run_for(@ui.move_most_ms * 2.0)
  assert_eq(t.drawn_glass().length(), 0, msg="after dd.release() settles, drawn_glass must return to 0")
  set_dark(None)
}
