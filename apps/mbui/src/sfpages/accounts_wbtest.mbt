// A profile's page (accounts.mbt) alone over the settings' fixture: Willow's
// (ws1/st1) Claude subscription and its API key, wide; ChatGPT 团队's.

///|
test "a profile's page, wide: who it is and whether it works, then its allowance and who uses it, sharing, settings" {
  let t = setting_tester(Profile("ws1/st1", "cc"), 1280.0)
  // its head: its name, what it is (the core's words), its last check
  assert_true(t.find("Claude 主账号") is Some(_))
  assert_true(t.find("订阅账号 · Ultra") is Some(_), msg="what it is")
  assert_true(t.find("订阅有效 · 5 分钟前检查") is Some(_), msg="its check in a line")
  // what is left of its allowance, a dial each, and who uses it in the same card
  assert_true(t.find("额度") is Some(_))
  assert_true(t.find("5 小时") is Some(_) && t.find("本周") is Some(_), msg="its windows")
  assert_true(t.find("星火助手") is Some(_))
  // whom it is shared with, and its settings
  scrolled_to(t, 1280.0, "分享给其他 station")
  assert_true(t.find("分享给其他 station") is Some(_), msg="sharing")
  scrolled_to(t, 1280.0, "默认 Fast")
  assert_true(t.find("默认 Fast") is Some(_))
}

///|
test "checking a Claude account does not ask for confirmation" {
  for (w, platform) in page_cases {
    let calls : Array[String] = []
    let t = setting_tester(Profile("ws1/st1", "cc"), w, platform~, over=fn(s) {
      { ..s, call: fn(name, params, done) {
          if name == "profile.check" || name == "profile.quota" { calls.push(name) }
          (s.call)(name, params, done)
        } }
    })
    t.click(Button, label="重新检查")
    t.frame()
    assert_eq(calls, ["profile.check", "profile.quota"])
    assert_false(@sf.presenting())
  }
}

///|
test "returning to a Claude account's open login page does not ask again" {
  for (w, platform) in page_cases {
    let calls : Array[String] = []
    let t = setting_tester(Profile("ws1/st1", "cc"), w, platform~, mode="settings-profile-login-station", over=fn(s) {
      fn with_open_screen(v : Json) -> Json {
        match v {
          Object(o) => {
            let copy = o.copy()
            for key, value in o { copy[key] = with_open_screen(value) }
            if text(Some(v), "state") == "needs_code" && flag(Some(v), "browser") {
              copy["screen"] = "browser:T1"
            }
            Json::object(copy)
          }
          Array(a) => Json::array(a.map(with_open_screen))
          _ => v
        }
      }
      { ..s,
        topic_read: fn(name, params) {
          let r = s.topic(name, params).get().snapshot()
          { ..r, value: r.value.map(with_open_screen) }
        },
        call: fn(name, params, done) {
          if name == "profile.loginBrowser" {
            calls.push(name)
            done(Ok({ "screen": "browser:T1" }))
          } else {
            (s.call)(name, params, done)
          }
        },
      }
    })
    t.click(Button, label="回到 Willow 的浏览器")
    t.frame()
    assert_eq(calls, ["profile.loginBrowser"])
    assert_false(@sf.presenting())
    assert_true(t.audit().is_empty())
  }
}

///|
test "a shared subscription's main switch and its station details remain usable at each width" {
  for case in page_cases {
    let (w, platform) = case
    let calls : Array[(String, Json)] = []
    let t = setting_tester(Profile("ws1/st1", "cc"), w, platform~, h=2400.0, over=fn(s) {
      { ..s, call: fn(name, params, done) {
          calls.push((name, params))
          if name == "profile.share" { done(Ok(obj([]))) } else { (s.call)(name, params, done) }
        } }
    })
    let at = "\{w} platform \{platform}"
    scrolled_to(t, w, "分享给其他 station")
    assert_eq(t.get(Switch, label="分享给其他 station").check, Some(On), msg=at)
    assert_true(t.find("所在 station") is Some(_) && t.find("可用的 station") is Some(_), msg=at)
    assert_true(t.find("将此账号迁移到其他 station") is Some(_), msg=at)
    assert_true(t.find("允许其他 station 上的对话使用此账号") is Some(_), msg=at)
    assert_true(t.find("选择哪些 station 可以使用此账号") is Some(_), msg=at)
    let boxes = t.boxes_held()
    let switch_title = boxes.filter(fn(b) { b.text == "分享给其他 station" })
    assert_eq(switch_title.length(), 1, msg=at)
    for title in ["所在 station", "可用的 station"] {
      let found = boxes.filter(fn(b) { b.text == title })
      assert_eq(found.length(), 1, msg="\{at}: \{title}")
      assert_eq(found[0].weight, 500, msg="\{at}: \{title}")
      assert_eq(found[0].color, switch_title[0].color, msg="\{at}: \{title} ink")
    }
    t.tap_text("所在 station")
    t.run_for(@motion.presence_in_ms)
    assert_true(t.find("移到哪台 station？") is Some(_), msg=at)
    @sf.presenters_reset()
    // (what was presented let go at once by hand, the test's way to close it: no signal of it, said)
    t.stepped()
    t.frame()
    t.tap_text("可用的 station")
    presented_in(t)
    assert_true(t.find("以后新加的 station 也能用") is Some(_), msg=at)
    assert_eq(t.get(Switch, label="全部 station").check, Some(On), msg=at)
    assert_eq(t.audit(), [], msg="\{at}: " + t.audit().join("; "))
    @sf.presenters_reset()
    // (what was presented let go at once by hand, the test's way to close it: no signal of it, said)
    t.stepped()
    t.frame()
    t.click(Switch, label="分享给其他 station")
    t.frame()
    let asked = calls.filter(fn(c) { c.0 == "profile.share" })
    assert_eq(asked.length(), 1, msg=at)
    assert_false(flag(Some(asked[0].1), "on"), msg=at)
  }
}

///|
test "which stations may use a share is said with the stations it was chosen among, so only theirs change" {
  let calls : Array[Json] = []
  let t = setting_tester(Profile("ws1/st1", "cc"), 1280.0, h=2400.0, over=fn(s) {
    { ..s, call: fn(name, params, done) {
        if name == "profile.share" {
          calls.push(params)
          done(Ok(obj([])))
        } else {
          (s.call)(name, params, done)
        }
      } }
  })
  scrolled_to(t, 1280.0, "可用的 station")
  let among = fn(p : Json) -> Array[String] {
    match field(Some(p), "among") {
      Some(Array(a)) => a.filter_map(fn(x) { if x is String(v) { Some(v) } else { None } })
      _ => []
    }
  }
  // Maple left out: the list of those ticked, and every one listed as what it was chosen among
  t.tap_text("可用的 station")
  t.run_for(@motion.presence_in_ms)
  t.click(Switch, label="Maple")
  t.frame()
  t.click(Button, label="完成")
  t.run_for(@motion.presence_out_ms)
  assert_eq(calls.length(), 1)
  assert_eq(field(Some(calls[0]), "allow"), Some(Json::array([Json::string("st1")])))
  assert_eq(among(calls[0]), ["st1", "st2"])
  // all of them ticked: no list, so the station keeps what was chosen of the others where it is in several workspaces
  t.tap_text("可用的 station")
  t.run_for(@motion.presence_in_ms)
  t.click(Button, label="完成")
  t.run_for(@motion.presence_out_ms)
  assert_eq(calls.length(), 2)
  assert_eq(field(Some(calls[1]), "allow"), None)
  assert_eq(among(calls[1]), ["st1", "st2"])
}

///|
test "a profile's workspace row shows its own mark, but no repeated initial without one" {
  for (w, platform) in page_cases {
    for (emoji, icon) in [("", ""), ("🌱", ""), ("", "glyph:star")] {
      let t = setting_tester(Profile("ws1/st1", "cc"), w, platform~, h=2400.0, over=fn(base) {
        {
          ..base,
          topic_read: fn(name, params) {
            if name == "memberships" {
              {
                value: Some({
                  "manages": true,
                  "workspaces": [{ "workspace": "ws2", "name": "个人", "home": false, "emoji": Json::string(emoji), "icon": Json::string(icon) }],
                }),
                error: None,
                version: 1,
              }
            } else {
              base.topic(name, params).get().snapshot()
            }
          },
        }
      })
      let at = "\{w} platform \{platform}, emoji \{emoji}, icon \{icon}"
      assert_true(t.get(Switch, label="个人").check is Some(_), msg=at)
      assert_true(t.boxes_held().filter(fn(b) { b.text == "个" }).is_empty(), msg=at)
      assert_eq(t.boxes_held().iter().any(fn(b) { b.text == "🌱" }), emoji != "", msg=at)
      assert_eq(drawn_names().iter().any(fn(n) { n.has_prefix("sf/pic/glyph/star") }), icon != "", msg=at)
    }
  }
}

///|
/// What the window's tree draws called by name now (View::drawn_as: a mark's glyph, sf/pic/glyph/NAME), each drawn
/// node's.
fn drawn_names() -> Array[String] {
  match @ui.view_tree() {
    Some(tree) => tree.drawn().map(fn(d) { tree.drawn_name(d.id) })
    None => []
  }
}

///|
test "a shared account's station rows explain what each row is for without per-station status rows" {
  for (w, platform) in page_cases {
    let t = setting_tester(Profile("ws1/st1", "cc"), w, platform~, h=2400.0)
    let at = "\{w} platform \{platform}"
    assert_true(t.find("所在 station") is Some(_), msg=at)
    assert_true(t.find("将此账号迁移到其他 station") is Some(_), msg=at)
    assert_true(t.find("允许其他 station 上的对话使用此账号") is Some(_), msg=at)
    assert_true(t.find("选择哪些 station 可以使用此账号") is Some(_), msg=at)
    assert_true(t.query(Link, label="Maple") is None, msg="\{at}: per-station rows removed")
  }
}

///|
/// The fixture's Claude subscription before it is shared.
fn unshared_claude(s : Source) -> Source {
  fn without_share(v : Json) -> Json {
    match v {
      Object(o) => {
        let p = o.copy()
        for k, x in o {
          p[k] = without_share(x)
        }
        if o.get("id") == Some(Json::string("cc")) && o.contains("available") {
          p.remove("share")
        }
        Json::object(p)
      }
      Array(a) => Json::array(a.map(without_share))
      _ => v
    }
  }
  {
    ..s,
    topic_read: fn(name, params) {
      let v = s.topic(name, params).get().snapshot()
      match v.value {
        Some(x) => { ..v, value: Some(without_share(x)) }
        None => v
      }
    },
  }
}

