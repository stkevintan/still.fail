// The open chat's bar on 大屏 and 中屏 (sfdesk's chat_bar_wide_node over the chat's page): what it shows in each state the
// chat can be in, laid out as the old bar laid it (the two compared word by word and rectangle by rectangle as the bar
// was made of nodes), and what each of its presses does.

///|
/// The fixture's chat (`mode`) on 大屏 (中屏 where `w` is one's), a window `w` × `h` of `platform`, the system's bars handed it where `able`;
/// its calls kept in `calls` and answered with nothing; each topic as `over` makes it; `inset`: a Windows 11 window's
/// (its corners 8, its own buttons the app's, in its top row); `nodes`: the chat's page made with its inside nodes.
fn wide_bar_at(
  calls : Array[Made],
  mode? : String = "chat",
  over? : (String, Topic) -> Topic = fn(_, t) { t },
  w? : Double = 1280.0,
  h? : Double = 800.0,
  platform? : Int = 0,
  able? : Bool = false,
  room? : String = "",
  inset? : Bool = false,
) -> @ui.Tester {
  new_run()
  let base = fixture(mode)
  let src : Source = {
    ..base,
    call: fn(name, params, done) {
      calls.push({ name, params, bytes: None, done })
      done(Ok(Json::object({})))
    },
    topic_read: fn(name, params) { over(name, base.topic(name, params).get().snapshot()) },
  }
  open_fixture_over(mode, src)
  let t = if inset {
    @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform~, nav_able=able, window_corner=8.0, window_inset=true)
  } else {
    @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform~, nav_able=able)
  }
  if able {
    t.post(@hostapi.system_channel, "{\"bars\":{\"top\":0,\"bottom\":20,\"left\":0,\"right\":84}}")
  }
  if room != "" {
    say_room(t, room, room)
  }
  t.run_for(@ui.move_most_ms)
  // (中屏: the chat's panel of the tape brought into use, as a press on what shows of it does)
  if @sfdesk.wide.tape.get() {
    page_over(t, w)
  }
  t
}

///|
/// Topic `name`'s value as `edit` makes it of what it was (the rest as they are).
fn wide_bar_edit(name : String, edit : (Json?) -> Json?) -> (String, Topic) -> Topic {
  fn(n, tp) {
    guard n == name else { return tp }
    { ..tp, value: edit(tp.value) }
  }
}

///|
/// Two edits of the topics, one after the other.
fn wide_bar_both(a : (String, Topic) -> Topic, b : (String, Topic) -> Topic) -> (String, Topic) -> Topic {
  fn(n, tp) { b(n, a(n, tp)) }
}

///|
/// The chat's field `key` set to `value`.
fn wide_bar_chat_field(key : String, value : (Json?) -> Json) -> (String, Topic) -> Topic {
  wide_bar_edit("chat", fn(v) {
    match v {
      Some(Object(m)) => {
        let o = m.copy()
        o[key] = value(m.get(key))
        Some(Json::object(o))
      }
      other => other
    }
  })
}

///|
/// The chat with `n` agents, each its first's made again by another key and name.
fn wide_bar_agents(n : Int) -> (String, Topic) -> Topic {
  wide_bar_chat_field("agents", fn(was) {
    let first = match was {
      Some(Array(a)) if a.length() > 0 => a[0]
      _ => Json::object({})
    }
    let all : Array[Json] = []
    for i in 0..<n {
      match first {
        Object(m) => {
          let o = m.copy()
          match m.get("session") {
            Some(Object(s)) => {
              let ss = s.copy()
              if i > 0 {
                ss["key"] = Json::string("s-x\{i}")
                ss["agentText"] = Json::string("Agent \{i}")
              }
              o["session"] = Json::object(ss)
            }
            _ => ()
          }
          all.push(Json::object(o))
        }
        other => all.push(other)
      }
    }
    Json::array(all)
  })
}

///|
/// The chat with `n` people, the first `pictured` of them with a picture.
fn wide_bar_people(n : Int) -> (String, Topic) -> Topic {
  wide_bar_chat_field("people", fn(_) {
    Json::array(
      Array::makei(n, fn(i) {
        Json::object({
          "id": Json::string("u\{i}"),
          "shown": Json::object({ "name": Json::string("人\{i}"), "display": Json::string("Person \{i}") }),
        })
      }),
    )
  })
}

///|
/// The core's `doing` with one `chat.rename` of the fixture's chat to `title`, at `stage`.
fn wide_bar_renaming(title : String, stage? : String = "sent", error? : String = "") -> (String, Topic) -> Topic {
  wide_bar_edit("doing", fn(_) {
    Some({
      "doing": [
        {
          "call": "chat.rename",
          "stage": Json::string(stage),
          "error": Json::string(error),
          "params": { "station": "ws1/st1", "session": "s-c1", "title": Json::string(title) },
        },
      ],
    })
  })
}

///|
/// The chat's services and jobs: some, one died lately (`alarm`).
fn wide_bar_jobs(alarm : String) -> (String, Topic) -> Topic {
  wide_bar_edit("chatJobs", fn(_) {
    Some({ "hasJobs": true, "hasServices": true, "jobs": [], "alarm": Json::string(alarm), "serviceAlarm": Json::string(alarm) })
  })
}

///|
/// The pointer moved onto the middle of what is said `label` in the bar (the topmost), or onto `words` drawn in it.
fn wide_bar_point(t : @ui.Tester, label? : String = "", suffix? : String = "", words? : String = "", right? : Double = 0.0) -> Unit {
  let at = if words != "" {
    match t.locate(words) {
      [p, ..] => Some(p)
      _ => None
    }
  } else {
    match t.all(Button).filter(fn(b) { (label != "" && b.label == label) || (suffix != "" && b.label.has_suffix(suffix)) }) {
      [b, ..] => {
        let (x, y, w, h) = b.rect
        Some((if right > 0.0 { x + w + right } else { x + w / 2.0 }, y + h / 2.0))
      }
      _ => None
    }
  }
  match at {
    Some((x, y)) => {
      t.move_to(x, y)
      t.frame()
      t.frame()
    }
    None => @halt.saying("nothing in the bar said \{label}\{suffix}\{words}")
  }
}

///|
/// The pointer rested on the bar's button said `label` till its tip shows.
fn wide_bar_tip(t : @ui.Tester, label : String) -> Unit {
  wide_bar_point(t, label~)
  t.run_for(@sf.tip_delay_ms + @ui.move_most_ms)
}

///|
/// The states of a chat the bar on 大屏 is held to (the old bar's each pinned against the new: the PR's own), each made
/// on calls kept in `calls`, by its name.
fn wide_bar_large(calls : Array[Made]) -> Array[(String, () -> @ui.Tester)] {
  [
    ("AGENT", fn() { wide_bar_at(calls) }),
    ("NOAGENT", fn() { wide_bar_at(calls, over=wide_bar_agents(0)) }),
    ("AGENTS", fn() { wide_bar_at(calls, over=wide_bar_agents(3)) }),
    ("PEOPLE", fn() { wide_bar_at(calls, over=wide_bar_people(7)) }),
    ("NARROW", fn() { wide_bar_at(calls, over=wide_bar_both(wide_bar_people(7), wide_bar_agents(3)), w=860.0) }),
    ("RENAME", fn() { wide_bar_at(calls, over=wide_bar_renaming("发布清单 v2")) }),
    (
      "RENAMEFAIL",
      fn() { wide_bar_at(calls, over=wide_bar_renaming("发布清单 v2", stage="failed", error="无法重命名：Willow 不在线")) },
    ),
    ("JOBS", fn() { wide_bar_at(calls, over=wide_bar_jobs("fail")) }),
    ("RESTART", fn() { wide_bar_at(calls, over=wide_bar_jobs("restart")) }),
    ("SCREEN", fn() { wide_bar_at(calls, mode="chat-station-screen") }),
    ("SCREENS", fn() { wide_bar_at(calls, mode="chat-station-screens") }),
    ("BESIDE", fn() { wide_bar_at(calls, mode="chat-history-side") }),
    ("FIND", fn() { wide_bar_at(calls, mode="chat-find") }),
    ("NARROW-FIND", fn() { wide_bar_at(calls, mode="chat-find", over=wide_bar_people(7), w=860.0) }),
    ("ARCHIVABLE", fn() { wide_bar_at(calls, over=wide_bar_chat_field("archivable", fn(_) { Json::boolean(true) })) }),
    (
      "ARCHIVE-JOBS",
      fn() {
        wide_bar_at(calls, over=wide_bar_both(wide_bar_chat_field("archivable", fn(_) { Json::boolean(true) }), wide_bar_jobs("fail")))
      },
    ),
    ("SCREENS-DRIVEN", fn() { wide_bar_at(calls, mode="chat-station-screens", over=wide_bar_jobs("restart")) }),
    ("TOUCH", fn() { wide_bar_at(calls, platform=2) }),
    ("TOUCH-NOAGENT", fn() { wide_bar_at(calls, platform=2, over=wide_bar_agents(0)) }),
    ("WIN", fn() { wide_bar_at(calls, platform=3) }),
    ("NATIVE", fn() { wide_bar_at(calls, w=951.0, h=669.0, platform=1, able=true) }),
    ("WAITING", fn() { wide_bar_at(calls, mode="chat-loading") }),
    (
      "HOVER-STATION",
      fn() {
        let t = wide_bar_at(calls, over=wide_bar_agents(0))
        wide_bar_point(t, words="Willow")
        t
      },
    ),
    (
      "HOVER-AGENT",
      fn() {
        let t = wide_bar_at(calls)
        wide_bar_point(t, suffix="的执行历史")
        t
      },
    ),
    (
      "HOVER-PART",
      fn() {
        let t = wide_bar_at(calls)
        wide_bar_point(t, words="Willow")
        t
      },
    ),
    (
      "HOVER-INFO",
      fn() {
        let t = wide_bar_at(calls)
        wide_bar_point(t, label=@sf.t("web-pages.chat.info"))
        t
      },
    ),
    // (each button's tip shown: its words, then its keys where it has any)
    (
      "TIP-ARCHIVE",
      fn() {
        let t = wide_bar_at(calls, over=wide_bar_chat_field("archivable", fn(_) { Json::boolean(true) }))
        wide_bar_tip(t, @sf.t("web-pages.chat.archive"))
        t
      },
    ),
    (
      "TIP-JOBS",
      fn() {
        let t = wide_bar_at(calls, over=wide_bar_jobs("fail"))
        wide_bar_tip(t, @sf.t("web-main.jobs.services"))
        t
      },
    ),
    (
      "TIP-SCREEN",
      fn() {
        let t = wide_bar_at(calls, mode="chat-station-screen")
        wide_bar_tip(t, @sf.t("web-pages.chat.screen"))
        t
      },
    ),
    (
      "TIP-INFO",
      fn() {
        let t = wide_bar_at(calls)
        wide_bar_tip(t, @sf.t("web-pages.chat.info"))
        t
      },
    ),
    (
      "TIP-PANEL",
      fn() {
        let t = wide_bar_at(calls)
        wide_bar_tip(t, @sf.t("web-pages.chat.openPanel"))
        t
      },
    ),
    (
      "TIP-PANEL-TOUCH",
      fn() {
        let t = wide_bar_at(calls, platform=2)
        wide_bar_tip(t, @sf.t("web-pages.chat.openPanel"))
        t
      },
    ),
  ]
}

