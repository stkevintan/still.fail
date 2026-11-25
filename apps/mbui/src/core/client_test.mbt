// The client over recorded messages: the smoke run's (scripts/core.sh smoke: accounts, auth.begin; the login URL's
// state and challenge replaced) and deltas as the core sends them.

///|
fn recorder() -> (@core.Client, Array[Json]) {
  let sent : Array[Json] = []
  let c = @core.Client::new(fn(s) { sent.push(@json.parse(s) catch { _ => Json::null() }) })
  (c, sent)
}

///|
test "subscribe asks once, keyed, and takes the first value" {
  let (c, sent) = recorder()
  let s = c.subscribe("accounts")
  let again = c.subscribe("accounts")
  assert_true(physical_equal(s, again))
  assert_eq(sent.length(), 1)
  let want : Json = { "id": 1, "subscribe": { "topic": "accounts" }, "keyed": true }
  assert_eq(sent[0].stringify(), want.stringify())
  assert_true(s.value is None)
  // recorded: the smoke run's first message
  assert_true(c.receive("{\"id\":1,\"value\":[]}"))
  assert_eq(s.value.unwrap().stringify(), "[]")
  assert_eq(s.version, 1)
}

///|
test "params make another subscription" {
  let (c, sent) = recorder()
  let a = c.subscribe("threads", params={ "station": "ws/a" })
  let b = c.subscribe("threads", params={ "station": "ws/b" })
  assert_true(a.id != b.id)
  assert_eq(
    sent[1].stringify(),
    ({ "id": 2, "subscribe": { "topic": "threads", "station": "ws/b" }, "keyed": true } : Json).stringify(),
  )
}

///|
test "subscription lookup preserves the topic sent to the core and distinguishes its parameters" {
  let (c, sent) = recorder()
  // A parameter named topic replaces the supplied topic in the message to the core. Both ways to ask for that
  // message must still share one subscription, including when it is ended by the other way.
  let overridden = c.subscribe("unused", params={ "topic": "actual", "station": "ws/一\n:1" })
  let direct = c.subscribe("actual", params={ "station": "ws/一\n:1" })
  assert_true(physical_equal(overridden, direct))
  assert_eq(sent.length(), 1)
  c.unsubscribe_topic("actual", params={ "station": "ws/一\n:1" })
  assert_eq(sent.length(), 2)
  let asked_again = c.subscribe("unused", params={ "topic": "actual", "station": "ws/一\n:1" })
  assert_true(asked_again.id != overridden.id)
  // Values of different kinds and strings that could look like concatenated key parts are separate topics.
  let text = c.subscribe("p", params={ "v": "1" })
  let number = c.subscribe("p", params={ "v": 1 })
  let one = c.subscribe("p", params={ "a": "bc", "d": "e" })
  let other = c.subscribe("p", params={ "a": "b", "cd": "e" })
  assert_true(text.id != number.id)
  assert_true(one.id != other.id)
  assert_true(physical_equal(one, c.subscribe("p", params={ "a": "bc", "d": "e" })))
}

///|
test "subscriptions share exactly when their outgoing topic JSON is the same" {
  let (c, _) = recorder()
  let cases : Array[(String, Map[String, Json])] = [
    ("a", {}),
    ("unused", { "topic": "a" }),
    ("a", { "x": "一\n:1" }),
    ("unused", { "x": "一\n:1", "topic": "a" }),
    ("a", { "x": "1" }),
    ("a", { "x": 1 }),
    ("a", { "x": null }),
    ("a", { "topic": 1, "x": "1" }),
    ("b", { "topic": 1, "x": "1" }),
    ("a", { "x": "bc", "y": "d" }),
    ("a", { "x": "b", "cy": "d" }),
    ("a", { "x": "b", "y": "cd" }),
    ("a", { "x": { "inner": [1, true, null] } }),
    ("a", { "x": { "inner": [1, true, null] } }),
    ("a", { "x": "inner", "y": "value" }),
    ("a", { "y": "value", "x": "inner" }),
    ("unused", { "topic": "z", "x": "1", "y": "2" }),
    ("other", { "x": "1", "topic": "z", "y": "2" }),
    ("z", { "x": "1", "y": "2" }),
    ("z", { "y": "2", "x": "1" }),
  ]
  let seen : Array[(String, Int, String, Map[String, Json])] = []
  for (topic, params) in cases {
    let sent : Map[String, Json] = { "topic": Json::string(topic) }
    for k, v in params { sent[k] = v }
    let outgoing = Json::object(sent).stringify()
    let sub = c.subscribe(topic, params~)
    for (previous, id, previous_topic, previous_params) in seen {
      assert_true(
        (outgoing == previous) == (sub.id == id),
        msg="the same outgoing topic must find the same subscription: \{outgoing} / \{previous}",
      )
      let (other, sent) = recorder()
      let old_sub = other.subscribe(previous_topic, params=previous_params)
      other.unsubscribe_topic(topic, params~)
      assert_true(
        (sent.length() == 2) == (outgoing == previous),
        msg="unsubscribe must find exactly the outgoing topic: \{outgoing} / \{previous}",
      )
      let again = other.subscribe(previous_topic, params=previous_params)
      assert_true(physical_equal(old_sub, again) == (outgoing != previous))
    }
    seen.push((outgoing, sub.id, topic, params))
  }
}

///|
test "a subscription with an overridden topic survives restart and is forgotten by reset" {
  let (c, sent) = recorder()
  let params : Map[String, Json] = { "station": "ws/a", "topic": "chat", "session": "s/a" }
  let first = c.subscribe("unused", params~)
  sent.clear()
  c.restarted()
  assert_eq(sent.length(), 1)
  assert_true(physical_equal(first, c.subscribe("unused", params~)))
  c.reset()
  let after_reset = c.subscribe("unused", params~)
  assert_true(!physical_equal(first, after_reset))
  assert_eq(after_reset.id, 1)
  c.unsubscribe_topic("unused", params~)
  assert_true(!physical_equal(after_reset, c.subscribe("unused", params~)))
}

///|
test "a call's answer goes to its on_done" {
  let (c, sent) = recorder()
  let got : Array[String] = []
  let params : Json = {
    "redirect_uri": "stillfail://auth/callback",
    "return_to": "/",
  }
  let id = c.call("auth.begin", params~, on_done=fn(r) {
    match r {
      Ok(Object(m)) =>
        match m.get("url") {
          Some(String(u)) => got.push(u)
          _ => ()
        }
      _ => got.push("error")
    }
  })
  assert_eq(id, 1)
  assert_eq(
    sent[0].stringify(),
    ({ "id": 1, "call": "auth.begin", "params": params } : Json).stringify(),
  )
  // recorded (state and challenge replaced)
  c.receive(
    "{\"id\":1,\"ok\":{\"url\":\"https://app.still.fail/v1/auth/google/start?state=S&code_challenge=C&code_challenge_method=S256&redirect_uri=stillfail%3A%2F%2Fauth%2Fcallback&name=still.fail\"}}",
  )
  |> ignore
  assert_eq(got.length(), 1)
  assert_true(got[0].has_prefix("https://app.still.fail/v1/auth/google/start?"))
  // answered once
  c.receive("{\"id\":1,\"ok\":null}") |> ignore
  assert_eq(got.length(), 1)
}

///|
test "a call's error" {
  let (c, _) = recorder()
  let got : Array[Json] = []
  c.call("auth.complete", params={ "query": "x" }, on_done=fn(r) {
    match r {
      Err(e) => got.push(e)
      Ok(_) => ()
    }
  })
  |> ignore
  c.receive(
    "{\"id\":1,\"error\":{\"code\":\"bad_request\",\"message\":\"no state\",\"status\":400}}",
  )
  |> ignore
  assert_eq(
    got[0].stringify(),
    "{\"code\":\"bad_request\",\"message\":\"no state\",\"status\":400}",
  )
}

