// What is put into a composer begins changing it at once; what it already holds goes with its ground.

///|
let composer_sample_ms : Double = 50.0

///|
test "a quote already in the composer moves with its ground as another is added" {
  new_run()
  let src = fixture("chat")
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(@ui.move_most_ms)
  let w = @sfbase.writing(src, "ws1/st1:s-c1")
  @sfbase.writing_quote(src, w, { "author": "Ana", "text": quote_passage, "ts": "ts8" })
  t.run_for(@ui.move_most_ms)
  let gap = quote_ground(t).1 - composer_glass(t).1
  @sfbase.writing_quote(src, w, { "author": "Ana", "text": "第二段引用", "ts": "ts9" })
  t.run_for(composer_sample_ms)
  let now = quote_ground(t).1 - composer_glass(t).1
  assert_true((now - gap).abs() < 2.0, msg="the first quote did not move with its ground")
}

///|
test "on a small screen a waiting quote moves with the composer when another arrives" {
  let calls : Array[Made] = []
  let made : Ref[Source?] = Ref(None)
  let t = fake_core(calls, made~)
  let src = made.val.unwrap()
  let w = @sfbase.writing(src, "ws1/st1:s-c1")
  @sfbase.writing_quote(src, w, { "author": "Ana", "text": quote_passage, "ts": "ts8" })
  t.run_for(@ui.move_most_ms)
  let ground = fn() {
    let glasses = t.drawn_glass_corners().filter(fn(g) { g.4 > 0.0 })
    glasses.sort_by(fn(a, b) { a.1.compare(b.1) })
    glasses[glasses.length() - 1].1
  }
  let gap = quote_ground(t).1 - ground()
  @sfbase.writing_quote(src, w, { "author": "Ana", "text": "第二段引用", "ts": "ts9" })
  t.run_for(composer_sample_ms)
  assert_true((quote_ground(t).1 - ground() - gap).abs() < 2.0, msg="the first quote did not move with its ground")
}

///|
test "a quote without a visible source comes in within the growing composer" {
  new_run()
  let src = fixture("chat")
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(@ui.move_most_ms)
  @sfbase.writing_quote(src, @sfbase.writing(src, "ws1/st1:s-c1"), {
    "author": "Ana", "text": quote_passage, "ts": "ts8",
  })
  t.run_for(composer_sample_ms)
  let (_, ground_y, _, _) = composer_glass(t)
  let cards = t.drawn_instances().filter(fn(a) {
    // (its card's shape, as big as the composer's room has grown for it by then)
    a[5] == 0.0 && a[3] > 0.0 && a[2] / a[3] > 11.5 && a[2] / a[3] < 14.5 && a[2] < 800.0 && a[1] > 500.0
  })
  assert_true(cards.length() > 0, msg="the quote's card should be drawn")
  assert_true(cards.iter().any(fn(a) { a[1] >= ground_y - 1.0 }), msg="the new quote appeared above the composer's ground")
}

///|
test "a file without a visible source comes in within the growing composer" {
  new_run()
  let src = fixture("chat")
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(@ui.move_most_ms)
  @sfbase.writing_add(src, @sfbase.writing(src, "ws1/st1:s-c1"), "ws1/st1", "新文件.txt", b"test")
  t.run_for(composer_sample_ms)
  let (_, ground_y, _, _) = composer_glass(t)
  let (_, words_y) = t.drawn_of("新文件").unwrap()
  assert_true(words_y >= ground_y - 1.0, msg="the file appeared above the composer's ground")
}

///|
test "a newly added picture appears within the growing composer" {
  new_run()
  let src = fixture("chat")
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(@ui.move_most_ms)
  let w = @sfbase.writing(src, "ws1/st1:s-c1")
  @sfbase.writing_add(src, w, "ws1/st1", "新图片.png", png_head())
  t.run_for(composer_sample_ms)
  let picture = @sfbase.writing_pictures[text(Some(w.files.get()[0]), "id")]
  let images = t.drawn_instances().filter(fn(a) { a[5] == 4.0 && t.image_src(a[20].to_int()) == picture })
  let (_, ground_y, _, _) = composer_glass(t)
  assert_true(images.length() > 0, msg="the picture was not drawn as the composer opened")
  assert_true(images.iter().any(fn(a) {
    let top = dmax(a[1], a[17])
    let bottom = dmin(a[1] + a[3], a[19])
    bottom > top && top >= ground_y - 1.0
  }), msg="the picture was visible above the composer's ground")
}

