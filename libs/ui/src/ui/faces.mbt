// The faces the app's words are set in (@hostapi.face_add): its own words, what people wrote and code each in a face of
// its own, chosen and given here (a file the app has, or fetched), else the system's. A face given (or given up)
// changes how words already shaped measure: what was kept of them is forgotten at once, and they are shaped again
// in it.

///|
/// Three-state CJK companion configuration for a face slot.
/// Only `face_text` may hold `Inherit(scale_override, weight_override)`; all other slots use `ExplicitNone` or
/// `Companion(cjk_slot, scale, weight_off)`.
#derive(Eq, Debug)
pub(all) enum CjkSlotState {
  Inherit(Double?, Int?)
  ExplicitNone
  Companion(Int, Double, Int)
}

///|
/// Which faces are given, 1 to faces_most - 1 (index 0 unused): only a face given changes a style (style_words is set
/// only with a face or text CJK override for it, so what people wrote stays in the app's words' style until one is).
// kept across runs: put back as a run begins (faces_reset)
let faces_given : FixedArray[Bool] = FixedArray::make(@hostapi.faces_most, false)

///|
/// Per-slot CJK companion state, indexed by face slot (1 to faces_most - 1).
// kept across runs: put back as a run begins (faces_reset)
let face_cjk : FixedArray[CjkSlotState] = FixedArray::makei(@hostapi.faces_most, fn(i) {
  if i == @hostapi.face_text {
    Inherit(None, None)
  } else {
    ExplicitNone
  }
})

///|
/// Whether ligatures are disabled per face slot.
// kept across runs: put back as a run begins (faces_reset)
let faces_no_lig : FixedArray[Bool] = FixedArray::make(@hostapi.faces_most, false)

///|
/// Whether CJK/Latin auto-spacing is enabled (controls MoonBit spacing and host autospace toggle).
// kept across runs: put back as a run begins (faces_reset)
let cjk_autospace_on : Ref[Bool] = Ref(true)

///|
/// Reactive cache of `local_font_info()`, updated at frame start when background scan completes.
// kept across runs: put back as a run begins (faces_reset)
let local_font_info_sig : @signals.Signal[String] = @signals.signal("")

///|
/// Whether `local_font_info()` has been requested in this run (so frame start polls for background completion).
// kept across runs: put back as a run begins (faces_reset)
let local_font_info_asked : Ref[Bool] = Ref(false)

///|
/// A font file (at `path`) made part of face `face` (@hostapi.face_ui, face_text, face_code, or 4 to 15 for words that
/// name it: Ctx::rich's `face`), for `weight` (0: a variable file, every weight from it). False when the host could not
/// take it (the face as it was). Every word shaped before is shaped again.
pub fn face_add(face : Int, path : String, weight? : Int = 0) -> Bool {
  if face <= 0 || face >= @hostapi.faces_most {
    return false
  }
  let ok = h_face_add(face, path, weight)
  if ok {
    faces_given[face] = true
    if face >= @hostapi.face_try {
      forget_words_for_face(face)
    } else {
      words_forgotten()
    }
  }
  ok
}

///|
/// As face_add, the font's file being `data`: one the app carries in itself, or fetched and kept.
pub fn face_add_bytes(face : Int, data : Bytes, weight? : Int = 0) -> Bool {
  if face <= 0 || face >= @hostapi.faces_most {
    return false
  }
  let ok = h_face_add_bytes(face, data, weight)
  if ok {
    faces_given[face] = true
    if face >= @hostapi.face_try {
      forget_words_for_face(face)
    } else {
      words_forgotten()
    }
  }
  ok
}

///|
/// Face `face` set in a family installed on this machine (`family`, one of local_font_families'): its every style the
/// system's. False where the host has none of it (the face as it was). Every word shaped before is shaped again.
pub fn face_add_family(face : Int, family : String) -> Bool {
  if face <= 0 || face >= @hostapi.faces_most || family == "" {
    return false
  }
  let ok = h_face_add_family(face, family)
  if ok {
    faces_given[face] = true
    if face >= @hostapi.face_try {
      forget_words_for_face(face)
    } else {
      words_forgotten()
    }
  }
  ok
}

