// Particle dissolve-and-reassemble flight tests (particle_flight_paint.mbt, @view.View::flies_in `particle=true`):
// exact endpoints at p == 0 and p == 1, fine-grained glyph splitting mid-flight with sub-atlas >= 1.5 and colour
// offset preserved, FPS-invariant determinism across 7/24/60/120fps, reduced_motion immediate landing, and zero
// words_over when particles sweep over another text node.

///|
let pf_dur_ms : Double = 400.0

///|
let pf_flight : @view.Flight = {
  way: fn(_) { if reduced_motion() { (0.0, fn(_) { 1.0 }) } else { (pf_dur_ms, fn(ms) { dclamp(ms / pf_dur_ms, 0.0, 1.0) }) } },
}

///|
/// Build a tree with an optional static obstacle label in the middle and a particle-flying label triggered by `sent`.
fn pf_scene(
  sent : @signals.Signal[Bool],
  obstacle? : Bool = false,
  reduced? : Bool = false,
) -> Tester {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=400.0)
  t.check_looks(false)
  t.set_reduce_motion(reduced)
  set_view_app(fn(root) {
    root.lines_up(Is(Some(Start))) |> ignore
    if obstacle {
      root.box(fn(o) {
        o.over(Is(true)).margin(Is((60.0, 180.0, 0.0, 0.0))) |> ignore
        o.box(fn(w) { w.words(Is("obstacle capsule words")) |> ignore }) |> ignore
      })
      |> ignore
    }
    root.show(fn() { sent.get() }, at_once=true, fn(slot) {
      slot.box(fn(b) {
        b
        .margin(Is((60.0, 60.0, 0.0, 0.0)))
        .padding(Is((10.0, 8.0, 10.0, 8.0)))
        .ground(Is(0x11223320L))
        .flies_in(
          pf_flight,
          fn(to) { Some((to.0, to.1 + 240.0, to.2, to.3)) },
          bare_from=true,
          particle=true,
        )
        |> ignore
        b.box(fn(w) { w.words(Is("hello particle flight words")) |> ignore }) |> ignore
      })
      |> ignore
    })
  })
  t
}

///|
test "particle flight: exact endpoints at p=0 and p=1, fine-grained splitting mid-flight with valid sub-atlas" {
  let sent = @signals.signal(false)
  let t = pf_scene(sent)
  t.draw()
  // Trigger flight in a change
  let start_t = t.time()
  sent.set(true)
  t.draw()
  // At p == 0 (start frame): zero splitting, glyphs sit at origin (y ~ 300)
  let start_glyphs = t.drawn_instances_keyed().filter(fn(a) { a[5] == 1.0 || a[5] == 3.0 })
  let base_count = start_glyphs.length()
  assert_true(base_count >= 20, msg="expected base glyphs, got \{base_count}")
  assert_true(start_glyphs.iter().all(fn(a) { a[1] > 280.0 }), msg="at p=0 glyphs must start at origin y~300")
  // Mid-flight at p = 0.35, 0.50, 0.70: glyphs split into finer particles with sub_uw >= 1.5 and sub_vh >= 1.5
  for target_ms in [140.0, 200.0, 280.0] {
    t.run_for(target_ms - (t.time() - start_t))
    let all = t.drawn_instances_keyed()
    let mid_glyphs = all.filter(fn(a) { a[5] == 1.0 || a[5] == 3.0 })
    assert_true(
      mid_glyphs.length() > base_count,
      msg="at \{target_ms} ms expected particle splitting (> \{base_count}), got \{mid_glyphs.length()}",
    )
    for g in mid_glyphs {
      assert_true(g[14] >= 1.5 || g[14] == 0.0, msg="sub_uw < 1.5: \{g[14]}")
      assert_true(g[15] >= 1.5 || g[15] == 0.0, msg="sub_vh < 1.5: \{g[15]}")
    }
  }
  // At p == 1 (landed): zero splitting, exact resting count and destination y ~ 68
  t.run_for(400.0 - (t.time() - start_t))
  let end_glyphs = t.drawn_instances_keyed().filter(fn(a) { a[5] == 1.0 || a[5] == 3.0 })
  assert_eq(end_glyphs.length(), base_count, msg="landed glyph count must match resting count")
  assert_true(end_glyphs.iter().all(fn(a) { a[1] < 100.0 }), msg="at p=1 glyphs must land at destination y~68")
}

///|
fn pf_with_unclipped(f : () -> Unit) -> Unit {
  let stack = clip_stack.copy()
  let window = clip_window.copy()
  let apart = clip_apart.copy()
  clip_stack.clear()
  clip_window.clear()
  clip_apart.clear()
  push_unclipped()
  clip_window.push(true)
  clip_apart.push(false)
  f()
  clip_stack.clear()
  clip_stack.append(stack)
  clip_window.clear()
  clip_window.append(window)
  clip_apart.clear()
  clip_apart.append(apart)
}

