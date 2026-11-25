// The model's panel beside its control (sfpages model_triple.mbt) in a desktop's window: as wide as its columns'
// words, no wider (2026-10-26 用户「没啥内容也这么宽感觉会很奇怪」), and as wide whichever model is picked in it.

///|
/// The fixture's `mode` in a desktop's window, its model's panel open beside its control.
fn model_pop(mode : String, font_scale? : Double = 1.0) -> @ui.Tester {
  let src = fixture_app(mode)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  if font_scale != 1.0 {
    t.set_font_scale(font_scale)
  }
  t.run_for(squeeze_opening)
  t
}

///|
test "a new chat asks before borrowing and sends the request only on confirmation" {
  for win in [corner_windows[0], corner_windows[5]] {
    let calls : Array[Json] = []
    let released : Array[String] = []
    let t = screen_in("newchat", win, "zh", source=Some(fn(base) {
      new_fix.borrow = true
      { ..base, call: fn(name, params, done) {
        if name == "pick.borrow" {
          calls.push(params)
          done(Ok(Json::object({})))
        } else {
          (base.call)(name, params, done)
        }
      }, leave: fn(name, params, reason) {
        if name == "pick" && reason is @sfbase.TopicLeave::Owned(_) {
          released.push(name)
        }
        (base.leave)(name, params, reason)
      } }
    }))
    t.click(Button, has="Opus 5.5")
    t.run_for(squeeze_opening)
    t.click(Button, label="去分享")
    t.run_for(squeeze_opening)
    assert_true(t.find("将账号分享至此 station") is Some(_), msg="\{win.0}: no confirmation")
    assert_true(t.find("这是订阅账号") is Some(_))
    assert_eq(calls.length(), 0)
    assert_eq(released.length(), 0, msg="the selection stays held while the confirmation is open")
    t.click(Button, label="取消")
    t.run_for(squeeze_opening)
    assert_eq(calls.length(), 0, msg="cancel does not borrow")
    assert_true(t.find("将账号分享至此 station") is None, msg="cancel closes confirmation: \{t.dump()}")
    assert_eq(released.length(), 1, msg="\{win.0}: cancel releases the selection, saw \{released.length()}")
    if t.query(Button, has="Opus 5.5") is None {
      t.click(Button, label=@sf.t("web-main.sidebar.close"))
      t.run_for(squeeze_opening)
    }
    t.click(Button, has="Opus 5.5")
    t.run_for(squeeze_opening)
    t.click(Button, label="去分享")
    t.run_for(squeeze_opening)
    assert_eq(released.length(), 1, msg="the selection stays held for the second confirmation")
    t.click(Button, label="确认分享")
    t.run_for(squeeze_opening)
    assert_eq(calls.length(), 1)
    assert_eq(text(Some(calls[0]), "of"), "new")
    assert_true(text(Some(calls[0]), "station") != "")
    assert_true(t.find("将账号分享至此 station") is None)
    assert_eq(released.length(), 2, msg="a completed borrowing releases the selection")
  }
}

///|
test "the borrowing note is visible at phone and desktop sizes" {
  for win in [corner_windows[0], corner_windows[5]] {
    let t = screen_in("newchat-borrow-model", win, "zh")
    assert_true(t.find("此 Profile 位于 Maple，尚未分享给此 station。") is Some(_), msg="\{win.0}: sharing reason missing")
    assert_true(t.query(Button, label="去分享") is Some(_), msg="\{win.0}: sharing action missing")
  }
}

///|
test "an unavailable workspace profile has a reason and a path to its settings" {
  for win in [corner_windows[0], corner_windows[5]] {
    let t = screen_in("newchat-scope", win, "zh")
    assert_true(t.find("Willow 的 Profile 尚未向此 workspace 开放，请在 Profile 设置中检查分享范围。") is Some(_))
    assert_true(t.query(Button, label="查看 Profile") is Some(_))
  }
}

///|
test "the station's own and shared models are shown first; other stations are asked for and hidden again on reopening" {
  for win in corner_windows {
    for lang in ["zh", "en"] {
      for scale in [1.0, 1.3] {
        let bare = fn(f : String) { f.split(" (at ").collect()[0].to_owned() }
        let held = screen_in("newchat", win, lang, font_scale=scale).audit().map(bare)
        let t = screen_in("newchat-station-models", win, lang, font_scale=scale)
        let here = @sf.t("web-main.model.here")
        let label = @sf.t("web-main.model.everywhere")
        assert_eq(t.get(Radio, label=here).check, Some(On))
        assert_eq(t.get(Radio, label~).check, Some(Off))
        assert_true(t.query(Button, label="Opus 5.5") is Some(_))
        assert_true(t.query(Button, label="Sonnet 5") is Some(_), msg="already shared here")
        assert_true(t.query(Button, label="GPT-6") is None)
        assert_eq(t.audit().map(bare).filter(fn(f) { !held.contains(f) }), [], msg="\{win.0}-\{lang} \{scale}: \{t.audit().join("\n")}")
        t.click(Radio, label~)
        t.run_for(squeeze_opening)
        assert_eq(t.get(Radio, label~).check, Some(On))
        assert_true(t.query(Button, label="GPT-6") is Some(_))
        assert_eq(new_fix.model, "claude-opus-5-5", msg="the filter never selects a model")
        assert_eq(t.audit().map(bare).filter(fn(f) { !held.contains(f) }), [], msg="\{win.0}-\{lang} \{scale}: \{t.audit().join("\n")}")
        t.click(Button, label="Opus 5.5")
        t.run_for(squeeze_opening)
        // The Medium fixture keeps its sidebar over the new chat. Close it before opening the model panel again.
        if t.query(Button, has="Opus 5.5") is None {
          t.click(Button, label=@sf.t("web-main.sidebar.close"))
          t.run_for(squeeze_opening)
        }
        t.click(Button, has="Opus 5.5")
        t.run_for(squeeze_opening)
        assert_eq(t.get(Radio, label=here).check, Some(On))
        assert_true(t.query(Button, label="GPT-6") is None)
      }
    }
  }
}

///|
test "a model panel with none of this station's says so, and still shows those another station could lend" {
  for win in [corner_windows[0], corner_windows[5]] {
    let t = screen_in("newchat-station-empty", win, "zh")
    // (none of this station's: said so, the way to the others' beside it)
    assert_eq(t.get(Radio, label="本机").check, Some(On))
    assert_true(t.find("本机没有可用的模型") is Some(_))
    assert_true(t.query(Button, label="Opus 5.5") is None && t.query(Button, label="GPT-6") is None)
    t.click(Radio, label="所有 station")
    t.run_for(squeeze_opening)
    assert_true(t.query(Button, label="GPT-6") is Some(_))
    t.click(Radio, label="本机")
    t.run_for(squeeze_opening)
    assert_true(t.query(Button, label="GPT-6") is None)
    assert_eq(t.get(Radio, label="本机").check, Some(On))
  }
}

///|
test "wide, short names: the model's panel as wide as what it holds, not as wide as it may be" {
  let t = model_pop("newchat-model")
  let (px, _, pw, _) = t.get(@ui.Role::Dialog).rect
  let effort = t.get(Radio, label="高").rect
  // (what it holds narrow, its foot the widest of it: far narrower than the most it may be)
  assert_true(pw < 2.0 * @sfpages.triple_models_least, msg="\{Repr(t.get(@ui.Role::Dialog).rect)}")
  assert_true(effort.0 + effort.2 <= px + pw - @sf.panel_pad, msg="\{Repr(t.get(@ui.Role::Dialog).rect)} \{Repr(effort)}")
  let model = t.get(Button, label="Opus 5.5").rect
  assert_true(model.0 + model.2 <= px + pw)
}

///|
test "choosing a frequent model fades the model words with the panel" {
  let t = model_pop("newchat-crowded-model")
  let (x, y, w, h) = t.get(@ui.Role::Dialog).rect
  let heading = t.words().filter(fn(item) { item.0 == "常用搭配" }).last().unwrap()
  let surfaces = t.drawn_instances().filter(fn(a) {
    a.length() > 15 && a[5] == 6.0 &&
    (a[0] - x).abs() < 0.1 && (a[1] - y).abs() < 0.1 &&
    (a[2] - w).abs() < 0.1 && (a[3] - h).abs() < 0.1 && a[15] > 0.0
  })
  assert_eq(surfaces.length(), 1, msg="the model panel's surface")
  let original = surfaces[0]
  let original_alpha = (original[15] * 255.0).round().to_int64()
  let in_heading = fn(g : (Double, Double, Int64)) {
    g.0 >= heading.1 - 2.0 && g.0 < heading.1 + heading.3 + 2.0 &&
    g.1 >= heading.2 - 2.0 && g.1 < heading.2 + heading.4 + 2.0
  }
  let before = t.drawn_glyphs().filter(in_heading)
  assert_true(!before.is_empty(), msg="those used most are titled")
  let ink = before.last().unwrap().2
  t.click(Button, label="GPT-6 Astra · 中")
  t.run_for(@motion.pop_out_ms / 2.0)
  let faded = t.drawn_instances().filter(fn(a) {
    a.length() > 15 && a[5] == 6.0 &&
    (a[0] - original[0]).abs() < 10.0 && (a[1] - original[1]).abs() < 10.0 &&
    a[2] > original[2] * 0.96 && a[3] > original[3] * 0.96
  })
  let words = t.drawn_glyphs().filter(fn(g) { in_heading(g) && g.2 >> 8 == ink >> 8 })
  assert_eq(faded.length(), 1, msg="the model panel remains during its fade")
  assert_true(!words.is_empty(), msg="their title remains during its fade")
  let surface_alpha = (faded[0][15] * 255.0).round().to_int64()
  let word_alpha = words.last().unwrap().2 & 0xFFL
  assert_true(surface_alpha > 0L && surface_alpha < 255L, msg="the surface is fading: \{surface_alpha}, its words \{word_alpha}")
  let difference = word_alpha * original_alpha - surface_alpha * (ink & 0xFFL)
  assert_true(difference >= -255L && difference <= 255L, msg="the model words and surface fade together")
}