///|
/// The same on 中屏: the chat in the page's panel of the tape, brought into use.
fn wide_bar_medium(calls : Array[Made]) -> Array[(String, () -> @ui.Tester)] {
  [
    ("M-AGENT", fn() { wide_bar_at(calls, w=720.0) }),
    ("M-NOAGENT", fn() { wide_bar_at(calls, w=720.0, over=wide_bar_agents(0)) }),
    ("M-AGENTS", fn() { wide_bar_at(calls, w=720.0, over=wide_bar_agents(3)) }),
    ("M-PEOPLE", fn() { wide_bar_at(calls, w=720.0, over=wide_bar_people(7)) }),
    ("M-NARROW", fn() { wide_bar_at(calls, over=wide_bar_both(wide_bar_people(7), wide_bar_agents(3)), w=600.0) }),
    ("M-RENAME", fn() { wide_bar_at(calls, w=720.0, over=wide_bar_renaming("发布清单 v2")) }),
    (
      "M-RENAMEFAIL",
      fn() {
        wide_bar_at(calls, w=720.0, over=wide_bar_renaming("发布清单 v2", stage="failed", error="无法重命名：Willow 不在线"))
      },
    ),
    ("M-JOBS", fn() { wide_bar_at(calls, w=720.0, over=wide_bar_jobs("fail")) }),
    ("M-SCREENS", fn() { wide_bar_at(calls, w=720.0, mode="chat-station-screens") }),
    ("M-BESIDE", fn() { wide_bar_at(calls, w=720.0, mode="chat-history-side") }),
    ("M-FIND", fn() { wide_bar_at(calls, w=720.0, mode="chat-find") }),
    (
      "M-ARCHIVABLE",
      fn() { wide_bar_at(calls, w=720.0, over=wide_bar_chat_field("archivable", fn(_) { Json::boolean(true) })) },
    ),
    ("M-TOUCH", fn() { wide_bar_at(calls, w=690.0, h=840.0, platform=2, room="medium") }),
    ("M-WIN", fn() { wide_bar_at(calls, w=720.0, platform=3) }),
    ("M-NATIVE", fn() { wide_bar_at(calls, w=820.0, h=1180.0, platform=1, able=true) }),
    ("M-WAITING", fn() { wide_bar_at(calls, w=720.0, mode="chat-loading") }),
    (
      "M-HOVER-STATION",
      fn() {
        let t = wide_bar_at(calls, w=720.0, over=wide_bar_agents(0))
        wide_bar_point(t, words="Willow")
        t
      },
    ),
    (
      "M-HOVER-AGENT",
      fn() {
        let t = wide_bar_at(calls, w=720.0)
        wide_bar_point(t, suffix="的执行历史")
        t
      },
    ),
    (
      "M-TIP-ARCHIVE",
      fn() {
        let t = wide_bar_at(calls, w=720.0, over=wide_bar_chat_field("archivable", fn(_) { Json::boolean(true) }))
        wide_bar_tip(t, @sf.t("web-pages.chat.archive"))
        t
      },
    ),
    (
      "M-TIP-PANEL",
      fn() {
        let t = wide_bar_at(calls, w=720.0)
        wide_bar_tip(t, @sf.t("web-pages.chat.openPanel"))
        t
      },
    ),
  ]
}

///|
/// What the nodes' audit says of the bar (its faults made in chat_bar_wide_node or find_bar_node) in state `name`, the
/// old bar's own as it was laid out (the old view held them to no rule; reported, pinned, 2026-11-11): its agents but
/// the first, 20 marks 10 apart, pressed in 33 × 36 (AGENTS, NARROW: two each). (A station's screens' count, 2.27:1 on
/// the amber of one driven, went with the count itself, 2026-11-13.)
fn wide_bar_known(_name : String) -> Array[String] {
  []
}

///|
/// Each state of `states` held to the old bar's arrangement as the comparison found it the same (words and rectangles,
/// one by one: rc3-11 against rc3-24), as relations here: what the bar shows on its middle line, its buttons from its
/// end in, nothing of it past the window; what the audit says of it only what wide_bar_known pins.
fn wide_bar_held(states : Array[(String, () -> @ui.Tester)]) -> Array[String] {
  let faults : Array[String] = []
  for s in states {
    let (name, make) = s
    let t = make()
    let (ww, _) = t.ctx().window_size()
    // (the bar's own: its agents' marks and its buttons, by what they are called, none as tall as a panel (中屏's side
    // panel off the tape, said 打开侧栏))
    let own = [
      @sf.t("web-pages.chat.archive"),
      @sf.t("web-main.jobs.services"),
      @sf.t("web-pages.chat.screen"),
      @sf.t("web-pages.chat.info"),
      @sf.t("common.more"),
      @sf.t("web-pages.chat.openPanel"),
    ]
    let bar = t
      .all(Button)
      .filter(fn(b) { b.rect.1 < 90.0 && b.rect.3 < 90.0 && (own.contains(b.label) || b.label.has_suffix("的执行历史")) })
    // (in the bar's middle, each: its buttons and its agents' marks alike)
    let mids = bar.map(fn(b) { b.rect.1 + b.rect.3 / 2.0 })
    if mids.length() > 1 && mids.iter().any(fn(m) { (m - mids[0]).abs() > 0.5 }) {
      faults.push("\{name}: not on one line: \{Repr(bar.map(fn(b) { (b.label, b.rect) }))}")
    }
    if bar.iter().any(fn(b) { b.rect.0 + b.rect.2 > ww }) {
      faults.push("\{name}: past the window: \{Repr(bar.map(fn(b) { (b.label, b.rect) }))}")
    }
    let audit = t.audit().filter(fn(f) { f.contains("chat_bar_wide_node") || f.contains("find_bar_node") })
    let known = wide_bar_known(name)
    let unknown = audit.filter(fn(f) { !known.iter().any(fn(k) { f.contains(k) }) })
    if unknown.length() > 0 || audit.length() != known.length() {
      faults.push("\{name}: audit \{Repr(audit)}")
    }
  }
  faults
}

///|
test "大屏: the bar in each state of its chat, as the old one laid it out; what the audit says of it the old one's own, pinned" {
  // (its own run first: each state's maker starts another before it reads a word)
  new_run()
  let calls : Array[Made] = []
  let faults = wide_bar_held(wide_bar_large(calls))
  assert_eq(faults, [], msg=faults.join("\n"))
}

///|
test "中屏: the bar in each state of its chat, as the old one laid it out; what the audit says of it the old one's own, pinned" {
  new_run()
  let calls : Array[Made] = []
  let faults = wide_bar_held(wide_bar_medium(calls))
  assert_eq(faults, [], msg=faults.join("\n"))
}
///|
/// The bar's button said `label` (its topmost; none as tall as a panel), where it is.
fn wide_bar_button(t : @ui.Tester, label : String) -> (Double, Double, Double, Double)? {
  match t.all(Button).filter(fn(b) { b.label == label && b.rect.3 < 90.0 }) {
    [b, ..] => Some(b.rect)
    _ => None
  }
}

///|
/// Where the bar's button `label` is drawn (wide_bar_button's), read out or not: the bar's buttons behind a popover the
/// tree puts up over the window (a chat's page made as nodes: chat_pops_node) are none of a screen reader's while it is
/// open, as anything behind a modal layer is.
fn wide_bar_button_drawn(t : @ui.Tester, label : String) -> (Double, Double, Double, Double)? {
  match t.semantics().filter(fn(b) { b.role == @ui.Role::Button && b.label == label && b.rect.3 < 90.0 }) {
    [b, ..] => Some(b.rect)
    _ => None
  }
}

///|
/// A press in the middle of `r`, its moment declared.
fn wide_bar_tap(t : @ui.Tester, r : (Double, Double, Double, Double)) -> Unit {
  let (x, y, w, h) = r
  t.tap(x + w / 2.0, y + h / 2.0)
  t.run_for(@ui.move_most_ms)
}

///|
/// The windows a bar's press is held to: a Mac's 1280 × 800 (Large), 720 wide (Medium: the chat in the page's panel of
/// the tape).
// kept across runs: a value
let wide_bar_windows : Array[(String, Double)] = [("大屏", 1280.0), ("中屏", 720.0)]

///|
test "大屏, 中屏: the bar's 对话信息 opens the chat's info under it and closes it again, its services' button their popover" {
  for win in wide_bar_windows {
    let calls : Array[Made] = []
    let t = wide_bar_at(calls, w=win.1, over=wide_bar_jobs("fail"))
    let info = @sf.t("web-pages.chat.info")
    guard wide_bar_button(t, info) is Some(b) else { fail("\{win.0}: no \{info}") }
    wide_bar_tap(t, b)
    assert_eq(@sfdesk.chat_pops_open(), (true, false), msg=win.0)
    // (under its button, its right edge by the button's: bar_popovers' Bottom, End)
    let dialogs = t.all(Dialog)
    assert_true(dialogs.length() > 0, msg="\{win.0}: the info's popover")
    let (dx, dy, dw, dh) = dialogs[dialogs.length() - 1].rect
    assert_true(wide_bar_under((dx, dy, dw, dh), b), msg="\{win.0}: under its button: \{Repr((dx, dy, dw, dh))} \{Repr(b)}")
    // In-place liquid morph replaces the trigger capsule while open, so dismiss via outside press.
    t.tap(win.1 / 2.0, 500.0)
    t.run_for(@ui.move_most_ms)
    assert_eq(@sfdesk.chat_pops_open(), (false, false), msg="\{win.0}: closed by outside press")
    let jobs = @sf.t("web-main.jobs.services")
    guard wide_bar_button(t, jobs) is Some(j) else { fail("\{win.0}: no \{jobs}") }
    wide_bar_tap(t, j)
    assert_eq(@sfdesk.chat_pops_open(), (false, true), msg=win.0)
    @sfdesk.toggle_jobs_pop()
    t.run_for(@ui.move_most_ms)
  }
}

///|
test "大屏, 中屏: the bar's \"…\" opens the chat's menu beside it; its side panel's switch opens its first agent's history; its agent's mark the same" {
  for win in wide_bar_windows {
    let calls : Array[Made] = []
    let t = wide_bar_at(calls, w=win.1)
    @sf.presenters_reset()
    guard wide_bar_button(t, @sf.t("common.more")) is Some(m) else { fail("\{win.0}: no …") }
    wide_bar_tap(t, m)
    assert_true(@sf.presenting(), msg="\{win.0}: its menu")
    t.key(@ui.key_escape)
    t.run_for(@ui.move_most_ms)
    assert_true(!@sf.presenting(), msg="\{win.0}: closed")
    let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
    guard wide_bar_button(t, @sf.t("web-pages.chat.openPanel")) is Some(p) else { fail("\{win.0}: no panel switch") }
    wide_bar_tap(t, p)
    // (the core asked to open its first agent's history beside the chat: its calls answered with nothing here)
    let opened = fn() { calls.filter(fn(c) { c.name == "chat.tabs.open" && text(Some(c.params), "tab") == "s-c1" }).length() }
    assert_eq(opened(), 1, msg="\{win.0}: its history beside the chat: \{Repr(calls.map(fn(c) { c.name }))}")
    let t = wide_bar_at(calls, w=win.1)
    let tile = t.all(Button).filter(fn(b) { b.label.has_suffix("的执行历史") && b.rect.1 > 400.0 })
    assert_eq(tile.length(), 1, msg=win.0)
    wide_bar_tap(t, tile[0].rect)
    assert_eq(opened(), 2, msg="\{win.0}: the agent's history from its mark: \{Repr(calls.map(fn(c) { c.name }))}")
    ignore(r)
  }
}

///|
test "大屏, 中屏: 归档 on a chat with nothing left in it puts it in the archive (chat.archive)" {
  for win in wide_bar_windows {
    let calls : Array[Made] = []
    let t = wide_bar_at(calls, w=win.1, over=wide_bar_chat_field("archivable", fn(_) { Json::boolean(true) }))
    guard wide_bar_button(t, @sf.t("web-pages.chat.archive")) is Some(a) else { fail("\{win.0}: no 归档") }
    wide_bar_tap(t, a)
    assert_true(calls.iter().any(fn(c) { c.name == "chat.archive" }), msg="\{win.0}: \{Repr(calls.map(fn(c) { c.name }))}")
  }
}

