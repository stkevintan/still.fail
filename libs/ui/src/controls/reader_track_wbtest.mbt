// A phone's reader's track (reader_node's on 小屏): a tap or a drag along it goes there as it is let go, by the text's
// length, whatever its blocks are.

///|
/// A reading of `book` (as `key`) made as nodes in a phone's window `w` by `h`, its bars shown, at rest.
fn track_tester(key : String, book : Book, w? : Double = 390.0, h? : Double = 844.0) -> (@ui.Tester, Reading) {
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w~, h~, platform=2)
  // (its book here already: nothing read; after the run begins, which lets go of every reading)
  let r = reading_for(key)
  r.asked = true
  r.book.set(Some(book))
  r.chrome.set(true)
  let file = blob_file(@utf8.encode(book.text), "book.txt", book.length.to_double(), save=fn() {  })
  @ui.set_view_app(fn(root) {
    reader_node(root, key, file, markdown=false, back_label=fn() { "返回" }, on_back=fn() {  }) |> ignore
  })
  t.draw()
  t.run_for(@ui.move_most_ms)
  (t, r)
}

///|
/// A book of `chunks`, its text all of them.
fn track_book(id : Int, title : String, chunks : Array[String]) -> Book {
  let starts = []
  let mut at = 0
  for c in chunks {
    starts.push(at)
    at += c.length()
  }
  {
    title,
    id,
    text: chunks.join(""),
    chunks,
    starts,
    parts: [],
    length: at,
    chapters: [],
    heads: Map([]),
    encoding: "UTF-8",
    truncated: false,
    markdown: false,
  }
}

///|
test "the reader's track jumps on a tap with no frame drawn while pressed" {
  let (t, r) = track_tester("track-tap", track_book(1, "Book", ["a", "b", "c", "d"]))
  let (x, y, w, h) = t.get(Slider).rect
  t.tap(x + w * 0.75, y + h / 2.0)
  assert_eq(r.jump.get().map(fn(j) { j.0 }), Some(3), msg="the tap reaches the selected part")
  // Start a drag in one frame, then move and release before the next.
  t.touch(0, x + w * 0.2, y + h / 2.0)
  t.draw()
  t.touch(1, x + w * 0.9, y + h / 2.0)
  t.touch(2, x + w * 0.9, y + h / 2.0)
  t.draw()
  assert_eq(r.jump.get().map(fn(j) { j.0 }), Some(3), msg="the drag reaches where it ended")
  reader_let_go("track-tap")
}

///|
test "a short book's track reaches the middle of its text" {
  let words = "0123456789".repeat(10)
  let (t, r) = track_tester("track-short", track_book(2, "Short book", [words]))
  let (x, y, w, h) = t.get(Slider).rect
  t.tap(x + w / 2.0, y + h / 2.0)
  assert_eq(r.jump.get(), Some((0, 50, true)), msg="the middle of the track reaches the middle of the text")
  reader_let_go("track-short")
}

///|
test "tapping the middle of a short book's track scrolls its text" {
  let words = "小说正文".repeat(225)
  let (t, r) = track_tester("track-short-scroll", track_book(4, "Short book", [words]), h=350.0)
  let (x, y, w, h) = t.get(Slider).rect
  t.tap(x + w / 2.0, y + h / 2.0)
  t.run_for(@ui.move_most_ms)
  guard r.list.sight_now() is Some(s) else { fail("the list says nothing in sight") }
  assert_eq(s.first, 0)
  assert_true(s.into > 0.0, msg="the text moved down from its beginning: \{Repr(s)}")
  reader_let_go("track-short-scroll")
}

///|
test "a book's track follows text position when its blocks have different lengths" {
  let book = track_book(3, "Uneven book", ["a".repeat(90), "b".repeat(10)])
  assert_true((reader_fraction(book, (0, 0.5)) - 0.45).abs() < 0.000001, msg="halfway through the first 90 characters is 45% of the book")
  let (t, r) = track_tester("track-uneven", book)
  let (x, y, w, h) = t.get(Slider).rect
  t.tap(x + slider_thumb_room / 2.0 + (w - slider_thumb_room) * 0.95, y + h / 2.0)
  assert_eq(r.jump.get().map(fn(j) { (j.0, j.1) }), Some((1, 5)), msg="95% reaches the middle of the last 10 characters")
  reader_let_go("track-uneven")
}

