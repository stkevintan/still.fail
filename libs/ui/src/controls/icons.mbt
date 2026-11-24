// Icons, as still.fail draws them (web/ui icons.tsx from design/icons): 24
// grid line art, 1.75 strokes, in one colour. Drawn by the GPU as shapes
// (mbui's Ctx::shapes), at whatever size and colour, nothing made first.

///|
let made : Map[String, Bool] = Map([])

///|
/// Icons' parts drawn, by name, parts, size and ink (`icon_parts_shapes`): what breathes or lights in steps drawn in
/// each step's ink found again, not cut from the icon's numbers anew each step.
let parts_made : Map[(String, Array[Int], Double, Int64), Array[@ui.Shape]] = Map([])

///|
/// Every Tester starts as the app does (mbui's on_reset): the images made here gone with its own, nothing waited on or
/// copied, the theme the first frame's.
fn init {
  @ui.on_reset(fn() {
    made.clear()
    parts_made.clear()
    tiles_made.clear()
    dark_set.set(None)
    accent_set.set("")
    rainbow_hue.set(default_rainbow_hue)
    custom_hue_kept.val = 210
    current.val = {
      dark: false,
      touch: false,
      p: light_palette,
      t: wide_type,
      rows: wide_rows,
      control_h: wide_control_h,
      bars: bars_drawn,
      round: wide_round,
      items: wide_items,
      chat_list: mouse_chat_list,
    }
  })
}

///|
/// An icon's shapes as its data has them (icon_data: a 24 grid's strokes), for a host to draw it in its own controls
/// (@hostapi.nav_bar's tabs and items); "" for none of that name.
pub fn icon_path(name : String) -> String {
  icon_data.get(name).unwrap_or("")
}

///|
/// Icon `name`'s data (icon_data's, the 24 grid) moved so its weight sits in its box's middle, for where it stands alone
/// in a round key (play_mark's triangle is so in its disc): a chevron's open side reads as a triangle's base, its weight
/// a sixth of its width (1 of the 24 grid's 6) off toward that side, so it is moved as far toward its point. Others as
/// they are.
fn icon_weighed(name : String, data : Array[Double]) -> Array[Double] {
  let (dx, dy) = match name {
    "chevron-left" => (-1.0, 0.0)
    "chevron-right" => (1.0, 0.0)
    "chevron-up" => (0.0, -1.0)
    "chevron-down" => (0.0, 1.0)
    _ => return data
  }
  let out = data.copy()
  let mut i = 0
  while i + 2 < out.length() {
    let n = out[i + 2].to_int()
    for p in 0..<n {
      out[i + 3 + 2 * p] += dx
      out[i + 4 + 2 * p] += dy
    }
    i = i + 3 + 2 * n
  }
  out
}

///|
/// How big the play mark is in its disc: its triangle (15 of play-mark's 24) two fifths of the disc across.
let play_mark_share : Double = 0.64

///|
/// A video's play mark over its picture in `parent` (play_mark's, as nodes): a disc `side` across of `shade`, the solid
/// triangle in it white, its weight in the disc's middle. The node.
#callsite(autofill(loc))
pub fn play_mark_node(parent : @view.View, side : Double, shade : @ui.Color, loc~ : SourceLoc) -> @view.View {
  parent.box(made_for=loc, fn(d) {
    d
    .width(Is(Some(side)))
    .height(Is(Some(side)))
    .radius(Is(side / 2.0))
    .ground(By(fn() { @ui.tree_theme().color(shade) }))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    |> ignore
    icon_node(d, "play-mark", side * play_mark_share, Is(white)) |> ignore
  })
}