///|
test "大屏: a press on the bar where nothing of it takes one drags the window, in one with its buttons in its top row" {
  let calls : Array[Made] = []
  let t = wide_bar_at(calls)
  let before = t.window_drags()
  guard wide_bar_button(t, @sf.t("web-pages.chat.info")) is Some(b) else { fail("no info") }
  // (between the title's row and the buttons: the bar's own)
  t.press_at(b.0 - 120.0, b.1 + b.3 / 2.0)
  t.release(b.0 - 120.0, b.1 + b.3 / 2.0)
  t.frame()
  assert_eq(t.window_drags() - before, if @ui.window_inset() { 1 } else { 0 })
}

///|
test "大屏, 中屏: a button of the bar says its keys in its tip after its words, as the app says them" {
  for win in wide_bar_windows {
    let calls : Array[Made] = []
    let tips = [
      ("web-pages.chat.archive", "chat.archive"),
      ("web-main.jobs.services", "chat.jobs"),
      ("web-pages.chat.screen", "chat.screen"),
      ("web-pages.chat.openPanel", "chat.history"),
    ]
    for tip in tips {
      let t = wide_bar_at(
        calls,
        w=win.1,
        mode=if tip.1 == "chat.screen" { "chat-station-screen" } else { "chat" },
        over=wide_bar_both(wide_bar_chat_field("archivable", fn(_) { Json::boolean(true) }), wide_bar_jobs("fail")),
      )
      let label = @sf.t(tip.0)
      let keys = @sf.shortcut_keys(tip.1)
      assert_true(keys != "", msg="\{win.0}: \{tip.1} has keys")
      guard wide_bar_button(t, label) is Some(b) else { fail("\{win.0}: no \{label}") }
      wide_bar_tip(t, label)
      // (its words, then its keys each a cap after them, in their order, on their line, beside the button)
      let under = fn(w : String) { t.locate(w).filter(fn(p) { p.1 > b.1 + b.3 || p.1 < b.1 }) }
      guard under(label) is [w, ..] else { fail("\{win.0}: \{label}'s tip: \{Repr(under(label))}") }
      let mut after = w.0
      for cap in @sf.key_caps(keys) {
        // (on the words' line, after the key before it)
        guard under(cap).filter(fn(k) { k.0 > after && (k.1 - w.1).abs() < 2.0 }) is [k, ..] else {
          fail("\{win.0}: \{label}'s key \{cap} after \{after} on its line \{Repr(w)}: \{Repr(under(cap))}")
        }
        after = k.0
      }
    }
  }
}

///|
/// The last dialog drawn (an old view's popover, the topmost), where it is.
fn wide_bar_dialog(t : @ui.Tester) -> (Double, Double, Double, Double)? {
  match t.all(Dialog) {
    [] => None
    ds => Some(ds[ds.length() - 1].rect)
  }
}

///|
/// Whether popover `d` stands beside button `b` (under for top-bar buttons, above for composer-bar buttons),
/// its end at the button's.
fn wide_bar_under(d : (Double, Double, Double, Double), b : (Double, Double, Double, Double)) -> Bool {
  // In-place liquid morph aligns top-bar popovers with the pill top (with pill_pad=2pt / viewport_pad=8pt)
  // and composer-top popovers with the capsule bottom (strictly above the composer).
  let vertical_ok = if b.1 < 90.0 {
    d.1 >= b.1 - 4.0 && d.1 <= b.1 + b.3 + 12.0
  } else {
    d.1 < b.1 && d.1 + d.3 <= b.1 + b.3 + 1.0
  }
  let end_ok = d.0 + d.2 >= b.0 + b.2 - 1.0 && d.0 + d.2 <= b.0 + b.2 + 3.0
  vertical_ok && end_ok
}

///|
test "大屏, 中屏: the bar's popovers keep by their buttons as the window changes, opened by a press or by a key; closed, the focus where it was" {
  for win in wide_bar_windows {
    let calls : Array[Made] = []
    for which in ["info", "jobs"] {
      let t = wide_bar_at(calls, w=win.1, over=wide_bar_jobs("fail"))
      let label = @sf.t(if which == "info" { "web-pages.chat.info" } else { "web-main.jobs.services" })
      let opened = fn() {
        let (i, j) = @sfdesk.chat_pops_open()
        if which == "info" {
          i
        } else {
          j
        }
      }
      guard wide_bar_button(t, label) is Some(b) else { fail("\{win.0}: no \{label}") }
      let focused = fn() { t.focused().map(fn(s) { s.label }) }
      wide_bar_tap(t, b)
      assert_true(opened(), msg="\{win.0}: \{label} opened")
      guard wide_bar_dialog(t) is Some(d) else { fail("\{win.0}: \{label}'s popover") }
      assert_true(wide_bar_under(d, b), msg="\{win.0}: \{label}'s popover by it: \{Repr(d)} \{Repr(b)}")
      // (the window wider: the button moved with the bar's end, its popover with it)
      t.resize(win.1 + 160.0, 800.0)
      t.run_for(@ui.move_most_ms)
      guard (wide_bar_button_drawn(t, label), wide_bar_dialog(t)) is (Some(b2), Some(d2)) else {
        fail("\{win.0}: \{label} wider")
      }
      assert_true(b2.0 != b.0, msg="\{win.0}: \{label} moved: \{Repr(b)} \{Repr(b2)}")
      assert_true(wide_bar_under(d2, b2), msg="\{win.0}: \{label}'s popover by it, wider: \{Repr(d2)} \{Repr(b2)}")
      // (closed by Escape: where the chat's page is made as nodes its bar's popovers are the library's presenters, which
      // give the focus back to what opened them, the button (decided: the library's rule); on the old page back where it
      // was as it opened, as the old view's popover gives it (kit's popover: what had it; the button only where that had
      // it))
      t.key(@ui.key_escape)
      t.run_for(@ui.move_most_ms)
      assert_true(!opened(), msg="\{win.0}: \{label} closed")
      let back = Some(label)
      assert_eq(focused(), back, msg="\{win.0}: the focus back where it was")
      // (opened by a key (a fixture's, the system's bars' item): by the button where it is, the window narrower again)
      if which == "info" {
        @sfdesk.open_info_pop()
      } else {
        @sfdesk.open_jobs_pop()
      }
      t.run_for(@ui.move_most_ms)
      t.resize(win.1, 800.0)
      t.run_for(@ui.move_most_ms)
      guard (wide_bar_button_drawn(t, label), wide_bar_dialog(t)) is (Some(b3), Some(d3)) else {
        fail("\{win.0}: \{label} by a key")
      }
      assert_true(wide_bar_under(d3, b3), msg="\{win.0}: \{label}'s popover by it, by a key: \{Repr(d3)} \{Repr(b3)}")
      t.key(@ui.key_escape)
      t.run_for(@ui.move_most_ms)
      assert_true(!opened(), msg="\{win.0}: \{label} closed again")
      assert_eq(t.audit().filter(fn(f) { f.contains("chat_bar_wide_node") }), [], msg=win.0)
    }
  }
}

///|
/// The words `w` drawn in the bar (over 90), seen: where they are and how wide, the first of them.
fn wide_bar_seen(t : @ui.Tester, w : String) -> (Double, Double)? {
  match t.words().filter(fn(x) { x.0 == w && x.2 < 90.0 && x.5 > 0.0 && x.3 > 0.0 }) {
    [x, ..] => Some((x.1, x.3))
    _ => None
  }
}

///|
test "大屏, 中屏: ⌘F's bar open in a bar short of room: the chat's people leave first, its title cut to 4 of its letters, its field the rest, none of it past the bar" {
  // (not the old bar's, on purpose (the coordinator, 2026-11-12): the old title row's least was 12 + 64 + 10 + 20 =
  // 106, its agent's piece's least taken as 20 where it drew 41.6, so the 21.6 more it took came off the title's 4
  // letters (大屏 860 with 7 people: the title 42.4, the field 262.4; 中屏 720: 42.4 and 305.9; 760: 60.4), never meant
  // so (K2, measured in the old code). Here the title keeps its 4 letters, the field gives the rest (860: 248.6, 720:
  // 292.1))
  let calls : Array[Made] = []
  // (a letter of the title as the bar draws it with room: its whole width, its letters)
  let letter = match wide_bar_seen(wide_bar_at(calls), "整理发布清单") {
    Some((_, w)) => w / "整理发布清单".length().to_double()
    None => fail("no title with room")
  }
  let states = [
    ("NARROW-FIND", fn() { wide_bar_at(calls, mode="chat-find", over=wide_bar_people(7), w=860.0) }, ["P", "+2"]),
    ("M-FIND", fn() { wide_bar_at(calls, mode="chat-find", w=720.0) }, ["你", "A"]),
  ]
  for s in states {
    let (name, make, people) = s
    let t = make()
    let (ww, _) = t.ctx().window_size()
    for p in people {
      assert_true(wide_bar_seen(t, p) is None, msg="\{name}: its people left out (\{p}): \{Repr(t.words().filter(fn(w) { w.2 < 90.0 }))}")
    }
    let (tx, tw) = match wide_bar_seen(t, "整理发布清单") {
      Some(x) => x
      None => fail("\{name}: no title")
    }
    assert_true(tw >= 4.0 * letter - 0.5, msg="\{name}: its title at least 4 letters wide: \{tw}, a letter \{letter}")
    match (wide_bar_seen(t, "在对话中查找"), wide_bar_seen(t, "无结果")) {
      (Some((fx, _)), Some((x, w))) => {
        assert_true(fx > tx + tw, msg="\{name}: the field after the title: \{fx} \{Repr((tx, tw))}")
        assert_true(x + w <= ww, msg="\{name}: its count within the window: \{Repr((x, w))} \{ww}")
      }
      _ => fail("\{name}: no field or count in ⌘F's bar")
    }
    let audit = t.audit().filter(fn(f) { f.contains("chat_bar_wide_node") || f.contains("find_bar_node") })
    assert_eq(audit, [], msg=name)
  }
}

///|
/// Whether something is drawn on `r` (a half of the agent's tile lit: its ground the hover's, none while it is not).
fn wide_bar_lit(t : @ui.Tester, r : (Double, Double, Double, Double)) -> Bool {
  let (x, y, w, h) = r
  t
  .drawn_rects()
  .iter()
  .any(fn(d) {
    (d.0 - x).abs() < 0.5 && (d.1 - y).abs() < 0.5 && (d.2 - w).abs() < 0.5 && (d.3 - h).abs() < 0.5 && (d.4 & 0xFFL) > 0L
  })
}

///|
/// Whether a hover card stands beside `r` at its start (under `r` in the top bar, or above `r` above the composer).
fn wide_bar_card_under(t : @ui.Tester, r : (Double, Double, Double, Double)) -> Bool {
  t
  .all(Group)
  .iter()
  .any(fn(g) {
    let (gx, gy, gw, gh) = g.rect
    let vertical_ok = (gy >= r.1 + r.3 && gy < r.1 + r.3 + 12.0) || (gy + gh <= r.1 + 1.0 && gy + gh >= r.1 - 12.0)
    (gx - r.0).abs() < 1.0 && vertical_ok && gw >= 200.0
  })
}

