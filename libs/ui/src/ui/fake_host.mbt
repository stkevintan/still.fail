// The Tester's fake host as mbui/hostapi's `Host` (Tester::new sets it): every answer a test's host gives, to the
// framework (hostcall.mbt, hostread.mbt, ctx.mbt…: each asks @hostapi, whoever the host is) and to the app asking its
// host directly (@hostapi.log, @hostapi.decode_charset…) alike. What it does not answer, as a host with nothing for it
// answers (hostapi's defaults). A test's program has no other host: it links no host's code.

///|
/// A package handed to the system's installer: kept by its name (Tester::installs).
fn FakeHost::install_package(self : FakeHost, name : String, _ : Bytes) -> Unit {
  self.installs.push(name)
}

///|
fn FakeHost::window_show(self : FakeHost) -> Unit {
  self.window_shows = self.window_shows + 1
}

///|
fn FakeHost::auto_launch(self : FakeHost) -> Bool {
  self.auto_launch
}

///|
fn FakeHost::set_auto_launch(self : FakeHost, enabled : Bool) -> Bool {
  self.auto_launch = enabled
  true
}

///|
fn FakeHost::hotkey_set(self : FakeHost, id : String, accel : String) -> Bool {
  if id == "" || accel == "" {
    return false
  }
  self.hotkeys[id] = accel
  true
}

///|
fn FakeHost::hotkey_clear(self : FakeHost, id : String) -> Unit {
  self.hotkeys.remove(id)
}

///|
/// The person's setting for motion (Tester::set_reduce_motion).
fn FakeHost::reduce_motion(self : FakeHost) -> Bool {
  self.reduce_motion
}

///|
fn FakeHost::display_hz(self : FakeHost) -> Double {
  self.display_hz
}

///|
/// Scripted system input (drive.mbt): tap a matching notification (6), look for one (7), resize the next frame (8), or
/// let files go on the window as a file manager does (13: fake_drop_drive).
fn FakeHost::drive(self : FakeHost, kind : Int, text : String) -> Bool {
  if kind == 13 {
    return fake_drop_drive(self, text)
  }
  if kind == 6 || kind == 7 {
    guard self.find_notice(text) is Some(index) else { return false }
    if kind == 6 {
      self.open_notice(index)
      self.wants = true
    }
    return true
  }
  if kind != 8 {
    return false
  }
  let wh = text.split("x").map(fn(v) { number(v.to_owned()) }).to_array()
  if wh.length() < 2 {
    return false
  }
  tester_size.val = Some((wh[0], wh[1]))
  true
}

///|
/// A script's `drop X Y PATH|PATH…` (drive.mbt, @hostapi.drive 13): those files let go at (X, Y) of the window with their
/// paths, as Tester::drop_files lets them go; what they hold is what the script's `picks` said, or, where it said none,
/// a file each of a few bytes named as its path ends (a folder, ending in "/", empty). False where the step says no
/// place.
fn fake_drop_drive(f : FakeHost, text : String) -> Bool {
  guard text.find(" ") is Some(i) else { return false }
  let after_x = text[i + 1:].to_owned()
  let (y_said, rest) = match after_x.find(" ") {
    Some(k) => (after_x[:k].to_owned(), after_x[k + 1:].to_owned())
    None => (after_x, "")
  }
  let x = number(text[:i].to_owned())
  let y = number(y_said)
  let paths = rest.split("|").filter(fn(p) { p != "" }).map(fn(p) { p.to_owned() }).to_array()
  if f.picks.is_empty() {
    for p in paths {
      let dir = p.has_suffix("/")
      let base = if dir { p[:p.length() - 1].to_owned() } else { p }
      let name = match base.rev_find("/") {
        Some(i) => base[i + 1:].to_owned()
        None => base
      }
      let bytes = if dir { b"" } else { b"file" }
      f.picks.push({ name: if dir { name + "/" } else { name }, bytes, held: 0, size: bytes.length().to_double(), src: "" })
    }
  }
  f.pick_asks.push({ kind: Files, said: false, taken: false })
  let id = f.pick_asks.length()
  if !f.picks_by_hand {
    f.due(f.time, "files dropped", fn() { fake_pick_said(f, id) })
  }
  let m : Map[String, Json] = {
    "type": Json::string("drop"),
    "x": Json::number(x),
    "y": Json::number(y),
    "pick": Json::number(id.to_double()),
  }
  if !paths.is_empty() {
    m["paths"] = Json::array(
      paths.mapi(fn(i, p) {
        let size = match f.picks.get(i) {
          Some(p) => p.size
          None => 0.0
        }
        let o : Map[String, Json] = {
          "path": Json::string(p),
          "dir": Json::boolean(p.has_suffix("/")),
          "size": Json::number(size),
        }
        Json::object(o)
      }),
    )
  }
  fake_post(f, "mbui.drop", Json::object(m).stringify(), None)
  true
}

///|
/// The app ended (a scripted run's verdict): noted on its log ("EXIT <code>").
fn FakeHost::exit(self : FakeHost, code : Int) -> Unit {
  self.logs.push("EXIT \{code}")
}

///|
/// An update asked for: kept as asked (Tester::update_asked), with the delta it was given where there was one.
fn FakeHost::update_fetch(_ : FakeHost, _ : String, _ : String, _ : Double, name : String, now : Bool, delta : String) -> Unit {
  update_asked.push(if delta == "" { "fetch \{name} \{now}" } else { "fetch \{name} \{now} delta \{delta}" })
}

///|
fn FakeHost::update_apply(_ : FakeHost, _ : String) -> Unit {
  update_asked.push("apply")
}

///|
/// How an update goes: as the test told it (Tester::tells_update).
fn FakeHost::update_state(_ : FakeHost) -> String {
  update_told.untracked()
}

// The system's pickers and the files kept on the device (@hostapi pick.mbt, keep.mbt) as a test has them: its pickers
// give what the test said (Tester::picks) at the moment each is asked, told as a host's event tells it (FakeHost::due:
// after the event that asked, before the clock moves on); what the app keeps is kept by the test (Tester::kept), from
// the frame after it was finished.

///|
priv struct FakePick {
  kind : @hostapi.PickKind
  /// its answer told (the host's event said): what the pickers give is there to take from then
  mut said : Bool
  mut taken : Bool
}

///|
priv struct FakeKeep {
  name : String
  mime : String
  way : @hostapi.KeepWay
  data : Array[Byte]
  /// the frame it was finished in (-1: not yet): kept from the next on; let go of
  mut finished : Int
  mut ended : Bool
}

///|
/// An ask of its pickers (its id, from 1: the ask's place; Tester::drop_files's too).
fn FakeHost::pk_start(self : FakeHost, kind : Int) -> Int {
  let kind : @hostapi.PickKind = match kind & 15 {
    1 => Photos
    3 => Camera
    _ => Files
  }
  self.pick_asks.push({ kind, said: false, taken: false })
  let id = self.pick_asks.length()
  // (answered at the moment it is asked, the host's event after the one that asked; where the test answers its pickers
  // itself, as it says: Tester::pick_answer)
  if !self.picks_by_hand {
    self.due(self.time, "a pick answered", fn() { fake_pick_said(self, id) })
  }
  id
}

///|
fn FakeHost::pk_photo(self : FakeHost, _ : String) -> Int {
  self.pk_start(1)
}

///|
/// Ask `id` answered with what the pickers give: told as a host's event tells it (on_outside, MB_OUTSIDE_PICK).
fn fake_pick_said(f : FakeHost, id : Int) -> Unit {
  guard f.pick_asks.get(id - 1) is Some(a) && !a.said else { return }
  a.said = true
  on_outside(outside_pick, id, 1)
}

///|
/// How ask `id` goes: 0 asking (till its answer is told: fake_pick_said), 1 answered, -1 let go of or none.
fn FakeHost::pk_state(self : FakeHost, id : Int) -> Int {
  match self.pick_asks.get(id - 1) {
    Some(a) if !a.taken => if a.said { 1 } else { 0 }
    _ => -1
  }
}

///|
fn FakeHost::pk_count(self : FakeHost, _ : Int) -> Int {
  self.picks.length()
}

///|
fn FakeHost::pk_name(self : FakeHost, _ : Int, i : Int) -> String {
  match self.picks.get(i) {
    Some(p) => p.name
    None => ""
  }
}

///|
fn FakeHost::pk_bytes(self : FakeHost, _ : Int, i : Int) -> Bytes {
  match self.picks.get(i) {
    Some(p) => p.bytes
    None => b""
  }
}

///|
fn FakeHost::pk_info(self : FakeHost, _ : Int, i : Int) -> String {
  match self.picks.get(i) {
    Some(p) => "\{p.held}\t\{p.size.to_int64()}\t\{p.src}"
    None => ""
  }
}

///|
/// An ask let go of (answered, or a drop nothing took): taken.
fn FakeHost::pk_end(self : FakeHost, id : Int) -> Unit {
  match self.pick_asks.get(id - 1) {
    Some(a) => a.taken = true
    None => ()
  }
}

///|
/// A file to keep (its id, from 1).
fn FakeHost::kp_begin(self : FakeHost, name : String, mime : String, way : Int) -> Int {
  let way : @hostapi.KeepWay = match way {
    2 => Choose
    3 => Photos
    _ => Downloads
  }
  self.keeps.push({ name, mime, way, data: [], finished: -1, ended: false })
  self.keeps.length()
}

///|
fn FakeHost::kp_append(self : FakeHost, id : Int, data : Bytes) -> Int {
  match self.keeps.get(id - 1) {
    Some(k) if k.finished < 0 && !k.ended => {
      for b in data {
        k.data.push(b)
      }
      1
    }
    _ => 0
  }
}

///|
fn FakeHost::kp_finish(self : FakeHost, id : Int) -> Unit {
  match self.keeps.get(id - 1) {
    Some(k) if k.finished < 0 => {
      k.finished = g().frame_no
      self.wants = true
    }
    _ => ()
  }
}

///|
/// How a keep stands: kept from the frame after it was finished (1), called off (2), keeping (0), none (-1).
fn FakeHost::kp_state(self : FakeHost, id : Int) -> Int {
  match self.keeps.get(id - 1) {
    Some(k) if k.ended && k.finished < 0 => 2
    Some(k) if k.finished >= 0 && g().frame_no > k.finished => 1
    Some(_) => 0
    None => -1
  }
}

///|
/// Where it was kept: where the system keeps downloads ("Download/" and its name; in MBUI_DOWNLOADS_DIR, as a
/// scripted run's host keeps there, its path).
fn FakeHost::kp_where(self : FakeHost, id : Int) -> String {
  match self.keeps.get(id - 1) {
    Some(k) =>
      match self.env.get("MBUI_DOWNLOADS_DIR").unwrap_or("") {
        "" => "Download/" + k.name
        dir => dir + "/" + k.name
      }
    None => ""
  }
}

///|
fn FakeHost::kp_end(self : FakeHost, id : Int) -> Unit {
  match self.keeps.get(id - 1) {
    Some(k) => k.ended = true
    None => ()
  }
}

///|
/// Its clock: the frames' (Tester::run_for…).
fn FakeHost::now(self : FakeHost) -> Double {
  self.time
}

///|
/// Its day: Tester::set_wall's at its clock's 0, on with its clock.
fn FakeHost::wall_ms(self : FakeHost) -> Double {
  self.wall + self.time
}

///|
/// Its day at its clock's 0 taken from `ms`, as it is (both whole ms where the test says them; its local time is
/// UTC's: utc_offset_min's default 0).
fn FakeHost::clock_at_wall(self : FakeHost, ms : Double) -> Double {
  ms - self.wall
}

///|
/// When the input event being handled happened where the test says it apart from its clock (a test's event taken
/// late: Tester::touch_at); -1, as the clock has it.
fn FakeHost::event_time(self : FakeHost) -> Double {
  self.event_at
}

///|
/// What it says the pointer's events come from (Tester::host_says_finger): 1 a finger, 0 a mouse, -1 not said.
fn FakeHost::event_finger(self : FakeHost) -> Int {
  self.event_finger
}

///|
/// How late the frame before this one reached the screen: as said for this frame (Tester::frame_late, a run's LATE
/// line), else on time.
fn FakeHost::frame_late(self : FakeHost) -> Double {
  let c = g()
  if self.late_after < 0.0 || c.clock <= self.late_after {
    return 0.0
  }
  if self.late_frame < 0 {
    self.late_frame = c.frame_no
  }
  if self.late_frame == c.frame_no {
    self.late
  } else {
    self.late_after = -1.0
    0.0
  }
}

///|
/// The system it plays (Tester::new's `platform`).
fn FakeHost::platform(self : FakeHost) -> Int {
  self.platform
}

///|
/// The system whose keys are typed (Tester::new's `keys`: by default the system it plays).
fn FakeHost::keys_platform(self : FakeHost) -> Int {
  self.keys
}

///|
fn FakeHost::request_frame(self : FakeHost) -> Unit {
  self.wants = true
  self.paced = 0.0
}

///|
/// A frame for what moves on by the clock: owed none at this moment (its time goes by run_for), counted
/// (Tester::frames_on).
fn FakeHost::request_frame_on(self : FakeHost) -> Unit {
  self.frames_on = self.frames_on + 1
  self.paced = 0.0
}

///|
/// A frame for what moves on by the clock that needs only `hz` frames a second: counted as request_frame_on's, its rate
/// told (Tester::frames_paced); its own frames are run_for's, whatever it is told.
fn FakeHost::frames_paced(self : FakeHost, hz : Double) -> Unit {
  self.frames_on = self.frames_on + 1
  self.paced = hz
}

///|
fn FakeHost::wake_after(self : FakeHost, ms : Double) -> Unit {
  if self.wake < 0.0 || self.time + ms < self.wake {
    self.wake = self.time + ms
  }
}

///|
/// Its text: a live host's (Tester::new's `live`); else a host's kept text where it has it (text_table); else its own
/// deterministic metrics.
fn FakeHost::font_metrics(self : FakeHost, size : Double, weight : Int, style : Int, out : FixedArray[Double]) -> Unit {
  if self.live is Some(l) {
    (l.host.font_metrics)(size, weight, style, out)
    return
  }
  if kept_metrics(size, weight, style, out) {
    return
  }
  out[0] = size * 0.8
  out[1] = size * 0.2
  out[2] = (size * 1.42).round()
}

///|
/// Who spaces Chinese and Japanese words: nobody where the run says MBUI_AUTOSPACE=off, else a live host's answer, else
/// the fake's own (Tester::words_spaced_here).
fn FakeHost::words_spaced(self : FakeHost) -> Int {
  // (none, as the run's own MBUI_AUTOSPACE says: a film's, its live host not asked)
  if self.env.get("MBUI_AUTOSPACE") == Some("off") {
    return @hostapi.words_spaced_none
  }
  match self.live {
    Some(l) => l.host.words_spaced()
    None => self.words_spaced
  }
}

///|
/// Fake shaping: one cluster per extended grapheme cluster, as real hosts
/// make them; Latin half an em wide (0.6 in the code face; ASCII as a real face where the test says:
/// Tester::latin_advances), everything else a full em.
///|
/// Optional counter of `FakeHost::shape` invocations for white-box tests.
// kept across runs: set and cleared within a single test
let fake_shape_calls : Ref[Int?] = Ref(None)

