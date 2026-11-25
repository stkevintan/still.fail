// White-box tests for Wave 4B v19 1:1 iOS 27.0 LiquidMorphPhysics (`bar_pill_group_node` +
// `anchored_popover_bridge` + `anchored_popover_shell`), verified across 60/120/24/7 fps:
// 1. Liquid glass `bar_pill_group_node` + `icon_button_node` trigger:
//    - Three-anchor optical invariant: `stage=0.0` == `glass_bar_pill()`, `stage=0.5` == `0x88/blur=5.0/bezel=18/refr=14`,
//      `stage=1.0` == `glass_menu()`.
//    - Rest (`>= 540ms`): 2 liquid instances (Archive + Menu), `merge == 0.0`, 0 `kind == 8` `content_lens`, `audit() == []`.
//    - Close recoil (`~183ms`): trigger pill kicks upward (`dy <= -10pt`) while Blob A + Blob B fuse in private group.
//    - Post-handoff splash (`~400ms`): Blob B vanishes (only 2 liquid instances remain — zero double glass) while
//      trigger pill exhibits `+1.6%` horizontal width splash (`> resting pill_w`) and rides recoil smoothly back.
//    - Post-close (`>= 620ms`): menu unmounts cleanly, trigger pill returns to resting `y` and `w` with `merge == 0.0`.
// 2. Non-pill plain button anchor (80×36): scales into button (`< 0.65` mid-exit) without stacking an extra glass droplet.
// 3. Context menu 1×1 point anchor (`at_point`): never emits a bridge and keeps `0.97..1.0` scale.
// 4. `MBUI_GLASS=solid` fallback: 0 `kind == 6` instances throughout entrance, rest, and exit, with clean audit.

///|
let bridge_test_settle_ms : Double = 640.0

///|
let bridge_test_recoil_ms : Double = 215.0

///|
let bridge_test_splash_step_ms : Double = 185.0

///|
let bridge_test_mid_slide_ms : Double = 80.0

///|
let bridge_test_slide_settle_ms : Double = 500.0

///|
let bridge_test_reopen_ms : Double = 120.0

///|
/// Returns `(index, merge)` for every `kind == 6` liquid glass instance emitted in the last frame.
fn bridge_liquid_instances(t : @ui.Tester) -> Array[(Int, Double)] {
  let out : Array[(Int, Double)] = []
  let insts = t.drawn_instances()
  for i in 0..<insts.length() {
    let a = insts[i]
    if a.length() > 23 && a[5] == 6.0 {
      out.push((i, a[23]))
    }
  }
  out
}

