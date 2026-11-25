// Text: the host shapes a string into grapheme clusters (with the system's
// own engine: Core Text on Apple platforms, canvas 2D in browsers) and
// rasterizes each cluster into its atlas on demand. Line breaking (UAX #14,
// from mbui/text), caret geometry and hit testing are done here, the same on
// every platform.
//
// What the host draws as one piece: a cluster, or a ligature the shaper made of
// several (the host gives it to the first, with the advance shared out). A word
// in a script whose letters take their shapes from their neighbours (Arabic,
// the Indic scripts…) is made one cluster here (@hostapi.text_key), so the host
// rasterizes it whole, joined as it is when the system draws it; a caret in it
// goes before or after the whole word. Right-to-left text is put in its visual
// order line by line (UAX #9, @text.Bidi): each line's clusters reordered, the
// caret and hit testing following them.

///|
priv struct KeptTextLay {
  lay : TextLayout
  mut ahead_known : Bool
  mut ahead_ox : Double
  mut ahead_zoomed : Bool
  mut ahead_moves : Int
}

///|
struct Shaped {
  starts : Array[Int]
  lens : Array[Int]
  adv : Array[Double]
  keys : Array[Int]
  cu : Array[Int]
  // before each cluster: 0 no line break, 1 a break opportunity, 2 a hard
  // line break (UAX #14); computed on demand (Shaped::breaks) so single-line
  // text and multi-run rich paragraphs skip per-run line-break scans
  mut brk : Array[Int]
  len : Int
  // the text's bidirectional levels, when any is not 0 (None: all left to right)
  bidi : @text.Bidi?
  // with letter spacing: how far each cluster's piece is drawn in from where it starts (half the spacing, the
  // other half after it; every advance has the whole of it)
  pad : Double
  // the last layout made of it (with no indent), for the next one asked
  // for with the same line height and wrapping, in a width it fits
  mut lay : KeptTextLay?
  mut lay_max : Double
  mut lay_line : Double
  mut lay_trim : Bool
  mut lay_wrap : Bool
  // the last frame it was asked for in (shapes_thin)
  mut used : Int
}

///|
pub struct TextLayout {
  text : String
  shaped : Shaped
  line_start : Array[Int]
  line_end : Array[Int]
  line_w : Array[Double]
  xs : Array[Double]
  line_of : Array[Int]
  w : Double
  h : Double
  ascent : Double
  line_h : Double
  // each cluster's bidi level on its line (empty: all left to right)
  lv : Array[Int]
}

///|
priv struct Glyph {
  u : Double
  v : Double
  gw : Double
  gh : Double
  ox : Double
  oy : Double
  color : Bool
  // its shelf in the atlas (@hostapi.Atlas; -1: nothing to draw), and whether that is colour glyphs' own
  plot : Int
  in_colour : Bool
  // the pixels a point its cell in the atlas was sized at
  sc : Double
}

///|
/// The strings shaped in one font (size, weight, style) with one letter spacing and effective CJK companion config.
priv struct FontShapes {
  size : Double
  weight : Int
  style : Int
  spacing : Double
  cjk_slot : Int
  cjk_scale_pct : Int
  cjk_weight_off : Int
  map : Map[String, Shaped]
}

///|
priv struct TextCache {
  fonts : Array[FontShapes]
  // strings shaped, in all fonts
  mut shaped : Int
  // ascent, descent, line height; the ascent and descent of the font Han falls back to; whether the host sets lines
  // on whole pixels
  metrics : Map[Int64, (Double, Double, Double, Double, Double, Bool)]
  glyphs : Map[Int, Glyph]
  // where they are in the host's atlas, and in colour glyphs' own (made as the first is asked for, at the size the
  // host's has; colour glyphs' none where the host keeps them with the others)
  mut atlas : @hostapi.Atlas?
  mut colour_atlas : @hostapi.Atlas?
  // the glyphs of what was shaped in this frame that it has not drawn yet, for the host to draw ahead (glyphs_ahead)
  fresh : Array[Int]
  mut generation : Int
  // the frame being drawn, and the last that let go of what was shaped longest ago (shapes_thin)
  mut frame : Int
  mut thinned : Int
  // whether this frame had a glyph with no room in the atlas, the last frame that started the atlases over for one, and
  // whether a whole atlas was too little for what is on the screen (none_short)
  mut short : Bool
  mut started_over : Int
  mut too_much : Bool
  buf : FixedArray[Double]
  mut part_buf : FixedArray[Double]?
  mut seg_buf : FixedArray[Double]?
  gbuf : FixedArray[Double]
}

///|
let text_cache : TextCache = {
  fonts: [],
  shaped: 0,
  metrics: Map([]),
  glyphs: Map([]),
  atlas: None,
  colour_atlas: None,
  fresh: [],
  generation: -1,
  frame: 0,
  thinned: -1,
  short: false,
  started_over: -1,
  too_much: false,
  buf: FixedArray::make(4 * 8192, 0.0),
  part_buf: None,
  seg_buf: None,
  gbuf: FixedArray::make(8, 0.0),
}

///|
/// A frame begins: what it shapes and draws from the atlas is kept through it.
fn text_frame() -> Unit {
  text_cache.frame = text_cache.frame + 1
  for a in [text_cache.atlas, text_cache.colour_atlas] {
    match a {
      Some(a) => a.next_frame()
      None => ()
    }
  }
  none_short()
}

///|
/// As a frame begins, before the window's tree is brought (on_frame; frame_offscreen): what the host drew and measured
/// before, forgotten where it is gone (@hostapi.atlas_generation moved on), what measured words told (words_shaped_in).
fn text_arrive() -> Unit {
  local_font_info_arrive()
  let g = atlas_now()
  if g != text_cache.generation {
    // (a host moves it on as its faces or its scale change, a face it was given is here (a page's, loaded later than
    // asked), its atlas is lost: what was measured in the face before is forgotten with the glyphs)
    let first = text_cache.generation < 0
    text_cache.generation = g
    glyphs_forget()
    // (and the halos blurred of them: their pictures are of the glyphs drawn before, halo.mbt)
    halos_forget()
    // (and the frame drawn whole: its glyphs drawn again where they were, the same numbers, other pixels: hostcall.mbt
    // `presented`)
    presented.forget()
    // (and on the first frame too where something was shaped or measured before it, as a run's tree is brought before
    // its first frame (set_view_app: a column's width measured as it is made): shaped while the generation was not yet
    // read, its glyphs' keys those of a host that may since have forgotten them (a web page's scale or a face changed
    // before its first frame, textSweep), each key drawn as another glyph; with nothing shaped before, nothing measured
    // again)
    if !first ||
      text_cache.shaped > 0 ||
      !text_cache.fonts.is_empty() ||
      !text_cache.metrics.is_empty() {
      clear_shapes()
      text_cache.fonts.clear()
      text_cache.metrics.clear()
      // (and the words laid out in what it measured before, a text's or a paragraph's layout kept on its node, laid out
      // again: a page's face is loaded after it is given (words_forgotten then), its words laid out till it is in the
      // place's face, else kept with those widths and drawn in the face, 「s till.fa il」)
      words_shaped_in.set(words_shaped_in.untracked() + 1)
      view_words_rescaled()
    }
  }
}

///|
/// The atlases started over where the last frame had a glyph with no room in them. A shelf is emptied only if the frame
/// draws nothing from it, and glyphs placed at different times lie across the shelves: with a glyph on the screen on
/// each, no new one gets a place, frame after frame, until what is on the screen changes (words with gaps in them).
/// Started over, what is on the screen lies together. Where the frame right after was short too, an atlas holds less
/// than is on the screen: not started over again until a frame is not (it would draw them all every frame, and none
/// would stay).
fn none_short() -> Unit {
  let short = text_cache.short
  text_cache.short = false
  if !short {
    text_cache.too_much = false
  } else if text_cache.started_over == text_cache.frame - 1 {
    text_cache.too_much = true
  } else if !text_cache.too_much {
    text_cache.started_over = text_cache.frame
    glyphs_forget()
    // (the same numbers may come out of other pixels, as where the generation moves on)
    presented.forget()
  }
}

///|
/// Whether the frame just drawn left a glyph out that the next, starting the atlases over, will draw: a frame owed
/// though nothing else changes.
fn glyphs_short_owed() -> Bool {
  text_cache.short && !text_cache.too_much && text_cache.started_over != text_cache.frame
}

///|
/// Every glyph forgotten, and where it was in the atlas: drawn again as it is next asked for.
fn glyphs_forget() -> Unit {
  glyphs_lost.val = true
  glyph_moves.val += 1
  text_cache.glyphs.clear()
  text_cache.fresh.clear()
  glyphs_laid.clear()
  if !glyphs_ahead_laid_keys.is_empty() {
    glyphs_ahead_laid_keys.clear()
  }
  if !glyphs_ahead_laid_bases.is_empty() {
    glyphs_ahead_laid_bases.clear()
  }
  text_cache.atlas = None
  text_cache.colour_atlas = None
}

///|
/// The glyphs what is made now to be kept draws from (a node's content, made once and composed frame after frame:
/// view_made), each told as it is drawn (its key, where it is in the atlas): None, none told.
// kept across runs: set only while a node's content is made, and put back
let glyphs_kept : Ref[Array[(Int, Double, Double)]?] = Ref(None)

///|
/// Whether a glyph may have gone from where something made to be kept draws it since that was last looked for: one let
/// go of for another (its shelf emptied), all forgotten, or one there was no room for. What draws from the atlas frame
/// after frame is looked through again then (view_glyphs_held), not each frame.
// kept across runs: set as one goes, put back as what draws them is looked through
let glyphs_lost : Ref[Bool] = Ref(true)

///|
/// How many times a glyph may have gone from where it was in the atlas (glyphs_lost's, or one placed again at another
/// scale), over every window of the run: a window that comes in place after another's frame moved one is built whole
/// (window_slots.mbt's glyphs_moved_since).
// kept across runs: only counts on
let glyph_moves : Ref[Int] = Ref(0)

///|
/// Glyph `key` drawn from where `g` is, told to what is made to be kept (glyphs_kept).
fn glyph_kept(key : Int, g : Glyph) -> Unit {
  match glyphs_kept.val {
    Some(a) => a.push((key, g.u, g.v))
    None => ()
  }
}

///|
/// Whether the glyphs `kept` (glyphs_kept's) are each where they were in the atlas still, at `sc` pixels a point, as
/// glyphs_still asks, none said drawn from in this frame (what is not drawn now: Atlas::drawn keeps a shelf through the
/// frame, and one drawn from by nothing on the screen may be emptied).
fn glyphs_there(kept : Array[(Int, Double, Double)], sc : Double) -> Bool {
  for k in kept {
    let (key, u, v) = k
    match text_cache.glyphs.get(key) {
      Some(g) if g.u == u && g.v == v && !glyph_other_scale(g, sc) => ()
      _ => return false
    }
  }
  true
}

///|
/// Whether the glyphs `kept` (glyphs_kept's) are each where they were in the atlas still, each kept there through this
/// frame as what draws from it is (Atlas::drawn); else (one moved or gone, or one there was no room for as it was made,
/// told at -1, -1: never one in the atlas) what draws them is to be made again.
fn glyphs_still(kept : Array[(Int, Double, Double)], sc : Double) -> Bool {
  for k in kept {
    let (key, u, v) = k
    match text_cache.glyphs.get(key) {
      Some(g) if g.u == u && g.v == v && !glyph_other_scale(g, sc) =>
        if g.plot >= 0 { atlas_of(g.in_colour).drawn(g.plot) }
      _ => return false
    }
  }
  true
}

