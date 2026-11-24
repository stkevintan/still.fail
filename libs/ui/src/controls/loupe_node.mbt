// The loupe (iOS's text loupe, Android's Magnifier) as a node of the window's tree: what a finger hides as it drags
// what needs seeing where it is (@ui.finger_reads: a field's caret or the ends of what is picked by their handles, a
// long press's word slid on) shown larger over it (View::magnifies), in a capsule of the glass a switch's knob held is
// (glass_knob), loupe_lift over the finger, over all else of the window (View::over_all), taking no press nor the
// focus. It is the knob's lens and the bar's ball, not one of its own (its measures at this file's foot): it comes in
// as the knob held does (lift_spring, larger by knob_lens_grow, fading in), follows the finger as the ball does
// (follow_spring) and is drawn out by its speed as the ball is (speed_stretch); let go, it goes where it is. Laid out
// where the finger last had it, drawn where its ways have it.

///|
/// The loupe over all else of the window in `root` (one of what the root holds: View::over_all), while `on` holds (else
/// nothing is read), of what the finger reads.
#callsite(autofill(loc))
pub fn loupe_node(root : @view.View, on : () -> Bool, loc~ : SourceLoc) -> Unit {
  @glass.liquid_loupe_node(
    root,
    on,
    @ui.finger_reads,
    bg=fn() { theme().p.bg },
    solid=fn() { glass_knob().solid },
    shadow_color=fn() { ui_theme_now().shadow },
    width=loupe_w,
    height=loupe_h,
    zoom=loupe_zoom,
    lift=loupe_lift,
    side_inset=loupe_side,
    grow=knob_lens_grow,
    shadow_blur=lens_shadow,
    shadow_y=lens_shadow_y,
    loc~,
  )
}

///|
/// How much larger the loupe shows what is under the finger, its size, how far over the finger its middle is, and how
/// far in from the window's sides it stays; how much larger a knob's lens grows as it comes (kit's loupe.mbt's).
let loupe_zoom : Double = 1.35

///|
let loupe_w : Double = 124.0

///|
let loupe_h : Double = 48.0

///|
let loupe_lift : Double = 92.0

///|
let loupe_side : Double = 8.0

///|
let knob_lens_grow : Double = 1.25

///|
/// A lens's shadow, held all the way: its blur and how far down (kit's toggle.mbt's, a sliding group's lens's).
let lens_shadow : Double = 0.0

///|
let lens_shadow_y : Double = 0.0
