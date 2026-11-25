// The windows of one run (window_slots.mbt): each window beside the first its own tree, drawn in its first frame,
// pressed and read apart from the first's; closed, its tree let go of and the first going on as it was.

///|
/// A Tester whose first window shows `首个窗口` and a button counting its presses in `first`, its windows opening in the
/// run, each beside it showing what it was opened for and a button counting in `beside`; `gone` counts the trees of
/// windows beside let go of.
fn windows_tester(first : Ref[Int], beside : Ref[Int], gone : Ref[Int]) -> Tester {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0)
  t.check_looks(false)
  t.set_windows_in_process(true)
  let page = fn(root : @view.View, title : String, count : Ref[Int]) {
    root.box(fn(b) {
      b.width(Is(Some(200.0))).height(Is(Some(40.0))).words(Is(title)) |> ignore
    })
    |> ignore
    root.box(fn(b) {
      b
      .width(Is(Some(120.0)))
      .height(Is(Some(44.0)))
      .says(Is(Some(@view.said(Button, label="按一下"))))
      .on_press(fn() { count.val += 1 })
      .words(Is("按一下"))
      |> ignore
    })
    |> ignore
  }
  set_window_tree(fn(_wid, what) {
    fn(root) {
      root.owns(fn() { gone.val += 1 }) |> ignore
      page(root, what, beside)
    }
  })
  set_view_app(fn(root) { page(root, "首个窗口", first) })
  t.draw()
  t
}

///|
fn shown_words(t : Tester) -> Array[String] {
  t.words().map(fn(w) { w.0 })
}

///|
test "a window opened beside the first: its tree drawn in its first frame, its words its own, the first's unchanged" {
  let (first, beside, gone) = (Ref(0), Ref(0), Ref(0))
  let t = windows_tester(first, beside, gone)
  let wid = window_open_here("屏幕窗口")
  assert_eq(wid, 1)
  t.draw()
  assert_true(shown_words(t).contains("首个窗口"), msg="\{Repr(shown_words(t))}")
  assert_false(shown_words(t).contains("屏幕窗口"), msg="\{Repr(shown_words(t))}")
  let words = Ref([])
  t.in_window(wid, fn() { words.val = shown_words(t) })
  assert_true(words.val.contains("屏幕窗口"), msg="\{Repr(words.val)}")
  assert_false(words.val.contains("首个窗口"), msg="\{Repr(words.val)}")
  assert_eq(current_window_id(), 0)
  assert_eq(t.windows_beside(), [(1, "屏幕窗口")])
}

///|
test "a press in a window beside the first is that window's: the first's button is not pressed, nor the other way" {
  let (first, beside, gone) = (Ref(0), Ref(0), Ref(0))
  let t = windows_tester(first, beside, gone)
  let wid = window_open_here("屏幕窗口")
  t.draw()
  t.in_window(wid, fn() { t.tap_text("按一下") })
  t.draw()
  assert_eq((first.val, beside.val), (0, 1))
  t.tap_text("按一下")
  t.draw()
  assert_eq((first.val, beside.val), (1, 1))
}

///|
test "a window beside the first closed by the person: its tree let go of, the first drawn on as it was, another opening anew" {
  let (first, beside, gone) = (Ref(0), Ref(0), Ref(0))
  let t = windows_tester(first, beside, gone)
  let wid = window_open_here("屏幕窗口")
  t.draw()
  let told = Ref([])
  when_window_closed(fn(w) { told.val.push(w) })
  t.close_window_beside(wid)
  t.draw()
  assert_eq(gone.val, 1)
  assert_eq(told.val, [wid])
  assert_eq(t.windows_beside(), [])
  assert_true(shown_words(t).contains("首个窗口"), msg="\{Repr(shown_words(t))}")
  t.tap_text("按一下")
  t.draw()
  assert_eq(first.val, 1)
  let again = window_open_here("又一个")
  t.draw()
  let words = Ref([])
  t.in_window(again, fn() { words.val = shown_words(t) })
  assert_eq(again, 2)
  assert_true(words.val.contains("又一个"), msg="\{Repr(words.val)}")
}

