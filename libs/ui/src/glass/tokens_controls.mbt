// Design tokens and iOS 27 Liquid Glass recipes for controls (bar pills, floating capsules,
// tab bars, media viewers, knobs, segmented controls, sliders, toggles).

// ---------------------------------------------------------------------------
// Segmented control & slider geometry / typography
// ---------------------------------------------------------------------------

///|
let ctrl_seg_pad : Double = 3.0

///|
pub let ctrl_seg_held_scale : Double = 1.15

///|
let ctrl_seg_px : Double = 12.0

///|
let ctrl_focus_w : Double = 2.0

///|
let ctrl_type_label : Double = 13.0

///|
let ctrl_type_caption : Double = 12.0

///|
let ctrl_type_seg : Double = 14.0

// ---------------------------------------------------------------------------
// Control colours
// ---------------------------------------------------------------------------

///|
/// Native iOS 27.0 lifted opaque pill fill at rest for segmented controls
/// (pure white in Light, lifted medium grey `0x68686EFF` in Dark matching native `(105..111)`).
/// Resting pills use zero border and zero shadow in both themes.
fn ctrl_seg_thumb_idle() -> Int64 {
  if is_dark() {
    0x68686EFFL
  } else {
    0xFFFFFFFFL
  }
}

///|
fn ctrl_seg_inactive_ink() -> Int64 {
  colors().content
}

///|
/// Translucent neutral track ground for embedded segmented controls (`glass_track=false`)
/// and narrow menu disclosures, ensuring zero visual jump between side-by-side and menu modes.
pub fn ctrl_seg_embedded_track_ink() -> Int64 {
  if is_dark() {
    0xFFFFFF18L
  } else {
    0x7878801FL
  }
}

// ---------------------------------------------------------------------------
// Glass recipes (iOS 27 @paint.Glass::liquid — single layer, zero glass-on-glass)
// ---------------------------------------------------------------------------

///|
/// Theme-adaptive hairline edge for `MBUI_GLASS=solid` fallback (0.5pt).
pub fn liquid_solid_edge() -> (Double, Int64) {
  if is_dark() {
    (0.5, 0xFFFFFF26L)
  } else {
    (0.5, 0x0000001CL)
  }
}

///|
/// Theme-adaptive hover overlay ink for controls inside a liquid glass pill group.
/// Light mode uses a soft dark wash (~11%) that the GPU automatically flips to luminous white (~16%)
/// when an adaptive glass capsule sits over dark or saturated backdrops.
pub fn liquid_pill_hover_ink(solid? : Bool = false) -> Int64 {
  ignore(solid)
  if is_dark() {
    0xFFFFFF29L
  } else {
    0x0000001CL
  }
}

///|
/// Theme-adaptive press overlay ink over translucent glass: luminous white highlight over real GPU liquid glass
/// in both Light and Dark modes (matching Apple `.glassEffect(.interactive())` with zero grey veil), falling back
/// to subtle dark contrast ink in Light mode when `MBUI_GLASS=solid` disables the GPU spot highlight.
pub fn liquid_press_ink(solid? : Bool = false) -> Int64 {
  if !solid {
    if is_dark() {
      0xFFFFFF38L
    } else {
      0xFFFFFF4CL
    }
  } else if is_dark() {
    0xFFFFFF38L
  } else {
    0x00000018L
  }
}

///|
fn maybe_sharing(g : @paint.Glass, sharing : Bool) -> @paint.Glass {
  if sharing {
    g.sharing()
  } else {
    g
  }
}

///|
/// Translucent iOS 27 Liquid Glass for floating top-bar action pills (36–40pt tall), sharing capture by default.
pub fn liquid_bar_pill_glass(
  spot? : (Double, Double)? = None,
  solid? : Int64 = clear,
  sharing? : Bool = true,
  adaptive? : Bool = false,
) -> @paint.Glass {
  let d = is_dark()
  let tint = if d { 0x20202067L } else { 0xFDFCFD67L }
  let sol = if solid != clear {
    solid
  } else if d {
    0x1E1F24FFL
  } else {
    0xFAFAFAFFL
  }
  maybe_sharing(
    @paint.Glass::liquid(
      blur=2.0,
      tint~,
      solid=sol,
      saturation=1.0,
      rim=0.6,
      bezel=14.0,
      refraction=20.0,
      chroma=0.06,
      merge=0.0,
      adaptive~,
      spot~,
    ),
    sharing,
  )
}

