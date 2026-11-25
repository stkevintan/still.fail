// Letter spacing and a most of lines (Ctx::text tracking, max_lines; TextStyle's).

///|
/// The x of each glyph drawn in the last frame, left to right.
fn glyph_xs(t : Tester) -> Array[Double] {
  ignore(t)
  let c = g()
  let xs = []
  for k in 0..<c.ninst {
    let b = k * inst_size
    if c.inst[b + 5] == 1.0 {
      xs.push(c.inst[b])
    }
  }
  xs
}

///|
test "letter spacing: each cluster's advance has it, its piece drawn half of it in, as Android spaces letters" {
  let spaced = Ref(false)
  let t = Tester::new(
    fn(c) {
      c.column(align=AStart, fn() {
        if spaced.val {
          c.text("abcd", tracking=2.0) |> ignore
        } else {
          c.text("abcd") |> ignore
        }
      })
      |> ignore
    },
    w=300.0,
    h=100.0,
  )
  // the fake host's Latin is 7.5 wide at 15
  let (_, _, w0, _) = t.rect_of("abcd").unwrap()
  assert_eq(w0, 30.0)
  let xs0 = glyph_xs(t)
  spaced.val = true
  t.draw()
  let (_, _, w1, _) = t.rect_of("abcd").unwrap()
  assert_eq(w1, 38.0)
  let xs1 = glyph_xs(t)
  assert_eq(xs1.length(), 4)
  for k in 0..<4 {
    assert_eq(xs1[k] - xs0[k], 1.0 + 2.0 * k.to_double())
  }
}

///|
test "letter spacing in ems from a style's token, and wrapping by the spaced widths" {
  let t = Tester::new(
    fn(c) {
      c.column(w=Px(80.0), align=AStart, fn() {
        // Widest: 0.1 em, 1.5 at 15: a letter 9 wide, so "aaaa bbbb" (81) does not fit 80
        c.text("aaaa bbbb", style=text_style(tracking=Widest)) |> ignore
        c.text("cccc dddd", style=text_style(tracking=Exact(-1.5))) |> ignore
      })
      |> ignore
    },
    w=300.0,
    h=200.0,
  )
  assert_eq(t.lines_of("aaaa"), ["aaaa ", "bbbb"])
  // 6 a letter: one line of 54
  assert_eq(t.lines_of("cccc"), ["cccc dddd"])
  let (_, _, w, _) = t.rect_of("cccc").unwrap()
  assert_eq(w, 54.0)
}

///|
test "words with letter spacing are shaped with no ligatures, those without as the font makes them" {
  // (the fake host's U+E000 is a ligature's second letter)
  let _ = Tester::new(fn(_) {  }, w=10.0, h=10.0)
  let plain = shape("a\u{E000}b", 15.0, 400)
  assert_eq(plain.keys[1], -1)
  let spaced = shape("a\u{E000}b", 15.0, 400, spacing=1.0)
  assert_true(spaced.keys[1] >= 0)
  assert_eq(spaced.pad, 0.5)
  // and each in a cache of its own
  assert_eq(shape("a\u{E000}b", 15.0, 400).keys[1], -1)
}

///|
test "max_lines: wrapped words cut after that many lines, the last ending in an ellipsis, the box as high as they" {
  let t = Tester::new(
    fn(c) {
      c.column(w=Px(80.0), align=AStart, fn() {
        c.text("one two three four five six seven", line=20.0, max_lines=2) |> ignore
        c.text("short", line=20.0, max_lines=2) |> ignore
        c.text("eight nine ten eleven twelve", style=text_style(max_lines=1)) |> ignore
      })
      |> ignore
    },
    w=300.0,
    h=200.0,
  )
  // 7.5 a letter: "one two " fits 80; the second line has what follows up to what fits with the dots (9 and the dots)
  assert_eq(t.lines_of("one two"), ["one two ", "three fou…"])
  let (_, _, _, h) = t.rect_of("one two").unwrap()
  assert_eq(h, 40.0)
  assert_eq(t.lines_of("short"), ["short"])
  assert_eq(t.lines_of("eight"), ["eight nin…"])
}

