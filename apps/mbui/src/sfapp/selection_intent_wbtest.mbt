// Experimental selection intent inference (实验性功能 › 选中文本自动推测意图):
// off by default (selection pill/bar unchanged); when enabled, selecting text in a chat shows 推测意图 beside 引用,
// calls `chat.selectionIntent`, and displays the inferred intent and direct reply in a panel.

///|
test "选中文本自动推测意图: off by default; when enabled, finger selection offers 推测意图 and opens the reply panel" {
  new_run()
  let calls : Array[(String, Json)] = []
  let src = fixture("chat")
  let orig_call = src.call
  let src : Source = {
    ..src,
    call: fn(name, params, cb) {
      calls.push((name, params))
      orig_call(name, params, cb)
    },
  }
  open_fixture_over("chat", src)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t.run_for(@ui.move_most_ms)

  // Locate a message with words to select.
  for _ in 0..<12 {
    match t.run_rects("高度先按 90 估") {
      [(_, py, _, _), ..] if py > 180.0 && py < 680.0 => break
      _ => {
        t.wheel(195.0, 400.0, -200.0)
        t.run_for(@ui.move_most_ms)
      }
    }
  }
  guard t.run_rects("高度先按 90 估") is [(px, py, _, ph), ..] else { fail("message words not drawn") }

  // 1. Default off: no 推测意图 button.
  t.press_at(px + 6.0, py + ph / 2.0)
  t.run_for(@ui.long_press_ms)
  t.release(px + 6.0, py + ph / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Button, label="引用") is Some(_))
  assert_true(t.query(Button, label="戳一下") is None)
  @ui.picked_let_go()
  t.run_for(@ui.move_most_ms)

  // 2. Turn on the experimental switch.
  exp_set(t, src, ["selectionIntent"], true)
  assert_true(@sfbase.selection_intent_feature.get())

  // 3. Long-press again: 戳一下 appears beside 引用.
  t.press_at(px + 6.0, py + ph / 2.0)
  t.run_for(@ui.long_press_ms)
  t.release(px + 6.0, py + ph / 2.0)
  t.run_for(@ui.move_most_ms)
  guard t.query(Button, label="戳一下") is Some(btn) else { fail("no 戳一下 button when feature is enabled") }
  let (bx, by, bw, bh) = btn.rect
  t.tap(bx + bw / 2.0, by + bh / 2.0)
  t.run_for(@ui.move_most_ms)

  // 4. `chat.selectionIntent` was called and the panel shows the direct reply with Pin and Copy actions.
  let asked = calls.filter(fn(c) { c.0 == "chat.selectionIntent" })
  assert_eq(asked.length(), 1, msg="expected one chat.selectionIntent call")
  assert_true(t.find("轻量模型结合当前对话上下文") is Some(_), msg="reply not shown")
  let drawn = @ui.view_tree().unwrap().drawn()
  guard drawn.iter().find_first(fn(d) { d.words.contains("轻量模型结合当前对话上下文") }) is Some(reply_d) else {
    fail("reply node not drawn")
  }
  guard drawn.iter().find_first(fn(d) { d.words == "戳一下" }) is Some(title_d) else {
    fail("title node not drawn")
  }
  assert_eq(reply_d.words_look.size, @sf.theme().t.meta, msg="poke reply uses meta size")
  assert_eq(title_d.words_look.size, @sf.theme().t.meta, msg="poke title uses meta size")
  assert_true(reply_d.words_look.size < @sfpages.body_size, msg="poke reply smaller than chat body prose")
  assert_true(t.query(Button, label="固定") is Some(_))
  assert_true(t.query(Button, label="复制") is Some(_))

  // 5. Clicking 固定 pins the reply into the chat, closes the panel, and supports collapse/unpin.
  t.click(Button, label="固定")
  t.run_for(@ui.move_most_ms)
  assert_eq(@sfbase.pinned_intents_for("ws1/st1:s-c1").length(), 1)
  assert_true(t.find("轻量模型结合当前对话上下文") is Some(_), msg="pinned card not visible in chat")
  t.click(Button, label="收起")
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.pinned_intents_for("ws1/st1:s-c1")[0].collapsed)
  t.click(Button, label="展开")
  t.run_for(@ui.move_most_ms)
  assert_false(@sfbase.pinned_intents_for("ws1/st1:s-c1")[0].collapsed)
  t.click(Button, label="取消固定")
  t.run_for(@ui.move_most_ms)
  assert_eq(@sfbase.pinned_intents_for("ws1/st1:s-c1").length(), 0)
}

