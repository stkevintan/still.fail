// Ported from Kyant0/AndroidLiquidGlass (Apache-2.0): catalog/utils/DampedDragAnimation.kt. A value dragged along a
// range and the glass that follows it: the value by a stiff spring (1, 1000), how fast it goes by a soft one (0.5, 300),
// how far it is held (1, 1000) and how large it is drawn across and down (0.6 and 0.7, 250), each a closed-form way of
// mbui's (@motion.NodeWay), set off from the moment of its cause and drawn where it is at the moment it is drawn: no
// frame loop, so a run is the same at any frame rate.
//
// Kotlin's coroutines become moments on the node's timeline: `release` lets go once the value is within 2.5% of its
// range of where it goes (snapshotFlow's filter), at the moment its way says it is (worked out from its way, not
// watched); the speed is the finger's (the value's change over the time between two drags, VelocityTracker's), eased
// by its spring, and eased to nothing at the moment the value comes to rest.

///|
/// The value spring's (DampedDragAnimation's valueAnimationSpec) at `threshold`.
fn value_spring(threshold : Double) -> @motion.Spec {
  @motion.spring(ratio=1.0, stiffness=1000.0, threshold~) // det-ok(motion-spring): DampedDragAnimation.kt valueAnimationSpec, ported 1:1
}

///|
/// The speed's spring (velocityAnimationSpec): soft, at rest within ten times the value's threshold.
fn speed_spring(threshold : Double) -> @motion.Spec {
  @motion.spring(ratio=0.5, stiffness=300.0, threshold=threshold * 10.0) // det-ok(motion-spring): DampedDragAnimation.kt velocityAnimationSpec, ported 1:1
}

///|
/// A value dragged along `lo` … `hi` and the glass that follows it (DampedDragAnimation): bound to the node whose
/// timeline its ways run on (`attach`), then pressed, dragged and let go by its control.
pub struct DampedDrag {
  priv mut lo : Double
  priv mut hi : Double
  priv threshold : Double
  priv rest_scale : Double
  priv held_scale : Double
  priv value : @motion.NodeWay
  priv speed : @motion.NodeWay
  priv press : @motion.NodeWay
  priv scale_x : @motion.NodeWay
  priv scale_y : @motion.NodeWay
  priv node : Ref[@view.View?]
  priv last : Ref[(Double, Double)?]
  priv letting_go : Ref[(() -> Unit)?]
  priv stilling : Ref[(() -> Unit)?]
}

///|
/// At `initial` along `lo` … `hi`, resting within `threshold`, drawn `rest_scale` times as large at rest and
/// `held_scale` held.
pub fn DampedDrag::new(
  initial : Double,
  lo~ : Double,
  hi~ : Double,
  threshold? : Double = 0.001,
  rest_scale? : Double = 1.0,
  held_scale~ : Double,
) -> DampedDrag {
  let v = clamp(initial, lo, hi)
  {
    lo,
    hi,
    threshold,
    rest_scale,
    held_scale,
    value: @motion.NodeWay::new(v),
    speed: @motion.NodeWay::new(0.0),
    press: @motion.NodeWay::new(0.0),
    scale_x: @motion.NodeWay::new(rest_scale),
    scale_y: @motion.NodeWay::new(rest_scale),
    node: Ref(None),
    last: Ref(None),
    letting_go: Ref(None),
    stilling: Ref(None),
  }
}

///|
/// Its ways run on `n`'s timeline from now on (its control's node).
pub fn DampedDrag::attach(self : DampedDrag, n : @view.View) -> Unit {
  self.node.val = Some(n)
}

///|
/// Attach `self` to `n` only when it does not already have a live host view.
fn DampedDrag::attach_if_needed(self : DampedDrag, n : @view.View) -> Unit {
  match self.node.val {
    Some(cur) if cur.alive() => ()
    _ => self.node.val = Some(n)
  }
}

///|
/// Update the drag bounds (for controls whose item count may change dynamically).
pub fn DampedDrag::set_bounds(self : DampedDrag, lo~ : Double, hi~ : Double) -> Unit {
  self.lo = lo
  self.hi = hi
}

///|
fn DampedDrag::at(self : DampedDrag) -> @view.View {
  match self.node.val {
    Some(n) => n
    None => @halt.saying("sf/glass: a DampedDrag moved before it was attached to its node")
  }
}

///|
/// Where its value is as `n` is drawn.
pub fn DampedDrag::value(self : DampedDrag, n : @view.View) -> Double {
  self.value.shown(n)
}

///|
/// How far along its range its value is as `n` is drawn (0 at `lo`, 1 at `hi`).
pub fn DampedDrag::progress(self : DampedDrag, n : @view.View) -> Double {
  let span = self.hi - self.lo
  if span <= 0.0 {
    0.0
  } else {
    (self.value.shown(n) - self.lo) / span
  }
}

///|
/// Where its value goes (targetValue), followed.
pub fn DampedDrag::target(self : DampedDrag) -> Double {
  self.value.target()
}

///|
/// How far it is held as `n` is drawn (pressProgress: 0 at rest, 1 held).
pub fn DampedDrag::pressed(self : DampedDrag, n : @view.View) -> Double {
  self.press.shown(n)
}

///|
/// Whether the lens press target is currently raised (true on the cause frame of `press` / `animate_to`).
pub fn DampedDrag::pressing(self : DampedDrag) -> Bool {
  self.press.target() > 0.001
}