///|
test "deltas apply to the value; versions count the messages" {
  let (c, _) = recorder()
  let s = c.subscribe("threads", params={ "station": "ws/s" })
  let v0 = c.version
  c.receive("{\"id\":1,\"delta\":[{\"path\":[],\"set\":1}]}") |> ignore
  // a delta before any value is not applied
  assert_true(s.value is None)
  assert_eq(s.version, 0)
  c.receive(
    "{\"id\":1,\"value\":[{\"id\":\"a\",\"t\":\"A\"},{\"id\":\"b\",\"t\":\"B\"}]}",
  )
  |> ignore
  let first = s.value.unwrap()
  c.receive(
    "{\"id\":1,\"delta\":[{\"path\":[],\"key\":[\"id\"],\"move\":\"b\",\"before\":\"a\"},{\"path\":[],\"key\":[\"id\"],\"patch\":\"a\",\"ops\":[{\"path\":[\"t\"],\"set\":\"A2\"}]}]}",
  )
  |> ignore
  assert_eq(
    s.value.unwrap().stringify(),
    "[{\"id\":\"b\",\"t\":\"B\"},{\"id\":\"a\",\"t\":\"A2\"}]",
  )
  // the value a view held before is as it was
  assert_eq(first.stringify(), "[{\"id\":\"a\",\"t\":\"A\"},{\"id\":\"b\",\"t\":\"B\"}]")
  assert_eq(s.version, 2)
  assert_eq(c.version, v0 + 2)
}

///|
test "an error clears the value until the next one" {
  let (c, _) = recorder()
  let s = c.subscribe("workspace", params={ "workspace": "w" })
  c.receive("{\"id\":1,\"value\":{\"a\":1}}") |> ignore
  c.receive("{\"id\":1,\"error\":{\"code\":\"offline\",\"message\":\"no network\"}}")
  |> ignore
  assert_true(s.value is None)
  assert_true(s.error is Some(_))
  c.receive("{\"id\":1,\"delta\":[{\"path\":[\"a\"],\"set\":2}]}") |> ignore
  assert_true(s.value is None)
  c.receive("{\"id\":1,\"value\":{\"a\":3}}") |> ignore
  assert_eq(s.value.unwrap().stringify(), "{\"a\":3}")
  assert_true(s.error is None)
  assert_eq(s.version, 3)
}

///|
test "a retained value belongs to the new core only after its reply" {
  let (c, sent) = recorder()
  assert_eq(c.topic_generation("composer"), (0, true))
  assert_eq(sent.length(), 0, msg="checking freshness must not create a subscription")
  let s = c.subscribe("composer")
  c.receive_json({ "id": 1, "value": { "text": "before" } })
  c.restarted()
  assert_eq(c.topic_generation("composer"), (1, false))
  assert_eq(s.value.unwrap().stringify(), "{\"text\":\"before\"}")
  c.receive_json({ "id": 1, "value": { "text": "after" } })
  assert_eq(c.topic_generation("composer"), (1, true))
  c.unsubscribe(s)
  assert_eq(sent.length(), 3, msg="the freshness check must not keep the subscription open")
  assert_eq(c.topic_generation("composer"), (1, true))
}

///|
test "a fatal fails the calls in flight; restarted asks every subscription again" {
  let (c, sent) = recorder()
  let s = c.subscribe("accounts")
  c.receive("{\"id\":1,\"value\":[]}") |> ignore
  let errs : Array[Json] = []
  c.call("auth.begin", on_done=fn(r) {
    match r {
      Err(e) => errs.push(e)
      Ok(_) => ()
    }
  })
  |> ignore
  c.receive("{\"fatal\":\"boom\"}") |> ignore
  assert_eq(c.fatal, Some("boom"))
  assert_eq(errs.length(), 1)
  // (in the app's words, the core's own reason kept in `fatal`)
  assert_eq(errs[0].stringify(), "{\"code\":\"core_restarted\",\"message\":\"" + @core.restarted_text.val + "\"}")
  sent.clear()
  c.restarted()
  assert_eq(c.fatal, None)
  assert_eq(sent.length(), 1)
  assert_eq(
    sent[0].stringify(),
    ({ "id": 1, "subscribe": { "topic": "accounts" }, "keyed": true } : Json).stringify(),
  )
  // the old value stays until the new core's
  assert_eq(s.value.unwrap().stringify(), "[]")
}

///|
test "unsubscribe tells the core and forgets the subscription" {
  let (c, sent) = recorder()
  let s = c.subscribe("accounts")
  c.unsubscribe(s)
  assert_eq(sent[1].stringify(), ({ "id": 1, "unsubscribe": true } : Json).stringify())
  c.receive("{\"id\":1,\"value\":[1]}") |> ignore
  assert_true(s.value is None)
  let again = c.subscribe("accounts")
  assert_eq(again.id, 2)
}

///|
test "leaving an unasked topic does not start it" {
  let (c, sent) = recorder()
  let summary : Map[String, Json] = { "station": "ws/s", "summary": true }
  let full : Map[String, Json] = { "station": "ws/s" }
  let held = c.subscribe("chatJobs", params=summary)
  c.unsubscribe_topic("chatJobs", params=full)
  assert_eq(sent.length(), 1, msg="an unopened jobs page is not asked just to leave it")
  c.unsubscribe_topic("chatJobs", params=summary)
  assert_eq(sent.length(), 2)
  assert_eq(sent[1].stringify(), ({ "id": 1, "unsubscribe": true } : Json).stringify())
  c.unsubscribe_topic("chatJobs", params=summary)
  assert_eq(sent.length(), 2)
  assert_true(c.subscribe("chatJobs", params=summary).id != held.id)
}

///|
test "what is not a message is let be" {
  let (c, _) = recorder()
  assert_false(c.receive("not json"))
  assert_true(c.receive("{\"id\":99,\"ok\":1}"))
  assert_true(c.receive("[1,2]"))
  assert_eq(c.version, 0)
}

///|
test "query_of: a callback URL's query" {
  assert_eq(
    @core.query_of("stillfail://auth/callback?code=a&state=b#x"),
    "code=a&state=b",
  )
  assert_eq(@core.query_of("stillfail://auth/callback?code=a"), "code=a")
  assert_eq(@core.query_of("stillfail://auth/callback"), "")
}

///|
test "a call whose answer has bytes beside it gets them, a plain call doesn't" {
  let (c, _) = recorder()
  let got : Array[(String, Int)] = []
  c.call_bytes(
    "media.image",
    params={ "station": "s", "book": "b", "ref": "r" },
    on_done=fn(r) {
      match r {
        Ok((j, Some(b))) => got.push((j.stringify(), b.length()))
        _ => got.push(("none", 0))
      }
    },
  )
  |> ignore
  c.receive_json(
    @json.parse("{\"id\":1,\"ok\":{\"type\":\"image/png\",\"size\":4}}"),
    bytes=Some(b"\x89PNG"),
  )
  assert_eq(got, [("{\"type\":\"image/png\",\"size\":4}", 4)])
  // the bytes are the message's only
  let plain : Array[Bool] = []
  c.call_bytes("media.image", on_done=fn(r) {
    plain.push(r is Ok((_, None)))
  })
  |> ignore
  c.receive_json(@json.parse("{\"id\":2,\"ok\":{}}"))
  assert_eq(plain, [true])
}

