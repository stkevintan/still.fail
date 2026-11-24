// Ported from Kyant0/AndroidLiquidGlass (Apache-2.0): catalog/components/LiquidSlider.kt. A track 6 high across all of
// its width, a capsule in the track's grey, filled in the accent up to its value; its thumb a white capsule 40 × 24 over
// it, its middle at the value, held within a quarter of itself of the track's ends. Held, the thumb turns to glass (its
// white and blur of 8 receding as its lens comes up, 10 deep bending by up to 14, the colours split, its Ambient
// highlight and its InnerShadow of 4), grows by half again and is squeezed as it goes by how fast (velocity / 10). The
// thumb is dragged by as much as the finger moves; a tap on the track sends it there as a hand would (pressed, sent,
// let go). Its keys and a screen reader's steps are mbui's headless slider's.
//
// The catalog's lens also sees the track scaled under it (a combined backdrop): mbui's glass sees the track as it is.

///|
/// The thumb's glass, held `p` (Native iOS 27.0 clear droplet loupe: paraxial bevel refraction, pinchWeight == 0).
fn slider_glass(p : Double) -> @paint.Glass {
  let p = clamp(p, 0.0, 1.0)
  @paint.Glass::liquid(
    blur=0.0,
    tint=0xFFFFFF00L,
    solid=white,
    saturation=1.0,
    rim=1.0 * p,
    bezel=9.0 * p,
    refraction=9.0 * p,
    chroma=0.0,
    merge=0.0,
    adaptive=false,
    zoom=1.0,
    droplet_role=1,
  )
}

///|
/// Where the thumb's left is along a track `w` wide at `progress` (0-1) of it: its middle there, held within a quarter
/// of itself of the ends; or, `flush` (a labeled thumb, a value slider's), meeting either end of the track at the ends
/// and evenly between, so the thumb stays in the track and every stop is as far from the next (a middle clamped short
/// of the ends put the first and last stops nearer their neighbours than the rest).
fn slider_thumb_x_for(w : Double, tw : Double, progress : Double, flush : Bool) -> Double {
  if flush {
    slider_travel_at(w, tw / 2.0, progress) - tw / 2.0
  } else {
    let hi = w - tw * 3.0 / 4.0
    let lo = -tw / 4.0
    if hi < lo {
      lo
    } else {
      clamp(-tw / 2.0 + w * progress, lo, hi)
    }
  }
}

///|
/// How far past its own top and foot a thumb `thumb_h` high reaches while held (grown; how fast it goes only flattens
/// it): the room what holds it keeps clear round it, or the thumb is cut where it is held.
pub fn slider_held_reach(thumb_h : Double) -> Double {
  thumb_h * (slider_thumb_held_scale - 1.0) / 2.0
}

///|
/// Where the middle of a flush thumb is at `progress` (0-1) of a track `w` wide, `half` in from either end at the ends.
fn slider_travel_at(w : Double, half : Double, progress : Double) -> Double {
  let half = dmin(half, w / 2.0)
  half + (w - 2.0 * half) * clamp(progress, 0.0, 1.0)
}

///|
/// Magnetic lean fraction toward the finger while dragging between discrete stops (matching sf-ui stops_node).
let slider_stops_lean : Double = 0.25

///|
/// Elastic track height growth while held/dragged (0.0: native iOS 27 keeps crisp 6pt track).
let slider_track_held_grow : Double = 0.0

