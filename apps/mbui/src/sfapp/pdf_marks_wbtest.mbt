// Words of a PDF picked over the picture the host draws of it, and what is done with them: by what a person does (a
// drag, a held finger, the bar's keys) and what the chat's draft comes to hold.

///|
/// A PDF of three pages of 600 × 800, each a line of words at (100, 700) in a font 10 wide a letter at 20.
fn pdf_marks_file() -> Bytes {
  let out = StringBuilder()
  out.write_string("%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")
  out.write_string("2 0 obj\n<< /Type /Pages /MediaBox [0 0 600 800] /Count 3 /Kids [10 0 R 12 0 R 14 0 R] >>\nendobj\n")
  out.write_string("3 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /FirstChar 32 /LastChar 122 /Widths [")
  for _ in 32..=122 {
    out.write_string("500 ")
  }
  out.write_string("] /Encoding /WinAnsiEncoding >>\nendobj\n")
  for k, words in ["first page words", "second page words", "third page words"] {
    let c = "BT /F1 20 Tf 100 700 Td (\{words}) Tj ET"
    out.write_string("\{10 + 2 * k} 0 obj\n<< /Type /Page /Parent 2 0 R /Resources << /Font << /F1 3 0 R >> >> /Contents \{11 + 2 * k} 0 R >>\nendobj\n")
    out.write_string("\{11 + 2 * k} 0 obj\n<< /Length \{c.length()} >>\nstream\n\{c}\nendstream\nendobj\n")
  }
  out.write_string("trailer\n<< /Root 1 0 R >>\n%%EOF\n")
  let s = out.to_string()
  Bytes::makei(s.length(), fn(i) { s.code_unit_at(i).to_int().to_byte() })
}

///|
/// The preview of a PDF whose words are the file above's, and where its first page is drawn.
fn pdf_marks_tester(platform? : Int = 0, w? : Double = 390.0) -> (@ui.Tester, Viewer, Double, Double, Double, Double) {
  let t = preview_tester("pdf", platform~, w~)
  let v = viewer.get().unwrap()
  v.pdf_marks.doc = @pdftext.Doc::open(pdf_marks_file())
  v.pdf_marks.read = true
  t.draw()
  let img = t.drawn_images()[0]
  (t, v, img[0], img[1], img[2], img[3])
}

///|
test "a mouse's drag picks words; the bar copies them" {
  let (t, v, x, y, w, h) = pdf_marks_tester()
  let at = fn(u : Double, v : Double) { (x + u * w, y + v * h) }
  // ("first page": from the first letter's left to the tenth's right, on the line 100 down of 800)
  let (x0, y0) = at(100.5 / 600.0, 100.0 / 800.0)
  let (x1, y1) = at(199.5 / 600.0, 100.0 / 800.0)
  t.drag(x0, y0, x1, y1)
  assert_eq(v.pdf_marks.picked.get(), Some(Words(0, 0, 0, 10)))
  assert_eq(@sfbase.pdf_words_of(v.pdf_marks.doc, Words(0, 0, 0, 10)), "first page")
  assert_true(t.find("引用") is Some(_) && t.find("批注") is Some(_) && t.find("复制") is Some(_), msg="the bar")
  t.tap_text("复制")
  assert_true(v.pdf_marks.picked.get() is None, msg="copied, let go")
  // (picked again: the copy key copies it, Escape lets it go)
  t.drag(x0, y0, x1, y1)
  t.key(@ui.key_code_copy)
  assert_eq(t.clipboard(), "first page")
  t.key(@ui.key_escape)
  assert_true(v.pdf_marks.picked.get() is None, msg="Escape let go")
}

///|
test "a drag over onto the next page picks across them" {
  let (t, v, x, y, w, h) = pdf_marks_tester()
  let (x0, y0) = (x + 250.5 / 600.0 * w, y + 100.0 / 800.0 * h)
  // (the second page's line: a page and the gap between them down)
  let (x1, y1) = (x + 199.5 / 600.0 * w, y + h + 12.0 + 100.0 / 800.0 * h)
  let (_, wh) = (0.0, 844.0)
  guard y1 < wh else { fail("the second page's line is off the window") }
  t.drag(x0, y0, x1, y1)
  match v.pdf_marks.picked.get() {
    Some(Words(0, _, 1, 10)) => ()
    other => fail("picked \{Repr(other)}")
  }
}

