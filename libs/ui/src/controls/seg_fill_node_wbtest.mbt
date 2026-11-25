// A narrow page's choice preserves the layout of its labels and chevron as the room and font scale change.

///|
/// Options in a box `w` wide (12 from its sides), the one `chosen`, as nodes; drawn at rest.
fn seg_fill_drawn(w : Double, chosen : Int, labels : Array[String], scale? : Double = 1.0) -> Array[String] {
  let at = @signals.signal(chosen)
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w~, h=200.0, platform=2)
  t.set_font_scale(scale)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(b) {
      b.padding(Is((12.0, 20.0, 12.0, 0.0))) |> ignore
      seg_fill_node(b, fn() { labels }, fn() { at.get() }, fn(k) { at.set(k) }) |> ignore
    })
    |> ignore
  })
  t.run_for(@ui.move_most_ms)
  t.run_for(@ui.move_most_ms)
  seg_drawn(t)
}

///|
/// The label and chevron instances, rounded to a hundredth and independent of glyph atlas placement.
fn seg_drawn(t : @ui.Tester) -> Array[String] {
  let all = t.drawn_instances().filter(fn(a) { a[5] == 1.0 || a[5] == 10.0 || a[5] == 11.0 }).map(fn(a) {
    a
    .mapi(fn(j, x) {
      if a[5] == 1.0 && j == 12 {
        if x >= 16384.0 { "colour" } else { "mono" }
      } else if a[5] == 1.0 && j == 13 {
        "-"
      } else {
        ((x * 100.0).round() / 100.0).to_string()
      }
    })
    .join(",")
  })
  all.sort()
  all
}

///|
test "a narrow page's choice as nodes: each chosen, filling its room, at normal and larger words" {
  let three = ["不提示", "做完就提示", "按模型判断"]
  let five = ["全部", "自动", "关闭", "仅工作日", "每天提醒我"]
  for case in [(390.0, three, 1.0), (390.0, five, 1.0), (260.0, five, 1.0), (200.0, five, 1.0), (390.0, three, 2.0), (390.0, five, 1.5)] {
    let (w, labels, scale) = case
    for k in 0..<labels.length() {
      assert_true(seg_fill_drawn(w, k, labels, scale~).length() > 0, msg="\{w} \{labels.length()} at \{scale}, chosen \{k}")
    }
  }
}

///|
test "a narrow page's choice as nodes too narrow for its options side by side: only the chosen one is drawn" {
  let two = ["按天", "按周"]
  let three = ["不提示", "做完就提示", "按模型判断"]
  let cases = [(90.0, three, 1.0), (80.0, three, 1.5)]
  for w = 60; w <= 92; w = w + 2 {
    cases.push((w.to_double(), two, 2.0))
  }
  for case in cases {
    let (w, labels, scale) = case
    for k in 0..<labels.length() {
      let made = seg_fill_drawn(w, k, labels, scale~)
      assert_true(made.length() > 0, msg="\{Repr(case)} chosen \{k}")
      // (not side by side: no words of the others drawn)
      let drawn = @ui.view_tree().unwrap().drawn()
      for j, l in labels {
        if j != k {
          assert_true(!drawn.iter().any(fn(d) { d.words == l }), msg="\{Repr(case)}: a pick, \{l} not drawn")
        }
      }
    }
  }
}

///|
/// A choice of `labels` in a window `w` wide (12 from its sides, 20 from its top), the first chosen, as nodes;
/// `scrolled`, in a column that scrolls. Each choice made counted. At rest.
priv struct SegRig {
  t : @ui.Tester
  at : @signals.Signal[Int]
  chosen : Ref[Int]
}

///|
fn seg_rig(w : Double, labels : Array[String], scrolled? : Bool = false) -> SegRig {
  let at = @signals.signal(0)
  let chosen = Ref(0)
  let choose = fn(k : Int) {
    chosen.val += 1
    at.set(k)
  }
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w~, h=200.0, platform=2)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    let body = fn(b : @view.View) {
      b.padding(Is((12.0, 20.0, 12.0, 0.0))) |> ignore
      seg_fill_node(b, fn() { labels }, fn() { at.get() }, choose) |> ignore
    }
    if scrolled {
      root.box(fn(v) {
        v.height(Is(Some(180.0))) |> ignore
        v.scrolls(@view.Scroll::list(), fn(s) {
          s.box(body) |> ignore
          s.box(fn(tall) { tall.height(Is(Some(600.0))) |> ignore }) |> ignore
        })
        |> ignore
      })
      |> ignore
    } else {
      root.box(body) |> ignore
    }
  })
  t.run_for(@ui.move_most_ms)
  { t, at, chosen }
}

///|
/// What a finger does at a moment (ms after the first of it): down at an x, moved to a point, let go, called off; or
/// what changes about where it is drawn (the window resized, the system's size of words).
priv enum SegStep {
  Down(Double)
  Up
  Off
  Change((@ui.Tester) -> Unit)
}