///|
test "a newly added picture comes in whole, never cut or faded across as the composer opens" {
  new_run()
  let src = fixture("chat")
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(@ui.move_most_ms)
  let w = @sfbase.writing(src, "ws1/st1:s-c1")
  @sfbase.writing_add(src, w, "ws1/st1", "新图片.png", png_head())
  let picture = @sfbase.writing_pictures[text(Some(w.files.get()[0]), "id")]
  let mut seen = 0
  let mut ms = 0.0
  while ms < @ui.move_most_ms {
    t.run_for(@ui.frame_period_default)
    ms = ms + @ui.frame_period_default
    let (_, ground_y, _, _) = composer_glass(t)
    for a in t.drawn_instances() {
      if a[5] != 4.0 || t.image_src(a[20].to_int()) != picture || a[11] <= 0.0 {
        continue
      }
      seen = seen + 1
      let (top, bottom) = (a[1], a[1] + a[3])
      assert_true(a[17] <= top + 0.5 && a[19] >= bottom - 0.5, msg="at \{ms} ms the picture \{top}–\{bottom} was cut to \{a[17]}–\{a[19]}")
      assert_true(!(a[53] > 0.0 && a[52] + a[53] > top + 0.5) && !(a[55] > 0.0 && a[54] - a[55] < bottom - 0.5), msg="at \{ms} ms the picture \{top}–\{bottom} faded across: from its top \{a[52]}+\{a[53]}, its foot \{a[54]}-\{a[55]}")
      assert_true(top >= ground_y - 1.0, msg="at \{ms} ms the picture showed above the composer's ground")
    }
  }
  assert_true(seen > 0, msg="the picture was not drawn as the composer opened")
}

///|
test "a quote sent while the composer opens leaves from where it was seen" {
  new_run()
  let src = fixture("chat")
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.tap_text("发消息")
  t.type_text("先上屏")
  t.run_for(@ui.move_most_ms)
  let w = @sfbase.writing(src, "ws1/st1:s-c1")
  @sfbase.writing_quote(src, w, { "author": "Ana", "text": quote_passage, "ts": "ts8" })
  t.run_for(composer_sample_ms * 2.0)
  let before = quote_once(t)
  tap_send(t)
  // (sent by the node composer: its draft, as the page's source holds it (writing, adopted), emptied, its send
  // button off till the next words)
  assert_true(
    @sfbase.writing(src, "ws1/st1:s-c1").text.get() == "" && t.get(Button, label=@sf.t("web-main.composer.send")).disabled,
    msg="the message was not sent",
  )
  let after = quote_once(t)
  assert_true((after.0 - before.0).abs() < 1.0 && (after.1 - before.1).abs() < 1.0, msg="the quote jumped from \{Repr(before)} to \{Repr(after)} on sending")
}

///|
test "a picture sent while the composer opens leaves from where it was seen" {
  new_run()
  let src = fixture("chat")
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.tap_text("发消息")
  t.type_text("看这张")
  t.run_for(@ui.move_most_ms)
  let w = @sfbase.writing(src, "ws1/st1:s-c1")
  @sfbase.writing_add(src, w, "ws1/st1", "新图片.png", png_head())
  let picture = @sfbase.writing_pictures[text(Some(w.files.get()[0]), "id")]
  t.run_for(composer_sample_ms * 2.0)
  let before = picture_instances(t, picture)[0].1
  tap_send(t)
  // (sent by the node composer: its draft, as the page's source holds it (writing, adopted), emptied, its send
  // button off till the next words)
  assert_true(
    @sfbase.writing(src, "ws1/st1:s-c1").text.get() == "" && t.get(Button, label=@sf.t("web-main.composer.send")).disabled,
    msg="the message was not sent",
  )
  let after = picture_instances(t, picture)
  let sent = match after.iter().find_first(fn(p) { (p.1[0] - before[0]).abs() < 1.0 && (p.1[1] - before[1]).abs() < 1.0 }) {
    Some((_, a)) => a
    None => fail("the picture moved as it was sent")
  }
  let visible_before = (dmax(before[1], before[17]), dmin(before[1] + before[3], before[19]))
  let visible_after = (dmax(sent[1], sent[17]), dmin(sent[1] + sent[3], sent[19]))
  assert_true((visible_after.0 - visible_before.0).abs() < 1.0 && (visible_after.1 - visible_before.1).abs() < 1.0, msg="the picture's visible part changed from \{Repr(visible_before)} to \{Repr(visible_after)} on sending")
  assert_true((sent[11] - before[11]).abs() < 0.03, msg="the picture's opacity changed on sending")
}

