// A single way to start a scene for an image or a film: the same view, tree, system, text, pictures and window.

///|
fn scene_tester(
  view : ((@ui.Ctx) -> Unit)?,
  tree : ((@view.View) -> Unit)?,
  w~ : Double,
  h~ : Double,
  scale~ : Double,
  platform~ : Int,
  dark~ : Bool,
  inset~ : Bool,
  window_corner~ : Double,
  corners_held~ : Bool,
  words_over_held~ : Bool,
  theme? : () -> @ui.Theme,
  transitions_only? : Bool,
) -> @ui.Tester {
  // Take the real host before the Tester installs its own. Its text and decoded images are what the renderer draws.
  let host = @hostapi.host()
  init_offscreen(w, h, scale)
  let pointing = match arg("MBUI_POINTING") {
    "finger" => Some(@ui.Pointing::Finger)
    "mouse" => Some(@ui.Pointing::Mouse)
    _ => None
  }
  let native = match arg("MBUI_NATIVE_INPUT") {
    "finger" => Some(@ui.Pointing::Finger)
    "mouse" => Some(@ui.Pointing::Mouse)
    _ => None
  }
  let keyboard = match arg("MBUI_KEYBOARD") {
    "1" => Some(true)
    "0" => Some(false)
    _ => None
  }
  let env = [
    ("MBUI_TEXT_RECORD", "1"),
    ("MBUI_LOCALE", arg("MBUI_LOCALE")),
    ("MBUI_DARK", arg("MBUI_DARK")),
    ("MBUI_GLASS", arg("MBUI_GLASS")),
    // (a picture of words as a shaper that spaces none sets them: hostapi's words_spaced)
    ("MBUI_AUTOSPACE", arg("MBUI_AUTOSPACE")),
  ]
  let live : @ui.Live = { host, turn: fn() { spin(1.0) } }
  let before = fn() {
    let z = @ui.window_zoom()
    set_offscreen_view(w / z, h / z, scale * z)
  }
  let nav_able = arg("MBUI_FILM_NAV_ABLE") == "1"
  // (MBUI_FILM_WINDOWS=1: windows of the run open to the app from its first frame, as its tree is made; below)
  let windows_beside = arg("MBUI_FILM_WINDOWS") == "1"
  let solid_glass = arg("MBUI_GLASS") == "solid"
  let begun = fn() {
    if solid_glass {
      @ui.set_glass_solid(Some(true))
    }
  }
  let t = match (view, tree) {
    (None, Some(make)) =>
      @ui.Tester::tree(
        make,
        w~,
        h~,
        scale~,
        platform~,
        dark~,
        pointing?,
        native?,
        keyboard?,
        env~,
        corners_held~,
        words_over_held~,
        live~,
        before~,
        begun~,
        window_corner~,
        nav_able~,
        windows_beside~,
        theme?,
        transitions_only=transitions_only.unwrap_or(true),
        fanout_limit=0,
        unseen_press_held=false,
      )
    (Some(v), _) =>
      @ui.Tester::new(
        v,
        tree?,
        w~,
        h~,
        scale~,
        platform~,
        dark~,
        pointing?,
        native?,
        keyboard?,
        env~,
        corners_held~,
        words_over_held~,
        live~,
        before~,
        begun~,
        window_corner~,
        nav_able~,
        windows_beside~,
        theme?,
        transitions_only=transitions_only.unwrap_or(false),
      )
    (None, None) =>
      @ui.Tester::tree(
        fn(_) { () },
        w~,
        h~,
        scale~,
        platform~,
        dark~,
        pointing?,
        native?,
        keyboard?,
        env~,
        corners_held~,
        words_over_held~,
        live~,
        before~,
        window_corner~,
        nav_able~,
        windows_beside~,
        theme?,
        transitions_only=transitions_only.unwrap_or(true),
        fanout_limit=0,
        unseen_press_held=false,
      )
  }
  // (as a host builds and lays out: no frame built again keeping no rows to be compared, a list's rows on the
  // device's pixels; film.mbt's head)
  t.check_looks(false)
  t.corners_look(false)
  t.set_rows_on_pixels(true)
  if inset {
    t.set_window_inset(true)
  }
  // (a desktop's file manager shows a file in its folder, as the Finder, Explorer and a Linux desktop's do: none filmed)
  if platform == 0 || platform == 3 || platform == 5 {
    t.set_reveals(true)
  }
  // (MBUI_FILM_WINDOWS=1: the windows the app opens beside its first open in the run, each the scene's size, as on a
  // Mac; MBUI_FILM_WINDOW=N films window N of them: film.mbt's host_frame)
  // (MBUI_FILM_WINDOWS=run: they open as runs of their own, as on Windows and Linux: none filmed here)
  match arg("MBUI_FILM_WINDOWS") {
    "1" => {
      t.set_window_opens(true)
      t.set_windows_in_process(true)
      // (MBUI_FILM_WINDOW_SIZE=WxH: their size, drawn from the picture's top left corner; else the scene's)
      let (bw, bh) = match arg("MBUI_FILM_WINDOW_SIZE").split("x").map(fn(x) { number(x.to_owned()) }).collect() {
        [Some(bw), Some(bh)] => (bw, bh)
        _ => (w, h)
      }
      for k in 1..<16 {
        t.set_window_beside_size(k, bw, bh)
      }
    }
    "run" => t.set_window_opens(true)
    _ => ()
  }
  match number(arg("MBUI_FONT_SCALE")) {
    Some(f) if f > 0.0 => t.set_font_scale(f)
    _ => ()
  }
  // (the font families installed here, as a host lists them: MBUI_FILM_LOCAL_FONTS / MBUI_FILM_LOCAL_FONT_INFO)
  match arg("MBUI_FILM_LOCAL_FONTS") {
    "" => ()
    families => t.set_local_fonts(families)
  }
  match arg("MBUI_FILM_LOCAL_FONT_INFO") {
    "" => ()
    info => t.set_local_font_info(info)
  }
  // (what the app's own native calls say in the scene: MBUI_APP_SAID, a JSON object of a text for each name)
  match (try Some(@json.parse(arg("MBUI_APP_SAID"))) catch { _ => None }) {
    Some(Object(said)) =>
      for name, v in said {
        if v is String(s) {
          t.set_app_said(name, s)
        }
      }
    _ => ()
  }
  t
}

///|
/// What the captured scene cannot draw. A film may show an image while it is still loading, whereas a still must
/// wait for its pending images; a failed decode needed in the frame or a native view's contents cannot be drawn.
fn scene_drawable(t : @ui.Tester, kind : String, pending_ok : Bool) -> Bool {
  if !pending_ok && !t.pending().is_empty() {
    say("\{kind}: images or native views are still pending")
    return false
  }
  let failed = t.failed_images_drawn()
  if !failed.is_empty() {
    for id in failed {
      say("\{kind}: image could not be decoded: \{t.image_src(id)}")
    }
    return false
  }
  // A native web or video view is a hole in mbui's canvas, not content this renderer can draw.
  if !t.holes().is_empty() {
    say("\{kind}: native view content cannot be drawn offscreen")
    return false
  }
  true
}
