// A toggle group (切换组) as nodes of the window's tree, made once: toggle buttons side by side in a quiet track, each
// its words, its icon and words, or its icon alone; those on lifted out of the track (the theme's lifted, a hairline
// round it), another under the hand on a faint ground. The track and its buttons follow the corner rule: a track a
// small corner round, its buttons as far in as the rule lets them stand and concentric with it (`Rounded`), or a capsule
// track round capsules (`Pill`). What it is to the hand, the keyboard and a screen reader is mbui's toggle group
// (@headless.toggle_group: a group of toggle buttons read out pressed while on, one stop of Tab's, the arrow keys, Home
// and End along it, Space or Enter turning the one the keyboard is on; at most one on at a time, `Single`, or each its
// own); here its look.

///|
/// How big a toggle group's buttons are: 24 high (`Compact`) or 28 (`Regular`).
#derive(Eq, Debug)
pub(all) enum ToggleGroupSize {
  Compact
  Regular
}

///|
/// A toggle group's shape: a small corner round its buttons concentric with it (`Rounded`), or capsules (`Pill`).
#derive(Eq, Debug)
pub(all) enum ToggleGroupShape {
  Rounded
  Pill
}

///|
/// A button of a toggle_group_node (toggle_item): its key, its words (read out its name, shown unless `icon_only`), its
/// icon ("" none), and whether it alone takes no press.
pub struct ToggleItem[K] {
  priv key : K
  priv label : () -> String
  priv icon : String
  priv icon_only : Bool
  priv disabled : () -> Bool
}

///|
/// A button of `key` called `label`, `icon` before its words ("" none) or alone (`icon_only`: its words read out, not
/// shown); `disabled` while it alone takes no press and no focus.
pub fn[K] toggle_item(
  key : K,
  label : () -> String,
  icon? : String = "",
  icon_only? : Bool = false,
  disabled? : () -> Bool = fn() { false },
) -> ToggleItem[K] {
  { key, label, icon, icon_only, disabled }
}

