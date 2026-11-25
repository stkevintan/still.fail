// 权限, 归档 and a station's own archiving (permissions.mbt) alone, at each width, with a finger and with a mouse: what
// each station does and each way to choose saves is the core's.

///|
test "权限, at each width and with either hand: notifications, what they are for and whether they are allowed, on a card" {
  for case in page_cases {
    let (w, platform) = case
    let t = setting_tester(Permissions, w, platform~)
    let at = "\{w} platform \{platform}"
    assert_true(t.find("通知") is Some(_), msg=at)
    assert_true(t.find("已允许") is Some(_), msg=at)
  }
}

///|
test "归档, at each width and with either hand: the hint, its three ways, each station a row saying how it archives; its row opens its page" {
  for case in page_cases {
    let (w, platform) = case
    let t = setting_tester(Archiving, w, platform~)
    let at = "\{w} platform \{platform}"
    assert_true(t.find("提示归档") is Some(_), msg=at)
    assert_true(t.find("按模型判断") is Some(_), msg=at)
    assert_true(t.find("空闲就归档 · 1 天 · Slack：3 天") is Some(_), msg=at)
    t.tap_text("Willow")
    t.run_for(@ui.move_most_ms)
    assert_true(app.nav.top() == Setting(StationArchiving("ws1/st1")), msg=at)
  }
}

///|
test "a station's archiving, at each width and with either hand: its review, its way, how long idle, Slack's; a way chosen saves what the core says it saves" {
  for case in page_cases {
    let (w, platform) = case
    let saved : Array[Json] = []
    let keep = fn(base : Source) -> Source {
      {
        ..base,
        call: fn(name, params, done) {
          if name == "archiving.save" {
            saved.push(params)
          }
          (base.call)(name, params, done)
        },
      }
    }
    let t = setting_tester(StationArchiving("ws1/st1"), w, platform~, over=keep)
    let at = "\{w} platform \{platform}"
    assert_true(t.find("已开启 · GPT-6 mini") is Some(_), msg=at)
    assert_true(t.find("空闲多久") is Some(_), msg=at)
    assert_true(t.find("只在 Slack 里的对话") is Some(_), msg=at)
    // 按模型判断 chosen: the days kept, reviewed (the core's `modes`)
    t.tap_text("按模型判断")
    t.draw()
    t.draw()
    assert_eq(saved.length(), 1, msg=at)
    assert_eq(field(Some(saved[0]), "reviewed"), Some(Json::boolean(true)), msg=at)
    assert_eq(number(Some(saved[0]), "days"), 1.0, msg=at)
  }
}

///|
fn archiving_patch(
  v : Json,
  mode_name : String,
  days : Double,
  slack_days : Double,
  reviewed : Bool,
) -> Json {
  match v {
    Object(o) => {
      let copy = o.copy()
      if copy.get("overview") is Some(Object(ov)) {
        let ov_copy = ov.copy()
        if ov_copy.get("archiving") is Some(Object(ar)) {
          let ar_copy = ar.copy()
          ar_copy["mode"] = Json::string(mode_name)
          ar_copy["days"] = Json::number(days)
          ar_copy["slackDays"] = Json::number(slack_days)
          ar_copy["reviewed"] = Json::boolean(reviewed)
          ov_copy["archiving"] = Json::object(ar_copy)
        }
        copy["overview"] = Json::object(ov_copy)
      }
      Json::object(copy)
    }
    _ => v
  }
}

