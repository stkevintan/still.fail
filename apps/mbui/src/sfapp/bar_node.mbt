// The phone's bottom bar drawn as nodes of the window's tree (bar.mbt's model and its ways), in its glass's node
// (bar_glass_node: where it is laid out, what takes a finger on it): laid out where it is told (bar_tell: BarLaid), each
// of its numbers read where it is as each frame is drawn (View::drawn_while) while the ways it is drawn by go, where they
// went once they are there (the clock no longer followed); told again as the bar is told anew (bar_said). What moves is
// drawn so, nothing laid out for it (src/motion's rule): the bar going down and coming back, drawn up out from under a
// finger, the glass's top as the panel opens, the capsule giving the action room and its places moving with it, the
// action's circle growing and its icon swapping, the ball, its lens, each place lighting up, a bar chosen landing.

///|
/// Said each time the bar is told what it goes by (bar_tell, bar_retell, bar_reset): its ways set out anew, what waits
/// on them told again (bar_node's said_moving).
// kept across runs: a count whose changes alone are read (what reads it read again), never its value
let bar_said : @signals.Signal[Int] = @signals.signal(0, same=fn(a, b) { a == b })

///|
/// The parts of the bar each drawn by ways of their own, told apart: what reads one part's ways is read again only as
/// its ways are told anew, not as another's are (the bar going down under a page wakes its holder alone).
priv enum BarPart {
  /// the bar shown and drawn up (vis, up): its holder
  Vis
  /// the notch, as the panel and the rise close it too (k, o, up, a bar chosen landing): the glass's notch, the action's
  /// disc, the places' places, a bar chosen landing
  Notch
  /// the panel alone (o, whether it is open, a bar chosen landing): the glass's top, its shadow, the panel's rows
  Panel
  /// the ball (where across and down, held, how faint and large): the ball, its lens
  Ball
  /// each place lit (tints)
  Tints
  /// the notch's icon and its swap
  Icon
  /// scroll-to-collapse progress alone (collapse): tab fades/scales and capsule clip
  Collapse
}

///|
/// Each part said as it is told anew (bar_said_again), in BarPart's order.
// kept across runs: counts whose changes alone are read (what reads them read again), never their values
let bar_parts_said : Array[@signals.Signal[Int]] = [
  @signals.signal(0, same=fn(a, b) { a == b }),
  @signals.signal(0, same=fn(a, b) { a == b }),
  @signals.signal(0, same=fn(a, b) { a == b }),
  @signals.signal(0, same=fn(a, b) { a == b }),
  @signals.signal(0, same=fn(a, b) { a == b }),
  @signals.signal(0, same=fn(a, b) { a == b }),
  @signals.signal(0, same=fn(a, b) { a == b }),
]

///|
/// What each part's ways were last told, as text (bar_part_told), in BarPart's order.
// kept across runs: said again each time the bar is told (bar_said_again), emptied by bar_reset's
let bar_parts_told : Array[String] = ["", "", "", "", "", "", ""]

///|
fn BarPart::ord(self : BarPart) -> Int {
  match self {
    Vis => 0
    Notch => 1
    Ball => 2
    Tints => 3
    Icon => 4
    Panel => 5
    Collapse => 6
  }
}

///|
/// Part `p` read as it is told anew (bar_parts_said).
fn bar_part_said(p : BarPart) -> Unit {
  bar_parts_said[p.ord()].get() |> ignore
}

///|
fn spr_told(s : Spr) -> String {
  "\{s.to} \{s.end()} \{s.set_at};"
}

///|
fn glide_told(g : Glide) -> String {
  "\{g.target} \{g.start} \{g.dur};"
}

///|
/// What part `p`'s ways are told now, as text: changed only as they are told anew.
fn bar_part_told(p : BarPart) -> String {
  let m = bar
  match p {
    Vis => glide_told(m.vis) + spr_told(m.up)
    Notch => {
      let swap = match m.swap {
        Some(s) => "\{s.i} \{s.ends}"
        None => ""
      }
      spr_told(m.k) +
      spr_told(m.o) +
      spr_told(m.up) +
      "\{m.bond_merge.target()} \{m.bond_merge.ends_at()} \{m.bond_recoil.ends_at()} " +
      "\{m.collapse.target()} \{m.collapse.ends_at()} " +
      "\{m.mode.untracked()} " +
      swap
    }
    Ball =>
      spr_told(m.ball_x) +
      spr_told(m.ball_y) +
      spr_told(m.held) +
      glide_told(m.ball_alpha) +
      glide_told(m.ball_scale)
    Tints => {
      let out = StringBuilder()
      for id, g in m.tints {
        out.write_string(id)
        out.write_string(glide_told(g))
      }
      out.to_string()
    }
    Icon => m_face.val + " " + m.icon_was + " " + glide_told(m.icon_swap)
    Panel => {
      let swap = match m.swap {
        Some(s) => "\{s.i} \{s.ends}"
        None => ""
      }
      spr_told(m.o) + "\{m.mode.untracked()} " + swap
    }
    Collapse => "\{m.collapse.target()} \{m.collapse.ends_at()}"
  }
}

///|
/// The bar told anew: each part whose ways changed said, and the bar as a whole.
fn bar_said_again() -> Unit {
  for p in [Vis, Notch, Ball, Tints, Icon, Panel, Collapse] {
    let told = bar_part_told(p)
    if told != bar_parts_told[p.ord()] {
      bar_parts_told[p.ord()] = told
      let s = bar_parts_said[p.ord()]
      s.set(s.untracked() + 1)
    }
  }
  bar_said.set(bar_said.untracked() + 1)
}

