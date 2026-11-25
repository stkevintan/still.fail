// Tests for single-layer iOS 27 Liquid Glass floating surfaces in `player_node.mbt`:
// 1. Non-embedded desktop & phone video players use `ViewerDark` (`@glass.liquid_viewer_dark_glass`)
//    with outside-only `glass_control_shadow()`, zero extra solid ground fills on the glass shell,
//    and degrade cleanly to `media_dark_ground` + hairline edge under `MBUI_GLASS=solid`.
// 2. Non-embedded audio players use theme-adaptive `Floating` (`@glass.liquid_floating_glass`).
// 3. Auto-hidden / dismissed player controls emit zero hidden glass instances and zero shadows.
// 4. Failed and ended cards (`night_card_node`) use liquid glass with `glass_overlay_shadow()`.
// 5. Embedded players (`embedded == true`) emit zero liquid glass instances.

///|
fn player_glass_tester(
  narrow : Bool,
  kind : String,
  dark : Bool,
  solid : Bool,
  embedded? : Bool = false,
  pin? : @player.MediaStatus,
  list? : Array[String] = ["E1.mp4", "E2.mp4"],
  env? : Array[(String, String)] = [],
) -> @ui.Tester {
  let (w, h, platform) = if narrow { (390.0, 844.0, 1) } else { (1280.0, 800.0, 0) }
  set_viewer_host(viewer_host_default())
  set_words(fn(key, args) {
    args.fold(init=test_words.get(key).unwrap_or(key), fn(said, a) { said.replace_all(old="{" + a.0 + "}", new=a.1) })
  })
  let name = if kind == "audio" { "song.m4a" } else { "E1.mp4" }
  let siblings : Array[ViewerEntry] = list.map(fn(n) { { name: n, size: 1.0, mtime: 0.0, mime: "", kind, dir: false } })
  let file = film(name, kind~)
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w~, h~, dark~, platform~, env~)
  set_dark(Some(dark))
  @ui.set_glass_solid(if solid { Some(true) } else { None })
  match pin {
    Some(s) => playing_for("k").media.pin(s)
    None => ()
  }
  @ui.set_view_app(
    fn(root) {
      root.box(fn(n) {
        n.grow(Is(1.0)) |> ignore
        let m = player_opened(n, "k", file, fn() { siblings })
        player_node(
          n,
          m,
          file,
          fn() { n.window() },
          back_label=fn() { "影片" },
          on_back=fn() {  },
          still=fn() { "" },
          flying=fn() { false },
          going=fn() { false },
          move_beside=fn() { None },
          list=fn() { playlist_for(file, siblings) },
          on_go=fn(_) {  },
          embedded~,
        )
        |> ignore
      })
      |> ignore
    },
    theme=ui_theme_now,
  )
  t.draw()
  t
}

///|
fn liquid_blurs(t : @ui.Tester) -> Array[Double] {
  t.drawn_instances().filter(fn(a) { a.length() > 22 && a[5] == 6.0 }).map(fn(a) { a[7] })
}

///|
test "player_node video controls use ViewerDark liquid glass with outside shadow and degrade cleanly under MBUI_GLASS=solid" {
  for narrow in [false, true] {
    for dark in [false, true] {
      let t = player_glass_tester(narrow, "video", dark, false)
      let glass = t.drawn_glass()
      let liquid = glass.filter(fn(g) { g.4 == 6 })
      // Phone has top 48pt capsule + bottom card (2); desktop has viewer_bar pills + bottom control bar (>= 2).
      let expected_min = if narrow { 2 } else { 2 }
      assert_true(liquid.length() >= expected_min, msg="narrow=\{narrow} dark=\{dark} liquid=\{liquid.length()}")
      assert_true(has_outside_shadow(t), msg="narrow=\{narrow} dark=\{dark} outside shadow")
      // Every bottom/top player glass instance over video uses ViewerDark (blur = 4.0).
      let blurs = liquid_blurs(t)
      assert_true(blurs.iter().all(fn(b) { (b - 4.0).abs() < 0.01 }), msg="narrow=\{narrow} dark=\{dark} blurs=\{Repr(blurs)}")
      // Solid fallback: 0 liquid glass instances, solid media_dark_ground drawn.
      let ts = player_glass_tester(narrow, "video", dark, true)
      assert_eq(ts.drawn_glass().length(), 0, msg="narrow=\{narrow} dark=\{dark} solid glass count")
      assert_true(
        ts.drawn_rects().iter().any(fn(r) { r.4 == media_dark_ground }),
        msg="narrow=\{narrow} dark=\{dark} solid ground fallback",
      )
    }
  }
  @ui.set_glass_solid(None)
  set_dark(None)
}

