// Adding a profile on the desktop (sfpages new_profile.mbt, a wide page), a secret's page, a place's first,
// over the whole app and the settings' fixture (a profile's own page: src/sfpages accounts_wbtest.mbt).

///|
test "wide: the profile list's rows say an account's name, its plan and its allowance; the plan leaves before the name is cut" {
  // (its plan right after its name, 8 apart, on its line; the plan the first to leave where the sidebar has not the room
  // for both, the name never cut short for it: the user, 2026-11-14 and 2026-11-17 「侧栏加回套餐，窄了先收起」; where
  // it can be used and who uses it are the account's page's)
  let t = wide_tester([], mode="settings", w=1440.0)
  app.nav.replace(Place("profiles"))
  t.draw()
  let side = t.text_runs().filter(fn(r) { r.x0 < 300.0 })
  let names = side.filter(fn(r) { r.text == "Claude 主账号" })
  let plans = side.filter(fn(r) { r.text == "Ultra" })
  assert_eq(names.length(), 1, msg="\{Repr(side.map(fn(r) { r.text }))}")
  assert_eq(plans.length(), 1, msg="\{Repr(side.map(fn(r) { r.text }))}")
  let (name, plan) = (names[0], plans[0])
  assert_true(plan.x0 > name.x1 && plan.x0 - name.x1 < 12.0, msg="name \{Repr(name)}, plan \{Repr(plan)}")
  assert_true(plan.top < name.bottom && plan.bottom > name.top, msg="on the name's line: \{Repr(name)}, \{Repr(plan)}")
  assert_true(side.iter().all(fn(r) { !r.text.contains("可用") }), msg="\{Repr(side.map(fn(r) { r.text }))}")
  // (a station's own login offered under them: its plan after its runtime the same way)
  let codex = side.filter(fn(r) { r.text == "Codex" })
  let plus = side.filter(fn(r) { r.text == "Plus" })
  assert_true(codex.length() == 1 && plus.length() == 1, msg="\{Repr(side.map(fn(r) { r.text }))}")
  assert_true(plus[0].x0 > codex[0].x1 && plus[0].x0 - codex[0].x1 < 12.0, msg="\{Repr(codex)}, \{Repr(plus)}")
  // (what the rules find of its name and its plan: none)
  let faults = t.audit().filter(fn(f) { f.contains("Ultra") || f.contains("Claude 主账号") })
  assert_true(faults.is_empty(), msg="\{Repr(faults)}")
}

///|
test "wide: an account's plan leaves the sidebar's row before its name is cut short" {
  // (a name as long as an account's email in a sidebar with not the room for it and its plan: the plan goes, the name
  // keeps what room there is)
  let t = wide_tester([], mode="settings", w=1440.0, before=fn(_) {
    @settings.fixture_page("settings-profiles-long-name") |> ignore
  })
  app.nav.replace(Place("profiles"))
  t.draw()
  // (a run's words as they are, cut short or not: by where they start)
  let side = t.text_runs().filter(fn(r) { r.x0 < 300.0 })
  assert_true(side.iter().all(fn(r) { r.text != "Ultra" }), msg="\{Repr(side.map(fn(r) { r.text }))}")
  assert_true(side.iter().any(fn(r) { r.text.has_prefix("someone.with") }), msg="\{Repr(side.map(fn(r) { r.text }))}")
}

///|
test "deleting a profile or removing a station in its place stays in the place instead of going back to the previous page; pushed on the stack, its page closes" {
  // 1. 大屏 Place("profiles") come to from a chat: history holds the chat behind it, deleting a profile stays in Place("profiles")
  new_run()
  let deleted : @signals.Signal[Array[String]] = @signals.signal([])
  let calls : Array[(String, Json)] = []
  let base = fixture("settings")
  let drop_profiles = fn(v : Json, gone : Array[String]) -> Json {
    if gone.is_empty() {
      return v
    }
    match v {
      Object(o) => {
        let copy = o.copy()
        if copy.get("items") is Some(Array(items_arr)) {
          copy["items"] = Json::array(
            items_arr.filter(fn(e) { !gone.contains(text(field(Some(e), "profile"), "id")) }),
          )
        }
        if copy.get("profiles") is Some(Array(ps)) {
          copy["profiles"] = Json::array(ps.filter(fn(p) { !gone.contains(text(Some(p), "id")) }))
        }
        if copy.get("overview") is Some(ov) {
          match ov {
            Object(oo) => {
              let ocopy = oo.copy()
              if ocopy.get("profiles") is Some(Array(ps)) {
                ocopy["profiles"] = Json::array(ps.filter(fn(p) { !gone.contains(text(Some(p), "id")) }))
              }
              copy["overview"] = Json::object(ocopy)
            }
            _ => ()
          }
        }
        Json::object(copy)
      }
      _ => v
    }
  }
  let src : Source = {
    ..base,
    topic_read: fn(name, params) {
      let r = base.topic(name, params).get().snapshot()
      let gone = deleted.get()
      if name == "profiles" || name == "station" {
        { ..r, value: r.value.map(fn(v) { drop_profiles(v, gone) }) }
      } else {
        r
      }
    },
    call: fn(name, params, done) {
      calls.push((name, params))
      if name == "profile.delete" {
        let id = text(Some(params), "id")
        deleted.set([..deleted.untracked(), id])
        done(Ok(Json::object({})))
      } else if name == "workspace.removeStation" {
        done(Ok(Json::object({})))
      } else {
        (base.call)(name, params, done)
      }
    },
  }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  t.run_for(@ui.move_most_ms)
  assert_true(app.nav.top() is Chat(_))
  @sfbase.go_place("profiles") |> ignore
  t.run_for(@ui.move_most_ms)
  assert_true(app.nav.pages() == [Place("profiles")])
  // Pick ChatGPT 团队 in the sidebar, then delete it: stays on Place("profiles"), moves to the remaining profile
  t.tap_text("ChatGPT 团队")
  t.run_for(@ui.move_most_ms)
  t.click(Button, label="更多")
  t.run_for(@ui.move_most_ms)
  t.tap_text("删除 Profile")
  t.run_for(@ui.move_most_ms)
  t.click(Button, label="删除 Profile")
  t.run_for(@ui.move_most_ms)
  assert_true(
    app.nav.pages() == [Place("profiles")],
    msg="stayed in Place(profiles), depth=\{app.nav.depth()}",
  )
  assert_eq(calls.filter(fn(c) { c.0 == "profile.delete" && text(Some(c.1), "id") == "cx" }).length(), 1)
  assert_true(t.find("备用 key") is Some(_), msg="switched to the first remaining profile")

  // 2. Pushed Setting(Profile(...)) on the stack: deleting it closes that page back to what was under it
  @sfbase.open_page(Setting(@settings.Route::Profile("ws1/st1", "cc")))
  t.run_for(@ui.move_most_ms)
  assert_true(app.nav.top() == Setting(@settings.Route::Profile("ws1/st1", "cc")))
  t.click(Button, label="更多")
  t.run_for(@ui.move_most_ms)
  t.tap_text("删除 Profile")
  t.run_for(@ui.move_most_ms)
  t.click(Button, label="删除 Profile")
  t.run_for(@ui.move_most_ms)
  assert_true(
    app.nav.pages() == [Place("profiles")],
    msg="pushed Profile page closed back to Place(profiles), depth=\{app.nav.depth()}",
  )
  assert_eq(calls.filter(fn(c) { c.0 == "profile.delete" && text(Some(c.1), "id") == "cc" }).length(), 1)

  // 3. 大屏 Place("stations") come to from Place("profiles"): removing a station stays in Place("stations")
  @sfbase.go_place("stations") |> ignore
  t.run_for(@ui.move_most_ms)
  assert_true(app.nav.pages() == [Place("stations")])
  t.click(Button, label="更多")
  t.run_for(@ui.move_most_ms)
  t.tap_text("从 workspace 移除")
  t.run_for(@ui.move_most_ms)
  t.click(Button, label="移除 station")
  t.run_for(@ui.move_most_ms)
  assert_true(
    app.nav.pages() == [Place("stations")],
    msg="stayed in Place(stations), depth=\{app.nav.depth()}",
  )
  assert_eq(calls.filter(fn(c) { c.0 == "workspace.removeStation" }).length(), 1)
}