///|
/// A video's capsule (as a node) laid over `parent`, in its foot's start corner concentric with a
/// message's file's (or `corner`, a quote's picture's): a small play mark and how long it is (`duration`, none where that
/// is not known) on the video's shade; while `coming` says how far the core has brought it here, a ring of that share
/// and the share in words in their place, each one in the other's place along the capsule's row (never both seen, the
/// capsule's width making its way between them); told nothing of its coming (a tile's), nothing made for that. Not yet: the one going out faded before the other comes in, as
/// video_capsule's (View::pick's `leave` reads the time in its fader's binding, View::going: a clock read here).
#callsite(autofill(loc))
pub fn video_capsule_node(
  parent : @view.View,
  duration : Double,
  corner? : Double = message_file_corner,
  coming? : () -> Double?,
  loc~ : SourceLoc,
) -> Unit {
  let length = if duration > 0.0 { clock(duration) } else { "" }
  parent.box(made_for=loc, fn(foot) {
    foot.over(Is(true)) |> ignore
    // (concentric with its corner as high as it is drawn: higher than said where its words' line is, box_at)
    style_node(foot, fn() { video_capsule_foot_at(corner, words_box_high(video_capsule_h, video_capsule_words, foot.words_scale())) })
    foot.box(fn(b) {
      // (a mark over the picture, the capsule itself (its foot is all of the picture, to lay it in its corner): where the
      // picture flies (View::shared), carried at its own size by its corner, gone halfway, as the old page's thumbnail
      // drew it over its flight: View::flight_mark)
      b.flight_mark() |> ignore
      // (as high as its words' line where the system's size of words draws it higher than the capsule: box_at)
      style_node(b, fn() { box_at(video_capsule_kept, video_capsule_box, video_capsule_h, video_capsule_words, b.words_scale()) })
      b.box(fn(row) {
        style_node(row, fn() { video_capsule_row })
        match coming {
          // (told nothing of its coming, a tile's: its mark and its length, nothing made to choose)
          None => {
            icon_node(row, "play", video_capsule_mark, Is(white)) |> ignore
            if length != "" {
              words_node(row, fn() { length }, fn() { video_capsule_words }) |> ignore
            }
          }
          Some(coming) => {
            // (how far, the last said kept as it goes out: video_capsule_last's)
            let last = Ref(0.0)
            let part = fn() {
              match coming() {
                Some(p) => {
                  last.val = p
                  p
                }
                None => last.val
              }
            }
            let shown = fn() { coming() is Some(_) }
            // its mark and its words each a pick of its own, so each has the other beside it to make its way along
            row.pick(along_row=true, shown, fn(m, on) {
              if on {
                progress_ring_node(m, video_capsule_ring, part, fn() { white }) |> ignore
              } else {
                icon_node(m, "play", video_capsule_mark, Is(white)) |> ignore
              }
            })
            row.pick(along_row=true, shown, fn(m, on) {
              if on {
                words_node(m, fn() { "\{(dmin(1.0, dmax(0.0, part())) * 100.0).floor().to_int()}%" }, fn() { video_capsule_words })
                |> ignore
              } else if length != "" {
                words_node(m, fn() { length }, fn() { video_capsule_words }) |> ignore
              }
            })
          }
        }
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// Where a video's capsule `h` high stands over its video in its foot's start corner, `corner` round (a message's
/// file's, or a quote's picture's): concentric with it (video_capsule_foot where it is as high as said).
fn video_capsule_foot_at(corner : Double, h : Double) -> @ui.Style {
  if corner == message_file_corner && h == video_capsule_h {
    video_capsule_foot
  } else if corner == message_file_corner {
    video_capsule_foot.then(@ui.style(p=room_of(@ui.capsule_in(message_file_corner, h))))
  } else {
    video_capsule_foot.then(@ui.style(p=room_of(capsule_fit(corner, h, video_capsule_alone_in))))
  }
}

///|
// kept across runs: the last theme and size of words a video's capsule was asked at and its box (box_at), worked out
// again for any other
let video_capsule_kept : Ref[WordsBoxKept?] = Ref(None)

///|
/// The capsule's height, its play mark's and its ring's.
pub let video_capsule_h : Double = 18.0

///|
let video_capsule_mark : Double = 10.0

///|
let video_capsule_ring : Double = 14.0

///|
/// How far the capsule is from the picture's sides and foot where its corner is too square to lead it (a quote's
/// picture's, quote_picture_corner).
let video_capsule_alone_in : Double = 8.0

///|
// kept across runs: a value (no field of it changes)
let video_capsule_foot : @ui.Style = @ui.style(
  w=Full,
  h=Full,
  justify=JEnd,
  align=AStart,
  p=room_of(@ui.capsule_in(message_file_corner, video_capsule_h)),
)

///|
// kept across runs: a value (no field of it changes)
let video_capsule_box : @ui.Style = @ui.style(
  row=true,
  h=Fixed(video_capsule_h),
  px=S1_5,
  radius=Full,
  bg=video_shade,
  align=ACenter,
)

///|
// kept across runs: a value (no field of it changes)
let video_capsule_row : @ui.Style = @ui.css("row gap=S1 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let video_capsule_words : @ui.TextStyle = @ui.text_style(size=Caption, color=white_ink, wrap=false)

///|
/// Of icon `name`, its parts `parts` `size` across in `ink` (none where there is no such icon): made once for each, the
/// same shapes after (which no one changes). Past 256 of them all go, to be made again as they are asked for.
fn icon_parts_shapes(name : String, parts : Array[Int], size : Double, ink : Int64) -> Array[@ui.Shape] {
  let key = (name, parts, size, ink)
  match parts_made.get(key) {
    Some(s) => s
    None => {
      let s = match icon_numbers(name) {
        Some(d) => icon_shapes(icon_data_parts(d, parts), size / 24.0, ink)
        None => []
      }
      if parts_made.length() >= 256 {
        parts_made.clear()
      }
      parts_made[(name, parts.copy(), size, ink)] = s
      s
    }
  }
}

///|
/// Icon `name`'s numbers with its lines as `trace` gives them (icon_traced's), for icon_shapes: a mark drawn on or back
/// along its strokes, in an old view or a node (sync_key_node).
pub fn icon_traced_data(name : String, trace : (Int, Array[Double]) -> Array[Array[Double]]) -> Array[Double] {
  let data : Array[Double] = []
  match icon_numbers(name) {
    Some(d) => {
      let mut i = 0
      let mut line = 0
      while i + 2 < d.length() {
        let w = d[i + 1]
        let n = d[i + 2].to_int()
        let end = i + 3 + 2 * n
        if d[i].to_int() != 2 {
          for pts in trace(line, d[i + 3:end].to_owned()) {
            if pts.length() >= 4 {
              data.push(0.0)
              data.push(w)
              data.push((pts.length() / 2).to_double())
              for v in pts {
                data.push(v)
              }
            }
          }
          line = line + 1
        }
        i = end
      }
    }
    None => ()
  }
  data
}

///|
/// The first `part` (0 to 1) of the line through `pts` (x y each) by its length: none where that is nothing.
pub fn stroke_from_start(pts : Array[Double], part : Double) -> Array[Double] {
  let n = pts.length() / 2
  let mut whole = 0.0
  for j in 1..<n {
    whole = whole + segment_length(pts, j)
  }
  let mut left = whole * part
  if left <= 0.0 || n < 2 {
    return []
  }
  let out = [pts[0], pts[1]]
  for j in 1..<n {
    let l = segment_length(pts, j)
    if l >= left {
      let f = if l > 0.0 { left / l } else { 1.0 }
      out.push(pts[2 * j - 2] + (pts[2 * j] - pts[2 * j - 2]) * f)
      out.push(pts[2 * j - 1] + (pts[2 * j + 1] - pts[2 * j - 1]) * f)
      return out
    }
    out.push(pts[2 * j])
    out.push(pts[2 * j + 1])
    left = left - l
  }
  out
}

///|
/// How long the `j`th piece of the line through `pts` is (from point j - 1 to j).
fn segment_length(pts : Array[Double], j : Int) -> Double {
  let dx = pts[2 * j] - pts[2 * j - 2]
  let dy = pts[2 * j + 1] - pts[2 * j - 1]
  (dx * dx + dy * dy).sqrt()
}

///|
/// The entries of an icon's data that are its parts `parts` (a fill's holes, of no width, with the fill they cut).
fn icon_data_parts(data : Array[Double], parts : Array[Int]) -> Array[Double] {
  let out : Array[Double] = []
  let mut i = 0
  let mut part = -1
  while i + 2 < data.length() {
    let kind = data[i].to_int()
    let w = data[i + 1]
    let n = data[i + 2].to_int()
    let end = i + 3 + 2 * n
    if !(kind == 2 && w <= 0.0 && part >= 0) {
      part = part + 1
    }
    if parts.contains(part) {
      for k in i..<end {
        out.push(data[k])
      }
    }
    i = end
  }
  out
}

///|
/// Icon `name`'s numbers, read from icon_data.mbt's text the first time it is asked for (as an array literal each, they
/// were the design system's start-up code: 670 KB of C compiled on every build, 2026-10-24).
pub fn icon_numbers(name : String) -> Array[Double]? {
  match icon_read.get(name) {
    Some(d) => Some(d)
    None =>
      match icon_data.get(name) {
        Some(text) => {
          let d = read_numbers(text)
          icon_read[name] = d
          Some(d)
        }
        None => None
      }
  }
}

///|
let icon_read : Map[String, Array[Double]] = Map([])

///|
/// The numbers in `text`, each a space from the next, as icons.py writes them ("-12", "0.562"): its digits read as one
/// whole number then divided by the point's power of ten, one rounding, so the same as the literal would be.
fn read_numbers(text : String) -> Array[Double] {
  let out : Array[Double] = []
  let mut m = 0L
  let mut neg = false
  let mut point = false
  let mut div = 1.0
  let mut digits = false
  for c in text + " " {
    if c == ' ' {
      if digits {
        let v = m.to_double() / div
        out.push(if neg { -v } else { v })
      }
      m = 0L
      neg = false
      point = false
      div = 1.0
      digits = false
    } else if c == '-' {
      neg = true
    } else if c == '.' {
      point = true
    } else {
      m = m * 10L + (c.to_int() - '0'.to_int()).to_int64()
      digits = true
      if point {
        div = div * 10.0
      }
    }
  }
  out
}

///|
/// How an icon drawn `k` points a unit (its size over 24) widens its strokes: under 1, by k^0.58, not by k, so a bar's
/// 14–16 and a rail's 20 are drawn in one weight of ink (20's 1.75 stroke 1.57, 16's 1.38, 14's 1.28; by k they were
/// 1.46, 1.17 and 1.02), and none thinner than the eye takes for the same line; at 24 and over, by k (their points too).
fn stroke_k(k : Double) -> Double {
  if k < 1.0 {
    @dmath.pow(k, 0.58)
  } else {
    k
  }
}

///|
/// An icon's parts as icon_data.mbt has them (0 a line, 1 a closed one, 2 a fill's outline: one with a width the
/// first of a fill), `k` points a unit, in `color`: its strokes of a width one shape (their pieces' nearest the one
/// that covers a pixel, as one stroke), each fill one.
pub fn icon_shapes(data : Array[Double], k : Double, color : Int64) -> Array[@ui.Shape] {
  let strokes : Array[(Double, Array[(Array[Double], Bool)])] = []
  let fills : Array[Array[(Array[Double], Bool)]] = []
  let mut i = 0
  while i + 2 < data.length() {
    let kind = data[i].to_int()
    let w = data[i + 1]
    let n = data[i + 2].to_int()
    let pts = data[i + 3:i + 3 + 2 * n].to_owned().map(fn(v) { v * k })
    i = i + 3 + 2 * n
    if kind == 2 {
      if w > 0.0 || fills.length() == 0 {
        fills.push([(pts, true)])
      } else {
        fills[fills.length() - 1].push((pts, true))
      }
    } else {
      match strokes.search_by(fn(s) { s.0 == w }) {
        Some(j) => strokes[j].1.push((pts, kind == 1))
        None => strokes.push((w, [(pts, kind == 1)]))
      }
    }
  }
  let out : Array[@ui.Shape] = []
  for f in fills {
    out.push(@ui.shape_of(f, fill=color))
  }
  let width_k = stroke_k(k)
  for s in strokes {
    out.push(@ui.shape_of(s.1, stroke=color, width=s.0 * width_k))
  }
  out
}

///|
/// What is at work steps round: eight, the brightest a step further every 100 ms,
/// the others fading behind it. It steps, it does not turn: a frame for each step, none between, on the clock every
/// resident decoration steps on (@ui.cycle_step_ms).
pub let spoke_step_ms : Double = @ui.cycle_step_ms

///|
/// The spokes' strength from the brightest back.
// kept across runs: a table, never written
let spoke_alpha : Array[Double] = [1.0, 0.75, 0.55, 0.42, 0.32, 0.25, 0.2, 0.2]

///|
/// What progress_ring draws, `size` across: its track and as much of its ring as `part` says, in `color` (a node's
/// shapes: tool_node's ring while what it does goes on).
pub fn ring_shapes(size : Double, part : Double, color : Int64) -> Array[@ui.Shape] {
  let share = if part < 0.0 { 0.0 } else if part > 1.0 { 1.0 } else { part }
  let r = 8.5 * size / 24.0
  let width = 1.75 * size / 24.0
  let mid = size / 2.0
  let pi = 3.141592653589793
  let circle = fn(from : Double, to : Double, n : Int) -> Array[Double] {
    let pts = []
    for i in 0..=n {
      let a = from + (to - from) * i.to_double() / n.to_double()
      pts.push(mid + r * @dmath.cos(a))
      pts.push(mid + r * @dmath.sin(a))
    }
    pts
  }
  let track = (color & 0xFFFFFF00L) | ((color & 0xFFL).to_double() * 0.18).round().to_int64()
  let shapes = [@ui.shape_of([(circle(0.0, 2.0 * pi, 48), true)], stroke=track, width~)]
  if share > 0.0 {
    let from = -0.5 * pi
    shapes.push(
      @ui.shape_of([(circle(from, from + share * 2.0 * pi, (48.0 * share).ceil().to_int()), false)], stroke=color, width~),
    )
  }
  shapes
}