///|
/// Floating adaptive iOS 27 Liquid Glass capsule (e.g. composer / floating island over scrolling content).
pub fn liquid_floating_glass(
  tint? : Int64? = None,
  solid? : Int64 = clear,
  spot? : (Double, Double)? = None,
  sharing? : Bool = false,
) -> @paint.Glass {
  let d = is_dark()
  let glass_tint = match tint {
    Some(c) => c
    None => if d { 0x20202067L } else { 0xFDFCFD67L }
  }
  let sol = if solid != clear {
    solid
  } else if d {
    0x1E1F24FFL
  } else {
    0xFAFAFAFFL
  }
  maybe_sharing(
    @paint.Glass::liquid(
      blur=2.2,
      tint=glass_tint,
      solid=sol,
      saturation=1.0,
      rim=0.6,
      bezel=20.0,
      refraction=28.0,
      chroma=0.06,
      merge=0.0,
      adaptive=true,
      spot~,
    ),
    sharing,
  )
}

///|
/// Calibrated iOS 27 regular Liquid Glass for bottom tab bars (56pt controls) with optional capillary merge.
pub fn liquid_tab_bar_glass(
  spot? : (Double, Double)? = None,
  merge? : Double = 0.0,
  solid? : Int64 = clear,
  sharing? : Bool = false,
  adaptive? : Bool = true,
) -> @paint.Glass {
  let d = is_dark()
  let tint = if d { 0x20202067L } else { 0xFDFCFD67L }
  let sol = if solid != clear {
    solid
  } else if d {
    0x1E1F24FFL
  } else {
    0xFAFAFAFFL
  }
  maybe_sharing(
    @paint.Glass::liquid(
      blur=2.2,
      tint~,
      solid=sol,
      saturation=1.0,
      rim=0.6,
      bezel=20.0,
      refraction=28.0,
      chroma=0.06,
      merge~,
      adaptive~,
      spot~,
    ),
    sharing,
  )
}

///|
/// Prominent accented iOS 26/27 Liquid Glass recipe (`.glassProminent`) with vivid 85% accent tint,
/// crisp bevel refraction, specular rim, micro chromatic dispersion, and touch-tracked GPU `spot`.
pub fn liquid_prominent_glass(
  accent~ : Int64,
  spot? : (Double, Double)? = None,
  solid? : Int64 = clear,
  sharing? : Bool = false,
) -> @paint.Glass {
  let sol = if solid != clear { solid } else { accent }
  maybe_sharing(
    @paint.Glass::liquid(
      blur=2.0,
      tint=alpha(accent, 0.85),
      solid=sol,
      saturation=1.15,
      rim=0.72,
      bezel=16.0,
      refraction=22.0,
      chroma=0.06,
      merge=0.0,
      adaptive=false,
      spot~,
    ),
    sharing,
  )
}

///|
/// High-translucency desaturated Liquid Glass for floating controls over vivid media / photography.
pub fn liquid_viewer_clear_glass(
  spot? : (Double, Double)? = None,
  solid? : Int64 = clear,
  sharing? : Bool = false,
) -> @paint.Glass {
  let d = is_dark()
  let tint = if d { 0x20202067L } else { 0xFDFCFD67L }
  let sol = if solid != clear {
    solid
  } else if d {
    0x1E1F24FFL
  } else {
    0xFAFAFAFFL
  }
  maybe_sharing(
    @paint.Glass::liquid(
      blur=4.0,
      tint~,
      solid=sol,
      saturation=0.55,
      rim=0.70,
      bezel=9.0,
      refraction=12.0,
      chroma=0.06,
      merge=0.0,
      adaptive=false,
      spot~,
    ),
    sharing,
  )
}

///|
/// Dark translucent Liquid Glass for white-ink media viewer capsules with controlled saturation.
pub fn liquid_viewer_dark_glass(
  spot? : (Double, Double)? = None,
  solid? : Int64 = clear,
  sharing? : Bool = false,
) -> @paint.Glass {
  let sol = if solid != clear { solid } else { 0x161618FFL }
  maybe_sharing(
    @paint.Glass::liquid(
      blur=4.0,
      tint=0x20202067L,
      solid=sol,
      saturation=0.65,
      rim=0.65,
      bezel=9.0,
      refraction=12.0,
      chroma=0.06,
      merge=0.0,
      adaptive=false,
      spot~,
    ),
    sharing,
  )
}