///|
test "max_lines: a line break ends the last line where it is, the dots after it" {
  let t = Tester::new(
    fn(c) {
      c.column(w=Px(200.0), align=AStart, fn() {
        c.text("first\nsecond\nthird", max_lines=2) |> ignore
      })
      |> ignore
    },
    w=300.0,
    h=200.0,
  )
  assert_eq(t.lines_of("first"), ["first\n", "second…"])
}

///|
test "census: words' letter spacing is part of their size" {
  let t = Tester::new(
    fn(c) {
      c.column(fn() {
        c.text("a", line=20.0) |> ignore
        c.text("b", line=20.0, tracking=-0.6) |> ignore
      })
      |> ignore
    },
    w=300.0,
    h=200.0,
  )
  assert_eq(t.census().text, ["15/20", "15/20 -0.6"])
}

///|
test "letter spacing in rich text: every run's clusters, in the code face too" {
  let spaced = Ref(false)
  let t = Tester::new(
    fn(c) {
      c.column(align=AStart, fn() {
        c.rich([plain("ab"), span("cd", mono=true)], tracking=if spaced.val { 2.0 } else { 0.0 }) |> ignore
      })
      |> ignore
    },
    w=300.0,
    h=100.0,
  )
  let (_, _, w0, _) = t.rect_of("abcd").unwrap()
  let xs0 = glyph_xs(t)
  spaced.val = true
  t.draw()
  let (_, _, w1, _) = t.rect_of("abcd").unwrap()
  assert_eq(w1 - w0, 8.0)
  let xs1 = glyph_xs(t)
  assert_eq(xs1.length(), 4)
  for k in 0..<4 {
    assert_eq(xs1[k] - xs0[k], 1.0 + 2.0 * k.to_double())
  }
}

///|
test "words with letter spacing are copied as they were written: what is shaped with no ligatures stays the host's" {
  // (U+E000: the fake host's ligature's second letter, made none by the spacing)
  let words = "office fi\u{E000}les"
  let t = Tester::new(
    fn(c) {
      c.mouse_drags_lists(false)
      c.column(w=Fill(1.0), fn() {
        c.selectable(fn() { c.rich([plain(words)], tracking=1.0) |> ignore })
        c.text(words, tracking=1.0) |> ignore
      })
      |> ignore
    },
    w=400.0,
    h=300.0,
  )
  let (_, y, _, h) = t.rect_of(words).unwrap()
  t.drag(1.0, y + h / 2.0, 390.0, y + h / 2.0)
  assert_eq(t.ctx().selected_text(), words)
  t.key(13, mods=8)
  assert_eq(t.clipboard(), words)
  assert_false(t.clipboard().contains("\u{200C}"))
  // and the plain text's lines, as shown and read out
  assert_eq(t.lines_of("office").join(""), words)
}