///|
/// Replaces the stations list on a profile's sharing entry (for 1-station and 3-station share tests).
fn with_share_stations(s : Source, stations : Array[Json]) -> Source {
  fn shaped(v : Json) -> Json {
    match v {
      Object(o) => {
        let p = o.copy()
        for k, x in o {
          p[k] = shaped(x)
        }
        if o.contains("stations") && o.contains("members") {
          p["stations"] = Json::array(stations)
        }
        Json::object(p)
      }
      Array(a) => Json::array(a.map(shaped))
      _ => v
    }
  }
  {
    ..s,
    topic_read: fn(name, params) {
      let v = s.topic(name, params).get().snapshot()
      match v.value {
        Some(x) => { ..v, value: Some(shaped(x)) }
        None => v
      }
    },
  }
}

///|
test "sharing a Claude subscription asks about requests on the target stations before enabling it" {
  for case in page_cases {
    let (w, platform) = case
    let asked : Array[Json] = []
    let t = setting_tester(Profile("ws1/st1", "cc"), w, platform~, over=fn(base) {
      let s = unshared_claude(base)
      { ..s, call: fn(name, params, done) {
        if name == "profile.share" { asked.push(params) }
        (s.call)(name, params, done)
      } }
    })
    let at = "\{w} platform \{platform}"
    scrolled_to(t, w, "分享给其他 station")
    assert_eq(t.get(Switch, label="分享给其他 station").check, Some(Off), msg=at)
    t.click(Switch, label="分享给其他 station")
    t.frame()
    assert_true(@sf.presenting(), msg=at)
    assert_eq(asked.length(), 0, msg="\{at}: not shared before confirmation")
    presented_in(t)
    assert_true(t.find("其他 station 会借用此账号的登录凭证，在各自的机器上直接向 Claude 发送请求") is Some(_), msg=at)
    assert_true(t.find("请自行确保目标 station 能安全访问 Claude") is Some(_), msg=at)
    assert_eq(t.get(Switch, label="全部 station").check, Some(Off), msg=at)
    assert_eq(t.get(Switch, label="Maple").check, Some(Off), msg=at)
    assert_eq(t.get(Switch, label="Willow").check, Some(On), msg=at)
    assert_true(t.get(Switch, label="Willow").disabled, msg=at)
    assert_true(t.get(Button, label="已了解，分享账号").disabled, msg=at)
    assert_eq(t.audit(), [], msg="\{at}: " + t.audit().join("; "))
    t.click(Button, label="取消")
    t.run_for(@motion.presence_out_ms)
    assert_eq(asked.length(), 0, msg="\{at}: cancellation does not share")
    assert_eq(t.get(Switch, label="分享给其他 station").check, Some(Off), msg=at)
    t.click(Switch, label="分享给其他 station")
    presented_in(t)
    t.click(Switch, label="Maple")
    t.run_for(@ui.move_most_ms)
    assert_false(t.get(Button, label="已了解，分享账号").disabled, msg=at)
    assert_eq(t.audit(), [], msg="\{at}: " + t.audit().join("; "))
    t.click(Button, label="已了解，分享账号")
    t.frame()
    assert_eq(asked.length(), 1, msg="\{at}: shared after confirmation")
    assert_eq(text(Some(asked[0]), "station"), "ws1/st1", msg=at)
    assert_eq(text(Some(asked[0]), "id"), "cc", msg=at)
    assert_eq(field(Some(asked[0]), "on"), Some(Json::boolean(true)), msg=at)
    assert_eq(field(Some(asked[0]), "among"), None, msg="\{at}: initial share omits among")
  }
}

///|
test "sharing an account with three stations starts all off, supports partial pick and select-all toggle without among" {
  let three : Array[Json] = [
    { "id": "st1", "name": "Willow", "online": true },
    { "id": "st2", "name": "Maple", "online": true },
    { "id": "st3", "name": "Birch", "online": true },
  ]
  for case in page_cases {
    let (w, platform) = case
    let asked : Array[Json] = []
    // (tall enough that the dialog's rows, the whitelist's among them, need no scrolling)
    let t = setting_tester(Profile("ws1/st1", "cc"), w, platform~, h=2400.0, over=fn(base) {
      let s = with_share_stations(unshared_claude(base), three)
      { ..s, call: fn(name, params, done) {
        if name == "profile.share" {
          asked.push(params)
          done(Ok(obj([])))
        } else {
          (s.call)(name, params, done)
        }
      } }
    })
    let at = "\{w} platform \{platform}"
    scrolled_to(t, w, "分享给其他 station")
    t.click(Switch, label="分享给其他 station")
    presented_in(t)
    assert_eq(t.get(Switch, label="全部 station").check, Some(Off), msg=at)
    assert_eq(t.get(Switch, label="Maple").check, Some(Off), msg=at)
    assert_eq(t.get(Switch, label="Birch").check, Some(Off), msg=at)
    assert_true(t.find("以后新加的 station 不会自动加进来") is Some(_), msg=at)
    assert_true(t.get(Button, label="已了解，分享账号").disabled, msg=at)
    assert_eq(t.audit(), [], msg="\{at}: " + t.audit().join("; "))
    // Partial pick: only Maple
    t.click(Switch, label="Maple")
    t.run_for(@ui.move_most_ms)
    assert_eq(t.get(Switch, label="全部 station").check, Some(Off), msg=at)
    assert_eq(t.get(Switch, label="Maple").check, Some(On), msg=at)
    assert_eq(t.get(Switch, label="Birch").check, Some(Off), msg=at)
    assert_false(t.get(Button, label="已了解，分享账号").disabled, msg=at)
    assert_eq(t.audit(), [], msg="\{at}: " + t.audit().join("; "))
    t.click(Button, label="已了解，分享账号")
    t.run_for(@motion.presence_out_ms)
    assert_eq(asked.length(), 1, msg=at)
    assert_eq(field(Some(asked[0]), "on"), Some(Json::boolean(true)), msg=at)
    assert_eq(field(Some(asked[0]), "allow"), Some(Json::array([Json::string("st1"), Json::string("st2")])), msg=at)
    assert_eq(field(Some(asked[0]), "among"), None, msg="\{at}: initial partial share omits among")
    // Re-open and test select-all toggle on -> off -> on
    t.click(Switch, label="分享给其他 station")
    presented_in(t)
    t.click(Switch, label="全部 station")
    t.run_for(@ui.move_most_ms)
    assert_eq(t.get(Switch, label="全部 station").check, Some(On), msg=at)
    assert_eq(t.get(Switch, label="Maple").check, Some(On), msg=at)
    assert_eq(t.get(Switch, label="Birch").check, Some(On), msg=at)
    assert_true(t.find("以后新加的 station 也能用") is Some(_), msg=at)
    assert_false(t.get(Button, label="已了解，分享账号").disabled, msg=at)
    assert_eq(t.audit(), [], msg="\{at}: " + t.audit().join("; "))
    t.click(Switch, label="全部 station")
    t.frame()
    assert_eq(t.get(Switch, label="全部 station").check, Some(Off), msg=at)
    assert_eq(t.get(Switch, label="Maple").check, Some(Off), msg=at)
    assert_eq(t.get(Switch, label="Birch").check, Some(Off), msg=at)
    assert_true(t.find("以后新加的 station 不会自动加进来") is Some(_), msg=at)
    assert_true(t.get(Button, label="已了解，分享账号").disabled, msg=at)
    t.click(Switch, label="全部 station")
    t.frame()
    t.click(Button, label="已了解，分享账号")
    t.run_for(@motion.presence_out_ms)
    assert_eq(asked.length(), 2, msg=at)
    assert_eq(field(Some(asked[1]), "on"), Some(Json::boolean(true)), msg=at)
    assert_eq(field(Some(asked[1]), "allow"), None, msg="\{at}: select-all omits allow")
    assert_eq(field(Some(asked[1]), "among"), None, msg="\{at}: initial select-all omits among")
  }
}

///|
test "sharing an account with only its own station requires turning on all stations" {
  let one : Array[Json] = [{ "id": "st1", "name": "Willow", "online": true }]
  for case in page_cases {
    let (w, platform) = case
    let asked : Array[Json] = []
    let t = setting_tester(Profile("ws1/st1", "cc"), w, platform~, over=fn(base) {
      let s = with_share_stations(unshared_claude(base), one)
      { ..s, call: fn(name, params, done) {
        if name == "profile.share" {
          asked.push(params)
          done(Ok(obj([])))
        } else {
          (s.call)(name, params, done)
        }
      } }
    })
    let at = "\{w} platform \{platform}"
    scrolled_to(t, w, "分享给其他 station")
    t.click(Switch, label="分享给其他 station")
    presented_in(t)
    assert_eq(t.get(Switch, label="全部 station").check, Some(Off), msg=at)
    assert_true(t.get(Button, label="已了解，分享账号").disabled, msg=at)
    assert_eq(t.audit(), [], msg="\{at}: " + t.audit().join("; "))
    t.click(Switch, label="全部 station")
    t.run_for(@ui.move_most_ms)
    assert_eq(t.get(Switch, label="全部 station").check, Some(On), msg=at)
    assert_true(t.find("以后新加的 station 也能用") is Some(_), msg=at)
    assert_false(t.get(Button, label="已了解，分享账号").disabled, msg=at)
    assert_eq(t.audit(), [], msg="\{at}: " + t.audit().join("; "))
    t.click(Button, label="已了解，分享账号")
    t.run_for(@motion.presence_out_ms)
    assert_eq(asked.length(), 1, msg=at)
    assert_eq(field(Some(asked[0]), "on"), Some(Json::boolean(true)), msg=at)
    assert_eq(field(Some(asked[0]), "allow"), None, msg=at)
    assert_eq(field(Some(asked[0]), "among"), None, msg=at)
  }
}