///|
fn FakeHost::shape(self : FakeHost, text : String, size : Double, weight : Int, style : Int, out : FixedArray[Double]) -> Int {
  match fake_shape_calls.val {
    Some(n) => fake_shape_calls.val = Some(n + 1)
    None => ()
  }
  if self.live is Some(l) {
    return (l.host.shape)(text, size, weight, style, out)
  }
  if kept_shape(text, size, weight, style, out) is Some(k) {
    return k
  }
  let n = text.length()
  let cap = out.length() / 4
  let mut i = 0
  let mut k = 0
  while i < n && k < cap {
    let c = text.at(i).to_int()
    let len = @text.next_grapheme(text, i) - i
    let mono = (style & @hostapi.style_mono) != 0
    // (a letter measured as a real face measures it: latin_advances)
    let real = match self.latin {
      Some((regular, bold)) if !mono && c >= 32 && c <= 126 =>
        Some(size * (if weight >= 600 { bold[c - 32] } else { regular[c - 32] }))
      _ => None
    }
    let adv = if c == 10 {
      0.0
    } else if real is Some(a) {
      a
    } else if self.cjk_marks && c >= 0x2010 && c <= 0x206F && (style & @hostapi.style_proportional) == 0 {
      size
    } else if c < 0x2E80 {
      if mono {
        size * 0.6
      } else {
        size * 0.5
      }
    } else {
      size
    }
    let adv = if weight >= 600 && c != 10 && real is None { adv + size * self.bold } else { adv }
    let adv = if self.ui_face != 0.0 && c != 10 && in_ui_face(style) { adv + size * self.ui_face } else { adv }
    let adv = if self.tabular != 0.0 && c >= 48 && c <= 57 && (style & @hostapi.style_tabular) != 0 {
      adv + size * self.tabular
    } else {
      adv
    }
    let adv = match self.faces_wider.get(@hostapi.face_of_style(style)) {
      Some(em) if c != 10 => adv + size * em
      _ => adv
    }
    out[k * 4] = i.to_double()
    out[k * 4 + 1] = len.to_double()
    out[k * 4 + 2] = adv
    // U+E000 plays a ligature's second letter: drawn as part of the cluster before it (unless shaped with no
    // ligatures)
    out[k * 4 + 3] = if c == 32 || c == 10 {
      -1.0
    } else if c == 0xE000 && k > 0 && (style & @hostapi.style_no_ligatures) == 0 {
      -2.0
    } else if text_table.val is Some(_) {
      (c | fake_fallback_glyph_bit).to_double()
    } else {
      c.to_double()
    }
    i = i + len
    k = k + 1
  }
  k
}

///|
/// Tag bit (bit 25, inside 0x03FFFFFF, above Unicode 0x10FFFF and KEYS_MOST=65536, below subpixel phase bits 26..27)
/// isolating FakeHost fallback glyph keys from recorded textrec glyph IDs.
let fake_fallback_glyph_bit : Int = 0x02000000

///|
/// Whether words in `style` are set in the app's words' face (face_ui) as a host sets them: one is given and the style
/// names no other (code's, the serif one, what people wrote's, one by its number).
fn in_ui_face(style : Int) -> Bool {
  face_given(@hostapi.face_ui) &&
  @hostapi.face_of_style(style) == 0 &&
  (style & (@hostapi.style_mono | @hostapi.style_serif | @hostapi.style_words)) == 0
}

///|
fn FakeHost::text_key(self : FakeHost, text : String, size : Double, weight : Int, style : Int) -> Int {
  if self.live is Some(l) {
    return (l.host.text_key)(text, size, weight, style)
  }
  match kept_key(text, size, weight, style) {
    Some(k) => k
    None =>
      if text_table.val is Some(_) {
        text.at(0).to_int() | fake_fallback_glyph_bit
      } else {
        text.at(0).to_int()
      }
  }
}

///|
/// The keys a Tester's host was asked to draw ahead (@hostapi.glyphs_ahead), in the order asked, where a test keeps
/// them (Some): it draws none ahead, each drawn as it is asked for, as ever.
// kept across runs: a test's own, set by it before it looks and put back after
let fake_ahead : Ref[Array[Int]?] = Ref(None)

///|
fn FakeHost::glyphs_ahead(self : FakeHost, keys : FixedArray[Int], n : Int) -> Unit {
  if fake_ahead.val is Some(asked) {
    for i in 0..<n {
      asked.push(keys[i])
    }
  }
  if self.live is Some(l) {
    (l.host.glyphs_ahead)(keys, n)
  }
}

///|
fn FakeHost::glyphs_ahead_able(_ : FakeHost) -> Bool {
  fake_ahead.val is Some(_)
}

///|
fn FakeHost::glyph(self : FakeHost, key : Int, out : FixedArray[Double]) -> Unit {
  if self.glyph_ms > 0.0 {
    self.time = self.time + self.glyph_ms
  }
  if self.live is Some(l) {
    (l.host.glyph)(key, out)
    return
  }
  if (key & fake_fallback_glyph_bit) == 0 && kept_glyph(key, out) {
    return
  }
  // a glyph box per cluster, so painting is exercised
  out[0] = 0.0
  out[1] = 0.0
  out[2] = self.glyph_box.0
  out[3] = self.glyph_box.1
  out[4] = 0.0
  out[5] = -10.0
  out[6] = if (key & 0x01FFFFFF) >= 0x1F000 { 1.0 } else { 0.0 }
}

///|
/// A glyph's picture put in the atlas: a live host's; the fake has no pictures.
fn FakeHost::glyph_put(self : FakeHost, key : Int, x : Int, y : Int) -> Unit {
  if self.live is Some(l) {
    (l.host.glyph_put)(key, x, y)
  }
}

///|
/// A glyph's picture given back (what words' halo is blurred from, halo.mbt): a live host's; the fake's glyph box all
/// covered, so a halo is made and drawn as a host's is.
fn FakeHost::glyph_picture(self : FakeHost, key : Int, out : FixedArray[Byte]) -> Bool {
  match self.live {
    Some(l) => (l.host.glyph_picture)(key, out)
    None => {
      out.fill(b'\xFF')
      true
    }
  }
}

///|
/// Pixels made here put in the atlas (a halo, halo.mbt): a live host's; the fake takes them, as it has no pictures.
fn FakeHost::atlas_put(self : FakeHost, x : Int, y : Int, w : Int, h : Int, px : FixedArray[Byte]) -> Bool {
  match self.live {
    Some(l) => (l.host.atlas_put)(x, y, w, h, px)
    None => true
  }
}

///|
/// The side of a fake host's atlas: the web's (its glyphs placed in it as a host's are), colour glyphs in it with the
/// others.
let fake_atlas_size : Int = 2048

///|
fn FakeHost::atlas_size(self : FakeHost, colour : Bool) -> Int {
  match self.live {
    Some(l) => (l.host.atlas_size)(colour)
    None => if colour { 0 } else { fake_atlas_size }
  }
}

///|
/// A face's file: a live host's; the fake takes any (its words measured as ever), but one the test made unreadable
/// (Tester::set_unreadable_font).
fn FakeHost::face_add(self : FakeHost, face : Int, path : String, weight : Int) -> Bool {
  match self.live {
    Some(l) => (l.host.face_add)(face, path, weight)
    None => {
      let ok = !self.unreadable_fonts.contains(path)
      if ok && self.generation_on_face_add.val {
        self.generation += 1
      }
      ok
    }
  }
}

///|
fn FakeHost::face_add_bytes(self : FakeHost, face : Int, data : Bytes, weight : Int) -> Bool {
  match self.live {
    Some(l) => (l.host.face_add_bytes)(face, data, weight)
    None => data.length() > 0
  }
}

///|
fn FakeHost::face_clear(self : FakeHost, face : Int) -> Unit {
  if self.live is Some(l) {
    (l.host.face_clear)(face)
  }
}

///|
fn FakeHost::face_add_family(self : FakeHost, face : Int, family : String) -> Bool {
  match self.live {
    Some(l) => (l.host.face_add_family)(face, family)
    None => {
      self.families_given[face] = family
      true
    }
  }
}

///|
fn FakeHost::has_local_fonts(self : FakeHost) -> Bool {
  self.local_fonts != ""
}

///|
/// The font families installed as it says them (Tester::set_local_fonts).
fn FakeHost::local_font_families(self : FakeHost) -> String {
  self.local_fonts
}

///|
fn FakeHost::face_set_ligatures(self : FakeHost, face : Int, on : Bool) -> Unit {
  self.face_ligatures[face] = on
  if self.live is Some(l) {
    (l.host.face_set_ligatures)(face, on)
  }
}

///|
fn FakeHost::set_host_autospace(self : FakeHost, on : Bool) -> Unit {
  self.host_autospace = on
  if self.live is Some(l) {
    (l.host.set_host_autospace)(on)
  }
}

///|
fn FakeHost::local_font_info(self : FakeHost) -> String {
  if self.local_fonts_info != "" {
    return self.local_fonts_info
  }
  if self.live is Some(l) {
    return (l.host.local_font_info)()
  }
  ""
}

///|
fn FakeHost::has_async_local_font_info(self : FakeHost) -> Bool {
  if self.local_fonts_info != "" {
    return true
  }
  self.local_fonts == ""
}

///|
/// Its glyphs' generation (each ask counted: Tester's): a live host's, else its own.
fn FakeHost::atlas_generation(self : FakeHost) -> Int {
  self.generation_asks += 1
  match self.live {
    Some(l) => (l.host.atlas_generation)()
    None => self.generation
  }
}

///|
/// The system asks for less transparency (Tester::set_reduce_transparency).
fn FakeHost::reduce_transparency(self : FakeHost) -> Bool {
  self.reduce_transparency
}

///|
/// The system asks for more contrast (Tester::set_increase_contrast).
fn FakeHost::increase_contrast(self : FakeHost) -> Bool {
  self.increase_contrast
}

///|
/// The system slows the device down for its heat (Tester::set_thermal_throttled).
fn FakeHost::thermal_throttled(self : FakeHost) -> Bool {
  self.thermal_throttled
}

///|
/// Its performance record (Tester::set_perf): -1 none kept here, 0 off, 1 on.
fn FakeHost::perf_state(self : FakeHost) -> Int {
  self.perf
}

///|
fn FakeHost::set_perf(self : FakeHost, on : Bool) -> Unit {
  if self.perf >= 0 {
    self.perf_sets.push(on)
    self.perf = if on { 1 } else { 0 }
  }
}

///|
fn FakeHost::perf_line(self : FakeHost, line : String) -> Unit {
  if self.perf == 1 {
    self.perf_lines.push(line)
  }
}

///|
fn FakeHost::perf_where(self : FakeHost) -> String {
  if self.perf >= 0 {
    "Documents/perf"
  } else {
    ""
  }
}

///|
fn FakeHost::reveal_file(self : FakeHost, path : String, go : Bool) -> Bool {
  if !self.reveals {
    return false
  }
  if go {
    self.revealed.push(path)
  }
  true
}

///|
fn FakeHost::perf_open(self : FakeHost, go : Bool) -> Bool {
  if !self.perf_opens {
    return false
  }
  if go {
    self.perf_opened += 1
  }
  true
}

///|
fn FakeHost::perf_size(self : FakeHost) -> Double {
  // (what the lines weigh is the real host's, whose times are not a test's: as the test says, Tester::set_perf_size)
  self.perf_bytes
}

///|
/// The field as it was told (its input method's), counted.
fn FakeHost::set_ime(self : FakeHost, active : Bool, x : Double, y : Double, w : Double, h : Double, text : String, a : Int, b : Int) -> Unit {
  self.ime_active = active
  self.ime_text = text
  self.ime_sel = (a, b)
  self.ime_rect = (x, y, w, h)
  self.ime_told = self.ime_told + 1
}

///|
fn FakeHost::text_menu(self : FakeHost, shown : Bool, x : Double, y : Double, w : Double, h : Double, can : Int) -> Unit {
  self.text_menu = (shown, x, y, w, h, can)
}

///|
fn FakeHost::text_menu_own(self : FakeHost, words : String) -> Unit {
  self.text_menu_own = words
}

///|
fn FakeHost::edit_can(self : FakeHost, can : Int) -> Unit {
  self.edit_can = can
}

///|
fn FakeHost::clipboard_set(self : FakeHost, s : String) -> Unit {
  self.clipboard = s
  self.clipboard_secret = -1.0
  self.clipboard_html = ""
}

///|
/// Words on the clipboard with their HTML (Tester::clipboard, Tester::clipboard_html).
fn FakeHost::clipboard_set_html(self : FakeHost, text : String, html : String) -> Unit {
  self.clipboard = text
  self.clipboard_secret = -1.0
  self.clipboard_html = html
}

///|
/// A word's bounds: a live host's; under a host's kept text, the host's word as it said it (a word it did not say: the
/// test is told, Tester::text_missing, and gets none of its own made up in its place); with no kept text, none.
fn FakeHost::word_at(self : FakeHost, text : String, off : Int) -> (Int, Int) {
  if self.live is Some(l) {
    return (l.host.word_at)(text, off)
  }
  match text_table.val {
    Some(_) => {
      let head : Json = [Json::string(text), Json::number(off.to_double())]
      match kept_answer("wa", head) {
        Some(Array([Number(s, ..), Number(e, ..), ..])) => (s.to_int(), e.to_int())
        _ => (-1, -1)
      }
    }
    None => (-1, -1)
  }
}

///|
/// A URL handed to the system: kept (Tester::opened).
fn FakeHost::open_url(self : FakeHost, url : String) -> Bool {
  self.opened.push(url)
  true
}

///|
/// A page in a browser's tab: kept as one handed to the system (Tester::opened).
fn FakeHost::open_tab(self : FakeHost, url : String) -> Bool {
  self.opened.push(url)
  true
}

///|
fn FakeHost::back_enabled(self : FakeHost, on : Bool) -> Unit {
  self.back_on = on
}

///|
fn FakeHost::wheel_kept(self : FakeHost, kept : Bool) -> Unit {
  self.wheel_kept = kept
}

///|
/// Something reading the widgets out (Tester's a11y_on).
fn FakeHost::a11y_on(self : FakeHost) -> Bool {
  self.a11y
}

///|
fn FakeHost::a11y_tree(self : FakeHost, tree : String) -> Unit {
  self.a11y_said = tree
  // (kept as a host keeps it: A11yMirror::apply)
  match a11y_update_read(tree) {
    Some((full, focus, told)) => self.a11y_told.apply(full, focus, told) |> ignore
    None => ()
  }
}

///|
fn FakeHost::log(self : FakeHost, s : String) -> Unit {
  self.logs.push(s)
}

///|
/// A picture by its source: a live host's decode (its sizes as that host has them); else as the host decoded it, when
/// kept with the text; else as the test made it up (Tester::new's images), one it does not know failed at once.
fn FakeHost::image_load(self : FakeHost, src : String, max_px : Int) -> Int {
  self.image_loads.push((src, max_px))
  let head : Json = [Json::string(src), Json::number(max_px.to_double())]
  let id = match self.live {
    Some(l) => live_image(self, l, (l.host.image_load)(src, max_px), { "is": head })
    None => {
      let id = match (self.image_sizes.get(src), text_table.val) {
        (None, Some(_)) =>
          match kept_sizes(kept_answer("is", head)) {
            Some((w, h, ow, oh)) => fake_image_sized(self, w, h, ow, oh)
            None => fake_image(self, 0, 0, max_px)
          }
        (sized, _) => {
          let (w, h) = sized.unwrap_or((0, 0))
          fake_image(self, w, h, max_px)
        }
      }
      match self.pixels_of_src.get(src) {
        Some(px) => self.pixels_of[id] = px
        None => ()
      }
      id
    }
  }
  // (its source kept, a failed one's too: Tester::image_src describes the same id as a live host's)
  self.image_srcs[id] = src
  // (said to take a while: done that long after it is asked for, Tester::decode_after)
  match self.decode_after.get(src) {
    Some(ms) => self.decode_due[id] = self.time + ms
    None => ()
  }
  id
}