///|
/// How many times as large as the host makes its glyphs (the window's pixels a point) what is painted now draws its
/// words: a shot's pixels a point over the window's (shot.mbt), 1 elsewhere.
// kept across runs: set only while a shot is painted, within one frame's paint, and put back
let words_zoom : Ref[Double] = Ref(1.0)

///|
/// The glyphs of words `text`, shaped as `s` is in `size`, `weight`, `style` and `spacing`, shaped again words_zoom
/// times as large, cluster for cluster: a shot drawn at more pixels a point than the window's draws its words by them,
/// each made by the host as crisp as that. None at 1, or where they do not come to as many clusters.
fn zoomed_keys(
  text : String,
  s : Shaped,
  size : Double,
  weight : Int,
  style : Int,
  spacing : Double,
  cjk_override? : @view.CjkOverride? = None,
) -> Array[Int]? {
  let k = words_zoom.val
  if k == 1.0 {
    return None
  }
  let big = shape(text, size * k, weight, style~, spacing=spacing * k, cjk_override~)
  if big.keys.length() == s.keys.length() {
    Some(big.keys)
  } else {
    None
  }
}

///|
/// Ascent, descent and line height of the system font at this size (its
/// code face, slanted, its serif face: `style`, @hostapi.style_mono, style_italic, style_serif).
fn font_metrics(
  size : Double,
  weight : Int,
  style? : Int = 0,
) -> (Double, Double, Double) {
  let (a, d, l, _, _, _) = all_metrics(size, weight, style)
  (a, d, l)
}

///|
/// Ascent and descent of the font a Han ideograph falls back to at this size (Noto Sans CJK, PingFang, Microsoft
/// YaHei): taller than most Latin faces. A host that does not say (a kept text from before) answers the font's own.
fn han_metrics(size : Double, weight : Int, style? : Int = 0) -> (Double, Double) {
  let (_, _, _, a, d, _) = all_metrics(size, weight, style)
  (a, d)
}

///|
/// Lines set as a browser sets them (Blink's LayoutNG), not as Android does: by the first font's ascent and descent
/// alone, each on a whole point, what is left of the line halved and rounded down above them (FontHeight::AddLeading);
/// what falls back to another font (Chinese) on the same baseline. A frame set as a web page is (a desktop's window,
/// as the desktop app's pages) says so (set_web_lines).
let web_lines : Ref[Bool] = Ref(false)

///|
/// Whether lines are set as a browser sets them from now on (web_lines); the layouts made the other way let go, the
/// window's tree's words measured and drawn again so (view_words_rescaled), as for any change of how all words are
/// shaped.
pub fn set_web_lines(on : Bool) -> Unit {
  if web_lines.val != on {
    web_lines.val = on
    for f in text_cache.fonts {
      for _, s in f.map {
        s.lay = None
      }
    }
    view_words_rescaled()
  }
}

///|
/// A line's ascent and descent as it is set (`cjk`: Chinese in it): the first font's, the taller of it and the font Han
/// falls back to (or the active CJK companion font) with Chinese in it, as Android measures a line by the fonts it
/// draws in; as a browser sets it (web_lines), the first font's alone on a whole point, except when an active CJK
/// companion scales or shifts weight (to prevent clipping enlarged CJK glyphs).
fn line_metrics(
  size : Double,
  weight : Int,
  cjk : Bool,
  style? : Int = 0,
  cjk_override? : @view.CjkOverride? = None,
) -> (Double, Double) {
  let (a, d, _) = font_metrics(size, weight, style~)
  if cjk {
    match effective_cjk(style, cjk_override) {
      Some((cjk_slot, cjk_scale, cjk_weight_off)) => {
        if web_lines.val && cjk_scale == 1.0 && cjk_weight_off == 0 {
          return (a.round(), d.round())
        }
        let cjk_size = size * cjk_scale
        let cjk_weight = imin(imax(weight + cjk_weight_off, 100), 900)
        let cjk_style = (style & @hostapi.style_face_bits.lnot()) | @hostapi.style_face(cjk_slot)
        let (ca, cd, _) = font_metrics(cjk_size, cjk_weight, style=cjk_style)
        return if web_lines.val {
          (dmax(a, ca).round(), dmax(d, cd).round())
        } else {
          (dmax(a, ca), dmax(d, cd))
        }
      }
      None => ()
    }
  }
  if web_lines.val {
    (a.round(), d.round())
  } else if cjk {
    let (ha, hd) = han_metrics(size, weight, style~)
    (dmax(a, ha), dmax(d, hd))
  } else {
    (a, d)
  }
}

///|
/// Whether lines are set as a browser sets them now (set_web_lines).
pub fn web_lines_on() -> Bool {
  web_lines.val
}

///|
/// Where the baseline of one line of words in `size` and `weight` (no Chinese in it) falls from the top of a line
/// `line` high, as set_line sets it: by the ascent and descent of the face the words are in, or, given `em`, of a face
/// reaching those shares of its size above and below its baseline (one the words are not in, to compare with).
pub fn line_baseline(
  line : Double,
  size? : Double = 15.0,
  weight? : Int = 400,
  em? : (Double, Double),
) -> Double {
  let (asc, desc) = match em {
    Some((a, d)) if web_lines.val => ((a * size).round(), (d * size).round())
    Some((a, d)) => (a * size, d * size)
    None => line_metrics(size, weight, false)
  }
  set_line(line, asc, desc, g().scale, whole_pixel_lines(size, weight)).1
}

///|
/// Whether the host sets a line of words on whole device pixels, as Android's StaticLayout does (its font metrics
/// whole pixels too): the sixth number it answers of font_metrics, 1. A host that does not say does not.
fn whole_pixel_lines(size : Double, weight : Int, style? : Int = 0) -> Bool {
  all_metrics(size, weight, style).5
}

///|
fn all_metrics(size : Double, weight : Int, style : Int) -> (Double, Double, Double, Double, Double, Bool) {
  // (measured in what the host measures in now, followed: measured again as that changes)
  words_shaped_in.get() |> ignore
  // (the font's figures change no line of it: its metrics are the same either way)
  let style = style & @hostapi.style_tabular.lnot()
  // (the size in tenths, the weight, the style's bits: 5-bit faces and all, each in a field of its own)
  let key = (((size * 10.0).to_int() * 1000 + weight).to_int64() << 13) | (style & 8191).to_int64()
  match text_cache.metrics.get(key) {
    Some(m) => m
    None => {
      let o = FixedArray::make(6, -1.0)
      h_font_metrics(size, weight, style, o)
      // (-1: not said)
      let m = (
        o[0],
        o[1],
        o[2],
        if o[3] < 0.0 { o[0] } else { o[3] },
        if o[4] < 0.0 { o[1] } else { o[4] },
        o[5] == 1.0,
      )
      text_cache.metrics[key] = m
      m
    }
  }
}

///|
/// Whether the Unicode code point belongs to the unified CJK character set (Han, kana, Hangul, bopomofo, CJK and
/// full-width punctuation, and Extension B..I ideographs U+20000..U+3FFFF).
fn is_cjk_cp(cp : Int) -> Bool {
  (cp >= 0x1100 && cp <= 0x11FF) ||
  (cp >= 0x2E80 && cp <= 0x9FFF) ||
  (cp >= 0xA960 && cp <= 0xA97F) ||
  (cp >= 0xAC00 && cp <= 0xD7AF) ||
  (cp >= 0xF900 && cp <= 0xFAFF) ||
  (cp >= 0xFE10 && cp <= 0xFE1F) ||
  (cp >= 0xFE30 && cp <= 0xFE4F) ||
  (cp >= 0xFF00 && cp <= 0xFFEF) ||
  (cp >= 0x20000 && cp <= 0x3FFFF)
}

///|
/// Whether the code point is an East Asian Ambiguous punctuation mark that belongs to CJK when not in narrow context.
fn is_ambiguous_cjk_punct(cp : Int) -> Bool {
  cp == 0x2018 ||
  cp == 0x2019 ||
  cp == 0x201C ||
  cp == 0x201D ||
  cp == 0x2014 ||
  cp == 0x2026 ||
  cp == 0x00B7 ||
  cp == 0x2022 ||
  cp == 0x2027
}

///|
/// Whether the grapheme cluster starting at UTF-16 offset `start` in `text` routes to the CJK companion font, given
/// whether `@text.width_runs` marked its context as narrow (Latin).
fn is_cjk_cluster(text : String, start : Int, is_narrow_ctx : Bool) -> Bool {
  let cp = cp_at(text, start)
  is_cjk_cp(cp) || (!is_narrow_ctx && is_ambiguous_cjk_punct(cp))
}

///|
/// Whether the UTF-16 code unit starts a character set in a CJK font: Han, kana, Hangul, bopomofo, CJK and full-width
/// punctuation (high surrogate 0xD840..0xD8BF covers supplementary ideographs U+20000..U+3FFFF).
fn is_cjk(c : Int) -> Bool {
  (c >= 0x1100 && c <= 0x11FF) ||
  (c >= 0x2E80 && c <= 0x9FFF) ||
  (c >= 0xA960 && c <= 0xA97F) ||
  (c >= 0xAC00 && c <= 0xD7AF) ||
  (c >= 0xD840 && c <= 0xD8BF) ||
  (c >= 0xF900 && c <= 0xFAFF) ||
  (c >= 0xFE10 && c <= 0xFE1F) ||
  (c >= 0xFE30 && c <= 0xFE4F) ||
  (c >= 0xFF00 && c <= 0xFFEF)
}

///|
/// Whether any of the words is in a CJK font's characters (is_cjk).
fn words_cjk(text : String) -> Bool {
  for i in 0..<text.length() {
    if is_cjk(text.unsafe_get(i).to_int()) {
      return true
    }
  }
  false
}

///|
/// How a line of words is set in a line `line` high, its font reaching `asc` above the baseline and `desc` below, as
/// Android sets it (Compose's line height: LineHeightStyle Center, Trim.None, Mode.Tight): the room over the font
/// shared out above and below; a font taller than its line not cut (the first line keeps the font's top, the last its
/// bottom). On a host that sets lines on whole pixels (`px`: Android's, whole_pixel_lines) the line is rounded up to
/// one and the room shared in them, below the bigger half; elsewhere the line is as asked and the room halved. A font
/// taller than its line there is padded as Compose pads a theme's words (Material's Text: LineHeightStyle Center,
/// Trim.None, Mode.Fixed) unless `trim` (words in a TextStyle of their own, with no LineHeightStyle, or Trim.Both:
/// SendText.kt's): the first line over by what its ascent lost, the last under by as much or what its descent lost,
/// whichever more (TextLayout getLineHeightPaddings), where `trim` keeps the font's own reach and no more.
/// (pitch: from a line to the next; the first line's baseline from the top; how much more than the lines' pitch
/// the words are high.)
fn set_line(
  line : Double,
  asc : Double,
  desc : Double,
  sc : Double,
  px : Bool,
  trim? : Bool = false,
  cjk_fit? : Bool = false,
) -> (Double, Double, Double) {
  // as a browser: the room halved, rounded down above; a font taller than its line overflows it, the line as asked
  // (except when an enlarged CJK companion is active and its ascent+descent exceeds the requested line, in which case
  // keep enough extra box height so the final line is not clipped).
  if web_lines.val {
    if cjk_fit && asc + desc > line {
      return (line, asc, asc + desc - line)
    }
    return (line, asc + ((line - asc - desc) / 2.0).floor(), 0.0)
  }
  let sc = if sc > 0.0 { sc } else { 1.0 }
  let pitch = if px { (line * sc - 1.0e-6).ceil() / sc } else { line }
  let room = pitch - asc - desc
  if room >= 0.0 {
    let below = if px { (room * sc / 2.0 - 1.0e-6).ceil() / sc } else { room / 2.0 }
    (pitch, pitch - desc - below, 0.0)
  } else if px && !trim {
    // (a 32 px bold Chinese line in 118 pixels: 97 + 25 high, its font's 97 + 24; Compose on an emulator, 2026-10-22)
    let missing = (-room * sc).round()
    let lost = (missing / 2.0).floor()
    let over = missing - lost
    let under = if lost > 0.0 { dmax(over, lost) } else { 0.0 }
    (pitch, asc, (over + under) / sc)
  } else {
    (pitch, asc, -room)
  }
}