///|
/// The desk's page wheeled down until `words` shows on it (above the window's foot).
fn desk_shown(t : @ui.Tester, words : String) -> Unit {
  t.move_to(800.0, 400.0)
  for _ in 0..<12 {
    match t.find(words) {
      Some((_, y)) if y < 760.0 => break
      _ => t.wheel(800.0, 400.0, 300.0)
    }
  }
}

///|
test "wide: Anthropic authorization in either browser waits for confirmation" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="settings-new-profile-login-station")
  @settings.fixture_page("settings-new-profile-login-station") |> ignore
  t.draw()
  app.nav.push(Setting(@settings.Route::NewProfile("ws1/st1")))
  t.run_for(@ui.move_most_ms)
  t.click(Button, label="打开授权页面")
  sheet_rested(t, "sf-present")
  assert_true(t.find("请确认登录环境") is Some(_))
  assert_true(t.find(@sf.t("common.login.confirmClaudeWarning")) is Some(_))
  assert_true(t.opened().is_empty())
  t.back()
  sheet_rested(t, "sf-present")
  t.click(Button, label="在 Willow 的浏览器中打开")
  sheet_rested(t, "sf-present")
  assert_true(t.find("请确认登录环境") is Some(_))
  assert_true(t.find(@sf.t("common.login.confirmClaudeWarning")) is Some(_))
  assert_true(named(calls, "login.browser").is_empty())
  t.tap_text("确认并登录")
  assert_eq(named(calls, "login.browser").length(), 1)
}

///|
test "station browser button sits beside 打开授权页面 and wraps cleanly at default and 1.3x words" {
  for mode in ["settings-profile-login-station", "settings-new-profile-login-station"] {
    for lang in ["zh", "en"] {
      let label = if lang == "zh" { "在 Willow 的浏览器中打开" } else { "Open in Willow's browser" }
      for win in corner_windows {
        let t = screen_in(mode, win, lang)
        assert_true(t.query(Button, label~) is Some(_), msg="\{win.0}-\{lang} \{mode}")
        assert_eq(t.squeeze_faults() + t.words_over_now() + t.fixed_outgrown(), [], msg="\{win.0}-\{lang} \{mode}")
      }
      guard corner_windows.search_by(w => w.0 == "phone") is Some(i) else { fail("no phone window") }
      let t_large = screen_in(mode, corner_windows[i], lang, font_scale=words_large_scale)
      assert_true(t_large.query(Button, label~) is Some(_), msg="phone-\{lang}-1.3 \{mode}")
      assert_eq(t_large.squeeze_faults() + t_large.words_over_now() + t_large.fixed_outgrown(), [], msg="phone-\{lang}-1.3 \{mode}")
    }
  }
}

///|
test "wide: adding a profile picks its provider from the core's groups, the machine's own login offered first" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="settings")
  t.draw()
  app.nav.push(Setting(@settings.Route::NewProfile("ws1/st1")))
  t.run_for(@ui.move_most_ms)
  // the core's step: its title and hint, its groups and their providers
  assert_true(t.find("选择服务商") is Some(_))
  assert_true(t.find("模型厂商") is Some(_) && t.find("中转站") is Some(_))
  assert_true(t.find("OpenRouter") is Some(_))
  // Willow's own Codex login, used as it is
  assert_true(t.find("使用此账号") is Some(_), msg="the machine's login offered")
  // a provider picked: told to the core
  match t.find("DeepSeek") {
    Some((x, y)) => t.tap(x, y)
    None => @halt.saying("no DeepSeek")
  }
  t.draw()
  assert_true(
    calls.iter().any(fn(m) { m.name == "profile.flow.edit" && text(field(Some(m.params), "input"), "provider") == "deepseek" }),
    msg="the provider told to the core",
  )
}

///|
test "wide: Command Code and Open Design are offered among the gateways with marks of their own" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="settings")
  t.draw()
  app.nav.push(Setting(@settings.Route::NewProfile("ws1/st1")))
  t.run_for(@ui.move_most_ms)
  for name in ["Command Code", "Open Design"] {
    assert_true(t.find(name) is Some(_), msg="\{name} offered")
  }
  // (their marks drawn from their own drawables, in the page's ink)
  for mark in ["maker_command_code", "maker_open_design"] {
    assert_true(@sf.has_drawable(mark), msg="\{mark} registered")
  }
  // (what the rules find of their tiles: none)
  let faults = t.audit().filter(fn(f) { f.contains("Command Code") || f.contains("Open Design") || f.contains("中转站") })
  assert_true(faults.is_empty(), msg="\{Repr(faults)}")
  match t.find("Command Code") {
    Some((x, y)) => t.tap(x, y)
    None => @halt.saying("no Command Code")
  }
  t.draw()
  assert_true(
    calls.iter().any(fn(m) { m.name == "profile.flow.edit" && text(field(Some(m.params), "input"), "provider") == "command-code" }),
    msg="the provider told to the core",
  )
}

///|
test "wide: the station's Hermes profile can be selected from its custom variables" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="settings-new-profile-hermes")
  t.draw()
  app.nav.push(Setting(@settings.Route::NewProfile("ws1/st1")))
  t.run_for(@ui.move_most_ms)
  desk_shown(t, "Hermes Agent")
  match t.find("Hermes Agent") {
    Some((x, y)) => t.tap(x, y)
    None => @halt.saying("no Hermes Agent")
  }
  t.draw()
  assert_true(
    calls.iter().any(fn(m) { m.name == "profile.flow.edit" && text(field(Some(m.params), "input"), "provider") == "env-hermes" }),
    msg="the selected Hermes profile told to the core",
  )
}