///|
/// The moment node `n` reads part `p`'s ways at, those it is drawn by ending at `until`: the moment it is drawn at while
/// they go, past every end (+inf: each where it went) once they are there, as the first frame after says; read again as
/// that part is told anew.
fn bar_moment(n : @view.View, p : BarPart, until : Double) -> Double {
  bar_part_said(p)
  n.drawn_while(fn(t) { t < until })
}

///|
/// Node `n` moved off where it is laid out by what `f` gives at the moment it is drawn at (View::moved_by: placed, pressed
/// and read out there, nothing laid out again), part `p`'s ways it goes by ending at `until`; asked again as that part
/// is told anew.
fn bar_moved(n : @view.View, p : BarPart, until : () -> Double, f : (Double) -> (Double, Double)) -> Unit {
  n
  .moved_by(
    fn(_, _, t) {
      bar_part_said(p)
      f(t)
    },
    fn(_, _) {
      bar_part_said(p)
      until()
    },
  )
  |> ignore
}

///|
/// Where the notch as drawn ends (BarModel::k_at: its spring's, the panel's, the rise's, its liquid bridge's, and
/// scroll-to-collapse).
fn bar_k_until() -> Double {
  dmax(
    dmax(dmax(bar.k.end(), dmax(bar.o.end(), bar.up.end())), bar.collapse.ends_at()),
    dmax(bar.bond_merge.ends_at(), bar.bond_recoil.ends_at()),
  )
}

///|
/// Where the ball as drawn ends (bar_ball_at: where it is, held, how big, how faint).
fn bar_ball_until() -> Double {
  let m = bar
  dmax(dmax(m.ball_x.end(), m.ball_y.end()), dmax(m.held.end(), dmax(m.ball_scale.end(), m.ball_alpha.end())))
}

///|
/// Where the place of tint `id` ends lighting up or going dim.
fn bar_tint_until(id : String) -> Double {
  match bar.tints.get(id) {
    Some(g) => g.end()
    None => -1.0
  }
}

///|
/// How lit the place of tint `id` is at moment `t` (its glide's, bar_tell's; none told yet: not).
fn bar_tint_at(id : String, t : Double) -> Double {
  match bar.tints.get(id) {
    Some(g) => g.at(t).0
    None => 0.0
  }
}

///|
/// A box `w` by `h` at (`x`, `y`) in `parent` (over all of it: View::over), made by `f`; it.
fn bar_at(
  parent : @view.View,
  x : () -> Double,
  y : () -> Double,
  w : () -> Double,
  h : () -> Double,
  f : (@view.View) -> Unit,
) -> @view.View {
  let made : Ref[@view.View?] = Ref(None)
  parent.box(fn(o) {
    o.over(Is(true)) |> ignore
    made.val = Some(
      o.box(fn(b) {
        b.width(By(fn() { Some(w()) })).height(By(fn() { Some(h()) })).offset(By(fn() { (x(), y()) })) |> ignore
        f(b)
      }),
    )
  })
  |> ignore
  made.val.unwrap()
}

///|
/// What the bar is laid out by as it was last told (BarLaid), or as none before it is.
fn bar_laid_now() -> BarLaid {
  bar_laid_told.get()
}

///|
/// The bar laid out as nothing told yet.
fn bar_laid_none() -> BarLaid {
  bar_laid({ shown: false, action: "", active: None, sets: [[]], cur: 0, width: 0.0 })
}

///|
/// How the bar is laid out as it was last told (bar_tell's: BarLaid), told again only as that changes, not as whether it
/// shows or what its notch offers does: what is laid out by it read again then alone.
// kept across runs: said again as the bar is told, put back by bar_reset
let bar_laid_told : @signals.Signal[BarLaid] = @signals.signal(bar_laid_none(), same=fn(a, b) { a == b })

///|
/// Whether the stack is currently in an interactive back gesture (or cancelling one) over a bottom-bar root place.
fn bar_nav_gesturing() -> Bool {
  app.nav.in_gesture() && app.nav.root_shows() && place_of(app.nav.pages()[0]) is Some(_)
}

///|
/// Watches the active root page's primary scrollable list and feeds its scroll offset into `bar_scroll_note`.
fn bar_scroll_watch_node(b : @view.View, ws : () -> Workspace?) -> Unit {
  let prev_in_hand : Ref[Bool] = Ref(false)
  b.reacts(
    fn() {
      ignore(@sfbase.first_page_waits.get())
      ignore(app.nav.top())
      guard bar_told_now.get() is Some(t) && t.shown else { return None }
      guard t.active is Some(active) else { return None }
      guard ws() is Some(w) else { return None }
      guard @ui.view_tree() is Some(tree) else { return None }
      let mut best : @view.Scroll? = None
      let mut best_most = 0.0
      for _, s in tree.lists_scrolled {
        match s.shown_by() {
          Some(v) if v.alive() && tree.takes_keys(v.id()) => {
            let most = s.reach()
            if most > best_most {
              best_most = most
              best = Some(s)
            }
          }
          _ => ()
        }
      }
      match best {
        Some(s) => {
          let key = w.id + ":" + active
          let held = s.in_hand()
          if held {
            Some((key, s.at(tree), best_most, true))
          } else {
            let gliding = s.glides_till() is Some(_)
            if prev_in_hand.val || gliding {
              Some((key, if gliding { s.drawn(tree) } else { s.at(tree) }, best_most, false))
            } else {
              None
            }
          }
        }
        None => None
      }
    },
    fn(obs) {
      match obs {
        Some((page_key, y, _, true)) => {
          prev_in_hand.val = true
          bar.scroll_page_key = page_key
          bar.scroll_last_y = y
          bar.scroll_acc = 0.0
        }
        Some((page_key, y, most, false)) => {
          prev_in_hand.val = false
          bar_scroll_note(page_key, y, most, b.cause_at())
        }
        None => prev_in_hand.val = false
      }
    },
  )
}

