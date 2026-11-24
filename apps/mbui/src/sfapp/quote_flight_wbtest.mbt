// What is quoted, sent (sfpages composer.mbt flying_quotes, sfbase's flight.mbt): in the list with its message from the
// frame it is sent, as the core's row will have it; its card flying there from its card in the composer, its words
// setting out from where they were.

///|
/// A passage no message of the made-up chat has.
let quote_passage : String = "表头先对齐第三列"

///|
/// Where the quote's words are seen now under the bar (each copy of its card's words, not see-through): their top left
/// and how opaque.
fn quote_seen(t : @ui.Tester) -> Array[(Double, Double, Double)] {
  t.words().filter(fn(w) { w.0.contains(quote_passage) && w.5 > 0.5 && w.2 > 60.0 }).map(fn(w) { (w.1, w.2, w.5) })
}

///|
/// Where the quote's words are seen now: the most opaque copy of them (a card flown as one box from the composer's to
/// a message's: the one's words going as the other's come, each where its card has it), else the test fails; two
/// seen whole apart fail it too.
fn quote_once(t : @ui.Tester) -> (Double, Double) raise {
  let at = quote_seen(t)
  guard at.length() > 0 else { fail("the quote not seen at \{t.time()}") }
  let mut best = at[0]
  for p in at {
    if p.2 > best.2 {
      best = p
    }
  }
  for p in at {
    if p.2 > 0.999 && best.2 > 0.999 && ((p.0 - best.0).abs() > 0.5 || (p.1 - best.1).abs() > 0.5) {
      fail("the quote seen twice apart at \{t.time()}: \{Repr(at)}")
    }
  }
  (best.0, best.1)
}

///|
/// The quote's card as drawn now: the least of what is drawn round its words (x, y, w, h).
fn quote_ground(t : @ui.Tester) -> (Double, Double, Double, Double) raise {
  let (x, y) = quote_once(t)
  let mut least : (Double, Double, Double, Double)? = None
  for r in t.drawn_rects() {
    let (rx, ry, rw, rh, colour) = r
    // (a card at least 24 by 16, as the flight's own card is (mbui particle_flight_paint.mbt): its dust, 2 to 2.8 across
    // and seeded by the card's node, is no card, wherever it drifts)
    if (colour & 0xFFL) != 0L &&
      rw >= 24.0 &&
      rh >= 16.0 &&
      rx <= x + 1.0 &&
      ry <= y + 1.0 &&
      rx + rw >= x + 1.0 &&
      ry + rh >= y + 1.0 {
      match least {
        Some((_, _, lw, lh)) if lw * lh <= rw * rh => ()
        _ => least = Some((rx, ry, rw, rh))
      }
    }
  }
  match least {
    Some(g) => g
    None => fail("nothing drawn round the quote at \{t.time()}")
  }
}

///|
/// Whether the composer's hint (发消息; a new chat's, 做任何事) is seen now: drawn in its colour where it is.
fn hint_seen(t : @ui.Tester, hint? : String = "发消息") -> Bool {
  match t.words().iter().find_first(fn(w) { w.0 == hint }) {
    Some((_, x, y, w, h, _)) =>
      t
      .drawn_glyphs()
      .iter()
      .any(fn(g) { g.0 >= x - 1.0 && g.0 <= x + w + 1.0 && g.1 >= y - 1.0 && g.1 <= y + h + 1.0 && g.2 == @sf.theme().p.subtle })
    None => false
  }
}

///|
/// How much of a quote's ✕ is seen now (its round, 20 across, in the ink): 0 none.
fn x_seen(t : @ui.Tester) -> Double {
  let ink = @sf.theme().p.text
  let mut most = 0.0
  for r in t.drawn_rects() {
    let (_, _, w, h, colour) = r
    if w >= 16.0 && w <= 21.0 && (h - w).abs() < 0.5 && colour >> 8 == ink >> 8 {
      let a = (colour & 0xFFL).to_double() / 255.0
      if a > most {
        most = a
      }
    }
  }
  most
}