///|
/// Bytes decoded: a live host's decode; else as the host decoded these bytes, when kept with the text; else a made-up
/// 400 × 300.
fn FakeHost::image_load_bytes(self : FakeHost, data : Bytes, max_px : Int) -> Int {
  self.image_loads.push(("bytes:\{data.length()}", max_px))
  let head = image_bytes_head(data, max_px)
  let id = match self.live {
    Some(l) => live_image(self, l, (l.host.image_load_bytes)(data, max_px), { "ib": head })
    None =>
      match (text_table.val, kept_sizes(kept_answer("ib", head))) {
        (Some(_), Some((w, h, ow, oh))) => fake_image_sized(self, w, h, ow, oh)
        _ => fake_image(self, 400, 300, max_px)
      }
  }
  // (said to take a while: done that long after it is asked for, Tester::decode_bytes_after)
  match fake_decode_bytes_after.val.search_by(fn(d) { d.0 == data }) {
    Some(i) => self.decode_due[id] = self.time + fake_decode_bytes_after.val[i].1
    None => ()
  }
  self.image_bytes[id] = data.length()
  self.image_bytes_now += data.length()
  if self.image_bytes_now > self.image_bytes_most {
    self.image_bytes_most = self.image_bytes_now
    host_image_bytes_held(self)
  }
  id
}

// What the host holds of the bytes handed over for decodes, at once (FakeHost.image_bytes): a phone's Java side kept a
// GIF's every frame's, 140 MB of a 256 MB heap, and the app was killed (#5301); the tests' every image was small and
// nothing counted what they came to. Held a file at a time, as gaps_steady.mbt's faults: the most a Tester made in a
// file has its host hold at once is at most its file's bar (`host_image_bytes_known`, given by a test package as it
// starts) and a tenth, or `host_image_bytes_free` where the file has none. The bars are what each file's Testers held
// at most when they were set (the user, 2026-11-11: 三条都加), and only fall: one brought down by a change to what is
// handed over is written down in the same change.

///|
/// What a Tester made in a file with no bar may have its host hold at once: an icon's, a few small pictures'.
let host_image_bytes_free : Int = 4096

///|
/// Each file's bar: the most bytes handed over for decodes a Tester made there may have its host hold at once.
// kept across runs: said once as a test program starts (its packages' `init`)
let host_image_bytes_bars : Map[String, Int] = Map([])

///|
/// The most bytes each file's Testers had their hosts hold so far in this run, said as it grows (motion_runs).
// kept across runs: the most of all the program's Testers, each file's said once as it grows
let host_image_bytes_most : Map[String, Int] = Map([])

///|
/// The bars of the files `bars` names, each the most bytes handed over for decodes (image_load_bytes) a Tester made
/// there may have its host hold at once, a tenth over it let by. Said by a test package as it starts (`fn init`);
/// only falls.
pub fn host_image_bytes_known(bars : Array[(String, Int)]) -> Unit {
  motion_bars_said("host_image_bytes", bars)
  for b in bars {
    host_image_bytes_bars.set(b.0, b.1)
  }
}

///|
/// Stops the test where what the host holds of the bytes handed over goes over its file's bar by more than a tenth.
fn host_image_bytes_held(f : FakeHost) -> Unit {
  let file = match f.made_at.find(":") {
    Some(i) => f.made_at.unsafe_substring(start=0, end=i)
    None => f.made_at
  }
  let bar = host_image_bytes_bars.get(file).unwrap_or(host_image_bytes_free)
  // (the most each file's Testers held, said as it grows: motion_runs, `MOTION held host_image_bytes <file> <bytes>`)
  if motion_runs() && f.image_bytes_now > host_image_bytes_most.get(file).unwrap_or(0) {
    host_image_bytes_most.set(file, f.image_bytes_now)
    println("MOTION held host_image_bytes \{file} \{f.image_bytes_now}")
  }
  if f.image_bytes_now * 10 > bar * 11 {
    @halt.saying(
      "the host holds \{f.image_bytes_now} bytes handed over for decodes at once (fake_host.mbt: host_image_bytes_known), " +
      "the Tester made at \{f.made_at}; \{file}'s bar is \{bar}" +
      (if host_image_bytes_bars.contains(file) { "" } else { " (none said: host_image_bytes_free)" }),
    )
  }
}

///|
fn FakeHost::image_info(self : FakeHost, id : Int, out : FixedArray[Double]) -> Int {
  match self.images.get(id) {
    Some(im) => {
      if im.state == 1 {
        out[0] = im.w
        out[1] = im.h
        out[2] = im.ow
        out[3] = im.oh
      }
      im.state
    }
    None => -1
  }
}

///|
/// A ready image's pixels: a live host's; else as the test made them (Tester::add_pixels), else every pixel a mid
/// grey, opaque.
fn FakeHost::image_pixels(self : FakeHost, id : Int, out : FixedArray[Byte]) -> Bool {
  match (self.live, self.live_images.get(id)) {
    (Some(l), Some(mine)) => return (l.host.image_pixels)(mine, out)
    _ => ()
  }
  match self.images.get(id) {
    Some(im) if im.state == 1 => {
      let n = im.w.to_int() * im.h.to_int() * 4
      match self.pixels_of.get(id) {
        Some(px) if px.length() == n => px.blit_to(out, len=n)
        _ =>
          for i in 0..<n {
            out[i] = if i % 4 == 3 { b'\xFF' } else { b'\x80' }
          }
      }
      true
    }
    _ => false
  }
}

///|
/// The last frame's pixels: a live host's as it drew the frame (a film's), the fake's every pixel a mid grey, opaque.
fn FakeHost::drawn_pixels(self : FakeHost, x : Int, y : Int, w : Int, h : Int, out : FixedArray[Byte]) -> Bool {
  match self.live {
    Some(l) => (l.host.drawn_pixels)(x, y, w, h, out)
    None => {
      for i in 0..<(w * h * 4) {
        out[i] = if i % 4 == 3 { b'\xFF' } else { b'\x80' }
      }
      true
    }
  }
}

///|
/// Instances never presented drawn: a live host's, its pictures that host's own as a film draws a frame (film.mbt
/// draw_frame: one it has not, nothing); the fake's every pixel a mid grey, opaque.
fn FakeHost::drawn_pixels_of(self : FakeHost, inst : FixedArray[Double], count : Int, r : Double, gg : Double, b : Double, scale : Double, w : Int, h : Int, out : FixedArray[Byte]) -> Bool {
  match self.live {
    Some(l) => {
      let len = count * inst_size
      let mine = FixedArray::make(if len > 0 { len } else { 1 }, 0.0)
      inst.blit_to(mine, len~)
      for k in 0..<count {
        let at = k * inst_size
        if mine[at + 5] == 4.0 {
          match self.live_images.get(mine[at + 20].to_int()) {
            Some(id) => mine[at + 20] = id.to_double()
            None => {
              // nothing drawn: a rect of no colour, no border, no blur
              mine[at + 5] = 0.0
              for j in 6..<12 {
                mine[at + j] = 0.0
              }
            }
          }
        }
      }
      (l.host.drawn_pixels_of)(mine, count, r, gg, b, scale, w, h, out)
    }
    None => {
      for i in 0..<(w * h * 4) {
        out[i] = if i % 4 == 3 { b'\xFF' } else { b'\x80' }
      }
      true
    }
  }
}

///|
fn FakeHost::image_free(self : FakeHost, id : Int) -> Unit {
  self.images.remove(id)
  match self.image_bytes.get(id) {
    Some(n) => {
      self.image_bytes.remove(id)
      self.image_bytes_now -= n
    }
    None => ()
  }
  match (self.live, self.live_images.get(id)) {
    (Some(l), Some(mine)) => {
      self.live_images.remove(id)
      (l.host.image_free)(mine)
    }
    _ => ()
  }
}

// Native views (native.mbt): the fake host has views of every kind, ready at once, 10 s long and 640 × 360, that
// never ask to read; it notes what is asked of them (FakeHost.views).

///|
fn FakeHost::view_open(self : FakeHost, kind : Int, arg : String) -> Int {
  self.view_ids += 1
  self.views.push("open \{self.view_ids} \{kind} \{arg.length()}")
  self.view_kinds[self.view_ids] = kind
  self.view_ids
}

///|
/// A view placed (device pixels, as a host is told): noted, and where it shows kept in points (what a finger on it
/// is by).
fn FakeHost::view_place(self : FakeHost, id : Int, px : Double, py : Double, pw : Double, ph : Double, pcx0 : Double, pcy0 : Double, pcx1 : Double, pcy1 : Double, pr0 : Double, pr1 : Double, pr2 : Double, pr3 : Double, shown : Bool) -> Unit {
  self.views.push(
    "place \{id} \{px} \{py} \{pw} \{ph} in \{pcx0} \{pcy0} \{pcx1} \{pcy1}" +
    (if pr0 == pr1 && pr1 == pr2 && pr2 == pr3 {
      if pr0 > 0.0 {
        " round \{pr0}"
      } else {
        ""
      }
    } else {
      " round \{pr0} \{pr1} \{pr2} \{pr3}"
    }) +
    (if shown { "" } else { " hidden" }) +
    // (in a window of the run beside the first, which: window_slots.mbt)
    (if self.window_at != 0 { " window \{self.window_at}" } else { "" }),
  )
  let z = window_zoom_drawn.val
  let (x, y, w, h) = (px / z, py / z, pw / z, ph / z)
  let (cx0, cy0, cx1, cy1) = (pcx0 / z, pcy0 / z, pcx1 / z, pcy1 / z)
  self.view_at[id] = (dmax(x, cx0), dmax(y, cy0), dmin(x + w, cx1), dmin(y + h, cy1), shown)
}

///|
fn FakeHost::view_close(self : FakeHost, id : Int) -> Unit {
  self.views.push("close \{id}")
  self.view_at.remove(id)
  self.scripts_waiting.remove(id)
  if self.touch_view == id {
    self.touch_view = 0
  }
}

///|
fn FakeHost::view_control(self : FakeHost, id : Int, op : Int, value : Double) -> Unit {
  self.views.push("control \{id} \{op} \{value}")
}

///|
/// How a view stands (each read counted: Tester's); a page there now runs what was sent to it.
fn FakeHost::view_info(self : FakeHost, id : Int, out : FixedArray[Double]) -> Int {
  self.view_reads += 1
  let state = fake_view_info(self, id, out)
  fake_scripts_flush(self, id)
  state
}

///|
fn fake_view_info(f : FakeHost, id : Int, out : FixedArray[Double]) -> Int {
  match f.view_infos.get(id) {
    // as the run recorded the host's saying it (Tester::view_said)
    Some((state, at)) => {
      for i in 0..<10 {
        out[i] = at[i]
      }
      return state
    }
    None => ()
  }
  // a test that says when views are ready: not yet, until it does
  if !f.auto_finish && f.view_ready.get(id).unwrap_or(0) != 1 {
    for i in 0..<10 {
      out[i] = 0.0
    }
    return f.view_ready.get(id).unwrap_or(0)
  }
  match f.players.get(id) {
    Some(p) => {
      for i in 0..<10 {
        out[i] = p[i]
      }
      1
    }
    None => {
      out[0] = 10000.0
      out[1] = 0.0
      out[2] = 0.0
      out[3] = 640.0
      out[4] = 360.0
      out[5] = 0.0
      out[6] = 1.0
      out[7] = 0.0
      out[8] = 0.0
      out[9] = 0.0
      1
    }
  }
}

///|
/// What its sites say, the view's own first (Tester::view_says…), then the views' common queue (Tester::site_says).
fn FakeHost::view_site_next(self : FakeHost, id : Int) -> String {
  let e = match self.site_of.get(id) {
    Some(q) if q.length() > 0 => q.remove(0)
    _ => if self.site.length() > 0 { self.site.remove(0) } else { "" }
  }
  // (a page that said something is there: what was sent to it runs)
  if e.has_prefix("{\"said\"") {
    self.page_there[id] = true
    fake_scripts_flush(self, id)
  }
  e
}

///|
/// What the app tells a view's host beyond its controls: each noted ("script 1 42 9a0b…", "touch 1 vertical 8",
/// "settings 1 …"), a page's scripts run as a host does: once its page is there (ready and not loading, or said
/// something since it started), in the order sent.
fn FakeHost::view_tell(self : FakeHost, id : Int, what : Int, text : String) -> Unit {
  if what == 1 {
    self.scripts_sent.push("\{id} \{text.length()} \{script_hash(text)}")
    match self.scripts_waiting.get(id) {
      Some(q) => q.push(text)
      None => self.scripts_waiting[id] = [text]
    }
    fake_scripts_flush(self, id)
  } else if what == 2 {
    let parts = text.split(" ").map(fn(p) { p.to_owned() }).to_array()
    let slop = match (try Some(@json.parse(parts.get(1).unwrap_or("0"))) catch { _ => None }) {
      Some(Number(n, ..)) => n
      _ => 0.0
    }
    self.view_touch[id] = (parts.get(0).unwrap_or("all"), slop)
    self.views.push("touch \{id} \{text}")
  } else if what == 4 {
    let rects : Array[Double] = []
    for p in text.split(" ") {
      match (try Some(@json.parse(p.to_owned())) catch { _ => None }) {
        Some(Number(n, ..)) => rects.push(n)
        _ => ()
      }
    }
    self.view_covers[id] = rects
  } else if what == 5 {
    self.views.push("raise \{id}")
  } else {
    self.views.push("settings \{id} \{text}")
  }
}

///|
/// Whether a fake page is there for scripts: said something since it started, or ready and not loading.
fn fake_page_there(f : FakeHost, id : Int) -> Bool {
  if f.page_there.get(id) is Some(true) {
    return true
  }
  let ready = match f.view_infos.get(id) {
    Some((state, _)) => state == 1
    None => f.auto_finish || f.view_ready.get(id).unwrap_or(0) == 1
  }
  let loading = match f.site_states.get(id) {
    Some(st) =>
      match (try Some(@json.parse(st)) catch { _ => None }) {
        Some(Object(m)) => m.get("loading") is Some(True)
        _ => false
      }
    None => false
  }
  ready && !loading
}

///|
/// A fake page's scripts that wait run, in the order sent, once it is there.
fn fake_scripts_flush(f : FakeHost, id : Int) -> Unit {
  match f.scripts_waiting.get(id) {
    Some(q) if q.length() > 0 && fake_page_there(f, id) => {
      let run = match f.scripts_run.get(id) {
        Some(r) => r
        None => {
          let r = []
          f.scripts_run[id] = r
          r
        }
      }
      for js in q {
        run.push(js)
        f.views.push("script \{id} \{js.length()} \{script_hash(js)}")
      }
      q.clear()
    }
    _ => ()
  }
}

///|
/// A request's body: as the run recorded it (Tester::view_said); else none.
fn FakeHost::view_site_body(self : FakeHost, id : Int, req : Int) -> Bytes {
  self.site_bodies.get((id, req)).unwrap_or(Bytes::make(0, b'\x00'))
}

///|
fn FakeHost::view_site_head(self : FakeHost, id : Int, req : Int, status : Int, headers : String) -> Unit {
  self.views.push("site head \{id} \{req} \{status} \{headers}")
}

///|
fn FakeHost::view_site_chunk(self : FakeHost, id : Int, req : Int, data : Bytes) -> Unit {
  self.views.push("site chunk \{id} \{req} \{data.length()}")
}

///|
fn FakeHost::view_site_end(self : FakeHost, id : Int, req : Int, error : String) -> Unit {
  self.views.push("site end \{id} \{req} \{error}")
}