///|
test "a model choice shows the speed fallback reported by the core" {
  let base = fixture_app("newchat-crowded-model")
  let src : Source = {
    ..base,
    call: fn(name, params, done) {
      (base.call)(name, params, fn(res) {
        match res {
          Ok(_) if name == "pick.save" => done(Ok({ "notice": "Ultrafast 不可用，已改用标准速度。" }))
          _ => done(res)
        }
      })
    },
  }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(squeeze_opening)
  t.click(Button, label="GPT-6 Astra · 中")
  t.run_for(squeeze_opening)
  assert_true(t.find("Ultrafast 不可用，已改用标准速度。") is Some(_))
}

///|
test "a frequent model with a different runtime is applied as its panel leaves without the contents jumping" {
  let t = model_pop("newchat-crowded-model")
  let before = t.find("常用搭配").unwrap()
  let words = fn(name : String) { t.words().filter(fn(w) { w.0 == name }).last().unwrap() }
  let heading = words("常用搭配")
  let row = words("SWE-2")
  let other = words("DeepSeek V4.1 Flash")
  assert_true(t.find("DeepSeek Harness") is Some(_))
  t.click(Button, label="GPT-6 Astra · 中")
  assert_eq(new_fix.model, "gpt-6-astra")
  assert_eq(t.find("常用搭配"), Some(before), msg="the model rows stay where they were as the panel starts to close")
  assert_true(t.find("DeepSeek Harness") is Some(_), msg="the leaving panel keeps the runtime that was shown")
  t.run_for(@motion.pop_out_ms / 2.0)
  // The rows' layout stays fixed while the panel fades and shrinks: drawn smaller with it, all alike (as much smaller
  // as its words are), never laid out anew.
  let heading_out = words("常用搭配")
  let row_out = words("SWE-2")
  let other_out = words("DeepSeek V4.1 Flash")
  let k = heading_out.4 / heading.4
  assert_true(((row_out.2 - heading_out.2) - k * (row.2 - heading.2)).abs() < 1.0, msg="the model rows keep their layout")
  assert_true(((other_out.2 - heading_out.2) - k * (other.2 - heading.2)).abs() < 1.0, msg="the other model row keeps its layout")
  assert_true(t.find("DeepSeek Harness") is Some(_), msg="the runtime stays with the leaving panel")
  // Open it again while the first panel is still leaving: the new one has its own, current contents.
  t.tap_text("GPT-6 Astra")
  t.run_for(@motion.pop_ms)
  assert_true(t.query(@ui.Role::Dialog) is Some(_), msg="the panel opens again")
  assert_true(t.query(Button, label="DeepSeek Harness") is None, msg="the reopened panel shows the new model")
}

///|
test "a new chat's model panel opens where it stays: what the page has shown until its own is read, not first in its bones elsewhere" {
  // (its own pick read a while after it opens, as a core across a thread answers it; the page's already there)
  let held = Ref(true)
  let base = fixture_app("newchat-crowded-model")
  let src : Source = {
    ..base,
    topic_read: fn(name, params) {
      @settings.fixture_followed()
      if name == "pick" && held.val {
        { value: None, error: None, version: -1 }
      } else {
        base.topic(name, params).get().snapshot()
      }
    },
  }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  @sffixture.fix_later(120.0, fn() { held.val = false })
  let rects : Array[(Double, Double, Double, Double)] = []
  let till = t.time() + 400.0
  while t.time() < till {
    t.frame()
    match t.query(@ui.Role::Dialog) {
      Some(d) => if rects.last() != Some(d.rect) { rects.push(d.rect) }
      None => ()
    }
  }
  assert_true(!held.val, msg="its own read")
  // (each frame as it ends up, only grown into it from the side it opens from as it comes in: the same corner, the
  // same shape)
  let (fx, fy, fw, fh) = rects.last().unwrap()
  assert_true(
    rects.iter().all(fn(r) {
      (r.0 - fx).abs() < 1.0 && (r.1 + r.3 - (fy + fh)).abs() < 1.0 && (r.2 / r.3 - fw / fh).abs() < 0.02 * fw / fh
    }),
    msg="\{Repr(rects)}",
  )
}

///|
/// A model pop of the fixture's `mode` whose calls are kept in `calls` (and answered by the fixture), with `liked`
/// starred before it opens.
fn model_pop_calls(mode : String, calls : Array[(String, Json)], liked? : Array[String] = []) -> @ui.Tester {
  let base = fixture_app(mode)
  new_fix.liked.push_iter(liked.iter())
  let src : Source = {
    ..base,
    call: fn(name, params, done) {
      calls.push((name, params))
      (base.call)(name, params, done)
    },
  }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(squeeze_opening)
  t
}

///|
/// What the screen of `mode` (a new chat's page, its model's panel not open) is faulted for by `Tester::audit`: what
/// the panel's screen is held to past it.
fn page_faults(mode : String) -> Array[String] {
  let src = fixture_app(mode)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(squeeze_opening)
  t.audit()
}

///|
/// Whether the rect `r` is wholly in view in the panel: inside the part seen of every box of the panel's laid out round
/// it (a scroller's, the panel's own), so nothing over its foot or past a scroller's edge hides any of it.
fn wholly_in_view(t : @ui.Tester, r : (Double, Double, Double, Double)) -> Bool raise {
  let (x, y, w, h) = r
  let (dx, _, dw, _) = t.get(@ui.Role::Dialog).rect
  t
  .boxes_held()
  .iter()
  .all(fn(b) {
    let holds = b.x >= dx - 0.5 && b.x + b.w <= dx + dw + 0.5 &&
      b.x <= x + 0.5 && x + w <= b.x + b.w + 0.5 && b.y <= y + 0.5 && y + h <= b.y + b.h + 0.5
    let (cx, cy, cw, ch) = b.cut
    !holds || (cx <= x + 0.5 && x + w <= cx + cw + 0.5 && cy <= y + 0.5 && y + h <= cy + ch + 0.5)
  })
}

///|
test "wide, crowded, the panel gone up from its control: the configuration used most wholly in view at its foot as it opens; pressed, all of it saved" {
  // (the panel is first built as one going down and found to stand above its control once laid out: the row nearest
  // the hand was brought into view for the other order and left a row past the scroller's foot, under the panel's)
  let calls = []
  let t = model_pop_calls("newchat-crowded-model", calls)
  t.run_for(@ui.move_most_ms)
  let first = t.get(Button, label="GPT-6 Astra · 中").rect
  let foot = t.get(Button, label="DeepSeek Harness").rect
  assert_true(wholly_in_view(t, first), msg="\{Repr(first)}")
  assert_true(first.1 + first.3 <= foot.1, msg="\{Repr(first)} over the foot's \{Repr(foot)}")
  t.click(Button, label="GPT-6 Astra · 中")
  t.run_for(@motion.presence_in_ms)
  let saves = calls.filter(fn(c) { c.0 == "pick.save" })
  assert_eq(saves.length(), 1, msg="\{Repr(saves)}")
  let p = Some(saves[0].1)
  assert_eq((text(p, "model"), text(p, "runtime"), text(p, "effort")), ("gpt-6-astra", "codex", "medium"))
  assert_eq((field(p, "fast"), field(p, "context")), (Some(Json::null()), Some(Json::null())))
}

///|
/// Whether a row's rect `r` holds a model's star (喜欢 …) beside it.
fn starred_beside(t : @ui.Tester, r : (Double, Double, Double, Double)) -> Bool {
  t.all(Button, has="喜欢").iter().any(fn(s) { s.rect.1 >= r.1 - 1.0 && s.rect.1 + s.rect.3 <= r.1 + r.3 + 1.0 })
}

