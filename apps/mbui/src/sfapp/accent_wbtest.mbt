// 外观's 主题色 (sfpages appearance.mbt, @sf.accent_pick; the prefs' `accent`): a colour theme chosen is the app's at once,
// by day and by night, the core told to keep it; still.fail's orange chosen again, none kept.

///|
test "主题色 蓝色 chosen, laid out narrow and wide, with touch and with a mouse: the accent and the grounds blue at once in light and dark, the core keeps it; 橙色, none kept" {
  for case in [(390.0, 2), (390.0, 0), (1280.0, 0)] {
    let (w, platform) = case
    let calls : Array[Made] = []
    let t = wide_tester(calls, w~, h=844.0, platform~)
    app.nav.push(Settings)
    app.nav.push(Setting(@settings.Route::Appearance))
    t.draw()
    t.run_for(@ui.move_most_ms)
    let orange = @sf.accents[0]
    let blue = @sf.accents[1]
    assert_eq(@sf.theme().p.accent, orange.light, msg="\{w}")
    let bg_orange = @sf.theme().p.bg
    assert_eq(t.get(Radio, label="橙色").selected, Some(true))
    // (each dot 8 apart from the next)
    let (x0, _, w0, _) = t.get(Radio, label="橙色").rect
    let (x1, _, _, _) = t.get(Radio, label="蓝色").rect
    assert_eq(x1 - (x0 + w0), 8.0, msg="\{w}")
    t.click(Radio, label="蓝色")
    t.frame()
    t.frame()
    let set = named(calls, "prefs.set")
    assert_eq(text(Some(set[set.length() - 1].params), "accent"), "blue")
    assert_eq(@sf.accent_key(), "blue")
    assert_eq(@sf.theme().p.accent, blue.light)
    assert_eq(@sf.theme().p.accent_text, blue.light_text)
    // the grounds in its hue (the page's, the sidebar's, what is chosen), as Slack's themes tint the frame
    let blue_day = blue.light_grounds.unwrap()
    assert_eq(@sf.theme().p.bg, blue_day.bg)
    assert_eq(@sf.theme().p.sidebar, blue_day.sidebar)
    assert_eq(@sf.ui_theme().sidebar, blue_day.sidebar)
    assert_eq(@sf.ui_theme().bg, blue_day.bg)
    assert_eq(@sf.ui_theme().faint, blue_day.faint)
    assert_eq(@sf.ui_theme().selected, blue_day.selected)
    // what a style's Accent and AccentText say, mbui's theme's
    assert_eq(@sf.ui_theme().accent, blue.light)
    assert_eq(@sf.ui_theme().accent_text, blue.light_text)
    assert_eq(t.get(Radio, label="蓝色").selected, Some(true))
    assert_eq(t.get(Radio, label="橙色").selected, Some(false))
    @sf.set_dark(Some(true))
    assert_eq(@sf.theme().p.accent, blue.dark)
    assert_eq(@sf.theme().p.accent_text, blue.dark_text)
    assert_eq(@sf.palette_of(true).accent, blue.dark)
    assert_eq(@sf.theme().p.bg, blue.dark_grounds.unwrap().bg)
    @sf.set_dark(Some(false))
    t.click(Radio, label="橙色")
    t.frame()
    t.frame()
    let set = named(calls, "prefs.set")
    assert_true(field(Some(set[set.length() - 1].params), "accent") is Some(Null))
    assert_eq(@sf.accent_key(), "")
    assert_eq(@sf.theme().p.accent, orange.light)
    assert_eq(@sf.theme().p.bg, bg_orange, msg="the warm paper back")
  }
}

///|
test "an accent the build does not know (kept by a newer one): still.fail's orange" {
  fresh_app()
  @sf.set_accent("indigo")
  assert_eq(@sf.accent_key(), "")
  @sf.set_accent("teal")
  assert_eq(@sf.theme().p.accent, @sf.accents[2].light)
  @sf.set_accent("")
}

