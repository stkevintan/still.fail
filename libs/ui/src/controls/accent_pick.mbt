// 主题色's control (外观): the colour themes (tokens.mbt `accents`) as a row of dots, each in its own colour as the
// theme draws it now (light or dark), the chosen one with a check on it; 自定义 last, a hue of the person's own.

///|
/// The colour themes' dots in a line (`names`: each one's name, what a screen reader says; then `custom`'s, 自定义's,
/// last), the one `chosen` says (its key, the prefs' `accent`) with a check on it (narrow, its first as far in as a
/// section's heading): each a dot 24 across (28 with touch), their middles a press's least room apart
/// (@ui.room_least: 36, 44 with touch; what each reaches, overlapping none). 自定义 last: chosen, a dot in its hue's
/// accent and a slider of hues under the dots, as wide as they are (`hue`: what a screen reader calls it), its track
/// every hue's accent, its knob the one's; not chosen, a ＋ in an outline, which takes the hue it had last
/// (custom_hue_kept). `choose` told the key a person chooses (a press's, a step's or a drag's along the hues; the
/// caller says it chosen then: `chosen` follows it). `preview`, where given, told the key of a dot the pointer comes
/// over unchosen (the caller shows the window in it a moment) and None as it leaves it, or the dots are let go, with
/// nothing chosen: a dot chosen ends it untold, the caller's choose saying the rest.
#callsite(autofill(loc))
pub fn accent_pick_node(
  parent : @view.View,
  names : () -> Array[String],
  rainbow : () -> String,
  custom : () -> String,
  hue : () -> String,
  chosen : () -> String,
  choose : (String) -> Unit,
  preview? : (String?) -> Unit,
  loc~ : SourceLoc,
) -> Unit {
  // (the dot whose colour is shown a moment, by its key, while the pointer is over it: None, none)
  let previewed : Ref[String?] = Ref(None)
  let choose = fn(key : String) {
    previewed.val = None
    choose(key)
  }
  let own = fn() { custom_hue(chosen()) }
  // (the hue 自定义 takes as it is pressed: the one it has while it is chosen)
  parent.reacts(own, fn(h) {
    match h {
      Some(h) => custom_hue_kept.val = h
      None => ()
    }
  })
  let ink_of = fn(a : AccentTone) { if theme().dark { a.dark } else { a.light } }
  parent.box(made_for=loc, fn(col) {
    // (let go with a colour shown a moment: the one chosen shown again)
    match preview {
      Some(tell) =>
        col.on_leaving(fn() {
          if previewed.val is Some(_) {
            previewed.val = None
            tell(None)
          }
        })
        |> ignore
      None => ()
    }
    // (narrow, a section's own: in from the page's edge as far as its heading's words, as its note is)
    let start = if look_node(col) is Narrow { accent_narrow_in } else { 0.0 }
    col.gap(Is(accent_column_gap)).padding(Is((start, 0.0, 0.0, 0.0))) |> ignore
    @headless.radio_group(col, fn() { "" }, chosen, choose, selected=true, fn(row, rg) {
      row
      .row(Is(true))
      .gap(Is(8.0))
      .lines_up(Is(Some(Middle)))
      |> ignore
      let a_dot = fn(key : () -> String, ink : () -> Int64?, name : () -> String, wheel : Bool) {
        rg.item(row, key, name, fn(d, item) {
          let on = fn() { item.chosen() }
          let side = dot_side(@signals.untracked(theme))
          let mark = side * accent_check_part
          let ring = fn() {
            if !wheel && ink() is None {
              alpha(theme().p.text, accent_open_line)
            } else if lit_node(d) && !on() {
              alpha(theme().p.text, accent_lit_line)
            } else {
              accent_no_ring
            }
          }
          d
          .width(Is(Some(side)))
          .height(Is(Some(side)))
          // (round as a pill is said to be, Full: as round as it can be)
          .radius(Is(1.0e6))
          .lines_up(Is(Some(Middle)))
          .lies_along(Is(Middle))
          |> ignore
          if wheel {
            // Backing ground matches the wheel's OKLCH lightness (for contrast audit under the white check) while the
            // clipped conic rainbow image covers the whole disc with no extra census colour.
            d
            .clips(Is(true))
            .ground(By(fn() { ink_of(accents[0]) }))
            .image(By(fn() { Some((rainbow_dot(theme().dark), "", hue_strip_most)) }))
            |> ignore
            d.box(fn(o) {
              o.over(Is(true)).radius(Is(1.0e6)).edge(By(fn() { (2.0, ring()) })) |> ignore
            })
            |> ignore
          } else {
            d
            .ground(By(fn() { ink().unwrap_or(accent_no_ring) }))
            .edge(By(fn() { (2.0, ring()) }))
            |> ignore
          }
          // (the pointer over it unchosen: its colour shown a moment; off it again, the chosen one's, unless another
          // was shown since)
          match preview {
            Some(tell) =>
              d.reacts(fn() { hovered_node(d) && !on() }, fn(over) {
                let k = @signals.untracked(key)
                if over {
                  previewed.val = Some(k)
                  tell(Some(k))
                } else if previewed.val == Some(k) {
                  previewed.val = None
                  tell(None)
                }
              })
            None => ()
          }
          d.show(on, fn(c) { icon_node(c, "check", mark, Is(0xFFFFFFFFL)) |> ignore })
          d.show(fn() { !wheel && !on() && ink() is None }, fn(c) {
            icon_node(c, "plus", mark, By(fn() { theme().p.muted })) |> ignore
          })
        })
        |> ignore
      }
      for i, a in accents {
        let key = a.key
        a_dot(fn() { key }, fn() { Some(ink_of(a)) }, fn() { names().get(i).unwrap_or(key) }, false)
      }
      a_dot(fn() { rainbow_accent_key }, fn() { None }, rainbow, true)
      a_dot(
        fn() { "custom:" + own().unwrap_or(custom_hue_kept.val).to_string() },
        fn() { own().map(fn(h) { ink_of(custom_tone(h)) }) },
        custom,
        false,
      )
    })
    |> ignore
    // 自定义's hues, as wide as the dots
    col.show(fn() { own() is Some(_) }, fn(s) {
      hue_slider_node(s, fn() { own().unwrap_or(custom_hue_kept.val) }, hue, fn(h) {
        custom_hue_kept.val = h
        choose("custom:" + h.to_string())
      })
    })
  })
  |> ignore
}