///|
/// A LiquidSlider in `parent`, at `value` along `least` … `most`; moved (its thumb dragged, its track tapped, a key, a
/// screen reader's step), `change` is told the new value. Read out a slider named `label`. As wide as what holds it
/// gives it, `thumb_h_px` high (default 24pt). Supports discrete `stops`, adaptive `thumb_label`, and floating
/// `value_bubble` while pressed. With stops and a label, the thumb is as wide at every stop as its widest stop's words
/// want (those of `stop_labels`, else `thumb_label` at each stop). The node.
#callsite(autofill(loc))
pub fn liquid_slider_node(
  parent : @view.View,
  value : () -> Double,
  change : (Double) -> Unit,
  label : () -> String,
  least? : Double = 0.0,
  most? : Double = 100.0,
  step? : Double = 0.0,
  threshold? : Double = 0.01,
  disabled? : () -> Bool = fn() { false },
  track_h? : Double = slider_track_h,
  track_held_grow? : Double = slider_track_held_grow,
  thumb_w_px? : Double = slider_thumb_w,
  thumb_h_px? : Double = slider_thumb_h,
  track_color? : () -> Int64,
  fill_color? : () -> Int64,
  stops? : Int = 0,
  thumb_label? : (Double) -> String,
  stop_labels? : () -> Array[String],
  value_text? : (Double) -> String,
  flush? : Bool = false,
  value_bubble? : ((Double) -> String)? = None,
  drag? : DampedDrag,
  loc~ : SourceLoc,
) -> @view.View {
  let dd = match drag {
    Some(d) => d
    None => DampedDrag::new(@signals.untracked(value), lo=least, hi=most, threshold~, held_scale=slider_thumb_held_scale)
  }
  let span = most - least
  let has_stops = stops > 1
  let has_label = thumb_label is Some(_)
  let eff_flush = has_label || flush
  let stop_step = if has_stops && span > 0.0 { span / (stops - 1).to_double() } else { 0.0 }
  let eff_step = if has_stops { stop_step } else { step }
  let snap_step = fn(raw : Double) -> Double {
    if !has_stops && step > 0.0 {
      clamp(least + ((raw - least) / step).round() * step, least, most)
    } else {
      clamp(raw, least, most)
    }
  }
  let stop_index_of = fn(v : Double) -> Int {
    if !has_stops || span <= 0.0 {
      0
    } else {
      let frac = clamp((v - least) / span, 0.0, 1.0)
      clamp((frac * (stops - 1).to_double()).round(), 0.0, (stops - 1).to_double()).to_int()
    }
  }
  let value_of_stop = fn(i : Int) -> Double {
    if !has_stops {
      least
    } else {
      least + span * (i.to_double() / (stops - 1).to_double())
    }
  }
  let lean_value_for = fn(raw_v : Double) -> (Int, Double) {
    let frac = if span <= 0.0 { 0.0 } else { clamp((raw_v - least) / span, 0.0, 1.0) }
    let fp = frac * (stops - 1).to_double()
    let nearest = clamp(fp.round(), 0.0, (stops - 1).to_double()).to_int()
    let leaned = clamp(
      nearest.to_double() + (fp - nearest.to_double()) * slider_stops_lean,
      0.0,
      (stops - 1).to_double(),
    )
    (nearest, least + span * (leaned / (stops - 1).to_double()))
  }
  let label_w = fn(text : String) { @ui.text_advance(text, size=ctrl_type_label, weight=weight_medium) + 20.0 }
  // (how wide the thumb is along a track `w` wide at `v`: a labeled one as its words want; with stops as its widest
  // stop's words want whichever it is at, so it meets either end of the track at the first and last stop and the stops
  // are evenly apart, none of them moved by which is picked)
  let thumb_w_at = fn(w : Double, v : Double) -> Double {
    match thumb_label {
      Some(lbl_fn) => {
        let mut want = thumb_w_px
        if has_stops {
          let names = match stop_labels {
            Some(f) => f()
            None => Array::makei(stops, fn(i) { lbl_fn(value_of_stop(i)) })
          }
          for n in names {
            want = dmax(want, label_w(n))
          }
        } else {
          want = dmax(want, label_w(lbl_fn(v)))
        }
        dmin(w, want)
      }
      None => thumb_w_px
    }
  }
  let on_thumb = Ref(false)
  let did_drag = Ref(false)
  let last_x = Ref(0.0)
  // (how far the thumb's middle travels end to end, as the finger came down: what a move of it along the track is of
  // the whole)
  let travel_px = Ref(1.0)
  let raw_drag_val = Ref(@signals.untracked(value))
  let felt_stop = Ref(stop_index_of(@signals.untracked(value)))
  let live_stop : @signals.Signal[Int?] = @signals.signal(None)
  let live_val = fn() -> Double {
    if has_stops {
      match live_stop.get() {
        Some(i) => value_of_stop(i)
        None => value()
      }
    } else {
      value()
    }
  }
  let hand = fn(d : @view.Drag) {
    if disabled() || d.w <= 0.0 {
      return
    }
    match d.kind {
      Down => {
        let cur_tw = thumb_w_at(d.w, @signals.untracked(value))
        let half = cur_tw / 2.0
        travel_px.val = dmax(1.0, d.w - cur_tw)
        let tx = slider_thumb_x_for(d.w, cur_tw, (dd.target() - least) / span, eff_flush)
        let hit_thumb = d.x >= tx && d.x <= tx + cur_tw
        on_thumb.val = true
        did_drag.val = false
        last_x.val = d.wx
        dd.press()
        if has_stops {
          let raw = if hit_thumb {
            @signals.untracked(value)
          } else {
            let frac = if eff_flush { (d.x - half) / travel_px.val } else { d.x / d.w }
            clamp(least + span * frac, least, most)
          }
          raw_drag_val.val = raw
          let (nearest, leaned) = lean_value_for(raw)
          felt_stop.val = nearest
          live_stop.set(Some(nearest))
          if !hit_thumb {
            dd.update_value(leaned)
            change(value_of_stop(nearest))
          }
        } else if !hit_thumb {
          let frac = if eff_flush {
            clamp((d.x - half) / travel_px.val, 0.0, 1.0)
          } else {
            clamp(d.x / d.w, 0.0, 1.0)
          }
          let to = snap_step(least + span * frac)
          raw_drag_val.val = to
          dd.update_value(to)
          change(to)
        } else {
          raw_drag_val.val = @signals.untracked(value)
        }
      }
      Moved =>
        if on_thumb.val {
          let dx = d.wx - last_x.val
          last_x.val = d.wx
          if dx != 0.0 {
            did_drag.val = true
          }
          if has_stops {
            let along = if eff_flush { travel_px.val } else { d.w }
            raw_drag_val.val = clamp(raw_drag_val.val + span * (dx / along), least, most)
            let (nearest, leaned) = lean_value_for(raw_drag_val.val)
            if nearest != felt_stop.val {
              felt_stop.val = nearest
              live_stop.set(Some(nearest))
              @ui.haptic(TextHandleMove)
            }
            dd.update_value(leaned)
          } else {
            let span_px = if eff_flush { travel_px.val } else { d.w }
            raw_drag_val.val = clamp(raw_drag_val.val + span * (dx / span_px), least, most)
            let next = snap_step(raw_drag_val.val)
            if next != dd.target() {
              dd.update_value(next)
              change(next)
            }
          }
        }
      Up =>
        if on_thumb.val {
          if has_stops {
            let snapped = value_of_stop(felt_stop.val)
            live_stop.set(None)
            dd.update_value(snapped)
            change(snapped)
          } else if did_drag.val {
            change(snap_step(dd.target()))
          }
          on_thumb.val = false
          dd.release()
        }
      Off =>
        if on_thumb.val {
          on_thumb.val = false
          if has_stops {
            live_stop.set(None)
            dd.update_value(@signals.untracked(value))
          }
          dd.release()
        }
    }
  }
  @headless.slider(
    made_for=loc,
    parent,
    label,
    value,
    min=least,
    max=most,
    step=eff_step,
    change,
    thumb_room=if eff_flush { thumb_w_px } else { 0.0 },
    disabled~,
    value_text?,
    drag=hand,
    fn(s, sl) {
      dd.attach(s)
      s.height(Is(Some(thumb_h_px))).alpha(By(fn() { if sl.disabled() { 0.5 } else { 1.0 } })) |> ignore
      // (moved by what is not this hand's drag: its value followed, LaunchedEffect's updateValue)
      s.reacts(at_start=false, value, fn(v) {
        if !(has_stops && on_thumb.val) && dd.target() != v {
          dd.update_value(v)
        }
      })
      s.by_room(fn(inner, room) {
        let w = fn() { room.width() }
        let no_lens = fn() { inner.glass_solid() || @ui.reduced_motion() }
        let lens = fn(n : @view.View) -> Double { if no_lens() { 0.0 } else { dd.pressed(n) } }
        let eff_tw = fn() -> Double {
          if thumb_label is Some(_) {
            inner.words_redone() |> ignore
          }
          thumb_w_at(w(), live_val())
        }
        // (where its middle is at `progress`: a flush thumb's between its ends, another's along the whole track)
        let middle_at = fn(progress : Double) {
          if eff_flush {
            slider_travel_at(w(), eff_tw() / 2.0, progress)
          } else {
            w() * progress
          }
        }
        let thumb_x = fn(tw : Double, progress : Double) { slider_thumb_x_for(w(), tw, progress, eff_flush) }
        // (a flush thumb meets the track's ends at the first and last stop: the track's round ends drawn in from them by
        // as much as their own round and a point, so they stay under the thumb's round ends, never peeking past its rim)
        let ends = if eff_flush { track_h / 2.0 + 1.0 } else { 0.0 }
        let along = fn() { dmax(0.0, w() - 2.0 * ends) }
        inner.box(fn(track) {
          track
          .over(Is(true))
          .width(By(fn() { Some(along()) }))
          .height(Is(Some(track_h)))
          .offset(Is((ends, (thumb_h_px - track_h) / 2.0)))
          .radius(Is(track_h / 2.0))
          .ground(By(fn() {
            match track_color {
              Some(f) => f()
              None => colors().track
            }
          }))
          .ground_drawn(By(fn() {
            let dh = track_held_grow * dmax(0.0, dd.pressed(track))
            if dh.abs() < 0.001 {
              @view.ground_as_laid
            } else {
              let rr = (track_h + dh) / 2.0
              { dx: 0.0, dy: -dh / 2.0, dw: 0.0, dh, corners: Some((rr, rr, rr, rr)) }
            }
          }))
          |> ignore
        })
        |> ignore
        // (how far along the track the fill goes: a flush thumb's under the thumb, from where it starts at the first stop
        // (none) to its middle at the last, so no fill shows at the first stop and no track between the fill and the
        // thumb at the last)
        let filled = fn(n : @view.View) {
          let at = clamp(dd.progress(n), 0.0, 1.0)
          if eff_flush {
            dmax(0.0, middle_at(at) - eff_tw() / 2.0 * (1.0 - at) - ends)
          } else {
            middle_at(at)
          }
        }
        inner.box(fn(fill) {
          fill
          .over(Is(true))
          .width(By(fn() { Some(along()) }))
          .height(Is(Some(track_h)))
          .offset(Is((ends, (thumb_h_px - track_h) / 2.0)))
          .alpha(By(fn() { if filled(fill) < 0.5 { 0.0 } else { 1.0 } }))
          .radius(Is(track_h / 2.0))
          .ground(By(fn() {
            match fill_color {
              Some(f) => f()
              None => colors().accent
            }
          }))
          .ground_drawn(By(fn() {
            let shown = filled(fill)
            let dh = track_held_grow * dmax(0.0, dd.pressed(fill))
            if dh.abs() < 0.001 {
              { ..@view.ground_as_laid, dw: shown - along() }
            } else {
              let rr = (track_h + dh) / 2.0
              { dx: 0.0, dy: -dh / 2.0, dw: shown - along(), dh, corners: Some((rr, rr, rr, rr)) }
            }
          }))
          |> ignore
        })
        |> ignore
        // Interior detent markers for discrete stops mode
        if has_stops {
          let dot_side = 4.0
          for i in 1..<(stops - 1) {
            let frac = i.to_double() / (stops - 1).to_double()
            inner.box(fn(dot) {
              dot
              .over(Is(true))
              .points(Is(false))
              .width(Is(Some(dot_side)))
              .height(Is(Some(dot_side)))
              .radius(Is(dot_side / 2.0))
              .offset(By(fn() { (middle_at(frac) - dot_side / 2.0, (thumb_h_px - dot_side) / 2.0) }))
              .ground(By(fn() { if is_dark() { 0xFFFFFF55L } else { 0x00000038L } }))
              |> ignore
            })
            |> ignore
          }
        }
        inner.box(fn(thumb) {
          let thumb_shape = fn(n : @view.View) -> @view.GroundShape {
            let cur_tw = eff_tw()
            let p = clamp(lens(n), 0.0, 1.0)
            let v = if no_lens() { 0.0 } else { dd.velocity(n) / 10.0 }
            // (stretched along its way and flattened as fast as it goes, whichever way: never taller than held, so never
            // past the room kept for it; the catalog's signed squeeze made it taller going left)
            let v = v.abs()
            let vel_sx = 1.0 / (1.0 - clamp(v * 0.75, 0.0, 0.2))
            let vel_sy = 1.0 - clamp(v * 0.25, 0.0, 0.2)
            let tw = cur_tw * lerp(1.0, 58.0 / 38.0, p) * vel_sx
            let th = thumb_h_px * lerp(1.0, slider_thumb_held_scale, p) * vel_sy
            let x = thumb_x(cur_tw, dd.progress(n))
            let r = th / 2.0
            {
              dx: x + (cur_tw - tw) / 2.0,
              dy: (thumb_h_px - th) / 2.0,
              dw: tw - thumb_w_px,
              dh: th - thumb_h_px,
              corners: Some((r, r, r, r)),
            }
          }
          thumb
          .over(Is(true))
          .width(Is(Some(thumb_w_px)))
          .height(Is(Some(thumb_h_px)))
          .radius(Is(thumb_h_px / 2.0))
          .shadow(By(fn() { thumb_lift_shadow(clamp(lens(thumb), 0.0, 1.0)) }))
          .shadow_outside(Is(true))
          .ground_drawn(By(fn() { thumb_shape(thumb) }))
          |> ignore
          thumb.box(fn(solid) {
            solid
            .over(Is(true))
            .width(Is(Some(thumb_w_px)))
            .height(Is(Some(thumb_h_px)))
            .radius(Is(thumb_h_px / 2.0))
            .ground(By(fn() {
              if has_label && is_dark() {
                0x2C2C2EFFL
              } else {
                white
              }
            }))
            .edge(By(fn() { (0.5, if is_dark() { 0xFFFFFF18L } else { 0x00000014L }) }))
            .alpha(By(fn() { clamp(1.0 - clamp(lens(solid), 0.0, 1.0) * 1.8, 0.0, 1.0) }))
            .ground_drawn(By(fn() { thumb_shape(solid) }))
            |> ignore
          })
          |> ignore
          // Lazy-mount the refraction loupe on first press (0 hidden glass & 0 extra nodes at rest; laid == 0 on release).
          let lens_mounted : @signals.Signal[Bool] = @signals.signal(false)
          thumb.reacts(fn() { !no_lens() && (dd.pressing() || dd.pressed(thumb) > 0.001) }, fn(active) {
            if active && !lens_mounted.untracked() {
              lens_mounted.set(true)
            }
          })
          thumb.show(fn() { lens_mounted.get() }, at_once=true, fn(gl) {
            gl
            .over(Is(true))
            .points(Is(false))
            .width(Is(Some(thumb_w_px)))
            .height(Is(Some(thumb_h_px)))
            .radius(Is(thumb_h_px / 2.0))
            .glass(By(fn() {
              let p = clamp(lens(gl), 0.0, 1.0)
              if p > 0.001 {
                Some(slider_glass(p))
              } else {
                None
              }
            }))
            .alpha(By(fn() { clamp(lens(gl), 0.0, 1.0) }))
            .ground_drawn(By(fn() { thumb_shape(gl) }))
            |> ignore
          })
          match thumb_label {
            Some(lbl_fn) =>
              thumb.box(fn(lbl) {
                lbl
                .over(Is(true))
                .points(Is(false))
                .width(By(fn() { Some(eff_tw()) }))
                .height(Is(Some(thumb_h_px)))
                .lines_up(Is(Some(Middle)))
                .lies_along(Is(Middle))
                .offset(By(fn() { (thumb_x(eff_tw(), dd.progress(lbl)), 0.0) }))
                |> ignore
                lbl.box(fn(wt) {
                  wt
                  .words(By(fn() { lbl_fn(live_val()) }), look=words_at(ctrl_type_label, weight=weight_medium))
                  .ink(By(fn() { colors().content }))
                  |> ignore
                })
                |> ignore
              })
              |> ignore
            None => ()
          }
        })
        |> ignore
        // Compact floating value bubble above the thumb while held/dragged (unmounted when settled)
        match value_bubble {
          Some(fmt_fn) =>
            inner.show(fn() { dd.pressing() || dd.pressed(inner) > 0.001 }, at_once=true, fn(bub) {
              bub
              .over(Is(true))
              .points(Is(false))
              .row(Is(true))
              .lines_up(Is(Some(Middle)))
              .lies_along(Is(Middle))
              .padding(Is((8.0, 3.0, 8.0, 3.0)))
              .radius(Is(11.0))
              .ground(By(fn() { colors().content }))
              .alpha(By(fn() { clamp(dd.pressed(bub), 0.0, 1.0) }))
              .scale(By(fn() { lerp(0.92, 1.0, clamp(dd.pressed(bub), 0.0, 1.0)) }), about=At(0.5, 1.0))
              .moved_by(
                fn(bw, bh, _at) {
                  let cur_tw = eff_tw()
                  let tx = thumb_x(cur_tw, dd.progress(bub))
                  (tx + cur_tw / 2.0 - bw / 2.0, -bh - 10.0)
                },
                fn(_bw, _bh) { dd.value.end() },
              )
              |> ignore
              bub.box(fn(wt) {
                wt
                .words(By(fn() { fmt_fn(live_val()) }), look=words_at(ctrl_type_caption, weight=weight_medium))
                .ink(By(fn() { if is_dark() { black } else { white } }))
                |> ignore
              })
              |> ignore
            })
          None => ()
        }
        inner.show(fn() { sl.focus_shown() }, fn(ring) {
          ring
          .over(Is(true))
          .width(By(fn() { Some(eff_tw() + 6.0) }))
          .height(Is(Some(thumb_h_px + 6.0)))
          .radius(Is(thumb_h_px / 2.0 + 3.0))
          .offset(By(fn() { (thumb_x(eff_tw(), dd.progress(ring)) - 3.0, -3.0) }))
          .edge(By(fn() { (2.0, colors().accent) }))
          |> ignore
        })
      })
      |> ignore
    },
  )
}