///|
test "a streamed call: each value before its answer, with the bytes beside it; cancelled, nothing more" {
  let (c, sent) = recorder()
  let heard : Array[String] = []
  let done : Array[String] = []
  let id = c.stream("station.preview", on_value=fn(v, b) {
    heard.push(v.stringify() + " " + b.map(fn(x) { x.length() }).unwrap_or(-1).to_string())
  }, on_done=fn(r) { done.push(if r is Ok(_) { "ok" } else { "err" }) })
  c.receive_json({ "id": Json::number(id.to_double()), "value": { "head": { "status": 200 } } })
  c.receive_json({ "id": Json::number(id.to_double()), "value": { "chunk": true } }, bytes=Some(b"abc"))
  c.receive_json({ "id": Json::number(id.to_double()), "ok": Json::null() })
  assert_eq(heard, ["{\"head\":{\"status\":200}} -1", "{\"chunk\":true} 3"])
  assert_eq(done, ["ok"])
  let id2 = c.stream("station.preview", on_value=fn(_, _) { heard.push("late") })
  c.cancel(id2)
  assert_eq(sent[sent.length() - 1].stringify(), "{\"id\":\{id2},\"cancel\":true}")
  c.receive_json({ "id": Json::number(id2.to_double()), "value": { "chunk": true } })
  assert_eq(heard.length(), 2)
}

///|
test "what is asked of the core is awaited until answered or first read" {
  let sent : Array[String] = []
  let c = @core.Client::new(fn(s) { sent.push(s) })
  let waits : Map[Int, String] = Map([])
  let n = Ref(0)
  c.track(
    fn(what) {
      n.val += 1
      waits[n.val] = what
      n.val
    },
    fn(t) { waits.remove(t) },
  )
  let s = c.subscribe("overview", params={ "station": Json::string("st1") })
  let answers : Array[Result[Json, Json]] = []
  let id = c.call("chat.send", params=Json::object({}), on_done=fn(r) { answers.push(r) })
  assert_eq(waits.length(), 2)
  // the subscription's first value: no longer awaited
  assert_true(c.receive("{\"id\":\{s.id},\"value\":{\"a\":1}}"))
  assert_eq(waits.values().collect(), ["core: chat.send (call \{id})"])
  // a delta later awaits nothing
  assert_true(c.receive("{\"id\":\{id},\"ok\":true}"))
  assert_eq(waits.length(), 0)
  // a stream cancelled, a subscription ended before its value
  let st = c.stream("station.preview", on_value=fn(_, _) {  })
  let s2 = c.subscribe("jobs", params={ "station": Json::string("st1") })
  assert_eq(waits.length(), 2)
  c.cancel(st)
  c.unsubscribe(s2)
  assert_eq(waits.length(), 0)
  // a fatal ends every call's wait; the core started again is asked again, and awaited
  let answers : Array[Result[Json, Json]] = []
  ignore(c.call("x", on_done=fn(r) { answers.push(r) }))
  assert_true(c.receive("{\"fatal\":\"gone\"}"))
  assert_eq(waits.length(), 0)
  c.restarted()
  assert_eq(waits.length(), 1)
}

///|
test "a core started anew is told again where the app's attention is (client.focus, as told last)" {
  let sent : Array[String] = []
  let c = @core.Client::new(fn(m) { sent.push(m) })
  c.call("client.focus", params={ "visible": true, "focused": true, "workspace": "ws1" }) |> ignore
  sent.clear()
  c.restarted()
  assert_eq(sent.length(), 1)
  assert_true(sent[0].contains("client.focus"))
  assert_true(sent[0].contains("\"visible\":true"))
}

///|
test "a core started anew is told again whether the device sends its reports and traces (client.reports, as told last), none where never told" {
  let sent : Array[String] = []
  let c = @core.Client::new(fn(m) { sent.push(m) })
  c.restarted()
  assert_true(sent.filter(fn(m) { m.contains("client.reports") }).is_empty(), msg="never told: nothing told again")
  c.call("client.reports", params={ "on": true }) |> ignore
  c.call("client.reports", params={ "on": false }) |> ignore
  sent.clear()
  c.restarted()
  let told = sent.filter(fn(m) { m.contains("client.reports") })
  assert_eq(told.length(), 1)
  assert_true(told[0].contains("\"on\":false"), msg=told[0])
  // (a client started anew, as a replay attaching to it does, tells nothing of it)
  c.reset()
  sent.clear()
  c.restarted()
  assert_true(sent.filter(fn(m) { m.contains("client.reports") }).is_empty())
}

///|
test "a core started anew is told both the app's attention and the chat it shows, whichever was told last" {
  let sent : Array[String] = []
  let c = @core.Client::new(fn(m) { sent.push(m) })
  c.call("client.focus", params={ "visible": true, "focused": true, "workspace": "ws1" }) |> ignore
  let chat : Json = { "station": "ws1/st1", "session": "s1", "thread": 7, "end": true }
  c.call("client.focus", params={ "chat": chat }) |> ignore
  sent.clear()
  c.restarted()
  assert_eq(sent.length(), 2)
  assert_true(sent[0].contains("\"visible\":true"))
  assert_true(sent[1].contains("\"session\":\"s1\""))
  // another chat's leaving keeps the one shown; its own lets it go
  c.call("client.focus", params={ "left": { "station": "ws1/st1", "session": "s0" } }) |> ignore
  sent.clear()
  c.restarted()
  assert_eq(sent.length(), 2)
  c.call("client.focus", params={ "left": { "station": "ws1/st1", "session": "s1" } }) |> ignore
  sent.clear()
  c.restarted()
  assert_eq(sent.length(), 1)
  assert_true(sent[0].contains("\"visible\":true"))
}

///|
test "a computed keeps a subscription after a direct reader leaves, and its last reader ends it" {
  let (c, sent) = recorder()
  let s = c.subscribe("accounts")
  let worked = Ref(0)
  let seen = @signals.computed(fn(_) {
    worked.val += 1
    // (as an app's source reads a topic_read: core_topic)
    let read = c.follow_topic("accounts")
    match read.value {
      Some(Array(a)) => a.length()
      _ => -1
    }
  })
  assert_eq(seen.get(), -1)
  assert_eq(seen.get(), -1)
  assert_eq(worked.val, 1)
  // the core's first value: pushed on, worked out again once
  assert_true(c.receive("{\"id\":1,\"value\":[]}"))
  assert_eq(seen.get(), 0)
  assert_eq(seen.get(), 0)
  assert_eq(worked.val, 2)
  // a delta
  assert_true(c.receive("{\"id\":1,\"delta\":[{\"path\":[],\"append\":[1]}]}"))
  assert_eq(seen.get(), 1)
  assert_eq(worked.val, 3)
  // The direct reader leaves; the computed still has the same subscription and value.
  c.unsubscribe(s)
  assert_eq(sent.length(), 1)
  assert_eq(seen.get(), 1)
  assert_eq(worked.val, 3)
  assert_true(c.receive("{\"id\":1,\"value\":[7,8]}"))
  assert_eq(seen.get(), 2)
  seen.dispose()
  assert_eq(sent.length(), 2)
  assert_eq(s.changes.get(), -1)
}

///|
test "a direct hold reacquired while a graph reader leaves keeps its subscription" {
  let (c, sent) = recorder()
  let first = c.subscribe("accounts")
  let seen = @signals.computed(fn(_) { c.follow_topic("accounts").version })
  seen.get() |> ignore
  c.unsubscribe(first)
  let again = c.subscribe("accounts")
  seen.dispose()
  assert_eq(sent.length(), 1)
  assert_true(physical_equal(again, c.peek_topic("accounts").unwrap()))
  c.unsubscribe(again)
  assert_eq(sent.length(), 2)
  assert_true(c.peek_topic("accounts") is None)
}