///|
test "editing allowed stations supports toggling all stations off and picking a subset with among" {
  let three : Array[Json] = [
    { "id": "st1", "name": "Willow", "online": true },
    { "id": "st2", "name": "Maple", "online": true },
    { "id": "st3", "name": "Birch", "online": true },
  ]
  for case in page_cases {
    let (w, platform) = case
    let asked : Array[Json] = []
    let t = setting_tester(Profile("ws1/st1", "cc"), w, platform~, h=2400.0, over=fn(base) {
      let s = with_share_stations(base, three)
      { ..s, call: fn(name, params, done) {
        if name == "profile.share" {
          asked.push(params)
          done(Ok(obj([])))
        } else {
          (s.call)(name, params, done)
        }
      } }
    })
    let at = "\{w} platform \{platform}"
    scrolled_to(t, w, "可用的 station")
    t.tap_text("可用的 station")
    presented_in(t)
    assert_eq(t.get(Switch, label="全部 station").check, Some(On), msg=at)
    assert_eq(t.get(Switch, label="Maple").check, Some(On), msg=at)
    assert_eq(t.get(Switch, label="Birch").check, Some(On), msg=at)
    assert_false(t.get(Button, label="完成").disabled, msg=at)
    assert_eq(t.audit(), [], msg="\{at}: " + t.audit().join("; "))
    t.click(Switch, label="全部 station")
    t.frame()
    assert_eq(t.get(Switch, label="Maple").check, Some(Off), msg=at)
    assert_eq(t.get(Switch, label="Birch").check, Some(Off), msg=at)
    assert_false(t.get(Button, label="完成").disabled, msg="\{at}: edit mode keeps Done enabled")
    t.click(Switch, label="Maple")
    t.frame()
    assert_eq(t.get(Switch, label="全部 station").check, Some(Off), msg=at)
    assert_eq(t.audit(), [], msg="\{at}: " + t.audit().join("; "))
    t.click(Button, label="完成")
    t.run_for(@motion.presence_out_ms)
    assert_eq(asked.length(), 1, msg=at)
    assert_eq(field(Some(asked[0]), "allow"), Some(Json::array([Json::string("st1"), Json::string("st2")])), msg=at)
    assert_eq(
      field(Some(asked[0]), "among"),
      Some(Json::array([Json::string("st1"), Json::string("st2"), Json::string("st3")])),
      msg=at,
    )
  }
}

///|
test "sharing other accounts explains how they are used on target stations" {
  for profile in ["cx", "k2"] {
    for case in page_cases {
      let (w, platform) = case
      let asked : Array[Json] = []
      let t = setting_tester(Profile("ws1/st1", profile), w, platform~, over=fn(s) {
        { ..s, call: fn(name, params, done) {
          if name == "profile.share" { asked.push(params) }
          (s.call)(name, params, done)
        } }
      })
      let at = "\{profile} \{w} platform \{platform}"
      scrolled_to(t, w, "分享给其他 station")
      assert_eq(t.get(Switch, label="分享给其他 station").check, Some(Off), msg=at)
      t.click(Switch, label="分享给其他 station")
      t.frame()
      assert_true(@sf.presenting(), msg=at)
      assert_eq(asked.length(), 0, msg=at)
      presented_in(t)
      let body = if profile == "cx" { "借用此账号的登录凭证" } else { "账号配置及其中的密钥会同步" }
      assert_true(t.find(body) is Some(_), msg=at)
      assert_true(t.find("在各自的机器上发送请求") is Some(_), msg=at)
      assert_true(t.find("安全访问 Claude") is None, msg=at)
      assert_eq(t.get(Switch, label="全部 station").check, Some(Off), msg=at)
      assert_eq(t.get(Switch, label="Maple").check, Some(Off), msg=at)
      assert_true(t.get(Button, label="分享账号").disabled, msg=at)
      assert_eq(t.audit(), [], msg="\{at}: " + t.audit().join("; "))
      t.click(Button, label="取消")
      t.run_for(@motion.presence_out_ms)
      assert_eq(asked.length(), 0, msg=at)
      assert_eq(t.get(Switch, label="分享给其他 station").check, Some(Off), msg=at)
      t.click(Switch, label="分享给其他 station")
      presented_in(t)
      t.click(Switch, label="Maple")
      t.run_for(@ui.move_most_ms)
      assert_false(t.get(Button, label="分享账号").disabled, msg=at)
      assert_eq(t.audit(), [], msg="\{at}: " + t.audit().join("; "))
      t.click(Button, label="分享账号")
      t.frame()
      assert_eq(asked.length(), 1, msg=at)
      assert_eq(text(Some(asked[0]), "id"), profile, msg=at)
      assert_eq(field(Some(asked[0]), "on"), Some(Json::boolean(true)), msg=at)
      assert_eq(field(Some(asked[0]), "among"), None, msg=at)
    }
  }
}

///|
test "stopping a share does not ask for confirmation" {
  let asked : Array[Json] = []
  let t = setting_tester(Profile("ws1/st1", "cc"), 1280.0, over=fn(s) {
    { ..s, call: fn(name, params, done) {
      if name == "profile.share" { asked.push(params) }
      (s.call)(name, params, done)
    } }
  })
  scrolled_to(t, 1280.0, "分享给其他 station")
  t.click(Switch, label="分享给其他 station")
  t.frame()
  assert_false(@sf.presenting())
  assert_eq(asked.length(), 1)
  assert_eq(field(Some(asked[0]), "on"), Some(Json::boolean(false)))
}

///|
test "a subscription's tier is shown on its page at every width" {
  for case in page_cases {
    let (w, platform) = case
    let t = setting_tester(Profile("ws1/st1", "cc"), w, platform~)
    assert_true(t.find("订阅账号 · Ultra") is Some(_), msg="tier at width \{w} platform \{platform}")
  }
}

///|
test "a key's profile's page, wide: its key masked, a new one asked for from its row" {
  let t = setting_tester(Profile("ws1/st1", "k2"), 1280.0)
  assert_true(t.find("备用 key") is Some(_))
  scrolled_to(t, 1280.0, "sk-…a41f")
  assert_true(t.find("sk-…a41f") is Some(_), msg="its key masked")
  // (the row's own: its trouble's 更换 key may be drawn above, out of sight)
  tap_words(t, "更换")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("新的 API key") is Some(_), msg="a new key asked for")
}

///|
test "a profile's page, wide: a profile one of the station's lists no more says so" {
  let t = setting_tester(Profile("ws1/st1", "gone"), 1280.0)
  assert_true(t.find("找不到 ID 为 gone 的 Profile") is Some(_))
}

// A profile's quota reset and its models over ChatGPT 团队: a reset used once asked, its
// models all listed, one named by hand and taken off again.

///|
test "a revoked Codex sign-in offers sign-in from the account check" {
  for (w, platform) in page_cases {
    let t = setting_tester(Profile("ws1/st1", "cx"), w, platform~, mode="settings-profile-quota-login")
    assert_true(t.find("需要登录") is Some(_))
    assert_true(t.find("ChatGPT 登录已失效，请重新登录") is Some(_))
    assert_true(t.find("订阅有效") is None, msg="the earlier account check must not contradict the expired login")
    assert_true(t.find("Willow 可用") is None, msg="this station must not be called usable after its login was refused")
    t.click(Button, label="登录")
    t.frame()
    assert_true(t.find("正在登录 ChatGPT") is Some(_), msg="the sign-in was started at width \{w}")
  }
}

///|
test "a profile's quota, a narrow page with a mouse: its resets left at the row's end; pressed, asks first, then uses one" {
  let t = setting_tester(Profile("ws1/st1", "cx"), 390.0)
  scrolled_to(t, 390.0, "剩 2 次")
  t.click(Link, label="额度重置")
  t.frame()
  assert_true(@sf.presenting(), msg="asked first")
  assert_true(t.find("重置额度？") is Some(_))
  assert_true(t.find("将使用「ChatGPT 团队」的 1 次额度重置，剩余 2 次") is Some(_))
  // (with a mouse: the web's confirm, come in)
  t.run_for(@motion.presence_in_ms)
  t.tap_text("使用一次重置")
  t.frame()
  t.frame()
  assert_true(t.find("剩 1 次") is Some(_))
}

///|
test "reset credits show their separate expiry times at every page width" {
  for (w, platform) in page_cases {
    let t = setting_tester(Profile("ws1/st1", "cx"), w, platform~, mode="settings-profile-quota-expiry")
    let note = "6 小时 35 分钟后、3 天 19 小时后到期"
    scrolled_to(t, w, note)
    assert_true(t.find(note) is Some(_), msg="reset expiries at width \{w}")
    assert_true(t.find("剩 2 次") is Some(_), msg="how many left, on their own, at width \{w}")
  }
}

///|
test "a subscription's resets of two kinds, a row each: what each gives back said, one usable only at a limit not offered, the other used by its kind" {
  for (w, platform) in page_cases {
    let t = setting_tester(Profile("ws1/st1", "cc"), w, platform~, mode="settings-profile-quota-kinds")
    scrolled_to(t, w, "Fable 重置")
    assert_true(t.find("5 小时重置") is Some(_), msg="the 5-hour kind at width \{w}")
    assert_true(t.find("立即恢复 5 小时额度 · 到达它能恢复的上限后才能用") is Some(_), msg="what it gives back, and why not now, at width \{w}")
    assert_true(t.find("把本周 Fable 用掉的额度还回每周额度 · 118 天后到期") is Some(_), msg="what the Fable one gives back at width \{w}")
    assert_true(t.find("剩 1 次") is Some(_), msg="how many left, on their own, at width \{w}")
  }
  let t = setting_tester(Profile("ws1/st1", "cc"), 390.0, mode="settings-profile-quota-kinds")
  scrolled_to(t, 390.0, "Fable 重置")
  assert_true(t.query(Link, label="5 小时重置") is None, msg="usable only at a limit: not offered")
  t.click(Link, label="Fable 重置")
  t.frame()
  assert_true(@sf.presenting(), msg="asked first")
  assert_true(t.find("将使用「Claude 主账号」的 1 次 Fable 重置：把本周 Fable 用掉的额度还回每周额度") is Some(_))
  t.run_for(@motion.presence_in_ms)
  t.click(Button, label="使用一次重置")
  // (its row closing its room on its way)
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Link, label="Fable 重置") is None, msg="the Fable reset used, by its kind")
  assert_true(t.find("5 小时重置") is Some(_), msg="the other kind left")
}

///|
test "a profile's models, a narrow page with a mouse: how many in a row; all of them in a panel, each a box to star; one named by hand added there, then taken off by its ×" {
  let t = setting_tester(Profile("ws1/st1", "cx"), 390.0)
  scrolled_to(t, 390.0, "可用模型")
  assert_true(t.find("12 个模型") is Some(_), msg="how many")
  assert_true(t.find("勾选常用模型，或按名称添加自定义模型") is Some(_), msg="what clicking it does")
  assert_true(t.find("GPT-6-MINI") is None, msg="not laid out on the page")
  t.tap_text("可用模型")
  t.run_for(@motion.presence_in_ms)
  assert_true(@sf.presenting(), msg="a panel")
  assert_true(t.find("GPT-6-MINI") is Some(_), msg="every one it runs")
  assert_true(t.query(Checkbox, label="喜欢 GPT-6-MINI") is Some(_), msg="its box")
  assert_true(t.query(Button, label="移除 GPT-6-MINI") is None, msg="one its provider lists: not taken off")
  // a name typed, then 添加
  t.tap_text("按名称添加模型")
  t.type_text("my-model")
  t.frame()
  // (添加 alone: the field's placeholder has the word too)
  tap_words(t, "添加")
  t.frame()
  t.frame()
  assert_true(t.query(Button, label="移除 MY-MODEL") is Some(_), msg="the model named, among the rest")
  // its × takes it off again (the sheet grown to hold it, on its way from as tall as it was: at rest)
  t.run_for(@ui.move_most_ms)
  t.click(Button, label="移除 MY-MODEL")
  // (its row closing its room on its way)
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Button, label="移除 MY-MODEL") is None, msg="taken off")
}

