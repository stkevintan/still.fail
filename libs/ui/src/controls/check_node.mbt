// A checkbox (mbui kit's checkbox, in still.fail's look: checkbox_look) as a node of the window's tree, made once: its
// look over mbui's headless toggle (@headless.toggle), whose it is that it is read out a checkbox, on or off, pressed
// and focused only while not disabled.

///|
/// A checkbox in `parent`, on or off as `on` says: 18 square, its corner 6, on the page's ground edged in the theme's
/// control edge (darker under the pointer), filled with the primary ink while on, its tick drawn in the ink on that by
/// its stroke as it is ticked (whole where it is on as it is made); sunk a little while pressed; faded while
/// `disabled`. Pressed (a tap, a click, Space with the keyboard's focus, a screen reader's Activate),
/// `turn` told what it becomes; a ring round it while the keyboard's focus is on it. Read out a checkbox named `label`,
/// on or off.
#callsite(autofill(loc))
pub fn check_node(
  parent : @view.View,
  on : () -> Bool,
  turn : (Bool) -> Unit,
  label : () -> String,
  disabled? : () -> Bool = fn() { false },
  loc~ : SourceLoc,
) -> Unit {
  check_node_of(loc~, parent, on, turn, label, disabled~) |> ignore
}

///|
/// check_node's checkbox, the node given back (what lights beside it while the hand is on it): `side` and `corner` its
/// own where a row asks another (a theme's rows' check), `edge` its edge while off and the hand not on it (one that
/// must show beside what is faded: the muted ink).
#callsite(autofill(loc))
pub fn check_node_of(
  parent : @view.View,
  on : () -> Bool,
  turn : (Bool) -> Unit,
  label : () -> String,
  disabled? : () -> Bool = fn() { false },
  side? : Double = check_side,
  corner? : Double = check_corner,
  edge? : () -> Int64,
  loc~ : SourceLoc,
) -> @view.View {
  check_box_node_by(loc~, parent, on, turn, label, disabled, fn() { side }, fn() { corner }, edge)
}

///|
/// Package-internal shared checkbox box with reactive `side` and `corner` (used by `check_node_of` and
/// `check_row_node`). Keeps `@headless.toggle(..., Checkbox, ...)`, `field_hover` edge when unchecked and hovered,
/// `@motion.press_feel`, stroke tick, disabled fade, and `focus_ring_node`.
#callsite(autofill(loc))
fn check_box_node_by(
  parent : @view.View,
  on : () -> Bool,
  turn : (Bool) -> Unit,
  label : () -> String,
  disabled : () -> Bool,
  side : () -> Double,
  corner : () -> Double,
  edge : (() -> Int64)?,
  loc~ : SourceLoc,
) -> @view.View {
  @headless.toggle(made_for=loc, parent, Checkbox, label, on, turn, disabled~, fn(b, _) {
    b
    .width(By(fn() { Some(side()) }))
    .height(By(fn() { Some(side()) }))
    .radius(By(corner))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .ground(By(fn() {
      let t = @ui.tree_theme()
      if on() { t.primary } else { t.bg }
    }))
    .edge(By(fn() {
      let t = @ui.tree_theme()
      let line = if on() {
        t.primary
      } else if b.pointed() && !disabled() {
        t.field_hover
      } else {
        match edge {
          Some(e) => e()
          None => t.border
        }
      }
      (1.0, line)
    }))
    .alpha(By(fn() { if disabled() { check_disabled_alpha } else { 1.0 } }))
    |> ignore
    // (pressed, sunk a little and springing back as it is let go; its tick drawn by its stroke as it is ticked)
    let s = @signals.untracked(side)
    @motion.press_feel(b, live=fn() { !disabled() }, hovers=false, size=(s, s)) |> ignore
    check_tick_node(b, on, side, fn() { @ui.tree_theme().on_primary })
    // (the keyboard's focus on it: a concentric ring round it, its gap and width the theme's)
    focus_ring_node(b)
  })
}

///|
/// A checkbox's side and corner (checkbox_look's 18 and 6), how faded it is while it may not be turned (0.45).
let check_side : Double = 18.0

///|
let check_corner : Double = 6.0

///|
let check_disabled_alpha : Double = 0.45

///|
/// A box's tick in `b` (its middle, `side()` square), in `ink()`, while `on()`: a pen's stroke (round ends and join)
/// drawn from its start as it comes to be on (check_tick_in), whole where it is on as it is made (a picture of it at rest
/// never half drawn), gone at once as it is off (on the box's own ground then, unseen however drawn). Nothing of it is
/// made while it is off.
fn check_tick_node(b : @view.View, on : () -> Bool, side : () -> Double, ink : () -> Int64) -> Unit {
  let tick = @motion.NodeWay::new(if @signals.untracked(on) { 1.0 } else { 0.0 })
  b.reacts(on, at_start=false, fn(now) { if now { tick.go_from(b, 0.0, 1.0, check_tick_in) } else { tick.put(0.0) } })
  b.show(on, at_once=true, fn(m) {
    m
    .width(By(fn() { Some(side()) }))
    .height(By(fn() { Some(side()) }))
    .lines(By(fn() {
      let k = side() / check_side
      [
        @paint.line(
          check_tick_points.map(fn(p) { (p.0 * k, p.1 * k) }),
          width=check_tick_w * k,
          color=ink(),
          upto=dmax(0.0, tick.shown(m)),
        ),
      ]
    }))
    |> ignore
  })
}

///|
/// How a box's tick is drawn as it is ticked (eased out), its points in an 18-point box (a pen's: down to its foot, up
/// to its end) and how wide.
let check_tick_in : @motion.Spec = @motion.tween(160.0, ease=Out)

///|
let check_tick_points : Array[(Double, Double)] = [(4.75, 9.25), (7.75, 12.25), (13.25, 5.75)]

///|
let check_tick_w : Double = 2.0
