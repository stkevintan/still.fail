// Composite font stack, 5-bit face slots (0..31), CJK segmentation, optical scaling/weight,
// autospace toggle, local preview CjkOverride, and reactive local_font_info_signal tests.

///|
test "font_v2: 5-bit face slots 0/1/15/16/17/31 have zero collision with weight 400/401" {
  let t = Tester::new(fn(c) { c.text("x") |> ignore })
  ignore(t)
  assert_eq(@hostapi.faces_most, 32)
  let slots = [0, 1, 15, 16, 17, 31]
  let keys : Map[Int64, Bool] = Map([])
  for f in slots {
    let st = @hostapi.style_face(f)
    assert_eq(@hostapi.face_of_style(st), f)
    if f > 0 {
      assert_true(face_add(f, "/fonts/slot-\{f}.ttf"))
      assert_true(face_given(f))
    }
    for w in [400, 401] {
      let style = st | @hostapi.style_italic | @hostapi.style_words
      let key = (((16.0 * 10.0).to_int() * 1000 + w).to_int64() << 13) | (style & 8191).to_int64()
      assert_false(keys.contains(key), msg="collision for slot=\{f} weight=\{w}")
      keys[key] = true
      let _ = all_metrics(16.0, w, style)
    }
  }
  assert_eq(keys.length(), slots.length() * 2)
  assert_false(face_add(32, "/fonts/oob.ttf"))
}

///|
test "font_v2: primary + CJK companion with 115% scale and weight offset" {
  let t = Tester::new(fn(c) { c.text("x") |> ignore })
  t.face_wider(@hostapi.face_ui_cjk, 0.2)
  assert_true(face_add(@hostapi.face_ui, "/fonts/primary.ttf"))
  assert_true(face_add(@hostapi.face_ui_cjk, "/fonts/cjk.ttf"))
  face_set_cjk(@hostapi.face_ui, @hostapi.face_ui_cjk, scale=1.15, weight_off=100)
  let s = shape("Hi中文", 20.0, 400)
  assert_eq(s.starts.length(), 4)
  // Latin 'H', 'i' stay at Primary size 20.0 (0.5 * 20 = 10.0)
  assert_true((s.adv[0] - 10.0).abs() < 0.01)
  assert_true((s.adv[1] - 10.0).abs() < 0.01)
  // CJK '中', '文' use cjk_size = 23.0 + face_wider(0.2 * 23 = 4.6) = 27.6
  assert_true((s.adv[2] - 27.6).abs() < 0.01)
  assert_true((s.adv[3] - 27.6).abs() < 0.01)
}

///|
test "font_v2: mixed grapheme clusters A𠀀国󠄀，👩💻é stay intact without splitting" {
  let t = Tester::new(fn(c) { c.text("x") |> ignore })
  ignore(t)
  assert_true(face_add(@hostapi.face_ui_cjk, "/fonts/cjk.ttf"))
  face_set_cjk(@hostapi.face_ui, @hostapi.face_ui_cjk, scale=1.1, weight_off=0)
  // A + U+20000 (surrogate pair) + 国+IVS(U+E0100) + ， + 👩‍💻(ZWJ) + e+combining acute
  let text = "A\u{20000}\u{56FD}\u{E0100}\u{FF0C}\u{1F469}\u{200D}\u{1F4BB}e\u{0301}"
  let s = shape(text, 16.0, 400)
  let expected_gbs = @text.graphemes(text)
  assert_eq(s.starts.length(), expected_gbs.length() - 1)
  for i in 0..<s.starts.length() {
    assert_eq(s.starts[i], expected_gbs[i])
    assert_eq(s.lens[i], expected_gbs[i + 1] - expected_gbs[i])
  }
}

