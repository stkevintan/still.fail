// A mark of a row where the row takes the press (check_mark_node) going between half ticked (its bar), ticked (its
// tick) and not ticked: the bar and the tick are one or the other in the box, never both, so the bar is in the box's
// middle every frame it is drawn and goes at once as the tick comes (2026-11-17: 全选 pressed with two of three accounts
// ticked had the bar pushed 11 down under the tick that came at once, mbui-check 44119674663).

///|
/// The box's ground as drawn (x, y, side) and the bar's rects (as drawn, 2 tall at most and narrower than the box).
fn check_mark_drawn(t : @ui.Tester) -> ((Double, Double, Double), Array[(Double, Double, Double, Double)]) {
  let side = theme().rows.check
  let rects = t.drawn_rects()
  let box = match rects.filter(fn(r) { r.2 == side && r.3 == side }).get(0) {
    Some(r) => (r.0, r.1, side)
    None => (0.0, 0.0, 0.0)
  }
  (box, rects.filter(fn(r) { r.3 > 0.0 && r.3 <= 2.0 && r.2 < side }).map(fn(r) { (r.0, r.1, r.2, r.3) }))
}

///|
/// A frame of 60 a second: how far apart the frames are that the walk below looks at.
let check_mark_frame_ms : Double = 1000.0 / 60.0

///|
/// `on` and `mixed` set to each of `steps` in turn, each walked a frame of 60 a second at a time to past its way; at
/// every frame the bar, if drawn, in the box's middle. What was drawn at rest after each step: (tick's pieces, bars).
fn check_mark_walk(
  on : @signals.Signal[Bool],
  mixed : @signals.Signal[Bool],
  steps : Array[(Bool, Bool)],
) -> Array[(Int, Int)] raise {
  let t = part_case(fn(b) { check_mark_node(b, fn() { on.get() }, mixed=fn() { mixed.get() }) })
  let rested = []
  for s in steps {
    on.set(s.0)
    mixed.set(s.1)
    let mut ms = 0.0
    while ms < @ui.move_most_ms + check_mark_frame_ms * 6.0 {
      t.run_for(check_mark_frame_ms)
      ms = ms + check_mark_frame_ms
      let (box, bars) = check_mark_drawn(t)
      for bar in bars {
        let off = bar.1 + bar.3 / 2.0 - (box.1 + box.2 / 2.0)
        assert_true(off.abs() <= 0.5, msg="\{Repr(s)} at \{ms}: the bar \{Repr(bar)} \{off} off the middle of \{Repr(box)}")
      }
    }
    rested.push((line_pieces(t), check_mark_drawn(t).1.length()))
  }
  rested
}

///|
test "a check mark from half ticked to ticked and back: the bar in the box's middle every frame, gone as the tick comes" {
  let on = @signals.signal(false)
  let mixed = @signals.signal(true)
  let rested = check_mark_walk(on, mixed, [(true, false), (false, true), (true, false), (false, true)])
  assert_eq(rested.map(fn(r) { (r.0 > 0, r.1) }), [(true, 0), (false, 1), (true, 0), (false, 1)])
}

///|
test "a check mark from half ticked to not ticked and back: the bar in the box's middle every frame" {
  let on = @signals.signal(false)
  let mixed = @signals.signal(true)
  let rested = check_mark_walk(on, mixed, [(false, false), (false, true), (false, false), (true, false), (false, true)])
  assert_eq(rested.map(fn(r) { (r.0 > 0, r.1) }), [(false, 0), (false, 1), (false, 0), (true, 0), (false, 1)])
}

///|
test "check_row_node via check_box_node_by: inner box and row each trigger once, hover edge, first-line note, disabled, focus" {
  let on = @signals.signal(false)
  let disabled = @signals.signal(false)
  let turns : Array[Bool] = []
  let t = @ui.Tester::new(fn(_c) {  }, w=420.0, h=220.0, platform=0)
  t.check_looks(false)
  @ui.set_view_app(
    fn(root) {
      root.padding(Is((16.0, 16.0, 16.0, 16.0))).gap(Is(8.0)) |> ignore
      button_node(root, fn() { "Before" }, fn() {  }) |> ignore
      check_row_node(
        root,
        fn() { "Sync workspace" },
        fn() { on.get() },
        fn(v) {
          turns.push(v)
          on.set(v)
        },
        note=fn() { "Keep local checkout synchronized with remote station" },
        disabled=fn() { disabled.get() },
      )
    },
    theme=ui_theme_now,
  )
  t.draw()
  // Clicking the inner checkbox triggers `turn` once.
  let box_node = t.get(Checkbox, label="Sync workspace")
  assert_eq(box_node.rect.2, theme().rows.check, msg="checkbox width tracks rows.check")
  assert_eq(box_node.rect.3, theme().rows.check, msg="checkbox height tracks rows.check")
  // First-line alignment: box vertical center aligns with title first line, above the note.
  let title_rect = t.rect_of("Sync workspace").unwrap()
  let note_rect = t.rect_of("Keep local checkout synchronized with remote station").unwrap()
  let box_mid_y = box_node.rect.1 + box_node.rect.3 / 2.0
  let title_mid_y = title_rect.1 + title_rect.3 / 2.0
  assert_true((box_mid_y - title_mid_y).abs() <= 2.0, msg="box mid \{box_mid_y} vs title mid \{title_mid_y}")
  assert_true(box_mid_y < note_rect.1, msg="box mid \{box_mid_y} above note top \{note_rect.1}")
  // Hovering unchecked box uses field_hover edge color.
  t.move_to(box_node.rect.0 + box_node.rect.2 / 2.0, box_node.rect.1 + box_node.rect.3 / 2.0)
  t.draw()
  let hovered_edges = @ui.view_tree().unwrap().drawn().filter(fn(d) {
    d.w == theme().rows.check && d.h == theme().rows.check && d.edge.1 == @ui.tree_theme().field_hover
  })
  assert_true(hovered_edges.length() > 0, msg="unchecked hovered checkbox draws field_hover edge")
  // Click inner box -> turns once (true).
  t.click(Checkbox, label="Sync workspace")
  t.draw()
  assert_eq(turns, [true], msg="clicking inner checkbox triggers turn once")
  // Click row words outside inner box -> turns once (false).
  t.tap_text("Sync workspace")
  t.draw()
  assert_eq(turns, [true, false], msg="clicking row outside checkbox triggers turn once")
  // Keyboard focus via Tab reaches the row then the inner checkbox, shows focus ring, and Space toggles once.
  t.act(Button, Focus, label="Before")
  t.tab()
  t.tab()
  t.draw()
  assert_eq(t.focused().map(fn(s) { s.label }), Some("Sync workspace"), msg="Tab focuses checkbox")
  let rings = @ui.view_tree().unwrap().drawn().filter(fn(d) { d.ring.0 != 0.0 })
  assert_true(rings.length() > 0, msg="focused check_row_node draws focus ring")
  t.key(@ui.key_space)
  t.draw()
  assert_eq(turns, [true, false, true], msg="Space toggles checkbox once")
  // Disabled blocks both inner box and row clicks.
  disabled.set(true)
  t.draw()
  t.click(Checkbox, label="Sync workspace")
  t.tap_text("Sync workspace")
  t.draw()
  assert_eq(turns, [true, false, true], msg="disabled check_row_node triggers 0 times")
}