///|
test "particle flight: colour glyph atlas 16384 offset is preserved when splitting" {
  let c = Ctx::new()
  pf_with_unclipped(fn() {
    let ck = clip_top()
    let outer_clip = FixedArray::makei(24, fn(j) { clip_stack[ck + j] })
    // Push one synthetic colour glyph (kind = 3.0, u0 = 16384 + 32, v0 = 16, uw = 18, vh = 18) at origin (100, 300)
    c.push_inst(100.0, 300.0, 18.0, 18.0, 0.0, 3.0, 0.0, 0.0, 0xFFFFFFFFL, 1.0, 16384.0 + 32.0, 16.0, 18.0, 18.0)
    let pf : @view.LiftParticle = {
      from_x: 100.0,
      from_y: 300.0,
      from_w: 18.0,
      from_h: 18.0,
      to_x: 100.0,
      to_y: 100.0,
      to_w: 18.0,
      to_h: 18.0,
      to_r: 0.0,
      t_lin: 0.5,
      p: 0.5,
      bare: true,
      old: false,
      shared_box: false,
      has_old: false,
      seed: 42,
    }
    let at : ParticleAt = { id: { at: 1, gen: 0 }, pf, k0: 0, outer_clip, base_x: 100.0, base_y: 200.0, base_s: 1.0, fast_fade: [] }
    c.particle_apply(at, 0, c.ninst)
  })
  assert_true(c.ninst > 1, msg="colour glyph should split into particles, got \{c.ninst}")
  for k in 0..<c.ninst {
    let b = k * inst_size
    assert_eq(c.inst[b + 5], 3.0)
    assert_true(c.inst[b + 12] >= 16384.0 + 32.0, msg="colour offset lost: \{c.inst[b + 12]}")
    assert_true(c.inst[b + 14] >= 1.5, msg="colour sub_uw < 1.5: \{c.inst[b + 14]}")
    assert_true(c.inst[b + 15] >= 1.5, msg="colour sub_vh < 1.5: \{c.inst[b + 15]}")
  }
}

///|
test "particle flight: identical instances across 7, 24, 60, and 120 fps at the same timestamp" {
  let snap_at = fn(period : Double) -> Array[Array[Double]] {
    let sent = @signals.signal(false)
    let t = pf_scene(sent)
    t.set_frame_period(period)
    t.draw()
    let t0 = t.time()
    sent.set(true)
    t.draw()
    let mut cur = t0 + period
    while cur < t0 + 200.0 - 0.001 {
      t.frame_at(cur)
      cur = cur + period
    }
    t.frame_at(t0 + 200.0)
    t.drawn_instances_keyed().filter(fn(a) { a[5] == 1.0 || a[5] == 3.0 })
  }
  let base = snap_at(1000.0 / 60.0)
  assert_true(base.length() > 30, msg="expected split particles at 200ms")
  for fps in [7.0, 24.0, 120.0] {
    let other = snap_at(1000.0 / fps)
    assert_eq(other.length(), base.length(), msg="fps \{fps} particle count mismatch")
    for i in 0..<base.length() {
      for j in [0, 1, 2, 3, 11, 12, 13, 14, 15, 32] {
        assert_true(
          (other[i][j] - base[i][j]).abs() < 1.0e-6,
          msg="fps \{fps} inst \{i} slot \{j}: \{other[i][j]} != \{base[i][j]}",
        )
      }
    }
  }
}

///|
test "particle flight: reduced_motion lands immediately without particle splitting" {
  let sent = @signals.signal(false)
  let t = pf_scene(sent, reduced=true)
  t.draw()
  sent.set(true)
  t.draw()
  let glyphs = t.drawn_instances_keyed().filter(fn(a) { a[5] == 1.0 || a[5] == 3.0 })
  assert_true(glyphs.length() >= 20 && glyphs.iter().all(fn(a) { a[1] < 100.0 }), msg="reduced motion should land immediately")
}

///|
let pf_step_ms : Double = 20.0

///|
test "particle flight: sweeping over another text node produces zero words_over faults" {
  let sent = @signals.signal(false)
  let t = pf_scene(sent, obstacle=true)
  t.draw()
  sent.set(true)
  t.draw()
  let start = t.time()
  while t.time() - start < 400.0 {
    assert_eq(g().words_over_faults().length(), 0, msg="words_over fault at \{t.time() - start} ms")
    t.run_for(pf_step_ms)
  }
}

