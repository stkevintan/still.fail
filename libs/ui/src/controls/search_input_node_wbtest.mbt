// The library's field to look through a list by (search_input_node): what is typed is its Field's and told as it
// changes; Enter gives it up once; while it holds words the clear key shows at its end, and pressed empties it, tells
// both that it was cleared and its words now none, and gives the focus back to the field; Escape is its caller's.

///|
/// A node "别处" taking the focus at the window's top, then in a box 300 wide what `make` makes there.
fn search_input_case(make : (@view.View) -> Unit) -> @ui.Tester {
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=400.0, h=400.0)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(e) {
      e
      .width(Is(Some(50.0)))
      .height(Is(Some(50.0)))
      .presses(Is(true))
      .focusable(Is(true))
      .says(Is(Some(@view.said(Button, label="别处"))))
      .on_press(fn() {  })
      |> ignore
    })
    |> ignore
    root.box(fn(b) {
      b.width(Is(Some(300.0))) |> ignore
      make(b)
    })
    |> ignore
  })
  t.draw()
  t
}

///|
/// The clear key's name, as the field says it.
fn search_clear_label() -> String {
  t("android-misc.drive.pick.filterClear")
}

///|
/// The panel search clear key's name (`web-pages.drive.pickClear`), distinct from `search_clear_label`.
fn panel_search_clear_label() -> String {
  t("web-pages.drive.pickClear")
}

///|
test "search_input_node: typed, its words told as they change; the clear key only while it holds words" {
  let f = @ui.Field::new()
  let told = []
  let t = search_input_case(fn(b) {
    search_input_node(b, f, fn() { "搜索设置" }, edited=fn(w) { told.push(w) }) |> ignore
  })
  let empty_has = t.query(Button, label=search_clear_label()) is Some(_)
  let (x, y, w, h) = t.get(TextField, label="搜索设置").rect
  t.tap(x + w / 2.0, y + h / 2.0)
  t.type_text("主题")
  t.draw()
  let typed_has = t.query(Button, label=search_clear_label()) is Some(_)
  assert_eq((empty_has, typed_has, f.text(), told.last()), (false, true, "主题", Some("主题")))
}

///|
test "search_input_node: the clear key empties it, tells it cleared and its words none, and gives the focus back to the field" {
  let f = @ui.Field::new(text="账号")
  let told = []
  let cleared = Ref(0)
  let t = search_input_case(fn(b) {
    search_input_node(b, f, fn() { "搜索设置" }, edited=fn(w) { told.push(w) }, cleared=fn() { cleared.val += 1 })
    |> ignore
  })
  let (x, y, w, h) = t.get(Button, label=search_clear_label()).rect
  t.tap(x + w / 2.0, y + h / 2.0)
  t.draw()
  let focused = t.focused().map(fn(s) { s.label })
  let gone = t.query(Button, label=search_clear_label()) is None
  assert_eq((f.text(), told, cleared.val, focused, gone), ("", [""], 1, Some("搜索设置"), true))
}

///|
test "search_input_node: Enter gives its words up once; Escape its caller's where it takes it" {
  let f = @ui.Field::new()
  let sent = []
  let escaped = Ref(0)
  let t = search_input_case(fn(b) {
    search_input_node(b, f, fn() { "搜索" }, submitted=fn(w) { sent.push(w) }, escape=fn() {
      escaped.val += 1
      true
    })
    |> ignore
  })
  let (x, y, w, h) = t.get(TextField, label="搜索").rect
  t.tap(x + w / 2.0, y + h / 2.0)
  t.type_text("归档")
  t.key_named("enter") |> ignore
  t.key_named("escape") |> ignore
  assert_eq((sent, escaped.val), (["归档"], 1))
}

///|
test "panel_search_input_node: rebinding finder.down distinguishes Finder context from combobox" {
  let bindings : Array[@view.Binding] = [
    { keys: [{ code: @ui.key_code_page_down, mods: 0 }], action: "finder.down", when: In("Finder") },
    { keys: [{ code: @ui.key_code_down, mods: 0 }], action: @headless.combobox_next, when: In(@headless.combobox_context) },
  ]
  // 1. panel_search_input_node responds to rebound finder.down (PageDown), not combobox's Down
  let panel_f = @ui.Field::new()
  let panel_steps : Array[Int] = []
  let t1 = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=400.0, h=400.0)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.keymap(Is(@view.Keymap::new(bindings))) |> ignore
    root.box(fn(b) {
      b.width(Is(Some(300.0))) |> ignore
      panel_search_input_node(b, panel_f, fn() { "面板搜索" }, step=fn(d) {
        panel_steps.push(d)
        true
      })
      |> ignore
    })
    |> ignore
  })
  t1.draw()
  let (px, py, pw, ph) = t1.get(TextField, label="面板搜索").rect
  t1.tap(px + pw / 2.0, py + ph / 2.0)
  t1.key(@ui.key_code_down)
  assert_eq(panel_steps, [])
  t1.key(@ui.key_code_page_down)
  assert_eq(panel_steps, [1])
  // 2. search_input_node responds to combobox's Down, not Finder's rebound PageDown
  let combo_f = @ui.Field::new()
  let combo_steps : Array[Int] = []
  let t2 = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=400.0, h=400.0)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.keymap(Is(@view.Keymap::new(bindings))) |> ignore
    root.box(fn(b) {
      b.width(Is(Some(300.0))) |> ignore
      search_input_node(b, combo_f, fn() { "列表搜索" }, step=fn(d) {
        combo_steps.push(d)
        true
      })
      |> ignore
    })
    |> ignore
  })
  t2.draw()
  let (cx, cy, cw, ch) = t2.get(TextField, label="列表搜索").rect
  t2.tap(cx + cw / 2.0, cy + ch / 2.0)
  t2.key(@ui.key_code_page_down)
  assert_eq(combo_steps, [])
  t2.key(@ui.key_code_down)
  assert_eq(combo_steps, [1])
}

