// Homogeneous mono/code run batching and lazy RichPrep::breaks in rich.mbt.

///|
fn batch_test_rich(runs : Array[Run], wrap? : Bool = false, code_bg? : Int64 = 0x7676801FL) -> Rich {
  {
    runs,
    size: 13.0,
    weight: 400,
    color: 0xFF1D1D1FL,
    line: 19.0,
    trim: false,
    wrap,
    link_color: 0xFF0A84FFL,
    pressed_bg: 0L,
    code_color: 0L,
    code_bg,
    code_scale: 0.9,
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
fn batch_prep_eq(a : RichPrep, b : RichPrep) -> Unit raise {
  assert_eq(a.text, b.text)
  assert_eq(a.len, b.len)
  assert_eq(a.run_start, b.run_start)
  assert_eq(a.run_c0, b.run_c0)
  assert_eq(a.run_c1, b.run_c1)
  assert_eq(a.run_size, b.run_size)
  assert_eq(a.run_a, b.run_a)
  assert_eq(a.run_d, b.run_d)
  assert_eq(a.run_lasc, b.run_lasc)
  assert_eq(a.run_ldesc, b.run_ldesc)
  assert_eq(a.starts, b.starts)
  assert_eq(a.lens, b.lens)
  assert_eq(a.adv, b.adv)
  assert_eq(a.pre, b.pre)
  assert_eq(a.keys, b.keys)
  assert_eq(a.cu, b.cu)
  assert_eq(a.run_of, b.run_of)
  assert_eq(a.drawings.length(), b.drawings.length())
}

///|
test "highlighted mono code block batches 120+ runs into <= 5 shape calls with bit-exact RichPrep parity" {
  let _ = Tester::new(fn(_) {  }, w=400.0, h=400.0)
  let runs : Array[Run] = []
  let colors : Array[Int64] = [0xFFCF222EL, 0xFF0550AEL, 0xFF0A3069L, 0xFF6E7781L, 0xFF8250DFL]
  // 30 lines * 5 distinct tokens/line = 150 mono runs, > 1500 UTF-16 code units, ASCII + CJK + \n + \r\n
  for line in 0..<30 {
    let c0 = colors[line % colors.length()]
    let c1 = colors[(line + 1) % colors.length()]
    let c2 = colors[(line + 2) % colors.length()]
    let c3 = colors[(line + 3) % colors.length()]
    let c4 = colors[(line + 4) % colors.length()]
    let nl = if line % 5 == 0 { "\r\n" } else { "\n" }
    runs.push(@text.span("fn_tok_\{line} ", mono=true, color=c0))
    runs.push(@text.span("arg_\{line}_val", mono=true, color=c1))
    runs.push(@text.span(" = ", mono=true, color=c2))
    runs.push(@text.span("\"注释_\{line}_code_text\"", mono=true, color=c3))
    runs.push(@text.span("; // line_\{line}\{nl}", mono=true, color=c4))
  }
  assert_true(runs.length() >= 120)
  let r = batch_test_rich(runs, wrap=false)

  // Unbatched baseline shape call count
  clear_shapes()
  rich_kept.clear()
  fake_shape_calls.val = Some(0)
  let ref_prep = rich_prep(r, batch=false)
  let unbatched_calls = fake_shape_calls.val.unwrap_or(0)
  fake_shape_calls.val = None

  // Batched shape call count
  clear_shapes()
  rich_kept.clear()
  fake_shape_calls.val = Some(0)
  let batched_prep = rich_prep(r)
  let batched_calls = fake_shape_calls.val.unwrap_or(0)
  fake_shape_calls.val = None

  assert_true(unbatched_calls >= 100, msg="expected unbatched shape calls >= 100, got \{unbatched_calls}")
  assert_true(batched_calls <= 5, msg="expected batched shape calls <= 5, got \{batched_calls}")
  assert_true(batched_prep.text.length() > 1024)
  batch_prep_eq(batched_prep, ref_prep)
}

///|
test "lazy RichPrep::breaks skips UAX #14 when wrap=false and computes + caches on demand" {
  let _ = Tester::new(fn(_) {  }, w=400.0, h=400.0)
  rich_kept.clear()
  let runs : Array[Run] = [
    @text.span("let a = 1\r\n", mono=true, color=0xFFCF222EL),
    @text.span("let 中文 = 2\n", mono=true, color=0xFF0550AEL),
    @text.span("return a + 中文", mono=true, color=0xFF0A3069L),
  ]
  let r_nowrap = batch_test_rich(runs, wrap=false)
  let r_wrap = batch_test_rich(runs, wrap=true)

  let lay_nowrap = layout_rich(r_nowrap, 1.0e9)
  let prep_nowrap = rich_kept_of(r_nowrap).prep
  assert_true(prep_nowrap.brk.is_empty(), msg="wrap=false must not eagerly compute UAX #14 breaks")

  let lay_wrap = layout_rich(r_wrap, 1.0e9)
  assert_eq(lay_nowrap.line_start, lay_wrap.line_start)
  assert_eq(lay_nowrap.line_end, lay_wrap.line_end)
  assert_eq(lay_nowrap.w, lay_wrap.w)
  assert_eq(lay_nowrap.h, lay_wrap.h)
  assert_eq(lay_nowrap.line_count(), 3)

  // Single-run wrap=false also skips UAX #14 breaks
  let r_one_nowrap = batch_test_rich([@text.span("one\r\ntwo\nthree", mono=true)], wrap=false)
  let lay_one = layout_rich(r_one_nowrap, 1.0e9)
  assert_true(rich_kept_of(r_one_nowrap).prep.brk.is_empty())
  assert_eq(lay_one.line_count(), 3)

  // Calling rich_least_w lazily computes and caches prep.brk
  let least = rich_least_w(r_nowrap)
  assert_true(least > 0.0)
  assert_eq(prep_nowrap.brk.length(), prep_nowrap.starts.length())
  let cached_brk = prep_nowrap.brk
  assert_true(physical_equal(prep_nowrap.breaks(), cached_brk))
}

///|
test "mixed runs batch only compatible contiguous mono segments and fall back on cross-run ligatures" {
  let _ = Tester::new(fn(_) {  }, w=400.0, h=400.0)
  let icon : InlineDrawing = { width: 1.0, height: 1.0, baseline: 0.8, paths: [], words: [] }
  let mixed_runs : Array[Run] = [
    plain("中文前面"),
    plain("ASCII "),
    code("inline_code"),
    @text.span("tok1", mono=true, color=0xFF111111L),
    @text.span("", mono=true, color=0xFF222222L),
    @text.span(" tok2 ", mono=true, color=0xFF333333L),
    @text.span("tok3", mono=true, color=0xFF444444L),
    { ..plain("obj"), drawing: Some(icon) },
    @text.span("big1", mono=true, scale=1.2, color=0xFF111111L),
    @text.span("big2", mono=true, scale=1.2, color=0xFF222222L),
    @text.span("bold1", mono=true, weight=700, color=0xFF333333L),
    @text.span("bold2", mono=true, weight=700, color=0xFF444444L),
    plain("末尾"),
  ]
  let r_mixed = batch_test_rich(mixed_runs, wrap=true)
  clear_shapes()
  let p_batched = rich_prep(r_mixed)
  clear_shapes()
  let p_single = rich_prep(r_mixed, batch=false)
  batch_prep_eq(p_batched, p_single)

  // Cross-run ligature (FakeHost merges U+E000 into the preceding cluster) and split CRLF
  let lig_runs : Array[Run] = [
    @text.span("ab", mono=true, color=0xFF111111L),
    @text.span("\u{E000}cd", mono=true, color=0xFF222222L),
    @text.span("ef\r", mono=true, color=0xFF333333L),
    @text.span("\ngh", mono=true, color=0xFF444444L),
  ]
  let r_lig = batch_test_rich(lig_runs, wrap=false)
  clear_shapes()
  let p_lig_batched = rich_prep(r_lig)
  clear_shapes()
  let p_lig_single = rich_prep(r_lig, batch=false)
  batch_prep_eq(p_lig_batched, p_lig_single)
}