///|
test "wide: Google Vertex AI way shows and pasting multi-line service account JSON reaches profile.flow.edit intact" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="settings-new-profile-google-vertex-ways")
  t.draw()
  app.nav.push(Setting(@settings.Route::NewProfile("ws1/st1")))
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("Vertex AI") is Some(_), msg="Vertex AI way shown")
  let ways_audit = t.audit().filter(fn(f) { f.contains("new_profile") || f.contains("ways") || f.contains("field_node") })
  let ways_msg = ways_audit.join("; ")
  assert_eq(ways_audit + t.squeeze_faults() + t.words_over_now() + t.fixed_outgrown(), [], msg="vertex ways audit: \{ways_msg}")
  match t.find("Vertex AI") {
    Some((x, y)) => t.tap(x, y)
    None => @halt.saying("no Vertex AI")
  }
  t.draw()
  assert_true(
    calls.iter().any(fn(m) { m.name == "profile.flow.edit" && text(field(Some(m.params), "input"), "method") == "vertex" }),
    msg="choosing vertex tells the core",
  )

  let calls2 : Array[Made] = []
  let t2 = wide_tester(calls2, mode="settings-new-profile-google-vertex-key")
  t2.draw()
  app.nav.push(Setting(@settings.Route::NewProfile("ws1/st1")))
  t2.run_for(@ui.move_most_ms)
  assert_true(t2.find("服务账号密钥（JSON）") is Some(_), msg="vertex key label shown")
  let key_audit = t2.audit().filter(fn(f) { f.contains("new_profile") || f.contains("ways") || f.contains("field_node") })
  let key_msg = key_audit.join("; ")
  assert_eq(key_audit + t2.squeeze_faults() + t2.words_over_now() + t2.fixed_outgrown(), [], msg="vertex key audit: \{key_msg}")
  let sa = "{\n  \"type\": \"service_account\",\n  \"project_id\": \"demo-proj\",\n  \"client_email\": \"bot@demo-proj.iam.gserviceaccount.com\",\n  \"private_key\": \"-----BEGIN PRIVATE KEY-----\\nabc\\n-----END PRIVATE KEY-----\\n\"\n}"
  match t2.find(@sf.t("android-settings.profile.keyPlaceholder")) {
    Some((x, y)) => {
      t2.tap(x, y)
      t2.paste(sa)
    }
    None => @halt.saying("no key placeholder")
  }
  t2.draw()
  let sent = calls2.filter(fn(m) { m.name == "profile.flow.edit" && field(field(Some(m.params), "input"), "key") is Some(_) })
  assert_true(sent.length() > 0, msg="pasting multi-line JSON sent profile.flow.edit")
  let got = text(field(Some(sent[sent.length() - 1].params), "input"), "key")
  assert_eq(got, sa, msg="multi-line JSON reached profile.flow.edit verbatim")
  let parsed = @json.parse(got) catch { _ => @halt.saying("pasted key did not parse as JSON") }
  assert_eq(text(Some(parsed), "type"), "service_account")
  assert_eq(text(Some(parsed), "project_id"), "demo-proj")
}

///|
test "wide: a secret's page says what it is, how agents may get it and when they did, its content masked until opened" {
  let t = wide_tester([], mode="settings")
  t.draw()
  app.nav.push(Setting(@settings.Route::VaultItem("v1", "it1")))
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("GitHub token") is Some(_))
  // the core's words of it
  assert_true(t.find("代理 · 限 api.github.com") is Some(_), msg="how it is given")
  assert_true(t.find("跟随默认 · 直到对话归档") is Some(_), msg="its longest grant")
  assert_true(t.find("git push origin main · 代理") is Some(_), msg="a use, how")
  // not opened: its field's name over dots
  assert_true(t.find("值") is Some(_))
  assert_true(t.find("ghp_") is None, msg="nothing of it shown")
}

///|
test "wide: the Station place with none in the workspace is the first to add, not a phone's page" {
  let t = wide_tester([], mode="settings-first-station")
  t.draw()
  app.nav.replace(Place("stations"))
  t.run_for(@ui.move_most_ms)
  // its scene and its one thing to do (the sidebar's 添加 station too)
  assert_true(t.find_last("添加 station") is Some(_))
}

///|
/// The profiles' place opened on 大屏 by touch (a tablet's window), a profile's page in its pane as it opens: the pane's
/// coming reads the layout for its size before any frame, and the page's blocks, made as that layout comes to them,
/// each read theirs. Begun inside it, that second layout left what the first laid out unplaced (mbui's
/// Tree::measured_now, #5245, whose own ways in were a phone's): the page's head and its sections' titles drawn where
/// and as big as whatever had their nodes before, a title 18 wide a letter a line. With a mouse a change is laid out as
/// it ends, for what is under the pointer, so the same steps there read no layout still to be done. Every frame is held
/// placed as laid out (Tester::hold_placed); said here of the first as well.
test "wide, by touch: the profiles' place opens on a page placed as it is laid out" {
  let t = wide_tester([], mode="settings-profile-fable", w=1100.0, h=700.0, platform=2)
  @settings.fixture_page("settings-profile-fable") |> ignore
  app.nav.replace(Place("profiles"))
  t.draw()
  assert_eq(t.placed_faults(), [])
  assert_true(t.find("额度与恢复") is Some(_))
  t.tap_text("Claude 主账号")
  t.run_for(@ui.move_most_ms)
  assert_eq(t.placed_faults(), [])
  // (its sections' titles each across the page's column, none in a box of a few points)
  for words in ["设置"] {
    let wide = t.words().filter(fn(w) { w.0 == words }).map(fn(w) { w.3 })
    assert_true(wide.length() == 1 && wide[0] > 200.0, msg="\{words}: \{Repr(wide)} wide")
  }
}

///|
test "wide: a machine's login not made a profile yet shows its allowance in the profiles' sidebar" {
  // (the fixture's place-profiles-offer, as sffix opens it; the Tester opens the place itself)
  let t = wide_tester([], mode="settings")
  @settings.fixture_page("settings-profiles-offer") |> ignore
  app.nav.replace(Place("profiles"))
  t.draw()
  // Willow's own Codex login, last in the sidebar: its week's capsule under its row as a profile's row has it
  let side = fn() { t.text_runs().filter(fn(r) { r.x0 < 300.0 }) }
  let offered = side().filter(fn(r) { r.text == "使用此账号" })
  assert_eq(offered.length(), 1, msg="the machine's login offered: \{Repr(side().map(fn(r) { r.text }))}")
  let under = side().filter(fn(r) { r.top >= offered[0].bottom }).map(fn(r) { r.text })
  for words in ["5h", "62%", "W", "19%"] {
    assert_true(under.contains(words), msg="\{words} under the offered login: \{Repr(under)}")
  }
  assert_eq(t.squeeze_faults(), [])
}

///|
/// How late the made-up core answers each call and every subscription as another station is pressed on the add page
/// (ms): at once, a frame late, and on to well past the 300 ms nothing may look like loading in.
let station_press_lates : Array[Double] = [0.0, 16.0, 120.0, 250.0, 400.0, 700.0]

