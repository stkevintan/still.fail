// Markdown as nodes (markdown_node) drawn as an old view's markdown draws the same words read the same way: each block,
// its words where they are, every instance the window draws.

///|
/// The core's reading of mn_text (its tree as markdown.ts writes it: blocks, their words in strings).
fn mn_tree() -> Json {
  let p = fn(xs : Array[Json]) { Json::array([Json::string("p"), Json::array(xs)]) }
  let s = fn(x : String) { Json::string(x) }
  let el = fn(name : String, kids : Array[Json]) { Json::array([Json::string(name), Json::array(kids)]) }
  let li = fn(kids : Array[Json], a : Json) { Json::array([Json::string("li"), Json::array(kids), a]) }
  Json::array([
    Json::array([s("h"), Json::array([s("今天的进度")]), Json::object({ "depth": Json::number(2.0) })]),
    p([s("改好了 "), el("b", [s("布局")]), s(" 和 "), el("i", [s("动画")]), s("，见 "), Json::array([s("a"), Json::array([s("说明")]), Json::object({ "href": s("https://example.com/notes") })]), s("。")]),
    Json::array([
      s("list"),
      Json::array([
        li([s("第一项，"), Json::array([s("code"), Json::array([]), Json::object({ "content": s("inline code") })])], Json::object({})),
        li([s("第二项"), Json::array([s("list"), Json::array([li([s("nested one")], Json::object({}))]), Json::object({ "ordered": Json::boolean(true), "start": Json::number(1.0) })])], Json::object({})),
        li([s("做完的事")], Json::object({ "checked": Json::boolean(true) })),
      ]),
      Json::object({}),
    ]),
    el("quote", [p([s("引用里的一句话")])]),
    Json::array([s("pre"), Json::array([]), Json::object({ "code": s("moon test --target native src/sf/markdown_node_wbtest.mbt"), "lang": s("sh"), "ink": s("") })]),
    el("hr", []),
    p([s("最后一段。")]),
  ])
}

///|
let mn_text : String = "（mn_tree 的原文）"

///|
/// The words drawn now, each with where it is, in one order.
fn mn_words(t : @ui.Tester) -> Array[String] {
  let all = t.words().map(fn(w) { "\{w.0} at \{(w.1 * 100.0).round() / 100.0},\{(w.2 * 100.0).round() / 100.0}" })
  all.sort()
  all
}

///|
/// Every instance the window drew last, each its numbers to a hundredth, in one order (read at once: the Tester's are
/// what the window last drew); a glyph's place in its atlas left out (where the order glyphs were first drawn in put
/// it), which atlas kept.
fn mn_instances(t : @ui.Tester) -> Array[String] {
  let all = t.drawn_instances_keyed().map(fn(a) {
    a
    .mapi(fn(j, x) {
      if a[5] == 1.0 && j == 12 {
        if x >= 16384.0 { "colour" } else { "mono" }
      } else if a[5] == 1.0 && j == 13 {
        "-"
      } else {
        ((x * 100.0).round() / 100.0).to_string()
      }
    })
    .join(",")
  })
  all.sort()
  all
}

///|
/// mn_tree's words in a column 16 in from a window `w` wide, drawn as nodes.
fn mn_tester(w : Double, platform : Int) -> @ui.Tester {
  let tree = mn_tree()
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w~, h=900.0, platform~)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.lines_up(Is(None)) |> ignore
    root.box(fn(b) {
      b.padding(Is((16.0, 16.0, 16.0, 16.0))) |> ignore
      markdown_node(b, fn() { mn_text }, tree=fn() { Some(tree) }) |> ignore
    })
    |> ignore
  })
  t.draw()
  t.draw()
  t
}

///|
test "Markdown as nodes: its blocks' words drawn in order, with a finger and with a mouse" {
  for case in [(390.0, 2), (800.0, 0)] {
    let (w, platform) = case
    let made_t = mn_tester(w, platform)
    let made = mn_words(made_t)
    // (each block's words drawn, the heading's to the last paragraph's)
    assert_true(made.iter().any(fn(x) { x.has_prefix("今天的进度") }), msg="\{Repr(case)}: \{Repr(made)}")
    assert_true(made.iter().any(fn(x) { x.has_prefix("改好了") }), msg="\{Repr(case)}: \{Repr(made)}")
    assert_true(made.iter().any(fn(x) { x.has_prefix("第一项") }), msg="\{Repr(case)}: \{Repr(made)}")
    assert_true(made.iter().any(fn(x) { x.has_prefix("nested one") }), msg="\{Repr(case)}: \{Repr(made)}")
    assert_true(made.iter().any(fn(x) { x.has_prefix("做完的事") }), msg="\{Repr(case)}: \{Repr(made)}")
    assert_true(made.iter().any(fn(x) { x.has_prefix("引用里的一句话") }), msg="\{Repr(case)}: \{Repr(made)}")
    assert_true(made.iter().any(fn(x) { x.has_prefix("最后一段。") }), msg="\{Repr(case)}: \{Repr(made)}")
    let (_, y_head, _, _) = made_t.rect_of("今天的进度").unwrap()
    let (_, y_quote, _, _) = made_t.rect_of("引用里的一句话").unwrap()
    let (_, y_last, _, _) = made_t.rect_of("最后一段。").unwrap()
    assert_true(y_head < y_quote && y_quote < y_last, msg="\{Repr(case)}: \{y_head} < \{y_quote} < \{y_last}")
  }
}

