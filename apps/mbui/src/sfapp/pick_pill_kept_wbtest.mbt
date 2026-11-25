// 引用 over words a mouse picked in a message, as a host builds the frames: the page's view kept where nothing it
// read changed, the message's row telling the pick as it is built (sfbase's pick.mbt, pick_pop).

///|
/// A mouse pressed at (x0, y0), dragged to (x1, y1) and let go there, as a host hands it on: each event between the
/// display's frames, the frames the app asks for drawn after it (no Tester::drag, whose draw tells it as from outside).
fn mouse_dragged(t : @ui.Tester, x0 : Double, y0 : Double, x1 : Double, y1 : Double) -> Unit {
  t.touch(0, x0, y0)
  t.frames_owed()
  // (its moves as Tester::drag's: inputs, each drawn as a host draws what it asks)
  let drag_moves = 10
  for i in 1..=drag_moves {
    let f = i.to_double() / drag_moves.to_double()
    t.frame(ms=@ui.input_step_ms)
    t.touch(1, x0 + (x1 - x0) * f, y0 + (y1 - y0) * f)
    t.frames_owed()
  }
  t.frame(ms=@ui.input_step_ms)
  t.touch(2, x1, y1)
  t.frames_owed()
}

///|
/// A mouse's click at (x, y), as a host hands it on.
fn mouse_clicked(t : @ui.Tester, x : Double, y : Double) -> Unit {
  t.touch(0, x, y)
  t.frames_owed()
  t.frame(ms=@ui.input_step_ms)
  t.touch(2, x, y)
  t.frames_owed()
}

///|
/// Where 引用 is drawn over the line `y` is on (within 60 over it), if it is.
fn pill_over(t : @ui.Tester, y : Double) -> (Double, Double)? {
  match t.words().filter(fn(w) { w.0 == "引用" && w.2 < y && w.2 > y - 60.0 }) {
    [w, ..] => Some((w.1, w.2))
    _ => None
  }
}

///|
/// The quote mark drawn immediately before the pill's words over line `y`.
fn pill_mark(t : @ui.Tester, y : Double) -> String {
  guard pill_over(t, y) is Some((qx, _)) else { return "" }
  for (name, x, sy, _, _) in t.shape_boxes() {
    // (the old view's icon path, sf/icon/…; the page made as nodes draws it by /icon/…, chat_quote_node's)
    if (name.has_prefix("sf/icon/quote") || name.has_prefix("/icon/quote")) && x < qx && qx - x < 40.0 && sy < y && sy > y - 60.0 {
      return name
    }
  }
  // (the pill made as nodes: its mark as the tree draws it)
  if @ui.view_tree() is Some(tree) {
    for d in tree.drawn() {
      let name = tree.drawn_name(d.id)
      if name.has_prefix("/icon/quote") && d.x < qx && qx - d.x < 40.0 && d.y < y && d.y > y - 60.0 {
        return "sf" + name
      }
    }
  }
  ""
}

///|
test "大屏, built as a host builds: words a mouse picked in a message have 引用 over where it let go in the frame it let go in, there after a while and a move, gone after a press" {
  // (this form alone shows it: a default Tester builds the frame again keeping nothing and shows the pill whatever
  // the page's view read, and a run_for(500) after the scroll brings it by a read of its own)
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="chat")
  t.check_looks(false)
  for _ in 0..<12 {
    match t.run_rects("做了什么") {
      [(_, y, _, _), ..] if y > 100.0 && y < 500.0 => break
      _ => t.wheel(900.0, 400.0, -200.0)
    }
  }
  let (hx, hy, _, hh) = words_rect(t, "做了什么")
  let (ix, iy, iw, ih) = words_rect(t, "滚动位置记成")
  mouse_dragged(t, hx + 1.0, hy + hh / 2.0, ix + iw - 1.0, iy + ih / 2.0)
  assert_true(t.ctx().selected_text().has_suffix("滚动位置记成"), msg=t.ctx().selected_text())
  match pill_over(t, iy) {
    Some((qx, _)) => assert_true((qx - (ix + iw)).abs() < 40.0, msg="引用 at \{qx}")
    None => fail("no 引用 over where the pointer let go, in the frame it let go in")
  }
  t.run_for(@ui.move_most_ms)
  assert_true(pill_over(t, iy) is Some(_), msg="引用 gone once all the let-go set off is over")
  t.touch(1, ix + iw + 30.0, iy + 40.0)
  t.frames_owed()
  assert_true(pill_over(t, iy) is Some(_), msg="引用 gone after the pointer moved")
  // (a click of its own, not a second of the press that picked: a double click's picks a word)
  t.run_for(@ui.double_click_ms)
  mouse_clicked(t, hx + 1.0, hy + hh / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(t.ctx().selected_text(), "")
  assert_true(t.words().filter(fn(w) { w.0 == "引用" }).is_empty(), msg="引用 still there after a press")
}