///|
/// A site's page: as the run recorded the host's saying it (Tester::view_said); not said: at its start, loaded,
/// untitled.
fn FakeHost::view_site_state(self : FakeHost, id : Int) -> String {
  let st = self.site_states.get(id).unwrap_or(
    "{\"path\":\"/\",\"back\":false,\"forward\":false,\"loading\":false,\"title\":\"\"}",
  )
  fake_scripts_flush(self, id)
  st
}

///|
/// What a view says: as the run recorded the host's saying it (Tester::view_said); not said yet: not known (a grab:
/// none asked). A grab said ready before its frame is said ("2", then the `still` line: a host says both in one frame,
/// a replay may give them a frame apart): still grabbing until the frame is here, not ready with none.
fn FakeHost::view_text(self : FakeHost, id : Int, what : Int) -> String? {
  match self.view_texts.get((id, what)) {
    Some("2") if what == 2 && !(self.view_stills.get(id) is Some(q) && q.length() > 0) => Some("1")
    Some(t) => Some(t)
    None => if what == 2 { Some("0") } else { None }
  }
}

///|
/// The oldest frame grabbed, taken (the grab's state back to none asked, as a host's).
fn FakeHost::view_still(self : FakeHost, id : Int) -> Bytes {
  let b = match self.view_stills.get(id) {
    Some(q) if q.length() > 0 => q.remove(0)
    _ => b""
  }
  if self.view_texts.get((id, 2)) == Some("2") {
    self.view_texts[(id, 2)] = "0"
  }
  b
}

///|
fn FakeHost::view_site_load(self : FakeHost, id : Int, path : String) -> Unit {
  self.views.push("site load \{id} \{path}")
}

///|
fn FakeHost::view_read_next(self : FakeHost, id : Int, out : FixedArray[Double]) -> Int {
  fake_read_next(self, id, out)
}

///|
fn FakeHost::view_read_answer(self : FakeHost, id : Int, req : Int, data : Bytes, total : Double, more : Bool) -> Unit {
  self.read_answers.push((id, req, data.length(), total, more))
}

// PDFs (native.mbt Pdf): the fake host's every PDF has 3 pages of 612 × 792 points; a page drawn is an image of that
// shape. Under a host's kept text (text_table), its answers as the host gave them.

///|
fn FakeHost::pdf_open(self : FakeHost, data : Bytes) -> Int {
  self.views.push("pdf \{data.length()}")
  let doc = 7 + self.pdfs.length()
  self.pdfs[doc] = (bytes_name(data), data.length())
  doc
}

///|
fn FakeHost::pdf_pages(self : FakeHost, doc : Int) -> Int {
  match self.pdfs.get(doc) {
    // as the host counted them, when kept with the text; else the fake's 3
    Some(named) if text_table.val is Some(_) =>
      match kept_answer("pn", pdf_head(named, [])) {
        Some(Number(n, ..)) => n.to_int()
        _ => 3
      }
    Some(_) => 3
    None => -1
  }
}

///|
fn FakeHost::pdf_page_size(self : FakeHost, doc : Int, page : Int, out : FixedArray[Double]) -> Unit {
  out[0] = 612.0
  out[1] = 792.0
  match self.pdfs.get(doc) {
    Some(named) if text_table.val is Some(_) =>
      match kept_answer("ps", pdf_head(named, [page])) {
        Some(Array([Number(w, ..), Number(h, ..), ..])) => {
          out[0] = w
          out[1] = h
        }
        _ => ()
      }
    _ => ()
  }
}

///|
fn FakeHost::pdf_page_load(self : FakeHost, doc : Int, page : Int, max_px : Int) -> Int {
  self.image_loads.push(("pdf:\{doc}/\{page}", max_px))
  match self.pdfs.get(doc) {
    Some(named) if text_table.val is Some(_) =>
      match kept_sizes(kept_answer("pi", pdf_head(named, [page, max_px]))) {
        Some((w, h, ow, oh)) => fake_image_sized(self, w, h, ow, oh)
        None => fake_image(self, 1224, 1584, max_px)
      }
    _ => fake_image(self, 1224, 1584, max_px)
  }
}

///|
fn FakeHost::pdf_close(self : FakeHost, doc : Int) -> Unit {
  self.views.push("pdf close \{doc}")
}

///|
/// The pointer's shape as last told (desktop.mbt).
fn FakeHost::set_cursor(self : FakeHost, kind : Int) -> Unit {
  self.cursor = kind
  self.cursors_told = self.cursors_told + 1
}

///|
/// The number on the app's icon, kept (Tester::badge).
fn FakeHost::set_badge(self : FakeHost, n : Int) -> Unit {
  self.badge = n
}

///|
/// What the app's own native call `name` says, as the test set it (Tester::set_app_said); "" unset.
fn FakeHost::app_said(self : FakeHost, name : String) -> String {
  self.app_said.get(name).unwrap_or("")
}

///|
/// What the app told its own native calls, kept (Tester::app_told).
fn FakeHost::app_tell(self : FakeHost, name : String, arg : String) -> Unit {
  self.app_told.push((name, arg))
}

///|
/// The keys held down as the test says (Tester::hold_mods).
fn FakeHost::mods_held(self : FakeHost) -> Int {
  self.mods
}

///|
/// A fake host's pointer held by the window and its game controllers, beside it rather than in it (FakeHost's layout
/// stays as it was: a field put among others moves the places of those after it in the C of every test program, all
/// of it compiled again): made as a test first holds the pointer or says controllers, let go as the next run starts.
priv struct FakePointerAux {
  fake : FakeHost
  /// the pointer held by the window (@hostapi.set_pointer_lock), how many times it was told to be, and how far the
  /// mouse moved while it is, not yet taken (Tester::locked_move)
  mut lock : Bool
  mut locks_told : Int
  mut delta : (Double, Double)
  /// the game controllers connected, as the test says (Tester::set_gamepads)
  mut pads : Array[@hostapi.Gamepad]
}

///|
// kept across a run's frames: each fake host's entry, let go as the next run starts (reset_globals)
let fake_pointer_auxs : Array[FakePointerAux] = []

///|
fn fake_pointer_of(fake : FakeHost) -> FakePointerAux? {
  for it in fake_pointer_auxs {
    if physical_equal(it.fake, fake) {
      return Some(it)
    }
  }
  None
}

///|
fn fake_pointer(fake : FakeHost) -> FakePointerAux {
  match fake_pointer_of(fake) {
    Some(it) => it
    None => {
      let it : FakePointerAux = { fake, lock: false, locks_told: 0, delta: (0.0, 0.0), pads: [] }
      fake_pointer_auxs.push(it)
      it
    }
  }
}

///|
fn fake_pointer_reset() -> Unit {
  fake_pointer_auxs.clear()
}

///|
/// The pointer held or let go of, as told (Tester::pointer_locked); what it moved while held let go of with it.
fn FakeHost::pointer_lock(self : FakeHost, on : Bool) -> Unit {
  let p = fake_pointer(self)
  p.locks_told = p.locks_told + 1
  p.lock = on
  p.delta = (0.0, 0.0)
}

///|
fn FakeHost::pointer_locked(self : FakeHost) -> Bool {
  match fake_pointer_of(self) {
    Some(p) => p.lock
    None => false
  }
}

///|
/// How far the mouse moved while the pointer is held (Tester::locked_move), taken.
fn FakeHost::pointer_delta(self : FakeHost, out : FixedArray[Double]) -> Unit {
  match fake_pointer_of(self) {
    Some(p) => {
      out[0] = p.delta.0
      out[1] = p.delta.1
      p.delta = (0.0, 0.0)
    }
    None => {
      out[0] = 0.0
      out[1] = 0.0
    }
  }
}

///|
/// The game controllers as the test says (Tester::set_gamepads), their sticks and triggers as they are.
fn FakeHost::gamepads(self : FakeHost, out : FixedArray[Double]) -> Int {
  guard fake_pointer_of(self) is Some(fp) else { return 0 }
  let mut n = 0
  for p in fp.pads {
    if n >= @hostapi.gamepads_most {
      break
    }
    let o = n * @hostapi.gamepad_fields
    out[o] = p.index.to_double()
    out[o + 1] = 1.0
    out[o + 2] = p.buttons.to_double()
    out[o + 3] = p.lx
    out[o + 4] = p.ly
    out[o + 5] = p.rx
    out[o + 6] = p.ry
    out[o + 7] = p.lt
    out[o + 8] = p.rt
    n += 1
  }
  n
}

///|
/// The window dragged: counted.
fn FakeHost::window_drag(self : FakeHost) -> Unit {
  self.window_drags = self.window_drags + 1
}

///|
/// What the app asked of the window's own buttons, oldest first (Tester's), the window in place's (window_acts_by;
/// the first's in window_acts too, as ever). Close (3) in a window beside the first closes it as a host's own close
/// does: told the app between frames, as the person's (Tester::close_window_beside).
fn FakeHost::window_act(self : FakeHost, what : Int) -> Unit {
  let wid = self.window_at
  if wid == 0 {
    self.window_acts.push(what)
  }
  match self.window_acts_by.get(wid) {
    Some(acts) => acts.push(what)
    None => self.window_acts_by[wid] = [what]
  }
  if what == 3 && wid > 0 {
    after_frame(fn() {
      if !self.window_ids_closed.contains(wid) {
        self.window_ids_closed.push(wid)
      }
      on_outside(outside_window, wid, -1)
      self.wants = true
    })
  }
}

///|
/// Whether the window in place is maximized (Tester::set_window_zoomed, set_window_zoomed_of).
fn FakeHost::window_zoomed(self : FakeHost) -> Bool {
  match self.window_zooms.get(self.window_at) {
    Some(z) if self.window_at > 0 => z
    _ => self.zoomed
  }
}

///|
/// Where the app last said its maximize button is (device pixels).
fn FakeHost::window_snap(self : FakeHost, x : Double, y : Double, w : Double, h : Double) -> Unit {
  self.snap = (x, y, w, h)
}

///|
/// How the pointer stands on the maximize button (Tester::set_window_snap).
fn FakeHost::window_snap_state(self : FakeHost) -> Int {
  match self.window_snaps.get(self.window_at) {
    Some(s) if self.window_at > 0 => s
    _ => self.snap_state
  }
}

///|
fn FakeHost::window_opens(self : FakeHost) -> Bool {
  self.window_opens
}

///|
/// Another window opened where it can (Tester::set_window_opens), kept.
fn FakeHost::window_open(self : FakeHost, what : String) -> Bool {
  if self.window_opens {
    self.windows_opened.push(what)
  }
  self.window_opens
}

///|
/// A window brought to the front where one opened for `what` is open still (Tester::close_window), kept.
fn FakeHost::window_front(self : FakeHost, what : String) -> Bool {
  let open = self.windows_opened.iter().filter(fn(w) { w == what }).count() >
    self.windows_closed.iter().filter(fn(w) { w == what }).count()
  if open {
    self.windows_fronted.push(what)
  }
  open
}

///|
/// Its windows in this run where the test says so (Tester::set_windows_in_process).
fn FakeHost::windows_in_process(self : FakeHost) -> Bool {
  self.windows_in_process
}

///|
/// The title each window of the run was given (as it was opened, @ui.set_window_title) and the role each beside the
/// first was opened as, by id (Tester::window_title, window_role): the run's, emptied as a Tester starts anew.
// kept across runs: a run's start clears it (the init below)
let fake_window_titles : Map[Int, String] = Map([])

///|
// kept across runs: a run's start clears it (the init below)
let fake_window_roles : Map[Int, String] = Map([])

///|
fn init {
  on_reset(fn() {
    fake_window_titles.clear()
    fake_window_roles.clear()
  })
}

///|
/// Another window of the run, its size the one a test said for it (Tester::set_window_beside_size), else what it was
/// opened at (a JSON object's positive "w" and "h": @ui.WindowSpec), else 480 × 720; its title and role kept as it says
/// them, its buttons in its top row as its "inset" says (else the first window's).
fn FakeHost::window_open_id(self : FakeHost, what : String) -> Int {
  guard self.windows_in_process else { return 0 }
  self.window_ids = self.window_ids + 1
  let wid = self.window_ids
  let parsed = @json.parse(what) catch { _ => Json::null() }
  let said : Map[String, Json] = match parsed {
    Object(m) => m
    _ => Map([])
  }
  if !self.window_sizes.contains(wid) {
    match (said.get("w"), said.get("h")) {
      (Some(Number(w, ..)), Some(Number(h, ..))) if w > 0.0 && h > 0.0 => self.window_sizes[wid] = (w, h)
      _ => self.window_sizes[wid] = (480.0, 720.0)
    }
  }
  match said.get("title") {
    Some(String(t)) if t != "" => fake_window_titles[wid] = t
    _ => ()
  }
  match said.get("role") {
    Some(String(r)) if r != "" => fake_window_roles[wid] = r
    _ => ()
  }
  // (its buttons in its top row as its spec says, else as the first window's; one a test said for it before kept)
  if !self.window_insets.contains(wid) {
    match said.get("inset") {
      Some(True) => self.window_insets[wid] = true
      Some(False) => self.window_insets[wid] = false
      _ => ()
    }
  }
  self.wants = true
  wid
}

///|
/// A window's title, kept (Tester::window_title): the window drawn or handed input now's where it says none (< 0).
fn FakeHost::window_set_title(self : FakeHost, wid : Int, title : String) -> Unit {
  fake_window_titles[if wid < 0 { self.window_at } else { wid }] = title
}

///|
/// A window of the run to the front, while it is open (Tester::close_window_beside), kept.
fn FakeHost::window_front_id(self : FakeHost, wid : Int) -> Bool {
  let open = wid > 0 && wid <= self.window_ids && !self.window_ids_closed.contains(wid)
  if open {
    self.window_ids_fronted.push(wid)
  }
  open
}

///|
/// A window of the run closed by the app, kept.
fn FakeHost::window_close_id(self : FakeHost, wid : Int) -> Unit {
  if !self.window_ids_closed.contains(wid) {
    self.window_ids_closed.push(wid)
  }
}

///|
/// The window of the run drawn or handed input now (Tester::in_window).
fn FakeHost::window_current(self : FakeHost) -> Int {
  self.window_at
}

///|
/// What another app shared in (Tester::share_in), from the frame after it was told; taken once.
fn FakeHost::shared_in(self : FakeHost) -> String {
  match self.share {
    Some((said, frame)) if g().frame_no > frame => {
      self.share = None
      said
    }
    _ => ""
  }
}

///|
/// The i-th of the files shared in, taken once.
fn FakeHost::shared_in_file(self : FakeHost, i : Int) -> Bytes {
  if i >= 0 && i < self.share_files.length() {
    let b = self.share_files[i]
    self.share_files[i] = b""
    b
  } else {
    b""
  }
}

///|
/// What the app hands the share sheet: taken, kept for the test (Tester::shared_out).
fn FakeHost::share(self : FakeHost, text : String, name : String, mime : String, data : Bytes) -> Bool {
  self.shares.push((text, name, mime, data))
  true
}

///|
/// Marks drawn onto an image: kept (Tester::marks_drawn), drawn by the frame after (or as the test says,
/// Tester::marks_by_hand); its PNG the test's (Tester::marks_make) or one clear pixel (its id, from 1: its place).
fn FakeHost::mk_start(self : FakeHost, _ : Bytes, marks : String) -> Int {
  self.marks.push((marks, g().frame_no))
  self.marks_out.push(self.marks_next.unwrap_or(marked_png))
  self.marks_next = None
  self.wants = true
  self.marks.length()
}

///|
/// How drawing `id` goes: 0 drawing (until the frame after it was asked, or by hand: at once, the test's word told
/// as a host's event), 1 drawn, -1 none.
fn FakeHost::mk_state(self : FakeHost, id : Int) -> Int {
  match self.marks.get(id - 1) {
    Some((_, frame)) => if self.marks_by_hand || g().frame_no > frame { 1 } else { 0 }
    None => -1
  }
}