///|
/// A Markdown node of `text` read as `tree` says (as it changes) at `size`, its code blocks of language `a` and `b` and
/// the files it names drawn as words saying which, a .jpg an image `ratio` wide over its height saying the width it is
/// given; in a window 390 wide. What the tree draws, its words.
fn mn_live(text : () -> String, tree : () -> Json?, size : () -> Double, ratio? : () -> Double = fn() { 1.0 }) -> @ui.Tester {
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=390.0, h=900.0, platform=2)
  let said = fn(v : @view.View, words : () -> String) { v.words(By(words)) |> ignore }
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    markdown_node(
      root,
      text,
      tree~,
      size~,
      code=fn(lang) {
        match lang {
          "a" | "b" => Some(fn(v, code) { said(v, fn() { lang + ":" + code() }) })
          _ => None
        }
      },
      files=fn(name) {
        if name.has_suffix(".png") {
          Some({ draw: fn(v) { said(v, fn() { "file:" + name }) }, image: None })
        } else if name.has_suffix(".jpg") {
          Some({
            draw: fn(v) { said(v, fn() { "file:" + name }) },
            image: Some((ratio(), fn(v, width) { said(v, fn() { "img:" + name + ":" + width().to_string() }) })),
          })
        } else {
          None
        }
      },
    )
    |> ignore
  })
  t.draw()
  t
}

///|
/// The words of the window's tree drawn now and the size each is set at.
fn mn_drawn() -> Array[(String, Double)] {
  @ui.view_tree().unwrap().drawn().filter(fn(d) { d.words != "" }).map(fn(d) { (d.words, d.words_look.size) })
}

///|
test "Markdown as nodes: a code block's language changed draws it as the new one's; its code changed, as it is now" {
  let lang = @signals.signal("a")
  let code = @signals.signal("x")
  let tree = fn() {
    Some(Json::array([Json::array([Json::string("pre"), Json::array([]), Json::object({ "code": Json::string(code.get()), "lang": Json::string(lang.get()) })])]))
  }
  // (its text as it is read: what a reading is kept by, as a message's words are)
  let t = mn_live(fn() { "```" + lang.get() + "\n" + code.get() + "\n```" }, tree, fn() { 15.0 })
  assert_true(mn_drawn().iter().any(fn(d) { d.0 == "a:x" }), msg="\{Repr(mn_drawn())}")
  code.set("y")
  t.draw()
  assert_true(mn_drawn().iter().any(fn(d) { d.0 == "a:y" }), msg="\{Repr(mn_drawn())}")
  lang.set("b")
  t.draw()
  assert_true(mn_drawn().iter().any(fn(d) { d.0 == "b:y" }), msg="\{Repr(mn_drawn())}")
  assert_true(!mn_drawn().iter().any(fn(d) { d.0.has_prefix("a:") }), msg="\{Repr(mn_drawn())}")
}

///|
test "Markdown as nodes: a paragraph of only a link to a file the message places draws that file; the link to another, the other" {
  let href = @signals.signal("x.png")
  let tree = fn() {
    Some(
      Json::array([
        Json::array([
          Json::string("p"),
          Json::array([Json::array([Json::string("a"), Json::array([Json::string("图")]), Json::object({ "href": Json::string(href.get()) })])]),
        ]),
      ]),
    )
  }
  let t = mn_live(fn() { "[图](" + href.get() + ")" }, tree, fn() { 15.0 })
  assert_true(mn_drawn().iter().any(fn(d) { d.0 == "file:x.png" }), msg="\{Repr(mn_drawn())}")
  href.set("y.png")
  t.draw()
  assert_true(mn_drawn().iter().any(fn(d) { d.0 == "file:y.png" }), msg="\{Repr(mn_drawn())}")
  assert_true(!mn_drawn().iter().any(fn(d) { d.0 == "file:x.png" }), msg="\{Repr(mn_drawn())}")
}