///|
/// The hues' slider (@headless.slider + @glass.liquid_slider_look), as wide as the dots over it: a track 6 high of
/// every hue's accent as the theme draws it, 10 in from each end, round; the knob, 24 across, the hue's accent ringed
/// 2 in the card's ground, its middle running from half the slider's thumb room in to as far from the end, lifting
/// into a clear liquid glass droplet loupe while held. A drag along it, an arrow with the keyboard's focus on it, a
/// screen reader's step (View::on_step) each `step_to` a hue (0 to 355, 5 apart), read out as `label`'s slider.
#callsite(autofill(loc))
fn hue_slider_node(
  parent : @view.View,
  now : () -> Int,
  label : () -> String,
  step_to : (Int) -> Unit,
  loc~ : SourceLoc,
) -> Unit {
  let n = (accents.length() + 2).to_double()
  let wide = fn() {
    let side = dot_side(theme())
    n * side + (n - 1.0) * 8.0
  }
  let dd = @glass.DampedDrag::new(
    @signals.untracked(fn() { now().to_double() }),
    lo=0.0,
    hi=custom_hue_most,
    held_scale=@glass.slider_thumb_held_scale,
  )
  let drag = fn(d : @view.Drag) {
    match d.kind {
      Down => {
        dd.press()
        if d.w > hue_thumb_room {
          let frac = dclamp((d.x - hue_thumb_room / 2.0) / (d.w - hue_thumb_room), 0.0, 1.0)
          let snapped = @headless.slider_snap(frac * custom_hue_most, 0.0, custom_hue_most, custom_hue_step)
          let h = snapped.round().to_int()
          if h != @signals.untracked(now) {
            step_to(h)
          }
          dd.update_value(@signals.untracked(fn() { now().to_double() }))
        }
      }
      Moved =>
        if d.w > hue_thumb_room {
          let frac = dclamp((d.x - hue_thumb_room / 2.0) / (d.w - hue_thumb_room), 0.0, 1.0)
          let snapped = @headless.slider_snap(frac * custom_hue_most, 0.0, custom_hue_most, custom_hue_step)
          let h = snapped.round().to_int()
          if h != @signals.untracked(now) {
            step_to(h)
          }
          let actual = @signals.untracked(fn() { now().to_double() })
          if actual != dd.target() {
            dd.update_value(actual)
          }
        }
      Up | Off => {
        let actual = @signals.untracked(fn() { now().to_double() })
        if actual != dd.target() {
          dd.update_value(actual)
        }
        dd.release()
      }
    }
  }
  @headless.slider(
    made_for=loc,
    parent,
    label,
    fn() { now().to_double() },
    min=0.0,
    max=custom_hue_most,
    step=custom_hue_step,
    thumb_room=hue_thumb_room,
    drag~,
    fn(h) { step_to(h.round().to_int()) },
    fn(s, sl) {
      dd.attach(s)
      s.reacts(at_start=false, fn() { now().to_double() }, fn(v) {
        if dd.target() != v {
          dd.update_value(v)
        }
      })
      s
      .width(By(fn() { Some(wide()) }))
      .height(Is(Some(hue_slider_h)))
      .lies_along(Is(Middle))
      |> ignore
      let look = @glass.SliderLook::new(
        track_h=hue_track_h,
        track_inset=hue_track_in,
        travel_inset=None,
        thumb_w=@glass.slider_thumb_w,
        thumb_h=@glass.slider_thumb_h,
        flush=true,
        track_color=fn() { 0L },
        fill_color=None,
        track_image=Some(fn() {
          let tw = dmax(1.0, wide() - 2.0 * hue_track_in)
          Some((hue_strip(theme().dark, tw, hue_thumb_room / 2.0 - hue_track_in), "", hue_strip_most))
        }),
        thumb_color=None,
        thumb_edge=None,
        focus_shown=Some(fn() { sl.focus_shown() }),
        focus_color=Some(fn() { @ui.tree_theme().focus }),
        lens_enabled=true,
        held_mark=Some(fn(m) {
          m.box(fn(bar) {
            bar
            .width(Is(Some(5.0)))
            .height(Is(Some(16.0)))
            .radius(Is(2.5))
            .ground(By(fn() {
              let h = (dd.progress(bar) * custom_hue_most).round().to_int()
              let a = custom_tone(h)
              if theme().dark {
                a.dark
              } else {
                a.light
              }
            }))
            .edge(Is((1.0, 0xFFFFFFFFL)))
            .shadow(Is((2.0, 0.0, 0x00000044L)))
            |> ignore
          })
          |> ignore
        }),
      )
      s.box(fn(slot) {
        slot.height(Is(Some(@glass.slider_thumb_h))) |> ignore
        @glass.liquid_slider_look(
          slot,
          fn(n) { dd.progress(n) },
          fn(n) { dd.pressed(n) },
          look,
          velocity=fn(n) { dd.velocity(n) },
          loc~,
        )
      })
      |> ignore
    },
  )
  |> ignore
}

