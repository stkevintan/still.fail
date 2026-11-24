// Performance invariants for profiles 概览:
// - charts use native kind 0 rects + kind 10 lines + RDP-simplified kind 11 fills (keeping kind 11/12 instances low);
// - flattened single by_room keeps layout passes bounded;
// - switching 账号 <-> 概览 keeps both panes parked via View::each(keeps=...), so waking 概览 makes/frees 0 nodes.

///|
fn ov_perf_inst_counts(t : @ui.Tester) -> (Int, Int, Int, Int, Int) {
  let insts = t.drawn_instances()
  let mut k0 = 0
  let mut k10 = 0
  let mut k11 = 0
  let mut k12 = 0
  for ins in insts {
    if ins[5] == 0.0 {
      k0 += 1
    } else if ins[5] == 10.0 {
      k10 += 1
    } else if ins[5] == 11.0 {
      k11 += 1
    } else if ins[5] == 12.0 {
      k12 += 1
    }
  }
  (insts.length(), k0, k10, k11, k12)
}

///|
fn ov_perf_max_passes(since? : Int = 0) -> (Int, Int) {
  let mut max_passes = 0
  let mut max_laid = 0
  let j = @ui.journal()
  for i in since..<j.length() {
    match j[i] {
      Work({ what: Frame(f), .. }) => {
        if f.passes > max_passes {
          max_passes = f.passes
        }
        if f.laid > max_laid {
          max_laid = f.laid
        }
      }
      _ => ()
    }
  }
  (max_passes, max_laid)
}

///|
fn ov_perf_audit_clean(t : @ui.Tester, at : String, check_tree_room? : Bool = true) -> Unit raise {
  assert_eq(t.unasked_faults(), [], msg="\{at} unasked")
  assert_eq(t.room_faults(), [], msg="\{at} room")
  if check_tree_room {
    assert_eq(t.tree_room_faults(), [], msg="\{at} tree_room")
  }
  assert_eq(t.squeeze_faults(), [], msg="\{at} squeeze")
  assert_eq(t.gap_faults(), [], msg="\{at} gap")
  assert_eq(t.corner_faults(), [], msg="\{at} corner")
  assert_eq(t.height_faults(), [], msg="\{at} height")
  assert_eq(t.first_line_faults(), [], msg="\{at} first_line")
  assert_eq(t.line_start_faults(), [], msg="\{at} line_start")
  assert_eq(t.unseen_press_faults(), [], msg="\{at} unseen_press")
  assert_eq(t.fixed_outgrown(), [], msg="\{at} fixed_outgrown")
  assert_eq(t.contrast_faults(), [], msg="\{at} contrast")
}

///|
test "profiles overview perf: bounded kind 11/12 instances and layout passes on phone and wide" {
  // 1. Phone overview
  new_run()
  let src_phone = fixture_app("place-profiles-sum-overview")
  let t_phone = @ui.Tester::new(fn(c) { view(c, src_phone) }, tree=app_tree(src_phone), w=390.0, h=844.0, platform=2)
  t_phone.run_for(@ui.move_most_ms)
  assert_true(t_phone.find("额度与恢复") is Some(_))
  assert_true(t_phone.find("消耗速度") is Some(_))
  let (p_total, p_k0, p_k10, p_k11, p_k12) = ov_perf_inst_counts(t_phone)
  let (p_passes, p_laid) = ov_perf_max_passes()
  println(
    "ov_perf phone: total=\{p_total} k0=\{p_k0} k10=\{p_k10} k11=\{p_k11} k12=\{p_k12} max_passes=\{p_passes} max_laid=\{p_laid}",
  )
  assert_true(p_k11 <= 120, msg="phone kind 11 too high: \{p_k11}")
  assert_true(p_k12 <= 160, msg="phone kind 12 too high: \{p_k12}")
  assert_true(p_passes <= 2, msg="phone max layout passes too high: \{p_passes}")
  ov_perf_audit_clean(t_phone, "phone")

  // 2. Wide overview
  let t_wide = wide_tester([], mode="place-profiles-sum-a")
  @settings.fixture_page("settings-profiles-sum-a") |> ignore
  let wide_since = @ui.journal().length()
  app.nav.replace(Place("profiles"))
  t_wide.run_for(@ui.move_most_ms)
  assert_true(t_wide.find("额度与恢复") is Some(_))
  assert_true(t_wide.find("消耗速度") is Some(_))
  let (w_total, w_k0, w_k10, w_k11, w_k12) = ov_perf_inst_counts(t_wide)
  let (w_passes, w_laid) = ov_perf_max_passes(since=wide_since)
  println(
    "ov_perf wide: total=\{w_total} k0=\{w_k0} k10=\{w_k10} k11=\{w_k11} k12=\{w_k12} max_passes=\{w_passes} max_laid=\{w_laid}",
  )
  assert_true(w_k11 <= 160, msg="wide kind 11 too high: \{w_k11}")
  assert_true(w_k12 <= 420, msg="wide kind 12 too high: \{w_k12}")
  assert_true(w_passes <= 2, msg="wide max layout passes too high: \{w_passes}")
  ov_perf_audit_clean(t_wide, "wide", check_tree_room=false)
}

