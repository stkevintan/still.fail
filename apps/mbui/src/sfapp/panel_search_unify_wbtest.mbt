// Panel search input unification tests (Wave 26 Track 3):
// Verifies presets, station_picker_node, and model_triple all use `@sf.panel_search_input_node` with live language
// updates (`placeholder_by`), Escape clear-then-close semantics, per-panel arrow/navigated behavior, single-fire clear
// and submit, and touch clear-button focus/IME hygiene.

///|
fn panel_search_clear_label() -> String {
  @sf.t("web-pages.drive.pickClear")
}

///|
/// Wraps `base` so the `"prefs"` topic reflects `lang` when non-empty (matching `pick_node_wbtest.mbt`), allowing live
/// language switching while a panel stays open.
fn panel_search_lang_src(base : Source, lang : @signals.Signal[String]) -> Source {
  {
    ..base,
    topic_read: fn(name, params) {
      let got = base.topic(name, params).get().snapshot()
      if name != "prefs" || lang.get() == "" {
        return got
      }
      let o = match got.value {
        Some(Object(m)) => m.copy()
        _ => {}
      }
      o["lang"] = Json::string(lang.get())
      { ..got, value: Some(Json::object(o)) }
    },
  }
}

///|
/// Whether the button named `label` currently has a visible hover/highlight background fill covering its rect.
fn panel_row_highlighted(t : @ui.Tester, label : String) -> Bool raise {
  let (rx, ry, rw, rh) = t.get(Button, label~).rect
  t
  .drawn_rects()
  .iter()
  .any(fn(r) {
    (r.4 & 0xFFL) > 0L &&
    (r.0 - rx).abs() < 2.0 &&
    (r.1 - ry).abs() < 2.0 &&
    (r.2 - rw).abs() < 2.0 &&
    (r.3 - rh).abs() < 2.0
  })
}

///|
test "presets panel search: live language switch, Escape clear-then-close, and touch clear keeps IME closed" {
  // Desktop popover: live language switch + Escape clears query first, then closes panel
  new_run()
  let lang = @signals.signal("")
  let t = preset_mode("newchat-preset-many", wide=true, src=panel_search_lang_src(fixture("newchat-preset-many"), lang))
  assert_true(t.query(TextField, label="搜预设") is Some(_), msg=t.semantics_dump())
  lang.set("en")
  t.stepped()
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(TextField, label="Search presets") is Some(_), msg=t.semantics_dump())
  lang.set("")
  @sf.set_language(None)
  t.stepped()
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(TextField, label="搜预设") is Some(_))
  t.click(TextField, label="搜预设")
  t.type_text("still")
  t.draw()
  assert_eq(t.get(TextField, label="搜预设").value, "still")
  // Non-empty Escape clears text and keeps dialog open
  t.key(@ui.key_escape)
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(@ui.Role::Dialog) is Some(_), msg="non-empty Escape must keep presets panel open")
  assert_eq(t.get(TextField, label="搜预设").value, "")
  // Empty Escape bubbles and closes dialog
  t.key(@ui.key_escape)
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(@ui.Role::Dialog) is None, msg="empty Escape must close presets panel")
  // Touch sheet: typing raises IME; clear button empties query cleanly
  new_run()
  let mt = preset_mode("newchat-preset-many", wide=false)
  let (fx, fy, fw, fh) = mt.get(TextField, label="搜预设").rect
  mt.tap(fx + fw / 2.0, fy + fh / 2.0)
  mt.type_text("still")
  mt.draw()
  assert_true(mt.ime().0, msg="typing in preset search raised IME")
  let (cx, cy, cw, ch) = mt.get(Button, label=panel_search_clear_label()).rect
  mt.tap(cx + cw / 2.0, cy + ch / 2.0)
  mt.draw()
  assert_eq(mt.get(TextField, label="搜预设").value, "")
  assert_true(mt.query(Button, label=panel_search_clear_label()) is None)
}

