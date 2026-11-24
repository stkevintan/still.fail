// App-registered vector drawables and station glyphs (register_drawables / register_station_glyphs): mbui's
// @pixels.Vector, drawn by the GPU as shapes (@ui.vector_shapes) at the size they show at, or made into pixels on the
// CPU (@pixels.Vector::rgba) for a picture to hand on.

///|
/// App-registered vector drawables (registered once by the host app via `register_drawables`).
// kept across runs: registered once by the host app, immutable lookup table
let drawables : Ref[Map[String, @pixels.Vector]] = Ref(Map([]))

///|
/// App-registered station glyph path specs (registered once by the host app via `register_station_glyphs`).
// kept across runs: registered once by the host app, immutable lookup table
let station_glyphs : Ref[Map[String, String]] = Ref(Map([]))

///|
/// Register the host app's vector drawables (brand marks, illustrations, etc.) for `drawable_node` / `drawable_vector`.
pub fn register_drawables(items : Map[String, @pixels.Vector]) -> Unit {
  drawables.val = items
}

///|
/// Register the host app's station glyph definitions (`"emoji|line;line|dot;dot"`) for `station_mark_node`.
pub fn register_station_glyphs(items : Map[String, String]) -> Unit {
  station_glyphs.val = items
  glyphs_read.clear()
}

///|
/// The picture `name` drawn `px` pixels wide (as tall as it is for that), in its own colours or all in `tint`: its
/// width, height and pixels (RGBA, straight, rows from the top), to make another picture with; None when there is no
/// such picture.
pub fn drawable_pixels(name : String, px : Int, tint? : Int64) -> (Int, Int, FixedArray[Byte])? {
  match drawables.val.get(name) {
    Some(d) => {
      let ph = (px.to_double() * d.h / d.w).round().to_int()
      let ph = if ph < 1 { 1 } else { ph }
      Some((px, ph, d.rgba(px, ph, tint?=tint)))
    }
    None => None
  }
}

///|
/// Whether the app has the picture `name` (its drawable's name: maker_openai,
/// illus_sign_in…).
pub fn has_drawable(name : String) -> Bool {
  drawables.val.contains(name)
}

///|
/// The picture `name` drawn `w` wide (as tall as it is for that), in its own
/// colours (a maker's mark, an illustration: their colours asked no contrast,
/// @ui's own_colours) or all in `tint`.
/// How tall drawable `name` is drawn `w` wide (`drawable`'s; as wide as tall when there is none so named).
pub fn drawable_height(name : String, w : Double) -> Double {
  match drawables.val.get(name) {
    Some(d) => w * d.h / d.w
    None => w
  }
}

///|
/// Drawable `name`'s picture (None: there is none so named), for a node of the window's tree to draw (View::picture).
pub fn drawable_vector(name : String) -> @pixels.Vector? {
  drawables.val.get(name)
}

///|
/// Marks drawn in one colour, the page's ink; the others in
/// their own.
let mono_makers : Array[String] = [
  "anthropic", "openai", "kimi", "xai", "mistral", "xiaomi", "ant-ling", "openrouter", "command-code", "open-design",
  "vercel", "cloudflare", "azure", "groq", "together", "fireworks", "cerebras", "huggingface",
  "nvidia", "baseten", "dsh", "cursor", "devin", "hermes", "pi", "copilot", "meta", "stepfun", "tencent",
  "meituan",
]

///|
/// The tools' marks drawn in the page's ink (black ones: white in the dark).
let ink_tools : Array[String] = ["github", "cursor", "vercel", "openai", "devin"]

///|
/// The mark of where a chat came from, by the core's originKind: Feishu's, Comma's for a Comma
/// connect's, else Slack's.
pub fn origin_mark_name(kind : String) -> String {
  match kind {
    "feishu" => "feishu"
    "comma" => "comma"
    "group" => "group"
    _ => "slack"
  }
}