///|
test "font_v2: ambiguous punctuation routes it's to Primary and 说：“好” to CJK" {
  let t = Tester::new(fn(c) { c.text("x") |> ignore })
  t.face_wider(@hostapi.face_ui_cjk, 0.25)
  assert_true(face_add(@hostapi.face_ui_cjk, "/fonts/cjk.ttf"))
  face_set_cjk(@hostapi.face_ui, @hostapi.face_ui_cjk, scale=1.0, weight_off=0)
  // English context: ’ (U+2019) stays in Primary (no +0.25em from face_ui_cjk)
  let en = shape("it\u{2019}s", 16.0, 400)
  assert_eq(en.starts.length(), 4)
  assert_true((en.adv[2] - 8.0).abs() < 0.01)
  // Chinese context: “ (U+201C) and ” (U+201D) route to CJK companion (gets +0.25em = +4.0)
  let zh = shape("说：\u{201C}好\u{201D}", 16.0, 400)
  assert_eq(zh.starts.length(), 5)
  // ‘“’ at index 2 is in CJK companion -> base 8.0 (c<0x2E80) + 4.0 wider = 12.0
  assert_true((zh.adv[2] - 12.0).abs() < 0.01)
  assert_true((zh.adv[4] - 12.0).abs() < 0.01)
}

///|
test "font_v2: web_lines=true scans full paragraph for enlarged CJK on line 2" {
  let t = Tester::new(fn(c) { c.text("x") |> ignore })
  ignore(t)
  set_web_lines(true)
  assert_true(face_add(@hostapi.face_ui_cjk, "/fonts/cjk.ttf"))
  face_set_cjk(@hostapi.face_ui, @hostapi.face_ui_cjk, scale=1.15, weight_off=0)
  // line_metrics with web_lines=true takes max(primary, cjk_scaled).round() when scale != 1.0
  let (la, ld) = line_metrics(20.0, 400, false)
  let (ca, cd) = line_metrics(20.0, 400, true)
  assert_true(ca > la && cd >= ld)
  // Full paragraph scan (0..<n) under web_lines=true: CJK on line 2 produces identical line metrics to CJK on line 1
  // and grows total box height so enlarged CJK glyphs are not clipped at the bottom edge.
  let latin_only = layout_text("hello\nworld", 20.0, 400, 100.0, true, line=20.0)
  let line1_cjk = layout_text("中文\nworld", 20.0, 400, 100.0, true, line=20.0)
  let line2_cjk = layout_text("hello\n中文", 20.0, 400, 100.0, true, line=20.0)
  assert_eq(line2_cjk.ascent, line1_cjk.ascent)
  assert_eq(line2_cjk.h, line1_cjk.h)
  assert_true(line2_cjk.h > latin_only.h)
  assert_true(line2_cjk.h >= 20.0 + ca + cd)
}

///|
test "font_v2: RTL full-width bracket mirrors while preserving CJK companion" {
  let t = Tester::new(fn(c) { c.text("x") |> ignore })
  t.face_wider(@hostapi.face_ui_cjk, 0.2)
  assert_true(face_add(@hostapi.face_ui_cjk, "/fonts/cjk.ttf"))
  face_set_cjk(@hostapi.face_ui, @hostapi.face_ui_cjk, scale=1.1, weight_off=0)
  // Arabic word followed by full-width parentheses （）
  let s = shape("\u{0645}\u{0631}\u{062D}\u{0628}\u{0627}\u{FF08}\u{FF09}", 20.0, 400)
  assert_true(s.bidi is Some(_))
  // Full-width '(' is at the penultimate cluster; its advance should reflect CJK companion (22.0 + 4.4 = 26.4)
  // and its glyph key must be the mirrored '）' (U+FF09) in the CJK companion font (different from unmirrored '（').
  let n = s.starts.length()
  assert_true(n >= 3)
  assert_true((s.adv[n - 2] - 26.4).abs() < 0.01)
  let mirrored_close = shape("\u{FF09}", 20.0, 400)
  let unmirrored_open = shape("\u{FF08}", 20.0, 400)
  assert_eq(s.keys[n - 2], mirrored_close.keys[0])
  assert_true(s.keys[n - 2] != unmirrored_open.keys[0])
}