///|
test "on 小屏 a panel open keeps no room of the text's: the column as wide under its sheet as without it" {
  let words = "小说正文".repeat(60)
  let (t, r) = track_tester("track-panel", track_book(5, "Book", [words]))
  let line = fn() {
    match t.words().filter(fn(w) { w.0.contains("小说正文") }) {
      [w, ..] => w.3
      _ => 0.0
    }
  }
  let was = line()
  @ui.view_tree().unwrap().event(t.time(), fn() { reader_open_panel(r, Contents) })
  t.run_for(@ui.move_most_ms)
  assert_true(was > 200.0 && line() == was, msg="as wide: \{was}, then \{line()}")
  reader_let_go("track-panel")
}

///|
let reader_slider_hold_ms : Double = 250.0

///|
let reader_slider_drag_ms : Double = 200.0

///|
let reader_slider_settle_ms : Double = 600.0

///|
test "phone reader position slider emits zero extra liquid glass instances while held, dragged, and releasing" {
  let words = "小说正文".repeat(120)
  let (t, _) = track_tester("track-no-lens", track_book(6, "Book", [words]))
  let rest_glass = t.drawn_glass().length()
  let (x, y, w, h) = t.get(Slider).rect
  let cy = y + h / 2.0
  t.press_at(x + w * 0.25, cy)
  t.run_for(reader_slider_hold_ms)
  assert_eq(t.drawn_glass().length(), rest_glass, msg="held phone position slider must not add a second glass layer")
  t.move_to(x + w * 0.65, cy)
  t.run_for(reader_slider_drag_ms)
  assert_eq(t.drawn_glass().length(), rest_glass, msg="dragging phone position slider must not add a second glass layer")
  t.release(x + w * 0.65, cy)
  t.run_for(reader_slider_settle_ms)
  assert_eq(t.drawn_glass().length(), rest_glass, msg="releasing phone position slider must not add a second glass layer")
  reader_let_go("track-no-lens")
}

///|
test "reader layout sliders: Tab focus + arrow keys update value and focus ring follows thumb" {
  let tr = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=900.0, h=700.0, platform=0)
  let prev_words = words_of.val
  set_words(default_words)
  set_language(Some("zh"))
  set_viewer_host(viewer_host_default())
  (viewer_host().set_reader_style)(Line(1.7))
  @ui.set_view_app(
    fn(root) {
      reader_layout_docked(root, fn() {  })
    },
    theme=ui_theme_now,
  )
  tr.draw()
  let line_label = t("web-pages.drive.reader.lines")
  // Tab until the line-spacing slider has keyboard focus (focus_shown == true)
  let mut reached = false
  for _ in 0..<20 {
    tr.tab()
    if tr.focused().map(fn(s) { s.label }) == Some(line_label) {
      reached = true
      break
    }
  }
  assert_true(reached, msg="Tab must reach line-spacing slider")
  let ring_x = fn() -> Double raise {
    let sl_rect = tr.get(Slider, label=line_label).rect
    let mut best = -1.0
    for inst in tr.drawn_instances() {
      // Focus ring is a 44x30 rounded rect (38x24 capsule thumb + 6) within the slider rect
      if inst[5] == 0.0 &&
        (inst[2] - 44.0).abs() < 0.5 &&
        (inst[3] - 30.0).abs() < 0.5 &&
        inst[0] >= sl_rect.0 - 4.0 &&
        inst[0] + inst[2] <= sl_rect.0 + sl_rect.2 + 4.0 &&
        inst[1] >= sl_rect.1 - 4.0 &&
        inst[1] <= sl_rect.1 + sl_rect.3 {
        best = inst[0]
      }
    }
    best
  }
  let x0 = ring_x()
  assert_true(x0 > 0.0, msg="focused line-spacing slider must draw 44x30 focus ring")
  tr.key(@ui.key_code_right)
  tr.key(@ui.key_code_right)
  tr.key(@ui.key_code_right)
  tr.key(@ui.key_code_right)
  tr.run_for(reader_slider_settle_ms)
  let x1 = ring_x()
  assert_true(x1 > x0 + 4.0, msg="focus ring must move right with thumb after Right arrow keys: \{x0} -> \{x1}")
  assert_true((viewer_host().reader_style)().line > 1.7, msg="Right arrow must increase line spacing")
  (viewer_host().set_reader_style)(Line(reader_style_default.line))
  set_language(None)
  set_words(prev_words)
}

