// Clear refractive liquid glass lens overlays and floating magnifying loupe.
// Zero hidden glass at rest, lazy mount on first interaction, and zero relayout on release.

///|
/// Lazy-mounted clear refractive liquid glass lens overlay (`liquid_tab_lens_glass`) above a
/// segmented control, tab strip, or slider knob. Mounts lazily on first press (`lens() > 0.001 ||
/// active()`) so idle controls allocate 0 extra nodes and 0 hidden glass, then stays mounted across
/// settle (`glass=None` when `lens <= 0.001`) so release triggers 0 relayout (`laid == 0`).
#callsite(autofill(loc))
pub fn liquid_lens_overlay_node(
  parent : @view.View,
  lens : () -> Double,
  height : () -> Double,
  rect? : () -> (Double, Double, Double, Double)? = fn() { None },
  ground_drawn? : (@view.View) -> @view.GroundShape,
  width? : () -> Double = fn() { 0.0 },
  radius? : Double = 1.0e6,
  solid? : () -> Int64,
  shadow_color? : () -> Int64 = fn() { @ui.tree_theme().shadow },
  shadow_blur? : Double = 0.0,
  shadow_y? : Double = 0.0,
  jelly? : (@view.View) -> (Double, Double),
  grow? : Double = 0.0,
  overhang_x? : Double = 0.0,
  overhang_y? : Double = 0.0,
  active? : () -> Bool = fn() { false },
  droplet_role? : Int = 4,
  loc~ : SourceLoc,
) -> Unit {
  let mounted : @signals.Signal[Bool] = @signals.signal(false)
  parent.reacts(fn() { lens() > 0.001 || active() }, fn(on) {
    if on && !mounted.untracked() {
      mounted.set(true)
    }
  })
  parent.show(fn() { mounted.get() }, at_once=true, fn(l) {
    l.made_for(loc) |> ignore
    let full = fn() { clamp(lens(), 0.0, 1.0) }
    l
    .over(Is(true))
    .points(Is(false))
    .offset(Is((0.0, 0.0)))
    .width(By(fn() { Some(width()) }))
    .height(By(fn() { Some(height()) }))
    .radius(Is(radius))
    .glass(By(fn() {
      let p = full()
      if p > 0.001 {
        let sol = match solid {
          Some(f) => f()
          None => clear
        }
        if droplet_role == 3 {
          Some(ctrl_segmented_lens_glass(p, solid=sol))
        } else {
          Some(liquid_tab_lens_glass(p, solid=sol, droplet_role~))
        }
      } else {
        None
      }
    }))
    .shadow(By(fn() {
      let p = full()
      if p > 0.001 {
        if overhang_y > 0.0 {
          seg_lens_shadow(p)
        } else if shadow_blur > 0.0 || shadow_y > 0.0 {
          (shadow_blur * p, shadow_y * p, shadow_color())
        } else {
          shadow_none
        }
      } else {
        shadow_none
      }
    }))
    .shadow_outside(Is(true))
    .alpha(By(full))
    .ground_drawn(By(fn() {
      match ground_drawn {
        Some(f) => f(l)
        None =>
          match rect() {
            Some((rx, ry, rw, _)) => {
              let hh = height()
              let ww = width()
              let p = full()
              let (lw, lh) = if overhang_x > 0.0 || overhang_y > 0.0 {
                let (vel_sx, vel_sy) = match jelly {
                  Some(jf) => {
                    let (sx, sy) = jf(l)
                    let ps = lerp(1.0, 1.0 + grow, p)
                    if ps > 0.001 { (sx / ps, sy / ps) } else { (1.0, 1.0) }
                  }
                  None => (1.0, 1.0)
                }
                (dmax(0.0, (rw + overhang_x * p) * vel_sx), dmax(0.0, (hh + overhang_y * p) * vel_sy))
              } else {
                match jelly {
                  Some(jf) => {
                    let (sx, sy) = jf(l)
                    (dmax(0.0, rw + hh * (sx - 1.0)), dmax(0.0, hh * sy))
                  }
                  None => {
                    let g = hh * grow * lens()
                    (rw + g, hh + g)
                  }
                }
              }
              {
                dx: rx + (rw - lw) / 2.0,
                dy: ry + (hh - lh) / 2.0,
                dw: lw - ww,
                dh: lh - hh,
                corners: Some((lh / 2.0, lh / 2.0, lh / 2.0, lh / 2.0)),
              }
            }
            None => @view.ground_as_laid
          }
      }
    }))
    |> ignore
  })
}