///|
test "a refreshed subscription still ends when its last graph reader leaves" {
  let (c, sent) = recorder()
  let direct = c.subscribe("accounts")
  let seen = @signals.computed(fn(_) { c.follow_topic("accounts").version })
  seen.get() |> ignore
  c.unsubscribe(direct)
  c.refresh_topic("accounts")
  assert_eq(sent.length(), 3)
  assert_eq(c.peek_topic("accounts").unwrap().id, 2)
  seen.dispose()
  assert_eq(sent.length(), 4)
  assert_eq(sent[3].stringify(), ({ "id": 2, "unsubscribe": true } : Json).stringify())
  assert_true(c.peek_topic("accounts") is None)
}

///|
test "a deferred retirement cannot end a subscription made after reset" {
  let (c, sent) = recorder()
  let direct = c.subscribe("accounts")
  let seen = @signals.computed(fn(_) { c.follow_topic("accounts").version })
  seen.get() |> ignore
  @signals.start_batch()
  c.unsubscribe(direct)
  seen.dispose()
  c.reset()
  let fresh = c.subscribe("accounts")
  @signals.end_batch()
  assert_eq(sent.length(), 2)
  assert_true(physical_equal(fresh, c.peek_topic("accounts").unwrap()))
  c.unsubscribe(fresh)
  assert_eq(sent.length(), 3)
}

///|
test "a quiet call's values and an unread call's answer may be taken as they come; the rest may not" {
  let (c, _) = recorder()
  c.quiet("screen.view", fn(v) { v is Object(o) && o.keys().all(fn(k) { k == "frame" }) })
  c.unread("screen.ack")
  let values : Array[String] = []
  let view = c.stream("screen.view", on_value=fn(v, _) { values.push(v.stringify()) })
  let ack = c.call("screen.ack")
  let read : Array[Result[Json, Json]] = []
  let other = c.call("prefs.set", on_done=fn(r) { read.push(r) })
  let said = fn(m : Json) {
    guard m is Object(o) else { return false }
    c.call_said(o)
  }
  // a frame alone: quiet; a state: what a frame reads
  assert_true(said({ "id": view, "value": { "frame": { "ts": 1 } } }))
  assert_false(said({ "id": view, "value": { "state": {} } }))
  assert_false(said({ "id": view, "value": { "frame": { "ts": 1 }, "config": {} } }))
  // its answer is read
  assert_false(said({ "id": view, "ok": {} }))
  // the ack's answer nobody reads; another call's is read
  assert_true(said({ "id": ack, "ok": {} }))
  assert_true(said({ "id": ack, "error": {} }))
  assert_false(said({ "id": other, "ok": {} }))
  // answered: nothing more of it is said
  c.receive_json({ "id": ack, "ok": {} })
  assert_false(said({ "id": ack, "ok": {} }))
  c.receive_json({ "id": view, "value": { "frame": { "ts": 2 } } })
  assert_eq(values, ["{\"frame\":{\"ts\":2}}"])
  // over: its values no longer quiet
  c.receive_json({ "id": view, "ok": {} })
  assert_false(said({ "id": view, "value": { "frame": { "ts": 3 } } }))
}

///|
test "more of a list asked from what it has: its first value what changed from that one's, which is kept till it comes" {
  let (c, sent) = recorder()
  let first = c.subscribe("chatRows", params={ "station": "ws/a", "limit": 2 })
  assert_true(c.receive("{\"id\":1,\"value\":{\"items\":[{\"id\":\"a\"},{\"id\":\"b\"}]}}"))
  let more = c.subscribe("chatRows", params={ "station": "ws/a", "limit": 4 })
  assert_eq(sent[1].stringify(), ({ "id": 2, "subscribe": { "topic": "chatRows", "station": "ws/a", "limit": 4 }, "keyed": true, "from": 1 } : Json).stringify())
  // (the one shown till then let go of: kept, as the delta to come is from it)
  c.unsubscribe(first)
  assert_eq(sent.length(), 2)
  let ops = "[{\"path\":[\"items\"],\"key\":[\"id\"],\"put\":{\"id\":\"c\"},\"before\":null},{\"path\":[\"items\"],\"key\":[\"id\"],\"put\":{\"id\":\"d\"},\"before\":null}]"
  assert_true(c.receive("{\"id\":2,\"delta\":" + ops + ",\"from\":1}"))
  assert_eq(more.value.unwrap().stringify(), "{\"items\":[{\"id\":\"a\"},{\"id\":\"b\"},{\"id\":\"c\"},{\"id\":\"d\"}]}")
  // (its rows had kept as they were)
  match (first.value, more.value) {
    (Some(Object(a)), Some(Object(b))) =>
      match (a.get("items"), b.get("items")) {
        (Some(Array(x)), Some(Array(y))) => assert_true(physical_equal(x[0], y[0]))
        _ => fail("no items")
      }
    _ => fail("no values")
  }
  assert_eq(sent[2].stringify(), ({ "id": 1, "unsubscribe": true } : Json).stringify())
}

///|
test "a call still answering keeps its name as the record forgets the others: its progress is said by it" {
  let (c, _) = recorder()
  let id = c.stream("station.preview", on_value=fn(_, _) {  })
  let done = c.call("chat.read")
  assert_eq(c.perf_name({ "id": Json::number(done.to_double()), "ok": Json::null() }), "answer chat.read")
  c.perf_forget()
  assert_eq(c.perf_name({ "id": Json::number(id.to_double()), "value": { "chunk": true } }), "progress station.preview")
  assert_eq(c.perf_name({ "id": Json::number(id.to_double()), "ok": Json::null() }), "answer station.preview")
}

///|
test "a value or a delta for an id nothing holds is told from its head, unread, and counted by what the id was" {
  let (c, sent) = recorder()
  let stations = c.subscribe("stations")
  let view = c.stream("screen.view", on_value=fn(_, _) {  })
  let read : Array[Result[Json, Json]] = []
  let other = c.call("prefs.set", on_done=fn(r) { read.push(r) })
  // held: read as any message (a subscription's, a stream's, a call's awaiting its answer)
  assert_false(c.unheld("{\"id\":\{stations.id},\"value\":{\"a\":1}}"))
  assert_false(c.unheld("{\"id\":\{view},\"value\":{\"frame\":{}}}"))
  assert_false(c.unheld("{\"id\":\{other},\"value\":1}"))
  // let go of: what the core said before it was told so is not read (not JSON past its head here: never parsed)
  c.unsubscribe(stations)
  assert_eq(sent[sent.length() - 1].stringify(), ({ "id": 1, "unsubscribe": true } : Json).stringify())
  c.cancel(view)
  assert_true(c.unheld("{\"id\":\{stations.id},\"value\":{never read"))
  assert_true(c.unheld("{\"id\":\{stations.id},\"delta\":[never read"))
  assert_true(c.unheld("{\"id\":\{view},\"value\":{never read"))
  // an id never let go of here: `?`
  assert_true(c.unheld("{\"id\":77,\"value\":1}"))
  // not written as a value or a delta at its head: read whole, as ever (an answer, a fatal, what is no message)
  assert_false(c.unheld("{\"id\":77,\"ok\":1}"))
  assert_false(c.unheld("{\"id\":77,\"error\":{}}"))
  assert_false(c.unheld("{\"id\":77}"))
  assert_false(c.unheld("{\"fatal\":\"boom\"}"))
  assert_false(c.unheld("{\"value\":1,\"id\":77}"))
  assert_false(c.unheld("{\"id\":\"77\",\"value\":1}"))
  assert_false(c.unheld("{\"id\":12345678901,\"value\":1}"))
  assert_false(c.unheld("not json"))
  assert_false(c.unheld(""))
  assert_eq(c.unheld_said(), [("topic stations", 2, 54), ("?", 1, 19), ("call screen.view", 1, 27)])
  // (begun again)
  assert_eq(c.unheld_said(), [])
}