///|
/// The words `name` drawn in the rect `r`.
fn words_in(t : @ui.Tester, r : (Double, Double, Double, Double), name : String) -> @ui.Laid? {
  t.boxes_held().rev().iter().find_first(fn(b) { b.kind == "text" && b.text == name && b.x >= r.0 && b.x < r.0 + r.2 && b.y >= r.1 && b.y < r.1 + r.3 })
}

///|
test "a long frequent configuration gives the model name room first" {
  let how = "Runner · Highest · Standard (extended speed unavailable)"
  for (w, h, scale, name, one_line) in [
    (1280.0, 800.0, 1.0, "Example Model 7", true),
    (390.0, 844.0, 1.0, "Example Model 7", true),
    (390.0, 844.0, 1.3, "Example Model 7", true),
    (320.0, 700.0, 1.0, "Example Model With A Very Long Name", false),
  ] {
    let label = name + " · " + how
    let base = fixture_app("newchat-model")
    let src : Source = {
      ..base,
      topic_read: fn(topic, params) {
        @settings.fixture_followed()
        let snap = base.topic(topic, params).get().snapshot()
        if topic != "pick" { return snap }
        match snap.value {
          Some(Object(o)) => {
            let m = o.copy()
            m["combos"] = [{
              "model": "gpt-6", "runtime": "codex", "effort": "high",
              "name": Json::string(name), "text": Json::string(how), "selected": false,
            }]
            { ..snap, value: Some(Json::object(m)) }
          }
          _ => snap
        }
      },
    }
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform=0)
    t.set_font_scale(scale)
    t.run_for(squeeze_opening)
    let row = t.get(Button, label~).rect
    let words = words_in(t, row, name).unwrap()
    assert_true(words.x + words.w <= row.0 + row.2, msg="the model name stays in the combination row")
    if one_line {
      assert_eq(t.lines_of(name), [name], msg="\{w} at \{scale}: the configuration must give the model name room first")
    }
    assert_true(t.query(Button, label="从常用搭配移除 " + label) is Some(_))
    t.click(Button, label~)
    t.run_for(@motion.presence_in_ms)
    assert_eq(new_fix.model, "gpt-6")
  }
}

///|
test "wide, few models: the configurations used most under 常用搭配, one model run two ways twice, a starred one's there and among the starred, none starred itself; the models over them, each its star" {
  // (what is used most is a configuration, apart from what is starred: the user, 2026-11-10, 「收藏跟常用不一样」
  // 「常用包括了思考深度和速度还有上下文长度」「是一种配置」)
  let held = page_faults("newchat")
  let calls = []
  let t = model_pop_calls("newchat-model", calls, liked=["claude-sonnet-5"])
  let head = t.find("常用搭配").unwrap()
  let combos = ["Opus 5.5 · 高", "GPT-6 · 中", "Opus 5.5 · 高 · 300K", "Sonnet 5 · 低"].map(fn(l) raise { (l, t.get(Button, label=l).rect) })
  let models = ["Opus 5.5", "GPT-6", "Sonnet 5"].map(fn(l) raise { (l, t.get(Button, label=l).rect) })
  let effort = t.get(Radio, label="高").rect
  // (three models: no way to all of them a step further)
  assert_true(t.query(Button, label="全部模型") is None)
  for c in combos {
    // under their name, nearest what opened the panel (its foot: it opens up from the composer); no star
    assert_true(c.1.1 > head.1, msg="\{Repr(c)} under 常用搭配 at \{Repr(head)}")
    assert_true(!starred_beside(t, c.1), msg="\{c.0} has a star")
  }
  // (the most used nearest what opened it)
  assert_true(combos[0].1.1 > combos[1].1.1 && combos[1].1.1 > combos[2].1.1, msg="\{Repr(combos)}")
  for m in models {
    assert_true(m.1.1 < head.1, msg="\{Repr(m)} over 常用搭配 at \{Repr(head)}")
    assert_true(starred_beside(t, m.1), msg="\{m.0} has no star")
    assert_true(effort.0 >= m.1.0 + m.1.2, msg="\{Repr(m)} \{Repr(effort)}")
  }
  // the starred one both among the starred and under 常用搭配, its star lit
  assert_true(t.query(Button, label="喜欢 Sonnet 5") is Some(_))
  // the one it runs on exactly drawn picked, the same model run another way not
  let (on, off) = (combos[0].1, combos[2].1)
  let weight = fn(r) { words_in(t, r, "Opus 5.5").map(fn(b) { b.weight }).unwrap_or(0) }
  assert_true(weight(on) > weight(off), msg="\{weight(on)} \{weight(off)}")
  // how it runs in its capsule after its name
  assert_true(words_in(t, off, "高 · 300K") is Some(_), msg="Opus 5.5's 高 · 300K")
  // pressed: all of it made what it runs on in one save, the panel closed
  t.click(Button, label="Opus 5.5 · 高 · 300K")
  t.run_for(@motion.presence_in_ms)
  assert_true(t.query(@ui.Role::Dialog) is None, msg="its panel closed")
  let saves = calls.filter(fn(c) { c.0 == "pick.save" })
  assert_eq(saves.length(), 1, msg="\{Repr(saves)}")
  let p = Some(saves[0].1)
  assert_eq((text(p, "model"), text(p, "runtime"), text(p, "effort")), ("claude-opus-5-5", "claude", "high"))
  assert_eq(field(p, "fast"), Some(Json::null()))
  assert_eq(field(p, "context"), Some(Json::number(300000.0)))
  assert_eq((new_fix.model, new_fix.runtime, new_fix.effort, new_fix.context), ("claude-opus-5-5", "claude", "high", "300000"))
  assert_eq(t.audit().filter(fn(f) { !held.contains(f) }), [])
}

///|
test "wide, few models: each configuration used most has what takes it out where a star would be; pressed, that one is taken out and leaves the panel, the next used most in its place, the panel open, the rest there; all taken out, 常用搭配 gone with them" {
  // (the user, 2026-11-10: 「常用模型应该是一种特定配置，并且可以删掉，跟模型没有关系」; 2026-11-13: 「删掉常用模型，只有 x
  // 会消失，然后关掉重新打开才能刷新」)
  let held = page_faults("newchat")
  let calls = []
  let t = model_pop_calls("newchat-model", calls, liked=["claude-sonnet-5"])
  let combos = ["Opus 5.5 · 高", "GPT-6 · 中", "Opus 5.5 · 高 · 300K", "Sonnet 5 · 低"]
  let rects = combos.map(fn(l) raise { t.get(Button, label=l).rect })
  for i, l in combos {
    let forget = t.get(Button, label="从常用搭配移除 " + l).rect
    assert_true(!starred_beside(t, rects[i]), msg="\{l} has a star")
    assert_true(
      forget.1 >= rects[i].1 - 1.0 && forget.1 + forget.3 <= rects[i].1 + rects[i].3 + 1.0 && forget.0 >= rects[i].0 + rects[i].2,
      msg="\{l}: \{Repr(forget)} beside \{Repr(rects[i])}",
    )
  }
  assert_eq(t.audit().filter(fn(f) { !held.contains(f) }), [])
  t.click(Button, label="从常用搭配移除 GPT-6 · 中")
  t.run_for(@ui.move_most_ms)
  let forgets = calls.filter(fn(c) { c.0 == "pick.forget" })
  assert_eq(forgets.length(), 1, msg="\{Repr(forgets)}")
  let p = Some(forgets[0].1)
  assert_eq((text(p, "model"), text(p, "runtime"), text(p, "effort")), ("gpt-6", "codex", "medium"))
  assert_eq((field(p, "fast"), field(p, "context")), (Some(Json::null()), Some(Json::null())))
  assert_true(t.query(@ui.Role::Dialog) is Some(_), msg="the panel closed")
  // (taken out: gone from the panel, its words too, the next used most come in its place, the rest there)
  assert_true(t.query(Button, label="从常用搭配移除 GPT-6 · 中") is None && t.query(Button, label="GPT-6 · 中") is None)
  assert_true(t.query(Button, label="GPT-6 · 高") is Some(_), msg="none in its place")
  for i, l in combos {
    if i != 1 {
      assert_true(t.query(Button, label=l) is Some(_), msg="\{l} gone")
    }
  }
  assert_true(t.query(Button, label="喜欢 Sonnet 5") is Some(_))
  assert_eq(t.audit().filter(fn(f) { !held.contains(f) }), [])
  // the rest taken out: no configuration, nor their name, the panel still open; the starred and the rest there
  for l in ["Opus 5.5 · 高", "Opus 5.5 · 高 · 300K", "Sonnet 5 · 低", "GPT-6 · 高"] {
    t.click(Button, label="从常用搭配移除 " + l)
    t.run_for(@ui.move_most_ms)
  }
  assert_true(t.query(@ui.Role::Dialog) is Some(_), msg="the panel closed")
  assert_true(t.find("常用搭配") is None, msg="常用搭配 with none under it")
  for l in [..combos, "GPT-6 · 高"] {
    assert_true(t.query(Button, label=l) is None, msg="\{l} still there")
  }
  assert_true(t.query(Button, label="Sonnet 5") is Some(_) && t.query(Button, label="喜欢 Sonnet 5") is Some(_))
}