///|
/// Cheap capability check for whether this host supports enumerating locally installed font families (no sync scan).
pub fn can_list_local_fonts() -> Bool {
  @hostapi.has_local_fonts()
}

///|
/// The font families installed on this machine (@hostapi.local_font_families), a JSON array of their names; "" where
/// there is no way to them.
pub fn local_font_families() -> String {
  @hostapi.local_font_families()
}

///|
/// Metadata for locally installed font families as a JSON array (@hostapi.local_font_info); "" if unavailable or still
/// scanning in the background.
pub fn local_font_info() -> String {
  local_font_info_asked.val = true
  let info = h_local_font_info()
  if info != "" && info != local_font_info_sig.untracked() {
    local_font_info_sig.set(info)
  }
  info
}

///|
/// Reactive signal reading `local_font_info()`. Triggers a background scan if not yet started and automatically
/// updates when the host finishes scanning and requests a frame (never writes signals during computed reads).
pub fn local_font_info_signal() -> String {
  let cur = local_font_info_sig.get()
  if cur != "" {
    return cur
  }
  local_font_info_asked.val = true
  @signals.untracked(fn() { h_local_font_info() })
}

///|
/// Whether the host is asynchronously scanning local font metadata in the background (`local_font_info_signal() == ""`
/// on a host with async info). Callers should show a loading indicator instead of blocking the UI thread with
/// synchronous `local_font_families()`.
pub fn local_font_info_loading() -> Bool {
  can_list_local_fonts() && @hostapi.has_async_local_font_info() && local_font_info_signal() == ""
}

///|
/// Called at frame start (`text_arrive`) to propagate completed background `local_font_info()` scans into the reactive
/// signal without requiring user input or mouse movement.
fn local_font_info_arrive() -> Unit {
  if !local_font_info_asked.val || local_font_info_sig.untracked() != "" {
    return
  }
  let info = h_local_font_info()
  if info != "" {
    local_font_info_sig.set(info)
  }
}

///|
/// Assign a CJK companion face slot (`cjk_face`) with optical `scale` (default 1.0) and `weight_off` (default 0)
/// to primary slot `slot`.
pub fn face_set_cjk(
  slot : Int,
  cjk_face : Int,
  scale? : Double = 1.0,
  weight_off? : Int = 0,
) -> Unit {
  if slot <= 0 || slot >= @hostapi.faces_most || cjk_face <= 0 || cjk_face >= @hostapi.face_try {
    return
  }
  let next = Companion(cjk_face, scale, weight_off)
  if face_cjk[slot] != next {
    face_cjk[slot] = next
    words_forgotten()
  }
}

///|
/// Explicitly disable any CJK companion for slot `slot` (breaks `face_text` inheritance from `face_ui`).
pub fn face_set_cjk_none(slot : Int) -> Unit {
  if slot <= 0 || slot >= @hostapi.faces_most {
    return
  }
  if face_cjk[slot] != ExplicitNone {
    face_cjk[slot] = ExplicitNone
    words_forgotten()
  }
}

///|
/// Set slot `slot` (intended for `face_text`) to inherit `face_ui`'s CJK companion, optionally overriding relative
/// `scale_override` and/or `weight_override`.
pub fn face_set_cjk_inherit(
  slot : Int,
  scale_override? : Double,
  weight_override? : Int,
) -> Unit {
  if slot <= 0 || slot >= @hostapi.faces_most {
    return
  }
  let next : CjkSlotState = if slot == @hostapi.face_text {
    Inherit(scale_override, weight_override)
  } else {
    ExplicitNone
  }
  if face_cjk[slot] != next {
    face_cjk[slot] = next
    words_forgotten()
  }
}

///|
/// Enable or disable programming / contextual ligatures on face slot `face`.
pub fn face_set_ligatures(face : Int, on : Bool) -> Unit {
  if face <= 0 || face >= @hostapi.faces_most {
    return
  }
  let no_lig = !on
  if faces_no_lig[face] != no_lig {
    faces_no_lig[face] = no_lig
    h_face_set_ligatures(face, on)
    if face >= @hostapi.face_try {
      forget_words_for_face(face)
    } else {
      words_forgotten()
    }
  }
}