///|
test "a window beside the first closed by the app: let go of between frames, the host told, the first going on" {
  let (first, beside, gone) = (Ref(0), Ref(0), Ref(0))
  let t = windows_tester(first, beside, gone)
  let wid = window_open_here("屏幕窗口")
  t.draw()
  t.in_window(wid, fn() { window_close_here(wid) })
  t.draw()
  assert_eq(gone.val, 1)
  assert_eq(t.window_ids_closed(), [wid])
  assert_eq(t.windows_beside(), [])
  assert_eq(current_window_id(), 0)
}

///|
test "no window opens beside the first where the host opens them as runs of their own" {
  let (first, beside, gone) = (Ref(0), Ref(0), Ref(0))
  let t = windows_tester(first, beside, gone)
  t.set_windows_in_process(false)
  t.draw()
  assert_eq(window_open_here("屏幕窗口"), 0)
  assert_eq(t.windows_beside(), [])
}

///|
test "a window opened as its WindowSpec says: drawn at its own size from its first frame, the first at its own, its title and role the host's, what it shows the spec's" {
  let (first, beside, gone) = (Ref(0), Ref(0), Ref(0))
  let t = windows_tester(first, beside, gone)
  let spec = WindowSpec::new(what="term:1", role="terminal", title="终端", w=640.0, h=480.0)
  let wid = window_open_spec(spec)
  assert_eq(wid, 1)
  t.draw()
  let (size, words) = (Ref((0.0, 0.0)), Ref([]))
  t.in_window(wid, fn() {
    size.val = window_size.val.get()
    words.val = shown_words(t)
  })
  assert_eq(size.val, (640.0, 480.0))
  assert_eq(window_size.val.get(), (400.0, 300.0))
  assert_true(words.val.contains("term:1"), msg="\{Repr(words.val)}")
  assert_eq(window_shows(wid), Some("term:1"))
  assert_eq(t.windows_beside(), [(1, "term:1")])
  assert_eq((t.window_title(wid=1), t.window_role(1), t.window_title()), ("终端", "terminal", ""))
}

///|
test "a WindowSpec told the host as JSON of what it says; one that says no what shown as that" {
  assert_eq(WindowSpec::new().to_json_string(), "{}")
  let all = WindowSpec::new(what="x", role="r", title="t", w=1.0, h=2.0, min_w=3.0, min_h=4.0, inset=Some(true))
  let parsed = @json.parse(all.to_json_string()) catch { _ => Json::null() }
  let said = match parsed {
    Object(m) => m.keys().collect()
    _ => []
  }
  let keys = ["h", "inset", "minH", "minW", "role", "title", "w", "what"]
  assert_eq((said.length(), keys.filter(fn(k) { !said.contains(k) })), (8, []))
  let (first, beside, gone) = (Ref(0), Ref(0), Ref(0))
  let t = windows_tester(first, beside, gone)
  let bare = WindowSpec::new(title="无名", w=500.0, h=400.0)
  let wid = window_open_spec(bare)
  t.draw()
  assert_eq(window_shows(wid), Some(bare.to_json_string()))
  // (one opened by what it shows, as JSON: its size and title read as the host reads them)
  let opened = window_open_here("{\"w\":320,\"h\":200,\"title\":\"旧\"}")
  t.draw()
  let size = Ref((0.0, 0.0))
  t.in_window(opened, fn() { size.val = window_size.val.get() })
  assert_eq((size.val, t.window_title(wid=opened)), ((320.0, 200.0), "旧"))
}

///|
test "each window's title its own: the first's and one beside it set apart, the same title told the host once" {
  let (first, beside, gone) = (Ref(0), Ref(0), Ref(0))
  let t = windows_tester(first, beside, gone)
  let wid = window_open_here("屏幕窗口")
  t.draw()
  set_window_title("主窗口")
  t.in_window(wid, fn() { set_window_title("副窗口") })
  assert_eq((t.window_title(), t.window_title(wid~)), ("主窗口", "副窗口"))
  // (what the host was told written over: the same title again tells it nothing)
  fake_window_titles[0] = "-"
  fake_window_titles[wid] = "-"
  set_window_title("主窗口")
  t.in_window(wid, fn() { set_window_title("副窗口") })
  set_window_title_of(wid, "副窗口")
  assert_eq((t.window_title(), t.window_title(wid~)), ("-", "-"))
  // (one beside set from the first: its own, the first's as it was, the first in place after)
  set_window_title_of(wid, "改了")
  set_window_title_of(9, "无此窗口")
  assert_eq((t.window_title(), t.window_title(wid~), t.window_title(wid=9)), ("-", "改了", ""))
  assert_eq(current_window_id(), 0)
  t.in_window(wid, fn() { set_window_title_of(0, "主窗口又") })
  assert_eq((t.window_title(), t.window_title(wid~)), ("主窗口又", "改了"))
}