///|
test "wide, few models: the configuration it runs on pressed sends nothing; another, its model, runtime and how hard it thinks" {
  let held = page_faults("newchat")
  let calls = []
  let t = model_pop_calls("newchat-model", calls)
  t.click(Button, label="Opus 5.5 · 高")
  t.run_for(@motion.presence_in_ms)
  assert_true(t.query(@ui.Role::Dialog) is None, msg="its panel closed")
  assert_eq(calls.filter(fn(c) { c.0 == "pick.save" }).length(), 0, msg="\{Repr(calls)}")
  let t = model_pop_calls("newchat-model", calls)
  t.click(Button, label="GPT-6 · 中")
  t.run_for(@motion.presence_in_ms)
  assert_eq((new_fix.model, new_fix.runtime, new_fix.effort, new_fix.context), ("gpt-6", "codex", "medium", ""))
  let p = Some(calls.filter(fn(c) { c.0 == "pick.save" })[0].1)
  assert_eq(field(p, "context"), Some(Json::null()))
  assert_eq(t.audit().filter(fn(f) { !held.contains(f) }), [])
}

///|
test "wide, many models: those used most, the way to all of them; there, a maker's models; every row's star beside it starred or not at a press, the panel open, the row where it was" {
  let t = model_pop("newchat-providers-model")
  assert_true(t.query(Button, label="Sonnet 5") is None, msg="neither used most nor starred: a step further")
  t.click(Button, label="全部模型")
  t.run_for(@motion.presence_in_ms)
  // the makers beside a maker's models
  assert_true(t.query(Button, label="Anthropic") is Some(_) && t.query(Button, label="OpenAI") is Some(_))
  t.click(Button, label="Anthropic")
  t.run_for(@motion.presence_in_ms)
  assert_true(t.query(Button, label="Opus 5.5") is Some(_) && t.query(Button, label="Gemini 3 Pro") is None, msg="Anthropic's alone")
  // its star pressed: starred (the same star on every row of the panel, in place of a box before a maker's models;
  // the user, 2026-11-10, of a ticked box read as the model picked)
  t.click(Button, label="喜欢 Sonnet 5")
  t.run_for(@motion.presence_in_ms)
  assert_eq(new_fix.liked, ["claude-sonnet-5"])
  assert_true(t.query(@ui.Role::Dialog) is Some(_), msg="the panel stays open")
  // back: Sonnet among the starred, over the configurations used most (none of them starred: a configuration is not)
  t.click(Button, label="全部模型")
  t.run_for(@ui.move_most_ms)
  let (sonnet, used) = (t.get(Button, label="Sonnet 5").rect.1, t.find("常用搭配").unwrap().1)
  assert_true(sonnet < used, msg="\{sonnet} \{used}")
  // its star pressed there: starred no more, its row where it was while the panel is open
  t.click(Button, label="喜欢 Sonnet 5")
  t.run_for(@motion.presence_in_ms)
  assert_eq(new_fix.liked, [])
  assert_eq(t.get(Button, label="Sonnet 5").rect.1, sonnet, msg="its row gone from under the hand")
}

///|
test "wide, models of many makers: each a row of its own in the list of them, none cut short" {
  let t = model_pop("newchat-providers-model")
  t.click(Button, label="全部模型")
  t.run_for(@motion.presence_in_ms)
  for k in ["Anthropic", "OpenAI", "DeepSeek", "Google"] {
    assert_true(t.query(Button, label=k) is Some(_), msg=k)
  }
  t.click(Button, label="Google")
  t.run_for(@motion.presence_in_ms)
  assert_true(t.query(Button, label="Gemini 3 Pro") is Some(_) && t.query(Button, label="Opus 5.5") is None)
  assert_eq(t.squeeze_faults(), [])
}

///|
test "wide, all models: the open panel makes room for a model and how it runs on one line" {
  let t = model_pop("newchat-providers-model", font_scale=1.5)
  t.click(Button, label="全部模型")
  t.run_for(@ui.move_most_ms)
  t.click(Button, label="OpenAI")
  t.run_for(@ui.move_most_ms)
  let panel = t.get(@ui.Role::Dialog).rect
  let model = t.get(Button, label="GPT-6 Astra").rect
  let name = words_whole(t, "GPT-6 Astra", model)
  let runtime = words_whole(t, "Codex · 中 · Ultrafast · 1.1M", model)
  assert_true(name is Some(n) && runtime is Some(r) && (n.1 - r.1).abs() < 4.0, msg="\{Repr((model, name, runtime))}")
  assert_true(panel.0 >= 0.0 && panel.0 + panel.2 <= 1280.0 && panel.2 < 960.0, msg="\{Repr(panel)}")
}

///|
test "wide, many models and Codex's efforts and speeds: the models, how hard it thinks and how fast in the right column, the runtime at the foot" {
  let t = model_pop("newchat-tall-model")
  let (px, py, pw, ph) = t.get(@ui.Role::Dialog).rect
  let all = t.get(Button, label="SWE-2").rect
  // how hard it thinks, its levels one under another at the panel's right, beside the models (2026-11-02 用户「思考深度
  // 放在整个面板的右边」「模型跟思考深度的并排的」)
  let levels = ["最低", "低", "中", "高", "很高", "最高", "Ultra"].map(fn(l) raise { t.get(Radio, label=l).rect })
  for i, r in levels {
    assert_true(r.0 == levels[0].0 && r.0 >= all.0 + all.2, msg="\{Repr(levels)}, beside \{Repr(all)}")
    assert_true(i == 0 || r.1 > levels[i - 1].1, msg="\{Repr(levels)}")
    assert_true(r.0 + r.2 <= px + pw && r.1 + r.3 <= py + ph, msg="\{Repr(r)} past the panel")
  }
  // speed sits directly under effort in the right column (1-click radio rows, no 跟随订阅), runtime stays in the foot
  let runtime = t.get(Button, label="DeepSeek Harness").rect
  let standard = t.get(Radio, label="标准").rect
  let fast = t.get(Radio, label="Fast").rect
  assert_true(standard.0 == levels[0].0 && fast.0 == standard.0, msg="\{Repr(standard)} \{Repr(fast)} beside \{Repr(levels[0])}")
  assert_true(standard.1 > levels[levels.length() - 1].1 + levels[levels.length() - 1].3, msg="\{Repr(standard)}")
  assert_true(fast.1 > standard.1 && fast.1 + fast.3 <= runtime.1, msg="\{Repr(fast)} above foot \{Repr(runtime)}")
  assert_true(t.words().iter().all(fn(w) { w.0 != "跟随订阅" }), msg="跟随订阅 said")
  t.click(Radio, label="Fast")
  t.run_for(squeeze_opening)
  assert_eq(t.get(Radio, label="Fast").check, Some(On))
}

///|
test "wide: how hard it thinks picked in the panel is made what it runs on at once, the panel open as wide as it opened" {
  let t = model_pop("newchat-crowded-model")
  let opened = t.get(@ui.Role::Dialog).rect
  for (label, effort) in [("低", "low"), ("最高", "max")] {
    t.click(Radio, label~)
    t.run_for(squeeze_opening)
    assert_eq(new_fix.effort, effort)
    let now = t.get(@ui.Role::Dialog).rect
    assert_true(now.0 == opened.0 && now.2 == opened.2, msg="\{label} picked: \{Repr(now)}, opened \{Repr(opened)}")
  }
}

///|
test "wide: how much context sits in the right column under effort; one click applies it at once" {
  let t = model_pop("newchat-model")
  let (px, py, pw, ph) = t.get(@ui.Role::Dialog).rect
  let high = t.get(Radio, label="高").rect
  let context = t.get(Radio, label="完整 · 1M").rect
  assert_true(context.0 == high.0 && context.1 > high.1 + high.3 && context.1 + context.3 <= py + ph && context.0 + context.2 <= px + pw, msg="\{Repr(context)}, effort \{Repr(high)}, the panel \{Repr((px, py, pw, ph))}")
  assert_true(t.words().iter().any(fn(w) { w.0 == "上下文" }), msg="no name before it")
  let steps = ["完整 · 1M", "500K", "300K", "200K"].map(fn(l) raise { (l, t.get(Radio, label=l).check) })
  assert_eq(steps, [("完整 · 1M", Some(On)), ("500K", Some(Off)), ("300K", Some(Off)), ("200K", Some(Off))])
  t.click(Radio, label="300K")
  t.run_for(squeeze_opening)
  assert_eq(new_fix.context, "300000")
  assert_eq(t.get(Radio, label="300K").check, Some(On))
  assert_eq(t.get(Radio, label="完整 · 1M").check, Some(Off))
}