///|
/// Enable or disable CJK/Latin automatic spacing across both host shapers (Core Text) and MoonBit spacing.
pub fn set_cjk_autospace(on : Bool) -> Unit {
  if cjk_autospace_on.val != on {
    cjk_autospace_on.val = on
    h_set_host_autospace(on)
    spaced_said.val = None
    words_forgotten()
  }
}

///|
/// Whether CJK/Latin automatic spacing is currently enabled.
pub fn cjk_autospace() -> Bool {
  cjk_autospace_on.val
}

///|
/// Face `face` given up: its words in the system's face again.
pub fn face_clear(face : Int) -> Unit {
  if face <= 0 || face >= @hostapi.faces_most {
    return
  }
  h_face_clear(face)
  faces_no_lig[face] = false
  if faces_given[face] {
    faces_given[face] = false
    if face >= @hostapi.face_try {
      forget_words_for_face(face)
    } else {
      words_forgotten()
    }
  }
}

///|
/// Whether face `face` is given (face_add).
pub fn face_given(face : Int) -> Bool {
  face > 0 && face < @hostapi.faces_most && faces_given[face]
}

///|
/// Resolve a slot's CJK companion `(cjk_slot, scale, weight_off)` if active and its companion face is given.
fn resolve_slot_cjk(slot : Int) -> (Int, Double, Int)? {
  if slot <= 0 || slot >= @hostapi.faces_most {
    return None
  }
  match face_cjk[slot] {
    ExplicitNone => None
    Companion(cjk_slot, scale, weight_off) =>
      if face_given(cjk_slot) {
        Some((cjk_slot, scale, weight_off))
      } else {
        None
      }
    Inherit(scale_ov, weight_ov) =>
      match face_cjk[@hostapi.face_ui] {
        Companion(cjk_slot, ui_scale, ui_weight_off) if face_given(cjk_slot) =>
          Some((cjk_slot, scale_ov.unwrap_or(ui_scale), weight_ov.unwrap_or(ui_weight_off)))
        _ => None
      }
  }
}

fn quantize_cjk_scale(scale : Double) -> Double {
  if scale == 1.0 {
    1.0
  } else {
    (scale * 100.0).round() / 100.0
  }
}

///|
/// Effective CJK companion `(cjk_slot, scale, weight_off)` for `style` and optional local preview `cjk_override`.
/// Strictly mirrors the 5-platform `face_id` precedence:
/// 1. local preview override (`Some(ov)`),
/// 2. explicit `style_face > 0` (no companion if that face is not given),
/// 3. `style_mono` -> `face_code`,
/// 4. `style_words` -> `face_text` (with `Inherit` falling back to `face_ui`),
/// 5. `style_serif` -> `None` (protects reader Songti),
/// 6. default -> `face_ui`.
fn effective_cjk(style : Int, cjk_override : @view.CjkOverride?) -> (Int, Double, Int)? {
  let raw = match cjk_override {
    Some(ov) =>
      if ov.face > 0 && face_given(ov.face) {
        Some((ov.face, ov.scale, ov.weight_off))
      } else {
        None
      }
    None => {
      let f = @hostapi.face_of_style(style)
      if f > 0 {
        if face_given(f) { resolve_slot_cjk(f) } else { None }
      } else if (style & @hostapi.style_mono) != 0 {
        resolve_slot_cjk(@hostapi.face_code)
      } else if (style & @hostapi.style_serif) != 0 {
        None
      } else if (style & @hostapi.style_words) != 0 {
        resolve_slot_cjk(@hostapi.face_text)
      } else {
        resolve_slot_cjk(@hostapi.face_ui)
      }
    }
  }
  match raw {
    Some((slot, sc, woff)) => Some((slot, quantize_cjk_scale(sc), woff))
    None => None
  }
}