///|
/// Generic floating text/drag magnifying loupe over the whole window (`View::over_all` +
/// `View::magnifies` + `@motion.SpringFollow2D` velocity-stretched capsule + `liquid_knob_glass`).
/// Renders 0 nodes and 0 glass whenever inactive and settled.
#callsite(autofill(loc))
pub fn liquid_loupe_node(
  root : @view.View,
  active : () -> Bool,
  target : () -> (Double, Double)?,
  bg? : () -> Int64 = fn() { colors().paper },
  solid? : () -> Int64 = fn() { colors().paper },
  shadow_color? : () -> Int64 = fn() { @ui.tree_theme().shadow },
  width? : Double = 124.0,
  height? : Double = 48.0,
  zoom? : Double = 1.35,
  lift? : Double = 92.0,
  side_inset? : Double = 8.0,
  grow? : Double = 1.25,
  shadow_blur? : Double = 0.0,
  shadow_y? : Double = 0.0,
  loc~ : SourceLoc,
) -> Unit {
  let read : @signals.Signal[(Double, Double)?] = @signals.signal(None, same=fn(a, b) { a == b })
  let follow = @motion.SpringFollow2D::new()
  root.box(made_for=loc, fn(l) {
    l
    .over(Is(true))
    .over_all(Is(true))
    .points(Is(false))
    .presses(Is(false))
    |> ignore
    let goal = fn(p : (Double, Double)) {
      let ww = l.window_w()
      let half = width / 2.0
      (
        clamp(p.0, half + side_inset, dmax(half + side_inset, ww - half - side_inset)),
        dmax(height / 2.0 + side_inset, p.1 - lift),
      )
    }
    l.reacts(
      fn() {
        if active() {
          target()
        } else {
          None
        }
      },
      fn(r) {
        match r {
          Some(p) => {
            let (tx, ty) = goal(p)
            follow.chase(l, tx, ty)
            read.set(Some(p))
          }
          None => follow.release(l)
        }
      },
    )
    l.show(
      at_once=true,
      fn() { read.get() is Some(_) && follow.active(l) },
      fn(at) {
        at.made_for(loc) |> ignore
        let laid = fn() {
          match read.get() {
            Some(p) => goal(p)
            None => (0.0, 0.0)
          }
        }
        let drawn = fn(n : @view.View) -> @view.GroundShape {
          let (tx, ty) = laid()
          follow.capsule_shape(n, width, height, tx, ty)
        }
        at
        .over(Is(true))
        .offset(By(fn() {
          let (tx, ty) = laid()
          (tx - width / 2.0, ty - height / 2.0)
        }))
        .width(Is(Some(width)))
        .height(Is(Some(height)))
        .radius(Is(height / 2.0))
        .ground(By(bg))
        .ground_drawn(By(fn() { drawn(at) }))
        .magnifies(By(fn() {
          match read.get() {
            Some(p) => Some((p.0, p.1, zoom))
            None => None
          }
        }))
        .alpha(By(fn() { dmin(1.0, follow.held_shown(at)) }))
        .scale(By(fn() { 1.0 + (grow - 1.0) * follow.held_shown(at) }))
        |> ignore
        at.box(fn(lens) {
          lens
          .over(Is(true))
          .radius(Is(height / 2.0))
          .ground_drawn(By(fn() { drawn(lens) }))
          .glass(By(fn() {
            if lens.glass_solid() || follow.held_shown(lens) <= 0.001 {
              None
            } else {
              Some(liquid_knob_glass(solid=solid()))
            }
          }))
          .shadow(By(fn() {
            let full = dmin(1.0, follow.held_shown(lens))
            if full > 0.001 && (shadow_blur > 0.0 || shadow_y > 0.0) {
              (shadow_blur * full, shadow_y * full, shadow_color())
            } else {
              shadow_none
            }
          }))
          .shadow_outside(Is(true))
          |> ignore
        })
        |> ignore
      },
    )
  })
  |> ignore
}
