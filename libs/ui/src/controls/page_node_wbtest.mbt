// A group's rows made once as nodes (page_node.mbt) drawn as page.mbt draws them narrow: a row with an icon, its title
// and a line under it, beside one with no line, each instance where and as the old view's are, at the system's size of
// words 1 and 2 (the icon by its first line, as tall as that line is drawn at least: row_lead's).

///|
/// What is drawn of the group as nodes, at the system's size of words `scale`, each instance's numbers rounded to a
/// hundredth (a glyph's place in its atlas left out), in one order.
fn rows_drawn(scale : Double) -> Array[String] {
  let t = @ui.Tester::new(fn(_c) {  }, w=390.0, h=600.0, platform=2)
  t.set_font_scale(scale)
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      page_block(b, fn(room) {
        group_node(room, fn(g) {
          link_row_node(g, fn() { "Station" }, fn() {  }, note=fn() { "两台在线，一台离线" }, lead=LeadIcon("server"))
          link_row_node(g, fn() { "连接" }, fn() {  }, value=fn() { "3 个" })
        })
      })
    })
    |> ignore
  })
  t.draw()
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
test "a group's rows as nodes: a row with an icon and a line under its title, and one with neither, drawn at sizes of words 1 and 2" {
  for scale in [1.0, 2.0] {
    assert_true(rows_drawn(scale).length() > 0, msg="at \{scale}")
  }
}

///|
/// A page made once (page_node, a finger's, 390 × 844) of 30 blocks each 60 tall (counted 80 before they are laid out),
/// dragged up by a finger `times` times across most of the window: where its last block is drawn then, top and foot.
fn page_dragged(times : Int) -> (Double, Double) {
  let t = @ui.Tester::new(fn(_c) {  }, w=390.0, h=844.0, platform=2)
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      b.height(Is(Some(844.0))).width(Is(Some(390.0))) |> ignore
      page_node(b, fn() { "Title" }, fn() { Array::makei(30, fn(i) { "b\{i}" }) }, fn(v, k) {
        v.box(fn(w) { w.height(Is(Some(60.0))).words(Is("block " + k)) |> ignore }) |> ignore
      }, on_back=fn() {  })
    })
    |> ignore
  })
  t.draw()
  for _ in 0..<times {
    t.drag(195.0, 700.0, 195.0, 100.0)
    t.run_for(@ui.move_most_ms)
  }
  match @ui.view_tree() {
    Some(tree) =>
      match tree.drawn().search_by(fn(d) { d.words == "block b29" }) {
        Some(i) => (tree.drawn()[i].y, tree.drawn()[i].y + tree.drawn()[i].h)
        None => (-1.0, -1.0)
      }
    None => (-1.0, -1.0)
  }
}

///|
test "a page made once dragged on past its end, counted taller there than it is: at its end as it really is, its foot's room under its last block" {
  let (_, foot) = page_dragged(6)
  assert_eq(foot, 844.0 - pg_foot)
}

///|
/// What is drawn of `made` (as nodes, in a page's block), 390 wide, at the system's size of words `scale`, as
/// rows_drawn reads it.
fn page_part_drawn(scale : Double, made : (@view.View) -> Unit) -> Array[String] {
  let t = @ui.Tester::new(fn(_c) {  }, w=390.0, h=600.0, platform=2)
  t.set_font_scale(scale)
  @ui.set_view_app(fn(root) { root.box(fn(b) { page_block(b, made) }) |> ignore })
  t.draw()
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
test "a row with words under it as a node: its title and what it says, at sizes of words 1 and 2" {
  for scale in [1.0, 2.0] {
    let made = page_part_drawn(scale, fn(room) {
      group_node(room, fn(g) {
        link_row_node(g, fn() { "判断是否完成" }, fn() {  }, note=fn() { "标记完成后判断是否推荐归档" }, value=fn() { "1 台 station 已启用" })
        link_row_node(g, fn() { "Willow" }, fn() {  }, value=fn() { "全局记忆 · 项目记忆" })
      })
    })
    assert_true(made.length() > 0, msg="at \{scale}")
  }
}

///|
test "a page's card as a node: plain and footed, at sizes of words 1 and 2" {
  for footed in [false, true] {
    for scale in [1.0, 2.0] {
      let made = page_part_drawn(scale, fn(room) {
        page_card_node(room, footed~, fn(k) {
          k.box(fn(w) { styled_words(w, fn() { "Willow" }, fn() { pg_heading }) |> ignore }) |> ignore
          k.box(fn(w) { styled_words(w, fn() { "空闲超过下面的天数就归档。只看状态，不读内容。" }, fn() { pg_note }) |> ignore }) |> ignore
        })
        room.box(fn(f) {
          f.height(Is(Some(20.0))).ground(By(fn() { @ui.tree_theme().color(Card) })) |> ignore
        })
        |> ignore
      })
      assert_true(made.length() > 0, msg="footed \{footed} at \{scale}")
    }
  }
}

///|
/// A page titled `title` with a choice of `labels` at its title's line's end (what it does), `w` wide, at the system's
/// size of words `scale`, made once (page_node's `actions`, seg_head_node); what is drawn, as rows_drawn reads it.
fn head_end_drawn(
  w : Double,
  scale : Double,
  title : String,
  labels : Array[String],
  share? : Bool = false,
) -> Array[String] {
  let at = @signals.signal(0)
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w~, h=400.0, platform=2)
  t.set_font_scale(scale)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(b) {
      b.height(Is(Some(400.0))) |> ignore
      page_node(b, fn() { title }, fn() { [] }, fn(_, _) {  }, on_back=fn() {  }, actions=fn(a) {
        if share {
          icon_button_node(a, "share", fn() { "分享卡片" }, fn() {  }) |> ignore
        }
        seg_head_node(a, fn() { labels }, fn() { at.get() }, fn(k) { at.set(k) }) |> ignore
      })
    })
    |> ignore
  })
  t.run_for(@ui.move_most_ms)
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
test "what a page does at its title's line's end as nodes (a choice of days there): beside its title as wide as its options, giving way first where the line has not the room, at sizes of words 1 and 2, as it was beside the old view's" {
  let seen : Array[String] = []
  for case in [(390.0, 1.0, "用量"), (390.0, 2.0, "用量"), (260.0, 1.0, "用量"), (300.0, 2.0, "按 station 的用量")] {
    let (w, scale, title) = case
    let made = head_end_drawn(w, scale, title, ["7 天", "30 天"])
    assert_true(made.length() > 0)
    seen.push("\{Repr(case)}:")
    seen.append(made)
  }
  inspect(seen.join("\n"), content=(
    #|(390, 1, "用量"):
    #|277,43,44,30,15,0,0,0,1,1,1,1,0,0,0,0,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,15,15,15,15,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|285,52,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|299,52,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|329,52,6,10,0,1,0,0,0.33,0.33,0.35,1,mono,-,12,20,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|336,52,6,10,0,1,0,0,0.33,0.33,0.35,1,mono,-,12,20,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|350,52,6,10,0,1,0,0,0.33,0.33,0.35,1,mono,-,12,20,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|24,56.5,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|51,56.5,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|275,41,99,34,17,0,0,0,0.47,0.47,0.5,0.12,0,0,0,0,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,17,17,17,17,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|(390, 2, "用量"):
    #|223,44.66,68,34,17,0,0,0,1,1,1,1,0,0,0,0,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,17,17,17,17,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|24,63,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|60.5,63,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|231,59.5,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|257,59.5,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|299,59.5,6,10,0,1,0,0,0.33,0.33,0.35,1,mono,-,12,20,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|312,59.5,6,10,0,1,0,0,0.33,0.33,0.35,1,mono,-,12,20,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|338,59.5,6,10,0,1,0,0,0.33,0.33,0.35,1,mono,-,12,20,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|221,42.66,153,38,19,0,0,0,0.47,0.47,0.5,0.12,0,0,0,0,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,19,19,19,19,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|(260, 1, "用量"):
    #|147,43,44,30,15,0,0,0,1,1,1,1,0,0,0,0,0,0,260,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,15,15,15,15,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|155,52,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,260,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|169,52,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,260,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|199,52,6,10,0,1,0,0,0.33,0.33,0.35,1,mono,-,12,20,0,0,260,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|206,52,6,10,0,1,0,0,0.33,0.33,0.35,1,mono,-,12,20,0,0,260,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|220,52,6,10,0,1,0,0,0.33,0.33,0.35,1,mono,-,12,20,0,0,260,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|24,56.5,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,260,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|51,56.5,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,260,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|145,41,99,34,17,0,0,0,0.47,0.47,0.5,0.12,0,0,0,0,0,0,260,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,17,17,17,17,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|(300, 2, "按 station 的用量"):
    #|24,63,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,300,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|133,63,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,300,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|170.5,44.66,50.44,34,17,0,0,0,1,1,1,1,0,0,0,0,0,0,300,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,17,17,17,17,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|196,58,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,300,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|225,58,6,10,0,1,0,0,0.33,0.33,0.35,1,mono,-,12,20,0,0,300,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|257,58,6,10,0,1,0,0,0.33,0.33,0.35,1,mono,-,12,20,0,0,300,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|78.5,63,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,300,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|96.5,63,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,300,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|114.5,63,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,300,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|174.5,58,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,300,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|235.5,58,6,10,0,1,0,0,0.33,0.33,0.35,1,mono,-,12,20,0,0,300,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|168.5,42.66,115.5,38,19,0,0,0,0.47,0.47,0.5,0.12,0,0,0,0,0,0,300,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,19,19,19,19,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0





  ))
}