///|
test "station_picker panel search: live language switch, navigated reset on edit/clear/escape, single submit, Escape clear-then-close" {
  // Wide modal: live language switch
  new_run()
  let lang = @signals.signal("")
  let calls : Array[Made] = []
  let t = preset_mode(
    "newchat-station-many",
    wide=true,
    src=panel_search_lang_src(preset_calls("newchat-station-many", calls), lang),
  )
  let zh_wide = "搜索 station 名称或连接方式…"
  let en_wide = "Search by station name or connection…"
  assert_true(t.query(TextField, label=zh_wide) is Some(_), msg=t.semantics_dump())
  lang.set("en")
  t.stepped()
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(TextField, label=en_wide) is Some(_), msg=t.semantics_dump())
  lang.set("")
  @sf.set_language(None)
  t.stepped()
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(TextField, label=zh_wide) is Some(_), msg=t.semantics_dump())
  // Initially empty & not navigated: neither Willow (row 0) nor Maple (row 1) has keyboard highlight
  assert_false(panel_row_highlighted(t, "Willow"), msg="row 0 unhighlighted before navigation")
  assert_false(panel_row_highlighted(t, "Maple"), msg="row 1 unhighlighted before navigation")
  // Step down with arrow -> navigated=true, search_at=1 -> Maple becomes highlighted
  t.click(TextField, label=zh_wide)
  t.key(@ui.key_code_down)
  t.run_for(@ui.move_most_ms)
  assert_true(panel_row_highlighted(t, "Maple"), msg="Down arrow must highlight row 1 (Maple)")
  // Type query -> edited resets search_at=0 & navigated=false; step down inside filtered results, then Escape clears
  // query and resets navigated=false so empty-query highlight disappears
  t.type_text("station")
  t.draw()
  t.key(@ui.key_code_down)
  t.run_for(@ui.move_most_ms)
  t.key(@ui.key_escape)
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(@ui.Role::Dialog) is Some(_), msg="non-empty Escape keeps station picker open")
  assert_eq(t.get(TextField, label=zh_wide).value, "")
  assert_false(panel_row_highlighted(t, "Willow"), msg="Escape clear must reset navigated and remove row 0 highlight")
  assert_false(panel_row_highlighted(t, "Maple"), msg="Escape clear must reset navigated and remove row 1 highlight")
  // Type again, step down, then click clear button -> clears query and resets search_at=0 & navigated=false
  t.type_text("station")
  t.draw()
  t.key(@ui.key_code_down)
  t.run_for(@ui.move_most_ms)
  let (cx, cy, cw, ch) = t.get(Button, label=panel_search_clear_label()).rect
  t.tap(cx + cw / 2.0, cy + ch / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(t.get(TextField, label=zh_wide).value, "")
  assert_true(t.query(Button, label=panel_search_clear_label()) is None)
  assert_false(panel_row_highlighted(t, "Willow"), msg="clear button must reset navigated and remove row 0 highlight")
  assert_false(panel_row_highlighted(t, "Maple"), msg="clear button must reset navigated and remove row 1 highlight")
  // Pressing Enter now picks index 0 (unfiltered first station "st1") exactly once and closes
  let picks_before = named(calls, "newChat.pick").length()
  t.key(@ui.key_code_enter)
  t.run_for(@ui.move_most_ms)
  let picks = named(calls, "newChat.pick")
  assert_eq(picks.length() - picks_before, 1, msg="Enter must submit station pick exactly once")
  assert_eq(text(Some(picks.last().unwrap().params), "station"), "st1")
  assert_true(t.query(@ui.Role::Dialog) is None, msg="Enter closes station picker")
  // Empty Escape closes station picker
  new_run()
  let t2 = preset_mode("newchat-station-many", wide=true)
  assert_true(t2.query(@ui.Role::Dialog) is Some(_))
  t2.key(@ui.key_escape)
  t2.run_for(@ui.move_most_ms)
  assert_true(t2.query(@ui.Role::Dialog) is None, msg="empty Escape must close station picker")
  // Narrow drawer: live language switch
  new_run()
  let nlang = @signals.signal("")
  let nt = preset_mode("newchat-station-many", wide=false, src=panel_search_lang_src(fixture("newchat-station-many"), nlang))
  assert_true(nt.query(TextField, label="搜索 station") is Some(_), msg=nt.semantics_dump())
  nlang.set("en")
  nt.stepped()
  nt.run_for(@ui.move_most_ms)
  assert_true(nt.query(TextField, label="Search stations") is Some(_), msg=nt.semantics_dump())
  nlang.set("")
  @sf.set_language(None)
}