///|
test "player_node audio controls use theme-adaptive Floating liquid glass" {
  for narrow in [false, true] {
    for dark in [false, true] {
      let t = player_glass_tester(narrow, "audio", dark, false)
      let blurs = liquid_blurs(t)
      // Floating liquid glass uses blur = 2.2 (distinct from ViewerDark's 4.0).
      assert_true(blurs.iter().any(fn(b) { (b - 2.2).abs() < 0.01 }), msg="narrow=\{narrow} dark=\{dark} audio blurs=\{Repr(blurs)}")
      assert_true(has_outside_shadow(t), msg="narrow=\{narrow} dark=\{dark} audio outside shadow")
    }
  }
  @ui.set_glass_solid(None)
  set_dark(None)
}

///|
test "player_node embedded mode emits zero liquid glass instances" {
  for narrow in [false, true] {
    for kind in ["video", "audio"] {
      let t = player_glass_tester(narrow, kind, false, false, embedded=true)
      assert_eq(t.drawn_glass().length(), 0, msg="narrow=\{narrow} kind=\{kind} embedded glass count")
    }
  }
  @ui.set_glass_solid(None)
  set_dark(None)
}

///|
test "player_node hidden controls emit zero hidden glass instances" {
  // Phone playing: tap stage once to hide controls, wait past fade-out.
  let t = player_glass_tester(true, "video", true, false, pin=pinned(2000.0))
  assert_eq(t.drawn_glass().length(), 2, msg="phone visible controls glass count")
  t.tap(195.0, 422.0)
  t.run_for(playing_for("k").media.times().1 + 600.0)
  assert_eq(t.drawn_glass().length(), 0, msg="phone hidden controls must emit zero glass")
  assert_eq(outside_shadows(t).length(), 0, msg="phone hidden controls must emit zero shadows")
  // Desktop playing: click stage once to hide controls, wait past fade-out.
  let td = player_glass_tester(false, "video", true, false, pin=pinned(2000.0))
  let before_glass = td.drawn_glass().length()
  assert_true(before_glass >= 2, msg="desktop visible controls glass count")
  td.tap(640.0, 400.0)
  td.run_for(playing_for("k").media.times().1 + 600.0)
  // Bottom control bar is hidden; remaining glass count drops strictly.
  assert_true(td.drawn_glass().length() < before_glass, msg="desktop hidden bottom bar drops glass count")
  @ui.set_glass_solid(None)
  set_dark(None)
}

///|
test "player_node failed and ended cards use liquid glass with overlay shadow" {
  let failed_pin : @player.MediaStatus = { ..pinned(1000.0), state: -1, playing: false }
  let tf = player_glass_tester(true, "video", true, false, pin=failed_pin)
  assert_true(tf.drawn_glass().length() >= 3, msg="phone failed card adds glass surface: \{tf.drawn_glass().length()}")
  assert_true(outside_shadows(tf).iter().any(fn(s) { s == glass_overlay_shadow() }), msg="failed card uses glass_overlay_shadow")

  let te = player_glass_tester(true, "video", true, false, pin=pinned(10000.0, ended=true))
  assert_true(te.drawn_glass().length() >= 3, msg="phone ended card adds glass surface: \{te.drawn_glass().length()}")
  assert_true(outside_shadows(te).iter().any(fn(s) { s == glass_overlay_shadow() }), msg="ended card uses glass_overlay_shadow")

  @ui.set_glass_solid(None)
  set_dark(None)
}