///|
test "a profile model's id appears beside the option the pointer is over" {
  let t = setting_tester(Profile("ws1/st1", "cc"), 1280.0)
  scrolled_to(t, 1280.0, "可用模型")
  t.tap_text("可用模型")
  t.run_for(@motion.presence_in_ms)
  for (name, id) in [("Opus 5.5", "claude-opus-5-5"), ("Sonnet 5", "claude-sonnet-5")] {
    // (its name on its box's row in the panel, not where the page under it says it)
    let (bx, by, _, bh) = t.get(Checkbox, label="喜欢 \{name}").rect
    let (_, x, y, w, h, _) = t.words().filter(fn(e) { e.0 == name && e.1 > bx && (e.2 + e.4 / 2.0 - (by + bh / 2.0)).abs() < 2.0 })[0]
    t.move_to(x + w / 2.0, y + h / 2.0)
    t.run_for(@sf.tip_delay_ms + @motion.presence_in_ms)
    let tip = t.get(Tooltip, label=id).rect
    let gap = tip.0 - (x + w)
    assert_true(gap >= 0.0 && gap <= 24.0, msg="\{name}: tip is directly to its right, gap \{gap}")
    let middle = tip.1 + tip.3 / 2.0 - (y + h / 2.0)
    assert_true(middle >= -1.0 && middle <= 1.0, msg="\{name}: tip is on the same row, offset \{middle}")
  }
}

///|
/// The fixture's Claude subscription as android 0.1.6389 showed one (2026-10-31): named by its long address, four
/// models on, its last 7 days' figures large.
fn long_profile(s : Source) -> Source {
  fn shaped(v : Json) -> Json {
    match v {
      Object(o) if o.get("id") == Some(Json::string("cc")) && o.contains("available") => {
        let p = o.copy()
        let ms : Array[Json] = ["claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5", "claude-haiku-5"]
        p["name"] = "claude5@jimmfly.example.com"
        p["models"] = Json::array(ms)
        p["modelsText"] = "4 个模型"
        p["available"] = Json::array(ms)
        p["names"] = { "claude-fable-5-1": "Fable 5.1", "claude-opus-5-5": "Opus 5.5", "claude-sonnet-5": "Sonnet 5", "claude-haiku-5": "Haiku 5" }
        p["series"] = [{ "name": "Claude", "models": Json::array(ms) }]
        Json::object(p)
      }
      Object(o) => {
        let p = o.copy()
        for k, x in o {
          p[k] = shaped(x)
        }
        if o.contains("lists") && o.contains("tiles") {
          // (in place of the fixture's own accounts)
          let lists = match o.get("lists") { Some(Array(a)) => a.filter(fn(l) {
                match l {
                  Object(m) => !(m.get("key") is Some(String("profiles")))
                  _ => true
                }
              }); _ => [] }
          lists.push({ "key": "profiles", "items": [{ "key": "ws1/st1/cc", "costText": "$1,735", "shareText": "64%", "callsText": "2.2 万", "tokensText": "49.7 亿", "topModel": "最多 Opus 5.5" }] })
          p["lists"] = Json::array(lists)
        }
        Json::object(p)
      }
      Array(a) => Json::array(a.map(shaped))
      _ => v
    }
  }
  {
    ..s,
    topic_read: fn(name, params) {
      let v = s.topic(name, params).get().snapshot()
      match v.value {
        Some(x) => { ..v, value: Some(shaped(x)) }
        None => v
      }
    },
  }
}

///|
test "a profile's page on a phone: its long name and how many models it runs, nothing squeezed" {
  for w in [326.0, 390.0] {
    let t = setting_tester(Profile("ws1/st1", "cc"), w, platform=2, over=long_profile, h=2400.0)
    // (its switches' words, beside their switches, are another's)
    let faults = t.squeeze_faults().filter(fn(f) { !f.contains("for what shares their row") })
    assert_eq(faults, [], msg=w.to_string() + faults.join("; "))
    assert_true(t.find("近 7 天") is None, msg="\{w}: usage removed from profile page")
    assert_true(t.find("4 个模型") is Some(_), msg="\{w}: 4 个模型")
  }
}

///|
test "a Devin profile's models panel asks Fusion pairs on demand, switches lead model chips, deduplicates ticked ones, and syncs pick.like" {
  let calls : Array[(String, Json)] = []
  let existing_uid = "fusion-gpt-6-sol-sidekick-claude-sonnet-5-5-medium"
  let fusion_catalog : Json = {
    "sides": [
      { "id": "swe-2-medium", "name": "SWE-2 · 中", "maker": { "id": "devin", "name": "Cognition" } },
      { "id": "claude-sonnet-5-5-medium", "name": "Sonnet 5.5 · 中", "maker": { "id": "anthropic", "name": "Anthropic" } },
    ],
    "leads": [
      {
        "id": "claude-opus-5-5",
        "name": "Opus 5.5",
        "maker": { "id": "anthropic", "name": "Anthropic" },
        "sides": [0],
      },
      {
        "id": "gpt-6-sol",
        "name": "GPT-6 Sol",
        "maker": { "id": "openai", "name": "OpenAI" },
        "sides": [0, 1],
      },
    ],
  }
  let fusion_profile = fn(s : Source) -> Source {
    fn shaped(v : Json) -> Json {
      match v {
        Object(o) if o.get("id") == Some(Json::string("cc")) && o.contains("available") => {
          let p = o.copy()
          p["runtime"] = "devin"
          p["models"] = ["gemini-4-carbon", existing_uid]
          p["named"] = [existing_uid]
          p["added"] = [existing_uid]
          p["modelsText"] = "2 个模型"
          p["available"] = ["gemini-4-carbon", existing_uid]
          p["names"] = {
            "gemini-4-carbon": "Gemini 4 Carbon",
            "fusion-gpt-6-sol-sidekick-claude-sonnet-5-5-medium": "GPT-6 Sol + Sonnet 5.5 (中)",
          }
          p["series"] = [
            { "name": "Gemini", "models": ["gemini-4-carbon"] },
            { "name": "Sol", "models": [existing_uid] },
          ]
          Json::object(p)
        }
        Object(o) => {
          let p = o.copy()
          for k, x in o {
            p[k] = shaped(x)
          }
          Json::object(p)
        }
        Array(a) => Json::array(a.map(shaped))
        _ => v
      }
    }
    fn shaped_pick(v : Json) -> Json {
      match v {
        Object(o) => {
          let p = o.copy()
          let opts = match o.get("options") {
            Some(Array(a)) => a.copy()
            _ => []
          }
          opts.push({ "model": existing_uid, "ids": [existing_uid], "liked": true })
          p["options"] = Json::array(opts)
          Json::object(p)
        }
        _ => v
      }
    }
    {
      ..s,
      topic_read: fn(name, params) {
        let v = s.topic(name, params).get().snapshot()
        match v.value {
          Some(x) => { ..v, value: Some(if name == "pick" { shaped_pick(x) } else { shaped(x) }) }
          None => v
        }
      },
      call: fn(name, params, done) {
        calls.push((name, params))
        if name == "profile.fusion" {
          done(Ok({ "fusion": fusion_catalog }))
        } else {
          done(Ok(obj([])))
        }
      },
    }
  }
  let t = setting_tester(Profile("ws1/st1", "cc"), 1280.0, over=fusion_profile)
  assert_eq(calls.length(), 0)
  scrolled_to(t, 1280.0, "可用模型")
  t.tap_text("可用模型")
  t.run_for(@motion.presence_in_ms)
  assert_eq(calls.map(fn(x) { x.0 }), ["profile.fusion"])
  assert_true(t.find("Fusion 组合") is Some(_))
  // Already-ticked Fusion pair from another lead (`gpt-6-sol`) is shown in `Fusion 组合`, not duplicated in top series.
  assert_true(t.find("GPT-6 Sol + Sonnet 5.5 (中)") is None)
  assert_true(t.find("GPT-6 Sol + Sonnet 5.5 · 中") is Some(_))
  assert_true(t.query(Checkbox, label="SWE-2 · 中") is Some(_))
  // Unchecking the already-ticked & liked pair removes it from `models` and clears `pick.like`.
  t.click(Checkbox, label="GPT-6 Sol + Sonnet 5.5 · 中")
  t.frame()
  assert_eq(calls.map(fn(x) { x.0 }), ["profile.fusion", "profile.put", "pick.like"])
  assert_true(!calls[1].1.stringify().contains(existing_uid), msg="profile.put drops \{existing_uid}: \{calls[1].1.stringify()}")
  assert_true(calls[2].1.stringify().contains("\"liked\":false"), msg="pick.like clears \{existing_uid}: \{calls[2].1.stringify()}")
  // Switching lead model chip to `GPT-6 Sol` and checking a sidekick saves it and stars it.
  // First verify Lead group is a single RadioGroup supporting arrow keys and sticky selection.
  assert_true(t.query(RadioGroup, label=@sf.t("web-pages.profiles.fusionLead")) is Some(_))
  assert_eq(t.get(Radio, label="Opus 5.5").check, Some(@view.Check::On))
  // Re-pressing already-selected lead keeps it selected.
  t.click(Radio, label="Opus 5.5")
  t.frame()
  assert_eq(t.get(Radio, label="Opus 5.5").check, Some(@view.Check::On))
  // Focusing Lead radio and pressing Right arrow moves to `GPT-6 Sol`, Left arrow moves back.
  t.act(Radio, Focus, label="Opus 5.5")
  t.frame()
  t.key(@ui.key_code_right)
  t.frame()
  assert_eq(t.get(Radio, label="GPT-6 Sol").check, Some(@view.Check::On))
  assert_eq(t.focused().map(fn(s) { s.label }), Some("GPT-6 Sol"))
  t.key(@ui.key_code_left)
  t.frame()
  assert_eq(t.get(Radio, label="Opus 5.5").check, Some(@view.Check::On))
  // Click `GPT-6 Sol` and check/uncheck a sidekick Checkbox chip.
  t.click(Radio, label="GPT-6 Sol")
  t.frame()
  assert_true(t.query(Checkbox, label="SWE-2 · 中") is Some(_))
  t.click(Checkbox, label="SWE-2 · 中")
  t.frame()
  assert_eq(calls.map(fn(x) { x.0 }), ["profile.fusion", "profile.put", "pick.like", "profile.put", "pick.like"])
  let uid = "fusion-gpt-6-sol-sidekick-swe-2-medium"
  assert_true(calls[3].1.stringify().contains(uid), msg="profile.put saves \{uid}: \{calls[3].1.stringify()}")
  assert_true(calls[4].1.stringify().contains("\"liked\":true"), msg="pick.like likes \{uid}: \{calls[4].1.stringify()}")
}