///|
test "a drag off the words frames an area of the page" {
  let (t, v, x, y, w, h) = pdf_marks_tester()
  t.drag(x + 0.2 * w, y + 0.4 * h, x + 0.6 * w, y + 0.6 * h)
  match v.pdf_marks.picked.get() {
    Some(Area(0, x0, y0, x1, y1)) =>
      assert_true((x0 - 0.2).abs() < 0.01 && (y0 - 0.4).abs() < 0.01 && (x1 - 0.6).abs() < 0.01 && (y1 - 0.6).abs() < 0.01)
    other => fail("picked \{Repr(other)}")
  }
  let q = @sfbase.pdf_quote("设计说明.pdf", Area(0, 0.2, 0.4, 0.6, 0.6), "", "")
  assert_eq(q.0, "设计说明.pdf 第 1 页")
  assert_eq(q.1, "页面区域：距左 20%，距上 40%，宽 40%，高 20%")
}

///|
/// What the chat's draft quotes of the PDF: its notes' quotes.
fn pdf_draft_quotes() -> Array[Json] {
  @sfbase.writing(preview_src.val.unwrap(), "ws1/st1:s-c1").quotes.get().filter(fn(q) { text(Some(q), "role") == "pdf" })
}

///|
/// The same PDF opened again in the preview, its words read as the first time.
fn pdf_reopened(t : @ui.Tester, file : @sfbase.Attachment) -> Viewer {
  @sfbase.open_preview("ws1/st1", "s-c1", file, beside=false, steps=InChat(Some(1.0), "s-c1"))
  t.frame()
  t.run_for(@ui.move_most_ms)
  let v = viewer.get().unwrap()
  v.pdf_marks.doc = @pdftext.Doc::open(pdf_marks_file())
  v.pdf_marks.read = true
  t.draw()
  v
}

///|
test "a note is a quote in the chat's draft from the moment it is made; closed and opened again, the file shows it; out of the draft, it is gone" {
  let (t, v, x, y, w, h) = pdf_marks_tester()
  let src = preview_src.val.unwrap()
  t.drag(x + 100.5 / 600.0 * w, y + 100.0 / 800.0 * h, x + 199.5 / 600.0 * w, y + 100.0 / 800.0 * h)
  t.tap_text("批注")
  // (in the draft at once, before anything is said of it: its file and page, its words, where on the page)
  let quotes = pdf_draft_quotes()
  assert_eq(quotes.length(), 1, msg="in the draft as it is made")
  assert_eq(text(Some(quotes[0]), "author"), "设计说明.pdf 第 1 页")
  assert_eq(text(Some(quotes[0]), "text"), "first page")
  assert_true(text(Some(quotes[0]), "mark").has_suffix("w:0,0,0,10"), msg="where: \{text(Some(quotes[0]), "mark")}")
  assert_eq(v.pdf_notes().length(), 1)
  t.type_text("这里改一下")
  let (kx, ky, kw, kh) = t.get(Button, label="完成").rect
  // (its card at the stage's foot, as a picture's note is: never over the words round what it is said of)
  let (_, wh) = t.size()
  assert_true(ky > y + 100.0 / 800.0 * h + 40.0 && ky + kh <= wh, msg="the note's card at the foot: \{ky} in \{wh}")
  t.tap(kx + kw / 2.0, ky + kh / 2.0)
  assert_eq(text(Some(pdf_draft_quotes()[0]), "comment"), "这里改一下", msg="what is said of it, the quote's comment")
  assert_eq(v.pdf_notes()[0].comment, "这里改一下")
  // (去发送: back to the chat, the notes in its draft already)
  assert_true(t.find("1 条标注") is Some(_) && t.find("去发送") is Some(_), msg="what lists the notes and goes to send them")
  let file = v.file
  t.tap_text("去发送")
  t.run_for(@ui.move_most_ms)
  assert_true(viewer.get() is None, msg="closed back to the chat")
  assert_eq(pdf_draft_quotes().length(), 1, msg="still in the draft")
  assert_eq(text(Some(pdf_draft_quotes()[0]), "role"), "pdf")
  // (opened again: its note on the page and in the list, from the draft)
  let v = pdf_reopened(t, file)
  assert_eq(v.pdf_notes().map(fn(x) { (x.what, x.comment) }), [(Words(0, 0, 0, 10), "这里改一下")], msg="back on the page")
  assert_true(t.find("1 条标注") is Some(_), msg="listed again")
  // (taken out of the draft in the composer: gone from the page)
  let w = @sfbase.writing(src, "ws1/st1:s-c1")
  @sfbase.writing_unquote(src, w, text(Some(pdf_draft_quotes()[0]), "id"))
  t.draw()
  assert_eq(v.pdf_notes().length(), 0, msg="gone with its quote")
  assert_true(t.find("1 条标注") is None, msg="nothing listed")
}

