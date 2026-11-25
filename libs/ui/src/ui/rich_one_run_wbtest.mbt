// A paragraph of one run of words is made of its shape as it is (rich.mbt rich_prep_one): what any width shares of it
// and every width's layout of it are what rich_prep's loop over its runs makes. Over the fake host.

///|
/// What any width shares of a paragraph, as values.
fn one_prep(
  p : RichPrep,
) -> (
  (String, Array[Int], Array[Int], Array[Int], Array[Double], Array[Double], Array[Double], Array[Double], Array[Double]),
  (Array[Int], Array[Int], Array[Double], Array[Double], Array[Int], Array[Int], Array[Int], Array[Int]),
  (Int, Double, Double, Double, FixedArray[Int]?, Int),
) {
  (
    (p.text, p.run_start, p.run_c0, p.run_c1, p.run_size, p.run_a, p.run_d, p.run_lasc, p.run_ldesc),
    (p.starts, p.lens, p.adv, p.pre, p.keys, p.cu, p.brk, p.run_of),
    (
      p.len,
      p.base_asc,
      p.base_desc,
      p.extra,
      p.bidi.map(fn(b) { b.line_levels(0, p.len) }),
      p.drawings.length(),
    ),
  )
}

///|
/// Where a layout puts its clusters and its lines, as values.
fn one_lines(
  lay : RichLayout,
) -> (
  (Array[Double], Array[Int], Array[Int], Array[Int], Array[Double], Array[Double], Array[Double], Array[Double]),
  (Array[Int], Array[Double], Array[Double], Double, Double),
) {
  (
    (lay.xs, lay.line_of, lay.line_start, lay.line_end, lay.line_w, lay.line_y, lay.line_h, lay.line_base),
    (lay.lv, lay.adv, lay.pre, lay.w, lay.h),
  )
}

///|
fn one_rich(run : Run, spacing? : Double = 0.0, line? : Double = 0.0) -> Rich {
  {
    runs: [run],
    size: 10.0,
    weight: 400,
    color: 0xFF000000L,
    line,
    trim: false,
    wrap: true,
    link_color: 0xFF0000FFL,
    pressed_bg: 0L,
    code_color: 0xFF333333L,
    code_bg: 0xFFEEEEEEL,
    code_scale: 0.9,
    spacing,
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
test "a paragraph of one run of words is what the runs' loop makes of it, and laid out so in every width" {
  let _ = Tester::new(fn(_) {  }, w=300.0, h=300.0)
  let paragraphs : Array[Rich] = [
    one_rich(plain("a plain paragraph of words that wraps over several lines in a narrow width")),
    one_rich(plain("中文段落，含 English 混排、数字 123 和（全角括号）与 (half) 括号，会在窄处折行。")),
    one_rich(bold("a heading said in bold")),
    // (a code run: the room on its ground before its first cluster and after its last)
    one_rich(code("let x = 1 + 2")),
    one_rich(plain("שלום עולם and hello (world) مرحبا ١٢٣")),
    one_rich(plain("spaced out words"), spacing=1.5),
    one_rich(plain("lines given their height, ending in a break\nand another line"), line=18.0),
    one_rich(plain("")),
    one_rich(plain("x")),
  ]
  for r in paragraphs {
    let fast = rich_prep(r)
    let lp = rich_prep(r, one=false)
    assert_eq(one_prep(fast), one_prep(lp))
    for w in [1.0e9, 200.0, 80.0, 30.0] {
      assert_eq(one_lines(rich_lines(r, fast, w)), one_lines(rich_lines(r, lp, w)))
    }
  }
  // (a code run has room round it: its first cluster's advance is wider than its shape's, and none of the shape's
  // arrays written in)
  let r = one_rich(code("let x"))
  let p = rich_prep(r)
  let s = shape("let x", r.run_size(r.runs[0]), r.run_weight(r.runs[0]), style=r.run_style(r.runs[0]))
  assert_true(p.adv[0] > s.adv[0])
  assert_true(!physical_equal(p.adv, s.adv))
}

///|
test "a paragraph of several runs, or one drawn, is made by the runs' loop as before" {
  let _ = Tester::new(fn(_) {  }, w=300.0, h=300.0)
  let r = one_rich(plain("one"))
  let several = { ..r, runs: [plain("one two "), bold("three"), plain(" שלום")] }
  assert_eq(one_prep(rich_prep(several)), one_prep(rich_prep(several, one=false)))
  assert_eq(rich_prep(several).run_c0.length(), 3)
}