///|
/// The buttons of `items` side by side in `parent`, a toggle group called `label`: each on as `is_on` says of its key,
/// `turn` told the key of one pressed and what it is to be (`Single`: the caller turns the one on before off); `kind`
/// at most one on or each its own; `size` and `shape` its look; `disabled` while none of it takes a press (faded). The
/// node.
#callsite(autofill(loc))
pub fn[K] toggle_group_node(
  parent : @view.View,
  label : () -> String,
  items : Array[ToggleItem[K]],
  is_on : (K) -> Bool,
  turn : (K, Bool) -> Unit,
  kind? : @headless.ToggleGroupKind = Multiple,
  size? : ToggleGroupSize = Regular,
  shape? : ToggleGroupShape = Rounded,
  disabled? : () -> Bool = fn() { false },
  loc~ : SourceLoc,
) -> @view.View {
  let h = match size {
    Compact => toggle_group_compact_h
    Regular => toggle_group_h
  }
  let has_words = items.iter().any(fn(it) { !it.icon_only })
  @headless.toggle_group(made_for=loc, parent, label, is_on, turn, kind~, disabled~, fn(track, g) {
    let h_now = fn() {
      if has_words {
        track.words_redone() |> ignore
        dmax(h, node_sp(track, theme().t.ui_line).ceil() + 2.0)
      } else {
        h
      }
    }
    // (the track's corner, and its buttons' concentric with it toggle_group_in in)
    let outer = fn() {
      match shape {
        Rounded => small_corner
        Pill => h_now() / 2.0 + toggle_group_in
      }
    }
    let inner = fn() {
      match shape {
        Rounded => @ui.concentric(small_corner, toggle_group_in)
        Pill => h_now() / 2.0
      }
    }
    style_node(track, fn() { toggle_group_track })
    track
    .radius(By(outer))
    .alpha(By(fn() { if g.disabled() { toggle_group_off_alpha } else { 1.0 } }))
    |> ignore
    for item in items {
      g.item(track, item.key, item.label, disabled=item.disabled, made_for=loc, fn(b, t) {
        let lit = fn() { !t.disabled() && (t.hovered() || t.pressed()) }
        let pressed = fn() { !t.disabled() && t.pressed() }
        let on_way = @motion.NodeWay::new(if @signals.untracked(fn() { t.on() }) { 1.0 } else { 0.0 })
        let lit_way = @motion.NodeWay::new(if @signals.untracked(lit) { 1.0 } else { 0.0 })
        let press_way = @motion.NodeWay::new(if @signals.untracked(pressed) { 1.0 } else { 0.0 })
        b.reacts(at_start=false, fn() { t.on() }, fn(on) { on_way.go_ms(b, if on { 1.0 } else { 0.0 }, dur_ms) })
        b.reacts(at_start=false, lit, fn(on) { lit_way.go_ms(b, if on { 1.0 } else { 0.0 }, dur_ms) })
        b.reacts(at_start=false, pressed, fn(on) { press_way.go_ms(b, if on { 1.0 } else { 0.0 }, dur_ms) })
        style_node(b, fn() { if item.icon_only { toggle_group_icon_button } else { toggle_group_button } })
        b
        .focus_ring_theme()
        .height(By(fn() { Some(h_now()) }))
        .min_width(By(fn() { Some(h_now()) }))
        .radius(By(inner))
        .ground(By(fn() {
          let on_w = dclamp(on_way.shown(b), 0.0, 1.0)
          let lit_w = dclamp(lit_way.shown(b), 0.0, 1.0)
          if on_w >= 0.999 {
            @ui.tree_theme().lifted
          } else if on_w <= 0.001 {
            if lit_w > 0.001 {
              alpha(theme().p.text, toggle_group_lit * lit_w)
            } else {
              0L
            }
          } else {
            let under = if lit_w > 0.001 { alpha(theme().p.text, toggle_group_lit * lit_w) } else { 0L }
            @glass.over(under, alpha(@ui.tree_theme().lifted, on_w))
          }
        }))
        .scale(By(fn() { 1.0 - toggle_group_press_dip * dclamp(press_way.shown(b), 0.0, 1.0) }))
        .alpha(By(fn() { if (item.disabled)() && !g.disabled() { toggle_group_off_alpha } else { 1.0 } }))
        |> ignore
        let ink = fn(n : @view.View) {
          let w = dmax(dclamp(on_way.shown(n), 0.0, 1.0), dclamp(lit_way.shown(n), 0.0, 1.0))
          if w >= 0.999 {
            theme().p.text
          } else if w <= 0.001 {
            theme().p.muted
          } else {
            @glass.lerp_color(theme().p.muted, theme().p.text, w)
          }
        }
        if item.icon != "" {
          let ic = icon_node(b, item.icon, toggle_group_icon, Is(0L))
          ic.tint(By(fn() { ink(ic) })) |> ignore
        }
        if !item.icon_only {
          let wn = words_node(b, item.label, fn() { toggle_group_words })
          wn.ink(By(fn() { ink(wn) })) |> ignore
        }
      })
      |> ignore
    }
  })
}

///|
/// A regular button's height, a compact one's; how far in from the track's edges its buttons stand (the nearest the
/// corner rule lets what follows a corner stand: corner_fit's near).
let toggle_group_h : Double = 28.0

///|
let toggle_group_compact_h : Double = 24.0

///|
let toggle_group_in : Double = 4.0

///|
/// An icon's size; the ink's share on a button under the hand; how far what is disabled is seen.
let toggle_group_icon : Double = 16.0

///|
let toggle_group_lit : Double = 0.06

///|
let toggle_group_off_alpha : Double = 0.55

///|
/// Gentle paint-only scale dip while a toggle button is pressed.
let toggle_group_press_dip : Double = 0.03

///|
/// The track: a row, its buttons 2 apart, 4 in, on a quiet ground.
// kept across runs: a value (no field of it changes)
let toggle_group_track : @ui.Style = @ui.css("row p=S1 gap=S0_5 bg=A(Fg,O5) align=ACenter")

///|
/// A button with words: 10 in from its sides, its icon and words 6 apart, in its middle.
// kept across runs: a value (no field of it changes)
let toggle_group_button : @ui.Style = @ui.css("row px=S2_5 gap=S1_5 align=ACenter justify=JCenter")

///|
/// A button of an icon alone: square, its icon in its middle.
// kept across runs: a value (no field of it changes)
let toggle_group_icon_button : @ui.Style = @ui.css("row align=ACenter justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let toggle_group_words : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Muted, wrap=false)