///|
/// The bottom bar drawn in `g`, its glass's node (bar_glass_node: so what a press there goes to holds what it draws),
/// shown on a place's top page with nothing over it; going down out of the way as it is hidden,
/// taking nothing as it goes (View::show's `leave`). `ws`: the workspace in view.
fn bar_node(g : @view.View, src : Source, ws : () -> Workspace?) -> Unit {
  g.box(fn(b) {
    b.transitions_only().over(Is(true)) |> ignore
    bar_place_marks_node(b, src, ws)
    bar_scroll_watch_node(b, ws)
    // (what waits on what moves told as the bar is told anew: when all of it is at rest, BarModel::rest)
    b.reacts(fn() { bar_said.get() }, fn(_) { b.said_moving("bar", "the bar's springs", fn(_) { bar.rest() }) })
    // (none before its width is known: it is first laid out where it goes, at once, bar_tell; its leave scoped to `b`)
    let bar_open = fn() {
      match bar_told_now.get() {
        Some(t) => t.width > 0.0 && (t.shown || bar_nav_gesturing())
        None => false
      }
    }
    let bar_shown = @signals.signal(@signals.untracked(bar_open), same=fn(a, b) { a == b })
    b.reacts(bar_open, fn(on) { @view.transition(within=b, fn() { bar_shown.set(on) }) }, at_start=false)
    b.show(at_once=true,
      fn() { bar_shown.get() },
      fn(holder) { bar_holder_node(holder, src, ws) },
      leave=bar_hide_ms,
    )
  })
  |> ignore
}

///|
/// The bar's panel in `holder` (its glass, the panel's rows over it as it opens), where it is told: going down out of
/// the way and back up, drawn up out from under a finger that has it, drawn so, laid out where it rests.
fn bar_holder_node(holder : @view.View, src : Source, ws : () -> Workspace?) -> Unit {
  let w = fn() { bar_laid_now().w }
  let panel = fn() { bar_laid_now().panel }
  let row_top = fn() { bar_laid_now().row_top }
  // (the glass's top laid out where the panel goes, drawn where it is as each frame is drawn: `drift` off that)
  let clip_top = fn() {
    bar_part_said(Panel) |> ignore
    bar_glass_top(bar_laid_now().reach, bar.o.to)
  }
  let drift = fn(t : Double) { bar_glass_top(bar_laid_now().reach, bar.o.at(t).0) - clip_top() }
  holder
  .width(By(fn() { Some(w()) }))
  .height(By(fn() { Some(panel()) }))
  .alpha(
    By(fn() {
      let vis = if bar_nav_gesturing() {
        app.nav.root_progress(fn() { app.nav.slide_moment(holder) })
      } else {
        bar.vis.at(bar_moment(holder, Vis, bar.vis.end())).0
      }
      vis * @sf.sheet_foot_alpha(holder)
    }),
  )
  |> ignore
  holder
  .moved_by(
    fn(_, _, t) {
      bar_part_said(Vis)
      let v = if bar_nav_gesturing() {
        app.nav.root_progress(fn() { t })
      } else {
        bar.vis.at(t).0
      }
      let foot = 22.0 + nav_foot()
      let raised = bar_raise(holder.window_h(), foot, panel(), status_top_now(holder.window_w())) * bar.up.at(t).0
      (0.0, (1.0 - v) * bar_drop - raised)
    },
    fn(_, _) {
      bar_part_said(Vis)
      let nav_end = if bar_nav_gesturing() { app.nav.rest() } else { -1.0 }
      dmax(nav_end, dmax(bar.vis.end(), bar.up.end()))
    },
  )
  |> ignore
  bar_shadows_node(holder, w, clip_top, panel, row_top, drift)
  bar_glass_capsule(holder, w, clip_top, panel, drift)
  // the action's circle of glass beside the capsule, at the bar's right, growing out of nothing as the place has an
  // action and the capsule gives it room (laid out as it is there, drawn so); closing, it keeps the last action's icon
  // as it shrinks. It is the notch's key: pressed while the place has an action, taken only where it is drawn whole at
  // its moment (closing, the panel up, what is under it the panel's); what it opens opened beside it
  let disc_x = fn() { w() - act_size }
  let disc_y = fn() { row_top() }
  let disc = bar_at(holder, disc_x, disc_y, fn() { act_size }, fn() { act_size }, fn(d) {
    @sf.tab_bar_surface_decorate(
      d.radius(Is(act_size / 2.0)),
      fn() {
        let t = bar_moment(d, Notch, bar_k_until())
        let spot = if d.pressed() { Some((act_size / 2.0, act_size / 2.0)) } else { None }
        (spot, bar_merge_at(t))
      },
      share_when_unmerged=true,
    )
    .presses(By(fn() {
      match bar_told_now.get() {
        Some(t) => t.shown && t.action != ""
        None => false
      }
    }))
    .takes(fn(w, h, at) { if bar.drag < 0.0 && !bar.holds && bar.k_at(at) > 0.9 { [(0.0, 0.0, w, h)] } else { [] } })
    .on_press(fn() {
      match ws() {
        Some(w) => bar_action_run(src, w, d.cause_at())
        None => ()
      }
    })
    |> ignore
    bar_action_icons(d)
  })
  bar_disc_look(disc)
  // (what its action opens opened beside it: bar_action_run)
  bar_action_anchor.val = Some(disc)
  bar_ball_node(holder)
  bar_rows_node(holder, w)
  bar_places_node(holder, w, row_top)
  bar_lens_node(holder)
  bar_swap_node(holder, w, row_top, panel)
}

///|
/// The icons the notch draws for its actions (bar_action_icon's: 令's and ＋'s alike a ＋).
// kept across runs: a table, never written
let bar_faces : Array[String] = ["plus"]