///|
/// The shapes of one font (with its effective CJK companion config): looked up by the string alone, no key to build.
fn font_shapes(
  size : Double,
  weight : Int,
  style : Int,
  spacing : Double,
  cjk_slot : Int,
  cjk_scale_pct : Int,
  cjk_weight_off : Int,
) -> Map[String, Shaped] {
  for f in text_cache.fonts {
    if f.size == size &&
      f.weight == weight &&
      f.style == style &&
      f.spacing == spacing &&
      f.cjk_slot == cjk_slot &&
      f.cjk_scale_pct == cjk_scale_pct &&
      f.cjk_weight_off == cjk_weight_off {
      return f.map
    }
  }
  let map = Map([])
  text_cache.fonts.push({ size, weight, style, spacing, cjk_slot, cjk_scale_pct, cjk_weight_off, map })
  map
}

///|
/// The most strings kept shaped: past it, what was asked for longest ago is let go (shapes_thin).
let shapes_most : Int = 6000

///|
/// The half of what is shaped that was asked for longest ago let go, never what this frame asked for: shaped again if
/// it is asked for again. (Every shape let go at once, a frame shaped again everything on the screen.)
fn shapes_thin() -> Unit {
  if text_cache.thinned == text_cache.frame {
    return
  }
  text_cache.thinned = text_cache.frame
  let used = []
  for f in text_cache.fonts {
    for _, s in f.map {
      used.push(s.used)
    }
  }
  if used.is_empty() {
    return
  }
  used.sort()
  let cut = used[used.length() / 2]
  let mut kept = 0
  for f in text_cache.fonts {
    let gone = []
    for t, s in f.map {
      if s.used < cut || (s.used == cut && cut < text_cache.frame) {
        gone.push(t)
        // (a shape and its last layout refer to each other: clear_shapes)
        s.lay = None
      } else {
        kept = kept + 1
      }
    }
    for t in gone {
      f.map.remove(t)
    }
  }
  text_cache.shaped = kept
}

///|
fn clear_shapes() -> Unit {
  // (and who spaces words and how the host's face draws the marks set closer: found again as a run starts or the
  // faces change)
  spaced_said.val = None
  spaced_stops_left.clear()
  marks_narrow.clear()
  for f in text_cache.fonts {
    // a shape and its last layout refer to each other (reference counts
    // never free a cycle): let go of the layout first
    for _, s in f.map {
      s.lay = None
    }
    f.map.clear()
  }
  text_cache.shaped = 0
}

///|
// kept across runs: empty placeholder for Array::release_unused on text_cache.fonts
let font_shapes_gone : FontShapes = {
  size: 0.0,
  weight: 0,
  style: 0,
  spacing: 0.0,
  cjk_slot: 0,
  cjk_scale_pct: 100,
  cjk_weight_off: 0,
  map: Map([]),
}

///|
/// Surgically evict shape, metric, and mark caches referencing preview/try `face` without incrementing
/// `words_shaped_in` or evicting unrelated global window text caches.
fn forget_words_for_face(face : Int) -> Unit {
  let kept : Array[FontShapes] = []
  let mut shaped = 0
  for f in text_cache.fonts {
    if @hostapi.face_of_style(f.style) == face || f.cjk_slot == face {
      for _, s in f.map {
        s.lay = None
      }
      f.map.clear()
    } else {
      shaped = shaped + f.map.length()
      kept.push(f)
    }
  }
  text_cache.fonts.clear()
  for f in kept {
    text_cache.fonts.push(f)
  }
  text_cache.fonts.release_unused(placeholder=font_shapes_gone)
  text_cache.shaped = shaped
  rich_forget_face(face)
  let gone_metrics : Array[Int64] = []
  for k, _ in text_cache.metrics {
    if @hostapi.face_of_style((k & 8191L).to_int()) == face {
      gone_metrics.push(k)
    }
  }
  for k in gone_metrics {
    text_cache.metrics.remove(k)
  }
  let gone_marks : Array[Int] = []
  for k, _ in marks_narrow {
    if @hostapi.face_of_style(k >> 12) == face {
      gone_marks.push(k)
    }
  }
  for k in gone_marks {
    marks_narrow.remove(k)
  }
  let gone_stops : Array[Int] = []
  for k, _ in spaced_stops_left {
    if (k >> 12) == face {
      gone_stops.push(k)
    }
  }
  for k in gone_stops {
    spaced_stops_left.remove(k)
  }
  presented.forget()
  let g = h_atlas_generation()
  if g != text_cache.generation {
    words_forgotten()
    return
  }
  view_words_rescaled_for_face(face)
}

///|
/// Whether `text` has a digit in it: words with none are shaped the same with their digits all one width
/// (@hostapi.style_tabular) as without, in the same font, their glyphs the same (shape asks it of the host only where
/// it changes something, the glyphs of the rest kept once).
fn has_digit(text : String) -> Bool {
  for i in 0..<text.length() {
    let c = text.at(i).to_int()
    if c >= 48 && c <= 57 {
      return true
    }
  }
  false
}

///|
/// The host's clusters of `text` (h_shape), shaped as they always were; and where the face drew a mark of ambiguous
/// width a whole em among Latin letters (a CJK face: 思源黑体's "it’s"), shaped again a piece at a time
/// (@text.width_runs), the narrow pieces with @hostapi.style_proportional, their clusters put together. A face whose
/// such marks are narrow already (Inter, Segoe UI, San Francisco, the system's) is asked nothing more, and words
/// with none of those marks, or only marks the face was seen to draw narrow so (marks_narrow), are not cut at all.
fn shape_widths(text : String, size : Double, weight : Int, style : Int, out : FixedArray[Double]) -> Int {
  let k = h_shape(text, size, weight, style, out)
  // (only a mark can be found drawn a whole em below: words with none, or with none this face is not known to draw
  // narrow, come out as shaped, not cut into pieces and looked through)
  let face = marks_face(weight, style)
  let known = marks_narrow.get(face).unwrap_or(0)
  let mut unknown = false
  for i in 0..<text.length() {
    if @text.width_mark(text, i) {
      let bit = width_mark_bit(text.code_unit_at(i).to_int())
      if bit == 0 || (known & bit) == 0 {
        unknown = true
        break
      }
    }
  }
  guard unknown else { return k }
  let runs = @text.width_runs(text)
  guard runs.length() > 1 || runs[0].2 else { return k }
  // a quote, a middle dot or an ellipsis in a narrow piece drawn a whole em (@text.width_mark): the face is one that
  // has its marks narrow only when asked; one drawn well under an em there is so in this face (marks_narrow)
  let mut wide = false
  let mut seen = known
  let mut r = 0
  for j in 0..<k {
    let st = out[j * 4].to_int()
    while r < runs.length() - 1 && st >= runs[r].1 {
      r = r + 1
    }
    if runs[r].2 && @text.width_mark(text, st) {
      if out[j * 4 + 2] >= size * 0.95 {
        wide = true
        break
      }
      if out[j * 4 + 2] < size * marks_narrow_under {
        seen = seen | width_mark_bit(text.code_unit_at(st).to_int())
      }
    }
  }
  if seen != known {
    marks_narrow[face] = seen
  }
  guard wide else { return k }
  let cap = out.length() / 4
  let part = match text_cache.part_buf {
    Some(b) if b.length() >= out.length() => b
    _ => {
      let b = FixedArray::make(out.length(), 0.0)
      text_cache.part_buf = Some(b)
      b
    }
  }
  let mut k = 0
  for run in runs {
    let (a, b, narrow) = run
    let style = if narrow { style | @hostapi.style_proportional } else { style }
    let m = h_shape(text.unsafe_substring(start=a, end=b), size, weight, style, part)
    for j in 0..<m {
      if k >= cap {
        break
      }
      out[k * 4] = part[j * 4] + a.to_double()
      out[k * 4 + 1] = part[j * 4 + 1]
      out[k * 4 + 2] = part[j * 4 + 2]
      out[k * 4 + 3] = part[j * 4 + 3]
      k = k + 1
    }
  }
  k
}

///|
/// The marks of ambiguous width (@text.width_mark) each face was seen to draw narrow among Latin letters, as it was
/// asked for (no style_proportional), a bit a mark (width_mark_bit), by the face (marks_face): words whose every such
/// mark is one of them are not looked through again (shape_widths).
// kept across runs: forgotten with the shapes (clear_shapes: a Tester's run, the host's faces changed)
let marks_narrow : Map[Int, Int] = Map([])

///|
/// How far under an em a mark is drawn to be seen narrow in its face (marks_narrow): well under the whole em
/// (shape_widths' 0.95) at any size, whatever a size's pixels round its advance to.
let marks_narrow_under : Double = 0.6

///|
/// A face as marks_narrow keeps it: its style (what face, slant and features) and its weight.
fn marks_face(weight : Int, style : Int) -> Int {
  (style << 12) | (weight & 0xFFF)
}

///|
/// The bit of marks_narrow of the code unit `c`, a mark of @text.width_mark; 0 of any other (never known narrow).
fn width_mark_bit(c : Int) -> Int {
  match c {
    0x2018 => 1
    0x2019 => 2
    0x201C => 4
    0x201D => 8
    0xB7 => 16
    0x2027 => 32
    0x2022 => 64
    0x2026 => 128
    _ => 0
  }
}

///|
/// Who spaces Chinese and Japanese words (@hostapi.words_spaced), asked once a run.
// kept across runs: forgotten with the shapes (clear_shapes: a Tester's run, the host's faces changed)
let spaced_said : Ref[Int?] = Ref(None)

///|
fn spaced_now() -> Int {
  match spaced_said.val {
    Some(s) => s
    None => {
      let s = @hostapi.words_spaced()
      spaced_said.val = Some(s)
      s
    }
  }
}

///|
/// The number of the mark `c` that closes a clause or a sentence (，。、：； 0 to 4), else -1.
fn spaced_stop_of(c : Int) -> Int {
  match c {
    0xFF0C => 0
    0x3002 => 1
    0x3001 => 2
    0xFF1A => 3
    0xFF1B => 4
    _ => -1
  }
}

///|
/// The mark that closes a clause or a sentence numbered `i` (spaced_stop_of's).
fn spaced_stop(i : Int) -> String {
  match i {
    0 => "\u{FF0C}"
    1 => "\u{3002}"
    2 => "\u{3001}"
    3 => "\u{FF1A}"
    _ => "\u{FF1B}"
  }
}

