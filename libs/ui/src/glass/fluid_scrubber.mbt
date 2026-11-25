// Fluid Scrubber Track (Apple AVPlayer / Apple Music style): a thumb-free pill track that swells smoothly in place
// on hover (5pt -> 7.5pt) and press/drag (7.5pt -> 10pt) via paint-layer `ground_drawn` (laid == 0, 0 glass layers).
// Both buffered and active fill segments nest inside the clipping base track (`track.clips(true)`), which pushes its
// live `ground_drawn` capsule SDF clip so `fill` and `buffered` stay strictly inside `track_capsule ∩ {x <= w * p}`
// with exact right-edge accuracy at every progress (including 1% on a 72pt volume bar) and zero vertical overflow.

///|
/// Visual configuration for `fluid_scrubber_look`, decoupling fluid track/buffered/fill/focus
/// painting from gesture and media state handling.
pub(all) struct ScrubberLook {
  rest_h : Double
  hover_h : Double
  active_h : Double
  track_color : () -> Int64
  fill_color : () -> Int64
  buffered : (() -> Double)?
  buffered_color : (() -> Int64)?
  focus_shown : (() -> Bool)?
  focus_color : (() -> Int64)?
  disabled : () -> Bool
}

///|
/// Construct a `ScrubberLook` with Apple AVPlayer-style fluid scrubber defaults (5pt rest, 7.5pt hover, 10pt active).
pub fn ScrubberLook::new(
  heights? : (Double, Double, Double) = (5.0, 7.5, 10.0),
  track_color? : () -> Int64 = fn() { colors().track },
  fill_color? : () -> Int64 = fn() { colors().accent },
  buffered? : (() -> Double)? = None,
  buffered_color? : (() -> Int64)? = None,
  focus_shown? : (() -> Bool)? = None,
  focus_color? : (() -> Int64)? = None,
  disabled? : () -> Bool = fn() { false },
) -> ScrubberLook {
  let (rest_h, hover_h, active_h) = heights
  {
    rest_h,
    hover_h,
    active_h,
    track_color,
    fill_color,
    buffered,
    buffered_color,
    focus_shown,
    focus_color,
    disabled,
  }
}

///|
/// Gesture-free fluid scrubber track primitive: renders a thumb-free capsule track, optional full-width
/// buffered segment, active progress fill, and optional keyboard focus ring. `progress` and `swell`
/// (0.0 rest, 0.5 hover, 1.0 active) take the painted `@view.View` for FPS invariance and idle skipping.
/// All thickness changes run in the paint layer (`ground_drawn`) with `laid == 0` and 0 glass layers.
#callsite(autofill(loc))
pub fn fluid_scrubber_look(
  parent : @view.View,
  progress : (@view.View) -> Double,
  swell : (@view.View) -> Double,
  look : ScrubberLook,
  loc~ : SourceLoc,
) -> Unit {
  parent.by_room(loc~, fn(inner, room) {
    inner.alpha(By(fn() { if (look.disabled)() { 0.5 } else { 1.0 } })) |> ignore
    let w = fn() { room.width() }
    let bh = fn() { room.height().unwrap_or(look.active_h) }
    let track_h_at = fn(n : @view.View) -> Double {
      if @ui.reduced_motion() {
        look.rest_h
      } else {
        let s = clamp(swell(n), 0.0, 1.0)
        if s <= 0.5 {
          lerp(look.rest_h, look.hover_h, s * 2.0)
        } else {
          lerp(look.hover_h, look.active_h, (s - 0.5) * 2.0)
        }
      }
    }
    // 1. Base capsule track (clips children to its live `ground_drawn` capsule SDF)
    inner.box(fn(track) {
      track
      .over(Is(true))
      .points(Is(false))
      .clips(Is(true))
      .width(By(fn() { Some(w()) }))
      .height(By(fn() { Some(bh()) }))
      .ground(By(look.track_color))
      .ground_drawn(By(fn() {
        let h = track_h_at(track)
        let box_h = bh()
        let cr = h / 2.0
        { dx: 0.0, dy: (box_h - h) / 2.0, dw: 0.0, dh: h - box_h, corners: Some((cr, cr, cr, cr)) }
      }))
      |> ignore
      // 2. Optional full-width buffered segment (0% hidden, 100%+ clamped to w(), clipped by track capsule)
      match look.buffered {
        Some(buf_fn) =>
          track.box(fn(buf) {
            let buf_w = fn() { w() * clamp(buf_fn(), 0.0, 1.0) }
            buf
            .over(Is(true))
            .points(Is(false))
            .width(By(fn() { Some(w()) }))
            .height(By(fn() { Some(bh()) }))
            .alpha(By(fn() { if buf_w() <= 0.0 { 0.0 } else { 1.0 } }))
            .ground(By(fn() {
              match look.buffered_color {
                Some(f) => f()
                None => (look.track_color)()
              }
            }))
            .ground_drawn(By(fn() {
              let h = track_h_at(buf)
              let box_h = bh()
              { dx: 0.0, dy: (box_h - h) / 2.0, dw: buf_w() - w(), dh: h - box_h, corners: Some((0.0, 0.0, 0.0, 0.0)) }
            }))
            |> ignore
          })
          |> ignore
        None => ()
      }
      // 3. Active progress fill (full-width 1:1 with progress, clipped by track capsule)
      track.box(fn(fill) {
        let fill_w = fn(n : @view.View) { w() * clamp(progress(n), 0.0, 1.0) }
        fill
        .over(Is(true))
        .points(Is(false))
        .width(By(fn() { Some(w()) }))
        .height(By(fn() { Some(bh()) }))
        .alpha(By(fn() { if fill_w(fill) <= 0.0 { 0.0 } else { 1.0 } }))
        .ground(By(look.fill_color))
        .ground_drawn(By(fn() {
          let h = track_h_at(fill)
          let box_h = bh()
          { dx: 0.0, dy: (box_h - h) / 2.0, dw: fill_w(fill) - w(), dh: h - box_h, corners: Some((0.0, 0.0, 0.0, 0.0)) }
        }))
        |> ignore
      })
      |> ignore
    })
    |> ignore
    // 4. Optional keyboard focus ring (sibling of track so 2pt outset pill is never clipped by track)
    match look.focus_shown {
      Some(shown_fn) =>
        inner.show(shown_fn, fn(ring) {
          ring
          .over(Is(true))
          .points(Is(false))
          .width(By(fn() { Some(w()) }))
          .height(By(fn() { Some(bh()) }))
          .edge(By(fn() {
            let col = match look.focus_color {
              Some(f) => f()
              None => colors().accent
            }
            (2.0, col)
          }))
          .ground_drawn(By(fn() {
            let h = track_h_at(ring) + 4.0
            let box_h = bh()
            let cr = h / 2.0
            { dx: -2.0, dy: (box_h - h) / 2.0, dw: 4.0, dh: h - box_h, corners: Some((cr, cr, cr, cr)) }
          }))
          |> ignore
        })
      None => ()
    }
  })
  .fills_across(Is(true))
  .grow(Is(1.0))
  |> ignore
}