///|
test "an image's marks come into the room the composer opens" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="chat")
  t.run_for(@ui.move_most_ms)
  draft_give("ws1/st1:s-c1", Marked("图片-标注.png", png_head(), [("图片 标注 1", quote_passage, "这里对齐")], "image"))
  t.run_for(composer_sample_ms)
  assert_eq(named(calls, "composer.quote").length(), 1, msg="the mark was not put in the composer")
  let (_, ground_y, _, _) = composer_glass(t)
  // (its card's words, as much of them as is seen while the composer's room grows for it: none above its ground)
  let under_ground = fn(words : String) {
    match t.shown_of(words) {
      Some((_, y, _, h)) => h <= 0.0 || y >= ground_y - 1.0
      None => true
    }
  }
  assert_true(t.find(quote_passage) is Some(_), msg="the mark's card was not drawn")
  // (laid out over the composer's top as its room opens, cut there by View::resizes: what is seen of it never above)
  assert_true(under_ground(quote_passage), msg="the mark was visible above the composer's ground")
  t.run_for(@ui.move_most_ms)
  quote_once(t) |> ignore
}

///|
test "an existing file stays in place when a quote is added above it" {
  new_run()
  let src = fixture("chat")
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(@ui.move_most_ms)
  let w = @sfbase.writing(src, "ws1/st1:s-c1")
  @sfbase.writing_add(src, w, "ws1/st1", "原有文件.txt", b"test")
  t.run_for(@ui.move_most_ms)
  let before = t.drawn_of("原有文件").unwrap().1
  @sfbase.writing_quote(src, w, { "author": "Ana", "text": quote_passage, "ts": "ts8" })
  t.draw()
  let first = t.drawn_of("原有文件").unwrap().1
  t.run_for(composer_sample_ms)
  let mid = t.drawn_of("原有文件").unwrap().1
  assert_true((first - before).abs() < 1.0 && (mid - before).abs() < 2.0, msg="the existing file jumped when the quote came in")
}

///|
test "a waiting video is a picture tile from the first frame, its composer steady when its still arrives" {
  let calls : Array[Made] = []
  let made : Ref[Source?] = Ref(None)
  let t = fake_core(calls, made~)
  let src = made.val.unwrap()
  let w = @sfbase.writing(src, "ws1/st1:s-c1")
  @sfbase.writing_add(src, w, "ws1/st1", "视频.mov", b"video")
  @sfbase.writing_add(src, w, "ws1/st1", "日志.txt", b"log")
  t.draw()
  let id = text(Some(w.files.get()[0]), "id")
  assert_true(t.query(Group, label="视频.mov") is None)
  t.run_for(composer_sample_ms)
  match waiting_tile_at(t, "ws1/st1//draft:" + id) {
    Some(tile) =>
      assert_true(
        (tile.2 - tile.3).abs() < 0.5 && tile.2 > 20.0 && tile.2 < 56.0,
        msg="expected smoothly scaling square tile at \{composer_sample_ms}ms, got \{Repr(tile)}",
      )
    None => fail("waiting video tile not drawn at \{composer_sample_ms}ms")
  }
  t.run_for(@ui.move_most_ms)
  // (its tile in the node composer: a 56 square, where the viewer's flight would end, waiting_tile_at; still before its video still arrives)
  assert_eq(waiting_tile_at(t, "ws1/st1//draft:" + id).map(fn(tile) { (tile.2, tile.3) }), Some((56.0, 56.0)))
  let ground = fn() {
    let glasses = t.drawn_glass_corners().filter(fn(g) { g.4 > 0.0 })
    glasses.sort_by(fn(a, b) { a.1.compare(b.1) })
    glasses[glasses.length() - 1].1
  }
  let before = ground()
  @sfbase.writing_pictures[id] = "mem:fixture/video-still.png"
  t.draw()
  let first = ground()
  t.run_for(composer_sample_ms)
  let mid = ground()
  assert_true((first - before).abs() < 1.0 && (mid - before).abs() < 1.0, msg="the composer's ground moved when the video's picture appeared")
}