///|
/// The action's icons in `d` (bar_action_icon's, each 30, in the bar's lit ink, in its middle), one of each action's, made once
/// and drawn (and found on screen by what it draws) only while the action is it (m_face) or another swaps in for it
/// (icon_was; bar_tell: a short scale and fade, 300 ms on the bar's clock, linear; the one going out by 120 ms, the one
/// coming in from 60 ms): none made or let go as the action is another.
fn bar_action_icons(d : @view.View) -> Unit {
  let css : @ui.Ease = Out
  // (how it is drawn, as faint and as large, at node `n`'s moment: coming in, going out, or not there: None)
  let look = fn(n : @view.View, face : String) -> (Double, Double)? {
    bar_part_said(Icon) |> ignore
    let v = bar.icon_swap.at(bar_moment(n, Icon, bar.icon_swap.end())).0
    if face == m_face.val {
      let ms = v * 300.0
      if ms < 300.0 {
        Some((css.at(dclamp((ms - 60.0) / 180.0, 0.0, 1.0)), 0.5 + 0.5 * css.at(dclamp((ms - 60.0) / 240.0, 0.0, 1.0))))
      } else {
        Some((1.0, 1.0))
      }
    } else if face == bar.icon_was && v < 1.0 {
      let p = css.at(dclamp(v * 300.0 / 120.0, 0.0, 1.0))
      Some((1.0 - p, 1.0 - 0.5 * p))
    } else {
      None
    }
  }
  for face in bar_faces {
    d.box(fn(c) {
      c
      .over(Is(true))
      .lines_up(Is(Some(Middle)))
      .lies_along(Is(Middle))
      .alpha(By(fn() { dclamp((bar.k_at(bar_moment(c, Notch, bar_k_until())) - 0.55) / 0.35, 0.0, 1.0) }))
      |> ignore
      let shown = fn() { look(c, face) }
      let i = @sf.icon_node(c, face, 26.0, By(bar_action_ink), name_now=fn() {
        if shown() is Some(_) {
          face
        } else {
          ""
        }
      })
      i
      .alpha(By(fn() { shown().map(fn(s) { s.0 }).unwrap_or(0.0) }))
      .scale(By(fn() { shown().map(fn(s) { s.1 }).unwrap_or(1.0) }))
      |> ignore
    })
    |> ignore
  }
}

///|
/// The action's circle: emerging smoothly from the capsule's right end with subtle elastic recoil on split/fuse;
/// there still while a finger has the capsule (taking nothing then), as Comma's circle is.
fn bar_disc_look_at(t : Double) -> (Double, Double) {
  let k = bar.k_at(t)
  if k <= 0.001 {
    (0.0, 1.0)
  } else {
    let alpha = dclamp(k / 0.15, 0.0, 1.0)
    let base_scale = 0.92 + 0.08 * dclamp(k, 0.0, 1.0)
    let recoil = dclamp(bar.bond_recoil.value_at(t) * 0.25, -0.06, 0.06)
    (alpha, dclamp(base_scale + recoil, 0.85, 1.08))
  }
}

///|
fn bar_disc_look(d : @view.View) -> Unit {
  let look = fn() { bar_disc_look_at(bar_moment(d, Notch, bar_k_until())) }
  d.alpha(By(fn() { look().0 })).scale(By(fn() { look().1 })) |> ignore
}