///|
/// The station glyphs' colours a station may give its glyph (glyph:<name>:<colour>), light and dark.
pub fn glyph_color(name : String, dark : Bool) -> Int64? {
  let light = match name {
    "red" => 0xBC4945FFL
    "orange" => 0xB75400FFL
    "amber" => 0xA16700FFL
    "green" => 0x0E8C41FFL
    "teal" => 0x008A8DFFL
    "blue" => 0x2D74CAFFL
    "purple" => 0x835CBEFFL
    "pink" => 0xB24981FFL
    _ => return None
  }
  if !dark {
    return Some(light)
  }
  Some(
    match name {
      "red" => 0xFB9890FFL
      "orange" => 0xF5A06FFFL
      "amber" => 0xE0AE57FFL
      "green" => 0x7CCD8EFFL
      "teal" => 0x3BCFCFFFL
      "blue" => 0x82BAFFFFL
      "purple" => 0xC3A5F9FFL
      _ => 0xF197C2FFL
    },
  )
}

///|
/// A picture put up by its address (on the page's time on top `stint`: Ctx::page_stint) as an image's key once it is
/// here ("" until then): the app's (its core's `picture`), said as it starts; until then the address itself, which
/// the host loads.
// kept across runs: the app says it as its view is built, the same function every run
pub let picture_of : Ref[(String, Int) -> String] = Ref(fn(url, _) { url })

///|
/// A picture given inline (a data URL: a station's icon put up, a web page's icon and picture in a link's card), as an
/// image of the app's own to draw by its key, made once; "" for what is no data URL (an address, drawn as it is).
pub fn data_image(url : String) -> String {
  guard url.has_prefix("data:image/") else { return "" }
  match url.find("base64,") {
    Some(i) => {
      // (named as the stations' were before: what is drawn is said by its key)
      let key = "mem:sf/station/\{url.length()}/\{@ui.stable_hash(url)}"
      data_images_made.ask(key, fn() { @ui.add_image(key, @codec.from_base64(url.exact_view(start=i + 7).to_owned())) })
      key
    }
    None => ""
  }
}

///|
/// The pictures given inline kept (MadeImages): every station's icon and every link's card's of a run many times over.
// kept across runs: let go of as a run begins (on_reset)
let data_images_made : MadeImages = MadeImages::new(128)

///|
fn init {
  @ui.on_reset(fn() { data_images_made.clear() })
}

///|
/// Whether a station has anything to be shown by (`station_mark_node` draws
/// nothing for it otherwise).
pub fn has_station_mark(emoji : String, icon : String) -> Bool {
  emoji != "" || icon != ""
}

///|
/// How far the app's own face (Inter 4.001, the wide frame's words with none chosen: sfbase's inter_face.mbt) reaches
/// above and below its baseline, shares of its size (its 1984 and 494 of 2048): where a station's emoji stands in its
/// line.
// kept across runs: a value (no field of it changes)
let mark_em : (Double, Double) = (1984.0 / 2048.0, 494.0 / 2048.0)

///|
/// A workspace's letter's square: what it holds in its middle.
// kept across runs: a value (no field of it changes)
let workspace_badge_tile : @ui.Style = @ui.css("align=ACenter justify=JCenter")

///|
/// Its letter: a meta's size, semibold, muted, on one line.
// kept across runs: a value (no field of it changes)
let workspace_badge_letter : @ui.TextStyle = @ui.text_style(size=Meta, leading=Font, weight=Semibold, color=Muted, wrap=false)

///|
fn imin(a : Int, b : Int) -> Int {
  if a < b {
    a
  } else {
    b
  }
}

///|
/// Station glyph `name`'s lines and dots, from its text registered via `register_station_glyphs`
/// ("emoji|line;line|dot;dot"), read the first time it is asked for.
fn glyph_paths(name : String) -> (Array[String], Array[String])? {
  if glyphs_read.get(name) is Some(g) {
    return Some(g)
  }
  guard station_glyphs.val.get(name) is Some(text) else { return None }
  let parts = text.split("|").map(fn(p) { p.to_owned() }).to_array()
  let paths = fn(i : Int) -> Array[String] {
    if i < parts.length() && parts[i] != "" {
      parts[i].split(";").map(fn(p) { p.to_owned() }).to_array()
    } else {
      []
    }
  }
  let g = (paths(1), paths(2))
  glyphs_read[name] = g
  Some(g)
}

