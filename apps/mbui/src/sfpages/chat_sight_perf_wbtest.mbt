// Regressions for Perf-41 Part 2:
// 1. `ChatBodyNow::index_of` & `last_index_of` snapshot isolation and duplicate-key semantics;
// 2. `chat_ask_shown` boundary cases (missing first, reversed last<first, first==last, missing last, multi-slice);
// 3. `page_shows_lent` zero-wakeup on same-range pixel scroll, off-screen margin false, head-delete+tail-insert,
//    swap, and tail-delete preserving off-screen false (Opus B2);
// 4. `chat_jump_node` bell fade-out & fade-in transition when `away == false` (sole capsule item, alpha in (0, 1)).

///|
let sight_step_ms : Double = 50.0

///|
let sight_bell_mid_ms : Double = float_ms / 2.0

///|
let sight_bell_end_ms : Double = float_ms + 200.0

///|
test "ChatBodyNow::index_of and last_index_of stay bound to their snapshot and preserve duplicate-key semantics" {
  let ks_sig : @signals.Signal[Array[String]] = @signals.signal(["a", "b", "b", "c", "b"])
  let rows_map : Map[String, ChatBodyRow] = Map([])
  let list = ChatBodyList::of_made(fn() { { keys: ks_sig.get(), rows: rows_map } })
  let snap1 = list.read()
  assert_eq(snap1.index_of("a"), Some(0))
  assert_eq(snap1.index_of("b"), Some(1))
  assert_eq(snap1.last_index_of("b"), Some(4))
  assert_eq(snap1.index_of("c"), Some(3))
  assert_eq(snap1.last_index_of("c"), Some(3))
  assert_eq(snap1.index_of("d"), None)
  assert_eq(snap1.last_index_of("d"), None)

  // Mutate underlying list keys to a brand new generation
  ks_sig.set(["d", "c", "a"])
  let snap2 = list.read()
  assert_eq(snap2.index_of("d"), Some(0))
  assert_eq(snap2.index_of("c"), Some(1))
  assert_eq(snap2.index_of("a"), Some(2))
  assert_eq(snap2.index_of("b"), None)
  assert_eq(snap2.last_index_of("b"), None)

  // Old snapshot must still resolve strictly against its own old keys
  assert_eq(snap1.index_of("a"), Some(0))
  assert_eq(snap1.index_of("b"), Some(1))
  assert_eq(snap1.last_index_of("b"), Some(4))
  assert_eq(snap1.index_of("c"), Some(3))
  assert_eq(snap1.index_of("d"), None)
}

///|
test "chat_ask_shown handles all range boundaries and multi-slice last message" {
  @sfbase.reset()
  reset()
  let chat_json = scale_chat(20)
  // Make message index 10 (seq 11, key m:t11) a multi-slice agent message
  guard chat_json is Object(o) && o.get("messages") is Some(Array(ms)) else { fail("no messages") }
  let ms = ms.copy()
  guard ms[10] is Object(m10) else { fail("no m10") }
  let m10 = m10.copy()
  m10["text"] = Json::string("第一段\n\n第二段\n\n第三段")
  m10["md"] = Json::array([body_para("第一段"), body_para("第二段"), body_para("第三段")])
  ms[10] = Json::object(m10)
  let base_cv = @sfbase.chat_view_made(keyed_with(chat_json, { "messages": Json::array(ms) }))
  let cv = { ..base_cv, asks: [11.0] }
  let made = chat_body_rows({ sent: {}, sent_as: {}, here: {} }, cv, @sfbase.entries_of(cv), [])
  let slices_11 = made.rows.get("m:t11").unwrap().slices
  assert_true(slices_11 >= 3, msg="expected >=3 slices, got \{slices_11}")
  let list = ChatBodyList::of_made(fn() { made })
  let jump = ChatJump::new()
  let ask_shown = chat_ask_shown(jump, fn() { cv }, list)

  // Before sight is set -> false
  assert_false(ask_shown())
  // Ask m:t11 NOT in sight -> bell shows
  jump.sight.set(Some(("m:t1", "m:t5", 0)))
  assert_true(ask_shown())
  // Ask m:t11 in interior of sight -> bell hides
  jump.sight.set(Some(("m:t10", "m:t14", 0)))
  assert_false(ask_shown())
  // Missing `first` -> empty seen -> bell shows
  jump.sight.set(Some(("m:missing", "m:t14", 0)))
  assert_true(ask_shown())
  // Reversed range (`last` appears before `first`, with ask m:t11 AFTER m:t10):
  // must skip scanning (otherwise scanning m:t10..end would hit m:t11 and wrongly hide the bell).
  jump.sight.set(Some(("m:t10", "m:t5", 0)))
  assert_true(ask_shown())
  // `first == last` on non-ask row -> bell shows
  jump.sight.set(Some(("m:t5", "m:t5", 0)))
  assert_true(ask_shown())
  // `first == last` on multi-slice ask row: penultimate slice -> bell shows; last slice -> bell hides
  jump.sight.set(Some(("m:t11", "m:t11", slices_11 - 2)))
  assert_true(ask_shown())
  jump.sight.set(Some(("m:t11", "m:t11", slices_11 - 1)))
  assert_false(ask_shown())
  // `last` missing (scans from `first` to end) -> m:t11 is after m:t10 -> bell hides
  jump.sight.set(Some(("m:t10", "m:missing", 0)))
  assert_false(ask_shown())
}

