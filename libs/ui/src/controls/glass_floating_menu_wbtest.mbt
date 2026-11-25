// Tests for unified anchored popover shell (`anchored_popover_shell`), `beside_side_for`, and iOS 27 liquid glass
// recipes (`glass_floating()`, `glass_menu()`), verifying:
// 1. Both recipes emit `liquid == true` with neutral iOS 27 light/dark tints (and passthrough custom tint).
// 2. All four anchored popovers (`menu_node`, `panel_node`, `pick_node`, `hover_panel_node`) emit exactly 1 single-layer
//    `kind == 6` liquid glass surface, outside-only float shadow (`shadow_outside == true`), zero extra `panel_ground()`
//    solid fill rects, and clean `Tester::audit()` in Light & Dark.
// 3. `MBUI_GLASS=solid` (`@ui.set_glass_solid(Some(true))`) degrades all four anchored popovers cleanly to
//    `panel_ground()` + 1 pt `panel_edge()`, zero glass instances, and clean `Tester::audit()` in Light & Dark.
// 4. `beside_side_for` returns `Bottom` for top anchors and `Top` for bottom anchors.

///|
test "glass_floating and glass_menu emit iOS 27 liquid glass recipes in light and dark" {
  for dark in [false, true] {
    let t = @ui.Tester::new(fn(_c) {  }, w=400.0, h=300.0, dark~, platform=0)
    set_dark(Some(dark))
    @ui.set_view_app(fn(root) {
      @ui.set_tree_theme(ui_theme_now)
      root.box(fn(_) {  }) |> ignore
    })
    t.draw()
    let fl = glass_floating()
    let fl_tinted = glass_floating(tint=0x11223344L)
    let mn = glass_menu()
    let expected_floating_tint = if dark { 0x20202067L } else { 0xFDFCFD67L }
    let expected_menu_tint = if dark { 0x202020A8L } else { 0xFDFCFDBFL }
    assert_eq(
      (fl.liquid, fl.blur, fl.bezel, fl.refraction, fl.tint, fl.adaptive),
      (true, 2.2, 20.0, 28.0, expected_floating_tint, true),
    )
    assert_eq((fl_tinted.liquid, fl_tinted.tint, fl_tinted.adaptive), (true, 0x11223344L, true))
    assert_eq(
      (mn.liquid, mn.blur, mn.bezel, mn.refraction, mn.chroma, mn.tint, mn.solid, mn.adaptive),
      (true, 6.0, 20.0, 26.0, 0.03, expected_menu_tint, panel_ground(), false),
    )
  }
}

///|
test "glass_control_shadow, glass_overlay_shadow, and tab_bar_shadow emit exact light/dark values" {
  for dark in [false, true] {
    let t = @ui.Tester::new(fn(_c) {  }, w=400.0, h=300.0, dark~, platform=0)
    set_dark(Some(dark))
    @ui.set_view_app(fn(root) {
      @ui.set_tree_theme(ui_theme_now)
      root.box(fn(_) {  }) |> ignore
    })
    t.draw()
    let expected_control = if dark { (6.0, 2.0, 0x00000038L) } else { (5.0, 2.0, 0x00000010L) }
    let expected_overlay = if dark { (16.0, 6.0, 0x00000048L) } else { (14.0, 6.0, 0x00000018L) }
    let tab = tab_bar_shadow()
    assert_eq(glass_control_shadow(), expected_control)
    assert_eq(glass_overlay_shadow(), expected_overlay)
    assert_eq((tab.sigma, tab.dy, tab.color), expected_control)
  }
  set_dark(None)
}

///|
fn outside_shadows(t : @ui.Tester) -> Array[(Double, Double, Int64)] {
  let ch = fn(v : Double) { (v * 255.0).round().to_int64() }
  let out : Array[(Double, Double, Int64)] = []
  for a in t.drawn_instances() {
    if a.length() > 13 && a[5] == 2.0 && a[12] == 1.0 {
      let c = (ch(a[8]) << 24) | (ch(a[9]) << 16) | (ch(a[10]) << 8) | ch(a[11])
      out.push((a[7], a[13], c))
    }
  }
  out
}

///|
fn has_outside_shadow(t : @ui.Tester) -> Bool {
  !outside_shadows(t).is_empty()
}

///|
fn has_panel_edge(t : @ui.Tester, edge_color : Int64) -> Bool {
  let ch = fn(v : Double) { (v * 255.0).round().to_int64() }
  t.drawn_instances().iter().any(fn(a) {
    if a.length() > 15 && a[5] == 0.0 && a[6] == 1.0 {
      let c = (ch(a[12]) << 24) | (ch(a[13]) << 16) | (ch(a[14]) << 8) | ch(a[15])
      c == edge_color
    } else {
      false
    }
  })
}

