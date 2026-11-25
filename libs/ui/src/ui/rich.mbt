// Rich text: one paragraph of runs, each in a style of its own (weight,
// slant, the code face, size, colour, a ground, strikethrough, a link),
// wrapped as one text: the runs are shaped apart (each in its own font, by
// the host) and their clusters laid end to end, lines broken where UAX #14
// allows in the whole paragraph's text, so a line breaks between runs as
// within one. A line is as high as the tallest run on it needs; runs share
// its baseline.
//
// The layout answers what selection asks (offset_at, caret, rects over a
// range of the paragraph's text: words.mbt), and links are found the same way: each
// link's pieces of lines are hit targets with an id of their own, pressed
// and clicked as any widget.

///|
/// A paragraph's runs (mbui/text's: the same data a node of the window's tree holds), here by their names.
pub using @text {
  type Run,
  type Ground,
  type InlineDrawing,
  span,
  plain,
  bold,
  italic,
  code,
  strike,
  link,
}

///|
/// A paragraph as its node keeps it: its runs and its own look (each of it what it is laid out by: layout_rich keeps a
/// layout for a paragraph the same in all of it).
#derive(Eq)
priv struct Rich {
  runs : Array[Run]
  size : Double
  weight : Int
  color : Int64
  line : Double
  // a font taller than its line not padded beyond its own reach (set_line `trim`)
  trim : Bool
  wrap : Bool
  link_color : Int64
  pressed_bg : Int64
  code_color : Int64
  code_bg : Int64
  code_scale : Double
  // letter spacing, in pixels, in every run (Ctx::text's)
  spacing : Double
  // the id its links' ids come from
  base : Int
  // its words picked with the pointer (Ctx::selectable: a desktop's page)
  select : Bool
  // wrapped words cut after that many lines, ending in an ellipsis (0: all of them)
  max_lines : Int
  // what every run's style has besides its own (faces.mbt faces_style: the face named, what people wrote; digits all one
  // width, @hostapi.style_tabular)
  faces : Int
  // the faces as they were given when it was built (faces.mbt words_shaped_in): laid out again once they change
  shaped_in : Int
  // optional local CJK companion overrides for preview cards (zero global cache invalidation)
  cjk_override : @view.CjkOverride?
  code_cjk_override : @view.CjkOverride?
}

///|
/// The id of the link run `k` is in, in a paragraph (`runs`): one for the runs one after another that lead to the
/// same place (a reference's `@` and its title, a link's words in two weights, a word found in it), pressed, held and
/// pointed at as one link.
fn link_id(base : Int, runs : Array[Run], k : Int) -> Int {
  let mut h = k
  while h > 0 && runs[h - 1].link == runs[k].link {
    h = h - 1
  }
  mix(base, h + 1)
}

///|
/// The first of the runs that lead where run `k` does one after another (its link's, as link_id has it).
fn link_first(runs : Array[Run], k : Int) -> Int {
  let mut h = k
  while h > 0 && runs[h - 1].link == runs[k].link {
    h = h - 1
  }
  h
}

///|
/// How far the line of a paragraph laid out in `lay` at `y` (in its terms; the last where under all of them) is moved
/// across where each line stands in the middle of `center_in` (rich_line_x's; none where not given).
fn rich_shift_at(lay : RichLayout, y : Double, center_in : Double) -> Double {
  if center_in < 0.0 || lay.line_y.length() == 0 {
    return 0.0
  }
  let mut l = lay.line_y.length() - 1
  for k in 0..<lay.line_y.length() {
    if y < lay.line_y[k] + lay.line_h[k] {
      l = k
      break
    }
  }
  rich_line_x(lay, l, 0.0, center_in)
}

///|
/// The pieces of line a paragraph's links laid out in `lay` are drawn on, at (ox, oy) (each line in the middle of
/// `center_in` where given): each by its link's first run (link_first) and where it is (x0, y0, x1, y1), as
/// paint_run_grounds tells them: what a press on one of them presses, its words' own place on their line, not the
/// line's room past them.
fn rich_link_pieces(
  r : Rich,
  lay : RichLayout,
  ox0 : Double,
  oy : Double,
  center_in? : Double = -1.0,
) -> Array[(Int, Double, Double, Double, Double)] {
  let out = []
  for k, run in r.runs {
    if run.link == "" {
      continue
    }
    let first = link_first(r.runs, k)
    for p in lay.pieces(k) {
      let (l, c0, c1) = p
      let ox = rich_line_x(lay, l, ox0, center_in)
      let top = oy + lay.line_y[l]
      let (sx0, sx1) = lay.span_x(c0, c1)
      out.push((first, ox + sx0, top, ox + sx1, top + lay.line_h[l]))
    }
  }
  out
}

///|
/// Whether run `k` starts a link (the first of the runs that lead to the same place one after another: link_id).
fn link_starts(runs : Array[Run], k : Int) -> Bool {
  runs[k].link != "" && (k == 0 || runs[k - 1].link != runs[k].link)
}

///|
/// A paragraph laid out: its clusters (from every run, in order), its
/// lines, and each run's metrics.
pub struct RichLayout {
  text : String
  /// where each run starts in the text (UTF-16)
  run_start : Array[Int]
  /// each run's clusters: run k has clusters run_c0[k] until run_c1[k]
  run_c0 : Array[Int]
  run_c1 : Array[Int]
  run_size : Array[Double]
  /// the run's font's ascent and descent (its ink's room)
  run_a : Array[Double]
  run_d : Array[Double]
  /// and with its share of the line's leading
  run_lasc : Array[Double]
  run_ldesc : Array[Double]
  run_extra : Array[Double]
  /// Inline drawings scaled once when laid out, never rescaled for each painted frame.
  drawings : Array[InlineDrawing?]
  starts : Array[Int]
  lens : Array[Int]
  adv : Array[Double]
  /// where the glyph is in its advance (a code run's first: after its room)
  pre : Array[Double]
  keys : Array[Int]
  cu : Array[Int]
  brk : Array[Int]
  run_of : Array[Int]
  xs : Array[Double]
  line_of : Array[Int]
  line_start : Array[Int]
  line_end : Array[Int]
  line_w : Array[Double]
  line_y : Array[Double]
  line_h : Array[Double]
  /// the baseline, down from the line's top
  line_base : Array[Double]
  /// each cluster's bidi level on its line (empty: all left to right)
  lv : Array[Int]
  len : Int
  w : Double
  h : Double
}

///|
fn RichLayout::hard_end(self : RichLayout, i : Int) -> Bool {
  is_nl(self.cu[i]) && !(self.cu[i] == 13 && i + 1 < self.starts.length() && self.cu[i + 1] == 10)
}

///|
fn run_style(r : Run) -> Int {
  (if r.italic { @hostapi.style_italic } else { 0 }) |
  (if r.code || r.mono { @hostapi.style_mono } else { 0 }) |
  (if r.serif && !r.code && !r.mono { @hostapi.style_serif } else { 0 })
}

///|
/// A run may name its own face instead of the paragraph's, including the app's face when the paragraph is in the
/// face for what people wrote. Other paragraph features, such as tabular digits, stay in effect.
fn Rich::run_style(self : Rich, run : Run) -> Int {
  let faces = match run.face {
    None => self.faces
    Some(face) =>
      (self.faces & (@hostapi.style_face_bits | @hostapi.style_words).lnot()) | faces_style(false, face)
  }
  run_style(run) | faces
}

///|
/// Local CJK companion override for `run` with resolved `style`: code/mono runs take `code_cjk_override`,
/// prose runs take `cjk_override`, preventing prose preview hovers from leaking into inline code.
fn Rich::run_cjk_override(self : Rich, run : Run, style : Int) -> @view.CjkOverride? {
  if run.code || (style & @hostapi.style_mono) != 0 {
    self.code_cjk_override
  } else {
    self.cjk_override
  }
}

///|
fn Rich::run_size(self : Rich, r : Run) -> Double {
  self.size * r.scale * (if r.code { self.code_scale } else { 1.0 })
}

///|
fn Rich::run_weight(self : Rich, r : Run) -> Int {
  if r.weight > 0 {
    r.weight
  } else {
    self.weight
  }
}

///|
fn Rich::run_bg(self : Rich, r : Run) -> Int64 {
  if r.bg != 0L {
    r.bg
  } else if r.code {
    self.code_bg
  } else {
    0L
  }
}

///|
/// The room a run of `size` has on its ground either side of its words, and after it off its ground (none without
/// one), to the half pixel.
fn Rich::run_room(self : Rich, r : Run, size : Double) -> (Double, Double) {
  let half = fn(v : Double) { (v * 2.0).round() / 2.0 }
  if self.run_bg(r) == 0L {
    (0.0, 0.0)
  } else {
    match r.ground {
      Some(g) => (half(g.room * size), half(g.after * size))
      None => (half(size * 0.3), 0.0)
    }
  }
}

///|
/// How deep the teeth of a torn ground `h` high are (torn_outline): three to its height, each as deep as a third of
/// its pitch.
fn torn_tooth(h : Double) -> Double {
  h / 3.0 / 3.0
}