///|
/// `steps` (each at its moment, from now) and what is drawn at each of `moments`, on one time line, in time order.
fn seg_drive(t : @ui.Tester, steps : Array[(Double, SegStep)], moments : Array[Double], grid? : Double = 0.0) -> Array[
  Array[String],
] raise {
  let t0 = t.time()
  let at : Array[Double] = []
  for s in steps {
    at.push(s.0)
  }
  for m in moments {
    at.push(m)
  }
  if grid > 0.0 {
    let last = at.fold(init=0.0, fn(a, b) { dmax(a, b) })
    let mut g = grid
    while g < last {
      at.push(g)
      g += grid
    }
  }
  at.sort()
  let out = []
  let mut where_ = (0.0, 20.0 + 17.0)
  let mut prev = -1.0
  for p in at {
    if p == prev {
      continue
    }
    prev = p
    assert_true(t0 + p >= t.time(), msg="the time line goes on: \{p} after \{t.time() - t0}")
    t.advance(t0 + p - t.time())
    assert_true(t.time() == t0 + p, msg="at \{p} as its steps come: \{t.time() - t0}")
    for s in steps {
      if s.0 == p {
        match s.1 {
          Down(x) => {
            where_ = (x, where_.1)
            t.touch(0, x, where_.1)
          }
          Up => t.touch(2, where_.0, where_.1)
          Off => t.touch(3, where_.0, where_.1)
          Change(f) => f(t)
        }
      }
    }
    t.frame_at(t0 + p)
    if moments.contains(p) {
      out.push(seg_drawn(t))
    }
  }
  out
}

///|
/// A rig made (seg_rig) and driven (seg_drive) at once: what is drawn at `moments`, how often one was chosen, the one
/// chosen.
fn seg_run(
  w : Double,
  labels : Array[String],
  steps : Array[(Double, SegStep)],
  moments : Array[Double],
  scrolled? : Bool = false,
  grid? : Double = 0.0,
) -> (Array[Array[String]], Int, Int) raise {
  let r = seg_rig(w, labels, scrolled~)
  let drawn = seg_drive(r.t, steps, moments, grid~)
  (drawn, r.chosen.val, r.at.get())
}

///|
let seg_three : Array[String] = ["不提示", "做完就提示", "按模型判断"]

///|
/// (the third's middle, 390 wide: 12 in, 2 into the track, its share of 362 a third)
let seg_third_x : Double = 12.0 + 2.0 + 362.0 / 3.0 * 2.5

///|
let seg_moments : Array[Double] = [16.0, 50.0, 100.0, 180.0, 300.0, 600.0]

///|
test "a narrow page's choice selects the pressed option once and keeps its label placement" {
  for held in [30.0, 250.0] {
    let steps = [(0.0, Down(seg_third_x)), (held, Up)]
    let (m, made_n, made_at) = seg_run(390.0, seg_three, steps, seg_moments)
    assert_eq((made_n, made_at), (1, 2), msg="held \{held}: the third chosen once")
    assert_true(m.length() == seg_moments.length())
  }
}

///|
test "a narrow page's thumb sent to either end stays in the track and slows to rest there, never stopped dead, on the display's frames" {
  if @ui.test_at_a_rate() {
    return
  }
  let rig = seg_rig(390.0, seg_three)
  let t = rig.t
  let (inside_l, inside_r) = (12.0 + 2.0, 12.0 + 2.0 + 362.0)
  let out : Array[String] = []
  t.each_frame(
    Some(fn() {
      for r in t.drawn_rects() {
        if (r.3 - (segmented_narrow_h - 2.0 * seg_inset)).abs() < 0.5 &&
          (r.0 < inside_l - 0.5 || r.0 + r.2 > inside_r + 0.5) {
          out.push("at \{t.time()}: \{r.0} to \{r.0 + r.2}")
        }
      }
    }),
  )
  let between = 8
  for i in 0..<between {
    for k in [2, 0] {
      t.advance(t.frame_period() * i.to_double() / between.to_double())
      guard t.find(seg_three[k]) is Some((x, y)) else { fail("no \{seg_three[k]}") }
      t.touch(0, x, y)
      t.touch(2, x, y)
      t.run_shown(@ui.move_most_ms)
    }
  }
  t.each_frame(None)
  assert_eq((rig.chosen.val, rig.at.get()), (2 * between, 0))
  assert_true(out.is_empty(), msg="the thumb out of the track's inside \{inside_l} to \{inside_r}: \{out.join("; ")}")
}

///|
test "a held narrow choice draws the liquid glass lens and respects reduced transparency" {
  let rig = seg_rig(390.0, seg_three)
  let t = rig.t
  assert_true(!t.drawn_glass().iter().any(fn(g) { g.4 == 6 }))
  t.touch(0, seg_third_x, 37.0)
  t.run_for(part_whole_ms)
  let lenses = t.drawn_instances().filter(fn(i) { i[5] == 6.0 })
  assert_eq(lenses.length(), 1)
  assert_eq(lenses[0][14], 0.0)
  assert_true(lenses[0][21] > 0.0)
  t.set_reduce_transparency(true)
  t.run_for(part_whole_ms)
  assert_true(!t.drawn_glass().iter().any(fn(g) { g.4 == 6 }))
  t.touch(2, seg_third_x, 37.0)
  t.run_for(part_whole_ms)
  assert_eq((rig.chosen.val, rig.at.get()), (1, 2))
}

