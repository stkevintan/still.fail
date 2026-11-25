// What the styles' migration (mbui's ui/style.mbt) must leave as it was, byte for byte: the draw lists of the lock's
// waiting page in each of its states, and of screens with kit's components, narrow and wide, light and dark. Each is
// kept as its length and its FNV-1a hash; one that changes is a change to what is drawn.

///|
fn fnv(s : String) -> String {
  let mut h = 0x811c9dc5U
  for ch in s {
    h = (h ^ ch.to_int().reinterpret_as_uint()) * 0x01000193U
  }
  s.length().to_string() + ":" + h.to_string(radix=16)
}

///|
/// The system a screen this wide is drawn on: a phone's width a phone's (Android: the phone the screens are of), a
/// desktop's the Mac's.
fn platform_of(w : Double) -> Int {
  if w < @sf.medium_from {
    2
  } else {
    0
  }
}

///|
/// The app over fixture `mode`, `w` × `h`, its first frame (and, with `page`, a settings page pushed): the draw list.
fn screen_drawlist(mode : String, w : Double, h : Double, page? : String = "") -> String {
  new_run()
  @settings.reset()
  let src = fixture(mode)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform=platform_of(w))
  if page != "" {
    open_setting(page)
  }
  t.draw()
  t.run_for(@ui.move_most_ms)
  t.drawlist()
}

///|
let style_ref_sizes : Array[(String, Double, Double)] = [("narrow", 390.0, 844.0), ("wide", 1280.0, 800.0)]

///|
test "styles: the lock's waiting page, every state, drawn as before" {
  let out = StringBuilder()
  for state in ["waiting", "finding", "code", "wrong", "checking", "none", "failed", "nocode"] {
    for dark in ["", "-dark"] {
      for size in style_ref_sizes {
        let (name, w, h) = size
        let d = screen_drawlist("lock-" + state + dark, w, h)
        out.write_string(state + dark + " " + name + " " + fnv(d) + "\n")
      }
    }
  }
  // Home narrow top bar only draws progressive scroll-edge glass over the status bar (skipped when status_top == 0).
  // P0 Regular Liquid Glass optics fix restored recipe blur 2.0/2.2 on narrow floating/bar pills.
  inspect(out.to_string(), content=(
    #|waiting narrow 28661:9dcc0326
    #|waiting wide 66023:4112183f
    #|waiting-dark narrow 28580:2b9fb8ac
    #|waiting-dark wide 65852:4a6a3989
    #|finding narrow 46462:1e66d4b0
    #|finding wide 84907:723ded1c
    #|finding-dark narrow 46516:d2078460
    #|finding-dark wide 84871:17a7b16a
    #|code narrow 32639:62388e1f
    #|code wide 70141:42f542a3
    #|code-dark narrow 32515:93b5b629
    #|code-dark wide 69927:72631d87
    #|wrong narrow 28626:966c6484
    #|wrong wide 66161:2649ae81
    #|wrong-dark narrow 28729:dc736e03
    #|wrong-dark wide 66174:f25a5808
    #|checking narrow 35731:39bd582a
    #|checking wide 74132:54bef3
    #|checking-dark narrow 35824:2031e1dd
    #|checking-dark wide 74135:1e5e7a12
    #|none narrow 39497:bf6a48fd
    #|none wide 77132:a85cd953
    #|none-dark narrow 39376:56079d44
    #|none-dark wide 76921:427c396c
    #|failed narrow 23888:b2a8b2a6
    #|failed wide 60819:839fa92d
    #|failed-dark narrow 23891:82cc9622
    #|failed-dark wide 60732:1a404b71
    #|nocode narrow 28661:9dcc0326
    #|nocode wide 66023:4112183f
    #|nocode-dark narrow 28580:2b9fb8ac
    #|nocode-dark wide 65852:4a6a3989
    #|













































  ))
}

///|
test "styles: screens with kit's components (switches, a sheet), drawn as before" {
  let out = StringBuilder()
  for dark in ["", "-dark"] {
    for size in style_ref_sizes {
      let (name, w, h) = size
      let home = screen_drawlist("settings" + dark, w, h, page="home")
      out.write_string("settings" + dark + " " + name + " " + fnv(home) + "\n")
      // (a station's page made once: what lies in the window drawn as the old list drew it, each of the four drawn to a
      // picture the same to the byte as main's at 16203ebae7, every glyph shown in the same box and every word seen at
      // the same place; the tree also hands the draw list the rows wholly under the window's foot, cut out by the page's
      // clip, and the shapes they draw, which the old list never drew)
      let station = screen_drawlist("settings" + dark, w, h, page="station:ws1/st1")
      out.write_string("station" + dark + " " + name + " " + fnv(station) + "\n")
      // a settings page's wait line, in its list's rows (built as the list is laid out: still.fail#791)
      let reading = screen_drawlist("settings-me-reading" + dark, w, h, page="me")
      out.write_string("me-reading" + dark + " " + name + " " + fnv(reading) + "\n")
    }
  }
  // (the wide ones, 2026-11-10: 共享调试 a row of the settings' sidebar on a computer too, 关于 under the window's
  // foot for it; the narrow ones, a phone's, had the row)
  // (a station's, 2026-11-15: 屏幕、浏览器与终端 a block a row, its card drawn as pieces of one ground meeting edge to
  // edge where it was one; every glyph at the same place, and what lies under the window's foot made only as it comes)
  // (the wide ones again, 2026-11-10: a sidebar's marks, words and headings 2 in, where its rows' foot capsules start)
  // (the wide ones again, 2026-11-16: a setting's switch on its title's line, line_end_node's, never across the middle
  // of the title and its note)
  // The narrow station settings use the wider glass switch in both themes.
  // Whole-pixel View::shift lets ride_kept_for hit across the narrow page slide, moving cached segment coordinates by 1 ULP (2e-14 px).
  // Adaptive liquid-glass back button icon bands encode center-relative offsets in slots 6-7 (+16 bytes on narrow screens).
  // iOS 27 pressed-lens calibration updated resting Switch shadow/track and Segmented track ground on wide station pages.
  // Narrow pushed page_node screens now use a single-row floating liquid glass top bar (circular < + inline title + glass trailing actions).
  // P0 Regular Liquid Glass optics fix restored recipe blur 2.0/2.2 on narrow bars/pills.
  // iOS 27.0 resting segmented/pill thumb aligned to #68686E dark fill with zero border/shadow in Light and Dark.
  inspect(out.to_string(), content=(
    #|settings narrow 101820:3e3cf699
    #|station narrow 97467:7101556f
    #|me-reading narrow 31219:805bd8af
    #|settings wide 204457:ab771352
    #|station wide 275333:fccdeb64
    #|me-reading wide 199176:3c1c9ea
    #|settings-dark narrow 102088:e3484e7b
    #|station-dark narrow 97278:a238d196
    #|me-reading-dark narrow 31356:3797369c
    #|settings-dark wide 204349:32841efe
    #|station-dark wide 274963:d4d0cfe9
    #|me-reading-dark wide 199134:f5de9219
    #|












  ))
}