///|
/// The add page's hint (the core's `hint`, its lead under its title), the same for each station in the fixture.
let station_press_hint : String = "订阅和 API key 都在这里添加"

///|
/// How long after the press the page is at rest, over a core answering `ms` late: its answer, the page come, and a
/// motion's most after it, twice.
fn station_press_rest_ms(ms : Double) -> Double {
  ms * 4.0 + @ui.move_most_ms * 2.0
}

///|
/// The add page on Willow (ws1/st1) in screen `s`, three stations online, over the settings' fixture whose core answers
/// each call and every subscription as late as `pace` says when it is asked (the page opened at once, the test's own
/// setup), as a device's host draws it (check_looks off), at rest: what it was asked told to `heard`, the calls made to
/// `calls`.
fn station_press_tester(s : Screen, pace : Ref[Double], heard : Array[String], calls : Array[(String, Json)]) -> @ui.Tester {
  new_run()
  let base = fixture_app("settings-new-profile-stations")
  let counted : Source = {
    ..base,
    call: fn(name, params, done) {
      calls.push((name, params))
      (base.call)(name, params, done)
    },
  }
  let src = round_trip_again(round_trip_by(counted, fn() { pace.val }), 0.0, heard=fn(h) { heard.push(h) }, late=fn(_, _) {
    pace.val
  })
  if !(app.nav.top() is Setting(NewProfile("ws1/st1"))) {
    app.nav.push(Setting(@settings.Route::NewProfile("ws1/st1")))
  }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=s.w, h=s.h, platform=s.platform)
  t.check_looks(false)
  t.draw()
  t.run_for(@ui.move_most_ms + 1000.0)
  t.ways_set_out() |> ignore
  t
}

///|
/// Station `name` shown chosen on the page's choice now.
fn station_chosen(t : @ui.Tester, name : String) -> Bool {
  t.query(Radio, label=name, checked=On) is Some(_)
}

///|
/// The words drawn now, each with where it is drawn (to a tenth of a point), but those of the stations' choice (each
/// station's name alone: its own answer to the hand, aside), in the order drawn.
fn station_press_words(t : @ui.Tester) -> Array[String] {
  t
  .words()
  .filter(fn(w) { w.5 > 0.01 && !["Willow", "Maple", "Cedar"].contains(w.0) })
  .map(fn(w) { "\{w.0} @\{(w.1 * 10.0).round() / 10.0},\{(w.2 * 10.0).round() / 10.0}" })
}

///|
/// Station `to` (its name, its address) pressed on the add page of station `from` (its address) in `t`, over a core
/// answering `ms` late from the press: from the press till the page is at rest, the page is drawn in two ways only: as
/// it was at the press but for the choice, till `to`'s page comes, then as it rests, from the frame it comes in; in
/// every frame nothing sets out after the press's own moment, the hint is drawn, no bones more than at the press, `to`
/// shown chosen. At rest the page is `to`'s, its draft opened once and what it reads as it is first made asked once
/// from the press and held (new_profile.mbt's new_profile_asks: its flow, its station).
fn station_pressed(
  t : @ui.Tester,
  at : String,
  heard : Array[String],
  calls : Array[(String, Json)],
  from : String,
  to : (String, String),
  ms : Double,
) -> Unit raise {
  let at = "\{at}, to \{to.0}"
  let (name, address) = to
  let bones_before = t.bones_drawn()
  let pressed_words = station_press_words(t)
  let target = match t.query(Radio, label=name) {
    Some(r) => r
    None => @halt.saying("\{at}: no \{name} to press")
  }
  let heard_from = heard.length()
  let calls_from = calls.length()
  let start = t.time()
  t.tap(target.rect.0 + target.rect.2 / 2.0, target.rect.1 + target.rect.3 / 2.0)
  let faults : Array[String] = []
  let ways : Array[String] = []
  // (each frame after the page came: when, and its words)
  let after : Array[(Double, Array[String])] = []
  let mut came = -1.0
  let frames = (station_press_rest_ms(ms) / @ui.frame_period_default).ceil().to_int()
  for i in 0..=frames {
    if i > 0 {
      t.run_for(@ui.frame_period_default)
    }
    let now = t.time() - start
    for w in t.ways_set_out() {
      if w.at > start + 0.5 {
        ways.push("\{w.kind} +\{(w.at - start).round()} ms \{w.made} \{w.part}")
      }
    }
    let waiting = app.nav.top() is Setting(NewProfile(f)) && f == from
    if !waiting && came < 0.0 {
      came = now
    }
    let words = station_press_words(t)
    if waiting {
      if words != pressed_words {
        faults.push("+\{now.round()} ms, waiting: words not as at the press: \{Repr(words)}, then \{Repr(pressed_words)}")
      }
    } else {
      after.push((now, words))
    }
    if t.find(station_press_hint) is None {
      faults.push("+\{now.round()} ms: no hint drawn (\{if waiting { "waiting" } else { "come" }})")
    }
    if t.bones_drawn() > bones_before {
      faults.push("+\{now.round()} ms: \{t.bones_drawn()} bones drawn, \{bones_before} before the press")
    }
    if !station_chosen(t, name) {
      faults.push("+\{now.round()} ms: \{name} not shown chosen")
    }
  }
  let rest = match after.last() {
    Some((_, w)) => w
    None => []
  }
  for f in after {
    if f.1 != rest {
      faults.push("+\{f.0.round()} ms, come: words not as at rest: \{Repr(f.1)}, at rest \{Repr(rest)}")
    }
  }
  println("STATION_PRESS \{at}: the page at +\{came.round()} ms, ways after the press \{Repr(ways)}")
  assert_eq(faults, [], msg="\{at}: every frame from the press")
  assert_eq(ways, [], msg="\{at}: ways set out after the press")
  assert_true(app.nav.top() is Setting(NewProfile(a)) && a == address, msg="\{at}: its page at rest")
  let opened = calls[calls_from:].to_owned().filter(fn(c) { c.0 == "profile.flow.open" && text(Some(c.1), "station") == address })
  assert_eq(opened.length(), 1, msg="\{at}: its draft opened: \{Repr(opened.map(fn(c) { c.1.stringify() }))}")
  let form = text(Some(opened[0].1), "form")
  let since = heard[heard_from:].to_owned()
  assert_eq(
    asked_held(since, "profileFlow", { "station": Json::string(address), "form": Json::string(form) }),
    (1, 0),
    msg="\{at}: its flow asked and let go",
  )
  assert_eq(
    asked_held(since, "station", { "scope": Json::string("ws1"), "station": Json::string(address) }),
    (1, 0),
    msg="\{at}: its station asked and let go",
  )
}