///|
test "分享 and a choice of days at a page's title's line's end as nodes, the line narrower than they ask but with the room for their least beside the title: on one line, sharing its lack as it was beside the old view's" {
  let seen : Array[String] = []
  for case in [(390.0, 1.0, "用量"), (390.0, 2.0, "按 station 的用量"), (340.0, 2.0, "按 station 的用量"), (300.0, 1.0, "按 station 的用量的明细")] {
    let (w, scale, title) = case
    let made = head_end_drawn(w, scale, title, ["7 天", "30 天"], share=true)
    assert_true(made.length() > 0)
    seen.push("\{Repr(case)}:")
    seen.append(made)
  }
  inspect(seen.join("\n"), content=(
    #|(390, 1, "用量"):
    #|277,43,44,30,15,0,0,0,1,1,1,1,0,0,0,0,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,15,15,15,15,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|285,52,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|299,52,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|329,52,6,10,0,1,0,0,0.33,0.33,0.35,1,mono,-,12,20,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|336,52,6,10,0,1,0,0,0.33,0.33,0.35,1,mono,-,12,20,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|350,52,6,10,0,1,0,0,0.33,0.33,0.35,1,mono,-,12,20,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|24,56.5,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|51,56.5,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|275,41,99,34,17,0,0,0,0.47,0.47,0.5,0.12,0,0,0,0,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,17,17,17,17,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|242.64,50.64,12.72,8,0.69,11,0,0,0.33,0.33,0.35,1,425816173,23,0,0,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0.69,0.69,0.69,0.69,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|242.64,58.64,12.72,6.72,0.69,11,0,0,0.33,0.33,0.35,1,208172532,30,0,0,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0.69,0.69,0.69,0.69,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|(390, 2, "按 station 的用量"):
    #|24,63,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|133,63,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|151,63,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|169,63,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|187,63,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|260.5,44.66,50.44,34,17,0,0,0,1,1,1,1,0,0,0,0,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,17,17,17,17,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|286,58,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|315,58,6,10,0,1,0,0,0.33,0.33,0.35,1,mono,-,12,20,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|347,58,6,10,0,1,0,0,0.33,0.33,0.35,1,mono,-,12,20,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|78.5,63,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|96.5,63,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|114.5,63,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|264.5,58,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|325.5,58,6,10,0,1,0,0,0.33,0.33,0.35,1,mono,-,12,20,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|258.5,42.66,115.5,38,19,0,0,0,0.47,0.47,0.5,0.12,0,0,0,0,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,19,19,19,19,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|226.14,54.3,12.72,8,0.69,11,0,0,0.33,0.33,0.35,1,425816173,23,0,0,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0.69,0.69,0.69,0.69,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|226.14,62.3,12.72,6.72,0.69,11,0,0,0.33,0.33,0.35,1,208172532,30,0,0,0,0,390,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0.69,0.69,0.69,0.69,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|(340, 2, "按 station 的用量"):
    #|24,63,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,340,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|133,63,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,340,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|210.5,44.66,50.44,34,17,0,0,0,1,1,1,1,0,0,0,0,0,0,340,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,17,17,17,17,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|236,58,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,340,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|265,58,6,10,0,1,0,0,0.33,0.33,0.35,1,mono,-,12,20,0,0,340,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|297,58,6,10,0,1,0,0,0.33,0.33,0.35,1,mono,-,12,20,0,0,340,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|78.5,63,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,340,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|96.5,63,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,340,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|114.5,63,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,340,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|214.5,58,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,340,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|275.5,58,6,10,0,1,0,0,0.33,0.33,0.35,1,mono,-,12,20,0,0,340,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|208.5,42.66,115.5,38,19,0,0,0,0.47,0.47,0.5,0.12,0,0,0,0,0,0,340,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,19,19,19,19,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|176.14,54.3,12.72,8,0.69,11,0,0,0.33,0.33,0.35,1,425816173,23,0,0,0,0,340,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0.69,0.69,0.69,0.69,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|176.14,62.3,12.72,6.72,0.69,11,0,0,0.33,0.33,0.35,1,208172532,30,0,0,0,0,340,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0.69,0.69,0.69,0.69,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|(300, 1, "按 station 的用量的明细"):
    #|200.5,43,37.25,30,15,0,0,0,1,1,1,1,0,0,0,0,0,0,300,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,15,15,15,15,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|205,52,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,300,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|219,52,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,300,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|24,56.5,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,300,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|78,56.5,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,300,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|105,56.5,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,300,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|118,56.5,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,300,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|242.5,52,6,10,0,1,0,0,0.33,0.33,0.35,1,mono,-,12,20,0,0,300,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|249.5,52,6,10,0,1,0,0,0.33,0.33,0.35,1,mono,-,12,20,0,0,300,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|263.5,52,6,10,0,1,0,0,0.33,0.33,0.35,1,mono,-,12,20,0,0,300,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|64.5,56.5,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,300,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|91.5,56.5,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,300,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|131.5,56.5,6,10,0,1,0,0,0.14,0.15,0.17,1,mono,-,12,20,0,0,300,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|198.5,41,85.5,34,17,0,0,0,0.47,0.47,0.5,0.12,0,0,0,0,0,0,300,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,17,17,17,17,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|166.14,50.64,12.72,8,0.69,11,0,0,0.33,0.33,0.35,1,425816173,23,0,0,0,0,300,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0.69,0.69,0.69,0.69,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    #|166.14,58.64,12.72,6.72,0.69,11,0,0,0.33,0.33,0.35,1,208172532,30,0,0,0,0,300,400,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0.69,0.69,0.69,0.69,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0





  ))
  // (each but the first narrower than they ask: the choice less wide than in a wide window, all on the title's line)
  for case in [(390.0, 2.0, "按 station 的用量"), (340.0, 2.0, "按 station 的用量"), (300.0, 1.0, "按 station 的用量的明细")] {
    let (w, scale, title) = case
    let (_, _, _, _, share, seg) = titled_ends(1000.0, title~, scale~)
    let (_, _, whole) = ends_drawn(share, seg, title~)
    let (_, _, _, _, share, seg) = titled_ends(w, title~, scale~)
    let (words, sh, sg) = ends_drawn(share, seg, title~)
    assert_true(sg.2 < whole.2 - 0.5, msg="\{Repr(case)}: the choice given way: \{sg.2} of \{whole.2}")
    assert_true(sh.1 < words.1 + words.3 && sg.1 < words.1 + words.3, msg="\{Repr(case)}: one line: \{Repr(words)} \{Repr(sh)} \{Repr(sg)}")
  }
}