///|
test "particle flight: zero jitter on untouched glyphs before the dissolve wavefront arrives" {
  let sent = @signals.signal(false)
  let t = pf_scene(sent)
  t.draw()
  let start = t.time()
  sent.set(true)
  t.draw()
  let base_glyphs = t.drawn_instances_keyed().filter(fn(a) { a[5] == 1.0 || a[5] == 3.0 })
  assert_true(base_glyphs.length() >= 10, msg="expected base glyphs")
  // Find the leftmost glyph (smallest x): right-to-left wave reaches it last (delay > 0.18 -> > 72ms).
  let mut left = base_glyphs[0]
  for g in base_glyphs {
    if g[0] < left[0] {
      left = g
    }
  }
  for sample_ms in [20.0, 40.0, 60.0] {
    t.run_for(sample_ms - (t.time() - start))
    let cur = t.drawn_instances_keyed().filter(fn(a) { a[5] == 1.0 || a[5] == 3.0 })
    let mut found = false
    for g in cur {
      if (g[0] - left[0]).abs() < 0.001 &&
        (g[1] - left[1]).abs() < 0.001 &&
        (g[2] - left[2]).abs() < 0.001 &&
        (g[3] - left[3]).abs() < 0.001 &&
        (g[12] - left[12]).abs() < 0.001 &&
        (g[13] - left[13]).abs() < 0.001 {
        found = true
        break
      }
    }
    assert_true(found, msg="at \{sample_ms} ms leftmost glyph jittered or rephased from (\{left[0]}, \{left[1]})")
  }
}

///|
test "particle flight: kind 4 image splits into valid sub-UV tiles across thumbnail-to-full morph" {
  let c = Ctx::new()
  pf_with_unclipped(fn() {
    let ck = clip_top()
    let outer_clip = FixedArray::makei(24, fn(j) { clip_stack[ck + j] })
    // Synthetic 200x140 resting image at origin (40, 500) flying to (120, 120) from a 56x56 thumbnail.
    c.push_inst(40.0, 500.0, 200.0, 140.0, 14.0, 4.0, 0.0, 0.0, 0xFFFFFFFFL, 1.0, 0.0, 0.0, 1.0, 1.0)
    let pf : @view.LiftParticle = {
      from_x: 40.0,
      from_y: 500.0,
      from_w: 56.0,
      from_h: 56.0,
      to_x: 120.0,
      to_y: 120.0,
      to_w: 200.0,
      to_h: 140.0,
      to_r: 14.0,
      t_lin: 0.45,
      p: 0.45,
      bare: false,
      old: false,
      shared_box: false,
      has_old: false,
      seed: 77,
    }
    let at : ParticleAt = { id: { at: 2, gen: 0 }, pf, k0: 0, outer_clip, base_x: 40.0, base_y: 500.0, base_s: 1.0, fast_fade: [] }
    c.particle_apply(at, 0, c.ninst)
  })
  assert_true(c.ninst >= 16 && c.ninst <= 1600, msg="expected 16..1600 image tiles, got \{c.ninst}")
  for k in 0..<c.ninst {
    let b = k * inst_size
    assert_eq(c.inst[b + 5], 4.0)
    let u0 = c.inst[b + 12]
    let v0 = c.inst[b + 13]
    let uw = c.inst[b + 14]
    let vh = c.inst[b + 15]
    assert_true(u0 >= -1.0e-6 && u0 + uw <= 1.0 + 1.0e-6, msg="invalid image sub-u: \{u0} + \{uw}")
    assert_true(v0 >= -1.0e-6 && v0 + vh <= 1.0 + 1.0e-6, msg="invalid image sub-v: \{v0} + \{vh}")
    assert_true(uw > 0.0 && vh > 0.0, msg="zero image sub-uv")
    assert_eq(c.inst[b + 22], 0.0)
  }
}

///|
test "particle flight: View::shared container=true particle=true hands off continuously across t in [0.32, 0.58]" {
  let sent = @signals.signal(false)
  let t = Tester::new(fn(_c) {  }, w=400.0, h=400.0)
  t.check_looks(false)
  set_view_app(fn(root) {
    root.lines_up(Is(Some(Start))) |> ignore
    root.show(fn() { !sent.get() }, at_once=true, fn(slot) {
      slot.box(fn(b) {
        b
        .margin(Is((40.0, 280.0, 0.0, 0.0)))
        .padding(Is((10.0, 8.0, 10.0, 8.0)))
        .ground(Is(0xEAEAEAFFL))
        .shared(Is("quote-card-1"), pf_flight, container=true, particle=true)
        |> ignore
        b.box(fn(w) { w.words(Is("quoted source card")) |> ignore }) |> ignore
      })
      |> ignore
    })
    root.show(fn() { sent.get() }, at_once=true, fn(slot) {
      slot.box(fn(b) {
        b
        .margin(Is((120.0, 60.0, 0.0, 0.0)))
        .padding(Is((10.0, 8.0, 10.0, 8.0)))
        .ground(Is(0xE0E0E0FFL))
        .shared(Is("quote-card-1"), pf_flight, container=true, particle=true)
        |> ignore
        b.box(fn(w) { w.words(Is("quoted landed card")) |> ignore }) |> ignore
      })
      |> ignore
    })
  })
  t.draw()
  let start = t.time()
  sent.set(true)
  t.draw()
  while t.time() - start < 400.0 {
    let insts = t.drawn_instances_keyed()
    let visible = insts.filter(fn(a) { a[11] > 0.01 })
    assert_true(visible.length() > 0, msg="blank frame during shared container handoff at \{t.time() - start} ms")
    assert_eq(g().words_over_faults().length(), 0, msg="words_over during shared handoff at \{t.time() - start} ms")
    t.run_for(pf_step_ms)
  }
}

///|
let pf_frame_ms : Double = 16.0

