// A shot taken at pixels a point of its own (Ctx::take_shot `scale`): drawn by the host at those, whatever the
// window's, its words' glyphs made by the host that much larger.

///|
/// A host whose glyphs say the size they are made in: each UTF-16 unit a cluster, keyed by its code and its size (in
/// tenths, the last three digits), half as wide as it is high. Where it was told to put each glyph noted, and the
/// pictures it was asked to draw apart (their pixels a point, sizes and instances).
priv struct ZoomHost {
  put : Map[(Int, Int), Int]
  drawn : Array[(Double, Int, Int, Array[Double])]
}

///|
fn ZoomHost::as_host(self : ZoomHost) -> @hostapi.Host {
  let h = @hostapi.Host::noop()
  h.font_metrics = fn(size, _, _, out) {
    out[0] = size * 0.75
    out[1] = size * 0.25
    out[2] = size * 1.25
  }
  h.shape = fn(text, size, _, _, out) {
    let n = text.length()
    for i in 0..<n {
      out[i * 4] = i.to_double()
      out[i * 4 + 1] = 1.0
      out[i * 4 + 2] = size * 0.5
      out[i * 4 + 3] = (text.at(i).to_int() * 1000 + (size * 10.0).round().to_int()).to_double()
    }
    n
  }
  h.glyph = fn(key, out) {
    let size = (key % 1000).to_double() / 10.0
    out[0] = 0.0
    out[1] = 0.0
    out[2] = size * 0.5
    out[3] = size
    out[4] = 0.0
    out[5] = -size * 0.75
    out[6] = 0.0
  }
  h.glyph_put = fn(key, x, y) { self.put[(x, y)] = key }
  h.atlas_size = fn(colour) { if colour { 0 } else { 1024 } }
  h.drawn_pixels_of = fn(inst, count, _, _, _, scale, w, hh, out) {
    self.drawn.push((scale, w, hh, Array::makei(count * zoom_inst, fn(i) { inst[i] })))
    for i in 0..<(w * hh * 4) {
      out[i] = b'\x00'
    }
    true
  }
  h
}

///|
/// The numbers of an instance (scene.mbt).
let zoom_inst = 60

///|
/// The glyphs instances `inst` draw (`count` of them): the size each was made in (by its key, where `host` put it),
/// how wide it is drawn (points) and how wide it is in the atlas (pixels).
fn zoom_glyphs(host : ZoomHost, inst : Array[Double], count : Int) -> Array[(Double, Double, Double)] {
  let out = []
  for k in 0..<count {
    let b = k * zoom_inst
    if inst[b + 5] == 1.0 {
      let key = host.put.get((inst[b + 12].to_int(), inst[b + 13].to_int())).unwrap_or(-1)
      out.push(((key % 1000).to_double() / 10.0, inst[b + 2], inst[b + 14]))
    }
  }
  out
}

///|
test "a shot taken at 3 pixels a point in a window of 2: drawn at 3 into a picture of its own, its words' glyphs made half as large again, drawn as large as on the screen" {
  let host = ZoomHost::{ put: {}, drawn: [] }
  let take = Ref(false)
  let got : Ref[Bytes?] = Ref(None)
  let t = @ui.Tester::new(
    fn(c) {
      c.text("Ab", size=16.0, wrap=false) |> ignore
      if take.val {
        take.val = false
        c.take_shot("sharp", fn(png) { got.val = png }, scale=3.0)
      }
      c.shot("sharp", 300.0, fn() {
        c.box(w=Fill(1.0), h=Px(40.0), fn() { c.text("Ab", size=16.0, wrap=false) |> ignore }) |> ignore
      })
    },
    w=200.0,
    h=120.0,
    scale=2.0,
    live={ host: host.as_host(), turn: fn() {  } },
  )
  // on the screen: glyphs made at its size, drawn 8 wide, 16 pixels of them in the atlas
  let (inst, n, _) = t.presented()
  let screen = zoom_glyphs(host, Array::makei(n * zoom_inst, fn(i) { inst[i] }), n)
  assert_eq(screen, [(16.0, 8.0, 16.0), (16.0, 8.0, 16.0)])
  take.val = true
  t.draw()
  // the shot, wider than the window: 300 × 40 points at 3 pixels a point, in one picture of its own
  assert_eq(host.drawn.length(), 1)
  let (scale, w, h, shot) = host.drawn[0]
  assert_eq((scale, w, h), (3.0, 900, 120))
  // its glyphs made at 24 (16 × 3 / 2), as many pixels as 8 points at 3, drawn 8 wide still
  assert_eq(zoom_glyphs(host, shot, shot.length() / zoom_inst), [(24.0, 8.0, 24.0), (24.0, 8.0, 24.0)])
  // and its PNG that size
  let png = got.val.unwrap().to_array()
  assert_eq((png_be32(png, 16), png_be32(png, 20)), (900, 120))
}