///|
/// 戳一下 asked of `src` whose `chat.selectionIntent` fails with `message`: the words picked, 戳一下 pressed.
fn intent_failed_tester(message : String, calls : Array[String]) -> @ui.Tester raise {
  new_run()
  let src = fixture("chat")
  let orig_call = src.call
  let src : Source = {
    ..src,
    call: fn(name, params, cb) {
      if name == "chat.selectionIntent" {
        calls.push(name)
        cb(Err({ "message": Json::string(message) }))
      } else {
        orig_call(name, params, cb)
      }
    },
  }
  open_fixture_over("chat", src)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t.run_for(@ui.move_most_ms)
  exp_set(t, src, ["selectionIntent"], true)
  for _ in 0..<12 {
    match t.run_rects("高度先按 90 估") {
      [(_, py, _, _), ..] if py > 180.0 && py < 680.0 => break
      _ => {
        t.wheel(195.0, 400.0, -200.0)
        t.run_for(@ui.move_most_ms)
      }
    }
  }
  guard t.run_rects("高度先按 90 估") is [(px, py, _, ph), ..] else { fail("message words not drawn") }
  t.press_at(px + 6.0, py + ph / 2.0)
  t.run_for(@ui.long_press_ms)
  t.release(px + 6.0, py + ph / 2.0)
  t.run_for(@ui.move_most_ms)
  t.click(Button, label="戳一下")
  t.run_for(@ui.move_most_ms)
  t
}

///|
test "戳一下 failed: says so in words, 重试 in the foot in place of 复制 and 固定, the raw error under it" {
  let calls : Array[String] = []
  let t = intent_failed_tester("timeout", calls)
  assert_true(t.find("没能拿到回复") is Some(_))
  assert_true(t.find("timeout") is Some(_))
  assert_true(t.query(Button, label="复制") is None)
  assert_true(t.query(Button, label="固定") is None)
  t.click(Button, label="重试")
  t.run_for(@ui.move_most_ms)
  assert_eq(calls.length(), 2)
}

///|
test "戳一下 on a station that predates it: says to update the station, no raw route, nothing to retry" {
  let calls : Array[String] = []
  let t = intent_failed_tester("no route POST /threads/1/selection-intent", calls)
  assert_true(t.find("这台 station 还不支持「戳一下」") is Some(_))
  assert_true(t.find("no route") is None)
  assert_true(t.query(Button, label="重试") is None)
  assert_true(t.query(Button, label="复制") is None)
}

///|
test "大屏, 戳一下 open beside the words picked with the mouse: the wheel over the chat scrolls it, the answer staying open" {
  new_run()
  @sf.presenters_reset()
  let src = fixture("chat")
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.check_looks(false)
  t.run_for(@ui.move_most_ms)
  exp_set(t, src, ["selectionIntent"], true)
  let (px, py, pw, ph) = quote_nodes_words(t, "高度先按 90 估")
  t.drag(px + 1.0, py + ph / 2.0, px + pw - 1.0, py + ph / 2.0)
  t.run_for(@ui.move_most_ms)
  t.click(Button, label="戳一下")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("轻量模型结合当前对话上下文") is Some(_), msg="the answer shown")
  // (over the words picked, clear of the panel under them: the chat moves under the pointer)
  t.wheel(px + 1.0, py + ph / 2.0, -40.0)
  t.run_for(@ui.move_most_ms)
  guard t.run_rects("高度先按 90 估") is [(_, moved, _, _), ..] else { fail("words not drawn") }
  assert_true(moved > py + 20.0, msg="the chat scrolled: \{py} to \{moved}")
  assert_true(t.find("轻量模型结合当前对话上下文") is Some(_), msg="the answer stays open")
}