///|
test "wide: Devin's sidekick at the foot opens a secondary model-by-effort panel; picking a sidekick model and effort saves at once" {
  let base = fixture_app("newchat-model")
  let src : Source = {
    ..base,
    topic_read: fn(name, params) {
      @settings.fixture_followed()
      let snap = base.topic(name, params).get().snapshot()
      if name == "pick" {
        match snap.value {
          Some(Object(o)) => {
            let m = o.copy()
            m["sidekicks"] = [
              { "id": "", "text": "无", "model": "claude-opus-5-5" },
              { "id": "swe-2-medium", "text": "SWE-2 · 中", "model": "fusion-claude-opus-5-5-sidekick-swe-2-medium", "maker": { "id": "devin", "name": "Cognition" } },
              { "id": "swe-2-high", "text": "SWE-2 · 高", "model": "fusion-claude-opus-5-5-sidekick-swe-2-high", "maker": { "id": "devin", "name": "Cognition" } },
            ]
            m["sidekickNow"] = Json::string(
              if new_fix.model == "fusion-claude-opus-5-5-sidekick-swe-2-medium" {
                "swe-2-medium"
              } else if new_fix.model == "fusion-claude-opus-5-5-sidekick-swe-2-high" {
                "swe-2-high"
              } else {
                ""
              },
            )
            { ..snap, value: Some(Json::object(m)) }
          }
          _ => snap
        }
      } else {
        snap
      }
    },
  }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(squeeze_opening)
  let (px, py, pw, ph) = t.get(@ui.Role::Dialog).rect
  let high = t.get(Radio, label="高").rect
  let sidekick = t.get(Button, label="无").rect
  assert_true(sidekick.1 > high.1 + high.3 && sidekick.1 + sidekick.3 <= py + ph && sidekick.0 + sidekick.2 <= px + pw, msg="\{Repr(sidekick)}, the panel \{Repr((px, py, pw, ph))}")
  assert_true(t.words().iter().any(fn(w) { w.0 == "副模型" }), msg="no name before it")
  t.click(Button, label="无")
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Button, label="副模型") is Some(_))
  assert_true(t.query(Button, label="SWE-2") is Some(_))
  t.click(Button, label="SWE-2")
  t.run_for(squeeze_opening)
  assert_eq((new_fix.model, new_fix.runtime), ("fusion-claude-opus-5-5-sidekick-swe-2-medium", "devin"))
  assert_eq(t.get(Radio, label="中").check, Some(On))
  assert_eq(t.get(Radio, label="高").check, Some(Off))
  t.click(Radio, label="高")
  t.run_for(squeeze_opening)
  assert_eq((new_fix.model, new_fix.runtime), ("fusion-claude-opus-5-5-sidekick-swe-2-high", "devin"))
  assert_eq(t.get(Radio, label="高").check, Some(On))
  t.click(Button, label="副模型")
  t.run_for(squeeze_opening)
  assert_true(t.query(Button, label="SWE-2 · 高") is Some(_), msg="the foot says the updated sidekick effort")
}
///|
test "the model control says its speed on small and large screens with larger words" {
  for win in [corner_windows[0], corner_windows[5]] {
    for scale in [1.0, 1.3] {
      let bare = fn(f : String) { f.split(" (at ").collect()[0].to_owned() }
      let standard = screen_in("newchat-speed-standard", win, "zh", font_scale=scale)
      let held = standard.audit().map(bare)
      assert_eq(standard.locate("icon:zap-fast").length() + standard.locate("icon:zap-ultrafast").length(), 0)
      for (mode, speed, icon) in [("newchat-speed-fast", "Fast", "zap-fast"), ("newchat-speed-ultrafast", "Ultrafast", "zap-ultrafast")] {
        let t = screen_in(mode, win, "zh", font_scale=scale)
        let buttons = t.semantics().filter(fn(s) { s.role is Button })
        guard buttons.filter(fn(b) { b.label.has_prefix("GPT-6.2 Sol") }) is [chip, ..] else {
          fail("no model control among \{buttons.map(fn(b) { b.label }).join(", ")}")
        }
        assert_true(chip.label.contains(speed), msg="\{win.0} at \{scale}: \{chip.label}")
        let marks = t.locate("icon:" + icon)
        assert_eq(marks.length(), 1, msg="\{win.0} at \{scale}: \{t.sources_of("GPT-6.2 Sol")}")
        let (x, y) = marks[0]
        let (bx, by, bw, bh) = chip.rect
        assert_true(x >= bx && x <= bx + bw && y >= by && y <= by + bh, msg=t.sources_at(x, y))
        assert_eq(t.audit().map(bare).filter(fn(f) { !held.contains(f) }), [], msg="\{win.0} at \{scale}: \{t.audit().join("\n")}")
      }
    }
  }
}

///|
test "Ultrafast can be selected and cleared on small and large screens with larger words" {
  for win in [corner_windows[0], corner_windows[5]] {
    for scale in [1.0, 1.3] {
      let t = screen_in("newchat-ultrafast-model", win, "zh", font_scale=scale)
      // (what is wrong already, wherever it is drawn: what opening the speeds moves keeps its fault)
      let bare = fn(f : String) { f.split(" (at ").collect()[0].to_owned() }
      let held = t.audit().map(bare)
      let phone = win.0 == "phone"
      if phone {
        t.click(Button, label="标准")
        t.run_for(squeeze_opening)
        assert_true(t.words().iter().any(fn(w) { w.0 == "Ultrafast" }))
        assert_eq(t.audit().map(bare).filter(fn(f) { !held.contains(f) }), [])
        t.click(Button, label="Ultrafast " + @sf.t("web-main.model.ultrafastNote"))
        t.run_for(squeeze_opening)
        assert_eq(new_fix.speed, "ultrafast")
        t.click(Button, label="Ultrafast")
        t.run_for(squeeze_opening)
        t.click(Button, label="标准")
        t.run_for(squeeze_opening)
        assert_eq(new_fix.speed, "standard")
      } else {
        assert_eq(t.get(Radio, label="标准").check, Some(On))
        assert_eq(t.get(Radio, label="Ultrafast").check, Some(Off))
        t.click(Radio, label="Ultrafast")
        t.run_for(squeeze_opening)
        assert_eq(new_fix.speed, "ultrafast")
        assert_eq(t.get(Radio, label="Ultrafast").check, Some(On))
        t.click(Radio, label="标准")
        t.run_for(squeeze_opening)
        assert_eq(new_fix.speed, "standard")
        assert_eq(t.get(Radio, label="标准").check, Some(On))
      }
      assert_eq(t.audit().map(bare).filter(fn(f) { !held.contains(f) }), [])
    }
  }
}

///|
test "Claude run mode can be changed in the model settings on small and large screens" {
  for win in [corner_windows[0], corner_windows[5]] {
    let t = screen_in("newchat-tui-model", win, "zh")
    let item : @view.Role = if win.0 == "phone" { Button } else { MenuItemRadio }
    for mode in ["TUI", "Print"] {
      t.click(Button, label=if mode == "TUI" { "Print" } else { "TUI" })
      t.run_for(squeeze_opening)
      t.click(item, label=mode)
      t.run_for(squeeze_opening)
      assert_eq(new_fix.tui, Some(mode == "TUI"))
    }
    let checkbox : @view.Role = if win.0 == "phone" { Button } else { MenuItemCheckbox }
    for enabled in [true, false] {
      t.click(Button, label="Print")
      t.run_for(squeeze_opening)
      if win.0 != "phone" {
        assert_eq(t.get(checkbox, label="新对话默认使用 TUI").check, Some(if enabled { Off } else { On }))
      }
      t.click(checkbox, label="新对话默认使用 TUI")
      t.run_for(squeeze_opening)
      assert_eq(new_fix.default_tui, enabled)
    }
  }
}