///|
test "大屏, 中屏: the agent and station halves of the composer-top capsule light independently on hover, open their own cards, and pressing the agent opens its history" {
  for win in wide_bar_windows {
    let calls : Array[Made] = []
    let t = wide_bar_at(calls, w=win.1)
    let agent = match t.all(Button).filter(fn(b) { b.label.has_suffix("的执行历史") && b.rect.1 > 400.0 }) {
      [b, ..] => b.rect
      _ => fail("\{win.0}: no agent's half")
    }
    let station = match t.all(Group).filter(fn(g) { g.label == "Willow" && g.rect.1 > 400.0 }) {
      [g, ..] => g.rect
      _ => fail("\{win.0}: no station's half")
    }
    let y = agent.1 + agent.3 / 2.0
    assert_true(agent.0 >= station.0 + station.2 - 1.0 && agent.0 <= station.0 + station.2 + 4.0, msg="\{win.0}: \{Repr(station)} \{Repr(agent)}")
    let on_agent = agent.0 + agent.2 / 2.0
    let on_station = station.0 + station.2 / 2.0
    t.move_to(on_agent, y)
    t.run_for(@sf.hover_card_open_ms + @ui.move_most_ms)
    assert_true(wide_bar_lit(t, agent), msg="\{win.0}: on the agent's half, the agent lit")
    assert_false(wide_bar_lit(t, station), msg="\{win.0}: on the agent's half, the station not lit")
    assert_true(wide_bar_card_under(t, agent), msg="\{win.0}: on the agent's half, its card")
    assert_false(wide_bar_card_under(t, station), msg="\{win.0}: on the agent's half, no station's card")
    t.move_to(on_station, y)
    t.run_for(@sf.hover_card_open_ms + @ui.move_most_ms)
    assert_false(wide_bar_lit(t, agent), msg="\{win.0}: on the station's half, the agent not lit")
    assert_true(wide_bar_lit(t, station), msg="\{win.0}: on the station's half, it lit")
    assert_false(wide_bar_card_under(t, agent), msg="\{win.0}: on the station's half, no agent's card")
    assert_true(wide_bar_card_under(t, station), msg="\{win.0}: on the station's half, its card")
    // (pressed on the agent's half: its history's, as ever)
    t.move_to(on_agent, y)
    t.run_for(@ui.move_most_ms)
    let n = calls.filter(fn(c) { c.name == "chat.tabs.open" }).length()
    t.press_at(on_agent, y)
    t.release(on_agent, y)
    t.run_for(@ui.move_most_ms)
    assert_eq(calls.filter(fn(c) { c.name == "chat.tabs.open" }).length(), n + 1, msg="\{win.0}: pressed on the agent's half, its history")
  }
}

///|
test "大屏, 中屏: a click on the station's half holds the card its hover brought, one card and no panel over it, kept as the pointer leaves" {
  for win in wide_bar_windows {
    let calls : Array[Made] = []
    let t = wide_bar_at(calls, w=win.1)
    let station = match t.all(Group).filter(fn(g) { g.label == "Willow" && g.rect.1 > 400.0 }) {
      [g, ..] => g.rect
      _ => fail("\{win.0}: no station's half")
    }
    let (x, y) = (station.0 + station.2 / 2.0, station.1 + station.3 / 2.0)
    t.move_to(x, y)
    t.run_for(@sf.hover_card_open_ms + @ui.move_most_ms)
    let rested = t.words().filter(fn(w) { w.5 > 0.0 }).map(fn(w) { w.0 })
    assert_true(wide_bar_card_under(t, station), msg="\{win.0}: rested on, its card")
    t.press_at(x, y)
    t.release(x, y)
    t.run_for(@ui.move_most_ms)
    // (the same words as the card the hover brought: no panel of its own over it)
    assert_eq(t.words().filter(fn(w) { w.5 > 0.0 }).map(fn(w) { w.0 }), rested, msg="\{win.0}: clicked, the card as it was")
    t.move_to(x, 40.0)
    t.run_for(@sf.hover_card_close_ms + @ui.move_most_ms)
    assert_true(wide_bar_card_under(t, station), msg="\{win.0}: clicked, the card held as the pointer left")
  }
}

///|
test "大屏, 中屏: the window's own buttons in its top row (Windows) pressed from 2 off them as on them, the bar's own part beside them none of theirs" {
  for win in wide_bar_windows {
    let calls : Array[Made] = []
    let t = wide_bar_at(calls, w=win.1, platform=3, inset=true)
    let key = fn(label : String) {
      match t.all(Button).filter(fn(b) { b.label == label && b.rect.1 < 90.0 }) {
        [b, ..] => Some(b.rect)
        _ => None
      }
    }
    guard key(@sf.t("desktop.menu.minimize")) is Some(least) else { fail("\{win.0}: no minimize") }
    guard key(@sf.t("desktop.menu.close")) is Some(close) else { fail("\{win.0}: no close") }
    let y = least.1 + least.3 / 2.0
    // (2 before the first, 2 after the last: within the room a press takes round each, 36 round their 32)
    for p in [(least.0 - 2.0, 1, "minimize"), (close.0 + close.2 + 1.5, 3, "close")] {
      let (x, act, name) = p
      let acts = t.window_acts().length()
      let drags = t.window_drags()
      t.press_at(x, y)
      t.release(x, y)
      t.run_for(@ui.move_most_ms)
      assert_eq(t.window_acts()[acts:].to_owned(), [act], msg="\{win.0}: \{name} pressed at \{x}")
      assert_eq(t.window_drags(), drags, msg="\{win.0}: \{name}: the window not dragged at \{x}")
    }
    // (past their room, the bar's: it drags the window)
    let x = least.0 - 8.0
    let drags = t.window_drags()
    let acts = t.window_acts().length()
    t.press_at(x, y)
    t.release(x, y)
    t.run_for(@ui.move_most_ms)
    assert_eq(t.window_drags(), drags + 1, msg="\{win.0}: 8 before them the bar's")
    assert_eq(t.window_acts().length(), acts, msg="\{win.0}: 8 before them none of theirs")
  }
}

///|
test "大屏, 中屏: 归档 on a chat keeping watch, asked, and 归档 in the question: the cursor in the next chat's composer, in the window, what is typed its; every frame built whole past the moment a composer let go would let go" {
  for win in wide_bar_windows {
    let calls : Array[Made] = []
    let t = wide_bar_at(
      calls,
      w=win.1,
      over=wide_bar_both(
        wide_bar_chat_field("archivable", fn(_) { Json::boolean(true) }),
        wide_bar_chat_field("watch", fn(_) { { "ask": "它还在盯着 CI，归档后就不盯了。" } }),
      ),
    )
    @sf.presenters_reset()
    guard wide_bar_button(t, @sf.t("web-pages.chat.archive")) is Some(a) else { fail("\{win.0}: no 归档") }
    // (pressed by a pointer: the composer keeps the cursor till the question takes it)
    wide_bar_tap(t, a)
    assert_true(@sf.presenting(), msg="\{win.0}: asked")
    guard t.all(Button).filter(fn(b) { b.label == @sf.t("web-pages.chat.archive") && b.rect.1 > 90.0 }) is [yes, ..] else {
      fail("\{win.0}: no 归档 in the question")
    }
    let (x, y, w, h) = yes.rect
    t.tap(x + w / 2.0, y + h / 2.0)
    // (each frame on the way, past the moment the composer of a chat without the cursor lets it go: the one archived,
    // sliding off on 中屏, and the next must not take turns with it; a size that steps there is said by the frame)
    let until = t.time() + @sfpages.let_go_ms + @ui.move_most_ms
    if @ui.test_at_a_rate() {
      t.run_for(until - t.time())
    } else {
      while t.time() < until {
        t.frame()
      }
    }
    assert_eq(named(calls, "chat.archive").length(), 1, msg=win.0)
    assert_true(!@sf.presenting(), msg="\{win.0}: the question gone")
    assert_true(
      match app.nav.top() {
        Chat(r) => r.session == "s-c2"
        _ => false
      },
      msg="\{win.0}: on to the next chat",
    )
    guard t.focused() is Some(f) else { fail("\{win.0}: the cursor nowhere") }
    let (fx, _, fw, _) = f.rect
    assert_true(f.role is TextField && f.label == "发消息" && fx >= 0.0 && fx + fw <= win.1, msg="\{win.0}: \{Repr(f.role)} \{f.label} \{@ui.rect_text(f.rect)}")
    let before = named(calls, "composer.text").length()
    t.type_text("接着写")
    t.run_for(@ui.move_most_ms)
    let typed = named(calls, "composer.text")
    assert_true(typed.length() > before, msg="\{win.0}: typed into none")
    let keys : Array[String] = []
    for i in before..<typed.length() {
      keys.push(text(Some(typed[i].params), "key"))
    }
    assert_true(keys.iter().all(fn(k) { k.contains("s-c2") }), msg="\{win.0}: \{Repr(keys)}")
  }
}

///|
/// Each frame's left of the bar's button `label` (wide_bar_button's) from the one before `change` is made, through
/// `ms` of the frames a host draws after it; and what steps more than 8 in a frame among them.
fn wide_bar_way(t : @ui.Tester, label : String, change : () -> Unit, ms : Double) -> (Array[Double], Array[String]) {
  let at = fn() {
    match wide_bar_button(t, label) {
      Some(r) => r.0
      None => -1000.0
    }
  }
  let xs = [at()]
  t.each_frame(Some(fn() { xs.push(at()) }))
  change()
  t.run_shown(ms)
  t.each_frame(None)
  let steps = []
  for i in 1..<xs.length() {
    let d = xs[i] - xs[i - 1]
    if d > 8.0 || d < -8.0 {
      steps.push("frame \{i}: \{xs[i - 1]} → \{xs[i]}")
    }
  }
  (xs, steps)
}

///|
test "大屏, 中屏: a button of the bar coming or going settles at once outside a transition (and as an answer), and moves those beside it along the row inside a transition" {
  for win in wide_bar_windows {
    let calls : Array[Made] = []
    let screen_on = @signals.signal(false)
    let screen = wide_bar_chat_field("screens", fn(_) {
      Json::array([
        Json::object({
          "id": Json::string("d1"),
          "kind": Json::string("display"),
          "name": Json::string("Display"),
          "live": Json::boolean(true),
          "driven": Json::boolean(false),
        }),
      ])
    })
    let t = wide_bar_at(
      calls,
      w=win.1,
      over=wide_bar_both(wide_bar_chat_field("archivable", fn(_) { Json::boolean(true) }), fn(n, tp) {
        if screen_on.get() {
          screen(n, tp)
        } else {
          tp
        }
      }),
    )
    let archive = @sf.t("web-pages.chat.archive")
    let x0 = match wide_bar_button(t, archive) {
      Some(r) => r.0
      None => fail("\{win.0}: no 归档")
    }
    // background screens change (outside a transition): settles at once, never sliding unprompted
    let (plain_in, _) = wide_bar_way(t, archive, fn() { screen_on.set(true) }, @ui.move_most_ms)
    let x1 = plain_in[plain_in.length() - 1]
    assert_true(x0 - x1 >= 20.0, msg="\{win.0}: 归档 made room for the remote screen button: \{x0} → \{x1}")
    assert_true(plain_in.length() >= 2, msg=win.0)
    assert_eq(plain_in[1], x1, msg="\{win.0}: outside a transition, button settles at once: \{Repr(plain_in)}")
    let (plain_out, _) = wide_bar_way(t, archive, fn() { screen_on.set(false) }, @ui.move_most_ms)
    assert_true(plain_out.length() >= 2, msg=win.0)
    assert_eq(plain_out[1], x0, msg="\{win.0}: outside a transition, leaving button settles at once: \{Repr(plain_out)}")
    // inside an explicit transition: moves those beside it along the row, never 8 in a frame
    let (came, came_steps) = wide_bar_way(t, archive, fn() { @view.transition(fn() { screen_on.set(true) }) }, @ui.move_most_ms)
    assert_eq(came[came.length() - 1], x1, msg=win.0)
    assert_true(came.length() > 3, msg="\{win.0}: drawn on its way: \{Repr(came)}")
    assert_eq(came_steps, [], msg="\{win.0}: its way in: \{Repr(came)}")
    let (went, went_steps) = wide_bar_way(t, archive, fn() { @view.transition(fn() { screen_on.set(false) }) }, @ui.move_most_ms)
    assert_eq(went[went.length() - 1], x0, msg=win.0)
    assert_eq(went_steps, [], msg="\{win.0}: its way out: \{Repr(went)}")
    // told as an answer (the topic's first value): at once, no way
    let (told, _) = wide_bar_way(t, archive, fn() { @view.answering(fn() { screen_on.set(true) }) }, @ui.move_most_ms)
    assert_true(told.length() >= 2, msg=win.0)
    assert_eq(told[1], x1, msg="\{win.0}: an answer's button in its place at once: \{Repr(told)}")
  }
}