///|
test "font_v2: style_serif is exempt from UI CJK companion; textCjk ExplicitNone and Inherit+override" {
  let t = Tester::new(fn(c) { c.text("x") |> ignore })
  ignore(t)
  assert_true(face_add(@hostapi.face_ui_cjk, "/fonts/ui-cjk.ttf"))
  face_set_cjk(@hostapi.face_ui, @hostapi.face_ui_cjk, scale=1.0, weight_off=0)
  // style_serif (alone and combined with style_words in reader mode) must NOT pick up face_ui's CJK companion
  assert_eq(effective_cjk(@hostapi.style_serif, None), None)
  assert_eq(effective_cjk(@hostapi.style_serif | @hostapi.style_words, None), None)
  // Default face_text inherits face_ui's CJK companion
  assert_eq(faces_style(true, 0), 0)
  assert_eq(effective_cjk(@hostapi.style_words, None), Some((@hostapi.face_ui_cjk, 1.0, 0)))
  // Astra R3 point 1: face_text not given, inherits ui CJK, but overrides scale -> sets style_words!
  face_set_cjk_inherit(@hostapi.face_text, scale_override=1.15)
  assert_eq(faces_style(true, 0), @hostapi.style_words)
  assert_eq(effective_cjk(@hostapi.style_words, None), Some((@hostapi.face_ui_cjk, 1.15, 0)))
  // textCjk = ExplicitNone breaks inheritance from uiCjk
  face_set_cjk_none(@hostapi.face_text)
  assert_eq(faces_style(true, 0), @hostapi.style_words)
  assert_eq(effective_cjk(@hostapi.style_words, None), None)
}

///|
test "font_v2: FontShapes cache key uses integer scale_pct (100% -> 105% -> 100% reuses first cache)" {
  let t = Tester::new(fn(c) { c.text("x") |> ignore })
  ignore(t)
  assert_true(face_add(@hostapi.face_ui_cjk, "/fonts/cjk.ttf"))
  let ov100 : @view.CjkOverride = { face: @hostapi.face_ui_cjk, scale: 1.0, weight_off: 0 }
  let ov105 : @view.CjkOverride = { face: @hostapi.face_ui_cjk, scale: 1.05, weight_off: 0 }
  let _ = shape("中文ABC", 16.0, 400, cjk_override=Some(ov100))
  let count1 = text_cache.fonts.length()
  let _ = shape("中文ABC", 16.0, 400, cjk_override=Some(ov105))
  let count2 = text_cache.fonts.length()
  assert_eq(count2, count1 + 1)
  let _ = shape("中文ABC", 16.0, 400, cjk_override=Some(ov100))
  // Reused first FontShapes entry: no 3rd bucket created
  assert_eq(text_cache.fonts.length(), count2)
}

///|
test "font_v2: cjk_autospace toggle controls here, by_host cross-segment, and rich cross-run spacing" {
  let t = Tester::new(fn(c) { c.text("x") |> ignore })
  t.words_spaced_here()
  let on_adv = shape("中a", 16.0, 400).adv
  assert_true((on_adv[0] - 18.0).abs() < 0.01)
  set_cjk_autospace(false)
  assert_false(cjk_autospace())
  let off_adv = shape("中a", 16.0, 400).adv
  assert_true((off_adv[0] - 16.0).abs() < 0.01)
  // Re-enable and verify by_host cross-segment spacing with CJK companion
  set_cjk_autospace(true)
  t.words_spaced_here(by_host=true)
  assert_true(face_add(@hostapi.face_ui_cjk, "/fonts/cjk.ttf"))
  face_set_cjk(@hostapi.face_ui, @hostapi.face_ui_cjk, scale=1.0, weight_off=0)
  let seg_on = shape("中a", 16.0, 400).adv
  assert_true((seg_on[0] - 18.0).abs() < 0.01)
  set_cjk_autospace(false)
  let seg_off = shape("中a", 16.0, 400).adv
  assert_true((seg_off[0] - 16.0).abs() < 0.01)
}

///|
test "font_v2: local preview CjkOverride updates Rich without triggering words_forgotten" {
  let ov : @signals.Signal[@view.CjkOverride?] = @signals.signal(None)
  let t = Tester::tree(fn(root) {
    root.lines_up(Is(Some(Start))) |> ignore
    root.box(fn(w) {
      w
      .words_runs(Is([@text.span("Hello 中文")]))
      .words_look(Is(@view.words_plain.one_line()))
      .runs_look(By(fn() { { ..@view.runs_plain, cjk: ov.get() } }))
      |> ignore
    })
    |> ignore
  })
  assert_true(face_add(@hostapi.face_ui_cjk, "/fonts/cjk.ttf"))
  t.run_for(0.0)
  let w0 = t.rect_of("Hello 中文").unwrap().2
  let gen0 = words_shaped_in.untracked()
  // Dragging slider / hovering CJK preview: zero words_forgotten!
  ov.set(Some({ face: @hostapi.face_ui_cjk, scale: 1.15, weight_off: 0 }))
  t.draw()
  assert_eq(words_shaped_in.untracked(), gen0)
  let w1 = t.rect_of("Hello 中文").unwrap().2
  assert_true(w1 > w0)
}