///|
/// A Tester whose every window shows a node 300 wide, 40 in round a field of its own ("the field"), taking words let go
/// on it for that field and files by their paths (what each window's took in `taken`, by its id); its windows opening
/// in the run.
fn drops_windows_tester(fields : Map[Int, Field], taken : Map[Int, Array[String]]) -> Tester {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0)
  t.check_looks(false)
  t.set_windows_in_process(true)
  let page = fn(root : @view.View, wid : Int) {
    let f = Field::new(text="")
    let got : Array[String] = []
    fields[wid] = f
    taken[wid] = got
    root.box(fn(cap) {
      cap.width(Is(Some(300.0))).padding(Is((40.0, 40.0, 40.0, 40.0))).on_press(fn() { f.focus() }) |> ignore
      field(cap, f, placeholder="the field", font_size=10.0, max_lines=1) |> ignore
      words_into(cap, f) |> ignore
      paths_into(cap, f, fn(ps) {
        for p in ps {
          got.push(p.path)
        }
      })
      |> ignore
    })
    |> ignore
  }
  set_window_tree(fn(wid, _what) { fn(root) { page(root, wid) } })
  set_view_app(fn(root) { page(root, 0) })
  t.draw()
  t
}

///|
test "what is let go on a window beside the first is that window's, at the same place as on the first: the first's nodes given none; on one closed since, let go" {
  let fields : Map[Int, Field] = Map([])
  let taken : Map[Int, Array[String]] = Map([])
  let t = drops_windows_tester(fields, taken)
  let wid = window_open_here("拖放")
  t.draw()
  // (the host's message comes between frames, the first window in place: it says the window they were let go on)
  t.drop_words(50.0, 20.0, "cd", wid~)
  t.draw()
  t.drop_files(50.0, 20.0, [("a.txt", b"x")], paths=["/Users/me/a.txt"], wid~)
  t.draw()
  assert_eq(current_window_id(), 0)
  assert_eq((fields[0].text(), taken[0]), ("", []))
  assert_eq((fields[wid].text(), taken[wid]), ("cd", ["/Users/me/a.txt"]))
  // (on the first, as ever: the first's)
  t.drop_words(50.0, 20.0, "ef")
  t.draw()
  assert_eq((fields[0].text(), fields[wid].text()), ("ef", "cd"))
  // (on a window closed since: taken by none, let go unread)
  t.drop_files(50.0, 20.0, [("b.txt", b"y")], paths=["/Users/me/b.txt"], wid=9)
  let pick = t.fake.pick_asks.length()
  t.drop_words(50.0, 20.0, "zz", wid=9)
  t.draw()
  assert_eq(t.fake.pk_state(pick), -1)
  assert_eq((fields[0].text(), fields[wid].text()), ("ef", "cd"))
  assert_eq((taken[0], taken[wid]), ([], ["/Users/me/a.txt"]))
}