///|
/// A chat ending with a long agent reply like the reported selection: a wrapped list item, followed by another item.
fn pick_list_tester(calls : Array[Made], w? : Double = 1280.0, lang? : @signals.Signal[String]) -> @ui.Tester {
  new_run()
  let text = "好，表 14 保持现状，不加说明。\n\n通读找到的问题里，还剩这些没定（编号沿用之前的）：\n- **7–12**：数字和单位前后不统一。两组 A1/b1 配置；同一批 400 项，系统统计数写成了 218/219/220 三个数；运行预算 20 和 50 分钟；501 和 509 s；sample 数 2,100 和 2,220；表 17 的列没标清楚。\n- **19–21**：可选。摘要补\"than the official Example evaluation\"；表 18 填上 115 s；写明 App 0.8.0b64。\n\n你点编号我就改；都不改的话，就可以收尾合并 #123 了。"
  let md : Json = [
    ["p", ["好，表 14 保持现状，不加说明。"]],
    ["p", ["通读找到的问题里，还剩这些没定（编号沿用之前的）："]],
    ["list", [
      ["li", [["b", ["7–12"]], "：数字和单位前后不统一。两组 A1/b1 配置；同一批 400 项，系统统计数写成了 218/219/220 三个数；运行预算 20 和 50 分钟；501 和 509 s；sample 数 2,100 和 2,220；表 17 的列没标清楚。"]],
      ["li", [["b", ["19–21"]], "：可选。摘要补\"than the official Example evaluation\"；表 18 填上 115 s；写明 App 0.8.0b64。"]],
    ]],
    ["p", ["你点编号我就改；都不改的话，就可以收尾合并 #123 了。"]],
  ]
  let base = fixture("chat")
  let src : Source = {
    ..base,
    call: fn(name, params, done) {
      calls.push({ name, params, bytes: None, done })
      (base.call)(name, params, done)
    },
    topic_read: fn(name, params) {
      let tp = base.topic(name, params).get().snapshot()
      match (name, tp.value) {
        ("prefs", _) =>
          match lang {
            Some(ls) if ls.get() != "" => {
              let o = match tp.value {
                Some(Object(m)) => m.copy()
                _ => {}
              }
              o["lang"] = Json::string(ls.get())
              { ..tp, value: Some(Json::object(o)) }
            }
            _ => tp
          }
        ("chat", Some(Object(o))) => {
          let messages = match o.get("messages") {
            Some(Array(a)) => a.copy()
            _ => []
          }
          match messages.last() {
            Some(Object(m)) => {
              let m = m.copy()
              m["text"] = Json::string(text)
              m["md"] = md
              messages[messages.length() - 1] = Json::object(m)
            }
            _ => ()
          }
          let o = o.copy()
          o["messages"] = Json::array(messages)
          { ..tp, value: Some(Json::object(o)) }
        }
        _ => tp
      }
    },
  }
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h=800.0, platform=0)
  t.run_for(@ui.move_most_ms)
  t
}