///|
test "profile page shows non-quota explanations and intermediate checking states" {
  // 1. Subscription with unsupported quota (e.g. Devin / Kimi Code) and no usedBy still shows the quota card and detail.
  let t_unsupported = setting_tester(Profile("ws1/st1", "cc"), 1280.0, over=fn(s) {
    fn shaped(v : Json) -> Json {
      match v {
        Object(o) if o.get("id") == Some(Json::string("cc")) => {
          let p = o.copy()
          p["quota"] = {
            "state": "unsupported",
            "detail": "Devin 不向 station 提供套餐用量，请在 app.devin.ai 的 Usage 页查看",
            "windows": [],
          }
          Json::object(p)
        }
        Object(o) if o.get("connects") is Some(_) => {
          let p = o.copy()
          for k, x in o {
            p[k] = shaped(x)
          }
          p["connects"] = Json::array([])
          p["presets"] = Json::array([])
          Json::object(p)
        }
        Object(o) => {
          let p = o.copy()
          for k, x in o {
            p[k] = shaped(x)
          }
          Json::object(p)
        }
        Array(a) => Json::array(a.map(shaped))
        _ => v
      }
    }
    {
      ..s,
      topic_read: fn(name, params) {
        let r = s.topic(name, params).get().snapshot()
        { ..r, value: r.value.map(shaped) }
      },
    }
  })
  assert_true(t_unsupported.find("额度") is Some(_))
  assert_true(t_unsupported.find("Devin 不向 station 提供套餐用量，请在 app.devin.ai 的 Usage 页查看") is Some(_))

  // 2. Subscription with unchecked quota (quota: null) shows 尚未查询额度, modelsReading shows 正在读取, and clicking 重新检查 dispatches both profile.check and profile.quota.
  let calls : Array[String] = []
  let t_unchecked = setting_tester(Profile("ws1/st1", "cc"), 1280.0, h=2400.0, over=fn(s) {
    fn shaped(v : Json) -> Json {
      match v {
        Object(o) if o.get("id") == Some(Json::string("cc")) => {
          let p = o.copy()
          p["quota"] = Json::null()
          p["available"] = Json::array([])
          p["modelsReading"] = Json::boolean(true)
          Json::object(p)
        }
        Object(o) => {
          let p = o.copy()
          for k, x in o {
            p[k] = shaped(x)
          }
          Json::object(p)
        }
        Array(a) => Json::array(a.map(shaped))
        _ => v
      }
    }
    {
      ..s,
      topic_read: fn(name, params) {
        let r = s.topic(name, params).get().snapshot()
        { ..r, value: r.value.map(shaped) }
      },
      call: fn(name, params, done) {
        if name == "profile.check" || name == "profile.quota" {
          calls.push(name)
        }
        (s.call)(name, params, done)
      },
    }
  })
  assert_true(t_unchecked.find("订阅账号 · Ultra") is Some(_))
  assert_true(t_unchecked.find("尚未查询额度") is Some(_))
  assert_true(t_unchecked.find("正在读取") is Some(_))
  t_unchecked.click(Button, label="重新检查")
  t_unchecked.frame()
  assert_eq(calls, ["profile.check", "profile.quota"])

  // 3. Plain API key with check.state == "ok" and quota.detail shows its capabilities in the facts line and quota.detail in the header state line without a quota card.
  let t_key = setting_tester(Profile("ws1/st1", "k2"), 1280.0, over=fn(s) {
    fn shaped(v : Json) -> Json {
      match v {
        Object(o) if o.get("id") == Some(Json::string("k2")) => {
          let p = o.copy()
          p["checkTone"] = Json::string("green")
          p["checkText"] = Json::string("可用")
          p["checkLine"] = Json::string("8 个模型")
          p["check"] = { "state": "ok", "time": { "checkedAt": { "ago": "5 分钟前" } } }
          p["quota"] = { "state": "unsupported", "detail": "按量计费，无额度上限", "windows": [] }
          Json::object(p)
        }
        Object(o) => {
          let p = o.copy()
          for k, x in o {
            p[k] = shaped(x)
          }
          Json::object(p)
        }
        Array(a) => Json::array(a.map(shaped))
        _ => v
      }
    }
    {
      ..s,
      topic_read: fn(name, params) {
        let r = s.topic(name, params).get().snapshot()
        { ..r, value: r.value.map(shaped) }
      },
    }
  })
  assert_true(t_key.find("API key · Anthropic") is Some(_))
  assert_true(t_key.find("可用于：") is Some(_))
  assert_true(t_key.find("Claude Code") is Some(_))
  assert_true(t_key.find("按量计费，无额度上限 · 5 分钟前检查") is Some(_))
  assert_true(t_key.boxes_held().filter(fn(b) { b.text == "额度" }).is_empty())
}

///|
test "a wide profile head aligns its 32 mark with the name's first line and starts the lines below at the mark's left edge" {
  let t = setting_tester(Profile("ws1/st1", "cc"), 1280.0)
  assert_eq(t.first_line_faults(), [])
  assert_eq(t.line_start_faults(), [])
  let name_word = t.words().filter(fn(w) { w.0 == "Claude 主账号" })[0]
  let facts_word = t.words().filter(fn(w) { w.0 == "订阅账号 · Ultra" })[0]
  let uses_word = t.words().filter(fn(w) { w.0 == "可用于：" })[0]
  let state_word = t.words().filter(fn(w) { w.0.contains("订阅有效") })[0]
  let mark_boxes = t.boxes_held().filter(fn(b) {
    (b.w - 32.0).abs() <= 0.5 &&
    (b.h - 32.0).abs() <= 0.5 &&
    b.x < name_word.1 &&
    (b.y - name_word.2).abs() < 20.0
  })
  assert_true(mark_boxes.length() > 0)
  let mark = mark_boxes[0]
  let mark_mid = mark.y + mark.h / 2.0
  let name_mid = name_word.2 + name_word.4 / 2.0
  assert_true(
    (mark_mid - name_mid).abs() <= 2.0,
    msg="mark_mid=\{mark_mid} name_mid=\{name_mid}",
  )
  assert_true(
    (facts_word.1 - mark.x).abs() <= 1.0,
    msg="facts_x=\{facts_word.1} mark_x=\{mark.x}",
  )
  assert_true(
    (uses_word.1 - mark.x).abs() <= 1.0,
    msg="uses_x=\{uses_word.1} mark_x=\{mark.x}",
  )
  assert_true(
    state_word.1 < name_word.1,
    msg="state_x=\{state_word.1} name_x=\{name_word.1}",
  )
}

///|
test "service profile hides model, fast, and env rows while keeping station controls and clean layout" {
  let svc : Json = {
    "id": "svc-gpu",
    "name": "GPU 节点账号",
    "email": "gpu@example.com",
    "runtime": null,
    "service": "fake-gpu",
    "runtimes": [],
    "access": { "kind": "service", "key": "", "service": "fake-gpu", "login": false },
    "usedBy": [],
    "loginCommand": "",
    "machine": false,
    "enabled": true,
    "fast": null,
    "check": { "state": "ok", "time": { "checkedAt": { "ago": "5 分钟前" } } },
    "login": null,
    "quota": null,
    "checkText": "可用",
    "checkTone": "green",
    "trouble": null,
    "makers": {},
    "names": {},
    "series": [],
    "modelsText": "尚未列出模型",
    "available": [],
    "added": [],
    "modelsReading": false,
    "uses": [],
    "canAddModel": false,
    "decisionOnly": false,
    "decisionModels": [],
    "share": null,
    "shareable": false,
    "workspaces": [],
    "kindText": "服务账号",
    "planText": "",
    "signInProvider": "",
    "checkLine": "连接正常",
  }
  let t = setting_tester(Profile("ws1/st1", "svc-gpu"), 1280.0, over=fn(s) {
    fn inject(v : Json) -> Json {
      match v {
        Object(o) => {
          let copy = o.copy()
          for k, val in o {
            copy[k] = if k == "profiles" && val is Array(arr) {
              Json::array(arr + [svc])
            } else {
              inject(val)
            }
          }
          Json::object(copy)
        }
        Array(a) => Json::array(a.map(inject))
        _ => v
      }
    }
    {
      ..s,
      topic_read: fn(name, params) {
        let r = s.topic(name, params).get().snapshot()
        { ..r, value: r.value.map(inject) }
      },
    }
  })
  assert_true(t.find("GPU 节点账号") is Some(_))
  assert_true(t.find("服务账号") is Some(_))
  assert_true(t.find("可用模型") is None, msg="service profile must not show availableModels")
  assert_true(t.find("默认 Fast") is None, msg="service profile must not show fast toggle")
  assert_true(t.find("编辑环境变量") is None, msg="service profile must not show env editor")
  scrolled_to(t, 1280.0, "分享给其他 station")
  assert_true(t.find("分享给其他 station") is Some(_), msg="service profile keeps sharing row")
  assert_eq(t.audit(), [])
}