///|
test "what a page does at its title's line's end as nodes, where the line has not the room for the title at its least beside the choice at its least (220 wide, words twice as large): the title on its line within the window, the choice under it whole within it, at the line's end, chosen by a tap (the old view's title ran past the window, its choice gone: not kept)" {
  let at = @signals.signal(0)
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=220.0, h=400.0, platform=2)
  t.set_font_scale(2.0)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(b) {
      b.height(Is(Some(400.0))) |> ignore
      page_node(b, fn() { "按 station 的用量" }, fn() { [] }, fn(_, _) {  }, on_back=fn() {  }, actions=fn(a) {
        seg_head_node(a, fn() { ["7 天", "30 天"] }, fn() { at.get() }, fn(k) { at.set(k) }) |> ignore
      })
    })
    |> ignore
  })
  t.run_for(@ui.move_most_ms)
  let drawn = @ui.view_tree().unwrap().drawn()
  let of = fn(w : String) { drawn.filter(fn(d) { d.words == w }) }
  for w in ["按 station 的用量", "7 天", "30 天"] {
    assert_true(of(w).length() == 1, msg="\{w} drawn once: \{of(w).length()}")
    let d = of(w)[0]
    assert_true(d.x >= 0.0 && d.x + d.w <= 220.0 && d.w > 0.0, msg="\{w} within the window: \{d.x} + \{d.w}")
  }
  // (the choice under the title, not over it, its end the line's: 16 in from the window's)
  let title = of("按 station 的用量")[0]
  let first = of("7 天")[0]
  let last = of("30 天")[0]
  assert_true(first.y >= title.y + title.h, msg="under the title: \{title.y} + \{title.h}, \{first.y}")
  assert_true(last.x + last.w <= 204.0, msg="within the line: \{last.x} + \{last.w}")
  t.tap_text("30 天")
  t.run_for(@ui.move_most_ms)
  assert_eq(at.get(), 1, msg="30 天 chosen by a tap")
}

///|
/// One step of words with shorter ones in their place: the box's width, the words, the shorter ones, whether they wrap.
#derive(Eq)
priv struct ShorterStep {
  w : Double
  said : String
  alts : Array[String]
  wrap : Bool
}

///|
/// The same words node (an old view's text with `shorter`; as nodes, View::shorter) through `steps` in turn, in a box as
/// wide as each says: at each, every instance drawn (their glyphs and the box's, as rows_drawn reads them) and what the
/// Tester finds as words.
fn shorter_seen(node : Bool, steps : Array[ShorterStep]) -> Array[String] {
  let at = @signals.signal(steps[0])
  let look = fn(s : ShorterStep) { pg_note.then(if s.wrap { @ui.text_style(wrap=true) } else { one_line }) }
  let t = if node {
    @ui.Tester::new(fn(_c) {  }, w=390.0, h=300.0, platform=2)
  } else {
    @ui.Tester::new(fn(c) {
      let s = at.get()
      c.box(w=Px(s.w), clip=true, bg=0x33669910L, fn() { c.text(s.said, style=look(s), shorter=s.alts) |> ignore }) |> ignore
    }, w=390.0, h=300.0, platform=2)
  }
  if node {
    @ui.set_view_app(fn(root) {
      root.lines_up(Is(Some(Start))) |> ignore
      root.box(fn(b) {
        b.width(By(fn() { Some(at.get().w) })).clips(Is(true)).ground(Is(0x33669910L)) |> ignore
        words_node(b, fn() { at.get().said }, fn() { look(at.get()) }).shorter(By(fn() { at.get().alts })).allow_ellipsis(Is(true))
        |> ignore
      })
      |> ignore
    })
  }
  let out = []
  for i, s in steps {
    at.set(s)
    t.draw()
    t.draw()
    let drawn = t.drawn_instances_keyed().map(fn(a) {
      a.mapi(fn(j, x) { if a[5] == 1.0 && (j == 12 || j == 13) { "-" } else { ((x * 100.0).round() / 100.0).to_string() } }).join(",")
    })
    drawn.sort()
    out.push("step \{i} (\{s.w}) words: " + t.words().map(fn(w) { w.0 }).join(" | "))
    for d in drawn {
      out.push("step \{i}: " + d)
    }
  }
  out
}

///|
test "words with shorter ones in their place, as nodes, the same node throughout: their own where they have the room; narrowed, the first shorter that has it, else the last cut short; widened, their own again; none said, or wrapping, their own; the words changed; every instance drawn as the old view's, found as their own words" {
  let said = "2026 年 5 月"
  let alts = ["5 月", "5"]
  let one = fn(w : Double, alts : Array[String]) -> ShorterStep { { w, said, alts, wrap: false } }
  let steps : Array[ShorterStep] = [
    one(200.0, alts),
    one(50.0, alts),
    one(22.0, alts),
    one(4.0, alts),
    one(200.0, alts),
    one(22.0, alts),
    // (none said in their place now, the same node: its own, cut short)
    one(22.0, []),
    one(22.0, alts),
    // (wrapping now: its own, on its lines)
    { w: 22.0, said, alts, wrap: true },
    one(22.0, alts),
    // (none fits but "": nothing)
    one(10.0, [""]),
    // (the words said otherwise)
    { w: 22.0, said: "2027 年 6 月", alts: ["6 月", "6"], wrap: false },
    { w: 300.0, said: "2027 年 6 月", alts: ["6 月", "6"], wrap: false },
  ]
  let made = shorter_seen(true, steps)
  let old = shorter_seen(false, steps)
  assert_true(old.length() > steps.length())
  if made != old {
    let only_old = old.filter(fn(x) { !made.contains(x) })
    let only_made = made.filter(fn(x) { !old.contains(x) })
    fail("old's alone:\n  \{only_old.join("\n  ")}\nmade's alone:\n  \{only_made.join("\n  ")}")
  }
}

///|
/// Words saying shorter ones, as wide as what of them is drawn, in a row `w` wide beside a box 40 by 10 (an old view's
/// text with `shorter`; as nodes, View::shorter): every instance drawn, at each of `widths` in turn, as rows_drawn reads
/// them.
fn shorter_row_seen(node : Bool, said : String, alts : Array[String], widths : Array[Double]) -> Array[String] {
  let w = @signals.signal(widths[0])
  // (as wide as its words: no w of its own)
  let look = secondary.then(one_line)
  let t = if node {
    @ui.Tester::new(fn(_c) {  }, w=390.0, h=300.0, platform=2)
  } else {
    @ui.Tester::new(fn(c) {
      c.box(dir=Row, w=Px(w.get()), fn() {
        c.text(said, style=look, shorter=alts) |> ignore
        c.box(w=Px(40.0), h=Px(10.0), bg=0x996633FFL, fn() {  }) |> ignore
      })
      |> ignore
    }, w=390.0, h=300.0, platform=2)
  }
  if node {
    @ui.set_view_app(fn(root) {
      root.lines_up(Is(Some(Start))) |> ignore
      root.box(fn(r) {
        r.row(Is(true)).width(By(fn() { Some(w.get()) })) |> ignore
        words_node(r, fn() { said }, fn() { look }).shorter(Is(alts)).allow_ellipsis(Is(true)) |> ignore
        r.box(fn(b) { b.width(Is(Some(40.0))).height(Is(Some(10.0))).ground(Is(0x996633FFL)) |> ignore }) |> ignore
      })
      |> ignore
    })
  }
  let out = []
  for x in widths {
    w.set(x)
    t.draw()
    t.draw()
    let drawn = t.drawn_instances_keyed().map(fn(a) {
      a.mapi(fn(j, v) { if a[5] == 1.0 && (j == 12 || j == 13) { "-" } else { ((v * 100.0).round() / 100.0).to_string() } }).join(",")
    })
    drawn.sort()
    for d in drawn {
      out.push("at \{x}: " + d)
    }
  }
  out
}

