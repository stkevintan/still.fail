// Tests for single-layer iOS 27 liquid glass floating button groups (`pick_bar_node`, `float_button_node`):
// 1. Default liquid glass mode in Light & Dark: exactly 1 `kind == 6` glass surface (single-layer, zero nesting),
//    outside-only float shadow (`shadow_outside == true`), zero extra solid ground fill rects on the control, and clean
//    `Tester::audit()`.
// 2. `MBUI_GLASS=solid` (`@ui.set_glass_solid(Some(true))`) fallback mode in Light & Dark: 0 glass instances, opaque
//    fallback fill (`panel_ground()` for the pick bar, `glass_floating().solid` for the round button: the capsules'
//    over the composer), 0.5pt `control_edge_w` hairline `theme().p.line` border, and clean `Tester::audit()`.
// 3. The round button's glass is the composer-top capsules' (`glass_floating()`): its liquid instance's blur, tint,
//    bezel, refraction and adaptive ink as `glass_floating()` says.

///|
fn float_control_tester(kind : String, dark : Bool, solid : Bool) -> @ui.Tester {
  presenters_reset()
  let t = @ui.Tester::new(fn(_c) {  }, w=600.0, h=400.0, dark~, platform=0)
  set_dark(Some(dark))
  @ui.set_glass_solid(if solid { Some(true) } else { None })
  @ui.set_view_app(
    fn(root) {
      root.box(fn(page) {
        page.grow(Is(1.0)).padding(Is((48.0, 48.0, 48.0, 48.0))).lines_up(Is(Some(Start))).ground(By(fn() { theme().p.bg }))
        |> ignore
        if kind == "pick_bar" {
          pick_bar_node(page, [
            { label: "引用", icon: "quote", mark: false, press: fn() {  } },
            { label: "复制", icon: "copy", mark: false, press: fn() {  } },
            { label: "全选", icon: "", mark: false, press: fn() {  } },
            { label: "多选", icon: "check-square", mark: true, press: fn() {  } },
          ])
          |> ignore
        } else {
          float_button_node(page, "arrow-down", fn() { "回到底部" }, fn() {  }, count=fn() { "3 条新消息" }) |> ignore
        }
      })
      |> ignore
    },
    theme=ui_theme_now,
  )
  t.draw()
  t.run_for(@ui.move_most_ms)
  t
}

///|
test "pick_bar_node and float_button_node use single-layer liquid glass with shadow_outside and degrade cleanly under MBUI_GLASS=solid" {
  for kind in ["pick_bar", "float_button"] {
    for dark in [false, true] {
      // 1. Default liquid glass mode
      let t = float_control_tester(kind, dark, false)
      let glass = t.drawn_glass()
      let liquid_count = glass.filter(fn(g) { g.4 == 6 }).length()
      let outside_shadow = has_outside_shadow(t)
      let expected_solid = if kind == "float_button" { glass_floating().solid } else { panel_ground() }
      if kind == "float_button" {
        let want = glass_floating()
        let ch = fn(v : Double) { (v * 255.0).round().to_int64() }
        let insts = t.drawn_instances().filter(fn(a) { a.length() > 22 && a[5] == 6.0 })
        let said = insts.map(fn(a) {
          (a[7], (ch(a[8]) << 24) | (ch(a[9]) << 16) | (ch(a[10]) << 8) | ch(a[11]), a[13], a[21], a[14] < 0.0)
        })
        assert_eq(
          (dark, said),
          (dark, [(want.blur, want.tint, want.bezel, want.refraction, want.adaptive)]),
        )
        assert_eq(
          (dark, want.blur, want.tint & 0xFFL, want.bezel, want.refraction, want.adaptive),
          (dark, 2.2, 0x67L, 20.0, 28.0, true),
        )
      }
      let has_shell_solid_fill = match glass.get(0) {
        Some(g) =>
          t
          .drawn_rects()
          .iter()
          .any(fn(r) {
            (r.4 & 0xFFL) != 0L &&
            (r.0 - g.0).abs() < 1.0 &&
            (r.1 - g.1).abs() < 1.0 &&
            (r.2 - g.2).abs() < 1.0 &&
            (r.3 - g.3).abs() < 1.0
          })
        None => false
      }
      let glass_edges = t.boxes_held().filter(fn(b) { b.border_w > 0.0 && b.w >= 20.0 })
      let glass_audits = t.audit()
      assert_eq(
        (kind, dark, glass.length(), liquid_count, outside_shadow, has_shell_solid_fill, glass_edges.length(), glass_audits),
        (kind, dark, 1, 1, true, false, 0, []),
      )

      // 2. Solid fallback mode (`MBUI_GLASS=solid`)
      let ts = float_control_tester(kind, dark, true)
      let solid_glass_count = ts.drawn_glass().length()
      let has_solid_ground = ts.drawn_rects().iter().any(fn(r) { r.4 == expected_solid })
      let solid_edges = ts
        .boxes_held()
        .filter(fn(b) { b.border_w > 0.0 && b.w >= 20.0 })
        .map(fn(b) { (b.border_w, b.border_c) })
      let solid_audits = ts.audit()
      @ui.set_glass_solid(None)
      assert_eq(
        (kind, dark, solid_glass_count, has_solid_ground, solid_edges, solid_audits),
        (kind, dark, 0, true, [(control_edge_w, theme().p.line)], []),
      )
    }
  }
  @ui.set_glass_solid(None)
  set_dark(None)
}