///|
test "particle flight: clipped View::shared container quote card keeps full destination clip in tail [0.80, 0.99]" {
  let sent = @signals.signal(false)
  let t = Tester::new(fn(_c) {  }, w=400.0, h=400.0)
  t.check_looks(false)
  set_view_app(fn(root) {
    root.lines_up(Is(Some(Start))) |> ignore
    root.show(fn() { !sent.get() }, at_once=true, fn(slot) {
      slot.box(fn(b) {
        b
        .margin(Is((40.0, 280.0, 0.0, 0.0)))
        .padding(Is((10.0, 8.0, 10.0, 8.0)))
        .ground(Is(0xEAEAEAFFL))
        .clips(Is(true))
        .shared(Is("quote-clip-1"), pf_flight, container=true, particle=true)
        |> ignore
        b.box(fn(w) { w.words(Is("clipped quote source")) |> ignore }) |> ignore
      })
      |> ignore
    })
    root.show(fn() { sent.get() }, at_once=true, fn(slot) {
      slot.box(fn(b) {
        b
        .margin(Is((120.0, 60.0, 0.0, 0.0)))
        .padding(Is((10.0, 8.0, 10.0, 8.0)))
        .ground(Is(0xE0E0E0FFL))
        .clips(Is(true))
        .shared(Is("quote-clip-1"), pf_flight, container=true, particle=true)
        |> ignore
        b.box(fn(w) { w.words(Is("clipped quote landed")) |> ignore }) |> ignore
      })
      |> ignore
    })
  })
  t.draw()
  let start = t.time()
  sent.set(true)
  t.draw()
  let mut tail_checked = 0
  while t.time() - start < 400.0 {
    let elapsed = t.time() - start
    if elapsed >= 320.0 && elapsed <= 396.0 {
      tail_checked = tail_checked + 1
      let landed = t
        .drawn_instances_keyed()
        .filter(fn(a) {
          (a[5] == 1.0 || a[5] == 3.0 || a[5] == 10.0 || a[5] == 11.0) &&
          a[1] < 100.0 &&
          a[35] == 0.0
        })
      assert_true(landed.length() > 0, msg="no landed glyphs in tail at \{elapsed} ms")
      for a in landed {
        assert_true(a[11] > 0.95, msg="tail alpha dropped to \{a[11]} at \{elapsed} ms")
        assert_true(
          a[16] <= a[0] + 0.5 &&
            a[17] <= a[1] + 0.5 &&
            a[18] >= a[0] + a[2] - 0.5 &&
            a[19] >= a[1] + a[3] - 0.5,
          msg="tail clip [\{a[16]}, \{a[17]}, \{a[18]}, \{a[19]}] cut glyph [\{a[0]}, \{a[1]}, \{a[0] + a[2]}, \{a[1] + a[3]}] at \{elapsed} ms",
        )
      }
    }
    t.run_for(pf_frame_ms)
  }
  assert_true(tail_checked >= 4, msg="expected >= 4 tail frames checked")
}

///|
test "particle flight: kind 4 image holds rounded thumbnail at takeoff, fine sand mid-flight, and 14pt rounded landing" {
  let run_at = fn(t_lin : Double) -> Array[Array[Double]] {
    let c = Ctx::new()
    pf_with_unclipped(fn() {
      let ck = clip_top()
      let outer_clip = FixedArray::makei(24, fn(j) { clip_stack[ck + j] })
      c.push_inst(40.0, 500.0, 200.0, 140.0, 14.0, 4.0, 0.0, 0.0, 0xFFFFFFFFL, 1.0, 0.0, 0.0, 1.0, 1.0)
      let pf : @view.LiftParticle = {
        from_x: 40.0,
        from_y: 500.0,
        from_w: 56.0,
        from_h: 56.0,
        to_x: 120.0,
        to_y: 120.0,
        to_w: 200.0,
        to_h: 140.0,
        to_r: 14.0,
        t_lin,
        p: t_lin,
        bare: false,
        old: false,
        shared_box: false,
        has_old: false,
        seed: 77,
      }
      let at : ParticleAt = { id: { at: 2, gen: 0 }, pf, k0: 0, outer_clip, base_x: 40.0, base_y: 500.0, base_s: 1.0, fast_fade: [] }
      c.particle_apply(at, 0, c.ninst)
    })
    let out : Array[Array[Double]] = []
    for k in 0..<c.ninst {
      let b = k * inst_size
      out.push(Array::makei(inst_size, fn(j) { c.inst[b + j] }))
    }
    out
  }
  // t = 0.05: rounded origin thumbnail (>= 10pt) present, no unlaunched grid fragments at rest
  let start_insts = run_at(0.05)
  let thumbs = start_insts.filter(fn(a) { a[5] == 4.0 && (a[2] - 56.0).abs() < 0.5 && (a[3] - 56.0).abs() < 0.5 })
  assert_eq(thumbs.length(), 1, msg="expected 1 rounded origin thumbnail at t=0.05")
  assert_true(thumbs[0][4] >= 10.0 && thumbs[0][36] >= 10.0 && thumbs[0][38] >= 10.0, msg="thumbnail corner < 10pt: \{thumbs[0][4]}")
  // t = 0.50: mid-flight fine sand (every particle <= 4.0pt)
  let mid_insts = run_at(0.50)
  assert_true(mid_insts.length() >= 32, msg="expected fine image sand at t=0.50")
  for a in mid_insts {
    assert_true(a[2] <= 4.0 && a[3] <= 4.0, msg="mid-flight image particle too large: \{a[2]}x\{a[3]}")
  }
  // t = 0.96: settled destination image has all 4 corners == 14.0
  let end_insts = run_at(0.96)
  let settled = end_insts.filter(fn(a) { a[5] == 4.0 && (a[2] - 200.0).abs() < 0.5 && (a[3] - 140.0).abs() < 0.5 })
  assert_eq(settled.length(), 1, msg="expected 1 settled destination image at t=0.96")
  for slot in [4, 36, 37, 38, 39] {
    assert_true((settled[0][slot] - 14.0).abs() < 0.001, msg="settled corner slot \{slot} != 14.0: \{settled[0][slot]}")
  }
}

