// The bar over words a finger picked in a message (sfbase's pick_bar, MessagePick.kt) as a node of the window's tree,
// made once: a single-layer liquid glass capsule 40 high (`glass_menu()`, falling back to `panel_ground()` + hairline
// `control_edge_w` border under `MBUI_GLASS=solid`) with outside-only `glass_control_shadow()`; its buttons 32 high and
// round, each its icon (where it has one) and its words; after a thin line 16 high, what it does with the message, each
// a mark alone 32 round, read out by its words. Each a ripple where it is pressed, over mbui's headless button.

///|
/// One of the bar's buttons: its words (read out, and shown where it is no `mark`), its icon ("" none), whether it is a
/// mark alone after the line, and what pressing it does.
pub(all) struct PickBarItem {
  label : String
  icon : String
  mark : Bool
  press : () -> Unit
}

///|
/// The bar in `parent` with `items` in their order (those that are no mark, then a line and the marks, the line only
/// where there is a mark): what is picked anew makes a bar anew, so what it offers is said as it is made. The node:
/// the capsule.
#callsite(autofill(loc))
pub fn pick_bar_node(
  parent : @view.View,
  items : Array[PickBarItem],
  compact? : Bool = false,
  loc~ : SourceLoc,
) -> @view.View {
  let bar = @glass.liquid_pill_group_node(
    parent,
    height=pick_bar_h,
    pad=pick_bar_pad,
    gap=0.0,
    solid=panel_ground,
    fn(bar) {
      for it in items {
        if !it.mark {
          pick_bar_button(bar, it, compact~) |> ignore
        }
      }
      let marks = items.filter(fn(it) { it.mark })
      if !marks.is_empty() {
        bar.box(fn(r) { style_node(r, fn() { pick_bar_rule }) }) |> ignore
      }
      for it in marks {
        pick_bar_button(bar, it, compact~) |> ignore
      }
    },
    loc~,
  )
  bar
  .edge(By(fn() { if bar.glass_solid() { (control_edge_w, theme().p.line) } else { (0.0, 0L) } }))
  .shadow(By(fn() { glass_control_shadow() }))
  |> ignore
  bar
}

///|
/// A button of the bar (pick_bar's button, its mark): its ground the page's while pressed (its ripple), its icon 15
/// and its words in the ink.
#callsite(autofill(loc))
fn pick_bar_button(
  parent : @view.View,
  it : PickBarItem,
  compact? : Bool = false,
  loc~ : SourceLoc,
) -> @view.View {
  @headless.button(made_for=loc, parent, fn() { it.label }, fn(_) { (it.press)() }, fn(v, b) {
    style_node(v, fn() {
      if it.mark {
        pick_bar_mark_look
      } else if compact {
        pick_bar_button_compact_look
      } else {
        pick_bar_button_look
      }
    })
    if it.icon != "" {
      icon_node(v, it.icon, pick_bar_icon, By(fn() { theme().p.text })) |> ignore
    }
    if !it.mark {
      words_node(v, fn() { it.label }, fn() { pick_bar_words }) |> ignore
    }
    // (its ripple: MessagePick.kt's clip(Smooth(16)).clickable, plus outer liquid glass pill GPU spot)
    @glass.bind_pill_press(v)
    let rippled = press_look(v, Is(pick_bar_round), fn() { false })
    v.gesture(
      @ui.touch_slop(),
      press=fn(d) {
        if !b.disabled() {
          (rippled.down)(d)
        }
      },
      tap=fn(d) {
        if !b.disabled() {
          (rippled.tapped)(d)
          if v.finger_target(d.wx, d.wy) {
            b.press()
          }
        }
      },
      drag=fn(d) {
        // (a mouse's moved on it past the slop: still a press as it is let go on it, as a click is)
        if d.kind == Up && @ui.pointing() is Mouse && v.finger_target(d.wx, d.wy) {
          b.press()
        }
      },
    )
    |> ignore
  })
}

///|
/// One action in a desktop selection bar (`pick_bar_desk_node`): its reactive label (shown and read out,
/// staying live across language/word-table switches), optional 15pt icon (`""` for none), and activation callback
/// receiving the button's window rectangle `(x, y, w, h)` synchronously at activation time.
pub struct PickBarAction {
  label : () -> String
  icon : String
  press_at : ((Double, Double, Double, Double)) -> Unit
}

///|
/// Builds a `PickBarAction` for `pick_bar_desk_node`.
pub fn pick_bar_action(
  label : () -> String,
  icon? : String = "",
  press_at : ((Double, Double, Double, Double)) -> Unit,
) -> PickBarAction {
  { label, icon, press_at }
}