///|
/// Another station pressed on the add page (大屏 with a mouse, 小屏 by touch), and back, the page opened over a core
/// answering at once and each press over one answering 0 to 700 ms late, each frame held steady too
/// (sizes_steady.mbt): from Willow, whose machine's own logins are offered over the providers, to Maple, which has
/// none, and back to Willow (station_pressed: the page drawn as it was at the press, then as it rests, nothing else).
test "the add page's station choice opens the other station's page whole, the page as it was meanwhile" {
  for s in [daily_large, daily_small] {
    for ms in station_press_lates {
      let at = "\{s.name}, \{ms} ms"
      let heard : Array[String] = []
      let calls : Array[(String, Json)] = []
      let pace = Ref(0.0)
      let t = station_press_tester(s, pace, heard, calls)
      pace.val = ms
      assert_true(station_chosen(t, "Willow"), msg="\{at}: Willow chosen at first")
      assert_true(t.find(station_press_hint) is Some(_), msg="\{at}: the hint at first")
      assert_true(t.find("使用此账号") is Some(_), msg="\{at}: Willow's machine's login offered")
      station_pressed(t, at, heard, calls, "ws1/st1", ("Maple", "ws1/st2"), ms)
      assert_true(t.find("使用此账号") is None, msg="\{at}: none of Maple's offered")
      station_pressed(t, at, heard, calls, "ws1/st2", ("Willow", "ws1/st1"), ms)
      assert_true(t.find("使用此账号") is Some(_), msg="\{at}: Willow's offered again")
    }
  }
}