///|
fn FakeHost::mk_png(self : FakeHost, id : Int) -> Bytes {
  self.marks_out.get(id - 1).unwrap_or(b"")
}

///|
/// Its clock is its own (its frames').
fn FakeHost::own_clock(_ : FakeHost) -> Bool {
  true
}

///|
fn FakeHost::system_dark(self : FakeHost) -> Bool {
  self.dark
}

///|
/// The system's size of words (Tester::set_font_scale).
fn FakeHost::font_scale(self : FakeHost) -> Double {
  self.font_scale
}

///|
/// How far its local time is ahead of UTC (Tester::set_utc_offset), whatever the moment.
fn FakeHost::utc_offset_min(self : FakeHost, _ : Double) -> Int {
  self.utc_offset
}

///|
/// What the person points with as it starts (Tester::new's `pointing`): 1 a finger, 0 a mouse; each event's word
/// after (@ui.pointing).
fn FakeHost::pointing(self : FakeHost) -> Int {
  match self.pointing {
    Finger => 1
    Mouse => 0
  }
}

///|
/// What the app was started to be used with (Tester::new's `native`): 1 a finger, 2 a mouse.
fn FakeHost::native_pointing(self : FakeHost) -> Int {
  match self.native {
    Finger => 1
    Mouse => 2
  }
}

///|
/// A keyboard at hand (Tester::new's `keyboard`, Tester::set_keyboard).
fn FakeHost::keyboard(self : FakeHost) -> Int {
  if self.keyboard {
    1
  } else {
    0
  }
}

///|
fn FakeHost::window_inset(self : FakeHost) -> Bool {
  match self.window_insets.get(self.window_at) {
    Some(i) if self.window_at > 0 => i
    _ => self.inset
  }
}

///|
fn FakeHost::full_screen(self : FakeHost) -> Bool {
  self.full
}

///|
/// The window made to fill the screen or back: kept (@ui.full_screen), a frame asked for it as a host's window that
/// changes so draws one, between frames; in one, that frame draws it (view_told_as_built).
fn FakeHost::set_full_screen(self : FakeHost, on : Bool) -> Unit {
  if self.full != on {
    self.full = on
    if !frame_running.val {
      self.wants = true
    }
  }
}

///|
/// The window's buttons moved lower: kept (Tester::window_buttons_down).
fn FakeHost::window_buttons_down(self : FakeHost, by : Double, ms : Double) -> Unit {
  self.buttons_down = (by, ms)
}

///|
/// How round the window's corners are (Tester::new's `window_corner`, the roundest of its `window_corners`): none
/// while it fills the screen.
fn FakeHost::window_corner(self : FakeHost) -> Double {
  if self.full {
    0.0
  } else {
    match self.window_corners {
      Some(k) => k.fold(init=0.0, fn(m, r) { dmax(m, r) })
      None => self.window_corner
    }
  }
}

///|
/// Corner `k` (0 top left, then round it: Tester::new's `window_corners`, else its `window_corner`).
fn FakeHost::window_corner_at(self : FakeHost, k : Int) -> Double {
  if self.full {
    0.0
  } else {
    match self.window_corners {
      Some(c) => c[k & 3]
      None => self.window_corner
    }
  }
}

///|
/// Whether it lays out the app's tabs itself (Tester::set_nav_able).
fn FakeHost::nv_able(self : FakeHost) -> Bool {
  self.nav_able
}

///|
/// The bars handed it, kept (Tester::nav_said): shown where it lays them out.
fn FakeHost::nv_bar(self : FakeHost, spec : String) -> Int {
  self.nav_said = spec
  if self.nav_able {
    1
  } else {
    0
  }
}

///|
/// Its environment (Tester::new's `env`, Tester::set_env).
fn FakeHost::env(self : FakeHost, name : String) -> String {
  self.env.get(name).unwrap_or("")
}

///|
fn FakeHost::app_version(self : FakeHost) -> Int {
  self.app_version
}
///|
/// A secret on the clipboard: kept as any words (Tester::clipboard), said to be a secret (Tester::clipboard_secret).
fn FakeHost::clipboard_set_secret(self : FakeHost, s : String, clear_ms : Double) -> Unit {
  self.clipboard = s
  self.clipboard_html = ""
  self.clipboard_secret = clear_ms
}

///|
/// The last secret taken off while it is there still (Tester::clipboard empty again, Tester::clipboard_secret None).
fn FakeHost::clipboard_secret_off(self : FakeHost) -> Unit {
  if self.clipboard_secret >= 0.0 {
    self.clipboard = ""
    self.clipboard_secret = -1.0
  }
}

///|
/// A picture on the clipboard: how long it was kept (Tester::clipboard_image).
fn FakeHost::clipboard_set_image(self : FakeHost, data : Bytes) -> Unit {
  self.clipboard_image = data.length()
}

///|
/// A frame presented: its instances counted, what a host that keeps its picture is handed kept for a test that
/// records it (tester_host.mbt).
/// Drawn out where a header stands for a group it keeps, as a host draws them (Ctx::flat_from): what a test reads of
/// the frame reads the instances drawn. Those are the frame's, every one: what a host is handed leaves out what
/// cannot be seen (h_present, @damage's Damage::occlude), which draws the same.
fn FakeHost::present(self : FakeHost, _ : FixedArray[Double], _ : Int, _ : Double, _ : Double, _ : Double) -> Unit {
  let c = g()
  c.flat_from(0)
  self.instances = c.ninst
  host_presented_now(c.inst, c.ninst)
  // (what of it was drawn not as laid out, as it is presented: held at the frame's end, tester_placed.mbt)
  placed_at_present()
  // (what the window's tree keeps against what working it out whole gives, as it is presented: held at the frame's
  // end, tester.mbt)
  kept_at_present()
  // (presenting it taking the time said: its clock moved on by it, as a device's GPU may hold a frame)
  if self.present_ms > 0.0 {
    self.time = self.time + self.present_ms
  }
}

///|
/// The app over another app done, kept (Tester::overs_done).
fn FakeHost::over_done(self : FakeHost, open_app : Bool) -> Unit {
  self.overs_done.push(open_app)
}

///|
/// What the notice holding the app up says, kept (Tester::hold_words).
fn FakeHost::hold_words(self : FakeHost, channel : String, title : String, body : String) -> Unit {
  self.hold_words = Some((channel, title, body))
}

///|
/// The legacy encodings it decodes (@hostapi.decode_charset): GB18030 and the two it holds (fake_gb18030.mbt); the
/// system's others are a host's own (its contract's).
fn fake_charset(charset : String) -> Bool {
  let c = charset.to_upper()
  c == "GB18030" || c == "GBK" || c == "GB2312"
}

///|
fn FakeHost::cs_known(_ : FakeHost, charset : String) -> Int {
  if fake_charset(charset) {
    1
  } else {
    0
  }
}

///|
fn FakeHost::cs_decode(_ : FakeHost, data : Bytes, charset : String) -> String {
  if fake_charset(charset) {
    gb18030_decode(data)
  } else {
    ""
  }
}

///|
/// The access level of a Tester's gallery (Tester::gallery).
fn FakeHost::ga_access(self : FakeHost) -> Int {
  guard self.gallery is Some(_) else { return 0 }
  if self.gallery_limited { 2 } else { 1 }
}

///|
fn FakeHost::ga_read(self : FakeHost) -> Int {
  self.gallery_read()
}

///|
fn FakeHost::ga_read_state(self : FakeHost, a0 : Int) -> Int {
  self.gallery_read_state(a0)
}

///|
fn FakeHost::ga_read_rows(self : FakeHost, a0 : Int) -> String {
  self.gallery_read_rows(a0)
}

///|
fn FakeHost::ga_read_end(self : FakeHost, a0 : Int) -> Unit {
  self.gallery_read_end(a0)
}

// This device's password manager (@hostapi passwords.mbt) as a test has it: none, unless it says how `op` answers
// (`fake_op`: its exit code, output and error output for the arguments given), each run ended at once.

///|
/// Bytes said to take a while to decode (Tester::decode_bytes_after; a film's scene says so of its own): the bytes and
/// how many ms after each decode of them is asked for it is done. None, as a Tester begins.
pub let fake_decode_bytes_after : Ref[Array[(Bytes, Double)]] = Ref([])

///|
/// How `op` answers a test, given its arguments: None, no password manager here.
pub let fake_op : Ref[((Array[String]) -> (Int, String, String))?] = Ref(None)

///|
/// The runs of `op` asked for in a test, by their id (from 1): their arguments.
pub let fake_op_runs : Array[Array[String]] = []

///|
fn FakeHost::pw_able(_ : FakeHost) -> Bool {
  fake_op.val is Some(_)
}

///|
fn FakeHost::pw_run(_ : FakeHost, args : String) -> Int {
  guard fake_op.val is Some(_) else { return 0 }
  let given = args.split("\u{1f}").map(fn(a) { a.to_owned() }).to_array()
  // (each argument ended by the separator: the last piece is none)
  ignore(given.pop())
  fake_op_runs.push(given)
  fake_op_runs.length()
}

///|
/// Whether the runs of `op` are still under way in a test (none has ended: 1Password slow to answer).
pub let fake_op_pending : Ref[Bool] = Ref(false)

///|
fn FakeHost::pw_out(_ : FakeHost, id : Int) -> String {
  guard fake_op.val is Some(answer) && id >= 1 && id <= fake_op_runs.length() && !fake_op_pending.val else { return "" }
  let (code, out, err) = answer(fake_op_runs[id - 1])
  "\{code}\u{1f}\{out}\u{1f}\{err}\u{1f}"
}

///|
fn FakeHost::pw_end(_ : FakeHost, _ : Int) -> Unit {
  ()
}

// The system's autofill (@hostapi autofill.mbt) as a test has it: none, unless it says there is a service
// (`fake_autofill`); the sites asked for kept, the login the person picked there given by `fake_autofill_picks`.

///|
/// Whether a test's host has an autofill service.
pub let fake_autofill : Ref[Bool] = Ref(false)

///|
/// The sites the autofill service was asked for in a test, in order; "" where the ask was let go of.
pub let fake_autofill_asks : Array[String] = []

///|
let fake_autofill_picked : Ref[String] = Ref("")

///|
/// The person picks a login in the autofill service's offer: its site's host, account and password, taken once.
pub fn fake_autofill_picks(host : String, username : String, password : String) -> Unit {
  fake_autofill_picked.val = "\{host}\u{1f}\{username}\u{1f}\{password}\u{1f}"
}

///|
fn FakeHost::af_able(_ : FakeHost) -> Bool {
  fake_autofill.val
}

///|
fn FakeHost::af_ask(_ : FakeHost, host : String) -> Int {
  guard fake_autofill.val else { return 0 }
  fake_autofill_asks.push(host)
  1
}

///|
fn FakeHost::af_take(_ : FakeHost) -> String {
  let p = fake_autofill_picked.val
  fake_autofill_picked.val = ""
  p
}

///|
fn FakeHost::af_end(_ : FakeHost) -> Unit {
  fake_autofill_picked.val = ""
  fake_autofill_asks.push("")
}

// This device's passkeys (@hostapi passkeys.mbt) as a test has them: none, unless it says how the device answers
// (`fake_passkey`: given the relying party, the client data, the verification and the ids asked, the host's answer as
// it gives it), each ask ended at once.

///|
/// How the device answers a test's ask for a passkey: None, no passkeys here.
pub let fake_passkey : Ref[((String, String, String, String) -> String)?] = Ref(None)

///|
/// The asks for a passkey in a test, by their id (from 1): the relying party, the client data, the verification, the
/// ids asked (hex, joined by commas).
pub let fake_passkey_asks : Array[(String, String, String, String)] = []

///|
fn FakeHost::wa_able(_ : FakeHost) -> Bool {
  fake_passkey.val is Some(_)
}

///|
fn FakeHost::wa_get(_ : FakeHost, ask : String) -> Int {
  guard fake_passkey.val is Some(_) else { return 0 }
  let p = ask.split("\u{1f}").map(fn(a) { a.to_owned() }).to_array()
  fake_passkey_asks.push((p.get(0).unwrap_or(""), p.get(1).unwrap_or(""), p.get(2).unwrap_or(""), p.get(3).unwrap_or("")))
  fake_passkey_asks.length()
}

///|
fn FakeHost::wa_out(_ : FakeHost, id : Int) -> String {
  guard fake_passkey.val is Some(answer) && id >= 1 && id <= fake_passkey_asks.length() else { return "" }
  let (rp, client, uv, ids) = fake_passkey_asks[id - 1]
  answer(rp, client, uv, ids)
}

///|
fn FakeHost::wa_end(_ : FakeHost, _ : Int) -> Unit {
  ()
}

// The device beyond the window (@hostapi device.mbt; @ui's device.mbt) as a test has it (FakeDevice): what it was told
// kept, the clipboard read as the test gives it (Tester::clipboard_gives…), from the frame after.

///|
/// A haptic fired, kept (Tester::haptics).
fn FakeHost::dv_haptic(self : FakeHost, kind : Int) -> Unit {
  let all : Array[Haptic] = [LongPress, ContextClick, TextHandleMove, Confirm, Reject, KeyboardTap]
  for h in all {
    if h.code() == kind {
      self.dev.haptics.push(h)
      return
    }
  }
}

///|
/// The screen kept awake as last told (Tester::awake).
fn FakeHost::dv_keep_awake(self : FakeHost, on : Int) -> Unit {
  self.dev.awake = on != 0
}

///|
/// Whether the system says a copy itself (Tester::new's `copy_shown`).
fn FakeHost::dv_copy_shown(self : FakeHost) -> Int {
  if self.dev.copy_shown {
    1
  } else {
    0
  }
}

///|
fn FakeHost::dv_key_catch(self : FakeHost, on : Int) -> Unit {
  self.dev.key_catch = on != 0
}

///|
/// The soft keyboard's height as the test says it.
fn FakeHost::dv_ime_inset(self : FakeHost) -> Double {
  self.dev.ime_inset
}

///|
fn FakeHost::dv_ime_action(self : FakeHost, kind : Int) -> Unit {
  self.dev.ime_action = kind
}

///|
fn FakeHost::dv_ime_let_go(self : FakeHost) -> Unit {
  self.dev.ime_let_go += 1
}

///|
/// Words or a picture put on the clipboard (@hostapi.clip_set_text, clip_set_png), held with their label
/// (Tester::clipboard, clipboard_png, clipboard_label).
fn FakeHost::cl_set(self : FakeHost, text : String, png : Bytes, label : String) -> Unit {
  if png.length() > 0 {
    self.clipboard = ""
    self.dev.clip_png = Some(png)
  } else {
    self.clipboard = text
    self.dev.clip_png = None
  }
  self.dev.clip_label = label
}

///|
/// A read of the clipboard asked (its id, from 1: the ask's place): answered by what the test gave before it, if it
/// did, else by what it gives next.
fn FakeHost::cl_read(self : FakeHost) -> Int {
  let ask : FakeClipRead = { answer: None }
  if self.dev.held.length() > 0 {
    ask.answer = Some((self.dev.held.remove(0), g().frame_no))
    self.wants = true
  }
  self.dev.reads.push(ask)
  self.dev.reads.length()
}

///|
/// What read `id` was answered with, from the frame after it was given.
fn FakeHost::clip_given(self : FakeHost, id : Int) -> Clipboard? {
  guard self.dev.reads.get(id - 1) is Some(r) else { return None }
  match r.answer {
    Some((c, at)) if g().frame_no > at => Some(c)
    _ => None
  }
}