///|
test "a station's archiving: delayed save holds optimistic radio and capsule, settles on Ok+topic, and reverts on async or sync Err" {
  let mode_visuals = fn(t : @ui.Tester, r_left : (Double, Double, Double, Double), r_right : (Double, Double, Double, Double)) {
    let lifted_rgb = @ui.tree_theme().lifted >> 8
    let rects = t
      .drawn_rects()
      .filter(fn(d) {
        (d.4 >> 8) == lifted_rgb &&
        (d.4 & 0xFFL) > 0x40L &&
        (d.3 - r_left.3).abs() < 2.0 &&
        d.1 >= r_left.1 - 4.0 &&
        d.1 <= r_left.1 + r_left.3 &&
        d.0 >= r_left.0 - 4.0 &&
        d.0 + d.2 <= r_right.0 + r_right.2 + 4.0
      })
    let cy = r_left.1 + r_left.3 / 2.0
    let glasses = t
      .drawn_glass()
      .filter(fn(g) {
        ((g.1 + g.3 / 2.0) - cy).abs() < 4.0 &&
        g.0 + g.2 >= r_left.0 - 24.0 &&
        g.0 <= r_right.0 + r_right.2 + 24.0
      })
    (rects, glasses)
  }
  for plat in [0, 2] {
    let at = "plat=\{plat}"
    let server_mode : @signals.Signal[String?] = @signals.signal(None)
    let pending_reply : Ref[((Result[Json, Json]) -> Unit)?] = Ref(None)
    let sync_fail : Ref[Bool] = Ref(false)
    let over = fn(base : Source) -> Source {
      {
        ..base,
        topic_read: fn(name, params) {
          let r = base.topic(name, params).get().snapshot()
          if name == "station" {
            match server_mode.get() {
              Some(m) => { ..r, value: r.value.map(fn(v) { archiving_patch(v, m, 1.0, 3.0, m == "reviewed") }) }
              None => r
            }
          } else {
            r
          }
        },
        call: fn(name, params, done) {
          if name == "archiving.save" {
            if sync_fail.val {
              done(Err(Json::object({ "message": Json::string("read-only") })))
            } else {
              pending_reply.val = Some(done)
            }
          } else {
            (base.call)(name, params, done)
          }
        },
      }
    }
    let t = setting_tester(StationArchiving("ws1/st1"), 390.0, platform=plat, over~)
    t.run_for(@ui.move_most_ms)
    let r_off = t.get(Radio, label="不自动归档").rect
    let r_idle = t.get(Radio, label="空闲就归档").rect
    let r_review = t.get(Radio, label="按模型判断").rect
    assert_eq(t.get(Radio, label="空闲就归档").check, Some(@ui.Check::On), msg=at)

    // Branch A: click/tap 按模型判断 while archiving.save is delayed -> holds optimistic selection until Ok + topic.
    let target_x = r_review.0 + r_review.2 / 2.0
    let target_y = r_review.1 + r_review.3 / 2.0
    if plat == 0 {
      t.click(Radio, label="按模型判断")
    } else {
      let start_x = r_idle.0 + r_idle.2 / 2.0
      t.touch(0, start_x, target_y)
      t.frame()
      t.touch(1, target_x, target_y)
      t.frame()
      t.touch(2, target_x, target_y)
    }
    assert_true(pending_reply.val is Some(_), msg="\{at}: archiving.save must be in flight")
    let samples = Ref(0)
    let reached = Ref(false)
    let drifted : Array[String] = []
    let min_x = (r_idle.0 + r_idle.2 + r_review.0) / 2.0
    t.each_frame(
      Some(fn() {
        samples.val += 1
        let radios = t.all(Radio, label="按模型判断")
        if radios.is_empty() || radios[0].check != Some(@ui.Check::On) {
          drifted.push("t=\{t.time()} radio not On")
        }
        let (rects, glasses) = mode_visuals(t, r_off, r_review)
        if rects.is_empty() && glasses.is_empty() {
          drifted.push("t=\{t.time()} missing capsule/lens")
        }
        for d in rects {
          let cx = d.0 + d.2 / 2.0
          if cx >= min_x {
            reached.val = true
          } else if reached.val {
            drifted.push("t=\{t.time()} rect drifted left of mid=\{min_x} (cx=\{cx})")
          }
        }
        for g in glasses {
          let cx = g.0 + g.2 / 2.0
          if cx >= min_x {
            reached.val = true
          } else if reached.val {
            drifted.push("t=\{t.time()} glass drifted left of mid=\{min_x} (cx=\{cx})")
          }
        }
      }),
    )
    t.run_for(@ui.move_most_ms)
    t.each_frame(None)
    assert_true(samples.val > 0, msg="\{at}: must sample in-flight frames")
    assert_true(reached.val, msg="\{at}: capsule must reach 按模型判断 while in flight")
    assert_true(drifted.is_empty(), msg="\{at}: drifted while archiving.save in flight: \{drifted.join("; ")}")
    let (rects_wait, glasses_wait) = mode_visuals(t, r_off, r_review)
    assert_eq(glasses_wait.length(), 0, msg="\{at}: in-flight resting must have 0 glass")
    assert_eq(rects_wait.length(), 1, msg="\{at}: in-flight resting must have 1 capsule")
    assert_true((rects_wait[0].0 + rects_wait[0].2 / 2.0 - target_x).abs() < 1.0, msg="\{at}: in-flight capsule must align with 按模型判断")
    // Deliver Ok + server topic update -> settles cleanly on 按模型判断.
    match pending_reply.val {
      Some(done) => {
        pending_reply.val = None
        done(Ok(Json::object({})))
      }
      None => fail("\{at}: missing pending_reply")
    }
    server_mode.set(Some("reviewed"))
    t.run_for(@ui.move_most_ms)
    assert_eq(t.get(Radio, label="按模型判断").check, Some(@ui.Check::On), msg=at)
    let (rects_ok, glasses_ok) = mode_visuals(t, r_off, r_review)
    assert_eq(glasses_ok.length(), 0, msg="\{at}: Ok settled must have 0 glass")
    assert_eq(rects_ok.length(), 1, msg="\{at}: Ok settled must have 1 resting capsule")
    assert_true((rects_ok[0].0 + rects_ok[0].2 / 2.0 - target_x).abs() < 1.0, msg="\{at}: Ok capsule must align with 按模型判断")

    // Branch B1: async Err reverts Radio and resting capsule to server-confirmed 按模型判断.
    t.click(Radio, label="空闲就归档")
    t.run_for(@ui.move_most_ms / 2.0)
    assert_true(pending_reply.val is Some(_), msg="\{at}: async Err archiving.save must be in flight")
    assert_eq(t.get(Radio, label="空闲就归档").check, Some(@ui.Check::On), msg="\{at}: optimistic switch before async Err")
    match pending_reply.val {
      Some(done) => {
        pending_reply.val = None
        done(Err(Json::object({ "message": Json::string("save failed") })))
      }
      None => fail("\{at}: missing pending_reply for async Err")
    }
    t.run_for(@ui.move_most_ms * 2.0)
    assert_eq(t.get(Radio, label="按模型判断").check, Some(@ui.Check::On), msg="\{at}: async Err must revert radio")
    let (rects_err, glasses_err) = mode_visuals(t, r_off, r_review)
    assert_eq(glasses_err.length(), 0, msg="\{at}: async Err settled must have 0 glass")
    assert_eq(rects_err.length(), 1, msg="\{at}: async Err settled must have 1 resting capsule")
    assert_true((rects_err[0].0 + rects_err[0].2 / 2.0 - target_x).abs() < 1.0, msg="\{at}: async Err capsule must revert to 按模型判断")

    // Branch B2: sync Err (e.g. read-only) keeps Radio and resting capsule aligned on 按模型判断.
    sync_fail.val = true
    if plat == 0 {
      t.click(Radio, label="空闲就归档")
    } else {
      let ix = r_idle.0 + r_idle.2 / 2.0
      let iy = r_idle.1 + r_idle.3 / 2.0
      t.touch(0, ix, iy)
      t.touch(2, ix, iy)
    }
    t.run_for(@ui.move_most_ms * 2.0)
    assert_eq(t.get(Radio, label="按模型判断").check, Some(@ui.Check::On), msg="\{at}: sync Err must keep radio on 按模型判断")
    let (rects_sync, glasses_sync) = mode_visuals(t, r_off, r_review)
    assert_eq(glasses_sync.length(), 0, msg="\{at}: sync Err settled must have 0 glass")
    assert_eq(rects_sync.length(), 1, msg="\{at}: sync Err settled must have 1 resting capsule")
    assert_true((rects_sync[0].0 + rects_sync[0].2 / 2.0 - target_x).abs() < 1.0, msg="\{at}: sync Err capsule must stay on 按模型判断")
  }
}