///|
test "大屏, the chat's page made as nodes: the side panel's switch pressed, the panel opening beside it, the bar's buttons go its way one way, the switch going along the row with it, none stepping aside first" {
  let calls : Array[(String, Json)] = []
  let (t, src) = chat_nodes_calling(1280.0, 800.0, 0, calls)
  let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
  @sfdesk.tab_place_set("ws1", Some({ station: "ws1/st1", root: Some(fix_docs), path: "" }))
  let archive = @sf.t("web-pages.chat.archive")
  guard wide_bar_button(t, archive) is Some(_) else { fail("no 归档") }
  guard wide_bar_button(t, @sf.t("web-pages.chat.openPanel")) is Some(_) else { fail("no switch of the side panel") }
  let (xs, _) = wide_bar_way(
    t,
    archive,
    fn() { @sfdesk.side_change(src, r, "open", Some("files")) },
    @ui.move_most_ms + 200.0,
  )
  let back = []
  for i in 1..<xs.length() {
    if xs[i] - xs[i - 1] > 0.5 {
      back.push("frame \{i}: \{xs[i - 1]} → \{xs[i]}")
    }
  }
  assert_true(xs.length() > 3 && xs[xs.length() - 1] < xs[0], msg="归档 gone left with the panel: \{Repr(xs)}")
  assert_eq(back, [], msg="归档 stepped right on the way: \{Repr(xs)}")
}

///|
test "大屏: hovering Station half opens its card and 屏幕 submenu, moving into submenu keeps both open, and moving back to Agent half closes Station card + submenu so only Agent card is open" {
  let calls : Array[Made] = []
  let t = wide_bar_at(calls, mode="chat-station-screens")
  let agent = match t.all(Button).filter(fn(b) { b.label.has_suffix("的执行历史") && b.rect.1 > 400.0 }) {
    [b, ..] => b.rect
    _ => fail("no agent's half")
  }
  let station = match t.all(Group).filter(fn(g) { g.label == "Willow" && g.rect.1 > 400.0 }) {
    [g, ..] => g.rect
    _ => fail("no station's half")
  }
  let word_mid = fn(w : String) -> (Double, Double)? {
    match t.words().filter(fn(x) { x.0 == w && x.5 > 0.5 }).last() {
      Some(x) => Some((x.1 + x.3 / 2.0, x.2 + x.4 / 2.0))
      None => None
    }
  }
  let y = station.1 + station.3 / 2.0
  let on_station = station.0 + station.2 / 2.0
  let on_agent = agent.0 + agent.2 / 2.0
  // 1) Hover Station half -> Station card opens
  t.move_to(on_station, y)
  t.run_for(@sf.hover_card_open_ms + @ui.move_most_ms)
  assert_true(wide_bar_card_under(t, station), msg="station card opened")
  // 2) Move onto 屏幕 row -> submenu opens
  guard word_mid("屏幕") is Some((sx, sy)) else { fail("no 屏幕 row in station card") }
  t.move_to(sx, sy)
  t.run_for(@ui.move_most_ms)
  guard word_mid("Willow 的屏幕") is Some((ix, iy)) else { fail("no Willow 的屏幕 submenu item") }
  // 3) Move into 屏幕 submenu -> stays open past close delay
  t.move_to(ix, iy)
  t.run_for(@sf.hover_card_close_ms + @ui.move_most_ms)
  assert_true(wide_bar_card_under(t, station), msg="station card stays open while on submenu")
  assert_true(word_mid("Willow 的屏幕") is Some(_), msg="submenu stays open while pointer on it")
  // 4) Move back to Agent half -> Station card + submenu close, only Agent card opens
  t.move_to(on_agent, y)
  t.run_for(@sf.hover_card_open_ms + @ui.move_most_ms)
  assert_false(wide_bar_card_under(t, station), msg="station card closed when moving to agent")
  assert_true(word_mid("Willow 的屏幕") is None, msg="screen submenu closed when moving to agent")
  assert_true(wide_bar_card_under(t, agent), msg="agent card opened")
  let agent_card_above = t
    .all(Group)
    .iter()
    .any(fn(g) {
      let (gx, gy, gw, gh) = g.rect
      (gx - agent.0).abs() < 1.0 && gw >= 200.0 && gy + gh <= agent.1 + 1.0 && gy + gh >= agent.1 - 12.0
    })
  assert_true(agent_card_above, msg="agent card opens above the composer-top capsule, not covering the composer")
  assert_eq(
    t.audit().filter(fn(f) { f.contains("hover_card_node") || f.contains("submenu_row_node") }),
    [],
    msg="no hover_card_node or submenu_row_node audit faults",
  )
}

///|
/// The chat's station (ws1/st1) marked `icon` and `emoji`, reached as `via` says now (direct, relay, offline; "": not
/// said how), the rest as the fixture's.
fn bar_station_as(icon : String, emoji : String, via : @signals.Signal[String]) -> (String, Topic) -> Topic {
  fn(n, tp) {
    guard n == "stations" && tp.value is Some(Array(rows)) else { return tp }
    let v = via.get()
    let made = rows.map(fn(row) {
      guard row is Object(m) && m.get("station") is Some(String("ws1/st1")) else { return row }
      let o = m.copy()
      o["icon"] = Json::string(icon)
      o["emoji"] = Json::string(emoji)
      o["online"] = Json::boolean(v != "offline")
      o["reconnecting"] = Json::boolean(false)
      o["way"] = Json::object({ "via": Json::string(if v == "" || v == "offline" { "none" } else { v }) })
      Json::object(o)
    })
    { ..tp, value: Some(Json::array(made)) }
  }
}

///|
/// The station's dots drawn in `cap` (a station's half or tag above the composer): `side` across (6.4 on its mark's
/// corner, 6 before its name), each with its ink.
fn bar_via_dots(t : @ui.Tester, cap : (Double, Double, Double, Double), side : Double) -> Array[(Double, Double, Double, Double, Int64)] {
  let (x, y, w, h) = cap
  t
  .drawn_rects()
  .filter(fn(d) {
    (d.2 - side).abs() < 0.05 &&
    (d.3 - side).abs() < 0.05 &&
    d.0 >= x - 0.5 &&
    d.0 + d.2 <= x + w + 0.5 &&
    d.1 >= y - 0.5 &&
    d.1 + d.3 <= y + h + 0.5
  })
}

///|
/// What a station's dot says `via` in, as the bar inks it.
fn bar_via_ink(via : String) -> Int64 {
  let p = @sf.theme().p
  match via {
    "direct" => p.online
    "relay" => @ui.tree_theme().color(Warn)
    "offline" => p.red
    _ => p.muted
  }
}

///|
/// Checks of a station's capsule half `cap` (`name` its words' place): with a mark, one dot on the mark's bottom
/// right (after where the mark starts, under its middle, before the name) and none before it; with none, one before
/// the name on its middle.
fn bar_via_placed(t : @ui.Tester, cap : (Double, Double, Double, Double), name : (Double, Double), marked : Bool, via : String, msg : String) -> Unit raise {
  let corner = bar_via_dots(t, cap, 6.4)
  let inline = bar_via_dots(t, cap, 6.0)
  let mid = cap.1 + cap.3 / 2.0
  if via == "" {
    assert_eq((corner.length(), inline.length()), (0, 0), msg="\{msg}: no dot while not said how")
    return
  }
  if marked {
    assert_eq((corner.length(), inline.length()), (1, 0), msg="\{msg}: \{Repr(t.drawn_rects().filter(fn(d) { d.2 < 10.0 && d.1 > cap.1 && d.1 < cap.1 + cap.3 }))}")
    let d = corner[0]
    // (its mark starts where the half's padding ends: 8 in a tile's half, 10 in a tag; the dot past most of it)
    assert_true(d.0 >= cap.0 + 8.0 + 9.0, msg="\{msg}: on the mark's right, not before it: \{Repr(d)} \{Repr(cap)}")
    assert_true(d.1 + d.3 / 2.0 > mid + 3.0, msg="\{msg}: on the mark's bottom: \{Repr(d)} \{Repr(cap)}")
    assert_true(d.0 + d.2 < name.0, msg="\{msg}: before the name: \{Repr(d)} \{Repr(name)}")
    assert_eq(d.4, bar_via_ink(via), msg="\{msg}: its ink")
  } else {
    assert_eq((corner.length(), inline.length()), (0, 1), msg="\{msg}: \{Repr(t.drawn_rects().filter(fn(d) { d.2 < 10.0 && d.1 > cap.1 && d.1 < cap.1 + cap.3 }))}")
    let d = inline[0]
    assert_true((d.1 + d.3 / 2.0 - mid).abs() < 1.0, msg="\{msg}: on the half's middle: \{Repr(d)} \{Repr(cap)}")
    assert_true(d.0 + d.2 < name.0, msg="\{msg}: before the name: \{Repr(d)} \{Repr(name)}")
    assert_eq(d.4, bar_via_ink(via), msg="\{msg}: its ink")
  }
}

///|
/// Where `words` are drawn inside `cap` (their middle), if they are.
fn bar_words_in(t : @ui.Tester, words : String, cap : (Double, Double, Double, Double)) -> (Double, Double)? {
  t.locate(words).iter().find_first(fn(p) { p.0 >= cap.0 && p.0 <= cap.0 + cap.2 && p.1 >= cap.1 && p.1 <= cap.1 + cap.3 })
}

///|
test "大屏, 中屏: the station's name above the composer inked as the agent's (Fg, p.text) while not pointed at, in its half of the agent's capsule and in its own tag, light and dark" {
  for win in wide_bar_windows {
    for dark in [false, true] {
      for alone in [false, true] {
        let calls : Array[Made] = []
        let over = if alone { wide_bar_chat_field("agents", fn(_) { Json::array([]) }) } else { fn(_, tp) { tp } }
        let t = wide_bar_at(calls, w=win.1, over~)
        t.set_dark(dark)
        t.run_for(@ui.move_most_ms)
        let msg = "\{win.0} \{if dark { "dark" } else { "light" }}\{if alone { " alone" } else { "" }}"
        let cap = match t.all(Group).filter(fn(g) { g.label == "Willow" && g.rect.1 > 400.0 }) {
          [g, ..] => g.rect
          _ => fail("\{msg}: no station's half")
        }
        let text = @sf.theme().p.text
        assert_false(wide_bar_lit(t, cap), msg="\{msg}: not lit")
        assert_eq(bar_words_inks(t, "Willow", cap), [text], msg="\{msg}: the station's name")
        if !alone {
          let agent = match t.all(Button).filter(fn(b) { b.label.has_suffix("的执行历史") && b.rect.1 > 400.0 }) {
            [b, ..] => b.rect
            _ => fail("\{msg}: no agent's half")
          }
          assert_eq(bar_words_inks(t, "Claude", agent), [text], msg="\{msg}: the agent's name")
        }
      }
    }
  }
}