///|
test "particle flight: file card container=true keeps 236pt takeoff width, emits visible dust, and translates clip on landing" {
  let run_at = fn(t_lin : Double) -> Array[Array[Double]] {
    let c = Ctx::new()
    pf_with_unclipped(fn() {
      let ck = clip_top()
      let outer_clip = FixedArray::makei(24, fn(j) { clip_stack[ck + j] })
      // Card background (118x44 resting, orig_alpha = 0.075) + clipped glyph & icon inside [40..158, 500..544]
      c.push_inst(40.0, 500.0, 118.0, 44.0, 12.0, 0.0, 0.0, 0.0, 0x888888FFL, 0.075, 0.0, 0.0, 0.0, 0.0)
      push_box_clip(40.0, 500.0, 118.0, 44.0, 12.0, 12.0, 12.0, 12.0)
      c.push_inst(56.0, 514.0, 12.0, 14.0, 0.0, 1.0, 0.0, 0.0, 0x222222FFL, 1.0, 10.0, 10.0, 12.0, 14.0)
      c.push_inst(48.0, 514.0, 14.0, 14.0, 0.0, 10.0, 0.0, 0.0, 0x444444FFL, 1.0, 0.0, 0.0, 14.0, 14.0)
      pop_clip()
      let pf : @view.LiftParticle = {
        from_x: 40.0,
        from_y: 500.0,
        from_w: 236.0,
        from_h: 44.0,
        to_x: 200.0,
        to_y: 120.0,
        to_w: 118.0,
        to_h: 44.0,
        to_r: 12.0,
        t_lin,
        p: t_lin,
        bare: false,
        old: false,
        shared_box: true,
        has_old: false,
        seed: 99,
      }
      let at : ParticleAt = { id: { at: 3, gen: 0 }, pf, k0: 0, outer_clip, base_x: 40.0, base_y: 500.0, base_s: 1.0, fast_fade: [] }
      c.particle_apply(at, 0, c.ninst)
    })
    let out : Array[Array[Double]] = []
    for k in 0..<c.ninst {
      let b = k * inst_size
      out.push(Array::makei(inst_size, fn(j) { c.inst[b + j] }))
    }
    out
  }
  // t = 0.05: origin card ground keeps full 236pt width
  let start_insts = run_at(0.05)
  let origin_bg = start_insts.filter(fn(a) { a[5] == 0.0 && a[2] > 200.0 })
  assert_eq(origin_bg.length(), 1, msg="expected 1 full-width origin card at t=0.05")
  assert_true((origin_bg[0][2] - 236.0).abs() < 0.001, msg="origin card width jumped: \{origin_bg[0][2]}")
  // t = 0.45: card dust particles visible (alpha >= 0.20)
  let mid_insts = run_at(0.45)
  let dust = mid_insts.filter(fn(a) { a[5] == 0.0 && a[2] <= 4.0 && a[3] <= 4.0 && a[11] >= 0.20 })
  assert_true(dust.length() >= 20, msg="expected >= 20 visible card dust particles (alpha >= 0.20), got \{dust.length()}")
  // t = 0.96: landed glyph & icon clips enclose their destination rects
  let end_insts = run_at(0.96)
  let landed = end_insts.filter(fn(a) { (a[5] == 1.0 || a[5] == 10.0) && a[1] < 200.0 })
  assert_true(landed.length() >= 2, msg="expected landed glyph and icon at t=0.96")
  for a in landed {
    assert_true(
      a[16] <= a[0] + 0.5 &&
        a[17] <= a[1] + 0.5 &&
        a[18] >= a[0] + a[2] - 0.5 &&
        a[19] >= a[1] + a[3] - 0.5,
      msg="landed clip [\{a[16]}, \{a[17]}, \{a[18]}, \{a[19]}] cut item [\{a[0]}, \{a[1]}, \{a[0] + a[2]}, \{a[1] + a[3]}]",
    )
  }
}

