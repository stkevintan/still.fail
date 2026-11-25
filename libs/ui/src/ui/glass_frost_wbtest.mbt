// Global liquid/frosted glass frost modulation and system increase-contrast linkage (glass.mbt, view_host.mbt).

///|
test "effective_glass: zero-overhead fast path at frost=0 and contrast=false" {
  let liq = Glass::liquid()
  assert_eq(effective_glass(liq, 0.0, false), liq)
  let fr = Glass::frosted(blur=10.0, tint=0xFFFFFF80L, solid=0xF5F5F7FFL, rim_edge=0.2)
  assert_eq(effective_glass(fr, 0.0, false), fr)
}

///|
test "effective_glass: frost=0.5 raises tint alpha, lifts low blur, and calms refraction" {
  let liq = Glass::liquid(blur=2.0, tint=0xFFFFFF1AL, solid=0x1C1C1EFFL, refraction=10.0, rim=0.55)
  let out = effective_glass(liq, 0.5, false)
  let orig_a = (liq.tint & 0xFFL).to_int()
  let out_a = (out.tint & 0xFFL).to_int()
  assert_true(out_a > orig_a + 80, msg="tint alpha should rise strongly: \{orig_a} -> \{out_a}")
  // RGB mixes 0.25 towards solid (0x1C < 0xFF)
  let out_r = ((out.tint >> 24) & 0xFFL).to_int()
  assert_true(out_r < 255 && out_r > 150, msg="tint red should mix toward solid: \{out_r}")
  // blur lifts from 2.0 towards 14.0 by 0.25 -> 5.0
  assert_true((out.blur - 5.0).abs() < 0.01, msg="blur=\{out.blur}")
  // refraction reduces by 1 - 0.55 * 0.5 = 0.725 -> 7.25
  assert_true((out.refraction - 7.25).abs() < 0.01, msg="refraction=\{out.refraction}")
  // rim unchanged without contrast
  assert_eq(out.rim, liq.rim)
}

///|
test "effective_glass: exempts clear optical magnifying lenses and progressive scroll edges" {
  let lens = Glass::liquid(blur=0.0, tint=0xFFFFFF00L, zoom=1.5, refraction=14.0)
  assert_eq(effective_glass(lens, 0.7, true), lens)
  let prog = Glass::frosted(blur=8.0, tint=0xFFFFFF40L, solid=0xFFFFFFFFL, progressive=true)
  assert_eq(effective_glass(prog, 0.7, true), prog)
}

///|
test "effective_glass: contrast=true boosts tint alpha and rim/rim_edge highlights" {
  let liq = Glass::liquid(blur=2.0, tint=0xFFFFFF1AL, solid=0xECECF0FFL, rim=0.5)
  let out_l = effective_glass(liq, 0.0, true)
  assert_true((out_l.tint & 0xFFL) > (liq.tint & 0xFFL))
  assert_true((out_l.rim - 0.745).abs() < 0.01, msg="liquid rim=\{out_l.rim}")
  let fr = Glass::frosted(blur=16.0, tint=0xFFFFFF60L, solid=0xECECF0FFL, rim_edge=0.2)
  let out_f = effective_glass(fr, 0.0, true)
  assert_true((out_f.tint & 0xFFL) > (fr.tint & 0xFFL))
  assert_eq(out_f.blur, 16.0)
  assert_true((out_f.rim_edge - 0.35).abs() < 0.01, msg="frosted rim_edge=\{out_f.rim_edge}")
}

///|
test "effective_glass: contrast=true zeroes chroma on dense liquid panel glass so applePanelGate is disabled" {
  let panel = Glass::liquid(
    blur=6.0,
    tint=0xFDFCFDBFL,
    solid=0xFFFFFFFFL,
    bezel=20.0,
    refraction=26.0,
    rim=0.6,
    chroma=0.03,
  )
  let out = effective_glass(panel, 0.0, true)
  assert_eq(out.chroma, 0.0)
  // Regular controls (chroma=0.06, droplet_role=0): contrast=true zeroes chroma, frost=0.5 alone preserves 0.06
  let ctrl = Glass::liquid(
    blur=2.0,
    tint=0xFDFCFD67L,
    solid=0xFFFFFFFFL,
    bezel=14.0,
    refraction=20.0,
    rim=0.6,
    chroma=0.06,
  )
  assert_eq(effective_glass(ctrl, 0.0, true).chroma, 0.0)
  assert_eq(effective_glass(ctrl, 0.5, false).chroma, 0.06)
}

