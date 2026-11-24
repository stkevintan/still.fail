// 外观, one page for every frame, made once: how this
// device shows still.fail, its settings (@sf.settings: wide, rows of one list card, each choice at its row's end;
// narrow, a block each): 主题, 主题色, 字体 (the faces chosen, opening their page: FontRow; font_setting.mbt), 动画, 震动, 语言; with
// keyboard and mouse the files dragged into a chat too, and laid out wide the rail changed in place (as the web's,
// `wideOnly`). Each choice is the core's prefs (`prefs.set`), shown at once; a colour theme's dot pointed at shows the
// window in it a moment, the one set again as the pointer leaves it unchosen or the page goes. When a done chat is offered to archive is
// 归档's, as the web's.

///|
/// The page (AppearancePage, AppearanceScreen), made once in node `v` as wide as `width` gives it, in the frame it is
/// given: its settings (@sf.setting_node's) wide the rows of one list card, narrow a block each.
pub fn appearance_node(
  v : @view.View,
  core : Core,
  on_back~ : () -> Unit,
  frame~ : () -> PageFrame,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
) -> Unit {
  let wide = fn() { @sf.width_is_wide(width) }
  // (what this device offers: its window zoomed, files dropped in; the rail changed where it is beside the page)
  let keys = fn() {
    let k = ["theme", "accent", "fonts", "glass", "motion", "haptics", "language"]
    if @ui.window_zoom_supported() {
      k.push("zoom")
    }
    if @ui.takes_drops() {
      k.push("drop")
    }
    // (not beside the system's bars, an iPhone Duo's: its places are the tab bar's, set in 下方栏)
    if wide() && !@sf.native_on() {
      k.push("rail")
    }
    k
  }
  @sf.page_node(
    v,
    fn() { @sf.t("web-pages.appearance.title") },
    on_back~,
    frame~,
    said?,
    width?,
    fn() { if wide() { ["settings"] } else { keys() } },
    fn(b, key) {
      if key == "settings" {
        @sf.group_node(b, fn(g) { g.each(keys, fn(k) { k }, fn(r, k) { appearance_setting(r, core, k.untracked(), wide) }) })
      } else {
        appearance_setting(b, core, key, wide)
      }
    },
  )
}