///|
test "清除标注 takes this file's notes out of the draft, other quotes left in it" {
  let (t, v, x, y, w, h) = pdf_marks_tester(w=1280.0)
  let src = preview_src.val.unwrap()
  let draft = @sfbase.writing(src, "ws1/st1:s-c1")
  @sfbase.writing_quote(src, draft, { "author": Json::string("Willow"), "text": Json::string("别的引用"), "role": Json::string("agent") })
  pdf_note_made(t, x, y, w, h, said="改短一点")
  assert_eq(pdf_draft_quotes().length(), 1)
  t.tap_text("清除标注")
  t.draw()
  assert_eq(pdf_draft_quotes().length(), 0, msg="the file's notes out of the draft")
  assert_eq(draft.quotes.get().length(), 1, msg="the other quote left")
  assert_eq(v.pdf_notes().length(), 0)
}

///|
/// Long enough for a finger's fling over the pages to come to rest.
let pdf_fling_over_ms : Double = 3000.0

///|
test "a finger that moves scrolls the pages; one held picks the word under it" {
  let (t, v, x, y, w, h) = pdf_marks_tester(platform=2)
  let (px, py) = (x + 130.0 / 600.0 * w, y + 100.0 / 800.0 * h)
  t.drag(px, py + 120.0, px, py - 40.0)
  assert_true(v.pdf_marks.picked.get() is None, msg="a finger that moved picked nothing")
  // (its fling over: the second page's line, where it is now)
  t.run_for(pdf_fling_over_ms)
  let second = t.drawn_images()[1]
  assert_true(second[1] < y + h, msg="it scrolled")
  let held_y = second[1] + 100.0 / 800.0 * second[3]
  t.touch(0, px, held_y)
  t.run_for(@ui.long_press_ms + tap_hold_extra_ms)
  t.touch(2, px, held_y)
  t.draw()
  match v.pdf_marks.picked.get() {
    Some(what) => assert_eq(@sfbase.pdf_words_of(v.pdf_marks.doc, what), "second")
    None => fail("held at \{Repr((px, held_y))} on a page at \{Repr(t.drawn_images().map(fn(i) { (i[0], i[1], i[2], i[3]) }))}: nothing picked")
  }
}

///|
/// A note made on the first page's words, from a drag to 完成 (its words written first where `said`).
fn pdf_note_made(t : @ui.Tester, x : Double, y : Double, w : Double, h : Double, said? : String = "") -> Unit raise {
  t.drag(x + 100.5 / 600.0 * w, y + 100.0 / 800.0 * h, x + 199.5 / 600.0 * w, y + 100.0 / 800.0 * h)
  t.tap_text("批注")
  if said != "" {
    t.type_text(said)
  }
  let (kx, ky, kw, kh) = t.get(Button, label="完成").rect
  t.tap(kx + kw / 2.0, ky + kh / 2.0)
}

///|
test "wide: the notes stand at the pages' side; a card opens its note, its bin takes it off" {
  let (t, v, x, y, w, h) = pdf_marks_tester(w=1280.0)
  pdf_note_made(t, x, y, w, h, said="改短一点")
  t.draw()
  assert_true(t.find("1 条标注") is Some(_), msg="the column's head")
  assert_true(t.find("first page") is Some(_) && t.find("改短一点") is Some(_), msg="the card: its words and its note")
  // (the pages narrowed for the column, clear of it)
  let page = t.drawn_images()[0]
  assert_true(page[0] + page[2] <= 1280.0 - @sfbase.doc_notes_side_w, msg="the page clear of the column: \{Repr(page)}")
  // (no bar at the foot: the column has the keys)
  assert_true(t.find("回到输入框发送") is Some(_))
  t.tap_text("改短一点")
  assert_eq(v.pdf_marks.writing.get(), v.pdf_notes()[0].id, msg="the card opened its note")
  assert_eq(v.pdf_marks.note.text(), "改短一点")
  let (kx, ky, kw, kh) = t.get(Button, label="完成").rect
  t.tap(kx + kw / 2.0, ky + kh / 2.0)
  let bins = t.all(Button, label="删除批注")
  assert_true(bins.length() >= 1, msg="the card's bin")
  let (bx, by, bw, bh) = bins[0].rect
  t.tap(bx + bw / 2.0, by + bh / 2.0)
  assert_eq(v.pdf_notes().length(), 0, msg="taken off")
  assert_eq(pdf_draft_quotes().length(), 0, msg="out of the draft")
  t.draw()
  assert_true(t.find("1 条标注") is None, msg="the column gone with the last note")
}