///|
/// How much of the slider's width its capsule thumb's middle does not run along (matches flush=true: half a thumb at
/// each end).
let hue_thumb_room : Double = @glass.slider_thumb_w

///|
/// The slider's layout height (h=S7), its track's height (6pt capsule) and end inset (4pt, tucked under flush capsule).
let hue_slider_h : Double = 28.0

///|
let hue_track_h : Double = @glass.slider_track_h

///|
let hue_track_in : Double = @glass.slider_track_h / 2.0 + 1.0

///|
/// The check on the chosen dot (and 自定义's ＋): 0.6 of its side.
let accent_check_part : Double = 0.6

///|
/// The dots and 自定义's hues under them, 8 apart (gap=S2); narrow, a section's own, its first dot as far in as the
/// heading's words (pl=S3).
let accent_column_gap : Double = 8.0

///|
let accent_narrow_in : Double = 12.0

///|
/// A dot's side: 24 across with keyboard and mouse, 28 with touch (w=S6, w=S7).
fn dot_side(t : Theme) -> Double {
  if t.touch {
    28.0
  } else {
    24.0
  }
}

///|
/// The hue 自定义 takes as it is pressed: the one it had last, at first a blue between the five's (210).
// kept across runs: put back as a Tester starts (icons.mbt)
let custom_hue_kept : Ref[Int] = Ref(210)