///|
/// A ground `w` by `h` from (0, 0), its corners `corner` round, torn at its start (`from`) or its end (`on`): that
/// edge three teeth `torn_tooth` deep, their tips on the box's edge. One closed outline (x, y, x, y, …), clockwise.
fn torn_outline(w : Double, h : Double, corner : Double, from : Bool, on : Bool) -> Array[Double] {
  let out = []
  let teeth = 3
  let t = torn_tooth(h)
  let arc = fn(cx : Double, cy : Double, a0 : Double) {
    let steps = 6
    for i in 0..=steps {
      let a = a0 + @math.PI / 2.0 * i.to_double() / steps.to_double()
      out.push(cx + corner * @dmath.cos(a))
      out.push(cy + corner * @dmath.sin(a))
    }
  }
  // the top, left to right, then the end down
  if from {
    out.push(0.0)
    out.push(0.0)
  } else {
    arc(corner, corner, @math.PI)
  }
  if on {
    out.push(w)
    out.push(0.0)
    for i in 0..<teeth {
      let y = h * i.to_double() / teeth.to_double()
      let p = h / teeth.to_double()
      out.push(w - t)
      out.push(y + p / 2.0)
      out.push(w)
      out.push(y + p)
    }
  } else {
    arc(w - corner, corner, -@math.PI / 2.0)
    arc(w - corner, h - corner, 0.0)
  }
  // the bottom, right to left, then the start up
  if from {
    out.push(0.0)
    out.push(h)
    for i in 0..<teeth {
      let y = h - h * i.to_double() / teeth.to_double()
      let p = h / teeth.to_double()
      out.push(t)
      out.push(y - p / 2.0)
      out.push(0.0)
      out.push(y - p)
    }
  } else {
    arc(corner, h - corner, @math.PI / 2.0)
  }
  out
}

///|
/// Paragraph `r` laid out in `max_w`: as it was where it was laid out before the same, at the same scale, its lines set
/// the same way and its faces measured the same (rich_kept), in a width that gives it the same lines; else what any
/// width shares of it as it was (its text, where it breaks, its bidi levels), laid out in this one.
fn layout_rich(r : Rich, max_w : Double) -> RichLayout {
  let k = rich_kept_of(r)
  // (greedy wrapping gives the same lines in any width from the widest line up to the one they were made in, a label
  // kept whole in it too: what is not wrapped, in any)
  for i, e in k.lays {
    let lay = e.lay
    if !r.wrap || (lay.w <= max_w + 0.01 && max_w <= e.made) {
      if i > 0 {
        k.lays.remove(i) |> ignore
        k.lays.insert(0, e)
      }
      if measuring_origin_known.val && paint_phase.val != 1 {
        let zoomed = words_zoom.val != 1.0
        if !e.ahead_known ||
          e.ahead_moves != glyph_moves.val ||
          e.ahead_zoomed != zoomed ||
          (!zoomed && !ahead_origin_same(measuring_origin_x.val, e.ahead_ox, g().scale)) {
          if laid_ahead(lay.keys, fn(c) { lay.xs[c] + lay.pre[c] }) {
            e.ahead_known = true
            e.ahead_ox = measuring_origin_x.val
            e.ahead_zoomed = zoomed
            e.ahead_moves = glyph_moves.val
          }
        }
      }
      return lay
    }
  }
  let lay = rich_lines(r, k.prep, max_w)
  // (its glyphs not drawn yet, at the phases its lines put them at: drawn ahead so, text.mbt glyphs_ahead)
  let complete = laid_ahead(lay.keys, fn(c) { lay.xs[c] + lay.pre[c] })
  k.lays.insert(0, {
    made: max_w,
    lay,
    ahead_known: complete && measuring_origin_known.val && paint_phase.val != 1,
    ahead_ox: measuring_origin_x.val,
    ahead_zoomed: words_zoom.val != 1.0,
    ahead_moves: glyph_moves.val,
  })
  if k.lays.length() > rich_lays_most {
    k.lays.pop() |> ignore
  }
  lay
}

///|
/// What is kept of paragraph `r` as it is laid out now (layout_rich's: at the scale, the lines' way and the faces
/// measured in now), made as it is first asked for, said used this frame.
fn rich_kept_of(r : Rich) -> RichKept {
  let sc = g().scale
  let web = web_lines.val
  let gen = text_cache.generation
  let key = rich_key(r)
  let k = match rich_kept.get(key) {
    Some(k) if k.sc == sc && k.web == web && k.gen == gen && k.r == r => k
    _ => {
      if !rich_kept.contains(key) && rich_kept.length() >= rich_kept_most {
        rich_kept_thin()
      }
      // (its runs as they are now: what it was given may be changed in place after)
      let k = { r: { ..r, runs: r.runs.copy() }, sc, web, gen, prep: rich_prep(r), lays: [], used: 0 }
      rich_kept[key] = k
      k
    }
  }
  k.used = text_cache.frame
  k
}

///|
/// How narrow paragraph `r` may be laid out wrapped: the widest of what lies between two places its lines may break
/// (UAX #14, as rich_lines breaks them), the blanks a piece ends in left out: a browser's min-content. A run on a
/// ground of its own (a file's chip) is one piece, as rich_lines keeps it whole: an inline block's min-content.
fn rich_least_w(r : Rich) -> Double {
  let p = rich_kept_of(r).prep
  let brk = p.breaks()
  let n = p.starts.length()
  let mut widest = 0.0
  let mut w = 0.0
  // (the piece so far without the blanks it ends in)
  let mut inked = 0.0
  for i in 0..<n {
    if i > 0 && brk[i] != 0 && !rich_within_ground(r, p, i) {
      widest = dmax(widest, inked)
      w = 0.0
      inked = 0.0
    }
    w = w + p.adv[i]
    if p.cu[i] != 32 && !is_nl(p.cu[i]) {
      inked = w
    }
  }
  dmax(widest, inked)
}

///|
/// Whether cluster `i` is within a run drawn on a ground of its own, not at its start: where rich_lines breaks no line
/// unless the run is wider than a whole one.
fn rich_within_ground(r : Rich, p : RichPrep, i : Int) -> Bool {
  let k = p.run_of[i]
  let run = r.runs[k]
  i > p.run_c0[k] && p.run_c1[k] - p.run_c0[k] >= 2 && run.ground is Some(_) && r.run_bg(run) != 0L
}

///|
/// What of a paragraph is the same in whatever width it is laid out in: its runs' clusters and metrics end to end, its
/// text, where UAX #14 lets its lines break, its bidirectional levels (UAX #9, None: all left to right).
priv struct RichPrep {
  text : String
  run_start : Array[Int]
  run_c0 : Array[Int]
  run_c1 : Array[Int]
  run_size : Array[Double]
  run_a : Array[Double]
  run_d : Array[Double]
  run_lasc : Array[Double]
  run_ldesc : Array[Double]
  run_extra : Array[Double]
  drawings : Array[InlineDrawing?]
  starts : Array[Int]
  lens : Array[Int]
  adv : Array[Double]
  pre : Array[Double]
  keys : Array[Int]
  cu : Array[Int]
  mut brk : Array[Int]
  run_of : Array[Int]
  len : Int
  base_asc : Double
  base_desc : Double
  extra : Double
  bidi : @text.Bidi?
}

///|
/// UAX #14 line-break opportunities before each cluster of `self`, computed once on demand and kept on `self`.
fn RichPrep::breaks(self : RichPrep) -> Array[Int] {
  let n = self.starts.length()
  if self.brk.length() == n {
    return self.brk
  }
  let brk = Array::make(n, 0)
  if n > 1 {
    let b = @text.line_breaks(self.text)
    for i in 1..<n {
      brk[i] = b[self.starts[i]]
    }
  }
  self.brk = brk
  brk
}

///|
priv struct KeptRichLay {
  made : Double
  lay : RichLayout
  mut ahead_known : Bool
  mut ahead_ox : Double
  mut ahead_zoomed : Bool
  mut ahead_moves : Int
}

///|
/// A paragraph laid out before (layout_rich), as it was given then (`r`, at the scale, the lines' way and the faces
/// measured in then), what of it any width shares, the layouts made of it (the latest asked first, each with the width
/// it was made in) and the last frame that asked for it.
priv struct RichKept {
  r : Rich
  sc : Double
  web : Bool
  gen : Int
  prep : RichPrep
  lays : Array[KeptRichLay]
  mut used : Int
}

///|
/// The paragraphs laid out, by rich_key: a frame measures a node's paragraph as the tree is laid out and lays it out
/// again to draw it (view_runs_measure_set, view_runs_laid), in a width or two, frame after frame; each of those after
/// the first is what it was. Kept till they come to rich_kept_most, then those the frame did not ask for let go.
// put back as a Tester begins (its shapes and their glyphs' keys another run's)
let rich_kept : Map[Int64, RichKept] = Map([])

///|
let rich_kept_most : Int = 1024

///|
let rich_lays_most : Int = 3