///|
/// A float_pill_group_node of three float_pill_item_node buttons (bell, list, arrow-down) on a page `w` by 400,
/// `platform`'s, dark or not, its glass solid or not, at rest; the capsule and the buttons.
fn float_pill_tester(
  dark : Bool,
  solid : Bool,
  platform : Int,
  pressed : Ref[Array[String]],
) -> (@ui.Tester, Ref[@view.View?], Array[@view.View]) {
  presenters_reset()
  let t = @ui.Tester::new(fn(_c) {  }, w=300.0, h=400.0, dark~, platform~)
  set_dark(Some(dark))
  @ui.set_glass_solid(if solid { Some(true) } else { None })
  let pill : Ref[@view.View?] = Ref(None)
  let items : Array[@view.View] = []
  @ui.set_view_app(
    fn(root) {
      root.box(fn(page) {
        page.grow(Is(1.0)).padding(Is((48.0, 48.0, 48.0, 48.0))).lines_up(Is(Some(Start))).ground(By(fn() { theme().p.bg }))
        |> ignore
        pill.val = Some(
          float_pill_group_node(page, fn(g) {
            for name in [("bell", "待处理"), ("list", "对话目录"), ("arrow-down", "跳到最新")] {
              let (icon, label) = name
              items.push(float_pill_item_node(g, icon, fn() { label }, fn() { pressed.val.push(label) }))
            }
          }),
        )
      })
      |> ignore
    },
    theme=ui_theme_now,
  )
  t.draw()
  t.run_for(@ui.move_most_ms)
  (t, pill, items)
}

///|
test "float_pill_group_node: one capsule of glass_floating() liquid glass round three float_pill_item_node buttons, concentric, each pressed alone, lit where pressed; solid under MBUI_GLASS=solid" {
  for dark in [false, true] {
    for platform in [0, 2] {
      let at = "dark=\{dark} platform=\{platform}"
      let pressed : Ref[Array[String]] = Ref([])
      let (t, pill, items) = float_pill_tester(dark, false, platform, pressed)
      // one liquid glass: 36 across, 3 × 32 + 2 × 2 gap + 2 × 2 pad high, glass_floating()'s make, its shadow outside
      let glass = t.drawn_glass()
      let want = glass_floating()
      let ch = fn(v : Double) { (v * 255.0).round().to_int64() }
      let said = t
        .drawn_instances()
        .filter(fn(a) { a.length() > 22 && a[5] == 6.0 })
        .map(fn(a) { (a[2], a[3], a[4], a[7], (ch(a[8]) << 24) | (ch(a[9]) << 16) | (ch(a[10]) << 8) | ch(a[11]), a[13], a[21], a[14] < 0.0) })
      assert_eq(
        (at, glass.length(), said),
        (at, 1, [(36.0, 104.0, 18.0, want.blur, want.tint, want.bezel, want.refraction, want.adaptive)]),
      )
      assert_eq((at, outside_shadows(t).map(fn(s) { (s.0, s.1, s.2) })), (at, [glass_control_shadow()]))
      // each button 32 round, 2 in from the capsule's edge, concentric with it
      let (gx, gy, _, _) = (glass[0].0, glass[0].1, glass[0].2, glass[0].3)
      let rects = items.map(fn(b) { b.placed_window_now() })
      assert_eq(
        (at, rects.map(fn(r) { (r.0 - gx, r.1 - gy, r.2, r.3) })),
        (at, [(2.0, 2.0, 32.0, 32.0), (2.0, 36.0, 32.0, 32.0), (2.0, 70.0, 32.0, 32.0)]),
      )
      assert_eq((at, t.audit()), (at, []))
      // each pressed alone; pressed down, the capsule lit there and springing, settled again once let go
      let scope = pill.val.unwrap().lent(@glass.liquid_pill_trigger_lent).unwrap()
      for i, r in rects {
        let (cx, cy) = (r.0 + r.2 / 2.0, r.1 + r.3 / 2.0)
        t.press_at(cx, cy)
        t.run_for(part_whole_ms)
        assert_eq((at, i, scope.fx.untracked().0), (at, i, Some((18.0, r.1 - gy + 16.0))))
        t.release(cx, cy)
        t.run_for(@ui.move_most_ms)
        assert_eq((at, i, scope.fx.untracked().0), (at, i, None))
      }
      assert_eq((at, pressed.val), (at, ["待处理", "对话目录", "跳到最新"]))
      // solid: no glass, glass_floating()'s solid ground and the hairline edge
      let (ts, _, _) = float_pill_tester(dark, true, platform, Ref([]))
      let solid_edges = ts
        .boxes_held()
        .filter(fn(b) { b.border_w > 0.0 && b.w >= 20.0 })
        .map(fn(b) { (b.border_w, b.border_c) })
      let solid_said = (
        ts.drawn_glass().length(),
        ts.drawn_rects().iter().any(fn(r) { r.4 == glass_floating().solid }),
        solid_edges,
        ts.audit(),
      )
      @ui.set_glass_solid(None)
      assert_eq((at, solid_said), (at, (0, true, [(control_edge_w, theme().p.line)], [])))
    }
  }
  @ui.set_glass_solid(None)
  set_dark(None)
}