///|
test "a segmented thumb follows the finger and selects on release below the track" {
  let quick_touch_ms = 80.0
  for scrolled in [false, true] {
    let rig = seg_rig(390.0, seg_three, scrolled~)
    let t = rig.t
    let (x, y, w, h) = t.get(Radio, label=seg_three[0]).rect
    let (end, _, end_w, _) = t.get(Radio, label=seg_three[2]).rect
    let from_x = x + w / 2.0
    let to_x = end + end_w / 2.0
    let at_y = y + h / 2.0
    let below = y + h + 12.0
    let lens = fn() { t.drawn_instances().filter(fn(a) { a[5] == 6.0 }) }
    t.touch(0, from_x, at_y)
    t.run_for(quick_touch_ms)
    assert_true(lens().is_empty())
    t.run_for(part_whole_ms)
    let before = lens()[0][0] + lens()[0][2] / 2.0
    t.touch(1, from_x + w / 4.0, at_y)
    t.run_for(part_whole_ms)
    let next = lens()[0][0] + lens()[0][2] / 2.0
    assert_true(next > before + 2.0 && next < x + w)
    t.touch(1, to_x, below)
    t.run_for(part_whole_ms)
    assert_eq((rig.chosen.val, rig.at.get()), (0, 0))
    let over_end = lens()
    assert_eq(over_end.length(), 1)
    let center = over_end[0][0] + over_end[0][2] / 2.0
    assert_true(center > end && center < end + end_w)
    t.touch(2, to_x, below)
    t.run_for(part_whole_ms)
    assert_eq((rig.chosen.val, rig.at.get()), (1, 2))
    assert_true(t.get(Radio, label=seg_three[2]).check is Some(On))
  }
}

///|
/// Five options of unlike widths: 300 wide fitted (their sides narrower); 360, laid out each its least or more; at 1.3
/// times the words, smaller.
let seg_five : Array[String] = ["全部", "自动", "关闭", "仅工作日", "每天提醒我"]

///|
test "a narrow page's choice as nodes: selects last option when resized or font-scaled mid-animation" {
  let moments = [30.0, 59.0, 60.0, 80.0, 120.0, 200.0, 400.0, 800.0]
  let x = 300.0 - 12.0 - 2.0 - 8.0
  let changes : Array[(String, (@ui.Tester) -> Unit)] = [
    ("resized", fn(t) { t.resize_next(360.0, 200.0) }),
    ("larger words", fn(t) { t.set_font_scale(1.3) }),
  ]
  for c in changes {
    let (what, change) = c
    let steps = [(0.0, Down(x)), (16.0, Up), (59.0, Change(change))]
    let (_, made_n, made_at) = seg_run(300.0, seg_five, steps, moments)
    assert_eq((made_n, made_at), (1, 4), msg="\{what}: the node's last chosen once")
  }
}

///|
test "a narrow page's choice as nodes: switches between side-by-side and narrow pick across resizes, label edits, and font scales" {
  let widths = [390.0, 150.0, 390.0, 300.0, 360.0]
  let at = @signals.signal(3)
  let labels = @signals.signal(seg_five)
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=390.0, h=200.0, platform=2)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(b) {
      b.padding(Is((12.0, 20.0, 12.0, 0.0))) |> ignore
      seg_fill_node(b, fn() { labels.get() }, fn() { at.get() }, fn(k) { at.set(k) }) |> ignore
    })
    |> ignore
  })
  t.run_for(@ui.move_most_ms)
  for w in widths {
    t.resize_next(w, 200.0)
    t.run_for(@ui.move_most_ms)
    t.run_for(@ui.move_most_ms)
    assert_true(seg_drawn(t).length() > 0, msg="\{w} wide")
    assert_eq(t.audit(), [], msg="\{w} wide audit")
  }
  // Mutating labels and font scale after resize round-trip keeps layout and selection intact.
  labels.set(["全天", "智能", "静默", "仅工作", "每日定时"])
  t.set_font_scale(1.3)
  t.run_for(@ui.move_most_ms)
  assert_true(seg_drawn(t).length() > 0, msg="after label change + 1.3x font scale")
  assert_eq(t.get(Radio, label="仅工作").check, Some(@ui.Check::On))
  assert_eq(t.audit(), [], msg="after label change + 1.3x audit")
  t.set_font_scale(1.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(t.audit(), [], msg="restored 1.0x audit")
}

///|
test "seg_fill_node: shared SegThumb rebuilt across hosts syncs bounds and lets keyboard switch to 3rd item" {
  let chosen = @signals.signal(0)
  let host_ver = @signals.signal(0)
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=390.0, h=200.0, platform=0)
  t.check_looks(false)
  @ui.set_view_app(
    fn(root) {
      let thumb = SegThumb::new(root, fn() { chosen.get() })
      root.each(
        fn() { [host_ver.get()] },
        fn(v) { v },
        fn(slot, _) {
          slot.padding(Is((12.0, 20.0, 12.0, 0.0))) |> ignore
          seg_fill_node(slot, fn() { seg_three }, fn() { chosen.get() }, fn(k) { chosen.set(k) }, thumb~) |> ignore
        },
        at_once=true,
      )
    },
    theme=ui_theme_now,
  )
  t.draw()
  t.run_for(@ui.move_most_ms)
  // Rebuild seg_fill_node on a fresh host sharing the same SegThumb.
  host_ver.set(1)
  t.draw()
  t.run_for(@ui.move_most_ms)
  // Keyboard Tab -> End jumps straight to the 3rd option (index 2).
  t.key(@ui.key_tab)
  t.draw()
  t.key(@ui.key_code_end)
  t.run_for(@ui.move_most_ms)
  assert_eq(chosen.get(), 2, msg="keyboard End must select 3rd item")
  assert_eq(t.get(Radio, label=seg_three[2]).check, Some(@ui.Check::On))
  let r2 = t.get(Radio, label=seg_three[2]).rect
  let lifted = @ui.tree_theme().lifted
  let thumbs = t.drawn_rects().filter(fn(d) { d.4 == lifted && (d.3 - r2.3).abs() < 0.5 })
  assert_eq(thumbs.length(), 1, msg="expected 1 lifted thumb after rebuild + keyboard End")
  let tcx = thumbs[0].0 + thumbs[0].2 / 2.0
  let r2cx = r2.0 + r2.2 / 2.0
  assert_true((tcx - r2cx).abs() < 1.0, msg="thumb center \{tcx} must align with 3rd item center \{r2cx}")
}