///|
fn bridge_pill_menu_tester(
  open : @signals.Signal[Bool],
  solid : Bool,
) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=800.0, h=600.0, dark=false, platform=0)
  set_dark(Some(false))
  @ui.set_glass_solid(if solid { Some(true) } else { None })
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    let more_ref : Ref[@view.View?] = Ref(None)
    root.box(fn(page) {
      page.grow(Is(1.0)).padding(Is((64.0, 24.0, 64.0, 64.0))).ground(By(fn() { theme().p.bg })) |> ignore
      page.box(fn(bar) {
        bar.row(Is(true)).gap(Is(6.0)).lies_along(Is(End)) |> ignore
        bar_pill_group_node(bar, height=36.0, pad=2.0, gap=2.0, fn(k) {
          icon_button_node(k, "archive", fn() { "Archive" }, fn() {  }) |> ignore
        })
        |> ignore
        bar_pill_group_node(bar, height=36.0, pad=2.0, gap=2.0, fn(k) {
          icon_button_node(k, "info", fn() { "Info" }, fn() {  }) |> ignore
          let more = icon_button_node(k, "more", fn() { "More" }, fn() { open.set(true) })
          more_ref.val = Some(more)
        })
        |> ignore
      })
      |> ignore
      root.box(fn(l) {
        l.over(Is(true)) |> ignore
        menu_node(
          l,
          fn() { open.get() },
          fn(_) { more_ref.val.unwrap() },
          fn() {
            [
              Some(menu_item_of("Copy Link", fn() {  })),
              Some(menu_item_of("Pin Message", fn() {  })),
              Some(menu_item_of("Delete", fn() {  })),
            ]
          },
          "",
          End,
          panel_offset,
          false,
          false,
          fn(_) { open.set(false) },
          fn() { open.set(false) },
        )
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t
}

///|
fn bridge_plain_menu_tester(
  open : @signals.Signal[Bool],
  solid : Bool,
) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=800.0, h=600.0, dark=false, platform=0)
  set_dark(Some(false))
  @ui.set_glass_solid(if solid { Some(true) } else { None })
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(page) {
      page.grow(Is(1.0)).padding(Is((64.0, 64.0, 64.0, 64.0))).ground(By(fn() { theme().p.bg })) |> ignore
      let btn = page.box(fn(o) {
        o
        .width(Is(Some(80.0)))
        .height(Is(Some(36.0)))
        .presses(Is(true))
        .on_press(fn() { open.set(true) })
        .says(Is(Some(@view.said(Button, label="Actions"))))
        |> ignore
      })
      root.box(fn(l) {
        l.over(Is(true)) |> ignore
        menu_node(
          l,
          fn() { open.get() },
          fn(_) { btn },
          fn() {
            [
              Some(menu_item_of("Copy Link", fn() {  })),
              Some(menu_item_of("Pin Message", fn() {  })),
              Some(menu_item_of("Delete", fn() {  })),
            ]
          },
          "",
          Start,
          panel_offset,
          false,
          false,
          fn(_) { open.set(false) },
          fn() { open.set(false) },
        )
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t
}

///|
test "bar_pill_group_node menu performs iOS 27.0 LiquidMorphPhysics with upward close recoil and horizontal splash while Archive stays isolated" {
  defer {
    @ui.set_glass_solid(None)
    set_dark(None)
  }
  let open = @signals.signal(false)
  let t = bridge_pill_menu_tester(open, false)

  // Before open: 2 resting pill liquid glass instances ([Archive] + [(i) ...]), both merge == 0.0
  let init_glass = t.drawn_glass()
  let init_liq = bridge_liquid_instances(t)
  assert_eq(init_liq.length(), 2, msg="2 resting pills emit 2 liquid glass instances")
  assert_eq(init_liq[0].1, 0.0, msg="resting archive pill merge is 0.0")
  assert_eq(init_liq[1].1, 0.0, msg="resting trigger pill merge is 0.0")
  let rest_pill_y = init_glass[1].1
  let rest_pill_w = init_glass[1].2

  // Three-anchor optical boundary invariant:
  // stage=0.0 == glass_bar_pill(), stage=0.5 == luminous 0x93/blur=4.0/bezel=18/refr=16/chroma=0.045, stage=1.0 == glass_menu()
  let pill_gl = @glass.liquid_bar_pill_glass(solid=panel_ground())
  let clear_gl = glass_menu_morph(0.0)
  let mid_gl = glass_menu_morph(0.5)
  let rest_gl = glass_menu()
  let frosted_gl = glass_menu_morph(1.0)
  assert_eq(clear_gl.tint, pill_gl.tint, msg="stage=0.0 tint bit-identical to glass_bar_pill")
  assert_eq(clear_gl.blur, pill_gl.blur, msg="stage=0.0 blur bit-identical to glass_bar_pill")
  assert_true((clear_gl.chroma - 0.06).abs() < 1.0e-9, msg="stage=0.0 chroma matches bar_pill: \{clear_gl.chroma}")
  assert_eq(mid_gl.tint & 0xFFL, 0x93L, msg="stage=0.5 light droplet uses 0x93 mid-translucent alpha")
  assert_true((mid_gl.blur - 4.0).abs() < 1.0e-9, msg="stage=0.5 droplet uses 4.0pt blur: \{mid_gl.blur}")
  assert_true((mid_gl.bezel - 18.0).abs() < 1.0e-9, msg="stage=0.5 droplet uses 18.0pt bezel: \{mid_gl.bezel}")
  assert_true((mid_gl.refraction - 16.0).abs() < 1.0e-9, msg="stage=0.5 droplet uses 16.0pt refraction: \{mid_gl.refraction}")
  assert_true((mid_gl.chroma - 0.045).abs() < 1.0e-9, msg="stage=0.5 droplet uses 0.045 chroma: \{mid_gl.chroma}")
  assert_eq(frosted_gl.tint, rest_gl.tint, msg="stage=1.0 tint bit-identical to glass_menu")
  assert_eq(frosted_gl.blur, rest_gl.blur, msg="stage=1.0 blur bit-identical to glass_menu")
  assert_eq(frosted_gl.bezel, rest_gl.bezel, msg="stage=1.0 bezel bit-identical to glass_menu")
  assert_eq(frosted_gl.refraction, rest_gl.refraction, msg="stage=1.0 refraction bit-identical to glass_menu")
  assert_eq(frosted_gl.chroma, rest_gl.chroma, msg="stage=1.0 chroma bit-identical to glass_menu")

  // Open menu and settle (>= 600ms): Archive + Menu (2 instances), 0 kind==8 lens overhead at rest, clean audit
  open.set(true)
  t.draw()
  t.run_for(bridge_test_settle_ms)
  let rest_glass = t.drawn_glass()
  let rest_liq = bridge_liquid_instances(t)
  assert_eq(rest_glass.length(), 2, msg="rest has 2 liquid surfaces (Archive + in-place Menu)")
  assert_eq(rest_liq.length(), 2, msg="rest has 2 raw liquid instances")
  assert_true((rest_glass[1].1 - rest_glass[0].1).abs() <= 1.5, msg="menu top aligns with top bar pill top")
  for x in rest_liq {
    assert_eq(x.1, 0.0, msg="rest merge is 0.0 for all surfaces")
  }
  let rest_lens_n = t.drawn_instances().filter(fn(a) { a.length() > 5 && a[5] == 8.0 }).length()
  assert_eq(rest_lens_n, 0, msg="resting menu emits 0 kind == 8 content_lens instances")
  assert_eq(t.audit(), [], msg="clean audit at rest")

  // Close menu: advance to ~185ms (peak parallel upward recoil ~-16..-17.5pt)
  open.set(false)
  t.draw()
  let close_t0 = t.time()
  t.run_for(bridge_test_recoil_ms)
  let recoil_dt = t.time() - close_t0
  if recoil_dt >= 140.0 && recoil_dt <= 260.0 {
    let recoil_glass = t.drawn_glass()
    let recoil_liq = bridge_liquid_instances(t)
    assert_eq(recoil_liq[0].1, 0.0, msg="Archive pill stays 100% isolated during close recoil")
    // Trigger pill (index 1 when Blob A emerged) has significant upward negative dy displacement
    if recoil_glass.length() >= 3 {
      let trig_dy = recoil_glass[1].1 - rest_pill_y
      assert_true(trig_dy <= -6.5 && trig_dy >= -11.5, msg="trigger pill kicks upward ~-9.5pt at \{recoil_dt}ms: dy=\{trig_dy}")
    }
  }

  // Advance to ~400ms (post-handoff horizontal splash > rest_pill_w, only 2 liquid instances — zero double glass)
  t.run_for(bridge_test_splash_step_ms)
  let splash_dt = t.time() - close_t0
  if splash_dt >= 340.0 && splash_dt <= 460.0 {
    let splash_glass = t.drawn_glass()
    let splash_liq = bridge_liquid_instances(t)
    assert_eq(splash_liq.length(), 2, msg="post-handoff has 2 liquid instances (no double glass) at \{splash_dt}ms")
    assert_true(splash_glass[1].2 > rest_pill_w + 0.1, msg="horizontal splash exceeds resting width at \{splash_dt}ms: w=\{splash_glass[1].2} vs rest=\{rest_pill_w}")
  }

  // Complete full 580ms close recoil + splash settle: trigger pill restored cleanly to resting y & w
  t.run_for(bridge_test_settle_ms)
  let after_glass = t.drawn_glass()
  let after_liq = bridge_liquid_instances(t)
  assert_eq(after_liq.length(), 2, msg="only 2 original top bar pills remain after close finishes")
  assert_eq(after_liq[0].1, 0.0, msg="restored archive pill merge is 0.0")
  assert_eq(after_liq[1].1, 0.0, msg="restored trigger pill merge is 0.0")
  assert_true((after_glass[1].1 - rest_pill_y).abs() < 0.5, msg="trigger pill returns to resting y")
  assert_true((after_glass[1].2 - rest_pill_w).abs() < 0.5, msg="trigger pill returns to resting width")
}

///|
test "non-pill plain button anchored popover keeps FromBeside 0.97..1.0 scale without stacking extra glass" {
  defer {
    @ui.set_glass_solid(None)
    set_dark(None)
  }
  let open = @signals.signal(false)
  let t = bridge_plain_menu_tester(open, false)
  open.set(true)
  t.draw()
  t.run_for(@motion.pop_ms * 0.3)
  let enter_glass = t.drawn_glass()
  assert_eq(enter_glass.length(), 1, msg="non-pill button emits single glass surface without fake droplet")
  t.run_for(@motion.pop_ms)
  let rest_glass = t.drawn_glass()
  assert_eq(rest_glass.length(), 1, msg="rest emits 1 liquid glass instance")
  assert_eq(t.audit(), [], msg="clean audit at rest")
  let rest_h = rest_glass[0].3
  assert_true(enter_glass[0].3 / rest_h >= 0.96, msg="non-pill entrance keeps 0.97..1.0 FromBeside scale: \{enter_glass[0].3 / rest_h}")
  open.set(false)
  t.draw()
  t.run_for(@motion.pop_out_ms * 0.5)
  let exit_glass = t.drawn_glass()
  assert_eq(exit_glass.length(), 1, msg="non-pill exit emits 1 liquid glass instance")
  let exit_scale = exit_glass[0].3 / rest_h
  assert_true(exit_scale >= 0.96 && exit_scale <= 1.0, msg="non-pill exit keeps 0.97..1.0 FromBeside scale: scale=\{exit_scale}")
  t.run_for(@motion.pop_out_ms)
  assert_eq(t.drawn_glass().length(), 0, msg="no glass instances after non-pill exit completes")
}

///|
test "1x1 point anchor context menu never emits a capillary bridge and keeps 0.97 scale" {
  defer {
    @ui.set_glass_solid(None)
    set_dark(None)
  }
  presenters_reset()
  let t = @ui.Tester::new(fn(_c) {  }, w=800.0, h=600.0, dark=false, platform=0)
  set_dark(Some(false))
  @ui.set_glass_solid(None)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(page) {
      page.grow(Is(1.0)).ground(By(fn() { theme().p.bg })) |> ignore
    })
    |> ignore
    presented_nodes(root)
  })
  t.draw()
  menu(
    [Some(menu_item_of("Copy", fn() {  })), Some(menu_item_of("Paste", fn() {  }))],
    from=at_point(240.0, 180.0),
  )
  t.draw()
  t.run_for(@motion.pop_ms * 0.3)
  let pt_mid = t.drawn_glass()
  assert_true(pt_mid.length() <= 1, msg="at_point mid-entrance emits at most 1 glass instance")
  t.run_for(@motion.pop_ms)
  let pt_rest = t.drawn_glass()
  assert_eq(pt_rest.length(), 1, msg="at_point resting emits 1 glass instance")
  assert_true(pt_mid[0].3 / pt_rest[0].3 >= 0.96, msg="at_point keeps 0.97..1.0 scale range: \{pt_mid[0].3 / pt_rest[0].3}")
  t.key(@ui.key_escape)
  t.draw()
  t.run_for(@motion.pop_out_ms * 0.5)
  let pt_exit = t.drawn_glass()
  assert_true(pt_exit.length() <= 1, msg="at_point mid-exit emits at most 1 glass instance")
  assert_true(pt_exit[0].3 / pt_rest[0].3 >= 0.96, msg="at_point exit keeps 0.97..1.0 scale range: \{pt_exit[0].3 / pt_rest[0].3}")
  t.run_for(@motion.pop_out_ms)
  assert_eq(t.drawn_glass().length(), 0, msg="at_point exit clears glass")
}

///|
test "MBUI_GLASS=solid emits zero liquid glass instances across pill menu entrance, rest, and exit" {
  defer {
    @ui.set_glass_solid(None)
    set_dark(None)
  }
  let open = @signals.signal(false)
  let t = bridge_pill_menu_tester(open, true)
  open.set(true)
  t.draw()
  t.run_for(@motion.pop_ms * 0.3)
  assert_eq(t.drawn_glass().length(), 0, msg="solid mid-entrance has 0 glass")
  t.run_for(@motion.pop_ms)
  assert_eq(t.drawn_glass().length(), 0, msg="solid rest has 0 glass")
  assert_eq(t.audit(), [], msg="solid rest audit clean")
  open.set(false)
  t.draw()
  t.run_for(@motion.pop_out_ms * 0.4)
  assert_eq(t.drawn_glass().length(), 0, msg="solid mid-exit has 0 glass")
  t.run_for(@motion.pop_out_ms)
  assert_eq(t.drawn_glass().length(), 0, msg="solid post-exit has 0 glass")
}

///|
test "pill menu submenu slides in-container with single glass shell, concentric back header, and clean dismiss" {
  defer {
    @ui.set_glass_solid(None)
    set_dark(None)
    presenters_reset()
  }
  presenters_reset()
  set_words(fn(key, _) { if key == "common.back" { "返回" } else { key } })
  let t = @ui.Tester::new(fn(_c) {  }, w=390.0, h=844.0, dark=false, platform=2)
  set_dark(Some(false))
  @ui.set_glass_solid(None)
  let more_ref : Ref[@view.View?] = Ref(None)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(page) {
      page.grow(Is(1.0)).padding(Is((16.0, 48.0, 16.0, 16.0))).ground(By(fn() { theme().p.bg })) |> ignore
      page.box(fn(bar) {
        bar.row(Is(true)).gap(Is(6.0)).lies_along(Is(End)) |> ignore
        bar_pill_group_node(bar, height=36.0, pad=2.0, gap=2.0, fn(k) {
          icon_button_node(k, "archive", fn() { "Archive" }, fn() {  }) |> ignore
        })
        |> ignore
        bar_pill_group_node(bar, height=36.0, pad=2.0, gap=2.0, fn(k) {
          icon_button_node(k, "info", fn() { "Info" }, fn() {  }) |> ignore
          let more = icon_button_node(k, "more", fn() { "More" }, fn() {
            let anchor = more_ref.val.unwrap()
            menu(
              [
                Some(menu_item_of("固定", fn() {  }, icon="pin")),
                Some(menu_item_of("分享", fn() {
                  menu(
                    [
                      Some(menu_item_of("复制链接", fn() {  }, icon="link")),
                      Some(menu_item_of("导出图片", fn() {  }, icon="image")),
                    ],
                    from=Node(anchor),
                    title="分享",
                    along=End,
                  )
                }, icon="share", further=true)),
                Some(menu_item_of("删除", fn() {  }, icon="trash", danger=true)),
              ],
              from=Node(anchor),
              along=End,
            )
          })
          more_ref.val = Some(more)
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
    presented_nodes(root)
  })
  t.draw()
  // Open root menu
  let (mx, my, mw, mh) = more_ref.val.unwrap().placed_window_now()
  t.press_at(mx + mw * 0.5, my + mh * 0.5)
  t.release(mx + mw * 0.5, my + mh * 0.5)
  t.run_for(bridge_test_settle_ms)
  assert_true(t.find("分享") is Some(_), msg="root menu shows 分享")
  assert_eq(bridge_liquid_instances(t).length(), 2, msg="root menu rest: Archive + 1 menu glass")
  assert_eq(t.audit(), [], msg="root menu rest audit clean")
  assert_eq(t.corner_faults(), [], msg="root menu rest corner_faults clean")

  // Tap 分享 -> push submenu in same glass container (no 2nd menu glass ball!)
  let (sx, sy) = t.find("分享").unwrap()
  t.press_at(sx, sy)
  t.release(sx, sy)
  t.run_for(bridge_test_mid_slide_ms)
  assert_eq(bridge_liquid_instances(t).length(), 2, msg="mid-slide submenu still has only 2 liquid instances (Archive + 1 menu)")
  t.run_for(bridge_test_slide_settle_ms)
  assert_true(t.find("复制链接") is Some(_), msg="submenu shows 复制链接")
  assert_eq(bridge_liquid_instances(t).length(), 2, msg="submenu rest: Archive + 1 menu glass")
  assert_eq(t.audit(), [], msg="submenu rest audit clean")
  assert_eq(t.corner_faults(), [], msg="submenu rest corner_faults clean")

  // Tap back -> slide back to root menu
  t.back()
  t.run_for(bridge_test_slide_settle_ms)
  assert_true(t.find("固定") is Some(_), msg="back returns to root menu")
  assert_eq(bridge_liquid_instances(t).length(), 2, msg="back rest: Archive + 1 menu glass")
  assert_eq(t.audit(), [], msg="back rest audit clean")

  // Push submenu again and dismiss by tapping outside -> whole menu closes cleanly back into pill
  let (sx2, sy2) = t.find("分享").unwrap()
  t.press_at(sx2, sy2)
  t.release(sx2, sy2)
  t.run_for(bridge_test_slide_settle_ms)
  t.press_at(40.0, 500.0)
  t.release(40.0, 500.0)
  t.run_for(bridge_test_settle_ms)
  assert_true(t.find("复制链接") is None, msg="outside tap closes whole submenu")
  assert_eq(bridge_liquid_instances(t).length(), 2, msg="post-close restores 2 top bar pills")
}

///|
test "rapid close and reopen on same pill trigger preserves morph_owner without old unmount clobber" {
  defer {
    @ui.set_glass_solid(None)
    set_dark(None)
    presenters_reset()
  }
  presenters_reset()
  let t = @ui.Tester::new(fn(_c) {  }, w=390.0, h=844.0, dark=false, platform=2)
  set_dark(Some(false))
  @ui.set_glass_solid(None)
  let more_ref : Ref[@view.View?] = Ref(None)
  let open_menu = fn() {
    let anchor = more_ref.val.unwrap()
    menu(
      [
        Some(menu_item_of("Item A", fn() {  })),
        Some(menu_item_of("Item B", fn() {  })),
      ],
      from=Node(anchor),
      along=End,
    )
  }
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(page) {
      page.grow(Is(1.0)).padding(Is((16.0, 48.0, 16.0, 16.0))).ground(By(fn() { theme().p.bg })) |> ignore
      page.box(fn(bar) {
        bar.row(Is(true)).gap(Is(6.0)).lies_along(Is(End)) |> ignore
        bar_pill_group_node(bar, height=36.0, pad=2.0, gap=2.0, fn(k) {
          let more = icon_button_node(k, "more", fn() { "More" }, open_menu)
          more_ref.val = Some(more)
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
    presented_nodes(root)
  })
  t.draw()
  // Open menu 1 and settle
  open_menu()
  t.draw()
  t.run_for(bridge_test_settle_ms)
  // Start closing menu 1 (mid-610ms close), then immediately open menu 2 on same trigger pill
  t.key(@ui.key_escape)
  t.draw()
  t.run_for(bridge_test_reopen_ms)
  open_menu()
  t.draw()
  // Wait past menu 1's old 610ms window + menu 2 settle: menu 2 must remain intact with exactly 1 glass instance
  t.run_for(bridge_test_settle_ms)
  assert_true(t.find("Item A") is Some(_), msg="menu 2 stays open after menu 1 unmount")
  assert_eq(bridge_liquid_instances(t).length(), 1, msg="only menu 2 glass instance active (old trigger stays hidden)")
  assert_eq(t.audit(), [], msg="reopen rest audit clean")
  // Close menu 2 cleanly: trigger pill must restore to alpha=1
  t.key(@ui.key_escape)
  t.draw()
  t.run_for(bridge_test_settle_ms)
  assert_eq(bridge_liquid_instances(t).length(), 1, msg="trigger pill restored cleanly after menu 2 close")
}

///|
test "tall 8-item pill menu clamps mid-open content scale to min(cur_w/w, cur_h/h)" {
  let f120 = @glass.lm_eval_pill_morph(300.0, 35.0, 74.0, 36.0, 358.0, 184.0, 35.0, 200.0, 390.0, 20.0, 1.0, false, 0.12)
  let scale_w = f120.cur_w / 200.0
  let scale_h = f120.cur_h / 390.0
  let clamped = dclamp(dmin(scale_w, scale_h), 0.20, 1.0)
  assert_true(scale_h < scale_w, msg="tall 8-item menu has cur_h/h < cur_w/w at 120ms: h=\{scale_h} w=\{scale_w}")
  assert_true(clamped <= scale_h + 1.0e-9, msg="content scale <= cur_h/h prevents top-row clipping: \{clamped} vs \{scale_h}")
}

///|
test "bar_pill_group_node panel_node performs liquid morph with OpenGate, zero rest lens, upward recoil, and horizontal splash" {
  defer {
    @ui.set_glass_solid(None)
    set_dark(None)
    presenters_reset()
  }
  presenters_reset()
  set_words(fn(key, _) { key })
  let t = @ui.Tester::new(fn(_c) {  }, w=900.0, h=640.0, dark=false, platform=0)
  set_dark(Some(false))
  @ui.set_glass_solid(None)
  let info_ref : Ref[@view.View?] = Ref(None)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(page) {
      page.grow(Is(1.0)).padding(Is((64.0, 24.0, 64.0, 64.0))).ground(By(fn() { theme().p.bg })) |> ignore
      page.box(fn(bar) {
        bar.row(Is(true)).gap(Is(6.0)).lies_along(Is(End)) |> ignore
        bar_pill_group_node(bar, height=36.0, pad=2.0, gap=2.0, fn(k) {
          icon_button_node(k, "archive", fn() { "Archive" }, fn() {  }) |> ignore
        })
        |> ignore
        bar_pill_group_node(bar, height=36.0, pad=2.0, gap=2.0, fn(k) {
          let info = icon_button_node(k, "info", fn() { "Info" }, fn() {
            let anchor = info_ref.val.unwrap()
            panel_nodes(
              "Chat Info",
              fn(body, _close) {
                body.box(fn(w) {
                  words_node(w, fn() { "Panel Body Content" }, fn() { paragraph }) |> ignore
                })
                |> ignore
              },
              from=Node(anchor),
              along=End,
            )
          })
          info_ref.val = Some(info)
          icon_button_node(k, "more", fn() { "More" }, fn() {  }) |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
    presented_nodes(root)
  })
  t.draw()
  let init_glass = t.drawn_glass()
  assert_eq(init_glass.length(), 2, msg="2 resting pills before panel open")
  let rest_pill_y = init_glass[1].1
  let rest_pill_w = init_glass[1].2

  let (ix, iy, iw, ih) = info_ref.val.unwrap().placed_window_now()
  t.press_at(ix + iw * 0.5, iy + ih * 0.5)
  t.release(ix + iw * 0.5, iy + ih * 0.5)
  t.run_for(bridge_test_settle_ms)
  assert_true(t.find("Panel Body Content") is Some(_), msg="panel body visible at rest")
  let rest_glass = t.drawn_glass()
  let rest_liq = bridge_liquid_instances(t)
  assert_eq(rest_glass.length(), 2, msg="rest panel has 2 liquid instances (Archive + Panel)")
  assert_eq(rest_liq.length(), 2, msg="rest panel has 2 raw liquid instances")
  assert_true((rest_glass[1].1 - rest_glass[0].1).abs() <= 1.5, msg="panel top aligns with top bar pill top")
  let rest_lens_n = t.drawn_instances().filter(fn(a) { a.length() > 5 && a[5] == 8.0 }).length()
  assert_eq(rest_lens_n, 0, msg="resting panel emits 0 kind == 8 content_lens")
  assert_eq(t.audit(), [], msg="panel rest audit clean")

  t.key(@ui.key_escape)
  t.draw()
  let close_t0 = t.time()
  t.run_for(bridge_test_recoil_ms)
  let recoil_dt = t.time() - close_t0
  if recoil_dt >= 140.0 && recoil_dt <= 260.0 {
    let recoil_glass = t.drawn_glass()
    if recoil_glass.length() >= 3 {
      let trig_dy = recoil_glass[1].1 - rest_pill_y
      assert_true(trig_dy <= -6.0 && trig_dy >= -11.5, msg="panel close trigger recoil upward at \{recoil_dt}ms: dy=\{trig_dy}")
    }
  }
  t.run_for(bridge_test_splash_step_ms)
  let splash_dt = t.time() - close_t0
  if splash_dt >= 340.0 && splash_dt <= 460.0 {
    let splash_glass = t.drawn_glass()
    assert_eq(bridge_liquid_instances(t).length(), 2, msg="panel post-handoff has 2 liquid instances")
    assert_true(splash_glass[1].2 > rest_pill_w + 0.1, msg="panel close horizontal splash: w=\{splash_glass[1].2} vs \{rest_pill_w}")
  }
  t.run_for(bridge_test_settle_ms)
  let after_glass = t.drawn_glass()
  assert_true(t.find("Panel Body Content") is None, msg="panel unmounted after close")
  assert_eq(bridge_liquid_instances(t).length(), 2, msg="2 resting pills after panel close")
  assert_true((after_glass[1].1 - rest_pill_y).abs() < 0.5, msg="pill returns to resting y")
  assert_true((after_glass[1].2 - rest_pill_w).abs() < 0.5, msg="pill returns to resting width")
  assert_eq(t.audit(), [], msg="post-close panel audit clean")
}

///|
test "bar_pill_group_node pick_node performs liquid morph with smooth exit recoil and clean unmount" {
  defer {
    @ui.set_glass_solid(None)
    set_dark(None)
    presenters_reset()
  }
  presenters_reset()
  set_words(fn(key, _) { key })
  let t = @ui.Tester::new(fn(_c) {  }, w=900.0, h=640.0, dark=false, platform=0)
  set_dark(Some(false))
  @ui.set_glass_solid(None)
  let pick_ref : Ref[@view.View?] = Ref(None)
  let choices = Array::makei(pick_search_from + 2, fn(i) { choice("c\{i}", "Option \{i}") })
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(page) {
      page.grow(Is(1.0)).padding(Is((64.0, 24.0, 64.0, 64.0))).ground(By(fn() { theme().p.bg })) |> ignore
      page.box(fn(bar) {
        bar.row(Is(true)).gap(Is(6.0)).lies_along(Is(End)) |> ignore
        bar_pill_group_node(bar, height=36.0, pad=2.0, gap=2.0, fn(k) {
          icon_button_node(k, "archive", fn() { "Archive" }, fn() {  }) |> ignore
        })
        |> ignore
        bar_pill_group_node(bar, height=36.0, pad=2.0, gap=2.0, fn(k) {
          icon_button_node(k, "info", fn() { "Info" }, fn() {  }) |> ignore
          let btn = icon_button_node(k, "more", fn() { "Choose" }, fn() {
            let anchor = pick_ref.val.unwrap()
            pick("Pick One", choices, "c0", fn(_) {  }, from=Node(anchor), along=End)
          })
          pick_ref.val = Some(btn)
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
    presented_nodes(root)
  })
  t.draw()
  let init_glass = t.drawn_glass()
  let rest_pill_y = init_glass[1].1
  let rest_pill_w = init_glass[1].2

  let (px, py, pw, ph) = pick_ref.val.unwrap().placed_window_now()
  t.press_at(px + pw * 0.5, py + ph * 0.5)
  t.release(px + pw * 0.5, py + ph * 0.5)
  t.run_for(bridge_test_settle_ms)
  assert_true(t.find("Option 1") is Some(_), msg="pick_node options visible at rest")
  let rest_glass = t.drawn_glass()
  assert_eq(rest_glass.length(), 2, msg="rest pick_node has 2 liquid instances (Archive + Pick)")
  assert_true((rest_glass[1].1 - rest_glass[0].1).abs() <= 1.5, msg="pick_node top aligns with top bar pill top")
  let rest_lens_n = t.drawn_instances().filter(fn(a) { a.length() > 5 && a[5] == 8.0 }).length()
  assert_eq(rest_lens_n, 0, msg="resting pick_node emits 0 kind == 8 content_lens")
  assert_eq(t.audit(), [], msg="pick_node rest audit clean")

  t.key(@ui.key_escape)
  t.draw()
  let close_t0 = t.time()
  t.run_for(bridge_test_recoil_ms)
  let recoil_dt = t.time() - close_t0
  if recoil_dt >= 140.0 && recoil_dt <= 260.0 {
    let recoil_glass = t.drawn_glass()
    if recoil_glass.length() >= 3 {
      let trig_dy = recoil_glass[1].1 - rest_pill_y
      assert_true(trig_dy <= -6.0 && trig_dy >= -11.5, msg="pick_node close recoil upward at \{recoil_dt}ms: dy=\{trig_dy}")
    }
  }
  t.run_for(bridge_test_settle_ms)
  assert_true(t.find("Option 1") is None, msg="pick_node unmounted after close")
  let after_glass = t.drawn_glass()
  assert_eq(bridge_liquid_instances(t).length(), 2, msg="2 resting pills after pick_node close")
  assert_true((after_glass[1].1 - rest_pill_y).abs() < 0.5, msg="pill returns to resting y after pick_node close")
  assert_true((after_glass[1].2 - rest_pill_w).abs() < 0.5, msg="pill returns to resting width after pick_node close")
  assert_eq(t.audit(), [], msg="post-close pick_node audit clean")
}

///|
test "glass_capsule_node trigger=true menu_node side=Top morphs upward, recoils downward, and restores capsule material" {
  defer {
    @ui.set_glass_solid(None)
    set_dark(None)
    presenters_reset()
  }
  presenters_reset()
  let t = @ui.Tester::new(fn(_c) {  }, w=800.0, h=600.0, dark=false, platform=0)
  set_dark(Some(false))
  @ui.set_glass_solid(None)
  let cap_ref : Ref[@view.View?] = Ref(None)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(page) {
      page.grow(Is(1.0)).padding(Is((64.0, 24.0, 64.0, 64.0))).lies_along(Is(End)).ground(By(fn() { theme().p.bg })) |> ignore
      page.box(fn(row) {
        row.row(Is(true)).gap(Is(8.0)) |> ignore
        let cap = action_box_node(row, fn() { "Model" }, fn(b) {
          menu(
            [
              Some(menu_item_of("Gemini 4", fn() {  })),
              Some(menu_item_of("Claude 5", fn() {  })),
              Some(menu_item_of("GPT 6", fn() {  })),
            ],
            from=Node(b),
            side=Top,
            along=Start,
          )
        }, fn(b) {
          glass_capsule_node(b, min_height=Some(32.0), radius=Some(999.0), trigger=true)
          .row(Is(true))
          .lines_up(Is(Some(Middle)))
          .padding(Is((14.0, 0.0, 14.0, 0.0)))
          |> ignore
          b.box(fn(w) { w.words(Is("Gemini 4")).ink(By(fn() { theme().p.text })) |> ignore }) |> ignore
        })
        cap_ref.val = Some(cap)
      })
      |> ignore
    })
    |> ignore
    presented_nodes(root)
  })
  t.draw()
  let init_glass = t.drawn_glass()
  assert_eq(init_glass.length(), 1, msg="1 resting trigger capsule")
  let rest_cap_y = init_glass[0].1
  let rest_cap_w = init_glass[0].2
  let rest_cap_h = init_glass[0].3

  let (cx, cy, cw, ch) = cap_ref.val.unwrap().placed_window_now()
  t.press_at(cx + cw * 0.5, cy + ch * 0.5)
  t.release(cx + cw * 0.5, cy + ch * 0.5)
  t.run_for(bridge_test_settle_ms)
  assert_true(t.find("Claude 5") is Some(_), msg="Top menu visible at rest")
  let rest_glass = t.drawn_glass()
  assert_eq(rest_glass.length(), 1, msg="rest Top menu replaces trigger capsule (1 liquid instance)")
  assert_true(
    (rest_glass[0].1 + rest_glass[0].3 - (rest_cap_y + rest_cap_h)).abs() <= 2.0,
    msg="Top menu bottom aligns with capsule bottom",
  )
  let rest_lens_n = t.drawn_instances().filter(fn(a) { a.length() > 5 && a[5] == 8.0 }).length()
  assert_eq(rest_lens_n, 0, msg="resting Top menu emits 0 kind == 8 content_lens")
  assert_eq(t.audit(), [], msg="Top menu rest audit clean")

  t.key(@ui.key_escape)
  t.draw()
  let close_t0 = t.time()
  t.run_for(bridge_test_recoil_ms)
  let recoil_dt = t.time() - close_t0
  if recoil_dt >= 140.0 && recoil_dt <= 260.0 {
    let recoil_glass = t.drawn_glass()
    if recoil_glass.length() >= 2 {
      let trig_dy = recoil_glass[0].1 - rest_cap_y
      assert_true(trig_dy >= 4.0 && trig_dy <= 11.5, msg="Top menu close recoils downward at \{recoil_dt}ms: dy=\{trig_dy}")
    }
  }
  t.run_for(bridge_test_settle_ms)
  let after_glass = t.drawn_glass()
  assert_true(t.find("Claude 5") is None, msg="Top menu unmounted after close")
  assert_eq(after_glass.length(), 1, msg="trigger capsule restored after Top menu close")
  assert_true((after_glass[0].1 - rest_cap_y).abs() < 0.5, msg="capsule returns to resting y")
  assert_true((after_glass[0].2 - rest_cap_w).abs() < 0.5, msg="capsule returns to resting w")
  assert_eq(t.audit(), [], msg="Top menu post-close audit clean")
}

///|
test "vertical float_pill_group_node panel_node side=Left contracts vertically, recoils rightward, and splashes vertically" {
  defer {
    @ui.set_glass_solid(None)
    set_dark(None)
    presenters_reset()
  }
  presenters_reset()
  set_words(fn(key, _) { key })
  let t = @ui.Tester::new(fn(_c) {  }, w=900.0, h=640.0, dark=false, platform=0)
  set_dark(Some(false))
  @ui.set_glass_solid(None)
  let toc_ref : Ref[@view.View?] = Ref(None)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(page) {
      page.grow(Is(1.0)).padding(Is((24.0, 64.0, 24.0, 64.0))).lines_up(Is(Some(End))).lies_along(Is(End)).ground(By(fn() { theme().p.bg })) |> ignore
      float_pill_group_node(page, fn(g) {
        float_pill_item_node(g, "inbox", fn() { "Inbox" }, fn() {  }) |> ignore
        let toc = float_pill_item_node(g, "list", fn() { "Outline" }, fn() {
          let anchor = toc_ref.val.unwrap()
          panel_nodes(
            "Outline",
            fn(body, _close) {
              body.box(fn(w) {
                words_node(w, fn() { "Section One" }, fn() { paragraph }) |> ignore
              })
              |> ignore
            },
            from=Node(anchor),
            side=Left,
            along=End,
          )
        })
        toc_ref.val = Some(toc)
        float_pill_item_node(g, "arrow-down", fn() { "Bottom" }, fn() {  }) |> ignore
      })
      |> ignore
    })
    |> ignore
    presented_nodes(root)
  })
  t.draw()
  let init_glass = t.drawn_glass()
  assert_eq(init_glass.length(), 1, msg="1 vertical float_pill_group_node at rest")
  let rest_pill_x = init_glass[0].0
  let rest_pill_y = init_glass[0].1
  let rest_pill_w = init_glass[0].2
  let rest_pill_h = init_glass[0].3
  assert_true(rest_pill_h > rest_pill_w * 2.0, msg="vertical pill is taller than wide: \{rest_pill_w}x\{rest_pill_h}")

  let (tx, ty, tw, th) = toc_ref.val.unwrap().placed_window_now()
  t.press_at(tx + tw * 0.5, ty + th * 0.5)
  t.release(tx + tw * 0.5, ty + th * 0.5)
  t.run_for(bridge_test_settle_ms)
  assert_true(t.find("Section One") is Some(_), msg="Left panel visible at rest")
  let rest_glass = t.drawn_glass()
  assert_eq(rest_glass.length(), 1, msg="rest Left panel replaces vertical pill (1 liquid instance)")
  let rest_lens_n = t.drawn_instances().filter(fn(a) { a.length() > 5 && a[5] == 8.0 }).length()
  assert_eq(rest_lens_n, 0, msg="resting Left panel emits 0 kind == 8 content_lens")
  assert_eq(t.audit(), [], msg="Left panel rest audit clean")

  t.key(@ui.key_escape)
  t.draw()
  let close_t0 = t.time()
  t.run_for(bridge_test_recoil_ms)
  let recoil_dt = t.time() - close_t0
  if recoil_dt >= 140.0 && recoil_dt <= 260.0 {
    let recoil_glass = t.drawn_glass()
    if recoil_glass.length() >= 2 {
      let trig_dx = recoil_glass[0].0 - rest_pill_x
      assert_true(trig_dx >= 4.0 && trig_dx <= 11.5, msg="Left panel close recoils rightward at \{recoil_dt}ms: dx=\{trig_dx}")
    }
  }
  t.run_for(bridge_test_splash_step_ms)
  let splash_dt = t.time() - close_t0
  if splash_dt >= 340.0 && splash_dt <= 460.0 {
    let splash_glass = t.drawn_glass()
    assert_eq(bridge_liquid_instances(t).length(), 1, msg="vertical pill post-handoff has 1 liquid instance")
    assert_true(splash_glass[0].3 > rest_pill_h + 0.1, msg="vertical splash exceeds resting height at \{splash_dt}ms: h=\{splash_glass[0].3} vs \{rest_pill_h}")
  }
  t.run_for(bridge_test_settle_ms)
  let after_glass = t.drawn_glass()
  assert_true(t.find("Section One") is None, msg="Left panel unmounted after close")
  assert_eq(after_glass.length(), 1, msg="vertical pill restored after close")
  assert_true((after_glass[0].0 - rest_pill_x).abs() < 0.5, msg="vertical pill returns to resting x")
  assert_true((after_glass[0].1 - rest_pill_y).abs() < 0.5, msg="vertical pill returns to resting y")
  assert_true((after_glass[0].3 - rest_pill_h).abs() < 0.5, msg="vertical pill returns to resting height")
  assert_eq(t.audit(), [], msg="vertical pill post-close audit clean")
}

///|
test "plain button panel/pick and glass_capsule_node trigger=false do not trigger pill_morph" {
  defer {
    @ui.set_glass_solid(None)
    set_dark(None)
    presenters_reset()
  }
  presenters_reset()
  set_words(fn(key, _) { key })
  let t = @ui.Tester::new(fn(_c) {  }, w=900.0, h=640.0, dark=false, platform=0)
  set_dark(Some(false))
  @ui.set_glass_solid(None)
  let cap_ref : Ref[@view.View?] = Ref(None)
  let btn_ref : Ref[@view.View?] = Ref(None)
  let choices = Array::makei(pick_search_from + 2, fn(i) { choice("c\{i}", "Plain \{i}") })
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(page) {
      page.grow(Is(1.0)).padding(Is((64.0, 64.0, 64.0, 64.0))).gap(Is(16.0)).ground(By(fn() { theme().p.bg })) |> ignore
      let cap = action_box_node(page, fn() { "NonTriggerCapsule" }, fn(b) {
        menu([Some(menu_item_of("Cap Item", fn() {  }))], from=Node(b))
      }, fn(b) {
        glass_capsule_node(b, min_height=Some(32.0), radius=Some(999.0))
        .row(Is(true))
        .lines_up(Is(Some(Middle)))
        .padding(Is((12.0, 0.0, 12.0, 0.0)))
        |> ignore
        b.box(fn(w) { w.words(Is("NonTriggerCapsule")).ink(By(fn() { theme().p.text })) |> ignore }) |> ignore
      })
      cap_ref.val = Some(cap)
      let btn = button_node(page, fn() { "PlainPick" }, fn() {
        pick("Plain Pick", choices, "c0", fn(_) {  }, from=Node(btn_ref.val.unwrap()))
      })
      btn_ref.val = Some(btn)
    })
    |> ignore
    presented_nodes(root)
  })
  t.draw()
  // 1. glass_capsule_node(trigger=false) keeps both capsule and menu glass (2 instances, no morph)
  let (cx, cy, cw, ch) = cap_ref.val.unwrap().placed_window_now()
  t.press_at(cx + cw * 0.5, cy + ch * 0.5)
  t.release(cx + cw * 0.5, cy + ch * 0.5)
  t.run_for(@motion.pop_ms)
  assert_true(t.find("Cap Item") is Some(_), msg="non-trigger capsule menu opens")
  assert_eq(t.drawn_glass().length(), 2, msg="trigger=false capsule stays visible beside menu (no morph)")
  t.key(@ui.key_escape)
  t.run_for(@motion.pop_out_ms)
  assert_true(t.find("Cap Item") is None, msg="non-trigger capsule menu closes")

  // 2. Plain button opening pick_node uses standard FromBeside without morph
  let (bx, by, bw, bh) = btn_ref.val.unwrap().placed_window_now()
  t.press_at(bx + bw * 0.5, by + bh * 0.5)
  t.release(bx + bw * 0.5, by + bh * 0.5)
  t.run_for(@motion.pop_ms * 0.3)
  let mid_glass = t.drawn_glass()
  assert_eq(mid_glass.length(), 2, msg="plain button pick emits capsule + 1 pick glass")
  t.run_for(@motion.pop_ms)
  let rest_glass = t.drawn_glass()
  assert_true(mid_glass[1].3 / rest_glass[1].3 >= 0.96, msg="plain pick keeps FromBeside 0.97..1.0 scale")
  t.key(@ui.key_escape)
  t.run_for(@motion.pop_out_ms)
  assert_true(t.find("Plain 1") is None, msg="plain pick closes after pop_out_ms")
  assert_eq(t.audit(), [], msg="plain pick post-close audit clean")
}

///|
test "MBUI_REDUCE_MOTION=1 skips pill_morph on bar_pill_group_node panel_node" {
  defer {
    @ui.set_glass_solid(None)
    set_dark(None)
    presenters_reset()
  }
  presenters_reset()
  set_words(fn(key, _) { key })
  let t = @ui.Tester::new(
    fn(_c) {  },
    w=900.0,
    h=640.0,
    dark=false,
    platform=0,
    env=[("MBUI_REDUCE_MOTION", "1")],
  )
  set_dark(Some(false))
  @ui.set_glass_solid(None)
  let info_ref : Ref[@view.View?] = Ref(None)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(page) {
      page.grow(Is(1.0)).padding(Is((64.0, 24.0, 64.0, 64.0))).ground(By(fn() { theme().p.bg })) |> ignore
      page.box(fn(bar) {
        bar.row(Is(true)).gap(Is(6.0)).lies_along(Is(End)) |> ignore
        bar_pill_group_node(bar, height=36.0, pad=2.0, gap=2.0, fn(k) {
          let info = icon_button_node(k, "info", fn() { "Info" }, fn() {
            let anchor = info_ref.val.unwrap()
            panel_nodes(
              "Chat Info",
              fn(body, _close) {
                body.box(fn(w) {
                  words_node(w, fn() { "Reduced Motion Panel" }, fn() { paragraph }) |> ignore
                })
                |> ignore
              },
              from=Node(anchor),
              along=End,
            )
          })
          info_ref.val = Some(info)
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
    presented_nodes(root)
  })
  t.draw()
  assert_eq(t.drawn_glass().length(), 1, msg="1 resting pill before open")
  let (ix, iy, iw, ih) = info_ref.val.unwrap().placed_window_now()
  t.press_at(ix + iw * 0.5, iy + ih * 0.5)
  t.release(ix + iw * 0.5, iy + ih * 0.5)
  t.draw()
  assert_true(t.find("Reduced Motion Panel") is Some(_), msg="reduced-motion panel visible immediately")
  assert_eq(t.drawn_glass().length(), 2, msg="reduced-motion keeps trigger pill + panel both visible (no morph hijack)")
  assert_eq(t.audit(), [], msg="reduced-motion open audit clean")
  t.key(@ui.key_escape)
  t.run_for(@motion.pop_out_ms)
  assert_true(t.find("Reduced Motion Panel") is None, msg="reduced-motion panel closes in pop_out_ms without 610ms hold")
  assert_eq(t.drawn_glass().length(), 1, msg="1 resting pill after reduced-motion close")
  assert_eq(t.audit(), [], msg="reduced-motion post-close audit clean")
}

///|
test "popover closing after its trigger pill unmounted still enters is_closing and shrinks on the next frame" {
  defer {
    @ui.set_glass_solid(None)
    set_dark(None)
    presenters_reset()
  }
  presenters_reset()
  set_words(fn(key, _) { key })
  let t = @ui.Tester::new(fn(_c) {  }, w=900.0, h=640.0, dark=false, platform=0)
  set_dark(Some(false))
  @ui.set_glass_solid(None)
  let show_bar = @signals.signal(true)
  let trig_ref : Ref[@view.View?] = Ref(None)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(page) {
      page.grow(Is(1.0)).padding(Is((64.0, 24.0, 64.0, 64.0))).ground(By(fn() { theme().p.bg })) |> ignore
      page.show(fn() { show_bar.get() }, at_once=true, fn(bar_wrap) {
        bar_wrap.row(Is(true)).gap(Is(6.0)).lies_along(Is(End)) |> ignore
        bar_pill_group_node(bar_wrap, height=36.0, pad=2.0, gap=2.0, fn(k) {
          let btn = icon_button_node(k, "info", fn() { "Info" }, fn() {
            let anchor = trig_ref.val.unwrap()
            pick(
              "Workspace",
              [choice("ws1", "WS 1"), choice("ws2", "WS 2")],
              "ws1",
              fn(_) { show_bar.set(false) },
              from=Node(anchor),
              along=End,
            )
          })
          trig_ref.val = Some(btn)
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
    presented_nodes(root)
  })
  t.draw()
  let (ix, iy, iw, ih) = trig_ref.val.unwrap().placed_window_now()
  t.press_at(ix + iw * 0.5, iy + ih * 0.5)
  t.release(ix + iw * 0.5, iy + ih * 0.5)
  t.run_for(@ui.move_most_ms)
  let open_glass = t.drawn_glass()
  assert_true(open_glass.length() >= 1, msg="open pick has glass surface")
  let open_h = open_glass[open_glass.length() - 1].3
  // Clicking WS 2 unmounts the trigger pill (show_bar=false) in the same turn that pick_nodes begins leaving.
  t.click(MenuItemRadio, label="WS 2")
  t.run_for(@ui.frame_period_default * 2.0)
  let closing_glass = t.drawn_glass()
  assert_true(
    closing_glass.length() == 0 || closing_glass[closing_glass.length() - 1].3 < open_h - 1.0,
    msg="popover shrinks promptly even after trigger pill unmounted: open_h=\{open_h}, count=\{closing_glass.length()}",
  )
  t.run_for(@glass.lm_close_duration_ms)
  assert_true(t.find("WS 2") is None, msg="popover unmounts cleanly after dead-trigger close")
  assert_eq(t.audit(), [], msg="dead-trigger close audit clean")
}