///|
/// One of 外观's settings, by its key: 主题, 主题色, 字体 (the faces chosen, opening their page), 动画, 震动, 语言, 缩放,
/// 拖入的文件, 侧栏. Each choice the core's prefs (`prefs.set`), shown at once.
fn appearance_setting(v : @view.View, core : Core, key : String, wide : () -> Bool) -> Unit {
  let prefs = fn() { (core.topic)("prefs", Map([])).get().value }
  // a choice of a few (Segmented, Seg): the kept value, or the one just chosen while the core takes it
  let choice = fn(title : String, note : String, options : Array[(String, String)], now : () -> String) {
    @sf.setting_choice_node(
      v,
      fn() { @sf.t(title) },
      fn() { options.map(fn(o) { @sf.t(o.1) }) },
      fn() { options.search_by(fn(o) { o.0 == now() }).unwrap_or(0) },
      fn(i) {
        // another theme picked: it spreads from where it was picked (mbui reveal.mbt)
        if key == "theme" {
          let (x, y) = @signals.untracked(fn() { v.window_down_point() })
          @ui.reveal_from(x, y, dark=fn() { @sf.theme().dark })
        }
        let pref = match key {
          "theme" => "appearance"
          "drop" => "dropAs"
          _ => key
        }
        @settings.set_pref(core, pref, options[i].0)
      },
      note=fn() { if note == "" { "" } else { @sf.t(note) } },
    )
  }
  match key {
    "theme" =>
      choice(
        "web-pages.appearance.theme.title",
        "web-pages.appearance.theme.description",
        [("system", "web-main.appearance.system"), ("light", "web-main.appearance.light"), ("dark", "web-main.appearance.dark")],
        fn() { @settings.appearance(prefs()) },
      )
    // the colour theme (@sf.accents, or a hue of one's own), its dots in their own colours
    "accent" => {
      let shown = fn() {
        let now = @settings.pref(core, "accent")
        if @sf.tone_of(now) is Some(_) {
          now
        } else {
          ""
        }
      }
      @sf.setting_node(
        v,
        fn() { @sf.t("web-pages.appearance.accent.title") },
        note=fn() { @sf.t("web-pages.appearance.accent.description") },
        fn(r) {
          @sf.accent_pick_node(
            r,
            fn() { accent_names.map(fn(k) { @sf.t(k) }) },
            fn() { @sf.t("web-pages.appearance.accent.rainbow") },
            fn() { @sf.t("web-pages.appearance.accent.custom") },
            fn() { @sf.t("web-pages.appearance.accent.hue") },
            shown,
            fn(picked) {
              // (chosen while it was shown a moment: kept as it shows, never back to the one before till the prefs say it)
              @sfbase.accent_chosen(picked)
              if picked != @signals.untracked(shown) {
                @settings.set_pref(core, "accent", picked)
              }
            },
            // (a dot pointed at: the window in its colours a moment; off it, or the page let go, the one set again)
            preview=@sfbase.accent_preview,
          )
        },
      )
    }
    // the faces chosen, opening their page (a chat as they set it and their list are a page's own, on every screen)
    "fonts" =>
      @sf.setting_link_node(
        v,
        fn() { @sf.t("web-pages.appearance.fonts.title") },
        fn() { fonts_said(prefs()) },
        fn() { (core.push)(Fonts) },
        note=fn() { @sf.t("web-pages.appearance.fonts.description") },
      )
    // liquid glass frost level (0..100: 0 default clear, 100 solid surfaces)
    "glass" => {
      let frost_pct = fn() -> Int {
        let s = @settings.pref(core, "glassFrost")
        if s == "" {
          0
        } else {
          let n = @string.parse_int(s) catch { _ => 0 }
          if n < 0 { 0 } else if n > 100 { 100 } else { n }
        }
      }
      let frost_label = fn(n : Int) -> String {
        if n <= 0 {
          @sf.t("web-pages.appearance.glass.clear")
        } else if n >= 100 {
          @sf.t("web-pages.appearance.glass.solid")
        } else {
          "\{n}%"
        }
      }
      @sf.setting_node(
        v,
        fn() { @sf.t("web-pages.appearance.glass.title") },
        note=fn() { @sf.t("web-pages.appearance.glass.description") },
        fn(r) {
          r.box(fn(row) {
            row
            .row(Is(true))
            .gap(Is(12.0))
            .lines_up(Is(Some(Middle)))
            .width(By(fn() { if wide() { Some(220.0) } else { None } }))
            .shrink(Is(0.0))
            |> ignore
            @sf.value_slider_node(
              row,
              fn() { @sf.t("web-pages.appearance.glass.title") },
              fn() { frost_pct().to_double() },
              fn(x) {
                let n = x.round().to_int()
                let next = if n <= 0 { "" } else if n >= 100 { "100" } else { n.to_string() }
                if next != @signals.untracked(fn() { @settings.pref(core, "glassFrost") }) {
                  @settings.set_pref(core, "glassFrost", next)
                }
              },
              min=0.0,
              max=100.0,
              step=5.0,
              format=frost_label,
            )
            .grow(Is(1.0))
            |> ignore
            row.box(fn(val_box) {
              val_box
              .row(Is(true))
              .lies_along(Is(End))
              .shrink(Is(0.0))
              .min_width(Is(Some(44.0)))
              |> ignore
              @sf.words_node(val_box, fn() { frost_label(frost_pct()) }, fn() { glass_frost_value_style }) |> ignore
            })
            |> ignore
          })
          |> ignore
        },
      )
    }
    "motion" =>
      choice(
        "web-pages.appearance.motion.title",
        "web-pages.appearance.motion.description",
        [("", "web-pages.appearance.motion.system"), ("reduce", "web-pages.appearance.motion.reduce"), ("full", "web-pages.appearance.motion.full")],
        fn() { @settings.pref(core, "motion") },
      )
    // haptics, all of them (on unless turned off: @ui.set_haptics, app_frame.mbt)
    "haptics" =>
      @sf.setting_switch_node(
        v,
        fn() { @sf.t("web-pages.appearance.haptics.title") },
        fn() { @settings.pref(core, "haptics") != "off" },
        fn(on) { @settings.set_pref(core, "haptics", if on { "" } else { "off" }) },
        note=fn() { @sf.t("web-pages.appearance.haptics.description") },
      )
    "language" =>
      choice(
        "common.language",
        "",
        [("", "common.language.system"), ("zh", "common.language.zh"), ("en", "common.language.en")],
        fn() { @settings.pref(core, "language") },
      )
    // the window's zoom, picked beside its button
    "zoom" => {
      let zoom = fn() { @settings.pref(core, "windowZoom") }
      @sf.setting_node(v, fn() { @sf.t("desktop.menu.zoom") }, fn(r) {
        let button : Ref[@view.View?] = Ref(None)
        button.val = Some(
          @sf.button_node(r, fn() { if zoom() == "" { "100%" } else { zoom() + "%" } }, fn() {
            guard button.val is Some(b) else { return }
            let choices = @sfbase.window_zoom_levels.map(fn(z) {
              @sf.choice(z.0, (if z.0 == "" { "100" } else { z.0 }) + "%")
            })
            @sf.pick(@sf.t("desktop.menu.zoom"), choices, @signals.untracked(zoom), fn(value) {
              @settings.set_pref(core, "windowZoom", value)
            }, from=Node(b), search=false)
          }),
        )
      })
    }
    // files dragged into a chat from outside (where they can be: @ui.takes_drops): named by their path (the default),
    // or sent as files
    "drop" =>
      choice(
        "web-pages.appearance.drop.title",
        "web-pages.appearance.drop.description",
        [("", "web-pages.appearance.drop.path"), ("file", "web-pages.appearance.drop.file")],
        fn() { @settings.pref(core, "dropAs") },
      )
    // the rail, changed where it is (rail.mbt): laid out wide, where the rail is beside the page (the web's wideOnly)
    "rail" =>
      @sf.setting_node(v, fn() { @sf.t("web-main.rail.title") }, note=fn() { @sf.t("web-main.rail.lead") }, fn(r) {
        @sf.button_node(r, fn() { @sf.t("web-main.rail.customize") }, fn() { @sfbase.edit_rail() }) |> ignore
      })
    _ => ()
  }
}

