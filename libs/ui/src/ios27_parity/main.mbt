// 1:1 iOS 27.0 Controls Parity Fixed Acceptance Scene (390x844 @ 2x = 780x1688)
// Uses real @sf / @glass library components, native iOS 27 typography & copy, and @glass.glass_symbol_node vector icons.

///|
fn section_header(parent : @view.View, title : String, color : Int64) -> Unit {
  parent.box(fn(h) {
    h.padding(Is((4.0, 0.0, 0.0, 0.0))) |> ignore
    h.box(fn(w) {
      w
      .words(
        Is(title),
        look={ ..@glass.words_at(13.5, weight=600), tracking: Points(0.35) },
      )
      .ink(Is(color))
      |> ignore
    }) |> ignore
  }) |> ignore
}

///|
fn card_box(parent : @view.View, bg : Int64, body : (@view.View) -> Unit) -> Unit {
  parent.box(fn(c) {
    c
    .width(Is(Some(358.0)))
    .radius(Is(20.0))
    .padding(Is((14.0, 14.0, 14.0, 14.0)))
    .gap(Is(12.0))
    .ground(Is(bg))
    |> ignore
    body(c)
  }) |> ignore
}

///|
fn parity_scene(dark : Bool) -> (@view.View) -> Unit {
  fn(root : @view.View) {
    @sf.set_language(Some("en"))
    @sf.set_dark(Some(dark))
    @sf.set_accent("ios-blue")
    @glass.set_dark(Some(dark))

    let page_bg = if dark { 0x000000FFL } else { 0xF2F2F7FFL }
    let card_bg = if dark { 0x1C1C1EFFL } else { 0xFFFFFFFFL }
    let search_bg = if dark { 0x1C1C20FFL } else { 0xE5E5EBFFL }
    let txt_pri = if dark { 0xFFFFFFFFL } else { 0x000000FFL }
    let txt_sec = if dark { 0x8E8E93FFL } else { 0x6E6E73FFL }
    let accent = if dark { 0x0091FFFFL } else { 0x0088FFFFL }
    let sep_col = if dark { 0x38383AFFL } else { 0xE5E5EAFFL }

    let seg_idx = @signals.signal(0)
    let dd_seg = @glass.DampedDrag::new(0.0, lo=0.0, hi=2.0, held_scale=1.15)
    let sw_on = @signals.signal(true)
    let dd_sw_on = @glass.DampedDrag::new(1.0, lo=0.0, hi=1.0, held_scale=@glass.thumb_held_scale)
    let sw_off = @signals.signal(false)
    let dd_sw_off = @glass.DampedDrag::new(0.0, lo=0.0, hi=1.0, held_scale=@glass.thumb_held_scale)
    let sl1_val = @signals.signal(50.0)
    let dd_sl1 = @glass.DampedDrag::new(50.0, lo=0.0, hi=100.0, held_scale=@glass.slider_thumb_held_scale)
    let sl2_val = @signals.signal(75.0)
    let dd_sl2 = @glass.DampedDrag::new(75.0, lo=0.0, hi=100.0, held_scale=@glass.slider_thumb_held_scale)

    root.box(fn(page) {
      page.grow(Is(1.0)).ground(Is(page_bg)) |> ignore

      // Main vertical content column
      page.box(fn(col) {
        col
        .width(Is(Some(390.0)))
        .padding(Is((16.0, 16.0, 16.0, 16.0)))
        .gap(Is(12.0))
        |> ignore

        // 1. Top Bar (height = 40)
        col.box(fn(top) {
          top
          .width(Is(Some(358.0)))
          .height(Is(Some(40.0)))
          .row(Is(true))
          .lines_up(Is(Some(Middle)))
          |> ignore
          // Left circular eye glass pill
          top.box(fn(eye) {
            eye
            .width(Is(Some(40.0)))
            .height(Is(Some(40.0)))
            .radius(Is(20.0))
            .glass(By(fn() { Some(@glass.liquid_bar_pill_glass(sharing=false)) }))
            .lines_up(Is(Some(Middle)))
            .lies_along(Is(Middle))
            |> ignore
            @glass.glass_symbol_node(eye, "eye", 20.0, fn() { txt_pri }) |> ignore
          }) |> ignore
          // Center title
          top.box(fn(mid) {
            mid.grow(Is(1.0)).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
            mid.box(fn(w) {
              w.words(Is("Controls Parity"), look=@glass.words_at(17.0, weight=600)).ink(Is(txt_pri)) |> ignore
            }) |> ignore
          }) |> ignore
          // Right grouped pill ("Solid" + colored indigo moon / golden sun icon)
          top.box(fn(grp) {
            grp
            .height(Is(Some(40.0)))
            .padding(Is((14.0, 0.0, 14.0, 0.0)))
            .radius(Is(20.0))
            .glass(By(fn() { Some(@glass.liquid_bar_pill_glass(sharing=false)) }))
            .row(Is(true))
            .lines_up(Is(Some(Middle)))
            .gap(Is(8.0))
            |> ignore
            grp.box(fn(w) {
              w.words(Is("Solid"), look=@glass.words_at(15.0, weight=500)).ink(Is(txt_pri)) |> ignore
            }) |> ignore
            if dark {
              @glass.glass_symbol_node(grp, "sun", 17.0, fn() { 0xFFD60AFFL }) |> ignore
            } else {
              @glass.glass_symbol_node(grp, "moon", 17.0, fn() { 0x5E5CE6FFL }) |> ignore
            }
          }) |> ignore
        }) |> ignore

        // 2. Search Controls Bar (solid grey fill, 40pt tall, non-glass, 17pt text)
        col.box(fn(search) {
          search
          .width(Is(Some(358.0)))
          .height(Is(Some(40.0)))
          .padding(Is((14.0, 0.0, 14.0, 0.0)))
          .radius(Is(20.0))
          .ground(Is(search_bg))
          .row(Is(true))
          .lines_up(Is(Some(Middle)))
          .gap(Is(8.0))
          |> ignore
          @glass.glass_symbol_node(search, "search", 18.0, fn() { txt_sec }) |> ignore
          search.box(fn(w) {
            w.words(Is("Search controls"), look=@glass.words_at(17.0, weight=400)).ink(Is(txt_sec)) |> ignore
          }) |> ignore
        }) |> ignore

        // 3. SEGMENTED CONTROL (32pt tall, glass_track=false native grey track, Day pressed p=1.0)
        col.box(fn(sec) {
          sec.gap(Is(6.0)) |> ignore
          section_header(sec, "SEGMENTED CONTROL", txt_sec)
          card_box(sec, card_bg, fn(c) {
            @glass.liquid_segmented_node(
              c,
              fn() { ["Day", "Week", "Month"] },
              fn() { seg_idx.get() },
              fn(i) { seg_idx.set(i) },
              width=330.0,
              height=32.0,
              drag=dd_seg,
              glass_track=false,
            ) |> ignore
          })
        }) |> ignore

        // 4. SWITCHES (UISWITCH) — native copy Notifications (On) & Low Power Mode (Off), both pressed p=1.0
        col.box(fn(sec) {
          sec.gap(Is(6.0)) |> ignore
          section_header(sec, "SWITCHES (UISWITCH)", txt_sec)
          card_box(sec, card_bg, fn(c) {
            c.box(fn(r1) {
              r1.width(Is(Some(330.0))).row(Is(true)).lines_up(Is(Some(Middle))) |> ignore
              r1.box(fn(l) {
                l.grow(Is(1.0)) |> ignore
                l.box(fn(w) {
                  w.words(Is("Notifications (On)"), look=@glass.words_at(16.0, weight=400)).ink(Is(txt_pri)) |> ignore
                }) |> ignore
              }) |> ignore
              @glass.liquid_toggle_node(
                r1,
                fn() { sw_on.get() },
                fn(v) { sw_on.set(v) },
                fn() { "Notifications (On)" },
                drag=dd_sw_on,
              ) |> ignore
            }) |> ignore
            c.box(fn(div) { div.width(Is(Some(330.0))).height(Is(Some(0.5))).ground(Is(sep_col)) |> ignore }) |> ignore
            c.box(fn(r2) {
              r2.width(Is(Some(330.0))).row(Is(true)).lines_up(Is(Some(Middle))) |> ignore
              r2.box(fn(l) {
                l.grow(Is(1.0)) |> ignore
                l.box(fn(w) {
                  w.words(Is("Low Power Mode (Off)"), look=@glass.words_at(16.0, weight=400)).ink(Is(txt_pri)) |> ignore
                }) |> ignore
              }) |> ignore
              @glass.liquid_toggle_node(
                r2,
                fn() { sw_off.get() },
                fn(v) { sw_off.set(v) },
                fn() { "Low Power Mode (Off)" },
                drag=dd_sw_off,
              ) |> ignore
            }) |> ignore
          })
        }) |> ignore

        // 5. SLIDERS (UISLIDER) — Continuous 50% & Stepped (25%) 75%, pressed 57x36pt (38x24 * 1.50)
        col.box(fn(sec) {
          sec.gap(Is(6.0)) |> ignore
          section_header(sec, "SLIDERS (UISLIDER)", txt_sec)
          card_box(sec, card_bg, fn(c) {
            c.box(fn(s1) {
              s1.width(Is(Some(330.0))).gap(Is(4.0)) |> ignore
              s1.box(fn(hdr) {
                hdr.width(Is(Some(330.0))).row(Is(true)).lines_up(Is(Some(Middle))) |> ignore
                hdr.box(fn(l) {
                  l.grow(Is(1.0)) |> ignore
                  l.box(fn(w) { w.words(Is("Continuous"), look=@glass.words_at(16.0, weight=400)).ink(Is(txt_pri)) |> ignore }) |> ignore
                }) |> ignore
                hdr.box(fn(w) { w.words(Is("50%"), look=@glass.words_at(15.0, weight=500)).ink(Is(txt_sec)) |> ignore }) |> ignore
              }) |> ignore
              @glass.liquid_slider_node(
                s1,
                fn() { sl1_val.get() },
                fn(v) { sl1_val.set(v) },
                fn() { "Continuous" },
                thumb_w_px=38.0,
                thumb_h_px=24.0,
                drag=dd_sl1,
              ) |> ignore
            }) |> ignore
            c.box(fn(s2) {
              s2.width(Is(Some(330.0))).gap(Is(4.0)) |> ignore
              s2.box(fn(hdr) {
                hdr.width(Is(Some(330.0))).row(Is(true)).lines_up(Is(Some(Middle))) |> ignore
                hdr.box(fn(l) {
                  l.grow(Is(1.0)) |> ignore
                  l.box(fn(w) { w.words(Is("Stepped (25%)"), look=@glass.words_at(16.0, weight=400)).ink(Is(txt_pri)) |> ignore }) |> ignore
                }) |> ignore
                hdr.box(fn(w) { w.words(Is("75%"), look=@glass.words_at(15.0, weight=500)).ink(Is(txt_sec)) |> ignore }) |> ignore
              }) |> ignore
              @glass.liquid_slider_node(
                s2,
                fn() { sl2_val.get() },
                fn(v) { sl2_val.set(v) },
                fn() { "Stepped" },
                stops=5,
                thumb_w_px=38.0,
                thumb_h_px=24.0,
                drag=dd_sl2,
              ) |> ignore
            }) |> ignore
          })
        }) |> ignore

        // 6. GLASS BUTTONS — real @sf.glass_button_node(prominent=false/true) + vector heart glass pill
        col.box(fn(sec) {
          sec.gap(Is(6.0)) |> ignore
          section_header(sec, "GLASS BUTTONS", txt_sec)
          card_box(sec, card_bg, fn(c) {
            c.box(fn(row) {
              row
              .width(Is(Some(330.0)))
              .row(Is(true))
              .lines_up(Is(Some(Middle)))
              .gap(Is(10.0))
              |> ignore
              @sf.glass_button_node(row, fn() { "Regular Glass" }, fn() { () }, prominent=false) |> ignore
              row.box(fn(heart) {
                heart
                .width(Is(Some(36.0)))
                .height(Is(Some(36.0)))
                .radius(Is(18.0))
                .glass(By(fn() { Some(@glass.liquid_bar_pill_glass(sharing=false)) }))
                .lines_up(Is(Some(Middle)))
                .lies_along(Is(Middle))
                |> ignore
                @glass.glass_symbol_node(heart, "heart", 17.0, fn() { txt_pri }) |> ignore
              }) |> ignore
              @sf.glass_button_node(row, fn() { "Prominent" }, fn() { () }, prominent=true) |> ignore
            }) |> ignore
          })
        }) |> ignore

        // 7. Native-style MENUS (UIMENU & .CONTEXTMENU) list card beneath Floating Bottom Tab Bar (y=758..818)
        col.box(fn(sec) {
          sec.gap(Is(6.0)) |> ignore
          section_header(sec, "MENUS (UIMENU & .CONTEXTMENU)", txt_sec)
          card_box(sec, card_bg, fn(c) {
            c.box(fn(row) {
              row.width(Is(Some(330.0))).row(Is(true)).lines_up(Is(Some(Middle))) |> ignore
              row.box(fn(w) {
                w.grow(Is(1.0)).words(Is("Action Menu"), look=@glass.words_at(15.0, weight=500)).ink(Is(txt_pri)) |> ignore
              }) |> ignore
              row.box(fn(w) {
                w.words(Is("Default"), look=@glass.words_at(14.0, weight=400)).ink(Is(txt_sec)) |> ignore
              }) |> ignore
            }) |> ignore
            c.box(fn(div) { div.width(Is(Some(330.0))).height(Is(Some(0.5))).ground(Is(sep_col)) |> ignore }) |> ignore
            c.box(fn(row) {
              row.width(Is(Some(330.0))).row(Is(true)).lines_up(Is(Some(Middle))) |> ignore
              row.box(fn(w) {
                w.grow(Is(1.0)).words(Is("Context Menu Preview"), look=@glass.words_at(15.0, weight=400)).ink(Is(txt_pri)) |> ignore
              }) |> ignore
              row.box(fn(w) {
                w.words(Is("Hold"), look=@glass.words_at(14.0, weight=400)).ink(Is(txt_sec)) |> ignore
              }) |> ignore
            }) |> ignore
            c.box(fn(div) { div.width(Is(Some(330.0))).height(Is(Some(0.5))).ground(Is(sep_col)) |> ignore }) |> ignore
            c.box(fn(row) {
              row.width(Is(Some(330.0))).row(Is(true)).lines_up(Is(Some(Middle))) |> ignore
              row.box(fn(w) {
                w.grow(Is(1.0)).words(Is("Share & Quick Actions"), look=@glass.words_at(15.0, weight=400)).ink(Is(txt_pri)) |> ignore
              }) |> ignore
              row.box(fn(w) {
                w.words(Is("Menu"), look=@glass.words_at(14.0, weight=400)).ink(Is(txt_sec)) |> ignore
              }) |> ignore
            }) |> ignore
          })
        }) |> ignore
      }) |> ignore

      // Floating 4-tab Bottom Tab Bar overlay (y = 758..818, height = 60pt, lens_lift_h = 1.16)
      page.box(fn(fg) {
        fg.over(Is(true)).padding(Is((16.0, 758.0, 16.0, 0.0))) |> ignore
        let bar_w = 358.0
        let bar_h = 60.0
        let tab_w = bar_w / 4.0
        let lens_h = bar_h * 1.16
        let lens_w = tab_w * 1.12
        let tabs : Array[(String, String)] = [
          ("Controls", "sliders"),
          ("Surfaces", "layers"),
          ("Lenses", "sparkles"),
          ("Settings", "settings"),
        ]

        fg.box(fn(bar) {
          bar
          .width(Is(Some(bar_w)))
          .height(Is(Some(bar_h)))
          .radius(Is(bar_h / 2.0))
          .glass(By(fn() { Some(@glass.liquid_tab_bar_glass()) }))
          |> ignore

          // 4 tab items with 23pt solid SF-Symbols-style vector icons
          bar.box(fn(row) {
            row.over(Is(true)).row(Is(true)) |> ignore
            for idx, item in tabs {
              let (lbl, sym_name) = item
              let ink = if idx == 0 { accent } else { txt_pri }
              row.box(fn(cell) {
                cell
                .width(Is(Some(tab_w)))
                .height(Is(Some(bar_h)))
                .lines_up(Is(Some(Middle)))
                .lies_along(Is(Middle))
                .gap(Is(1.5))
                |> ignore
                @glass.glass_symbol_node(cell, sym_name, 25.0, fn() { ink }) |> ignore
                cell.box(fn(w) {
                  w.words(Is(lbl), look=@glass.words_at(10.0, weight=600)).ink(Is(ink)) |> ignore
                }) |> ignore
              }) |> ignore
            }
          }) |> ignore

          // Active tab 0 pressed 1.16x lifted clear glass lens (p = 1.0)
          bar.box(fn(lens) {
            let r = lens_h / 2.0
            lens
            .over(Is(true))
            .width(Is(Some(tab_w)))
            .height(Is(Some(bar_h)))
            .glass(By(fn() { Some(@glass.liquid_tab_lens_glass(1.0)) }))
            .ground_drawn(By(fn() {
              {
                dx: (tab_w - lens_w) / 2.0,
                dy: (bar_h - lens_h) / 2.0,
                dw: lens_w - tab_w,
                dh: lens_h - bar_h,
                corners: Some((r, r, r, r)),
              }
            }))
            |> ignore
          }) |> ignore
        }) |> ignore
      }) |> ignore
    }) |> ignore
    @signals.untracked(fn() {
      dd_seg.press()
      dd_sw_on.press()
      dd_sw_off.press()
      dd_sl1.press()
      dd_sl2.press()
    })
  }
}