///|
test "words saying shorter ones as wide as what of them is drawn, a box beside them where their row puts it, as the old view's: their own, a shorter one, the last cut short" {
  let widths = [300.0, 120.0, 70.0, 50.0, 300.0]
  let made = shorter_row_seen(true, "2026 年 5 月", ["5 月", "5"], widths)
  let old = shorter_row_seen(false, "2026 年 5 月", ["5 月", "5"], widths)
  assert_true(old.length() > 0)
  if made != old {
    let only_old = old.filter(fn(x) { !made.contains(x) })
    let only_made = made.filter(fn(x) { !old.contains(x) })
    fail("old's alone:\n  \{only_old.join("\n  ")}\nmade's alone:\n  \{only_made.join("\n  ")}")
  }
}

///|
/// Where a box 40 wide stands after words saying shorter ones in a row 50 wide (as nodes), the words given way and
/// made as narrow as `setup` says of them, then as `change` changes them (the same node): its x before and after.
fn give_way_seen(setup : (@view.View) -> Unit, change : (@ui.Tester) -> Unit) -> (Double, Double) {
  let t = @ui.Tester::new(fn(_c) {  }, w=390.0, h=300.0, platform=2)
  @ui.set_view_app(fn(root) {
    root.lines_up(Is(Some(Start))) |> ignore
    root.box(fn(r) {
      r.row(Is(true)).width(Is(Some(50.0))) |> ignore
      // (focusable isolates row last_resort so this test checks View::shorter's own shrink/min_width contract alone)
      setup(words_node(r, fn() { "2026 年 5 月" }, fn() { secondary.then(one_line) }).focusable(Is(true)))
      r.box(fn(b) { b.width(Is(Some(40.0))).height(Is(Some(10.0))).ground(Is(0x996633FFL)) |> ignore }) |> ignore
    })
    |> ignore
  })
  let box_x = fn() {
    t.draw()
    t.draw()
    match @ui.view_tree().unwrap().drawn().search_by(fn(d) { d.ground == 0x996633FFL }) {
      Some(i) => @ui.view_tree().unwrap().drawn()[i].x
      None => -1.0
    }
  }
  let before = box_x()
  change(t)
  (before, box_x())
}

///|
test "words saying shorter ones give way along their row down to the last of them as they look now; what is said of how they give way and how narrow they may be theirs, said before or after; saying none, as ever" {
  let alts = @signals.signal(["5 月", "5"])
  // (giving way down to the last, "5": the box beside them where that leaves it, not past the row)
  let (given, _) = give_way_seen(fn(w) { w.shorter(By(fn() { alts.get() })) |> ignore }, fn(_) {  })
  assert_true(given > 0.0 && given <= 10.5, msg="given way: \{given}")
  // (said not to give way, before or after: as wide as the shorter one that fits the row)
  let (kept_after, _) = give_way_seen(fn(w) { w.shorter(Is(["5 月", "5"])).shrink(Is(0.0)) |> ignore }, fn(_) {  })
  let (kept_before, _) = give_way_seen(fn(w) { w.shrink(Is(0.0)).shorter(Is(["5 月", "5"])) |> ignore }, fn(_) {  })
  assert_true(kept_after > 10.5 && kept_after == kept_before, msg="not giving way: \{kept_after}, \{kept_before}")
  // (said how narrow, before or after: that)
  let (least_after, _) = give_way_seen(fn(w) { w.shorter(Is(["5 月", "5"])).min_width(Is(Some(20.0))) |> ignore }, fn(_) {  })
  let (least_before, _) = give_way_seen(fn(w) { w.min_width(Is(Some(20.0))).shorter(Is(["5 月", "5"])) |> ignore }, fn(_) {  })
  assert_true(least_after == 20.0 && least_before == 20.0, msg="as narrow as said: \{least_after}, \{least_before}")
  // (the same node saying none now: as words give way of themselves, none, as wide as they are)
  let none_said = @signals.signal(["5 月", "5"])
  let (with_some, with_none) = give_way_seen(fn(w) { w.shorter(By(fn() { none_said.get() })) |> ignore }, fn(_) { none_said.set([]) })
  assert_true(with_none > 50.0 && with_some <= 10.5, msg="saying none: \{with_some} then \{with_none}")
  // (the system's words larger, the same node: as narrow as the last of them is now, wider)
  let (small, large) = give_way_seen(fn(w) { w.shorter(Is(["5 月", "5"])) |> ignore }, fn(t) { t.set_font_scale(2.0) })
  assert_true(large > small, msg="the last as wide as it is now: \{small} then \{large}")
}

///|
test "said not cut short (View::cuts false) after it was said to give way, it gives way nowhere, whatever is said after it or its shorter words come to: a box 100 wide in a row 50 wide, words saying shorter ones" {
  let t = @ui.Tester::new(fn(_c) {  }, w=390.0, h=300.0, platform=2)
  let alts = @signals.signal(["5 月", "5"])
  let least = @signals.signal(0.0)
  @ui.set_view_app(fn(root) {
    root.lines_up(Is(Some(Start))) |> ignore
    root.box(fn(r) {
      r.row(Is(true)).width(Is(Some(50.0))) |> ignore
      r.box(fn(b) {
        b.width(Is(Some(100.0))).height(Is(Some(10.0))).ground(Is(0x336699FFL)).shrink(Is(1.0)).cuts(Is(false)).min_width(By(fn() { Some(least.get()) }))
        |> ignore
      })
      |> ignore
    })
    |> ignore
    root.box(fn(r) {
      r.row(Is(true)).width(Is(Some(50.0))) |> ignore
      // (focusable isolates row last_resort so this test checks View::cuts(false)'s own shrink contract alone)
      words_node(r, fn() { "2026 年 5 月" }, fn() { secondary.then(one_line) }).focusable(Is(true)).shorter(By(fn() { alts.get() })).cuts(Is(false)).ground(Is(0x996633FFL))
      |> ignore
      // (a box beside them their row has not the room for: they keep the room the shorter one fitting it takes)
      r.box(fn(b) { b.width(Is(Some(40.0))).height(Is(Some(10.0))) |> ignore }) |> ignore
    })
    |> ignore
  })
  let w_of = fn(ink : Int64) {
    t.draw()
    t.draw()
    match @ui.view_tree().unwrap().drawn().search_by(fn(d) { d.ground == ink }) {
      Some(i) => @ui.view_tree().unwrap().drawn()[i].w
      None => -1.0
    }
  }
  assert_eq(w_of(0x336699FFL), 100.0, msg="the box, as said")
  let words = w_of(0x996633FFL)
  // (as wide as "5 月", the first shorter one the row's 50 has: not given way to "5", 10 left beside the box)
  assert_true(words > 10.5, msg="the words not given way: \{words}")
  // (what is said after, and what its words come to: still none)
  least.set(1.0)
  // (two again, other ones: the first fits the 50 alone but not the 10 beside the box, the last does)
  alts.set(["6 月", "6"])
  t.set_font_scale(1.5)
  assert_eq(w_of(0x336699FFL), 100.0, msg="the box, said how narrow after")
  assert_true(w_of(0x996633FFL) > 10.5, msg="the words, other shorter ones, larger: \{w_of(0x996633FFL)}")
}

///|
test "words saying shorter ones in a column: as narrow as nothing there, cut to the column's width (their least along a row alone)" {
  let t = @ui.Tester::new(fn(_c) {  }, w=390.0, h=300.0, platform=2)
  @ui.set_view_app(fn(root) {
    root.lines_up(Is(Some(Start))) |> ignore
    root.box(fn(c) {
      c.width(Is(Some(4.0))).clips(Is(true)) |> ignore
      words_node(c, fn() { "2026 年 5 月" }, fn() { secondary.then(one_line) }).shorter(Is(["5 月", "5"])).ground(Is(0x996633FFL)) |> ignore
    })
    |> ignore
  })
  t.draw()
  t.draw()
  let w = match @ui.view_tree().unwrap().drawn().search_by(fn(d) { d.ground == 0x996633FFL }) {
    Some(i) => @ui.view_tree().unwrap().drawn()[i].w
    None => -1.0
  }
  assert_eq(w, 4.0, msg="as wide as the column")
}