///|
test "profiles overview: wide defaults to 概览 with pool switching; narrow defaults to 账号 and switches to 概览" {
  // 1. Wide defaults to 概览 with both charts and switches between model pools and individual accounts
  let t_wide = wide_tester([], mode="place-profiles-sum-a")
  @settings.fixture_page("settings-profiles-sum-a") |> ignore
  app.nav.replace(Place("profiles"))
  t_wide.run_for(@ui.move_most_ms)
  assert_true(t_wide.find("额度与恢复") is Some(_))
  assert_true(t_wide.find("消耗速度") is Some(_))
  // (the tightest pool first: Claude's, going without in 12 hours, spending 1.8%/h over what it could keep up, its last
  // and next 24 hours each against that, either way from 0)
  assert_true(t_wide.find("18% · 12h后断档") is Some(_))
  assert_true(t_wide.find("-1.8%/h") is Some(_))
  assert_true(t_wide.find("+4%/h") is Some(_) && t_wide.find("-4%/h") is Some(_))
  assert_true(t_wide.find("-24h") is Some(_) && t_wide.find("+24h") is Some(_) && t_wide.find("-12h") is Some(_))
  assert_true(t_wide.find("3 项需处理") is Some(_))
  assert_true(t_wide.find("重新登录") is Some(_))
  assert_true(t_wide.find("更换 key") is Some(_))
  // (alerts are virtualized one row per block: scroll down so the 3rd row enters the viewport, then return to top)
  t_wide.wheel(640.0, 400.0, 160.0)
  // (why jiachen@cue.surf is there: its week's allowance mostly unused, gone when the week resets)
  assert_true(t_wide.find("周额度剩 84% 未用 · 14h后重置清零") is Some(_))
  t_wide.wheel(640.0, 400.0, -160.0)
  t_wide.run_for(@ui.scrollbar_fade_ms)
  // (Claude's pool going without: how many more of its plan would keep it going, under its charts)
  assert_true(t_wide.find("按当前消耗速度，还需约 ") is Some(_))
  assert_true(t_wide.find("个同档账号才能不断档") is Some(_))
  assert_eq(t_wide.corner_faults(), [])
  assert_eq(t_wide.lit_all_faults(), [])
  assert_eq(t_wide.room_faults(), [])
  assert_eq(t_wide.hover_only_faults(), [])
  assert_eq(t_wide.height_faults(), [])
  assert_eq(t_wide.first_line_faults(), [])
  assert_eq(t_wide.line_start_faults(), [])
  assert_eq(t_wide.fixed_outgrown(), [])
  assert_eq(t_wide.hand_moves(), [])
  assert_eq(t_wide.squeeze_faults(), [])
  t_wide.click(Button, label="Codex 2/3")
  t_wide.draw()
  assert_true(t_wide.find("72%") is Some(_))
  assert_true(t_wide.find("+0.6%/h") is Some(_))
  assert_true(t_wide.find("18% · 12h后断档") is None)
  // (Codex's keeps up: nothing said of more accounts, gone as it is picked)
  assert_true(t_wide.find("个同档账号才能不断档") is None)
  t_wide.tap_text("ChatGPT 团队")
  t_wide.run_for(@ui.move_most_ms)
  assert_true(t_wide.find("额度与恢复") is None)
  t_wide.tap_text("概览")
  t_wide.run_for(@ui.move_most_ms)
  assert_true(t_wide.find("额度与恢复") is Some(_))

  // 2. Narrow Place("profiles") (bottom bar) and Setting(Profiles("")) (from settings):
  //    - 账号 | 概览 has 12px page inset on both sides (not flush to 0..w)
  //    - Place("profiles") switches to 概览 and back with zero jump on the segmented control and remembers 概览 across shelf switches
  //    - Setting(Profiles("")) pushed over Place("profiles") keeps compact nav_bar with zero header jump and does not clobber Place("profiles")
  new_run()
  let src = fixture_app("place-profiles-sum-a")
  let t_phone = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t_phone.run_for(@ui.move_most_ms)
  assert_true(t_phone.find("Claude 主账号") is Some(_))
  assert_true(t_phone.find("额度与恢复") is None)
  let acc_radio_0 = t_phone.all(Radio, label="账号")[0].rect
  let ov_radio_0 = t_phone.all(Radio, label="概览")[0].rect
  assert_true(acc_radio_0.0 >= 12.0, msg="place accounts radio inset from left edge: \{acc_radio_0.0}")
  assert_true(ov_radio_0.0 + ov_radio_0.2 <= 390.0 - 12.0, msg="place overview radio inset from right edge: \{ov_radio_0.0 + ov_radio_0.2}")
  let thumb_x = fn() {
    t_phone.drawn_rects().iter().find_first(fn(r) {
      (r.1 - acc_radio_0.1).abs() < 0.5 &&
      (r.2 - acc_radio_0.2).abs() < 0.5 &&
      (r.3 - acc_radio_0.3).abs() < 0.5 &&
      r.4 == @ui.tree_theme().lifted
    }).map(fn(r) { r.0 })
  }
  let start_x = thumb_x().unwrap()
  t_phone.tap_text("概览")
  assert_true(t_phone.find("额度与恢复") is Some(_))
  t_phone.run_for(@sf.dur_ms / 4.0)
  let mid_x = thumb_x().unwrap()
  t_phone.run_for(@ui.move_most_ms)
  let end_x = thumb_x().unwrap()
  assert_true(start_x < mid_x && mid_x < end_x, msg="the thumb slides across as the pane changes: \{start_x}, \{mid_x}, \{end_x}")
  assert_true(t_phone.find("额度与恢复") is Some(_), msg="Place(\"profiles\") switches to 概览")
  assert_true(t_phone.find("消耗速度") is Some(_))
  let ov_radio_1 = t_phone.all(Radio, label="概览")[0].rect
  assert_true((ov_radio_1.0 - ov_radio_0.0).abs() <= 0.5 && (ov_radio_1.1 - ov_radio_0.1).abs() <= 0.5, msg="place segmented control stays in place: \{ov_radio_0.0},\{ov_radio_0.1} -> \{ov_radio_1.0},\{ov_radio_1.1}")
  assert_eq(t_phone.corner_faults(), [])
  assert_eq(t_phone.lit_all_faults(), [])
  assert_eq(t_phone.room_faults(), [])
  assert_eq(t_phone.hover_only_faults(), [])
  assert_eq(t_phone.height_faults(), [])
  assert_eq(t_phone.first_line_faults(), [])
  assert_eq(t_phone.line_start_faults(), [])
  assert_eq(t_phone.fixed_outgrown(), [])
  assert_eq(t_phone.hand_moves(), [])
  assert_eq(t_phone.squeeze_faults(), [])
  // Switch bottom bar away to Home and back: Place("profiles") shelved, keeps 概览
  @ui.view_tree().unwrap().event(t_phone.time(), fn() { @sfbase.nav_root_kept(Home) })
  t_phone.run_for(@ui.move_most_ms)
  assert_true(t_phone.find("额度与恢复") is None)
  @ui.view_tree().unwrap().event(t_phone.time(), fn() { @sfbase.nav_root_kept(Place("profiles")) })
  t_phone.run_for(@ui.move_most_ms)
  assert_true(t_phone.find("额度与恢复") is Some(_), msg="shelved Place(\"profiles\") remembers 概览")
  // Open Settings -> Setting(Profiles("")) over Place("profiles"): starts on 账号, switches without header jump, popping preserves Place("profiles") 概览
  t_phone.click(Button, label="设置")
  t_phone.run_for(page_local_ms + @ui.move_most_ms)
  @ui.view_tree().unwrap().event(t_phone.time(), fn() { app.nav.push(Setting(@settings.Route::Profiles(""))) })
  t_phone.run_for(page_local_ms + @ui.move_most_ms)
  assert_true(t_phone.find("Claude 主账号") is Some(_))
  assert_true(t_phone.find("额度与恢复") is None)
  let set_acc_0 = t_phone.all(Radio, label="账号")[0].rect
  let set_ov_0 = t_phone.all(Radio, label="概览")[0].rect
  assert_true(t_phone.query(Link, label="设置") is Some(_), msg="Setting(Profiles(\"\"))'s 账号 has its way back")
  assert_true(set_acc_0.0 >= 12.0, msg="settings accounts radio inset: \{set_acc_0.0}")
  assert_true(set_ov_0.0 + set_ov_0.2 <= 390.0 - 12.0, msg="settings overview radio inset: \{set_ov_0.0 + set_ov_0.2}")
  t_phone.tap_text("概览")
  t_phone.run_for(@ui.move_most_ms)
  assert_true(t_phone.find("额度与恢复") is Some(_), msg="Setting(Profiles(\"\")) switches to 概览")
  assert_true(t_phone.query(Link, label="设置") is Some(_), msg="Setting(Profiles(\"\"))'s 概览 keeps the same top bar, its way back")
  let set_ov_1 = t_phone.all(Radio, label="概览")[0].rect
  assert_true((set_ov_1.0 - set_ov_0.0).abs() <= 0.5 && (set_ov_1.1 - set_ov_0.1).abs() <= 0.5, msg="settings segmented control stays in place (no header jump): \{set_ov_0.0},\{set_ov_0.1} -> \{set_ov_1.0},\{set_ov_1.1}")
  assert_eq(t_phone.corner_faults(), [])
  assert_eq(t_phone.room_faults(), [])
  assert_eq(t_phone.squeeze_faults(), [])
  t_phone.tap_text("账号")
  t_phone.run_for(@ui.move_most_ms)
  assert_true(t_phone.find("额度与恢复") is None, msg="Setting(Profiles(\"\")) back to 账号")
  // Back to the bottom bar's Profile: Setting(Profiles(""))'s switch left it as it was (its own, still 概览)
  @ui.view_tree().unwrap().event(t_phone.time(), fn() { @sfbase.nav_root_kept(Place("profiles")) })
  t_phone.run_for(page_local_ms + @ui.move_most_ms)
  assert_true(t_phone.find("额度与恢复") is Some(_), msg="Setting(Profiles(\"\")) leaves Place(\"profiles\")'s 概览 as it was")
  t_phone.tap_text("账号")
  t_phone.run_for(@ui.move_most_ms)
  assert_true(t_phone.find("Claude 主账号") is Some(_))
  assert_true(t_phone.find("额度与恢复") is None)

  // 3. Every corner_windows tier (zh & en) + 1.3x font scale on phone for place-profiles, place-profiles-sum-overview, and settings-profiles-sum-a
  for win in corner_windows {
    for lang in ["zh", "en"] {
      for mode in ["place-profiles", "place-profiles-sum-a", "place-profiles-sum-overview", "settings-profiles", "settings-profiles-sum-a"] {
        let at = "\{win.0}-\{lang} \{mode}"
        let t = screen_in(mode, win, lang)
        let expected_corners = if win.0 == "touch" || win.0 == "desk-win" { 1 } else { 0 }
        let c_faults = t.corner_faults()
        for f in t.lit_all_faults() {
          if !c_faults.contains(f) {
            c_faults.push(f)
          }
        }
        let c_joined = c_faults.join("; ")
        assert_eq(c_faults.length(), expected_corners, msg="\{at} corners: \{c_joined}")
        if lang == "zh" {
          assert_eq(t.room_faults(), [], msg="\{at} room")
          assert_eq(t.hover_only_faults(), [], msg="\{at} hover")
          assert_eq(contrast_wrong("\{win.0}-light \{mode}", t.contrast_faults()), None, msg="\{at} contrast")
        }
        assert_eq(t.height_faults(), [], msg="\{at} height")
        assert_eq(t.first_line_faults(), [], msg="\{at} first_line")
        assert_eq(t.line_start_faults(), [], msg="\{at} line_start")
        assert_eq(t.fixed_outgrown(), [], msg="\{at} outgrown")
        assert_eq(t.hand_moves(), [], msg="\{at} hand_moves")
        if squeeze_windows.contains(win.0) {
          assert_eq(t.squeeze_faults(), [], msg="\{at} squeeze")
        }
        let g_faults = t.gap_faults()
        let g_joined = g_faults.join("; ")
        assert_eq(g_faults.length(), 0, msg="\{at} gaps: \{g_joined}")
      }
      if win.0 == "phone" {
        for mode in ["place-profiles", "place-profiles-sum-overview", "settings-profiles", "settings-profiles-sum-a"] {
          let at = "phone-\{lang}-1.3 \{mode}"
          let tl = screen_in(mode, win, lang, font_scale=1.3)
          assert_eq(tl.fixed_outgrown(), [], msg="\{at} outgrown")
          let wl = tl.squeeze_faults() + tl.words_over_now()
          let wl_joined = wl.join("; ")
          assert_eq(wl, [], msg="\{at} words_large: \{wl_joined}")
        }
      }
    }
  }
}