///|
test "float_button_node and pick_bar_node press drives GPU spot highlight and settles cleanly" {
  let spot_of = fn(raw : Double) -> Double { if raw < 0.0 { -raw - 1.0 } else { raw } }
  for kind in ["pick_bar", "float_button"] {
    for dark in [false, true] {
      let t = float_control_tester(kind, dark, false)
      let has_spot = fn() {
        t.drawn_instances().iter().any(fn(a) { a.length() > 14 && a[5] == 6.0 && spot_of(a[14]) > 0.0 })
      }
      assert_eq(has_spot(), false, msg="\{kind} dark=\{dark}: rest must have no active GPU spot")
      let target = if kind == "pick_bar" {
        t.get(Button, label="引用")
      } else {
        t.get(Button, label="回到底部")
      }
      let (tx, ty, tw, th) = target.rect
      let (cx, cy) = (tx + tw / 2.0, ty + th / 2.0)
      t.press_at(cx, cy)
      t.run_for(part_whole_ms)
      assert_true(has_spot(), msg="\{kind} dark=\{dark}: press must drive active GPU spot")
      t.release(cx, cy)
      t.run_for(@ui.move_most_ms * 2.0)
      assert_eq(has_spot(), false, msg="\{kind} dark=\{dark}: settled must clear GPU spot")
      assert_eq(t.audit(), [])
    }
  }
  @ui.set_glass_solid(None)
  set_dark(None)
}