///|
test "words saying shorter ones, then in pieces (View::words_runs): giving way and as narrow as nothing again, as words in pieces are; words alone again, as their shorter ones say" {
  let t = @ui.Tester::new(fn(_c) {  }, w=390.0, h=300.0, platform=2)
  let pieces = @signals.signal(false)
  @ui.set_view_app(fn(root) {
    root.lines_up(Is(Some(Start))) |> ignore
    root.box(fn(r) {
      r.row(Is(true)).width(Is(Some(50.0))) |> ignore
      r.box(fn(w) {
        // (focusable isolates row last_resort so this test checks View::words_runs' own shrink contract alone)
        w.focusable(Is(true)).words(Is("2026 年 5 月"), look=@ui.style_words(secondary.then(one_line))).shorter(Is(["5 月", "5"])) |> ignore
        // (the same node's words said in pieces from then on: its words' binding said anew)
        w.reacts(fn() { pieces.get() }, fn(on) {
          if on {
            w.words_runs(Is([@view.words_run("2026 年 5 月")]), look=@ui.style_words(secondary.then(one_line))) |> ignore
          }
        })
      })
      |> ignore
      r.box(fn(b) { b.width(Is(Some(40.0))).height(Is(Some(10.0))).ground(Is(0x996633FFL)) |> ignore }) |> ignore
    })
    |> ignore
  })
  let box_x = fn() {
    t.draw()
    t.draw()
    match @ui.view_tree().unwrap().drawn().search_by(fn(d) { d.ground == 0x996633FFL }) {
      Some(i) => @ui.view_tree().unwrap().drawn()[i].x
      None => -1.0
    }
  }
  let alone = box_x()
  pieces.set(true)
  let in_pieces = box_x()
  assert_true(in_pieces > alone, msg="in pieces, given way as words in pieces are (none): \{alone} then \{in_pieces}")
}

///|
/// A page titled 用量 with 分享 and a choice of days (seg_head_node) at its title's line's end, at the system's size of
/// words twice as large in a window `w` wide: the window's tree, made once; what made it (its actions made how many
/// times), its title's words, 分享 and the choice.
fn titled_ends(
  w : Double,
  title? : String = "用量",
  scale? : Double = 2.0,
) -> (@ui.Tester, Ref[Int], Ref[Int], @signals.Signal[Int], Ref[@view.View?], Ref[@view.View?]) {
  let at = @signals.signal(0)
  let shared = Ref(0)
  let made = Ref(0)
  let share : Ref[@view.View?] = Ref(None)
  let seg : Ref[@view.View?] = Ref(None)
  // (the presenters as the app begins: what a test before this one left presented is over this page else, its press
  // that one's)
  presenters_reset()
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w~, h=600.0, platform=2)
  t.set_font_scale(scale)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(b) {
      b.height(Is(Some(600.0))) |> ignore
      page_node(b, fn() { title }, fn() { [] }, fn(_, _) {  }, on_back=fn() {  }, actions=fn(a) {
        made.val += 1
        share.val = Some(icon_button_node(a, "share", fn() { "分享卡片" }, fn() { shared.val += 1 }))
        seg.val = Some(seg_head_node(a, fn() { ["7 天", "30 天"] }, fn() { at.get() }, fn(k) { at.set(k) }))
      })
    })
    |> ignore
    @ui.old(root, fn(c) { presented(c) }).over(Is(true)) |> @ui.old_takes_own |> ignore
    presented_nodes(root)
  })
  t.run_for(@ui.move_most_ms)
  (t, made, shared, at, share, seg)
}

///|
/// Where the title's words, 分享 and the choice are drawn now (x, y, w, h each).
fn ends_drawn(
  share : Ref[@view.View?],
  seg : Ref[@view.View?],
  title? : String = "用量",
) -> ((Double, Double, Double, Double), (Double, Double, Double, Double), (Double, Double, Double, Double)) raise {
  let tree = @ui.view_tree().unwrap()
  let title = match tree.drawn().search_by(fn(d) { d.words == title }) {
    Some(i) => tree.drawn()[i]
    None => fail("the title drawn")
  }
  ((title.x, title.y, title.w, title.h), share.val.unwrap().rect(), seg.val.unwrap().rect())
}