///|
test "particle flight: sizes_steady and sizes_across skip particle-flight nodes while still catching non-particle size snaps" {
  // 1) particle=true flight changing box size 236x56 -> 137.5x52 must report zero sizes_steady / sizes_across faults at 60 & 120 fps.
  for fps in [60.0, 120.0] {
    let sent = @signals.signal(false)
    let t = Tester::new(fn(_c) {  }, w=400.0, h=400.0, words_over_held=false)
    t.check_looks(false)
    t.set_frame_period(1000.0 / fps)
    set_view_app(fn(root) {
      root.lines_up(Is(Some(Start))) |> ignore
      root.show(fn() { sent.get() }, at_once=true, fn(slot) {
        slot.box(fn(b) {
          b
          .margin(Is((60.0, 60.0, 0.0, 0.0)))
          .width(Is(Some(137.5)))
          .height(Is(Some(52.0)))
          .ground(Is(0x336699FFL))
          .flies_in(
            pf_flight,
            fn(to) { Some((to.0, to.1 + 240.0, 236.0, 56.0)) },
            particle=true,
          )
          |> ignore
          b.box(fn(w) { w.words(Is("notes")) |> ignore }) |> ignore
        })
        |> ignore
      })
    })
    t.draw()
    sent.set(true)
    let steps = if fps > 90.0 { 56 } else { 28 }
    let (down, across) = across_frames(t, steps)
    assert_eq(down, [], msg="particle flight @\{fps}fps reported false sizes_steady: \{Repr(down)}")
    assert_eq(across, [], msg="particle flight @\{fps}fps reported false sizes_across: \{Repr(across)}")
  }
  // 2) A non-particle box snapping 236x56 -> 137.5x52 in one frame must still be caught by both sizes_steady and sizes_across.
  let bw = @signals.signal(236.0)
  let bh = @signals.signal(56.0)
  let t2 = Tester::new(fn(_c) {  }, w=400.0, h=400.0, words_over_held=false)
  t2.check_looks(false)
  t2.set_frame_period(1000.0 / 60.0)
  set_view_app(fn(root) {
    root.lines_up(Is(Some(Start))) |> ignore
    root.box(fn(b) {
      b
      .margin(Is((60.0, 60.0, 0.0, 0.0)))
      .width(By(fn() { Some(bw.get()) }))
      .height(By(fn() { Some(bh.get()) }))
      .ground(Is(0x336699FFL))
      |> ignore
    })
    |> ignore
  })
  t2.draw()
  let _ = across_frames(t2, 3)
  bw.set(137.5)
  bh.set(52.0)
  let (down2, across2) = across_frames(t2, 4)
  assert_true(down2.length() > 0, msg="non-particle height snap was not caught by sizes_steady")
  assert_true(across2.length() > 0, msg="non-particle width snap was not caught by sizes_across")
}