///|
let glyphs_read : Map[String, (Array[String], Array[String])] = Map([])

///|
/// OpenCode's mark: a frame in the words' ink, half as wide as the mark and two thirds as high.
let opencode_w : Double = 0.5

///|
let opencode_h : Double = 0.6667

///|
// kept across runs: a value (no field of it changes)
let opencode_frame : @ui.Style = @ui.css("border=B1_5 border_color=Fg")

///|
/// The rings (rings') as a node of the window's tree in `parent`, `side` across, of the shares `shares` says as it
/// changes (drawn again as they come out otherwise). The node.
#callsite(autofill(loc))
pub fn rings_node(
  parent : @view.View,
  shares : () -> Array[(Double, Int64)],
  side : Double,
  track : Int64,
  most~ : Int,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(v) {
    v
    .width(Is(Some(side)))
    .height(Is(Some(side)))
    .picture(By(fn() { Some(rings_drawn(shares(), side, track, most).1) }))
    |> ignore
  })
}

///|
/// The rings' picture (rings'), and the key it is kept by.
fn rings_drawn(shares : Array[(Double, Int64)], side : Double, track : Int64, most : Int) -> (String, @pixels.Vector) {
  let mid = side / 2.0
  let n = (if most > 1 { most } else { 1 }).to_double()
  let width = mid / (n + ring_hole + ring_apart * (n - 1.0))
  let gap = width * ring_apart
  let layers : Array[@pixels.VectorPath] = []
  let keys : Array[String] = []
  for k, ring in shares {
    let (share, color) = ring
    let share = if share < 0.0 { 0.0 } else { share }
    keys.push("\{share}/\{color}")
    let r = mid - width / 2.0 - k.to_double() * (width + gap)
    if r <= 0.0 {
      break
    }
    let path = fn(d : String, stroke : Int64) -> @pixels.VectorPath {
      { d, fill: 0L, stroke, width, even_odd: false, sx: 1.0, sy: 1.0, tx: 0.0, ty: 0.0 }
    }
    // turn `t` (0 the first): its colour, deeper past the first
    let turn = fn(t : Int) -> Int64 {
      let mut keep = 1.0
      for _ in 0..<t {
        keep = keep * ring_turn_keep
      }
      mix(color, keep, 0x000000FFL)
    }
    let circle = "M \{mid - r} \{mid} A \{r} \{r} 0 1 1 \{mid + r} \{mid} A \{r} \{r} 0 1 1 \{mid - r} \{mid}"
    layers.push(path(circle, (color & 0xFFFFFF00L) | (track & 0xFFL)))
    let whole = share.floor()
    let rest = share - whole
    if whole >= 1.0 {
      layers.push(path(circle, turn(whole.to_int() - 1)))
    }
    if rest > 0.0 {
      let a = rest * 2.0 * @math.PI
      let (x, y) = (mid + r * @dmath.sin(a), mid - r * @dmath.cos(a))
      let large = if rest > 0.5 { 1 } else { 0 }
      layers.push(path("M \{mid} \{mid - r} A \{r} \{r} 0 \{large} 1 \{x} \{y}", turn(whole.to_int())))
    }
  }
  ("rings/\{side}/\{width}/\{gap}/\{track}/" + keys.join(","), { w: side, h: side, layers })
}

///|
/// The hole in the middle of rings (rings): round as far as a ring is wide (Activity's: three rings, the hole as wide
/// as one).
let ring_hole : Double = 1.0

///|
/// How far apart rings are (rings): this much of one's width.
let ring_apart : Double = 0.2