///|
/// Whether `face_text` needs `style_words` set on prose runs: true when `face_text` has its own primary face,
/// or its CJK state is not a plain unmodified inheritance of `face_ui`.
fn text_needs_words_style() -> Bool {
  if face_given(@hostapi.face_text) {
    return true
  }
  match face_cjk[@hostapi.face_text] {
    Inherit(None, None) => false
    Inherit(scale_ov, weight_ov) =>
      match face_cjk[@hostapi.face_ui] {
        Companion(_, ui_scale, ui_weight_off) =>
          scale_ov.unwrap_or(ui_scale) != ui_scale || weight_ov.unwrap_or(ui_weight_off) != ui_weight_off
        _ => scale_ov is Some(_) || weight_ov is Some(_)
      }
    _ => true
  }
}

///|
/// What words in a paragraph said to be `words` (what people wrote) and in `face` (0: none named) add to each run's
/// style: the face named where it is given; what people wrote marked so where a face or text CJK override is set for it.
fn faces_style(words : Bool, face : Int) -> Int {
  (if face == @hostapi.face_sys_default || face_given(face) { @hostapi.style_face(face) } else { 0 }) |
  (if words && text_needs_words_style() { @hostapi.style_words } else { 0 })
}

///|
/// What the host measures words in, as one number that moves on as it changes (the faces given, the host's glyphs'
/// generation: text_arrive): read where words are measured (shape, all_metrics), so that what measured them is
/// measured again as it changes; words laid out before (a text's or a paragraph's, its node's layout kept, a row kept
/// as laid out) are laid out again.
// kept across runs: put back as a run begins (faces_reset)
let words_shaped_in : @signals.Signal[Int] = @signals.signal(0)

///|
/// Number of times `words_forgotten()` has run in the current session (read untracked for zero-invalidation tests).
pub fn words_forgotten_count() -> Int {
  words_shaped_in.untracked()
}

///|
/// Everything shaped and measured forgotten (its faces changed): shaped again as it is next asked for; the window's
/// tree's words measured and drawn again in them at once (view_words_rescaled), as an old view's are laid out again.
fn words_forgotten() -> Unit {
  words_shaped_in.set(words_shaped_in.untracked() + 1)
  clear_shapes()
  text_cache.fonts.clear()
  text_cache.metrics.clear()
  glyphs_forget()
  // (the frame drawn whole, its glyphs other pixels; the host's glyphs as they are now: a face it has later than it is
  // given (a page's, loaded) moves them on again, and what was laid out till then is laid out again (text_frame))
  presented.forget()
  let g = h_atlas_generation()
  atlas_said.val = Some(g)
  text_cache.generation = g
  view_words_rescaled()
}

///|
/// As at the start (a Tester's): no face given.
fn faces_reset() -> Unit {
  words_shaped_in.set(0)
  faces_env_read.val = false
  cjk_autospace_on.val = true
  local_font_info_sig.set("")
  local_font_info_asked.val = false
  for i in 0..<faces_given.length() {
    faces_given[i] = false
    faces_no_lig[i] = false
    face_cjk[i] = if i == @hostapi.face_text { Inherit(None, None) } else { ExplicitNone }
  }
}

///|
/// Whether MBUI_FACES was read (once, as the first frame begins).
let faces_env_read : Ref[Bool] = Ref(false)

///|
/// The faces a run is given from outside, as its first frame begins: MBUI_FACES, `face:path` or `face:path:weight`
/// apart by `;` (a host's own check of a face, a screenshot in it). Nothing without it.
fn faces_from_env() -> Unit {
  if faces_env_read.val {
    return
  }
  faces_env_read.val = true
  for item in h_env("MBUI_FACES").split(";") {
    let parts = item.split(":").map(fn(p) { p.to_owned() }).collect()
    if parts.length() < 2 {
      continue
    }
    match digits(parts[0]) {
      Some(face) =>
        if parts[1] == "local" && parts.length() > 2 {
          ignore(face_add_family(face, parts[2]))
        } else {
          let weight = if parts.length() > 2 { digits(parts[2]).unwrap_or(0) } else { 0 }
          ignore(face_add(face, parts[1], weight~))
        }
      None => ()
    }
  }
}