///|
test "font_v2: local_font_info background completion auto-refreshes UI signal with zero input" {
  let t = Tester::tree(fn(root) {
    root.box(fn(w) {
      w.words(By(fn() {
        let info = local_font_info_signal()
        if info == "" { "loading" } else { "ready:" + info }
      }))
      |> ignore
    })
    |> ignore
  })
  t.run_for(0.0)
  assert_true(t.rect_of("loading") is Some(_))
  // Background GCD scan finishes and calls mb_host_request_frame() while mouse is idle
  t.set_local_font_info("[{\"name\":\"PingFang SC\",\"cjk\":true}]")
  t.draw()
  assert_true(t.rect_of("ready:[{\"name\":\"PingFang SC\",\"cjk\":true}]") is Some(_))
}

///|
test "font_v2: Rich cjk_override and code_cjk_override stay isolated between prose and inline code" {
  let t = Tester::new(fn(c) { c.text("x") |> ignore })
  ignore(t)
  assert_true(face_add(@hostapi.face_text_cjk, "/fonts/text_cjk.ttf"))
  assert_true(face_add(@hostapi.face_code_cjk, "/fonts/code_cjk.ttf"))
  let base_runs = [@text.span("正文中文 "), @text.code("代码中文")]
  let make_rich = fn(cjk_override : @view.CjkOverride?, code_cjk_override : @view.CjkOverride?) -> Rich {
    {
      runs: base_runs,
      size: 16.0,
      weight: 400,
      color: 0xFFFFFFFFL,
      line: 22.0,
      trim: false,
      wrap: false,
      link_color: 0L,
      pressed_bg: 0L,
      code_color: 0L,
      code_bg: 0L,
      code_scale: 1.0,
      spacing: 0.0,
      base: 0,
      select: false,
      max_lines: 0,
      faces: faces_style(true, 0),
      shaped_in: words_shaped_in.untracked(),
      cjk_override,
      code_cjk_override,
    }
  }
  let run_w = fn(p : RichPrep, k : Int) -> Double {
    let mut sum = 0.0
    for c in p.run_c0[k]..<p.run_c1[k] {
      sum = sum + p.adv[c]
    }
    sum
  }
  let p_base = rich_prep(make_rich(None, None))
  let prose_base = run_w(p_base, 0)
  let code_base = run_w(p_base, 1)

  // Setting only cjk_override scales prose CJK only; inline code stays unchanged
  let p_prose = rich_prep(
    make_rich(Some({ face: @hostapi.face_text_cjk, scale: 1.25, weight_off: 0 }), None),
  )
  assert_true(run_w(p_prose, 0) > prose_base + 1.0)
  assert_true((run_w(p_prose, 1) - code_base).abs() < 0.01)

  // Setting only code_cjk_override scales inline code CJK only; prose stays unchanged
  let p_code = rich_prep(
    make_rich(None, Some({ face: @hostapi.face_code_cjk, scale: 1.25, weight_off: 0 })),
  )
  assert_true((run_w(p_code, 0) - prose_base).abs() < 0.01)
  assert_true(run_w(p_code, 1) > code_base + 1.0)
}

///|
test "font_v2: composite seg_buf does not alias shape_widths part_buf for multi-run primary segments" {
  let t = Tester::new(fn(c) { c.text("x") |> ignore })
  ignore(t)
  assert_true(face_add(@hostapi.face_ui_cjk, "/fonts/cjk.ttf"))
  face_set_cjk(@hostapi.face_ui, @hostapi.face_ui_cjk, scale=1.1, weight_off=0)
  for sample in ["it\u{2019}s\u{1100}中", "10\u{33A1} room, it\u{2019}s big"] {
    let s = shape(sample, 16.0, 400)
    let gbs = @text.graphemes(sample)
    assert_eq(s.starts.length(), gbs.length() - 1)
    for i in 0..<s.starts.length() {
      assert_eq(s.starts[i], gbs[i])
      assert_eq(s.lens[i], gbs[i + 1] - gbs[i])
      if sample.at(s.starts[i]).to_int() != 32 {
        assert_true(s.keys[i] >= 0)
      }
    }
  }
}

