// What a frame hands its host to draw ahead (glyphs_ahead) as its tree is laid out: each glyph at the phase it is then
// painted at (laid_ahead), not phase 0 alone.

///|
/// A page of words as a chat's are laid out: plain words and runs of several styles, Han and Latin, wrapped, each in a
/// column at a whole number of points from the window's edge; at a size whose Han is no whole number of pixels wide at
/// any scale the test draws at, as most sizes are.
fn ahead_page(root : @view.View) -> Unit {
  root.box(fn(p) {
    p.width(Is(Some(360.0))).padding(Is((16.0, 16.0, 16.0, 16.0))) |> ignore
    p.box(fn(v) {
      v
      .width(Is(Some(328.0)))
      .words(
        Is("今天把渲染的预热改成排版之后立即派发，Latin words between them, 再看一下首帧。"),
        look={ ..@view.words_plain, size: 15.3, line: 22.0, wrap: true },
      )
      |> ignore
    })
    |> ignore
    p.box(fn(v) {
      v
      .width(Is(Some(328.0)))
      .words_runs(
        Is([
          @view.words_run("富文本里的"),
          @view.words_run("粗体段落", weight=700),
          @view.words_run(" and a code-ish run ", weight=500),
          @view.words_run("然后又回到正文，一直写到第二行以后才结束。"),
        ]),
        look={ ..@view.words_plain, size: 15.3, line: 22.0, wrap: true },
      )
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// The glyphs the frame placed (their keys with their phase), and how many of them were asked ahead at that phase, and
/// how many at phase 0.
fn ahead_hits(asked : Array[Int]) -> (Int, Int, Int) {
  let at : Map[Int, Bool] = Map([])
  for k in asked {
    at[k] = true
  }
  let mut placed = 0
  let mut hit = 0
  let mut first = 0
  for k, _ in text_cache.glyphs {
    placed = placed + 1
    if at.contains(k) {
      hit = hit + 1
    }
    if (k >> 26) == 0 {
      first = first + 1
    }
  }
  (placed, hit, first)
}

///|
test "glyphs laid out are asked ahead at the phase the frame paints them at" {
  for sc in [2.75, 3.0, 2.0] {
    let asked : Array[Int] = []
    fake_ahead.val = Some(asked)
    let t = Tester::new(fn(_c) {  }, w=400.0, h=400.0, scale=sc)
    // (Latin letters of widths of a real face's, none a whole number of pixels)
    t.latin_advances(
      FixedArray::makei(95, fn(i) { 0.45 + (i % 7).to_double() * 0.037 }),
      FixedArray::makei(95, fn(i) { 0.48 + (i % 5).to_double() * 0.041 }),
    )
    set_view_app(ahead_page)
    t.draw()
    fake_ahead.val = None
    let (placed, hit, first) = ahead_hits(asked)
    assert_true(placed > 60, msg="scale \{sc}: \{placed} placed")
    // (every glyph the frame painted was asked ahead at its own phase, before it was painted: the frame's first ask
    // is its tree's layout's)
    assert_eq(hit, placed, msg="scale \{sc}: \{hit} of \{placed} asked at their phase")
    // (where phase 0 alone was asked, most would have been drawn on the frame's thread)
    assert_true(first * 2 < placed, msg="scale \{sc}: \{first} of \{placed} at phase 0")
    // (each asked once)
    let seen : Map[Int, Bool] = Map([])
    for k in asked {
      assert_true(!seen.contains(k), msg="scale \{sc}: \{k} asked twice")
      seen[k] = true
    }
  }
}

///|
test "a glyph shaped and not laid out is asked at phase 0, once; one laid out is not asked again at phase 0" {
  let asked : Array[Int] = []
  fake_ahead.val = Some(asked)
  let _t = Tester::new(fn(_c) {  }, w=200.0, h=100.0, scale=2.75)
  // shaped alone: its glyphs at phase 0
  let s = shape("只量不排", 15.0, 400)
  glyphs_ahead()
  assert_eq(asked, s.keys.filter(fn(k) { k >= 0 }))
  // laid out: at the phases of its line, none of them again at phase 0 for having been shaped
  asked.clear()
  let tl = layout_text("排版之后 laid", 15.0, 400, 300.0, false)
  glyphs_ahead()
  fake_ahead.val = None
  let want = []
  for c, k in tl.shaped.keys {
    if k >= 0 {
      want.push(glyph_sub_at(k, tl.xs[c] + tl.shaped.pad, g().scale, 1.0))
    }
  }
  let seen : Map[Int, Bool] = Map([])
  let want = want.filter(fn(k) {
    let first = !seen.contains(k)
    seen[k] = true
    first
  })
  assert_eq(asked, want)
  assert_true(asked.iter().any(fn(k) { (k >> 26) != 0 }))
}

///|
test "between-frame event layout dispatches glyphs_ahead before next draw with zero duplicate on draw" {
  let asked : Array[Int] = []
  let show = @signals.signal(false)
  let t = Tester::new(fn(_c) {  }, w=400.0, h=400.0, scale=2.75)
  t.latin_advances(
    FixedArray::makei(95, fn(i) { 0.45 + (i % 7).to_double() * 0.037 }),
    FixedArray::makei(95, fn(i) { 0.48 + (i % 5).to_double() * 0.041 }),
  )
  set_view_app(fn(root) {
    root.laid_before_causes()
    root.box(fn(p) {
      p.width(Is(Some(360.0))).padding(Is((16.0, 16.0, 16.0, 16.0))) |> ignore
      p.show(
        fn() { show.get() },
        fn(v) {
          v
          .width(Is(Some(328.0)))
          .words(
            Is("帧间事件新增文本节点，在下一帧绘制之前就应该提前派发字形预热。"),
            look={ ..@view.words_plain, size: 15.3, line: 22.0, wrap: true },
          )
          |> ignore
        },
        at_once=true,
      )
      |> ignore
    })
    |> ignore
  })
  t.draw()
  fake_ahead.val = Some(asked)
  view_event(fn() { show.set(true) })
  let before_draw = asked.length()
  assert_true(before_draw > 15, msg="expected glyphs_ahead during between-frame event, got \{before_draw}")
  t.draw()
  fake_ahead.val = None
  let seen : Map[Int, Bool] = Map([])
  for k in asked {
    assert_true(!seen.contains(k), msg="duplicate (key, phase) dispatched across event + draw: \{k}")
    seen[k] = true
  }
  let (placed, hit, _) = ahead_hits(asked)
  assert_true(placed > 15)
  assert_eq(hit, placed, msg="\{hit} of \{placed} placed glyphs asked at their phase")
}

///|
test "heavy single-frame layout flushes glyphs_laid mid-layout without touching fresh and with zero duplicates" {
  let asked : Array[Int] = []
  let t = Tester::new(fn(_c) {  }, w=400.0, h=600.0, scale=2.75)
  t.latin_advances(
    FixedArray::makei(95, fn(i) { 0.45 + (i % 7).to_double() * 0.037 }),
    FixedArray::makei(95, fn(i) { 0.48 + (i % 5).to_double() * 0.041 }),
  )
  set_view_app(fn(_root) {  })
  t.draw()
  fake_ahead.val = Some(asked)
  // Pre-shape a second paragraph (as Flex width measurement does) before laying out the first paragraph.
  let long_b = "菜重芥姜海咸河淡鳞潜羽翔龙师火帝鸟官人皇始制文字乃服衣裳推位让国有虞陶唐"
  let shaped_b = shape(long_b, 15.3, 400)
  let fresh_before = text_cache.fresh.length()
  assert_true(fresh_before > 20)
  // > 48 distinct characters in one layout_text call triggers glyphs_laid_flush() mid-layout without draining fresh.
  let long_a = "天地玄黄宇宙洪荒日月盈昃辰宿列张寒来暑往秋收冬藏闰余成岁律吕调阳云腾致雨露结为霜金生丽水玉出昆冈剑号巨阙珠称夜光果珍李柰"
  let _ = layout_text(long_a, 15.3, 400, 328.0, true)
  let mid_count = asked.length()
  assert_true(
    mid_count >= glyphs_ahead_batch,
    msg="expected mid-layout flush >= \{glyphs_ahead_batch}, got \{mid_count}",
  )
  // text_cache.fresh must NOT have been drained by glyphs_laid_flush().
  assert_true(text_cache.fresh.length() >= fresh_before, msg="glyphs_laid_flush must not drain text_cache.fresh")
  // None of long_b's unique glyphs should have been prematurely dispatched at phase 0 before long_b is laid out.
  let asked_mid : Map[Int, Bool] = Map([])
  for k in asked {
    asked_mid[k & 0x03FFFFFF] = true
  }
  for k in shaped_b.keys {
    if k >= 0 {
      assert_false(asked_mid.contains(k), msg="shaped-only glyph \{k} must not be flushed before its layout")
    }
  }
  // Now lay out long_b (with overlapping chars from long_a too) and flush frame end with glyphs_ahead().
  let _ = layout_text("天地玄黄" + long_b, 15.3, 400, 328.0, true)
  glyphs_ahead()
  fake_ahead.val = None
  assert_true(asked.length() > mid_count, msg="expected remaining glyphs flushed after second layout")
  let seen : Map[Int, Bool] = Map([])
  for k in asked {
    assert_true(!seen.contains(k), msg="duplicate (key, phase) in single frame: \{k}")
    seen[k] = true
  }
}

///|
/// A page with non-integer-pixel padding, nested code blocks, blockquotes, and list items to verify
/// `measuring_origin_x` predicts exact subpixel phases at non-integer device scales.
fn ahead_non_int_dpi_page(root : @view.View) -> Unit {
  root.box(fn(p) {
    p.width(Is(Some(351.0))).padding(Is((16.0, 16.0, 16.0, 16.0))) |> ignore
    // 1. Padding 16pt plain text
    p.box(fn(v) {
      v
      .width(Is(Some(319.0)))
      .words(
        Is("非整数 DPI 下的正文段落，padding=16pt，验证首帧预热相位完全命中。"),
        look={ ..@view.words_plain, size: 15.3, line: 22.0, wrap: true },
      )
      |> ignore
    })
    |> ignore
    // 2. Nested code block: 16 + 14 = 30pt horizontal origin
    p.box(fn(code_box) {
      code_box.width(Is(Some(319.0))).padding(Is((14.0, 14.0, 14.0, 14.0))) |> ignore
      code_box.box(fn(v) {
        v
        .words_breaks(Is(true))
        .words_runs(
          Is([
            @text.span("fn ", mono=true, color=0xFFCF222EL),
            @text.span("render_code", mono=true, color=0xFF0550AEL),
            @text.span("(dpi: Double) {\n  let x = 30.0\n}", mono=true, color=0xFF1D1D1FL),
          ]),
          look={ ..@view.words_plain, size: 13.0, line: 19.0, wrap: false },
        )
        |> ignore
      })
      |> ignore
    })
    |> ignore
    // 3. Blockquote: Row(2pt bar + 10pt pad/gap) -> 16 + 2 + 10 = 28pt
    p.box(fn(bq) {
      bq.row(Is(true)).width(Is(Some(319.0))).gap(Is(10.0)) |> ignore
      bq.box(fn(bar) { bar.width(Is(Some(2.0))).height(Is(Some(20.0))) |> ignore }) |> ignore
      bq.box(fn(v) {
        v
        .width(Is(Some(307.0)))
        .words(
          Is("引用块里的文字在非整数缩放下同样应保持 100% 相位命中。"),
          look={ ..@view.words_plain, size: 14.5, line: 21.0, wrap: true },
        )
        |> ignore
      })
      |> ignore
    })
    |> ignore
    // 4. List item: Row(20pt marker + 8pt gap) -> 16 + 20 + 8 = 44pt
    p.box(fn(item) {
      item.row(Is(true)).width(Is(Some(319.0))).gap(Is(8.0)) |> ignore
      item.box(fn(marker) { marker.width(Is(Some(20.0))).height(Is(Some(20.0))) |> ignore }) |> ignore
      item.box(fn(v) {
        v
        .width(Is(Some(291.0)))
        .words_runs(
          Is([
            @view.words_run("列表项"),
            @view.words_run("加粗前缀 ", weight=700),
            @view.words_run("followed by body text at 44pt origin."),
          ]),
          look={ ..@view.words_plain, size: 15.0, line: 22.0, wrap: true },
        )
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
test "non-integer DPI first-frame layout hits 100% of painted subpixel glyph phases" {
  for sc in [3.6, 4.1, 2.625, 1.25, 2.75] {
    let asked : Array[Int] = []
    fake_ahead.val = Some(asked)
    let t = Tester::new(fn(_c) {  }, w=351.0, h=600.0, scale=sc)
    t.latin_advances(
      FixedArray::makei(95, fn(i) { 0.45 + (i % 7).to_double() * 0.037 }),
      FixedArray::makei(95, fn(i) { 0.48 + (i % 5).to_double() * 0.041 }),
    )
    set_view_app(ahead_non_int_dpi_page)
    t.draw()
    fake_ahead.val = None
    let (placed, hit, _) = ahead_hits(asked)
    assert_true(placed > 80, msg="scale \{sc}: expected > 80 placed glyphs, got \{placed}")
    assert_eq(hit, placed, msg="scale \{sc}: \{hit} of \{placed} glyphs hit predicted subpixel phase")
    let seen : Map[Int, Bool] = Map([])
    for k in asked {
      assert_true(!seen.contains(k), msg="scale \{sc}: duplicate (key, phase) dispatched: \{k}")
      seen[k] = true
    }
  }
}

///|
test "non-integer DPI between-frame nodes under placed ancestors hit 100% of painted subpixel phases" {
  for sc in [3.6, 4.1, 2.625, 1.25, 2.75] {
    let asked : Array[Int] = []
    let show = @signals.signal(false)
    let t = Tester::new(fn(_c) {  }, w=351.0, h=600.0, scale=sc)
    t.latin_advances(
      FixedArray::makei(95, fn(i) { 0.45 + (i % 7).to_double() * 0.037 }),
      FixedArray::makei(95, fn(i) { 0.48 + (i % 5).to_double() * 0.041 }),
    )
    set_view_app(fn(root) {
      root.laid_before_causes()
      root.box(fn(p) {
        p.width(Is(Some(351.0))).padding(Is((16.0, 16.0, 16.0, 16.0))) |> ignore
        // Placed outer container with padding 14pt
        p.box(fn(code_box) {
          code_box.width(Is(Some(319.0))).padding(Is((14.0, 14.0, 14.0, 14.0))) |> ignore
          code_box.show(
            fn() { show.get() },
            fn(v) {
              v
              .width(Is(Some(291.0)))
              .words(
                Is("帧间在已放置容器内新增代码与中文段落，验证 30pt 原点相位预测。"),
                look={ ..@view.words_plain, size: 15.3, line: 22.0, wrap: true },
              )
              |> ignore
            },
            at_once=true,
          )
          |> ignore
        })
        |> ignore
        // Placed Row with 20pt marker + 8pt gap
        p.box(fn(item) {
          item.row(Is(true)).width(Is(Some(319.0))).gap(Is(8.0)) |> ignore
          item.box(fn(marker) { marker.width(Is(Some(20.0))).height(Is(Some(20.0))) |> ignore }) |> ignore
          item.show(
            fn() { show.get() },
            fn(v) {
              v
              .width(Is(Some(291.0)))
              .words_runs(
                Is([
                  @view.words_run("新增行内"),
                  @view.words_run("高亮片段 ", weight=700),
                  @view.words_run("under placed row at 44pt."),
                ]),
                look={ ..@view.words_plain, size: 15.0, line: 22.0, wrap: true },
              )
              |> ignore
            },
            at_once=true,
          )
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    t.draw()
    fake_ahead.val = Some(asked)
    view_event(fn() { show.set(true) })
    let before_draw = asked.length()
    assert_true(before_draw > 20, msg="scale \{sc}: expected glyphs_ahead during event, got \{before_draw}")
    t.draw()
    fake_ahead.val = None
    let seen : Map[Int, Bool] = Map([])
    for k in asked {
      assert_true(!seen.contains(k), msg="scale \{sc}: duplicate (key, phase) across event + draw: \{k}")
      seen[k] = true
    }
    let (placed, hit, _) = ahead_hits(asked)
    assert_true(placed > 20, msg="scale \{sc}: expected > 20 placed glyphs, got \{placed}")
    assert_eq(hit, placed, msg="scale \{sc}: \{hit} of \{placed} glyphs hit predicted subpixel phase")
  }
}

///|
test "words_ahead matches painted quarter-pixel phases across non-integer DPI scales" {
  let look = { ..@view.words_plain, size: 15.0, line: 22.0, wrap: false }
  let unmarked = "无标记聊天标题 Home Row Title 123"
  let marked = "有状态标记的聊天标题 Marked Row 456"
  for sc in [3.6, 4.1, 2.625, 2.0, 1.0] {
    let asked : Array[Int] = []
    fake_ahead.val = Some(asked)
    let t = Tester::new(fn(_c) {  }, w=360.0, h=200.0, scale=sc)
    t.latin_advances(
      FixedArray::makei(95, fn(i) { 0.45 + (i % 7).to_double() * 0.037 }),
      FixedArray::makei(95, fn(i) { 0.48 + (i % 5).to_double() * 0.041 }),
    )
    let w1 = words_ahead(unmarked, look, 22.0, 1.0)
    let w2 = words_ahead(marked, look, 40.0, 1.0)
    words_ahead_flush()
    fake_ahead.val = None
    assert_true(w1 > 0.0 && w2 > 0.0, msg="scale \{sc}: expected positive prewarmed widths")
    set_view_app(fn(root) {
      root.box(fn(p) {
        p.width(Is(Some(360.0))) |> ignore
        p.box(fn(r1) {
          r1.padding(Is((22.0, 0.0, 0.0, 0.0))) |> ignore
          r1.box(fn(v) { v.words(Is(unmarked), look~) |> ignore }) |> ignore
        })
        |> ignore
        p.box(fn(r2) {
          r2.padding(Is((40.0, 0.0, 0.0, 0.0))) |> ignore
          r2.box(fn(v) { v.words(Is(marked), look~) |> ignore }) |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    t.draw()
    let (placed, hit, _) = ahead_hits(asked)
    assert_true(placed > 20, msg="scale \{sc}: expected > 20 placed glyphs, got \{placed}")
    assert_eq(hit, placed, msg="scale \{sc}: \{hit} of \{placed} placed glyphs hit words_ahead phase")
  }
}

///|
test "words_ahead normalizes single-line newlines to hit the same shapes and phased glyph keys" {
  let look = { ..@view.words_plain, size: 15.0, line: 22.0, wrap: false }
  let asked : Array[Int] = []
  fake_ahead.val = Some(asked)
  let t = Tester::new(fn(_c) {  }, w=360.0, h=120.0, scale=3.6)
  t.latin_advances(
    FixedArray::makei(95, fn(i) { 0.45 + (i % 7).to_double() * 0.037 }),
    FixedArray::makei(95, fn(i) { 0.48 + (i % 5).to_double() * 0.041 }),
  )
  let w = words_ahead("第一行\n第二行", look, 22.0, 1.0)
  words_ahead_flush()
  fake_ahead.val = None
  assert_true(w > 0.0)
  fake_shape_calls.val = Some(0)
  set_view_app(fn(root) {
    root.box(fn(p) {
      p.width(Is(Some(360.0))).padding(Is((22.0, 0.0, 0.0, 0.0))) |> ignore
      p.box(fn(v) { v.words(Is("第一行\n第二行"), look~) |> ignore }) |> ignore
    })
    |> ignore
  })
  t.draw()
  let shapes_during_draw = fake_shape_calls.val.unwrap_or(-1)
  fake_shape_calls.val = None
  assert_eq(shapes_during_draw, 0, msg="expected zero new shape calls after words_ahead normalized newline")
  let (placed, hit, _) = ahead_hits(asked)
  assert_true(placed >= 6, msg="expected >= 6 placed glyphs, got \{placed}")
  assert_eq(hit, placed, msg="\{hit} of \{placed} placed glyphs hit normalized words_ahead phase")
}

///|
test "words_ahead dispatches both phases for identical text at two origin_x offsets" {
  let look = { ..@view.words_plain, size: 15.0, line: 22.0, wrap: false }
  let sample = "同串双相位预热验证"
  let asked : Array[Int] = []
  fake_ahead.val = Some(asked)
  let t = Tester::new(fn(_c) {  }, w=360.0, h=200.0, scale=3.6)
  let _ = words_ahead(sample, look, 22.0, 1.0)
  let _ = words_ahead(sample, look, 40.0, 1.0)
  words_ahead_flush()
  fake_ahead.val = None
  let phases_by_base : Map[Int, Set[Int]] = Map([])
  for k in asked {
    let base = k & 0x03FFFFFF
    let phase = (k >> 26) & 3
    match phases_by_base.get(base) {
      Some(s) => s.add(phase)
      None => phases_by_base[base] = Set([phase])
    }
  }
  let mut multi_phase = 0
  for _, s in phases_by_base {
    if s.length() >= 2 {
      multi_phase = multi_phase + 1
    }
  }
  assert_true(multi_phase >= 5, msg="expected >= 5 glyphs dispatched at 2 distinct phases, got \{multi_phase}")
  set_view_app(fn(root) {
    root.box(fn(p) {
      p.width(Is(Some(360.0))) |> ignore
      p.box(fn(r1) {
        r1.padding(Is((22.0, 0.0, 0.0, 0.0))) |> ignore
        r1.box(fn(v) { v.words(Is(sample), look~) |> ignore }) |> ignore
      })
      |> ignore
      p.box(fn(r2) {
        r2.padding(Is((40.0, 0.0, 0.0, 0.0))) |> ignore
        r2.box(fn(v) { v.words(Is(sample), look~) |> ignore }) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  let (placed, hit, _) = ahead_hits(asked)
  assert_true(placed >= 10)
  assert_eq(hit, placed, msg="\{hit} of \{placed} placed glyphs hit dual-origin words_ahead phases")
}

///|
test "words_ahead safely skips on default FakeHost and under MBUI_TEXT_RECORD=1" {
  let look = { ..@view.words_plain, size: 15.0, line: 22.0, wrap: false }
  let t = Tester::new(fn(_c) {  }, w=360.0, h=120.0, scale=3.6)
  fake_ahead.val = None
  assert_false(words_ahead_able())
  assert_eq(words_ahead("默认宿主跳过", look, 22.0, 1.0), 0.0)
  // Even when fake_ahead is attached, MBUI_TEXT_RECORD=1 must disable prewarming and emit no TEXTREC.
  let asked : Array[Int] = []
  fake_ahead.val = Some(asked)
  t.set_env("MBUI_TEXT_RECORD", "1")
  text_rec.val = -1
  let logs_before = t.fake.logs.length()
  let able_rec = words_ahead_able()
  let w_rec = words_ahead("录制模式跳过", look, 22.0, 1.0)
  words_ahead_flush()
  let logs_after = t.fake.logs.length()
  text_rec.val = -1
  fake_ahead.val = None
  assert_false(able_rec)
  assert_eq(w_rec, 0.0)
  assert_eq(asked.length(), 0)
  assert_eq(logs_after, logs_before)
}

///|
test "words_ahead ellipsizes overflowing single-line text and prewarms ellipsis glyph" {
  let look = { ..@view.words_plain, size: 15.0, line: 22.0, wrap: false }
  let asked : Array[Int] = []
  fake_ahead.val = Some(asked)
  let _t = Tester::new(fn(_c) {  }, w=360.0, h=120.0, scale=3.6)
  let max_w = 80.0
  let w = words_ahead("这是一段非常长的单行聊天标题需要被截断显示省略号", look, 22.0, 1.0, width=max_w)
  words_ahead_flush()
  fake_ahead.val = None
  assert_true(w > 0.0 && w <= max_w + 0.5, msg="expected ellipsized width <= \{max_w + 0.5}, got \{w}")
  let ellipsis_base = 0x2026
  let has_ellipsis = asked.iter().any(fn(k) { (k & 0x03FFFFFF) == ellipsis_base })
  assert_true(has_ellipsis, msg="expected ellipsis glyph U+2026 to be prewarmed")
}

///|
test "laid_ahead dispatches non-zero subpixel phases after phase 0 is in atlas via glyphs_ahead" {
  let asked : Array[Int] = []
  let t = Tester::new(fn(_c) {  }, w=400.0, h=200.0, scale=2.75)
  t.latin_advances(
    FixedArray::makei(95, fn(i) { 0.45 + (i % 7).to_double() * 0.037 }),
    FixedArray::makei(95, fn(i) { 0.48 + (i % 5).to_double() * 0.041 }),
  )
  let sample = "精确子像素相位判重测试abcd"
  // Pre-populate phase 0 for every glyph in sample into text_cache.glyphs.
  let s = shape(sample, 15.3, 400)
  for k in s.keys {
    if k >= 0 {
      text_cache.glyphs[k] = no_glyph
    }
  }
  glyphs_ahead()
  // Also push base keys into fresh to confirm fresh will not re-dispatch phase 0.
  for k in s.keys {
    if k >= 0 {
      text_cache.fresh.push(k)
    }
  }
  fake_ahead.val = Some(asked)
  let prev_ox = measuring_origin_x.val
  measuring_origin_x.val = 0.25 / g().scale
  let tl = layout_text(sample, 15.3, 400, 328.0, true)
  let ox = measuring_origin_x.val
  measuring_origin_x.val = prev_ox
  glyphs_ahead()
  fake_ahead.val = None
  let want : Array[Int] = []
  let seen : Map[Int, Bool] = Map([])
  for c, k in tl.shaped.keys {
    if k >= 0 {
      let pk = glyph_sub_at(k, ox + tl.xs[c] + tl.shaped.pad, g().scale, 1.0)
      if (pk >> 26) != 0 && !seen.contains(pk) {
        seen[pk] = true
        want.push(pk)
      }
    }
  }
  assert_true(want.length() > 0 && want.length() < glyphs_ahead_batch)
  assert_eq(asked, want, msg="expected exact non-zero phase keys once and no phase 0 from fresh")
  for k in asked {
    assert_true((k >> 26) != 0, msg="phase 0 must not be re-dispatched: \{k}")
  }
}

///|
test "laid_ahead dispatches non-zero subpixel phases after phase 0 is in atlas via glyphs_laid_flush" {
  let asked : Array[Int] = []
  let t = Tester::new(fn(_c) {  }, w=400.0, h=600.0, scale=2.75)
  t.latin_advances(
    FixedArray::makei(95, fn(i) { 0.45 + (i % 7).to_double() * 0.037 }),
    FixedArray::makei(95, fn(i) { 0.48 + (i % 5).to_double() * 0.041 }),
  )
  // > 48 distinct characters so laid_ahead triggers mid-layout glyphs_laid_flush().
  let long_sample = "天地玄黄宇宙洪荒日月盈昃辰宿列张寒来暑往秋收冬藏闰余成岁律吕调阳云腾致雨露结为霜金生丽水玉出昆冈剑号巨阙珠称夜光果珍李柰菜重芥姜海咸河淡"
  let s = shape(long_sample, 15.3, 400)
  for k in s.keys {
    if k >= 0 {
      text_cache.glyphs[k] = no_glyph
    }
  }
  glyphs_ahead()
  for k in s.keys {
    if k >= 0 {
      text_cache.fresh.push(k)
    }
  }
  fake_ahead.val = Some(asked)
  let prev_ox = measuring_origin_x.val
  measuring_origin_x.val = 0.25 / g().scale
  let tl = layout_text(long_sample, 15.3, 400, 328.0, true)
  let ox = measuring_origin_x.val
  measuring_origin_x.val = prev_ox
  let mid_count = asked.length()
  assert_true(
    mid_count >= glyphs_ahead_batch,
    msg="expected mid-layout glyphs_laid_flush >= \{glyphs_ahead_batch}, got \{mid_count}",
  )
  glyphs_ahead()
  fake_ahead.val = None
  let want : Array[Int] = []
  let seen : Map[Int, Bool] = Map([])
  for c, k in tl.shaped.keys {
    if k >= 0 {
      let pk = glyph_sub_at(k, ox + tl.xs[c] + tl.shaped.pad, g().scale, 1.0)
      if (pk >> 26) != 0 && !seen.contains(pk) {
        seen[pk] = true
        want.push(pk)
      }
    }
  }
  assert_true(want.length() >= glyphs_ahead_batch)
  assert_eq(asked, want, msg="expected exact non-zero phase keys once across mid-layout flush + glyphs_ahead")
  for k in asked {
    assert_true((k >> 26) != 0, msg="phase 0 must not be re-dispatched: \{k}")
  }
}

///|
fn expected_phased_keys(
  keys : Array[Int],
  x : (Int) -> Double,
  ox : Double,
  sc : Double,
  z : Double,
) -> Array[Int] {
  let out : Array[Int] = []
  let seen : Map[Int, Bool] = Map([])
  for c, k in keys {
    if k >= 0 {
      let pk = glyph_sub_at(k, ox + x(c), sc, z)
      if !seen.contains(pk) && !text_cache.glyphs.contains(pk) {
        seen[pk] = true
        out.push(pk)
      }
    }
  }
  out
}

///|
test "layout_text cache hit re-dispatches laid_ahead by measuring_origin_known, fractional origin, zoom, moves, and truncation" {
  let asked : Array[Int] = []
  let t = Tester::new(fn(_c) {  }, w=400.0, h=200.0, scale=2.0)
  t.latin_advances(
    FixedArray::makei(95, fn(i) { 0.45 + (i % 7).to_double() * 0.037 }),
    FixedArray::makei(95, fn(i) { 0.48 + (i % 5).to_double() * 0.041 }),
  )
  let sample = "缓存命中预热plain"
  let sc = g().scale
  fake_ahead.val = Some(asked)

  // 1. Initial layout with measuring_origin_known == false does not mark memo known.
  measuring_origin_x.val = 0.0
  measuring_origin_known.val = false
  let tl = layout_text(sample, 15.0, 400, 300.0, true)
  let x_of = fn(c : Int) { tl.xs[c] + tl.shaped.pad }
  glyphs_ahead()
  asked.clear()

  // 2. Cache hit while still unknown does not push and does not pollute memo.
  let _ = layout_text(sample, 15.0, 400, 300.0, true)
  glyphs_ahead()
  assert_eq(asked.length(), 0)

  // 3. Transition from unknown -> known 0.0 must re-dispatch exact phased keys at ox=0.0.
  measuring_origin_x.val = 0.0
  measuring_origin_known.val = true
  let _ = layout_text(sample, 15.0, 400, 300.0, true)
  glyphs_ahead()
  let want3 = expected_phased_keys(tl.shaped.keys, x_of, 0.0, sc, 1.0)
  assert_true(want3.length() > 0)
  assert_eq(asked, want3, msg="expected exact phased keys when origin becomes known 0.0")
  asked.clear()

  // 4. Cache hit at same origin_x does not re-dispatch.
  let _ = layout_text(sample, 15.0, 400, 300.0, true)
  glyphs_ahead()
  assert_eq(asked.length(), 0)

  // 5. Whole-pixel translation (+3 device pixels = +1.5 pt at 2x) does not re-dispatch.
  measuring_origin_x.val = 3.0 / sc
  let _ = layout_text(sample, 15.0, 400, 300.0, true)
  glyphs_ahead()
  assert_eq(asked.length(), 0)

  // 6. Fractional-pixel shift (+0.25 device pixels) re-dispatches exact keys at new phases.
  let ox6 = 0.25 / sc
  measuring_origin_x.val = ox6
  let _ = layout_text(sample, 15.0, 400, 300.0, true)
  glyphs_ahead()
  let want6 = expected_phased_keys(tl.shaped.keys, x_of, ox6, sc, 1.0)
  assert_true(want6 != want3, msg="expected fractional shift to change subpixel phases")
  assert_eq(asked, want6, msg="expected exact phased keys on fractional origin shift")
  asked.clear()

  // 7. paint_phase == 1 suppresses cache-hit re-dispatch and does not overwrite memo.
  let ox7 = 0.5 / sc
  measuring_origin_x.val = ox7
  paint_phase.val = 1
  let _ = layout_text(sample, 15.0, 400, 300.0, true)
  paint_phase.val = 0
  glyphs_ahead()
  assert_eq(asked.length(), 0)
  // After paint_phase returns to 0, same 0.5px shift still triggers exact keys because memo was not polluted.
  let _ = layout_text(sample, 15.0, 400, 300.0, true)
  glyphs_ahead()
  let want7 = expected_phased_keys(tl.shaped.keys, x_of, ox7, sc, 1.0)
  assert_eq(asked, want7, msg="expected exact phased keys after paint_phase ended")
  asked.clear()

  // 8. words_zoom toggle (1.0 -> 1.5 -> 1.0): zoomed dispatches phase 0 only, unzoomed restores exact non-zero phases.
  words_zoom.val = 1.5
  let _ = layout_text(sample, 15.0, 400, 300.0, true)
  glyphs_ahead()
  let want8_zoom = expected_phased_keys(tl.shaped.keys, x_of, ox7, sc, 1.5)
  assert_eq(asked, want8_zoom, msg="expected phase-0 keys when words_zoom becomes 1.5")
  for k in asked {
    assert_eq((k >> 26) & 3, 0, msg="zoomed prewarm must use phase 0")
  }
  asked.clear()
  words_zoom.val = 1.0
  let _ = layout_text(sample, 15.0, 400, 300.0, true)
  glyphs_ahead()
  assert_eq(asked, want7, msg="expected exact non-zero phases restored when words_zoom returns to 1.0")
  assert_true(asked.iter().any(fn(k) { ((k >> 26) & 3) != 0 }), msg="expected non-zero phase at ox=0.5px")
  asked.clear()

  // 9. glyph_moves increment triggers exact re-dispatch.
  glyph_moves.val += 1
  let _ = layout_text(sample, 15.0, 400, 300.0, true)
  glyphs_ahead()
  assert_eq(asked, want7, msg="expected exact phased keys after glyph_moves increments")
  asked.clear()

  // 10. Truncation by glyphs_ahead_most must NOT mark memo known, so next call after draining re-dispatches exact keys.
  let ox10 = 0.75 / sc
  measuring_origin_x.val = ox10
  for _ in 0..<glyphs_ahead_most {
    glyphs_laid.push(1)
  }
  let _ = layout_text(sample, 15.0, 400, 300.0, true)
  glyphs_ahead()
  asked.clear()
  let _ = layout_text(sample, 15.0, 400, 300.0, true)
  glyphs_ahead()
  let want10 = expected_phased_keys(tl.shaped.keys, x_of, ox10, sc, 1.0)
  assert_eq(asked, want10, msg="expected exact phased keys after truncated laid_ahead")

  measuring_origin_known.val = false
  measuring_origin_x.val = 0.0
  fake_ahead.val = None
}

///|
test "layout_rich cache hit re-dispatches laid_ahead by measuring_origin_known, fractional origin, zoom, moves, and truncation" {
  let asked : Array[Int] = []
  let t = Tester::new(fn(_c) {  }, w=400.0, h=200.0, scale=2.0)
  t.latin_advances(
    FixedArray::makei(95, fn(i) { 0.45 + (i % 7).to_double() * 0.037 }),
    FixedArray::makei(95, fn(i) { 0.48 + (i % 5).to_double() * 0.041 }),
  )
  let r : Rich = {
    runs: [plain("富文本"), bold("缓存预热rich")],
    size: 15.0,
    weight: 400,
    color: 0xFF000000L,
    line: 22.0,
    trim: false,
    wrap: true,
    link_color: 0xFF0000FFL,
    pressed_bg: 0L,
    code_color: 0xFF000000L,
    code_bg: 0L,
    code_scale: 0.9,
    spacing: 0.0,
    base: 0,
    select: false,
    max_lines: 0,
    faces: 0,
    shaped_in: words_shaped_in.untracked(),
    cjk_override: None,
    code_cjk_override: None,
  }
  let sc = g().scale
  fake_ahead.val = Some(asked)

  // 1. Initial layout with measuring_origin_known == false.
  measuring_origin_x.val = 0.0
  measuring_origin_known.val = false
  let lay = layout_rich(r, 300.0)
  let x_of = fn(c : Int) { lay.xs[c] + lay.pre[c] }
  glyphs_ahead()
  asked.clear()

  // 2. Cache hit while unknown does not push.
  let _ = layout_rich(r, 300.0)
  glyphs_ahead()
  assert_eq(asked.length(), 0)

  // 3. Unknown -> known 0.0 re-dispatches exact phased keys.
  measuring_origin_x.val = 0.0
  measuring_origin_known.val = true
  let _ = layout_rich(r, 300.0)
  glyphs_ahead()
  let want3 = expected_phased_keys(lay.keys, x_of, 0.0, sc, 1.0)
  assert_true(want3.length() > 0)
  assert_eq(asked, want3, msg="expected exact rich phased keys when origin becomes known 0.0")
  asked.clear()

  // 4. Same origin_x does not re-dispatch.
  let _ = layout_rich(r, 300.0)
  glyphs_ahead()
  assert_eq(asked.length(), 0)

  // 5. Whole-pixel translation (+4 device px = +2.0 pt at 2x) does not re-dispatch.
  measuring_origin_x.val = 4.0 / sc
  let _ = layout_rich(r, 300.0)
  glyphs_ahead()
  assert_eq(asked.length(), 0)

  // 6. Fractional shift (+0.25 device px) re-dispatches exact keys at new phases.
  let ox6 = 0.25 / sc
  measuring_origin_x.val = ox6
  let _ = layout_rich(r, 300.0)
  glyphs_ahead()
  let want6 = expected_phased_keys(lay.keys, x_of, ox6, sc, 1.0)
  assert_true(want6 != want3, msg="expected rich fractional shift to change subpixel phases")
  assert_eq(asked, want6, msg="expected exact rich phased keys on fractional shift")
  asked.clear()

  // 7. paint_phase == 1 suppresses and does not pollute memo.
  let ox7 = 0.5 / sc
  measuring_origin_x.val = ox7
  paint_phase.val = 1
  let _ = layout_rich(r, 300.0)
  paint_phase.val = 0
  glyphs_ahead()
  assert_eq(asked.length(), 0)
  let _ = layout_rich(r, 300.0)
  glyphs_ahead()
  let want7 = expected_phased_keys(lay.keys, x_of, ox7, sc, 1.0)
  assert_eq(asked, want7, msg="expected exact rich phased keys after paint_phase ended")
  asked.clear()

  // 8. words_zoom toggle: zoomed uses phase 0 only, unzoomed restores exact non-zero phases.
  words_zoom.val = 1.5
  let _ = layout_rich(r, 300.0)
  glyphs_ahead()
  let want8_zoom = expected_phased_keys(lay.keys, x_of, ox7, sc, 1.5)
  assert_eq(asked, want8_zoom, msg="expected rich phase-0 keys when words_zoom becomes 1.5")
  for k in asked {
    assert_eq((k >> 26) & 3, 0, msg="zoomed rich prewarm must use phase 0")
  }
  asked.clear()
  words_zoom.val = 1.0
  let _ = layout_rich(r, 300.0)
  glyphs_ahead()
  assert_eq(asked, want7, msg="expected exact rich non-zero phases restored when words_zoom returns to 1.0")
  assert_true(asked.iter().any(fn(k) { ((k >> 26) & 3) != 0 }), msg="expected rich non-zero phase at ox=0.5px")
  asked.clear()

  // 9. glyph_moves increment triggers exact re-dispatch.
  glyph_moves.val += 1
  let _ = layout_rich(r, 300.0)
  glyphs_ahead()
  assert_eq(asked, want7, msg="expected exact rich phased keys after glyph_moves increments")
  asked.clear()

  // 10. Truncation by glyphs_ahead_most does not mark memo known.
  let ox10 = 0.75 / sc
  measuring_origin_x.val = ox10
  for _ in 0..<glyphs_ahead_most {
    glyphs_laid.push(1)
  }
  let _ = layout_rich(r, 300.0)
  glyphs_ahead()
  asked.clear()
  let _ = layout_rich(r, 300.0)
  glyphs_ahead()
  let want10 = expected_phased_keys(lay.keys, x_of, ox10, sc, 1.0)
  assert_eq(asked, want10, msg="expected exact rich phased keys after truncated laid_ahead")

  measuring_origin_known.val = false
  measuring_origin_x.val = 0.0
  fake_ahead.val = None
}

///|
test "ahead_origin_same rejects 1e-6 and 4e-11 px shifts across glyph_qf 1/8 px boundary and re-dispatches new phase" {
  let asked : Array[Int] = []
  let _t = Tester::new(fn(_c) {  }, w=400.0, h=200.0, scale=2.0)
  let sc = g().scale
  // 1. Shift of 1e-6 device px straddling the 0.125 px (1/8 px) boundary between phase 0 and phase 1.
  let ox0 = (0.125 - 5.0e-7) / sc
  let ox1 = (0.125 + 5.0e-7) / sc
  assert_false(ahead_origin_same(ox0, ox1, sc))
  fake_ahead.val = Some(asked)
  measuring_origin_known.val = true
  measuring_origin_x.val = ox0
  let tl = layout_text("边界测试", 15.0, 400, 300.0, true)
  let x_of = fn(c : Int) { tl.xs[c] + tl.shaped.pad }
  glyphs_ahead()
  let want0 = expected_phased_keys(tl.shaped.keys, x_of, ox0, sc, 1.0)
  assert_eq(asked, want0)
  asked.clear()

  measuring_origin_x.val = ox1
  let _ = layout_text("边界测试", 15.0, 400, 300.0, true)
  glyphs_ahead()
  let want1 = expected_phased_keys(tl.shaped.keys, x_of, ox1, sc, 1.0)
  assert_true(want1 != want0, msg="expected phase flip across 1/8 px boundary")
  assert_eq(asked, want1, msg="expected re-dispatch across 1/8 px boundary")
  asked.clear()

  // 2. Shift of ~4e-11 device px straddling glyph_qf's 1e-9 shifted boundary (0.12499999973 vs 0.12499999977).
  let ox2 = 0.12499999973 / sc
  let ox3 = 0.12499999977 / sc
  assert_false(ahead_origin_same(ox2, ox3, sc))
  measuring_origin_x.val = ox2
  let tl2 = layout_text("微界反例", 15.0, 400, 300.0, true)
  let x_of2 = fn(c : Int) { tl2.xs[c] + tl2.shaped.pad }
  glyphs_ahead()
  let want2 = expected_phased_keys(tl2.shaped.keys, x_of2, ox2, sc, 1.0)
  assert_eq(asked, want2)
  asked.clear()

  measuring_origin_x.val = ox3
  let _ = layout_text("微界反例", 15.0, 400, 300.0, true)
  glyphs_ahead()
  let want3 = expected_phased_keys(tl2.shaped.keys, x_of2, ox3, sc, 1.0)
  assert_true(want3 != want2, msg="expected phase flip across 4e-11 shifted boundary")
  assert_eq(asked, want3, msg="expected re-dispatch across 4e-11 shifted boundary")

  measuring_origin_known.val = false
  measuring_origin_x.val = 0.0
  fake_ahead.val = None
}

///|
test "layout_rich tracks per-width prewarm memos independently in RichKept::lays" {
  let asked : Array[Int] = []
  let _t = Tester::new(fn(_c) {  }, w=400.0, h=200.0, scale=2.0)
  let sc = g().scale
  let r : Rich = {
    runs: [plain("多宽度独立缓存条目验证甲乙丙丁戊己")],
    size: 15.0,
    weight: 400,
    color: 0xFF000000L,
    line: 22.0,
    trim: false,
    wrap: true,
    link_color: 0xFF0000FFL,
    pressed_bg: 0L,
    code_color: 0xFF000000L,
    code_bg: 0L,
    code_scale: 0.9,
    spacing: 0.0,
    base: 0,
    select: false,
    max_lines: 0,
    faces: 0,
    shaped_in: words_shaped_in.untracked(),
    cjk_override: None,
    code_cjk_override: None,
  }
  fake_ahead.val = Some(asked)
  measuring_origin_known.val = true
  measuring_origin_x.val = 0.0
  let lay_wide = layout_rich(r, 300.0)
  let lay_narrow = layout_rich(r, 60.0)
  assert_true(lay_narrow.line_start.length() > lay_wide.line_start.length())
  glyphs_ahead()
  asked.clear()

  // Move origin_x and hit only the wide entry: updates wide's memo, leaves narrow's memo at ox=0.0.
  let ox1 = 0.25 / sc
  measuring_origin_x.val = ox1
  let _ = layout_rich(r, 300.0)
  glyphs_ahead()
  let want_wide = expected_phased_keys(lay_wide.keys, fn(c) { lay_wide.xs[c] + lay_wide.pre[c] }, ox1, sc, 1.0)
  assert_eq(asked, want_wide)
  asked.clear()
  // Second hit on wide at ox1 is a no-op.
  let _ = layout_rich(r, 300.0)
  glyphs_ahead()
  assert_eq(asked.length(), 0)

  // Hitting narrow at ox1 must still re-dispatch narrow's exact phased keys.
  let _ = layout_rich(r, 60.0)
  glyphs_ahead()
  let want_narrow = expected_phased_keys(lay_narrow.keys, fn(c) { lay_narrow.xs[c] + lay_narrow.pre[c] }, ox1, sc, 1.0)
  assert_eq(asked, want_narrow)

  measuring_origin_known.val = false
  measuring_origin_x.val = 0.0
  fake_ahead.val = None
}

///|
test "real Tester::tree and take_picture measure callbacks propagate measuring_origin_known without leaking" {
  let look = { ..@view.words_plain, size: 15.0, line: 22.0, wrap: false }
  let sample = "真实树测量已知原点零点"
  let asked : Array[Int] = []
  let show = @signals.signal(false)
  let t = Tester::tree(fn(root) {
    root.show(fn() { show.get() }, fn(s) {
      s.box(fn(b) { b.words(Is(sample), look~) |> ignore }) |> ignore
    })
    |> ignore
  }, w=360.0, h=120.0, scale=2.0)
  // Unpositioned glyph_cells must leave measuring_origin_known == false and NOT mark memo known.
  assert_false(measuring_origin_known.val)
  let _ = glyph_cells(sample, look, 1.0)
  assert_false(measuring_origin_known.val)
  glyphs_ahead()

  // Now show the real tree node at known origin_x == 0.0: measure callback sets measuring_origin_known = true and
  // dispatches exact phased keys at ox = 0.0, then restores measuring_origin_known = false.
  fake_ahead.val = Some(asked)
  show.set(true)
  t.draw()
  assert_false(measuring_origin_known.val)
  fake_ahead.val = None
  let (placed, hit, _) = ahead_hits(asked)
  assert_true(placed >= 10)
  assert_eq(hit, placed, msg="expected all glyphs at known origin_x=0.0 to hit prewarmed phases")

  // take_picture also propagates measuring_origin_known = true on cache hit at a known fractional origin_x,
  // dispatches the exact phased keys, and restores measuring_origin_known == false afterward.
  let shot_sample = "截图测量原点验证"
  let sc = g().scale
  let shot_ox = 0.25 / sc
  assert_false(measuring_origin_known.val)
  let shot_tl = layout_words(
    shot_sample,
    view_sp(1.0, look.size),
    look.weight,
    1.0e9,
    false,
    balance=false,
    line=view_line(1.0, look),
    spacing=view_spacing(1.0, look),
    style=view_words_style(),
  )
  glyphs_ahead()
  asked.clear()
  let shot_want = expected_phased_keys(
    shot_tl.shaped.keys,
    fn(c) { shot_tl.xs[c] + shot_tl.shaped.pad },
    shot_ox,
    sc,
    1.0,
  )
  assert_true(shot_want.length() >= 8)
  assert_true(shot_want.iter().any(fn(k) { ((k >> 26) & 3) != 0 }))
  fake_ahead.val = Some(asked)
  let got_png : Ref[Bool] = Ref(false)
  take_picture("origin_known_shot", 200.0, fn(b) {
    b.padding(Is((shot_ox, 0.0, 0.0, 0.0))) |> ignore
    b.box(fn(v) { v.words(Is(shot_sample), look~) |> ignore }) |> ignore
  }, fn(_png) { got_png.val = true })
  t.draw()
  fake_ahead.val = None
  assert_false(measuring_origin_known.val)
  assert_eq(asked, shot_want, msg="expected take_picture measure callback to re-dispatch exact phased keys")
}

///|
test "words_ahead retries exact phased keys at same origin_x without glyph_moves bump (backpressure recovery)" {
  let look = { ..@view.words_plain, size: 15.0, line: 22.0, wrap: false }
  let sample = "背压重试预热验证"
  let asked : Array[Int] = []
  fake_ahead.val = Some(asked)
  let _t = Tester::new(fn(_c) {  }, w=360.0, h=120.0, scale=3.6)
  let _ = words_ahead(sample, look, 22.0, 1.0)
  words_ahead_flush()
  let first = asked.copy()
  assert_true(first.length() >= 8)

  // Simulate host backpressure/eviction (no glyph_moves increment): calling words_ahead again at the same origin_x
  // must explicitly re-dispatch the exact same phased keys.
  asked.clear()
  let moves_before = glyph_moves.val
  let _ = words_ahead(sample, look, 22.0, 1.0)
  words_ahead_flush()
  assert_eq(glyph_moves.val, moves_before)
  assert_eq(asked, first, msg="expected explicit words_ahead retry to re-dispatch exact phased keys")
  fake_ahead.val = None
}