///|
test "大屏, a mouse picks across two list items of one message and quotes the passage" {
  let calls : Array[Made] = []
  let t = pick_list_tester(calls)
  t.check_looks(false)
  let before = t.audit()
  let (ax, ay, _, ah) = words_rect(t, "字和单位前后不统一")
  let (bx, by, bw, bh) = words_rect(t, "表 18")
  mouse_dragged(t, ax + 1.0, ay + ah / 2.0, bx + bw - 1.0, by + bh / 2.0)
  let picked = t.ctx().selected_text()
  assert_true(picked.has_prefix("字和单位前后不统一") && picked.has_suffix("表 18"), msg=picked)
  guard pill_over(t, by) is Some(_) else {
    fail("no 引用 over list items: box=\{Repr(t.ctx().selection_box())}, picked=\{Repr(@sfbase.picked.get())}")
  }
  assert_true(pill_mark(t, by).contains("/icon/quote/"), msg="the pill over the end has a closing quote")
  // (each fault as it was before, whatever the frame's nodes are numbered now)
  let was = before.map(aw_plain)
  assert_eq(t.audit().filter(fn(f) { !was.contains(aw_plain(f)) }), [])
  // The same passage picked upwards has the pill at the other end.
  t.run_for(@ui.double_click_ms)
  mouse_dragged(t, bx + bw - 1.0, by + bh / 2.0, ax + 1.0, ay + ah / 2.0)
  assert_eq(t.ctx().selected_text(), picked)
  guard pill_over(t, ay) is Some(_) else { fail("no 引用 over the start when picked upwards") }
  assert_true(pill_mark(t, ay).contains("/icon/quote-open/"), msg="the pill over the start has an opening quote")
  t.run_for(@ui.double_click_ms)
  guard t.words().filter(fn(w) { w.0 == "引用" && w.2 < ay && w.2 > ay - 60.0 }) is [(_, qx, qy, qw, qh, _), ..] else {
    fail("no 引用 to press")
  }
  mouse_clicked(t, qx + qw / 2.0, qy + qh / 2.0)
  let quoted = named(calls, "composer.quote")
  assert_eq(quoted.length(), 1)
  let q = field(Some(quoted[0].params), "quote")
  assert_eq((text(q, "text"), text(q, "ts"), text(q, "role")), (picked, "ts11", "agent"))
  assert_eq(t.ctx().selected_text(), "")
}

///|
test "大屏, a mouse picking across two messages is not offered 引用" {
  let calls : Array[Made] = []
  let t = pick_list_tester(calls)
  t.check_looks(false)
  let (ax, ay, _, ah) = words_rect(t, "推送截图前要先登录")
  let (bx, by, bw, bh) = words_rect(t, "好，表 14 保持现状")
  // A previously quotable selection must not keep its pill once the next drag crosses messages.
  mouse_dragged(t, bx + 1.0, by + bh / 2.0, bx + bw - 1.0, by + bh / 2.0)
  assert_true(pill_over(t, by) is Some(_))
  t.run_for(@ui.double_click_ms)
  mouse_dragged(t, ax + 1.0, ay + ah / 2.0, bx + bw - 1.0, by + bh / 2.0)
  let picked = t.ctx().selected_text()
  assert_true(picked.has_prefix("推送截图前要先登录") && picked.has_suffix("好，表 14 保持现状"), msg=picked)
  assert_true(pill_over(t, by) is None, msg="引用 over words from different messages")
  assert_eq(named(calls, "composer.quote").length(), 0)
}

///|
test "中屏's tape, built as a host builds: words a mouse picked in a message have 引用 over them in the frame it let go in, there after a while and a move, gone after a press" {
  // (this form alone shows it: a default Tester builds the frame again keeping nothing and shows the pill whatever
  // the page's view read)
  let t = tape_chat(0, 690.0, 840.0, width="medium", height="medium")
  t.check_looks(false)
  page_over(t, 690.0)
  let (mx, my) = t.find("做完了：列表、跳到最新的按钮").unwrap()
  mouse_dragged(t, mx, my, mx + 300.0, my)
  assert_true(t.ctx().selected_text() != "")
  assert_true(pill_over(t, my) is Some(_), msg="no 引用 over what is picked, in the frame it let go in")
  t.run_for(@ui.move_most_ms)
  assert_true(pill_over(t, my) is Some(_), msg="引用 gone once all the let-go set off is over")
  t.touch(1, mx + 320.0, my + 40.0)
  t.frames_owed()
  assert_true(pill_over(t, my) is Some(_), msg="引用 gone after the pointer moved")
  // (a click of its own, not a second of the press that picked: a double click's picks a word)
  t.run_for(@ui.double_click_ms)
  mouse_clicked(t, mx, my)
  t.run_for(@ui.move_most_ms)
  assert_eq(t.ctx().selected_text(), "")
  assert_true(t.words().filter(fn(w) { w.0 == "引用" }).is_empty(), msg="引用 still there after a press")
}