///|
test "glyph phase: a pen moving right moves its glyph right a quarter pixel at a time, a half pixel never split" {
  for sc in [1.0, 1.5, 2.0, 2.625, 3.0] {
    let mut last = -1.0e9
    // (device pixels from -5 to 40, a hundredth at a time, and each half pixel a hair either side of it)
    let pens : Array[Double] = []
    for i in -500..=4000 {
      pens.push(i.to_double() * 0.01)
    }
    for k in -5..=39 {
      pens.push(k.to_double() + 0.5 - 1.0e-12)
      pens.push(k.to_double() + 0.5 + 1.0e-12)
    }
    pens.sort()
    for tx in pens {
      let (col, sub) = glyph_col_sub(tx)
      assert_true(sub >= 0 && sub <= 3)
      assert_eq(col, col.floor())
      let at = col + glyph_sub_dx(sub)
      // within an eighth of a pixel of the pen, on a quarter
      assert_true((at - tx).abs() <= 0.1251, msg="sc=\{sc} tx=\{tx} at=\{at}")
      assert_eq(at * 4.0, (at * 4.0).round())
      // never back, never more than a quarter at a step
      assert_true(at >= last, msg="sc=\{sc} tx=\{tx} at=\{at} last=\{last}")
      if last > -1.0e8 {
        assert_true(at - last == 0.0 || at - last == 0.25, msg="sc=\{sc} tx=\{tx} step=\{at - last}")
      }
      last = at
      // a whole pixel further: the next column, the same phase
      let (col2, sub2) = glyph_col_sub(tx + 3.0)
      assert_eq(col2, col + 3.0)
      assert_eq(sub2, sub)
      // as text.mbt and scene.mbt have it for a cluster laid out at tx / sc points
      let x = tx / sc
      let key = glyph_sub_at(77, x, sc, 1.0)
      assert_eq(key & 0x03FFFFFF, 77)
      let (want_col, want_sub) = glyph_col_sub(x * sc)
      assert_eq(key >> 26, want_sub)
      assert_true((on_glyph_col(x, 0.0, sc) * sc - want_col).abs() < 1.0e-9)
      // drawn zoomed: no phase, on the nearest pixel
      assert_eq(glyph_sub_at(77, x, sc, 2.0), 77)
      assert_eq(on_glyph_col(x, 0.0, sc, z=2.0), on_pixels(x, sc))
    }
    // a half pixel either side of a hair: the same place
    for k in -5..=40 {
      let h = k.to_double() + 0.5
      let (c0, s0) = glyph_col_sub(h - 1.0e-12)
      let (c1, s1) = glyph_col_sub(h + 1.0e-12)
      assert_eq((c0, s0), (c1, s1))
      assert_eq(c0 + glyph_sub_dx(s0), h)
    }
  }
  // the four phases, and below nought
  assert_eq(glyph_col_sub(10.0), (10.0, 0))
  assert_eq(glyph_col_sub(10.25), (10.0, 1))
  assert_eq(glyph_col_sub(10.499999), (11.0, 2))
  assert_eq(glyph_col_sub(10.5), (11.0, 2))
  assert_eq(glyph_col_sub(10.500001), (11.0, 2))
  assert_eq(glyph_col_sub(10.75), (11.0, 3))
  assert_eq(glyph_col_sub(11.0), (11.0, 0))
  assert_eq(glyph_col_sub(-0.25), (0.0, 3))
  assert_eq(glyph_col_sub(-0.5), (0.0, 2))
}