///|
let player_slider_hold_ms : Double = 250.0

///|
let player_slider_drag_ms : Double = 200.0

///|
let player_slider_settle_ms : Double = 500.0

///|
fn scrubber_bars(
  t : @ui.Tester,
  sl : (Double, Double, Double, Double),
  col : Int64,
) -> Array[(Double, Double, Double, Double, Int64)] {
  t
  .drawn_rects()
  .filter(fn(r) {
    r.4 == col &&
    r.3 >= 3.0 &&
    r.3 <= 12.0 &&
    r.0 >= sl.0 - 0.5 &&
    r.0 + r.2 <= sl.0 + sl.2 + 0.5 &&
    r.1 >= sl.1 - 2.0 &&
    r.1 + r.3 <= sl.1 + sl.3 + 2.0
  })
}

///|
test "player_node fluid scrubber timeline and volume: 5pt rest, 7.5pt hover, 10pt active, laid == 0, 0 dots/capsules/extra glass, reduced_motion stays 5pt" {
  let track_col = alpha(media_dark_text, media_track_share)
  let fill_col = media_dark_text
  for narrow in [false, true] {
    let t = player_glass_tester(narrow, "video", true, false, pin=pinned(3000.0))
    if !narrow {
      t.host_says_finger(Some(false))
      t.draw()
    }
    let rest_glass = t.drawn_glass().length()
    let labels = if narrow {
      ["web-pages.drive.player.position"]
    } else {
      ["web-pages.drive.player.position", "web-pages.drive.player.volume"]
    }
    for label in labels {
      let sl = t.get(Slider, label~).rect
      let cy = sl.1 + sl.3 / 2.0
      // Rest: 5pt track & fill, zero circular dots (12x12/10x10), zero 38x24 white capsules
      let tracks_rest = scrubber_bars(t, sl, track_col)
      let fills_rest = scrubber_bars(t, sl, fill_col)
      assert_eq(tracks_rest.length(), 1, msg="narrow=\{narrow} \{label} rest track count")
      assert_eq(fills_rest.length(), 1, msg="narrow=\{narrow} \{label} rest fill count")
      assert_true((tracks_rest[0].3 - 5.0).abs() < 0.2, msg="narrow=\{narrow} \{label} rest track h=\{tracks_rest[0].3}")
      assert_true((fills_rest[0].3 - 5.0).abs() < 0.2, msg="narrow=\{narrow} \{label} rest fill h=\{fills_rest[0].3}")
      let old_knobs = t
        .drawn_rects()
        .filter(fn(r) {
          r.0 >= sl.0 - 20.0 &&
          r.0 <= sl.0 + sl.2 + 20.0 &&
          r.1 >= sl.1 - 8.0 &&
          r.1 <= sl.1 + sl.3 + 8.0 &&
          (((r.2 - 12.0).abs() < 0.5 && (r.3 - 12.0).abs() < 0.5) ||
            ((r.2 - 10.0).abs() < 0.5 && (r.3 - 10.0).abs() < 0.5) ||
            (r.4 == 0xFFFFFFFFL && (r.2 - 38.0).abs() < 0.5 && (r.3 - 24.0).abs() < 0.5))
        })
      assert_eq(old_knobs.length(), 0, msg="narrow=\{narrow} \{label} must have 0 circular dots or 38x24 capsules")
      // Desktop hover -> swells to ~7.5pt with laid == 0 and 0 extra glass
      if !narrow {
        t.move_to(sl.0 + sl.2 * 0.4, cy)
        t.tree_frames_from_now()
        t.run_for(player_slider_settle_ms)
        for f in t.tree_frames() {
          assert_eq(f.laid, 0, msg="\{label} hover swell must not relayout: \{Repr(f)}")
        }
        assert_eq(t.drawn_glass().length(), rest_glass, msg="\{label} hover must add 0 glass")
        let tracks_hov = scrubber_bars(t, sl, track_col)
        assert_eq(tracks_hov.length(), 1)
        assert_true(
          tracks_hov[0].3 >= 7.0 && tracks_hov[0].3 <= 8.0,
          msg="\{label} hover track must swell to ~7.5pt, got \{tracks_hov[0].3}",
        )
      }
      // Press & hold -> swells to ~10pt with 0 extra glass
      let x0 = sl.0 + sl.2 * 0.35
      let x1 = sl.0 + sl.2 * 0.70
      t.press_at(x0, cy)
      t.run_for(player_slider_hold_ms)
      assert_eq(t.drawn_glass().length(), rest_glass, msg="narrow=\{narrow} \{label} held must add 0 glass")
      let tracks_held = scrubber_bars(t, sl, track_col)
      assert_eq(tracks_held.length(), 1)
      assert_true(
        tracks_held[0].3 >= 9.5 && tracks_held[0].3 <= 10.5,
        msg="narrow=\{narrow} \{label} held track must swell to ~10pt, got \{tracks_held[0].3}",
      )
      // Drag -> laid == 0 on animation frames (volume laid == 0 throughout), 0 extra glass
      if label == "web-pages.drive.player.volume" {
        t.tree_frames_from_now()
        t.move_to(x1, cy)
      } else {
        t.move_to(x1, cy)
        assert_eq(t.get(Slider, label~).rect, sl, msg="narrow=\{narrow} \{label} rect must not shift on drag")
        t.tree_frames_from_now()
      }
      t.run_for(player_slider_drag_ms)
      for f in t.tree_frames() {
        assert_eq(f.laid, 0, msg="narrow=\{narrow} \{label} drag must not relayout: \{Repr(f)}")
      }
      assert_eq(t.drawn_glass().length(), rest_glass, msg="narrow=\{narrow} \{label} drag must add 0 glass")
      // Release & move pointer off -> returns to 5pt with laid == 0 and 0 extra glass
      if label == "web-pages.drive.player.volume" {
        t.tree_frames_from_now()
        t.release(x1, cy)
      } else {
        t.release(x1, cy)
        assert_eq(t.get(Slider, label~).rect, sl, msg="narrow=\{narrow} \{label} rect must not shift on release")
        t.tree_frames_from_now()
      }
      if !narrow {
        t.move_to(10.0, 10.0)
        t.tree_frames_from_now()
      }
      t.run_for(player_slider_settle_ms)
      for f in t.tree_frames() {
        assert_eq(f.laid, 0, msg="narrow=\{narrow} \{label} release must not relayout: \{Repr(f)}")
      }
      assert_eq(t.drawn_glass().length(), rest_glass, msg="narrow=\{narrow} \{label} settled must add 0 glass")
      let tracks_done = scrubber_bars(t, sl, track_col)
      assert_eq(tracks_done.length(), 1)
      assert_true(
        (tracks_done[0].3 - 5.0).abs() < 0.2,
        msg="narrow=\{narrow} \{label} settled track must return to 5pt, got \{tracks_done[0].3}",
      )
    }
  }
  // reduced_motion(): hover and press stay strictly at 5.0pt with 0 extra glass
  let tr = player_glass_tester(false, "video", true, false, pin=pinned(3000.0), env=[("MBUI_REDUCE_MOTION", "1")])
  let rest_glass_r = tr.drawn_glass().length()
  for label in ["web-pages.drive.player.position", "web-pages.drive.player.volume"] {
    let sl = tr.get(Slider, label~).rect
    let cy = sl.1 + sl.3 / 2.0
    let x0 = sl.0 + sl.2 * 0.5
    tr.press_at(x0, cy)
    tr.run_for(player_slider_hold_ms)
    assert_eq(tr.drawn_glass().length(), rest_glass_r, msg="reduced_motion \{label} held glass")
    let tracks = scrubber_bars(tr, sl, track_col)
    assert_eq(tracks.length(), 1)
    assert_true(
      (tracks[0].3 - 5.0).abs() < 0.2,
      msg="reduced_motion \{label} held must stay 5pt, got \{tracks[0].3}",
    )
    tr.release(x0, cy)
    tr.run_for(player_slider_settle_ms)
  }
  @ui.set_glass_solid(None)
  set_dark(None)
}