///|
test "page_card_node glass=true decorates both layered=true and layered=false with liquid panel glass, outside shadow, floating_host_lend, and 1pt solid fallback" {
  for layered in [true, false] {
    for dark in [false, true] {
      let at = "layered=\{layered} dark=\{dark}"
      presenters_reset()
      let host_seen : Ref[Bool] = Ref(false)
      let t = @ui.Tester::new(fn(_c) {  }, w=500.0, h=400.0, dark~, platform=0)
      set_dark(Some(dark))
      @ui.set_glass_solid(None)
      @ui.set_view_app(
        fn(root) {
          root.box(fn(page) {
            page.grow(Is(1.0)).padding(Is((24.0, 24.0, 24.0, 24.0))).ground(By(fn() { theme().p.bg })) |> ignore
            page_card_node(page, footed=true, layered~, glass=true, fn(k) {
              host_seen.val = k.lent(floating_host_lent).map(fn(h) { h.id() == k.id() }).unwrap_or(false)
              words_node(k, fn() { "已选 2 项" }, fn() { theme().rows.title }) |> ignore
              card_foot_node(k, fn(acts) {
                button_node(acts, fn() { "分享与 station" }, fn() {  }, tone=Primary) |> ignore
                button_node(acts, fn() { "停止分享" }, fn() {  }, tone=GhostDanger) |> ignore
              })
            })
          })
          |> ignore
        },
        theme=ui_theme_now,
      )
      t.draw()
      t.run_for(@ui.move_most_ms)
      let glass = t.drawn_glass()
      let liquid_count = glass.filter(fn(g) { g.4 == 6 }).length()
      assert_eq(
        (at, host_seen.val, glass.length(), liquid_count, has_outside_shadow(t), t.corner_faults(), t.audit()),
        (at, true, 1, 1, true, [], []),
      )

      // MBUI_GLASS=solid fallback: 0 glass + 1pt overlay_solid_edge + panel_ground
      presenters_reset()
      let ts = @ui.Tester::new(fn(_c) {  }, w=500.0, h=400.0, dark~, platform=0)
      set_dark(Some(dark))
      @ui.set_glass_solid(Some(true))
      @ui.set_view_app(
        fn(root) {
          root.box(fn(page) {
            page.grow(Is(1.0)).padding(Is((24.0, 24.0, 24.0, 24.0))).ground(By(fn() { theme().p.bg })) |> ignore
            page_card_node(page, footed=true, layered~, glass=true, fn(k) {
              words_node(k, fn() { "已选 2 项" }, fn() { theme().rows.title }) |> ignore
              card_foot_node(k, fn(acts) {
                button_node(acts, fn() { "分享与 station" }, fn() {  }, tone=Primary) |> ignore
              })
            })
          })
          |> ignore
        },
        theme=ui_theme_now,
      )
      ts.draw()
      ts.run_for(@ui.move_most_ms)
      let solid_edges = ts
        .boxes_held()
        .filter(fn(b) { b.border_w >= 0.9 && b.w >= 200.0 })
        .map(fn(b) { b.border_w })
      let has_ground = ts.drawn_rects().iter().any(fn(r) { r.4 == panel_ground() })
      @ui.set_glass_solid(None)
      assert_eq(
        (at, ts.drawn_glass().length(), has_ground, solid_edges, ts.corner_faults(), ts.audit()),
        (at, 0, true, [1.0], [], []),
      )
    }
  }
  @ui.set_glass_solid(None)
  set_dark(None)
}