///|
test "大屏, 中屏: the station's dot above the composer on its mark's corner as the agent's badge (a glyph, an emoji, words 1.3 as large), before its name where it has no mark, with or without an agent; inked as it is reached, gone while not said" {
  let cases : Array[(String, String, Bool)] = [("glyph:desktop", "", true), ("", "🍁", true), ("", "", false)]
  for win in wide_bar_windows {
    for c in cases {
      for scale in [1.0, 1.3] {
        for alone in [false, true] {
          let (icon, emoji, marked) = c
          let via = @signals.signal("direct")
          let calls : Array[Made] = []
          let over = if alone {
            wide_bar_both(bar_station_as(icon, emoji, via), wide_bar_chat_field("agents", fn(_) { Json::array([]) }))
          } else {
            bar_station_as(icon, emoji, via)
          }
          let t = wide_bar_at(calls, w=win.1, over~)
          if scale != 1.0 {
            t.set_font_scale(scale)
            t.run_for(@ui.move_most_ms)
          }
          let msg = "\{win.0} \{icon}\{emoji} \{scale}x\{if alone { " alone" } else { "" }}"
          let cap = match t.all(Group).filter(fn(g) { g.label == "Willow" && g.rect.1 > 400.0 }) {
            [g, ..] => g.rect
            _ => fail("\{msg}: no station's half")
          }
          guard bar_words_in(t, "Willow", cap) is Some(name) else { fail("\{msg}: no name in \{Repr(cap)}") }
          for v in ["direct", "relay", "offline", "", "direct"] {
            via.set(v)
            t.run_for(@ui.move_most_ms)
            bar_via_placed(t, cap, name, marked, v, "\{msg} \{v}")
          }
          let audit = t.audit().filter(fn(f) { f.contains("chat_bar_wide_node") || f.contains("agent_badge_node") || f.contains("mark_node") })
          assert_eq(audit, [], msg~)
        }
      }
    }
  }
}

///|
/// The chat's station (ws1/st1) named `name`, the rest as the fixture's.
fn bar_station_named(name : String) -> (String, Topic) -> Topic {
  fn(n, tp) {
    guard n == "stations" && tp.value is Some(Array(rows)) else { return tp }
    let made = rows.map(fn(row) {
      guard row is Object(m) && m.get("station") is Some(String("ws1/st1")) else { return row }
      let o = m.copy()
      o["name"] = Json::string(name)
      Json::object(o)
    })
    { ..tp, value: Some(Json::array(made)) }
  }
}

///|
/// The chat's first agent named `name` (its session's agentText), the rest as the fixture's.
fn bar_agent_named(name : String) -> (String, Topic) -> Topic {
  wide_bar_chat_field("agents", fn(was) {
    match was {
      Some(Array(a)) =>
        Json::array(
          a.mapi(fn(i, j) {
            guard i == 0 && j is Object(m) && m.get("session") is Some(Object(s)) else { return j }
            let o = m.copy()
            let ss = s.copy()
            ss["agentText"] = Json::string(name)
            o["session"] = Json::object(ss)
            Json::object(o)
          }),
        )
      Some(other) => other
      None => Json::array([])
    }
  })
}

///|
/// The chat leading one sub-chat (its `opened`, led).
fn bar_leads_one() -> (String, Topic) -> Topic {
  wide_bar_chat_field("opened", fn(_) {
    Json::array([{ "station": "ws1/st1", "session": "s-sub1", "title": "子对话", "stateText": "运行中", "led": true }])
  })
}

///|
test "大屏, 中屏: the station's and the agent's names above the composer shown whole where the row has room for them, with or without an agent" {
  let station = "tokyo-mac-studio-0"
  let agent = "Opus 5.5 · medium"
  for win in wide_bar_windows {
    for alone in [false, true] {
      let calls : Array[Made] = []
      let over = if alone {
        wide_bar_both(bar_station_named(station), wide_bar_chat_field("agents", fn(_) { Json::array([]) }))
      } else {
        wide_bar_both(bar_station_named(station), bar_agent_named(agent))
      }
      let t = wide_bar_at(calls, w=win.1, over~)
      let msg = "\{win.0}\{if alone { " alone" } else { "" }}"
      guard t.all(Group).filter(fn(g) { g.label == station && g.rect.1 > 400.0 }) is [_, ..] else {
        fail("\{msg}: no station's capsule")
      }
      assert_eq(t.lines_of(station), [station], msg="\{msg}: the station's name whole")
      if !alone {
        assert_eq(t.lines_of(agent), [agent], msg="\{msg}: the agent's name whole")
      }
      let audit = t.audit().filter(fn(f) { f.contains("chat_bar_wide_node") || f.contains("agent_badge_node") || f.contains("mark_node") })
      assert_eq(audit, [], msg~)
    }
  }
}

///|
fn wide_bar_neon_over(extra_agents? : Int = 0, with_subchats? : Bool = false, with_jobs? : Bool = false) -> (String, Topic) -> Topic {
  let edit_chat = wide_bar_edit("chat", fn(v) {
    match v {
      Some(Object(m)) => {
        let o = m.copy()
        let first = match m.get("agents") {
          Some(Array(a)) if a.length() > 0 => a[0]
          _ => Json::object({})
        }
        let all : Array[Json] = []
        match first {
          Object(am) => {
            let ao = am.copy()
            match am.get("session") {
              Some(Object(s)) => {
                let ss = s.copy()
                ss["runtime"] = Json::string("agy")
                ss["maker"] = { "id": "gemini", "name": "Google" }
                ss["model"] = Json::string("gemini-4-neon")
                ss["modelName"] = Json::string("Gemini 4 Neon")
                ss["modelShort"] = Json::string("Neon")
                ss["effort"] = Json::string("high")
                ss["agentText"] = Json::string("Gemini 4 Neon · high")
                ao["session"] = Json::object(ss)
              }
              _ => ()
            }
            all.push(Json::object(ao))
          }
          other => all.push(other)
        }
        for i in 0..<extra_agents {
          all.push({
            "session": {
              "key": "s-extra-\{i}",
              "runtime": "agy",
              "maker": { "id": "gemini", "name": "Google" },
              "model": "gemini-4-neon",
              "modelName": "Gemini 4 Neon",
              "modelShort": "Neon",
              "effort": "high",
              "agentText": "Gemini 4 Neon · high",
              "statusText": "未开始",
              "tone": "neutral",
            },
            "status": "idle",
          })
        }
        o["agents"] = Json::array(all)
        if with_subchats {
          o["opened"] = Json::array([
            {
              "station": "ws1/st1",
              "session": "s-sub-1",
              "title": "子会话一",
              "led": true,
              "state": "run",
            },
            {
              "station": "ws1/st1",
              "session": "s-sub-2",
              "title": "子会话二",
              "led": true,
              "state": "done",
            },
          ])
        }
        Some(Json::object(o))
      }
      other => other
    }
  })
  if with_jobs {
    wide_bar_both(edit_chat, wide_bar_jobs("fail"))
  } else {
    edit_chat
  }
}

///|
test "大屏, 中屏: a station's name too long for the row above the composer (with its services and a led sub-chat) cut in its capsule, none of it past the services' button or the window" {
  let station = "这是一台名字非常非常长的机器用来检验输入框上方的胶囊在放不下时会不会把右边的按钮挤出去或者画到窗口外面去了"
  for win in [("大屏", 860.0), ("中屏", 720.0)] {
    for alone in [false, true] {
      let calls : Array[Made] = []
      let named = wide_bar_both(wide_bar_both(bar_station_named(station), wide_bar_jobs("")), bar_leads_one())
      let over = if alone { wide_bar_both(named, wide_bar_chat_field("agents", fn(_) { Json::array([]) })) } else { named }
      let t = wide_bar_at(calls, w=win.1, over~)
      let msg = "\{win.0}\{if alone { " alone" } else { "" }}"
      let cap = match t.all(Group).filter(fn(g) { g.label == station && g.rect.1 > 400.0 }) {
        [g, ..] => g.rect
        _ => fail("\{msg}: no station's capsule")
      }
      let services = t.all(Button).filter(fn(b) { b.label == @sf.t("web-main.jobs.services") && b.rect.1 > 400.0 })
      guard services is [s, ..] else { fail("\{msg}: no services' button above the composer") }
      assert_true(cap.0 + cap.2 <= s.rect.0, msg="\{msg}: the station's capsule before the services' button: \{Repr(cap)} \{Repr(s.rect)}")
      assert_true(s.rect.0 + s.rect.2 <= win.1, msg="\{msg}: the services' button in the window: \{Repr(s.rect)}")
      assert_true(t.lines_of(station).iter().any(fn(l) { l.has_suffix("…") }), msg="\{msg}: its name cut: \{Repr(t.lines_of(station))}")
      let audit = t.audit().filter(fn(f) { f.contains("chat_bar_wide_node") || f.contains("agent_badge_node") || f.contains("mark_node") })
      assert_eq(audit, [], msg~)
    }
  }
}

///|
test "大屏: the agent's card over the capsule, its context's menu open: a press on the card closes the menu alone, the card staying (twice); 清空上下文 asked in the middle, the card closed" {
  let calls : Array[Made] = []
  let clearable = wide_bar_chat_field("agents", fn(was) {
    match was {
      Some(Array(a)) =>
        Json::array(
          a.map(fn(x) {
            match x {
              Object(m) => {
                let o = m.copy()
                let s = match m.get("session") {
                  Some(Object(sm)) => sm.copy()
                  _ => Map([])
                }
                s["canCompact"] = Json::boolean(true)
                s["canClear"] = Json::boolean(true)
                o["session"] = Json::object(s)
                Json::object(o)
              }
              other => other
            }
          }),
        )
      _ => Json::array([])
    }
  })
  let card_said = wide_bar_edit("agentCard", fn(_) {
    Some({
      "work": "共工作 1 小时 12 分",
      "cost": "$4.20",
      "cache": { "percent": 91, "text": "91%", "level": "ok" },
      "context": { "percent": 31, "text": "62K / 200K", "level": "ok" },
      "latest": [{ "key": "k1", "text": "读了 src/ui/list.mbt" }],
      "attention": [],
    })
  })
  let t = wide_bar_at(calls, over=wide_bar_both(clearable, card_said))
  let before = t.audit()
  let agent = match t.all(Button).filter(fn(b) { b.label.has_suffix("的执行历史") && b.rect.1 > 400.0 }) {
    [b, ..] => b.rect
    _ => fail("no agent's half")
  }
  // (words seen above the capsule: the card's, not the page's)
  let in_card = fn(w : String) -> (Double, Double)? {
    match t.words().filter(fn(x) { x.0 == w && x.5 > 0.5 && x.2 < agent.1 && x.2 > agent.1 - 400.0 }).last() {
      Some(x) => Some((x.1 + x.3 / 2.0, x.2 + x.4 / 2.0))
      None => None
    }
  }
  let clear = @sf.t("web-pages.chat.clear")
  let menu_open = fn() { t.words().iter().any(fn(x) { x.0 == clear && x.5 > 0.5 }) }
  // (the card drawn and seen: its words, read out or not (under a modal layer what it holds is not read out))
  let card_open = fn() { in_card("$4.20") is Some(_) }
  t.move_to(agent.0 + agent.2 / 2.0, agent.1 + agent.3 / 2.0)
  t.run_for(@sf.hover_card_open_ms + @ui.move_most_ms)
  assert_true(wide_bar_card_under(t, agent), msg="the agent's card open")
  let context = @sf.t("web-main.chat.agentCard.context")
  let open_menu = fn(round : String) raise {
    guard in_card(context) is Some((cx, cy)) else { fail("\{round}: no \{context} in the card") }
    t.move_to(cx, cy)
    t.run_for(@ui.move_most_ms)
    t.press_at(cx, cy)
    t.release(cx, cy)
    t.run_for(@ui.move_most_ms)
    assert_true(menu_open(), msg="\{round}: its context's menu open")
    assert_true(card_open(), msg="\{round}: the card open with it")
  }
  for round in ["first", "second"] {
    open_menu(round)
    guard in_card("$4.20") is Some((px, py)) else { fail("\{round}: no cost in the card") }
    t.move_to(px, py)
    t.press_at(px, py)
    t.release(px, py)
    t.run_for(@sf.hover_card_close_ms + @ui.move_most_ms)
    assert_false(menu_open(), msg="\{round}: a press on the card: the menu closed")
    assert_true(card_open(), msg="\{round}: a press on the card: the card stays")
  }
  // (清空上下文: asked in the middle of the window, the card closed under it)
  open_menu("clear")
  guard t.words().filter(fn(x) { x.0 == clear && x.5 > 0.5 }).last() is Some(row) else { fail("no \{clear}") }
  let (rx, ry) = (row.1 + row.3 / 2.0, row.2 + row.4 / 2.0)
  t.move_to(rx, ry)
  t.press_at(rx, ry)
  t.release(rx, ry)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find(@sf.t("web-pages.chat.clearConfirm")) is Some(_), msg="asked whether to clear")
  assert_false(card_open(), msg="the ask over it: the card closed")
  // (the ask let go of: the window as it was, what the audit says of it the same)
  t.key(@ui.key_escape)
  t.run_for(@ui.move_most_ms)
  assert_false(@sf.presenting(), msg="the ask closed")
  assert_eq(t.audit(), before)
  @sf.presenters_reset()
}