///|
/// Whether a quote's ✕ seen now is drawn over its card (after the card's ground), where both are drawn.
fn x_over_card(t : @ui.Tester) -> Bool raise {
  let ink = @sf.theme().p.text
  let rects = t.drawn_rects()
  let (gx, gy, gw, gh) = quote_ground(t)
  let mut card = -1
  let mut x = -1
  for k, r in rects {
    let (rx, ry, rw, rh, colour) = r
    if (rx - gx).abs() < 0.5 && (ry - gy).abs() < 0.5 && (rw - gw).abs() < 0.5 && (rh - gh).abs() < 0.5 {
      card = k
    }
    if rw >= 16.0 && rw <= 21.0 && (rh - rw).abs() < 0.5 && colour >> 8 == ink >> 8 && (colour & 0xFFL) != 0L {
      x = k
    }
  }
  card < 0 || x < 0 || x > card
}

///|
/// The send button's ground as drawn now: its round.
fn send_ground(t : @ui.Tester) -> Int64 raise {
  let (x, y, w, h) = match t.query(Button, label=@sf.t("web-main.composer.send")) {
    Some(b) => b.rect
    None => fail("no send button")
  }
  // (its round: the largest round about its middle, what it is pressed in reaching past it; drawn on its way as the
  // composer changes shape, its place in the capsule's end and in the opened box's corner 1.13 apart: smooth.mbt
  // capsule_in)
  let (mx, my) = (x + w / 2.0, y + h / 2.0)
  let mut round : (Double, Double, Double, Double, Int64)? = None
  for r in t.drawn_rects() {
    if (r.0 + r.2 / 2.0 - mx).abs() < 1.5 && (r.1 + r.3 / 2.0 - my).abs() < 1.5 && (r.2 - r.3).abs() < 0.5 {
      match round {
        Some(b) if b.2 >= r.2 => ()
        _ => round = Some(r)
      }
    }
  }
  match round {
    Some(r) => r.4
    None => {
      let near = t.drawn_rects().filter(fn(r) { r.0 < x + w && r.0 + r.2 > x && r.1 < y + h && r.1 + r.3 > y })
      fail("nothing drawn as the send button at \{Repr((x, y, w, h))}: \{Repr(near)}")
    }
  }
}

///|
/// The chat's composer with the passage quoted in it, what is said about it typed in its line.
fn quoting(calls : Array[Made]) -> @ui.Tester {
  let made : Ref[Source?] = Ref(None)
  let t = fake_core(calls, made~)
  let src = made.val.unwrap()
  @sfbase.writing_quote(src, @sfbase.writing(src, "ws1/st1:s-c1"), {
    "author": "Claude",
    "text": quote_passage,
    "ts": "ts8",
  })
  t.run_for(@ui.move_most_ms)
  t.type_text("这里要对齐")
  t.draw()
  t
}

///|
test "a long quoted picture's words do not rewrap as the card sets out" {
  both_pages(fn() raise {
    new_run()
    let src = fixture("chat")
    open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
    let passage = quote_passage + "，然后把表格中的每一项逐一检查，确保发送前后文字不会在这里突然换行"
    let file : Json = {
      "name": "long-quote.png", "path": "/w/uploads/long-quote.png", "size": 120,
      "width": 1600, "height": 900, "owner": "s-c1",
    }
    @sfbase.writing_quote(src, @sfbase.writing(src, "ws1/st1:s-c1"), {
      "author": "Ana", "text": Json::string(passage), "ts": "ts8",
    }, file~)
    t.run_for(@ui.move_most_ms + @ui.image_fade_ms)
    let before = t.lines_of(passage)
    assert_true(before.length() > 0, msg="the quote's words were not laid out")
    tap_send(t)
    let first = t.lines_of(passage)
    assert_eq(first, before, msg="the quote's words rewrapped on sending")
  })
}