///|
test "pick_bar_desk_node: 40pt liquid_bar_pill_glass capsule matching pick_bar_node, hairline divider for multiple actions, synchronous placed_window_now on pointer and keyboard, clean solid fallback" {
  for count in [1, 2] {
    for dark in [false, true] {
      let at = "count=\{count} dark=\{dark}"
      presenters_reset()
      let got_rects : Array[(String, (Double, Double, Double, Double))] = []
      let bar_ref : Ref[@view.View?] = Ref(None)
      let english : @signals.Signal[Bool] = @signals.signal(false)
      let t = @ui.Tester::new(fn(_c) {  }, w=500.0, h=300.0, dark~, platform=0)
      set_dark(Some(dark))
      @ui.set_glass_solid(None)
      @ui.set_view_app(
        fn(root) {
          root.box(fn(page) {
            page.grow(Is(1.0)).padding(Is((48.0, 48.0, 48.0, 48.0))).lines_up(Is(Some(Start))).ground(By(fn() { theme().p.bg }))
            |> ignore
            let actions : Array[PickBarAction] = [
              pick_bar_action(fn() { if english.get() { "Quote" } else { "引用" } }, icon="quote", fn(r) {
                got_rects.push(("引用", r))
              }),
            ]
            if count == 2 {
              actions.push(
                pick_bar_action(fn() { if english.get() { "Poke" } else { "戳一下" } }, icon="poke", fn(r) {
                  got_rects.push(("戳一下", r))
                }),
              )
            }
            bar_ref.val = Some(pick_bar_desk_node(page, actions))
          })
          |> ignore
        },
        theme=ui_theme_now,
      )
      t.draw()
      t.run_for(@ui.move_most_ms)
      assert_eq(theme().dark, dark, msg="\{at}: theme().dark")
      let bar = bar_ref.val.unwrap()
      let has_host = bar.lent(floating_host_lent).map(fn(h) { h.id() == bar.id() }).unwrap_or(false)
      let glass = t.drawn_glass()
      let liquid = glass.filter(fn(g) { g.4 == 6 })
      let want = @glass.liquid_bar_pill_glass(solid=panel_ground())
      let ch = fn(v : Double) { (v * 255.0).round().to_int64() }
      let said = t
        .drawn_instances()
        .filter(fn(a) { a.length() > 22 && a[5] == 6.0 })
        .map(fn(a) {
          (a[7], (ch(a[8]) << 24) | (ch(a[9]) << 16) | (ch(a[10]) << 8) | ch(a[11]), a[13], a[21], a[14] < 0.0)
        })
      assert_eq(
        (at, said),
        (at, [(want.blur, want.tint, want.bezel, want.refraction, want.adaptive)]),
      )
      assert_eq(
        (at, want.blur, want.bezel, want.refraction, want.adaptive),
        (at, 2.0, 14.0, 20.0, false),
      )
      assert_eq((at, has_host, glass.length(), liquid.length(), has_outside_shadow(t)), (at, true, 1, 1, true))
      assert_true((liquid[0].3 - 40.0).abs() < 0.5, msg="\{at}: height=\{liquid[0].3}")
      // Hairline vertical divider present iff count == 2
      let seps = t.drawn_rects().filter(fn(r) { (r.2 - rule_w).abs() < 0.1 && (r.3 - 16.0).abs() < 0.5 })
      assert_eq((at, seps.length()), (at, if count == 2 { 1 } else { 0 }))
      assert_eq((at, t.audit()), (at, []))

      // Reactive label update: switching language/word table updates visible words and a11y names in place
      english.set(true)
      t.draw()
      assert_true(t.find("Quote") is Some(_) && t.query(Button, label="Quote") is Some(_), msg="\{at}: updated to Quote")
      if count == 2 {
        assert_true(t.find("Poke") is Some(_) && t.query(Button, label="Poke") is Some(_), msg="\{at}: updated to Poke")
      }
      english.set(false)
      t.draw()
      assert_true(t.find("引用") is Some(_) && t.query(Button, label="引用") is Some(_), msg="\{at}: restored 引用")

      // Click triggers press_at with synchronous button rect
      let btn = t.get(Button, label=if count == 2 { "戳一下" } else { "引用" })
      t.tap(btn.rect.0 + btn.rect.2 / 2.0, btn.rect.1 + btn.rect.3 / 2.0)
      t.run_for(@ui.move_most_ms)
      assert_eq(got_rects.length(), 1)
      let (_, rect) = got_rects[0]
      assert_true((rect.0 - btn.rect.0).abs() < 1.0 && (rect.3 - 32.0).abs() < 1.0, msg="\{at}: rect=\{Repr(rect)}")

      // Keyboard activation also delivers synchronous rect
      t.key(@ui.key_tab)
      t.draw()
      t.key(@ui.key_code_enter)
      t.run_for(@ui.move_most_ms)
      assert_eq(got_rects.length(), 2, msg="\{at}: keyboard Enter fired press_at")

      // Solid fallback
      presenters_reset()
      let ts = @ui.Tester::new(fn(_c) {  }, w=500.0, h=300.0, dark~, platform=0)
      set_dark(Some(dark))
      @ui.set_glass_solid(Some(true))
      @ui.set_view_app(
        fn(root) {
          root.box(fn(page) {
            page.grow(Is(1.0)).padding(Is((48.0, 48.0, 48.0, 48.0))).lines_up(Is(Some(Start))).ground(By(fn() { theme().p.bg }))
            |> ignore
            let actions : Array[PickBarAction] = [pick_bar_action(fn() { "引用" }, icon="quote", fn(_) {  })]
            if count == 2 {
              actions.push(pick_bar_action(fn() { "戳一下" }, icon="poke", fn(_) {  }))
            }
            pick_bar_desk_node(page, actions) |> ignore
          })
          |> ignore
        },
        theme=ui_theme_now,
      )
      ts.draw()
      ts.run_for(@ui.move_most_ms)
      let solid_edges = ts
        .boxes_held()
        .filter(fn(b) { b.border_w > 0.0 && b.w >= 20.0 })
        .map(fn(b) { (b.border_w, b.border_c) })
      let has_ground = ts.drawn_rects().iter().any(fn(r) { r.4 == panel_ground() })
      @ui.set_glass_solid(None)
      assert_eq(
        (at, ts.drawn_glass().length(), has_ground, solid_edges, ts.audit()),
        (at, 0, true, [(control_edge_w, theme().p.line)], []),
      )
    }
  }
  @ui.set_glass_solid(None)
  set_dark(None)
}