///|
/// Preceding outside-only shadows for the capsule and `＋` action circle, kept in a sibling layer before both glass
/// nodes so `sd_group` adjacency is never broken and the `＋` shadow fades in smoothly with separation (never bleeding
/// dark shadow into the capsule while merged).
fn bar_shadows_node(
  holder : @view.View,
  w : () -> Double,
  top : () -> Double,
  bottom : () -> Double,
  row_top : () -> Double,
  drift : (Double) -> Double,
) -> Unit {
  let h = fn() { bottom() - top() }
  holder.box(fn(shadows) {
    shadows.over(Is(true)) |> ignore
    bar_at(shadows, fn() { 0.0 }, top, w, h, fn(cs) {
      cs
      .radius(By(fn() { dmin(rad, h() / 2.0) }))
      .shadow(By(bar_shadow))
      .shadow_outside(Is(true))
      .ground_drawn(
        By(fn() {
          bar_part_said(Notch)
          let t = bar_moment(cs, Panel, dmax(bar.o.end(), bar_k_until()))
          let d = drift(t)
          { dx: 0.0, dy: d, dw: bar_cur_capsule_w(w(), bar.k_at(t), bar.collapse_at(t)) - w(), dh: -d, corners: None }
        }),
      )
      |> ignore
    })
    |> ignore
    bar_at(shadows, fn() { w() - act_size }, row_top, fn() { act_size }, fn() { act_size }, fn(ds) {
      let at = fn() { bar_moment(ds, Notch, bar_k_until()) }
      ds
      .radius(Is(act_size / 2.0))
      .shadow(By(bar_shadow))
      .shadow_outside(Is(true))
      .alpha(By(fn() {
        let t = at()
        let k = bar.k_at(t)
        if k <= 0.001 {
          0.0
        } else {
          let gap = (act_size + act_gap) * k - act_size
          let u = dclamp(gap / bar_bond_break_gap, 0.0, 1.0)
          u * u * (3.0 - 2.0 * u)
        }
      }))
      .scale(By(fn() { bar_disc_look_at(at()).1 }))
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// The shadow round the bar's glass on the page (@sf.glass_control_shadow: light/dark separated), outside its outline
/// only: the glass bends nothing of it.
fn bar_shadow() -> (Double, Double, Int64) {
  @sf.glass_control_shadow()
}

///|
/// The ink of the action's icon: the bar's places' lit ink (@sf.bar_place_node's).
fn bar_action_ink() -> Int64 {
  if @sf.theme().dark {
    0xFFFFFFFFL
  } else {
    0x111827FFL
  }
}

///|
/// The capsule's glass (glass_tab_bar's) from `top` to `bottom`, as wide as the bar less the action's room as far as
/// the notch is open as each frame is drawn, round at its ends, its top where the panel has it, its breath of shadow.
fn bar_glass_capsule(
  holder : @view.View,
  w : () -> Double,
  top : () -> Double,
  bottom : () -> Double,
  drift : (Double) -> Double,
) -> Unit {
  let h = fn() { bottom() - top() }
  bar_at(holder, fn() { 0.0 }, top, w, h, fn(g) {
    @sf.tab_bar_surface_decorate(g.radius(By(fn() { dmin(rad, h() / 2.0) })), fn() {
      bar_part_said(Notch)
      let until = dmax(if bar.held.to > 0.01 { bar_ball_until() } else { bar.held.end() }, bar_k_until())
      let t = bar_moment(g, Ball, until)
      let a = bar_ball_at(t)
      let spot = if a.held > 0.01 { Some((a.cx, a.cy - top())) } else { None }
      (spot, bar_merge_at(t))
    })
    // (its top where the panel has it as each frame is drawn, its foot where it is; its right end in by the action's
    // room as far as the notch is open then)
    .ground_drawn(
      By(fn() {
        bar_part_said(Notch)
        let t = bar_moment(g, Panel, dmax(bar.o.end(), bar_k_until()))
        let d = drift(t)
        { dx: 0.0, dy: d, dw: bar_cur_capsule_w(w(), bar.k_at(t), bar.collapse_at(t)) - w(), dh: -d, corners: None }
      }),
    )
    |> ignore
  })
  |> ignore
}

///|
/// The ball as drawn at moment `t`: its middle, how much its speed stretches it along its way and lowers it, how faint,
/// how large it is coming or going, how far it is held, how far the notch is open then (how wide a place is).
priv struct BallAt {
  cx : Double
  cy : Double
  stretch : Double
  lower : Double
  alpha : Double
  scale : Double
  held : Double
  k : Double
  collapse : Double
}

///|
/// The box the ball and its lens are drawn in about their middle, larger than either drawn at its largest.
let ball_box_w : Double = 160.0

///|
let ball_box_h : Double = 96.0

///|
/// The ball at moment `t`.
fn bar_ball_at(t : Double) -> BallAt {
  let m = bar
  let (x, xv) = m.ball_x.at(t)
  // (its way a frame at 60, as fast as it goes then: none at rest. Not cut to none within half a point of where it goes,
  // as the old view's was: a spring passing it there went on stretched the frame after, a jump each frame drew)
  let v = xv / 60.0
  let (stretch, lower) = @motion.speed_stretch(v)
  {
    cx: x + (if v < 0.0 { -stretch } else { stretch }) / 2.0,
    cy: m.ball_y.at(t).0,
    stretch,
    lower,
    alpha: m.ball_alpha.at(t).0,
    scale: m.ball_scale.at(t).0,
    held: m.held.at(t).0,
    k: m.k_at(t),
    collapse: m.collapse_at(t),
  }
}

///|
/// How wide and high the ball `a` is drawn on the bar laid out as `l`: the pill as wide as its place and past it to
/// the pill's inset at the bar's ends (ShellTabBar.kt pillWidthFor), `lens` its lens lifting out of it as it is held,
/// taller than the bar and wider than a place (TabBarLens.kt lensSize, lensLiftedWidth); each stretched along its way.
fn bar_ball_size(a : BallAt, l : BarLaid, lens : Bool) -> (Double, Double) {
  let iw = bar_item_w(l.w, a.k, l.items.length())
  let pw = iw + 2.0 * (tab_edge - pill_inset)
  let (w, h) = if lens {
    let lh = bar_track * lens_lift_h
    let lw = dmin(lh * lens_lift_aspect, iw * lens_lift_aspect)
    let up = dclamp(a.held, 0.0, 1.2)
    (pw + (lw - pw) * up, pill_h + (lh - pill_h) * up)
  } else {
    (pw, pill_h)
  }
  (w + a.stretch, dmax(8.0, h - a.lower))
}

///|
/// A capsule round the ball's middle in `parent`, as wide and high as `size` has the ball drawn, placed where the ball
/// is as each frame is drawn, drawn as large and as faint as `alpha` has it; made by `f`.
fn bar_ball_capsule(
  parent : @view.View,
  lens : Bool,
  alpha : (@view.View, BallAt) -> Double,
  f : (@view.View) -> Unit,
) -> Unit {
  let at = fn(n : @view.View) {
    bar_part_said(Notch)
    bar_ball_at(bar_moment(n, Ball, dmax(bar_ball_until(), bar_k_until())))
  }
  parent.box(fn(o) {
    o.over(Is(true)) |> ignore
    o.box(fn(b) {
      b
      .width(Is(Some(ball_box_w)))
      .height(Is(Some(ball_box_h)))
      // (laid out where it goes, drawn where it is)
      .offset(By(fn() {
        bar_part_said(Ball) |> ignore
        (bar.ball_x.to - ball_box_w / 2.0, bar.ball_y.to - ball_box_h / 2.0)
      }))
      .alpha(By(fn() { alpha(b, at(b)) }))
      .scale(By(fn() { at(b).scale }))
      |> ignore
      bar_moved(b, Ball, bar_ball_until, fn(t) {
        let a = bar_ball_at(t)
        (a.cx - bar.ball_x.to, a.cy - bar.ball_y.to)
      })
      b.box(fn(s) {
        s.over(Is(true)) |> ignore
        // (as wide and as high as it is drawn about its middle, as round as the shorter)
        s
        .ground_drawn(
          By(fn() {
            let (sw, sh) = bar_ball_size(at(s), bar_laid_now(), lens)
            let r = dmin(sw, sh) / 2.0
            {
              dx: (ball_box_w - sw) / 2.0,
              dy: (ball_box_h - sh) / 2.0,
              dw: sw - ball_box_w,
              dh: sh - ball_box_h,
              corners: Some((r, r, r, r)),
            }
          }),
        )
        .radius(Is(pill_h / 2.0))
        |> ignore
        f(s)
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// The pill under the places (ShellTabBar.kt's: a grey of the glass, token_glass_selection), stretched by its speed
/// toward where it goes (as it fades and grows in or out, drawn so). Held, the lens over the places takes its place: it
/// fades as the lens comes.
fn bar_ball_node(holder : @view.View) -> Unit {
  bar_ball_capsule(
    holder,
    false,
    fn(n, b) {
      let lensed = if n.glass_solid() { 0.0 } else { dmin(1.0, b.held) }
      let fade = dclamp(1.0 - b.collapse / 0.25, 0.0, 1.0)
      b.alpha * (1.0 - lensed) * fade
    },
    fn(g) { g.ground(By(@sf.glass_selection)) |> ignore },
  )
}

///|
/// The ball in the finger: a lens of clear liquid glass lifted out of the pill as it is held (TabBarLens.kt's), taller
/// than the bar and wider than a place, what is under its rim bent; gone as it is let go. Where glass is solid there is
/// nothing to bend: the pill alone.
fn bar_lens_node(holder : @view.View) -> Unit {
  holder.box(fn(b) {
    b.over(Is(true)) |> ignore
    b.show(at_once=true, fn() { !b.glass_solid() }, fn(on) {
      on.over(Is(true)) |> ignore
      let held = fn(n : @view.View) { bar.held.at(bar_moment(n, Ball, bar.held.end())).0 }
      bar_ball_capsule(
        on,
        true,
        fn(_, a) {
          let fade = dclamp(1.0 - a.collapse / 0.4, 0.0, 1.0)
          if a.held > 0.01 && a.alpha > 0.0 && fade > 0.0 {
            dmin(1.0, a.held) * a.alpha * fade
          } else {
            0.0
          }
        },
        fn(g) {
          @sf.tab_lens_surface_decorate(g, fn() { held(g) }) |> ignore
        },
      )
    })
  })
  |> ignore
}

///|
/// What the bar's places say of the workspace in view (read while the bar is: bar_place_marks_node): a station
/// in trouble, a remote agent lit, the stations at a glance and in words.
#derive(Eq)
priv struct BarPlaceMarks {
  trouble : Bool
  remote : Bool
  glance : @sf.GlyphCounts
  said : String
}

///|
/// None said yet.
// kept across runs: a value (no field of it changes)
let bar_place_marks_none : BarPlaceMarks = {
  trouble: false,
  remote: false,
  glance: { online: 0, dim: 0, failing: 0, working: 0, asleep: false, connecting: 0 },
  said: "",
}

///|
/// The bar's marks as the workspace in view last said them (bar_place_marks_node), what each place reads.
// kept across runs: said again as the bar is made (bar_place_marks_node)
let bar_place_marks : @signals.Signal[BarPlaceMarks] = @signals.signal(bar_place_marks_none, same=fn(a, b) { a == b })

///|
/// The bar's marks told in node `b` as the workspace in view `ws` says them (the chats' trouble, a remote agent, the
/// stations at a glance): read all along while the bar is there, shown or not.
fn bar_place_marks_node(b : @view.View, src : Source, ws : () -> Workspace?) -> Unit {
  b.reacts(
    fn() {
      match ws() {
        Some(w) => {
          let (glance, said) = stations_at_glance(src, w.id)
          {
            trouble: field(chats_topic(src, w.id).value, "trouble") is Some(Object(_)),
            remote: @sfpages.remote_agent_lit(src, w.id),
            glance,
            said,
          }
        }
        None => bar_place_marks_none
      }
    },
    fn(m) { bar_place_marks.set(m) },
  )
}

///|
/// What a screen reader says of place `key` (Station's, the stations in words).
fn bar_said_of(key : String) -> String {
  let said = if key == "stations" { bar_place_marks.get().said } else { "" }
  if said != "" {
    said
  } else {
    place_label(key)
  }
}

///|
/// Place `key`'s dot: a station in trouble (red) on Station's, a remote agent lit (the accent) on 远程's; none else.
fn bar_dot_of(key : String) -> Int64 {
  match key {
    "stations" => if bar_place_marks.get().trouble { @sf.theme().p.red } else { 0L }
    "remote" => if bar_place_marks.get().remote { @sf.theme().p.primary } else { 0L }
    _ => 0L
  }
}

///|
/// A place of the bar or the panel (place_at's) in `at`, its slot 44 high round its middle, as the library draws one
/// (@sf.bar_place_node): lit as far as `lit_at` has it as each frame is drawn, its dot, read out by its name.
fn bar_face_node(
  at : @view.View,
  key : String,
  part : BarPart,
  lit_at : (Double) -> Double,
  lit_until : () -> Double,
) -> Unit {
  @sf.bar_place_node(
    at,
    place_icon(key),
    if key == "stations" {
      Some(fn() { bar_place_marks.get().glance })
    } else {
      None
    },
    fn(n) { lit_at(bar_moment(n, part, lit_until())) },
    fn() { bar_dot_of(key) },
    fn() { bar_said_of(key) },
  )
}

///|
/// The bar's places over the ball: each its slot round its middle, lit as far as it is as each frame is drawn, placed
/// where the notch has it as each frame is drawn (drawn, pressed and read out there; nothing laid out for it); none
/// while a bar chosen lands (bar_swap_node draws them coming down).
fn bar_places_node(
  holder : @view.View,
  w : () -> Double,
  row_top : () -> Double,
) -> Unit {
  let items = fn() { bar_laid_now().items }
  let slot = fn(n : Int) { bar_slot(w(), n) }
  holder.box(fn(row) {
    row
    .over(Is(true))
    .width(By(fn() { Some(w()) }))
    .height(Is(Some(bar_track)))
    .offset(By(fn() { (0.0, row_top()) }))
    .radius(Is(rad))
    .clips(Is(true))
    .ground_drawn(
      By(fn() {
        let t = bar_moment(row, Collapse, bar.collapse.ends_at())
        let c = bar.collapse_at(t)
        let dw = if c <= 0.0001 {
          0.0
        } else {
          bar_cur_capsule_w(w(), bar.k_at(t), c) - w()
        }
        { dx: 0.0, dy: 0.0, dw, dh: 0.0, corners: None }
      }),
    )
    .alpha(By(fn() { if bar.swap_at(bar_moment(row, Panel, bar.o.end())) is Some(_) { 0.0 } else { 1.0 } }))
    |> ignore
    row.each(at_once=true, items, fn(k) { k }, fn(p, key) {
      let key = key.untracked()
      let is_active = fn() {
        match bar_told_now.get() {
          Some({ active: Some(a), .. }) => a == key
          _ => false
        }
      }
      let x_at = fn(k : Double) {
        let items = items()
        bar_centres(w(), k, items.length())[items.search(key).unwrap_or(0)] - slot(items.length()) / 2.0
      }
      bar_at(p, fn() {
          bar_part_said(Notch) |> ignore
          x_at(bar.k_end())
        }, fn() { (bar_track - 44.0) / 2.0 }, fn() { slot(items().length()) }, fn() { 44.0 }, fn(at) {
        at
        .alpha(By(fn() {
          let c = bar.collapse_at(bar_moment(at, Collapse, bar.collapse.ends_at()))
          if c <= 0.0001 || is_active() {
            1.0
          } else {
            dclamp(1.0 - c / 0.30, 0.0, 1.0)
          }
        }))
        .scale(By(fn() {
          let c = bar.collapse_at(bar_moment(at, Collapse, bar.collapse.ends_at()))
          if c <= 0.0001 || is_active() {
            1.0
          } else {
            1.0 - 0.12 * c
          }
        }))
        |> ignore
        bar_moved(at, Notch, bar_k_until, fn(t) {
          let items = items()
          let idx = items.search(key).unwrap_or(0)
          let exp_cx = bar_centres(w(), bar.k_at(t), items.length())[idx]
          let c = bar.collapse_at(t)
          let orb_cx = bar_track / 2.0
          let cx = exp_cx + (orb_cx - exp_cx) * c
          (cx - slot(items.length()) / 2.0 - x_at(bar.k_end()), 0.0)
        })
        bar_face_node(at, key, Tints, fn(t) { bar_tint_at("bar:" + key, t) }, fn() { bar_tint_until("bar:" + key) })
      })
      |> ignore
    })
  })
  |> ignore
}

///|
/// The other bars, above this one, as the panel opens (rowsAlpha, rowsShift): each its places at rest across its row,
/// as faint and as low as the panel has them as each frame is drawn; none while it is closed, nor while a bar chosen
/// lands (bar_swap_node draws them going).
fn bar_rows_node(holder : @view.View, w : () -> Double) -> Unit {
  let slot = fn(n : Int) { bar_slot(w(), n) }
  holder.box(fn(rows) {
    rows.over(Is(true)) |> ignore
    rows.show(at_once=true,
      fn() {
        bar.mode.get() || bar.o.to > 0.001 || bar_moment(rows, Panel, bar.o.end()) != @double.infinity
      },
      fn(open) {
        open.over(Is(true)) |> ignore
        let look_at = fn(t : Double) {
          let o = bar.o.at(t).0
          (if bar.swap_at(t) is Some(_) { 0.0 } else { rows_alpha(o) }, rows_shift(o, bar_laid_now().reach))
        }
        open.alpha(By(fn() { look_at(bar_moment(open, Panel, bar.o.end())).0 })) |> ignore
        bar_moved(open, Panel, fn() { bar.o.end() }, fn(t) { (0.0, look_at(t).1) })
        // (each other bar by its place among the bars, at its row: n from the top)
        let others = fn() { bar_laid_now().others.mapi(fn(n, i) { (n, i) }) }
        open.each(at_once=true, others, fn(ni) { ni.1 }, fn(r, ni) {
          r.over(Is(true)) |> ignore
          let i = ni.untracked().1
          let n = fn() { ni.get().0 }
          let set = fn() { bar_laid_now().sets.get(i).unwrap_or([]) }
          r.each(at_once=true, set, fn(k) { k }, fn(p, key) {
            let key = key.untracked()
            let x = fn() { bar_centres(w(), 0.0, set().length())[set().search(key).unwrap_or(0)] - slot(set().length()) / 2.0 }
            let y = fn() { over + n().to_double() * bar_row + bar_row / 2.0 - 22.0 }
            bar_at(p, x, y, fn() { slot(set().length()) }, fn() { 44.0 }, fn(at) {
              bar_face_node(at, key, Tints, fn(t) { bar_tint_at("row:" + key, t) }, fn() { bar_tint_until("row:" + key) })
            })
            |> ignore
          })
        })
      },
    )
  })
  |> ignore
}

///|
/// A bar being chosen: the stack of bars slides down inside the closing glass, the chosen one into the bar's place,
/// what is not chosen cut off by the glass's edge. It starts as the rows and the bar were drawn (the rows' fade and
/// offset, each place as lit as it was) and comes to the bar's look as it lands, each frame as it is drawn; cut to the
/// glass as its top is drawn then, and to the panel's foot.
fn bar_swap_node(
  holder : @view.View,
  w : () -> Double,
  row_top : () -> Double,
  panel : () -> Double,
) -> Unit {
  let slot = fn(n : Int) { bar_slot(w(), n) }
  let bar_mid = fn() { row_top() + bar_track / 2.0 }
  holder.box(fn(b) {
    b.over(Is(true)) |> ignore
    b.show(at_once=true,
      fn() {
        bar_part_said(Notch) |> ignore
        b.drawn_while(fn(t) { bar.swap_at(t) is Some(_) }) != @double.infinity
      },
      fn(on) {
        on.over(Is(true)) |> ignore
        let s = bar.swap.unwrap()
        let until = fn() { dmax(bar.o.end(), bar_k_until()) }
        let now_at = fn(t : Double) {
          let o = bar.o.at(t).0
          let st = s.t(o)
          let (xs, y) = swap_at(s, o, w(), bar.k_at(t), row_top())
          (o, st, xs, y - (over + s.n.to_double() * bar_row + bar_row / 2.0), s.drop * (1.0 - st), s.alpha + (1.0 - s.alpha) * st)
        }
        let now = fn(n : @view.View) { now_at(bar_moment(n, Notch, until())) }
        let was = fn(id : String) { s.lit.get(id).unwrap_or(0.0) }
        // (the glass's top as it is drawn at a moment: what is over it cut off)
        let top = fn(t : Double) { bar_glass_top(bar_laid_now().reach, now_at(t).0) }
        let window = fn(f : (@view.View, (Double) -> Double) -> Unit) {
          bar_at(on, fn() { 0.0 }, fn() { 0.0 }, w, panel, fn(foot) {
            foot.clips(Is(true)) |> ignore
            bar_at(foot, fn() { 0.0 }, fn() { 0.0 }, w, panel, fn(win) {
              win.clips(Is(true)) |> ignore
              bar_moved(win, Notch, until, fn(t) { (0.0, top(t)) })
              f(win, top)
            })
            |> ignore
          })
          |> ignore
        }
        // the rest, leaving: the rows not chosen and the bar as it was, sliding down
        window(fn(win, top) {
          let laid_others : Array[Int] = []
          for i in 0..<s.sets.length() {
            if i != s.cur {
              laid_others.push(i)
            }
          }
          for n, i in laid_others {
            if i != s.i {
              let set = s.sets[i]
              for j, key in set {
                let x = fn() { bar_centres(w(), 0.0, set.length())[j] - slot(set.length()) / 2.0 }
                let y = fn() { over + n.to_double() * bar_row + bar_row / 2.0 - 22.0 }
                bar_at(win, x, y, fn() { slot(set.length()) }, fn() { 44.0 }, fn(at) {
                  at
                  .alpha(By(fn() { now(at).5 }))
                  |> ignore
                  bar_moved(at, Notch, until, fn(t) {
                    let n = now_at(t)
                    (0.0, n.3 + n.4 - top(t))
                  })
                  bar_face_node(at, key, Notch, fn(_) { was("row:" + key) }, fn() { -1.0 })
                })
                |> ignore
              }
            }
          }
          let laid_items = s.sets[s.cur]
          for j, key in laid_items {
            let x = fn() {
              bar_part_said(Notch) |> ignore
              bar_centres(w(), bar.k_end(), laid_items.length())[j] - slot(laid_items.length()) / 2.0
            }
            let y = fn() { bar_mid() - 22.0 }
            bar_at(win, x, y, fn() { slot(laid_items.length()) }, fn() { 44.0 }, fn(at) {
              bar_moved(at, Notch, until, fn(t) {
                let laid = bar_centres(w(), bar.k_end(), laid_items.length())[j]
                (bar_centres(w(), bar.k_at(t), laid_items.length())[j] - laid, now_at(t).3 - top(t))
              })
              bar_face_node(at, key, Notch, fn(_) { was("bar:" + key) }, fn() { -1.0 })
            })
            |> ignore
          }
        })
        // the chosen bar, inside the closing glass too: landed, as the bar's places are drawn, lit as it comes when it
        // is the place shown (bar_tell)
        window(fn(win, top) {
          let items = s.sets[s.i]
          let active = match bar.told {
            Some({ active: Some(a), .. }) => a
            _ => ""
          }
          for j, key in items {
            let x = fn() {
              bar_part_said(Notch) |> ignore
              bar_centres(w(), bar.k_end(), items.length())[j] - slot(items.length()) / 2.0
            }
            let y = fn() { bar_mid() - 22.0 }
            bar_at(win, x, y, fn() { slot(items.length()) }, fn() { 44.0 }, fn(at) {
              at
              .alpha(By(fn() { now(at).5 }))
              |> ignore
              bar_moved(at, Notch, until, fn(t) {
                let n = now_at(t)
                let laid = bar_centres(w(), bar.k_end(), items.length())[j]
                let dx = if j < n.2.length() { n.2[j] - laid } else { 0.0 }
                (dx, n.3 + n.4 + over + s.n.to_double() * bar_row + bar_row / 2.0 - bar_mid() - top(t))
              })
              let end = if active == key { 1.0 } else { 0.0 }
              let from = was("row:" + key)
              bar_face_node(
                at,
                key,
                Notch,
                fn(t) {
                  let st = s.t(bar.o.at(t).0)
                  if st >= 1.0 {
                    end
                  } else if st <= 0.0 {
                    from
                  } else {
                    from + (end - from) * st
                  }
                },
                fn() { bar.o.end() },
              )
            })
            |> ignore
          }
        })
      },
    )
  })
  |> ignore
}