///|
test "Markdown as nodes: its words' size changed, its paragraphs and headings set at the new one, the same nodes" {
  let size = @signals.signal(15.0)
  let tree = fn() {
    Some(
      Json::array([
        Json::array([Json::string("h"), Json::array([Json::string("标题")]), Json::object({ "depth": Json::number(1.0) })]),
        Json::array([Json::string("p"), Json::array([Json::string("一段话")])]),
      ]),
    )
  }
  let t = mn_live(fn() { "size" }, tree, fn() { size.get() })
  let size_of = fn(w : String) {
    match mn_drawn().search_by(fn(d) { d.0 == w }) {
      Some(i) => mn_drawn()[i].1
      None => -1.0
    }
  }
  assert_eq((size_of("标题"), size_of("一段话")), (15.0, 15.0))
  size.set(20.0)
  t.draw()
  assert_eq((size_of("标题"), size_of("一段话")), (20.0, 20.0))
}

///|
test "Markdown as nodes: a row of images, one of them twice, each drawn at the width it has as the window and their widths change" {
  let ratio = @signals.signal(1.0)
  let img = fn(src : String) { Json::array([Json::string("img"), Json::array([]), Json::object({ "src": Json::string(src), "alt": Json::string("") })]) }
  let tree = fn() { Some(Json::array([Json::array([Json::string("p"), Json::array([img("a.jpg"), img("a.jpg"), img("b.jpg")])])])) }
  let t = mn_live(fn() { "images" }, tree, fn() { 15.0 }, ratio=fn() { ratio.get() })
  // (each image's words and the width it says, with the width it is drawn at)
  let images = fn() {
    @ui.view_tree().unwrap().drawn().filter(fn(d) { d.words.has_prefix("img:") }).map(fn(d) { (d.words, d.w) })
  }
  let said_as_drawn = fn() {
    images().iter().all(fn(d) { d.0.has_suffix(":" + d.1.to_string()) })
  }
  let first = images()
  assert_eq(first.filter(fn(d) { d.0.has_prefix("img:a.jpg:") }).length(), 2, msg="\{Repr(first)}")
  assert_eq(first.filter(fn(d) { d.0.has_prefix("img:b.jpg:") }).length(), 1, msg="\{Repr(first)}")
  assert_true(said_as_drawn(), msg="\{Repr(first)}")
  t.resize(600.0, 900.0)
  t.draw()
  let wider = images()
  assert_true(said_as_drawn(), msg="\{Repr(wider)}")
  assert_true(wider[0].1 > first[0].1, msg="\{Repr(first)} \{Repr(wider)}")
  ratio.set(0.5)
  t.draw()
  let narrower = images()
  assert_eq(narrower.length(), 3, msg="\{Repr(narrower)}")
  assert_true(said_as_drawn(), msg="\{Repr(narrower)}")
  assert_true(narrower[0].1 < wider[0].1, msg="\{Repr(wider)} \{Repr(narrower)}")
}

///|
/// `code` in a code block in a column 16 in from a window `w` wide (a finger's at 390, a mouse's wider), in the colours
/// `ink` says where it says them, the system's words at `scale`, wrapped at its width where `wrapped` (its wrap key
/// pressed), drawn as nodes (`code_block_node`): its Tester, drawn.
fn mlines_tester(code : String, ink : String?, w : Double, scale : Double, wrapped : Bool) -> @ui.Tester raise {
  let platform = if w < 500.0 { 2 } else { 0 }
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w~, h=900.0, platform~)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.lines_up(Is(None)) |> ignore
    root.box(fn(b) {
      b.padding(Is((16.0, 16.0, 16.0, 16.0))) |> ignore
      b.box(fn(k) { code_block_node(k, fn() { code }, fn() { "sh" }, fn() { ink }) }) |> ignore
    })
    |> ignore
  })
  t.set_font_scale(scale)
  t.draw()
  t.draw()
  if wrapped {
    if w < 500.0 {
      t.tap_text(md_wrap_words(false))
    } else {
      // (with a mouse its keys are made while the pointer is on the block: over its first line, then its wrap key)
      let first = code.split("\n").to_array()[0].to_owned()
      match t.rect_of(first) {
        Some(r) => t.move_to(r.0 + 2.0, r.1 + 2.0)
        None => ()
      }
      t.draw()
      t.click(Button, label=md_wrap_words(false))
    }
    t.run_for(@ui.move_most_ms)
  }
  t
}