///|
/// What tells a paragraph from others (rich_kept's key; its whole compared as it is found).
fn rich_key(r : Rich) -> Int64 {
  let mix = fn(h : Int64, v : Int64) { h * 1099511628211L + v }
  let mut h = r.size.reinterpret_as_int64()
  h = mix(h, r.weight.to_int64())
  h = mix(h, r.line.reinterpret_as_int64())
  h = mix(h, if r.wrap { 1L } else { 0L })
  h = mix(h, r.spacing.reinterpret_as_int64())
  h = mix(h, r.faces.to_int64())
  h = mix(h, r.shaped_in.to_int64())
  match r.cjk_override {
    Some(ov) => {
      h = mix(h, ov.face.to_int64() + 1L)
      h = mix(h, (ov.scale * 100.0).round().to_int().to_int64())
      h = mix(h, ov.weight_off.to_int64())
    }
    None => h = mix(h, 0L)
  }
  match r.code_cjk_override {
    Some(ov) => {
      h = mix(h, ov.face.to_int64() + 1L)
      h = mix(h, (ov.scale * 100.0).round().to_int().to_int64())
      h = mix(h, ov.weight_off.to_int64())
    }
    None => h = mix(h, 0L)
  }
  for run in r.runs {
    h = mix(h, stable_hash(run.text))
    h = mix(h, run.weight.to_int64())
    h = mix(h, run.scale.reinterpret_as_int64())
    h = mix(
      h,
      match run.face {
        Some(f) => f.to_int64() + 1L
        None => 0L
      },
    )
  }
  h
}

///|
/// What the frame did not ask for of the paragraphs laid out let go; all of them where it asked for each.
fn rich_kept_thin() -> Unit {
  let now = text_cache.frame
  let old = []
  for key, k in rich_kept {
    if k.used != now {
      old.push(key)
    }
  }
  if old.length() == 0 {
    rich_kept.clear()
  }
  for key in old {
    rich_kept.remove(key)
  }
}

///|
/// Surgically drop cached rich paragraphs that reference `face` (via paragraph face, any run face, or local CJK
/// override), leaving unrelated primary UI paragraphs intact.
fn rich_forget_face(face : Int) -> Unit {
  let gone : Array[Int64] = []
  for key, k in rich_kept {
    let r = k.r
    let mut hit = @hostapi.face_of_style(r.faces) == face
    if !hit {
      match r.cjk_override {
        Some(ov) if ov.face == face => hit = true
        _ => ()
      }
    }
    if !hit {
      match r.code_cjk_override {
        Some(ov) if ov.face == face => hit = true
        _ => ()
      }
    }
    if !hit {
      for run in r.runs {
        let style = r.run_style(run)
        if run.face == Some(face) || @hostapi.face_of_style(style) == face {
          hit = true
          break
        }
        match effective_cjk(style, r.run_cjk_override(run, style)) {
          Some((cjk_slot, _, _)) if cjk_slot == face => {
            hit = true
            break
          }
          _ => ()
        }
      }
    }
    if hit {
      gone.push(key)
    }
  }
  for key in gone {
    rich_kept.remove(key)
  }
}

///|
/// Whether run `run` of paragraph `r` (in `style`, its r.run_style) is words that an eighth of an em parts from the
/// words of the run beside it where a Han character or kana meets a Latin letter or a digit, as words_spaced_in parts
/// them within one run: not a drawing, not code or on a ground of its own (its room round it parts it already), not in
/// the code face (a grid), and not where nobody spaces words (@hostapi.words_spaced_none). Where the host's shaper
/// spaces them (@hostapi.words_spaced_by_host) it does so only within what it is given, one run.
fn rich_spaced_run(r : Rich, run : Run, style : Int) -> Bool {
  run.drawing is None &&
  !run.code &&
  run.ground is None &&
  r.run_bg(run) == 0L &&
  (style & @hostapi.style_mono) == 0 &&
  @hostapi.face_of_style(style) != @hostapi.face_code &&
  cjk_autospace_on.val &&
  spaced_now() != @hostapi.words_spaced_none
}

///|
/// Whether `run` in paragraph `r` (with resolved `style`) can be concatenated with adjacent mono/code runs sharing the
/// same `(size, weight, style)` for batched shaping: no inline drawing, no background room, no cross-run CJK/Latin
/// spacing, and no digit-dependent `style_tabular` toggle.
fn rich_can_batch_mono(r : Rich, run : Run, style : Int) -> Bool {
  run.drawing is None &&
  !run.code &&
  run.ground is None &&
  r.run_bg(run) == 0L &&
  ((style & @hostapi.style_mono) != 0 ||
  (@hostapi.face_of_style(style) == @hostapi.face_code && (style & @hostapi.style_tabular) == 0))
}

///|
/// Target UTF-16 code-unit budget per batched mono `shape()` call (well below `text_cache.buf`'s 8192-cluster cap).
let rich_mono_batch_budget : Int = 1024