///|
test "a quote sent alone is in the list at once, its card flying there from the composer's: seen every frame, from where its words were" {
  both_pages(fn() raise {
    let calls : Array[Made] = []
    let t = quoting(calls)
    let was = quote_once(t)
    let (_, _, wide, _) = quote_ground(t)
    tap_send(t)
    // in the list from the frame it is sent, as the core will have it (composer.ts take: what is said about it with it)
    let sent = sending_of("ws1/st1\u{1}s-c1")
    assert_eq(sent.length(), 1)
    assert_eq(sent[0].row.quotes.map(fn(q) { (q.text, q.comment, q.ts) }), [(quote_passage, "这里要对齐", "ts8")])
    // (the old page's flight; made as nodes, its row flies from where the composer had it: its SentFrom, mbui's
    // View::flies_in, what follows holds the same of it)
    // where its words were as it is sent, then every frame till it has landed: never gone, never twice apart
    let at = quote_once(t)
    assert_true((at.0 - was.0).abs() < 0.5 && (at.1 - was.1).abs() < 0.5, msg="sent, seen at \{Repr(at)}, not \{Repr(was)}")
    // its card as wide as it was in the composer as it sets out, and narrower only on its way (filtering out the
    // full-page background while the card surface is dissolved into particles mid-flight)
    let widths = [quote_ground(t).2]
    let sent_at = t.time()
    let mut hinted = false
    while t.time() < sent_at + flight_ms + 50.0 {
      t.frame()
      quote_once(t) |> ignore
      let g = quote_ground(t).2
      if g <= wide + 1.0 {
        widths.push(g)
      }
      // the composer's hint away while the card is over it (the field comes up under it as the composer comes down)
      if t.time() < sent_at + flight_ms / 4.0 && hint_seen(t) {
        hinted = true
      }
    }
    assert_false(hinted)
    // and not back once it is out of it: the words' field has the cursor its comment line had (composer_hint)
    t.run_for(@sf.hint_back_ms)
    assert_eq(focused_field(t), "发消息")
    assert_false(hint_seen(t))
    // landed in its message, over the composer, as wide as it needs
    let (_, y) = quote_once(t)
    assert_true(y < was.1 - 40.0, msg="landed at \{y}, its words were at \{was.1}")
    let landed = widths[widths.length() - 1]
    assert_true(landed < wide - 40.0, msg="landed \{landed} wide, as the composer's \{wide}")
    // (its card going from the composer's width to its own on its way: starts at wide, never wider than wide or
    // widening backward)
    assert_true((widths[0] - wide).abs() < 0.5, msg="set out \{widths[0]} wide, not \{wide}: \{Repr(widths)}")
    for k in 1..<widths.length() {
      if widths[k] > wide + 0.5 || widths[k] > widths[k - 1] + 0.5 {
        fail("its width went from \{widths[k - 1]} to \{widths[k]}: \{Repr(widths)}")
      }
    }
  })
}

///|
/// Which field has the keyboard's focus now: its hint ("" none).
fn focused_field(t : @ui.Tester) -> String {
  match t.focused() {
    Some(s) if s.role is TextField => s.label
    _ => ""
  }
}

///|
test "sent with the focus in its comment line, a quote leaves the focus in the words' field" {
  both_pages(fn() raise {
    let calls : Array[Made] = []
    let t = quoting(calls)
    assert_eq(focused_field(t), "添加说明（可选）")
    tap_send(t)
    t.run_for(flight_ms + 50.0)
    assert_eq(focused_field(t), "发消息")
  })
}

///|
test "taken out with the focus in its comment line, a quote leaves the focus in the words' field" {
  both_pages(fn() raise {
    let calls : Array[Made] = []
    let t = quoting(calls)
    assert_eq(focused_field(t), "添加说明（可选）")
    t.click(Button, label=@sf.t("web-main.quote.remove"))
    t.run_for(@sf.leave_ms + 50.0)
    assert_eq(focused_field(t), "发消息")
  })
}

///|
test "words sent with a quote land under its card, which is in their row from the frame they are sent" {
  both_pages(fn() raise {
    let calls : Array[Made] = []
    let t = quoting(calls)
    t.tap_text("发消息")
    t.type_text("先上屏")
    tap_send(t)
    assert_eq(sending_of("ws1/st1\u{1}s-c1")[0].row.quotes.length(), 1)
    t.run_for(flight_ms + 50.0)
    let (_, qy) = quote_once(t)
    match t.drawn_of("先上屏") {
      Some((_, wy)) => assert_true(qy < wy, msg="the quote at \{qy}, the words at \{wy}")
      None => fail("the words not drawn")
    }
  })
}