///|
/// The faces chosen at a glance (FontRow: their names, " · " between), or the app's own.
fn fonts_said(prefs : Json?) -> String {
  let faces = field(prefs, "faces")
  let names = []
  for place in @settings.font_places {
    if text(field(prefs, "fonts"), place) != "" {
      names.push(text(field(faces, place), "name"))
    }
  }
  if names.is_empty() {
    @sf.t("web-pages.appearance.fonts.default")
  } else {
    names.join(" · ")
  }
}

///|
/// 字体's page made once as nodes in node `v`, one for every frame (opened from 外观's row narrow), laid out by the
/// `width` its frame gives it: what it is for under its title, the setting (font_setting.mbt's fonts_blocks_node).
pub fn fonts_node(
  v : @view.View,
  core : Core,
  on_back~ : () -> Unit,
  frame~ : () -> PageFrame,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
) -> Unit {
  let (blocks, block) = fonts_blocks_node(core)
  @sf.page_node(
    v,
    fn() { @sf.t("web-pages.appearance.fonts.title") },
    on_back~,
    frame~,
    said?,
    width?,
    lead=fn() { @sf.t("web-pages.appearance.fonts.description") },
    blocks,
    block,
  )
}

///|
// kept across runs: a value (no field of it changes)
let glass_frost_value_style : @ui.TextStyle = @ui.text_style(size=Ui, color=Muted, wrap=false)

///|
/// The accents' names, as @sf.accents has them.
// kept across runs: a value (no element of it changes)
let accent_names : Array[String] = [
  "web-pages.appearance.accent.orange", "web-pages.appearance.accent.blue", "web-pages.appearance.accent.teal", "web-pages.appearance.accent.purple",
  "web-pages.appearance.accent.pink",
]