///|
test "a page's title with 分享 and a choice of days at its line's end, where even their least has not the room beside the title's (220 wide, words twice as large): those two under the title, together, at the line's end; each within the window and none over another, 分享 pressed, either day chosen (the choice its chosen one and a pick: seg_head_node's)" {
  let (t, made, shared, at, share, seg) = titled_ends(220.0)
  let (title, sh, sg) = ends_drawn(share, seg)
  for p in [("title", title), ("分享", sh), ("the choice", sg)] {
    let (x, y, w, h) = p.1
    assert_true(x >= 0.0 && x + w <= 220.0 + 0.01 && y >= 0.0 && w > 0.0 && h > 0.0, msg="\{p.0} within the window: \{Repr(p.1)}")
  }
  // (under the title, 分享 then the choice, the choice's end the line's: 16 in from the window's)
  assert_true(sh.1 >= title.1 + title.3 && sg.1 >= title.1 + title.3, msg="under the title: \{Repr(title)} \{Repr(sh)} \{Repr(sg)}")
  assert_true(sh.0 + sh.2 <= sg.0 + 0.01, msg="分享 before the choice: \{Repr(sh)} \{Repr(sg)}")
  assert_true((sg.0 + sg.2 - 204.0).abs() < 0.01, msg="the choice's end the line's: \{Repr(sg)}")
  t.tap(sh.0 + sh.2 / 2.0, sh.1 + sh.3 / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(shared.val, 1, msg="分享 pressed once")
  // (the other day: by a tap on it where both show, else from the pick the chosen one opens; then back)
  let tree = @ui.view_tree().unwrap()
  for k in [1, 0] {
    let other = if k == 1 { "30 天" } else { "7 天" }
    if !tree.drawn().iter().any(fn(d) { d.words == other }) {
      t.tap(sg.0 + sg.2 / 2.0, sg.1 + sg.3 / 2.0)
      t.run_for(@ui.move_most_ms)
    }
    t.tap_text(other)
    t.run_for(@ui.move_most_ms)
    assert_eq(at.get(), k, msg="\{other} chosen")
  }
  assert_eq(made.val, 1, msg="made once")
}

///|
test "a page's title with what it does at its line's end, its window narrowed and widened across where their least has the room beside each other (words twice as large): on one line, the title at its least or more, then under it, each width as it was coming either way; nothing made again" {
  let (t, made, _, _, share, seg) = titled_ends(390.0)
  // (each width, from 390 down to 220 and up again: one line or two, and where each is)
  let seen : Map[Int, String] = Map([])
  let mut lines_at : Int? = None
  let widths = []
  for w = 390; w >= 220; w = w - 2 {
    widths.push(w)
  }
  for w = 222; w <= 390; w = w + 2 {
    widths.push(w)
  }
  for w in widths {
    t.resize(w.to_double(), 600.0)
    t.run_for(@ui.move_most_ms)
    let (title, sh, sg) = ends_drawn(share, seg)
    let one = sh.1 < title.1 + title.3 && sg.1 < title.1 + title.3
    // (the choice's end the line's either way; on one line the title at least 80 wide, before 分享)
    assert_true((sg.0 + sg.2 - (w.to_double() - 16.0)).abs() < 0.01, msg="\{w}: the choice's end the line's: \{Repr(sg)}")
    if one {
      assert_true(sh.0 - 24.0 >= 80.0 + 10.0 - 0.01, msg="\{w}: the title at its least: \{Repr(title)} \{Repr(sh)}")
    } else {
      assert_true(sh.1 >= title.1 + title.3 && sg.1 >= title.1 + title.3, msg="\{w}: under the title")
    }
    // (one line from some width up, two under it: never one line narrower than two)
    match lines_at {
      None => if !one { lines_at = Some(w) }
      Some(under) => if one { assert_true(w > under, msg="\{w}: one line under \{under}") }
    }
    let now = "\{@ui.rect_text(title)} \{@ui.rect_text(sh)} \{@ui.rect_text(sg)}"
    match seen.get(w) {
      Some(was) => assert_eq(now, was, msg="\{w}: as it was coming the other way")
      None => seen[w] = now
    }
    // (and the same frame after frame)
    t.draw()
    let (title2, sh2, sg2) = ends_drawn(share, seg)
    assert_eq("\{@ui.rect_text(title2)} \{@ui.rect_text(sh2)} \{@ui.rect_text(sg2)}", now, msg="\{w}: still")
  }
  assert_true(lines_at is Some(_), msg="two lines somewhere at 220…390")
  assert_true(seen.get(390).unwrap() != seen.get(220).unwrap())
  assert_eq(made.val, 1, msg="made once")
}

///|
test "on_baseline aligns secondary Meta text to primary Ui first-line baseline across web_lines and font scales" {
  let primary_style = @ui.text_style(size=Ui, color=Fg, wrap=false)
  let secondary_style = @ui.text_style(size=Meta, color=Muted, wrap=false)
  for web in [true, false] {
    @ui.set_web_lines(web)
    for scale in [1.0, 1.3] {
      let t = @ui.Tester::tree(w=400.0, h=120.0, platform=if web { 0 } else { 2 }, theme=fn() { ui_theme() }, fn(root) {
        root.box(fn(row) {
          row.row(Is(true)).gap(Is(6.0)).lines_up(Is(Some(Start))) |> ignore
          words_node(row, fn() { "Gemini 4 Neon" }, fn() { primary_style }) |> ignore
          let sub = words_node(row, fn() { "AGY" }, fn() { secondary_style })
          on_baseline(sub, Ui, Meta) |> ignore
        })
        |> ignore
      })
      if scale != 1.0 {
        t.set_font_scale(scale)
      }
      t.draw()
      let runs = t.text_runs()
      let p = runs.filter(fn(r) { r.text == "Gemini 4 Neon" })[0]
      let s = runs.filter(fn(r) { r.text == "AGY" })[0]
      assert_true(
        (p.base - s.base).abs() < 0.01,
        msg="web=\{web} scale=\{scale}: primary base=\{p.base} secondary base=\{s.base}",
      )
    }
  }
  @ui.set_web_lines(false)
}

///|
test "ask_node, confirm_node, and card_foot_node wrap at narrow 220pt / 1.3x keeping primary button on bottom row" {
  // 1. ask_node at 220pt / 1.3x
  let t1 = @ui.Tester::new(fn(_c) {  }, w=220.0, h=420.0, platform=0)
  t1.check_looks(false)
  t1.set_font_scale(1.3)
  let field = @ui.Field::new()
  @ui.set_view_app(
    fn(root) {
      ask_node(
        root,
        fn() { true },
        "重命名",
        field,
        "",
        "名称",
        "保存并应用更改",
        "",
        false,
        false,
        fn() {  },
        fn(_) {  },
      )
    },
    theme=ui_theme_now,
  )
  t1.run_for(@ui.move_most_ms)
  let btns1 = t1.semantics().filter(fn(s) { s.role == Button && !s.hidden })
  let cancel1 = btns1.filter(fn(s) { s.label == t("common.cancel") })[0]
  let act1 = btns1.filter(fn(s) { s.label == "保存并应用更改" })[0]
  assert_true(act1.rect.1 > cancel1.rect.1 + 1.0, msg="ask_node primary on bottom row: cancel=\{Repr(cancel1.rect)} act=\{Repr(act1.rect)}")

  // 2. confirm_node at 220pt / 1.3x
  let t2 = @ui.Tester::new(fn(_c) {  }, w=220.0, h=420.0, platform=0)
  t2.check_looks(false)
  t2.set_font_scale(1.3)
  @ui.set_view_app(
    fn(root) {
      confirm_node(
        root,
        fn() { true },
        fn() { "确认删除" },
        fn() { "此操作不可撤销。" },
        fn() { "永久删除全部数据" },
        true,
        fn() {  },
        fn() {  },
      )
    },
    theme=ui_theme_now,
  )
  t2.run_for(@ui.move_most_ms)
  let btns2 = t2.semantics().filter(fn(s) { s.role == Button && !s.hidden })
  let cancel2 = btns2.filter(fn(s) { s.label == t("common.cancel") })[0]
  let act2 = btns2.filter(fn(s) { s.label == "永久删除全部数据" })[0]
  assert_true(act2.rect.1 > cancel2.rect.1 + 1.0, msg="confirm_node primary on bottom row: cancel=\{Repr(cancel2.rect)} act=\{Repr(act2.rect)}")

  // 3. card_foot_node (Start / reverse=true) at 220pt / 1.3x
  let t3 = @ui.Tester::new(fn(_c) {  }, w=220.0, h=300.0, platform=2)
  t3.check_looks(false)
  t3.set_font_scale(1.3)
  @ui.set_view_app(
    fn(root) {
      root.padding(Is((12.0, 12.0, 12.0, 12.0))) |> ignore
      page_card_node(root, footed=true, fn(k) {
        card_foot_node(k, fn(f) {
          button_node(f, fn() { "立即开启保护" }, fn() {  }, tone=Primary, card_words=true) |> ignore
          button_node(f, fn() { "稍后再说" }, fn() {  }, tone=Ghost) |> ignore
        })
      })
    },
    theme=ui_theme_now,
  )
  t3.draw()
  let btns3 = t3.semantics().filter(fn(s) { s.role == Button && !s.hidden })
  let primary3 = btns3.filter(fn(s) { s.label == "立即开启保护" })[0]
  let sec3 = btns3.filter(fn(s) { s.label == "稍后再说" })[0]
  assert_true(primary3.rect.1 > sec3.rect.1 + 1.0, msg="card_foot_node primary on bottom row: primary=\{Repr(primary3.rect)} sec=\{Repr(sec3.rect)}")
}

///|
test "corner_row_node: 1.0x/1.3x keep button_height; 2.0x grows with trailing button with zero fixed_outgrown or squeeze_faults" {
  let t = @ui.Tester::new(fn(_c) {  }, w=390.0, h=240.0, platform=2)
  t.check_looks(false)
  @ui.set_view_app(
    fn(root) {
      root.padding(Is((16.0, 20.0, 16.0, 20.0))) |> ignore
      page_card_node(root, fn(k) {
        corner_row_node(k, fn() { "语言设置" }, fn(e) {
          button_node(e, fn() { "更改" }, fn() {  }, tone=Ghost) |> ignore
        })
      })
    },
    theme=ui_theme_now,
  )
  t.draw()
  let btn_h_1 = t.semantics().filter(fn(s) { s.role == Button && !s.hidden })[0].rect.3
  assert_eq(btn_h_1, button_height(), msg="1.0x button height exact")
  assert_eq(t.fixed_outgrown(), [], msg="1.0x fixed_outgrown")
  assert_eq(t.squeeze_faults(), [], msg="1.0x squeeze_faults")
  t.set_font_scale(1.3)
  t.draw()
  let btn_h_13 = t.semantics().filter(fn(s) { s.role == Button && !s.hidden })[0].rect.3
  assert_eq(btn_h_13, button_height(), msg="1.3x button height exact")
  assert_eq(t.fixed_outgrown(), [], msg="1.3x fixed_outgrown")
  assert_eq(t.squeeze_faults(), [], msg="1.3x squeeze_faults")
  t.set_font_scale(2.0)
  t.draw()
  let btn_h_2 = t.semantics().filter(fn(s) { s.role == Button && !s.hidden })[0].rect.3
  assert_true(btn_h_2 > button_height(), msg="2.0x trailing button grew: \{btn_h_2}")
  assert_eq(t.fixed_outgrown(), [], msg="2.0x fixed_outgrown")
  assert_eq(t.squeeze_faults(), [], msg="2.0x squeeze_faults")
}

///|
test "narrow page_node with back renders floating liquid glass back pill and progressive top scroll edge, stays pinned on scroll, triggers on_back, and emits zero glass without back" {
  let back_sig = @signals.signal((Some("对话") : String?))
  let backs = Ref(0)
  let t = @ui.Tester::new(fn(_c) {  }, w=390.0, h=844.0, platform=2)
  @ui.set_view_app(
    fn(root) {
      @ui.set_tree_theme(ui_theme_now)
      root.box(fn(b) {
        b.width(Is(Some(390.0))).height(Is(Some(844.0))) |> ignore
        page_node(
          b,
          fn() { "设置" },
          fn() { Array::makei(30, fn(i) { "b\{i}" }) },
          fn(v, k) {
            v.box(fn(w) { w.height(Is(Some(60.0))).words(Is("block " + k)) |> ignore }) |> ignore
          },
          on_back=fn() { backs.val += 1 },
          frame=fn() { { ..no_frame, back: back_sig.get() } },
        )
      })
      |> ignore
    },
    theme=ui_theme_now,
  )
  t.run_for(@ui.move_most_ms)
  let liquid = t.drawn_glass().filter(fn(g) { g.4 == 6 })
  let edge = t.drawn_glass().filter(fn(g) { g.4 == 5 })
  assert_eq(liquid.length(), 1, msg="1 floating liquid glass back pill: \{Repr(liquid)}")
  assert_eq(edge.length(), 1, msg="1 progressive top scroll edge: \{Repr(edge)}")
  let links = t.semantics().filter(fn(s) { s.role == Link && !s.hidden && s.label == "对话" })
  assert_eq(links.length(), 1, msg="back Link semantics: \{Repr(links)}")
  let pill_y0 = liquid[0].1
  assert_eq(t.audit(), [], msg="audit with back")
  // Scroll down multiple screens: back pill stays pinned at top
  for _ in 0..<3 {
    t.drag(195.0, 700.0, 195.0, 150.0)
    t.run_for(@ui.move_most_ms)
  }
  let liquid_after = t.drawn_glass().filter(fn(g) { g.4 == 6 })
  assert_eq(liquid_after.length(), 1, msg="pill still present after scroll")
  assert_true((liquid_after[0].1 - pill_y0).abs() < 0.01, msg="pill stays pinned: \{pill_y0} vs \{liquid_after[0].1}")
  // Tap back pill triggers on_back
  let (px, py, pw, ph) = links[0].rect
  t.tap(px + pw / 2.0, py + ph / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(backs.val, 1, msg="on_back triggered once")
  // Without back: zero floating pill and zero top scroll edge
  back_sig.set(None)
  t.run_for(@ui.move_most_ms)
  assert_eq(t.drawn_glass().length(), 0, msg="zero glass when back is None: \{Repr(t.drawn_glass())}")
  assert_eq(t.audit(), [], msg="audit without back")
}

///|
test "narrow page_node with back places title inline centered with circular glass back, groups trailing icon actions into one glass capsule, and avoids overlap with wide trailing actions" {
  // 1. Grouped trailing icon actions (like Profile's share + add) share one glass pill; hidden when shown() is false
  let actions_on = @signals.signal(true)
  let t = @ui.Tester::new(fn(_c) {  }, w=390.0, h=844.0, platform=2)
  @ui.set_view_app(
    fn(root) {
      @ui.set_tree_theme(ui_theme_now)
      root.box(fn(b) {
        b.width(Is(Some(390.0))).height(Is(Some(844.0))) |> ignore
        page_node(
          b,
          fn() { "Profile" },
          fn() { ["b0"] },
          fn(v, _) { v.box(fn(w) { w.height(Is(Some(60.0))).words(Is("body")) |> ignore }) |> ignore },
          on_back=fn() {  },
          frame=fn() { { back: Some("设置"), top: 32.0, foot: 0.0, named: false } },
          actions=fn(a) {
            bar_actions_pill_node(a, fn() { actions_on.get() }, count=fn() { 2 }, fn(g) {
              icon_button_node(g, "share", fn() { "分享" }, fn() {  }) |> ignore
              icon_button_node(g, "plus", fn() { "新建" }, fn() {  }) |> ignore
            })
          },
        )
      })
      |> ignore
    },
    theme=ui_theme_now,
  )
  t.run_for(@ui.move_most_ms)
  let pills = t.drawn_glass().filter(fn(g) { g.4 == 6 })
  assert_eq(pills.length(), 2, msg="1 circular back pill + 1 grouped trailing pill: \{Repr(pills)}")
  // Left back pill is 40x40 circle; right grouped pill is 40pt tall and wider than 40pt
  let left_pill = pills.filter(fn(g) { g.0 < 100.0 })[0]
  let right_pill = pills.filter(fn(g) { g.0 > 200.0 })[0]
  assert_true((left_pill.2 - 40.0).abs() < 0.5 && (left_pill.3 - 40.0).abs() < 0.5, msg="circular back: \{Repr(left_pill)}")
  assert_true(right_pill.2 > 70.0 && (right_pill.3 - 40.0).abs() < 0.5, msg="grouped trailing pill: \{Repr(right_pill)}")
  // Title is centered inline on the same row as the glass pills, with zero second-row duplicate
  let titles = @ui.view_tree().unwrap().drawn().filter(fn(d) { d.words == "Profile" })
  assert_eq(titles.length(), 1, msg="title drawn once inline")
  let title_mid_x = titles[0].x + titles[0].w / 2.0
  let title_mid_y = titles[0].y + titles[0].h / 2.0
  let pill_mid_y = left_pill.1 + left_pill.3 / 2.0
  assert_true((title_mid_x - 195.0).abs() <= 1.0, msg="title dead-centered: \{title_mid_x}")
  assert_true((title_mid_y - pill_mid_y).abs() <= 2.0, msg="title inline with pills: \{title_mid_y} vs \{pill_mid_y}")
  assert_eq(t.audit(), [], msg="audit with grouped trailing glass pill")
  // Hiding grouped actions removes the trailing glass capsule (zero empty glass capsule)
  actions_on.set(false)
  t.run_for(@ui.move_most_ms)
  let pills_hidden = t.drawn_glass().filter(fn(g) { g.4 == 6 })
  assert_eq(pills_hidden.length(), 1, msg="zero empty trailing glass pill: \{Repr(pills_hidden)}")
  // 2. Pushed narrow page with segmented_node(head=true) + narrow_bar_choice_node keeps top bar symmetric
  // (centered title + 40pt glass back + 40pt glass share) and puts the range selector full-width below the bar
  let at = @signals.signal(0)
  let t2 = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=390.0, h=600.0, platform=2)
  @ui.set_view_app(
    fn(root) {
      @ui.set_tree_theme(ui_theme_now)
      root.box(fn(b) {
        b.width(Is(Some(390.0))).height(Is(Some(600.0))) |> ignore
        let labels = fn() { ["7 天", "30 天", "总计"] }
        let chosen = fn() { at.get() }
        let choose = fn(k) { at.set(k) }
        page_node(
          b,
          fn() { "用量" },
          fn() { ["b0"] },
          fn(v, _) {
            narrow_bar_choice_node(v, labels, chosen, choose)
            v.box(fn(w) { w.height(Is(Some(60.0))).words(Is("body")) |> ignore }) |> ignore
          },
          on_back=fn() {  },
          frame=fn() { { back: Some("设置"), top: 32.0, foot: 0.0, named: false } },
          actions=fn(a) {
            icon_button_node(a, "share", fn() { "分享卡片" }, fn() {  }) |> ignore
            segmented_node(a, head=true, labels, chosen, choose)
          },
        )
      })
      |> ignore
    },
    theme=ui_theme_now,
  )
  t2.run_for(@ui.move_most_ms)
  let pills2 = t2.drawn_glass().filter(fn(g) { g.4 == 6 })
  assert_eq(pills2.length(), 2, msg="back circle + standalone share glass circle: \{Repr(pills2)}")
  let title2 = @ui.view_tree().unwrap().drawn().filter(fn(d) { d.words == "用量" })[0]
  assert_true(((title2.x + title2.w / 2.0) - 195.0).abs() <= 1.0, msg="用量 dead-centered: \{title2.x + title2.w / 2.0}")
  let seg_word = @ui.view_tree().unwrap().drawn().filter(fn(d) { d.words == "7 天" })[0]
  let bar_bottom2 = pills2[0].1 + pills2[0].3
  assert_true(seg_word.y > bar_bottom2, msg="range selector below top bar: \{seg_word.y} > \{bar_bottom2}")
  assert_eq(t2.audit(), [], msg="audit with narrow_bar_choice_node")
  // 3. Narrow 320pt at 2.0x English ("Usage" + share + ["7 days", "30 days", "All time"]): zero squeeze or audit faults
  let t3 = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=320.0, h=600.0, platform=2)
  t3.set_font_scale(2.0)
  @ui.set_view_app(
    fn(root) {
      @ui.set_tree_theme(ui_theme_now)
      root.box(fn(b) {
        b.width(Is(Some(320.0))).height(Is(Some(600.0))) |> ignore
        let labels = fn() { ["7 days", "30 days", "All time"] }
        let chosen = fn() { at.get() }
        let choose = fn(k) { at.set(k) }
        page_node(
          b,
          fn() { "Usage" },
          fn() { ["b0"] },
          fn(v, _) {
            narrow_bar_choice_node(v, labels, chosen, choose)
            v.box(fn(w) { w.height(Is(Some(60.0))).words(Is("body")) |> ignore }) |> ignore
          },
          on_back=fn() {  },
          frame=fn() { { back: Some("Settings"), top: 0.0, foot: 0.0, named: false } },
          actions=fn(a) {
            icon_button_node(a, "share", fn() { "Share" }, fn() {  }) |> ignore
            segmented_node(a, head=true, labels, chosen, choose)
          },
        )
      })
      |> ignore
    },
    theme=ui_theme_now,
  )
  t3.run_for(@ui.move_most_ms)
  assert_eq(t3.squeeze_faults(), [], msg="320pt 2.0x EN squeeze faults")
  assert_eq(t3.audit(), [], msg="320pt 2.0x EN audit")
  // 4. 2.0x font scale with small subtitle: Top clearance grows with text so first block clears floating top bar
  let t4 = @ui.Tester::new(fn(_c) {  }, w=390.0, h=844.0, platform=2)
  t4.set_font_scale(2.0)
  @ui.set_view_app(
    fn(root) {
      @ui.set_tree_theme(ui_theme_now)
      root.box(fn(b) {
        b.width(Is(Some(390.0))).height(Is(Some(844.0))) |> ignore
        page_node(
          b,
          fn() { "文件" },
          fn() { ["b0"] },
          fn(v, _) { v.box(fn(w) { w.height(Is(Some(60.0))).words(Is("first block")) |> ignore }) |> ignore },
          on_back=fn() {  },
          frame=fn() { { back: Some("设置"), top: 32.0, foot: 0.0, named: false } },
          small=fn() { "Willow" },
        )
      })
      |> ignore
    },
    theme=ui_theme_now,
  )
  t4.run_for(@ui.move_most_ms)
  let drawn4 = @ui.view_tree().unwrap().drawn()
  let sub4 = drawn4.filter(fn(d) { d.words == "Willow" })[0]
  let body4 = drawn4.filter(fn(d) { d.words == "first block" })[0]
  assert_true(body4.y >= sub4.y + sub4.h + 4.0, msg="2.0x + small first block clears bar: body=\{body4.y}, sub_end=\{sub4.y + sub4.h}")
  assert_eq(t4.audit(), [], msg="2.0x + small audit")
}