///|
test "seg_fill_node: entering narrow menu mid-drag cancels preview back to committed item with 0 choose callbacks" {
  let rig = seg_rig(390.0, seg_three)
  let t = rig.t
  let r0 = t.get(Radio, label=seg_three[0]).rect
  let r2 = t.get(Radio, label=seg_three[2]).rect
  let y = r0.1 + r0.3 / 2.0
  let c0x = r0.0 + r0.2 / 2.0
  let c2x = r2.0 + r2.2 / 2.0
  // Start finger drag toward option 2 without releasing.
  t.touch(0, c0x, y)
  t.run_for(part_whole_ms)
  t.touch(1, c2x, y)
  t.run_for(part_whole_ms / 2.0)
  assert_eq((rig.chosen.val, rig.at.get()), (0, 0), msg="mid-drag must not commit yet")
  // Shrink into narrow menu mode mid-drag -> must cancel_to(committed) with 0 choose callbacks.
  t.resize_next(90.0, 200.0)
  t.run_for(@ui.move_most_ms)
  assert_eq((rig.chosen.val, rig.at.get()), (0, 0), msg="entering menu mid-drag must fire 0 choose callbacks")
  assert_eq(t.drawn_glass().length(), 0, msg="narrow menu must clear held lens")
  // Expand back to 390pt -> thumb center must sit on committed option 0, Radio states intact, 0 callbacks.
  t.touch(3, c2x, y)
  t.resize_next(390.0, 200.0)
  t.run_for(@ui.move_most_ms)
  assert_eq((rig.chosen.val, rig.at.get()), (0, 0), msg="expanding back must still have 0 choose callbacks")
  assert_eq(t.get(Radio, label=seg_three[0]).check, Some(@ui.Check::On))
  assert_eq(t.get(Radio, label=seg_three[1]).check, Some(@ui.Check::Off))
  assert_eq(t.get(Radio, label=seg_three[2]).check, Some(@ui.Check::Off))
  let r0_after = t.get(Radio, label=seg_three[0]).rect
  let lifted = @ui.tree_theme().lifted
  let thumbs = t.drawn_rects().filter(fn(d) { d.4 == lifted && (d.3 - r0_after.3).abs() < 0.5 })
  assert_eq(thumbs.length(), 1, msg="expected 1 lifted thumb after expanding back")
  let tcx = thumbs[0].0 + thumbs[0].2 / 2.0
  let r0cx = r0_after.0 + r0_after.2 / 2.0
  assert_true((tcx - r0cx).abs() < 1.0, msg="thumb center \{tcx} must return to committed option 0 (\{r0cx})")
}

///|
test "seg_fill_node: finger drag emits exactly one TextHandleMove haptic per crossed segment" {
  let rig = seg_rig(390.0, seg_three)
  let t = rig.t
  let r0 = t.get(Radio, label=seg_three[0]).rect
  let r1 = t.get(Radio, label=seg_three[1]).rect
  let r2 = t.get(Radio, label=seg_three[2]).rect
  let y = r0.1 + r0.3 / 2.0
  let c0x = r0.0 + r0.2 / 2.0
  let c1x = r1.0 + r1.2 / 2.0
  let c2x = r2.0 + r2.2 / 2.0
  let count_ticks = fn() { t.haptics().filter(fn(h) { h == @ui.Haptic::TextHandleMove }).length() }
  let before = count_ticks()
  t.touch(0, c0x, y)
  t.run_for(part_whole_ms)
  assert_eq(count_ticks() - before, 0, msg="holding on already-selected option 0 emits 0 ticks")
  // Multiple continuous moves inside option 1 emit only 1 tick total.
  t.touch(1, c1x - 10.0, y)
  t.frame()
  t.touch(1, c1x, y)
  t.frame()
  t.touch(1, c1x + 10.0, y)
  t.frame()
  assert_eq(count_ticks() - before, 1, msg="crossing into option 1 must emit exactly 1 TextHandleMove")
  // Multiple continuous moves inside option 2 emit 1 more tick (total 2).
  t.touch(1, c2x - 8.0, y)
  t.frame()
  t.touch(1, c2x, y)
  t.frame()
  assert_eq(count_ticks() - before, 2, msg="crossing into option 2 must emit exactly 1 more TextHandleMove")
  // Releasing on option 2 must NOT double-fire haptic since option 2 was already felt.
  t.touch(2, c2x, y)
  t.run_for(@ui.move_most_ms)
  assert_eq(count_ticks() - before, 2, msg="releasing on already-felt option 2 must not duplicate haptic")
  assert_eq((rig.chosen.val, rig.at.get()), (1, 2))
}