///|
test "glass_frost: ViewBlock invalidates on frost and contrast changes, and frost=1.0 switches to solid" {
  let t = Tester::tree(w=400.0, h=300.0, fn(root) {
    root.box(fn(b) {
      b
      .width(Is(Some(120.0)))
      .height(Is(Some(60.0)))
      .glass(Is(Some(Glass::liquid(blur=2.0, tint=0xFFFFFF1AL, solid=0xECECF0FFL, refraction=10.0, rim=0.5))))
      |> ignore
    })
    |> ignore
  })
  t.draw()
  assert_eq(glass_frost(), 0.0)
  let find_glass = fn() -> (Double, Double, Double, Double)? {
    let c = the_ctx.val
    let n = c.ninst
    for i in 0..<n {
      let b = i * inst_size
      if c.inst[b + 5] == 6.0 {
        return Some((c.inst[b + 7], c.inst[b + 11], c.inst[b + 12], c.inst[b + 21]))
      }
    }
    None
  }
  guard find_glass() is Some((blur0, alpha0, rim0, refr0)) else { fail("expected liquid glass instance at frost=0") }
  assert_true((blur0 - 2.0).abs() < 0.01)
  assert_true((refr0 - 10.0).abs() < 0.01)

  // Raise frost to 0.5: cached ViewBlock must rebuild with higher blur/alpha and lower refraction.
  set_glass_frost(0.5)
  t.draw()
  assert_eq(glass_frost(), 0.5)
  guard find_glass() is Some((blur50, alpha50, rim50, refr50)) else { fail("expected liquid glass instance at frost=0.5") }
  assert_true(blur50 > blur0 + 1.0, msg="blur did not increase: \{blur0} -> \{blur50}")
  assert_true(alpha50 > alpha0 + 0.25, msg="alpha did not increase: \{alpha0} -> \{alpha50}")
  assert_true(refr50 < refr0 - 1.0, msg="refraction did not decrease: \{refr0} -> \{refr50}")
  assert_true((rim50 - rim0).abs() < 0.01)

  // Enable system Increase Contrast: cached ViewBlock must rebuild with stronger rim and alpha.
  t.set_increase_contrast(true)
  t.draw()
  guard find_glass() is Some((_, alpha_c, rim_c, _)) else { fail("expected liquid glass instance under contrast") }
  assert_true(alpha_c > alpha50, msg="contrast should raise alpha: \{alpha50} -> \{alpha_c}")
  assert_true(rim_c > rim50 + 0.1, msg="contrast should boost rim: \{rim50} -> \{rim_c}")

  // Frost at 1.0 switches glass_solid() to true: no kind 6 glass instance emitted.
  set_glass_frost(1.0)
  t.draw()
  assert_true(the_ctx.val.glass_solid(), msg="frost=1.0 should enable glass_solid")
  assert_true(find_glass() is None, msg="frost=1.0 should draw solid rect instead of glass instance")

  // Explicit set_glass_solid(Some(false)) still overrides frost=1.0.
  set_glass_solid(Some(false))
  t.draw()
  assert_false(the_ctx.val.glass_solid())
  assert_true(find_glass() is Some(_))
  set_glass_solid(None)
  set_glass_frost(0.0)
  t.set_increase_contrast(false)
}

///|
test "droplet_role: slot 7 packing survives at_strength while slot 21 scales linearly, public clear stays 0.0" {
  let roles : Array[(Int, Double, Double)] = [
    (1, -16.0, 3.0),
    (2, -32.0, 9.0),
    (3, -48.0, 9.0),
    (4, -64.0, 9.0),
  ]
  for entry in roles {
    let (role, exp_slot7, base_refr) = entry
    let base = Glass::liquid(blur=0.0, tint=0xFFFFFF00L, refraction=base_refr, droplet_role=role)
    for s in [0.5, 0.8, 1.0] {
      let scaled = base.at_strength(s)
      assert_eq(scaled.droplet_role, role)
      let t = Tester::tree(w=200.0, h=120.0, fn(root) {
        root.box(fn(b) {
          b.width(Is(Some(80.0))).height(Is(Some(40.0))).glass(Is(Some(scaled))) |> ignore
        }) |> ignore
      })
      t.draw()
      let c = the_ctx.val
      let mut found = false
      for i in 0..<c.ninst {
        let b = i * inst_size
        if c.inst[b + 5] == 6.0 {
          assert_true((c.inst[b + 7] - exp_slot7).abs() < 0.001, msg="role=\{role} s=\{s} slot7=\{c.inst[b + 7]}")
          assert_true((c.inst[b + 21] - base_refr * s).abs() < 0.01, msg="role=\{role} s=\{s} refr=\{c.inst[b + 21]}")
          found = true
          break
        }
      }
      assert_true(found, msg="expected kind 6 for role=\{role} s=\{s}")
    }
  }
  // Public Glass::liquid(blur=0, tint=0xFFFFFF00, refraction=9.0) must emit slot 7 == 0.0 (default path)
  let pub_gl = Glass::liquid(blur=0.0, tint=0xFFFFFF00L, refraction=9.0)
  let t_pub = Tester::tree(w=200.0, h=120.0, fn(root) {
    root.box(fn(b) {
      b.width(Is(Some(80.0))).height(Is(Some(40.0))).glass(Is(Some(pub_gl))) |> ignore
    }) |> ignore
  })
  t_pub.draw()
  let c = the_ctx.val
  let mut found_pub = false
  for i in 0..<c.ninst {
    let b = i * inst_size
    if c.inst[b + 5] == 6.0 {
      assert_true(c.inst[b + 7].abs() < 0.001, msg="public clear must keep slot7=0.0, got \{c.inst[b + 7]}")
      found_pub = true
      break
    }
  }
  assert_true(found_pub)
}