///|
test "colab service profile shows CU credits, active VM note, and relogin on expired token" {
  let colab : Json = {
    "id": "colab-1",
    "name": "gpu@example.com",
    "email": "gpu@example.com",
    "runtime": null,
    "service": "colab",
    "runtimes": [],
    "access": { "kind": "service", "key": "", "service": "colab", "login": false },
    "usedBy": [],
    "loginCommand": "",
    "machine": false,
    "enabled": true,
    "fast": null,
    "check": { "state": "ok", "time": { "checkedAt": { "ago": "2 分钟前" } } },
    "login": null,
    "quota": {
      "state": "ok",
      "windows": [],
      "creditsText": "2,500 CU",
      "detail": "1 台运行中 · 10.05 CU/h",
      "time": { "checkedAt": { "ago": "2 分钟前" } },
    },
    "checkText": "可用",
    "checkTone": "green",
    "trouble": null,
    "makers": {},
    "names": {},
    "series": [],
    "modelsText": "尚未列出模型",
    "available": [],
    "added": [],
    "modelsReading": false,
    "uses": [],
    "providerName": "Google Colab",
    "providerMark": "colab",
    "canAddModel": false,
    "decisionOnly": false,
    "decisionModels": [],
    "share": null,
    "shareable": false,
    "workspaces": [],
    "kindText": "Google Colab",
    "planText": "",
    "signInProvider": "Google Colab",
    "checkLine": "已登录",
  }
  let t = setting_tester(Profile("ws1/st1", "colab-1"), 1280.0, over=fn(s) {
    fn inject(v : Json) -> Json {
      match v {
        Object(o) => {
          let copy = o.copy()
          for k, val in o {
            copy[k] = if k == "profiles" && val is Array(arr) {
              Json::array(arr + [colab])
            } else {
              inject(val)
            }
          }
          Json::object(copy)
        }
        Array(a) => Json::array(a.map(inject))
        _ => v
      }
    }
    {
      ..s,
      topic_read: fn(name, params) {
        let r = s.topic(name, params).get().snapshot()
        { ..r, value: r.value.map(inject) }
      },
    }
  })
  assert_true(t.find("gpu@example.com") is Some(_))
  assert_true(t.find("Google Colab") is Some(_))
  assert_true(t.find("2,500 CU") is Some(_), msg="colab profile must show CU balance")
  assert_true(t.find("1 台运行中 · 10.05 CU/h") is Some(_), msg="colab profile must show active VM note")
  assert_true(t.find("无可用额度信息") is None, msg="colab credits row must not fall back to no-quota row")
  assert_true(t.find("可用模型") is None)
  assert_true(t.find("默认 Fast") is None)
  assert_true(t.find("编辑环境变量") is None)
  assert_eq(t.audit(), [])

  // Token expired: check.state == "login" shows sign-in block with primary login button
  let expired : Json = {
    "id": "colab-exp",
    "name": "expired@example.com",
    "email": "expired@example.com",
    "runtime": null,
    "service": "colab",
    "runtimes": [],
    "access": { "kind": "service", "key": "", "service": "colab", "login": false },
    "usedBy": [],
    "loginCommand": "",
    "machine": false,
    "enabled": true,
    "fast": null,
    "check": { "state": "login", "time": { "checkedAt": { "ago": "刚刚" } } },
    "login": null,
    "quota": null,
    "checkText": "需要登录",
    "checkTone": "red",
    "trouble": {
      "title": "需要登录",
      "detail": "未登录",
      "next": "重新登录以继续使用",
      "action": "login",
      "label": "重新登录",
    },
    "makers": {},
    "names": {},
    "series": [],
    "modelsText": "尚未列出模型",
    "available": [],
    "added": [],
    "modelsReading": false,
    "uses": [],
    "providerName": "Google Colab",
    "providerMark": "colab",
    "canAddModel": false,
    "decisionOnly": false,
    "decisionModels": [],
    "share": null,
    "shareable": false,
    "workspaces": [],
    "kindText": "Google Colab",
    "planText": "",
    "signInProvider": "Google Colab",
    "checkLine": "未登录",
  }
  let t2 = setting_tester(Profile("ws1/st1", "colab-exp"), 1280.0, over=fn(s) {
    fn inject(v : Json) -> Json {
      match v {
        Object(o) => {
          let copy = o.copy()
          for k, val in o {
            copy[k] = if k == "profiles" && val is Array(arr) {
              Json::array(arr + [expired])
            } else {
              inject(val)
            }
          }
          Json::object(copy)
        }
        Array(a) => Json::array(a.map(inject))
        _ => v
      }
    }
    {
      ..s,
      topic_read: fn(name, params) {
        let r = s.topic(name, params).get().snapshot()
        { ..r, value: r.value.map(inject) }
      },
    }
  })
  assert_true(t2.find("登录") is Some(_), msg="expired colab profile must show sign-in card")
  assert_eq(t2.audit(), [])
}

///|
test "profiles list aggregates Google Colab under Google group and add profile flow picks colab method" {
  let agy_item : Json = {
    "key": "agy-lin@example.com",
    "group": "agy",
    "groupTitle": "Google",
    "title": "lin@example.com",
    "usable": true,
    "station": "ws1/st1",
    "stationName": "Willow",
    "state": { "text": "", "tone": "neutral" },
    "profile": {
      "id": "agy-1",
      "name": "lin@example.com",
      "runtime": "agy",
      "access": { "kind": "subscription" },
      "providerMark": "gemini",
      "kindText": "Google 订阅",
      "planText": "Ultra 5x",
      "quota": { "state": "ok", "windows": [] },
    },
  }
  let colab_item : Json = {
    "key": "colab-lin@example.com",
    "group": "agy",
    "groupTitle": "Google",
    "title": "lin@example.com",
    "usable": true,
    "station": "ws1/st1",
    "stationName": "Willow",
    "state": { "text": "", "tone": "neutral" },
    "profile": {
      "id": "colab-1",
      "name": "lin@example.com",
      "runtime": null,
      "service": "colab",
      "access": { "kind": "service", "service": "colab" },
      "providerMark": "colab",
      "kindText": "Google Colab",
      "planText": "",
      "quota": {
        "state": "ok",
        "windows": [],
        "creditsText": "2,500 CU",
        "detail": "1 台运行中 · 10.05 CU/h",
      },
    },
  }
  let t_list = setting_tester(Profiles(""), 1280.0, over=fn(s) {
    fn inject_list(v : Json) -> Json {
      match v {
        Object(o) => {
          let copy = o.copy()
          for k, val in o {
            copy[k] = if k == "items" && val is Array(arr) {
              Json::array(arr + [agy_item, colab_item])
            } else {
              inject_list(val)
            }
          }
          Json::object(copy)
        }
        Array(a) => Json::array(a.map(inject_list))
        _ => v
      }
    }
    {
      ..s,
      topic_read: fn(name, params) {
        let r = s.topic(name, params).get().snapshot()
        if name == "profiles" {
          { ..r, value: r.value.map(inject_list) }
        } else {
          r
        }
      },
    }
  })
  assert_true(t_list.find("Google") is Some(_), msg="profiles list shows Google group")
  assert_true(t_list.find("Ultra 5x") is Some(_), msg="profiles list shows Antigravity CLI row")
  assert_true(t_list.find("Google Colab") is Some(_), msg="profiles list shows Google Colab tag on Colab row")
  assert_true(t_list.find("2,500 CU · 1 台运行中 · 10.05 CU/h") is Some(_), msg="profiles list shows CU balance and active VM detail")
  assert_eq(t_list.audit(), [])

  // Add profile flow: Google method step shows Google Colab option and sends profile.flow.edit(method: "colab")
  let edit_calls : Array[Json] = []
  let method_view : Json = {
    "step": "method",
    "title": "连接 Google",
    "tile": {
      "id": "google",
      "name": "Google",
      "kind": "api-provider",
      "runtime": "agy",
      "service": "colab",
      "mark": "gemini",
      "hasPlan": true,
      "hasKey": true,
    },
    "groups": [],
    "choices": [
      { "id": "plan", "title": "订阅 · Google AI", "hint": "Antigravity CLI" },
      { "id": "enterprise", "title": "企业版 · Gemini Enterprise", "hint": "Gemini Enterprise" },
      { "id": "colab", "title": "Google Colab", "hint": "Google Colab / AI Ultra 账号，用于 GPU 算力任务" },
      { "id": "key", "title": "API key", "hint": "使用 Google Gemini 的 API key，按量计费" },
    ],
    "signIn": null,
    "showKey": false,
    "showEndpoint": false,
    "protocols": [],
    "regions": [],
    "canSubmit": false,
    "pending": false,
    "error": null,
  }
  let t_method = setting_tester(NewProfile("ws1/st1"), 1280.0, over=fn(s) {
    {
      ..s,
      topic_read: fn(name, params) {
        if name == "profileFlow" {
          { value: Some(method_view), version: 1, error: None }
        } else {
          s.topic(name, params).get().snapshot()
        }
      },
      call: fn(name, params, done) {
        if name == "profile.flow.edit" {
          edit_calls.push(params)
          done(Ok(obj([])))
        } else {
          (s.call)(name, params, done)
        }
      },
    }
  })
  assert_true(t_method.find("Google Colab") is Some(_), msg="Google method step shows Google Colab choice")
  assert_eq(t_method.audit(), [])
  t_method.tap_text("Google Colab")
  t_method.frame()
  assert_eq(edit_calls.length(), 1, msg="tapping Google Colab calls profile.flow.edit")
  assert_eq(text(field(Some(edit_calls[0]), "input"), "method"), "colab")

  // Connect step for Google Colab (method=colab) starts login.new with service=colab (no runtime)
  let login_calls : Array[Json] = []
  let connect_view : Json = {
    "step": "connect",
    "method": "colab",
    "title": "连接 Google Colab",
    "groups": [],
    "choices": [],
    "signIn": { "service": "colab", "provider": "Google Colab" },
    "usesLine": "添加后可用于 Google Colab GPU 算力任务",
    "showKey": false,
    "showEndpoint": false,
    "protocols": [],
    "regions": [],
    "canSubmit": false,
    "pending": false,
    "error": null,
  }
  let t_conn = setting_tester(NewProfile("ws1/st1"), 1280.0, over=fn(s) {
    {
      ..s,
      topic_read: fn(name, params) {
        if name == "profileFlow" {
          { value: Some(connect_view), version: 1, error: None }
        } else {
          s.topic(name, params).get().snapshot()
        }
      },
      call: fn(name, params, done) {
        if name == "login.new" {
          login_calls.push(params)
          done(Ok({ "id": "job-colab-1" }))
        } else {
          (s.call)(name, params, done)
        }
      },
    }
  })
  assert_true(t_conn.find("Google Colab GPU 算力任务") is Some(_), msg="connect step shows usesLine")
  assert_eq(login_calls.length(), 1, msg="connect step starts login.new")
  assert_eq(text(Some(login_calls[0]), "service"), "colab", msg="login.new passes service=colab")
  assert_eq(field(Some(login_calls[0]), "runtime"), None, msg="login.new omits runtime for service")
  assert_eq(t_conn.audit(), [])
}