///|
test "font_v2: rich_zoomed_keys at 2x preserves local CjkOverride glyph keys" {
  let t = Tester::new(fn(c) { c.text("x") |> ignore })
  ignore(t)
  assert_true(face_add(@hostapi.face_text_cjk, "/fonts/text_cjk.ttf"))
  let ov : @view.CjkOverride = { face: @hostapi.face_text_cjk, scale: 1.15, weight_off: 0 }
  let make_rich = fn(cjk_override : @view.CjkOverride?) -> Rich {
    {
      runs: [@text.span("中文")],
      size: 16.0,
      weight: 400,
      color: 0xFFFFFFFFL,
      line: 22.0,
      trim: false,
      wrap: false,
      link_color: 0L,
      pressed_bg: 0L,
      code_color: 0L,
      code_bg: 0L,
      code_scale: 1.0,
      spacing: 0.0,
      base: 0,
      select: false,
      max_lines: 0,
      faces: faces_style(true, 0),
      shaped_in: words_shaped_in.untracked(),
      cjk_override,
      code_cjk_override: None,
    }
  }
  let r_ov = make_rich(Some(ov))
  let lay_ov = layout_rich(r_ov, 400.0)
  words_zoom.val = 2.0
  let k_ov = rich_zoomed_keys(r_ov, lay_ov).unwrap()
  words_zoom.val = 1.0
  assert_eq(k_ov.length(), 2)
  assert_true(k_ov[0] >= 0)
  // Verify the 2x zoomed shaping bucket actually carried the local CjkOverride (slot + 115% scale)
  let has_2x_cjk = text_cache.fonts.iter().any(fn(f) {
    (f.size - 32.0).abs() < 0.01 && f.cjk_slot == @hostapi.face_text_cjk && f.cjk_scale_pct == 115
  })
  assert_true(has_2x_cjk)
}

///|
test "font_v2: web_lines=true Rich 115% CJK fits final line without clipping; 100%/0 has zero height regression" {
  let t = Tester::new(fn(c) { c.text("x") |> ignore })
  ignore(t)
  set_web_lines(true)
  assert_true(face_add(@hostapi.face_ui_cjk, "/fonts/cjk.ttf"))
  let make_rich = fn(line : Double) -> Rich {
    {
      runs: [@text.span("hello\n中文")],
      size: 20.0,
      weight: 400,
      color: 0xFFFFFFFFL,
      line,
      trim: false,
      wrap: true,
      link_color: 0L,
      pressed_bg: 0L,
      code_color: 0L,
      code_bg: 0L,
      code_scale: 1.0,
      spacing: 0.0,
      base: 0,
      select: false,
      max_lines: 0,
      faces: 0,
      shaped_in: words_shaped_in.untracked(),
      cjk_override: None,
      code_cjk_override: None,
    }
  }
  // (b) 100%/0 default companion with tight line=18 must match no-companion height identically (zero-pixel regression)
  let plain_none = layout_text("hello\n中文", 20.0, 400, 200.0, true, line=18.0)
  let rich_none = layout_rich(make_rich(18.0), 200.0)
  face_set_cjk(@hostapi.face_ui, @hostapi.face_ui_cjk, scale=1.0, weight_off=0)
  let plain_100 = layout_text("hello\n中文", 20.0, 400, 200.0, true, line=18.0)
  let rich_100 = layout_rich(make_rich(18.0), 200.0)
  assert_eq(plain_100.h, plain_none.h)
  assert_eq(rich_100.h, rich_none.h)
  // (a) 115% enlarged companion in Rich with line=20 must accommodate final line ca + cd without clipping
  face_set_cjk(@hostapi.face_ui, @hostapi.face_ui_cjk, scale=1.15, weight_off=0)
  let (ca, cd) = line_metrics(20.0, 400, true)
  let rich_115 = layout_rich(make_rich(20.0), 200.0)
  assert_true(rich_115.h >= 20.0 + ca + cd)
}