///|
test "chat_read_whole_seq uses last_index_of on duplicate keys with multi-slice tail (Astra R2 NB2)" {
  @sfbase.reset()
  reset()
  let chat_json = scale_chat(22)
  guard chat_json is Object(o) && o.get("messages") is Some(Array(ms)) else { fail("no messages") }
  let ms = ms.copy()
  guard ms[10] is Object(m10) else { fail("no m10") }
  let m10 = m10.copy()
  m10["text"] = Json::string("第一段\n\n第二段\n\n第三段")
  m10["md"] = Json::array([body_para("第一段"), body_para("第二段"), body_para("第三段")])
  ms[10] = Json::object(m10)
  let cv = @sfbase.chat_view_made(keyed_with(chat_json, { "messages": Json::array(ms) }))
  let made = chat_body_rows({ sent: {}, sent_as: {}, here: {} }, cv, @sfbase.entries_of(cv), [])
  let w = "m:t11"
  assert_true(made.rows.get(w).unwrap().slices >= 3)
  // Construct duplicate-key list: [msg10, w, msg20, w]; with w at slice 0 (< slices-1),
  // scanning backwards from the LAST occurrence of w must land on msg20 (seq 20), not msg10 (seq 10).
  let dup_rows : ChatBodyRows = { keys: ["m:t10", w, "m:t20", w], rows: made.rows }
  let list = ChatBodyList::of_made(fn() { dup_rows })
  let snap = list.read()
  assert_eq(chat_read_whole_seq(snap, w, 0), 20.0)
}

///|
test "sight_window stays Unresolved (false) when first page_shows_lent reader attaches after tail delete (Astra R2 B2)" {
  @sfbase.reset()
  reset()
  let base_json = scale_chat(40)
  let base_cv = @sfbase.chat_view_made(base_json)
  let view = @signals.signal(base_cv)
  let entries = @signals.signal(@sfbase.entries_of(base_cv))
  let place : @view.ListPlace[String] = @view.ListPlace::new()
  let src = @sffixture.fixture("chat")
  let mounted : Map[String, @view.View] = Map([])

  // Do NOT read page_shows_lent during initial mount/sight so sight_window has never been evaluated (was == None).
  let t = body_new(src, 390.0, 600.0, 2, view, entries, place~, made=fn(k, row) {
    if k != "top" {
      mounted[k] = row
    }
  })
  t.draw()
  t.run_for(sight_step_ms)

  let s_foot = place.sight_now().unwrap()
  let first_idx = base_cv.messages.search_by(fn(m) { "m:" + m.ts == s_foot.first }).unwrap()
  // Pick a mounted off-screen margin row strictly above s_foot.first
  let mut offscreen_k = ""
  for i in 0..<first_idx {
    let k = "m:" + base_cv.messages[i].ts
    if mounted.get(k) is Some(_) {
      offscreen_k = k
      break
    }
  }
  assert_true(offscreen_k != "", msg="expected a mounted off-screen row above s_foot.first")
  let off_row = mounted.get(offscreen_k).unwrap()
  let page_shows = off_row.lent(@sfbase.page_shows_lent).unwrap()

  // Delete s_foot.last BEFORE ever reading sight_window, then attach the first reader synchronously
  let ms_trimmed = base_cv.messages.copy()
  guard ms_trimmed.pop() is Some(popped) else { fail("empty messages") }
  assert_eq("m:" + popped.ts, s_foot.last)
  let trimmed_cv = { ..base_cv, messages: ms_trimmed }
  view.set(trimmed_cv)
  entries.set(@sfbase.entries_of(trimmed_cv))

  let flashed_true = Ref(false)
  let latest = Ref(true)
  off_row.reacts(fn() { page_shows() }, fn(on) {
    latest.val = on
    if on {
      flashed_true.val = true
    }
  })
  // Before next on_sight: must be Unresolved -> false, never flashing true
  assert_false(latest.val)
  assert_false(flashed_true.val)
  t.run_for(sight_step_ms)
  let s_trimmed = place.sight_now().unwrap()
  let new_first_idx = ms_trimmed.search_by(fn(m) { "m:" + m.ts == s_trimmed.first }).unwrap()
  match ms_trimmed.search_by(fn(m) { "m:" + m.ts == offscreen_k }) {
    Some(idx) if idx < new_first_idx => {
      assert_false(latest.val)
      assert_false(flashed_true.val)
    }
    _ => ()
  }
}