///|
test "model_triple panel search: live language switch, empty vs non-empty arrows, Escape clear-then-close, single submit" {
  new_run()
  let lang = @signals.signal("")
  let calls : Array[Made] = []
  let t = preset_mode(
    "newchat-providers-model",
    wide=true,
    src=panel_search_lang_src(preset_calls("newchat-providers-model", calls), lang),
  )
  assert_true(t.query(TextField, label="搜索模型") is Some(_), msg=t.semantics_dump())
  lang.set("en")
  t.stepped()
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(TextField, label="Search models") is Some(_), msg=t.semantics_dump())
  lang.set("")
  @sf.set_language(None)
  t.stepped()
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(TextField, label="搜索模型") is Some(_))
  // Empty search: finder.down / finder.up are NOT consumed (step_can is false)
  t.click(TextField, label="搜索模型")
  assert_false(@ui.view_action("finder.down"), msg="empty model search must not consume finder.down")
  assert_false(@ui.view_action("finder.up"), msg="empty model search must not consume finder.up")
  t.draw()
  assert_true(t.query(Button, label="全部模型") is Some(_))
  // Non-empty search: finder.down / finder.up ARE consumed (step_can is true); clear button empties once
  t.type_text("openai")
  t.draw()
  assert_true(t.query(Button, label="GPT-6 Astra") is Some(_) && t.query(Button, label="gpt-oss 2") is Some(_))
  assert_true(@ui.view_action("finder.down"), msg="non-empty model search must consume finder.down")
  assert_true(@ui.view_action("finder.up"), msg="non-empty model search must consume finder.up")
  t.draw()
  let (cx, cy, cw, ch) = t.get(Button, label=panel_search_clear_label()).rect
  t.tap(cx + cw / 2.0, cy + ch / 2.0)
  t.draw()
  assert_eq(t.get(TextField, label="搜索模型").value, "")
  assert_true(t.query(Button, label="全部模型") is Some(_))
  // Type again, non-empty Escape clears and keeps panel open
  t.type_text("openai")
  t.draw()
  t.key(@ui.key_escape)
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(@ui.Role::Dialog) is Some(_), msg="non-empty Escape keeps model panel open")
  assert_eq(t.get(TextField, label="搜索模型").value, "")
  // Empty Escape closes panel
  t.key(@ui.key_escape)
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(@ui.Role::Dialog) is None, msg="empty Escape closes model panel")
  // Reopen, search "openai", step down once, Enter submits once and picks second match
  new_run()
  let calls2 : Array[Made] = []
  let t2 = preset_mode("newchat-providers-model", wide=true, src=preset_calls("newchat-providers-model", calls2))
  t2.click(TextField, label="搜索模型")
  t2.type_text("openai")
  t2.draw()
  t2.key(@ui.key_code_down)
  t2.draw()
  let picks_before = named(calls2, "pick.save").length()
  t2.key(@ui.key_code_enter)
  t2.run_for(@ui.move_most_ms)
  let picks = named(calls2, "pick.save")
  assert_eq(picks.length() - picks_before, 1, msg="Enter must submit model pick exactly once")
  assert_eq(@sffixture.new_fix.model, "gpt-oss-2")
  assert_true(t2.query(@ui.Role::Dialog) is None)
}