///|
test "a quote appears in place when motion is reduced" {
  new_run()
  let src = fixture("chat")
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.set_reduce_motion(true)
  t.draw()
  let w = @sfbase.writing(src, "ws1/st1:s-c1")
  @sfbase.writing_quote(src, w, { "author": "Ana", "text": quote_passage, "ts": "ts8" })
  t.draw()
  assert_true(quote_ground(t).1 >= composer_glass(t).1, msg="the quote did not appear in the composer")
}

///|
/// Check that no visible glyph or attachment card/tile inside the composer's extras region is clipped vertically.
/// When `allow_quote_foot_clip` is true (during `quotes_room.resizes(open_top=true)`), the animating quote card's
/// own body/caret may clip cleanly at the room's animated bottom edge while top edges, `✕` badges, file cards, and
/// image tiles remain completely unclipped.
fn assert_no_extras_clip(
  t : @ui.Tester,
  min_x : Double,
  max_x : Double,
  min_y : Double,
  max_y : Double,
  label : String,
  allow_quote_foot_clip? : Bool = false,
) -> Unit raise {
  for g in t.glyph_clips() {
    let ((gx, gy, gw, gh), (_, cy0, _, cy1)) = g
    if gh <= 0.5 || gw <= 0.5 || gx + gw <= min_x || gx >= max_x || gy + gh <= min_y || gy >= max_y {
      continue
    }
    // Skip tall non-composer text blocks if any overlap
    if gh > 40.0 {
      continue
    }
    assert_true(
      cy0 <= gy + 0.5 && (allow_quote_foot_clip || cy1 >= gy + gh - 0.5),
      msg="\{label}: glyph at (\{gx},\{gy} \{gw}x\{gh}) was clipped to \{cy0}–\{cy1}",
    )
  }
  for a in t.drawn_instances() {
    if a[11] <= 0.01 || a[3] <= 0.5 {
      continue
    }
    let (left, right, top, bottom) = (a[0], a[0] + a[2], a[1], a[1] + a[3])
    if right <= min_x || left >= max_x || bottom <= min_y || top >= max_y {
      continue
    }
    // Check image tiles (kind 4) and file/quote cards & close buttons (kind 0, height <= 72);
    // under allow_quote_foot_clip, skip thin comment-field carets (width <= 4) clipped by quotes_room's animated foot.
    let is_card_or_badge = a[5] == 0.0 && a[3] <= 72.0 && a[2] <= 260.0 && (!allow_quote_foot_clip || a[2] >= 16.0)
    if a[5] == 4.0 || is_card_or_badge {
      assert_true(
        a[17] <= top + 0.5 && a[19] >= bottom - 0.5,
        msg="\{label}: instance kind=\{a[5]} at (\{left},\{top} \{a[2]}x\{a[3]}) was clipped to \{a[17]}–\{a[19]}",
      )
    }
  }
}

///|
test "adding a first picture smoothly grows composer height without clipping" {
  new_run()
  let src = fixture("chat")
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.tap_text("发消息")
  t.run_for(@ui.move_most_ms)
  let h0 = composer_glass(t).3
  let w = @sfbase.writing(src, "ws1/st1:s-c1")
  @sfbase.writing_add(src, w, "ws1/st1", "新图片.png", png_head())
  let mut saw_mid = false
  let mut ms = 0.0
  while ms < @ui.move_most_ms {
    t.run_for(@ui.frame_period_default)
    ms = ms + @ui.frame_period_default
    let (gx, gy, gw, gh) = composer_glass(t)
    if gh > h0 + 2.0 && gh < h0 + 50.0 {
      saw_mid = true
    }
    assert_no_extras_clip(t, gx, gx + gw, gy - 12.0, gy + gh - 44.0, "pic 0->1 at \{ms}ms")
  }
  let h1 = composer_glass(t).3
  assert_true(h1 > h0 + 40.0, msg="composer did not grow for picture: \{h0} -> \{h1}")
  assert_true(saw_mid, msg="composer jumped instantly instead of smoothly growing for picture: \{h0} -> \{h1}")
}

