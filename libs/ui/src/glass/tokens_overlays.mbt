// Liquid Glass overlay recipes and solid-fallback edge tokens.

///|
/// Three-anchor continuous optical interpolation for iOS 27.0 in-place liquid-droplet popover morphing:
/// - `stage == 0.0`: bar-pill anchor (`a=0x67`, `blur=2.0`, `bezel=14`, `refr=20`, `rim=0.60`, `chroma=0.06`);
/// - `stage == 0.5`: mid-flight translucent droplet (`a=0x93` light / `0x88` dark, `blur=4.0`, `bezel=18`, `refr=16`, `rim=0.78`, `chroma=0.045`);
/// - `stage == 1.0`: resting translucent menu anchor (`a=0xBF` light / `0xA8` dark, `blur=6.0`, `bezel=20`, `refr=26`, `rim=0.60`, `chroma=0.03`).
pub fn liquid_menu_morph_glass(
  stage : Double,
  solid? : Int64 = clear,
  dark? : Bool,
  merge? : Double = 0.0,
  layer? : Int = 0,
  break_gap? : Double = 0.0,
) -> @paint.Glass {
  let s = clamp(stage, 0.0, 1.0)
  let d = match dark {
    Some(v) => v
    None => is_dark()
  }
  let base_rgb = if d { 0x20202000L } else { 0xFDFCFD00L }
  let mid_a = if d { 136.0 } else { 147.0 }
  let end_a = if d { 168.0 } else { 191.0 }
  let (a_f, blur, bezel, refraction, rim, chroma) = if s <= 0.5 {
    let u = s * 2.0
    (
      103.0 + (mid_a - 103.0) * u,
      2.0 + (4.0 - 2.0) * u,
      14.0 + (18.0 - 14.0) * u,
      20.0 + (16.0 - 20.0) * u,
      0.60 + (0.78 - 0.60) * u,
      0.06 + (0.045 - 0.06) * u,
    )
  } else {
    let u = (s - 0.5) * 2.0
    (
      mid_a + (end_a - mid_a) * u,
      4.0 + (6.0 - 4.0) * u,
      18.0 + (20.0 - 18.0) * u,
      16.0 + (26.0 - 16.0) * u,
      0.78 + (0.60 - 0.78) * u,
      0.045 + (0.03 - 0.045) * u,
    )
  }
  let a = a_f.round().to_int64() & 0xFFL
  let resolved_solid = if solid != clear {
    solid
  } else if d {
    0x1C1C1EFFL
  } else {
    0xF7F7FAFFL
  }
  @paint.Glass::liquid(
    blur~,
    tint=base_rgb | a,
    solid=resolved_solid,
    saturation=1.0,
    rim~,
    bezel~,
    refraction~,
    chroma~,
    merge~,
    layer~,
    break_gap~,
    adaptive=false,
  )
}

///|
/// Liquid glass material for floating panels (Menu, Popover, List, Disclosure).
/// Native iOS 27 calibrated liquid glass (`0xFDFCFDBFL` 75% light / `0x202020A8L` 65.9% dark) with soft `blur=6.0`,
/// `20/26` bevel refraction, and `0.03` dispersion (paired with shader bright-backdrop relaxation & 1..8pt cushion rim).
pub fn liquid_panel_glass(solid? : Int64 = clear) -> @paint.Glass {
  let d = is_dark()
  @paint.Glass::liquid(
    blur=6.0,
    tint=if d { 0x202020A8L } else { 0xFDFCFDBFL },
    solid=if solid != clear { solid } else if d { 0x1C1C1EFFL } else { 0xF7F7FAFFL },
    saturation=1.0,
    rim=0.6,
    bezel=20.0,
    refraction=26.0,
    chroma=0.03,
    merge=0.0,
    adaptive=false,
  )
}

///|
/// Liquid glass material for modal dialogs and dialog shells.
/// Symmetric 70% luminous liquid glass (`0xFDFCFDB3L` light / `0x202020B3L` dark) calibrated to iOS 26/27:
/// >= 5.7:1–9.7:1 contrast over high-contrast backdrops while preserving crisp bevel refraction and rim glint.
pub fn liquid_dialog_glass(solid? : Int64 = clear) -> @paint.Glass {
  let d = is_dark()
  @paint.Glass::liquid(
    blur=9.0,
    tint=if d { 0x202020B3L } else { 0xFDFCFDB3L },
    solid=if solid != clear { solid } else if d { 0x1C1C1EFFL } else { 0xF7F7FAFFL },
    saturation=1.0,
    rim=0.65,
    bezel=22.0,
    refraction=32.0,
    chroma=0.0,
    merge=0.0,
    adaptive=false,
  )
}