///|
test "droplet_role: frost=0 keeps clear switch lens (slot7=-32), frost>0 monotonically frosts, contrast frosts, glass_solid degrades to solid" {
  let sw_gl = Glass::liquid(blur=0.0, tint=0xFFFFFF00L, solid=0xFFFFFFFFL, refraction=9.0, rim=1.0, bezel=9.0, droplet_role=2)
  let t = Tester::tree(w=200.0, h=120.0, fn(root) {
    root.box(fn(b) {
      b.width(Is(Some(60.0))).height(Is(Some(38.0))).glass(Is(Some(sw_gl))) |> ignore
    }) |> ignore
  })
  let find_glass = fn() -> (Double, Double)? {
    let c = the_ctx.val
    for i in 0..<c.ninst {
      let b = i * inst_size
      if c.inst[b + 5] == 6.0 {
        return Some((c.inst[b + 7], c.inst[b + 11]))
      }
    }
    None
  }
  // Default clear (frost == 0.0 and 0.0001) keeps crystal droplet (slot7=-32, alpha=0)
  set_glass_frost(0.0)
  t.set_increase_contrast(false)
  t.draw()
  guard find_glass() is Some((slot7_0, alpha_0)) else { fail("expected switch glass at frost=0.0") }
  assert_true((slot7_0 - -32.0).abs() < 0.001, msg="frost=0.0 must keep slot7=-32.0, got \{slot7_0}")
  assert_true(alpha_0 < 0.001, msg="frost=0.0 must keep clear alpha=0, got \{alpha_0}")
  // C0 continuity across 0 -> eps -> 0.05 -> 0.10: slot7 stays -32.0 (blur==0) while alpha rises monotonically
  let low_frosts = [0.0001, 0.00011, 0.05, 0.10]
  let mut prev_low_a = alpha_0
  for f in low_frosts {
    set_glass_frost(f)
    t.draw()
    guard find_glass() is Some((s7, al)) else { fail("expected switch glass at frost=\{f}") }
    assert_true((s7 - -32.0).abs() < 0.001, msg="frost=\{f} must preserve slot7=-32.0 while a_frac<=0.12, got \{s7}")
    assert_true(al >= prev_low_a - 0.0001, msg="frost=\{f} alpha must be non-decreasing: \{al} < \{prev_low_a}")
    prev_low_a = al
  }
  assert_true(prev_low_a > 0.08 && prev_low_a < 0.12, msg="frost=0.10 alpha should be ~0.094, got \{prev_low_a}")
  // Positive frost (0.3 -> 0.5) monotonically increases blur (slot7 > 0) and tint alpha
  set_glass_frost(0.3)
  t.draw()
  guard find_glass() is Some((slot7_30, alpha_30)) else { fail("expected switch glass at frost=0.3") }
  assert_true(slot7_30 > 0.5 && alpha_30 > prev_low_a, msg="frost=0.3 should frost droplet: slot7=\{slot7_30}, alpha=\{alpha_30}")
  set_glass_frost(0.5)
  t.draw()
  guard find_glass() is Some((slot7_50, alpha_50)) else { fail("expected switch glass at frost=0.5") }
  assert_true(slot7_50 > slot7_30 && alpha_50 > alpha_30, msg="frost=0.5 must be more frosted than 0.3: (\{slot7_50},\{alpha_50}) vs (\{slot7_30},\{alpha_30})")
  // Returning to frost == 0.0 restores crystal droplet (slot7=-32, alpha=0)
  set_glass_frost(0.0)
  t.draw()
  guard find_glass() is Some((slot7_back, alpha_back)) else { fail("expected switch glass restored at frost=0.0") }
  assert_true((slot7_back - -32.0).abs() < 0.001, msg="restored frost=0.0 must keep slot7=-32.0, got \{slot7_back}")
  assert_true(alpha_back < 0.001, msg="restored frost=0.0 must keep clear alpha=0, got \{alpha_back}")
  // Increase Contrast disables crystal droplet mode -> positive blur & tint alpha
  t.set_increase_contrast(true)
  t.draw()
  guard find_glass() is Some((slot7_c, alpha_c)) else { fail("expected frosted glass under contrast=true") }
  assert_true(slot7_c > 0.5, msg="contrast=true should yield positive blur, got \{slot7_c}")
  assert_true(alpha_c > 0.15, msg="contrast=true should raise tint alpha, got \{alpha_c}")
  // Reduce Transparency (glass_solid=true) -> opaque solid, zero kind 6 glass instances
  set_glass_solid(Some(true))
  t.draw()
  assert_true(find_glass() is None, msg="glass_solid=true must emit zero glass instances")
  set_glass_solid(None)
  set_glass_frost(0.0)
  t.set_increase_contrast(false)
}