///|
test "a narrow page's choice as nodes: tapped, held, cancelled" {
  let second = 12.0 + 2.0 + 362.0 / 3.0 * 1.5
  let cases : Array[(String, Bool, Array[(Double, SegStep)], Int)] = [
    ("tapped", false, [(0.0, Down(second)), (30.0, Up)], 1),
    ("held still, let go", false, [(0.0, Down(second)), (900.0, Up)], 1),
    ("called off", false, [(0.0, Down(second)), (100.0, Off)], 0),
  ]
  for c in cases {
    let (what, scrolled, steps, times) = c
    let (_, made_n, _) = seg_run(390.0, seg_three, steps, [1000.0], scrolled~)
    assert_eq(made_n, times, msg="\{what}: chosen \{made_n} times, want \{times}")
  }
}

///|
test "seg_fill_node: liquid glass lens animation during drag causes zero relayout (laid == 0)" {
  let r = seg_rig(390.0, seg_three)
  r.t.check_looks(false)
  let second = 12.0 + 2.0 + 362.0 / 3.0 * 1.5
  let y = 20.0 + 17.0
  let lens_mount_ms = dur_ms / 4.0
  let lens_step_ms = @ui.move_most_ms / 2.0
  r.t.touch(0, second, y)
  r.t.touch(1, seg_third_x, y)
  r.t.run_for(lens_mount_ms)
  r.t.tree_frames_from_now()
  r.t.run_for(lens_step_ms)
  let frames = r.t.tree_frames()
  assert_true(frames.length() > 0, msg="expected animation frames while seg_fill_node lens scales")
  assert_true(
    frames.iter().all(fn(f) { f.laid == 0 }),
    msg="seg_fill_node lens animation must not trigger relayout: \{Repr(frames.map(fn(f) { f.laid }))}",
  )
  r.t.touch(2, seg_third_x, y)
  r.t.run_for(@ui.move_most_ms * 2.0)
}

///|
fn seg_rgb_near(inst : Array[Double], color : Int64) -> Bool {
  let r = ((color >> 24) & 0xFFL).to_double() / 255.0
  let g = ((color >> 16) & 0xFFL).to_double() / 255.0
  let b = ((color >> 8) & 0xFFL).to_double() / 255.0
  let tol = 1.0 / 255.0 + 0.0001
  (inst[8] - r).abs() <= tol && (inst[9] - g).abs() <= tol && (inst[10] - b).abs() <= tol
}

///|
test "seg_fill_node: SegThumb::new with chosen >= 2 aligns resting capsule on first draw before clock advances" {
  let chosen = @signals.signal(2)
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=390.0, h=200.0, platform=2)
  t.check_looks(false)
  @ui.set_view_app(
    fn(root) {
      let thumb = SegThumb::new(root, fn() { chosen.get() })
      root.box(fn(b) {
        b.padding(Is((12.0, 20.0, 12.0, 0.0))) |> ignore
        seg_fill_node(b, fn() { seg_three }, fn() { chosen.get() }, fn(k) { chosen.set(k) }, thumb~) |> ignore
      })
      |> ignore
    },
    theme=ui_theme_now,
  )
  t.draw()
  let r2 = t.get(Radio, label=seg_three[2]).rect
  let lifted = @ui.tree_theme().lifted
  let thumbs = t.drawn_rects().filter(fn(d) { d.4 == lifted && (d.3 - r2.3).abs() < 0.5 })
  assert_eq(thumbs.length(), 1, msg="expected 1 lifted thumb on first draw")
  let tcx = thumbs[0].0 + thumbs[0].2 / 2.0
  let r2cx = r2.0 + r2.2 / 2.0
  assert_true((tcx - r2cx).abs() < 0.5, msg="first-draw thumb center \{tcx} must align with 3rd radio center \{r2cx}")
}

///|
test "seg_fill_node: unmounting shared SegThumb host mid-drag cancels cleanly on new host with 0 callbacks and 0 lens" {
  let chosen = @signals.signal(0)
  let host_ver = @signals.signal(0)
  let callbacks = Ref(0)
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=390.0, h=200.0, platform=2)
  t.check_looks(false)
  @ui.set_view_app(
    fn(root) {
      let thumb = SegThumb::new(root, fn() { chosen.get() })
      root.each(
        fn() { [host_ver.get()] },
        fn(v) { v },
        fn(slot, _) {
          slot.padding(Is((12.0, 20.0, 12.0, 0.0))) |> ignore
          seg_fill_node(
            slot,
            fn() { seg_three },
            fn() { chosen.get() },
            fn(k) {
              callbacks.val += 1
              chosen.set(k)
            },
            thumb~,
          )
          |> ignore
        },
        at_once=true,
      )
    },
    theme=ui_theme_now,
  )
  t.draw()
  t.run_for(@ui.move_most_ms)
  let r0 = t.get(Radio, label=seg_three[0]).rect
  let r2 = t.get(Radio, label=seg_three[2]).rect
  let y = r0.1 + r0.3 / 2.0
  t.touch(0, r0.0 + r0.2 / 2.0, y)
  t.run_for(part_whole_ms)
  t.touch(1, r2.0 + r2.2 / 2.0, y)
  t.run_for(part_whole_ms / 2.0)
  assert_true(t.drawn_glass().length() > 0, msg="lens should be active mid-drag before host swap")
  // Unmount old host and mount fresh host while finger is still held.
  host_ver.set(1)
  t.draw()
  t.run_for(@ui.move_most_ms * 2.0)
  assert_eq(callbacks.val, 0, msg="unmounting mid-drag must fire 0 choose callbacks")
  assert_eq(chosen.get(), 0, msg="chosen must remain committed item 0")
  assert_eq(t.drawn_glass().length(), 0, msg="new host must not retain permanent held lens")
  let r0_new = t.get(Radio, label=seg_three[0]).rect
  let lifted = @ui.tree_theme().lifted
  let thumbs = t.drawn_rects().filter(fn(d) { d.4 == lifted && (d.3 - r0_new.3).abs() < 0.5 })
  assert_eq(thumbs.length(), 1, msg="expected 1 resting thumb on new host")
  let tcx = thumbs[0].0 + thumbs[0].2 / 2.0
  let r0cx = r0_new.0 + r0_new.2 / 2.0
  assert_true((tcx - r0cx).abs() < 1.0, msg="thumb center \{tcx} must return to committed radio 0 (\{r0cx})")
}

