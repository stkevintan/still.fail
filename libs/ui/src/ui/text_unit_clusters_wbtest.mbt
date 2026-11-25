// unit_clusters fast path and lazy Shaped::breaks: ASCII/CJK strings skip UAX #29 / joining / bidi scans,
// single-line layout and multi-run rich_prep skip per-run UAX #14 line-break scans, and results stay identical.

///|
test "unit_clusters matches UAX #29, non-joining, and LTR-only guarantees" {
  let simple_cases = [
    "hello world 123 !@#",
    "中文测试段落，包含标点（全角）和 English 123",
    "日本語ひらがなカタカナ漢字",
    "한국어 음절 테스트",
    "line1\nline2\tindented",
    "Claude Code · Opus 5.5 · 3 分钟前",
    "“引号”——省略号…•条目 × 2 ± 1° ¥100 €50 37℃ 10‰",
    "\u{00A5}\u{00A7}\u{00B0}\u{00B1}\u{00B7}\u{00D7}\u{00F7}",
    "\u{2013}\u{2014}\u{2018}\u{2019}\u{201A}\u{201B}\u{201C}\u{201D}",
    "\u{2022}\u{2026}\u{2030}\u{2032}\u{2033}\u{20AC}\u{2103}",
  ]
  for s in simple_cases {
    assert_true(unit_clusters(s), msg="expected simple: \{s}")
    let g = @text.graphemes(s)
    assert_eq(g.length(), s.length() + 1, msg="grapheme count mismatch: \{s}")
    for i in 0..<=s.length() {
      assert_eq(g[i], i, msg="grapheme boundary \{i} mismatch: \{s}")
    }
    assert_true(@text.bidi_mixed(s) is None, msg="unexpected bidi: \{s}")
    for i in 0..<s.length() {
      assert_false(joining(s, i), msg="unexpected joining at \{i}: \{s}")
    }
  }
  let added_cps = [
    0x00A5, 0x00A7, 0x00B0, 0x00B1, 0x00B7, 0x00D7, 0x00F7, 0x2013, 0x2014, 0x2018, 0x2019, 0x201A, 0x201B, 0x201C,
    0x201D, 0x2022, 0x2026, 0x2030, 0x2032, 0x2033, 0x20AC, 0x2103,
  ]
  for cp in added_cps {
    let s = Int::unsafe_to_char(cp).to_string()
    assert_true(unit_clusters(s), msg="expected unit_clusters for U+\{cp}")
    let g = @text.graphemes(s)
    assert_eq(g, [0, 1], msg="expected single grapheme for U+\{cp}")
    assert_true(@text.bidi_mixed(s) is None, msg="unexpected bidi for U+\{cp}")
    assert_false(joining(s, 0), msg="unexpected joining for U+\{cp}")
  }
  let complex_cases = [
    "a\r\nb",
    "e\u{0301}",
    "が\u{3099}",
    "🎉 emoji",
    "שלום עולם",
    "مرحبا",
    "ไทย",
    "हिन्दी",
    "a\u{200C}b",
    "a\u{200D}b",
    "a\u{200E}b",
    "a\u{200F}b",
    "a\u{202E}b",
    "a\u{2066}b",
    "©",
    "®",
    "™",
    "\u{2194}",
  ]
  for s in complex_cases {
    assert_false(unit_clusters(s), msg="expected non-simple: \{s}")
  }
}

///|
test "lazy Shaped::breaks: nowrap and multi-run rich_prep skip per-run line_breaks, wrap computes and caches" {
  let _ = Tester::new(fn(_) {  }, w=300.0, h=300.0)
  // 1. Single-line nowrap text leaves s.brk empty even for CJK + ASCII and \r\n.
  let nowrap = "单行标题 Single Line 123"
  let tl0 = layout_text(nowrap, 14.0, 400, 120.0, false)
  assert_true(tl0.shaped.brk.is_empty())
  assert_eq(tl0.line_start.length(), 1)
  // \r\n splits into two lines without needing s.brk.
  let crlf = "first\r\nsecond"
  let tl_crlf = layout_text(crlf, 14.0, 400, 200.0, false)
  assert_true(tl_crlf.shaped.brk.is_empty())
  assert_eq(tl_crlf.line_start.length(), 2)
  // 2. Wrapping text computes s.brk lazily and reuses the cached array.
  let tl1 = layout_text(nowrap, 14.0, 400, 60.0, true)
  assert_eq(tl1.shaped.brk.length(), tl1.shaped.starts.length())
  assert_true(tl1.line_start.length() > 1)
  let brk_first = tl1.shaped.brk
  let tl2 = layout_text(nowrap, 14.0, 400, 40.0, true)
  assert_true(physical_equal(tl2.shaped.brk, brk_first))
  // 3. Multi-run rich_prep does not populate per-run s.brk, while computing paragraph breaks once.
  let run_a = "多段富文本前缀 "
  let run_b = "加粗关键词"
  let run_c = " 以及后续长内容需要折行测试"
  let r : Rich = {
    runs: [plain(run_a), bold(run_b), plain(run_c)],
    size: 14.0,
    weight: 400,
    color: 0xFF000000L,
    line: 0.0,
    trim: false,
    wrap: true,
    link_color: 0xFF0000FFL,
    pressed_bg: 0L,
    code_color: 0xFF333333L,
    code_bg: 0xFFEEEEEEL,
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
  let prep = rich_prep(r)
  assert_eq(prep.brk.length(), prep.starts.length())
  assert_true(shape(run_a, 14.0, 400).brk.is_empty())
  assert_true(shape(run_b, 14.0, 700).brk.is_empty())
  assert_true(shape(run_c, 14.0, 400).brk.is_empty())
  let lay = rich_lines(r, prep, 80.0)
  assert_true(lay.line_start.length() > 1)
}