///|
test "a page its frame names, its blocks told in place of what it showed waiting: at its top, narrow and wide" {
  // (no head, title or lead over its blocks: the room at its foot an item of its list, alone in it as its blocks
  // were told, held what showed, and they came in over it, the page at its end)
  for w in [1280.0, 390.0] {
    let t = @ui.Tester::new(fn(_c) {  }, w~, h=600.0, platform=2)
    let blocks : @signals.Signal[Array[String]] = @signals.signal(["wait"])
    @ui.set_view_app(fn(root) {
      root.box(fn(b) {
        b.height(Is(Some(600.0))).width(Is(Some(w))) |> ignore
        page_node(b, fn() { "Title" }, fn() { blocks.get() }, fn(v, k) {
          v.box(fn(x) { x.height(Is(Some(60.0))).words(Is("block " + k)) |> ignore }) |> ignore
        }, on_back=fn() {  }, frame=fn() { { back: None, top: 0.0, foot: 0.0, named: true } })
      })
      |> ignore
    })
    t.draw()
    blocks.set(Array::makei(30, fn(i) { "b\{i}" }))
    t.run_for(@ui.move_most_ms)
    let drawn = @ui.view_tree().unwrap().drawn()
    let first = drawn.search_by(fn(d) { d.words == "block b0" }).map(fn(i) { drawn[i].y })
    assert_true(first is Some(y) && y.abs() < 0.5, msg="\{w}: its first block at \{Repr(first)}")
  }
}