///|
/// What of paragraph `r` any width shares (RichPrep).
/// (`one`: a paragraph of one run of words made as rich_prep_one makes it; false only in a test, which holds the two the
/// same)
fn rich_prep(r : Rich, one? : Bool = true, batch? : Bool = true) -> RichPrep {
  let sc = g().scale
  let (_, _, own0) = font_metrics(r.size, r.weight)
  // Chinese in it: measured by the CJK font's too (taller), as Android measures a line by the fonts it draws in (as a
  // browser, by the first font's alone: line_metrics)
  let cjk = r.runs.iter().any(fn(run) { words_cjk(run.text) })
  let all_code_or_mono = r.runs.length() > 0 && r.runs.iter().all(fn(run) { run.code || run.mono })
  let base_cjk_ov = if all_code_or_mono { r.code_cjk_override } else { r.cjk_override }
  let base_eff_cjk = effective_cjk(r.faces, base_cjk_ov)
  let base_style = if base_eff_cjk is Some(_) { r.faces } else { 0 }
  let base_cjk_enlarged = match base_eff_cjk {
    Some((_, s, _)) => s > 1.0
    None => false
  }
  let (a0, d0) = line_metrics(r.size, r.weight, cjk, style=base_style, cjk_override=base_cjk_ov)
  let lh = if r.line > 0.0 { r.line } else { own0 }
  let px = whole_pixel_lines(r.size, r.weight)
  let (pitch0, base_asc, extra) = set_line(lh, a0, d0, sc, px, trim=r.trim, cjk_fit=cjk && base_cjk_enlarged)
  let base_desc = pitch0 - base_asc
  // one run of words (a paragraph, a heading, an item, most of what a chat's message is made of): its clusters, their
  // breaks and its levels are its shape's, as they are (nothing laid out of a paragraph writes in them), not copied
  // out and worked out again of the same words
  if one && r.runs.length() == 1 && r.runs[0].drawing is None {
    return rich_prep_one(r, r.runs[0], lh, sc, px, base_asc, base_desc, extra)
  }
  let sb = StringBuilder()
  let run_start = []
  let run_c0 = []
  let run_c1 = []
  let run_size = []
  let run_a = []
  let run_d = []
  let run_lasc = []
  let run_ldesc = []
  let run_extra = []
  let drawings = []
  let starts = []
  let lens = []
  let adv = []
  let pre = []
  let keys = []
  let cu = []
  let run_of = []
  let mut off = 0
  // the last cluster of the run of words before (its index, its first code unit, the run's size), where an eighth of
  // an em may part it from this run's first (rich_spaced_run): each run is shaped on its own, so neither the host's
  // shaper nor words_spaced_in sees where two runs meet
  let mut spaced_before : (Int, Int, Double)? = None
  fn push_single(k : Int) {
    let run = r.runs[k]
    let size = r.run_size(run)
    drawings.push(None)
    let weight = r.run_weight(run)
    let style = r.run_style(run)
    let ov = r.run_cjk_override(run, style)
    let s = shape(run.text, size, weight, style~, spacing=r.spacing, cjk_override=ov)
    let run_cjk = words_cjk(run.text)
    let run_cjk_enlarged = match effective_cjk(style, ov) {
      Some((_, s, _)) => s > 1.0
      None => false
    }
    let fit = run_cjk && run_cjk_enlarged
    let (a, d) = line_metrics(size, weight, run_cjk, style~, cjk_override=ov)
    let (l, lasc, rx) = set_line(lh * size / r.size, a, d, sc, px, cjk_fit=fit)
    run_start.push(off)
    run_size.push(size)
    run_a.push(a)
    run_d.push(d)
    run_lasc.push(lasc)
    run_ldesc.push(l - lasc)
    run_extra.push(if fit { rx } else { 0.0 })
    run_c0.push(starts.length())
    let n = s.starts.length()
    let (room, after) = r.run_room(run, size)
    let spaced = rich_spaced_run(r, run, style)
    if spaced && n > 0 {
      match spaced_before {
        Some((c, before, before_size)) if spaced_pair(before, s.cu[0]) =>
          adv[c] = adv[c] + before_size * 0.125
        _ => ()
      }
    }
    for i in 0..<n {
      starts.push(s.starts[i] + off)
      lens.push(s.lens[i])
      let mut a = s.adv[i]
      let mut p = s.pad
      if i == 0 {
        a = a + room
        p = p + room
      }
      if i == n - 1 {
        a = a + room + after
      }
      adv.push(a)
      pre.push(p)
      keys.push(s.keys[i])
      cu.push(s.cu[i])
      run_of.push(k)
    }
    if n > 0 {
      spaced_before = if spaced { Some((starts.length() - 1, s.cu[n - 1], size)) } else { None }
    }
    run_c1.push(starts.length())
    sb.write_string(run.text)
    off = off + run.text.length()
  }

  let total_runs = r.runs.length()
  let mut k = 0
  while k < total_runs {
    let run = r.runs[k]
    let size = r.run_size(run)
    match run.drawing {
      Some(d) => {
        run_start.push(off)
        run_size.push(size)
        run_a.push(d.baseline * size)
        run_d.push((d.height - d.baseline) * size)
        run_lasc.push(dmax(base_asc, d.baseline * size))
        run_ldesc.push(dmax(base_desc, (d.height - d.baseline) * size))
        run_extra.push(0.0)
        run_c0.push(starts.length())
        starts.push(off)
        lens.push(run.text.length())
        adv.push(d.width * size)
        pre.push(0.0)
        keys.push(-2)
        cu.push(0xFFFC)
        run_of.push(k)
        run_c1.push(starts.length())
        sb.write_string(run.text)
        off = off + run.text.length()
        drawings.push(Some(({
          width: d.width * size,
          height: d.height * size,
          baseline: d.baseline * size,
          paths: d.paths.map(fn(path) { path.map(fn(p) { (p.0.map(fn(v) { v * size }), p.1) }) }),
          words: d.words.map(fn(w) { (w.0, w.1 * size, w.2 * size, w.3 * size) }),
        } : InlineDrawing)))
        spaced_before = None
        k = k + 1
        continue
      }
      None => ()
    }
    let weight = r.run_weight(run)
    let style = r.run_style(run)
    if batch && rich_can_batch_mono(r, run, style) && run.text.length() <= rich_mono_batch_budget {
      let mut k1 = k + 1
      let mut chunk_len = run.text.length()
      let mut last_nl_k1 = if has_nl(run.text) { k1 } else { -1 }
      while k1 < total_runs {
        let next = r.runs[k1]
        if next.drawing is Some(_) || r.run_size(next) != size || r.run_weight(next) != weight {
          break
        }
        let next_style = r.run_style(next)
        if next_style != style || !rich_can_batch_mono(r, next, next_style) {
          break
        }
        let nlen = next.text.length()
        if chunk_len + nlen > rich_mono_batch_budget {
          if last_nl_k1 >= k + 2 {
            k1 = last_nl_k1
          }
          break
        }
        chunk_len = chunk_len + nlen
        k1 = k1 + 1
        if has_nl(next.text) {
          last_nl_k1 = k1
        }
      }
      if k1 - k >= 2 {
        let count = k1 - k
        let chunk_sb = StringBuilder()
        let local_start = Array::make(count, 0)
        let local_end = Array::make(count, 0)
        let mut loff = 0
        for j in 0..<count {
          let t = r.runs[k + j].text
          local_start[j] = loff
          chunk_sb.write_string(t)
          loff = loff + t.length()
          local_end[j] = loff
        }
        let chunk = chunk_sb.to_string()
        let batch_ov = r.run_cjk_override(run, style)
        let s = shape(chunk, size, weight, style~, spacing=r.spacing, cjk_override=batch_ov)
        let batch_c0 = Array::make(count, 0)
        let batch_c1 = Array::make(count, 0)
        let m = s.starts.length()
        let mut ci = 0
        let mut aligned = true
        for j in 0..<count {
          let ls = local_start[j]
          let le = local_end[j]
          batch_c0[j] = ci
          if ls < le {
            if ci >= m || s.starts[ci] != ls {
              aligned = false
              break
            }
            while ci < m && s.starts[ci] < le {
              if s.starts[ci] + s.lens[ci] > le {
                aligned = false
                break
              }
              ci = ci + 1
            }
            if !aligned || ci == batch_c0[j] || s.starts[ci - 1] + s.lens[ci - 1] != le {
              aligned = false
              break
            }
          }
          batch_c1[j] = ci
        }
        if ci != m {
          aligned = false
        }
        if aligned {
          for j in 0..<count {
            let rk = k + j
            let rrun = r.runs[rk]
            let rrun_cjk = words_cjk(rrun.text)
            let batch_cjk_enlarged = match effective_cjk(style, batch_ov) {
              Some((_, s, _)) => s > 1.0
              None => false
            }
            let fit = rrun_cjk && batch_cjk_enlarged
            let (a, d) = line_metrics(size, weight, rrun_cjk, style~, cjk_override=batch_ov)
            let (l, lasc, rx) = set_line(lh * size / r.size, a, d, sc, px, cjk_fit=fit)
            drawings.push(None)
            run_start.push(off + local_start[j])
            run_size.push(size)
            run_a.push(a)
            run_d.push(d)
            run_lasc.push(lasc)
            run_ldesc.push(l - lasc)
            run_extra.push(if fit { rx } else { 0.0 })
            run_c0.push(starts.length())
            for c in batch_c0[j]..<batch_c1[j] {
              starts.push(s.starts[c] + off)
              lens.push(s.lens[c])
              adv.push(s.adv[c])
              pre.push(s.pad)
              keys.push(s.keys[c])
              cu.push(s.cu[c])
              run_of.push(rk)
            }
            run_c1.push(starts.length())
          }
          if m > 0 {
            spaced_before = None
          }
          sb.write_string(chunk)
          off = off + chunk.length()
          k = k1
          continue
        }
        for rk in k..<k1 {
          push_single(rk)
        }
        k = k1
        continue
      }
    }
    push_single(k)
    k = k + 1
  }
  let text = sb.to_string()
  let n = starts.length()
  let brk = if r.wrap {
    let brk = Array::make(n, 0)
    if n > 1 {
      let b = @text.line_breaks(text)
      for i in 1..<n {
        brk[i] = b[starts[i]]
      }
    }
    brk
  } else {
    []
  }
  // a label (a run on a ground of its own shape) is one thing, as CSS's inline-block is: a line breaks before it
  // (right to left: each line's clusters put in their visual order, rich_lines)
  let bd = @text.bidi_mixed(text)
  {
    text,
    run_start,
    run_c0,
    run_c1,
    run_size,
    run_a,
    run_d,
    run_lasc,
    run_ldesc,
    run_extra,
    drawings,
    starts,
    lens,
    adv,
    pre,
    keys,
    cu,
    brk,
    run_of,
    len: off,
    base_asc,
    base_desc,
    extra,
    bidi: bd,
  }
}

///|
/// rich_prep of a paragraph of one run, `run`, of words: what it is the same as rich_prep's loop makes of it (its
/// shape's clusters, the room round it on its first and last, its shape's breaks and levels), the shape's arrays taken
/// as they are where nothing is added to them.
fn rich_prep_one(
  r : Rich,
  run : Run,
  lh : Double,
  sc : Double,
  px : Bool,
  base_asc : Double,
  base_desc : Double,
  extra : Double,
) -> RichPrep {
  let size = r.run_size(run)
  let weight = r.run_weight(run)
  let style = r.run_style(run)
  let ov = r.run_cjk_override(run, style)
  let s = shape(run.text, size, weight, style~, spacing=r.spacing, cjk_override=ov)
  let run_cjk = words_cjk(run.text)
  let run_cjk_enlarged = match effective_cjk(style, ov) {
    Some((_, s, _)) => s > 1.0
    None => false
  }
  let fit = run_cjk && run_cjk_enlarged
  let (a, d) = line_metrics(size, weight, run_cjk, style~, cjk_override=ov)
  let (l, lasc, rx) = set_line(lh * size / r.size, a, d, sc, px, cjk_fit=fit)
  let n = s.starts.length()
  let (room, after) = r.run_room(run, size)
  let (adv, pre) = if room == 0.0 && after == 0.0 {
    (s.adv, Array::make(n, s.pad))
  } else {
    let adv = s.adv.copy()
    let pre = Array::make(n, s.pad)
    if n > 0 {
      adv[0] = adv[0] + room
      pre[0] = pre[0] + room
      adv[n - 1] = adv[n - 1] + room + after
    }
    (adv, pre)
  }
  {
    text: run.text,
    run_start: [0],
    run_c0: [0],
    run_c1: [n],
    run_size: [size],
    run_a: [a],
    run_d: [d],
    run_lasc: [lasc],
    run_ldesc: [l - lasc],
    run_extra: [if fit { rx } else { 0.0 }],
    drawings: [None],
    starts: s.starts,
    lens: s.lens,
    adv,
    pre,
    keys: s.keys,
    cu: s.cu,
    brk: if r.wrap { s.breaks(run.text) } else { [] },
    run_of: Array::make(n, 0),
    len: run.text.length(),
    base_asc,
    base_desc,
    extra,
    bidi: s.bidi,
  }
}