///|
test "a list's page asked from the one shown: that one is held till the page comes, then what is said to it is not" {
  let (c, _) = recorder()
  let first = c.subscribe("chatRows", params={ "station": "ws/a", "limit": 2 })
  assert_true(c.receive("{\"id\":1,\"value\":{\"items\":[]}}"))
  let _more = c.subscribe("chatRows", params={ "station": "ws/a", "limit": 4 })
  c.unsubscribe(first)
  // (let go of, kept for the page's first value: still read)
  assert_false(c.unheld("{\"id\":1,\"delta\":[]}"))
  assert_true(c.receive("{\"id\":2,\"delta\":[],\"from\":1}"))
  assert_true(c.unheld("{\"id\":1,\"delta\":[]}"))
  assert_eq(c.unheld_said(), [("topic chatRows", 1, 19)])
}

///|
test "what the core says to an id nothing holds is taken as it comes, and as a frame is built, unread" {
  @core.unheld_said() |> ignore
  // (as it comes: taken, nothing left for the frame to build for; not JSON past its head: never parsed)
  assert_true(@core.receive_said("{\"id\":424242,\"value\":{never read", None))
  // (after one left for the frame, handed straight to `receive`)
  @core.receive("{\"id\":424242,\"delta\":[never read", None)
  assert_eq(@core.unheld_said(), [("?", 2, 64)])
}

///|
test "a kept topic is let go of keeping its value till the core says its version, and asked again with it" {
  let (c, sent) = recorder()
  c.keep(fn(name, _) { if name == "stations" { 64 } else { 0 } })
  let s = c.subscribe("stations", params={ "scope": "ws" })
  c.receive("{\"id\":1,\"value\":[{\"id\":\"a\",\"t\":\"A\"}]}") |> ignore
  c.unsubscribe(s)
  assert_eq(sent[1].stringify(), ({ "id": 1, "unsubscribe": true, "keep": true } : Json).stringify())
  // What the core sent before it was told: applied still to what is kept, not let be as for what nothing holds.
  let changed = "{\"id\":1,\"delta\":[{\"path\":[],\"key\":[\"id\"],\"patch\":\"a\",\"ops\":[{\"path\":[\"t\"],\"set\":\"A2\"}]}]}"
  assert_false(c.unheld(changed))
  c.receive(changed) |> ignore
  // Asked again before the core's answer: no version to say yet, asked as ever.
  let early = c.subscribe("stations", params={ "scope": "other" })
  assert_eq(early.id, 2)
  c.receive("{\"id\":1,\"v\":\"k:1\"}") |> ignore
  // After it, nothing more is the id's.
  assert_true(c.unheld("{\"id\":1,\"value\":[]}"))
  let again = c.subscribe("stations", params={ "scope": "ws" })
  assert_eq(
    sent[3].stringify(),
    ({ "id": 3, "subscribe": { "topic": "stations", "scope": "ws" }, "keyed": true, "have": "k:1" } : Json).stringify(),
  )
  assert_true(again.value is None)
  let v0 = c.version
  c.receive("{\"id\":3,\"same\":true}") |> ignore
  // the value kept, with what changed of it before the answer
  assert_eq(again.value.unwrap().stringify(), "[{\"id\":\"a\",\"t\":\"A2\"}]")
  assert_eq(again.version, 1)
  assert_eq(c.version, v0 + 1)
  // Let go of and asked again once more, the core saying it changed meanwhile: its value whole, as ever.
  c.unsubscribe(again)
  c.receive("{\"id\":3,\"v\":\"k:2\"}") |> ignore
  let third = c.subscribe("stations", params={ "scope": "ws" })
  assert_eq(sent[sent.length() - 1].stringify(), ({ "id": 4, "subscribe": { "topic": "stations", "scope": "ws" }, "keyed": true, "have": "k:2" } : Json).stringify())
  c.receive("{\"id\":4,\"value\":[]}") |> ignore
  assert_eq(third.value.unwrap().stringify(), "[]")
  // Its version said once: let go of without its value kept answered (none), and asked anew without it.
  c.unsubscribe(third)
  c.receive("{\"id\":4,\"v\":null}") |> ignore
  let fourth = c.subscribe("stations", params={ "scope": "ws" })
  assert_eq(sent[sent.length() - 1].stringify(), ({ "id": 5, "subscribe": { "topic": "stations", "scope": "ws" }, "keyed": true } : Json).stringify())
  assert_true(fourth.value is None)
}

///|
test "a topic not kept is let go of as ever" {
  let (c, sent) = recorder()
  c.keep(fn(name, _) { if name == "stations" { 64 } else { 0 } })
  let other = c.subscribe("accounts")
  c.receive("{\"id\":1,\"value\":[]}") |> ignore
  c.unsubscribe(other)
  assert_eq(sent[1].stringify(), ({ "id": 1, "unsubscribe": true } : Json).stringify())
}

///|
test "a kept topic let go of before its first value: said so all the same; what comes before the core's word kept, else nothing" {
  // (its value come before the core's word of its leaving: kept, and asked again with its version)
  let (c, sent) = recorder()
  c.keep(fn(name, _) { if name == "stations" { 64 } else { 0 } })
  let s = c.subscribe("stations", params={ "scope": "ws" })
  c.unsubscribe(s)
  assert_eq(sent[1].stringify(), ({ "id": 1, "unsubscribe": true, "keep": true } : Json).stringify())
  c.receive("{\"id\":1,\"value\":[{\"id\":\"a\"}]}") |> ignore
  c.receive("{\"id\":1,\"v\":\"k:1\"}") |> ignore
  let again = c.subscribe("stations", params={ "scope": "ws" })
  assert_eq(
    sent[2].stringify(),
    ({ "id": 2, "subscribe": { "topic": "stations", "scope": "ws" }, "keyed": true, "have": "k:1" } : Json).stringify(),
  )
  c.receive("{\"id\":2,\"same\":true}") |> ignore
  assert_eq(again.value.unwrap().stringify(), "[{\"id\":\"a\"}]")
  // (nothing come before the core's word: nothing kept, asked again as ever)
  let (c, sent) = recorder()
  c.keep(fn(name, _) { if name == "stations" { 64 } else { 0 } })
  let s = c.subscribe("stations", params={ "scope": "ws" })
  c.unsubscribe(s)
  assert_eq(sent[1].stringify(), ({ "id": 1, "unsubscribe": true, "keep": true } : Json).stringify())
  c.receive("{\"id\":1,\"v\":null}") |> ignore
  let again = c.subscribe("stations", params={ "scope": "ws" })
  assert_eq(sent[2].stringify(), ({ "id": 2, "subscribe": { "topic": "stations", "scope": "ws" }, "keyed": true } : Json).stringify())
  assert_true(again.value is None)
  // (after the core's word, nothing more is the id's)
  assert_true(c.unheld("{\"id\":1,\"value\":[]}"))
}

///|
test "a kept value is forgotten by reset" {
  let (c, sent) = recorder()
  c.keep(fn(name, _) { if name == "stations" { 64 } else { 0 } })
  let s = c.subscribe("stations", params={ "scope": "ws" })
  c.receive("{\"id\":1,\"value\":[1]}") |> ignore
  c.unsubscribe(s)
  c.receive("{\"id\":1,\"v\":\"k:1\"}") |> ignore
  c.reset()
  c.subscribe("stations", params={ "scope": "ws" }) |> ignore
  assert_eq(sent[sent.length() - 1].stringify(), ({ "id": 1, "subscribe": { "topic": "stations", "scope": "ws" }, "keyed": true } : Json).stringify())
}