///|
/// The fixture's chat that has only been in a Feishu group (sffixture's chat-feishu: what was said there, all it shows),
/// on 大屏, built as a host builds (FB-37).
fn feishu_tester(calls : Array[Made]) -> @ui.Tester {
  let t = wide_tester(calls, mode="chat-feishu")
  t.check_looks(false)
  t.run_for(@ui.move_most_ms)
  t
}

///|
/// The quote the last composer.quote asked for: its words, its message, as what and whose.
fn last_quote(calls : Array[Made]) -> (String, String, String, String) raise {
  let quoted = named(calls, "composer.quote")
  guard quoted.last() is Some(m) else { fail("no composer.quote: \{Repr(calls.map(fn(c) { c.name }))}") }
  let q = field(Some(m.params), "quote")
  (text(q, "text"), text(q, "ts"), text(q, "role"), text(q, "author"))
}

///|
/// 引用 over line `y` pressed, as a mouse clicks it.
fn pill_pressed(t : @ui.Tester, y : Double) -> Unit raise {
  t.run_for(@ui.double_click_ms)
  guard t.words().filter(fn(w) { w.0 == "引用" && w.2 < y && w.2 > y - 60.0 }) is [(_, qx, qy, qw, qh, _), ..] else {
    fail("no 引用 to press over \{y}")
  }
  mouse_clicked(t, qx + qw / 2.0, qy + qh / 2.0)
  t.run_for(@ui.move_most_ms)
}

///|
test "大屏, a chat only in Feishu, built as a host builds: words a mouse picked in a list item of its agent's reply there have 引用 over them; pressed, quoted as the agent's, of no message" {
  let calls : Array[Made] = []
  let t = feishu_tester(calls)
  let (ax, ay, _, ah) = words_rect(t, "已挂载文本选区标记")
  let (bx, by, bw, bh) = words_rect(t, "浮层即可正常出现")
  mouse_dragged(t, ax + 1.0, ay + ah / 2.0, bx + bw - 1.0, by + bh / 2.0)
  let picked = t.ctx().selected_text()
  assert_true(picked.has_prefix("已挂载文本选区标记") && picked.has_suffix("浮层即可正常出现"), msg=picked)
  guard pill_over(t, by) is Some((qx, _)) else {
    fail("no 引用 over words picked in a Feishu reply: picked=\{Repr(@ui.picked_now())}")
  }
  assert_true((qx - (bx + bw)).abs() < 40.0, msg="引用 at \{qx}")
  pill_pressed(t, by)
  let (qt, ts, role, author) = last_quote(calls)
  assert_true(qt != "" && qt == picked.trim(chars=" \n\t").to_owned(), msg=qt)
  assert_eq((ts, role, author), ("", "agent", "Claude"))
  assert_true(@ui.picked_now() is None)
  assert_eq(t.ctx().selected_text(), "")
  assert_true(t.words().filter(fn(w) { w.0 == "引用" }).is_empty(), msg="引用 still there after a press")
  // (the draft shows what it quotes over its field, whose words they are before them)
  let seen = t.words().filter(fn(w) { w.0.contains("已挂载文本选区标记") && w.5 > 0.5 })
  assert_true(seen.iter().any(fn(w) { w.0.has_prefix("Claude：已挂载文本选区标记") }), msg="no quote shown in the draft: \{Repr(seen)}")
}

///|
test "大屏, a chat only in Feishu: words a mouse picked in a person's message there are quoted as theirs; picked across two of its messages, no 引用" {
  let calls : Array[Made] = []
  let t = feishu_tester(calls)
  let (ax, ay, aw, ah) = words_rect(t, "选中回复里的列表项文字")
  mouse_dragged(t, ax + 1.0, ay + ah / 2.0, ax + aw - 1.0, ay + ah / 2.0)
  assert_eq(t.ctx().selected_text(), "选中回复里的列表项文字")
  guard pill_over(t, ay) is Some(_) else { fail("no 引用 over words picked in a Feishu person's message") }
  pill_pressed(t, ay)
  assert_eq(last_quote(calls), ("选中回复里的列表项文字", "", "person", "林知夏"))
  // across the person's and the agent's: two messages, none to quote (where they are now, the draft holding a quote)
  let (ax, ay, _, ah) = words_rect(t, "选中回复里的列表项文字")
  let (bx, by, bw, bh) = words_rect(t, "已经定位到飞书接入会话")
  t.run_for(@ui.double_click_ms)
  mouse_dragged(t, ax + 1.0, ay + ah / 2.0, bx + bw - 1.0, by + bh / 2.0)
  guard @ui.picked_now() is Some(p) else { fail("nothing picked across the two") }
  assert_eq(p.of.length(), 2, msg="picked of \{@ui.list_text(p.of)}")
  t.run_for(@ui.move_most_ms)
  assert_true(t.words().filter(fn(w) { w.0 == "引用" }).is_empty(), msg="引用 over a pick across two messages")
  assert_eq(named(calls, "composer.quote").length(), 1)
}