///|
test "player_node fluid scrubber: tapping 25% and 75% maps 1:1 on inset timeline and full volume track, playback follows shown() directly" {
  let t = player_glass_tester(false, "video", true, false)
  t.set_player(1, position=0.0, duration=10000.0, playing=true)
  t.draw()
  let tl = t.get(Slider, label="web-pages.drive.player.position").rect
  let tl_cy = tl.1 + tl.3 / 2.0
  let tl_left = tl.0 + player_track_inset
  let tl_span = tl.2 - 2.0 * player_track_inset
  // Playback direct-read: position=4000ms immediately aligns fill left at inset and right at 40% with zero animation lag
  t.set_player(1, position=4000.0, duration=10000.0, playing=true)
  t.draw()
  let fills_40 = scrubber_bars(t, tl, media_dark_text)
  assert_eq(fills_40.length(), 1)
  assert_true((fills_40[0].0 - tl_left).abs() < 0.5, msg="timeline fill left \{fills_40[0].0} vs inset \{tl_left}")
  let expected_40 = tl_left + tl_span * 0.4
  let actual_40 = fills_40[0].0 + fills_40[0].2
  assert_true(
    (actual_40 - expected_40).abs() < 1.0,
    msg="direct shown() fill right at 40%: \{actual_40} vs \{expected_40}",
  )
  // Tap timeline at 25% and 75% (inset track [inset, w - inset])
  for pair in [(0.25, "2500"), (0.75, "7500")] {
    let (frac, ms_str) = pair
    let tap_x = tl_left + tl_span * frac
    t.tap(tap_x, tl_cy)
    assert_true(told(t, 11, value=ms_str), msg="timeline tap at \{frac} must seek_near \{ms_str}")
  }
  // Tap volume at 25% and 75% (full track 0..w, 0pt inset)
  let vol = t.get(Slider, label="web-pages.drive.player.volume").rect
  let vol_cy = vol.1 + vol.3 / 2.0
  for frac in [0.25, 0.75] {
    let tap_x = vol.0 + vol.2 * frac
    t.tap(tap_x, vol_cy)
    t.draw()
    let (v_now, _) = playing_for("k").media.volume()
    assert_true((v_now - frac).abs() < 0.01, msg="volume tap at \{frac} gave \{v_now}")
    let vfills = scrubber_bars(t, vol, media_dark_text)
    assert_eq(vfills.length(), 1)
    let right = vfills[0].0 + vfills[0].2
    assert_true((right - tap_x).abs() < 1.0, msg="volume fill right \{right} vs tap \{tap_x}")
  }
  @ui.set_glass_solid(None)
  set_dark(None)
}