///|
test "seg_fill_node: switching shared SegThumb host mid-animation continues smoothly to target" {
  let chosen = @signals.signal(0)
  let host_ver = @signals.signal(0)
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=390.0, h=200.0, platform=0)
  t.check_looks(false)
  @ui.set_view_app(
    fn(root) {
      let thumb = SegThumb::new(root, fn() { chosen.get() })
      root.each(
        fn() { [host_ver.get()] },
        fn(v) { v },
        fn(slot, _) {
          slot.padding(Is((12.0, 20.0, 12.0, 0.0))) |> ignore
          seg_fill_node(slot, fn() { seg_three }, fn() { chosen.get() }, fn(k) { chosen.set(k) }, thumb~) |> ignore
        },
        at_once=true,
      )
    },
    theme=ui_theme_now,
  )
  t.draw()
  t.run_for(@ui.move_most_ms)
  let r0 = t.get(Radio, label=seg_three[0]).rect
  let r2 = t.get(Radio, label=seg_three[2]).rect
  let r0cx = r0.0 + r0.2 / 2.0
  let r2cx = r2.0 + r2.2 / 2.0
  let lifted = @ui.tree_theme().lifted
  let thumb_cx = fn() raise {
    let thumbs = t.drawn_rects().filter(fn(d) { d.4 == lifted && (d.3 - r0.3).abs() < 0.5 })
    assert_eq(thumbs.length(), 1, msg="expected 1 thumb rect")
    thumbs[0].0 + thumbs[0].2 / 2.0
  }
  chosen.set(2)
  t.run_for(part_whole_ms / 2.0)
  let mid_cx = thumb_cx()
  assert_true(mid_cx > r0cx + 5.0 && mid_cx < r2cx - 5.0, msg="expected mid-flight thumb center, got \{mid_cx}")
  // Swap host mid-animation: thumb must keep moving from mid-flight rather than jumping back or stalling.
  host_ver.set(1)
  t.draw()
  let swapped_cx = thumb_cx()
  assert_true(swapped_cx > r0cx + 5.0, msg="host swap must not reset thumb back to start (\{swapped_cx})")
  t.run_for(@ui.move_most_ms)
  let end_cx = thumb_cx()
  assert_true((end_cx - r2cx).abs() < 1.0, msg="thumb center \{end_cx} must finish at radio 2 (\{r2cx})")
}

///|
test "seg_fill_node: controlled sync rejection reverts capsule to committed radio (finger & mouse)" {
  for plat in [2, 0] {
    let chosen = @signals.signal(0)
    let requested = Ref(-1)
    let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=390.0, h=200.0, platform=plat)
    t.check_looks(false)
    @ui.set_view_app(
      fn(root) {
        root.box(fn(b) {
          b.padding(Is((12.0, 20.0, 12.0, 0.0))) |> ignore
          seg_fill_node(b, fn() { seg_three }, fn() { chosen.get() }, fn(k) { requested.val = k }) |> ignore
        })
        |> ignore
      },
      theme=ui_theme_now,
    )
    t.draw()
    t.run_for(@ui.move_most_ms)
    let r0 = t.get(Radio, label=seg_three[0]).rect
    let r2 = t.get(Radio, label=seg_three[2]).rect
    let y = r0.1 + r0.3 / 2.0
    let c0x = r0.0 + r0.2 / 2.0
    let c2x = r2.0 + r2.2 / 2.0
    if plat == 2 {
      t.touch(0, c0x, y)
      t.run_for(part_whole_ms)
      t.touch(1, c2x, y)
      t.run_for(part_whole_ms / 2.0)
      t.touch(2, c2x, y)
    } else {
      t.press_at(c0x, y)
      t.move_to(c2x, y)
      t.run_for(part_whole_ms)
      t.release(c2x, y)
    }
    t.run_for(@ui.move_most_ms * 2.0)
    assert_eq(requested.val, 2, msg="plat=\{plat}: on_select must be called with 2")
    assert_eq(chosen.get(), 0, msg="plat=\{plat}: sync rejection keeps chosen at 0")
    assert_eq(t.get(Radio, label=seg_three[0]).check, Some(@ui.Check::On))
    assert_eq(t.drawn_glass().length(), 0, msg="plat=\{plat}: lens must clear after rejection settle")
    let lifted = @ui.tree_theme().lifted
    let thumbs0 = t.drawn_rects().filter(fn(d) { d.4 == lifted && (d.3 - r0.3).abs() < 0.5 })
    assert_eq(thumbs0.length(), 1)
    let tcx0 = thumbs0[0].0 + thumbs0[0].2 / 2.0
    let r0cx = r0.0 + r0.2 / 2.0
    assert_true((tcx0 - r0cx).abs() < 1.0, msg="plat=\{plat}: rejected capsule \{tcx0} must align with item 0 (\{r0cx})")
  }
}