///|
fn archiving_receipt(days : Double, slack_days : Double, reviewed : Bool) -> Json {
  Json::object({
    "archiving": Json::object({
      "days": Json::number(days),
      "slackDays": Json::number(slack_days),
      "reviewed": Json::boolean(reviewed),
      "canEdit": Json::boolean(true),
    }),
  })
}

///|
test "a station's archiving: Ok-before-topic uses write receipt so sibling choice emits fresh PUT with no stale overwrite" {
  let server_state : @signals.Signal[((String, Double, Double, Bool), Int)?] = @signals.signal(None)
  let calls : Array[(Json, (Result[Json, Json]) -> Unit)] = []
  let over = fn(base : Source) -> Source {
    {
      ..base,
      topic_read: fn(name, params) {
        let r = base.topic(name, params).get().snapshot()
        if name == "station" {
          match server_state.get() {
            Some(((m, d, sl, rev), ver)) =>
              { ..r, version: r.version + ver, value: r.value.map(fn(v) { archiving_patch(v, m, d, sl, rev) }) }
            None => r
          }
        } else {
          r
        }
      },
      call: fn(name, params, done) {
        if name == "archiving.save" {
          calls.push((params, done))
        } else {
          (base.call)(name, params, done)
        }
      },
    }
  }
  let t = setting_tester(StationArchiving("ws1/st1"), 390.0, platform=0, over~)
  t.run_for(@ui.move_most_ms)
  assert_eq(t.get(Radio, label="空闲就归档").check, Some(@ui.Check::On))
  // 1. Click 按模型判断 -> 1st archiving.save in flight; sibling Slack choice is locked while in flight.
  t.click(Radio, label="按模型判断")
  t.run_for(@ui.move_most_ms / 2.0)
  assert_eq(calls.length(), 1, msg="expected 1st archiving.save for 按模型判断")
  assert_eq(field(Some(calls[0].0), "reviewed"), Some(Json::boolean(true)))
  let slack_7 = t.all(Radio, label="7 天")[1].rect
  t.tap(slack_7.0 + slack_7.2 / 2.0, slack_7.1 + slack_7.3 / 2.0)
  t.run_for(@ui.move_most_ms / 2.0)
  assert_eq(calls.length(), 1, msg="sibling choice must stay locked while 1st PUT is in flight")
  // 2. Deliver Ok with real write receipt (days=1, slackDays=3, reviewed=true), BEFORE station topic updates.
  (calls[0].1)(Ok(archiving_receipt(1.0, 3.0, true)))
  t.run_for(@ui.move_most_ms)
  assert_eq(t.get(Radio, label="按模型判断").check, Some(@ui.Check::On), msg="Ok receipt must hold 按模型判断 before topic")
  // 3. Immediately click Slack 7 天 before station topic arrives -> unlocked via receipt, emits 2nd PUT with reviewed=true (never stale false!).
  t.tap(slack_7.0 + slack_7.2 / 2.0, slack_7.1 + slack_7.3 / 2.0)
  t.run_for(@ui.move_most_ms / 2.0)
  assert_eq(calls.length(), 2, msg="Ok-before-topic must unlock immediately using receipt")
  assert_eq(number(Some(calls[1].0), "days"), 1.0)
  assert_eq(number(Some(calls[1].0), "slackDays"), 7.0)
  assert_eq(field(Some(calls[1].0), "reviewed"), Some(Json::boolean(true)))
  // 4. If 2nd PUT fails, UI reverts to 1st confirmed receipt (按模型判断 / Slack 3 天), not stale pre-1st view().
  (calls[1].1)(Err(Json::object({ "message": Json::string("2nd save failed") })))
  t.run_for(@ui.move_most_ms * 2.0)
  assert_eq(t.get(Radio, label="按模型判断").check, Some(@ui.Check::On), msg="failed 2nd PUT keeps 1st acked receipt")
  assert_eq(t.all(Radio, label="3 天")[1].check, Some(@ui.Check::On), msg="failed 2nd PUT reverts Slack to 3 天")
}