///|
/// Whether the host's face draws each of the marks that close a clause (spaced_stop) in the first half of its em (as a simplified Chinese face draws
/// them all; a traditional one draws them in the middle, a Japanese one ：；), found of their glyphs once per `(cjk_slot, cjk_weight)`: where one is
/// drawn in the middle, set half an em closer to the mark after it, the two marks' ink would meet (。」).
// kept across runs: forgotten with the shapes (clear_shapes: a Tester's run, the host's faces changed)
let spaced_stops_left : Map[Int, FixedArray[Bool]] = Map([])

///|
fn spaced_stop_left(i : Int, stop_style? : Int = 0, stop_weight? : Int = 400) -> Bool {
  let slot = @hostapi.face_of_style(stop_style)
  let cache_key = (slot << 12) | (stop_weight & 0xFFF)
  let left = match spaced_stops_left.get(cache_key) {
    Some(l) => l
    None => {
      let size = 16.0
      let out = FixedArray::make(16 * 4, 0.0)
      let g = FixedArray::make(8, 0.0)
      let l = FixedArray::make(5, false)
      let probe_style = if slot > 0 { @hostapi.style_face(slot) } else { 0 }
      for k in 0..<5 {
        let n = h_shape(spaced_stop(k), size, stop_weight, probe_style, out)
        let key = if n == 1 { out[3].to_int() } else { -1 }
        l[k] = if n != 1 {
          // (not one cluster as a mark is: not known to be left)
          false
        } else if key < 0 {
          // (nothing drawn: no ink to meet)
          true
        } else {
          h_glyph(key, g)
          // its ink (where it starts from the pen, how wide) ends before the em's middle, or there is none
          g[2] == 0.0 || g[4] + g[2] <= size * 0.45
        }
      }
      spaced_stops_left[cache_key] = l
      l
    }
  }
  left[i]
}

///|
/// A Han character or kana (not a mark): what an eighth of an em parts from a Latin letter or a digit.
fn spaced_wide(c : Int) -> Bool {
  (c >= 0x3400 && c <= 0x4DBF) ||
  (c >= 0x4E00 && c <= 0x9FFF) ||
  (c >= 0xF900 && c <= 0xFAFF) ||
  // (a high surrogate of the planes' ideographs, U+20000 to U+3FFFF)
  (c >= 0xD840 && c <= 0xD8BF) ||
  (c >= 0x3041 && c <= 0x3096) ||
  (c >= 0x30A1 && c <= 0x30FA) ||
  c == 0x30FC
}