///|
test "seg_fill_node: controlled optimistic async pattern stays steady without retreating (finger & mouse)" {
  for plat in [2, 0] {
    let chosen = @signals.signal(0)
    let pending : @signals.Signal[Int?] = @signals.signal(None)
    let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=390.0, h=200.0, platform=plat)
    t.check_looks(false)
    @ui.set_view_app(
      fn(root) {
        root.box(fn(b) {
          b.padding(Is((12.0, 20.0, 12.0, 0.0))) |> ignore
          seg_fill_node(
            b,
            fn() { seg_three },
            fn() { pending.get().unwrap_or(chosen.get()) },
            fn(k) { pending.set(Some(k)) },
          )
          |> ignore
        })
        |> ignore
      },
      theme=ui_theme_now,
    )
    t.draw()
    t.run_for(@ui.move_most_ms)
    let r0 = t.get(Radio, label=seg_three[0]).rect
    let r2 = t.get(Radio, label=seg_three[2]).rect
    let y = r0.1 + r0.3 / 2.0
    let c0x = r0.0 + r0.2 / 2.0
    let c2x = r2.0 + r2.2 / 2.0
    if plat == 2 {
      t.touch(0, c0x, y)
      t.run_for(part_whole_ms)
      t.touch(1, c2x, y)
      t.run_for(part_whole_ms / 2.0)
      t.touch(2, c2x, y)
    } else {
      t.press_at(c0x, y)
      t.move_to(c2x, y)
      t.run_for(part_whole_ms)
      t.release(c2x, y)
    }
    let lifted = @ui.tree_theme().lifted
    let samples = Ref(0)
    let last_cx = Ref(-1.0)
    let retreated : Array[String] = []
    t.each_frame(
      Some(fn() {
        let mut frame_cx : Double? = None
        for d in t.drawn_rects() {
          if d.4 == lifted && (d.3 - r2.3).abs() < 0.5 {
            frame_cx = Some(d.0 + d.2 / 2.0)
            break
          }
        }
        if frame_cx is None {
          for inst in t.drawn_instances() {
            if inst[5] == 6.0 && inst[14] == 0.0 {
              frame_cx = Some(inst[0] + inst[2] / 2.0)
              break
            }
          }
        }
        match frame_cx {
          Some(cx) => {
            samples.val += 1
            last_cx.val = cx
            if cx < r2.0 {
              retreated.push("plat=\{plat} t=\{t.time()} cx=\{cx} < r2.x=\{r2.0}")
            }
          }
          None => ()
        }
      }),
    )
    t.run_for(part_whole_ms / 2.0)
    t.each_frame(None)
    assert_true(samples.val > 0, msg="plat=\{plat}: must observe at least 1 capsule/lens frame during async wait")
    assert_true(retreated.is_empty(), msg="plat=\{plat}: optimistic async must not bounce back: \{retreated.join("; ")}")
    let r2cx = r2.0 + r2.2 / 2.0
    assert_true((last_cx.val - r2cx).abs() < 12.0, msg="plat=\{plat}: thumb \{last_cx.val} must stay near item 2 (\{r2cx})")
    // Server confirms and pending clears -> stays cleanly aligned with item 2 and 0 glass.
    chosen.set(2)
    pending.set(None)
    t.run_for(@ui.move_most_ms * 2.0)
    assert_eq(t.drawn_glass().length(), 0, msg="plat=\{plat}: lens must clear after settle")
    let thumbs2 = t.drawn_rects().filter(fn(d) { d.4 == lifted && (d.3 - r2.3).abs() < 0.5 })
    assert_eq(thumbs2.length(), 1)
    let tcx2 = thumbs2[0].0 + thumbs2[0].2 / 2.0
    assert_true((tcx2 - r2cx).abs() < 1.0, msg="plat=\{plat}: settled thumb must align with item 2 (\{tcx2} vs \{r2cx})")
  }
}

///|
test "seg_fill_node: synchronous on_select redirect moves thumb to redirected item" {
  let chosen = @signals.signal(0)
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=390.0, h=200.0, platform=2)
  t.check_looks(false)
  @ui.set_view_app(
    fn(root) {
      root.box(fn(b) {
        b.padding(Is((12.0, 20.0, 12.0, 0.0))) |> ignore
        // Synchronously redirect any selection request to item 1.
        seg_fill_node(b, fn() { seg_three }, fn() { chosen.get() }, fn(_) { chosen.set(1) }) |> ignore
      })
      |> ignore
    },
    theme=ui_theme_now,
  )
  t.draw()
  t.run_for(@ui.move_most_ms)
  let r0 = t.get(Radio, label=seg_three[0]).rect
  let r1 = t.get(Radio, label=seg_three[1]).rect
  let r2 = t.get(Radio, label=seg_three[2]).rect
  let y = r0.1 + r0.3 / 2.0
  t.touch(0, r0.0 + r0.2 / 2.0, y)
  t.run_for(part_whole_ms)
  t.touch(1, r2.0 + r2.2 / 2.0, y)
  t.run_for(part_whole_ms / 2.0)
  t.touch(2, r2.0 + r2.2 / 2.0, y)
  t.run_for(@ui.move_most_ms * 2.0)
  assert_eq(chosen.get(), 1)
  assert_eq(t.drawn_glass().length(), 0, msg="lens must clear after redirect settle")
  let lifted = @ui.tree_theme().lifted
  let thumbs1 = t.drawn_rects().filter(fn(d) { d.4 == lifted && (d.3 - r1.3).abs() < 0.5 })
  assert_eq(thumbs1.length(), 1)
  let tcx1 = thumbs1[0].0 + thumbs1[0].2 / 2.0
  let r1cx = r1.0 + r1.2 / 2.0
  assert_true((tcx1 - r1cx).abs() < 1.0, msg="redirected commit must align with item 1 (\{tcx1} vs \{r1cx})")
}