///|
test "font_v2: web_lines=true Rich prose without CJK + inline code 115% CJK preserves final-line height" {
  let t = Tester::new(fn(c) { c.text("x") |> ignore })
  ignore(t)
  set_web_lines(true)
  assert_true(face_add(@hostapi.face_code_cjk, "/fonts/code-cjk.ttf"))
  let make_mixed = fn(code_cjk_ov : @view.CjkOverride?) -> Rich {
    {
      runs: [@text.span("x"), @text.span("中文", code=true)],
      size: 20.0,
      weight: 400,
      color: 0xFFFFFFFFL,
      line: 20.0,
      trim: false,
      wrap: true,
      link_color: 0L,
      pressed_bg: 0L,
      code_color: 0L,
      code_bg: 0L,
      code_scale: 1.0,
      spacing: 0.0,
      base: 0,
      select: false,
      max_lines: 0,
      faces: 0,
      shaped_in: words_shaped_in.untracked(),
      cjk_override: None,
      code_cjk_override: code_cjk_ov,
    }
  }
  // 100% inline-code CJK has zero height regression vs no override
  let base_lay = layout_rich(make_mixed(None), 200.0)
  let ov100 = layout_rich(make_mixed(Some({ face: @hostapi.face_code_cjk, scale: 1.0, weight_off: 0 })), 200.0)
  assert_eq(ov100.h, base_lay.h)
  // 115% inline-code CJK on a line whose prose has extra=0 must include run_extra so h >= 23.0 (no 1pt clipping)
  let ov115 = layout_rich(make_mixed(Some({ face: @hostapi.face_code_cjk, scale: 1.15, weight_off: 0 })), 200.0)
  assert_true(ov115.h >= 23.0, msg="ov115.h=\{ov115.h} base=\{base_lay.h}")
}

///|
test "font_v2: slot 7 consecutive family switch evicts slot-7 rich_kept without touching slot-1 rich_kept or global generation" {
  let t = Tester::new(fn(c) { c.text("x") |> ignore })
  assert_true(face_add(@hostapi.face_ui, "/fonts/ui.ttf"))
  assert_true(face_add_family(7, "FamilyA"))
  let make_rich = fn(face : Int) -> Rich {
    {
      runs: [@text.span("Hello preview", face=Some(face))],
      size: 16.0,
      weight: 400,
      color: 0xFFFFFFFFL,
      line: 22.0,
      trim: false,
      wrap: true,
      link_color: 0L,
      pressed_bg: 0L,
      code_color: 0L,
      code_bg: 0L,
      code_scale: 1.0,
      spacing: 0.0,
      base: 0,
      select: false,
      max_lines: 0,
      faces: 0,
      shaped_in: words_shaped_in.untracked(),
      cjk_override: None,
      code_cjk_override: None,
    }
  }
  let r1 = make_rich(@hostapi.face_ui)
  let r7 = make_rich(7)
  let lay1_before = layout_rich(r1, 300.0)
  let lay7_a = layout_rich(r7, 300.0)
  let key1 = rich_key(r1)
  let key7 = rich_key(r7)
  assert_true(rich_kept.contains(key1))
  assert_true(rich_kept.contains(key7))
  let gen_before = words_shaped_in.untracked()
  let forgotten_before = words_forgotten_count()
  // Switch slot 7 to a wider family B (global generation does NOT bump)
  t.face_wider(7, 0.25)
  face_clear(7)
  assert_true(face_add_family(7, "FamilyB"))
  assert_eq(words_shaped_in.untracked(), gen_before)
  assert_eq(words_forgotten_count(), forgotten_before)
  // Slot-7 rich_kept was evicted; slot-1 rich_kept stayed intact!
  assert_false(rich_kept.contains(key7))
  assert_true(rich_kept.contains(key1))
  // Re-laying out slot 7 produces new wider width; slot 1 keeps identical width and glyph keys
  let lay7_b = layout_rich(r7, 300.0)
  let lay1_after = layout_rich(r1, 300.0)
  assert_true(lay7_b.w > lay7_a.w + 1.0, msg="lay7_a=\{lay7_a.w} lay7_b=\{lay7_b.w}")
  assert_eq(lay1_after.w, lay1_before.w)
  assert_eq(lay1_after.keys, lay1_before.keys)
}