///|
fn anchored_popover_tester(kind : String, dark : Bool, solid : Bool) -> @ui.Tester {
  presenters_reset()
  set_words(fn(key, _) { key })
  let t = @ui.Tester::new(fn(_c) {  }, w=900.0, h=640.0, dark~, platform=0)
  set_dark(Some(dark))
  if solid {
    @ui.set_glass_solid(Some(true))
  } else {
    @ui.set_glass_solid(None)
  }
  let opener : Ref[@view.View?] = Ref(None)
  let tips_at : Ref[@view.View?] = Ref(None)
  let tips = TipLayer::new(fn() { tips_at.val })
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(col) {
      col.grow(Is(1.0)).padding(Is((64.0, 64.0, 64.0, 64.0))).ground(By(fn() { theme().p.bg })) |> ignore
      if kind == "hover_panel" {
        let btn = button_node(col, fn() { "Hover Panel" }, fn() {  })
        opener.val = Some(btn)
        hover_panel_node(
          tips,
          btn,
          "Preview",
          fn(body, _close) {
            body.box(fn(w) {
              words_node(w, fn() { "Hover panel body" }, fn() { @ui.text_style(size=Ui, color=Fg) }) |> ignore
            })
            |> ignore
          },
          spec=hover_panel_spec(w=280.0, tall=0.0, side=Bottom, along=Start, offset=6.0),
        )
        |> ignore
      } else {
        opener.val = Some(
          button_node(col, fn() { "Open Popover" }, fn() {
            match opener.val {
              Some(b) =>
                if kind == "menu" {
                  menu(
                    [
                      Some(menu_item_of("Copy Link", fn() {  })),
                      Some(menu_item_of("Pin Message", fn() {  })),
                      None,
                      Some(menu_item_of("Delete", fn() {  })),
                    ],
                    from=Node(b),
                    along=Start,
                  )
                } else if kind == "panel" {
                  panel_nodes(
                    "Panel Title",
                    fn(body, _close) {
                      body.box(fn(w) {
                        words_node(w, fn() { "Anchored panel content" }, fn() { @ui.text_style(size=Ui, color=Fg) })
                        |> ignore
                      })
                      |> ignore
                    },
                    from=Node(b),
                    w=280.0,
                    along=Start,
                  )
                } else {
                  let choices : Array[Choice] = []
                  for i in 0..<(pick_search_from + 2) {
                    choices.push(choice("c" + i.to_string(), "Choice " + i.to_string()))
                  }
                  pick("Pick One", choices, "c0", fn(_) {  }, from=Node(b), along=Start)
                }
              None => ()
            }
          }),
        )
      }
    })
    |> ignore
    presented_nodes(root)
    tips_at.val = Some(root.box(fn(l) { l.over(Is(true)).over_all(Is(true)) |> ignore }))
  })
  t.draw()
  if kind == "hover_panel" {
    let (x, y) = t.drawn_of("Hover Panel").unwrap()
    t.move_to(x, y)
    t.run_for(hover_panel_open_ms + @ui.move_most_ms)
  } else {
    t.tap_text("Open Popover")
    t.run_for(@ui.move_most_ms)
  }
  t
}

///|
test "all four anchored popovers use single-layer liquid glass with shadow_outside and degrade cleanly under MBUI_GLASS=solid" {
  for kind in ["menu", "panel", "pick", "hover_panel"] {
    for dark in [false, true] {
      // 1. Liquid glass mode: exactly 1 kind==6 glass panel, shadow_outside=true, 0 extra shell panel_ground rects, clean audit
      let t = anchored_popover_tester(kind, dark, false)
      let glass = t.drawn_glass()
      let liquid_count = glass.filter(fn(g) { g.4 == 6 }).length()
      let shadows = outside_shadows(t)
      let expected_shadow = glass_overlay_shadow()
      let expected_solid = panel_ground()
      let has_shell_solid_fill = match glass.get(0) {
        Some(g) =>
          t
          .drawn_rects()
          .iter()
          .any(fn(r) { r.4 == expected_solid && (r.0 - g.0).abs() < 1.0 && (r.1 - g.1).abs() < 1.0 && (r.2 - g.2).abs() < 1.0 && (r.3 - g.3).abs() < 1.0 })
        None => false
      }
      let glass_audits = t.audit()
      assert_eq(
        (kind, dark, glass.length(), liquid_count, shadows, has_shell_solid_fill, glass_audits),
        (kind, dark, 1, 1, [expected_shadow], false, []),
      )

      // 2. Solid fallback mode (`MBUI_GLASS=solid`): 0 glass instances, panel_ground + 1pt panel_edge, clean audit
      let ts = anchored_popover_tester(kind, dark, true)
      let solid_glass_count = ts.drawn_glass().length()
      let has_panel_ground = ts.drawn_rects().iter().any(fn(r) { r.4 == expected_solid })
      let has_edge = has_panel_edge(ts, panel_edge())
      let solid_audits = ts.audit()
      @ui.set_glass_solid(None)
      assert_eq(
        (kind, dark, solid_glass_count, has_panel_ground, has_edge, solid_audits),
        (kind, dark, 0, true, true, []),
      )
    }
  }
}

///|
test "beside_side_for returns Bottom for top anchors and Top for bottom anchors" {
  let t = @ui.Tester::new(fn(_c) {  }, w=900.0, h=800.0, dark=false, platform=0)
  let top_anchor : Ref[@view.View?] = Ref(None)
  let bottom_anchor : Ref[@view.View?] = Ref(None)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(col) {
      col.grow(Is(1.0)).height(Is(Some(800.0))) |> ignore
      col.box(fn(top) {
        top.margin(Is((24.0, 24.0, 0.0, 0.0))).width(Is(Some(120.0))).height(Is(Some(36.0))) |> ignore
        top_anchor.val = Some(top)
      })
      |> ignore
      col.box(fn(spacer) { spacer.grow(Is(1.0)) |> ignore }) |> ignore
      col.box(fn(bot) {
        bot.margin(Is((24.0, 0.0, 0.0, 24.0))).width(Is(Some(120.0))).height(Is(Some(36.0))) |> ignore
        bottom_anchor.val = Some(bot)
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  assert_eq(beside_side_for(top_anchor.val.unwrap()), Bottom)
  assert_eq(beside_side_for(bottom_anchor.val.unwrap()), Top)
  // Custom `need`: when need is small enough to fit under bottom_anchor, Bottom is still chosen
  assert_eq(beside_side_for(bottom_anchor.val.unwrap(), need=16.0), Bottom)
}