///|
fn main {
  let dir = @ui.env("MBUI_EVIDENCE_DIR")
  if dir == "" {
    println("ios27_parity: set MBUI_EVIDENCE_DIR=<dir>")
    return
  }
  let backend_env = @ui.env("MBUI_EVIDENCE_BACKEND")
  let backend = if backend_env == "" { "gles" } else { backend_env }
  let mode_filter = @ui.env("MBUI_EVIDENCE_MODE")
  let prefix_env = @ui.env("MBUI_EVIDENCE_PREFIX")
  let prefix = if prefix_env == "" { "wave3c-ios27-parity" } else { prefix_env }
  let scale_env = @ui.env("MBUI_EVIDENCE_SCALE")
  let scale = if scale_env == "3" || scale_env == "3.0" { 3.0 } else { 2.0 }
  for dark in [false, true] {
    let mode = if dark { "dark" } else { "light" }
    if mode_filter != "" && mode_filter != mode {
      continue
    }
    let ok = @film.picture(
      parity_scene(dark),
      path="\{dir}/\{prefix}-\{mode}-\{backend}.png",
      w=390.0,
      h=844.0,
      scale~,
      dark~,
      theme=@sf.ui_theme_now,
      script="wait 350\n",
      at=0.0,
      corners_held=false,
      words_over_held=false,
    )
    println("ios27_parity: \{prefix}-\{mode}-\{backend}.png \{ok}")
  }
}