///|
/// Paragraph `r` (what any width shares of it: `p`) laid out in `max_w`.
fn rich_lines(r : Rich, p : RichPrep, max_w : Double) -> RichLayout {
  let text = p.text
  let run_start = p.run_start
  let run_c0 = p.run_c0
  let run_c1 = p.run_c1
  let run_size = p.run_size
  let run_a = p.run_a
  let run_d = p.run_d
  let run_lasc = p.run_lasc
  let run_ldesc = p.run_ldesc
  let run_extra = p.run_extra
  let drawings = p.drawings
  let starts = p.starts
  let lens = p.lens
  let adv = p.adv
  let pre = p.pre
  let keys = p.keys
  let cu = p.cu
  let brk = if r.wrap { p.breaks() } else { [] }
  let run_of = p.run_of
  let base_asc = p.base_asc
  let base_desc = p.base_desc
  let extra = p.extra
  let n = starts.length()
  // rather than within it, unless it is wider than a whole line; each cluster in one kept whole: where it starts
  let whole = Array::make(n, -1)
  if r.wrap {
    for k, run in r.runs {
      let c0 = run_c0[k]
      let c1 = run_c1[k]
      if run.ground is None || r.run_bg(run) == 0L || c1 - c0 < 2 {
        continue
      }
      let mut w = 0.0
      for c in c0..<c1 {
        w = w + adv[c]
      }
      if w <= max_w + 0.01 {
        for c in (c0 + 1)..<c1 {
          whole[c] = c0
        }
      }
    }
  }
  let xs = Array::make(n, 0.0)
  let line_of = Array::make(n, 0)
  let line_start = []
  let line_end = []
  let line_w = []
  let lay : RichLayout = {
    text,
    run_start,
    run_c0,
    run_c1,
    run_size,
    run_a,
    run_d,
    run_lasc,
    run_ldesc,
    run_extra,
    drawings,
    starts,
    lens,
    adv,
    pre,
    keys,
    cu,
    brk,
    run_of,
    xs,
    line_of,
    line_start,
    line_end,
    line_w,
    line_y: [],
    line_h: [],
    line_base: [],
    lv: [],
    len: p.len,
    w: 0.0,
    h: 0.0,
  }
  let mut w_max = 0.0
  fn finish(start : Int, end : Int) {
    // its width without the spaces it ends in
    let mut e = end
    while e > start && (cu[e - 1] == 32 || is_nl(cu[e - 1])) {
      e = e - 1
    }
    let lw = if e > start { xs[e - 1] + adv[e - 1] } else { 0.0 }
    line_start.push(start)
    line_end.push(end)
    line_w.push(lw)
    if lw > w_max {
      w_max = lw
    }
  }

  let mut ls = 0
  let mut i = 0
  let mut x = 0.0
  let mut last_break = -1
  while i < n {
    let c = cu[i]
    if lay.hard_end(i) {
      xs[i] = x
      line_of[i] = line_start.length()
      finish(ls, i + 1)
      ls = i + 1
      i = i + 1
      x = 0.0
      last_break = -1
      continue
    }
    if r.wrap && i > ls && brk[i] != 0 {
      last_break = i
    }
    let a = adv[i]
    if r.wrap && x + a > max_w + 0.01 && i > ls && c != 32 {
      let b = if last_break > ls { last_break } else { i }
      let b = if whole[b] > ls { whole[b] } else { b }
      finish(ls, b)
      ls = b
      i = b
      x = 0.0
      last_break = -1
      continue
    }
    xs[i] = x
    line_of[i] = line_start.length()
    x = x + a
    i = i + 1
  }
  if ls < n || line_start.length() == 0 || (n > 0 && lay.hard_end(n - 1)) {
    finish(ls, n)
  }
  // right to left: each line's clusters in their visual order
  // right to left: each line's clusters in their visual order
  match p.bidi {
    Some(bd) => {
      for _ in 0..<n {
        lay.lv.push(0)
      }
      for l in 0..<line_start.length() {
        let a = line_start[l]
        let mut e = line_end[l]
        while e > a && (cu[e - 1] == 32 || is_nl(cu[e - 1])) {
          e = e - 1
        }
        bidi_line(bd, starts, lens, adv, xs, lay.lv, a, e, 0.0)
      }
    }
    None => ()
  }
  // each line as high as its tallest run needs, its baseline shared
  let mut y = 0.0
  let mut last_extra = extra
  let last_line = line_start.length() - 1
  for l in 0..<line_start.length() {
    let mut asc = base_asc
    let mut desc = base_desc
    let is_last = l == last_line
    for c in line_start[l]..<line_end[l] {
      let k = run_of[c]
      asc = dmax(asc, run_lasc[k])
      desc = dmax(desc, run_ldesc[k])
      if is_last {
        last_extra = dmax(last_extra, run_extra[k])
      }
    }
    lay.line_y.push(y)
    lay.line_h.push(asc + desc)
    lay.line_base.push(asc)
    y = y + asc + desc
  }
  { ..lay, w: w_max, h: y + last_extra }
}

///|
pub fn RichLayout::line_count(self : RichLayout) -> Int {
  self.line_start.length()
}

///|
/// The start and end offsets (UTF-16, in the paragraph's text) of a line.
pub fn RichLayout::line_range(self : RichLayout, line : Int) -> (Int, Int) {
  let a = self.line_start[line]
  let b = self.line_end[line]
  let n = self.starts.length()
  (
    if a < n {
      self.starts[a]
    } else {
      self.len
    },
    if b < n {
      self.starts[b]
    } else {
      self.len
    },
  )
}

///|
/// Which line a point's y is on.
pub fn RichLayout::line_at(self : RichLayout, y : Double) -> Int {
  let lines = self.line_start.length()
  let mut l = 0
  while l + 1 < lines && y >= self.line_y[l + 1] {
    l = l + 1
  }
  l
}

///|
/// The UTF-16 offset nearest to a point in the paragraph (relative to its
/// top left).
pub fn RichLayout::offset_at(self : RichLayout, x : Double, y : Double) -> Int {
  let n = self.starts.length()
  if n == 0 || self.line_start.length() == 0 {
    return 0
  }
  let line = self.line_at(y)
  let a = self.line_start[line]
  let b = self.line_end[line]
  if self.lv.length() > 0 {
    return bidi_offset_at(self.starts, self.lens, self.adv, self.xs, self.lv, self.cu, a, b, x)
  }
  for c in a..<b {
    if is_nl(self.cu[c]) {
      return self.starts[c]
    }
    if x < self.xs[c] + self.adv[c] / 2.0 {
      return self.starts[c]
    }
  }
  if b >= n {
    self.len
  } else {
    self.starts[b]
  }
}

///|
/// Where a caret at `off` would be: x, the top of its line, the line's
/// height.
pub fn RichLayout::caret(self : RichLayout, off : Int) -> (Double, Double, Double) {
  let n = self.starts.length()
  if n == 0 {
    return (0.0, 0.0, if self.line_h.length() > 0 { self.line_h[0] } else { 0.0 })
  }
  let mut c = 0
  while c < n && self.starts[c] < off {
    c = c + 1
  }
  if c >= n {
    let last = n - 1
    let l = self.line_start.length() - 1
    if self.hard_end(last) {
      return (0.0, self.line_y[l], self.line_h[l])
    }
    let ll = self.line_of[last]
    (caret_after(self.xs, self.adv, self.lv, last), self.line_y[ll], self.line_h[ll])
  } else {
    let l = self.line_of[c]
    (caret_before(self.xs, self.adv, self.lv, c), self.line_y[l], self.line_h[l])
  }
}

///|
/// The rectangles (x, y, w, h; one a line) the text from `a` until `b`
/// covers: a selection's, a link's.
pub fn RichLayout::rects(
  self : RichLayout,
  a : Int,
  b : Int,
) -> Array[(Double, Double, Double, Double)] {
  let out = []
  let n = self.starts.length()
  let mut l = -1
  let mut x0 = 0.0
  let mut x1 = 0.0
  for c in 0..<n {
    let s = self.starts[c]
    if s < a || s >= b || is_nl(self.cu[c]) {
      continue
    }
    let cl = self.line_of[c]
    if cl != l {
      if l >= 0 {
        out.push((x0, self.line_y[l], x1 - x0, self.line_h[l]))
      }
      l = cl
      x0 = self.xs[c]
      x1 = x0
    }
    // a line's clusters may be out of order (right to left): the box around them
    if self.xs[c] < x0 {
      x0 = self.xs[c]
    }
    if self.xs[c] + self.adv[c] > x1 {
      x1 = self.xs[c] + self.adv[c]
    }
  }
  if l >= 0 {
    out.push((x0, self.line_y[l], x1 - x0, self.line_h[l]))
  }
  out
}

///|
/// The run the text at `off` is in (-1 past the end).
pub fn RichLayout::run_at(self : RichLayout, off : Int) -> Int {
  let mut k = -1
  for i, s in self.run_start {
    if s <= off {
      k = i
    }
  }
  if off >= self.len {
    -1
  } else {
    k
  }
}

///|
/// Where clusters [c0, c1) of one line lie: from the left of the leftmost to the right of the rightmost (in order
/// unless the line holds right-to-left text).
fn RichLayout::span_x(self : RichLayout, c0 : Int, c1 : Int) -> (Double, Double) {
  let mut x0 = self.xs[c0]
  let mut x1 = self.xs[c1 - 1] + self.adv[c1 - 1]
  if self.lv.length() > 0 {
    for c in c0..<c1 {
      if self.xs[c] < x0 {
        x0 = self.xs[c]
      }
      if self.xs[c] + self.adv[c] > x1 {
        x1 = self.xs[c] + self.adv[c]
      }
    }
  }
  (x0, x1)
}

///|
/// Run k's pieces of lines: (line, first cluster, past its last), without
/// the spaces a line ends in.
fn RichLayout::pieces(self : RichLayout, k : Int) -> Array[(Int, Int, Int)] {
  let out = []
  let c0 = self.run_c0[k]
  let c1 = self.run_c1[k]
  let mut c = c0
  while c < c1 {
    let l = self.line_of[c]
    let mut e = c
    while e < c1 && self.line_of[e] == l {
      e = e + 1
    }
    let mut t = e
    while t > c && (self.cu[t - 1] == 32 || is_nl(self.cu[t - 1])) {
      t = t - 1
    }
    if t > c {
      out.push((l, c, t))
    }
    c = e
  }
  out
}

// ---------------------------------------------------------------------------
// Building and painting