///|
test "player_node fluid scrubber volume: Up commits release x, out-of-bounds clamps [0, 1], Off keeps last value and shrinks to 5pt" {
  let track_col = alpha(media_dark_text, media_track_share)
  let t = player_glass_tester(false, "video", true, false, pin=pinned(3000.0))
  let vol = t.get(Slider, label="web-pages.drive.player.volume").rect
  let cy = vol.1 + vol.3 / 2.0
  assert_true((vol.2 - 72.0).abs() < 0.5, msg="desktop volume width must be 72pt, got \{vol.2}")
  // Down + Moved to x=18 (25%), then Up directly at x=54 (75%) -> commits 0.75
  t.press_at(vol.0 + 18.0, cy)
  t.move_to(vol.0 + 18.0, cy)
  t.draw()
  let (v_mid, _) = playing_for("k").media.volume()
  assert_true((v_mid - 0.25).abs() < 0.01, msg="volume at x=18 expected 0.25, got \{v_mid}")
  t.release(vol.0 + 54.0, cy)
  t.draw()
  let (v_up, _) = playing_for("k").media.volume()
  assert_true((v_up - 0.75).abs() < 0.01, msg="volume Up at x=54 must commit 0.75, got \{v_up}")
  // Out-of-bounds clamp: x < 0 -> 0.0, x > w -> 1.0
  t.press_at(vol.0 + 36.0, cy)
  t.move_to(vol.0 - 20.0, cy)
  t.draw()
  let (v_lo, _) = playing_for("k").media.volume()
  assert_true(v_lo.abs() < 0.001, msg="volume x<0 must clamp to 0.0, got \{v_lo}")
  t.release(vol.0 + vol.2 + 20.0, cy)
  t.draw()
  let (v_hi, _) = playing_for("k").media.volume()
  assert_true((v_hi - 1.0).abs() < 0.001, msg="volume x>w must clamp to 1.0, got \{v_hi}")
  // Off (cancel): preserves last written value (0.40) and shrinks back to 5pt
  t.press_at(vol.0 + vol.2 * 0.4, cy)
  t.run_for(player_slider_hold_ms)
  assert_true(scrubber_bars(t, vol, track_col)[0].3 >= 9.5, msg="held volume swelled to ~10pt")
  t.touch(3, vol.0 + vol.2 * 0.9, cy)
  t.move_to(10.0, 10.0)
  t.run_for(player_slider_settle_ms)
  let (v_off, _) = playing_for("k").media.volume()
  assert_true((v_off - 0.4).abs() < 0.01, msg="Off must preserve last written volume 0.40, got \{v_off}")
  assert_true(
    (scrubber_bars(t, vol, track_col)[0].3 - 5.0).abs() < 0.2,
    msg="Off must shrink volume back to 5pt",
  )
  @ui.set_glass_solid(None)
  set_dark(None)
}