///|
test "panel_search_input_node: step_can gates arrows; Escape clears once then bubbles; Enter and clear fire once" {
  let f = @ui.Field::new()
  let edited : Array[String] = []
  let submitted : Array[String] = []
  let steps : Array[Int] = []
  let outer_escapes = Ref(0)
  let outer_downs = Ref(0)
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=400.0, h=400.0)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.keymap(Is(@view.Keymap::new(finder_bindings()))) |> ignore
    root.box(fn(outer) {
      outer
      .width(Is(Some(300.0)))
      .key_context("Finder")
      .on_action("finder.down", fn(_) {
        outer_downs.val += 1
        true
      })
      .on_key(fn(k) {
        if k.code == @ui.key_escape && k.mods == 0 {
          outer_escapes.val += 1
          true
        } else {
          false
        }
      })
      |> ignore
      panel_search_input_node(
        outer,
        f,
        fn() { "搜模型" },
        edited=fn(w) { edited.push(w) },
        submitted=fn(w) { submitted.push(w) },
        step=fn(d) {
          steps.push(d)
          true
        },
        step_can=fn() { f.text() != "" },
      )
      |> ignore
    })
    |> ignore
  })
  t.draw()
  let (x, y, w, h) = t.get(TextField, label="搜模型").rect
  t.tap(x + w / 2.0, y + h / 2.0)
  // Empty: Down bubbles to outer (step_can is false), Escape bubbles to outer
  t.key(@ui.key_code_down)
  t.key(@ui.key_escape)
  assert_eq((steps, outer_downs.val, outer_escapes.val), ([], 1, 1))
  // Non-empty: Down/Up consumed by panel_search_input_node, Enter submits once, Escape clears once & consumes
  t.type_text("gpt")
  t.draw()
  t.key(@ui.key_code_down)
  t.key(@ui.key_code_up)
  t.key(@ui.key_code_enter)
  assert_eq((steps, outer_downs.val, submitted), ([1, -1], 1, ["gpt"]))
  let edits_before_esc = edited.length()
  t.key(@ui.key_escape)
  t.draw()
  assert_eq((f.text(), edited.length() - edits_before_esc, edited.last(), outer_escapes.val), ("", 1, Some(""), 1))
  // Empty again: Escape bubbles to outer
  t.key(@ui.key_escape)
  assert_eq((outer_escapes.val, edited.length() - edits_before_esc), (2, 1))
  // Shift+Escape also clears non-empty text and consumes (matching original panel search behavior)
  t.type_text("gemini")
  t.draw()
  let edits_before_shift_esc = edited.length()
  t.key(@ui.key_escape, mods=@ui.mod_shift_key)
  t.draw()
  assert_eq((f.text(), edited.length() - edits_before_shift_esc, edited.last(), outer_escapes.val), ("", 1, Some(""), 2))
  // Clear button uses panel-specific label ("清除"), empties once and notifies edited("") once
  assert_true(panel_search_clear_label() != search_clear_label())
  t.type_text("claude")
  t.draw()
  assert_true(t.query(Button, label=panel_search_clear_label()) is Some(_))
  assert_true(t.query(Button, label=search_clear_label()) is None)
  let edits_before_clear = edited.length()
  let (bx, by, bw, bh) = t.get(Button, label=panel_search_clear_label()).rect
  t.tap(bx + bw / 2.0, by + bh / 2.0)
  t.draw()
  assert_eq((f.text(), edited.length() - edits_before_clear, edited.last()), ("", 1, Some("")))
  assert_true(t.query(Button, label=panel_search_clear_label()) is None)
}

///|
test "panel_search_input_node: touch clear button empties field without forcing focus or raising IME" {
  let f = @ui.Field::new(text="openai")
  let edited : Array[String] = []
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=390.0, h=844.0, platform=2)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(b) {
      b.width(Is(Some(300.0))) |> ignore
      panel_search_input_node(b, f, fn() { "搜索模型" }, edited=fn(w) { edited.push(w) }) |> ignore
    })
    |> ignore
  })
  t.draw()
  assert_false(t.ime().0, msg="IME closed initially")
  let (bx, by, bw, bh) = t.get(Button, label=panel_search_clear_label()).rect
  t.tap(bx + bw / 2.0, by + bh / 2.0)
  t.draw()
  assert_eq((f.text(), edited), ("", [""]))
  assert_false(t.ime().0, msg="tapping clear button on touch must not raise IME")
  assert_true(t.focused().map(fn(s) { s.label }) != Some("搜索模型"), msg="tapping clear button on touch must not force field focus")
}

///|
test "panel_search_input_node: placeholder_by updates live when language switches" {
  set_words(default_words)
  set_language(Some("zh"))
  let f = @ui.Field::new()
  let t = search_input_case(fn(b) {
    panel_search_input_node(b, f, fn() { t("common.search") }) |> ignore
  })
  assert_true(t.query(TextField, label="搜索") is Some(_))
  set_language(Some("en"))
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(TextField, label="Search") is Some(_))
  set_language(None)
}
