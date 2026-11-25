// chip_node height scaling with system font scale: 1.0x and 1.3x keep exact 30pt,
// 2.0x grows with zero fixed_outgrown or squeeze_faults.

///|
test "chip_node: 1.0x and 1.3x keep exact 30pt; 2.0x scales height with zero fixed_outgrown or squeeze_faults" {
  let t = @ui.Tester::new(fn(_c) {  }, w=600.0, h=200.0, platform=0)
  t.check_looks(false)
  @ui.set_view_app(
    fn(root) {
      root.row(Is(true)).lines_up(Is(Some(Start))).padding(Is((20.0, 20.0, 20.0, 20.0))).gap(Is(8.0)) |> ignore
      chip_node(root, fn() { "Filter" }, fn() {  }) |> ignore
      chip_node(root, fn() { "Capsule" }, fn() {  }, capsule=true) |> ignore
    },
    theme=ui_theme_now,
  )
  t.draw()
  assert_eq(t.get(Button, label="Filter").rect.3, 30.0, msg="1.0x chip height")
  assert_eq(t.get(Button, label="Capsule").rect.3, 30.0, msg="1.0x capsule chip height")
  assert_eq(t.fixed_outgrown(), [], msg="1.0x fixed_outgrown")
  assert_eq(t.squeeze_faults(), [], msg="1.0x squeeze_faults")
  t.set_font_scale(1.3)
  t.draw()
  assert_eq(t.get(Button, label="Filter").rect.3, 30.0, msg="1.3x chip height")
  assert_eq(t.get(Button, label="Capsule").rect.3, 30.0, msg="1.3x capsule chip height")
  assert_eq(t.fixed_outgrown(), [], msg="1.3x fixed_outgrown")
  assert_eq(t.squeeze_faults(), [], msg="1.3x squeeze_faults")
  t.set_font_scale(2.0)
  t.draw()
  let h2 = t.get(Button, label="Filter").rect.3
  assert_true(h2 > 30.0, msg="2.0x chip height grew: \{h2}")
  assert_eq(t.get(Button, label="Capsule").rect.3, h2, msg="2.0x capsule chip height matches")
  assert_eq(t.fixed_outgrown(), [], msg="2.0x fixed_outgrown")
  assert_eq(t.squeeze_faults(), [], msg="2.0x squeeze_faults")
}

///|
test "radio_chip_group/item and check_chip_node: Radio arrows & sticky selected, Checkbox toggle, focus ring, disabled" {
  let lead = @signals.signal("a")
  let lead_changes : Array[String] = []
  let side_a = @signals.signal(false)
  let side_disabled = @signals.signal(false)
  let side_changes : Array[Bool] = []
  let t = @ui.Tester::new(fn(_c) {  }, w=520.0, h=240.0, platform=0)
  t.check_looks(false)
  @ui.set_view_app(
    fn(root) {
      root.padding(Is((20.0, 20.0, 20.0, 20.0))).gap(Is(12.0)) |> ignore
      radio_chip_group(
        root,
        fn() { "Lead" },
        fn() { lead.get() },
        fn(k) {
          lead_changes.push(k)
          lead.set(k)
        },
        fn(g, rg) {
          g.row(Is(true)).gap(Is(8.0)) |> ignore
          for item in [("a", "Alpha"), ("b", "Beta"), ("c", "Gamma")] {
            let (k, name) = item
            radio_chip_item(rg, g, fn() { k }, fn() { name }, fn(v) {
              words_node(v, fn() { name }, fn() { toggle_chip_words }) |> ignore
            })
            |> ignore
          }
        },
      )
      |> ignore
      root.box(fn(row) {
        row.row(Is(true)).gap(Is(8.0)) |> ignore
        check_chip_node(
          row,
          fn() { "Sidekick A · 中" },
          fn() { side_a.get() },
          fn(v) {
            side_changes.push(v)
            side_a.set(v)
          },
          fn(v) { words_node(v, fn() { "Sidekick A" }, fn() { toggle_chip_words }) |> ignore },
          disabled=fn() { side_disabled.get() },
        )
        |> ignore
      })
      |> ignore
    },
    theme=ui_theme_now,
  )
  t.draw()
  // Radio group & Radio role.
  assert_true(t.query(RadioGroup, label="Lead") is Some(_), msg="Lead is a RadioGroup")
  assert_eq(t.get(Radio, label="Alpha").check, Some(@view.Check::On), msg="Alpha starts On")
  assert_eq(t.get(Radio, label="Beta").check, Some(@view.Check::Off), msg="Beta starts Off")
  // Re-pressing already-chosen Radio keeps it chosen with 0 changes.
  t.click(Radio, label="Alpha")
  t.draw()
  assert_eq(lead.get(), "a", msg="re-pressing chosen Radio stays selected")
  assert_eq(lead_changes, [], msg="re-pressing chosen Radio does not fire choose")
  // Tab focuses the chosen Radio, Right/Left arrow keys move selection within the group.
  t.tab()
  t.draw()
  assert_eq(t.focused().map(fn(s) { s.label }), Some("Alpha"), msg="Tab stops on chosen Radio")
  // Focus ring is drawn on the focused radio chip.
  let rings = @ui.view_tree().unwrap().drawn().filter(fn(d) { d.ring.0 != 0.0 })
  assert_true(rings.length() > 0, msg="Radio chip draws focus ring on keyboard focus")
  t.key(@ui.key_code_right)
  t.draw()
  assert_eq(lead.get(), "b", msg="Right arrow selects Beta")
  assert_eq(t.focused().map(fn(s) { s.label }), Some("Beta"), msg="Right arrow moves focus to Beta")
  t.key(@ui.key_code_left)
  t.draw()
  assert_eq(lead.get(), "a", msg="Left arrow returns to Alpha")
  assert_eq(t.focused().map(fn(s) { s.label }), Some("Alpha"), msg="Left arrow moves focus to Alpha")
  // Tab moves out of RadioGroup straight to the Checkbox chip.
  t.tab()
  t.draw()
  assert_eq(t.focused().map(fn(s) { s.label }), Some("Sidekick A · 中"), msg="Tab moves to Checkbox chip")
  // Space toggles Checkbox chip on and back off.
  t.key(@ui.key_space)
  t.draw()
  assert_eq((side_a.get(), t.get(Checkbox, label="Sidekick A · 中").check), (true, Some(@view.Check::On)), msg="Space toggles on")
  t.key(@ui.key_space)
  t.draw()
  assert_eq((side_a.get(), t.get(Checkbox, label="Sidekick A · 中").check), (false, Some(@view.Check::Off)), msg="Space toggles off")
  // Disabled Checkbox chip does not trigger.
  side_disabled.set(true)
  t.draw()
  t.click(Checkbox, label="Sidekick A · 中")
  t.draw()
  assert_eq(side_changes, [true, false], msg="disabled check_chip_node ignores clicks")
}