///|
/// Liquid glass material for detached floating sheets and action sheets.
/// Symmetric 80% dense liquid glass (`0xFDFCFDCCL` light / `0x202020CCL` dark) for >= 4.5:1 body text contrast.
pub fn liquid_sheet_glass(solid? : Int64 = clear) -> @paint.Glass {
  let d = is_dark()
  @paint.Glass::liquid(
    blur=12.0,
    tint=if d { 0x202020CCL } else { 0xFDFCFDCCL },
    solid=if solid != clear { solid } else if d { 0x1C1C1EFFL } else { 0xF7F7FAFFL },
    saturation=1.0,
    rim=0.6,
    bezel=20.0,
    refraction=24.0,
    chroma=0.0,
    merge=0.0,
    adaptive=false,
  )
}

///|
/// Liquid glass material for floating island side drawers (`r=28pt`, 10pt outer margin).
/// Symmetric 80% dense liquid glass (`0xFDFCFDCCL` light / `0x202020CCL` dark) with crisp bevel refraction.
pub fn liquid_drawer_glass(solid? : Int64 = clear) -> @paint.Glass {
  let d = is_dark()
  @paint.Glass::liquid(
    blur=12.0,
    tint=if d { 0x202020CCL } else { 0xFDFCFDCCL },
    solid=if solid != clear { solid } else if d { 0x1C1C1EFFL } else { 0xF7F7FAFFL },
    saturation=1.0,
    rim=0.6,
    bezel=22.0,
    refraction=36.0,
    chroma=0.0,
    merge=0.0,
    adaptive=false,
  )
}

///|
/// Liquid glass material for floating toast capsules (`blur=2.1`, symmetric 75% tint, crisp 12/14 bevel).
pub fn liquid_toast_glass(solid? : Int64 = clear) -> @paint.Glass {
  let d = is_dark()
  @paint.Glass::liquid(
    blur=2.1,
    tint=if d { 0x202020BFL } else { 0xFDFCFDBFL },
    solid=if solid != clear { solid } else if d { 0x1E1F24FFL } else { 0xFAFAFAFFL },
    saturation=1.0,
    rim=0.6,
    bezel=12.0,
    refraction=14.0,
    chroma=0.0,
    merge=0.0,
    adaptive=false,
  )
}

///|
/// Liquid glass material for capsule surfaces (Tooltip, capsule overlays).
pub fn liquid_capsule_glass(solid? : Int64 = clear) -> @paint.Glass {
  let d = is_dark()
  @paint.Glass::liquid(
    blur=3.0,
    tint=if d { 0x20202067L } else { 0xFDFCFD67L },
    solid=if solid != clear { solid } else if d { 0x1E1F24FFL } else { 0xFAFAFAFFL },
    saturation=1.0,
    rim=0.6,
    bezel=16.0,
    refraction=24.0,
    chroma=0.0,
    merge=0.0,
    adaptive=false,
  )
}

///|
/// Progressive blur soft scroll-edge backdrop (iOS 26 `UIScrollEdgeEffect.soft`): progressive variable blur
/// across the host node's `View::fades` band (`blur=8.5`, `progressive=true`),
/// degrading to a solid `bg` alpha fade under `MBUI_GLASS=solid`.
///
/// When `pure=true` (full-bleed media viewers), emits zero tint (`tint=clear`, `saturation=1.0`) so dark
/// photos/videos are never washed out by a light-mode scrim. Otherwise (`pure=false`, default for bare-title
/// chat/settings bars), applies a 50% `bg` tint veil (`alpha(resolved, 0.50)`, `saturation=1.25`) to preserve
/// bare-text readability over scrolled content.
pub fn liquid_scroll_edge_glass(bg? : Int64 = clear, pure? : Bool = false) -> @paint.Glass {
  let resolved = if bg != clear {
    bg
  } else if is_dark() {
    0x121212FFL
  } else {
    0xFFFFFFFFL
  }
  @paint.Glass::frosted(
    blur=8.5,
    tint=if pure { clear } else { alpha(resolved, 0.50) },
    solid=resolved,
    saturation=if pure { 1.0 } else { 1.25 },
    progressive=true,
  )
}

///|
/// 1pt hairline border used when `MBUI_GLASS=solid` degrades a floating glass overlay to opaque solid.
pub fn liquid_overlay_solid_edge() -> (Double, Int64) {
  if is_dark() { (1.0, 0xFFFFFF24L) } else { (1.0, 0x00000018L) }
}

///|
/// Default panel / popover corner radius (pt) for `liquid_panel_shell_node`.
let ovl_popover_radius : Double = 22.0