///|
test "narrow: a count at the foot opens the notes in a sheet; a row opens its note on the page" {
  let (t, v, x, y, w, h) = pdf_marks_tester(platform=2)
  // (a finger: held on the words, slid along them)
  let (px, py) = (x + 100.5 / 600.0 * w, y + 100.0 / 800.0 * h)
  t.touch(0, px, py)
  t.run_for(@ui.long_press_ms + tap_hold_extra_ms)
  t.hold_move(x + 150.5 / 600.0 * w, py)
  t.hold_move(x + 199.5 / 600.0 * w, py)
  t.touch(2, x + 199.5 / 600.0 * w, py)
  t.draw()
  assert_eq(v.pdf_marks.picked.get(), Some(Words(0, 0, 0, 10)), msg="held and slid: the words")
  t.tap_text("批注")
  t.type_text("这里")
  let (kx, ky, kw, kh) = t.get(Button, label="完成").rect
  t.tap(kx + kw / 2.0, ky + kh / 2.0)
  t.draw()
  // (the foot: the count and 去发送, no column at this width)
  assert_true(t.find("1 条标注") is Some(_) && t.find("去发送") is Some(_), msg="the foot's count and 去发送")
  t.tap_text("1 条标注")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("第 1 页") is Some(_) && t.find("这里") is Some(_), msg="the sheet's row")
  t.tap_text("这里")
  t.run_for(@ui.move_most_ms)
  assert_eq(v.pdf_marks.writing.get(), v.pdf_notes()[0].id, msg="the row opened its note")
  // (the sheet gone, its note's field still takes what is typed)
  t.type_text("，短些")
  assert_eq(v.pdf_marks.note.text(), "这里，短些", msg="written on as the sheet went")
}

///|
test "a finger held off the words frames an area as it slides" {
  let (t, v, x, y, w, h) = pdf_marks_tester(platform=2)
  let (px, py) = (x + 0.3 * w, y + 0.5 * h)
  t.touch(0, px, py)
  t.run_for(@ui.long_press_ms + tap_hold_extra_ms)
  t.hold_move(x + 0.5 * w, y + 0.55 * h)
  t.hold_move(x + 0.7 * w, y + 0.6 * h)
  t.touch(2, x + 0.7 * w, y + 0.6 * h)
  t.draw()
  match v.pdf_marks.picked.get() {
    Some(Area(0, x0, y0, x1, y1)) =>
      assert_true((x0 - 0.3).abs() < 0.02 && (y0 - 0.5).abs() < 0.02 && (x1 - 0.7).abs() < 0.02 && (y1 - 0.6).abs() < 0.02)
    other => fail("picked \{Repr(other)}")
  }
  assert_true(t.find("批注") is Some(_), msg="its bar")
}

///|
/// A little longer than a long press, for a hold to be taken.
let tap_hold_extra_ms : Double = 20.0