///|
/// How read `id` goes: 0 reading (until the test's answer is a frame old), 1 read.
fn FakeHost::cl_state(self : FakeHost, id : Int) -> Int {
  if self.clip_given(id) is Some(_) {
    1
  } else {
    0
  }
}

///|
fn FakeHost::cl_text(self : FakeHost, id : Int) -> String {
  match self.clip_given(id) {
    Some(c) => c.text
    None => ""
  }
}

///|
fn FakeHost::cl_picture(self : FakeHost, id : Int) -> Int {
  match self.clip_given(id) {
    Some({ picture: Png(_), .. }) => @hostapi.clip_png
    Some({ picture: TooLarge, .. }) => @hostapi.clip_too_large
    Some({ picture: Unreadable, .. }) => @hostapi.clip_unreadable
    _ => @hostapi.clip_none
  }
}

///|
fn FakeHost::cl_png(self : FakeHost, id : Int) -> Bytes {
  match self.clip_given(id) {
    Some({ picture: Png(b), .. }) => b
    _ => Bytes::make(0, b'\x00')
  }
}

///|
fn FakeHost::cl_files(self : FakeHost, id : Int) -> Int {
  match self.clip_given(id) {
    Some(c) => c.files.length()
    None => 0
  }
}

///|
fn FakeHost::cl_file_name(self : FakeHost, id : Int, i : Int) -> String {
  match self.clip_given(id) {
    Some(c) if i >= 0 && i < c.files.length() => c.files[i].0
    _ => ""
  }
}

///|
fn FakeHost::cl_file(self : FakeHost, id : Int, i : Int) -> Bytes {
  match self.clip_given(id) {
    Some(c) if i >= 0 && i < c.files.length() => c.files[i].1
    _ => Bytes::make(0, b'\x00')
  }
}

// The system's notifications (@hostapi notify.mbt) as a test has them: those shown kept (Tester::notices), one tapped
// as the test says (Tester::tap_notice), what the system lets the app show and what the person answers when asked
// (Tester::set_notice_permission, set_notice_reply).

///|
fn FakeHost::find_notice(self : FakeHost, text : String) -> Int? {
  self.notices.search_by(fn(n) { n.title.contains(text) || n.body.contains(text) })
}

///|
fn FakeHost::open_notice(self : FakeHost, index : Int) -> Unit {
  self.notice_opened = self.notices.remove(index).opens
}

///|
/// A notification shown: kept, one of the same tag replaced.
fn FakeHost::nt_show(self : FakeHost, channel : String, tag : String, title : String, body : String, opens : String) -> Unit {
  let kept = self.notices.filter(fn(n) { tag == "" || n.tag != tag })
  self.notices.clear()
  self.notices.append(kept)
  self.notices.push({ channel, tag, title, body, opens })
}

///|
fn FakeHost::nt_cancel(self : FakeHost, tag : String) -> Unit {
  let kept = self.notices.filter(fn(n) { n.tag != tag })
  self.notices.clear()
  self.notices.append(kept)
}

///|
/// 0: what it lets the app show (1 granted, 2 denied, 3 ask, 4 default, 0 unknown); 1: asked to let it (where it is not
/// granted or unknown: the person's answer due, as the test said); 2: the answer, as a frame begins (never between
/// frames: the person answers as the frame after the ask begins), refused leaving it denied, but a browser's "default"
/// as it was (its prompt put away); 3: its settings opened, counted, as the system it plays has them (none a browser's
/// page opens: 0, nothing counted); 4: whether it shows the number on the app's icon, as the system it plays does.
fn FakeHost::nt_state(self : FakeHost, what : Int) -> Int {
  match what {
    0 =>
      match self.notice_perm {
        "granted" => 1
        "denied" => 2
        "ask" => 3
        "default" => 4
        _ => 0
      }
    1 => {
      if self.notice_perm == "granted" || self.notice_perm == "unknown" {
        return 0
      }
      self.notice_asks += 1
      self.notice_due = match self.notice_reply {
        Some(yes) => Some((yes, g().frame_no))
        None => None
      }
      self.wants = true
      1
    }
    2 =>
      match self.notice_due {
        Some((yes, _)) if frame_running.val => {
          self.notice_due = None
          self.notice_perm = if yes {
            "granted"
          } else if self.notice_perm == "default" {
            "default"
          } else {
            "denied"
          }
          if yes {
            1
          } else {
            0
          }
        }
        _ => -1
      }
    3 => {
      if self.platform == 4 {
        return 0
      }
      self.notice_settings += 1
      1
    }
    4 => if platform_badge(self.platform) { 1 } else { 0 }
    _ => 0
  }
}

///|
/// 0: the notification tapped (what it opens), once.
fn FakeHost::nt_text(self : FakeHost, what : Int) -> String {
  if what != 0 {
    return ""
  }
  let o = self.notice_opened
  self.notice_opened = ""
  o
}

// Streams (@hostapi stream.mbt; @ui's stream.mbt) as a test has them: what each was handed, a line each
// (Tester::stream_fed), and its events as the test or a run says them (Tester::stream_shows…, view_said).

///|
fn fake_fed(f : FakeHost, id : Int, line : String) -> Unit {
  match f.streams_fed.get(id) {
    Some(a) => a.push(line)
    None => f.streams_fed[id] = [line]
  }
}

///|
fn FakeHost::st_open(self : FakeHost) -> Int {
  self.stream_ids += 1
  self.streams_fed[self.stream_ids] = []
  self.stream_said[self.stream_ids] = []
  self.stream_ids
}

///|
fn FakeHost::st_h264(self : FakeHost, id : Int, avcc : Bytes, w : Int, h : Int) -> Unit {
  fake_fed(self, id, "h264 \{w}x\{h} avcc=\{avcc.length()}")
}

///|
fn FakeHost::st_hevc(self : FakeHost, id : Int, hvcc : Bytes, w : Int, h : Int) -> Unit {
  fake_fed(self, id, "hevc \{w}x\{h} hvcc=\{hvcc.length()}")
}

///|
fn FakeHost::st_av1(self : FakeHost, id : Int, av1c : Bytes, w : Int, h : Int) -> Unit {
  fake_fed(self, id, "av1 \{w}x\{h} av1c=\{av1c.length()}")
}

///|
fn FakeHost::st_frame(self : FakeHost, id : Int, data : Bytes, key : Int, ts : Double) -> Unit {
  fake_fed(self, id, "frame key=\{key != 0} ts=\{ts} bytes=\{data.length()}")
}

///|
/// A frame not to be shown: "frame … hidden", taken (as Windows' host does), unless the test said its host has nothing
/// for one (Tester::set_stream_hides false: one shown as st_frame's, the other not taken).
fn FakeHost::st_frame_shown(self : FakeHost, id : Int, data : Bytes, key : Int, ts : Double, show : Int) -> Int {
  if show != 0 {
    fake_fed(self, id, "frame key=\{key != 0} ts=\{ts} bytes=\{data.length()}")
    1
  } else if self.stream_hides {
    fake_fed(self, id, "frame key=\{key != 0} ts=\{ts} bytes=\{data.length()} hidden")
    1
  } else {
    0
  }
}

///|
fn FakeHost::st_flush(self : FakeHost, id : Int, drain : Int) -> Unit {
  fake_fed(self, id, "flush drain=\{drain != 0}")
}

///|
fn FakeHost::st_audio_played(self : FakeHost, id : Int) -> Double {
  match self.stream_audio_clock.get(id) {
    Some((played, _)) => played
    None => 0.0
  }
}

///|
fn FakeHost::st_audio_queued(self : FakeHost, id : Int) -> Double {
  match self.stream_audio_clock.get(id) {
    Some((_, queued)) => queued
    None => 0.0
  }
}

///|
fn FakeHost::st_audio_wanted(self : FakeHost, id : Int) -> Double {
  if !self.audio_here {
    return 0.0
  }
  match self.stream_audio_wanted.get(id) {
    Some(ms) => ms
    None => self.stream_audio_wanted.get(0).unwrap_or(0.0)
  }
}

///|
fn FakeHost::st_audio_volume(self : FakeHost, id : Int, v : Double) -> Unit {
  fake_fed(self, id, "volume \{v}")
}

///|
fn FakeHost::st_jpeg(self : FakeHost, id : Int, data : Bytes, ts : Double) -> Unit {
  fake_fed(self, id, "jpeg ts=\{ts} bytes=\{data.length()}")
}

///|
fn FakeHost::st_show(self : FakeHost, id : Int, ts : Double) -> Unit {
  fake_fed(self, id, "show ts=\{ts}")
}

///|
fn FakeHost::st_codec(self : FakeHost, id : Int, cmd : String, data : Bytes) -> Unit {
  fake_fed(self, id, if data.length() > 0 { "do \{cmd} bytes=\{data.length()}" } else { "do \{cmd}" })
}

///|
fn FakeHost::st_close(self : FakeHost, id : Int) -> Unit {
  fake_fed(self, id, "close")
}

///|
/// A route's frames (@hostapi.stream_direct: `flags` 1 video, 2 audio; none, the route let go of: 0).
fn FakeHost::st_direct(self : FakeHost, id : Int, route : Double, after : Double, flags : Int) -> Unit {
  let video = (flags & 1) != 0
  let audio = (flags & 2) != 0
  let r = if video || audio { route.to_int() } else { 0 }
  fake_fed(self, id, "route \{r} after=\{after} video=\{video} audio=\{audio}")
}

///|
fn FakeHost::st_audio(self : FakeHost, id : Int, data : Bytes) -> Unit {
  fake_fed(self, id, "audio bytes=\{data.length()}")
}

///|
/// The pointer's picture said by the name the app gives it, its size and hot spot in points.
fn FakeHost::st_pointer_named(self : FakeHost, id : Int, key : String, _ : () -> Bytes, w : Double, h : Double, hx : Double, hy : Double) -> Unit {
  let z = window_zoom_drawn.val
  fake_fed(self, id, "pointer \{key} \{w / z}x\{h / z} hot=\{hx / z},\{hy / z}")
}

///|
fn FakeHost::st_pointer_at(self : FakeHost, id : Int, x : Double, y : Double, shown : Int) -> Unit {
  fake_fed(self, id, if shown != 0 { "pointer at \{x} \{y}" } else { "pointer none" })
}

///|
/// Stream `id`'s next event, as the test or the run said it.
fn FakeHost::st_next(self : FakeHost, id : Int) -> String {
  match self.stream_said.get(id) {
    Some(q) if q.length() > 0 => q.remove(0)
    _ => ""
  }
}

///|
/// Whether it decodes H.264 (Tester::new's `h264`).
fn FakeHost::st_h264_here(self : FakeHost) -> Int {
  if self.h264 {
    1
  } else {
    0
  }
}

///|
/// Whether it decodes H.265 (Tester::set_h265).
fn FakeHost::st_h265_here(self : FakeHost) -> Int {
  if self.h265_here {
    1
  } else {
    0
  }
}

///|
/// Whether it decodes AV1 (Tester::set_av1).
fn FakeHost::st_av1_here(self : FakeHost) -> Int {
  if self.av1_here {
    1
  } else {
    0
  }
}

///|
/// Whether its H.264 decoder is driven from the app (Tester::set_stream_feeds).
fn FakeHost::st_feeds(self : FakeHost) -> Int {
  if self.stream_feeds {
    1
  } else {
    0
  }
}

///|
/// Its streams' system video layers (Tester::set_stream_layers): 0 none, 1 in a stream's tagged colours, 2 in sRGB
/// (Tester::set_stream_layers_srgb).
fn FakeHost::st_layers(self : FakeHost) -> Int {
  if !self.stream_layers {
    0
  } else if self.stream_layers_srgb {
    2
  } else {
    1
  }
}

///|
/// Whether it plays a remote screen's audio (Tester::set_stream_audio).
fn FakeHost::st_audio_here(self : FakeHost) -> Int {
  if self.audio_here {
    1
  } else {
    0
  }
}

///|
/// As a frame begins: its pages run what was sent to them once they are there.
fn Tester::fake_pages_run(self : Tester) -> Unit {
  for v in open_views {
    fake_scripts_flush(self.fake, v.id)
  }
}

///|
/// What was posted to it (fake_post) since a frame took the last: how many, taken one by one (post_next).
fn FakeHost::post_take(_ : FakeHost) -> Int {
  fake_posted.length()
}

///|
fn FakeHost::post_next(_ : FakeHost) -> (String, String, Bytes)? {
  if fake_posted.is_empty() {
    return None
  }
  let (channel, json, b) = fake_posted.remove(0)
  Some((channel, json, b.unwrap_or(Bytes::make(0, b'\x00'))))
}

// The app's own calls of its host (@hostapi native.mbt; @ui's native_call.mbt) as a test has them: each waits until
// the test answers it (Tester::answer_native, refuse_native), or answered as it is asked (Tester::native_answers) or by
// an answer given before it (held: a replay's NATIVESAID), each told at that moment as a host's event tells it
// (FakeHost::due: after the event that asked or answered, before the clock moves on).

///|
/// A call asked (its id, from 1: its place).
fn FakeHost::ncall_call(self : FakeHost, name : String, params : String) -> Int {
  let params = @json.parse(params) catch { _ => Json::string(params) }
  let ask : FakeNative = { name, params, answer: None, said: false }
  let mut held = -1
  for i, h in self.dev.native_held {
    if h.0 == name {
      held = i
      break
    }
  }
  if held >= 0 {
    ask.answer = Some(self.dev.native_held.remove(held).1)
  } else {
    match self.dev.native_auto.get(name) {
      Some(answer) => ask.answer = Some(answer(params))
      None => ()
    }
  }
  self.dev.natives.push(ask)
  let id = self.dev.natives.length()
  if ask.answer is Some(_) {
    fake_native_due(self, id)
  }
  id
}

///|
/// Call `id`'s answer, once its host's event told it (fake_native_due).
fn FakeHost::native_given(self : FakeHost, id : Int) -> Result[Json, String]? {
  guard self.dev.natives.get(id - 1) is Some(a) && a.said else { return None }
  a.answer
}

///|
/// How call `id` goes: 0 waiting, 1 answered, 2 refused.
fn FakeHost::ncall_state(self : FakeHost, id : Int) -> Int {
  match self.native_given(id) {
    Some(Ok(_)) => 1
    Some(Err(_)) => 2
    None => 0
  }
}

///|
/// Its answer's JSON, or why it was refused.
fn FakeHost::ncall_result(self : FakeHost, id : Int) -> String {
  match self.native_given(id) {
    Some(Ok(j)) => j.stringify()
    Some(Err(why)) => why
    None => ""
  }
}

///|
/// Its answers come by the frame after they were asked or given (Tester::finish where the test says when), told by
/// no event; but what was picked and a native call's answer, told at their moment as a host's event tells them
/// (fake_pick_said, fake_native_due), and the marks' drawings where the test answers them by hand
/// (Tester::marks_by_hand), told so (Tester::marks_answer).
fn FakeHost::answers_by_frame(self : FakeHost, kind : Int) -> Bool {
  kind != outside_pick &&
  kind != outside_native &&
  !(kind == outside_marks && self.marks_by_hand)
}

///|
/// What it answers at a moment is told as a host's event (on_outside); the rest by the frame (answers_by_frame).
fn FakeHost::set_outside(_ : FakeHost, _ : FuncRef[(Int, Int, Int) -> Unit]) -> Bool {
  true
}