///|
test "a model row's usualText and a frequent combination's configuration share their name's baseline" {
  for scale in [1.0, 1.3] {
    let flat = model_pop("newchat-model", font_scale=scale)
    let flat_runs = flat.text_runs()
    // (opening upward puts the flat model list above 常用搭配: the first GPT-6 is the model row, the last its combo row)
    let gpt = flat_runs.filter(fn(r) { r.text == "GPT-6" })[0]
    let gpt_usual = flat_runs.filter(fn(r) { r.x0 > gpt.x1 && (r.top - gpt.top).abs() < 10.0 && r.text == "中" })
    assert_true(!gpt_usual.is_empty(), msg="missing usualText beside GPT-6 at scale \{scale}: \{Repr(flat_runs)}")
    assert_true(
      (gpt.base - gpt_usual[0].base).abs() < 0.01,
      msg="GPT-6 baseline \{gpt.base} vs \{gpt_usual[0].text} baseline \{gpt_usual[0].base} at scale \{scale}",
    )
    let combo = flat_runs.filter(fn(r) { r.text == "GPT-6" }).last().unwrap()
    let combo_how = flat_runs.filter(fn(r) { r.x0 > combo.x1 && (r.top - combo.top).abs() < 10.0 && r.text != "" })
    assert_true(!combo_how.is_empty(), msg="missing configuration beside the GPT-6 combination at scale \{scale}: \{Repr(flat_runs)}")
    assert_true(
      (combo.base - combo_how[0].base).abs() < 0.01,
      msg="GPT-6 combination baseline \{combo.base} vs \{combo_how[0].text} baseline \{combo_how[0].base} at scale \{scale}",
    )

    let t = model_pop("newchat-providers-model", font_scale=scale)
    t.click(Button, label="全部模型")
    t.run_for(squeeze_opening)
    t.click(Button, label="OpenAI")
    t.run_for(squeeze_opening)
    let runs = t.text_runs()
    let astra = runs.filter(fn(r) { r.text == "GPT-6 Astra" }).last().unwrap()
    let usual = runs.filter(fn(r) { r.x0 > astra.x1 && (r.top - astra.top).abs() < 10.0 && r.text.contains("Codex") })
    assert_true(!usual.is_empty(), msg="missing usualText beside GPT-6 Astra at scale \{scale}: \{Repr(runs)}")
    assert_true(
      (astra.base - usual[0].base).abs() < 0.01,
      msg="GPT-6 Astra baseline \{astra.base} vs \{usual[0].text} baseline \{usual[0].base} at scale \{scale}",
    )
  }
}

///|
test "wide, first level: when a frequent combination is selected, no duplicate current model row appears above 常用搭配" {
  let t = model_pop("newchat-providers-model")
  assert_true(t.query(Button, label="DeepSeek V4.1 Flash · DSH · 高") is Some(_))
  assert_true(t.query(Button, label="DeepSeek V4.1 Flash") is None, msg="current model duplicated above 常用搭配")
  // natural height: panel stays compact instead of stretching to a fixed 360pt list void
  let (_, _, _, ph) = t.get(@ui.Role::Dialog).rect
  assert_true(ph < 380.0, msg="panel stretched with empty void: \{ph}")
}

///|
test "wide, search: matches maker and runtime tokens, Escape clears before closing, and arrows plus Enter pick a model" {
  let t = model_pop("newchat-providers-model")
  t.click(TextField, label="搜索模型")
  t.run_for(squeeze_opening)
  // multi-token search across maker and runtime
  t.type_text("openai codex")
  t.run_for(squeeze_opening)
  assert_true(t.query(Button, label="GPT-6 Astra") is Some(_), msg="maker + runtime search finds GPT-6 Astra")
  assert_true(t.query(Button, label="Opus 5.5") is None)
  // Escape with query clears text and keeps the panel open
  t.key(@ui.key_escape)
  t.run_for(squeeze_opening)
  assert_true(t.query(@ui.Role::Dialog) is Some(_), msg="Escape cleared query instead of closing panel")
  assert_true(t.query(Button, label="全部模型") is Some(_), msg="returned to first level after clearing query")
  // search OpenAI (2 models: GPT-6 Astra, gpt-oss 2), step down to second result, Enter picks it and closes
  t.type_text("openai")
  t.run_for(squeeze_opening)
  assert_true(t.query(Button, label="GPT-6 Astra") is Some(_) && t.query(Button, label="gpt-oss 2") is Some(_))
  t.key(@ui.key_code_down)
  t.run_for(squeeze_opening)
  t.key(@ui.key_code_enter)
  t.run_for(@motion.presence_in_ms)
  assert_true(t.query(@ui.Role::Dialog) is None, msg="Enter closed the panel after picking")
  assert_eq(new_fix.model, "gpt-oss-2")
}

///|
test "wide, keys and mouse: the model's panel opened over the focused composer has 搜索模型 focused, typed into at once with no press; a model picked, the focus back in the composer" {
  let t = model_pop("newchat-providers")
  let focus = fn() { t.focused().map(fn(s) { "\{s.role} \{s.label}" }).unwrap_or("none") }
  // (the composer pressed: it has the keys)
  let composer = t.semantics().filter(fn(s) { s.role is TextField })[0]
  let (x, y, w, h) = composer.rect
  t.tap(x + w / 2.0, y + h / 2.0)
  t.run_for(squeeze_opening)
  let had = focus()
  assert_true(had.has_prefix("TextField "), msg="the composer's before: \{had}")
  // (the model's control pressed: its panel beside it, 搜索模型 focused, nothing more pressed)
  let buttons = t.semantics().filter(fn(s) { s.role is Button }).map(fn(s) { s.label })
  guard t.semantics().filter(fn(s) { s.role is Button && s.label.has_prefix("DeepSeek V4.1 Flash · ") }) is [chip, ..] else {
    fail("no model control among \{buttons.join(", ")}")
  }
  let (x, y, w, h) = chip.rect
  t.tap(x + w / 2.0, y + h / 2.0)
  t.run_for(squeeze_opening)
  assert_true(t.query(@ui.Role::Dialog) is Some(_), msg="the model's panel open")
  assert_eq(focus(), "TextField 搜索模型")
  t.type_text("openai codex")
  t.run_for(squeeze_opening)
  assert_true(t.query(Button, label="GPT-6 Astra") is Some(_), msg="typed at once: GPT-6 Astra found")
  assert_true(t.query(Button, label="Opus 5.5") is None, msg="typed at once: Opus 5.5 filtered out")
  assert_eq(t.get(TextField, label="搜索模型").value, "openai codex")
  // (Escape clears what was typed, the panel open; Enter on a model found picks it, the panel gone, the focus back where
  // it was and nothing typed the composer's)
  t.key(@ui.key_escape)
  t.run_for(squeeze_opening)
  assert_true(t.query(@ui.Role::Dialog) is Some(_), msg="Escape cleared the search, the panel open")
  assert_eq(t.get(TextField, label="搜索模型").value, "")
  t.type_text("openai")
  t.run_for(squeeze_opening)
  t.key(@ui.key_code_enter)
  t.run_for(@motion.presence_in_ms)
  assert_true(t.query(@ui.Role::Dialog) is None, msg="Enter picked a model and closed the panel")
  assert_eq(focus(), had)
  assert_eq(t.semantics().filter(fn(s) { s.role is TextField })[0].value, "", msg="nothing typed went to the composer")
}

///|
/// The panel's lines (`A(Line, O60)`, a hairline thick) drawn inside its dialog: those across (h) and those down (v), and the
/// dialog's rect.
fn panel_lines(
  t : @ui.Tester,
) -> (
  Array[(Double, Double, Double, Double)],
  Array[(Double, Double, Double, Double)],
  (Double, Double, Double, Double),
) raise {
  let (px, py, pw, ph) = t.get(@ui.Role::Dialog).rect
  let line = @ui.alpha(@sf.theme().p.line, 0.6)
  let inside = t
    .drawn_rects()
    .filter(fn(r) {
      r.4 >> 8 == line >> 8 && ((r.4 & 0xFFL) - (line & 0xFFL)).abs() <= 1L && r.0 >= px - 0.5 && r.0 + r.2 <= px + pw + 0.5 && r.1 >= py - 0.5 && r.1 + r.3 <= py + ph + 0.5
    })
    .map(fn(r) { (r.0, r.1, r.2, r.3) })
  let h = inside.filter(fn(r) { (r.3 - 0.5).abs() < 0.01 && r.2 > 2.0 })
  let v = inside.filter(fn(r) { (r.2 - 0.5).abs() < 0.01 && r.3 > 2.0 })
  (h, v, (px, py, pw, ph))
}

///|
fn near(a : Double, b : Double) -> Bool {
  (a - b).abs() < 0.05
}

///|
/// Every line of the panel's first level ends on another line or on the panel's edge: the foot's across it, the one
/// between the models and how they run from the top to the foot's, the one over 全部模型 from the left edge to that one,
/// those between how it runs from that one to the right edge; none crossing another (each a hairline of `Line`, which is
/// faded, seen through: two over each other drawn darker where they meet).
fn first_level_lines_meet(t : @ui.Tester, what : String) -> Unit raise {
  let (h, v, (px, py, pw, _)) = panel_lines(t)
  let msg = "\{what}: across \{Repr(h)}, down \{Repr(v)}, panel \{Repr((px, py, pw))}"
  assert_eq(v.length(), 1, msg~)
  let rv = v[0]
  let foot = h.fold(init=h[0], fn(a, r) { if r.1 > a.1 { r } else { a } })
  assert_true(near(foot.0, px) && near(foot.0 + foot.2, px + pw), msg="the foot's line across the panel: \{msg}")
  assert_true(near(rv.1, py) && near(rv.1 + rv.3, foot.1), msg="the line down from the top to the foot's: \{msg}")
  for r in h {
    if r == foot {
      continue
    }
    if r.0 < rv.0 {
      // (over 全部模型: from the panel's left edge to the line down, not over it)
      assert_true(near(r.0, px) && near(r.0 + r.2, rv.0), msg="a line left of the one down: \{Repr(r)} \{msg}")
    } else {
      // (between how it runs: from the line down, not over it, to the panel's right edge)
      assert_true(near(r.0, rv.0 + rv.2) && near(r.0 + r.2, px + pw), msg="a line right of the one down: \{Repr(r)} \{msg}")
    }
  }
}