///|
test "narrow: profiles 账号 ↔ 概览 holds optimistic selection across delayed profilesOverview and settles on delivery or cancellation" {
  let make_delayed = fn() {
    new_run()
    let base = fixture_app("place-profiles-sum-a")
    let ready : @signals.Signal[Bool] = @signals.signal(false)
    let src : Source = {
      ..base,
      topic_read: fn(name, params) {
        if name == "profilesOverview" && !ready.get() {
          { value: None, error: None, version: 0 }
        } else {
          base.topic(name, params).get().snapshot()
        }
      },
    }
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
    t.run_for(@ui.move_most_ms)
    (t, ready)
  }
  let seg_visuals = fn(t : @ui.Tester, r0 : (Double, Double, Double, Double), r1 : (Double, Double, Double, Double)) {
    let lifted_rgb = @ui.tree_theme().lifted >> 8
    let rects = t
      .drawn_rects()
      .filter(fn(d) {
        (d.4 >> 8) == lifted_rgb &&
        (d.4 & 0xFFL) > 0x40L &&
        (d.3 - r0.3).abs() < 2.0 &&
        d.1 >= r0.1 - 4.0 &&
        d.1 <= r0.1 + r0.3 &&
        d.0 >= r0.0 - 4.0 &&
        d.0 + d.2 <= r1.0 + r1.2 + 4.0
      })
    let cy = r0.1 + r0.3 / 2.0
    let glasses = t
      .drawn_glass()
      .filter(fn(g) {
        ((g.1 + g.3 / 2.0) - cy).abs() < 4.0 &&
        g.0 + g.2 >= r0.0 - 24.0 &&
        g.0 <= r1.0 + r1.2 + 24.0
      })
    (rects, glasses)
  }
  let drag_to_overview = fn(t : @ui.Tester, r0 : (Double, Double, Double, Double), r1 : (Double, Double, Double, Double)) {
    let y = r0.1 + r0.3 / 2.0
    let x0 = r0.0 + r0.2 / 2.0
    let x1 = r1.0 + r1.2 / 2.0
    t.touch(0, x0, y)
    t.frame()
    t.touch(1, (x0 + x1) / 2.0, y)
    t.frame()
    t.touch(1, x1, y)
    t.frame()
    t.touch(2, x1, y)
  }

  // Branch A: drag from 账号 to 概览 while profilesOverview is delayed, then deliver it.
  let (t_a, ready_a) = make_delayed()
  assert_true(t_a.find("Claude 主账号") is Some(_))
  assert_true(t_a.find("额度与恢复") is None)
  let r0_a = t_a.all(Radio, label="账号")[0].rect
  let r1_a = t_a.all(Radio, label="概览")[0].rect
  let mid_x_a = (r0_a.0 + r0_a.2 + r1_a.0) / 2.0
  let r1cx_a = r1_a.0 + r1_a.2 / 2.0
  drag_to_overview(t_a, r0_a, r1_a)
  let samples_a = Ref(0)
  let reached_a = Ref(false)
  let drifted_a : Array[String] = []
  t_a.each_frame(
    Some(fn() {
      samples_a.val += 1
      let radios_ov = t_a.all(Radio, label="概览")
      if radios_ov.is_empty() || radios_ov[0].check != Some(@ui.Check::On) {
        drifted_a.push("t=\{t_a.time()} overview radio not On")
      }
      let (rects, glasses) = seg_visuals(t_a, r0_a, r1_a)
      if rects.is_empty() && glasses.is_empty() {
        drifted_a.push("t=\{t_a.time()} missing capsule/lens")
      }
      for d in rects {
        let cx = d.0 + d.2 / 2.0
        if cx >= mid_x_a {
          reached_a.val = true
        } else if reached_a.val {
          drifted_a.push("t=\{t_a.time()} rect cx=\{cx} drifted back left of mid=\{mid_x_a}")
        }
      }
      for g in glasses {
        let cx = g.0 + g.2 / 2.0
        if cx >= mid_x_a {
          reached_a.val = true
        } else if reached_a.val {
          drifted_a.push("t=\{t_a.time()} glass cx=\{cx} drifted back left of mid=\{mid_x_a}")
        }
      }
    }),
  )
  t_a.run_for(@ui.move_most_ms)
  t_a.each_frame(None)
  assert_true(samples_a.val > 0, msg="branch A must sample wait frames")
  assert_true(reached_a.val, msg="branch A capsule/lens must reach 概览 during wait")
  assert_true(drifted_a.is_empty(), msg="branch A drifted during wait: \{drifted_a.join("; ")}")
  assert_true(t_a.find("Claude 主账号") is Some(_), msg="accounts list stays visible while profilesOverview is pending")
  assert_true(t_a.find("额度与恢复") is None, msg="overview must not mount before profilesOverview arrives")
  let (rects_a_wait, glasses_a_wait) = seg_visuals(t_a, r0_a, r1_a)
  assert_eq(glasses_a_wait.length(), 0, msg="branch A in-flight resting: expected 0 glass lenses")
  assert_eq(rects_a_wait.length(), 1, msg="branch A in-flight resting: expected 1 resting capsule")
  assert_true((rects_a_wait[0].0 + rects_a_wait[0].2 / 2.0 - r1cx_a).abs() < 1.0, msg="branch A in-flight capsule must align with 概览")
  // Deliver delayed profilesOverview -> switches to overview with unique resting capsule aligned to 概览, 0 glass.
  ready_a.set(true)
  t_a.run_for(@ui.move_most_ms)
  assert_true(t_a.find("额度与恢复") is Some(_), msg="overview mounts once profilesOverview arrives")
  assert_eq(t_a.all(Radio, label="概览")[0].check, Some(@ui.Check::On))
  let (rects_a, glasses_a) = seg_visuals(t_a, r0_a, r1_a)
  assert_eq(glasses_a.length(), 0, msg="branch A settled: expected 0 glass lenses")
  assert_eq(rects_a.length(), 1, msg="branch A settled: expected 1 resting capsule")
  let tcx_a = rects_a[0].0 + rects_a[0].2 / 2.0
  assert_true((tcx_a - r1cx_a).abs() < 1.0, msg="branch A capsule \{tcx_a} must align with 概览 \{r1cx_a}")

  // Branch B: drag from 账号 to 概览 while profilesOverview is delayed, then cancel by tapping 账号.
  let (t_b, ready_b) = make_delayed()
  let r0_b = t_b.all(Radio, label="账号")[0].rect
  let r1_b = t_b.all(Radio, label="概览")[0].rect
  let mid_x_b = (r0_b.0 + r0_b.2 + r1_b.0) / 2.0
  let r0cx_b = r0_b.0 + r0_b.2 / 2.0
  drag_to_overview(t_b, r0_b, r1_b)
  let samples_b = Ref(0)
  let reached_b = Ref(false)
  let drifted_b : Array[String] = []
  t_b.each_frame(
    Some(fn() {
      samples_b.val += 1
      let radios_ov = t_b.all(Radio, label="概览")
      if radios_ov.is_empty() || radios_ov[0].check != Some(@ui.Check::On) {
        drifted_b.push("t=\{t_b.time()} overview radio not On")
      }
      let (rects, glasses) = seg_visuals(t_b, r0_b, r1_b)
      if rects.is_empty() && glasses.is_empty() {
        drifted_b.push("t=\{t_b.time()} missing capsule/lens")
      }
      for d in rects {
        let cx = d.0 + d.2 / 2.0
        if cx >= mid_x_b {
          reached_b.val = true
        } else if reached_b.val {
          drifted_b.push("t=\{t_b.time()} rect drifted back")
        }
      }
      for g in glasses {
        let cx = g.0 + g.2 / 2.0
        if cx >= mid_x_b {
          reached_b.val = true
        } else if reached_b.val {
          drifted_b.push("t=\{t_b.time()} glass drifted back")
        }
      }
    }),
  )
  t_b.run_for(@ui.move_most_ms)
  t_b.each_frame(None)
  assert_true(samples_b.val > 0, msg="branch B must sample wait frames")
  assert_true(reached_b.val, msg="branch B capsule/lens must reach 概览 during wait")
  assert_true(drifted_b.is_empty(), msg="branch B drifted during wait: \{drifted_b.join("; ")}")
  // Cancel in-flight overview switch by tapping 账号.
  t_b.tap_text("账号")
  t_b.run_for(@ui.move_most_ms * 2.0)
  assert_true(t_b.find("Claude 主账号") is Some(_), msg="branch B stays on accounts list after cancel")
  assert_true(t_b.find("额度与恢复") is None, msg="branch B must not show overview after cancel")
  assert_eq(t_b.all(Radio, label="账号")[0].check, Some(@ui.Check::On))
  let (rects_b, glasses_b) = seg_visuals(t_b, r0_b, r1_b)
  assert_eq(glasses_b.length(), 0, msg="branch B cancelled: expected 0 glass lenses")
  assert_eq(rects_b.length(), 1, msg="branch B cancelled: expected 1 resting capsule")
  let tcx_b = rects_b[0].0 + rects_b[0].2 / 2.0
  assert_true((tcx_b - r0cx_b).abs() < 1.0, msg="branch B capsule \{tcx_b} must align with 账号 \{r0cx_b}")
  // Late profilesOverview delivery after cancellation must NOT flip to overview.
  ready_b.set(true)
  t_b.run_for(@ui.move_most_ms)
  assert_true(t_b.find("额度与恢复") is None, msg="late profilesOverview after cancel must not switch to overview")
  assert_eq(t_b.all(Radio, label="账号")[0].check, Some(@ui.Check::On))
}