///|
test "glyph phase: ViewBlock re-phased in place as an ancestor moves its words by less than a pixel, on every platform" {
  let sc = 1.5
  let gox = -1.0 / sc
  for n in [10, 44, 73, 128] {
    let x = (n.to_double() + 0.5) / sc
    glyph_origin_x.val = 0.0
    glyphs_carried[0] = 0.0
    let col = on_glyph_col(x, gox, sc)
    // (a half pixel: the column right of it, at the phase half a pixel back)
    assert_eq((col * sc).round(), n.to_double())
  }
  let build = fn(platform : Int, x0 : Double, shifts : Array[Double]) -> (Array[Double], Array[Int], Array[Int], Int) raise {
    let off = @signals.signal(x0, same=fn(a, b) { a == b })
    let plain_id : Ref[@view.NodeId?] = Ref(None)
    let rich_id : Ref[@view.NodeId?] = Ref(None)
    let t = Tester::new(fn(_c) {  }, w=400.0, h=200.0, platform~, scale=1.5)
    set_view_app(fn(root) {
      root.box(fn(p) {
        p.width(Is(Some(200.0))).height(Is(Some(60.0))).offset(By(fn() { (off.get(), 10.0) })) |> ignore
        p.box(fn(b) {
          plain_id.val = Some(b.id())
          b.width(Is(Some(200.0))).height(Is(Some(24.0))).words(Is("Tick apps")) |> ignore
        })
        |> ignore
        p.box(fn(b) {
          rich_id.val = Some(b.id())
          b
          .width(Is(Some(200.0)))
          .height(Is(Some(24.0)))
          .words_runs(Is([@view.words_run("Chat "), @view.words_run("sidebar", weight=600)]))
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    t.draw()
    let made0 = view_paint_work.made
    // (what it kept as it was made, as a ride of an older frame may hold it: never written as it is re-phased)
    let old_kept = view_blocks.get(plain_id.val.unwrap()).unwrap().kept
    let old_seen = old_kept.copy()
    for x1 in shifts {
      off.set(x1)
      t.draw()
    }
    let remade = view_paint_work.made - made0
    let now_kept = view_blocks.get(plain_id.val.unwrap()).unwrap().kept
    assert_eq(old_kept, old_seen)
    if now_kept.map(fn(k) { k.0 }) != old_seen.map(fn(k) { k.0 }) {
      assert_true(!physical_equal(now_kept, old_kept), msg="platform \{platform}: re-phased into the array it kept")
    }
    let xs = t.drawn_glyphs().map(fn(g) { g.0 })
    let plain_subs = now_kept.map(fn(k) { (k.0 >> 26) & 7 })
    let rich_subs = view_blocks.get(rich_id.val.unwrap()).unwrap().kept.map(fn(k) { (k.0 >> 26) & 7 })
    (xs, plain_subs, rich_subs, remade)
  }
  // macOS, Android, Windows
  for platform in [0, 2, 3] {
    let initial = build(platform, 0.0, [])
    let shifted = build(platform, 0.0, [1.0, 2.0, 3.0, 10.25])
    let fresh = build(platform, 10.25, [])
    assert_true(shifted.0.length() > 10)
    assert_true(initial.1 != fresh.1, msg="platform \{platform}")
    // (moved by less than a pixel: its glyphs at their new phases, the block not made again)
    assert_eq(shifted.3, 0)
    assert_eq(shifted, fresh)
    // moved by whole pixels (2 points at 1.5: 3 pixels): the same phases, each glyph 3 pixels further
    let whole = build(platform, 2.0, [])
    assert_eq(whole.1, initial.1)
    assert_eq(whole.2, initial.2)
    for i, x in whole.0 {
      assert_eq(((x - initial.0[i]) * 1.5 * 1000.0).round(), 3000.0)
    }
  }
}

///|
test "view_made glyph_x uses glyph_origin_x for words_halo, glyphs_by, inline drawing words, and glyphs_ahead skips subpixel-drawn keys" {
  // 1. View::words_halo at fractional ux (10.5) aligns halo quad with first glyph and updates when ux shifts by 0.5
  let off = @signals.signal(10.5, same=fn(a, b) { a == b })
  let t = Tester::new(fn(_c) {  }, w=400.0, h=200.0, platform=3, scale=1.0)
  set_view_app(fn(root) {
    root.box(fn(p) {
      p.width(Is(Some(200.0))).height(Is(Some(60.0))).offset(By(fn() { (off.get(), 10.0) })) |> ignore
      p.box(fn(b) {
        b
        .width(Is(Some(200.0)))
        .height(Is(Some(24.0)))
        .words(Is("Halo text"), look={ ..@view.words_plain, size: 13.0, line: 18.0, wrap: false })
        .words_halo(Is((4.0, 0xFF0000FFL)))
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  let gs0 = t.drawn_instances().filter(fn(i) { i[5] == 1.0 })
  assert_true(gs0.length() > 2)
  // halo quad is exactly 3 * blur (12 px) to the left of the first glyph (which is on a whole pixel)
  assert_eq(gs0[1][0] - gs0[0][0], 12.0)
  assert_eq(gs0[0][0] - gs0[0][0].round(), 0.0)
  off.set(10.0)
  t.draw()
  let gs1 = t.drawn_instances().filter(fn(i) { i[5] == 1.0 })
  assert_eq(gs1[1][0] - gs1[0][0], 12.0)
  assert_eq(gs1[0][0] - gs1[0][0].round(), 0.0)

  // 2. View::glyphs_by with sx != 1.0 at fractional ux (10.5) matches Ctx::glyphs_by at 10.5
  let look_fn = fn(at : GlyphAt) -> GlyphLook {
    { alpha: 1.0, dx: 0.0, dy: 0.0, scale: 1.0, sx: if at.index % 2 == 0 { 1.0 } else { 0.5 } }
  }
  let t_old = Tester::new(
    fn(c) {
      c.row(w=Px(300.0), h=Px(100.0), fn() {
        c.box(w=Px(10.5), h=Px(10.0), fn() {  }) |> ignore
        let col = c.column(w=Px(200.0), align=AStart, fn() { c.text("Glyphs scale", size=15.0, line=22.0) |> ignore })
        c.glyphs_by(col, look_fn)
      })
      |> ignore
    },
    w=400.0,
    h=200.0,
  )
  t_old.check_looks(false)
  t_old.draw()
  let old_xs = t_old.drawn_glyphs().map(fn(g) { (g.0 * 1000.0).round() })

  let t_new = Tester::new(fn(_c) {  }, w=400.0, h=200.0)
  t_new.check_looks(false)
  set_view_app(fn(root) {
    root.box(fn(p) {
      p.width(Is(Some(200.0))).height(Is(Some(60.0))).offset(Is((10.5, 0.0))) |> ignore
      p.box(fn(v) {
        v.words(Is("Glyphs scale")) |> ignore
        v.glyphs_by(Is(0), fn(_, at) { look_fn(at) }) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t_new.draw()
  let new_xs = t_new.drawn_glyphs().map(fn(g) { (g.0 * 1000.0).round() })
  assert_eq(new_xs, old_xs)

  // 3. InlineDrawing words in View::words_runs at fractional (10.5, 10.5) snap onto whole pixels via unplaced
  let drawing : InlineDrawing = { width: 2.0, height: 1.2, baseline: 0.9, paths: [], words: [("sin", 0.2, 0.9, 1.0)] }
  let t_math = Tester::new(fn(_c) {  }, w=400.0, h=200.0, platform=3, scale=1.5)
  set_view_app(fn(root) {
    root.box(fn(p) {
      p.width(Is(Some(200.0))).height(Is(Some(60.0))).offset(Is((10.25, 10.25))) |> ignore
      p.box(fn(v) {
        v.words_runs(Is([span("sin", drawing=Some(drawing))])) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t_math.draw()
  let math_gs = t_math.drawn_glyphs()
  assert_eq(math_gs.length(), 3)
  for g in math_gs {
    let px = g.0 * 1.5
    let py = g.1 * 1.5
    assert_true((px - px.round()).abs() < 1.0e-6, msg="px=\{px}")
    assert_true((py - py.round()).abs() < 1.0e-6, msg="py=\{py}")
  }

  // 4. glyph_drawn_any_sub recognizes base keys already drawn at subpixel phases 1..3
  // (used only for phase-less `shape` (`fresh`) prewarming, not for exact-phase `laid_ahead` deduplication)
  for k, _ in text_cache.glyphs {
    if (k >> 26) != 0 {
      assert_true(glyph_drawn_any_sub(k & 0x03FFFFFF))
    }
  }
}

///|
test "glyph phase: whole-pixel shifts keep phase across non-dyadic scales on half-point coordinates" {
  for sc in [1.5, 2.5, 2.625, 3.0, 3.25] {
    for base in [10.5, 137.5, 259.5] {
      let want = glyph_sub_at(77, base, sc, 1.0)
      for k in -200..=200 {
        let shifted = base + k.to_double() / sc
        assert_eq(glyph_sub_at(77, shifted, sc, 1.0), want)
      }
    }
  }
}