///|
/// The level of all models, browsing a maker: the line under ‹ 全部模型 from the left edge to the line down between
/// the models and how they run; the one between the makers and their models from that line's foot to the panel foot's.
fn all_level_lines_meet(t : @ui.Tester, what : String) -> Unit raise {
  let (h, v, (px, py, pw, _)) = panel_lines(t)
  let msg = "\{what}: across \{Repr(h)}, down \{Repr(v)}, panel \{Repr((px, py, pw))}"
  assert_eq(v.length(), 2, msg~)
  let (mv, rv) = if v[0].0 < v[1].0 { (v[0], v[1]) } else { (v[1], v[0]) }
  let foot = h.fold(init=h[0], fn(a, r) { if r.1 > a.1 { r } else { a } })
  assert_true(near(foot.0, px) && near(foot.0 + foot.2, px + pw), msg="the foot's line across the panel: \{msg}")
  assert_true(near(rv.1, py) && near(rv.1 + rv.3, foot.1), msg="the line down from the top to the foot's: \{msg}")
  let back = h.filter(fn(r) { r != foot && r.0 < rv.0 })
  assert_eq(back.length(), 1, msg="one line under ‹ 全部模型: \{msg}")
  let b = back[0]
  assert_true(near(b.0, px) && near(b.0 + b.2, rv.0), msg="the line under ‹ 全部模型 to the line down: \{msg}")
  assert_true(
    near(mv.1, b.1 + b.3) && near(mv.1 + mv.3, foot.1),
    msg="the line between makers and models from that line to the foot's: \{msg}",
  )
  for r in h {
    if r != foot && r.0 >= rv.0 {
      assert_true(near(r.0, rv.0 + rv.2) && near(r.0 + r.2, px + pw), msg="a line right of the one down: \{Repr(r)} \{msg}")
    }
  }
}

///|
test "wide: the model panel's lines meet each other and its edges, at its first level and at all models, none over another" {
  let wide = corner_windows[5]
  for lang in ["zh", "en"] {
    for scale in [1.0, 1.3] {
      let bare = fn(f : String) { f.split(" (at ").collect()[0].to_owned() }
      let held = screen_in("newchat", wide, lang, font_scale=scale).audit().map(bare)
      let new_faults = fn(t : @ui.Tester, what : String) raise {
        assert_eq(t.audit().map(bare).filter(fn(f) { !held.contains(f) }), [], msg="\{what}: \{t.audit().join("\n")}")
      }
      for mode in ["newchat-tall-model", "newchat-providers-model", "newchat-model"] {
        let t = screen_in(mode, wide, lang, font_scale=scale)
        t.run_for(@ui.move_most_ms)
        let what = "\{mode} \{lang} \{scale}"
        first_level_lines_meet(t, what)
        new_faults(t, what)
      }
      let t = screen_in("newchat-providers-model", wide, lang, font_scale=scale)
      t.click(Button, label=@sf.t("web-main.model.allModels"))
      t.run_for(@ui.move_most_ms)
      for maker in ["DeepSeek", "Anthropic"] {
        t.click(Button, label=maker)
        t.run_for(@ui.move_most_ms)
        let what = "all models, \{maker} \{lang} \{scale}"
        all_level_lines_meet(t, what)
        new_faults(t, what)
      }
    }
  }
}

///|
test "small: in the model sheet the line over 全部模型 runs as far as the sheet foot's line, side to side" {
  for lang in ["zh", "en"] {
    for scale in [1.0, 1.3] {
      let t = screen_in("newchat-providers-model", corner_windows[0], lang, font_scale=scale)
      t.run_for(@ui.move_most_ms)
      let (h, _, _) = panel_lines(t)
      let to_all = t.get(Button, label=@sf.t("web-main.model.allModels")).rect
      let foot = h.fold(init=h[0], fn(a, r) { if r.1 > a.1 { r } else { a } })
      let over = h.filter(fn(r) { r.1 + r.3 <= to_all.1 + 0.5 })
      let msg = "\{lang} \{scale}: across \{Repr(h)}, 全部模型 \{Repr(to_all)}"
      assert_true(!over.is_empty() && foot.1 > to_all.1, msg~)
      let line = over.fold(init=over[0], fn(a, r) { if r.1 > a.1 { r } else { a } })
      assert_true(near(line.0, foot.0) && near(line.0 + line.2, foot.0 + foot.2), msg="the line over 全部模型 and the foot's: \{msg}")
    }
  }
}

///|
test "wide: when otherStations scope and search both appear, search sits on the same row to the right of scope with zero new audit faults" {
  let t = model_pop("newchat-station-models-many")
  let seg0 = t.get(Radio, label="本机").rect
  let seg1 = t.get(Radio, label="所有 station").rect
  let search = t.get(TextField, label="搜索模型").rect
  assert_true(
    (search.1 + search.3 / 2.0 - (seg0.1 + seg0.3 / 2.0)).abs() < 2.0,
    msg="search (\{Repr(search)}) must sit on the same row as scope (\{Repr(seg0)})",
  )
  assert_true(
    search.0 >= seg1.0 + seg1.2,
    msg="search (\{Repr(search)}) must sit to the right of scope (\{Repr(seg1)})",
  )
  // Also verify in "全部模型" wide view
  t.click(Button, label=@sf.t("web-main.model.allModels"))
  t.run_for(@ui.move_most_ms)
  let seg0_all = t.get(Radio, label="本机").rect
  let seg1_all = t.get(Radio, label="所有 station").rect
  let search_all = t.get(TextField, label="搜索模型").rect
  assert_true(
    (search_all.1 + search_all.3 / 2.0 - (seg0_all.1 + seg0_all.3 / 2.0)).abs() < 2.0 &&
    search_all.0 >= seg1_all.0 + seg1_all.2,
    msg="allModels: search (\{Repr(search_all)}) must sit on the same row right of scope (\{Repr(seg0_all)}, \{Repr(seg1_all)})",
  )
  // Sweep 7 windows x zh/en x 1.0/1.3 font scales for zero new audit faults.
  for win in corner_windows {
    for lang in ["zh", "en"] {
      for scale in [1.0, 1.3] {
        let bare = fn(f : String) { f.split(" (at ").collect()[0].to_owned() }
        let held = screen_in("newchat", win, lang, font_scale=scale).audit().map(bare)
        let tw = screen_in("newchat-station-models-many", win, lang, font_scale=scale)
        assert_eq(
          tw.audit().map(bare).filter(fn(f) { !held.contains(f) }),
          [],
          msg="newchat-station-models-many \{win.0}-\{lang} \{scale}: \{tw.audit().join("\n")}",
        )
      }
    }
  }
}

///|
test "wide: otherStations scope reverts checked radio and resting capsule when pick.set fails" {
  let base = fixture_app("newchat-station-models-many")
  let reply : Ref[((Result[Json, Json]) -> Unit)?] = Ref(None)
  let src : Source = {
    ..base,
    call: fn(name, params, done) {
      if name == "pick.set" {
        reply.val = Some(done)
      } else {
        (base.call)(name, params, done)
      }
    },
  }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(squeeze_opening)
  let seg0 = t.get(Radio, label="本机").rect
  let seg1 = t.get(Radio, label="所有 station").rect
  assert_eq(t.get(Radio, label="本机").check, Some(@ui.Check::On))
  // Click "所有 station" while pick.set is in flight: optimistically switches without waiting.
  t.click(Radio, label="所有 station")
  t.run_for(@ui.move_most_ms / 2.0)
  assert_true(reply.val is Some(_), msg="expected pick.set call to be captured")
  assert_eq(t.get(Radio, label="所有 station").check, Some(@ui.Check::On))
  // Simulate async pick.set failure with otherStations topic unchanged (false): must revert cleanly.
  match reply.val {
    Some(done) => done(Err(Json::string("network failed")))
    None => fail("missing pick.set callback")
  }
  t.run_for(@ui.move_most_ms * 2.0)
  assert_eq(t.get(Radio, label="本机").check, Some(@ui.Check::On), msg="failed pick.set must revert checked radio to 本机")
  assert_eq(t.get(Radio, label="所有 station").check, Some(@ui.Check::Off))
  let lifted = @ui.tree_theme().lifted
  let thumbs = t
    .drawn_rects()
    .filter(fn(d) {
      d.4 == lifted &&
      (d.3 - seg0.3).abs() < 2.0 &&
      d.1 >= seg0.1 - 4.0 &&
      d.1 <= seg0.1 + seg0.3 &&
      d.0 >= seg0.0 - 4.0 &&
      d.0 + d.2 <= seg1.0 + seg1.2 + 4.0
    })
  assert_eq(thumbs.length(), 1, msg="expected 1 resting scope capsule after rollback")
  let tcx = thumbs[0].0 + thumbs[0].2 / 2.0
  let r0cx = seg0.0 + seg0.2 / 2.0
  assert_true((tcx - r0cx).abs() < 1.0, msg="rolled-back capsule center \{tcx} must align with 本机 radio center \{r0cx}")
}