///|
test "a key's profile with no allowance shown, wide: the connect using it sits in the middle of its card" {
  // (k2 shows no allowance; one connect uses it here)
  let t = setting_tester(Profile("ws1/st1", "k2"), 1280.0, over=fn(s) {
    fn inject(v : Json) -> Json {
      match v {
        Object(o) => {
          let copy = o.copy()
          for k, val in o {
            copy[k] = inject(val)
          }
          if o.get("id") == Some(Json::string("k2")) && o.contains("usedBy") {
            copy["usedBy"] = ["k1"]
          }
          Json::object(copy)
        }
        Array(a) => Json::array(a.map(inject))
        _ => v
      }
    }
    {
      ..s,
      topic_read: fn(name, params) {
        let r = s.topic(name, params).get().snapshot()
        { ..r, value: r.value.map(inject) }
      },
    }
  })
  scrolled_to(t, 1280.0, "星火助手")
  guard t.find("星火助手") is Some((x, y)) else { fail("no connect row: \{Repr(t.words().map(fn(w) { w.0 }))}") }
  // (the card it is on: the least drawn ground round its name as tall as a row and its padding at least)
  let card = t
    .drawn_rects()
    .filter(fn(r) { r.0 <= x && x <= r.0 + r.2 && r.1 <= y && y <= r.1 + r.3 && r.3 >= 40.0 && r.3 < 120.0 })
    .fold(init=None, fn(a : (Double, Double, Double, Double, Int64)?, r) {
      match a {
        Some(b) if b.2 * b.3 <= r.2 * r.3 => a
        _ => Some(r)
      }
    })
  guard card is Some(c) else { fail("no card round 星火助手") }
  let off = y - (c.1 + c.3 / 2.0)
  assert_true(off.abs() < 0.5, msg="its name \{off} off its card's middle: \{Repr(c)}, at \{y}")
  assert_eq(t.audit(), [])
}

///|
/// The fixture with each of its overviews' sharing said by a station from before `shareAllowAuto` (`auto_ok` false), or
/// its Claude subscription's share following the workspace's whitelist (`follows`).
fn with_share_auto(s : Source, auto_ok? : Bool = true, follows? : Bool = false) -> Source {
  fn shaped(v : Json, auto_ok : Bool, follows : Bool) -> Json {
    match v {
      Object(o) => {
        let p = o.copy()
        for k, x in o {
          p[k] = shaped(x, auto_ok, follows)
        }
        if !auto_ok {
          p.remove("shareAllowAuto")
        }
        if follows && o.get("id") == Some(Json::string("cc")) && o.get("share") is Some(Object(sh)) {
          let share = sh.copy()
          share["allowAuto"] = Json::boolean(true)
          share["allow"] = Json::array([Json::string("st1"), Json::string("st2")])
          p["share"] = Json::object(share)
        }
        Json::object(p)
      }
      Array(a) => Json::array(a.map(fn(x) { shaped(x, auto_ok, follows) }))
      _ => v
    }
  }
  {
    ..s,
    topic_read: fn(name, params) {
      let v = s.topic(name, params).get().snapshot()
      match v.value {
        Some(x) => { ..v, value: Some(shaped(x, auto_ok, follows)) }
        None => v
      }
    },
  }
}

///|
/// Three stations of the workspace, Maple alone on its whitelist (it takes automatically assigned chats).
let whitelisted_three : Array[Json] = [
  { "id": "st1", "name": "Willow", "online": true, "acceptAutoChats": false },
  { "id": "st2", "name": "Maple", "online": true, "acceptAutoChats": true },
  { "id": "st3", "name": "Birch", "online": true, "acceptAutoChats": false },
]

///|
test "可用的 station follows the workspace's whitelist: the rows show those on it, one ticked by hand chooses by hand" {
  for case in page_cases {
    let (w, platform) = case
    let asked : Array[Json] = []
    let t = setting_tester(Profile("ws1/st1", "cc"), w, platform~, h=2400.0, over=fn(base) {
      let s = with_share_stations(with_share_auto(base), whitelisted_three)
      { ..s, call: fn(name, params, done) {
        if name == "profile.share" {
          asked.push(params)
          done(Ok(obj([])))
        } else {
          (s.call)(name, params, done)
        }
      } }
    })
    let at = "\{w} platform \{platform}"
    scrolled_to(t, w, "可用的 station")
    t.tap_text("可用的 station")
    presented_in(t)
    assert_eq(t.get(Switch, label="全部 station").check, Some(On), msg=at)
    assert_eq(t.get(Switch, label="跟随工作区白名单").check, Some(Off), msg=at)
    assert_false(t.get(Switch, label="跟随工作区白名单").disabled, msg=at)
    assert_true(t.find("白名单内现有 1 台 station，随白名单同步") is Some(_), msg=at)
    // On: every station off, the rows those on the whitelist (and this one, always)
    t.click(Switch, label="跟随工作区白名单")
    t.run_for(@ui.move_most_ms)
    assert_eq(t.get(Switch, label="跟随工作区白名单").check, Some(On), msg=at)
    assert_eq(t.get(Switch, label="全部 station").check, Some(Off), msg=at)
    assert_eq(t.get(Switch, label="Willow").check, Some(On), msg=at)
    assert_eq(t.get(Switch, label="Maple").check, Some(On), msg=at)
    assert_eq(t.get(Switch, label="Birch").check, Some(Off), msg=at)
    assert_eq(t.audit(), [], msg="\{at}: " + t.audit().join("; "))
    t.click(Button, label="完成")
    t.run_for(@motion.presence_out_ms)
    assert_eq(asked.length(), 1, msg=at)
    assert_eq(field(Some(asked[0]), "allowAuto"), Some(Json::boolean(true)), msg=at)
    assert_eq(field(Some(asked[0]), "allow"), None, msg="\{at}: a rule, no list")
    assert_eq(field(Some(asked[0]), "among"), None, msg=at)
    // Following it, then Maple ticked off by hand: chosen by hand, the rest as it was
    t.tap_text("可用的 station")
    presented_in(t)
    t.click(Switch, label="跟随工作区白名单")
    t.frame()
    t.click(Switch, label="Maple")
    t.run_for(@ui.move_most_ms)
    assert_eq(t.get(Switch, label="跟随工作区白名单").check, Some(Off), msg=at)
    assert_eq(t.get(Switch, label="Maple").check, Some(Off), msg=at)
    t.click(Button, label="完成")
    t.run_for(@motion.presence_out_ms)
    assert_eq(asked.length(), 2, msg=at)
    assert_eq(field(Some(asked[1]), "allowAuto"), None, msg=at)
    assert_eq(field(Some(asked[1]), "allow"), Some(Json::array([Json::string("st1")])), msg=at)
  }
}

///|
test "a share following the whitelist says so on its page and opens following it; a station from before offers it not, saying why" {
  for case in page_cases {
    let (w, platform) = case
    let at = "\{w} platform \{platform}"
    let t = setting_tester(Profile("ws1/st1", "cc"), w, platform~, h=2400.0, over=fn(base) {
      with_share_stations(with_share_auto(base, follows=true), whitelisted_three)
    })
    scrolled_to(t, w, "可用的 station")
    assert_true(t.find("跟随工作区白名单") is Some(_), msg="\{at}: its row's value")
    t.tap_text("可用的 station")
    presented_in(t)
    assert_eq(t.get(Switch, label="跟随工作区白名单").check, Some(On), msg=at)
    assert_eq(t.get(Switch, label="Maple").check, Some(On), msg=at)
    assert_eq(t.get(Switch, label="Birch").check, Some(Off), msg=at)
    assert_eq(t.audit(), [], msg="\{at}: " + t.audit().join("; "))
    let old = setting_tester(Profile("ws1/st1", "cc"), w, platform~, h=2400.0, over=fn(base) {
      with_share_stations(with_share_auto(base, auto_ok=false), whitelisted_three)
    })
    scrolled_to(old, w, "可用的 station")
    old.tap_text("可用的 station")
    presented_in(old)
    assert_true(old.get(Switch, label="跟随工作区白名单").disabled, msg=at)
    assert_true(old.find("该 station 版本较旧，更新后可用") is Some(_), msg=at)
  }
}

///|
test "多选 shares several accounts and sets their stations at once, and stops sharing those shared, once asked" {
  for case in page_cases {
    let (w, platform) = case
    let at = "\{w} platform \{platform}"
    let asked : Array[Json] = []
    let t = setting_tester(Profiles(""), w, platform~, h=1400.0, over=fn(base) {
      let s = with_titled(with_share_auto(base), "cc", "lin@claude.example")
      { ..s, call: fn(name, params, done) {
        if name == "profile.share" {
          asked.push(params)
          done(Ok(obj([])))
        } else {
          (s.call)(name, params, done)
        }
      } }
    })
    t.click(Button, label="多选")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("已选 0 项") is Some(_), msg=at)
    // (each row named as it was out of 多选: its profile's name, not the account's title)
    assert_true(t.find("Claude 主账号") is Some(_) && t.find("lin@claude.example") is None, msg="\{at}: a row keeps its name")
    assert_true(t.get(Button, label="分享与 station").disabled, msg="\{at}: nothing picked")
    assert_true(t.get(Button, label="停止分享").disabled, msg=at)
    // a key and the shared subscription: 分享与 station
    t.tap_text("Claude 主账号")
    t.tap_text("备用 key")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("已选 2 项") is Some(_), msg=at)
    assert_false(t.get(Button, label="分享与 station").disabled, msg=at)
    assert_false(t.get(Button, label="停止分享").disabled, msg=at)
    assert_eq(t.audit(), [], msg="\{at}: " + t.audit().join("; "))
    t.click(Button, label="分享与 station")
    presented_in(t)
    assert_true(t.find("将应用于 2 个 Profile") is Some(_), msg=at)
    assert_true(t.find("将为未分享的账号开启分享，并统一设置可用 station") is Some(_), msg=at)
    t.click(Switch, label="跟随工作区白名单")
    t.run_for(@ui.move_most_ms)
    assert_eq(t.audit(), [], msg="\{at}: " + t.audit().join("; "))
    t.click(Button, label="完成")
    t.run_for(@motion.presence_out_ms)
    assert_eq(asked.length(), 2, msg=at)
    for a in asked {
      assert_eq(text(Some(a), "station"), "ws1/st1", msg=at)
      assert_eq(field(Some(a), "allowAuto"), Some(Json::boolean(true)), msg=at)
    }
    assert_true(t.find("已更新 2 个 Profile") is Some(_) || t.query(Button, label="多选") is Some(_), msg="\{at}: done, 多选 over")
    // stopping: only those shared asked, after a confirmation
    t.click(Button, label="多选")
    t.run_for(@ui.move_most_ms)
    t.tap_text("Claude 主账号")
    t.tap_text("备用 key")
    t.frame()
    t.click(Button, label="停止分享")
    presented_in(t)
    assert_eq(asked.length(), 2, msg="\{at}: asked first")
    assert_true(t.find("停止分享 1 个账号？") is Some(_), msg="\{at}: the key not shared is left as it is")
    // (the confirmation's own 停止分享: the last of them, over the bar's)
    let stops = t.all(Button, label="停止分享")
    let (x, y, bw, bh) = stops[stops.length() - 1].rect
    t.tap(x + bw / 2.0, y + bh / 2.0)
    t.run_for(@motion.presence_out_ms)
    assert_eq(asked.length(), 3, msg=at)
    assert_eq(field(Some(asked[2]), "on"), Some(Json::boolean(false)), msg=at)
    assert_eq(text(Some(asked[2]), "id"), "cc", msg=at)
  }
}