///|
test "adding files, wrapping to row 2, stacking quote, and removing all never clips" {
  new_run()
  let src = fixture("chat")
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.tap_text("发消息")
  t.run_for(@ui.move_most_ms)
  let w = @sfbase.writing(src, "ws1/st1:s-c1")
  let check_window = fn(tag : String, allow_quote_foot_clip : Bool) raise {
    let mut ms = 0.0
    while ms < @ui.move_most_ms {
      t.run_for(@ui.frame_period_default)
      ms = ms + @ui.frame_period_default
      let (gx, gy, gw, gh) = composer_glass(t)
      assert_no_extras_clip(t, gx, gx + gw, gy - 12.0, gy + gh - 44.0, "\{tag} at \{ms}ms", allow_quote_foot_clip~)
    }
  }
  // 0 -> 1 file
  @sfbase.writing_add(src, w, "ws1/st1", "发布变更清单说明.md", b"abc")
  check_window("file 0->1", false)
  // same row 2nd attachment (image)
  @sfbase.writing_add(src, w, "ws1/st1", "截图.png", png_head())
  check_window("same row pic", false)
  // wrap to row 2
  @sfbase.writing_add(src, w, "ws1/st1", "性能压测结果报告.pdf", b"def")
  check_window("file 3", false)
  @sfbase.writing_add(src, w, "ws1/st1", "线上告警排查记录.log", b"ghi")
  check_window("file 4 row2", false)
  // stack quote on files
  @sfbase.writing_quote(src, w, { "author": "Ana", "text": quote_passage, "ts": "ts8" })
  check_window("quote on files", true)
  // remove quote and files one by one
  let qid = text(Some(w.quotes.get()[0]), "id")
  @sfbase.writing_unquote(src, w, qid)
  check_window("remove quote", true)
  while w.files.get().length() > 0 {
    let files = w.files.get()
    let fid = text(Some(files[files.length() - 1]), "id")
    @sfbase.writing_remove(src, w, fid)
    check_window("remove file left=\{w.files.get().length()}", false)
  }
}

///|
test "small screen unfocused capsule adding attachments expands smoothly without clipping" {
  let calls : Array[Made] = []
  let made : Ref[Source?] = Ref(None)
  let t = fake_core(calls, made~)
  let src = made.val.unwrap()
  let w = @sfbase.writing(src, "ws1/st1:s-c1")
  let ground = fn() {
    let glasses = t.drawn_glass_corners().filter(fn(g) { g.4 > 0.0 })
    glasses.sort_by(fn(a, b) { a.1.compare(b.1) })
    glasses[glasses.length() - 1]
  }
  let h0 = ground().3
  @sfbase.writing_add(src, w, "ws1/st1", "构建日志.log", b"log")
  let mut saw_mid = false
  let mut ms = 0.0
  while ms < @ui.move_most_ms {
    t.run_for(@ui.frame_period_default)
    ms = ms + @ui.frame_period_default
    let (gx, gy, gw, gh, _) = ground()
    if gh > h0 + 2.0 && gh < h0 + 90.0 {
      saw_mid = true
    }
    assert_no_extras_clip(t, gx, gx + gw, gy - 12.0, gy + gh - 44.0, "phone capsule 0->1 at \{ms}ms")
    match t.drawn_of("构建日志") {
      Some((_, wy)) => assert_true(wy >= gy - 1.0, msg="at \{ms}ms file text \{wy} above glass \{gy}")
      None => ()
    }
  }
  assert_true(saw_mid, msg="phone capsule did not expand smoothly")
  let fid = text(Some(w.files.get()[0]), "id")
  @sfbase.writing_remove(src, w, fid)
  ms = 0.0
  while ms < @ui.move_most_ms {
    t.run_for(@ui.frame_period_default)
    ms = ms + @ui.frame_period_default
    let (gx, gy, gw, gh, _) = ground()
    assert_no_extras_clip(t, gx, gx + gw, gy - 12.0, gy + gh - 44.0, "phone remove at \{ms}ms")
  }
}