///|
/// Code of more lines in a code block, wrapped at its width (`wrapped`) or on its lines as written, drawn as nodes:
/// each case at 760 and 390, words at 1 and 1.3.
fn mlines_alike(wrapped : Bool) -> Unit raise {
  let long = "printf '%s\\n' \"a line of a script long enough to run past a phone's width and past a desktop's at its size, on and on\""
  let cases : Array[(String, String, String?)] = [
    ("two lines", "moon test --target wasm-gc src/sf/markdown_node_wbtest.mbt\nmoon check", None),
    ("an empty line", "a = 1\n\nb = 2", None),
    ("a long line among short ones", "set -e\n" + long + "\ndone", None),
    ("a break at its end", "line one\nline two\n", None),
    ("in a language's colours", "let x = 1\n// note\nfoo(\"hi\")\n", Some("h3a1j1a1c1a1f1a1b7a1i3c1d4c1a1")),
  ]
  for case in cases {
    let (name, code, ink) = case
    for w in [760.0, 390.0] {
      for scale in [1.0, 1.3] {
        let at = "\{name}, \{w} wide, words at \{scale}\{if wrapped { ", wrapped" } else { "" }}"
        let made_t = mlines_tester(code, ink, w, scale, wrapped)
        let lines = code.split("\n").to_array().filter(fn(l) { l != "" }).map(fn(l) { l.to_owned() })
        let rows = lines.map(fn(l) { made_t.run_rects(l) })
        if !wrapped {
          // (each a line of its own, one under the other)
          assert_true(rows.iter().all(fn(r) { r.length() == 1 }), msg="\{at}: \{Repr(rows)}")
          for k in 1..<rows.length() {
            assert_true(rows[k][0].1 > rows[k - 1][0].1, msg="\{at}: \{Repr(rows)}")
          }
        } else {
          // (each line starts below the previous line's end; long lines wrap onto multiple lines within the block)
          assert_true(rows.iter().all(fn(r) { r.length() >= 1 }), msg="\{at}: \{Repr(rows)}")
          for k in 1..<rows.length() {
            let prev = rows[k - 1]
            assert_true(rows[k][0].1 > prev[prev.length() - 1].1, msg="\{at}: \{Repr(rows)}")
          }
          if name == "a long line among short ones" {
            assert_true(rows[1].length() > 1, msg="\{at}: long line wrapped \{Repr(rows[1])}")
          }
        }
      }
    }
  }
}

///|
test "a code block of more lines as nodes, on its lines as written: each line on a line of its own, at 760 and 390, words at 1 and 1.3" {
  mlines_alike(false)
}

///|
test "a code block of more lines as nodes, wrapped once its key is pressed: each line starts on a line of its own and long lines wrap, at 760 and 390, words at 1 and 1.3" {
  mlines_alike(true)
}

///|
test "Markdown as nodes: a table of one block asks for nothing to scroll across with (a list's block taken for another's keeps how far it is scrolled by its key); a long table's piece scrolls across with what it is given" {
  let (text, tree) = tw_four()
  let (long_text, long_tree) = tw_table(["模型", "输入", "输出", "备注"], [
    ["Opus 5.5", "$15", "$75", "最强的推理与写代码"],
    ["Sonnet 5.5", "$3", "$15", "日常的大多数事"],
    ["Haiku 5.5", "$0.8", "$4", "快而便宜，适合分类与摘要"],
    ["Opus 4", "$15", "$75", "上一代的最强"],
    ["Sonnet 4", "$3", "$15", "上一代的日常"],
  ])
  let long = @signals.signal(false)
  let asked = Ref(0)
  let scrolls : Map[Int, @view.Scroll] = Map([])
  let tt = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=220.0, h=400.0, platform=2)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.pick(fn() { long.get() }, fn(b, long) {
      markdown_node(
        b,
        fn() { if long { long_text } else { text } },
        tree=fn() { Some(if long { long_tree } else { tree }) },
        piece=if long { Some({ from: 0, upto: 1, rows: Some((0, 4)), last: false }) } else { None },
        across_of=fn(i) {
          asked.val += 1
          match scrolls.get(i) {
            Some(s) => s
            None => {
              let s = @view.Scroll::across()
              scrolls[i] = s
              s
            }
          }
        },
      )
      |> ignore
    })
    |> ignore
  })
  tt.draw()
  let x_of = fn() raise {
    match @ui.view_tree().unwrap().drawn().filter(fn(d) { d.words == "Opus 5.5" }) {
      [d] => d.x
      ds => fail("Opus 5.5 drawn \{ds.length()} times")
    }
  }
  let at_rest = x_of()
  assert_eq(asked.val, 0)
  // (a long table's first piece: scrolled across as what it is given is)
  long.set(true)
  tt.run_for(@ui.move_most_ms)
  let piece_rest = x_of()
  scrolls[0].put(60.0)
  tt.draw()
  let scrolled = x_of()
  assert_true(asked.val > 0 && scrolled < piece_rest - 1.0, msg="asked \{asked.val}, scrolled \{scrolled} at rest \{piece_rest} (one block's \{at_rest})")
}