///|
test "seg_fill_node: mouse drag continuously interpolates label ink before and after release" {
  let chosen = @signals.signal(0)
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=390.0, h=200.0, platform=0)
  t.check_looks(false)
  @ui.set_view_app(
    fn(root) {
      root.box(fn(b) {
        b.padding(Is((12.0, 20.0, 12.0, 0.0))) |> ignore
        seg_fill_node(b, fn() { seg_three }, fn() { chosen.get() }, fn(k) { chosen.set(k) }) |> ignore
      })
      |> ignore
    },
    theme=ui_theme_now,
  )
  t.draw()
  t.run_for(@ui.move_most_ms)
  let r0 = t.get(Radio, label=seg_three[0]).rect
  let r1 = t.get(Radio, label=seg_three[1]).rect
  let y = r0.1 + r0.3 / 2.0
  let c0x = r0.0 + r0.2 / 2.0
  let c1x = r1.0 + r1.2 / 2.0
  let check_glyphs = fn(rect : (Double, Double, Double, Double), expected : Int64, label : String) raise {
    let glyphs = t
      .drawn_instances()
      .filter(fn(a) {
        if a[5] != 1.0 {
          return false
        }
        let gx = a[0] + a[2] / 2.0
        let gy = a[1] + a[3] / 2.0
        gx >= rect.0 && gx <= rect.0 + rect.2 && gy >= rect.1 && gy <= rect.1 + rect.3
      })
    assert_true(glyphs.length() > 0, msg="expected glyphs in \{label}")
    for g in glyphs {
      assert_true(seg_rgb_near(g, expected), msg="\{label} glyph RGB mismatch")
    }
  }
  // Press item 0 and drag to item 1 center without releasing.
  t.press_at(c0x, y)
  t.move_to(c1x, y)
  t.run_for(@ui.move_most_ms)
  assert_eq(chosen.get(), 0, msg="must not commit before mouse release")
  check_glyphs(r1, theme().p.text, "item 1 while held")
  check_glyphs(r0, theme().p.muted, "item 0 while held")
  // Release and verify ink stays matched after commit.
  t.release(c1x, y)
  t.run_for(@ui.move_most_ms)
  assert_eq(chosen.get(), 1)
  check_glyphs(r1, theme().p.text, "item 1 after release")
  check_glyphs(r0, theme().p.muted, "item 0 after release")
}

///|
test "seg_fill_node: side-by-side and narrow menu track colors match identically in light and dark modes" {
  for dark in [false, true] {
    set_dark(Some(dark))
    let expected = @glass.ctrl_seg_embedded_track_ink()
    let rig = seg_rig(390.0, seg_three)
    let t = rig.t
    let wide_tracks = t.drawn_rects().filter(fn(r) { (r.3 - segmented_narrow_h).abs() < 0.5 && r.4 == expected })
    assert_eq(wide_tracks.length(), 1, msg="dark=\{dark}: side-by-side track must use ctrl_seg_embedded_track_ink")
    t.resize_next(90.0, 200.0)
    t.run_for(@ui.move_most_ms)
    let menu_tracks = t.drawn_rects().filter(fn(r) { (r.3 - segmented_narrow_h).abs() < 0.5 && r.4 == expected })
    assert_eq(menu_tracks.length(), 1, msg="dark=\{dark}: narrow menu track must use identical ctrl_seg_embedded_track_ink")
    assert_eq(wide_tracks[0].4, menu_tracks[0].4, msg="dark=\{dark}: wide and menu track colors must be identical")
  }
  set_dark(None)
}

///|
test "seg_fill_node: sparse finger jump across multiple segments emits one TextHandleMove per crossed step" {
  let rig = seg_rig(390.0, seg_three)
  let t = rig.t
  let r0 = t.get(Radio, label=seg_three[0]).rect
  let r2 = t.get(Radio, label=seg_three[2]).rect
  let y = r0.1 + r0.3 / 2.0
  let c0x = r0.0 + r0.2 / 2.0
  let c2x = r2.0 + r2.2 / 2.0
  let count_ticks = fn() { t.haptics().filter(fn(h) { h == @ui.Haptic::TextHandleMove }).length() }
  let before = count_ticks()
  t.touch(0, c0x, y)
  t.run_for(part_whole_ms)
  assert_eq(count_ticks() - before, 0, msg="holding on initial item 0 emits 0 ticks")
  // Single sparse Moved directly from 0 to 2 -> 2 ticks.
  t.touch(1, c2x, y)
  t.frame()
  assert_eq(count_ticks() - before, 2, msg="single jump 0 -> 2 must emit 2 TextHandleMove haptics")
  // Single sparse Moved directly from 2 back to 0 -> +2 ticks (total 4).
  t.touch(1, c0x, y)
  t.frame()
  assert_eq(count_ticks() - before, 4, msg="single jump 2 -> 0 must emit 2 more TextHandleMove haptics")
  // Release on 0 -> still 4 (no extra tick).
  t.touch(2, c0x, y)
  t.run_for(@ui.move_most_ms)
  assert_eq(count_ticks() - before, 4, msg="releasing on 0 must not emit extra haptic")
}