///|
test "大屏, 中屏: 多模型按 station 分组合并成一颗胶囊，Station 在最左侧，悬停各自独立、点击切换对应模型且仅选中段高亮、无外框蓝边" {
  for win in wide_bar_windows {
    // 1) Single agent: Station strictly left of Agent0
    let calls1 : Array[Made] = []
    let t1 = wide_bar_at(calls1, w=win.1)
    let st1 = match t1.all(Group).filter(fn(g) { g.label == "Willow" && g.rect.1 > 400.0 }) {
      [g, ..] => g.rect
      _ => fail("\{win.0} single: no station")
    }
    let ag1 = match t1.all(Button).filter(fn(b) { b.label.has_suffix("的执行历史") && b.rect.1 > 400.0 }) {
      [b, ..] => b.rect
      _ => fail("\{win.0} single: no agent")
    }
    assert_true(st1.0 + st1.2 <= ag1.0 + 2.0, msg="\{win.0} single: station left of agent: \{Repr(st1)} \{Repr(ag1)}")

    // 2) Multi-agent (2 agents): single merged capsule, Station < Agent0 < Agent1, independent hover & click
    let calls2 : Array[Made] = []
    let t2 = wide_bar_at(calls2, w=win.1, over=wide_bar_agents(2))
    let sts = t2.all(Group).filter(fn(g) { g.label == "Willow" && g.rect.1 > 400.0 })
    assert_eq(sts.length(), 1, msg="\{win.0} 2-agents: one station group")
    let st = sts[0].rect
    let ags = t2.all(Button).filter(fn(b) { b.label.has_suffix("的执行历史") && b.rect.1 > 400.0 })
    assert_eq(ags.length(), 2, msg="\{win.0} 2-agents: two agent segments")
    let a0 = ags[0].rect
    let a1 = ags[1].rect
    assert_true(st.0 + st.2 <= a0.0 + 2.0 && a0.0 - (st.0 + st.2) <= 3.0, msg="\{win.0}: station joined left of a0: \{Repr(st)} \{Repr(a0)}")
    assert_true(a0.0 + a0.2 <= a1.0 + 2.0 && a1.0 - (a0.0 + a0.2) <= 3.0, msg="\{win.0}: a0 joined left of a1 in one capsule: \{Repr(a0)} \{Repr(a1)}")
    let y = st.1 + st.3 / 2.0
    // Hover Station -> only Station lit + Station card
    t2.move_to(st.0 + st.2 / 2.0, y)
    t2.run_for(@sf.hover_card_open_ms + @ui.move_most_ms)
    assert_true(wide_bar_lit(t2, st), msg="\{win.0}: station lit")
    assert_false(wide_bar_lit(t2, a0), msg="\{win.0}: a0 not lit when hovering station")
    assert_false(wide_bar_lit(t2, a1), msg="\{win.0}: a1 not lit when hovering station")
    assert_true(wide_bar_card_under(t2, st), msg="\{win.0}: station card")
    // Hover Agent0 -> only Agent0 lit + Agent0 card
    t2.move_to(a0.0 + a0.2 / 2.0, y)
    t2.run_for(@sf.hover_card_open_ms + @ui.move_most_ms)
    assert_false(wide_bar_lit(t2, st), msg="\{win.0}: station not lit when hovering a0")
    assert_true(wide_bar_lit(t2, a0), msg="\{win.0}: a0 lit")
    assert_false(wide_bar_lit(t2, a1), msg="\{win.0}: a1 not lit when hovering a0")
    assert_true(wide_bar_card_under(t2, a0), msg="\{win.0}: a0 card")
    // Hover Agent1 -> only Agent1 lit + Agent1 card
    t2.move_to(a1.0 + a1.2 / 2.0, y)
    t2.run_for(@sf.hover_card_open_ms + @ui.move_most_ms)
    assert_false(wide_bar_lit(t2, st), msg="\{win.0}: station not lit when hovering a1")
    assert_false(wide_bar_lit(t2, a0), msg="\{win.0}: a0 not lit when hovering a1")
    assert_true(wide_bar_lit(t2, a1), msg="\{win.0}: a1 lit")
    assert_true(wide_bar_card_under(t2, a1), msg="\{win.0}: a1 card")
    // Click Agent0 and Agent1 -> chat.tabs.open with respective keys
    wide_bar_tap(t2, a0)
    wide_bar_tap(t2, a1)
    let opened_tabs = calls2.filter(fn(c) { c.name == "chat.tabs.open" }).map(fn(c) { text(Some(c.params), "tab") })
    assert_true(opened_tabs.contains("s-c1") && opened_tabs.contains("s-x1"), msg="\{win.0}: opened both agents: \{Repr(opened_tabs)}")
    // Click Station -> holds its card, no panel of its own over it
    @sf.presenters_reset()
    wide_bar_tap(t2, st)
    assert_false(@sf.presenting(), msg="\{win.0}: station click opens no panel")
    assert_true(wide_bar_card_under(t2, st), msg="\{win.0}: station click holds its card")
    t2.key(@ui.key_escape)
    t2.run_for(@ui.move_most_ms)

    // 3) Side panel active on Agent1: only Agent1 segment is marked/lit
    let calls3 : Array[Made] = []
    let side_a1 = wide_bar_both(
      wide_bar_agents(2),
      wide_bar_chat_field("tabs", fn(_) { { "open": ["s-x1"], "shown": "s-x1" } }),
    )
    let t3 = wide_bar_at(calls3, w=win.1, over=side_a1)
    let st3 = t3.all(Group).filter(fn(g) { g.label == "Willow" && g.rect.1 > 400.0 })[0].rect
    let ags3 = t3.all(Button).filter(fn(b) { b.label.has_suffix("的执行历史") && b.rect.1 > 400.0 })
    assert_eq(ags3.length(), 2, msg="\{win.0} marked: two agents")
    assert_false(wide_bar_lit(t3, st3), msg="\{win.0} marked: station not lit")
    assert_false(wide_bar_lit(t3, ags3[0].rect), msg="\{win.0} marked: a0 not lit")
    assert_true(wide_bar_lit(t3, ags3[1].rect), msg="\{win.0} marked: a1 lit")
    assert_eq(t3.audit().filter(fn(f) { f.contains("chat_bar_wide_node") }), [], msg=win.0)
  }
}

///|
test "大屏窄窗(860)与中屏窄窗(600): 3 模型 + 服务按钮 + 子会话下，合并胶囊不越过右侧按钮与窗口边界，零 audit 告警" {
  for win in [("大屏", 860.0), ("中屏", 600.0)] {
    let calls : Array[Made] = []
    let over = wide_bar_both(wide_bar_both(wide_bar_agents(3), wide_bar_jobs("")), bar_leads_one())
    let t = wide_bar_at(calls, w=win.1, over~)
    let sts = t.all(Group).filter(fn(g) { g.label == "Willow" && g.rect.1 > 400.0 })
    let ags = t.all(Button).filter(fn(b) { b.label.has_suffix("的执行历史") && b.rect.1 > 400.0 })
    let services = t.all(Button).filter(fn(b) { b.label == @sf.t("web-main.jobs.services") && b.rect.1 > 400.0 })
    assert_eq(sts.length(), 1, msg=win.0)
    assert_eq(ags.length(), 3, msg=win.0)
    guard services is [s, ..] else { fail("\{win.0}: no services button") }
    assert_true(sts[0].rect.0 < ags[0].rect.0 && ags[0].rect.0 < ags[1].rect.0 && ags[1].rect.0 < ags[2].rect.0, msg=win.0)
    let right_most = ags[2].rect.0 + ags[2].rect.2
    assert_true(right_most <= s.rect.0, msg="\{win.0}: merged capsule before services: \{right_most} vs \{s.rect.0}")
    assert_true(s.rect.0 + s.rect.2 <= win.1, msg="\{win.0}: services in window: \{Repr(s.rect)}")
    assert_eq(t.audit().filter(fn(f) { f.contains("chat_bar_wide_node") || f.contains("agent_badge_node") }), [], msg=win.0)
  }
}

///|
test "大屏/中屏输入框上方胶囊：Gemini 4 Neon · 高 宽屏完整展示，挤窄时逐级降级为 Neon · 高 与 Neon（始终保底短名不藏掉），无省略号无死留白，拉宽恢复" {
  let calls : Array[Made] = []
  let bar_texts = fn(t : @ui.Tester) -> Array[String] {
    t.text_runs().filter(fn(r) { r.top > 400.0 && r.bottom < 740.0 }).map(fn(r) { r.text })
  }
  // 1) Roomy Large screen (1280): full "Gemini 4 Neon" + "高" shown without ellipsis
  let t = wide_bar_at(calls, w=1280.0, over=wide_bar_neon_over(with_subchats=true, with_jobs=true))
  let wide_words = bar_texts(t)
  assert_true(wide_words.contains("Gemini 4 Neon"), msg="1280: full model name: \{Repr(wide_words)}")
  assert_true(wide_words.contains("· 高"), msg="1280: effort shown: \{Repr(wide_words)}")
  assert_true(wide_words.iter().all(fn(s) { !s.contains("…") }), msg="1280: zero ellipsis: \{Repr(wide_words)}")
  assert_eq(t.audit().filter(fn(f) { f.contains("chat_bar_wide_node") || f.contains("model_segments_node") }), [], msg="1280 audit")
  // 2) Crowded Medium screen (600) with 3 agents + subchats + jobs: all agents step down to "Neon" without ellipsis
  let t2 = wide_bar_at(calls, w=600.0, over=wide_bar_neon_over(extra_agents=2, with_subchats=true, with_jobs=true))
  let mid_words = bar_texts(t2)
  assert_true(mid_words.contains("Neon"), msg="600 crowded: short model name Neon: \{Repr(mid_words)}")
  assert_true(!mid_words.contains("Gemini 4 Neon"), msg="600 crowded: full name stepped down: \{Repr(mid_words)}")
  assert_true(mid_words.iter().all(fn(s) { !s.contains("…") }), msg="600 crowded: zero ellipsis: \{Repr(mid_words)}")
  assert_eq(t2.audit().filter(fn(f) { f.contains("chat_bar_wide_node") || f.contains("model_segments_node") }), [], msg="600 audit")
  // 3) Widen back to 1280: full "Gemini 4 Neon" + "高" recovers immediately
  t2.resize(1280.0, 800.0)
  t2.run_for(@ui.move_most_ms)
  let back_words = bar_texts(t2)
  assert_true(back_words.contains("Gemini 4 Neon"), msg="widened back: full restored: \{Repr(back_words)}")
  assert_true(back_words.contains("· 高"), msg="widened back: effort restored: \{Repr(back_words)}")
}

