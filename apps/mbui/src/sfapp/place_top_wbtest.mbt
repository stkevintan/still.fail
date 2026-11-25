// A place's top page with the bar under it: its top bar frosted over what it shows, which starts under
// the bar and scrolls on under it to the page's top, not cut short at the bar's foot; its actions in the bar.

///|
/// The place `place` at the stack's root over the made-up workspace, a phone's bars said (24 over, 48 under), in a
/// window short enough for its list to scroll.
fn place_tester(place : String) -> @ui.Tester {
  new_run()
  let base = fixture("home")
  let src = if place == "stations" {
    // The compact 2-line stations list fits two stations in 520pt; add enough stations after Willow so the list
    // overflows the short window and scrolls under its frosted top bar.
    {
      ..base,
      topic_read: fn(name, params) {
        let r = base.topic(name, params).get().snapshot()
        if name == "stations" {
          match r.value {
            Some(Array(rows)) if rows.length() >= 2 => {
              let more = rows.copy()
              for i in 0..<6 {
                more.push(
                  Json::object({
                    "station": Json::string("ws1/extra-\{i}"),
                    "id": Json::string("extra-\{i}"),
                    "name": Json::string("Pine-\{i}"),
                    "summary": Json::string("离线 · 3 天前"),
                    "online": Json::boolean(false),
                  }),
                )
              }
              { ..r, value: Some(Json::array(more)) }
            }
            _ => r
          }
        } else {
          r
        }
      },
    }
  } else {
    base
  }
  app.nav.replace(Place(place))
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=520.0, platform=2)
  t.post(@hostapi.system_channel, "{\"bars\":{\"top\":24,\"bottom\":48,\"left\":0,\"right\":0}}")
  t.frame()
  t
}

///|
test "a place's page: from under its frosted top bar, scrolled on under it, not cut off at its foot" {
  let t = place_tester("stations")
  // the bar spans from the page's top over the status bar to its foot (24 + 50) with floating liquid glass pill controls
  let glass = t.drawn_glass()
  let tree = @ui.view_tree().unwrap()
  if !tree.drawn().iter().any(fn(d) { (d.ground != 0L || d.glass is Some(_)) && d.x == 0.0 && d.y == 0.0 && d.w == 390.0 && d.h >= 24.0 + 50.0 }) {
    fail("no top bar scrim spanning status bar")
  }
  if !glass.iter().any(fn(g) { g.4 == 6 && g.1 >= 24.0 && g.1 + g.3 <= 24.0 + 50.0 }) {
    fail("no liquid glass pill in top bar: \{Repr(glass)}")
  }
  // its first station as it opens: under the bar, 8 down in its card
  let y0 = match t.rect_of("Willow") {
    Some((_, y, _, _)) => y
    None => fail("no Willow")
  }
  assert_true(y0 > 24.0 + 50.0)
  // scrolled 60: the cards go on under the bar; pressed on its glass (beside the title, on none of the bar's buttons)
  // it is the bar's, what is under it out of sight there (mbui's Node::covers: the page made once as nodes); pressed
  // under the bar, the first card's (Willow's), which opens its station
  t.move_to(195.0, 300.0)
  t.wheel(195.0, 300.0, 60.0)
  let y1 = match t.rect_of("Willow") {
    Some((_, y, _, _)) => y
    None => fail("no Willow scrolled")
  }
  if (y0 - y1 - 60.0).abs() >= 0.5 {
    fail("Willow at \{y0}, scrolled at \{y1}")
  }
  assert_eq(app.nav.depth(), 1)
  t.tap(300.0, 60.0)
  t.frame()
  assert_eq(app.nav.depth(), 1)
  t.tap(300.0, 24.0 + 50.0 + 30.0)
  t.frame()
  assert_eq(@sf.presenting(), false)
  assert_eq(app.nav.depth(), 2)
}

///|
test "a page's name kept whole: 用量's share and days as wide as they are after it, giving way where its line has not the room (Usage on a 360 phone, its place's bar and the page from settings, the system's words 1, 1.3, 1.6)" {
  for from_settings in [false, true] {
    for fs in [1.0, 1.3, 1.6] {
      new_run()
      let src = if from_settings {
        fixture_app("settings-usage")
      } else {
        let s = fixture("home")
        app.nav.replace(Place("usage"))
        s
      }
      let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=360.0, h=640.0, env=[("MBUI_LOCALE", "en-US")], platform=2)
      t.set_font_scale(fs)
      t.post(@hostapi.system_channel, "{\"bars\":{\"top\":24,\"bottom\":48,\"left\":0,\"right\":0}}")
      t.run_for(@ui.move_most_ms)
      t.frame()
      let at = "\{if from_settings { "from settings" } else { "the place's bar" }}, words \{fs}"
      // (2026-10-26 用户's phone: 「Us…」, the days filling half the line beside it)
      let cut = t.beside_faults()
      if cut.length() > 0 {
        fail("\{at}: \{Repr(cut)}")
      }
      let faults = t.squeeze_faults()
      if faults.length() > 0 {
        fail("\{at}: \{Repr(faults)}")
      }
      // (the name: the largest words saying it)
      let mut title = (0.0, 0.0, 0.0, 0.0)
      for w in t.words() {
        if w.0 == "Usage" && w.4 > title.3 {
          title = (w.1, w.2, w.3, w.4)
        }
      }
      if title.3 <= 0.0 {
        fail("\{at}: no Usage")
      }
      // the share and the days after the name, on its line, in the window
      let (x, y, w, h) = t.get(Button, label="Share card").rect
      if x < title.0 + title.2 || (y + h / 2.0 - (title.1 + title.3 / 2.0)).abs() >= 1.0 || x + w > 360.0 {
        fail("\{at}: Share card at \{Repr((x, y, w, h))}, Usage at \{Repr(title)}")
      }
      match t.rect_of("7 days") {
        Some((x, y, w, _)) =>
          if from_settings {
            if y < title.1 + title.3 || x < 0.0 || x + w > 360.0 {
              fail("\{at}: 7 days at \{x}, \{y}, \{w}, Usage at \{Repr(title)}")
            }
          } else if x < title.0 + title.2 || x + w > 360.0 {
            fail("\{at}: 7 days at \{x}, \{w}, Usage at \{Repr(title)}")
          }
        None => fail("\{at}: no 7 days")
      }
    }
  }
}

///|
test "a place's page: its actions in its top bar, at the end of the title's line (用量's days)" {
  let t = place_tester("usage")
  // the middle of the bar's line under the status bar: 24 + 8 + 34 / 2 (its choice's words, not the page's that say
  // the days: 比前 7 天)
  match t.words().search_by(fn(w) { w.0 == "7 天" && w.5 > 0.5 }) {
    Some(i) => {
      let (_, x, y, w, h, _) = t.words()[i]
      let (x, y) = (x + w / 2.0, y + h / 2.0)
      if (y - 49.0).abs() >= 0.5 || x <= 195.0 {
        fail("7 天 at (\{x}, \{y})")
      }
    }
    None => fail("no 7 天")
  }
}
