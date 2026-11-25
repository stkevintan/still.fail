// A continuous value slider as a node of the window's tree: thin sf-ui theme wrapper over `@glass.liquid_slider_node`
// (unified iOS 26 40×24 capsule thumb, 6→10pt elastic track thickening in paint layer, lazy-mounted 1.5× clear liquid
// glass refraction loupe 60×36pt, zero relayout during drag). Optionally renders a rolling numeric value bubble above
// the lifted lens while held, in `tips` layer (unclipped by ancestors) when provided.

///|
/// A slider in `parent`, called `label`, at `value()` along `min` … `max` in steps of `step` (`change` told the value
/// it is moved to); faded and taking nothing while `disabled`. `format` how its value, rounded to a whole number, is
/// read out and written in its bubble (by default its digits); `bubble` whether the bubble shows while it is held, in
/// `tips`' layer where that is given (over all of the window, beside the thumb), else over the thumb in the slider
/// itself. As wide as what holds it gives it. The node.
#callsite(autofill(loc))
pub fn value_slider_node(
  parent : @view.View,
  label : () -> String,
  value : () -> Double,
  change : (Double) -> Unit,
  min? : Double = 0.0,
  max? : Double = 100.0,
  step? : Double = 1.0,
  disabled? : () -> Bool = fn() { false },
  format? : (Int) -> String = fn(n) { n.to_string() },
  bubble? : Bool = true,
  tips? : TipLayer,
  on_commit? : (Double) -> Unit,
  loc~ : SourceLoc,
) -> @view.View {
  let dd = @glass.DampedDrag::new(
    @signals.untracked(value),
    lo=min,
    hi=max,
    held_scale=@glass.slider_thumb_held_scale,
  )
  parent.box(made_for=loc, fn(wrap) {
    wrap
    .height(Is(Some(vslider_h)))
    .min_width(Is(Some(vslider_least_w)))
    |> ignore
    wrap.by_room(fn(inner, room) {
      inner
      .row(Is(true))
      .height(Is(Some(vslider_h)))
      .lines_up(Is(Some(Middle)))
      |> ignore
      let sl = @glass.liquid_slider_node(
        inner,
        value,
        change,
        label,
        least=min,
        most=max,
        step~,
        disabled~,
        track_h=@glass.slider_track_h,
        thumb_w_px=@glass.slider_thumb_w,
        thumb_h_px=@glass.slider_thumb_h,
        track_color=fn() { theme().p.line_strong },
        fill_color=fn() { theme().p.accent },
        value_text=fn(x) { format(x.round().to_int()) },
        flush=true,
        drag=dd,
        on_commit?,
        loc~,
      )
      sl.grow(Is(1.0)) |> ignore
      let hold = fn(n : @view.View) { dclamp(dd.pressed(n), 0.0, 1.0) }
      let active = fn(n : @view.View) { !disabled() && (dd.pressing() || dd.pressed(n) > 0.001) }
      let thumb_x = fn(n : @view.View) {
        let span_px = dmax(0.0, room.width() - @glass.slider_thumb_w)
        dclamp(dd.progress(n), 0.0, 1.0) * span_px
      }
      let bubble_in = fn(o : @view.View) {
        o
        .row(Is(true))
        .padding(Is((vslider_bubble_pad, vslider_bubble_pad / 2.0, vslider_bubble_pad, vslider_bubble_pad / 2.0)))
        .radius(Is(small_corner))
        .ground(By(fn() { theme().p.text }))
        .alpha(By(fn() { seen_at(hold(o)) }))
        |> ignore
        rolling_number_node(o, fn() { value().round().to_int() }, format~, style=fn() { vslider_bubble_words }, rolls=fn() {
          !dd.pressing()
        })
        |> ignore
      }
      match (bubble, tips) {
        (true, Some(layer)) => {
          // Invisible paint-layer anchor tracking the thumb so `tips` popover stays unclipped with zero relayout.
          let anchor = inner.box(fn(a) {
            a
            .over(Is(true))
            .points(Is(false))
            .offset(Is((0.0, 0.0)))
            .width(Is(Some(@glass.slider_thumb_w)))
            .height(Is(Some(vslider_h)))
            .moved_by(fn(_w, _h, _at) { (thumb_x(a), 0.0) }, fn(_w, _h) { 0.0 })
            |> ignore
          })
          let made = Ref(false)
          let make = fn() {
            guard !made.val && (layer.layer)() is Some(top) else { return }
            made.val = true
            let holder = top.box(fn(h) { h.over(Is(true)) |> ignore }).lives_with(anchor)
            holder.show(fn() { active(holder) }, at_once=true, fn(o) {
              o
              .beside(anchor.id(), side=Top, along=Middle, offset=vslider_bubble_gap)
              .scale(By(fn() { dmin(1.0, slider_bubble_scale_from + (1.0 - slider_bubble_scale_from) * hold(o)) }), about=FromBeside)
              |> ignore
              bubble_in(o)
            })
          }
          make()
          inner.reacts(fn() { dd.pressing() }, at_start=false, fn(down) { if down { make() } })
        }
        (true, None) =>
          inner.show(fn() { active(inner) }, at_once=true, fn(o) {
            o
            .over(Is(true), edges=(None, Some(-vslider_bubble_gap), None, None))
            .points(Is(false))
            .scale(By(fn() { dmin(1.0, slider_bubble_scale_from + (1.0 - slider_bubble_scale_from) * hold(o)) }), about=At(0.5, 1.0))
            .moved_by(
              fn(w, h, _at) { (thumb_x(o) + @glass.slider_thumb_w / 2.0 - w / 2.0, -h) },
              fn(_w, _h) { 0.0 },
            )
            |> ignore
            bubble_in(o)
          })
        _ => ()
      }
    })
    |> ignore
  })
}

///|
/// Outer slider row height (28pt centering the 24pt capsule thumb) and minimum width.
let vslider_h : Double = 28.0

///|
let vslider_least_w : Double = 120.0

///|
/// Starting scale of the slider value bubble when pressed (0.94 -> 1.0, avoiding abrupt pop).
let slider_bubble_scale_from : Double = 0.94

///|
/// Vertical gap above the slider row so the value bubble clears the 36pt lifted liquid glass lens (4pt top overhang + 6pt gap).
let vslider_bubble_gap : Double = 10.0

///|
let vslider_bubble_pad : Double = 8.0

///|
let vslider_bubble_words : @ui.TextStyle = @ui.text_style(size=Ui, color=Bg)