///|
test "page_shows_lent: zero wakeup on pixel scroll, off-screen false, swap, and tail-delete (Opus B2)" {
  @sfbase.reset()
  reset()
  let base_json = scale_chat(40)
  let base_cv = @sfbase.chat_view_made(base_json)
  let view = @signals.signal(base_cv)
  let entries = @signals.signal(@sfbase.entries_of(base_cv))
  let place : @view.ListPlace[String] = @view.ListPlace::new()
  let src = @sffixture.fixture("chat")
  let slot_keys : Map[@view.NodeId, Ref[String]] = Map([])
  let eval_counts : Map[String, Int] = Map([])
  let row_shown : Map[String, Bool] = Map([])
  let flashed_true : Map[String, Bool] = Map([])
  let record_flash = Ref(false)

  let t = body_new(src, 390.0, 600.0, 2, view, entries, place~, made=fn(k, row) {
    if k == "top" {
      return
    }
    let id = row.id()
    match slot_keys.get(id) {
      Some(rk) => rk.val = k
      None => {
        // Must have page_shows_lent explicitly lent by chat_body_node (no fallback)
        guard row.lent(@sfbase.page_shows_lent) is Some(page_shows) else {
          @halt.saying("page_shows_lent missing on chat row \{k}")
        }
        let rk = Ref(k)
        slot_keys[id] = rk
        row.reacts(
          fn() {
            let ck = rk.val
            eval_counts[ck] = eval_counts.get(ck).unwrap_or(0) + 1
            page_shows()
          },
          fn(on) {
            let ck = rk.val
            row_shown[ck] = on
            if on && record_flash.val {
              flashed_true[ck] = true
            }
          },
        )
      }
    }
  })
  t.draw()
  t.run_for(sight_step_ms)

  // 1) Opus B2 regression at foot: collect all mounted off-screen margin rows (`row_shown == Some(false)`),
  //    then delete `s_foot.last`. Synchronously on the key update (before the next layout's `on_sight`),
  //    NO off-screen row may flash `true`; after layout settles, any row still above `new_s.first` must
  //    remain `Some(false)` and never have flashed `true`.
  let s_foot = place.sight_now().unwrap()
  let offscreen_keys : Array[String] = []
  for m in base_cv.messages {
    let k = "m:" + m.ts
    if row_shown.get(k) == Some(false) {
      offscreen_keys.push(k)
    }
  }
  assert_true(!offscreen_keys.is_empty(), msg="expected at least one mounted off-screen margin row")
  record_flash.val = true
  let ms_trimmed = base_cv.messages.copy()
  guard ms_trimmed.pop() is Some(popped) else { fail("empty messages") }
  assert_eq("m:" + popped.ts, s_foot.last)
  let trimmed_cv = { ..base_cv, messages: ms_trimmed }
  view.set(trimmed_cv)
  entries.set(@sfbase.entries_of(trimmed_cv))
  // Transient window before next layout's on_sight: sight_window must keep `was`, not fall back to `None`
  for k in offscreen_keys {
    assert_false(flashed_true.get(k).unwrap_or(false), msg="off-screen row \{k} flashed true during tail delete before on_sight")
    assert_eq(row_shown.get(k), Some(false))
  }
  t.run_for(sight_step_ms)
  let s_trimmed = place.sight_now().unwrap()
  let new_first_idx = ms_trimmed.search_by(fn(m) { "m:" + m.ts == s_trimmed.first }).unwrap()
  for k in offscreen_keys {
    match ms_trimmed.search_by(fn(m) { "m:" + m.ts == k }) {
      Some(idx) if idx < new_first_idx => {
        assert_false(flashed_true.get(k).unwrap_or(false), msg="still-off-screen row \{k} flashed true")
        assert_eq(row_shown.get(k), Some(false))
      }
      _ => ()
    }
  }
  record_flash.val = false

  // Restore full 40 messages and scroll up into the middle
  view.set(base_cv)
  entries.set(@sfbase.entries_of(base_cv))
  t.run_for(sight_step_ms)
  t.wheel(195.0, 300.0, -200.0)
  t.run_for(sight_step_ms)
  let s_before = place.sight_now().unwrap()
  let total_before = eval_counts.values().fold(init=0, fn(acc, n) { acc + n })

  // 2) Small 2px scroll: verify scroll actually moved (`into` changed) AND caused ZERO page_shows_lent wakeups
  t.wheel(195.0, 300.0, -2.0)
  t.run_for(sight_step_ms)
  let s_after = place.sight_now().unwrap()
  assert_true((s_after.into - s_before.into).abs() > 0.1, msg="expected pixel scroll to move into")
  assert_eq((s_after.first, s_after.slice, s_after.last, s_after.last_slice), (s_before.first, s_before.slice, s_before.last, s_before.last_slice))
  let total_after = eval_counts.values().fold(init=0, fn(acc, n) { acc + n })
  assert_eq(total_after, total_before)

  // 3) Head-delete + tail-insert (keys generation changes) refreshes page_shows_lent
  let ms = base_cv.messages.copy()
  let removed = ms.remove(0)
  let last_seq = ms[ms.length() - 1].seq
  ms.push({ ..removed, seq: last_seq + 1.0, ts: "t-tail-new" })
  let shifted_cv = { ..base_cv, messages: ms }
  view.set(shifted_cv)
  entries.set(@sfbase.entries_of(shifted_cv))
  t.run_for(sight_step_ms)
  let s_shifted = place.sight_now().unwrap()
  assert_eq(row_shown.get(s_shifted.first), Some(true))
  assert_eq(row_shown.get(s_shifted.last), Some(true))

  // 4) Swap non-anchor in-view row (`s_shifted.last`) with an out-of-view row:
  //    swapped-in key becomes true; swapped-out key (if still mounted in margin) becomes false.
  let ms2 = shifted_cv.messages.copy()
  let in_idx = ms2.search_by(fn(m) { "m:" + m.ts == s_shifted.last }).unwrap()
  let out_idx = if in_idx > 2 { 0 } else { ms2.length() - 1 }
  let swapped_out_key = "m:" + ms2[in_idx].ts
  let swapped_in_key = "m:" + ms2[out_idx].ts
  let tmp = ms2[in_idx]
  ms2[in_idx] = ms2[out_idx]
  ms2[out_idx] = tmp
  let swapped_cv = { ..shifted_cv, messages: ms2 }
  view.set(swapped_cv)
  entries.set(@sfbase.entries_of(swapped_cv))
  t.run_for(sight_step_ms)
  assert_eq(row_shown.get(swapped_in_key), Some(true))
  match row_shown.get(swapped_out_key) {
    Some(on) => assert_false(on)
    None => ()
  }
}