///|
test "narrow & bar_actions: tapping 多选 while profilesOverview switch is pending cancels switch and preserves multi-select state" {
  // Verify both: (1) phone Place("profiles") using profiles_page_node's bar_actions 多选,
  // and (2) pushed Setting(Profiles("")) using profiles_list_node's own actions pill 多选.
  for pushed in [false, true] {
    let at = if pushed { "pushed Setting(Profiles)" } else { "Place(profiles) bar_actions" }
    new_run()
    let base = fixture_app("place-profiles-sum-a")
    let ready : @signals.Signal[Bool] = @signals.signal(false)
    let src : Source = {
      ..base,
      topic_read: fn(name, params) {
        if name == "profilesOverview" && !ready.get() {
          { value: None, error: None, version: 0 }
        } else {
          base.topic(name, params).get().snapshot()
        }
      },
    }
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=if pushed { 0 } else { 2 })
    t.run_for(@ui.move_most_ms)
    if pushed {
      @ui.view_tree().unwrap().event(t.time(), fn() { app.nav.push(Setting(@settings.Route::Profiles(""))) })
      t.run_for(page_local_ms + @ui.move_most_ms)
    }
    assert_true(t.find("Claude 主账号") is Some(_), msg=at)
    assert_true(t.find("额度与恢复") is None, msg=at)
    let r0 = t.all(Radio, label="账号")[0].rect
    let r1 = t.all(Radio, label="概览")[0].rect
    // 1. Trigger 概览 switch while profilesOverview is delayed.
    t.tap_text("概览")
    t.run_for(@ui.move_most_ms / 2.0)
    assert_eq(t.all(Radio, label="概览")[0].check, Some(@ui.Check::On), msg="\{at}: optimistic 概览 while pending")
    assert_true(t.find("额度与恢复") is None, msg="\{at}: still showing accounts while pending")
    // 2. Tap 多选 before profilesOverview arrives -> cancels pending overview switch and enters multi-select.
    t.click(Button, label="多选")
    t.run_for(@ui.move_most_ms)
    assert_eq(t.all(Radio, label="账号")[0].check, Some(@ui.Check::On), msg="\{at}: 多选 must cancel pending 概览")
    // 3. Pick an account in multi-select mode.
    t.tap_text("Claude 主账号")
    t.run_for(@ui.move_most_ms / 2.0)
    assert_true(t.find("已选 1") is Some(_), msg="\{at}: expected 1 selected account before delayed overview arrives")
    // 4. Deliver delayed profilesOverview -> must stay on 账号 with capsule aligned and multi-select + selection preserved.
    ready.set(true)
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("额度与恢复") is None, msg="\{at}: delayed overview must not clobber active multi-select")
    assert_true(t.find("Claude 主账号") is Some(_), msg=at)
    assert_true(t.find("已选 1") is Some(_), msg="\{at}: multi-select selection must survive delayed overview delivery")
    assert_eq(t.all(Radio, label="账号")[0].check, Some(@ui.Check::On), msg=at)
    let lifted_rgb = @ui.tree_theme().lifted >> 8
    let rects = t
      .drawn_rects()
      .filter(fn(d) {
        (d.4 >> 8) == lifted_rgb &&
        (d.4 & 0xFFL) > 0x40L &&
        (d.3 - r0.3).abs() < 2.0 &&
        d.1 >= r0.1 - 4.0 &&
        d.1 <= r0.1 + r0.3 &&
        d.0 >= r0.0 - 4.0 &&
        d.0 + d.2 <= r1.0 + r1.2 + 4.0
      })
    let cy = r0.1 + r0.3 / 2.0
    let glasses = t
      .drawn_glass()
      .filter(fn(g) {
        ((g.1 + g.3 / 2.0) - cy).abs() < 4.0 &&
        g.0 + g.2 >= r0.0 - 24.0 &&
        g.0 <= r1.0 + r1.2 + 24.0
      })
    assert_eq(glasses.length(), 0, msg="\{at}: expected 0 glass at rest")
    assert_eq(rects.length(), 1, msg="\{at}: expected 1 resting capsule")
    let tcx = rects[0].0 + rects[0].2 / 2.0
    let r0cx = r0.0 + r0.2 / 2.0
    assert_true((tcx - r0cx).abs() < 1.0, msg="\{at}: capsule \{tcx} must align with 账号 \{r0cx}")
  }
}