///|
/// The hues' slider: 0 to 355, 5 apart.
let custom_hue_most : Double = 355.0

///|
let custom_hue_step : Double = 5.0

///|
/// How many pixels across the hues' track's picture is made (1px ≈ 1pt on desktop 208pt track), mapping 0°..355°
/// linearly across the thumb center travel `[cap_in, track_w - cap_in]` and clamping both end caps to 0° / 355°.
let hue_cells : Int = 208

///|
/// Hue in degrees [0, 355] at track-local position `x` in `[0, track_w]` when thumb centers travel `[cap_in, track_w - cap_in]`.
fn hue_strip_hue_at(x : Double, track_w : Double, cap_in : Double) -> Int {
  let span = dmax(1.0, track_w - 2.0 * cap_in)
  let frac = dclamp((x - cap_in) / span, 0.0, 1.0)
  (frac * custom_hue_most).round().to_int()
}

///|
/// The picture of every hue's accent by day or by night (hue_cells across, 1 high), aligned to the flush capsule
/// thumb's center travel `[cap_in, track_w - cap_in]` so the color under the droplet center matches the selected hue.
fn hue_strip(dark : Bool, track_w : Double, cap_in : Double) -> String {
  let tw_key = dmax(1.0, track_w.round()).to_int()
  let key = "mem:sf-hues/\{dark}/\{tw_key}/\{hue_cells}"
  if !@ui.has_image(key) {
    let px = FixedArray::make(hue_cells * 4, b'\x00')
    for i in 0..<hue_cells {
      let x = (i.to_double() + 0.5) / hue_cells.to_double() * track_w
      let a = custom_tone(hue_strip_hue_at(x, track_w, cap_in))
      let ink = if dark { a.dark } else { a.light }
      for k in 0..<4 {
        px[i * 4 + k] = ((ink >> (24 - k * 8)) & 0xFFL).to_int().to_byte()
      }
    }
    @ui.add_image(key, @pixels.png(hue_cells, 1, px))
  }
  key
}

///|
/// The outline round 自定义's ＋ while it is not chosen: the ink at 24%.
let accent_open_line : Double = 0.24

///|
/// The ring round a dot under the pointer: the ink at 30%; none round the others.
let accent_lit_line : Double = 0.3

///|
let accent_no_ring : Int64 = 0L

///|
/// The most pixels the hues' picture is asked at (mark_node's pictures').
let hue_strip_most : Int = 8192

///|
/// Pixel size of the conic rainbow disc for 五彩色 (20×20 RGBA PNG = 1,688 B: smooth under GPU bilinear filtering
/// while both light and dark copies plus hue_strip stay under host_image_bytes_free).
let rainbow_dot_px : Int = 20

///|
/// The conic OKLCH rainbow wheel for 五彩色 by day or by night, cached by key as hue_strip is.
fn rainbow_dot(dark : Bool) -> String {
  let key = "mem:sf-rainbow/\{dark}/\{rainbow_dot_px}"
  if !@ui.has_image(key) {
    let n = rainbow_dot_px
    let mid = (n - 1).to_double() / 2.0
    let px = FixedArray::make(n * n * 4, b'\x00')
    let deg_per_rad = 180.0 / @math.PI
    for y in 0..<n {
      let dy = y.to_double() - mid
      for x in 0..<n {
        let dx = x.to_double() - mid
        let deg = @dmath.atan2(dy, dx) * deg_per_rad + 115.0
        let h = ((deg.round().to_int() % 360) + 360) % 360
        let a = custom_tone(h)
        let ink = if dark { a.dark } else { a.light }
        let at = (y * n + x) * 4
        for k in 0..<4 {
          px[at + k] = ((ink >> (24 - k * 8)) & 0xFFL).to_int().to_byte()
        }
      }
    }
    @ui.add_image(key, @pixels.png(n, n, px))
  }
  key
}