///|
/// A paragraph of runs, wrapped as one text in `size` (the runs' sizes
/// relative to it) with lines `line` high (0: the font's own). `line_em`, when given, sets the line as a multiple of
/// the drawn size after system text scaling. Links are drawn in `link_color` (unless a run has its own), with `pressed_bg`
/// behind them while held; tapped, `on_link` is told where they lead; held a long press's time, or right clicked,
/// `on_link_hold` (with the piece of line under the finger or the pointer); `on_link_shown`, each link's way, its
/// words and its id as the paragraph is built (what shows over it while it is pointed at: a card by that id,
/// Peeks.tsx Hover). Code
/// runs: the code face at `code_scale`, in `code_color` (0: the
/// paragraph's) on `code_bg` (0: none). `key` keeps its links' ids apart
/// from another paragraph's with the same words. `tracking`: letter spacing in pixels, in every run (a style's
/// `Tracking` in ems of `size`). `max_lines`: wrapped words cut after that many lines, ending in an ellipsis in the
/// style of the run it follows (as Ctx::text's, Android's maxLines with TextOverflow.Ellipsis); on one line (`wrap`
/// false), as Ctx::text's words are: never wider than a column it is in, cut so where it is laid narrower than it is
/// (`w` Cut in a row with less room, a share, a width said), its line breaks spaces unless `breaks` keeps them (code
/// shown as written); in what scrolls sideways it is as wide as it is, never cut. `words`: what people
/// and agents wrote (a message, a composer's words), set in the face given for them (faces.mbt, @hostapi.face_text) where
/// there is one. `face`: every run in that face (4 to 15, face_add), where it is given (a face shown in itself).
/// `tabular`: digits all one width (as Ctx::text's; where unsaid, the theme's for the app's own words, none for what
/// people wrote or a face shown in itself).
pub fn Ctx::rich(
  self : Ctx,
  runs : Array[Run],
  key? : String = "",
  style? : TextStyle,
  size? : Double,
  weight? : Int,
  color? : Int64,
  line? : Double,
  line_em? : Double,
  trim? : Bool = false,
  wrap? : Bool,
  w? : Size,
  link_color? : Int64 = 0x0A84FFFFL,
  pressed_bg? : Int64 = 0x0A84FF29L,
  code_color? : Int64 = 0L,
  code_bg? : Int64 = 0x7676801FL,
  code_scale? : Double = 0.9,
  tracking? : Double,
  max_lines? : Int,
  on_link? : (String) -> Unit = fn(_) {  },
  on_link_hold? : ((String, (Double, Double, Double, Double)) -> Unit)? = None,
  on_link_shown? : ((String, String, Int) -> Unit)? = None,
  words? : Bool = false,
  face? : Int = 0,
  tabular? : Bool,
  breaks? : Bool = false,
  allow_ellipsis? : Bool = false,
) -> Int {
  // its style (style.mbt) under what is said here, as Ctx::text's
  let st = self.text_patch(style)
  let (s_size, s_line) = self.text_sizes(st)
  let size = self.sp(first(size, s_size).unwrap_or(15.0))
  let weight = first(weight, opt_weight(st.weight)).unwrap_or(400)
  let color = first(color, opt_color(self.theme, st.color)).unwrap_or(0x1D1D1FFFL)
  // An em line follows the drawn size, including the system's non-linear text scaling.
  let line = match line_em {
    Some(em) => size * em
    None => first(line, s_line).map(fn(l) { self.sp(l) }).unwrap_or(self.theme.text_line * size)
  }
  let wrap = first(wrap, st.wrap).unwrap_or(true)
  let w = first(w, opt_size(st.w)).unwrap_or(Auto)
  let spacing = match (tracking, st.tracking) {
    (Some(v), _) => self.sp(v)
    (None, Some(t)) => t.px(size)
    (None, None) => 0.0
  }
  // (on one line: its line breaks spaces, as Ctx::text's)
  let runs = if wrap || breaks || !runs.iter().any(fn(r) { has_nl(r.text) }) {
    runs
  } else {
    match one_line(runs.map(fn(r) { r.text })) {
      Some(texts) => runs.mapi(fn(k, r) { { ..r, text: texts[k] } })
      None => runs
    }
  }
  let sb = StringBuilder()
  for r in runs {
    sb.write_string(r.text)
  }
  let text = sb.to_string()
  let base = self.id(if key == "" { "\u{1}rich\u{1}" + text } else { key })
  // a link pressed: told as it is let go (Ctx::on_press)
  for k, r in runs {
    if link_starts(runs, k) {
      let link = r.link
      self.on_press(link_id(base, runs, k), fn() { on_link(link) })
    }
  }
  // a link right clicked (a pointer's secondary button: a desktop's long press) told as held, at once; its menu the
  // link's alone, as the innermost asker's (Ctx::menu_asked): what it lies in offers none of its own with it
  match on_link_hold {
    Some(f) =>
      for k, r in runs {
        let id = link_id(base, runs, k)
        if r.link != "" {
          self.mark_id(id, mark_asks)
        }
        match (r.link, self.right_clicked(id)) {
          ("", _) | (_, None) => ()
          (link, Some((x, y))) => {
            f(link, link_piece(self, id, x, y))
            break
          }
        }
      }
    None => ()
  }
  // a link held still a long press's time by a finger: told where it leads and the piece of line held (in the
  // window), once a press, and the press is the hold's (no tap of the link as it lifts); a mouse holds nothing (its
  // right click, above: Pointing)
  // (read so: hand.mbt)
  hand.down.get() |> ignore
  match on_link_hold {
    Some(f) if self.down && self.held_told != self.press_at && pointing() is Finger =>
      for k, r in runs {
        let id = link_id(base, runs, k)
        if r.link == "" || !self.pressed(id) {
          continue
        }
        let moved = (self.px - self.press_x).abs() > touch_slop() ||
          (self.py - self.press_y).abs() > touch_slop()
        if moved {
          break
        }
        // (a moment: the frame at it woken, wake_in)
        let held = self.clock - self.press_at
        if held < long_press_ms {
          self.wake_in(long_press_ms - held)
          break
        }
        self.held_told = self.press_at
        let piece = link_piece(self, id, self.press_x, self.press_y)
        self.take_press()
        f(r.link, piece)
        break
      }
    _ => ()
  }
  let i = self.alloc_part(kind_rich, true, false)
  let n = self.nodes[i]
  n.allow_ellipsis = allow_ellipsis
  n.text = text
  n.font_size = size
  n.weight = weight
  n.color = color
  n.wrap = wrap
  n.line_h = line
  n.line_trim = trim
  n.w = w
  n.spacing = spacing
  n.rich = Some({
    runs,
    size,
    weight,
    color,
    line,
    trim,
    wrap,
    link_color,
    pressed_bg,
    code_color,
    code_bg,
    code_scale,
    spacing,
    base,
    select: desk.selecting,
    max_lines: first(max_lines, st.max_lines).unwrap_or(0),
    faces: faces_style(words, face) |
    (
      if first(tabular, st.tabular).unwrap_or(self.theme.tabular && !words && face == 0) {
        @hostapi.style_tabular
      } else {
        0
      }
    ),
    shaped_in: words_shaped_in.get(),
    cjk_override: None,
    code_cjk_override: None,
  })
  // each link told with its words and its id, once the paragraph is there
  match on_link_shown {
    Some(f) =>
      for k, r in runs {
        if link_starts(runs, k) {
          let words = StringBuilder()
          let mut j = k
          while j < runs.length() && runs[j].link == r.link {
            words.write_string(runs[j].text)
            j = j + 1
          }
          f(r.link, words.to_string(), link_id(base, runs, k))
        }
      }
    None => ()
  }
  i
}

///|
/// The paragraph laid out in `max_w`; as text_layout, one layout serves
/// every width from its widest line up to the one it was laid out in. On one line (not wrapped) and laid out
/// narrower than it is, cut with an ellipsis there, as Ctx::text's words are (ui/squeeze.mbt); not cut, it
/// serves every width it fits in.
fn Node::rich_layout(self : Node, max_w : Double) -> RichLayout? {
  match self.rich {
    None => None
    Some(r) => {
      // kept only for the same paragraph: the same words in other runs (a range moved, a run split) are laid out
      // again, whatever part of the frame asks
      match self.rl {
        Some(rl) if rich_same(self.rl_for, self.rich) && rl.w <= max_w + 0.01 && max_w <= self.rl_max =>
          return Some(rl)
        _ => ()
      }
      let rl = layout_rich(r, max_w)
      self.rl_whole = if r.wrap { 0.0 / 0.0 } else { rl.w }
      let cut = if r.wrap && r.max_lines > 0 && rl.line_start.length() > r.max_lines {
        Some(cut_rich(r, rl, max_w))
      } else if !r.wrap && rl.line_start.length() == 1 && rl.w > max_w + 0.5 {
        // (its one line as the first of lines cut after it)
        Some(cut_rich({ ..r, max_lines: 1 }, rl, max_w))
      } else {
        None
      }
      self.rcut = cut
      let rl = match cut {
        Some(c) => layout_rich(c, max_w)
        None => rl
      }
      self.rl = Some(rl)
      self.rl_max = if !r.wrap && cut is None { 1.0e18 } else { max_w }
      self.rl_for = self.rich
      Some(rl)
    }
  }
}