///|
test "大屏, a chat only in Feishu, built as a host builds: words a mouse picked within one list item of its agent's reply have 引用 over them; pressed, quoted as the agent's" {
  let calls : Array[Made] = []
  let t = feishu_tester(calls)
  let (ax, ay, aw, ah) = words_rect(t, "已挂载文本选区标记")
  mouse_dragged(t, ax + 1.0, ay + ah / 2.0, ax + aw - 1.0, ay + ah / 2.0)
  guard @ui.picked_now() is Some(p) else { fail("nothing picked") }
  assert_eq(p.text, "已挂载文本选区标记")
  assert_true(!p.text.contains("\n"), msg=p.text)
  guard pill_over(t, ay) is Some((qx, _)) else { fail("no 引用 over words picked within one list item") }
  assert_true((qx - (ax + aw)).abs() < 40.0, msg="引用 at \{qx}")
  pill_pressed(t, ay)
  assert_eq(last_quote(calls), ("已挂载文本选区标记", "", "agent", "Claude"))
  assert_true(@ui.picked_now() is None)
}

///|
/// 大屏's chat in `dark` (glass drawn solid where `solid`, as MBUI_GLASS=solid makes it), words of a message a mouse
/// picked, its 引用 shown: the Tester, the faults it had before the pick and where 引用's words are drawn.
fn quote_pill_tester(dark : Bool, solid : Bool) -> (@ui.Tester, Array[String], (Double, Double, Double, Double)) raise {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="chat")
  @sf.set_dark(Some(dark))
  @ui.set_glass_solid(if solid { Some(true) } else { None })
  t.check_looks(false)
  for _ in 0..<12 {
    match t.run_rects("做了什么") {
      [(_, y, _, _), ..] if y > 100.0 && y < 500.0 => break
      _ => t.wheel(900.0, 400.0, -200.0)
    }
  }
  t.run_for(@ui.move_most_ms)
  let before = t.audit().map(aw_plain)
  let (hx, hy, _, hh) = words_rect(t, "做了什么")
  let (ix, iy, iw, ih) = words_rect(t, "滚动位置记成")
  mouse_dragged(t, hx + 1.0, hy + hh / 2.0, ix + iw - 1.0, iy + ih / 2.0)
  t.run_for(@ui.move_most_ms)
  guard t.words().filter(fn(w) { w.0 == "引用" && w.2 < iy && w.2 > iy - 60.0 }) is [(_, qx, qy, qw, qh, _), ..] else {
    fail("no 引用 over the pick (dark \{dark}, solid \{solid})")
  }
  (t, before, (qx, qy, qw, qh))
}

///|
/// Whether (x, y, w, h) holds the middle of `r`.
fn holds_middle(x : Double, y : Double, w : Double, h : Double, r : (Double, Double, Double, Double)) -> Bool {
  let cx = r.0 + r.2 / 2.0
  let cy = r.1 + r.3 / 2.0
  cx > x && cx < x + w && cy > y && cy < y + h
}