///|
fn spaced_narrow(c : Int) -> Bool {
  (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
}

///|
/// 1 a full-width closing bracket or quote (its ink in the first half of its em in a simplified Chinese, a traditional
/// Chinese and a Japanese face alike: its second half empty), 2 an opening one (its ink in its second half), 3 a mark
/// closing a clause (，。、：；: its second half empty only where spaced_stop_left says so), else 0. ！ and ？ are none:
/// drawn in the middle by a traditional and a Japanese face, and wider than half an em in a simplified one (as chws
/// leaves them).
fn spaced_mark(c : Int) -> Int {
  match c {
    0xFF09 | 0x300D | 0x300F | 0x3011 | 0x300B | 0x3009 | 0x3015 | 0x3017 | 0xFF3D | 0xFF5D | 0x201D | 0x2019 => 1
    0xFF08 | 0x300C | 0x300E | 0x3010 | 0x300A | 0x3008 | 0x3014 | 0x3016 | 0xFF3B | 0xFF5B | 0x201C | 0x2018 => 2
    0xFF0C | 0x3002 | 0x3001 | 0xFF1A | 0xFF1B => 3
    _ => 0
  }
}

///|
/// Whether full-width mark `c` (spaced_mark's 1 or 3) has the second half of its em empty, in the host's face.
fn spaced_mark_open_after(c : Int, m : Int, stop_style? : Int = 0, stop_weight? : Int = 400) -> Bool {
  if m == 1 {
    return true
  }
  let i = spaced_stop_of(c)
  i >= 0 && spaced_stop_left(i, stop_style~, stop_weight~)
}

///|
/// Chinese and Japanese words in the host's clusters (`out`, `k` of them) spaced as Core Text has spaced them since
/// iOS 26 and macOS 27, where the host's shaper spaces none (@hostapi.words_spaced_here: Android's, Windows', Linux's,
/// the web's): an eighth of an em between a Han character or kana and a Latin letter or a digit right beside it, either
/// way round (never where anything is between them: a space someone wrote, a no-break space, a tab, a mark), put
/// on the advance of the first of the two, so each glyph is drawn where its cluster starts and the room is after the
/// first (on the second's, a Latin letter after Han showed its room after it: 你是O wner, apple_text.m); and a
/// full-width mark a whole em wide before another a half em narrower where its ink ends before the other's begins (a
/// closing bracket's empty second half, a clause's mark's where the face draws it in its first half (spaced_stop_left);
/// an opening bracket's before another opening one's empty first half), as chws sets them: never an opening one before
/// a closing one ("（）"). A mark a host set closer already (Windows' punct_solid) is no longer an em: left as it is.
/// The text is not changed (what is copied is what was written) and a caret goes by the advances. Not in the code
/// face, whose columns are a grid.
fn words_spaced_in(
  text : String,
  size : Double,
  out : FixedArray[Double],
  k : Int,
  space_words : Bool,
  cjk_em? : Double = size,
  stop_style? : Int = 0,
  stop_weight? : Int = 400,
) -> Unit {
  let gap = size * 0.125
  let tol = cjk_em * 0.05
  for j in 0..<(k - 1) {
    let a = out[j * 4].to_int()
    let b = out[(j + 1) * 4].to_int()
    if a >= text.length() || b >= text.length() {
      continue
    }
    let ca = text.at(a).to_int()
    let cb = text.at(b).to_int()
    if spaced_pair(ca, cb) {
      if space_words {
        out[j * 4 + 2] = out[j * 4 + 2] + gap
      }
      continue
    }
    let ma = spaced_mark(ca)
    let mb = spaced_mark(cb)
    // (an opening bracket before another opening one: the other's empty first half; a closing mark before any: its
    // own empty second half, where it has one)
    let closer = if ma == 2 {
      mb == 2
    } else {
      ma != 0 && mb != 0 && spaced_mark_open_after(ca, ma, stop_style~, stop_weight~)
    }
    if !closer {
      continue
    }
    if (out[j * 4 + 2] - cjk_em).abs() <= tol && (out[(j + 1) * 4 + 2] - cjk_em).abs() <= tol {
      out[j * 4 + 2] = out[j * 4 + 2] - cjk_em / 2.0
    }
  }
}

///|
/// Whether a cluster starting with `a` right before one starting with `b` are a Han character or kana and a Latin
/// letter or a digit, either way round: an eighth of an em between them.
fn spaced_pair(a : Int, b : Int) -> Bool {
  (spaced_wide(a) && spaced_narrow(b)) || (spaced_narrow(a) && spaced_wide(b))
}

///|
/// Whether every UTF-16 unit in `text` is a standalone UAX #29 extended grapheme cluster, non-joining, and left-to-right
/// (matching Android MBText.unitClusters): tab, line feed, printable ASCII, common standalone Latin-1 / general
/// punctuation & currency symbols, and CJK / kana / Hangul syllables / fullwidth punctuation without combining marks,
/// surrogates, CR, variation selectors, bidi controls, emoji-candidate symbols, or ZWJ.
fn unit_clusters(text : String) -> Bool {
  let n = text.length()
  for k in 0..<n {
    let c = text.at(k).to_int()
    if c >= 0x20 && c <= 0x7E {
      continue
    }
    if c < 0x3000 {
      if c == 10 ||
        c == 9 ||
        c == 0x00A5 ||
        c == 0x00A7 ||
        c == 0x00B0 ||
        c == 0x00B1 ||
        c == 0x00B7 ||
        c == 0x00D7 ||
        c == 0x00F7 ||
        c == 0x2013 ||
        c == 0x2014 ||
        (c >= 0x2018 && c <= 0x201D) ||
        c == 0x2022 ||
        c == 0x2026 ||
        c == 0x2030 ||
        c == 0x2032 ||
        c == 0x2033 ||
        c == 0x20AC ||
        c == 0x2103 {
        continue
      }
      return false
    }
    if c <= 0x3029 ||
      (c >= 0x3041 && c <= 0x3096) ||
      (c >= 0x30A1 && c <= 0x30FF) ||
      (c >= 0x3400 && c <= 0x9FFF) ||
      (c >= 0xAC00 && c <= 0xD7A3) ||
      (c >= 0xFF01 && c <= 0xFF60) {
      continue
    }
    return false
  }
  true
}

///|
/// UAX #14 line-break opportunities before each cluster of `self`, computed once on demand and kept on `self`.
fn Shaped::breaks(self : Shaped, text : String) -> Array[Int] {
  let n = self.starts.length()
  if self.brk.length() == n {
    return self.brk
  }
  let brk = Array::make(n, 0)
  if n > 1 {
    let b = @text.line_breaks(text)
    for k in 1..<n {
      brk[k] = b[self.starts[k]]
    }
  }
  self.brk = brk
  brk
}

///|
/// With `spacing` (letter spacing, as Android's: each cluster's advance has it, half before its piece and half
/// after), shaped with no ligatures (@hostapi.style_no_ligatures): a ligature's letters would not be spaced.
fn shape(
  text : String,
  size : Double,
  weight : Int,
  style? : Int = 0,
  spacing? : Double = 0.0,
  keep_tabular? : Bool = false,
  cjk_override? : @view.CjkOverride? = None,
) -> Shaped {
  // (measured in what the host measures in now, followed: measured again as that changes)
  words_shaped_in.get() |> ignore
  let style = if spacing != 0.0 { style | @hostapi.style_no_ligatures } else { style }
  // (digits all one width only where they would not be: the code face's are, and words with none have none unless
  // keep_tabular preserves the pre-truncation choice)
  let style = if (style & @hostapi.style_tabular) != 0 &&
    ((style & @hostapi.style_mono) != 0 || (!keep_tabular && !has_digit(text))) {
    style & @hostapi.style_tabular.lnot()
  } else {
    style
  }
  let eff = effective_cjk(style, cjk_override)
  let (cjk_slot, cjk_scale_pct, cjk_weight_off) = match eff {
    Some((slot, sc, woff)) => (slot, (sc * 100.0).round().to_int(), woff)
    None => (0, 100, 0)
  }
  let cjk_scale = cjk_scale_pct.to_double() / 100.0
  let shapes = font_shapes(size, weight, style, spacing, cjk_slot, cjk_scale_pct, cjk_weight_off)
  match shapes.get(text) {
    Some(s) => {
      s.used = text_cache.frame
      s
    }
    None => {
      if text_cache.shaped > shapes_most {
        shapes_thin()
      }
      let out = text_cache.buf
      let cjk_size = size * cjk_scale
      let cjk_weight = imin(imax(weight + cjk_weight_off, 100), 900)
      let cjk_style = if cjk_slot > 0 {
        (style & @hostapi.style_face_bits.lnot()) | @hostapi.style_face(cjk_slot)
      } else {
        style
      }
      let out_cjk : Array[Bool] = []
      let mut seg_count = 1
      let seg_ends : Array[Int] = []
      let m = if text.length() == 0 {
        0
      } else if cjk_slot == 0 {
        shape_widths(text, size, weight, style, out)
      } else {
        // Composite font stack segmentation: full-context width_runs + extended grapheme clusters
        let wruns = @text.width_runs(text)
        let gbs = @text.graphemes(text)
        let segs : Array[(Int, Int, Bool)] = []
        let mut r = 0
        for gi in 0..<(gbs.length() - 1) {
          let cs = gbs[gi]
          let ce = gbs[gi + 1]
          while r < wruns.length() - 1 && cs >= wruns[r].1 {
            r = r + 1
          }
          let is_narrow = if r < wruns.length() { wruns[r].2 } else { false }
          let is_c = is_cjk_cluster(text, cs, is_narrow)
          let slen = segs.length()
          if slen > 0 && segs[slen - 1].2 == is_c {
            segs[slen - 1] = (segs[slen - 1].0, ce, is_c)
          } else {
            segs.push((cs, ce, is_c))
          }
        }
        seg_count = segs.length()
        if seg_count == 1 && !segs[0].2 {
          shape_widths(text, size, weight, style, out)
        } else {
          let cap = out.length() / 4
          let seg_buf = match text_cache.seg_buf {
            Some(b) if b.length() >= out.length() => b
            _ => {
              let b = FixedArray::make(out.length(), 0.0)
              text_cache.seg_buf = Some(b)
              b
            }
          }
          let mut k = 0
          for seg in segs {
            let (sa, sb, is_c) = seg
            let sub = text.unsafe_substring(start=sa, end=sb)
            let sm = if is_c {
              shape_widths(sub, cjk_size, cjk_weight, cjk_style, seg_buf)
            } else {
              shape_widths(sub, size, weight, style, seg_buf)
            }
            for j in 0..<sm {
              if k >= cap {
                break
              }
              out[k * 4] = seg_buf[j * 4] + sa.to_double()
              out[k * 4 + 1] = seg_buf[j * 4 + 1]
              out[k * 4 + 2] = seg_buf[j * 4 + 2]
              out[k * 4 + 3] = seg_buf[j * 4 + 3]
              out_cjk.push(is_c)
              k = k + 1
            }
            seg_ends.push(k)
          }
          k
        }
      }
      if m > 1 &&
        (style & @hostapi.style_mono) == 0 &&
        @hostapi.face_of_style(style) != @hostapi.face_code &&
        spaced_now() != @hostapi.words_spaced_none {
        let mode = spaced_now()
        words_spaced_in(
          text,
          size,
          out,
          m,
          mode == @hostapi.words_spaced_here && cjk_autospace_on.val,
          cjk_em=if out_cjk.length() > 0 { cjk_size } else { size },
          stop_style=if out_cjk.length() > 0 { cjk_style } else { 0 },
          stop_weight=if out_cjk.length() > 0 { cjk_weight } else { 400 },
        )
        if mode == @hostapi.words_spaced_by_host && seg_count >= 2 && cjk_autospace_on.val {
          // Cross-segment boundary spacing when host shaper only saw each segment individually
          let gap = size * 0.125
          for si in 0..<(seg_ends.length() - 1) {
            let idx = seg_ends[si]
            if idx > 0 && idx < m {
              let a = out[(idx - 1) * 4].to_int()
              let b = out[idx * 4].to_int()
              if a < text.length() && b < text.length() {
                if spaced_pair(text.at(a).to_int(), text.at(b).to_int()) {
                  out[(idx - 1) * 4 + 2] = out[(idx - 1) * 4 + 2] + gap
                }
              }
            }
          }
        }
      }
      // UAX #29's clusters: a host that cut one in two (a Thai vowel sign some segmenters leave on its own) is
      // made whole again. Where every unit is a standalone non-joining LTR cluster (ASCII and nearly all CJK:
      // unit_clusters), skip graphemes, joining, line_breaks and bidi_mixed.
      let has_cjk_flags = out_cjk.length() == m && m > 0
      let key_for = fn(sub : String, is_c : Bool) -> Int {
        if is_c {
          h_text_key(sub, cjk_size, cjk_weight, cjk_style)
        } else {
          h_text_key(sub, size, weight, style)
        }
      }
      let simple = unit_clusters(text)
      let mut lb : FixedArray[Int]? = None
      let starts = Array(capacity=m)
      let lens = Array(capacity=m)
      let adv = Array(capacity=m)
      let keys = Array(capacity=m)
      let cu = Array(capacity=m)
      let cjk_flags : Array[Bool] = if has_cjk_flags { Array(capacity=m) } else { [] }
      if simple {
        for i in 0..<m {
          let st = out[i * 4].to_int()
          starts.push(st)
          lens.push(out[i * 4 + 1].to_int())
          adv.push(out[i * 4 + 2])
          keys.push(out[i * 4 + 3].to_int())
          cu.push(if st < text.length() { text.at(st).to_int() } else { 0 })
          if has_cjk_flags {
            cjk_flags.push(out_cjk[i])
          }
        }
      } else {
        let gb = if m > 1 { Some(@text.graphemes(text)) } else { None }
        let boundary = FixedArray::make(text.length() + 1, m <= 1)
        match gb {
          Some(g) =>
            for b in g {
              boundary[b] = true
            }
          None => ()
        }
        let mut i = 0
        while i < m {
          let st = out[i * 4].to_int()
          let is_c = has_cjk_flags && out_cjk[i]
          // what joins it: the rest of its grapheme cluster, and the rest of a word in a joining script (which ends
          // where a line may break)
          let word = joining(text, st) && out[i * 4 + 3] != -1.0
          let mut j = i + 1
          while j < m {
            let sj = out[j * 4].to_int()
            if !boundary[sj] {
              j = j + 1
              continue
            }
            if !word {
              break
            }
            let b = match lb {
              Some(b) => b
              None => {
                let b = @text.line_breaks(text)
                lb = Some(b)
                b
              }
            }
            if b[sj] != 0 || out[j * 4 + 3] == -1.0 || !joining(text, sj) {
              break
            }
            j = j + 1
          }
          let k0 = out[i * 4 + 3].to_int()
          if j - i >= 2 {
            let end = out[(j - 1) * 4].to_int() + out[(j - 1) * 4 + 1].to_int()
            let mut a = 0.0
            let mut drawn = false
            for k in i..<j {
              a = a + out[k * 4 + 2]
              drawn = drawn || out[k * 4 + 3] != -1.0
            }
            starts.push(st)
            lens.push(end - st)
            adv.push(a)
            keys.push(
              if k0 == -2 {
                -2
              } else if drawn && !is_nl(text.at(st).to_int()) {
                key_for(text.unsafe_substring(start=st, end~), is_c)
              } else {
                k0
              },
            )
          } else {
            starts.push(st)
            lens.push(out[i * 4 + 1].to_int())
            adv.push(out[i * 4 + 2])
            keys.push(k0)
          }
          cu.push(if st < text.length() { text.at(st).to_int() } else { 0 })
          if has_cjk_flags {
            cjk_flags.push(is_c)
          }
          i = j
        }
      }
      // ligatures: a cluster the shaper drew as part of the one before it (-2 from the host) has that one's piece
      // drawn over it; the piece, the whole ligature, is the first's, the advance shared out evenly
      let mut c = 0
      while c < keys.length() {
        if keys[c] != -2 {
          c = c + 1
          continue
        }
        let u = c - 1
        let mut e = c
        while e < keys.length() && keys[e] == -2 {
          e = e + 1
        }
        if u < 0 || keys[u] < 0 {
          for k in c..<e {
            let is_c = has_cjk_flags && cjk_flags[k]
            keys[k] = key_for(text.unsafe_substring(start=starts[k], end=starts[k] + lens[k]), is_c)
          }
        } else {
          let end = starts[e - 1] + lens[e - 1]
          let is_c = has_cjk_flags && cjk_flags[u]
          keys[u] = key_for(text.unsafe_substring(start=starts[u], end~), is_c)
          let mut a = 0.0
          for k in u..<e {
            a = a + adv[k]
          }
          for k in u..<e {
            adv[k] = a / (e - u).to_double()
            if k > u {
              keys[k] = -1
            }
          }
        }
        c = e
      }
      let n = starts.length()
      if spacing != 0.0 {
        for k in 0..<n {
          if !is_nl(cu[k]) {
            adv[k] = adv[k] + spacing
          }
        }
      }
      // (line breaks kept where a joining word already computed them; else computed once on demand in Shaped::breaks)
      let brk = match lb {
        Some(b) => {
          let brk = Array::make(n, 0)
          for k in 1..<n {
            brk[k] = b[starts[k]]
          }
          brk
        }
        None => []
      }
      let bd = if simple { None } else { @text.bidi_mixed(text) }
      // L4: a bracket (or another mirrored character) reading right to left is drawn as its mirror image, ")" for
      // "(" (each cluster is drawn on its own, out of the line the shaper would have mirrored it in)
      match bd {
        Some(bd) => {
          for k in 0..<n {
            if lens[k] == 1 && bd.levels[starts[k]] % 2 == 1 && keys[k] >= 0 {
              let c = text.at(starts[k]).to_int()
              let m = @text.mirror(c)
              if m != c {
                let is_c = has_cjk_flags && cjk_flags[k]
                keys[k] = key_for(Int::unsafe_to_char(m).to_string(), is_c)
              }
            }
          }
        }
        None => ()
      }
      let s = {
        starts,
        lens,
        adv,
        keys,
        cu,
        brk,
        len: text.length(),
        bidi: bd,
        pad: spacing / 2.0,
        lay: None,
        lay_max: 0.0,
        lay_line: 0.0,
        lay_trim: false,
        lay_wrap: false,
        used: text_cache.frame,
      }
      shapes[text] = s
      text_cache.shaped = text_cache.shaped + 1
      // its glyphs not drawn yet: drawn ahead unless this frame draws them (glyphs_ahead)
      for k in keys {
        if k >= 0 && text_cache.fresh.length() < glyphs_ahead_most && !glyph_drawn_any_sub(k) {
          text_cache.fresh.push(k)
        }
      }
      s
    }
  }
}

///|
/// The code point at UTF-16 offset i.
fn cp_at(text : String, i : Int) -> Int {
  let c = text.at(i).to_int()
  if c >= 0xD800 && c < 0xDC00 && i + 1 < text.length() {
    let d = text.at(i + 1).to_int()
    if d >= 0xDC00 && d < 0xE000 {
      return 0x10000 + ((c - 0xD800) << 10) + (d - 0xDC00)
    }
  }
  c
}

///|
/// Whether the cluster at offset i is of a script whose letters take their shapes from the letters beside them
/// (cursive joining: Arabic, Syriac, N'Ko, Mongolian…; conjuncts and reordered vowel signs: the Indic scripts,
/// Myanmar, Khmer, Tibetan) or joins them (ZWJ, ZWNJ): a word of them is drawn whole. Arabic's digits and number
/// signs are not (they read left to right in a right-to-left line).
fn joining(text : String, i : Int) -> Bool {
  if i >= text.length() {
    return false
  }
  let c = cp_at(text, i)
  if c < 0x600 {
    return false
  }
  if c <= 0x8FF {
    // Arabic, Syriac, Thaana, N'Ko, Samaritan, Mandaic and the Arabic supplements, less their numbers
    !((c >= 0x600 && c <= 0x605) ||
    (c >= 0x660 && c <= 0x66C) ||
    (c >= 0x6F0 && c <= 0x6F9) ||
    c == 0x6DD ||
    (c >= 0x7C0 && c <= 0x7C9) ||
    c == 0x890 ||
    c == 0x891 ||
    c == 0x8E2)
  } else {
    (c >= 0x900 && c <= 0xDFF) ||
    (c >= 0xF00 && c <= 0x109F) ||
    (c >= 0x1780 && c <= 0x18AF) ||
    c == 0x200C ||
    c == 0x200D ||
    (c >= 0xA8E0 && c <= 0xA8FF) ||
    (c >= 0xA9E0 && c <= 0xA9FF) ||
    (c >= 0xAA60 && c <= 0xAA7F) ||
    (c >= 0xFB50 && c <= 0xFDFF) ||
    (c >= 0xFE70 && c <= 0xFEFE) ||
    (c >= 0x10D00 && c <= 0x10D3F) ||
    (c >= 0x11000 && c <= 0x111FF)
  }
}

///|
/// A line's clusters [a, e) (without the spaces it ends in) put in their visual order from x: their xs, and their
/// levels (UAX #9 with L1) into lv.
fn bidi_line(
  b : @text.Bidi,
  starts : Array[Int],
  lens : Array[Int],
  adv : Array[Double],
  xs : Array[Double],
  lv : Array[Int],
  a : Int,
  e : Int,
  x0 : Double,
) -> Unit {
  if e <= a {
    return
  }
  let base = starts[a]
  let ll = b.line_levels(base, starts[e - 1] + lens[e - 1])
  let levels = Array::makei(e - a, fn(k) { ll[starts[a + k] - base] })
  for k, l in levels {
    lv[a + k] = l
  }
  let order = @text.visual_order(levels[:])
  let mut x = x0
  for k in order {
    xs[a + k] = x
    x = x + adv[a + k]
  }
}

///|
/// The x of a caret before cluster c (its left edge, or right edge read right to left).
fn caret_before(xs : Array[Double], adv : Array[Double], lv : Array[Int], c : Int) -> Double {
  if c < lv.length() && lv[c] % 2 == 1 {
    xs[c] + adv[c]
  } else {
    xs[c]
  }
}

///|
/// The x of a caret after cluster c.
fn caret_after(xs : Array[Double], adv : Array[Double], lv : Array[Int], c : Int) -> Double {
  if c < lv.length() && lv[c] % 2 == 1 {
    xs[c]
  } else {
    xs[c] + adv[c]
  }
}

///|
/// The offset nearest x on a line of clusters [a, b) in visual order (some right to left).
fn bidi_offset_at(
  starts : Array[Int],
  lens : Array[Int],
  adv : Array[Double],
  xs : Array[Double],
  lv : Array[Int],
  cu : Array[Int],
  a : Int,
  b : Int,
  x : Double,
) -> Int {
  let mut left = -1
  let mut right = -1
  for c in a..<b {
    if is_nl(cu[c]) {
      continue
    }
    let rtl = lv[c] % 2 == 1
    if x >= xs[c] && x < xs[c] + adv[c] {
      let first_half = x < xs[c] + adv[c] / 2.0
      return if first_half != rtl { starts[c] } else { starts[c] + lens[c] }
    }
    if left < 0 || xs[c] < xs[left] {
      left = c
    }
    if right < 0 || xs[c] > xs[right] {
      right = c
    }
  }
  if left < 0 {
    return if a < starts.length() { starts[a] } else { 0 }
  }
  if x < xs[left] {
    if lv[left] % 2 == 1 {
      starts[left] + lens[left]
    } else {
      starts[left]
    }
  } else if lv[right] % 2 == 1 {
    starts[right]
  } else {
    starts[right] + lens[right]
  }
}

///|
/// The most glyphs a frame asks its host to draw ahead.
let glyphs_ahead_most : Int = 4096

///|
/// Once this many laid-out glyphs accumulate in `glyphs_laid` during a tree layout, flush them ahead immediately so
/// background raster threads can work in parallel with the remaining text layout.
let glyphs_ahead_batch : Int = 48

///|
/// Whether base glyph `k` has already been placed in the atlas at any horizontal subpixel phase (glyph_sub_at).
/// Used only for phase-less `shape` (`text_cache.fresh`) prewarming, never for exact-phase `laid_ahead` deduplication.
fn glyph_drawn_any_sub(k : Int) -> Bool {
  text_cache.glyphs.contains(k) ||
  text_cache.glyphs.contains(k | (1 << 26)) ||
  text_cache.glyphs.contains(k | (2 << 26)) ||
  text_cache.glyphs.contains(k | (3 << 26))
}

///|
/// Whether two horizontal origins `a` and `b` (points) are guaranteed to preserve every glyph's quarter-pixel phase at
/// scale `sc`. Uses zero tolerance (`a == b` or exact integer device-pixel delta `d == d.round()`): any non-zero
/// epsilon could straddle `glyph_qf`'s shifted 1/8 px boundary and skip a phase change.
fn ahead_origin_same(a : Double, b : Double, sc : Double) -> Bool {
  if a == b {
    return true
  }
  let d = (a - b) * sc
  d == d.round()
}

///|
/// The glyphs of words just laid out (layout_text, layout_rich) not drawn yet, each with the quarter-pixel phase it is
/// drawn at (glyph_sub_at) where what holds the words stands on a whole pixel, its pen `x(c)` points into its line: for
/// the host to draw first at that phase (glyphs_ahead). Most words stand so (a list's rows, a page's columns); one that
/// does not (centred, or at a padding of no whole pixels) has its glyphs at another phase, drawn on the frame's thread
/// as before. Returns `true` when every cluster was processed without hitting the `glyphs_ahead_most` truncation cap.
fn laid_ahead(keys : Array[Int], x : (Int) -> Double) -> Bool {
  let sc = g().scale
  let z = words_zoom.val
  let ox = measuring_origin_x.val
  let mut complete = true
  for c in 0..<keys.length() {
    if glyphs_laid.length() >= glyphs_ahead_most {
      complete = false
      break
    }
    let k = keys[c]
    if k >= 0 {
      let pk = glyph_sub_at(k, ox + x(c), sc, z)
      if !text_cache.glyphs.contains(pk) {
        glyphs_laid.push(pk)
      }
    }
  }
  if glyphs_laid.length() >= glyphs_ahead_batch {
    glyphs_laid_flush()
  }
  complete
}

///|
/// The glyphs of what was laid out since they were last handed to the host, each at its phase (laid_ahead).
// kept across runs: emptied as each frame hands them on (glyphs_ahead) and with the glyphs (glyphs_forget)
let glyphs_laid : Array[Int] = []

///|
/// Exact phased keys already flushed mid-layout by `glyphs_laid_flush` since the last `glyphs_ahead`.
// kept across runs: emptied as each frame hands them on (glyphs_ahead) and with the glyphs (glyphs_forget)
let glyphs_ahead_laid_keys : Map[Int, Bool] = Map([])

///|
/// Base glyph keys already flushed at an exact layout phase by `glyphs_laid_flush` since the last `glyphs_ahead`,
/// so `glyphs_ahead` does not re-dispatch them at phase 0 from `text_cache.fresh`.
// kept across runs: emptied as each frame hands them on (glyphs_ahead) and with the glyphs (glyphs_forget)
let glyphs_ahead_laid_bases : Map[Int, Bool] = Map([])

///|
/// Flush only `glyphs_laid` to the host mid-layout without touching `text_cache.fresh`, so glyphs shaped for later
/// nodes are not prematurely dispatched at phase 0 before their own layout computes their exact subpixel phases.
fn glyphs_laid_flush() -> Unit {
  let laid = glyphs_laid
  if laid.is_empty() {
    return
  }
  let keys = FixedArray::make(laid.length(), 0)
  let mut n = 0
  for k in laid {
    let base = k & 0x03FFFFFF
    if !glyphs_ahead_laid_keys.contains(k) && !text_cache.glyphs.contains(k) {
      glyphs_ahead_laid_keys[k] = true
      glyphs_ahead_laid_bases[base] = true
      keys[n] = k
      n = n + 1
    }
  }
  laid.clear()
  if n > 0 {
    h_glyphs_ahead(keys, n)
  }
}

///|
/// The glyphs of what the frame shaped and laid out and did not draw yet (a page pushed, still off the screen; the lines
/// below what a list shows; what the frame is about to paint), handed to the host to draw them ahead, off the frames'
/// thread: as the window's tree is laid out, as the painting begins and as it is over (app.mbt), so what was laid out is
/// drawn on the host's other cores while the frame goes on, and the rest is there when it comes into view, a frame or
/// more later. Each at the phase its line put it at (glyphs_laid: bits 26..27 of its key, glyph_sub_at), the host
/// drawing that phase first; one shaped and not laid out at phase 0. What is drawn is the same; only when and where the
/// work is done changes (@hostapi.glyphs_ahead).
fn glyphs_ahead() -> Unit {
  let fresh = text_cache.fresh
  let laid = glyphs_laid
  if fresh.is_empty() && laid.is_empty() {
    if !glyphs_ahead_laid_keys.is_empty() {
      glyphs_ahead_laid_keys.clear()
    }
    if !glyphs_ahead_laid_bases.is_empty() {
      glyphs_ahead_laid_bases.clear()
    }
    return
  }
  let keys = FixedArray::make(fresh.length() + laid.length(), 0)
  let mut n = 0
  // (each key once; a glyph laid out at a phase not asked again at phase 0 for having been shaped)
  let asked : Map[Int, Bool] = Map([])
  for k in laid {
    let base = k & 0x03FFFFFF
    if !glyphs_ahead_laid_keys.contains(k) && !asked.contains(k) && !text_cache.glyphs.contains(k) {
      asked[k] = true
      asked[base | (1 << 30)] = true
      keys[n] = k
      n = n + 1
    }
  }
  for k in fresh {
    if !asked.contains(k | (1 << 30)) && !glyphs_ahead_laid_bases.contains(k) && !glyph_drawn_any_sub(k) {
      asked[k | (1 << 30)] = true
      keys[n] = k
      n = n + 1
    }
  }
  fresh.clear()
  laid.clear()
  if !glyphs_ahead_laid_keys.is_empty() {
    glyphs_ahead_laid_keys.clear()
  }
  if !glyphs_ahead_laid_bases.is_empty() {
    glyphs_ahead_laid_bases.clear()
  }
  if n > 0 {
    h_glyphs_ahead(keys, n)
  }
}

///|
/// A glyph with nothing to draw (nothing in it, too large for the atlas, or no room in it for now).
// kept across runs: a value (no field of it changes)
let no_glyph : Glyph = {
  u: 0.0,
  v: 0.0,
  gw: 0.0,
  gh: 0.0,
  ox: 0.0,
  oy: 0.0,
  color: false,
  plot: -1,
  in_colour: false,
  sc: 0.0,
}

///|
/// The glyphs in the atlas by their places ("u v", as an instance has them): their keys.
fn glyph_keys() -> Map[String, Int] {
  let at : Map[String, Int] = Map([])
  text_cache.glyphs.each(fn(key, g) { if g.plot >= 0 { at["\{g.u} \{g.v}"] = key & 0x03FFFFFF } })
  at
}

///|
/// The glyphs in the atlas by their places, as `glyph_keys`: their whole keys, the phase (bits 26..27) kept.
fn glyph_full_keys() -> Map[String, Int] {
  let at : Map[String, Int] = Map([])
  text_cache.glyphs.each(fn(key, g) { if g.plot >= 0 { at["\{g.u} \{g.v}"] = key } })
  at
}

///|
/// The horizontal origin (in points) of the View node being built in `view_made` (`ux`, which `view_blit`
/// rounds from as `lx`), 0 outside `view_made`.
// kept across runs: set and put back around view_made
let glyph_origin_x : Ref[Double] = Ref(0.0)

///|
/// The estimated horizontal origin (in points) of the View node being measured during tree layout
/// (`Tree::measuring_origin_x`), 0 outside tree measure callbacks.
// kept across runs: set and put back around measure callbacks
let measuring_origin_x : Ref[Double] = Ref(0.0)

///|
/// Whether `measuring_origin_x` holds a real estimated origin (`true` inside `View::words` measure callbacks and
/// `words_ahead`; `false` for unpositioned measurements or outside measure).
// kept across runs: set and put back around measure callbacks and reset in Tester::new
let measuring_origin_known : Ref[Bool] = Ref(false)

///|
/// How far (device pixels) a glyph drawn at horizontal subpixel phase `sub` (bits 26..27 of its key: glyph_sub_at) is
/// drawn right of the whole pixel column its quad is put on: 0, +1/4, -1/2, -1/4. Every host draws a phase so
/// (win_text.cpp, apple_text.m, MBText.java, linux_text.c, the web's host.js: their `sub_dx`).
// (held by its tests: what each phase is drawn at, the hosts' own number)
#warnings("-unused_value")
fn glyph_sub_dx(sub : Int) -> Double {
  match sub {
    1 => 0.25
    2 => -0.5
    3 => -0.25
    _ => 0.0
  }
}

///|
/// The quarter-pixel step nearest a glyph's pen at `tx` device pixels: what its column and its phase are both of
/// (glyph_col_of, glyph_sub_of), so `col + glyph_sub_dx(sub)` is `qf / 4` wherever `tx` is and a pen moving right only
/// ever moves its glyph right, a quarter of a pixel at a time, within an eighth of a pixel of where it is laid out. A
/// half pixel (`k + 1/2`, where a rounding of the column alone went one way for one glyph and the other for the next) is
/// a phase like the others (2, on the column to its right), an eighth of a pixel from where its step changes; and a pen
/// moved by whole pixels keeps its phase. (Two numbers of one step, not a pair: what composes every glyph each frame
/// makes no allocation of it.)
fn glyph_qf(tx : Double) -> Double {
  // (1e-9 breaks exact N + 0.5 ties upward so shifting a glyph by whole pixels k / sc at non-dyadic scales like 3.25
  // never flips its phase across floor() from 1-ULP float rounding: ride_kept_for and view_blocks rely on whole-pixel
  // shifts keeping every glyph's phase)
  (tx * 4.0 + 0.5 + 1.0e-9).floor()
}

///|
/// The whole device pixel column a glyph of quarter-pixel step `qf` (glyph_qf) is put on.
fn glyph_col_of(qf : Double) -> Double {
  ((qf + 2.0) * 0.25).floor()
}

///|
/// The quarter-pixel phase a glyph of quarter-pixel step `qf` (glyph_qf) is drawn at on its column (glyph_sub_dx).
fn glyph_sub_of(qf : Double) -> Int {
  match (qf - glyph_col_of(qf) * 4.0).to_int() {
    1 => 1
    -2 => 2
    -1 => 3
    _ => 0
  }
}

///|
/// A glyph's pen at `tx` device pixels: its column and its phase (glyph_qf).
// (held by its tests: the two together, as a test reads them)
#warnings("-unused_value")
fn glyph_col_sub(tx : Double) -> (Double, Int) {
  let qf = glyph_qf(tx)
  (glyph_col_of(qf), glyph_sub_of(qf))
}

///|
/// Glyph `key` with its horizontal quarter-pixel phase (bits 26..27: glyph_sub_of's) for a cluster laid out at
/// `laid_x` points (`sc` pixels a point, `z` zoom), so its quad stays on the whole pixel column `on_glyph_col` puts it
/// on while the host draws its ink within 1/8 px of `laid_x * sc`: on every host. Unchanged when zoomed (a glyph drawn
/// bigger and shown smaller: its quad on the pixels, on_glyph_col).
fn glyph_sub_at(key : Int, laid_x : Double, sc : Double, z : Double) -> Int {
  if key < 0 || z != 1.0 || sc <= 0.0 {
    return key
  }
  (key & 0x03FFFFFF) | (glyph_sub_of(glyph_qf(laid_x * sc)) << 26)
}

///|
fn glyph_sub(key : Int, x : Double, sc : Double, z : Double) -> Int {
  glyph_sub_at(key, glyph_origin_x.val + x - glyphs_carried[0], sc, z)
}

///|
/// The host's atlas a glyph goes in (atlas_for), without how far across it is said: what marks a glyph drawn asks it for
/// each glyph drawn, and a pair is an allocation each.
fn atlas_of(colour : Bool) -> @hostapi.Atlas {
  if colour {
    match text_cache.colour_atlas {
      Some(a) if a.sized() => return a
      _ => ()
    }
  }
  match text_cache.atlas {
    Some(a) if !colour => a
    _ => atlas_for(colour).0
  }
}

///|
/// The host's atlas a glyph goes in as its glyphs are placed in it: colour glyphs' own (`colour`, where the host keeps
/// one), else the words'; how far across past its place in it the glyph is said (@hostapi.colour_atlas_u).
fn atlas_for(colour : Bool) -> (@hostapi.Atlas, Int) {
  if colour {
    let a = match text_cache.colour_atlas {
      Some(a) => a
      None => {
        let a = @hostapi.Atlas::new(h_atlas_size(true))
        a.before_full(glyphs_held_drawn)
        text_cache.colour_atlas = Some(a)
        a
      }
    }
    if a.sized() {
      return (a, @hostapi.colour_atlas_u)
    }
  }
  match text_cache.atlas {
    Some(a) => (a, 0)
    None => {
      let a = @hostapi.Atlas::new(h_atlas_size(false))
      a.before_full(glyphs_held_drawn)
      text_cache.atlas = Some(a)
      (a, 0)
    }
  }
}

///|
/// Whether glyph `g` is in the atlas at other than `sc` pixels a point (a host's generation moves on as its scale
/// changes; a shot's scale over its zoom comes back to the window's only within rounding).
fn glyph_other_scale(g : Glyph, sc : Double) -> Bool {
  g.plot >= 0 && (g.sc - sc).abs() > 0.001
}

///|
/// Whether a glyph found at another scale has been logged: once a run, what brought it being what is looked for.
// kept across runs: only goes to true, and only says whether a line was logged
let glyph_scale_told : Ref[Bool] = Ref(false)

///|
/// Milliseconds spent on foreground `glyph()` cache misses during `frame_paint` (covering taking prewarmed background
/// results, synchronous rasterization, atlas placement, and upload; excluding direct `h_glyph` calls such as halo or
/// punctuation probes). Reset at paint start and in `journal_reset`, flushed to journal notes as `"paint glyphs"` before
/// paint ends.
// kept across runs: reset in `frame_paint` and `journal_reset`
let paint_glyph_ms : Ref[Double] = Ref(0.0)

///|
fn paint_glyph_reset() -> Unit {
  paint_glyph_ms.val = 0.0
}

///|
fn paint_glyph_flush() -> Unit {
  let ms = paint_glyph_ms.val
  if ms > 0.0 {
    paint_glyph_ms.val = 0.0
    @hostapi.work_took("paint glyphs", ms)
  }
}

///|
fn glyph_miss(key : Int, sc : Double) -> Glyph {
  let o = text_cache.gbuf
  h_glyph(key, o)
  let color = o[6] > 0.5
  let (a, across) = atlas_for(color)
  let w = (o[2] * sc).round().to_int()
  let h = (o[3] * sc).round().to_int()
  if !a.holds(w, h) {
    text_cache.glyphs[key] = no_glyph
    return no_glyph
  }
  match a.place(key, w, h, fn(k) {
    text_cache.glyphs.remove(k)
    glyphs_lost.val = true
    glyph_moves.val += 1
  }) {
    Some((plot, x, y)) => {
      h_glyph_put(key, x + across, y)
      let g = {
        u: (x + across).to_double(),
        v: y.to_double(),
        gw: o[2],
        gh: o[3],
        ox: o[4],
        oy: o[5],
        color,
        plot,
        in_colour: across > 0,
        sc,
      }
      text_cache.glyphs[key] = g
      glyph_kept(key, g)
      g
    }
    // (no room while this frame is drawn: what is made to be kept made again once there is, glyphs_still)
    None => {
      text_cache.short = true
      glyphs_lost.val = true
      glyph_moves.val += 1
      glyph_kept(key, { ..no_glyph, u: -1.0, v: -1.0 })
      no_glyph
    }
  }
}

///|
/// Glyph `key` as it is drawn at `sc` pixels a point: where it is in the atlas, drawn from in this frame. One not in it
/// is drawn by the host and put there (its pixels its size at `sc`), in place of the glyphs drawn from longest ago where
/// it is full (@hostapi.Atlas); with no room while this frame is drawn, it is not drawn in it (none_short, for the
/// next). One put there at another scale is drawn and put again: its cell at this one would take in what lies beside it.
fn glyph(key : Int, sc : Double) -> Glyph {
  match text_cache.glyphs.get(key) {
    Some(g) if glyph_other_scale(g, sc) => {
      if !glyph_scale_told.val {
        glyph_scale_told.val = true
        h_log("GLYPHSCALE placed at \{g.sc}, drawn at \{sc}, generation \{h_atlas_generation()}")
      }
      text_cache.glyphs.remove(key)
      glyph_moves.val += 1
      glyph(key, sc)
    }
    Some(g) => {
      if g.plot >= 0 {
        atlas_of(g.in_colour).drawn(g.plot)
      }
      glyph_kept(key, g)
      g
    }
    None => {
      let t0 = if paint_phase.val == 1 { @hostapi.work_began() } else { -1.0 }
      let res = glyph_miss(key, sc)
      if t0 >= 0.0 {
        let t1 = @hostapi.work_began()
        if t1 > t0 {
          paint_glyph_ms.val += t1 - t0
        }
      }
      res
    }
  }
}

///|
/// Line terminators (Line_Break BK, CR, LF, NL).
fn is_nl(c : Int) -> Bool {
  c == 10 || c == 13 || c == 11 || c == 12 || c == 0x85 || c == 0x2028 || c == 0x2029
}

///|
/// Whether there is a line break in `s`.
fn has_nl(s : String) -> Bool {
  s.iter().any(fn(ch) { is_nl(ch.to_int()) })
}

///|
/// Words that do not wrap put on one line, as CSS's white-space: nowrap puts them: each line break in them, with the
/// spaces round it, one space; none before the first words or after the last. `texts` are a paragraph's runs in order
/// (a break may run from one into the next), each its own again; None where there is no line break in them.
fn one_line(texts : Array[String]) -> Array[String]? {
  guard texts.iter().any(has_nl) else { None }
  let chars : Array[(Char, Int)] = []
  for k, s in texts {
    for ch in s {
      chars.push((ch, k))
    }
  }
  let blank = fn(ch : Char) { ch == ' ' || ch == '\t' || is_nl(ch.to_int()) }
  let out = texts.map(fn(_) { StringBuilder() })
  let n = chars.length()
  let mut said = false
  let mut i = 0
  while i < n {
    let (ch, k) = chars[i]
    if !blank(ch) {
      out[k].write_char(ch)
      said = true
      i = i + 1
      continue
    }
    // blanks: with a line break among them, one space where words are either side; else as they are
    let mut j = i
    let mut broken = false
    while j < n && blank(chars[j].0) {
      broken = broken || is_nl(chars[j].0.to_int())
      j = j + 1
    }
    if !broken {
      for m in i..<j {
        out[chars[m].1].write_char(chars[m].0)
      }
    } else if said && j < n {
      out[k].write_char(' ')
    }
    i = j
  }
  Some(out.map(fn(sb) { sb.to_string() }))
}

///|
/// Whether cluster i ends a line by itself: a line terminator that is not CR immediately before LF (when the host
/// emits CR and LF as two clusters).
fn Shaped::hard_end(self : Shaped, i : Int) -> Bool {
  is_nl(self.cu[i]) && !(self.cu[i] == 13 && i + 1 < self.starts.length() && self.cu[i + 1] == 10)
}

///|
fn layout_text(
  text : String,
  size : Double,
  weight : Int,
  max_w : Double,
  wrap : Bool,
  indent? : Double = 0.0,
  line? : Double = 0.0,
  trim? : Bool = false,
  spacing? : Double = 0.0,
  style? : Int = 0,
  keep_tabular? : Bool = false,
  cjk_override? : @view.CjkOverride? = None,
) -> TextLayout {
  let s = shape(text, size, weight, style~, spacing~, keep_tabular~, cjk_override~)
  // greedy wrapping gives the same lines in any width from the widest
  // line up to the one they were made in (as Node::text_layout)
  if indent == 0.0 {
    match s.lay {
      Some(kept) if s.lay_line == line &&
        s.lay_trim == trim &&
        s.lay_wrap == wrap &&
        (!wrap || (kept.lay.w <= max_w + 0.01 && max_w <= s.lay_max)) => {
        if measuring_origin_known.val && paint_phase.val != 1 {
          let zoomed = words_zoom.val != 1.0
          if !kept.ahead_known ||
            kept.ahead_moves != glyph_moves.val ||
            kept.ahead_zoomed != zoomed ||
            (!zoomed && !ahead_origin_same(measuring_origin_x.val, kept.ahead_ox, g().scale)) {
            let tl = kept.lay
            if laid_ahead(s.keys, fn(c) { tl.xs[c] + s.pad }) {
              kept.ahead_known = true
              kept.ahead_ox = measuring_origin_x.val
              kept.ahead_zoomed = zoomed
              kept.ahead_moves = glyph_moves.val
            }
          }
        }
        return kept.lay
      }
      _ => ()
    }
  }
  let brk = if wrap { s.breaks(text) } else { [] }
  let n = s.starts.length()
  let xs = Array::make(n, 0.0)
  let line_of = Array::make(n, 0)
  let line_start = []
  let line_end = []
  let line_w = []
  let mut ls = 0
  let mut i = 0
  // the first line may start indented
  let mut x = indent
  let mut last_break = -1
  let mut w_max = 0.0
  fn finish(start : Int, end : Int) {
    // width without trailing spaces, but for the words whole on one line: their spaces at the end are theirs, as
    // Android measures a line that needs no breaking (BoringLayout: "当前延迟 " then its figure, a space between)
    let whole = n > 0 && start == 0 && end == n && !is_nl(s.cu[n - 1])
    let mut e = end
    while e > start && ((s.cu[e - 1] == 32 && !whole) || is_nl(s.cu[e - 1])) {
      e = e - 1
    }
    let lw = if e > start { xs[e - 1] + s.adv[e - 1] } else { 0.0 }
    line_start.push(start)
    line_end.push(end)
    line_w.push(lw)
    if lw > w_max {
      w_max = lw
    }
  }

  while i < n {
    let c = s.cu[i]
    if s.hard_end(i) {
      xs[i] = x
      line_of[i] = line_start.length()
      finish(ls, i + 1)
      ls = i + 1
      i = i + 1
      x = 0.0
      last_break = -1
      continue
    }
    if wrap && i > ls && brk[i] != 0 {
      last_break = i
    }
    let a = s.adv[i]
    if wrap && x + a > max_w + 0.01 && i > ls && c != 32 {
      let brk = if last_break > ls { last_break } else { i }
      finish(ls, brk)
      ls = brk
      i = brk
      x = 0.0
      last_break = -1
      continue
    }
    xs[i] = x
    line_of[i] = line_start.length()
    x = x + a
    i = i + 1
  }
  if ls < n || line_start.length() == 0 || (n > 0 && s.hard_end(n - 1)) {
    finish(ls, n)
  }
  let lines = line_start.length()
  // a line as high as asked, the glyphs in its middle; measured by the first line's fonts, as Android measures them
  // (Chinese in it: the CJK font's, taller), the lines after it set in the same place; when a CJK companion is active,
  // scan all clusters 0..<n so enlarged CJK on later lines is never clipped.
  let (_, _, own_h) = font_metrics(size, weight)
  let has_cjk_comp = effective_cjk(style, cjk_override) is Some(_)
  let mut cjk = false
  if has_cjk_comp {
    for c in 0..<n {
      if is_cjk(s.cu[c]) {
        cjk = true
        break
      }
    }
  } else if lines > 0 {
    for c in line_start[0]..<line_end[0] {
      if is_cjk(s.cu[c]) {
        cjk = true
        break
      }
    }
  }
  let (asc, desc) = if has_cjk_comp {
    line_metrics(size, weight, cjk, style~, cjk_override~)
  } else {
    line_metrics(size, weight, cjk)
  }
  let cjk_enlarged = match effective_cjk(style, cjk_override) {
    Some((_, sc, _)) => sc > 1.0
    None => false
  }
  let (line_h, ascent, extra) = set_line(
    if line > 0.0 {
      line
    } else {
      own_h
    },
    asc,
    desc,
    g().scale,
    whole_pixel_lines(size, weight),
    trim~,
    cjk_fit=cjk && cjk_enlarged,
  )
  // right to left: each line's clusters in their visual order
  let lv = match s.bidi {
    Some(b) => {
      let lv = Array::make(n, 0)
      for l in 0..<lines {
        let a = line_start[l]
        let mut e = line_end[l]
        while e > a && (s.cu[e - 1] == 32 || is_nl(s.cu[e - 1])) {
          e = e - 1
        }
        bidi_line(b, s.starts, s.lens, s.adv, xs, lv, a, e, if l == 0 { indent } else { 0.0 })
        // the spaces it ends in stay after it, read left to right
        for c in e..<line_end[l] {
          lv[c] = 0
        }
      }
      lv
    }
    None => []
  }
  let tl = {
    text,
    shaped: s,
    line_start,
    line_end,
    line_w,
    xs,
    line_of,
    w: w_max,
    h: lines.to_double() * line_h + extra,
    ascent,
    line_h,
    lv,
  }
  // (its glyphs not drawn yet, at the phases its lines put them at: drawn ahead so, glyphs_ahead)
  let complete = laid_ahead(s.keys, fn(c) { xs[c] + s.pad })
  if indent == 0.0 {
    s.lay = Some({
      lay: tl,
      ahead_known: complete && measuring_origin_known.val && paint_phase.val != 1,
      ahead_ox: measuring_origin_x.val,
      ahead_zoomed: words_zoom.val != 1.0,
      ahead_moves: glyph_moves.val,
    })
    s.lay_max = max_w
    s.lay_line = line
    s.lay_trim = trim
    s.lay_wrap = wrap
  }
  tl
}

///|
/// Caret position (x, line) for a UTF-16 offset.
fn TextLayout::caret(self : TextLayout, off : Int) -> (Double, Int) {
  let s = self.shaped
  let n = s.starts.length()
  if n == 0 {
    return (0.0, 0)
  }
  let mut c = 0
  while c < n && s.starts[c] < off {
    c = c + 1
  }
  if c >= n {
    let last = n - 1
    if s.hard_end(last) {
      return (0.0, self.line_start.length() - 1)
    }
    (caret_after(self.xs, s.adv, self.lv, last), self.line_of[last])
  } else {
    (caret_before(self.xs, s.adv, self.lv, c), self.line_of[c])
  }
}

///|
/// The UTF-16 offset nearest to a point inside the text.
fn TextLayout::offset_at(self : TextLayout, x : Double, y : Double) -> Int {
  let s = self.shaped
  let lines = self.line_start.length()
  if lines == 0 || s.starts.length() == 0 {
    return 0
  }
  let line = imin(imax((y / self.line_h).to_int(), 0), lines - 1)
  let a = self.line_start[line]
  let b = self.line_end[line]
  if self.lv.length() > 0 {
    return bidi_offset_at(s.starts, s.lens, s.adv, self.xs, self.lv, s.cu, a, b, x)
  }
  for c in a..<b {
    if is_nl(s.cu[c]) {
      return s.starts[c]
    }
    if x < self.xs[c] + s.adv[c] / 2.0 {
      return s.starts[c]
    }
  }
  if b >= s.starts.length() {
    s.len
  } else {
    s.starts[b]
  }
}

///|
/// The line starting at offset `off` that the one before wraps into (no line break between them), or -1: where an
/// offset is the end of one line and the start of the next.
fn TextLayout::wrapped_into(self : TextLayout, off : Int) -> Int {
  let s = self.shaped
  for l in 1..<self.line_start.length() {
    let c = self.line_start[l]
    if c < s.starts.length() && s.starts[c] == off {
      return if s.hard_end(c - 1) { -1 } else { l }
    }
  }
  -1
}

///|
/// The caret's place (x, line) at offset `off`, as TextLayout::caret; with `up`, where a line wraps into the next
/// there, at the end of the line before instead of the next one's start (where a move to that line's end, or the
/// pointer past it, put the caret).
fn TextLayout::caret_side(self : TextLayout, off : Int, up : Bool) -> (Double, Int) {
  let l = if up { self.wrapped_into(off) } else { -1 }
  if l > 0 {
    let s = self.shaped
    return (caret_after(self.xs, s.adv, self.lv, self.line_end[l - 1] - 1), l - 1)
  }
  self.caret(off)
}

///|
/// The offset nearest to `x` on line `line`, and whether a caret there shows on that line where the line wraps into
/// the next at it (caret_side's `up`): past the line's end, where its words go on on the next.
fn TextLayout::offset_on(self : TextLayout, x : Double, line : Int) -> (Int, Bool) {
  let off = self.offset_at(x, (line.to_double() + 0.5) * self.line_h)
  (off, line + 1 < self.line_start.length() && self.wrapped_into(off) == line + 1)
}

///|
/// The start (`d` -1) or the end (1) of the line the caret at `off` shows on (`up`: caret_side's), and whether the
/// caret there shows on it as caret_side's `up` says: its end before its line break, or where it wraps into the next,
/// the next one's start shown at its own end.
fn TextLayout::line_end_at(self : TextLayout, off : Int, up : Bool, d : Int) -> (Int, Bool) {
  let (_, line) = self.caret_side(off, up)
  let (a, b) = self.line_range(line)
  let s = self.shaped
  let e = self.line_end[line]
  if d < 0 {
    (a, false)
  } else if line + 1 >= self.line_start.length() {
    (b, false)
  } else if e > 0 && s.hard_end(e - 1) {
    (s.starts[e - 1], false)
  } else {
    (b, true)
  }
}

///|
/// The start and end offsets of a line.
fn TextLayout::line_range(self : TextLayout, line : Int) -> (Int, Int) {
  let s = self.shaped
  let a = self.line_start[line]
  let b = self.line_end[line]
  let start = if a < s.starts.length() { s.starts[a] } else { s.len }
  let end = if b < s.starts.length() { s.starts[b] } else { s.len }
  (start, end)
}

///|
/// The width `text` advances on one line in that font (style: @hostapi.style_italic, style_mono), as mbui lays it out:
/// for comparing with the platform's own (src/textdiff).
pub fn text_advance(
  text : String,
  size? : Double = 15.0,
  weight? : Int = 400,
  style? : Int = 0,
) -> Double {
  let s = shape(text, size, weight, style~)
  let mut w = 0.0
  for a in s.adv {
    w = w + a
  }
  w
}