///|
test "small screen focused composer adding, wrapping, and removing attachments animates height smoothly frame by frame" {
  let calls : Array[Made] = []
  let made : Ref[Source?] = Ref(None)
  let t = fake_core(calls, made~, platform=1)
  let src = made.val.unwrap()
  let w = @sfbase.writing(src, "ws1/st1:s-c1")
  t.tap_text("发消息")
  t.resize(390.0, 520.0)
  t.run_for(@ui.move_most_ms)
  let ground = fn() {
    let glasses = t.drawn_glass_corners().filter(fn(g) { g.2 > 200.0 && g.4 > 0.0 })
    glasses.sort_by(fn(a, b) { a.1.compare(b.1) })
    glasses[glasses.length() - 1]
  }
  let fmt_heights = fn(hs : Array[Double]) {
    hs.map(fn(h) { "\{(h * 10.0).round() / 10.0}" }).join(", ")
  }
  let assert_smooth_height_change = fn(tag : String, expect_grow : Bool) raise {
    let h_start = ground().3
    let heights : Array[Double] = [h_start]
    let mut ms = 0.0
    while ms < @ui.move_most_ms {
      t.run_for(@ui.frame_period_default)
      ms = ms + @ui.frame_period_default
      let (gx, gy, gw, gh, _) = ground()
      heights.push(gh)
      assert_no_extras_clip(t, gx, gx + gw, gy - 12.0, gy + gh - 44.0, "\{tag} at \{ms}ms")
    }
    let h_end = heights[heights.length() - 1]
    let total_delta = (h_end - h_start).abs()
    assert_true(
      total_delta > 35.0 && (if expect_grow { h_end > h_start } else { h_end < h_start }),
      msg="\{tag}: unexpected height delta \{h_start} -> \{h_end} (expect_grow=\{expect_grow}), heights=[\{fmt_heights(heights)}]",
    )
    let lo = if h_start < h_end { h_start } else { h_end }
    let hi = if h_start > h_end { h_start } else { h_end }
    let mut mid_count = 0
    let mut max_step = 0.0
    for i in 1..<heights.length() {
      let prev = heights[i - 1]
      let cur = heights[i]
      if cur > lo + 0.5 && cur < hi - 0.5 {
        mid_count = mid_count + 1
      }
      let step = (cur - prev).abs()
      if step > max_step {
        max_step = step
      }
      if expect_grow {
        assert_true(
          cur >= prev - 0.5,
          msg="\{tag}: non-monotonic grow at frame \{i} (\{prev} -> \{cur}), heights=[\{fmt_heights(heights)}]",
        )
      } else {
        assert_true(
          cur <= prev + 0.5,
          msg="\{tag}: non-monotonic shrink at frame \{i} (\{prev} -> \{cur}), heights=[\{fmt_heights(heights)}]",
        )
      }
    }
    assert_true(
      mid_count >= 3,
      msg="\{tag}: expected >= 3 intermediate frames, got \{mid_count}, heights=[\{fmt_heights(heights)}]",
    )
    assert_true(
      max_step < total_delta * 0.45,
      msg="\{tag}: max frame step \{max_step} >= 45% of total delta \{total_delta}, heights=[\{fmt_heights(heights)}]",
    )
  }
  let h0 = ground().3
  // 1. focused 0->1 picture, then 1->0 remove
  @sfbase.writing_add(src, w, "ws1/st1", "新图片.png", png_head())
  assert_smooth_height_change("focused pic 0->1", true)
  let pic_id = text(Some(w.files.get()[0]), "id")
  @sfbase.writing_remove(src, w, pic_id)
  assert_smooth_height_change("focused pic 1->0", false)
  // 2. focused file 0->1, wrap row1->row2, then unwrap row2->row1
  @sfbase.writing_add(src, w, "ws1/st1", "构建日志-1.log", b"log-1")
  assert_smooth_height_change("focused file 0->1", true)
  @sfbase.writing_add(src, w, "ws1/st1", "构建日志-2.log", b"log-2")
  assert_smooth_height_change("focused wrap row1->row2", true)
  let files_after_wrap = w.files.get()
  let last_id = text(Some(files_after_wrap[files_after_wrap.length() - 1]), "id")
  @sfbase.writing_remove(src, w, last_id)
  assert_smooth_height_change("focused unwrap row2->row1", false)
  // 3. remove last remaining file back to 0 and verify height returns to h0
  let first_id = text(Some(w.files.get()[0]), "id")
  @sfbase.writing_remove(src, w, first_id)
  assert_smooth_height_change("focused remove to 0", false)
  let h_final = ground().3
  assert_true(
    (h_final - h0).abs() < 1.0,
    msg="focused remove to 0 did not return to h0: h0=\{h0}, h_final=\{h_final}",
  )
}