///|
test "phone reader position slider: disabled while book == None keeps thumb, percent, and a11y at 0%; works after book loads" {
  let words = "小说正文".repeat(120)
  let book = track_book(7, "Loaded", [words])
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=390.0, h=844.0, platform=2)
  let r = reading_for("track-loading")
  r.asked = true
  r.chrome.set(true)
  let file = blob_file(@utf8.encode(book.text), "book.txt", book.length.to_double(), save=fn() {  })
  @ui.set_view_app(fn(root) {
    reader_node(root, "track-loading", file, markdown=false, back_label=fn() { "返回" }, on_back=fn() {  }) |> ignore
  })
  t.draw()
  t.run_for(@ui.move_most_ms)
  // 1. Loading (book == None): slider is disabled; press/drag/release leaves thumb, pct, and a11y at 0%
  let sl_loading = t.get(Slider)
  assert_true(sl_loading.disabled, msg="phone position slider must be disabled while book == None")
  let (x, y, w, h) = sl_loading.rect
  let cy = y + h / 2.0
  t.press_at(x + w * 0.5, cy)
  t.run_for(reader_slider_hold_ms)
  t.move_to(x + w * 0.8, cy)
  t.run_for(reader_slider_drag_ms)
  t.release(x + w * 0.8, cy)
  t.run_for(reader_slider_settle_ms)
  assert_eq(t.get(Slider).value, "0", msg="a11y value must stay 0 while loading")
  assert_true(t.words().any(fn(wd) { wd.0 == "0%" }), msg="percentage must stay 0% while loading")
  // 2. Book loads: slider becomes enabled; drag updates preview and commits with 0 extra glass
  @ui.view_tree().unwrap().event(t.time(), fn() { r.book.set(Some(book)) })
  t.draw()
  assert_true(!t.get(Slider).disabled, msg="phone position slider must enable once book loads")
  let rest_glass = t.drawn_glass().length()
  t.press_at(x + w * 0.45, cy)
  t.run_for(reader_slider_hold_ms)
  assert_eq(t.drawn_glass().length(), rest_glass, msg="held after load must add 0 glass")
  t.release(x + w * 0.45, cy)
  t.run_for(reader_slider_settle_ms)
  assert_eq(t.drawn_glass().length(), rest_glass, msg="released after load must add 0 glass")
  assert_true(r.jump.get() is Some(_), msg="release after book loads must commit jump")
  reader_let_go("track-loading")
}

///|
test "reader slider_node: rejected value keeps thumb synced to model value and narrowing during drag still releases lens" {
  let model = @signals.signal(20.0)
  let box_w = @signals.signal(240.0)
  let t = w2_case(w=600.0, fn(root) {
    root.box(fn(wrap) {
      wrap.width(By(fn() { Some(box_w.get()) })) |> ignore
      slider_node(
        wrap,
        fn() { "受限滑块" },
        fn() { model.get() },
        0.0,
        100.0,
        1.0,
        fn() { reader_paper("white") },
        fn(v) {
          // Reject values above 40.0 (clamp model to <= 40.0)
          model.set(if v > 40.0 { 40.0 } else { v })
        },
        fn(_) {  },
        lens_enabled=true,
      )
    })
    |> ignore
  })
  t.run_for(@ui.move_most_ms)
  let sl = t.get(Slider, label="受限滑块").rect
  let cy = sl.1 + sl.3 / 2.0
  // Press and drag to 90% -> model clamps to 40.0
  t.press_at(sl.0 + sl.2 * 0.9, cy)
  t.run_for(reader_slider_hold_ms)
  assert_eq(model.untracked(), 40.0)
  // Shrink container width <= slider_thumb_room while still pressed, then release -> lens must release to 0 glass
  @ui.view_tree().unwrap().event(t.time(), fn() { box_w.set(16.0) })
  t.draw()
  t.release(sl.0 + sl.2 * 0.9, cy)
  t.run_for(reader_slider_settle_ms)
  assert_eq(t.drawn_glass().length(), 0, msg="releasing after narrowing <= thumb_room must still release liquid lens")
  // Restore width and verify thumb aligns with clamped model value (40%)
  @ui.view_tree().unwrap().event(t.time(), fn() { box_w.set(240.0) })
  t.draw()
  let sl2 = t.get(Slider, label="受限滑块").rect
  let knobs = t.drawn_rects().filter(fn(r) {
    r.4 == 0xFFFFFFFFL &&
    (r.2 - @glass.slider_thumb_w).abs() < 0.5 &&
    (r.3 - @glass.slider_thumb_h).abs() < 0.5
  })
  assert_eq(knobs.length(), 1, msg="expected 1 white 38x24 capsule thumb rect after restore")
  let cx = knobs[0].0 + knobs[0].2 / 2.0
  let expected_cx = sl2.0 + slider_thumb_room / 2.0 + (sl2.2 - slider_thumb_room) * 0.4
  assert_true((cx - expected_cx).abs() < 1.0, msg="thumb center \{cx} must align with clamped model 40% (\{expected_cx})")
}