///|
/// A test's finger (kinds as on_pointer's: 0 down, 1 moved, 2 up, 3 called off; 4, 5, 6 a second finger; 8 the first
/// let go, the second the first from here), taken as a host takes it where a page's view is.
fn finger(kind : Int, x : Double, y : Double) -> Unit {
  // (what was posted before this input told first, at its moment: posted_tell)
  posted_tell()
  let f = match fake.val {
    Some(f) => f
    None => return on_pointer(kind, x, y, 0)
  }
  if kind == 0 {
    let (id, mode, _) = fake_view_under(f, x, y)
    if id > 0 && mode != "through" {
      f.touch_view = id
      f.touch_down = (x, y)
      f.touch_at = (x, y)
      f.touch_sideways = false
      f.views.push("finger \{id} down \{x} \{y}")
      return
    }
    f.touch_view = 0
    return on_pointer(kind, x, y, 0)
  }
  let id = f.touch_view
  if id == 0 {
    return on_pointer(kind, x, y, 0)
  }
  let (mode, slop) = f.view_touch.get(id).unwrap_or(("all", 0.0))
  let (dx0, dy0) = f.touch_down
  let taken = match kind {
    1 =>
      mode == "vertical" &&
      !f.touch_sideways &&
      (y - dy0).abs() > slop &&
      (y - dy0).abs() > (x - dx0).abs()
    4 => mode == "pinch"
    _ => false
  }
  if taken {
    // the page's no more: called off there, the canvas's from where it went down (a pinch's first finger then where it
    // is now, before the second comes down)
    f.views.push("finger \{id} cancel")
    f.touch_view = 0
    on_pointer(0, dx0, dy0, 0)
    if kind == 4 {
      on_pointer(1, f.touch_at.0, f.touch_at.1, 0)
    }
    on_pointer(kind, x, y, 0)
    return
  }
  if kind == 1 {
    f.touch_at = (x, y)
    // sideways first: the page's to the end of the touch
    if mode == "vertical" && (x - dx0).abs() > slop {
      f.touch_sideways = true
    }
  }
  let name = match kind {
    1 => "move"
    2 => "up"
    3 => "cancel"
    4 => "second down"
    5 => "second move"
    _ => "second up"
  }
  f.views.push("finger \{id} \{name} \{x} \{y}")
  if kind == 2 || kind == 3 {
    f.touch_view = 0
  }
}

///|
/// A test's wheel, taken as a host takes it over a page's view: the page's (All, PinchOut), the canvas's (Through,
/// VerticalOut: its upright scroll).
fn finger_wheel(x : Double, y : Double, dx : Double, dy : Double, phase : Int) -> Unit {
  match fake.val {
    Some(f) => {
      let (id, mode, _) = fake_view_under(f, x, y)
      if id > 0 && (mode == "all" || mode == "pinch") {
        f.views.push("wheel \{id} \{dx} \{dy}")
        return
      }
    }
    None => ()
  }
  posted_tell()
  on_wheel(x, y, dx, dy, phase)
}

///|
/// What a script tells its system, its native views' host, its keyboard and its pickers, done as told (drive.mbt).
fn FakeHost::script_step(self : FakeHost, step : String, arg : String) -> String {
  match step {
    "system" => {
      fake_post(self, @hostapi.system_channel, arg, None)
      ""
    }
    "viewsaid" => {
      // (what the host says of its native views comes from outside: frame_watch.mbt)
      outside_counted()
      if fake_view_said(self, arg) {
        ""
      } else {
        "viewsaid: not a line of what a native view's host says: " + arg
      }
    }
    "appsaid" => {
      // (what the app's own native call `NAME` says from here on, `NAME TEXT`, as a device's host comes to say it:
      // changed outside the app, posted on its channel as the host tells it, app_calls.h)
      match arg.find(" ") {
        Some(i) => {
          let name = arg[:i].to_owned()
          self.app_said[name] = arg[i + 1:].to_owned()
          fake_post(self, name, "{}", None)
          ""
        }
        None => "appsaid: NAME TEXT, not " + arg
      }
    }
    "ime" => {
      self.dev.ime_inset = number(arg)
      self.wants = true
      ""
    }
    // (what the clipboard holds as the app next reads it: Tester::clipboard_gives)
    "clip" => {
      fake_clip_give(self, { text: arg, picture: NoPicture, files: [] })
      ""
    }
    "picks" => {
      self.picks.clear()
      for part in arg.split(" ") {
        match part.rev_find(":") {
          Some(i) => {
            // (NAME:SIZE so many bytes; NAME:WxH a picture so many pixels across and down, as a picker gives a
            // photo: its bytes a PNG's)
            let said = part[i + 1:].to_owned()
            let bytes = match said.find("x") {
              Some(k) => picked_picture(digits_of(said.unsafe_substring(start=0, end=k)), digits_of(said.unsafe_substring(start=k + 1, end=said.length())))
              None => Bytes::make(digits_of(said), b'x')
            }
            self.picks.push({ name: part[:i].to_owned(), bytes, held: 0, size: bytes.length().to_double(), src: "" })
          }
          None => ()
        }
      }
      ""
    }
    _ => "\{step}: the Tester's host takes no such step of a script"
  }
}

///|
/// The number `s`'s digits say.
fn digits_of(s : String) -> Int {
  let mut n = 0
  for ch in s {
    n = n * 10 + (ch.to_int() - 48)
  }
  n
}

///|
/// A picture `w` by `h` picked (FakeHost's `picks`): a PNG of a sky over ground, the same every run.
fn picked_picture(w : Int, h : Int) -> Bytes {
  let w = if w < 1 { 1 } else { w }
  let h = if h < 1 { 1 } else { h }
  let px = FixedArray::make(w * h * 4, b'\xff')
  for y in 0..<h {
    for x in 0..<w {
      let at = (y * w + x) * 4
      let sky = y * 2 < h
      let r = if sky { 120 + x * 80 / w } else { 70 + y * 40 / h }
      let g = if sky { 170 + y * 60 / h } else { 120 + x * 30 / w }
      let b = if sky { 230 } else { 60 }
      px[at] = r.to_byte()
      px[at + 1] = g.to_byte()
      px[at + 2] = b.to_byte()
    }
  }
  @pixels.png(w, h, px)
}

///|
/// It keeps groups of instances, as every platform's host does: drawn out as it is handed them (present); none where
/// the test says so (Tester::set_groups), as the web's host.
fn FakeHost::groups_here(self : FakeHost) -> Bool {
  self.groups
}

///|
/// A list's rows set on its pixels as every platform's host sets them, where the test says so
/// (Tester::set_rows_on_pixels).
fn FakeHost::rows_on_pixels(self : FakeHost) -> Bool {
  self.rows_on_pixels
}

///|
/// The window's tree keeps where in the source each node was made, for what a test finds to say where to change it
/// (view's source.mbt), unless the test runs it as a device does (Tester::new's `keeps_sources`).
fn FakeHost::keeps_sources(self : FakeHost) -> Bool {
  self.keeps_sources
}

///|
/// Over a host's kept text, as that host said of its fonts (any of them), asked of nothing new; else not.
fn FakeHost::lines_on_pixels(_ : FakeHost) -> Bool {
  match text_table.val {
    Some(t) => t.metrics.values().any(fn(r) { r.length() > 5 && r[5] == 1.0 })
    None => false
  }
}

///|
/// What the fake host was posted and has not told yet, told now, between frames: before its clock moves on (a frame
/// drawn later, the clock advanced) and before an input it is given, so at the moment it was posted, as a device's host
/// tells it as it is posted (MB_OUTSIDE_POSTED), not as the next frame begins. What is posted at one moment is told as
/// one, in the order posted, as a device's host takes all that came by the time it is told (messages_between).
fn posted_tell() -> Unit {
  if in_frame.val || frame_running.val {
    return
  }
  if fake_posted.length() > 0 {
    on_outside(outside_posted, 0, 0)
  }
  // (and what the fake host does at a moment of its own come by now: FakeHost::due, each as one event, in its order)
  let now = match fake.val {
    Some(f) => f.time
    None => return
  }
  while fake_dues.length() > 0 && fake_dues[0].0 <= now + 1.0e-9 {
    let (_, _, _, f) = fake_dues.remove(0)
    f()
    if fake_posted.length() > 0 {
      on_outside(outside_posted, 0, 0)
    }
  }
}

///|
/// `f` done `ms` from now between frames, as what comes from outside comes then (a made-up core's answer across no
/// thread: an app's fixture): under a Tester its fake host's moment (FakeHost::due), told at it however the clock is run
/// on; on a device's host the window's runtime's timer. `what` names it.
pub fn later_between_frames(ms : Double, what : String, f : () -> Unit) -> Unit {
  match fake.val {
    Some(h) => h.due(h.time + ms, what, f)
    None => runtime().after(ms.ceil().to_int(), f)
  }
}

///|
/// A message on `channel` from what stands for the outside in this process (a made-up core answering across no thread:
/// an app's fixture), posted as a host's is: under a Tester to its fake host, told between frames at its moment with
/// all posted then (posted_tell); on a device's host taken as messages_between takes a post, what changes only signals
/// now and the rest left for the next frame, which it asks for (in a frame, left for the next). So what a test's made-up
/// core says reaches the app by the path a device's core's does.
pub fn outside_post(channel : String, json : String) -> Unit {
  match fake.val {
    // (told by what is telling the fake host's moments now, posted_tell, or as its clock moves on)
    Some(h) => fake_post(h, channel, json, None)
    None => {
      if frame_running.val {
        messages_in.push((channel, json, None))
        outside_left()
        return
      }
      messages_take([(channel, json, None)])
      if messages_in.length() > 0 {
        outside_left()
      }
    }
  }
}

///|
/// A frame of the fake host's ended: what it is to do by now (FakeHost::due: asked of it as the frame was made, at the
/// frame's moment) done now, between frames, before anything else comes, and what was posted with it (posted_tell),
/// as a device's host answers after the frame that asked. Nothing of the frame's posted else is told here: that waits,
/// as ever, for the clock to move or an input.
fn fake_dues_after_frame(f : FakeHost) -> Unit {
  if fake_dues.length() > 0 && fake_dues[0].0 <= f.time + 1.0e-9 {
    posted_tell()
  }
}

///|
/// What the fake host is to do at moments of its clock (FakeHost::due): when, in what order said, what (named for what
/// says it), done.
// kept across runs: emptied by each Tester (Tester::new)
let fake_dues : Array[(Double, Int, String, () -> Unit)] = []

///|
// kept across runs: only counted on
let fake_due_count : Ref[Int] = Ref(0)

///|
/// `f` done by the fake host at `at` on its clock, between frames, as an event from outside that comes then (a picked
/// file, a native call's answer, an operation done, as a device's host tells each at its moment): at the moment the
/// clock comes to it, however it is run on (run_for and come_to stop there at any rate of frames), after what is
/// going on now where `at` is now; several at one moment in the order said. `what` names it where it is said.
pub fn FakeHost::due(self : FakeHost, at : Double, what : String, f : () -> Unit) -> Unit {
  ignore(self)
  fake_due_count.val += 1
  let entry = (at, fake_due_count.val, what, f)
  let mut i = fake_dues.length()
  while i > 0 && (fake_dues[i - 1].0 > at || (fake_dues[i - 1].0 == at && fake_dues[i - 1].1 > entry.1)) {
    i -= 1
  }
  fake_dues.insert(i, entry)
}

///|
/// The fake host's next moment of its own (FakeHost::due) after `now`, +inf none.
fn fake_due_next(now : Double) -> Double {
  for d in fake_dues {
    if d.0 > now {
      return d.0
    }
  }
  @double.infinity
}

///|
/// The fake host's clock on to each of its moments (FakeHost::due) up to `t`, what is due at each done there, before the
/// clock goes on.
fn fake_dues_to(f : FakeHost, t : Double) -> Unit {
  while !in_frame.val && !frame_running.val && fake_dues.length() > 0 && fake_dues[0].0 <= t + 1.0e-9 {
    if fake_dues[0].0 > f.time {
      f.time = fake_dues[0].0
    }
    posted_tell()
  }
}