///|
test "one hand for every window: a list's rows going back soon after a press in a window beside the first are its answer, no shake of the list's" {
  let tall = @signals.signal(40.0)
  let row : Ref[@view.View?] = Ref(None)
  // (a bar under the list growing slowly from the first press on, so the first window draws every frame of the
  // display's: the rows seen standing at rest between their two ways, as where something else in the window moves)
  let bar_tall = @signals.signal(4.0)
  let bar : Ref[@view.View?] = Ref(None)
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0)
  t.check_looks(false)
  t.set_windows_in_process(true)
  // (the first window's first row made another height on its list's way, in that window as it is the row's: from
  // whichever window it is pressed in)
  let resize = fn(to : Double) {
    as_window(0, fn() {
      match row.val {
        Some(r) => r.resizes() |> ignore
        None => ()
      }
      tall.set(to)
    })
  }
  let button = fn(root : @view.View, label : String, press : () -> Unit) {
    root.box(fn(b) {
      b
      .width(Is(Some(120.0)))
      .height(Is(Some(44.0)))
      .says(Is(Some(@view.said(Button, label~))))
      .on_press(press)
      .words(Is(label))
      |> ignore
    })
    |> ignore
  }
  set_window_tree(fn(_wid, _what) { fn(root) { button(root, "收起", fn() { resize(40.0) }) } })
  set_view_app(fn(root) {
    button(root, "展开", fn() {
      resize(90.0)
      match bar.val {
        Some(b) => b.resizes(spec=(rows_return_ms * 2.0, fn(p) { p })) |> ignore
        None => ()
      }
      bar_tall.set(24.0)
    })
    root.box(fn(col) {
      col.width(Is(Some(300.0))).height(Is(Some(200.0))) |> ignore
      col.scrolls_window(@view.Scroll::list(), fn() { [0, 1, 2] }, est=40.0, fn(b, k) {
        b.width(Is(Some(200.0))).ground(Is(0x445566FFL)).words(Is("第\{k}行")) |> ignore
        if k == 0 {
          b.height(By(fn() { Some(tall.get()) })) |> ignore
          row.val = Some(b)
        } else {
          b.height(Is(Some(40.0))) |> ignore
        }
      })
      |> ignore
    })
    |> ignore
    root.box(fn(b) {
      b.width(Is(Some(300.0))).height(By(fn() { Some(bar_tall.get()) })).ground(Is(0x334455FFL)) |> ignore
      bar.val = Some(b)
    })
    |> ignore
  })
  t.draw()
  let wid = window_open_here("另一个窗口")
  t.draw()
  t.run_for(row_size_ms * 2.0)
  // (the rows under the first go down 50 for a press in the first window, then back up for one in the other soon after
  // they came to rest: the press's answer, the hand's whichever window it was in)
  t.tap_text("展开")
  t.run_for(row_size_ms * 2.0)
  t.in_window(wid, fn() { t.tap_text("收起") })
  t.run_for(row_size_ms * 2.0)
  let found : Array[String] = rows_steady.found.iter().collect()
  assert_eq((tall.get(), found), (40.0, []))
}

///|
test "each window's own buttons, maximized and inset: the first in full screen beside one under its buttons, each drawn as its own says frame after frame; its close button closes it alone" {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0)
  t.check_looks(false)
  t.set_windows_in_process(true)
  // (each window's words as its own host settings say them, bound: built again only as its own change)
  let page = fn(root : @view.View) {
    root.box(fn(b) {
      b
      .width(Is(Some(300.0)))
      .height(Is(Some(40.0)))
      .words(By(fn() {
        (if window_inset() { "inset" } else { "plain" }) + " " + (if window_zoomed() { "zoomed" } else { "windowed" })
      }))
      |> ignore
    })
    |> ignore
  }
  set_window_tree(fn(_wid, _what) { fn(root) { page(root) } })
  set_view_app(fn(root) { page(root) })
  t.draw()
  let wid = window_open_spec(WindowSpec::new(what="tab", role="tab", title="说明.md", w=480.0, h=360.0, inset=Some(true)))
  assert_eq(wid, 1)
  let seen = fn() {
    let beside = Ref([])
    t.in_window(wid, fn() { beside.val = shown_words(t) })
    (shown_words(t), beside.val)
  }
  for _ in 0..<3 {
    t.draw()
    assert_eq(seen(), (["plain windowed"], ["inset windowed"]))
  }
  // the window beside maximized, then the first: each its own, frame after frame
  t.set_window_zoomed_of(wid, true)
  for _ in 0..<3 {
    t.draw()
    assert_eq(seen(), (["plain windowed"], ["inset zoomed"]))
  }
  t.set_window_zoomed_of(0, true)
  t.set_window_inset_of(wid, false)
  for _ in 0..<3 {
    t.draw()
    assert_eq(seen(), (["plain zoomed"], ["plain zoomed"]))
  }
  t.set_window_zoomed_of(wid, false)
  t.draw()
  assert_eq(seen(), (["plain zoomed"], ["plain windowed"]))
  // its own close button (the app's, @hostapi.window_act 3): that window closed as its host would, the first as it was
  t.in_window(wid, fn() { window_act(3) })
  t.draw()
  assert_eq(t.window_acts_of(wid~), [3])
  assert_eq(t.window_acts(), [])
  assert_eq(t.windows_beside(), [])
  assert_eq(t.window_ids_closed(), [wid])
  assert_eq(shown_words(t), ["plain zoomed"])
}