///|
test "a kept topic asked again is given what changed from what it kept: applied, the same value as whole" {
  let (c, sent) = recorder()
  c.keep(fn(name, _) { if name == "stations" { 64 } else { 0 } })
  let s = c.subscribe("stations", params={ "scope": "ws" })
  c.receive("{\"id\":1,\"value\":[{\"id\":\"a\",\"t\":\"A\"},{\"id\":\"b\",\"t\":\"B\"}]}") |> ignore
  c.unsubscribe(s)
  c.receive("{\"id\":1,\"v\":\"k:1\"}") |> ignore
  let again = c.subscribe("stations", params={ "scope": "ws" })
  assert_eq(sent[sent.length() - 1].stringify(), ({ "id": 2, "subscribe": { "topic": "stations", "scope": "ws" }, "keyed": true, "have": "k:1" } : Json).stringify())
  // (nothing of it shown before the core's answer)
  assert_true(again.value is None)
  let v0 = c.version
  c.receive(
    "{\"id\":2,\"kept\":true,\"delta\":[{\"path\":[],\"key\":[\"id\"],\"patch\":\"a\",\"ops\":[{\"path\":[\"t\"],\"set\":\"A2\"}]},{\"path\":[],\"key\":[\"id\"],\"put\":{\"id\":\"c\",\"t\":\"C\"},\"before\":null}]}",
  )
  |> ignore
  assert_eq(again.version, 1)
  assert_eq(c.version, v0 + 1)
  // The same as the value whole would have been
  let whole = c.subscribe("stations", params={ "scope": "other" })
  c.receive("{\"id\":3,\"value\":[{\"id\":\"a\",\"t\":\"A2\"},{\"id\":\"b\",\"t\":\"B\"},{\"id\":\"c\",\"t\":\"C\"}]}") |> ignore
  assert_eq(again.value.unwrap().stringify(), whole.value.unwrap().stringify())
  // Taken out as it came: let go of without keeping and asked again, no version said.
  c.keep(fn(_, _) { 0 })
  c.unsubscribe(again)
  c.subscribe("stations", params={ "scope": "ws" }) |> ignore
  assert_eq(sent[sent.length() - 1].stringify(), ({ "id": 4, "subscribe": { "topic": "stations", "scope": "ws" }, "keyed": true } : Json).stringify())
}

///|
test "a topic's name keeps as many values as said, the oldest forgotten; one forgotten before its answer is asked whole" {
  let (c, sent) = recorder()
  c.keep(fn(name, _) { if name == "chat" { 4 } else if name == "stations" { 64 } else { 0 } })
  let list = c.subscribe("stations", params={ "scope": "ws" })
  c.receive("{\"id\":1,\"value\":[]}") |> ignore
  c.unsubscribe(list)
  c.receive("{\"id\":1,\"v\":\"l:1\"}") |> ignore
  // Five chats opened and let go of: the four last kept, and the list beside them.
  for i in 0..<5 {
    let s = c.subscribe("chat", params={ "station": "ws/a", "session": "s\{i}" })
    c.receive("{\"id\":\{s.id},\"value\":{\"title\":\"\{i}\"}}") |> ignore
    c.unsubscribe(s)
    c.receive("{\"id\":\{s.id},\"v\":\"c:\{i}\"}") |> ignore
  }
  let had = fn() { sent[sent.length() - 1].stringify().contains("\"have\"") }
  let first = c.subscribe("chat", params={ "station": "ws/a", "session": "s0" })
  assert_false(had(), msg="the oldest chat forgotten")
  let second = c.subscribe("chat", params={ "station": "ws/a", "session": "s1" })
  assert_true(had())
  c.subscribe("stations", params={ "scope": "ws" }) |> ignore
  assert_true(had(), msg="the list not counted with the chats")
  // Asked with its version, its kept value forgotten before the answer (four more chats let go of meanwhile): what
  // changed from it cannot be applied, so it is asked again, whole.
  for i in 5..<9 {
    let s = c.subscribe("chat", params={ "station": "ws/a", "session": "s\{i}" })
    c.receive("{\"id\":\{s.id},\"value\":{\"title\":\"\{i}\"}}") |> ignore
    c.unsubscribe(s)
    c.receive("{\"id\":\{s.id},\"v\":\"c:\{i}\"}") |> ignore
  }
  c.receive("{\"id\":\{second.id},\"kept\":true,\"delta\":[{\"path\":[\"title\"],\"set\":\"1b\"}]}") |> ignore
  assert_true(second.value is None)
  assert_eq(sent[sent.length() - 1].stringify(), ({ "id": second.id, "subscribe": { "topic": "chat", "station": "ws/a", "session": "s1" }, "keyed": true } : Json).stringify())
  c.receive("{\"id\":\{second.id},\"value\":{\"title\":\"1b\"}}") |> ignore
  assert_eq(second.value.unwrap().stringify(), "{\"title\":\"1b\"}")
  assert_true(first.value is None)
}

///|
test "a call given no on_done: sent as any call, its id its own; its answer nobody reads, awaited by nothing, taken as it comes" {
  let (c, sent) = recorder()
  let waits : Array[String] = []
  c.track(fn(what) { waits.push(what); waits.length() }, fn(_) {  })
  let told = c.call("client.focus", params={ "chat": "ws/a" })
  let read : Array[Result[Json, Json]] = []
  let asked = c.call("chat.send", params={ "text": "hi" }, on_done=fn(r) { read.push(r) })
  // (on the wire as ever: the same message, its own id)
  assert_eq(sent[0].stringify(), ({ "id": told, "call": "client.focus", "params": { "chat": "ws/a" } } : Json).stringify())
  assert_eq(sent[1].stringify(), ({ "id": asked, "call": "chat.send", "params": { "text": "hi" } } : Json).stringify())
  // (awaited: only the one whose answer is read)
  assert_eq(waits, ["core: chat.send (call \{asked})"])
  let said = fn(m : Json) {
    guard m is Object(o) else { return false }
    c.call_said(o)
  }
  assert_true(said({ "id": told, "ok": {} }))
  assert_true(said({ "id": told, "error": {} }))
  assert_false(said({ "id": asked, "ok": {} }))
  // (its answer taken: nothing runs, nothing more of it is said)
  c.receive_json({ "id": told, "ok": {} })
  assert_false(said({ "id": told, "ok": {} }))
  c.receive_json({ "id": asked, "ok": { "sent": true } })
  assert_eq(read.length(), 1)
}

///|
/// A client keeping `chatJobs` (16 of them) and showing what it kept at once as it is asked again (Client::show_kept).
fn shown_kept_recorder() -> (@core.Client, Array[Json]) {
  let (c, sent) = recorder()
  c.keep(fn(name, _) { if name == "chatJobs" { 16 } else { 0 } })
  c.show_kept(fn(name) { name == "chatJobs" })
  (c, sent)
}