///|
/// Find the drawn opacity of a control at `rect = (x, y, w, h)` in `tree`.
fn bell_drawn_alpha(tree : @view.Tree, rect : (Double, Double, Double, Double)) -> Double? {
  let (rx, ry, rw, rh) = rect
  let cx = rx + rw / 2.0
  let cy = ry + rh / 2.0
  let found : Ref[Double?] = Ref(None)
  tree.each_drawn(fn(d, x, y, alpha) {
    if cx >= x - 1.0 && cx <= x + d.w + 1.0 && cy >= y - 1.0 && cy <= y + d.h + 1.0 && d.w <= rw + 16.0 && d.h <= rh + 16.0 {
      found.val = Some(alpha)
    }
  })
  found.val
}

///|
test "chat_jump_node bell fades smoothly via @view.transition when away is false (sole capsule item)" {
  @sfbase.reset()
  reset()
  let base_json = scale_chat(40)
  let base_cv = @sfbase.chat_view_made(base_json)
  // Find which message is just above the viewport at foot so a tiny scroll (< to_newest_away = 120px) toggles ask_shown
  // while keeping `away == false` (so the ask bell is the SOLE item in the floating capsule).
  let probe_place : @view.ListPlace[String] = @view.ListPlace::new()
  let probe_t = body_new(@sffixture.fixture("chat"), 390.0, 600.0, 2, @signals.signal(base_cv), @signals.signal(@sfbase.entries_of(base_cv)), place=probe_place)
  probe_t.draw()
  probe_t.run_for(sight_step_ms)
  let foot_first = probe_place.sight_now().unwrap().first
  let foot_first_idx = base_cv.messages.search_by(fn(m) { "m:" + m.ts == foot_first }).unwrap()
  // Pick the message 1 row above `foot_first`: hidden at foot, enters sight after ~40-60px scroll up (still away == false!)
  let ask_seq = base_cv.messages[foot_first_idx - 1].seq
  let ask_key = "m:" + base_cv.messages[foot_first_idx - 1].ts

  let cv = { ..base_cv, asks: [ask_seq] }
  let view = @signals.signal(cv)
  let entries = @signals.signal(@sfbase.entries_of(cv))
  let place : @view.ListPlace[String] = @view.ListPlace::new()
  let src = @sffixture.fixture("chat")

  @sf.set_words(@sfbase.fill)
  absolute_times.set(false)
  let t = @ui.Tester::new(
    fn(c) {
      @sf.begin(c) |> ignore
      c.with_theme(@sf.ui_theme(), fn() { @ui.old_views_here(c) })
    },
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      let tips = @sf.TipLayer::new(fn() { Some(root) })
      let here : MessageNodeHere = {
        station: body_ref.station,
        session: body_ref.session,
        view: fn() { view.get() },
        width: fn() { 390.0 },
        tips,
        stint: fn() { 0 },
        jump: None,
        picture: None,
      }
      root.box(fn(f) {
        f.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        chat_body_node(
          f,
          src,
          here,
          fn() { entries.get() },
          sending=fn() { [] },
          core=Some(@sfbase.settings_core(src, body_ws)),
          foot=fn() { body_foot(view.get()) },
          place~,
          to=body_ref,
        )
        |> ignore
      })
      |> ignore
      @sf.presented_nodes(root)
    },
    w=390.0,
    h=600.0,
    platform=2,
    scale=2.0,
  )
  t.set_rows_on_pixels(true)
  t.draw()
  t.run_for(sight_step_ms)

  let tree = @ui.view_tree().unwrap()
  let bell_label = @sf.t("web-main.chat.asks.go")
  let bell_rect = t.semantics().iter().find_first(fn(s) { s.role == @ui.Role::Button && s.label == bell_label }).unwrap().rect
  // At foot: away == false, ask_key is just above sight -> bell is visible at full opacity
  let s0 = place.sight_now().unwrap()
  assert_true(s0.at_foot || s0.from_foot <= to_newest_away)
  assert_eq(bell_drawn_alpha(tree, bell_rect), Some(1.0))

  // 1) Scroll up slightly (keep from_foot <= to_newest_away so away stays false!) until ask_key enters sight:
  //    bell must fade OUT smoothly (alpha strictly in (0, 1) at +float_ms/2, gone after float_ms).
  let mut entered = false
  for _ in 0..<12 {
    t.wheel(195.0, 300.0, -10.0)
    match place.sight_now() {
      Some(s) if s.first == ask_key => {
        entered = true
        break
      }
      _ => ()
    }
  }
  assert_true(entered, msg="expected ask_key \{ask_key} to enter sight within away==false budget")
  let s_in = place.sight_now().unwrap()
  assert_true(s_in.from_foot <= to_newest_away, msg="expected away==false, got from_foot=\{s_in.from_foot}")
  t.run_for(sight_bell_mid_ms)
  let mid_out = bell_drawn_alpha(tree, bell_rect)
  assert_true(
    match mid_out {
      Some(a) => a > 0.01 && a < 0.99
      None => false
    },
    msg="expected bell mid fade-out alpha in (0, 1), got \{Repr(mid_out)}",
  )
  t.run_for(sight_bell_end_ms)
  assert_true(bell_drawn_alpha(tree, bell_rect) is None)

  // 2) Scroll back down to foot (away stays false) so ask_key leaves sight:
  //    bell must fade IN smoothly (alpha strictly in (0, 1) at +float_ms/2, 1.0 after float_ms).
  t.wheel(195.0, 300.0, 120.0)
  let s_out = place.sight_now().unwrap()
  assert_true(s_out.at_foot || s_out.from_foot <= to_newest_away)
  t.run_for(sight_bell_mid_ms)
  let mid_in = bell_drawn_alpha(tree, bell_rect)
  assert_true(
    match mid_in {
      Some(a) => a > 0.01 && a < 0.99
      None => false
    },
    msg="expected bell mid fade-in alpha in (0, 1), got \{Repr(mid_in)}",
  )
  t.run_for(sight_bell_end_ms)
  assert_eq(bell_drawn_alpha(tree, bell_rect), Some(1.0))
}
