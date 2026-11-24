// Ported from Kyant0/AndroidLiquidGlass (Apache-2.0): core colours, sizes, typography and colour math
// (Oklab lerp, source-over compositing, stretched capsule helper) for ui/glass.
// Colours are 0xRRGGBBAA; a Compose `Color(0xFFrrggbb).copy(a)` is rrggbb at a × 255.

///|
/// Light or dark as the app says (None: as mbui's window is, its theme's `dark`).
// kept across runs: said by the app as it starts and as the person changes it
let dark_said : @signals.Signal[Bool?] = @signals.signal(None)

///|
/// Light or dark from now on (None: as the window is).
pub fn set_dark(dark : Bool?) -> Unit {
  dark_said.set(dark)
}

///|
/// Whether what is drawn now is drawn dark: the app's say, else the window's.
pub fn is_dark() -> Bool {
  match dark_said.get() {
    Some(d) => d
    None => @ui.tree_theme().dark
  }
}

///|
/// Core liquid glass palette in one look (light or dark).
pub(all) struct Colors {
  /// LiquidSlider's accentColor
  accent : Int64
  /// LiquidToggle's accentColor
  toggle_on : Int64
  /// LiquidToggle's and LiquidSlider's trackColor
  track : Int64
  /// Segmented/lens containerColor
  container : Int64
  /// Foreground contentColor
  content : Int64
  /// Resting lens surface (Black or White at 10%)
  lens_idle : Int64
  /// Loupe paper backgroundColor at 90%
  paper : Int64
}

///|
/// The light look's colours.
pub let light : Colors = {
  accent: 0x0088FFFFL,
  toggle_on: 0x34C759FFL,
  track: 0x7878802AL,
  container: 0xFAFAFA66L,
  content: 0x000000FFL,
  lens_idle: 0x0000001AL,
  paper: 0xFFFFFFE6L,
}

///|
/// The dark look's colours.
pub let dark : Colors = {
  accent: 0x0091FFFFL,
  toggle_on: 0x30D158FFL,
  track: 0x78788037L,
  container: 0x12121266L,
  content: 0xFFFFFFFFL,
  lens_idle: 0xFFFFFF1AL,
  paper: 0x121212E6L,
}

///|
/// Dedicated Switch Off default track colour (separate from Slider `colors().track`):
/// Dark `0x787880ADL` (~90 over `#1C1C1E`), Light `0x78788068L` (~200 over white).
pub fn toggle_off_track() -> Int64 {
  if is_dark() {
    0x787880ADL
  } else {
    0x78788068L
  }
}

///|
/// The colours as a node is drawn now (light or dark: is_dark), read where they are drawn so they follow.
pub fn colors() -> Colors {
  if is_dark() {
    dark
  } else {
    light
  }
}

///|
/// White, as a thumb's surface at rest.
pub let white : Int64 = 0xFFFFFFFFL

///|
/// Black.
pub let black : Int64 = 0x000000FFL

///|
/// Nothing at all.
pub let clear : Int64 = 0x00000000L

///|
/// Backdrop's Shadow.Default (Shadow.kt): radius 24, its offset a sixth of that down, black at 10%; drawn as mbui's
/// shadow by its deviation, half the radius.
pub let shadow_default : (Double, Double, Int64) = (12.0, 4.0, 0x0000001AL)

///|
/// LiquidToggle's and LiquidSlider's thumb's Shadow: radius 4, black at 5%, a sixth of it down.
pub let shadow_thumb : (Double, Double, Int64) = (2.0, 4.0 / 6.0, 0x0000000DL)

///|
/// No shadow.
pub let shadow_none : (Double, Double, Int64) = (0.0, 0.0, 0x00000000L)

///|
/// Outer lift shadow for Slider / Switch thumb: removed (`shadow_none`) for shadow-free lifted transparent droplets.
pub fn thumb_lift_shadow(_press : Double) -> (Double, Double, Int64) {
  shadow_none
}

///|
/// Outer lift shadow for Segmented control's lifted clear lens: removed (`shadow_none`).
pub fn seg_lens_shadow(_press : Double) -> (Double, Double, Int64) {
  shadow_none
}

// Sizes (dp, mbui's points).

///|
/// LiquidToggle: its track 63 × 28, its thumb 37 × 24, 2 in; held 59.2 × 38.4pt (1.60× uniform, matching iOS 27).
pub let toggle_w : Double = 63.0

///|
pub let toggle_h : Double = 28.0

///|
pub let thumb_w : Double = 37.0

///|
pub let thumb_h : Double = 24.0

///|
pub let toggle_pad : Double = 2.0

///|
pub let thumb_held_scale : Double = 1.60

///|
/// LiquidSlider: resting thumb 38 × 24, held 58 × 38pt (`slider_thumb_held_scale = 38/24`).
pub let slider_thumb_w : Double = 38.0

///|
pub let slider_thumb_h : Double = 24.0

///|
pub let slider_thumb_held_scale : Double = 38.0 / 24.0

///|
/// LiquidSlider: its track 6 high.
pub let slider_track_h : Double = 6.0

// Type (sp, mbui's points).

///|
/// Words `size` high at `weight`, on one line unless `wrap` (at most `lines` of them where `lines` > 0).
pub fn words_at(size : Double, weight? : Int = 400, wrap? : Bool = false, lines? : Int = 0) -> @view.WordsLook {
  {
    size,
    weight,
    line: size * 1.4,
    wrap,
    tracking: if size >= 18.0 { Points(-0.25) } else { Points(0.0) },
    balance: false,
    max_lines: lines,
  }
}