///|
test "profiles overview perf: second switch 账号 -> 概览 wakes kept pane with made == 0 and let_go == 0" {
  new_run()
  let src = fixture_app("place-profiles-sum-a")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("Claude 主账号") is Some(_))
  assert_true(t.find("额度与恢复") is None)
  // First switch to 概览 builds the overview pane
  t.tap_text("概览")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("额度与恢复") is Some(_))
  // Switch back to 账号 parks the overview pane
  t.tap_text("账号")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("额度与恢复") is None)
  assert_true(t.find("Claude 主账号") is Some(_))
  // Second switch to 概览 wakes the parked pane without making or freeing nodes
  t.tree_frames_from_now()
  t.tap_text("概览")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("额度与恢复") is Some(_))
  let mut made = 0
  let mut let_go = 0
  for f in t.tree_frames() {
    made += f.made
    let_go += f.let_go
  }
  println("ov_perf second switch to overview: made=\{made} let_go=\{let_go}")
  assert_eq(made, 0)
  assert_eq(let_go, 0)
  ov_perf_audit_clean(t, "phone-second-switch")
}

///|
fn ov_perf_frame_totals(since : Int) -> (Int, Int, Int, Int) {
  let mut made = 0
  let mut let_go = 0
  let mut laid = 0
  let mut measured = 0
  let j = @ui.journal()
  for i in since..<j.length() {
    match j[i] {
      Work({ what: Frame(f), .. }) => {
        made += f.made
        let_go += f.let_go
        laid += f.laid
        measured += f.measured
      }
      _ => ()
    }
  }
  (made, let_go, laid, measured)
}

///|
test "profiles place perf: wide overview <-> account wakes parked panes with made == 0, let_go == 0 and zero leaks" {
  let t = wide_tester([], mode="place-profiles-sum-a")
  @settings.fixture_page("settings-profiles-sum-a") |> ignore
  app.nav.replace(Place("profiles"))
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("额度与恢复") is Some(_))

  // First visit to account A builds its pane and parks 概览
  t.tap_text("Claude 主账号")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("额度与恢复") is None)
  assert_eq(t.unasked_faults(), [])

  // Second visit to 概览 wakes parked overview pane with 0 made / 0 let_go
  t.tree_frames_from_now()
  t.tap_text("概览")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("额度与恢复") is Some(_))
  let mut ov_made = 0
  let mut ov_let_go = 0
  for f in t.tree_frames() {
    ov_made += f.made
    ov_let_go += f.let_go
  }
  println("wide place-profiles wake overview: made=\{ov_made} let_go=\{ov_let_go}")
  assert_eq(ov_made, 0)
  assert_eq(ov_let_go, 0)
  ov_perf_audit_clean(t, "wide-wake-overview", check_tree_room=false)

  // Second visit to account A wakes parked account pane with 0 made / 0 let_go and releases ahead-reads cleanly
  t.tree_frames_from_now()
  t.tap_text("Claude 主账号")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("额度与恢复") is None)
  let mut acc_made = 0
  let mut acc_let_go = 0
  for f in t.tree_frames() {
    acc_made += f.made
    acc_let_go += f.let_go
  }
  println("wide place-profiles wake account A: made=\{acc_made} let_go=\{acc_let_go}")
  assert_eq(acc_made, 0)
  assert_eq(acc_let_go, 0)
  ov_perf_audit_clean(t, "wide-wake-account", check_tree_room=false)
}