///|
/// How fast its value goes as `n` is drawn, in its ranges a second (velocity).
pub fn DampedDrag::velocity(self : DampedDrag, n : @view.View) -> Double {
  self.speed.shown(n)
}

///|
/// How large its glass is drawn across and down as `n` is drawn, squeezed by how fast it goes (the catalog's
/// layerBlock: its speed divided by `per`, 50 for the toggle and 10 for the slider and the tabs; across
/// `scaleX / (1 - clamp(v × 0.75, ±0.2))`, down `scaleY × (1 - clamp(v × 0.25, ±0.2))`).
pub fn DampedDrag::jelly(self : DampedDrag, n : @view.View, per : Double) -> (Double, Double) {
  let v = self.speed.shown(n) / per
  let sx = self.scale_x.shown(n) / (1.0 - clamp(v * 0.75, -0.2, 0.2))
  let sy = self.scale_y.shown(n) * (1.0 - clamp(v * 0.25, -0.2, 0.2))
  (sx, sy)
}

///|
/// Held (press): its glass comes up and grows, its speed tracked anew.
pub fn DampedDrag::press(self : DampedDrag) -> Unit {
  let n = self.at()
  self.last.val = None
  self.cancel_release()
  self.press.go(n, 1.0, @motion.backdrop_press_spring)
  self.scale_x.go(n, self.held_scale, @motion.backdrop_scale_x_spring)
  self.scale_y.go(n, self.held_scale, @motion.backdrop_scale_y_spring)
}

///|
fn DampedDrag::cancel_release(self : DampedDrag) -> Unit {
  match self.letting_go.val {
    Some(f) => {
      self.letting_go.val = None
      f()
    }
    None => ()
  }
}

///|
/// Let go (release): its glass goes down and back to its size once its value is within 2.5% of its range of where it
/// goes, at once where it is already.
pub fn DampedDrag::release(self : DampedDrag) -> Unit {
  let n = self.at()
  self.cancel_release()
  let now = n.cause_at()
  let within = (self.hi - self.lo) * 0.025
  let aim = self.value.target()
  let near = fn(t : Double) { (self.value.value_at(t) - aim).abs() < within }
  let down = fn() {
    self.press.go(n, 0.0, @motion.backdrop_press_spring)
    self.scale_x.go(n, self.rest_scale, @motion.backdrop_scale_x_spring)
    self.scale_y.go(n, self.rest_scale, @motion.backdrop_scale_y_spring)
  }
  if near(now) || !self.value.goes_at(now) {
    down()
    return
  }
  // (the first whole millisecond its way is near, read off the way itself: it ends near, at the latest)
  let end = self.value.end()
  let mut t = now
  while t < end && !near(t) {
    t += 1.0
  }
  let stop = n.at_moment(t, fn() {
    self.letting_go.val = None
    down()
  })
  self.letting_go.val = Some(stop)
}

///|
/// Its value sent towards `v` (updateValue, held within its range): followed by its spring, and its speed by the
/// change since the last such over the time between them.
pub fn DampedDrag::update_value(self : DampedDrag, v : Double, spec? : @motion.Spec) -> Unit {
  let n = self.at()
  let to = clamp(v, self.lo, self.hi)
  let now = n.cause_at()
  let span = self.hi - self.lo
  match self.last.val {
    Some((was, at)) if now > at && span > 0.0 => {
      let fast = (to - was) / ((now - at) / 1000.0) / span
      self.speed.go(n, fast, speed_spring(self.threshold))
    }
    _ => ()
  }
  self.last.val = Some((to, now))
  let sp = match spec {
    Some(s) => s
    None => value_spring(self.threshold)
  }
  self.value.go(n, to, sp)
  self.still_at_rest(n)
}

///|
/// Its speed eased to nothing at the moment its value comes to rest (VelocityTracker reading a still value).
fn DampedDrag::still_at_rest(self : DampedDrag, n : @view.View) -> Unit {
  match self.stilling.val {
    Some(f) => f()
    None => ()
  }
  let end = self.value.end()
  self.stilling.val = Some(
    n.at_moment(end, fn() {
      self.stilling.val = None
      self.last.val = None
      self.speed.go(n, 0.0, speed_spring(self.threshold))
    }),
  )
}

///|
/// Sent to `v` as by a hand that pressed it there and let go (animateToValue): held, its value sent there, its speed
/// eased to nothing, let go.
pub fn DampedDrag::animate_to(self : DampedDrag, v : Double) -> Unit {
  let n = self.at()
  self.press()
  let to = clamp(v, self.lo, self.hi)
  self.value.go(n, to, value_spring(self.threshold))
  self.speed.go(n, 0.0, speed_spring(self.threshold))
  self.release()
}

///|
/// Sent smoothly to `v` without pressing or scaling (external/programmatic selection change):
/// only its value slides to `v` on the value spring while `press` and `scale` stay at rest.
pub fn DampedDrag::slide_to(self : DampedDrag, v : Double, spec? : @motion.Spec) -> Unit {
  let n = self.at()
  let to = clamp(v, self.lo, self.hi)
  let sp = match spec {
    Some(s) => s
    None => value_spring(self.threshold)
  }
  self.value.go(n, to, sp)
  self.speed.go(n, 0.0, speed_spring(self.threshold))
}

///|
/// Gesture cancelled: slide smoothly back to `v`, ease velocity to 0, and release any held lens.
pub fn DampedDrag::cancel_to(self : DampedDrag, v : Double, spec? : @motion.Spec) -> Unit {
  self.slide_to(v, spec?)
  self.release()
}