///|
test "sent, a quote's ✕ leaves with its card and the send button fades to faint: neither at once" {
  both_pages(fn() raise {
    let calls : Array[Made] = []
    let t = quoting(calls)
    // (as it came up when the draft could be sent)
    t.run_for(@sf.dur_ms)
    let ready = send_ground(t)
    assert_true(x_seen(t) > 0.9)
    tap_send(t)
    let xs = [x_seen(t)]
    let grounds = [send_ground(t)]
    let sent_at = t.time()
    while t.time() < sent_at + @sf.leave_ms + 50.0 {
      t.frame()
      xs.push(x_seen(t))
      grounds.push(send_ground(t))
      // over its card all the way, never under it
      assert_true(x_over_card(t), msg="the ✕ under its card at \{t.time()}")
    }
    // the ✕: seen as it sets out, fading on (never back), gone once it has left (made as nodes, flown with its card as
    // one box to the message's, View::shared's `container`: cut by that box's edge as it narrows, as what the card
    // holds is, at its own size)
    assert_true(xs[0] > 0.9, msg="\{Repr(xs)}")
    assert_eq(xs[xs.length() - 1], 0.0)
    for k in 1..<xs.length() {
      if xs[k] > xs[k - 1] + 0.01 {
        fail("the ✕ came back: \{Repr(xs)}")
      }
    }
    // the send button: through what lies between its two grounds, not from one to the other at once
    let faint = grounds[grounds.length() - 1]
    assert_true(faint != ready)
    assert_true(grounds.iter().any(fn(g) { g != ready && g != faint }), msg="\{Repr(grounds)}")
  })
}

///|
test "a draft's quote with no id of its own takes no cursor on a phone, on the old page and made as nodes; its ✕ leaves none" {
  new_run()
  @sf.presenters_reset()
  let src = fixture("chat-quote")
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t.run_for(@ui.move_most_ms)
  assert_eq(focused_field(t), "", msg="opened")
  t.click(Button, label=@sf.t("web-main.quote.remove"))
  t.run_for(@ui.move_most_ms)
  assert_eq(focused_field(t), "", msg="its quote taken out")
}