///|
/// A table of ten rows under its head as markdown_node draws it in a window 220 wide: whole in one block, or cut in the
/// pieces a page's list makes a block each (md_table_piece_rows a piece), the pieces scrolling across beside each other
/// and keeping its columns together (`tracks_of`) or each its own. How many times its room was shared out among its
/// columns, and how many words the window's tree measured, from the table's first frame.
fn mn_ten_rows(pieces : Bool, kept : Bool) -> (Int, Int) {
  let rows = Array::makei(10, fn(i) { ["第 \{i} 行", "$\{i * 3}", "$\{i * 7}", "第 \{i} 行的说明，较长的一句"] })
  let (text, tree) = tw_table(["模型", "输入", "输出", "备注"], rows)
  let across = @view.Scroll::across()
  let tracks = @view.TracksKept::new()
  let tt = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=220.0, h=900.0, platform=2)
  let before = table_widths_worked.val
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    let all = md_table_piece_rows
    let cuts = if pieces { [(0, all), (all, 2 * all), (2 * all, 11)] } else { [] }
    if cuts.is_empty() {
      markdown_node(root, fn() { text }, tree=fn() { Some(tree) }) |> ignore
    }
    for i, cut in cuts {
      markdown_node(
        root,
        fn() { text },
        tree=fn() { Some(tree) },
        piece=Some({ from: 0, upto: 1, rows: Some(cut), last: i == cuts.length() - 1 }),
        across_of=fn(_) { across },
        tracks_of=fn(_) { if kept { Some(tracks) } else { None } },
      )
      |> ignore
    }
  })
  tt.draw()
  (table_widths_worked.val - before, @ui.view_tree().unwrap().work().measured)
}

///|
test "Markdown as nodes: a long table cut in three pieces keeping its columns together measures its cells and shares out its room once, as the table whole in one block does, not once a piece" {
  let (whole_shared, whole_measured) = mn_ten_rows(false, false)
  let (kept_shared, kept_measured) = mn_ten_rows(true, true)
  let (own_shared, own_measured) = mn_ten_rows(true, false)
  // (each its own: every piece measures every cell of the table again, 4 columns of 11 rows twice more)
  assert_eq(
    (whole_shared, kept_shared, kept_measured, own_shared, own_measured - kept_measured),
    (1, 1, whole_measured, 3, 2 * 4 * 11),
  )
}