///|
test "wide: rapid scope clicks (0 -> 1 -> 0) stay steady on 本机 when stale A topic arrives and pass through external updates after B settles" {
  let base = fixture_app("newchat-station-models-many")
  let queue : Array[(Json, (Result[Json, Json]) -> Unit)] = []
  let src : Source = {
    ..base,
    call: fn(name, params, done) {
      if name == "pick.set" && params is Object(m) && m.contains("otherStations") {
        queue.push((params, done))
      } else {
        (base.call)(name, params, done)
      }
    },
  }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(squeeze_opening)
  let seg0 = t.get(Radio, label="本机").rect
  let seg1 = t.get(Radio, label="所有 station").rect
  let lifted = @ui.tree_theme().lifted
  let scope_thumbs = fn() {
    t
    .drawn_rects()
    .filter(fn(d) {
      d.4 == lifted &&
      (d.3 - seg0.3).abs() < 2.0 &&
      d.1 >= seg0.1 - 4.0 &&
      d.1 <= seg0.1 + seg0.3 &&
      d.0 >= seg0.0 - 4.0 &&
      d.0 + d.2 <= seg1.0 + seg1.2 + 4.0
    })
  }
  let r0cx = seg0.0 + seg0.2 / 2.0
  let r1cx = seg1.0 + seg1.2 / 2.0
  // Rapidly click 所有 station (A) then 本机 (B) before either settles.
  t.click(Radio, label="所有 station")
  t.frame()
  t.click(Radio, label="本机")
  t.run_for(@ui.move_most_ms)
  assert_eq(queue.length(), 2, msg="expected 2 queued pick.set calls (A and B)")
  assert_eq(t.get(Radio, label="本机").check, Some(@ui.Check::On))
  // Stale A topic (otherStations=true) + A Ok arrives while B is still in flight:
  // must NOT clear pending=Some(0) or jump back to 所有 station.
  let jumped : Array[String] = []
  t.each_frame(
    Some(fn() {
      for d in scope_thumbs() {
        let cx = d.0 + d.2 / 2.0
        if cx > seg0.0 + seg0.2 {
          jumped.push("t=\{t.time()} cx=\{cx} > seg0.right=\{seg0.0 + seg0.2}")
        }
      }
    }),
  )
  (base.call)("pick.set", queue[0].0, queue[0].1)
  t.run_for(@ui.move_most_ms)
  t.each_frame(None)
  assert_eq(t.get(Radio, label="本机").check, Some(@ui.Check::On), msg="stale A must not flip radio to 所有 station")
  assert_true(jumped.is_empty(), msg="stale A must not bounce capsule toward 所有 station: \{jumped.join("; ")}")
  let thumbs_mid = scope_thumbs()
  assert_eq(thumbs_mid.length(), 1)
  assert_true((thumbs_mid[0].0 + thumbs_mid[0].2 / 2.0 - r0cx).abs() < 1.0)
  // Deliver B Ok + otherStations=false topic -> stays on 本机 and clears pending.
  (base.call)("pick.set", queue[1].0, queue[1].1)
  t.run_for(@ui.move_most_ms)
  assert_eq(t.get(Radio, label="本机").check, Some(@ui.Check::On))
  // Prove pending was cleanly cleared: an external otherStations=true push now switches to 所有 station.
  (base.call)("pick.set", queue[0].0, fn(_) {  })
  t.run_for(@ui.move_most_ms)
  assert_eq(t.get(Radio, label="所有 station").check, Some(@ui.Check::On), msg="external push after settle must pass through")
  let thumbs_ext = scope_thumbs()
  assert_eq(thumbs_ext.length(), 1)
  assert_true((thumbs_ext[0].0 + thumbs_ext[0].2 / 2.0 - r1cx).abs() < 1.0)
}

///|
test "wide: rapid scope clicks (0 -> 1 -> 0) revert to confirmed 所有 station when A succeeds and B fails" {
  let base = fixture_app("newchat-station-models-many")
  let queue : Array[(Json, (Result[Json, Json]) -> Unit)] = []
  let src : Source = {
    ..base,
    call: fn(name, params, done) {
      if name == "pick.set" && params is Object(m) && m.contains("otherStations") {
        queue.push((params, done))
      } else {
        (base.call)(name, params, done)
      }
    },
  }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(squeeze_opening)
  let seg0 = t.get(Radio, label="本机").rect
  let seg1 = t.get(Radio, label="所有 station").rect
  // Rapidly click 所有 station (A) then 本机 (B).
  t.click(Radio, label="所有 station")
  t.frame()
  t.click(Radio, label="本机")
  t.run_for(@ui.move_most_ms / 2.0)
  assert_eq(queue.length(), 2, msg="expected 2 queued pick.set calls (A and B)")
  // A succeeds and updates server topic to otherStations=true.
  (base.call)("pick.set", queue[0].0, queue[0].1)
  t.run_for(@ui.move_most_ms / 2.0)
  assert_eq(t.get(Radio, label="本机").check, Some(@ui.Check::On))
  // B fails -> pending clears and UI reverts to server-confirmed 所有 station.
  (queue[1].1)(Err(Json::string("B failed")))
  t.run_for(@ui.move_most_ms * 2.0)
  assert_eq(t.get(Radio, label="所有 station").check, Some(@ui.Check::On), msg="failed B must revert to confirmed 所有 station")
  assert_eq(t.get(Radio, label="本机").check, Some(@ui.Check::Off))
  let lifted = @ui.tree_theme().lifted
  let thumbs = t
    .drawn_rects()
    .filter(fn(d) {
      d.4 == lifted &&
      (d.3 - seg1.3).abs() < 2.0 &&
      d.1 >= seg0.1 - 4.0 &&
      d.1 <= seg0.1 + seg0.3 &&
      d.0 >= seg0.0 - 4.0 &&
      d.0 + d.2 <= seg1.0 + seg1.2 + 4.0
    })
  assert_eq(thumbs.length(), 1, msg="expected 1 resting scope capsule after B rollback")
  let tcx = thumbs[0].0 + thumbs[0].2 / 2.0
  let r1cx = seg1.0 + seg1.2 / 2.0
  assert_true((tcx - r1cx).abs() < 1.0, msg="capsule center \{tcx} must align with confirmed 所有 station (\{r1cx})")
}

///|
test "wide: synchronous read-only pick.set rejection keeps scope radio and resting capsule aligned on 本机 (mouse & finger)" {
  for plat in [0, 2] {
    let base = fixture_app("newchat-station-models-many")
    let rejected = Ref(0)
    let src : Source = {
      ..base,
      call: fn(name, params, done) {
        if name == "pick.set" && params is Object(m) && m.contains("otherStations") {
          rejected.val += 1
          done(Err(Json::string("read-only")))
        } else {
          (base.call)(name, params, done)
        }
      },
    }
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=plat)
    t.run_for(squeeze_opening)
    let seg0 = t.get(Radio, label="本机").rect
    let seg1 = t.get(Radio, label="所有 station").rect
    let c1x = seg1.0 + seg1.2 / 2.0
    let c1y = seg1.1 + seg1.3 / 2.0
    if plat == 0 {
      t.click(Radio, label="所有 station")
    } else {
      t.touch(0, c1x, c1y)
      t.touch(2, c1x, c1y)
    }
    t.run_for(@ui.move_most_ms * 2.0)
    assert_eq(rejected.val, 1, msg="plat=\{plat}: expected synchronous pick.set rejection")
    assert_eq(t.get(Radio, label="本机").check, Some(@ui.Check::On), msg="plat=\{plat}: 本机 must remain checked")
    assert_eq(t.get(Radio, label="所有 station").check, Some(@ui.Check::Off))
    let lifted = @ui.tree_theme().lifted
    let thumbs = t
      .drawn_rects()
      .filter(fn(d) {
        d.4 == lifted &&
        (d.3 - seg0.3).abs() < 2.0 &&
        d.1 >= seg0.1 - 4.0 &&
        d.1 <= seg0.1 + seg0.3 &&
        d.0 >= seg0.0 - 4.0 &&
        d.0 + d.2 <= seg1.0 + seg1.2 + 4.0
      })
    assert_eq(thumbs.length(), 1, msg="plat=\{plat}: expected 1 resting scope capsule after sync rejection")
    let tcx = thumbs[0].0 + thumbs[0].2 / 2.0
    let r0cx = seg0.0 + seg0.2 / 2.0
    assert_true((tcx - r0cx).abs() < 1.0, msg="plat=\{plat}: capsule center \{tcx} must stay on 本机 (\{r0cx})")
  }
}