///|
test "font_v2: web_lines=false non-CJK inline code overflow does not inflate last-line run_extra" {
  let _t = Tester::new(fn(c) { c.text("x") |> ignore })
  set_web_lines(false)
  let r : Rich = {
    runs: [@text.plain("alpha "), @text.code("inline_code")],
    size: 16.0,
    weight: 400,
    color: 0xFFFFFFFFL,
    // Tight line height (< ascent + descent) so set_line returns non-zero extra when room < 0
    line: 14.0,
    trim: false,
    wrap: true,
    link_color: 0L,
    pressed_bg: 0L,
    code_color: 0xFFFFFFFFL,
    code_bg: 0L,
    code_scale: 1.0,
    spacing: 0.0,
    base: 0,
    select: false,
    max_lines: 0,
    faces: 0,
    shaped_in: words_shaped_in.untracked(),
    cjk_override: None,
    code_cjk_override: None,
  }
  let lay = layout_rich(r, 400.0)
  for rx in lay.run_extra {
    assert_eq(rx, 0.0)
  }
  // Paragraph height equals line height + base extra only (never inflated by per-run non-CJK extra).
  let (_, _, base_extra) = set_line(14.0, lay.run_a[0], lay.run_d[0], g().scale, false)
  assert_eq(lay.h, lay.line_h[0] + base_extra)
}

///|
test "font_v2: preview slot switch updates affected tracks table widths without bumping words_redone or evicting virtual list offscreen heights" {
  let items = Array::makei(40, fn(i) { "row-\{i}" })
  let measured : Array[Int] = []
  let t = Tester::new(fn(c) { c.text("x") |> ignore }, w=400.0, h=220.0)
  let scroll = @view.Scroll::new()
  let tracks_ref : Ref[@view.Tracks?] = Ref(None)
  set_view_app(fn(root) {
    root.box(fn(row) {
      row.row(Is(true)) |> ignore
      row.box(fn(p) {
        p.words_runs(Is([@text.span("Preview sample", face=Some(7))])) |> ignore
      })
      |> ignore
    })
    |> ignore
    tracks_ref.val = Some(
      root.tracks(
        fn() {
          [[@view.TrackCell::Said([@text.span("Preview cell", face=Some(7))], @view.words_plain, @view.runs_plain)]]
        },
        fn() { 360.0 },
        fn(extents, _room) {
          let w = extents[0][0].whole
          ([w], w)
        },
      ),
    )
    root.box(fn(box) {
      box.height(Is(Some(160.0))) |> ignore
      box.scrolls_window(
        scroll,
        fn() { items },
        fn(row, k) {
          row.height(Is(Some(32.0))).words(Is(k)) |> ignore
          measured.push(1)
        },
        est=30.0,
      )
      |> ignore
    })
    |> ignore
  })
  assert_true(face_add_family(7, "FamilyA"))
  t.draw()
  // Scroll down so early rows go offscreen with cached heights, then settle.
  t.wheel(200.0, 120.0, -300.0)
  t.draw()
  let tree = view_tree().unwrap()
  let redone_before = tree.words_redone.untracked()
  let forgotten_before = words_forgotten_count()
  let measured_before = measured.length()
  let (_, _, w_before, _) = t.rect_of("Preview sample").unwrap()
  let col_before = (tracks_ref.val.unwrap().widths)().0[0]
  // Switch preview slot 7 to a wider family: updates preview text & tracks table width,
  // while NOT bumping words_redone or re-measuring unrelated list rows.
  t.face_wider(7, 0.35)
  face_clear(7)
  assert_true(face_add_family(7, "FamilyB"))
  t.draw()
  assert_eq(tree.words_redone.untracked(), redone_before)
  assert_eq(words_forgotten_count(), forgotten_before)
  assert_eq(measured.length(), measured_before)
  let (_, _, w_after, _) = t.rect_of("Preview sample").unwrap()
  let col_after = (tracks_ref.val.unwrap().widths)().0[0]
  assert_true(w_after > w_before + 1.0, msg="preview width before=\{w_before} after=\{w_after}")
  assert_true(col_after > col_before + 1.0, msg="tracks col width before=\{col_before} after=\{col_after}")
}