///|
test "wide: doc_notes_side_node uses single-layer liquid panel glass with outside shadow, 1pt solid fallback, and stays clean in short window, long notes, 1.3x font scale, and keyboard focus" {
  let long_comment = "这段设计说明里的接口约束需要补充错误码与边界条件说明，同时确认多端降级行为保持一致"
  for dark in [false, true] {
    let at = "dark=\{dark}"
    let (t, _, x, y, w, h) = pdf_marks_tester(w=1280.0)
    // Switch theme via prefs.set + Tester host dark mode so full-app view(c, src) applies it on draw
    let src = preview_src.val.unwrap()
    (src.call)("prefs.set", { "appearance": Json::string(if dark { "dark" } else { "light" }) }, @sfbase.answer_unread)
    t.set_dark(dark)
    @ui.set_glass_solid(None)
    t.draw()
    assert_eq(@sf.theme().dark, dark, msg="\{at}: theme().dark must match")
    pdf_note_made(t, x, y, w, h, said=long_comment)
    t.run_for(@ui.move_most_ms)
    // Side panel lies on the right (`x >= 1280 - doc_notes_side_w - 24`)
    let side_x_min = 1280.0 - @sfbase.doc_notes_side_w - 24.0
    let side_glass = t.drawn_glass().filter(fn(g) { g.0 >= side_x_min && (g.2 - @sfbase.doc_notes_side_w).abs() < 2.0 })
    let side_liquid = side_glass.filter(fn(g) { g.4 == 6 })
    let side_outside_shadow = t
      .drawn_instances()
      .iter()
      .any(fn(a) {
        a.length() > 12 && a[5] == 2.0 && a[12] == 1.0 && a[0] >= side_x_min && (a[2] - @sfbase.doc_notes_side_w).abs() < 2.0
      })
    assert_eq((at, side_glass.length(), side_liquid.length(), side_outside_shadow), (at, 1, 1, true))
    assert_eq(t.corner_faults().filter(fn(f) { f.contains("doc_notes_node") }), [], msg="\{at}: glass corner faults")

    // MBUI_GLASS=solid fallback: 0 glass on side panel + 1pt border
    @ui.set_glass_solid(Some(true))
    t.draw()
    t.run_for(@ui.move_most_ms)
    assert_eq(@sf.theme().dark, dark, msg="\{at}: solid theme().dark must match")
    let solid_glass = t.drawn_glass().filter(fn(g) { g.0 >= side_x_min && (g.2 - @sfbase.doc_notes_side_w).abs() < 2.0 })
    let solid_edges = t
      .boxes_held()
      .filter(fn(b) { b.border_w >= 0.9 && b.x >= side_x_min && (b.w - @sfbase.doc_notes_side_w).abs() < 2.0 })
      .map(fn(b) { b.border_w })
    assert_eq((at, solid_glass.length(), solid_edges), (at, 0, [1.0]))
    @ui.set_glass_solid(None)
  }

  // Short window + long notes + 1.3x font scale + keyboard focus on top ("删除批注") & bottom ("回到输入框发送") buttons
  let (t, _, x, y, w, h) = pdf_marks_tester(w=1280.0)
  let src = preview_src.val.unwrap()
  (src.call)("prefs.set", { "appearance": Json::string("light") }, @sfbase.answer_unread)
  t.set_dark(false)
  @ui.set_glass_solid(None)
  t.draw()
  assert_eq(@sf.theme().dark, false)
  pdf_note_made(t, x, y, w, h, said=long_comment)
  t.set_font_scale(1.3)
  t.resize(1280.0, 420.0)
  t.run_for(@ui.move_most_ms)
  let clear_btn = t.get(Button, label="清除标注")
  let send_btn = t.get(Button, label="回到输入框发送")
  let del_btn = t.all(Button, label="删除批注")[0]
  // Side heading ("1 条标注") left edge must align with first note card left edge (<= 0.5pt, zero inset shift)
  guard t.words().filter(fn(wd) { wd.0.contains("条标注") }) is [(_, head_x, _, _, _, _), ..] else {
    fail("side heading containing 条标注 not found")
  }
  let note_card = t.get(Button, label="第 1 页 first page")
  assert_true(
    (head_x - note_card.rect.0).abs() <= 0.5,
    msg="side heading left \{head_x} must align with first note card left \{note_card.rect.0} (<= 0.5pt)",
  )
  assert_true(clear_btn.rect.1 >= 0.0 && clear_btn.rect.1 + clear_btn.rect.3 <= 420.0, msg="clear btn visible in short window")
  assert_true(send_btn.rect.1 >= 0.0 && send_btn.rect.1 + send_btn.rect.3 <= 420.0, msg="send btn visible in short window")
  assert_true(del_btn.rect.1 >= 0.0 && del_btn.rect.1 + del_btn.rect.3 <= 420.0, msg="top delete btn visible in short window")
  // Step with t.tab() until top "删除批注" and bottom "回到输入框发送" each receive focus,
  // verifying live frame visibility, 0 faults (both doc_notes_node & viewer_marks_node),
  // and that the theme outer focus ring is actually drawn with all 4 edges unclipped inside [0, 1280] × [0, 420].
  let check_focus_ring = fn(label : String, rect : (Double, Double, Double, Double)) raise {
    let th = @ui.tree_theme()
    let out = th.focus_gap + th.focus_w
    let fc = th.focus
    let fr = ((fc >> 24) & 0xFFL).to_double() / 255.0
    let fg = ((fc >> 16) & 0xFFL).to_double() / 255.0
    let fb = ((fc >> 8) & 0xFFL).to_double() / 255.0
    let fa = (fc & 0xFFL).to_double() / 255.0
    let exp_x = rect.0 - out
    let exp_y = rect.1 - out
    let exp_w = rect.2 + 2.0 * out
    let exp_h = rect.3 + 2.0 * out
    let rings = t
      .drawn_instances()
      .filter(fn(a) {
        a.length() >= 20 &&
        a[5] == 0.0 &&
        a[11] == 0.0 &&
        (a[6] - th.focus_w).abs() < 0.2 &&
        (a[12] - fr).abs() < 0.02 &&
        (a[13] - fg).abs() < 0.02 &&
        (a[14] - fb).abs() < 0.02 &&
        (a[15] - fa).abs() < 0.02 &&
        (a[0] - exp_x).abs() < 1.5 &&
        (a[1] - exp_y).abs() < 1.5 &&
        (a[2] - exp_w).abs() < 3.0 &&
        (a[3] - exp_h).abs() < 3.0
      })
    guard rings is [ring, ..] else {
      fail("focus ring not drawn for \{label} rect=\{Repr(rect)} expected=(\{exp_x},\{exp_y},\{exp_w},\{exp_h})")
    }
    let rx0 = ring[0]
    let ry0 = ring[1]
    let rx1 = ring[0] + ring[2]
    let ry1 = ring[1] + ring[3]
    assert_true(
      rx0 >= 0.0 && ry0 >= 0.0 && rx1 <= 1280.0 && ry1 <= 420.0,
      msg="focus ring for \{label} outside viewport: (\{rx0},\{ry0})..(\{rx1},\{ry1})",
    )
    assert_true(
      rx0 >= ring[16] - 0.5 && ry0 >= ring[17] - 0.5 && rx1 <= ring[18] + 0.5 && ry1 <= ring[19] + 0.5,
      msg="focus ring for \{label} clipped: ring=(\{rx0},\{ry0})..(\{rx1},\{ry1}) clip=(\{ring[16]},\{ring[17]})..(\{ring[18]},\{ring[19]})",
    )
  }
  let mut hit_top = false
  let mut hit_bottom = false
  for _ in 0..<24 {
    t.tab()
    match t.focused() {
      Some(s) if s.label == "删除批注" => {
        hit_top = true
        assert_true(s.rect.1 >= 0.0 && s.rect.1 + s.rect.3 <= 420.0, msg="focused top btn in [0,420]: \{Repr(s.rect)}")
        assert_eq(
          t.corner_faults().filter(fn(f) { f.contains("doc_notes_node") || f.contains("viewer_marks_node") }),
          [],
          msg="focused top btn corner faults",
        )
        assert_eq(
          t.focus_visible_faults().filter(fn(f) { f.contains("doc_notes_node") || f.contains("viewer_marks_node") }),
          [],
          msg="focused top btn focus visible",
        )
        check_focus_ring("删除批注", s.rect)
      }
      Some(s) if s.label == "回到输入框发送" => {
        hit_bottom = true
        assert_true(s.rect.1 >= 0.0 && s.rect.1 + s.rect.3 <= 420.0, msg="focused bottom btn in [0,420]: \{Repr(s.rect)}")
        assert_eq(
          t.corner_faults().filter(fn(f) { f.contains("doc_notes_node") || f.contains("viewer_marks_node") }),
          [],
          msg="focused bottom btn corner faults",
        )
        assert_eq(
          t.focus_visible_faults().filter(fn(f) { f.contains("doc_notes_node") || f.contains("viewer_marks_node") }),
          [],
          msg="focused bottom btn focus visible",
        )
        check_focus_ring("回到输入框发送", s.rect)
      }
      _ => ()
    }
    if hit_top && hit_bottom {
      break
    }
  }
  assert_true(hit_top, msg="Tab reached top 删除批注 button; last focused=\{t.focus_said()}")
  assert_true(hit_bottom, msg="Tab reached bottom 回到输入框发送 button; last focused=\{t.focus_said()}")
  @ui.set_glass_solid(None)
}