///|
test "主题色 自定义: a hue of one's own, its slider under the dots; a step along it is the theme's at once, the core keeps it" {
  for case in [(390.0, 2), (1280.0, 0)] {
    let (w, platform) = case
    let calls : Array[Made] = []
    let t = wide_tester(calls, w~, h=844.0, platform~)
    app.nav.push(Settings)
    app.nav.push(Setting(@settings.Route::Appearance))
    t.draw()
    t.run_for(@ui.move_most_ms)
    // no hue slider till 自定义 is chosen
    assert_true(t.query(Slider, label="色相") is None, msg="\{w}")
    t.click(Radio, label="自定义")
    // (the slider comes in under the dots on its way: looked at once that is over)
    t.run_for(@ui.move_most_ms)
    let set = named(calls, "prefs.set")
    assert_eq(text(Some(set[set.length() - 1].params), "accent"), "custom:210")
    assert_eq(@sf.accent_key(), "custom:210")
    assert_eq(@sf.theme().p.accent, @sf.custom_tone(210).light)
    assert_eq(@sf.theme().p.bg, @sf.custom_tone(210).light_grounds.unwrap().bg)
    assert_eq(t.get(Radio, label="自定义").selected, Some(true))
    // its hues, as wide as the dots: a step along
    let hue = t.get(Slider, label="色相")
    let (dx, _, _, _) = t.get(Radio, label="橙色").rect
    let (ex, _, ew, _) = t.get(Radio, label="自定义").rect
    let (hx, _, hw, _) = hue.rect
    assert_eq((hx, hw), (dx, ex + ew - dx), msg="\{w}: the slider under the dots")
    t.act(Slider, Increment, label="色相")
    t.frame()
    t.frame()
    let set = named(calls, "prefs.set")
    assert_eq(text(Some(set[set.length() - 1].params), "accent"), "custom:215")
    assert_eq(@sf.theme().p.accent, @sf.custom_tone(215).light)
    // a preset again: the slider goes, the hue kept for 自定义's next press
    t.click(Radio, label="紫色")
    t.frame()
    t.frame()
    assert_eq(@sf.accent_key(), "purple")
    // (the slider closes its way under the dots: gone once it has)
    t.run_for(@ui.move_most_ms)
    assert_true(t.query(Slider, label="色相") is None, msg="\{w}")
    t.click(Radio, label="自定义")
    t.frame()
    t.frame()
    assert_eq(@sf.accent_key(), "custom:215")
  }
}

///|
test "主题色 五彩色: chosen saves rainbow and applies its picked hue in light and dark; each page open picks a colour from the clock" {
  for case in [(390.0, 2), (1280.0, 0)] {
    let (w, platform) = case
    let calls : Array[Made] = []
    let t = wide_tester(calls, w~, h=844.0, platform~)
    app.nav.push(Settings)
    app.nav.push(Setting(@settings.Route::Appearance))
    t.draw()
    t.run_for(@ui.move_most_ms)
    t.click(Radio, label="五彩色")
    t.frame()
    t.frame()
    let set = named(calls, "prefs.set")
    assert_eq(text(Some(set[set.length() - 1].params), "accent"), "rainbow", msg="\{w}")
    assert_eq(@sf.accent_key(), "rainbow", msg="\{w}")
    assert_eq(t.get(Radio, label="五彩色").selected, Some(true), msg="\{w}")
    assert_true(t.query(Slider, label="色相") is None, msg="\{w}: no hue slider under 五彩色")
    let picked = @sf.custom_tone(@sf.rainbow_hue_now())
    assert_eq(@sf.theme().p.accent, picked.light, msg="\{w}")
    assert_eq(@sf.theme().p.bg, picked.light_grounds.unwrap().bg, msg="\{w}")
    assert_eq(@sf.ui_theme().accent, picked.light, msg="\{w}")
    @sf.set_dark(Some(true))
    assert_eq(@sf.theme().p.accent, picked.dark, msg="\{w}")
    assert_eq(@sf.theme().p.bg, picked.dark_grounds.unwrap().bg, msg="\{w}")
    @sf.set_dark(Some(false))
  }
  // Opening the app at two different times with prefs.accent == "rainbow" automatically picks two distinct colours.
  let open_at = fn(ms : Double) -> (Int, Int64) raise {
    new_run()
    @settings.reset()
    let base = @sffixture.fixture("settings")
    let src : Source = {
      ..base,
      now: fn() { ms },
      topic_read: fn(name, params) {
        let got = (base.topic_read)(name, params)
        if name == "prefs" {
          match got.value {
            Some(Object(m)) => {
              let next = m.copy()
              next["accent"] = Json::string("rainbow")
              { ..got, value: Some(Json::object(next)) }
            }
            _ => got
          }
        } else {
          got
        }
      },
    }
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
    t.draw()
    assert_eq(@sf.accent_key(), "rainbow")
    let h = @sf.rainbow_hue_now()
    assert_eq(h, @sf.rainbow_hue_of_seed(ms.to_int64()))
    let accent = @sf.theme().p.accent
    assert_eq(accent, @sf.custom_tone(h).light)
    (h, accent)
  }
  let (h_a, accent_a) = open_at(1795530806000.0)
  let (h_b, accent_b) = open_at(1795530807000.0)
  assert_true(h_a != h_b, msg="different opens pick different hues: \{h_a} vs \{h_b}")
  assert_true(accent_a != accent_b)
}