///|
test "小屏: quote card enters near full width without overlapping bottom controls, removes cleanly, and restores composer caret after settle or immediate typing" {
  let calls : Array[Made] = []
  let made : Ref[Source?] = Ref(None)
  let t = fake_core(calls, made~)
  let src = made.val.unwrap()
  t.draw()
  let assert_quote_above_send = fn(phase : String) -> Unit raise {
    let send_y = match t.query(Button, label=@sf.t("web-main.composer.send")) {
      Some(b) => b.rect.1
      None => return
    }
    let q_words = t.words().filter(fn(w) { w.0.contains(quote_passage) && w.5 > 0.02 && w.2 > 60.0 })
    if q_words.is_empty() {
      return
    }
    let (_, qx, qy, _, _, _) = q_words[0]
    for a in t.drawn_instances_keyed() {
      let kind = a[5]
      let rx = a[0]
      let ry = a[1]
      let rw = a[2]
      let rh = a[3]
      let alpha = a[11]
      let cy0 = a[17]
      let cy1 = a[19]
      if kind == 0.0 &&
        alpha > 0.01 &&
        rw >= 100.0 &&
        rh >= 16.0 &&
        rh < 120.0 &&
        rx <= qx + 2.0 &&
        ry <= qy + 2.0 &&
        rx + rw >= qx + 2.0 &&
        ry + rh >= qy + 2.0 {
        let vis_bottom = @sf.dmin(ry + rh, cy1)
        assert_true(
          vis_bottom <= send_y + 0.5,
          msg="\{phase}: quote card visible bottom \{vis_bottom} overlapped send button top \{send_y} (ry=\{ry}, rh=\{rh}, clip=[\{cy0}, \{cy1}]) at \{t.time()}",
        )
      }
    }
  }
  // 1) Add a quote from the shut capsule: width stays >= 94% of resting width AND clipped bottom never overlaps `+`/`↑`.
  @sfbase.writing_quote(src, @sfbase.writing(src, "ws1/st1:s-c1"), {
    "author": "Claude",
    "text": quote_passage,
    "ts": "ts8",
  })
  let add_at = t.time()
  let mut min_w = 1.0e9
  while t.time() - add_at < @ui.move_most_ms {
    t.frame_as_host() |> ignore
    assert_quote_above_send("enter")
    if quote_seen(t).length() > 0 {
      let gw = quote_ground(t).2
      if gw < min_w {
        min_w = gw
      }
    }
  }
  t.run_for(@ui.move_most_ms)
  let rest_w = quote_ground(t).2
  assert_true(min_w >= rest_w * 0.94, msg="entering quote card shrank to \{min_w} (< 94% of \{rest_w})")
  let assert_no_orphan_x = fn(phase : String) -> Unit raise {
    let xa = x_seen(t)
    if xa <= 0.02 {
      return
    }
    let mut best_vis_h = 0.0
    for a in t.drawn_instances_keyed() {
      if a[5] == 0.0 && a[11] > 0.005 && a[2] >= 100.0 && a[3] >= 30.0 && a[3] < 120.0 {
        let vis_h = @sf.dmin(a[1] + a[3], a[19]) - @sf.dmax(a[1], a[17])
        if vis_h > best_vis_h {
          best_vis_h = vis_h
        }
      }
    }
    assert_true(
      best_vis_h >= 24.0,
      msg="\{phase}: orphan ✕ visible (alpha=\{xa}) after quote card collapsed (best_vis_h=\{best_vis_h}) at \{t.time()}",
    )
  }
  // 2) Delete single quote via ✕: collapsing quote card must never overlap `+`/`↑` and ✕ must vanish before card collapses.
  t.click(Button, label=@sf.t("web-main.quote.remove"))
  let rm_at = t.time()
  while t.time() - rm_at < @ui.move_most_ms {
    t.frame_as_host() |> ignore
    assert_quote_above_send("remove")
    assert_no_orphan_x("remove")
  }
  t.run_for(@ui.move_most_ms)
  // 3) Re-add quote, type a comment, send: composer caret stays hidden past sent_out_away_ms (where composer is still collapsing)
  //    and until composer hold+down finishes, then cleanly returns.
  @sfbase.writing_quote(src, @sfbase.writing(src, "ws1/st1:s-c1"), {
    "author": "Claude",
    "text": quote_passage,
    "ts": "ts8",
  })
  t.run_for(@ui.move_most_ms)
  t.type_text("手机引用说明")
  t.draw()
  guard composer_field(t) is Some((fx, _, fw, _)) else { fail("no composer field") }
  let quote_away_ms = @sf.dmax(@sfbase.sent_out_away_ms(), @sfbase.sent_out_hold_ms + @sfbase.sent_down_ms)
  assert_true(quote_away_ms > @sfbase.sent_out_away_ms() + 100.0, msg="quote away_ms did not extend past plain sent_out_away_ms")
  tap_send(t)
  let sent_at = t.time()
  let mut checked_past_plain_away = false
  while t.time() - sent_at < quote_away_ms - 1.0 {
    let dt = t.time() - sent_at
    if dt > @sfbase.sent_out_away_ms() + 16.0 {
      checked_past_plain_away = true
    }
    match mf_caret(t, fx, fw) {
      Some(r) => fail("caret appeared mid-flight at +\{dt}ms: \{Repr(r)}")
      None => ()
    }
    t.frame_as_host() |> ignore
  }
  assert_true(checked_past_plain_away, msg="did not check caret past plain sent_out_away_ms")
  t.run_for(@sfbase.sent_out_hold_ms)
  assert_true(mf_caret(t, fx, fw) is Some(_), msg="composer caret did not return after quote send settled")
  // 4) Immediate typing right after sending a quote restores the caret immediately without waiting move_most_ms.
  @sfbase.writing_quote(src, @sfbase.writing(src, "ws1/st1:s-c1"), {
    "author": "Claude",
    "text": quote_passage,
    "ts": "ts8",
  })
  t.run_for(@ui.move_most_ms)
  tap_send(t)
  t.run_for(@sfbase.sent_out_hold_ms)
  t.type_text("先上屏")
  t.draw()
  assert_true(mf_caret(t, fx, fw) is Some(_), msg="immediate typing after quote send kept caret hidden")
}
