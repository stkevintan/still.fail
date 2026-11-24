// A touch screen's fingers as each host has them (each by the system's own id for it, from its down to its end:
// Android's pointer id, a UITouch, a GDK sequence, a Windows pointer id) made the app's two: the pointer's (0 down,
// 1 moved, 2 up, 3 called off) and the second's (4 down, 5 moved, 6 up), the first let go while the second is down 8
// (the second the first from then on, the same finger: its moves come as the first's). A finger down while two are is
// none of the app's to its end, whatever is let go meanwhile: no finger is told whose down was not. One called off
// (the system took it, the window no longer the app's) calls all of it off: told once (3), as where it was, both let
// go, nothing more of either told. The hosts hand each finger's events on as they come (pointer kinds 10 down, 11
// moved, 12 up, 13 called off, the system's id where a press's button goes); what they come to is the app's input, as
// it is kept on a tape (inputrec.mbt) and given again.
//
// A system hands a finger's moves in batches, a frame's samples together (Android's MotionEvent with its history, iOS's
// coalesced touches): 2-4 a frame on a phone. Each sample is a move of its own, taken at its own moment (what follows
// the hand, what it is let go at, sees every one), but what they changed is laid out once, as the batch's last is
// taken: the host hands each sample but the last as 14 (moved, more of its batch after it), the last as 11. A move of
// the app's pointer so (pointer_in's `more`) brings the tree to nothing, before it or after it, and the moves after it
// in the batch find the tree as the first did, till the last is taken: one layout a batch, not one a sample (每帧安卓送
// 2-4 个采样时整棵树排了 2-4 遍, 2026-11-16). What is laid out so is so as of the last's moment, the batch one input;
// a tape keeps which moves had more after them (inputrec.mbt), so a replay does the same at any rate of frames.
// A frame boundary (app.mbt's `on_frame`) or an unrouted trailing sample (`!more && kind < 0`, taped as
// `pointer-flush`) also closes an open batch and flushes deferred pointing/layout.

///|
/// The system's ids of the app's two fingers (any number, a negative one too), and whether each is there.
// kept across runs: put back as a run begins (touches_forget)
let touch_slots : FixedArray[Int] = FixedArray::make(2, 0)

///|
// kept across runs: put back as a run begins (touches_forget)
let touch_down : FixedArray[Bool] = FixedArray::make(2, false)

///|
/// Additional fingers beyond the primary two slots (`(sys_id, extra_slot)`), when the active target accepts > 2 fingers.
// kept across runs: put back as a run begins (touches_forget)
let touch_extra : Array[(Int, Int)] = []

///|
/// Next extra slot number (>= 2), reset in `touches_forget`.
// kept across runs: put back as a run begins (touches_forget)
let touch_extra_next : Ref[Int] = Ref(2)

///|
/// As a run begins, or the window is no longer the app's: no finger down of the app's.
fn touches_forget() -> Unit {
  touch_down[0] = false
  touch_down[1] = false
  touch_extra.clear()
  touch_extra_next.val = 2
  moves_batched.val = false
  perf_touch_at.val = -1.0
}

///|
/// A finger's event as the host has it (`phase`: 0 down, 1 moved, 2 up, 3 called off; `id`: the system's for it):
/// the app's pointer kind it comes to (as above), -1 none.
// (called by view_touches_wbtest.mbt to keep the 2-finger routing contract tested directly)
#warnings("-unused_value")
fn touch_kind(phase : Int, id : Int) -> Int {
  let first = touch_down[0] && touch_slots[0] == id
  let second = touch_down[1] && touch_slots[1] == id
  match phase {
    0 =>
      if !touch_down[0] {
        touch_slots[0] = id
        touch_down[0] = true
        0
      } else if !touch_down[1] && !first {
        touch_slots[1] = id
        touch_down[1] = true
        4
      } else {
        -1
      }
    1 => if first { 1 } else if second { 5 } else { -1 }
    2 =>
      if second {
        touch_down[1] = false
        6
      } else if first && touch_down[1] {
        touch_slots[0] = touch_slots[1]
        touch_down[1] = false
        8
      } else if first {
        touch_down[0] = false
        2
      } else {
        -1
      }
    3 =>
      if first || second {
        touches_forget()
        3
      } else {
        -1
      }
    _ => -1
  }
}