///|
test "particle flight: shared_box old->new handoff keeps identical card dust, icon continuity, immediate short-quote launch, bounded long-quote destination, and flies_fade" {
  // 1) Direct particle_apply check with mismatched layouts & radii:
  //    old (358x66 composer quote, radius 14, single wide line rx=310, gw=12) vs
  //    new (180x50 message quote, radius 18, wrapped 2-line layout), both sharing to_r=18.
  let run_mismatched = fn(old : Bool, t_lin : Double, long_quote : Bool) -> Array[Array[Double]] {
    let c = Ctx::new()
    pf_with_unclipped(fn() {
      let ck = clip_top()
      let outer_clip = FixedArray::makei(24, fn(j) { clip_stack[ck + j] })
      let fast_fade : Array[(Int, Int)] = []
      let to_w = if long_quote { 180.0 } else { 86.0 }
      let to_h = if long_quote { 50.0 } else { 34.0 }
      let card_w = if old { 358.0 } else { to_w }
      let card_h = if old { 66.0 } else { to_h }
      let card_r = if old { 14.0 } else { 18.0 }
      c.push_inst(16.0, 650.0, card_w, card_h, card_r, 0.0, 0.0, 0.0, 0x1D1D1FFFL, 0.04, 0.0, 0.0, 0.0, 0.0)
      if old {
        // Extra composer wrapper instance before icon to ensure shape_idx ignores raw instance index i
        c.push_inst(16.0, 650.0, card_w, card_h, card_r, 0.0, 0.0, 0.0, 0x00000000L, 0.0, 0.0, 0.0, 0.0, 0.0)
      }
      // Quote-open icon at top-left (same rx/ry on both sides even when text wrapping differs!)
      c.push_inst(28.0, 660.0, 12.0, 12.0, 0.0, 10.0, 0.0, 0.0, 0xE05A2BFFL, 1.0, 0.0, 0.0, 12.0, 12.0)
      if long_quote {
        if old {
          // Wide single line reaching rx=310, gw=12 (right edge 322 > to_w - 8 = 172 -> triggers old_dest_sx < 1)
          c.push_inst(326.0, 660.0, 12.0, 12.0, 0.0, 1.0, 0.0, 0.0, 0x1D1D1FFFL, 1.0, 8.0, 8.0, 12.0, 12.0)
        } else {
          // Wrapped 2-line layout in narrower destination card (different content bbox!)
          c.push_inst(140.0, 660.0, 12.0, 12.0, 0.0, 1.0, 0.0, 0.0, 0x1D1D1FFFL, 1.0, 8.0, 8.0, 12.0, 12.0)
          c.push_inst(70.0, 682.0, 12.0, 12.0, 0.0, 1.0, 0.0, 0.0, 0x1D1D1FFFL, 1.0, 8.0, 8.0, 12.0, 12.0)
        }
      } else {
        // Short quote text glyph at right end of short quote (rx = 60, well inside 358pt wide composer card)
        c.push_inst(76.0, 660.0, 10.0, 12.0, 0.0, 1.0, 0.0, 0.0, 0x1D1D1FFFL, 1.0, 8.0, 8.0, 10.0, 12.0)
      }
      if old {
        // Empty field placeholder glyph marked fast_fade
        let p0 = c.ninst
        c.push_inst(28.0, 684.0, 10.0, 12.0, 0.0, 1.0, 0.0, 0.0, 0x8E8E93FFL, 1.0, 20.0, 8.0, 10.0, 12.0)
        fast_fade.push((p0, c.ninst))
      }
      let pf : @view.LiftParticle = {
        from_x: 16.0,
        from_y: 650.0,
        from_w: 358.0,
        from_h: 66.0,
        to_x: 374.0 - to_w,
        to_y: 550.0,
        to_w,
        to_h,
        to_r: 18.0,
        t_lin,
        p: t_lin,
        bare: false,
        old,
        shared_box: true,
        has_old: true,
        seed: 12345,
      }
      let at : ParticleAt = { id: { at: 9, gen: 0 }, pf, k0: 0, outer_clip, base_x: 16.0, base_y: 650.0, base_s: 1.0, fast_fade }
      c.particle_apply(at, 0, c.ninst)
    })
    let out : Array[Array[Double]] = []
    for k in 0..<c.ninst {
      let b = k * inst_size
      out.push(Array::makei(inst_size, fn(j) { c.inst[b + j] }))
    }
    out
  }
  // Both short and long (mismatched layout + mismatched radius 14 vs 18 + old_dest_sx < 1) must match bit-for-bit at t=0.44!
  for long_quote in [false, true] {
    let old_mid = run_mismatched(true, 0.44, long_quote)
    let new_mid = run_mismatched(false, 0.44, long_quote)
    let old_dust = old_mid.filter(fn(a) { a[5] == 0.0 && a[2] <= 4.0 && a[3] <= 4.0 })
    let new_dust = new_mid.filter(fn(a) { a[5] == 0.0 && a[2] <= 4.0 && a[3] <= 4.0 })
    assert_eq(old_dust.length(), new_dust.length(), msg="card dust count jumped (long=\{long_quote})")
    assert_true(old_dust.length() >= 40, msg="expected >= 40 card dust particles, got \{old_dust.length()}")
    for i in 0..<old_dust.length() {
      assert_true(
        (old_dust[i][0] - new_dust[i][0]).abs() < 0.01 && (old_dust[i][1] - new_dust[i][1]).abs() < 0.01,
        msg="card dust[\{i}] jumped (long=\{long_quote}): (\{old_dust[i][0]}, \{old_dust[i][1]}) vs (\{new_dust[i][0]}, \{new_dust[i][1]})",
      )
    }
    let old_icon = old_mid.filter(fn(a) { a[5] == 10.0 })
    let new_icon = new_mid.filter(fn(a) { a[5] == 10.0 })
    assert_eq(old_icon.length(), 1)
    assert_eq(new_icon.length(), 1)
    assert_true(
      (old_icon[0][0] - new_icon[0][0]).abs() < 0.01 && (old_icon[0][1] - new_icon[0][1]).abs() < 0.01,
      msg="quote icon jumped (long=\{long_quote}): (\{old_icon[0][0]}, \{old_icon[0][1]}) vs (\{new_icon[0][0]}, \{new_icon[0][1]})",
    )
  }
  // Long quote at t=0.90: old glyphs' right edge must stay within destination card (to_x + to_w - 8.0 + spread margin)
  let old_long_end = run_mismatched(true, 0.99, true).filter(fn(a) { a[5] == 1.0 && a[12] < 20.0 })
  for g in old_long_end {
    assert_true(g[0] + g[2] <= 374.0 - 8.0 + 0.5, msg="long quote old glyph poked past right margin: \{g[0] + g[2]}")
  }
  // Empty field placeholder (fast_fade) must fade alpha while preserving glyph atlas UV height vh at t_lin = 0.05,
  // and be completely gone by t_lin = 0.12 (never flying as sand).
  let old_t05 = run_mismatched(true, 0.05, false)
  let fade_ph = old_t05.filter(fn(a) { a[5] == 1.0 && a[12] >= 20.0 })
  assert_eq(fade_ph.length(), 1, msg="expected 1 fast-fading placeholder glyph at t=0.05")
  assert_true((fade_ph[0][15] - 12.0).abs() < 0.001, msg="fast-fading placeholder corrupted glyph UV vh: \{fade_ph[0][15]}")
  assert_true(fade_ph[0][11] > 0.1 && fade_ph[0][11] < 0.9, msg="fast-fading placeholder alpha did not fade: \{fade_ph[0][11]}")
  let old_t12 = run_mismatched(true, 0.12, false)
  let stray_ph = old_t12.filter(fn(a) { a[5] == 1.0 && a[12] >= 20.0 })
  assert_eq(stray_ph.length(), 0, msg="empty-field placeholder lingered as flying particles at t=0.12: \{stray_ph.length()}")
  // Short quote right-end glyph must already be moving by t_lin = 0.06 (no ~120ms dead stall)
  let old_t06 = run_mismatched(true, 0.06, false)
  let right_glyphs = old_t06.filter(fn(a) { a[5] == 1.0 && a[12] < 20.0 })
  assert_true(right_glyphs.length() > 1, msg="short quote did not begin dissolving by t=0.06 (got \{right_glyphs.length()} insts)")
  // 2) End-to-end View::shared(container=true, particle=true) with an empty TreeField AND an oversized 32x32
  //    View::flies_fade() corner badge verifies both fast-fade cleanly without geometric size assumptions.
  let sent = @signals.signal(false)
  let comment_f = Field::new()
  let t = Tester::new(fn(_c) {  }, w=390.0, h=844.0)
  t.check_looks(false)
  set_view_app(fn(root) {
    root.lines_up(Is(Some(Start))) |> ignore
    root.show(fn() { !sent.get() }, at_once=true, fn(slot) {
      slot.box(fn(b) {
        b
        .margin(Is((16.0, 640.0, 0.0, 0.0)))
        .width(Is(Some(358.0)))
        .padding(Is((10.0, 8.0, 10.0, 8.0)))
        .ground(Is(0xEAEAEAFFL))
        .shared(Is("quote-empty-field"), pf_flight, container=true, particle=true)
        |> ignore
        b.box(fn(w) { w.words(Is("Claude: 了")) |> ignore }) |> ignore
        field(b, comment_f, placeholder="添加说明（可选）", placeholder_color=0x0088CCFFL, max_lines=1) |> ignore
        // Oversized 32x32 flies_fade() corner badge (red 0xDD2222) that would fail any <=24px geometric heuristic
        b.box(fn(badge) {
          badge
          .over(Is(true))
          .width(Is(Some(32.0)))
          .height(Is(Some(32.0)))
          .ground(Is(0xDD2222FFL))
          .flies_fade()
          |> ignore
          badge.box(fn(lbl) { lbl.words(Is("X")).ink(Is(0xFFFFFFFFL)) |> ignore }) |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    root.show(fn() { sent.get() }, at_once=true, fn(slot) {
      slot.box(fn(b) {
        b
        .margin(Is((280.0, 520.0, 0.0, 0.0)))
        .width(Is(Some(94.0)))
        .padding(Is((10.0, 8.0, 10.0, 8.0)))
        .ground(Is(0xEAEAEAFFL))
        .shared(Is("quote-empty-field"), pf_flight, container=true, particle=true)
        |> ignore
        b.box(fn(w) { w.words(Is("Claude: 了")) |> ignore }) |> ignore
      })
      |> ignore
    })
  })
  t.draw()
  // Confirm placeholder glyphs (blue 0x0088CC) and red flies_fade badge (0xDD2222) are present before sending
  let before_ph = t.drawn_instances_keyed().filter(fn(a) { (a[5] == 1.0 || a[5] == 3.0) && a[11] > 0.01 && a[10] > 0.7 && a[8] < 0.1 })
  let before_badge = t.drawn_instances_keyed().filter(fn(a) { a[5] == 0.0 && a[11] > 0.5 && a[8] > 0.7 && a[9] < 0.2 })
  assert_true(before_ph.length() > 0, msg="expected empty comment placeholder before send")
  assert_true(before_badge.length() > 0, msg="expected flies_fade badge before send")
  sent.set(true)
  t.run_for(pf_dur_ms * 0.30)
  // By t = 120ms (t_lin = 0.30), BOTH empty comment placeholder and 32x32 flies_fade badge must be completely gone.
  let ph_glyphs = t.drawn_instances_keyed().filter(fn(a) { (a[5] == 1.0 || a[5] == 3.0) && a[11] > 0.01 && a[10] > 0.7 && a[8] < 0.1 })
  let badge_left = t.drawn_instances_keyed().filter(fn(a) { a[5] == 0.0 && a[11] > 0.01 && a[8] > 0.7 && a[9] < 0.2 })
  assert_eq(ph_glyphs.length(), 0, msg="empty comment placeholder glyphs stayed visible at 120ms: \{ph_glyphs.length()}")
  assert_eq(badge_left.length(), 0, msg="flies_fade badge lingered at 120ms: \{badge_left.length()}")
}