///|
test "narrow page_node with back, short of room for three trailing actions beside its title, takes the title off its centre and cuts no action" {
  for w in [320.0, 390.0] {
    let t = @ui.Tester::new(fn(_c) {  }, w~, h=600.0, platform=2)
    @ui.set_view_app(
      fn(root) {
        @ui.set_tree_theme(ui_theme_now)
        root.box(fn(b) {
          b.width(Is(Some(w))).height(Is(Some(600.0))) |> ignore
          page_node(
            b,
            fn() { "Profile" },
            fn() { ["b0"] },
            fn(v, _) { v.box(fn(x) { x.height(Is(Some(60.0))).words(Is("body")) |> ignore }) |> ignore },
            on_back=fn() {  },
            frame=fn() { { back: Some("设置"), top: 32.0, foot: 0.0, named: false } },
            actions=fn(a) {
              bar_actions_pill_node(a, fn() { true }, count=fn() { 3 }, fn(g) {
                icon_button_node(g, "share", fn() { "分享" }, fn() {  }) |> ignore
                icon_button_node(g, "check-circle", fn() { "多选" }, fn() {  }) |> ignore
                icon_button_node(g, "plus", fn() { "新建" }, fn() {  }) |> ignore
              })
            },
          )
        })
        |> ignore
      },
      theme=ui_theme_now,
    )
    t.run_for(@ui.move_most_ms)
    // (the trailing pill whole: three keys, their gaps and its pads)
    let right = t.drawn_glass().filter(fn(g) { g.4 == 6 && g.0 > w / 2.0 })
    let whole = 3.0 * pg_bar_pill_key + 2.0 * pg_bar_pill_gap + 2.0 * pg_bar_pill_pad
    assert_eq(right.length(), 1, msg="\{w}: \{Repr(right)}")
    assert_true((right[0].2 - whole).abs() < 0.5, msg="\{w}: trailing pill whole: \{Repr(right[0])}")
    assert_eq(t.squeeze_faults(), [], msg="\{w}")
    assert_eq(t.audit(), [], msg="\{w}")
    let titles = @ui.view_tree().unwrap().drawn().filter(fn(d) { d.words == "Profile" })
    assert_eq(titles.length(), 1, msg="\{w}: title drawn")
    // (where there is room, still dead-centred)
    if w == 390.0 {
      assert_true((titles[0].x + titles[0].w / 2.0 - w / 2.0).abs() <= 1.0, msg="title centred at 390")
    }
  }
}