///|
/// Extended touch router supporting > 2 simultaneous fingers when `allow_extra` is true (or extra fingers are already
/// active): returns `(kind, extra_slot)` where `extra_slot` is 0 for standard kinds `<= 8`, and `>= 2` for extra kinds
/// (15 down, 16 move, 17 non-last up, 18 last up); kind 19 is slot 0 up while extra fingers remain down.
fn touch_kind_in(phase : Int, id : Int, allow_extra : Bool) -> (Int, Int) {
  let first = touch_down[0] && touch_slots[0] == id
  let second = touch_down[1] && touch_slots[1] == id
  let extra_idx = touch_extra.search_by(fn(e) { e.0 == id })
  match phase {
    0 =>
      if !touch_down[0] && !touch_down[1] && touch_extra.is_empty() {
        touch_slots[0] = id
        touch_down[0] = true
        (0, 0)
      } else if touch_down[0] && !touch_down[1] && touch_extra.is_empty() && !first {
        touch_slots[1] = id
        touch_down[1] = true
        (4, 0)
      } else if !first && !second && extra_idx is None && (allow_extra || !touch_extra.is_empty()) {
        let slot = touch_extra_next.val
        touch_extra_next.val += 1
        touch_extra.push((id, slot))
        (15, slot)
      } else {
        (-1, 0)
      }
    1 =>
      if first {
        (1, 0)
      } else if second {
        (5, 0)
      } else {
        match extra_idx {
          Some(i) => (16, touch_extra[i].1)
          None => (-1, 0)
        }
      }
    2 =>
      if second {
        touch_down[1] = false
        (6, 0)
      } else if first && touch_down[1] {
        touch_slots[0] = touch_slots[1]
        touch_down[1] = false
        (8, 0)
      } else if first && touch_extra.is_empty() {
        touch_down[0] = false
        (2, 0)
      } else if first {
        touch_down[0] = false
        (19, 0)
      } else {
        match extra_idx {
          Some(i) => {
            let slot = touch_extra[i].1
            touch_extra.remove(i) |> ignore
            if !touch_down[0] && !touch_down[1] && touch_extra.is_empty() {
              (18, slot)
            } else {
              (17, slot)
            }
          }
          None => (-1, 0)
        }
      }
    3 =>
      if first || second || extra_idx is Some(_) {
        touches_forget()
        (3, 0)
      } else {
        (-1, 0)
      }
    _ => (-1, 0)
  }
}

///|
/// Whether the pointer's last move had more of its batch after it (above): the next move finds the tree as it was.
// kept across runs: put back as a run begins (touches_forget)
let moves_batched : Ref[Bool] = Ref(false)

///|
/// The window no longer the app's: a finger of the app's down called off (3), all of it, as any called off is.
fn touches_off() -> Unit {
  // A frame after the app returns is not an answer to a touch from before it left the foreground.
  perf_touch_at.val = -1.0
  if touch_down[0] || touch_down[1] || !touch_extra.is_empty() {
    let id = if touch_down[0] {
      touch_slots[0]
    } else if touch_down[1] {
      touch_slots[1]
    } else {
      touch_extra[0].0
    }
    touch_in(3, id, last_touch_x.val, last_touch_y.val)
  }
}

///|
/// Where the app's first finger was last told (what one called off by the window says).
// kept across runs: where one is called off
let last_touch_x : Ref[Double] = Ref(0.0)

///|
// kept across runs: where one is called off
let last_touch_y : Ref[Double] = Ref(0.0)

///|
/// A finger's event from the host (above), as one event at its own moment (view_host.mbt): what was due before it done
/// first, then what it comes to worked out and taken as the app's pointer's, in the same event (what was due never
/// sees a finger not down yet, nor misses one that is). `phase` 4: moved, more of its batch after it.
fn touch_in(phase : Int, id : Int, x : Double, y : Double) -> Unit {
  let more = phase == 4
  let phase = if more { 1 } else { phase }
  if phase == 2 &&
    ((touch_down[0] && touch_slots[0] == id) ||
    (touch_down[1] && touch_slots[1] == id) ||
    touch_extra.iter().any(fn(e) { e.0 == id })) {
    perf_touch_started()
  }
  // (a finger's, so as of its moment: pointer_in's)
  let what = match phase {
    0 => "touch-down"
    1 => "touch-move"
    2 => "touch-up"
    _ => "touch-off"
  }
  view_event_said(fn() { pointing_said_by_host(1) }, fn() {
    let (kind, extra_slot) = touch_kind_in(phase, id, view_wants_extra_fingers())
    if kind >= 0 && kind <= 3 {
      last_touch_x.val = x
      last_touch_y.val = y
    }
    if kind >= 0 {
      // (in this event: at its moment)
      pointer_in(kind, x, y, extra_slot, if kind == 0 { mods_held() } else { 0 }, by=1, more~)
    } else if !more && moves_batched.val {
      moves_batched.val = false
      view_pointed(bring=true)
      input_taped("pointer-flush", h_event_time(), [])
    }
  }, what~, more~)
}
