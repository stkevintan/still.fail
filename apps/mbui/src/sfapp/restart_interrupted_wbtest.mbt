// Non-update restart batch-resume banner card (`restart_interrupted_parts` / `restart_interrupted_card_node`):
// verifies render, expand/collapse, reactive count/chats updates without losing expanded state,
// optimistic hide + RPC dispatch (`station.resumeInterrupted` / `station.dismissInterrupted`),
// and `restart_interrupted_gone` pruning so a subsequent restart of the same station re-shows the card.

///|
fn restart_interrupted_json(count : Int, chats : Array[(String, String)]) -> Json {
  Json::array([
    {
      "station": "ws1/st-tokyo",
      "stationName": "AFK-东京服务器",
      "count": Json::number(count.to_double()),
      "chats": Json::array(
        chats.map(fn(c) {
          { "key": Json::string(c.0), "thread": 101, "title": Json::string(c.1) }
        }),
      ),
    },
  ])
}

///|
test "restart interrupted card updates reactively, dispatches resume/dismiss, and reappears on second restart" {
  for win in [(1280.0, 800.0, 0), (390.0, 844.0, 2)] {
    let (w, h, platform) = win
    let at = "\{w}"
    new_run()
    let base = fixture("home")
    let calls : Array[Made] = []
    let version = Ref(1)
    let interrupted : @signals.Signal[Json?] = @signals.signal(
      Some(
        restart_interrupted_json(12, [
          ("s-cut-1", "修复登录态失效续跑问题"),
          ("s-cut-2", "检查 macOS 内存压力检测逻辑"),
          ("s-cut-3", "排查飞书长连接断连原因"),
        ]),
      ),
    )
    let src : Source = {
      ..base,
      topic_read: fn(name, params) {
        let snap = base.topic(name, params).get().snapshot()
        if name == "chats" {
          let cur = interrupted.get()
          match (snap.value, cur) {
            (Some(Object(m)), Some(arr)) => {
              let next = m.copy()
              next["interrupted"] = arr
              { value: Some(Json::object(next)), error: snap.error, version: version.val }
            }
            (Some(Object(m)), None) => {
              let next = m.copy()
              next.remove("interrupted")
              { value: Some(Json::object(next)), error: snap.error, version: version.val }
            }
            _ => snap
          }
        } else {
          snap
        }
      },
      call: fn(name, params, done) {
        calls.push({ name, params, bytes: None, done })
        if name == "station.resumeInterrupted" || name == "station.dismissInterrupted" {
          done(Ok(Json::object({})))
        } else {
          (base.call)(name, params, done)
        }
      },
    }
    let push_interrupted = fn(next : Json?) {
      version.val += 1
      interrupted.set(next)
    }

    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform~)
    t.run_for(@ui.move_most_ms)

    // 1. Initial render: station header + summary + action buttons visible, preview list collapsed
    let summary_12 = "意外重启，12 个对话中断"
    assert_true(t.find("AFK-东京服务器") is Some(_), msg=at + ": station name missing")
    assert_true(t.find(summary_12) is Some(_), msg=at + ": initial summary missing")
    assert_true(t.query(Button, label="全部拉起") is Some(_), msg=at + ": resumeAll missing")
    assert_true(t.query(Button, label="忽略") is Some(_), msg=at + ": dismiss missing")
    assert_true(t.find("修复登录态失效续跑问题") is None, msg=at + ": preview should start collapsed")

    // 2. Tap summary row to expand preview list
    let hdr = t.find(summary_12).unwrap()
    t.tap(hdr.0, hdr.1)
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("修复登录态失效续跑问题") is Some(_), msg=at + ": expanded chat 1 missing")
    assert_true(t.find("检查 macOS 内存压力检测逻辑") is Some(_), msg=at + ": expanded chat 2 missing")
    assert_true(t.find("排查飞书长连接断连原因") is Some(_), msg=at + ": expanded chat 3 missing")
    assert_true(t.find("还有 9 个对话") is Some(_), msg=at + ": more count 9 missing")

    // 3. Core pushes updated count & chats -> summary & expanded list update reactively without collapsing
    push_interrupted(
      Some(
        restart_interrupted_json(4, [
          ("s-cut-2", "检查 macOS 内存压力检测逻辑"),
          ("s-cut-3", "排查飞书长连接断连原因"),
        ]),
      ),
    )
    t.run_for(@ui.move_most_ms)
    let summary_4 = "意外重启，4 个对话中断"
    assert_true(t.find(summary_4) is Some(_), msg=at + ": updated count 4 summary missing")
    assert_true(t.find("修复登录态失效续跑问题") is None, msg=at + ": removed chat 1 still shown")
    assert_true(t.find("检查 macOS 内存压力检测逻辑") is Some(_), msg=at + ": expanded chat 2 should remain visible")
    assert_true(t.find("还有 2 个对话") is Some(_), msg=at + ": updated more count 2 missing")

    // 4. Tap summary row again to collapse
    let hdr4 = t.find(summary_4).unwrap()
    t.tap(hdr4.0, hdr4.1)
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("检查 macOS 内存压力检测逻辑") is None, msg=at + ": preview should collapse")

    // 5. Click 全部拉起 -> dispatches station.resumeInterrupted and optimistically hides card
    t.click(Button, label="全部拉起")
    // (it leaves by its way, drawn as it goes, not emptied at once: rows under it never jump up)
    t.run_for(@ui.move_least_ms / 4.0)
    assert_true(t.find(summary_4) is Some(_), msg=at + ": card vanished at once instead of leaving by its way")
    t.run_for(@ui.move_most_ms)
    assert_true(
      calls.iter().any(fn(c) {
        c.name == "station.resumeInterrupted" &&
        field(Some(c.params), "station") == Some(Json::string("ws1/st-tokyo"))
      }),
      msg=at + ": station.resumeInterrupted not called",
    )
    assert_true(t.find(summary_4) is None, msg=at + ": card should hide optimistically after resumeAll")

    // 6. Core clears interrupted (prunes restart_interrupted_gone), then same station restarts again -> card reappears
    push_interrupted(None)
    t.run_for(@ui.move_most_ms)
    push_interrupted(
      Some(
        restart_interrupted_json(2, [
          ("s-cut-new", "二次重启中断的对话"),
        ]),
      ),
    )
    t.run_for(@ui.move_most_ms)
    let summary_2 = "意外重启，2 个对话中断"
    assert_true(t.find(summary_2) is Some(_), msg=at + ": card must reappear on second restart of same station")

    // 7. Click 忽略 -> dispatches station.dismissInterrupted and optimistically hides card
    t.click(Button, label="忽略")
    t.run_for(@ui.move_least_ms / 4.0)
    assert_true(t.find(summary_2) is Some(_), msg=at + ": card vanished at once instead of leaving by its way after dismiss")
    t.run_for(@ui.move_most_ms)
    assert_true(
      calls.iter().any(fn(c) {
        c.name == "station.dismissInterrupted" &&
        field(Some(c.params), "station") == Some(Json::string("ws1/st-tokyo"))
      }),
      msg=at + ": station.dismissInterrupted not called",
    )
    assert_true(t.find(summary_2) is None, msg=at + ": card should hide optimistically after dismiss")
  }
}
