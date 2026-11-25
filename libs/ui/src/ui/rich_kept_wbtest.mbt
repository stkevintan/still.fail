// A paragraph laid out once is kept (rich.mbt layout_rich, rich_kept): asked again the same, in a width that gives it
// the same lines, it is what it was; in another width, laid out again from what any width shares of it; any of what it
// is laid out by changed, laid out anew. Over the fake host (Latin 5 px wide at size 10).

///|
fn kept_rich(runs : Array[Run]) -> Rich {
  {
    runs,
    size: 10.0,
    weight: 400,
    color: 0xFF000000L,
    line: 0.0,
    trim: false,
    wrap: true,
    link_color: 0xFF0000FFL,
    pressed_bg: 0L,
    code_color: 0L,
    code_bg: 0L,
    code_scale: 1.0,
    spacing: 0.0,
    base: 0,
    select: false,
    max_lines: 0,
    faces: 0,
    shaped_in: 0,
    cjk_override: None,
    code_cjk_override: None,
  }
}

///|
/// What a layout says of where its clusters are and its lines: compared with one made with nothing kept.
fn kept_lines(lay : RichLayout) -> (Array[Int], Array[Int], Array[Double], Double, Double) {
  (lay.line_start, lay.line_end, lay.xs, lay.w, lay.h)
}

///|
fn kept_runs() -> Array[Run] {
  [plain("one two "), bold("three"), plain(" four five six")]
}

///|
test "a paragraph asked again the same, its runs made anew, is the layout it was; a width with its lines too" {
  let _ = Tester::new(fn(_) {  }, w=300.0, h=300.0)
  rich_kept.clear()
  let a = layout_rich(kept_rich(kept_runs()), 200.0)
  assert_true(physical_equal(layout_rich(kept_rich(kept_runs()), 200.0), a))
  // (narrower, but no narrower than its widest line: the same lines)
  assert_true(physical_equal(layout_rich(kept_rich(kept_runs()), a.w + 1.0), a))
  // what nothing kept lays out
  let r = kept_rich(kept_runs())
  assert_eq(kept_lines(a), kept_lines(rich_lines(r, rich_prep(r), 200.0)))
}

///|
test "in a width that breaks it otherwise, laid out again from what every width shares; both kept" {
  let _ = Tester::new(fn(_) {  }, w=300.0, h=300.0)
  rich_kept.clear()
  let wide = layout_rich(kept_rich(kept_runs()), 1.0e9)
  let narrow = layout_rich(kept_rich(kept_runs()), 40.0)
  assert_true(narrow.line_start.length() > wide.line_start.length())
  // (its text, where it breaks: one, shared)
  assert_true(physical_equal(narrow.brk, wide.brk))
  assert_true(physical_equal(narrow.text, wide.text))
  let r = kept_rich(kept_runs())
  assert_eq(kept_lines(narrow), kept_lines(rich_lines(r, rich_prep(r), 40.0)))
  // the two widths asked in turn, as a frame measures a node and draws it: each what it was
  assert_true(physical_equal(layout_rich(kept_rich(kept_runs()), 1.0e9), wide))
  assert_true(physical_equal(layout_rich(kept_rich(kept_runs()), 40.0), narrow))
}

///|
test "a paragraph whose words, a run's style, ink, link or size changed, or whose faces were measured anew, is laid out anew" {
  let _ = Tester::new(fn(_) {  }, w=300.0, h=300.0)
  rich_kept.clear()
  let a = layout_rich(kept_rich(kept_runs()), 200.0)
  let others : Array[Rich] = [
    kept_rich([plain("one two "), bold("three"), plain(" four five sixty")]),
    kept_rich([plain("one two "), plain("three"), plain(" four five six")]),
    kept_rich([plain("one two "), { ..bold("three"), color: 0xFF00FF00L }, plain(" four five six")]),
    kept_rich([plain("one two "), link("three", "https://example.test/"), plain(" four five six")]),
    kept_rich([plain("one two "), code("three"), plain(" four five six")]),
    { ..kept_rich(kept_runs()), size: 12.0 },
    { ..kept_rich(kept_runs()), shaped_in: 1 },
  ]
  for r in others {
    let b = layout_rich(r, 200.0)
    assert_true(!physical_equal(b, a))
    assert_eq(kept_lines(b), kept_lines(rich_lines(r, rich_prep(r), 200.0)))
  }
  // the host's faces moved on: what was measured in them laid out anew
  let gen = text_cache.generation
  text_cache.generation = gen + 1
  let c = layout_rich(kept_rich(kept_runs()), 200.0)
  text_cache.generation = gen
  assert_true(!physical_equal(c, a))
}

///|
test "runs changed in place after they were laid out are not taken for the ones laid out" {
  let _ = Tester::new(fn(_) {  }, w=300.0, h=300.0)
  rich_kept.clear()
  let runs = kept_runs()
  let a = layout_rich(kept_rich(runs), 200.0)
  runs[2] = plain(" four five six seven")
  let b = layout_rich(kept_rich(runs), 200.0)
  assert_true(!physical_equal(b, a))
  assert_true(b.len > a.len)
}