///|
/// Desktop selection pill bar in `parent` with `actions` separated by hairline `pick_bar_rule`
/// dividers (none when there is only one action). Matches mobile `pick_bar_node` proportions and optics
/// (`40pt` tall, `pad=4pt`, `floating=false` → `liquid_bar_pill_glass` instead of oversized `liquid_floating_glass`,
/// `32pt` round buttons, `panel_ground` + `control_edge_w` in `MBUI_GLASS=solid`, `glass_control_shadow`)
/// and registers via `floating_host_lend`. Returns the outer capsule node.
#callsite(autofill(loc))
pub fn pick_bar_desk_node(
  parent : @view.View,
  actions : Array[PickBarAction],
  loc~ : SourceLoc,
) -> @view.View {
  let bar = @glass.liquid_pill_group_node(
    parent,
    height=pick_bar_h,
    pad=pick_bar_pad,
    gap=0.0,
    floating=false,
    solid=panel_ground,
    shadow=glass_control_shadow,
    solid_edge=fn() { (control_edge_w, theme().p.line) },
    fn(bar) {
      for i, act in actions {
        if i > 0 {
          bar.box(fn(sep) { style_node(sep, fn() { pick_bar_rule }) }) |> ignore
        }
        pick_bar_desk_button(bar, act, loc~) |> ignore
      }
    },
    loc~,
  )
  floating_host_lend(bar)
  bar
}

///|
/// A button of the desktop selection bar (`pick_bar_desk_node`): matches mobile `pick_bar_button`
/// (`32pt` high, `15pt` icon, `Ui` words, `16pt` round) with hover ground, inset focus ring,
/// touch-only ripple, mouse drag-past-slop click tolerance, and synchronous `placed_window_now()` delivery.
#callsite(autofill(loc))
fn pick_bar_desk_button(
  parent : @view.View,
  act : PickBarAction,
  loc~ : SourceLoc,
) -> @view.View {
  @headless.button(
    made_for=loc,
    parent,
    act.label,
    fn(v) { (act.press_at)(v.placed_window_now()) },
    fn(v, b) {
      style_node(v, fn() { pick_bar_button_look })
      hover_ground_node(v)
      focus_ring_node(v)
      if act.icon != "" {
        icon_node(v, act.icon, pick_bar_icon, By(fn() { theme().p.text })) |> ignore
      }
      words_node(v, act.label, fn() { pick_bar_words }) |> ignore
      @glass.bind_pill_press(v)
      let rippled = press_look(loc~, v, Is(pick_bar_round), fn() { false }, pointer=false)
      v.gesture(
        @ui.touch_slop(),
        press=fn(d) {
          if !b.disabled() && @ui.pointing() is Finger {
            (rippled.down)(d)
          }
        },
        tap=fn(d) {
          if !b.disabled() {
            if @ui.pointing() is Finger {
              (rippled.tapped)(d)
            }
            if v.finger_target(d.wx, d.wy) {
              b.press()
            }
          }
        },
        drag=fn(d) {
          // (a mouse's moved on it past the slop: still a press as it is let go on it, as a click is)
          if d.kind == Up && @ui.pointing() is Mouse && v.finger_target(d.wx, d.wy) {
            b.press()
          }
        },
      )
      |> ignore
    },
  )
}

///|
/// A button (pick_button's): 32 high, 12 in, its icon 5 before its words, round.
// kept across runs: a value (no field of it changes)
let pick_bar_button_look : @ui.Style = @ui.css("row min_h=S8 px=S3 gap=S1_25 radius=Full align=ACenter")

///|
/// A compact button for tight narrow viewports (e.g. 320pt at 1.3x font scale with 4 actions): 8 in, round.
// kept across runs: a value (no field of it changes)
let pick_bar_button_compact_look : @ui.Style = @ui.css("row min_h=S8 px=S2 gap=S1 radius=Full align=ACenter")

///|
/// A mark alone (pick_mark_button's): 32 round, its icon in its middle.
// kept across runs: a value (no field of it changes)
let pick_bar_mark_look : @ui.Style = @ui.css("h=S8 w=S8 radius=Full align=ACenter justify=JCenter")

///|
/// The line before the marks (pick_bar_rule's): 1 wide, 16 high, 4 off what is beside it.
// kept across runs: a value (no field of it changes)
let pick_bar_rule : @ui.Style = rule_down.then(@ui.css("h=S4 mx=S1"))

///|
// kept across runs: a value (no field of it changes)
let pick_bar_words : @ui.TextStyle = @ui.text_style(size=Ui, color=Fg, wrap=false)

///|
let pick_bar_h : Double = 40.0

///|
let pick_bar_pad : Double = 4.0

///|
let pick_bar_icon : Double = 15.0

///|
let pick_bar_round : Double = 16.0