///|
/// Body words size: 16.
pub let type_body : Double = 16.0

///|
/// Medium weight.
pub let weight_medium : Int = 500

///|
/// mbui's theme in the liquid glass look (for tests and standalone previews).
pub fn ui_theme() -> @ui.Theme {
  let d = is_dark()
  let c = colors()
  let base = if d { @ui.Theme::dark() } else { @ui.Theme::light() }
  { ..base, fg: c.content, accent: c.accent, focus: c.accent, corner_ladder: [], corner_fit: None }
}

///|
/// `c` at `share` of its opacity.
pub fn alpha(c : Int64, share : Double) -> Int64 {
  let a = (c & 0xFFL).to_double() * clamp(share, 0.0, 1.0)
  (c & 0xFFFFFF00L) | a.round().to_int64()
}

///|
/// `top` laid over `base` (source over).
pub fn over(base : Int64, top : Int64) -> Int64 {
  let ta = (top & 0xFFL).to_double() / 255.0
  let ba = (base & 0xFFL).to_double() / 255.0
  let oa = ta + ba * (1.0 - ta)
  if oa <= 0.0 {
    return clear
  }
  let ch = fn(shift : Int) -> Int64 {
    let t = ((top >> shift) & 0xFFL).to_double()
    let b = ((base >> shift) & 0xFFL).to_double()
    ((t * ta + b * ba * (1.0 - ta)) / oa).round().to_int64().max(0L).min(255L)
  }
  (ch(24) << 24) | (ch(16) << 16) | (ch(8) << 8) | (oa * 255.0).round().to_int64()
}

///|
/// A glass ground drawn moved by (`dx`, `dy`) and `sx` × `sy` times as large about its middle, a capsule still, for a
/// box laid out `w` × `h`.
fn stretched(w : Double, h : Double, dx : Double, dy : Double, sx : Double, sy : Double) -> @view.GroundShape {
  if w <= 0.0 || h <= 0.0 || (dx == 0.0 && dy == 0.0 && sx == 1.0 && sy == 1.0) {
    return @view.ground_as_laid
  }
  let dw = w * (sx - 1.0)
  let dh = h * (sy - 1.0)
  let r = (h + dh) / 2.0
  { dx: dx - dw / 2.0, dy: dy - dh / 2.0, dw, dh, corners: Some((r, r, r, r)) }
}

///|
fn dmax(a : Double, b : Double) -> Double {
  if a > b { a } else { b }
}

///|
fn dmin(a : Double, b : Double) -> Double {
  if a < b { a } else { b }
}

///|
/// `x` held within `lo` … `hi` (Kotlin's coerceIn).
pub fn clamp(x : Double, lo : Double, hi : Double) -> Double {
  if x < lo {
    lo
  } else if x > hi {
    hi
  } else {
    x
  }
}

///|
/// `a` to `b` by `f` (Compose's lerp of floats).
pub fn lerp(a : Double, b : Double, f : Double) -> Double {
  a + (b - a) * f
}

///|
/// Compose's lerp of two colours (Color.kt: through Oklab, alpha straight), `f` of the way from `a` to `b`.
pub fn lerp_color(a : Int64, b : Int64, f : Double) -> Int64 {
  let (al, aa, ab) = oklab_of(a)
  let (bl, ba, bb) = oklab_of(b)
  let alpha_a = (a & 0xFFL).to_double() / 255.0
  let alpha_b = (b & 0xFFL).to_double() / 255.0
  let (r, g, bl2) = srgb_of(lerp(al, bl, f), lerp(aa, ba, f), lerp(ab, bb, f))
  let ch = fn(x : Double) -> Int64 { (clamp(x, 0.0, 1.0) * 255.0).round().to_int64() }
  (ch(r) << 24) | (ch(g) << 16) | (ch(bl2) << 8) | ch(lerp(alpha_a, alpha_b, f))
}

///|
fn to_linear(c : Double) -> Double {
  if c <= 0.04045 {
    c / 12.92
  } else {
    @dmath.pow((c + 0.055) / 1.055, 2.4)
  }
}

///|
fn to_gamma(c : Double) -> Double {
  if c <= 0.0031308 {
    c * 12.92
  } else {
    1.055 * @dmath.pow(c, 1.0 / 2.4) - 0.055
  }
}

///|
fn cbrt(x : Double) -> Double {
  if x < 0.0 {
    -@dmath.pow(-x, 1.0 / 3.0)
  } else {
    @dmath.pow(x, 1.0 / 3.0)
  }
}

///|
/// Oklab (Björn Ottosson's) of an 0xRRGGBBAA colour.
fn oklab_of(c : Int64) -> (Double, Double, Double) {
  let r = to_linear(((c >> 24) & 0xFFL).to_double() / 255.0)
  let g = to_linear(((c >> 16) & 0xFFL).to_double() / 255.0)
  let b = to_linear(((c >> 8) & 0xFFL).to_double() / 255.0)
  let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
  let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
  let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
  (
    0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
  )
}

///|
/// sRGB (0-1 each) of an Oklab colour.
fn srgb_of(l : Double, a : Double, b : Double) -> (Double, Double, Double) {
  let l_ = l + 0.3963377774 * a + 0.2158037573 * b
  let m_ = l - 0.1055613458 * a - 0.0638541728 * b
  let s_ = l - 0.0894841775 * a - 1.2914855480 * b
  let (l3, m3, s3) = (l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_)
  (
    to_gamma(4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3),
    to_gamma(-1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3),
    to_gamma(-0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3),
  )
}