///|
/// A paragraph cut after its `max_lines`th line in `w` (cut_to_lines's, for runs): the last line has what follows of
/// it up to what fits with an ellipsis after it, the ellipsis in the style of the run the cut is in (a link's no
/// link). The lines before stay as they were. Its runs, to be laid out and drawn.
fn cut_rich(r : Rich, lay : RichLayout, w : Double) -> Rich {
  let count = lay.starts.length()
  let a = lay.line_start[r.max_lines - 1]
  // the run the line's words end in, by the last of it that fits
  let style_of = fn(c : Int) { r.runs[lay.run_of[imin(imax(c, 0), count - 1)]] }
  let dots_w = fn(run : Run) {
    shape("…", r.run_size(run), r.run_weight(run), style=r.run_style(run), spacing=r.spacing).adv.fold(
      init=0.0,
      fn(s, x) { s + x },
    )
  }
  let mut end = a
  let mut x = 0.0
  while end < count && !is_nl(lay.cu[end]) {
    let room = w - dots_w(style_of(end))
    if x + lay.adv[end] > room + 0.01 {
      break
    }
    x = x + lay.adv[end]
    end = end + 1
  }
  // no space left before the dots
  while end > a && lay.cu[end - 1] == 32 {
    end = end - 1
  }
  let cut_at = fn(end : Int) -> Rich {
    let cut = if end < count { lay.starts[end] } else { lay.len }
    let last = style_of(if end > a { end - 1 } else { a })
    let runs : Array[Run] = []
    let mut off = 0
    for run in r.runs {
      let n = run.text.length()
      if off + n <= cut {
        runs.push(run)
      } else if off < cut {
        runs.push({ ..run, text: run.text.clamped_view(end=cut - off).to_owned() })
      }
      off = off + n
    }
    runs.push({ ..last, text: "…", link: "", drawing: None })
    { ..r, runs }
  }
  let mut out = cut_at(end)
  // (its last line wider with the dots than it was measured (a full-width mark set closer before what followed it
  // than before the dots, words_spaced_in): on one line past `w`, or wrapped onto a line more; a cluster fewer until
  // it fits. Laid out as its callers lay it out next, in the width they do: kept, not laid out twice, rich_kept_of)
  while end > a {
    let cl = layout_rich(out, if r.wrap { w } else { 1.0e9 })
    let n = cl.line_start.length()
    let over = if r.wrap { n > r.max_lines || (n > 0 && cl.line_w[n - 1] > w + 0.5) } else { cl.w > w + 0.5 }
    if !over {
      break
    }
    end = end - 1
    while end > a && lay.cu[end - 1] == 32 {
      end = end - 1
    }
    out = cut_at(end)
  }
  out
}

///|
fn rich_zoomed_keys(r : Rich, lay : RichLayout) -> Array[Int]? {
  if words_zoom.val == 1.0 || lay.run_c0.length() != r.runs.length() {
    return None
  }
  let keys = lay.keys.copy()
  for k, run in r.runs {
    if run.drawing is Some(_) {
      continue
    }
    let (c0, c1) = (lay.run_c0[k], lay.run_c1[k])
    let style = r.run_style(run)
    let cjk_override = r.run_cjk_override(run, style)
    let s = shape(run.text, r.run_size(run), r.run_weight(run), style~, spacing=r.spacing, cjk_override~)
    match zoomed_keys(run.text, s, r.run_size(run), r.run_weight(run), style, r.spacing, cjk_override~) {
      Some(big) if big.length() == c1 - c0 =>
        for c in c0..<c1 {
          keys[c] = big[c - c0]
        }
      _ =>
        for c in c0..<c1 {
          keys[c] = -1
        }
    }
  }
  Some(keys)
}

///|
fn Ctx::paint_rich(self : Ctx, i : Int, n : Node, alpha : Double) -> Unit {
  // its layout as the cache has it for these runs (Node::rich_layout: laid out again when they are not the ones it was
  // laid out from), in the width it was placed in
  let lay = match n.rich_layout(dmax(n.fw - n.pad_l - n.pad_r, 0.0)) {
    Some(l) => l
    None => return
  }
  let r = match (n.rcut, n.rich) {
    (Some(r), _) | (None, Some(r)) => r
    _ => return
  }
  let ox = n.x + n.pad_l
  let oy = n.y + n.pad_t
  // a passage selected in the words it is in (words.mbt), behind everything of it
  if !words_sel.is_empty() {
    self.paint_selection(i, lay, ox, oy, alpha)
  }
  let k = clip_top()
  let cx0 = clip_stack[k]
  let cy0 = clip_stack[k + 1]
  let cx1 = clip_stack[k + 2]
  let cy1 = clip_stack[k + 3]
  keep_rich_runs(lay, ox, oy, cy0, cy1)
  // its words picked with the pointer: where it is for the next press, what of it is picked under its words
  if r.select {
    selectable_painted(Para(r.base), OldLayer(self.layer_of(i)), n.island, self.page_order(i), lay, n.text, ox, oy, dmax(n.x, cx0), dmax(n.y, cy0), dmin(n.x + n.fw, cx1), dmin(n.y + n.fh, cy1))
    for rect in selected_rects(Para(r.base), lay) {
      self.emit_rect(ox + rect.0, oy + rect.1, rect.2, rect.3, 0.0, desk.sel_color, 0.0, 0L, alpha)
    }
  }
  let colors = r.run_colors(n.color)
  // grounds (code, a pressed link), then the words, then the lines through or under them; links' pieces are hit
  // targets
  self.paint_run_grounds(
    r,
    lay,
    ox,
    oy,
    alpha,
    fn(k) {
      let run = r.runs[k]
      run.link != "" && self.pressed(link_id(r.base, r.runs, k))
    },
    fn(k, x0, y0, x1, y1) { self.rich_link_target(link_id(r.base, r.runs, k), x0, y0, x1, y1, cx0, cy0, cx1, cy1) },
  )
  self.emit_rich_glyphs(r, lay, ox, oy, colors, alpha, cy0, cy1)
  self.paint_run_lines(r, lay, ox, oy, colors, alpha)
}

///|
/// The ink each of a paragraph's runs is drawn in: its own, else a link's, code's (where the paragraph says one), else
/// `words` (the paragraph's).
fn Rich::run_colors(self : Rich, words : Int64) -> Array[Int64] {
  self.runs.map(fn(run) {
    if run.color != 0L {
      run.color
    } else if run.link != "" {
      self.link_color
    } else if run.code && self.code_color != 0L {
      self.code_color
    } else {
      words
    }
  })
}

///|
/// Where line `l` of a paragraph laid out in `lay` starts across from `ox`: there, or in the middle of `center_in`
/// where given, by its width without the spaces it ends in (emit_rich_glyphs').
fn rich_line_x(lay : RichLayout, l : Int, ox : Double, center_in : Double) -> Double {
  if center_in >= 0.0 && l < lay.line_w.length() {
    ox + dmax((center_in - lay.line_w[l]) / 2.0, 0.0)
  } else {
    ox
  }
}

///|
/// The grounds of a paragraph's runs laid out in `lay` at (ox, oy) (code's, a label's; a link's while `pressed(k)` says
/// run `k` is held, its pressed ground), under its words; each piece of a link's line told `piece` (its run, where it
/// is drawn: x0, y0, x1, y1), as drawn. A ground carried on to the next line, or from the last, torn there.
fn Ctx::paint_run_grounds(
  self : Ctx,
  r : Rich,
  lay : RichLayout,
  ox0 : Double,
  oy : Double,
  alpha : Double,
  pressed : (Int) -> Bool,
  piece : (Int, Double, Double, Double, Double) -> Unit,
  center_in? : Double = -1.0,
) -> Unit {
  for k, run in r.runs {
    let link = run.link != ""
    let pressed = link && pressed(k)
    let bg = if pressed { r.pressed_bg } else { r.run_bg(run) }
    if bg == 0L && !link {
      continue
    }
    for p in lay.pieces(k) {
      let (l, c0, c1) = p
      let ox = rich_line_x(lay, l, ox0, center_in)
      let top = oy + lay.line_y[l]
      let (sx0, sx1) = lay.span_x(c0, c1)
      let x0 = ox + sx0
      let x1 = ox + sx1
      if bg != 0L {
        let base = top + lay.line_base[l]
        let a = lay.run_a[k]
        let d = lay.run_d[k]
        // a ground carried on to the next line, or from the last, is torn there: its edge a row of teeth past the
        // words, so its pieces read as one broken across lines
        let from = lay.line_of[lay.run_c0[k]] != l
        let on = lay.line_of[lay.run_c1[k] - 1] != l
        let (bx0, bx1) = if pressed && r.run_bg(run) == 0L {
          (x0 - 2.0, x1 + 2.0)
        } else if c1 == lay.run_c1[k] {
          (x0, x1 - r.run_room(run, lay.run_size[k]).1)
        } else {
          (x0, x1)
        }
        // a code run's: its ink and a pixel either way; a label's centred on its ink
        let (by, bh, corner) = match run.ground {
          None => (base - a - 1.0, a + d + 2.0, dmin(4.0, (a + d) / 2.0))
          Some(g) => {
            let h = g.height * lay.run_size[k]
            (base - (a - d) / 2.0 - h / 2.0, h, dmin(g.corner * lay.run_size[k], h / 2.0))
          }
        }
        if (from || on) && !(pressed && r.run_bg(run) == 0L) {
          let tooth = torn_tooth(bh)
          let gx0 = if from { bx0 - tooth } else { bx0 }
          let gx1 = if on { bx1 + tooth } else { bx1 }
          self.emit_shape(gx0, by, [(torn_outline(gx1 - gx0, bh, corner, from, on), true)], true, 0.0, false, bg, alpha)
        } else {
          self.emit_rect(bx0, by, bx1 - bx0, bh, corner, bg, 0.0, 0L, alpha)
        }
      }
      if link {
        piece(k, x0, top, x1, top + lay.line_h[l])
      }
    }
  }
}