///|
test "player_node fluid scrubber buffered bar renders 0%, 60%, 100%, and 150% clamped to inset track bounds" {
  let buf_color = alpha(media_dark_text, media_came_share)
  let fill_color = media_dark_text
  // 0% buffered: 0 drawn buffered rects
  let t0 = player_glass_tester(false, "video", true, false, pin={ ..pinned(2000.0), buffered: 0.0 })
  let tl0 = t0.get(Slider, label="web-pages.drive.player.position").rect
  assert_eq(scrubber_bars(t0, tl0, buf_color).length(), 0, msg="0% buffered must draw 0 buffered segments")
  // 60% buffered: aligned left with inset track & fill, wider than 20% fill, inside inset track right
  let t60 = player_glass_tester(false, "video", true, false, pin={ ..pinned(2000.0), buffered: 6000.0 })
  let tl60 = t60.get(Slider, label="web-pages.drive.player.position").rect
  let bufs60 = scrubber_bars(t60, tl60, buf_color)
  let fills60 = scrubber_bars(t60, tl60, fill_color)
  assert_eq(bufs60.length(), 1, msg="expected 1 buffered segment at 60%")
  assert_eq(fills60.length(), 1, msg="expected 1 active fill segment at 60%")
  assert_true(
    (bufs60[0].0 - (tl60.0 + player_track_inset)).abs() < 0.5,
    msg="buffered left aligns with inset track left",
  )
  assert_true((fills60[0].0 - bufs60[0].0).abs() < 0.5, msg="fill left aligns with buffered left")
  assert_true(bufs60[0].2 > fills60[0].2 + 10.0, msg="60% buffered must be wider than 20% fill")
  assert_true(
    bufs60[0].0 + bufs60[0].2 <= tl60.0 + tl60.2 - player_track_inset + 0.5,
    msg="60% buffered inside inset track right",
  )
  // 100% and 150% buffered: right edge reaches inset track right (tl.0 + tl.2 - inset) within 0.5pt
  for buf_ms in [10000.0, 15000.0] {
    let tf = player_glass_tester(false, "video", true, false, pin={ ..pinned(2000.0), buffered: buf_ms })
    let tlf = tf.get(Slider, label="web-pages.drive.player.position").rect
    let bufs = scrubber_bars(tf, tlf, buf_color)
    assert_eq(bufs.length(), 1, msg="expected 1 buffered segment at \{buf_ms}ms")
    let track_right = tlf.0 + tlf.2 - player_track_inset
    let buf_right = bufs[0].0 + bufs[0].2
    assert_true(
      (buf_right - track_right).abs() <= 0.5,
      msg="buf_ms=\{buf_ms}: buffered right \{buf_right} must reach inset track right \{track_right}",
    )
  }
  @ui.set_glass_solid(None)
  set_dark(None)
}