///|
test "a station's archiving: idle days choice holds optimistic state on delayed Ok+topic and reverts on Err" {
  let server_days : @signals.Signal[(Double, Int)?] = @signals.signal(None)
  let pending_reply : Ref[((Result[Json, Json]) -> Unit)?] = Ref(None)
  let over = fn(base : Source) -> Source {
    {
      ..base,
      topic_read: fn(name, params) {
        let r = base.topic(name, params).get().snapshot()
        if name == "station" {
          match server_days.get() {
            Some((d, ver)) =>
              { ..r, version: r.version + ver, value: r.value.map(fn(v) { archiving_patch(v, "idle", d, 3.0, false) }) }
            None => r
          }
        } else {
          r
        }
      },
      call: fn(name, params, done) {
        if name == "archiving.save" {
          pending_reply.val = Some(done)
        } else {
          (base.call)(name, params, done)
        }
      },
    }
  }
  let t = setting_tester(StationArchiving("ws1/st1"), 390.0, platform=0, over~)
  t.run_for(@ui.move_most_ms)
  let r_1d = t.all(Radio, label="1 天")[0].rect
  let r_3d = t.all(Radio, label="3 天")[0].rect
  let r_7d = t.all(Radio, label="7 天")[0].rect
  let r_30d = t.all(Radio, label="30 天")[0].rect
  let idle_thumbs = fn() {
    let lifted_rgb = @ui.tree_theme().lifted >> 8
    t
    .drawn_rects()
    .filter(fn(d) {
      (d.4 >> 8) == lifted_rgb &&
      (d.4 & 0xFFL) > 0x40L &&
      (d.3 - r_1d.3).abs() < 2.0 &&
      d.1 >= r_1d.1 - 4.0 &&
      d.1 <= r_1d.1 + r_1d.3 &&
      d.0 >= r_1d.0 - 4.0 &&
      d.0 + d.2 <= r_30d.0 + r_30d.2 + 4.0
    })
  }
  assert_eq(t.all(Radio, label="1 天")[0].check, Some(@ui.Check::On))
  // 1. Click 3 天 (idle) -> holds optimistic state while in flight, settles on Ok + matching topic.
  t.tap(r_3d.0 + r_3d.2 / 2.0, r_3d.1 + r_3d.3 / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_true(pending_reply.val is Some(_), msg="idle save must be in flight")
  assert_eq(t.all(Radio, label="3 天")[0].check, Some(@ui.Check::On), msg="idle radio must hold optimistic 3 天")
  let th_wait = idle_thumbs()
  assert_eq(th_wait.length(), 1)
  assert_true((th_wait[0].0 + th_wait[0].2 / 2.0 - (r_3d.0 + r_3d.2 / 2.0)).abs() < 1.0)
  match pending_reply.val {
    Some(done) => {
      pending_reply.val = None
      done(Ok(Json::object({})))
    }
    None => fail("missing idle pending_reply")
  }
  server_days.set(Some((3.0, 1)))
  t.run_for(@ui.move_most_ms)
  assert_eq(t.all(Radio, label="3 天")[0].check, Some(@ui.Check::On))
  // 2. Click 7 天 (idle) -> Err reverts cleanly back to 3 天.
  t.tap(r_7d.0 + r_7d.2 / 2.0, r_7d.1 + r_7d.3 / 2.0)
  t.run_for(@ui.move_most_ms / 2.0)
  assert_true(pending_reply.val is Some(_))
  assert_eq(t.all(Radio, label="7 天")[0].check, Some(@ui.Check::On))
  match pending_reply.val {
    Some(done) => {
      pending_reply.val = None
      done(Err(Json::object({ "message": Json::string("idle save failed") })))
    }
    None => fail("missing idle err pending_reply")
  }
  t.run_for(@ui.move_most_ms * 2.0)
  assert_eq(t.all(Radio, label="3 天")[0].check, Some(@ui.Check::On), msg="idle Err must revert radio to 3 天")
  let th_rev = idle_thumbs()
  assert_eq(th_rev.length(), 1)
  assert_true((th_rev[0].0 + th_rev[0].2 / 2.0 - (r_3d.0 + r_3d.2 / 2.0)).abs() < 1.0)
}

///|
test "a station's archiving: concurrent admin update unlocks after Ok (both Ok-first and afterWrite topic-first orders)" {
  for ok_first in [true, false] {
    let at = if ok_first { "Ok-first then B snapshot" } else { "B snapshot (afterWrite) then Ok" }
    let server_state : @signals.Signal[((String, Double, Double, Bool), Int)?] = @signals.signal(None)
    let calls : Array[(Json, (Result[Json, Json]) -> Unit)] = []
    let over = fn(base : Source) -> Source {
      {
        ..base,
        topic_read: fn(name, params) {
          let r = base.topic(name, params).get().snapshot()
          if name == "station" {
            match server_state.get() {
              Some(((m, d, sl, rev), ver)) =>
                { ..r, version: r.version + ver, value: r.value.map(fn(v) { archiving_patch(v, m, d, sl, rev) }) }
              None => r
            }
          } else {
            r
          }
        },
        call: fn(name, params, done) {
          if name == "archiving.save" {
            calls.push((params, done))
          } else {
            (base.call)(name, params, done)
          }
        },
      }
    }
    let t = setting_tester(StationArchiving("ws1/st1"), 390.0, platform=0, over~)
    t.run_for(@ui.move_most_ms)
    assert_eq(t.get(Radio, label="空闲就归档").check, Some(@ui.Check::On), msg=at)
    // 1. Admin A clicks 按模型判断 -> captures 1st PUT (days=1, slackDays=3, reviewed=true).
    t.click(Radio, label="按模型判断")
    t.run_for(@ui.move_most_ms / 2.0)
    assert_eq(calls.length(), 1, msg="\{at}: expected 1st PUT")
    // 2. Deliver Ok with real write receipt and concurrent Admin B's authoritative snapshot (reviewed, 1, 7, true) — NEVER (reviewed, 1, 3, true).
    if ok_first {
      (calls[0].1)(Ok(archiving_receipt(1.0, 3.0, true)))
      t.run_for(@ui.move_most_ms / 2.0)
      server_state.set(Some((("reviewed", 1.0, 7.0, true), 1)))
    } else {
      server_state.set(Some((("reviewed", 1.0, 7.0, true), 1)))
      t.run_for(@ui.move_most_ms / 2.0)
      (calls[0].1)(Ok(archiving_receipt(1.0, 3.0, true)))
    }
    t.run_for(@ui.move_most_ms)
    // 3. All 3 controls unlock and reflect authoritative Admin B snapshot: 按模型判断 / 1 天 / 7 天.
    assert_eq(t.get(Radio, label="按模型判断").check, Some(@ui.Check::On), msg="\{at}: mode must be 按模型判断")
    assert_eq(t.all(Radio, label="1 天")[0].check, Some(@ui.Check::On), msg="\{at}: idle must be 1 天")
    assert_eq(t.all(Radio, label="7 天")[1].check, Some(@ui.Check::On), msg="\{at}: slack must reflect Admin B's 7 天")
    // 4. Clicking idle 3 天 emits 2nd PUT preserving Admin B's slackDays=7.0 and reviewed=true.
    let idle_3 = t.all(Radio, label="3 天")[0].rect
    t.tap(idle_3.0 + idle_3.2 / 2.0, idle_3.1 + idle_3.3 / 2.0)
    t.run_for(@ui.move_most_ms / 2.0)
    assert_eq(calls.length(), 2, msg="\{at}: unlocked idle choice must emit 2nd PUT")
    assert_eq(number(Some(calls[1].0), "days"), 3.0, msg=at)
    assert_eq(number(Some(calls[1].0), "slackDays"), 7.0, msg=at)
    assert_eq(field(Some(calls[1].0), "reviewed"), Some(Json::boolean(true)), msg=at)
  }
}

///|
test "a station's archiving: pre-write snapshot arriving before Ok keeps receipt so next PUT never sends stale reviewed=false" {
  let server_state : @signals.Signal[((String, Double, Double, Bool), Int)?] = @signals.signal(None)
  let calls : Array[(Json, (Result[Json, Json]) -> Unit)] = []
  let over = fn(base : Source) -> Source {
    {
      ..base,
      topic_read: fn(name, params) {
        let r = base.topic(name, params).get().snapshot()
        if name == "station" {
          match server_state.get() {
            Some(((m, d, sl, rev), ver)) =>
              { ..r, version: r.version + ver, value: r.value.map(fn(v) { archiving_patch(v, m, d, sl, rev) }) }
            None => r
          }
        } else {
          r
        }
      },
      call: fn(name, params, done) {
        if name == "archiving.save" {
          calls.push((params, done))
        } else {
          (base.call)(name, params, done)
        }
      },
    }
  }
  let t = setting_tester(StationArchiving("ws1/st1"), 390.0, platform=0, over~)
  t.run_for(@ui.move_most_ms)
  assert_eq(t.get(Radio, label="空闲就归档").check, Some(@ui.Check::On))
  // 1. Admin A clicks 按模型判断 -> 1st PUT in flight.
  t.click(Radio, label="按模型判断")
  t.run_for(@ui.move_most_ms / 2.0)
  assert_eq(calls.length(), 1)
  // 2. Pre-write snapshot (idle, 1, 7, false) arrives at ver=1 BEFORE A's Ok.
  server_state.set(Some((("idle", 1.0, 7.0, false), 1)))
  t.run_for(@ui.move_most_ms / 2.0)
  // 3. A's Ok arrives with write receipt (1, 3, true); topic does NOT include A's write, so receipt is kept.
  (calls[0].1)(Ok(archiving_receipt(1.0, 3.0, true)))
  t.run_for(@ui.move_most_ms)
  assert_eq(t.get(Radio, label="按模型判断").check, Some(@ui.Check::On), msg="receipt must keep 按模型判断 over pre-write snapshot")
  // 4. Before post-write topic arrives, A clicks idle 3 天 -> 2nd PUT MUST carry (days=3, slackDays=3, reviewed=true).
  let idle_3 = t.all(Radio, label="3 天")[0].rect
  t.tap(idle_3.0 + idle_3.2 / 2.0, idle_3.1 + idle_3.3 / 2.0)
  t.run_for(@ui.move_most_ms / 2.0)
  assert_eq(calls.length(), 2, msg="2nd PUT must fire cleanly from receipt")
  assert_eq(number(Some(calls[1].0), "days"), 3.0)
  assert_eq(number(Some(calls[1].0), "slackDays"), 3.0)
  assert_eq(field(Some(calls[1].0), "reviewed"), Some(Json::boolean(true)), msg="must NEVER send stale reviewed=false")
}

///|
test "a station's archiving: post-write revert to original state via newer topic version clears receipt and remains editable" {
  let server_state : @signals.Signal[((String, Double, Double, Bool), Int)?] = @signals.signal(None)
  let calls : Array[(Json, (Result[Json, Json]) -> Unit)] = []
  let over = fn(base : Source) -> Source {
    {
      ..base,
      topic_read: fn(name, params) {
        let r = base.topic(name, params).get().snapshot()
        if name == "station" {
          match server_state.get() {
            Some(((m, d, sl, rev), ver)) =>
              { ..r, version: r.version + ver, value: r.value.map(fn(v) { archiving_patch(v, m, d, sl, rev) }) }
            None => r
          }
        } else {
          r
        }
      },
      call: fn(name, params, done) {
        if name == "archiving.save" {
          calls.push((params, done))
        } else {
          (base.call)(name, params, done)
        }
      },
    }
  }
  let t = setting_tester(StationArchiving("ws1/st1"), 390.0, platform=0, over~)
  t.run_for(@ui.move_most_ms)
  assert_eq(t.get(Radio, label="空闲就归档").check, Some(@ui.Check::On))
  // 1. Admin A clicks 按模型判断 and receives Ok(receipt=(1,3,true)).
  t.click(Radio, label="按模型判断")
  t.run_for(@ui.move_most_ms / 2.0)
  assert_eq(calls.length(), 1)
  (calls[0].1)(Ok(archiving_receipt(1.0, 3.0, true)))
  t.run_for(@ui.move_most_ms)
  assert_eq(t.get(Radio, label="按模型判断").check, Some(@ui.Check::On))
  // 2. Admin B legally reverts back to A's original (idle, 1, 3, false) with newer topic version (ver > ok_ver).
  server_state.set(Some((("idle", 1.0, 3.0, false), 1)))
  t.run_for(@ui.move_most_ms)
  assert_eq(t.get(Radio, label="空闲就归档").check, Some(@ui.Check::On), msg="newer topic reverting to original must clear receipt")
  // 3. Page remains fully editable: clicking Slack 7 天 emits 2nd PUT with B's authoritative (days=1, slackDays=7, reviewed=false).
  let slack_7 = t.all(Radio, label="7 天")[1].rect
  t.tap(slack_7.0 + slack_7.2 / 2.0, slack_7.1 + slack_7.3 / 2.0)
  t.run_for(@ui.move_most_ms / 2.0)
  assert_eq(calls.length(), 2, msg="page must remain editable after post-write revert")
  assert_eq(number(Some(calls[1].0), "days"), 1.0)
  assert_eq(number(Some(calls[1].0), "slackDays"), 7.0)
  assert_eq(field(Some(calls[1].0), "reviewed"), Some(Json::boolean(false)))
}

///|
test "a station's archiving: changing idle days then mode before topic arrives preserves effective days in 2nd PUT" {
  let calls : Array[(Json, (Result[Json, Json]) -> Unit)] = []
  let over = fn(base : Source) -> Source {
    {
      ..base,
      call: fn(name, params, done) {
        if name == "archiving.save" {
          calls.push((params, done))
        } else {
          (base.call)(name, params, done)
        }
      },
    }
  }
  let t = setting_tester(StationArchiving("ws1/st1"), 390.0, platform=0, over~)
  t.run_for(@ui.move_most_ms)
  assert_eq(t.get(Radio, label="空闲就归档").check, Some(@ui.Check::On))
  // 1. Change idle days from 1 天 to 7 天 -> deliver Ok receipt (7, 3, false) without pushing topic yet.
  let idle_7 = t.all(Radio, label="7 天")[0].rect
  t.tap(idle_7.0 + idle_7.2 / 2.0, idle_7.1 + idle_7.3 / 2.0)
  t.run_for(@ui.move_most_ms / 2.0)
  assert_eq(calls.length(), 1)
  (calls[0].1)(Ok(archiving_receipt(7.0, 3.0, false)))
  t.run_for(@ui.move_most_ms)
  assert_eq(t.all(Radio, label="7 天")[0].check, Some(@ui.Check::On))
  // 2. Immediately switch mode to 按模型判断 before topic arrives -> 2nd PUT must keep days=7.0 (never stale 1.0).
  t.click(Radio, label="按模型判断")
  t.run_for(@ui.move_most_ms / 2.0)
  assert_eq(calls.length(), 2, msg="switching mode after idle receipt must emit 2nd PUT")
  assert_eq(number(Some(calls[1].0), "days"), 7.0, msg="mode PUT must preserve effective days=7.0")
  assert_eq(number(Some(calls[1].0), "slackDays"), 3.0)
  assert_eq(field(Some(calls[1].0), "reviewed"), Some(Json::boolean(true)))
}

///|
test "a station's archiving: newer topic arriving while 2nd PUT is in flight evicts old receipt so 2nd Err falls back to fresh topic" {
  let server_state : @signals.Signal[((String, Double, Double, Bool), Int)?] = @signals.signal(None)
  let calls : Array[(Json, (Result[Json, Json]) -> Unit)] = []
  let over = fn(base : Source) -> Source {
    {
      ..base,
      topic_read: fn(name, params) {
        let r = base.topic(name, params).get().snapshot()
        if name == "station" {
          match server_state.get() {
            Some(((m, d, sl, rev), ver)) =>
              { ..r, version: r.version + ver, value: r.value.map(fn(v) { archiving_patch(v, m, d, sl, rev) }) }
            None => r
          }
        } else {
          r
        }
      },
      call: fn(name, params, done) {
        if name == "archiving.save" {
          calls.push((params, done))
        } else {
          (base.call)(name, params, done)
        }
      },
    }
  }
  let t = setting_tester(StationArchiving("ws1/st1"), 390.0, platform=0, over~)
  t.run_for(@ui.move_most_ms)
  // 1. Click 按模型判断 and deliver Ok receipt (1, 3, true) without pushing topic yet.
  t.click(Radio, label="按模型判断")
  t.run_for(@ui.move_most_ms / 2.0)
  assert_eq(calls.length(), 1)
  (calls[0].1)(Ok(archiving_receipt(1.0, 3.0, true)))
  t.run_for(@ui.move_most_ms)
  // 2. Immediately click Slack 7 天 -> 2nd PUT in flight.
  let slack_7 = t.all(Radio, label="7 天")[1].rect
  t.tap(slack_7.0 + slack_7.2 / 2.0, slack_7.1 + slack_7.3 / 2.0)
  t.run_for(@ui.move_most_ms / 2.0)
  assert_eq(calls.length(), 2)
  // 3. While 2nd PUT is in flight, another admin updates topic to (reviewed, 30, 3, true) at ver=1.
  server_state.set(Some((("reviewed", 30.0, 3.0, true), 1)))
  t.run_for(@ui.move_most_ms / 2.0)
  // 4. 2nd PUT fails -> must fall back to fresh topic (30 天), NOT old receipt (1 天).
  (calls[1].1)(Err(Json::object({ "message": Json::string("2nd save failed") })))
  t.run_for(@ui.move_most_ms * 2.0)
  assert_eq(t.all(Radio, label="30 天")[0].check, Some(@ui.Check::On), msg="failed 2nd PUT must show fresh topic 30 天")
  assert_eq(t.all(Radio, label="3 天")[1].check, Some(@ui.Check::On))
  // 5. Retry Slack 7 天 -> 3rd PUT must send (days=30.0, slackDays=7.0, reviewed=true).
  t.tap(slack_7.0 + slack_7.2 / 2.0, slack_7.1 + slack_7.3 / 2.0)
  t.run_for(@ui.move_most_ms / 2.0)
  assert_eq(calls.length(), 3, msg="retry Slack 7 天 must emit 3rd PUT")
  assert_eq(number(Some(calls[2].0), "days"), 30.0)
  assert_eq(number(Some(calls[2].0), "slackDays"), 7.0)
  assert_eq(field(Some(calls[2].0), "reviewed"), Some(Json::boolean(true)))
}

///|
test "a station's archiving: off receipt hides idle row immediately and re-enabling idle uses days=1.0 rather than stale 7.0" {
  let calls : Array[(Json, (Result[Json, Json]) -> Unit)] = []
  let over = fn(base : Source) -> Source {
    {
      ..base,
      topic_read: fn(name, params) {
        let r = base.topic(name, params).get().snapshot()
        if name == "station" {
          { ..r, value: r.value.map(fn(v) { archiving_patch(v, "idle", 7.0, 3.0, false) }) }
        } else {
          r
        }
      },
      call: fn(name, params, done) {
        if name == "archiving.save" {
          calls.push((params, done))
        } else {
          (base.call)(name, params, done)
        }
      },
    }
  }
  let t = setting_tester(StationArchiving("ws1/st1"), 390.0, platform=0, over~)
  t.run_for(@ui.move_most_ms)
  assert_eq(t.get(Radio, label="空闲就归档").check, Some(@ui.Check::On))
  assert_true(t.find("空闲多久") is Some(_))
  // 1. Switch to 不自动归档 -> deliver Ok(receipt=(0, 3, false)) without pushing topic yet.
  t.click(Radio, label="不自动归档")
  t.run_for(@ui.move_most_ms / 2.0)
  assert_eq(calls.length(), 1)
  (calls[0].1)(Ok(archiving_receipt(0.0, 3.0, false)))
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("空闲多久") is None, msg="off receipt must hide 空闲多久 immediately")
  // 2. Re-enable 空闲就归档 before topic arrives -> 2nd PUT must use days=1.0 (not stale 7.0).
  t.click(Radio, label="空闲就归档")
  t.run_for(@ui.move_most_ms / 2.0)
  assert_eq(calls.length(), 2, msg="re-enabling 空闲就归档 after off receipt must emit 2nd PUT")
  assert_eq(number(Some(calls[1].0), "days"), 1.0, msg="re-enabling from off must send days=1.0, never stale 7.0")
  assert_eq(number(Some(calls[1].0), "slackDays"), 3.0)
  assert_eq(field(Some(calls[1].0), "reviewed"), Some(Json::boolean(false)))
}