///|
test "profiles place perf: wide LRU keeps at most 4 recent accounts while keeping 概览 parked" {
  let t = wide_tester([], mode="place-profiles-sum-a")
  @settings.fixture_page("settings-profiles-sum-a") |> ignore
  app.nav.replace(Place("profiles"))
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("额度与恢复") is Some(_))

  // Open 4 distinct accounts: all 4 fit in the LRU alongside 概览
  for name in ["Claude 主账号", "afkdev1@proton.me", "afkdev2@proton.me", "cuesurf4@proton.me"] {
    t.tap_text(name)
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("额度与恢复") is None, msg="opened \{name}")
  }

  // Opening a 5th account evicts the oldest ("Claude 主账号")
  t.tree_frames_from_now()
  t.tap_text("cuesurf2@proton.me")
  t.run_for(@ui.move_most_ms)
  let mut fifth_let_go = 0
  for f in t.tree_frames() {
    fifth_let_go += f.let_go
  }
  println("wide place-profiles 5th account eviction: let_go=\{fifth_let_go}")
  assert_true(fifth_let_go > 0, msg="5th account should evict oldest parked account")

  // 概览 is still permanently parked (made == 0, let_go == 0)
  t.tree_frames_from_now()
  t.tap_text("概览")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("额度与恢复") is Some(_))
  let mut ov_made = 0
  let mut ov_let_go = 0
  for f in t.tree_frames() {
    ov_made += f.made
    ov_let_go += f.let_go
  }
  assert_eq(ov_made, 0, msg="概览 must remain parked after LRU eviction")
  assert_eq(ov_let_go, 0, msg="概览 must not evict on wake")

  // 2nd account ("afkdev1@proton.me") is still in the 4-account LRU (made == 0, let_go == 0)
  t.tree_frames_from_now()
  t.tap_text("afkdev1@proton.me")
  t.run_for(@ui.move_most_ms)
  let mut recent_made = 0
  let mut recent_let_go = 0
  for f in t.tree_frames() {
    recent_made += f.made
    recent_let_go += f.let_go
  }
  assert_eq(recent_made, 0, msg="recent account in LRU should wake with made == 0")
  assert_eq(recent_let_go, 0, msg="recent account in LRU should wake with let_go == 0")

  // Evicted oldest account ("Claude 主账号") must rebuild when revisited (made > 0)
  t.tree_frames_from_now()
  t.tap_text("Claude 主账号")
  t.run_for(@ui.move_most_ms)
  let mut evicted_made = 0
  for f in t.tree_frames() {
    evicted_made += f.made
  }
  assert_true(evicted_made > 0, msg="evicted oldest account should rebuild when revisited")
  assert_eq(t.unasked_faults(), [])
}

///|
test "profiles side widths: unrelated profile fields (usedCount / checkText) do not re-measure sidebar quota widths" {
  new_run()
  let bump : @signals.Signal[Int] = @signals.signal(0)
  let base = fixture("settings")
  let patch_non_quota = fn(v : Json, n : Int) -> Json {
    if n == 0 {
      return v
    }
    match v {
      Object(o) => {
        let copy = o.copy()
        if copy.get("items") is Some(Array(arr)) {
          let next = arr.map(fn(e) {
            match e {
              Object(eo) => {
                let ec = eo.copy()
                if ec.get("profile") is Some(Object(po)) && po.get("id") == Some(Json::string("cc")) {
                  let pc = po.copy()
                  pc["usedCount"] = Json::number((n + 10).to_double())
                  pc["checkText"] = Json::string("已检查 " + n.to_string())
                  ec["profile"] = Json::object(pc)
                }
                Json::object(ec)
              }
              _ => e
            }
          })
          copy["items"] = Json::array(next)
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
      let n = bump.get()
      if name == "profiles" {
        { ..r, value: r.value.map(fn(v) { patch_non_quota(v, n) }) }
      } else {
        r
      }
    },
  }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  app.nav.replace(Place("profiles"))
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("Claude 主账号") is Some(_))

  let since = @ui.journal().length()
  bump.set(1)
  t.draw()
  let (made, let_go, laid, measured) = ov_perf_frame_totals(since)
  println("profiles side widths non-quota update: made=\{made} let_go=\{let_go} laid=\{laid} measured=\{measured}")
  assert_eq(made, 0)
  assert_eq(let_go, 0)
  assert_eq(laid, 0)
  assert_eq(measured, 0)
}

///|
test "profiles: 多选 in the bar stays as 概览 shows, and pressed there shows the list with 多选 begun" {
  new_run()
  let src = fixture_app("place-profiles-sum-a")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t.run_for(@ui.move_most_ms)
  t.tap_text("概览")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("额度与恢复") is Some(_))
  t.click(Button, label="多选")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("额度与恢复") is None, msg="the list shown again")
  assert_true(t.find("已选 0 项") is Some(_), msg="多选 begun")
  // (概览 again: 多选 over)
  t.tap_text("概览")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("已选 0 项") is None)
}