///|
test "player_node fluid scrubber: cancel (Off) shrinks back to 5pt and Tab focus ring + arrow keys step value" {
  let track_col = alpha(media_dark_text, media_track_share)
  let t = player_glass_tester(false, "video", true, false, pin=pinned(3000.0))
  playing_for("k").media.set_volume(0.6)
  t.draw()
  // Cancel (Off) mid-hold shrinks track back to 5pt
  let tl_rect = t.get(Slider, label="web-pages.drive.player.position").rect
  let tl_cy = tl_rect.1 + tl_rect.3 / 2.0
  t.press_at(tl_rect.0 + tl_rect.2 * 0.4, tl_cy)
  t.run_for(player_slider_hold_ms)
  assert_true(scrubber_bars(t, tl_rect, track_col)[0].3 >= 9.5, msg="held timeline swelled to ~10pt")
  t.touch(3, tl_rect.0 + tl_rect.2 * 0.4, tl_cy)
  t.move_to(10.0, 10.0)
  t.run_for(player_slider_settle_ms)
  assert_true(
    (scrubber_bars(t, tl_rect, track_col)[0].3 - 5.0).abs() < 0.2,
    msg="Off/cancel must shrink timeline back to 5pt",
  )
  // Helper: 2pt outset focus pill around track rect (w - 2*inset + 4, h ~ 9pt at rest)
  let has_focus_ring = fn(sl : (Double, Double, Double, Double), inset : Double) -> Bool {
    t
    .drawn_instances()
    .iter()
    .any(fn(inst) {
      inst[5] == 0.0 &&
      (inst[2] - (sl.2 - 2.0 * inset + 4.0)).abs() < 1.0 &&
      inst[3] >= 8.0 &&
      inst[3] <= 16.0 &&
      (inst[0] - (sl.0 + inset - 2.0)).abs() < 1.0 &&
      inst[1] >= sl.1 - 4.0 &&
      inst[1] <= sl.1 + sl.3 + 4.0
    })
  }
  // Tab to timeline slider
  let tl_label = "web-pages.drive.player.position"
  let mut reached_tl = false
  for _ in 0..<25 {
    t.tab()
    if t.focused().map(fn(s) { s.label }) == Some(tl_label) {
      reached_tl = true
      break
    }
  }
  assert_true(reached_tl, msg="Tab must reach timeline slider")
  assert_true(has_focus_ring(tl_rect, player_track_inset), msg="focused timeline slider must draw outset pill focus ring")
  let before_views = t.views().length()
  t.key(@ui.key_code_right)
  t.draw()
  assert_true(
    t.views()[before_views:].iter().any(fn(l) { l.has_prefix("control 1 11 ") }),
    msg="Right arrow on focused timeline must seek_near",
  )
  // Tab to volume slider
  let vol_label = "web-pages.drive.player.volume"
  let mut reached_vol = false
  for _ in 0..<25 {
    t.tab()
    if t.focused().map(fn(s) { s.label }) == Some(vol_label) {
      reached_vol = true
      break
    }
  }
  assert_true(reached_vol, msg="Tab must reach volume slider")
  let vol_rect = t.get(Slider, label=vol_label).rect
  assert_true(has_focus_ring(vol_rect, 0.0), msg="focused volume slider must draw outset pill focus ring")
  t.key(@ui.key_code_left)
  t.key(@ui.key_code_left)
  t.draw()
  let (v_after, _) = playing_for("k").media.volume()
  assert_true(v_after < 0.55, msg="Left arrows on focused volume must decrease volume: \{v_after}")
  @ui.set_glass_solid(None)
  set_dark(None)
}