///|
test "a topic shown as kept: asked again, its value kept is its value at once, the core's `same` making it the core's, the same object" {
  let (c, sent) = shown_kept_recorder()
  let params : Map[String, Json] = { "station": "ws/a", "session": "s1" }
  let s = c.subscribe("chatJobs", params~)
  assert_true(c.receive("{\"id\":1,\"value\":{\"jobs\":[{\"id\":\"j1\",\"name\":\"dev\"}]}}"))
  let had = s.value.unwrap()
  c.unsubscribe(s)
  assert_true(c.receive("{\"id\":1,\"v\":\"k:1\"}"))
  // Asked again: shown at once as kept, before the core says anything, its version below every core's.
  let again = c.subscribe("chatJobs", params~)
  assert_true(again.value is Some(v) && physical_equal(v, had), msg="the value kept, the same object, at once")
  assert_eq(again.version, -2)
  assert_eq(sent[sent.length() - 1].stringify(), ({ "id": 2, "subscribe": { "topic": "chatJobs", "station": "ws/a", "session": "s1" }, "keyed": true, "have": "k:1" } : Json).stringify())
  // The core's `same`: the same object still, now the core's.
  assert_true(c.receive("{\"id\":2,\"same\":true}"))
  assert_true(again.value is Some(v) && physical_equal(v, had), msg="the same object once the core says it is the same")
  assert_eq(again.version, 1)
  // What changes after goes on from it as ever.
  assert_true(c.receive("{\"id\":2,\"delta\":[{\"path\":[\"jobs\",0,\"name\"],\"set\":\"web\"}]}"))
  assert_eq(again.value.unwrap().stringify(), "{\"jobs\":[{\"id\":\"j1\",\"name\":\"web\"}]}")
  assert_eq(again.version, 2)
}

///|
test "a topic shown as kept, its first answer what changed from what it kept: applied to it, made the core's" {
  let (c, _) = shown_kept_recorder()
  let s = c.subscribe("chatJobs")
  assert_true(c.receive("{\"id\":1,\"value\":{\"n\":1,\"t\":\"A\"}}"))
  c.unsubscribe(s)
  assert_true(c.receive("{\"id\":1,\"v\":\"k:1\"}"))
  let again = c.subscribe("chatJobs")
  assert_eq(again.value.unwrap().stringify(), "{\"n\":1,\"t\":\"A\"}")
  assert_true(c.receive("{\"id\":2,\"kept\":true,\"delta\":[{\"path\":[\"n\"],\"set\":2}]}"))
  assert_eq(again.value.unwrap().stringify(), "{\"n\":2,\"t\":\"A\"}")
  assert_eq(again.version, 1)
  // a whole value or an error after a showing as kept, the same as any first answer
  c.unsubscribe(again)
  assert_true(c.receive("{\"id\":2,\"v\":\"k:2\"}"))
  let third = c.subscribe("chatJobs")
  assert_eq(third.value.unwrap().stringify(), "{\"n\":2,\"t\":\"A\"}")
  assert_true(c.receive("{\"id\":3,\"value\":{\"n\":3}}"))
  assert_eq(third.value.unwrap().stringify(), "{\"n\":3}")
  assert_eq(third.version, 1)
}

///|
test "a topic let go of and asked again before the core said its version: what it held shown at once, asked whole" {
  let (c, sent) = shown_kept_recorder()
  let s = c.subscribe("chatJobs")
  assert_true(c.receive("{\"id\":1,\"value\":{\"n\":1}}"))
  c.unsubscribe(s)
  // (closed and opened again at once: the core's `{id, v}` still on its way)
  let again = c.subscribe("chatJobs")
  assert_eq(again.value.unwrap().stringify(), "{\"n\":1}")
  assert_eq(again.version, -2)
  let asked = sent[sent.length() - 1].stringify()
  assert_true(!asked.contains("have"), msg=asked)
  assert_true(c.receive("{\"id\":1,\"v\":\"k:1\"}"))
  assert_true(c.receive("{\"id\":2,\"value\":{\"n\":2}}"))
  assert_eq(again.value.unwrap().stringify(), "{\"n\":2}")
  assert_eq(again.version, 1)
}

///|
test "a topic shown as kept and let go of before the core answers keeps nothing new of what it showed: the one kept before stays" {
  let (c, sent) = shown_kept_recorder()
  let s = c.subscribe("chatJobs")
  assert_true(c.receive("{\"id\":1,\"value\":{\"n\":1}}"))
  c.unsubscribe(s)
  assert_true(c.receive("{\"id\":1,\"v\":\"k:1\"}"))
  let again = c.subscribe("chatJobs")
  c.unsubscribe(again)
  // (its core's word of a value it never sent it: nothing kept for it)
  assert_true(c.receive("{\"id\":2,\"v\":\"k:9\"}"))
  let third = c.subscribe("chatJobs")
  assert_eq(third.value.unwrap().stringify(), "{\"n\":1}")
  let asked = sent[sent.length() - 1].stringify()
  assert_true(asked.contains("\"have\":\"k:1\"") && !asked.contains("k:9"), msg=asked)
}

///|
test "a topic not shown as kept, or a client told nothing of it, waits for the core's answer as before" {
  let (c, _) = recorder()
  c.keep(fn(name, _) { if name == "chatJobs" || name == "chat" { 16 } else { 0 } })
  c.show_kept(fn(name) { name == "chatJobs" })
  let s = c.subscribe("chat")
  assert_true(c.receive("{\"id\":1,\"value\":{\"n\":1}}"))
  c.unsubscribe(s)
  assert_true(c.receive("{\"id\":1,\"v\":\"k:1\"}"))
  let again = c.subscribe("chat")
  assert_true(again.value is None, msg="a chat's kept value waits for the core")
  assert_eq(again.version, 0)
}

///|
test "what is kept is forgotten as the one signed in changes: asked again whole, nothing shown before the core answers" {
  let (c, sent) = shown_kept_recorder()
  let s = c.subscribe("chatJobs")
  assert_true(c.receive("{\"id\":1,\"value\":{\"n\":1}}"))
  c.unsubscribe(s)
  assert_true(c.receive("{\"id\":1,\"v\":\"k:1\"}"))
  c.forget_kept()
  let again = c.subscribe("chatJobs")
  assert_true(again.value is None)
  let asked = sent[sent.length() - 1].stringify()
  assert_true(!asked.contains("have"), msg=asked)
}

///|
test "what comes for a kept topic let go of is taken unread: a whole value read over goes unread, what is kept read as it is asked again" {
  let (c, sent) = shown_kept_recorder()
  let s = c.subscribe("chatJobs")
  assert_true(c.receive("{\"id\":1,\"value\":{\"n\":1}}"))
  c.unsubscribe(s)
  let v0 = c.version
  // (taken from its head alone: not JSON past it here, so never parsed; a whole value after it put in its place)
  assert_true(c.later("{\"id\":1,\"value\":{never read"))
  assert_true(c.later("{\"id\":1,\"delta\":[never read"))
  assert_true(c.later("{\"id\":1,\"value\":{\"n\":2}}"))
  assert_true(c.later("{\"id\":1,\"delta\":[{\"path\":[\"n\"],\"set\":3}]}"))
  // (nothing a frame reads changed: nothing is built for it)
  assert_eq(c.version, v0)
  // not a value or a delta at its head, or for one not let go of: read as ever
  assert_false(c.later("{\"id\":1,\"v\":\"k:1\"}"))
  assert_false(c.later("{\"id\":1,\"error\":{}}"))
  assert_false(c.later("{\"id\":77,\"value\":1}"))
  assert_true(c.receive("{\"id\":1,\"v\":\"k:1\"}"))
  // Asked again: what is kept is what was sent, all of it applied, read now.
  let again = c.subscribe("chatJobs")
  assert_eq(again.value.unwrap().stringify(), "{\"n\":3}")
  assert_eq(sent[sent.length() - 1].stringify(), ({ "id": 2, "subscribe": { "topic": "chatJobs" }, "keyed": true, "have": "k:1" } : Json).stringify())
  let had = again.value.unwrap()
  assert_true(c.receive("{\"id\":2,\"same\":true}"))
  assert_true(again.value is Some(v) && physical_equal(v, had), msg="the value kept read once, the same object")
  assert_eq(again.version, 1)
}

