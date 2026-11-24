// A system's batch of a finger's samples (touches.mbt): each a move taken at its own moment, what they changed laid out
// once, as the batch's last is taken.

///|
/// A frame of a phone's display: between the finger's down and its batch of moves.
let batch_frame_ms : Double = 16.0

///|
/// Intermediate moment during a touch fling glide before hitting the edge.
let batch_mid_fling_ms : Double = 120.0

///|
/// Duration long enough for a touch fling glide to finish in batch tests.
let batch_fling_ms : Double = 1200.0

///|
/// A Tester with a node a finger drags over the window's top left: its width the drag's x, what it is told in `seen`
/// (what, where, when).
fn batch_tester(seen : Array[String]) -> Tester {
  let t = Tester::new(fn(_c) {  })
  t.check_looks(false)
  let w = @signals.signal(100.0)
  set_view_app(fn(root) {
    root.box(fn(b) {
      b.over(Is(true)) |> ignore
      b.box(fn(h) {
        h
        .width(By(fn() { Some(w.get()) }))
        .height(Is(Some(200.0)))
        .on_drag(fn(d) {
          seen.push("\{d.kind} \{d.x} \{d.at}")
          if d.kind is Moved {
            w.set(d.x)
          }
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.drawn_now()
  t
}

///|
/// A finger down at 10,10, then the moves to `xs` (one batch: the host's phase for each, 4 more after it, 1 the
/// last), 2 ms apart: what the node was told, the nodes laid out by the moves.
fn batch_moved(phases : Array[Int], xs : Array[Double]) -> (Array[String], Int) {
  let seen : Array[String] = []
  let t = batch_tester(seen)
  let t0 = t.time()
  t.touch_raw(0, 7, 10.0, 10.0, t0)
  t.advance(batch_frame_ms)
  t.drawn_now()
  let laid = fn() { view_app.val.unwrap().work().laid }
  let before = laid()
  for i, x in xs {
    t.touch_raw(phases[i], 7, x, 10.0, t0 + batch_frame_ms + 2.0 * i.to_double())
  }
  let moved = laid() - before
  t.drawn_now()
  t.touch_raw(2, 7, xs[xs.length() - 1], 10.0, t0 + 40.0)
  (seen, moved)
}

///|
test "a batch of a finger's moves: each told at its own moment, laid out once, at the last" {
  let xs = [120.0, 130.0, 140.0, 150.0]
  let (apart, apart_laid) = batch_moved([1, 1, 1, 1], xs)
  let (batch, batch_laid) = batch_moved([4, 4, 4, 1], xs)
  // (every sample the node's, at its own moment, as when each came alone)
  assert_eq(batch, apart)
  assert_eq(batch.length(), 6)
  // (one layout of the four's: as many nodes as one alone lays out)
  assert_true(apart_laid > 0)
  assert_eq(batch_laid * 4, apart_laid)
}

///|
/// Build a touch-scrollable virtualized list with `View::laid_before_moves` and `ListPlace::on_sight` for batch tests.
fn batch_list_tester(
  scroll : @view.Scroll,
  place : @view.ListPlace[Int],
  sights : Array[(Int, Int, Double)],
  extra_box? : (@view.View) -> Unit = fn(_) {  },
) -> Tester {
  let t = Tester::new(fn(_c) {  }, w=390.0, h=600.0, platform=2)
  t.check_looks(false)
  set_view_app(fn(root) {
    root.transitions_only() |> ignore
    root.box(fn(col) {
      col.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      col.laid_before_moves()
      extra_box(col)
      col.scrolls_window(
        scroll,
        fn() { Array::makei(80, fn(i) { i }) },
        est=40.0,
        follows=fn() { false },
        place~,
        fn(row, k) {
          row.height(Is(Some(40.0))).box(fn(inner) {
            inner.words(Is("row-\{k}")) |> ignore
          })
          |> ignore
        },
      )
      |> ignore
      place.on_sight(fn(s) {
        sights.push((s.first, s.last, h_event_time()))
      })
    })
    |> ignore
  })
  t.draw()
  t.drawn_now()
  t
}

///|
/// Run a scroll + fling gesture on `batch_list_tester` with given move phases and return
/// `(mid_sights, end_sights, mid_laid, mid_settles, after_drag_offset, mid_fling_offset, after_fling_offset, final_sight)`.
fn run_list_batch(phases : Array[Int], ys : Array[Double]) -> (Int, Int, Int, Int, Double, Double, Double, (Int, Int)) {
  let scroll = @view.Scroll::list()
  let place : @view.ListPlace[Int] = @view.ListPlace::new()
  let sights : Array[(Int, Int, Double)] = []
  let t = batch_list_tester(scroll, place, sights)
  let t0 = t.time()
  t.touch_raw(0, 1, 180.0, 460.0, t0)
  t.advance(batch_frame_ms)
  t.drawn_now()
  let tree = view_app.val.unwrap()
  let sights0 = sights.length()
  let laid0 = tree.work().laid
  let settles0 = tree.work().settles
  let mut mid_sights = 0
  let mut mid_laid = 0
  let mut mid_settles = 0
  for i, y in ys {
    t.touch_raw(phases[i], 1, 180.0, y, t0 + batch_frame_ms + 2.0 * (i + 1).to_double())
    if i < ys.length() - 1 {
      mid_sights = sights.length() - sights0
      mid_laid = tree.work().laid - laid0
      mid_settles = tree.work().settles - settles0
    }
  }
  let end_sights = sights.length() - sights0
  let after_drag = @signals.untracked(fn() { scroll.at(tree) })
  t.touch_raw(2, 1, 180.0, ys[ys.length() - 1], t0 + batch_frame_ms + 2.0 * (ys.length() + 1).to_double())
  t.run_for(batch_mid_fling_ms)
  let mid_fling = @signals.untracked(fn() { scroll.at(tree) })
  t.run_for(batch_fling_ms)
  let after_fling = @signals.untracked(fn() { scroll.at(tree) })
  let final_sight = match place.sight_now() {
    Some(s) => (s.first, s.last)
    None => (-1, -1)
  }
  (mid_sights, end_sights, mid_laid, mid_settles, after_drag, mid_fling, after_fling, final_sight)
}

///|
test "scrolls_window batch [4,4,4,1] matches [1,1,1,1] mid-fling and final state with zero mid-batch sight and layout" {
  let ys = [420.0, 380.0, 340.0, 300.0]
  let (_, _, _, _, apart_drag, apart_mid, apart_fling, apart_sight) = run_list_batch([1, 1, 1, 1], ys)
  let (mid_sights, end_sights, mid_laid, mid_settles, batch_drag, batch_mid, batch_fling, batch_sight) = run_list_batch(
    [4, 4, 4, 1],
    ys,
  )
  assert_eq(mid_sights, 0)
  assert_eq(mid_laid, 0)
  assert_eq(mid_settles, 0)
  assert_eq(end_sights, 1)
  assert_true((batch_drag - apart_drag).abs() < 0.01, msg="drag \{batch_drag} vs \{apart_drag}")
  assert_true((batch_mid - apart_mid).abs() < 0.01, msg="mid-fling \{batch_mid} vs \{apart_mid}")
  assert_true((batch_fling - apart_fling).abs() < 0.01, msg="fling \{batch_fling} vs \{apart_fling}")
  assert_eq(batch_sight, apart_sight)
}

///|
test "abnormal batch endings (4->2, 4->3, 4->at_moment->2, 4->frame) settle cleanly and reset moves_batched" {
  // 1) 4 -> 2 (touch-up immediately after phase 4)
  {
    let scroll = @view.Scroll::list()
    let place : @view.ListPlace[Int] = @view.ListPlace::new()
    let sights : Array[(Int, Int, Double)] = []
    let t = batch_list_tester(scroll, place, sights)
    let t0 = t.time()
    t.touch_raw(0, 1, 180.0, 460.0, t0)
    t.advance(batch_frame_ms)
    t.drawn_now()
    let s0 = sights.length()
    t.touch_raw(4, 1, 180.0, 380.0, t0 + 18.0)
    assert_eq(sights.length(), s0)
    assert_true(moves_batched.val)
    t.touch_raw(2, 1, 180.0, 340.0, t0 + 22.0)
    assert_false(moves_batched.val)
    assert_true(sights.length() > s0)
    t.run_for(batch_fling_ms)
    assert_true(@signals.untracked(fn() { scroll.at(view_app.val.unwrap()) }) > 0.0)
  }

  // 2) 4 -> 3 (touch-cancel mid-batch): exactly 1 Off, no leaked hold, moves_batched == false
  {
    let seen : Array[String] = []
    let t = batch_tester(seen)
    let t0 = t.time()
    t.touch_raw(0, 7, 10.0, 10.0, t0)
    t.advance(batch_frame_ms)
    t.drawn_now()
    t.touch_raw(4, 7, 60.0, 10.0, t0 + 18.0)
    assert_true(moves_batched.val)
    t.touch_raw(3, 7, 60.0, 10.0, t0 + 22.0)
    assert_false(moves_batched.val)
    assert_true(view_held.val is None)
    let offs = seen.filter(fn(s) { s.has_prefix("Off ") }).length()
    assert_eq(offs, 1)
  }

  // 3) 4 -> at_moment due -> 2: exact order ["moment", "up"]
  {
    let order : Array[String] = []
    let t = Tester::new(fn(_c) {  }, w=390.0, h=600.0, platform=2)
    t.check_looks(false)
    let box_ref : Ref[@view.View?] = Ref(None)
    set_view_app(fn(root) {
      root.box(fn(b) {
        box_ref.val = Some(b)
        b.width(Is(Some(300.0))).height(Is(Some(300.0)))
        .on_drag(fn(d) {
          if d.kind is Up {
            order.push("up")
          }
        })
        |> ignore
      })
      |> ignore
    })
    t.draw()
    t.drawn_now()
    let t0 = t.time()
    box_ref.val.unwrap().at_moment(t0 + 20.0, fn() { order.push("moment") }) |> ignore
    t.touch_raw(0, 1, 100.0, 100.0, t0)
    t.touch_raw(4, 1, 140.0, 100.0, t0 + 18.0)
    assert_eq(order, [])
    // Next sample at t0 + 24.0 must fire the due at_moment at t0 + 20.0 before Ended
    t.touch_raw(2, 1, 160.0, 100.0, t0 + 24.0)
    assert_eq(order, ["moment", "up"])
    assert_false(moves_batched.val)
  }

  // 4) 4 -> frame (frame boundary resets leaked moves_batched and settles sight)
  {
    let scroll = @view.Scroll::list()
    let place : @view.ListPlace[Int] = @view.ListPlace::new()
    let sights : Array[(Int, Int, Double)] = []
    let t = batch_list_tester(scroll, place, sights)
    let t0 = t.time()
    t.touch_raw(0, 1, 180.0, 460.0, t0)
    t.advance(batch_frame_ms)
    t.drawn_now()
    let s0 = sights.length()
    t.touch_raw(4, 1, 180.0, 380.0, t0 + 18.0)
    assert_true(moves_batched.val)
    // Frame arrives without a trailing phase=1 sample
    t.advance(batch_frame_ms)
    t.drawn_now()
    assert_false(moves_batched.val)
    assert_true(sights.length() > s0)
    t.touch_raw(2, 1, 180.0, 380.0, t.time())
    t.run_for(batch_fling_ms)
  }
}

///|
test "replay pointer_in(more=true) matches touch_raw(4) and unrouted finger flushes batch and records pointer-flush tape" {
  // 1) pointer_in(..., more=true) defers mid-batch layout/sight just like touch_raw(4, ...)
  {
    let scroll = @view.Scroll::list()
    let place : @view.ListPlace[Int] = @view.ListPlace::new()
    let sights : Array[(Int, Int, Double)] = []
    let t = batch_list_tester(scroll, place, sights)
    let t0 = t.time()
    t.advance(batch_frame_ms)
    t.drawn_now()
    let send_ptr = fn(kind : Int, y : Double, at : Double, more : Bool) {
      t.fake.event_at = at
      pointer_in(kind, 180.0, y, 0, 0, by=1, more~)
      t.fake.event_at = -1.0
    }
    send_ptr(0, 460.0, t0 + batch_frame_ms, false)
    let tree = view_app.val.unwrap()
    let s0 = sights.length()
    let laid0 = tree.work().laid
    send_ptr(1, 410.0, t0 + batch_frame_ms + 2.0, true)
    send_ptr(1, 360.0, t0 + batch_frame_ms + 4.0, true)
    assert_eq(sights.length(), s0)
    assert_eq(tree.work().laid, laid0)
    assert_true(moves_batched.val)
    send_ptr(1, 310.0, t0 + batch_frame_ms + 6.0, false)
    assert_false(moves_batched.val)
    assert_eq(sights.length(), s0 + 1)
    send_ptr(2, 310.0, t0 + batch_frame_ms + 8.0, false)
    t.run_for(batch_fling_ms)
  }

  // 2) Truly unrouted finger (id=99 never pressed, so touch_kind_in returns kind=-1) carries final !more sample:
  //    must NOT dispatch an extra drag move, must reset moves_batched, must fire on_sight at t0+22.0,
  //    and must tape `pointer-flush` so replay produces the exact same settlement moment.
  let recorded : Array[String] = []
  let live_sight_at = Ref(-1.0)
  {
    let scroll = @view.Scroll::list()
    let place : @view.ListPlace[Int] = @view.ListPlace::new()
    let sights : Array[(Int, Int, Double)] = []
    let t = batch_list_tester(scroll, place, sights)
    let t0 = t.time()
    tape.val = Some(recorded)
    t.touch_raw(0, 1, 180.0, 460.0, t0)
    t.advance(batch_frame_ms)
    t.drawn_now()
    let s0 = sights.length()
    // Finger 1 moves with phase=4 (more=true), then unrouted id=99 gets phase=1 (more=false -> kind == -1)
    t.touch_raw(4, 1, 180.0, 380.0, t0 + 20.0)
    assert_true(moves_batched.val)
    assert_eq(sights.length(), s0)
    let offset_before = @signals.untracked(fn() { scroll.at(view_app.val.unwrap()) })
    t.touch_raw(1, 99, 260.0, 120.0, t0 + 22.0)
    let offset_after = @signals.untracked(fn() { scroll.at(view_app.val.unwrap()) })
    // Unrouted finger must not move the scroll
    assert_eq(offset_after, offset_before)
    assert_false(moves_batched.val)
    assert_eq(sights.length(), s0 + 1)
    live_sight_at.val = sights[sights.length() - 1].2
    assert_eq(live_sight_at.val, t0 + 22.0)
    t.touch_raw(2, 1, 180.0, 380.0, t0 + 26.0)
    tape.val = None
    t.run_for(batch_fling_ms)
  }
  let input_lines = recorded.filter(fn(l) { l.has_prefix("INPUT ") })
  assert_true(input_lines.iter().any(fn(l) { l.contains("\"pointer-flush\"") }))

  // Replay the recorded INPUT lines on a fresh Tester and verify identical settlement moment
  {
    let scroll = @view.Scroll::list()
    let place : @view.ListPlace[Int] = @view.ListPlace::new()
    let sights : Array[(Int, Int, Double)] = []
    let t = batch_list_tester(scroll, place, sights)
    let s0 = sights.length()
    for line in input_lines {
      replay_input(t.fake, line)
    }
    assert_false(moves_batched.val)
    // Find the first sight fired after the down/move batch flush
    assert_true(sights.length() > s0)
    assert_true(sights.iter().any(fn(s) { s.2 == live_sight_at.val }))
    t.run_for(batch_fling_ms)
  }

  // Mixed input: Mouse more=true -> unrouted finger id=99 triggers pointer-flush;
  // both live and replayed runs must restore pointing() == Finger after the flush.
  let mixed_recorded : Array[String] = []
  {
    let t = Tester::new(fn(_c) {  }, w=300.0, h=200.0, platform=0)
    t.check_looks(false)
    set_view_app(fn(root) {
      root.box(fn(b) { b.width(Is(Some(200.0))).height(Is(Some(200.0))).points(Is(true)) |> ignore }) |> ignore
    })
    t.draw()
    t.drawn_now()
    let t0 = t.time()
    tape.val = Some(mixed_recorded)
    t.fake.event_at = t0 + 2.0
    pointer_in(1, 50.0, 50.0, 0, 0, by=0, more=true)
    t.fake.event_at = -1.0
    assert_true(moves_batched.val)
    assert_eq(@signals.untracked(pointing), Mouse)
    t.touch_raw(1, 99, 120.0, 80.0, t0 + 4.0)
    assert_false(moves_batched.val)
    assert_eq(@signals.untracked(pointing), Finger)
    tape.val = None
  }
  let mixed_inputs = mixed_recorded.filter(fn(l) { l.has_prefix("INPUT ") })
  assert_true(mixed_inputs.iter().any(fn(l) { l.contains("\"pointer-flush\"") }))
  {
    let t = Tester::new(fn(_c) {  }, w=300.0, h=200.0, platform=0)
    t.check_looks(false)
    set_view_app(fn(root) {
      root.box(fn(b) { b.width(Is(Some(200.0))).height(Is(Some(200.0))).points(Is(true)) |> ignore }) |> ignore
    })
    t.draw()
    t.drawn_now()
    for line in mixed_inputs {
      replay_input(t.fake, line)
    }
    assert_false(moves_batched.val)
    assert_eq(@signals.untracked(pointing), Finger)
  }
}

///|
test "on_frame mid-batch flushes deferred hover pointing from stationary box A to box B" {
  let t = Tester::new(fn(_c) {  }, w=300.0, h=200.0, platform=0)
  t.check_looks(false)
  let a_ref : Ref[@view.View?] = Ref(None)
  let b_ref : Ref[@view.View?] = Ref(None)
  let b_moves = Ref(0)
  set_view_app(fn(root) {
    root.row(Is(true)) |> ignore
    root.box(fn(a) {
      a_ref.val = Some(a)
      a.width(Is(Some(100.0))).height(Is(Some(100.0))).points(Is(true)) |> ignore
    })
    |> ignore
    root.box(fn(b) {
      b_ref.val = Some(b)
      b.width(Is(Some(100.0))).height(Is(Some(100.0))).points(Is(true))
      .on_pointer_moved(fn() { b_moves.val += 1 })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.drawn_now()
  let a = a_ref.val.unwrap()
  let b = b_ref.val.unwrap()
  let t0 = t.time()
  // Hover over A first
  t.fake.event_at = t0 + 2.0
  pointer_in(1, 50.0, 50.0, 0, 0, by=0, more=false)
  t.fake.event_at = -1.0
  assert_true(@signals.untracked(fn() { a.pointed() }))
  assert_false(@signals.untracked(fn() { b.pointed() }))
  assert_eq(b_moves.val, 0)

  // Move mouse to B with more=true (mid-batch) then immediately tick a frame without a trailing more=false
  t.fake.event_at = t0 + 4.0
  pointer_in(1, 150.0, 50.0, 0, 0, by=0, more=true)
  t.fake.event_at = -1.0
  assert_true(moves_batched.val)
  t.advance(batch_frame_ms)
  t.draw()
  assert_false(moves_batched.val)
  assert_false(@signals.untracked(fn() { a.pointed() }))
  assert_true(@signals.untracked(fn() { b.pointed() }))
  assert_true(@signals.untracked(fn() { b.pointer_within() }))
  assert_eq(b_moves.val, 1)

  // Resize on the same frame that closes a more=true batch: right-aligned boxes [A, B] shift right when
  // window widens 300 -> 400, so pointer at x=250 (was over B) must land on A after layout, with 0 spurious B moves.
  {
    let t2 = Tester::new(fn(_c) {  }, w=300.0, h=200.0, platform=0)
    t2.check_looks(false)
    let ra_ref : Ref[@view.View?] = Ref(None)
    let rb_ref : Ref[@view.View?] = Ref(None)
    let ra_moves = Ref(0)
    let rb_moves = Ref(0)
    set_view_app(fn(root) {
      root.row(Is(true)) |> ignore
      root.box(fn(sp) { sp.grow(Is(1.0)) |> ignore }) |> ignore
      root.box(fn(a) {
        ra_ref.val = Some(a)
        a.width(Is(Some(100.0))).height(Is(Some(100.0))).points(Is(true))
        .on_pointer_moved(fn() { ra_moves.val += 1 })
        |> ignore
      })
      |> ignore
      root.box(fn(b) {
        rb_ref.val = Some(b)
        b.width(Is(Some(100.0))).height(Is(Some(100.0))).points(Is(true))
        .on_pointer_moved(fn() { rb_moves.val += 1 })
        |> ignore
      })
      |> ignore
    })
    t2.draw()
    t2.drawn_now()
    let ra = ra_ref.val.unwrap()
    let rb = rb_ref.val.unwrap()
    let t0_2 = t2.time()
    // Initially at w=300: A is [100, 200], B is [200, 300]. Start pointed at x=50 (spacer).
    t2.fake.event_at = t0_2 + 2.0
    pointer_in(1, 50.0, 50.0, 0, 0, by=0, more=false)
    t2.fake.event_at = -1.0
    assert_false(@signals.untracked(fn() { ra.pointed() }))
    assert_false(@signals.untracked(fn() { rb.pointed() }))
    // Move to x=250 (over B at w=300) with more=true, then widen window to w=400 on the closing frame
    // so A shifts to [200, 300] and B shifts to [300, 400].
    t2.fake.event_at = t0_2 + 4.0
    pointer_in(1, 250.0, 50.0, 0, 0, by=0, more=true)
    t2.fake.event_at = -1.0
    assert_true(moves_batched.val)
    t2.resize_next(400.0, 200.0)
    t2.advance(batch_frame_ms)
    t2.draw()
    assert_false(moves_batched.val)
    assert_true(@signals.untracked(fn() { ra.pointed() }))
    assert_false(@signals.untracked(fn() { rb.pointed() }))
    assert_eq(ra_moves.val, 1)
    assert_eq(rb_moves.val, 0)
  }
}

///|
test "mid-batch transition preserves exact pre-transition placement for both prior-event and in-batch mutations (Opus B1/B3)" {
  // 1) Prior non-transition event before batch, then mid-batch @view.transition
  {
    let pad = @signals.signal(0.0)
    let mode = @signals.signal(0)
    let target : Ref[@view.View?] = Ref(None)
    let seen_placed_y = Ref(-1.0)
    let seen_laid_y = Ref(-1.0)
    let t = Tester::new(fn(_c) {  }, w=390.0, h=600.0, platform=2)
    t.check_looks(false)
    set_view_app(fn(root) {
      root.transitions_only() |> ignore
      root.box(fn(col) {
        col.laid_before_moves()
        col.box(fn(spacer) { spacer.height(By(fn() { Some(pad.get()) })) |> ignore }) |> ignore
        col.box(fn(mode_spacer) {
          mode_spacer.height(By(fn() { Some(if mode.get() == 1 { 30.0 } else { 0.0 }) })) |> ignore
        })
        |> ignore
        col.box(fn(b) {
          target.val = Some(b)
          b.height(Is(Some(40.0)))
          .on_drag(fn(d) {
            if d.kind is Moved && d.x >= 135.0 && mode.untracked() == 0 {
              @view.transition(fn() { mode.set(1) })
            }
          })
          |> ignore
        })
        |> ignore
        let initialized = Ref(false)
        col.reacts(fn() { mode.get() }, fn(_) {
          if !initialized.val {
            initialized.val = true
            return
          }
          if col.transition_gate() {
            let b = target.val.unwrap()
            seen_placed_y.val = b.placed_window_now().1
            seen_laid_y.val = b.laid_window_now().1
          }
        })
      })
      |> ignore
    })
    t.draw()
    t.drawn_now()
    let t0 = t.time()
    t.touch_raw(0, 7, 100.0, 20.0, t0)
    t.advance(batch_frame_ms)
    t.drawn_now()
    view_app.val.unwrap().event(t0 + batch_frame_ms + 1.0, fn() { pad.set(60.0) })
    t.touch_raw(4, 7, 120.0, 20.0, t0 + batch_frame_ms + 2.0)
    t.touch_raw(4, 7, 150.0, 20.0, t0 + batch_frame_ms + 4.0)
    t.touch_raw(1, 7, 160.0, 20.0, t0 + batch_frame_ms + 6.0)
    t.touch_raw(2, 7, 160.0, 20.0, t0 + batch_frame_ms + 8.0)
    assert_eq(seen_placed_y.val, 60.0)
    assert_eq(seen_laid_y.val, 90.0)
  }

  // 2) In-batch mutation: sample 1 (phase=4) mutates pad=60.0 without settling;
  //    sample 2 (phase=4) calls @view.transition(mode=1) -> transition_run drains batch_owed_at first
  //    so placed_window_now() settles pad=60 and sees exact pre-transition placement 60.0 -> 90.0.
  {
    let pad = @signals.signal(0.0)
    let mode = @signals.signal(0)
    let target : Ref[@view.View?] = Ref(None)
    let seen_placed_y = Ref(-1.0)
    let seen_laid_y = Ref(-1.0)
    let t = Tester::new(fn(_c) {  }, w=390.0, h=600.0, platform=2)
    t.check_looks(false)
    set_view_app(fn(root) {
      root.transitions_only() |> ignore
      root.box(fn(col) {
        col.laid_before_moves()
        col.box(fn(spacer) { spacer.height(By(fn() { Some(pad.get()) })) |> ignore }) |> ignore
        col.box(fn(mode_spacer) {
          mode_spacer.height(By(fn() { Some(if mode.get() == 1 { 30.0 } else { 0.0 }) })) |> ignore
        })
        |> ignore
        col.box(fn(b) {
          target.val = Some(b)
          b.height(Is(Some(40.0)))
          .on_drag(fn(d) {
            if d.kind is Moved {
              if d.x < 135.0 {
                pad.set(60.0)
              } else if mode.untracked() == 0 {
                @view.transition(fn() { mode.set(1) })
              }
            }
          })
          |> ignore
        })
        |> ignore
        let initialized = Ref(false)
        col.reacts(fn() { mode.get() }, fn(_) {
          if !initialized.val {
            initialized.val = true
            return
          }
          if col.transition_gate() {
            let b = target.val.unwrap()
            seen_placed_y.val = b.placed_window_now().1
            seen_laid_y.val = b.laid_window_now().1
          }
        })
      })
      |> ignore
    })
    t.draw()
    t.drawn_now()
    let t0 = t.time()
    t.touch_raw(0, 7, 100.0, 20.0, t0)
    t.advance(batch_frame_ms)
    t.drawn_now()
    t.touch_raw(4, 7, 120.0, 20.0, t0 + batch_frame_ms + 2.0)
    t.touch_raw(4, 7, 150.0, 20.0, t0 + batch_frame_ms + 4.0)
    t.touch_raw(1, 7, 160.0, 20.0, t0 + batch_frame_ms + 6.0)
    t.touch_raw(2, 7, 160.0, 20.0, t0 + batch_frame_ms + 8.0)
    assert_eq(seen_placed_y.val, 60.0)
    assert_eq(seen_laid_y.val, 90.0)
  }

  // 3) Astra R2 B1: 18ms phase=4 pad.set(60) -> 20ms at_moment transition { mode.set(1) }
  //    driven by (a) 24ms frame (advance + draw) vs (b) 24ms next input (touch_raw):
  //    both paths MUST see identical pre-transition placement (60.0 -> 90.0).
  for via_frame in [true, false] {
    let pad = @signals.signal(0.0)
    let mode = @signals.signal(0)
    let target : Ref[@view.View?] = Ref(None)
    let seen_placed_y = Ref(-1.0)
    let seen_laid_y = Ref(-1.0)
    let t = Tester::new(fn(_c) {  }, w=390.0, h=600.0, platform=2)
    t.check_looks(false)
    set_view_app(fn(root) {
      root.transitions_only() |> ignore
      root.box(fn(col) {
        col.laid_before_moves()
        col.box(fn(spacer) { spacer.height(By(fn() { Some(pad.get()) })) |> ignore }) |> ignore
        col.box(fn(mode_spacer) {
          mode_spacer.height(By(fn() { Some(if mode.get() == 1 { 30.0 } else { 0.0 }) })) |> ignore
        })
        |> ignore
        col.box(fn(b) {
          target.val = Some(b)
          b.height(Is(Some(40.0)))
          .on_drag(fn(d) {
            if d.kind is Moved && pad.untracked() == 0.0 {
              pad.set(60.0)
            }
          })
          |> ignore
        })
        |> ignore
        let initialized = Ref(false)
        col.reacts(fn() { mode.get() }, fn(_) {
          if !initialized.val {
            initialized.val = true
            return
          }
          if col.transition_gate() {
            let b = target.val.unwrap()
            seen_placed_y.val = b.placed_window_now().1
            seen_laid_y.val = b.laid_window_now().1
          }
        })
      })
      |> ignore
    })
    t.draw()
    t.drawn_now()
    let t0 = t.time()
    t.touch_raw(0, 7, 100.0, 20.0, t0)
    t.advance(batch_frame_ms)
    t.drawn_now()
    let base_at = t.time()
    target.val.unwrap().at_moment(base_at + 4.0, fn() {
      @view.transition(fn() { mode.set(1) })
    })
    |> ignore
    // Sample at base_at + 2.0 mutates pad=60.0 inside a more=true batch
    t.touch_raw(4, 7, 120.0, 20.0, base_at + 2.0)
    assert_true(moves_batched.val)
    if via_frame {
      t.advance(batch_frame_ms)
      t.draw()
    } else {
      t.touch_raw(1, 7, 140.0, 20.0, base_at + 8.0)
    }
    assert_eq(seen_placed_y.val, 60.0)
    assert_eq(seen_laid_y.val, 90.0)
  }
}

///|
let batch_cancel_step_ms : Double = 24.0

///|
let batch_cancel_later_ms : Double = 90.0

///|
test "advance_loop re-selects timeline after settling batch_owed_at unschedules an entry (R3 B1)" {
  // Helper: eager tree (laid_before_causes, no transitions_only) where a phase=4 move changes box width
  // from 200 to 260, triggering `by_room`'s `room.width()` reaction during `settle_now(batch_at)` to invoke `on_grow`.
  let make_eager = fn(on_grow : Ref[() -> Unit]) -> (Tester, @view.View) {
    let w = @signals.signal(200.0)
    let box_ref : Ref[@view.View?] = Ref(None)
    let t = Tester::new(fn(_c) {  }, w=390.0, h=600.0, platform=2)
    t.check_looks(false)
    set_view_app(fn(root) {
      root.laid_before_causes()
      root.box(fn(b) {
        box_ref.val = Some(b)
        b.width(By(fn() { Some(w.get()) })).height(Is(Some(40.0)))
        .on_drag(fn(d) {
          if d.kind is Moved && w.untracked() == 200.0 {
            w.set(260.0)
          }
        })
        |> ignore
        b.by_room(fn(inner, room) {
          inner.reacts(fn() { room.width() }, fn(nw) {
            if nw >= 260.0 {
              (on_grow.val)()
            }
          })
        })
        |> ignore
      })
      |> ignore
    })
    t.draw()
    t.drawn_now()
    (t, box_ref.val.unwrap())
  }

  // 1) Schedule A at +20ms and B at +100ms; phase=4 at +18ms cancels A during settle_now.
  //    Advancing to +24ms must run neither A nor B; advancing past +100ms runs B exactly once.
  {
    let a_ran = Ref(0)
    let b_ran = Ref(0)
    let on_grow : Ref[() -> Unit] = Ref(fn() {  })
    let (t, b) = make_eager(on_grow)
    let t0 = t.time()
    t.touch_raw(0, 7, 100.0, 20.0, t0)
    t.advance(batch_frame_ms)
    t.drawn_now()
    let base = t.time()
    let cancel_a = b.at_moment(base + 20.0, fn() { a_ran.val += 1 })
    b.at_moment(base + 100.0, fn() { b_ran.val += 1 }) |> ignore
    on_grow.val = cancel_a
    t.touch_raw(4, 7, 120.0, 20.0, base + 18.0)
    assert_true(moves_batched.val)
    t.advance(batch_cancel_step_ms)
    t.draw()
    assert_eq(a_ran.val, 0)
    assert_eq(b_ran.val, 0)
    t.advance(batch_cancel_later_ms)
    t.draw()
    assert_eq(a_ran.val, 0)
    assert_eq(b_ran.val, 1)
  }

  // 2) Schedule ONLY A at +20ms; phase=4 at +18ms cancels A during settle_now.
  //    Advancing to +24ms must not abort out-of-bounds and A must not run.
  {
    let a_ran = Ref(0)
    let on_grow : Ref[() -> Unit] = Ref(fn() {  })
    let (t, b) = make_eager(on_grow)
    let t0 = t.time()
    t.touch_raw(0, 7, 100.0, 20.0, t0)
    t.advance(batch_frame_ms)
    t.drawn_now()
    let base = t.time()
    let cancel_a = b.at_moment(base + 20.0, fn() { a_ran.val += 1 })
    on_grow.val = cancel_a
    t.touch_raw(4, 7, 120.0, 20.0, base + 18.0)
    assert_true(moves_batched.val)
    t.advance(batch_cancel_step_ms)
    t.draw()
    assert_eq(a_ran.val, 0)
  }

  // 3) Schedule A at +100ms (index 0) THEN B at +20ms (index 1); phase=4 at +18ms cancels A (shifts B to index 0).
  //    Advancing to +24ms must run B exactly once and A zero times without out-of-bounds index.
  {
    let a_ran = Ref(0)
    let b_ran = Ref(0)
    let on_grow : Ref[() -> Unit] = Ref(fn() {  })
    let (t, b) = make_eager(on_grow)
    let t0 = t.time()
    t.touch_raw(0, 7, 100.0, 20.0, t0)
    t.advance(batch_frame_ms)
    t.drawn_now()
    let base = t.time()
    let cancel_a = b.at_moment(base + 100.0, fn() { a_ran.val += 1 })
    b.at_moment(base + 20.0, fn() { b_ran.val += 1 }) |> ignore
    on_grow.val = cancel_a
    t.touch_raw(4, 7, 120.0, 20.0, base + 18.0)
    assert_true(moves_batched.val)
    t.advance(batch_cancel_step_ms)
    t.draw()
    assert_eq(a_ran.val, 0)
    assert_eq(b_ran.val, 1)
  }
}

///|
test "on_frame mid-batch refreshes IBeam cursor over selectable text in both directions (R3 B2)" {
  let t = Tester::new(fn(_c) {  }, w=300.0, h=200.0, platform=0)
  t.check_looks(false)
  set_view_app(fn(root) {
    words_picked(root)
    root.box(fn(blank) { blank.width(Is(Some(300.0))).height(Is(Some(80.0))) |> ignore }) |> ignore
    root.box(fn(w) {
      w
      .width(Is(Some(300.0)))
      .height(Is(Some(60.0)))
      .words_runs(
        Is([plain("hello selectable text line")]),
        ink=0x333333FFL,
        look={ size: 15.0, weight: 400, line: 22.0, wrap: true, tracking: @view.letters_own, balance: false, max_lines: 0 },
      )
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.drawn_now()
  let t0 = t.time()
  // 1) Normal move over blank area -> Arrow
  t.fake.event_at = t0 + 2.0
  pointer_in(1, 50.0, 40.0, 0, 0, by=0, more=false)
  t.fake.event_at = -1.0
  assert_eq(t.cursor(), Arrow)

  // 2) Batched move (more=true) onto selectable text, ended by frame -> IBeam
  t.fake.event_at = t0 + 4.0
  pointer_in(1, 50.0, 92.0, 0, 0, by=0, more=true)
  t.fake.event_at = -1.0
  assert_true(moves_batched.val)
  t.advance(batch_frame_ms)
  t.draw()
  assert_false(moves_batched.val)
  assert_eq(t.cursor(), IBeam)

  // 3) Batched move (more=true) back onto blank area, ended by frame -> Arrow
  t.fake.event_at = t.time() + 2.0
  pointer_in(1, 50.0, 40.0, 0, 0, by=0, more=true)
  t.fake.event_at = -1.0
  assert_true(moves_batched.val)
  t.advance(batch_frame_ms)
  t.draw()
  assert_false(moves_batched.val)
  assert_eq(t.cursor(), Arrow)
}