///|
test "Markdown emphasis (*…*): upright muted text updating across live theme switches, preserving HTML emph flag, while inline code, links, file refs and chat mentions keep their own upright ink" {
  let s = fn(x : String) { Json::string(x) }
  let el = fn(name : String, kids : Array[Json]) { Json::array([s(name), Json::array(kids)]) }
  let code = fn(c : String) { Json::array([s("code"), Json::array([]), Json::object({ "content": s(c) })]) }
  let file_ref = fn(c : String, path : String) {
    Json::array([s("code"), Json::array([]), Json::object({ "content": s(c), "path": s(path), "shown": s(c) })])
  }
  let a = fn(href : String, kids : Array[Json]) {
    Json::array([s("a"), Json::array(kids), Json::object({ "href": s(href) })])
  }
  let chat_a = fn(href : String, kids : Array[Json]) {
    Json::array([
      s("a"),
      Json::array(kids),
      Json::object({ "href": s(href), "to": Json::object({ "chat": Json::boolean(true) }) }),
    ])
  }
  let tree = Json::array([
    el("p", [
      s("正文 "),
      el("i", [
        s("附注 "),
        code("packages/opentype"),
        s(" 与 "),
        file_ref("run.mbt", "src/text/run.mbt"),
        s(" 与 "),
        el("b", [s("粗体附注")]),
        s(" 与 "),
        el("s", [s("删去附注")]),
        s(" 见 "),
        a("https://example.com/a", [s("外链")]),
        s(" 与 "),
        chat_a("https://example.com/chats/demo", [s("讨论")]),
      ]),
      s(" 和 "),
      a("https://example.com/b", [el("i", [s("链内强调")])]),
    ]),
  ])
  // Reuse one node across a live light -> dark switch to confirm reactive theme ink updates.
  let tt = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=600.0, h=400.0, platform=0)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(b) { markdown_node(b, fn() { "emph-live-case" }, tree=fn() { Some(tree) }) |> ignore }) |> ignore
  })
  for dark in [false, true] {
    set_dark(Some(dark))
    tt.draw()
    let p = theme().p
    let drawn = @ui.view_tree().unwrap().drawn().filter(fn(d) { d.runs.length() > 0 })
    assert_eq(drawn.length(), 1, msg="dark=\{dark}: drawn=\{drawn.length()}")
    let runs = drawn[0].runs
    // No run in Markdown emphasis may set italic (no synthetic oblique on CJK or code).
    assert_true(runs.iter().all(fn(r) { !r.italic }), msg="dark=\{dark}: found italic run in \{Repr(runs)}")
    let run_of = fn(word : String) -> @ui.Run {
      match runs.iter().find_first(fn(r) { r.text == word }) {
        Some(r) => r
        None => @halt.saying("missing run \{word} in \{Repr(runs)}")
      }
    }
    // Plain body prose inherits default ink (0L) without emph; emphasized prose takes muted ink + emph.
    let body = run_of("正文 ")
    assert_eq((body.color, body.emph), (0L, false))
    let note = run_of("附注 ")
    assert_eq((note.color, note.emph), (p.muted, true))
    // Bold and strikethrough inside emphasis stay upright, styled, muted, and keep emph.
    let bold_emph = run_of("粗体附注")
    assert_eq((bold_emph.weight, bold_emph.color, bold_emph.emph), (700, p.muted, true))
    let strike_emph = run_of("删去附注")
    assert_eq((strike_emph.strike, strike_emph.color, strike_emph.emph), (true, p.muted, true))
    // Inline code and FileRef fallback inside emphasis stay upright and keep code_ink (color == 0L).
    let code_run = run_of("packages/opentype")
    assert_eq((code_run.code, code_run.color, code_run.emph), (true, 0L, true))
    let fref_run = run_of("run.mbt")
    assert_eq((fref_run.code, fref_run.color, fref_run.emph), (true, 0L, true))
    // Links inside emphasis, and emphasis inside links, keep link_color (color == 0L lets RunsLook.link apply).
    let link_in_emph = run_of("外链")
    assert_eq((link_in_emph.link, link_in_emph.color, link_in_emph.emph), ("https://example.com/a", 0L, true))
    let emph_in_link = run_of("链内强调")
    assert_eq((emph_in_link.link, emph_in_link.color, emph_in_link.emph), ("https://example.com/b", 0L, true))
    // Chat mentions inside emphasis keep accent_text upright.
    let chat_run = run_of("讨论")
    assert_eq((chat_run.color, chat_run.emph), (p.accent_text, true))
    // Verify drawn glyphs actually carry muted, code_ink, blue, and accent_text inks.
    let inks = tt.drawn_glyphs().map(fn(g) { g.2 })
    assert_true(inks.contains(p.muted), msg="dark=\{dark}: missing muted ink")
    assert_true(inks.contains(p.code_ink), msg="dark=\{dark}: missing code_ink")
    assert_true(inks.contains(p.blue), msg="dark=\{dark}: missing link blue ink")
    assert_true(inks.contains(p.accent_text), msg="dark=\{dark}: missing chat accent ink")
  }
  set_dark(None)
}

///|
test "Markdown emphasis (*…*) adapts to enclosing block ink: primary text inside muted quotes/steps, inherited inside red notices" {
  let s = fn(x : String) { Json::string(x) }
  let el = fn(name : String, kids : Array[Json]) { Json::array([s(name), Json::array(kids)]) }
  let quote_tree = Json::array([el("quote", [el("p", [s("引用 "), el("i", [s("引用强调")])])])])
  let step_tree = Json::array([el("p", [s("历史 "), el("i", [s("步骤强调")])])])
  let err_tree = Json::array([el("p", [s("失败 "), el("i", [s("红字强调")])])])
  let tt = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=600.0, h=400.0, platform=0)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(b) {
      markdown_node(b, fn() { "emph-quote" }, tree=fn() { Some(quote_tree) }) |> ignore
      markdown_node(b, fn() { "emph-step" }, tree=fn() { Some(step_tree) }, ink=fn() { theme().p.muted }) |> ignore
      markdown_node(b, fn() { "emph-err" }, tree=fn() { Some(err_tree) }, ink=fn() { theme().p.red }) |> ignore
    })
    |> ignore
  })
  for dark in [false, true] {
    set_dark(Some(dark))
    tt.draw()
    let p = theme().p
    let all_runs = @ui.view_tree().unwrap().drawn().fold(init=[], fn(acc : Array[@ui.Run], d) {
      acc.append(d.runs)
      acc
    })
    assert_true(all_runs.iter().all(fn(r) { !r.italic }), msg="dark=\{dark}: found italic run")
    let run_of = fn(word : String) -> @ui.Run {
      match all_runs.iter().find_first(fn(r) { r.text == word }) {
        Some(r) => r
        None => @halt.saying("missing run \{word}")
      }
    }
    // Quote (web().muted) and muted history step (p.muted) flip emphasis to primary p.text.
    assert_eq((run_of("引用强调").color, run_of("引用强调").emph), (p.text, true))
    assert_eq((run_of("步骤强调").color, run_of("步骤强调").emph), (p.text, true))
    // Semantic red notice keeps color == 0L so emphasis inherits red instead of turning gray.
    assert_eq((run_of("红字强调").color, run_of("红字强调").emph), (0L, true))
    assert_true(tt.drawn_glyphs().map(fn(g) { g.2 }).contains(p.red), msg="dark=\{dark}: missing red ink")
  }
  set_dark(None)
}