///|
test "player_node fluid scrubber 72pt volume at 1%: right edge stays 0.72pt across rest/hover/held with live track capsule clip" {
  let track_col = alpha(media_dark_text, media_track_share)
  let fill_col = media_dark_text
  let t = player_glass_tester(false, "video", true, false, pin=pinned(3000.0))
  t.host_says_finger(Some(false))
  t.draw()
  let vol = t.get(Slider, label="web-pages.drive.player.volume").rect
  let cy = vol.1 + vol.3 / 2.0
  assert_true((vol.2 - 72.0).abs() < 0.5, msg="desktop volume width must be 72pt, got \{vol.2}")
  // Tap at 1% (x = 0.72pt) and move pointer away to settle at idle 5pt
  t.tap(vol.0 + 0.72, cy)
  t.move_to(10.0, 10.0)
  t.run_for(player_slider_settle_ms)
  let (v1, _) = playing_for("k").media.volume()
  assert_true((v1 - 0.01).abs() < 0.001, msg="expected volume 0.01, got \{v1}")
  fn verify_bar(expected_h : Double, label : String) raise {
    let tracks = scrubber_bars(t, vol, track_col)
    let fills = scrubber_bars(t, vol, fill_col)
    assert_eq(tracks.length(), 1, msg="\{label}: expected 1 track")
    assert_eq(fills.length(), 1, msg="\{label}: expected 1 fill at 1%")
    let tr = tracks[0]
    let fl = fills[0]
    assert_true((tr.3 - expected_h).abs() < 0.3, msg="\{label}: track h=\{tr.3} vs \{expected_h}")
    let right_dx = fl.0 + fl.2 - tr.0
    assert_true((right_dx - 0.72).abs() < 0.05, msg="\{label}: 1% fill right_dx=\{right_dx} must stay 0.72pt")
    let fill_insts = t
      .drawn_instances()
      .filter(fn(inst) {
        inst[5] == 0.0 &&
        (inst[0] - tr.0).abs() < 0.1 &&
        (inst[2] - 0.72).abs() < 0.05 &&
        (inst[3] - tr.3).abs() < 0.2
      })
    assert_eq(fill_insts.length(), 1, msg="\{label}: expected 1 fill instance")
    let inst = fill_insts[0]
    let r_exp = tr.3 / 2.0
    assert_true((inst[16] - tr.0).abs() < 0.1, msg="\{label}: clip x0=\{inst[16]} vs \{tr.0}")
    assert_true((inst[17] - tr.1).abs() < 0.1, msg="\{label}: clip y0=\{inst[17]} vs \{tr.1}")
    assert_true((inst[18] - (tr.0 + tr.2)).abs() < 0.1, msg="\{label}: clip x1=\{inst[18]} vs \{tr.0 + tr.2}")
    assert_true((inst[19] - (tr.1 + tr.3)).abs() < 0.1, msg="\{label}: clip y1=\{inst[19]} vs \{tr.1 + tr.3}")
    for ci in 24..<=27 {
      assert_true((inst[ci] - r_exp).abs() < 0.1, msg="\{label}: clip corner[\{ci}]=\{inst[ci]} vs \{r_exp}")
    }
  }
  // 1. Idle (5.0pt)
  verify_bar(5.0, "idle")
  // 2. Hover (7.5pt)
  t.move_to(vol.0 + vol.2 * 0.5, cy)
  t.run_for(player_slider_settle_ms)
  verify_bar(7.5, "hover")
  // 3. Held at x = 0.72 (keeps 1% volume, swells to 10.0pt)
  t.press_at(vol.0 + 0.72, cy)
  t.run_for(player_slider_hold_ms)
  verify_bar(10.0, "held")
  t.release(vol.0 + 0.72, cy)
  t.move_to(10.0, 10.0)
  t.run_for(player_slider_settle_ms)
  @ui.set_glass_solid(None)
  set_dark(None)
}