///|
/// Clear refractive liquid glass lens recipe for knobs and text loupes (`blur=0`, `tint=clear`,
/// `bezel=7`, `refraction=3.5`, `chroma=0.0` — strictly below Switch `pinchWeight` 4.5 threshold).
pub fn liquid_knob_glass(solid? : Int64 = clear) -> @paint.Glass {
  let sol = if solid != clear { solid } else { colors().paper }
  @paint.Glass::liquid(
    blur=0.0,
    tint=0xFFFFFF00L,
    solid=sol,
    saturation=1.0,
    rim=0.6,
    bezel=7.0,
    refraction=3.5,
    chroma=0.0,
    merge=0.0,
    adaptive=false,
  )
}

///|
/// Clear lifted Liquid Glass loupe for bottom tab bar / segmented control thumbs while held.
pub fn liquid_tab_lens_glass(
  press : Double,
  solid? : Int64 = clear,
  sharing? : Bool = false,
  droplet_role? : Int = 4,
) -> @paint.Glass {
  let p = clamp(press, 0.0, 1.0)
  let d = is_dark()
  let sol = if solid != clear {
    solid
  } else if d {
    0x242428FFL
  } else {
    0xFFFFFFFFL
  }
  maybe_sharing(
    @paint.Glass::liquid(
      blur=0.0,
      tint=0xFFFFFF00L,
      solid=sol,
      saturation=1.0,
      rim=1.0 * p,
      bezel=14.0 * p,
      refraction=9.0 * p,
      chroma=0.0,
      merge=0.0,
      adaptive=false,
      spot=None,
      zoom=1.0,
      droplet_role~,
    ),
    sharing,
  )
}

///|
fn ctrl_segmented_track_glass() -> @paint.Glass {
  let d = is_dark()
  @paint.Glass::liquid(
    blur=2.1,
    tint=if d { 0x20202067L } else { 0xFDFCFD67L },
    solid=if d { 0x1E1F24FFL } else { 0xFAFAFAFFL },
    saturation=1.0,
    rim=0.6,
    bezel=16.0,
    refraction=20.0,
    chroma=0.06,
    merge=0.0,
    adaptive=false,
    spot=None,
  )
}

///|
/// Calibrated clear loupe recipe for standalone 40-44pt segmented capsules overlaid above labels (`glass_track=true`).
/// Keeps maximum inward refraction inside the clear vertical margin so top/bottom bevel rims never ghost text strokes.
fn ctrl_segmented_lens_glass(p : Double, solid? : Int64) -> @paint.Glass {
  let p = clamp(p, 0.0, 1.0)
  let c = colors()
  let sol = match solid {
    Some(s) if s != clear => s
    _ => alpha(c.container, 1.0 / 0.4)
  }
  @paint.Glass::liquid(
    blur=0.0,
    tint=0xFFFFFF00L,
    solid=sol,
    saturation=1.0,
    rim=1.0 * p,
    bezel=9.0 * p,
    refraction=9.0 * p,
    chroma=0.04 * p,
    merge=0.0,
    adaptive=false,
    spot=None,
    zoom=1.0,
    droplet_role=3,
  )
}

///|
/// Calibrated clear loupe recipe for compact 30-36pt segmented capsules overlaid above labels (`glass_track=false`).
/// Pure crystal droplet (`tint=0xFFFFFF00L`, `zoom=1.0`) overhanging track edges for Native iOS 27 concentric moat.
fn ctrl_segmented_compact_lens_glass(p : Double) -> @paint.Glass {
  let p = clamp(p, 0.0, 1.0)
  let c = colors()
  @paint.Glass::liquid(
    blur=0.0,
    tint=0xFFFFFF00L,
    solid=alpha(c.container, 1.0 / 0.4),
    saturation=1.0,
    rim=1.0 * p,
    bezel=9.0 * p,
    refraction=9.0 * p,
    chroma=0.04 * p,
    merge=0.0,
    adaptive=false,
    spot=None,
    zoom=1.0,
    droplet_role=3,
  )
}