///|
/// The fixture's `profiles` rows with the account of profile `id` titled `title` (an account's email, not its profile's
/// name), and that row made one 多选 cannot take on the workspace's list (signed in on several stations), as the core
/// says it of one: `several`.
fn with_titled(s : Source, id : String, title : String, several? : Bool = false) -> Source {
  fn shaped(v : Json, id : String, title : String, several : Bool) -> Json {
    match v {
      Object(o) => {
        let p = o.copy()
        for k, x in o {
          p[k] = shaped(x, id, title, several)
        }
        if o.contains("canBatchShare") && text(field(Some(v), "profile"), "id") == id {
          p["title"] = Json::string(title)
          if several {
            p["canBatchShare"] = Json::boolean(false)
            p["batchShareWhy"] = Json::string("several")
          }
        }
        Json::object(p)
      }
      Array(a) => Json::array(a.map(fn(x) { shaped(x, id, title, several) }))
      _ => v
    }
  }
  {
    ..s,
    topic_read: fn(name, params) {
      let v = s.topic(name, params).get().snapshot()
      match v.value {
        Some(x) if name == "profiles" => { ..v, value: Some(shaped(x, id, title, several)) }
        _ => v
      }
    },
  }
}

///|
test "多选 is over as 概览 is shown, and a station's own page takes its account though the workspace's list cannot (signed in on several)" {
  for case in page_cases {
    let (w, platform) = case
    let at = "\{w} platform \{platform}"
    let t = setting_tester(Profiles(""), w, platform~, h=1400.0, over=fn(base) { with_share_auto(base) })
    t.click(Button, label="多选")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("已选 0 项") is Some(_), msg=at)
    // (概览 shown, as its tab says it once its pools are read: the page's own signal, then back to 账号)
    @settings.profiles_narrow_overview.set(true)
    t.run_for(@ui.move_most_ms)
    @settings.profiles_narrow_overview.set(false)
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("已选 0 项") is None, msg="\{at}: 多选 over with 概览")
    // a station's own page: its own profile, whatever the workspace's list says of the account
    let one = setting_tester(Profiles("ws1/st1"), w, platform~, h=1400.0, over=fn(base) {
      with_titled(with_share_auto(base), "cc", "Claude 主账号", several=true)
    })
    one.click(Button, label="多选")
    one.run_for(@ui.move_most_ms)
    one.tap_text("Claude 主账号")
    one.run_for(@ui.move_most_ms)
    assert_true(one.find("已选 1 项") is Some(_), msg="\{at}: this station's own, taken here")
    assert_true(one.find("多台 station 独立登录，请点进分别设置") is None, msg=at)
    assert_eq(one.audit(), [], msg="\{at}: " + one.audit().join("; "))
  }
}

///|
test "profiles_batch_foot_node (page=true): liquid glass card with outside shadow, 1pt solid fallback, 0 corner faults, reverse-wrap height, and last row scrollable clear of bar" {
  for dark in [false, true] {
    for case in [(900.0, 0), (390.0, 2)] {
      let (w, platform) = case
      let at = "dark=\{dark} w=\{w} platform=\{platform}"
      let t = setting_tester(Profiles(""), w, platform~, h=640.0, over=fn(base) { with_share_auto(base) })
      // Set dark after setting_tester (Tester::new calls reset_globals) and assert theme().dark actually matches
      @sf.set_dark(Some(dark))
      @ui.set_glass_solid(None)
      t.draw()
      assert_eq(@sf.theme().dark, dark, msg="\{at}: theme().dark must match")
      t.click(Button, label="多选")
      t.run_for(@ui.move_most_ms)
      assert_true(t.find("已选 0 项") is Some(_), msg=at)
      let share_btn = t.get(Button, label="分享与 station")
      let stop_btn = t.get(Button, label="停止分享")
      // Card sits at the bottom of the viewport
      let bar_glass = t.drawn_glass().filter(fn(g) { g.1 + g.3 > 450.0 && g.2 > 200.0 })
      let bar_liquid = bar_glass.filter(fn(g) { g.4 == 6 })
      let bar_shadow = t
        .drawn_instances()
        .iter()
        .any(fn(a) { a.length() > 12 && a[5] == 2.0 && a[12] == 1.0 && a[1] + a[3] > 450.0 && a[2] > 200.0 })
      assert_eq((at, bar_glass.length(), bar_liquid.length(), bar_shadow), (at, 1, 1, true))
      // Direct 0 corner fault assertion on the batch bar card
      assert_eq(t.corner_faults(), [], msg="\{at}: corner faults")
      // Buttons stay inside the glass card with proper concentric inset
      let g = bar_liquid[0]
      assert_true(
        share_btn.rect.0 >= g.0 + 4.0 &&
        share_btn.rect.1 + share_btn.rect.3 <= g.1 + g.3 - 4.0 &&
        stop_btn.rect.0 >= g.0 + 4.0 &&
        stop_btn.rect.1 + stop_btn.rect.3 <= g.1 + g.3 - 4.0,
        msg="\{at}: buttons inside card g=\{Repr(g)} share=\{Repr(share_btn.rect)} stop=\{Repr(stop_btn.rect)}",
      )
      // On narrow 320pt at 1.3x font scale: reverse-wrap strictly puts primary button on the lower row,
      // and scrolling in that same narrow wrapped state must bring the true last row ("使用此账号") completely above bar_top
      if w <= 390.0 {
        t.resize(320.0, 640.0)
        t.set_font_scale(1.3)
        t.run_for(@ui.move_most_ms)
        let s2 = t.get(Button, label="分享与 station")
        let st2 = t.get(Button, label="停止分享")
        assert_true(
          s2.rect.1 > st2.rect.1 + 1.0,
          msg="\{at}: reverse-wrap must put primary strictly on lower row: share=\{Repr(s2.rect)} stop=\{Repr(st2.rect)}",
        )
        assert_eq(t.corner_faults(), [], msg="\{at}: 320pt 1.3x corner faults")
        for _ in 0..<12 {
          t.wheel(160.0, 200.0, 200.0)
        }
        t.run_for(@ui.move_most_ms)
        let narrow_bar_top = t.drawn_glass().filter(fn(gl) { gl.1 + gl.3 > 400.0 && gl.2 > 200.0 })[0].1
        guard t.query(Button, label="使用此账号") is Some(last_btn) else {
          fail("\{at}: narrow wrapped last row (使用此账号) not found after scrolling")
        }
        let cx = last_btn.rect.0 + last_btn.rect.2 / 2.0
        let cy = last_btn.rect.1 + last_btn.rect.3 / 2.0
        let cards = t
          .boxes_held()
          .filter(fn(b) {
            b.bg != 0L && b.radius >= 8.0 && b.h < 400.0 && b.w > last_btn.rect.2 + 20.0 && b.x <= cx && cx <= b.x + b.w && b.y <= cy && cy <= b.y + b.h
          })
        guard cards.length() > 0 else {
          fail("\{at}: narrow wrapped Codex last card enclosing 使用此账号 not found")
        }
        let mut last_card = cards[0]
        for c in cards {
          if c.h < last_card.h {
            last_card = c
          }
        }
        let card_bottom = last_card.y + last_card.h
        assert_true(
          card_bottom > last_btn.rect.1 + last_btn.rect.3 + 10.0,
          msg="\{at}: narrow Codex card bottom \{card_bottom} must include below-button lines past \{last_btn.rect.1 + last_btn.rect.3}",
        )
        assert_true(
          card_bottom <= narrow_bar_top,
          msg="\{at}: narrow wrapped Codex card bottom \{card_bottom} must be <= bar_top \{narrow_bar_top}",
        )
        t.set_font_scale(1.0)
        t.resize(w, 640.0)
        t.run_for(@ui.move_most_ms)
      } else {
        // Wide: scroll down and strictly assert the full Codex last card bottom clears bar_top
        for _ in 0..<12 {
          t.wheel(w / 2.0, 200.0, 200.0)
        }
        t.run_for(@ui.move_most_ms)
        let wide_bar_top = t.drawn_glass().filter(fn(gl) { gl.1 + gl.3 > 450.0 && gl.2 > 200.0 })[0].1
        guard t.query(Button, label="使用此账号") is Some(last_btn) else {
          fail("\{at}: wide last row (使用此账号) not found after scrolling")
        }
        let cx = last_btn.rect.0 + last_btn.rect.2 / 2.0
        let cy = last_btn.rect.1 + last_btn.rect.3 / 2.0
        let cards = t
          .boxes_held()
          .filter(fn(b) {
            b.bg != 0L && b.radius >= 8.0 && b.h < 400.0 && b.w > last_btn.rect.2 + 20.0 && b.x <= cx && cx <= b.x + b.w && b.y <= cy && cy <= b.y + b.h
          })
        guard cards.length() > 0 else {
          fail("\{at}: wide Codex last card enclosing 使用此账号 not found")
        }
        let mut last_card = cards[0]
        for c in cards {
          if c.h < last_card.h {
            last_card = c
          }
        }
        let card_bottom = last_card.y + last_card.h
        assert_true(
          card_bottom > last_btn.rect.1 + last_btn.rect.3 + 10.0,
          msg="\{at}: wide Codex card bottom \{card_bottom} must include below-button lines past \{last_btn.rect.1 + last_btn.rect.3}",
        )
        assert_true(
          card_bottom <= wide_bar_top,
          msg="\{at}: wide Codex card bottom \{card_bottom} must be <= bar_top \{wide_bar_top}",
        )
      }
      // MBUI_GLASS=solid fallback: 0 glass + 1pt border
      @ui.set_glass_solid(Some(true))
      t.draw()
      t.run_for(@ui.move_most_ms)
      assert_eq(@sf.theme().dark, dark, msg="\{at}: solid theme().dark must match")
      let solid_glass = t.drawn_glass().filter(fn(gl) { gl.1 + gl.3 > 450.0 && gl.2 > 200.0 })
      let solid_edges = t
        .boxes_held()
        .filter(fn(b) { b.border_w >= 0.9 && b.y + b.h > 450.0 && b.w > 200.0 })
        .map(fn(b) { b.border_w })
      assert_eq((at, solid_glass.length(), solid_edges), (at, 0, [1.0]))
      assert_eq(t.corner_faults(), [], msg="\{at}: solid corner faults")
      @ui.set_glass_solid(None)
    }
  }
  @ui.set_glass_solid(None)
  @sf.set_dark(None)
}