///|
/// The lines through or under a paragraph's runs laid out in `lay` at (ox, oy) (strike, underline), in their inks
/// (`colors`), over its words: a code run's room either side, a label's after it, not under them.
fn Ctx::paint_run_lines(
  self : Ctx,
  r : Rich,
  lay : RichLayout,
  ox0 : Double,
  oy : Double,
  colors : Array[Int64],
  alpha : Double,
  center_in? : Double = -1.0,
) -> Unit {
  let sc = self.scale
  for k, run in r.runs {
    if !run.strike && !run.underline {
      continue
    }
    let size = lay.run_size[k]
    let t = dmax(1.0, (size / 15.0 * sc).round() / sc)
    // a code run's room either side is not under the line, nor a label's after it
    let room = if lay.run_c1[k] > lay.run_c0[k] {
      lay.pre[lay.run_c0[k]]
    } else {
      0.0
    }
    for p in lay.pieces(k) {
      let (l, c0, c1) = p
      let ox = rich_line_x(lay, l, ox0, center_in)
      let base = oy + lay.line_y[l] + lay.line_base[l]
      let (sx0, sx1) = lay.span_x(c0, c1)
      let x0 = ox + sx0 + (if c0 == lay.run_c0[k] { room } else { 0.0 })
      let x1 = ox + sx1 - (if c1 == lay.run_c1[k] { room + r.run_room(run, size).1 } else { 0.0 })
      if run.strike {
        let y = glyph_y(base - size * 0.27 - t / 2.0, sc)
        self.emit_rect(x0, y, x1 - x0, t, 0.0, colors[k], 0.0, 0L, alpha)
      }
      if run.underline {
        let y = glyph_y(base + size * 0.12, sc)
        self.emit_rect(x0, y, x1 - x0, t, 0.0, colors[k], 0.0, 0L, alpha)
      }
    }
  }
}

///|
/// How long a finger is held still for a long press (ViewConfiguration's long press timeout, as Compose has it on
/// Android: 400 ms).
pub let long_press_ms : Double = 400.0

///|
/// The piece of a link's line under (x, y), as it was last drawn (x, y, w, h in the window); the point itself when none.
fn link_piece(c : Ctx, id : Int, x : Double, y : Double) -> (Double, Double, Double, Double) {
  let mut k = c.hit_ids.length() - 1
  while k >= 0 {
    if c.hit_ids[k] == id {
      let r = k * 4
      let x0 = c.hit_rects[r]
      let y0 = c.hit_rects[r + 1]
      let x1 = c.hit_rects[r + 2]
      let y1 = c.hit_rects[r + 3]
      if x >= x0 && x < x1 && y >= y0 && y < y1 {
        return (x0, y0, x1 - x0, y1 - y0)
      }
    }
    k = k - 1
  }
  (x, y, 0.0, 0.0)
}

///|
/// The glyphs (and drawings) of paragraph `r` laid out as `lay`, its top left at (`ox`, `oy`), each run in its colour
/// (`colors`), as opaque as `alpha`, those of lines between `cy0` and `cy1`: set on the pixels where they are made, and
/// each told to `unplaced` where it is before that (instance, x, the line's baseline, the glyph's own offset down), for
/// what places it again elsewhere (a node's words, view_blit), as emit_text tells its own.
fn Ctx::emit_rich_glyphs(
  self : Ctx,
  r : Rich,
  lay : RichLayout,
  ox : Double,
  oy : Double,
  colors : Array[Int64],
  alpha : Double,
  cy0 : Double,
  cy1 : Double,
  unplaced? : Array[UnplacedGlyph],
  center_in? : Double = -1.0,
) -> Unit {
  let sc = self.scale
  let zoom = words_zoom.val
  let zoomed = rich_zoomed_keys(r, lay)
  let ox0 = ox
  for c in 0..<lay.starts.length() {
    // (each line in the middle of `center_in` where given, by its width without the spaces it ends in: as emit_text's)
    let line = lay.line_of[c]
    let ox = if center_in >= 0.0 && line < lay.line_w.length() {
      ox0 + dmax((center_in - lay.line_w[line]) / 2.0, 0.0)
    } else {
      ox0
    }
    let key = lay.keys[c]
    if key == -2 {
      match lay.drawings[lay.run_of[c]] {
        Some(d) => {
          let l = lay.line_of[c]
          let x = ox + lay.xs[c]
          let y = oy + lay.line_y[l] + lay.line_base[l] - d.baseline
          if y > cy1 || y + d.height < cy0 {
            left_out()
            continue
          }
          if rec_whole.val {
            rec_line(self.ninst, y, d.height)
          }
          let color = colors[lay.run_of[c]]
          for path in d.paths { self.emit_shape(x, y, path, true, 0.0, false, color, alpha) }
          for word in d.words {
            let tl = layout_text(word.0, word.3, 400, 100000.0, false, style=@hostapi.style_serif)
            self.emit_text(tl, x + word.1, y + word.2 - tl.ascent, color, alpha, font=(word.3, 400, @hostapi.style_serif, 0.0), unplaced?)
          }
        }
        None => ()
      }
      continue
    }
    if key < 0 {
      continue
    }
    let l = lay.line_of[c]
    let top = oy + lay.line_y[l]
    // (its own look, where what holds it says one: Ctx::glyphs_by)
    let own = glyph_next(ox + lay.xs[c], top, lay.line_h[l], l, lay.xs[c] + lay.adv[c] / 2.0)
    match own {
      Some(gl) if gl.alpha <= 0.002 => continue
      _ => ()
    }
    if top > cy1 || top + lay.line_h[l] < cy0 {
      left_out()
      continue
    }
    if rec_whole.val {
      rec_line(self.ninst, top, lay.line_h[l])
    }
    // (made at the host's pixels a point; in a shot drawn at more, made that much larger and drawn that much smaller:
    // emit_text)
    let (base_key, z) = match zoomed {
      Some(big) if big[c] >= 0 => (big[c], zoom)
      _ => (key, 1.0)
    }
    let key = glyph_sub(base_key, ox + lay.xs[c] + lay.pre[c], sc, z)
    if rec_glyph_early(key, sc / zoom, ox + lay.xs[c], top, ox + lay.xs[c] + lay.adv[c], top + lay.line_h[l]) {
      rec_skip(top, top + lay.line_h[l])
      continue
    }
    let g = glyph(key, sc / zoom)
    if g.gw <= 0.0 {
      continue
    }
    let gx = glyph_x(ox + lay.xs[c] + lay.pre[c], g.ox / z, sc, z~)
    let gy = glyph_row(oy, lay.line_y[l] + lay.line_base[l], g.oy / z, sc)
    let (gw, gh) = (g.gw / z, g.gh / z)
    // (the uniform scale is about its ink's middle; an extra horizontal scale is about its advance's middle, so a
    // glyph stays in its place while that place changes width)
    let (set_x, set_y) = (gx, gy)
    let (gx, gy, gw, gh, ga) = match own {
      Some(gl) => {
        let ink_x = gx + gw * (1.0 - gl.scale) / 2.0
        let cell_x = ox + lay.xs[c] + lay.adv[c] / 2.0
        let x = if gl.sx == 1.0 { ink_x } else { cell_x + (ink_x - cell_x) * gl.sx }
        (x + gl.dx, gy + gh * (1.0 - gl.scale) / 2.0 + gl.dy, gw * gl.scale * gl.sx, gh * gl.scale, alpha * gl.alpha)
      }
      None => (gx, gy, gw, gh, alpha)
    }
    // (where it is before it is set on the pixels, for what places it again elsewhere (view_blit), and what its own
    // look moves it by after that)
    match unplaced {
      Some(u) =>
        u.push({
          at: self.ninst,
          x: ox + lay.xs[c] + lay.pre[c],
          ox: g.ox / z,
          base: top + lay.line_base[l],
          oy: g.oy / z,
          own_x: gx - set_x,
          own_y: gy - set_y,
          key: base_key,
          z,
        })
      None => ()
    }
    // (its halo's, where its words have one: halo.mbt)
    halo_told(self.ninst, key)
    glyph_pushing.val = true
    self.push_inst(
      gx,
      gy,
      gw,
      gh,
      0.0,
      if g.color { 3.0 } else { 1.0 },
      0.0,
      0.0,
      if g.color { 0xFFFFFFFFL } else { colors[lay.run_of[c]] },
      ga,
      g.u,
      g.v,
      g.gw * (sc / zoom),
      g.gh * (sc / zoom),
    )
    glyph_pushing.val = false
    if inst_owners_kept() {
      let (x0, x1) = lay.span_x(c, c + 1)
      inst_cell(self.ninst - 1, gx, gw, ox + x0 + lay.pre[c], ox + x1)
    }
  }
  if rec_whole.val {
    rec_line(self.ninst, 0.0, -1.0)
  }
}