///|
/// The bar's soft scroll edge as drawn (chat_bar_wide_node's wide_bar_scrim_node: frosted glass from the bar's top, as
/// wide as the bar, as tall as it and 16 more; the rightmost such, the page's over the sidebar's), (x, y, w, h).
fn wide_bar_edge(t : @ui.Tester) -> (Double, Double, Double, Double)? {
  let mut found : (Double, Double, Double, Double)? = None
  for g in t.drawn_glass() {
    let (x, y, w, h, kind, _) = g
    if kind == 5 &&
      y < 40.0 &&
      w >= 300.0 &&
      h >= @sf.wide_bar_h + 16.0 - 0.01 &&
      h < 140.0 &&
      (found is None || x > found.unwrap().0) {
      found = Some((x, y, w, h))
    }
  }
  found
}

///|
/// Where the bar has the chat's title `title` (its words' box, read out as them, within the bar's edge), (x, y, w, h).
fn wide_bar_title_at(t : @ui.Tester, title : String) -> (Double, Double, Double, Double)? {
  guard wide_bar_edge(t) is Some((ex, ey, ew, eh)) else { return None }
  match
    t
    .semantics()
    .filter(fn(b) {
      b.role == @ui.Role::Text &&
      b.label == title &&
      b.rect.0 >= ex - 0.5 &&
      b.rect.0 + b.rect.2 <= ex + ew + 0.5 &&
      b.rect.1 >= ey &&
      b.rect.1 + b.rect.3 <= ey + eh
    }) {
    [b, ..] => Some(b.rect)
    _ => None
  }
}

///|
/// Where the bar's buttons at its end start (the leftmost of them), the window's width where it has none.
fn wide_bar_keys_x(t : @ui.Tester) -> Double {
  let own = [
    @sf.t("web-pages.chat.archive"),
    @sf.t("web-pages.chat.screen"),
    @sf.t("web-pages.chat.info"),
    @sf.t("common.more"),
    @sf.t("web-pages.chat.openPanel"),
  ]
  // (the bar's end, past the window's on the tape where its page's panel is partly out of it)
  let mut least = match wide_bar_edge(t) {
    Some((ex, _, ew, _)) => ex + ew
    None => t.ctx().window_size().0
  }
  // (as read out: on the tape past the window's edge too)
  for b in t.semantics() {
    if b.role == @ui.Role::Button && b.rect.1 < 90.0 && b.rect.3 < 90.0 && own.contains(b.label) {
      least = dmin(least, b.rect.0)
    }
  }
  least
}

///|
/// The fixture's chat's title.
// kept across runs: a value
let wide_bar_title_words : String = "整理发布清单"

///|
/// Where the chat's words start across (the first line of one of its answers, laid out in its column).
// kept across runs: a value
let wide_bar_words_words : String = "高度先按 90 估"

///|
/// What is wrong with the title in each state of `states` (by its name, its title's words, whether the chat's column
/// stands clear of the bar's start room): its start where the chat's words start in its column (`wide_bar_words_words`)
/// or, where those start nearer the bar's start than its start room (the panel's words' line on the tape, the bar's 12
/// in off it with the sidebar open) and its words' 8 in, there (`clear` false: never there where it is true), none
/// of it past the bar's start or onto its buttons, and (`steady`) its start where the first state's is.
fn wide_bar_aligned(
  states : Array[(String, String, Bool, () -> @ui.Tester)],
  steady? : Bool = false,
) -> Array[String] {
  let faults : Array[String] = []
  let mut first : Double? = None
  for s in states {
    let (name, title, clear, make) = s
    let t = make()
    guard wide_bar_edge(t) is Some((ex, _, _, _)) else {
      faults.push("\{name}: no edge under the bar")
      continue
    }
    guard wide_bar_title_at(t, title) is Some((x, _, w, _)) else {
      faults.push("\{name}: no title")
      continue
    }
    guard t.rect_of(wide_bar_words_words) is Some((wx, _, _, _)) else {
      faults.push("\{name}: no words of the chat's")
      continue
    }
    let keys = wide_bar_keys_x(t)
    if x < ex || x + w > keys {
      faults.push("\{name}: the title \{x}..\{x + w}, the bar from \{ex}, the buttons from \{keys}")
    }
    // (the bar's start room: on the tape the panel's words' line, off it, the sidebar open, the bar's 12 in)
    let room = if @sfdesk.wide.tape.get() { @sfdesk.wide.bar_pl } else { @sfdesk.bar_in }
    let least = ex + room + 8.0
    if (x - dmax(wx, least)).abs() > 1.0 {
      faults.push("\{name}: the title from \{x}, the chat's words from \{wx}, its least start \{least}")
    }
    if clear && (x - wx).abs() > 1.0 {
      faults.push("\{name}: the title from \{x}, the chat's words from \{wx} (its start room \{least})")
    }
    match first {
      Some(f) if steady && (x - f).abs() > 0.5 => faults.push("\{name}: the title from \{x}, the first's from \{f}")
      None => first = Some(x)
      _ => ()
    }
    let audit = t.audit().filter(fn(f) { f.contains("chat_bar_wide_node") })
    if audit.length() > 0 {
      faults.push("\{name}: audit \{Repr(audit)}")
    }
  }
  faults
}

///|
test "大屏, 中屏: the chat's title starts where its words do (中屏: at the panel's words' line), not moved as 归档, the screens or the side panel's switch come and go" {
  // (its own run first: each state's maker starts another before it reads a word)
  new_run()
  for win in wide_bar_windows {
    let calls : Array[Made] = []
    let title = wide_bar_title_words
    // (大屏's column stands clear of the bar's start; 中屏's, on the tape, starts nearer its edge than the panel's
    // words' line)
    let clear = win.1 > 1000.0
    let faults = wide_bar_aligned(steady=true, [
      ("\{win.0} plain", title, clear, fn() { wide_bar_at(calls, w=win.1) }),
      (
        "\{win.0} archivable",
        title,
        clear,
        fn() { wide_bar_at(calls, w=win.1, over=wide_bar_chat_field("archivable", fn(_) { Json::boolean(true) })) },
      ),
      ("\{win.0} screens", title, clear, fn() { wide_bar_at(calls, w=win.1, mode="chat-station-screens") }),
      ("\{win.0} no agent", title, clear, fn() { wide_bar_at(calls, w=win.1, over=wide_bar_agents(0)) }),
      ("\{win.0} people", title, clear, fn() { wide_bar_at(calls, w=win.1, over=wide_bar_people(7)) }),
    ])
    assert_eq(faults, [], msg=faults.join("\n"))
  }
}

///|
test "大屏: the title where the chat's words start with the sidebar folded and in a Windows window; a long one in a narrow window at the bar's start room, clear of the buttons" {
  // (its own run first: each state's maker starts another before it reads a word)
  new_run()
  let long = "把发布清单里每一项都核对一遍然后整理成最终的版本再发给大家确认一下"
  let calls : Array[Made] = []
  let titled = wide_bar_chat_field("title", fn(_) { Json::string(long) })
  let faults = wide_bar_aligned([
    (
      "folded",
      wide_bar_title_words,
      true,
      fn() {
        let t = wide_bar_at(calls)
        @sfdesk.sidebar_toggle()
        t.run_for(@ui.move_most_ms)
        t
      },
    ),
    ("windows", wide_bar_title_words, true, fn() { wide_bar_at(calls, platform=3, inset=true) }),
    // (a title cut short: its box as wide as is left it; the column at 860 and on the tape nearer the bar's start than
    // its start room)
    ("long 860", long, false, fn() { wide_bar_at(calls, w=860.0, over=titled) }),
    ("long 860 people", long, false, fn() { wide_bar_at(calls, w=860.0, over=wide_bar_both(wide_bar_people(7), titled)) }),
    ("long 中屏", long, false, fn() { wide_bar_at(calls, w=600.0, over=titled) }),
  ])
  assert_eq(faults, [], msg=faults.join("\n"))
}

///|
test "大屏, 中屏: under the bar a soft scroll edge, as tall as it and 16 more, in place of its ground; light and dark, 1.3x, a finger's, a Windows window's" {
  let calls : Array[Made] = []
  let states : Array[(String, () -> @ui.Tester)] = [
    ("大屏", fn() { wide_bar_at(calls) }),
    ("中屏", fn() { wide_bar_at(calls, w=720.0) }),
    ("windows", fn() { wide_bar_at(calls, platform=3, inset=true) }),
    ("touch", fn() { wide_bar_at(calls, w=690.0, h=840.0, platform=2, room="medium") }),
  ]
  for s in states {
    for dark in [false, true] {
      for scale in [1.0, 1.3] {
        let t = (s.1)()
        t.set_dark(dark)
        t.set_font_scale(scale)
        t.run_for(@ui.move_most_ms)
        let msg = "\{s.0} \{if dark { "dark" } else { "light" }} \{scale}x"
        guard wide_bar_edge(t) is Some((ex, ey, ew, eh)) else { fail("\{msg}: no edge under the bar") }
        // (no ground of the bar's own over it: the edge is its ground)
        let grounds = t
          .drawn_rects()
          .filter(fn(r) {
            (r.0 - ex).abs() < 0.5 && (r.1 - ey).abs() < 0.5 && (r.2 - ew).abs() < 0.5 && (r.3 - (eh - 16.0)).abs() < 0.5
          })
        assert_eq(grounds.length(), 0, msg="\{msg}: a ground as the bar's: \{Repr(grounds)}")
        guard wide_bar_title_at(t, wide_bar_title_words) is Some(_) else { fail("\{msg}: no title") }
        let audit = t.audit().filter(fn(f) { f.contains("chat_bar_wide_node") || f.contains("find_bar_node") })
        assert_eq(audit, [], msg~)
      }
    }
  }
}

///|
test "大屏: the bar's empty parts beside its title drag a Windows window; under the bar, its soft edge takes no press" {
  let calls : Array[Made] = []
  let t = wide_bar_at(calls, platform=3, inset=true)
  guard wide_bar_edge(t) is Some((ex, ey, _, eh)) else { fail("no edge under the bar") }
  guard wide_bar_title_at(t, wide_bar_title_words) is Some((x, y, w, h)) else { fail("no title") }
  let mid = y + h / 2.0
  let keys = wide_bar_keys_x(t)
  // (between the bar's start and the title, between the title and the buttons)
  for px in [(ex + x) / 2.0, (x + w + keys) / 2.0] {
    assert_true(t.drags_window_at(px, mid), msg="no drag at \{px}, \{mid}: \{t.sources_at(px, mid)}")
  }
  // (the edge's tail under the bar: what is under it takes the press, not the bar)
  let bar_h = eh - 16.0
  assert_false(t.drags_window_at(x + w / 2.0, ey + bar_h + 8.0), msg="the edge's tail drags the window")
  let before = t.window_drags()
  t.press_at((x + w + keys) / 2.0, mid)
  t.release((x + w + keys) / 2.0, mid)
  t.frame()
  assert_eq(t.window_drags() - before, 1)
}