///|
test "what comes for a kept topic let go of, read where it is shown again before the core says its version" {
  let (c, sent) = shown_kept_recorder()
  let s = c.subscribe("chatJobs")
  assert_true(c.receive("{\"id\":1,\"value\":{\"n\":1,\"t\":\"A\"}}"))
  c.unsubscribe(s)
  assert_true(c.receive("{\"id\":1,\"delta\":[{\"path\":[\"n\"],\"set\":2}]}"))
  // (opened again at once: shown from the one let go of, what came for it read now)
  let again = c.subscribe("chatJobs")
  assert_eq(again.value.unwrap().stringify(), "{\"n\":2,\"t\":\"A\"}")
  assert_eq(again.version, -2)
  assert_true(!sent[sent.length() - 1].stringify().contains("have"))
  // (more for the one let go of after it was read: taken unread again, kept as its version comes)
  assert_true(c.receive("{\"id\":1,\"delta\":[{\"path\":[\"t\"],\"set\":\"B\"}]}"))
  assert_true(c.receive("{\"id\":1,\"v\":\"k:1\"}"))
  assert_true(c.receive("{\"id\":2,\"value\":{\"n\":9}}"))
  c.unsubscribe(again)
  assert_true(c.receive("{\"id\":2,\"v\":\"k:2\"}"))
  let third = c.subscribe("chatJobs")
  assert_eq(third.value.unwrap().stringify(), "{\"n\":9}")
}

///|
test "what comes for a kept topic let go of, then a message read whole for it: those before it applied first" {
  let (c, _) = shown_kept_recorder()
  let s = c.subscribe("chatJobs")
  assert_true(c.receive("{\"id\":1,\"value\":{\"n\":1}}"))
  c.unsubscribe(s)
  assert_true(c.receive("{\"id\":1,\"delta\":[{\"path\":[\"n\"],\"set\":2}]}"))
  // (the core's error for it: what it held is no more, what came before it read and let be)
  assert_true(c.receive("{\"id\":1,\"error\":{\"code\":\"x\"}}"))
  assert_true(c.receive("{\"id\":1,\"v\":\"k:1\"}"))
  let again = c.subscribe("chatJobs")
  assert_true(again.value is None, msg="nothing kept of an error")
  // (`same` read whole after what came unread: applied to it, the version going on)
  let (c, _) = shown_kept_recorder()
  let s = c.subscribe("chatJobs")
  assert_true(c.receive("{\"id\":1,\"value\":{\"n\":1}}"))
  c.unsubscribe(s)
  assert_true(c.receive("{\"id\":1,\"delta\":[{\"path\":[\"n\"],\"set\":2}]}"))
  assert_true(c.receive("{\"id\":1,\"same\":true}"))
  assert_true(c.receive("{\"id\":1,\"v\":\"k:1\"}"))
  assert_eq(c.subscribe("chatJobs").value.unwrap().stringify(), "{\"n\":2}")
}

///|
test "a kept topic let go of before its first value: what changed of nothing is let be, a whole value come unread is kept" {
  let (c, sent) = shown_kept_recorder()
  let s = c.subscribe("chatJobs")
  c.unsubscribe(s)
  // (what changed of no value: let be, its version not moved, so nothing is kept of it)
  assert_true(c.later("{\"id\":1,\"delta\":[{\"path\":[\"n\"],\"set\":2}]}"))
  assert_true(c.receive("{\"id\":1,\"v\":\"k:1\"}"))
  let again = c.subscribe("chatJobs")
  assert_true(again.value is None)
  assert_true(!sent[sent.length() - 1].stringify().contains("have"))
  // (a whole value, then what changed of it, unread: kept, both applied as it is asked again)
  c.unsubscribe(again)
  assert_true(c.later("{\"id\":2,\"value\":{\"n\":1}}"))
  assert_true(c.later("{\"id\":2,\"delta\":[{\"path\":[\"n\"],\"set\":2}]}"))
  assert_true(c.receive("{\"id\":2,\"v\":\"k:2\"}"))
  let third = c.subscribe("chatJobs")
  assert_eq(third.value.unwrap().stringify(), "{\"n\":2}")
  assert_eq(sent[sent.length() - 1].stringify(), ({ "id": 3, "subscribe": { "topic": "chatJobs" }, "keyed": true, "have": "k:2" } : Json).stringify())
}

///|
test "what comes for a list let go of while more of it is asked from it is taken unread, read as the more's first value comes" {
  let (c, sent) = recorder()
  let first = c.subscribe("chatRows", params={ "station": "ws/a", "limit": 2 })
  assert_true(c.receive("{\"id\":1,\"value\":{\"items\":[{\"id\":\"a\"},{\"id\":\"b\"}]}}"))
  let more = c.subscribe("chatRows", params={ "station": "ws/a", "limit": 4 })
  c.unsubscribe(first)
  let v0 = c.version
  // (the core's change to the one let go of, before it gave the more its first: unread till then)
  assert_true(c.later("{\"id\":1,\"delta\":[{\"path\":[\"items\"],\"key\":[\"id\"],\"patch\":\"b\",\"ops\":[{\"path\":[\"t\"],\"set\":\"B\"}]}]}"))
  assert_eq(c.version, v0)
  let ops = "[{\"path\":[\"items\"],\"key\":[\"id\"],\"put\":{\"id\":\"c\"},\"before\":null}]"
  assert_true(c.receive("{\"id\":2,\"delta\":" + ops + ",\"from\":1}"))
  assert_eq(more.value.unwrap().stringify(), "{\"items\":[{\"id\":\"a\"},{\"id\":\"b\",\"t\":\"B\"},{\"id\":\"c\"}]}")
  assert_eq(sent[sent.length() - 1].stringify(), ({ "id": 1, "unsubscribe": true } : Json).stringify())
  // (let go of whole once that came: what the core still says to it, nothing holds)
  assert_false(c.later("{\"id\":1,\"value\":{}}"))
  assert_true(c.unheld("{\"id\":1,\"value\":{}}"))
}

///|
test "what comes for one let go of that nothing reads (not kept, nothing asked from it waiting) is let be" {
  let (c, _) = recorder()
  let first = c.subscribe("chatRows", params={ "station": "ws/a", "limit": 2 })
  assert_true(c.receive("{\"id\":1,\"value\":{\"items\":[]}}"))
  let more = c.subscribe("chatRows", params={ "station": "ws/a", "limit": 4 })
  c.unsubscribe(first)
  // (the one asked from it let go of too before its first value: nothing will read the first's)
  c.unsubscribe(more)
  assert_true(c.later("{\"id\":1,\"value\":{never read"))
  assert_true(c.later("{\"id\":1,\"delta\":[never read"))
}

///|
test "what the core says to one let go of is taken as it comes, and as a frame is built, unread" {
  let first = @core.subscribe("chatRows", params={ "station": "ws/later", "limit": 2 })
  @core.receive("{\"id\":\{first.id},\"value\":{\"items\":[]}}", None)
  let more = @core.subscribe("chatRows", params={ "station": "ws/later", "limit": 4 })
  @core.unsubscribe(first)
  // (as it comes: taken, nothing left for the frame to build for; not JSON past its head: not parsed as it comes)
  assert_true(@core.receive_said("{\"id\":\{first.id},\"value\":{\"items\":[{\"id\":\"a\"}]}}", None))
  @core.receive("{\"id\":\{first.id},\"delta\":[{\"path\":[\"items\"],\"key\":[\"id\"],\"put\":{\"id\":\"b\"},\"before\":null}]}", None)
  @core.receive("{\"id\":\{more.id},\"delta\":[],\"from\":\{first.id}}", None)
  assert_eq(more.value.unwrap().stringify(), "{\"items\":[{\"id\":\"a\"},{\"id\":\"b\"}]}")
  @core.unsubscribe(more)
  @core.unheld_said() |> ignore
}