///|
test "大屏, light and dark: 引用 over words a mouse picked is one layer of liquid glass with its shadow outside, its mark and words in the ink; under MBUI_GLASS=solid the panel's ground with a hairline edge" {
  for dark in [false, true] {
    // glass
    let (t, before, q) = quote_pill_tester(dark, false)
    let ink = @sf.theme().p.text
    let glass = t.drawn_glass().filter(fn(g) { holds_middle(g.0, g.1, g.2, g.3, q) })
    let liquid = glass.filter(fn(g) { g.4 == 6 })
    guard liquid is [pill, ..] else { fail("dark \{dark}: no glass under 引用: \{Repr(t.drawn_glass())}") }
    let (px, py, pw, ph, _, _) = pill
    // (no solid ground of its own over or under the glass, the size of the pill)
    let solid_fill = t
      .drawn_rects()
      .iter()
      .any(fn(r) {
        (r.4 & 0xFFL) != 0L && (r.0 - px).abs() < 1.0 && (r.1 - py).abs() < 1.0 && (r.2 - pw).abs() < 1.0 && (r.3 - ph).abs() < 1.0
      })
    let outside_shadow = t
      .drawn_instances()
      .iter()
      .any(fn(a) { a.length() > 12 && a[5] == 2.0 && a[12] == 1.0 && holds_middle(a[0], a[1], a[2], a[3], q) })
    let words_ink = t.boxes_held().filter(fn(b) { b.text == "引用" }).map(fn(b) { b.color })
    let edged = t.boxes_held().filter(fn(b) { b.border_w > 0.0 && holds_middle(b.x, b.y, b.w, b.h, q) }).length()
    // (none new, and none of the pill's: what the page had before the pick is the sidebar's, not this)
    let new_faults = t.audit().filter(fn(f) { !before.contains(aw_plain(f)) || f.contains("chat_quote_node") })
    assert_eq(
      (dark, glass.length(), liquid.length(), solid_fill, outside_shadow, words_ink, edged, new_faults),
      (dark, 1, 1, false, true, [ink], 0, []),
    )
    // solid
    let (ts, before, q) = quote_pill_tester(dark, true)
    let panel = @sf.panel_ground()
    let glass = ts.drawn_glass().filter(fn(g) { holds_middle(g.0, g.1, g.2, g.3, q) }).length()
    let ground = ts.drawn_rects().iter().any(fn(r) { r.4 == panel && holds_middle(r.0, r.1, r.2, r.3, q) })
    let edges = ts
      .boxes_held()
      .filter(fn(b) { b.border_w > 0.0 && holds_middle(b.x, b.y, b.w, b.h, q) })
      .map(fn(b) { (b.border_w, b.border_c) })
    let words_ink = ts.boxes_held().filter(fn(b) { b.text == "引用" }).map(fn(b) { b.color })
    let new_faults = ts.audit().filter(fn(f) { !before.contains(aw_plain(f)) || f.contains("chat_quote_node") })
    @ui.set_glass_solid(None)
    assert_eq(
      (dark, glass, ground, edges, words_ink, new_faults),
      (dark, 0, true, [(@sf.control_edge_w, @sf.theme().p.line)], [@sf.theme().p.text], []),
    )
  }
  @ui.set_glass_solid(None)
  @sf.set_dark(None)
}

///|
test "大屏, words a mouse picked in a message, the list then scrolled on till they are out of what it shows (its block still built): no 引用 anywhere, not over the composer or the bars; scrolled back, 引用 over them again" {
  let calls : Array[Made] = []
  let t = pick_list_tester(calls)
  t.check_looks(false)
  let (bx, by, bw, bh) = words_rect(t, "表 18")
  mouse_dragged(t, bx + 1.0, by + bh / 2.0, bx + bw - 1.0, by + bh / 2.0)
  assert_true(t.ctx().selected_text() != "")
  guard pill_over(t, by) is Some(_) else { fail("no 引用 over the words picked") }
  let pills = fn() { t.words().filter(fn(w) { w.0 == "引用" }).length() }
  // (the list scrolled toward its top, its last message carried down past the window's foot)
  let mut turned = 0
  while turned < 12 {
    t.wheel(900.0, 400.0, -150.0)
    t.run_for(@ui.move_most_ms)
    turned = turned + 1
    if words_rect(t, "表 18").1 > 820.0 {
      break
    }
  }
  assert_true(words_rect(t, "表 18").1 > 820.0, msg="the words carried out of sight")
  assert_true(t.ctx().selected_text() != "", msg="what was picked kept as the list scrolls")
  assert_eq(pills(), 0, msg="引用 drawn with the words it stands for out of sight")
  // (scrolled back as far: 引用 over them again)
  for _ in 0..<turned {
    t.wheel(900.0, 400.0, 150.0)
    t.run_for(@ui.move_most_ms)
  }
  let (_, by2, _, _) = words_rect(t, "表 18")
  assert_true(by2 < 800.0, msg="the words back in sight: \{by2}")
  assert_true(pill_over(t, by2) is Some(_), msg="引用 over the words again")
}