///|
/// Closure table view of this fake host, built once per Tester run.
fn FakeHost::as_host(self : FakeHost) -> @hostapi.Host {
  let h = @hostapi.Host::noop()
  h.install_package = fn(a0, a1) { self.install_package(a0, a1) }
  h.window_show = fn() { self.window_show() }
  h.auto_launch = fn() { self.auto_launch() }
  h.set_auto_launch = fn(a0) { self.set_auto_launch(a0) }
  h.hotkey_set = fn(a0, a1) { self.hotkey_set(a0, a1) }
  h.hotkey_clear = fn(a0) { self.hotkey_clear(a0) }
  h.reduce_motion = fn() { self.reduce_motion() }
  h.display_hz = fn() { self.display_hz() }
  h.drive = fn(a0, a1) { self.drive(a0, a1) }
  h.exit = fn(a0) { self.exit(a0) }
  h.update_fetch = fn(a0, a1, a2, a3, a4, a5) { self.update_fetch(a0, a1, a2, a3, a4, a5) }
  h.update_apply = fn(a0) { self.update_apply(a0) }
  h.update_state = fn() { self.update_state() }
  h.pk_start = fn(a0) { self.pk_start(a0) }
  h.pk_photo = fn(a0) { self.pk_photo(a0) }
  h.pk_state = fn(a0) { self.pk_state(a0) }
  h.pk_count = fn(a0) { self.pk_count(a0) }
  h.pk_name = fn(a0, a1) { self.pk_name(a0, a1) }
  h.pk_bytes = fn(a0, a1) { self.pk_bytes(a0, a1) }
  h.pk_info = fn(a0, a1) { self.pk_info(a0, a1) }
  h.pk_end = fn(a0) { self.pk_end(a0) }
  h.kp_begin = fn(a0, a1, a2) { self.kp_begin(a0, a1, a2) }
  h.kp_append = fn(a0, a1) { self.kp_append(a0, a1) }
  h.kp_finish = fn(a0) { self.kp_finish(a0) }
  h.kp_state = fn(a0) { self.kp_state(a0) }
  h.kp_where = fn(a0) { self.kp_where(a0) }
  h.kp_end = fn(a0) { self.kp_end(a0) }
  h.now = fn() { self.now() }
  h.wall_ms = fn() { self.wall_ms() }
  h.clock_at_wall = Some(fn(a0) { self.clock_at_wall(a0) })
  h.event_time = fn() { self.event_time() }
  h.event_finger = fn() { self.event_finger() }
  h.frame_late = fn() { self.frame_late() }
  h.platform = fn() { self.platform() }
  h.keys_platform = fn() { self.keys_platform() }
  h.request_frame = fn() { self.request_frame() }
  h.request_frame_on = Some(fn() { self.request_frame_on() })
  h.frames_paced = Some(fn(a0) { self.frames_paced(a0) })
  h.wake_after = fn(a0) { self.wake_after(a0) }
  h.font_metrics = fn(a0, a1, a2, a3) { self.font_metrics(a0, a1, a2, a3) }
  h.words_spaced = Some(fn() { self.words_spaced() })
  h.shape = fn(a0, a1, a2, a3, a4) { self.shape(a0, a1, a2, a3, a4) }
  h.text_key = fn(a0, a1, a2, a3) { self.text_key(a0, a1, a2, a3) }
  h.glyphs_ahead = fn(a0, a1) { self.glyphs_ahead(a0, a1) }
  h.glyphs_ahead_able = fn() { self.glyphs_ahead_able() }
  h.glyph = fn(a0, a1) { self.glyph(a0, a1) }
  h.glyph_put = fn(a0, a1, a2) { self.glyph_put(a0, a1, a2) }
  h.glyph_picture = fn(a0, a1) { self.glyph_picture(a0, a1) }
  h.atlas_put = fn(a0, a1, a2, a3, a4) { self.atlas_put(a0, a1, a2, a3, a4) }
  h.atlas_size = fn(a0) { self.atlas_size(a0) }
  h.face_add = fn(a0, a1, a2) { self.face_add(a0, a1, a2) }
  h.face_add_bytes = fn(a0, a1, a2) { self.face_add_bytes(a0, a1, a2) }
  h.face_clear = fn(a0) { self.face_clear(a0) }
  h.face_add_family = fn(a0, a1) { self.face_add_family(a0, a1) }
  h.has_local_fonts = fn() { self.has_local_fonts() }
  h.local_font_families = fn() { self.local_font_families() }
  h.face_set_ligatures = fn(a0, a1) { self.face_set_ligatures(a0, a1) }
  h.set_host_autospace = fn(a0) { self.set_host_autospace(a0) }
  h.local_font_info = fn() { self.local_font_info() }
  h.has_async_local_font_info = fn() { self.has_async_local_font_info() }
  h.atlas_generation = fn() { self.atlas_generation() }
  h.reduce_transparency = fn() { self.reduce_transparency() }
  h.increase_contrast = fn() { self.increase_contrast() }
  h.thermal_throttled = fn() { self.thermal_throttled() }
  h.perf_state = fn() { self.perf_state() }
  h.set_perf = fn(a0) { self.set_perf(a0) }
  h.perf_line = fn(a0) { self.perf_line(a0) }
  h.perf_where = fn() { self.perf_where() }
  h.reveal_file = fn(a0, a1) { self.reveal_file(a0, a1) }
  h.perf_open = fn(a0) { self.perf_open(a0) }
  h.perf_size = fn() { self.perf_size() }
  h.set_ime = fn(a0, a1, a2, a3, a4, a5, a6, a7) { self.set_ime(a0, a1, a2, a3, a4, a5, a6, a7) }
  h.text_menu = fn(a0, a1, a2, a3, a4, a5) { self.text_menu(a0, a1, a2, a3, a4, a5) }
  h.text_menu_own = fn(a0) { self.text_menu_own(a0) }
  h.edit_can = fn(a0) { self.edit_can(a0) }
  h.clipboard_set = fn(a0) { self.clipboard_set(a0) }
  h.clipboard_set_html = Some(fn(a0, a1) { self.clipboard_set_html(a0, a1) })
  h.word_at = fn(a0, a1) { self.word_at(a0, a1) }
  h.open_url = fn(a0) { self.open_url(a0) }
  h.open_tab = fn(a0) { self.open_tab(a0) }
  h.back_enabled = fn(a0) { self.back_enabled(a0) }
  h.wheel_kept = fn(a0) { self.wheel_kept(a0) }
  h.a11y_on = fn() { self.a11y_on() }
  h.a11y_tree = fn(a0) { self.a11y_tree(a0) }
  h.log = fn(a0) { self.log(a0) }
  h.image_load = fn(a0, a1) { self.image_load(a0, a1) }
  h.image_load_bytes = fn(a0, a1) { self.image_load_bytes(a0, a1) }
  h.image_info = fn(a0, a1) { self.image_info(a0, a1) }
  h.image_pixels = fn(a0, a1) { self.image_pixels(a0, a1) }
  h.drawn_pixels = fn(a0, a1, a2, a3, a4) { self.drawn_pixels(a0, a1, a2, a3, a4) }
  h.drawn_pixels_of = fn(a0, a1, a2, a3, a4, a5, a6, a7, a8) { self.drawn_pixels_of(a0, a1, a2, a3, a4, a5, a6, a7, a8) }
  h.image_free = fn(a0) { self.image_free(a0) }
  h.view_open = fn(a0, a1) { self.view_open(a0, a1) }
  h.view_place = fn(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13) { self.view_place(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13) }
  h.view_close = fn(a0) { self.view_close(a0) }
  h.view_control = fn(a0, a1, a2) { self.view_control(a0, a1, a2) }
  h.view_info = fn(a0, a1) { self.view_info(a0, a1) }
  h.view_site_next = fn(a0) { self.view_site_next(a0) }
  h.view_tell = fn(a0, a1, a2) { self.view_tell(a0, a1, a2) }
  h.view_site_body = fn(a0, a1) { self.view_site_body(a0, a1) }
  h.view_site_head = fn(a0, a1, a2, a3) { self.view_site_head(a0, a1, a2, a3) }
  h.view_site_chunk = fn(a0, a1, a2) { self.view_site_chunk(a0, a1, a2) }
  h.view_site_end = fn(a0, a1, a2) { self.view_site_end(a0, a1, a2) }
  h.view_site_state = fn(a0) { self.view_site_state(a0) }
  h.view_text = fn(a0, a1) { self.view_text(a0, a1) }
  h.view_still = fn(a0) { self.view_still(a0) }
  h.view_site_load = fn(a0, a1) { self.view_site_load(a0, a1) }
  h.view_read_next = fn(a0, a1) { self.view_read_next(a0, a1) }
  h.view_read_answer = fn(a0, a1, a2, a3, a4) { self.view_read_answer(a0, a1, a2, a3, a4) }
  h.pdf_open = fn(a0) { self.pdf_open(a0) }
  h.pdf_pages = fn(a0) { self.pdf_pages(a0) }
  h.pdf_page_size = fn(a0, a1, a2) { self.pdf_page_size(a0, a1, a2) }
  h.pdf_page_load = fn(a0, a1, a2) { self.pdf_page_load(a0, a1, a2) }
  h.pdf_close = fn(a0) { self.pdf_close(a0) }
  h.set_cursor = fn(a0) { self.set_cursor(a0) }
  h.set_badge = fn(a0) { self.set_badge(a0) }
  h.app_said = fn(a0) { self.app_said(a0) }
  h.app_tell = fn(a0, a1) { self.app_tell(a0, a1) }
  h.mods_held = fn() { self.mods_held() }
  h.pointer_lock = fn(a0) { self.pointer_lock(a0) }
  h.pointer_locked = fn() { self.pointer_locked() }
  h.pointer_delta = fn(a0) { self.pointer_delta(a0) }
  h.gamepads = fn(a0) { self.gamepads(a0) }
  h.window_drag = fn() { self.window_drag() }
  h.window_act = fn(a0) { self.window_act(a0) }
  h.window_zoomed = fn() { self.window_zoomed() }
  h.window_snap = fn(a0, a1, a2, a3) { self.window_snap(a0, a1, a2, a3) }
  h.window_snap_state = fn() { self.window_snap_state() }
  h.window_opens = fn() { self.window_opens() }
  h.window_open = fn(a0) { self.window_open(a0) }
  h.window_front = fn(a0) { self.window_front(a0) }
  h.windows_in_process = fn() { self.windows_in_process() }
  h.window_open_id = fn(a0) { self.window_open_id(a0) }
  h.window_set_title = fn(a0, a1) { self.window_set_title(a0, a1) }
  h.window_front_id = fn(a0) { self.window_front_id(a0) }
  h.window_close_id = fn(a0) { self.window_close_id(a0) }
  h.window_current = fn() { self.window_current() }
  h.shared_in = fn() { self.shared_in() }
  h.shared_in_file = fn(a0) { self.shared_in_file(a0) }
  h.share = fn(a0, a1, a2, a3) { self.share(a0, a1, a2, a3) }
  h.mk_start = fn(a0, a1) { self.mk_start(a0, a1) }
  h.mk_state = fn(a0) { self.mk_state(a0) }
  h.mk_png = fn(a0) { self.mk_png(a0) }
  h.own_clock = fn() { self.own_clock() }
  h.system_dark = fn() { self.system_dark() }
  h.font_scale = fn() { self.font_scale() }
  h.utc_offset_min = fn(a0) { self.utc_offset_min(a0) }
  h.pointing = fn() { self.pointing() }
  h.native_pointing = fn() { self.native_pointing() }
  h.keyboard = fn() { self.keyboard() }
  h.window_inset = fn() { self.window_inset() }
  h.full_screen = fn() { self.full_screen() }
  h.set_full_screen = fn(a0) { self.set_full_screen(a0) }
  h.window_buttons_down = fn(a0, a1) { self.window_buttons_down(a0, a1) }
  h.window_corner = fn() { self.window_corner() }
  h.window_corner_at = Some(fn(a0) { self.window_corner_at(a0) })
  h.nv_able = fn() { self.nv_able() }
  h.nv_bar = fn(a0) { self.nv_bar(a0) }
  h.env = fn(a0) { self.env(a0) }
  h.app_version = fn() { self.app_version() }
  h.clipboard_set_secret = fn(a0, a1) { self.clipboard_set_secret(a0, a1) }
  h.clipboard_secret_off = fn() { self.clipboard_secret_off() }
  h.clipboard_set_image = fn(a0) { self.clipboard_set_image(a0) }
  h.present = fn(a0, a1, a2, a3, a4) { self.present(a0, a1, a2, a3, a4) }
  h.over_done = fn(a0) { self.over_done(a0) }
  h.hold_words = fn(a0, a1, a2) { self.hold_words(a0, a1, a2) }
  h.cs_known = fn(a0) { self.cs_known(a0) }
  h.cs_decode = fn(a0, a1) { self.cs_decode(a0, a1) }
  h.ga_access = fn() { self.ga_access() }
  h.ga_read = fn() { self.ga_read() }
  h.ga_read_state = fn(a0) { self.ga_read_state(a0) }
  h.ga_read_rows = fn(a0) { self.ga_read_rows(a0) }
  h.ga_read_end = fn(a0) { self.ga_read_end(a0) }
  h.pw_able = fn() { self.pw_able() }
  h.pw_run = fn(a0) { self.pw_run(a0) }
  h.pw_out = fn(a0) { self.pw_out(a0) }
  h.pw_end = fn(a0) { self.pw_end(a0) }
  h.af_able = fn() { self.af_able() }
  h.af_ask = fn(a0) { self.af_ask(a0) }
  h.af_take = fn() { self.af_take() }
  h.af_end = fn() { self.af_end() }
  h.wa_able = fn() { self.wa_able() }
  h.wa_get = fn(a0) { self.wa_get(a0) }
  h.wa_out = fn(a0) { self.wa_out(a0) }
  h.wa_end = fn(a0) { self.wa_end(a0) }
  h.dv_haptic = fn(a0) { self.dv_haptic(a0) }
  h.dv_keep_awake = fn(a0) { self.dv_keep_awake(a0) }
  h.dv_copy_shown = fn() { self.dv_copy_shown() }
  h.dv_key_catch = fn(a0) { self.dv_key_catch(a0) }
  h.dv_ime_inset = fn() { self.dv_ime_inset() }
  h.dv_ime_action = fn(a0) { self.dv_ime_action(a0) }
  h.dv_ime_let_go = fn() { self.dv_ime_let_go() }
  h.cl_set = fn(a0, a1, a2) { self.cl_set(a0, a1, a2) }
  h.cl_read = fn() { self.cl_read() }
  h.cl_state = fn(a0) { self.cl_state(a0) }
  h.cl_text = fn(a0) { self.cl_text(a0) }
  h.cl_picture = fn(a0) { self.cl_picture(a0) }
  h.cl_png = fn(a0) { self.cl_png(a0) }
  h.cl_files = fn(a0) { self.cl_files(a0) }
  h.cl_file_name = fn(a0, a1) { self.cl_file_name(a0, a1) }
  h.cl_file = fn(a0, a1) { self.cl_file(a0, a1) }
  h.nt_show = fn(a0, a1, a2, a3, a4) { self.nt_show(a0, a1, a2, a3, a4) }
  h.nt_cancel = fn(a0) { self.nt_cancel(a0) }
  h.nt_state = fn(a0) { self.nt_state(a0) }
  h.nt_text = fn(a0) { self.nt_text(a0) }
  h.st_open = fn() { self.st_open() }
  h.st_h264 = fn(a0, a1, a2, a3) { self.st_h264(a0, a1, a2, a3) }
  h.st_hevc = fn(a0, a1, a2, a3) { self.st_hevc(a0, a1, a2, a3) }
  h.st_av1 = fn(a0, a1, a2, a3) { self.st_av1(a0, a1, a2, a3) }
  h.st_frame = fn(a0, a1, a2, a3) { self.st_frame(a0, a1, a2, a3) }
  h.st_frame_shown = Some(fn(a0, a1, a2, a3, a4) { self.st_frame_shown(a0, a1, a2, a3, a4) })
  h.st_flush = fn(a0, a1) { self.st_flush(a0, a1) }
  h.st_audio_played = fn(a0) { self.st_audio_played(a0) }
  h.st_audio_queued = fn(a0) { self.st_audio_queued(a0) }
  h.st_audio_wanted = fn(a0) { self.st_audio_wanted(a0) }
  h.st_audio_volume = fn(a0, a1) { self.st_audio_volume(a0, a1) }
  h.st_jpeg = fn(a0, a1, a2) { self.st_jpeg(a0, a1, a2) }
  h.st_show = fn(a0, a1) { self.st_show(a0, a1) }
  h.st_codec = fn(a0, a1, a2) { self.st_codec(a0, a1, a2) }
  h.st_close = fn(a0) { self.st_close(a0) }
  h.st_direct = fn(a0, a1, a2, a3) { self.st_direct(a0, a1, a2, a3) }
  h.st_audio = fn(a0, a1) { self.st_audio(a0, a1) }
  h.st_pointer_named = Some(fn(a0, a1, a2, a3, a4, a5, a6) { self.st_pointer_named(a0, a1, a2, a3, a4, a5, a6) })
  h.st_pointer_at = fn(a0, a1, a2, a3) { self.st_pointer_at(a0, a1, a2, a3) }
  h.st_next = fn(a0) { self.st_next(a0) }
  h.st_h264_here = fn() { self.st_h264_here() }
  h.st_h265_here = fn() { self.st_h265_here() }
  h.st_av1_here = fn() { self.st_av1_here() }
  h.st_feeds = fn() { self.st_feeds() }
  h.st_layers = fn() { self.st_layers() }
  h.st_audio_here = fn() { self.st_audio_here() }
  h.post_take = fn() { self.post_take() }
  h.post_next = fn() { self.post_next() }
  h.ncall_call = fn(a0, a1) { self.ncall_call(a0, a1) }
  h.ncall_state = fn(a0) { self.ncall_state(a0) }
  h.ncall_result = fn(a0) { self.ncall_result(a0) }
  h.answers_by_frame = fn(a0) { self.answers_by_frame(a0) }
  h.set_outside = fn(a0) { self.set_outside(a0) }
  h.script_step = fn(a0, a1) { self.script_step(a0, a1) }
  h.groups_here = fn() { self.groups_here() }
  h.rows_on_pixels = fn() { self.rows_on_pixels() }
  h.keeps_sources = fn() { self.keeps_sources() }
  h.lines_on_pixels = Some(fn() { self.lines_on_pixels() })
  h.tm_open = fn(a0, a1) { self.tm_open(a0, a1) }
  h.tm_write = fn(a0, a1) { self.tm_write(a0, a1) }
  h.tm_resize = fn(a0, a1, a2, a3, a4) { self.tm_resize(a0, a1, a2, a3, a4) }
  h.tm_modes = fn(a0) { self.tm_modes(a0) }
  h.tm_scroll = fn(a0, a1, a2) { self.tm_scroll(a0, a1, a2) }
  h.tm_select = fn(a0, a1, a2, a3, a4, a5) { self.tm_select(a0, a1, a2, a3, a4, a5) }
  h.tm_text = fn(a0, a1) { self.tm_text(a0, a1) }
  h.tm_mouse = fn(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9) { self.tm_mouse(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9) }
  h.tm_frame = fn(a0, a1) { self.tm_frame(a0, a1) }
  h.tm_close = fn(a0) { self.tm_close(a0) }
  h
}
