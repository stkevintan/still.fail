///|
/// A host whose glyphs are 60 pixels square, its atlas 1024 a side (four plots of eight shelves of eight of them):
/// each UTF-16 unit a cluster, keyed by its code. What it is asked to draw noted, and which glyph it was told to put
/// where last.
priv struct SquareHost {
  drawn : Array[Int]
  put : Map[(Int, Int), Int]
}

///|
fn SquareHost::as_host(self : SquareHost) -> @hostapi.Host {
  let h = @hostapi.Host::noop()
  h.font_metrics = fn(size, _, _, out) {
    out[0] = size * 0.75
    out[1] = size * 0.25
    out[2] = size * 1.25
  }
  h.shape = fn(text, _, _, _, out) {
    let n = text.length()
    for i in 0..<n {
      out[i * 4] = i.to_double()
      out[i * 4 + 1] = 1.0
      out[i * 4 + 2] = 7.0
      out[i * 4 + 3] = text.at(i).to_int().to_double()
    }
    n
  }
  h.text_key = fn(text, _, _, _) { text.at(0).to_int() }
  h.glyph = fn(key, out) {
    self.drawn.push(key)
    out[0] = 0.0
    out[1] = 0.0
    out[2] = square_glyph
    out[3] = square_glyph
    out[4] = 0.0
    out[5] = -square_glyph
    out[6] = 0.0
  }
  h.glyph_put = fn(key, x, y) { self.put[(x, y)] = key }
  h.atlas_size = fn(colour) { if colour { 0 } else { 1024 } }
  h
}

///|
/// A glyph's side in points: 60 pixels at the Tester's scale (1).
let square_glyph : Double = 60.0

///|
test "words scrolled through, more than the atlas holds: what stays on the screen is drawn once, every glyph from where it was put" {
  let host = SquareHost::{ drawn: [], put: {} }
  let words = Ref("")
  let t = @ui.Tester::new(
    fn(c) { c.text(words.val, wrap=false) |> ignore },
    w=4000.0,
    scale=1.0,
    live={ host: host.as_host(), turn: fn() {  } },
  )
  // "AB" on the screen all along, 30 words of its own beside it on each page: 362 glyphs in all, the atlas 256
  for page in 0..<12 {
    let codes = ['A'.to_int(), 'B'.to_int()]
    codes.append(Array::makei(30, fn(i) { 0x4E00 + page * 30 + i }))
    let line = StringBuilder()
    for code in codes {
      line.write_char(Int::unsafe_to_char(code))
    }
    words.val = line.to_string()
    t.draw()
    // every glyph drawn from the place the host last put that glyph in, none from another's
    let (inst, n, _) = t.presented()
    let from : Array[Int] = []
    for k in 0..<n {
      if inst[k * glyphs_inst + 5] == 1.0 {
        let at = (inst[k * glyphs_inst + 12].to_int(), inst[k * glyphs_inst + 13].to_int())
        from.push(host.put.get(at).unwrap_or(-1))
      }
    }
    from.sort()
    codes.sort()
    assert_eq(from, codes)
  }
  // what stayed was drawn once, the first time it showed
  assert_eq(host.drawn.filter(fn(k) { k == 'A'.to_int() || k == 'B'.to_int() }).length(), 2)
}

///|
/// The words of these codes, and which glyphs what was drawn of them drew from, in order of code.
fn square_words(codes : Array[Int]) -> String {
  let line = StringBuilder()
  for code in codes {
    line.write_char(Int::unsafe_to_char(code))
  }
  line.to_string()
}

///|
fn square_drawn_from(t : @ui.Tester, host : SquareHost) -> Array[Int] {
  let (inst, n, _) = t.presented()
  let from : Array[Int] = []
  for k in 0..<n {
    if inst[k * glyphs_inst + 5] == 1.0 {
      let at = (inst[k * glyphs_inst + 12].to_int(), inst[k * glyphs_inst + 13].to_int())
      from.push(host.put.get(at).unwrap_or(-1))
    }
  }
  from.sort()
  from
}

///|
test "a glyph of what is on the screen on every shelf of a full atlas: a new word has its glyph by the next frame" {
  let host = SquareHost::{ drawn: [], put: {} }
  let words = Ref(square_words(Array::makei(256, fn(i) { 0x4E00 + i })))
  let t = @ui.Tester::new(
    fn(c) { c.text(words.val, wrap=false) |> ignore },
    w=4000.0,
    scale=1.0,
    live={ host: host.as_host(), turn: fn() {  } },
  )
  // the atlas full, its 32 shelves of eight each: then one glyph from each with a new one after them
  t.draw()
  let codes = Array::makei(32, fn(i) { 0x4E00 + i * 8 })
  codes.push(0x5E00)
  words.val = square_words(codes)
  t.draw()
  t.draw()
  assert_eq(square_drawn_from(t, host), codes)
  // and it stays, drawn no more
  let drawn = host.drawn.length()
  t.draw()
  assert_eq(square_drawn_from(t, host), codes)
  assert_eq(host.drawn.length(), drawn)
}

///|
test "more on the screen than a whole atlas holds: started over once, not every frame" {
  let host = SquareHost::{ drawn: [], put: {} }
  let t = @ui.Tester::new(
    fn(c) { c.text(square_words(Array::makei(257, fn(i) { 0x4E00 + i })), wrap=false) |> ignore },
    w=4000.0,
    scale=1.0,
    live={ host: host.as_host(), turn: fn() {  } },
  )
  t.draw()
  t.draw()
  t.draw()
  // from here only the one with no room is asked for, each frame
  let drawn = host.drawn.length()
  t.draw()
  t.draw()
  assert_eq(host.drawn.length(), drawn + 2)
  assert_eq(square_drawn_from(t, host).length(), 256)
}

///|
test "words scrolled through, a glyph of each page kept on the screen: none drawn twice, the atlas never started over" {
  // pages of 32 words of their own, the first of each staying on the screen under the next ones: glyphs of what is
  // on the screen come to lie in every stretch of the atlas, as a screen of Chinese scrolled through does (were a plot
  // emptied only whole, each holding two pages: past the eighth every plot had one on the screen, none could be
  // emptied, and the atlas started over, drawing them all again)
  let host = SquareHost::{ drawn: [], put: {} }
  let words = Ref("")
  let t = @ui.Tester::new(
    fn(c) { c.text(words.val, wrap=false) |> ignore },
    w=4000.0,
    scale=1.0,
    live={ host: host.as_host(), turn: fn() {  } },
  )
  let stay : Array[Int] = []
  for page in 0..<16 {
    let codes = Array::makei(32, fn(i) { 0x4E00 + page * 32 + i })
    codes.append(stay)
    words.val = square_words(codes)
    t.draw()
    codes.sort()
    assert_eq(square_drawn_from(t, host), codes)
    stay.push(0x4E00 + page * 32)
  }
  // each drawn once, the first time it showed
  let once : Map[Int, Bool] = Map([])
  for k in host.drawn {
    assert_true(!once.contains(k), msg="\{k} drawn again")
    once[k] = true
  }
  assert_eq(host.drawn.length(), 16 * 32)
}

///|
/// The numbers of an instance (scene.mbt).
let glyphs_inst = 60