///|
test "大屏, selectionIntent enabled: mouse selection shows 40pt dual-button 引用 | 戳一下 glass bar, hides on scroll out and returns on scroll back, and 戳一下 opens Poke popover at real anchor" {
  let calls : Array[Made] = []
  let lang = @signals.signal("")
  let t = pick_list_tester(calls, lang~)
  t.check_looks(false)
  @sfbase.selection_intent_feature.set(true)
  t.draw()
  let (bx, by, bw, bh) = words_rect(t, "表 18")
  mouse_dragged(t, bx + 1.0, by + bh / 2.0, bx + bw - 1.0, by + bh / 2.0)
  t.run_for(@ui.move_most_ms)
  guard t.words().filter(fn(w) { w.0 == "引用" && w.2 < by && w.2 > by - 60.0 }) is [(_, qx, qy, qw, qh, _), ..] else {
    fail("no 引用 in dual-button bar")
  }
  guard t.words().filter(fn(w) { w.0 == "戳一下" && w.2 < by && w.2 > by - 60.0 }) is [(_, px, _, _, _, _), ..] else {
    fail("no 戳一下 in dual-button bar")
  }
  assert_true(px > qx + qw, msg="戳一下 sits to the right of 引用")
  // Single 40pt liquid glass pill + hairline rule_down divider between the two actions
  let glass = t.drawn_glass().filter(fn(g) { holds_middle(g.0, g.1, g.2, g.3, (qx, qy, qw, qh)) })
  assert_eq(glass.length(), 1, msg="single liquid glass capsule")
  assert_eq(glass[0].4, 6)
  assert_true((glass[0].3 - 40.0).abs() < 0.5, msg="height 40pt: \{glass[0].3}")
  let seps = t.drawn_rects().filter(fn(r) {
    (r.2 - @sf.rule_w).abs() < 0.1 && (r.3 - 16.0).abs() < 0.5 && r.0 >= qx + qw && r.0 <= px
  })
  assert_eq(seps.length(), 1, msg="hairline rule_down separator between 引用 and 戳一下")

  // Switching language while the selection stays open updates both visible labels and a11y button names live
  lang.set("en")
  t.stepped()
  t.run_for(@ui.move_most_ms)
  assert_true(
    t.words().iter().any(fn(w) { w.0 == "Quote" && w.2 < by && w.2 > by - 60.0 }) &&
    t.query(Button, label="Quote") is Some(_),
    msg="Quote updated live on language switch",
  )
  assert_true(
    t.words().iter().any(fn(w) { w.0 == "Poke" && w.2 < by && w.2 > by - 60.0 }) &&
    t.query(Button, label="Poke") is Some(_),
    msg="Poke updated live on language switch",
  )
  lang.set("")
  t.stepped()
  t.run_for(@ui.move_most_ms)
  assert_true(
    t.query(Button, label="引用") is Some(_) && t.query(Button, label="戳一下") is Some(_),
    msg="Chinese labels restored live",
  )

  // Scroll out of sight -> dual bar hidden; scroll back -> dual bar returns
  let mut turned = 0
  while turned < 12 {
    t.wheel(900.0, 400.0, -150.0)
    t.run_for(@ui.move_most_ms)
    turned = turned + 1
    if words_rect(t, "表 18").1 > 820.0 {
      break
    }
  }
  assert_true(t.words().filter(fn(w) { w.0 == "戳一下" }).is_empty(), msg="dual bar hidden when scrolled out")
  for _ in 0..<turned {
    t.wheel(900.0, 400.0, 150.0)
    t.run_for(@ui.move_most_ms)
  }
  let (_, by2, _, _) = words_rect(t, "表 18")
  guard t.words().filter(fn(w) { w.0 == "戳一下" && w.2 < by2 && w.2 > by2 - 60.0 }) is [(_, px2, py2, pw2, ph2, _), ..] else {
    fail("dual bar did not return after scrolling back")
  }

  // Click 戳一下 -> calls chat.selectionIntent and opens Poke popover
  t.run_for(@ui.double_click_ms)
  mouse_clicked(t, px2 + pw2 / 2.0, py2 + ph2 / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(named(calls, "chat.selectionIntent").length(), 1, msg="chat.selectionIntent called")
  assert_true(t.find("轻量模型结合当前对话上下文") is Some(_), msg="Poke popover opened with reply")
  @sfbase.selection_intent_feature.set(false)
}