///|
test "md_task_node: 1x/1.3x baseline alignment, radius md_task_side/3, light/dark stroke tick, read-only and zero Tab stops" {
  let s = fn(x : String) { Json::string(x) }
  let li = fn(kids : Array[Json], a : Json) { Json::array([s("li"), Json::array(kids), a]) }
  let task_tree = Json::array([
    Json::array([
      s("list"),
      Json::array([
        li([s("已完成任务")], Json::object({ "checked": Json::boolean(true) })),
        li([s("未完成任务")], Json::object({ "checked": Json::boolean(false) })),
      ]),
      Json::object({}),
    ]),
  ])
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=420.0, h=300.0, platform=0)
  t.check_looks(false)
  @ui.set_view_app(
    fn(root) {
      @ui.set_tree_theme(ui_theme_now)
      root.padding(Is((16.0, 16.0, 16.0, 16.0))).gap(Is(8.0)) |> ignore
      button_node(root, fn() { "前按钮" }, fn() {  }) |> ignore
      markdown_node(root, fn() { "- [x] 已完成任务\n- [ ] 未完成任务" }, tree=fn() { Some(task_tree) }) |> ignore
      button_node(root, fn() { "后按钮" }, fn() {  }) |> ignore
    },
    theme=ui_theme_now,
  )
  // 1x and 1.3x font scale baseline alignment & radius check.
  for scale in [1.0, 1.3] {
    t.set_font_scale(scale)
    t.draw()
    let boxes = @ui.view_tree().unwrap().drawn().filter(fn(d) {
      d.w == md_task_side && d.h == md_task_side && (d.radius - md_task_side / 3.0).abs() <= 0.01
    })
    assert_eq(boxes.length(), 2, msg="scale=\{scale}: expected 2 task boxes with radius md_task_side/3")
    let done_word = t.rect_of("已完成任务").unwrap()
    let todo_word = t.rect_of("未完成任务").unwrap()
    let done_mid = boxes[0].y + boxes[0].h / 2.0
    let done_word_mid = done_word.1 + done_word.3 / 2.0
    assert_true((done_mid - done_word_mid).abs() <= 3.0, msg="scale=\{scale}: done box mid \{done_mid} vs word mid \{done_word_mid}")
    let todo_mid = boxes[1].y + boxes[1].h / 2.0
    let todo_word_mid = todo_word.1 + todo_word.3 / 2.0
    assert_true((todo_mid - todo_word_mid).abs() <= 3.0, msg="scale=\{scale}: todo box mid \{todo_mid} vs word mid \{todo_word_mid}")
  }
  t.set_font_scale(1.0)
  // Light and dark mode stroke tick (upto=1.0, zero animation) with WCAG >= 3.0 contrast.
  let srgb_lin = fn(c : Double) -> Double {
    if c <= 0.04045 { c / 12.92 } else { @dmath.pow((c + 0.055) / 1.055, 2.4) }
  }
  let luminance = fn(argb : Int64) -> Double {
    let r = ((argb >> 24) & 0xFFL).to_double() / 255.0
    let g = ((argb >> 16) & 0xFFL).to_double() / 255.0
    let b = ((argb >> 8) & 0xFFL).to_double() / 255.0
    0.2126 * srgb_lin(r) + 0.7152 * srgb_lin(g) + 0.0722 * srgb_lin(b)
  }
  let contrast_ratio = fn(a : Int64, b : Int64) -> Double {
    let la = luminance(a)
    let lb = luminance(b)
    let hi = dmax(la, lb)
    let lo = dmin(la, lb)
    (hi + 0.05) / (lo + 0.05)
  }
  for dark in [false, true] {
    set_dark(Some(dark))
    t.draw()
    let tick_nodes = @ui.view_tree().unwrap().drawn().filter(fn(d) {
      d.w == md_task_side && d.h == md_task_side && d.lines.length() > 0
    })
    assert_eq(tick_nodes.length(), 1, msg="dark=\{dark}: only the checked task draws a stroke tick")
    let line = tick_nodes[0].lines[0]
    assert_eq(line.upto, 1.0, msg="dark=\{dark}: static stroke tick upto=1.0")
    assert_eq(line.points.length(), check_tick_points.length(), msg="dark=\{dark}: tick uses check_tick_points")
    let done_boxes = @ui.view_tree().unwrap().drawn().filter(fn(d) {
      d.w == md_task_side && d.h == md_task_side && (d.radius - md_task_side / 3.0).abs() <= 0.01 && d.edge.0 == 0.0
    })
    assert_eq(done_boxes.length(), 1, msg="dark=\{dark}: expected 1 filled done task box")
    let bg_fill = over(theme().p.canvas, done_boxes[0].ground)
    let fg_tick = over(bg_fill, line.color)
    let ratio = contrast_ratio(fg_tick, bg_fill)
    assert_true(ratio >= 3.0, msg="dark=\{dark}: tick contrast \{ratio} < 3.0 (fg=\{fg_tick}, bg=\{bg_fill})")
  }
  set_dark(None)
  t.draw()
  // Zero added Tab stops: Tab moves directly from 前按钮 to 后按钮.
  t.act(Button, Focus, label="前按钮")
  t.tab()
  assert_eq(t.focused().map(fn(s) { s.label }), Some("后按钮"), msg="Tab skips read-only markdown task checkboxes")
}

///|
test "markdown_node MdTypography prose_scale scales heading, paragraph, code block, and table uniformly" {
  let s = fn(x : String) { Json::string(x) }
  let el = fn(name : String, kids : Array[Json]) { Json::array([s(name), Json::array(kids)]) }
  let row = fn(words : Array[String]) { el("tr", words.map(fn(w) { el("td", [s(w)]) })) }
  let doc = Json::array([
    Json::array([s("h"), Json::array([s("HeadingScale")]), Json::object({ "depth": Json::number(2.0) })]),
    el("p", [s("ParagraphScale")]),
    Json::array([s("pre"), Json::array([]), Json::object({ "code": s("CodeScaleSample"), "lang": s("sh"), "ink": s("") })]),
    el("table", [row(["TableHead"]), row(["TableCell"])]),
  ])
  let typo = @signals.signal(MdTypography::default())
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=480.0, h=600.0, platform=0)
  t.check_looks(false)
  @ui.set_view_app(
    fn(root) {
      @ui.set_tree_theme(ui_theme_now)
      root.padding(Is((16.0, 16.0, 16.0, 16.0))) |> ignore
      markdown_node(root, fn() { "scale-doc" }, tree=fn() { Some(doc) }, typography=fn() { typo.get() }, copy=false)
      |> ignore
    },
    theme=ui_theme_now,
  )
  t.draw()
  let (_, _, _, h1) = t.rect_of("HeadingScale").unwrap()
  let (_, _, _, p1) = t.rect_of("ParagraphScale").unwrap()
  let (_, _, _, c1) = t.rect_of("CodeScaleSample").unwrap()
  let (_, _, _, tb1) = t.rect_of("TableCell").unwrap()
  typo.set({ ..MdTypography::default(), prose_scale: 1.30 })
  t.draw()
  let (_, _, _, h2) = t.rect_of("HeadingScale").unwrap()
  let (_, _, _, p2) = t.rect_of("ParagraphScale").unwrap()
  let (_, _, _, c2) = t.rect_of("CodeScaleSample").unwrap()
  let (_, _, _, tb2) = t.rect_of("TableCell").unwrap()
  assert_true(h2 > h1 * 1.20 && h2 < h1 * 1.40, msg="heading height \{h1} -> \{h2}")
  assert_true(p2 > p1 * 1.20 && p2 < p1 * 1.40, msg="paragraph height \{p1} -> \{p2}")
  assert_true(c2 > c1 * 1.20 && c2 < c1 * 1.40, msg="code height \{c1} -> \{c2}")
  assert_true(tb2 > tb1 * 1.20 && tb2 < tb1 * 1.40, msg="table height \{tb1} -> \{tb2}")
}
