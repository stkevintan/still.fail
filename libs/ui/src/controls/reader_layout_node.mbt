// The reader's layout (排版: Reader.tsx Layout) as nodes of the window's tree, laid over the reader where its panel is
// (reader_node.mbt's): the day's papers, the size with its keys, the lines and the margins on sliders, the
// face and the indent each a choice (seg_node), each changed as it is picked (the host's set_reader_style). While a
// reading's layout is open (layout_open, reader_panel_set): on 小屏 a sheet from the window's foot, half of it tall, on
// the page's own ground (sheet_node, as the reader's other panels are the host's sheets there); else docked at the
// window's right under the reader's bar, 320 wide, on its paper (the old panel's place, desk_panel's: the text kept
// clear of it as reader_sides has it), its head the title and its close. It follows the tier as the window changes,
// as the old panel did; closed (Escape, its close, the sheet let go, gone back), it goes as the sheet goes, or at once.
// A reader in a tab beside a chat has the same docked panel in the tab's own stage (reader_layout_docked, laid by
// sfbase's viewer_tab_node), going and coming back with the tab.

///|
/// What of the reader the window's tree lays over it, in `root` (presented_nodes'): its layout's panel while one is
/// open, docked beside the text or a sheet on 小屏.
#callsite(autofill(loc))
fn reader_layout_nodes(root : @view.View, loc~ : SourceLoc) -> Unit {
  let small = fn() { layout(root.window_w()) is Small }
  let open = fn() { layout_open.get() is Some(_) }
  // (the reading whose panel it is, as it opens)
  let reading = fn() { reading_for(layout_open.untracked().unwrap_or("")) }
  let close = fn(r : Reading) { fn() { reader_panel_set(r, NoPanel) } }
  // docked at the window's right, under the bar (desk_panel's place)
  root.show(fn() { open() && !small() }, fn(o) {
    let r = reading()
    // The reader can itself be inside the viewer's modal layer. Its panel must take input above that layer, while
    // presenters (whose serials start at 1) still open above the panel.
    // (clear of the column of the system's bars down the window's trailing edge, an iPhone Duo's on its side, as the
    // reader under it is: native_clear)
    o.over(Is(true)).stacked(Is(0)).padding(By(fn() { (0.0, 0.0, native_clear(), 0.0) })) |> ignore
    o.box(fn(top) { top.height(By(fn() { Some(viewer_bar_under()) })) |> ignore }) |> ignore
    reader_layout_docked(o, close(r))
  })
  // a sheet from the window's foot on 小屏, half of it tall, its title as the host's reader sheet heads it
  let x : PanelOf = {
    title: t("web-pages.drive.reader.layout"),
    description: "",
    w: panel_w,
    fits: false,
    wide: false,
    live: None,
    tall: narrow_sheet_half,
    grows: false,
    focus: true,
    ruled: false,
    fade_out_together: false,
    form: false,
    popover: false,
    stage: false,
    above: None,
    heads_itself: true,
    side: Bottom,
    along: Start,
    offset: panel_offset,
    match_panel: 0,
    scrolls_under: false,
    on_back: None,
    nodes: {
      body: fn(col, _) {
        col.box(fn(head) {
          style_node(head, fn() { layout_sheet_head })
          // (its words' own line, as the old host's sheet set its title, no line of the size's)
          head.box(fn(w) {
            w
            .words(By(fn() { t("web-pages.drive.reader.layout") }))
            .words_look(By(fn() { { ..@ui.style_words(sheet_title_words), line: -@ui.tree_theme().text_line } }))
            .ink(By(fn() { @ui.style_ink(sheet_title_words) }))
            |> ignore
          })
          |> ignore
        })
        |> ignore
        layout_body(col, true, sheet_paper)
      },
      foot: None,
      hugs: false,
      hugs_centred: false,
      steps: false,
      sheet_heads: true,
      heads: false,
      top: 0.0,
      most: None,
      flush: false,
      head_end: None,
    },
  }
  let shut = fn() {
    match layout_open.untracked() {
      Some(k) => reader_panel_set(reading_for(k), NoPanel)
      None => ()
    }
  }
  root.box(made_for=loc, fn(layer) {
    layer.over(Is(true)).stacked(Is(0)) |> ignore
    sheet_node(
      layer,
      fn() { open() && small() },
      fn() { [{ n: 0, x, close: shut, from: Unanchored }] },
      shut,
    )
  })
  |> ignore
}

///|
/// The layout's panel docked at the right of `parent` (a column), from where it is to its foot: the text's room, then
/// the panel 320 wide on the reader's paper (desk_panel's box), its head the title and its close (`close`), its controls
/// (layout_body). `fits`: no wider than `parent` where that is less (a tab's stage beside a chat: viewer_tab_node's).
#callsite(autofill(loc))
pub fn reader_layout_docked(parent : @view.View, close : () -> Unit, fits? : Bool = false, loc~ : SourceLoc) -> Unit {
  let paper = fn() { reader_paper((viewer_host().reader_style)().paper) }
  parent.box(made_for=loc, fn(row) {
    style_node(row, fn() { desk_panel_row })
    row.box(fn(room) { style_node(room, fn() { desk_panel_room }, in_row=true) }) |> ignore
    row.box(fn(p) {
      style_node(p, fn() { desk_panel_box.then(@ui.style(bg=Data(paper().ground))) }, in_row=true)
      if fits {
        p.shrink(Is(1.0)).min_width(Is(Some(0.0))).clips(Is(true)) |> ignore
      }
      // (a press on it its own: not the text's under it)
      ground_node(p) |> ignore
      p.box(fn(head) {
        style_node(head, fn() { desk_panel_head })
        words_node(head, fn() { t("web-pages.drive.reader.layout") }, fn() {
          desk_panel_title.then(@ui.text_style(color=Data(paper().ink)))
        })
        |> ignore
        head.box(fn(g) { style_node(g, fn() { desk_grow }, in_row=true) }) |> ignore
        chip_node(head, fn() { "" }, close, icon="close", ink=fn() { paper().ink }, said=fn() { t("common.close") })
        |> ignore
      })
      |> ignore
      layout_body(p, false, paper)
    })
    |> ignore
  })
  |> ignore
}

///|
/// The layout's controls in `col` (desk_layout's as it was): in the panel's 280 (320 less 20 either side), or a sheet's
/// width less 20 either side (`narrow`, the face and the indent side by side there: the sheet between the system's bars
/// down the window's sides, View::clear, as sheet_node lays it); on paper `p`.
#callsite(autofill(loc))
fn layout_body(col : @view.View, narrow : Bool, p : () -> ReaderPaper, loc~ : SourceLoc) -> Unit {
  let style = fn() { (viewer_host().reader_style)() }
  let set = fn(change : ReaderStyleChange) { (viewer_host().set_reader_style)(change) }
  let inner = fn() {
    if narrow {
      let (_, right, _, left) = col.clear()
      dmax(desk_none, col.window_w() - left - right - 2.0 * desk_layout_in)
    } else {
      desk_layout_inner
    }
  }
  let swatch = fn() { (inner() - desk_papers_gaps) / desk_papers_row }
  let half = fn() { (inner() - desk_pair_gap) / 2.0 }
  // (each option at least half its half less its track's room, a sheet's; the panel's 138: made again as that changes)
  let seg_item = fn() { if narrow { (half() - desk_seg_track) / 2.0 } else { desk_seg_item } }
  let label = fn(parent : @view.View, key : String) {
    words_node(parent, fn() { t(key) }, fn() { desk_layout_label.then(@ui.text_style(color=Data(p().muted))) }) |> ignore
  }
  col.box(made_for=loc, fn(b) {
    style_node(b, fn() { desk_layout_box })
    // the day's papers; night is the app's dark (外观), never picked here
    b.box(fn(k) {
      style_node(k, fn() { desk_layout_block })
      label(k, "web-pages.drive.reader.paper")
      k.box(fn(row) {
        style_node(row, fn() { desk_papers })
        let shown = fn() { if theme().dark { "night" } else { day_paper_key(style().paper) } }
        for key in ["white", "green", "grey"] {
          layout_swatch(row, key, fn() { shown() == key }, p, swatch, fn() { set(Paper(key)) })
        }
      })
      |> ignore
    })
    |> ignore
    b.box(fn(k) {
      style_node(k, fn() { desk_layout_block })
      label(k, "web-pages.drive.reader.size")
      k.box(fn(row) {
        style_node(row, fn() { desk_size_row.then(@ui.style(bg=Data(alpha(p().ink, desk_size_ground)))) }, in_row=false)
        let (least, most) = reader_sizes
        let word = fn() { t("web-pages.drive.reader.size") }
        let now = fn() { @signals.untracked(style).size }
        layout_size_key(row, "A−", fn() { style().size > least }, p, fn() {
          t("web-pages.drive.reader.less", args=[("what", word())])
        }, fn() { set(Size(now() - 1)) })
        row.box(fn(m) {
          style_node(m, fn() { desk_grow_middle }, in_row=true)
          words_node(m, fn() { "\{style().size}" }, fn() { desk_size_value.then(@ui.text_style(color=Data(p().ink))) })
          |> ignore
        })
        |> ignore
        layout_size_key(row, "A+", fn() { style().size < most }, p, fn() {
          t("web-pages.drive.reader.more", args=[("what", word())])
        }, fn() { set(Size(now() + 1)) })
      })
      |> ignore
    })
    |> ignore
    // (the sliders' names in a column as wide as the wider of them in this language, 48 at least: words of a length
    // known, whole)
    let names = ["web-pages.drive.reader.lines", "web-pages.drive.reader.margin"]
    let label_w = fn() {
      b.words_redone() |> ignore
      let size = node_sp(b, @ui.style_words(desk_layout_label).size)
      names.fold(init=desk_slider_label_w, fn(m, k) { dmax(m, node_words_w(t(k), size).ceil()) })
    }
    let (lines_least, lines_most) = reader_lines
    // (kept as the pointer lets it go, or a key steps it)
    layout_slider_row(b, names[0], label_w, fn() { style().line }, lines_least, lines_most, desk_lines_step, p, fn(v) {
      "\{(v * 100.0).round().to_int()}%"
    }, fn(v) { set(Line(v)) })
    let (margin_least, margin_most) = reader_margins
    layout_slider_row(
      b,
      names[1],
      label_w,
      fn() { style().margin.to_double() },
      margin_least.to_double(),
      margin_most.to_double(),
      desk_margin_step,
      p,
      fn(v) { "\{v.round().to_int()}" },
      fn(v) { set(Margin(v.round().to_int())) },
    )
    b.box(fn(pair) {
      style_node(pair, fn() { if narrow { desk_layout_pair } else { desk_layout_column } })
      let half_style = fn() { if narrow { desk_layout_half.then(@ui.style(w=Fixed(half()))) } else { desk_layout_block } }
      pair.box(fn(k) {
        style_node(k, half_style, in_row=narrow)
        label(k, "web-pages.drive.reader.face")
        k.pick(seg_item, fn(v, item_w) {
          seg_node(
            v,
            fn() { [t("web-pages.drive.reader.serif"), t("web-pages.drive.reader.sans")] },
            fn() { if style().face == "serif" { 0 } else { 1 } },
            fn(i) {
              let want = if i == 0 { "serif" } else { "sans" }
              if want != @signals.untracked(style).face {
                set(Face(want))
              }
            },
            item_w~,
          )
          |> ignore
        })
      })
      |> ignore
      pair.box(fn(k) {
        style_node(k, half_style, in_row=narrow)
        label(k, "web-pages.drive.reader.indentLabel")
        k.pick(seg_item, fn(v, item_w) {
          seg_node(
            v,
            fn() { [t("web-pages.drive.reader.indent"), t("web-pages.drive.reader.flush")] },
            fn() { if style().indent { 0 } else { 1 } },
            fn(i) {
              if (i == 0) != @signals.untracked(style).indent {
                set(Indent(i == 0))
              }
            },
            item_w~,
          )
          |> ignore
        })
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// One paper in `row`, drawn in itself (desk_swatch's): 文 on its ground, ringed in the accent when it is the one (`on`),
/// its name under it, `w()` wide; `press` as it is pressed.
#callsite(autofill(loc))
fn layout_swatch(
  row : @view.View,
  key : String,
  on : () -> Bool,
  p : () -> ReaderPaper,
  w : () -> Double,
  press : () -> Unit,
  loc~ : SourceLoc,
) -> Unit {
  // (each as it is by day, whatever the app's theme)
  let paper = paper_by_key(key)
  let glyph = fn() { t("web-pages.drive.reader.paperGlyph") }
  let name = fn() { t("web-pages.drive.reader.paper." + key) }
  @headless.button(made_for=loc, row, fn() { glyph() + " " + name() }, fn(_) { press() }, fn(s, _) {
    style_node(s, fn() { desk_swatch_box.then(@ui.style(w=Fixed(w()))) }, in_row=true)
    s.box(fn(g) {
      // (its ring desk_swatch_on's B2 in the accent where it is on, desk_swatch_off's B1 in the page's ink, faint)
      style_node(g, fn() {
        (if on() { desk_swatch_on } else { desk_swatch_off }).then(
          @ui.style(bg=Data(paper.ground), border_color=Data(if on() { p().accent } else { alpha(p().ink, desk_swatch_line) })),
        )
      })
      g.box(fn(m) {
        m
        .words_runs(By(fn() { [@ui.span(glyph(), serif=true)] }))
        .words_look(By(fn() { @ui.style_words(desk_swatch_glyph) }))
        .ink(Is(paper.ink))
        |> ignore
      })
      |> ignore
    })
    |> ignore
    words_node(s, name, fn() { desk_swatch_name.then(@ui.text_style(color=Data(p().muted))) }) |> ignore
  })
  |> ignore
}

///|
/// A size's key in `row` (desk_size_key's): A− or A+, 32 high, 44 wide at least, quiet where it can go no further (not
/// `on`), the tint under the hand; read out a button named `said`, `press` as it is pressed.
#callsite(autofill(loc))
fn layout_size_key(
  row : @view.View,
  words : String,
  on : () -> Bool,
  p : () -> ReaderPaper,
  said : () -> String,
  press : () -> Unit,
  loc~ : SourceLoc,
) -> Unit {
  @headless.button(made_for=loc, row, said, fn(_) { press() }, disabled=fn() { !on() }, fn(k, _) {
    style_node(k, fn() { desk_size_key_box })
    k
    .alpha(By(fn() { if on() { desk_whole } else { desk_size_key_off } }))
    .radius(By(desk_size_key_corner))
    .ground(Is(no_ground))
    .focus_ring_theme()
    |> ignore
    hover_ground_node(k, on~, color=fn() { @ui.tree_theme().color(Tint) })
    words_node(k, fn() { words }, fn() { desk_size_key_words.then(@ui.text_style(color=Data(p().ink))) }) |> ignore
  })
  |> ignore
}

///|
/// How a size's key that can go no further shows (desk_size_key_box's disabled{opacity=O35}).
let desk_size_key_off : Double = 0.35

///|
/// A setting along a hairline with a knob in `parent` (desk_slider_row's): its name (`label_w()` wide), the line, its
/// value as `shown` says; dragged or tapped, the value follows, and is kept (`keep`) as the pointer lets go there, or a
/// key steps it.
#callsite(autofill(loc))
fn layout_slider_row(
  parent : @view.View,
  name_key : String,
  label_w : () -> Double,
  value : () -> Double,
  min : Double,
  max : Double,
  step : Double,
  p : () -> ReaderPaper,
  shown : (Double) -> String,
  keep : (Double) -> Unit,
  loc~ : SourceLoc,
) -> Unit {
  let name = fn() { t(name_key) }
  parent.box(made_for=loc, fn(row) {
    style_node(row, fn() { desk_slider_box })
    // (held: where it is drawn, a draft; let go: kept, the draft let go with it)
    let draft : @signals.Signal[Double?] = @signals.signal(None)
    let now = fn() { draft.get().unwrap_or(value()) }
    row.box(fn(l) {
      l.width(By(fn() { Some(label_w()) })) |> ignore
      words_node(l, name, fn() { desk_layout_label.then(@ui.text_style(color=Data(p().muted))) }) |> ignore
    })
    |> ignore
    row.box(fn(g) {
      style_node(g, fn() { desk_grow }, in_row=true)
      slider_node(g, name, now, min, max, step, p, fn(v) { draft.set(Some(v)) }, fn(v) {
        if v != @signals.untracked(value) {
          keep(v)
        }
        draft.set(None)
      })
    })
    |> ignore
    row.box(fn(v) {
      style_node(v, fn() { desk_slider_value_box })
      words_node(v, fn() { shown(now()) }, fn() { desk_slider_value.then(@ui.text_style(color=Data(p().ink))) }) |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// A slider in `parent` as nodes (@headless.slider + @glass.liquid_slider_look, themed strictly by `ReaderPaper` `p`):
/// a line 3 high on 16% of the paper's ink, the part up to the knob in the paper's accent, the knob 22 across in it
/// ringed 3 in the paper's ground; its knob's middle from half a knob in to as far from the end. At `now()` between
/// `min` and `max`, on steps of `step`. Held and dragged along (a press first jumping it there), `moved` told the
/// value under the hand at each step, `let_go` the value as it is let go; with the keyboard's focus on it the arrows a
/// step (→ and ↑ more), Page Up and Down ten, Home and End its ends, and a screen reader's step, each `moved` and let
/// go at once. `lens_enabled=false` keeps a solid capsule scale feedback without mounting a glass droplet (used inside
/// glass panels like the phone reader footer to prevent glass-on-glass).
#callsite(autofill(loc))
fn slider_node(
  parent : @view.View,
  label : () -> String,
  now : () -> Double,
  min : Double,
  max : Double,
  step : Double,
  p : () -> ReaderPaper,
  moved : (Double) -> Unit,
  let_go : (Double) -> Unit,
  disabled? : () -> Bool = fn() { false },
  lens_enabled? : Bool = true,
  loc~ : SourceLoc,
) -> Unit {
  let dd = @glass.DampedDrag::new(
    @signals.untracked(now),
    lo=min,
    hi=max,
    held_scale=@glass.slider_thumb_held_scale,
  )
  let sync_dd = fn() {
    let actual = @signals.untracked(now)
    if actual != dd.target() {
      dd.update_value(actual)
    }
  }
  let drag = fn(d : @view.Drag) {
    match d.kind {
      Down => {
        dd.press()
        if d.w > slider_thumb_room {
          let frac = dclamp((d.x - slider_thumb_room / 2.0) / (d.w - slider_thumb_room), 0.0, 1.0)
          let next = @headless.slider_snap(min + frac * (max - min), min, max, step)
          if next != @headless.slider_snap(@signals.untracked(now), min, max, step) {
            moved(next)
          }
          dd.update_value(@signals.untracked(now))
        }
      }
      Moved =>
        if d.w > slider_thumb_room {
          let frac = dclamp((d.x - slider_thumb_room / 2.0) / (d.w - slider_thumb_room), 0.0, 1.0)
          let next = @headless.slider_snap(min + frac * (max - min), min, max, step)
          if next != @headless.slider_snap(@signals.untracked(now), min, max, step) {
            moved(next)
          }
          sync_dd()
        }
      Up | Off => {
        sync_dd()
        dd.release()
      }
    }
  }
  @headless.slider(
    parent,
    label,
    now,
    min~,
    max~,
    step~,
    moved,
    fn(s, sl) {
      dd.attach(s)
      s.reacts(at_start=false, now, fn(v) {
        if dd.target() != v {
          dd.update_value(v)
        }
      })
      s.reacts(at_start=false, fn() { sl.disabled() }, fn(off) {
        if off {
          dd.release()
        }
      })
      s
      .height(Is(Some(slider_outer_h)))
      .lies_along(Is(Middle))
      |> ignore
      let look = @glass.SliderLook::new(
        track_h=slider_track_h,
        track_inset=slider_track_in,
        travel_inset=None,
        thumb_w=@glass.slider_thumb_w,
        thumb_h=@glass.slider_thumb_h,
        flush=true,
        track_color=fn() { alpha(p().ink, slider_rest) },
        fill_color=Some(fn() { p().accent }),
        thumb_color=None,
        thumb_edge=None,
        focus_shown=Some(fn() { sl.focus_shown() }),
        focus_color=Some(fn() { @ui.tree_theme().focus }),
        lens_enabled~,
        disabled=fn() { sl.disabled() },
      )
      s.box(fn(slot) {
        slot.height(Is(Some(@glass.slider_thumb_h))) |> ignore
        @glass.liquid_slider_look(
          slot,
          fn(n) { dd.progress(n) },
          fn(n) { dd.pressed(n) },
          look,
          velocity=fn(n) { dd.velocity(n) },
          loc~,
        )
      })
      |> ignore
    },
    thumb_room=slider_thumb_room,
    disabled~,
    drag~,
    on_commit=fn(v) {
      let_go(v)
      sync_dd()
    },
    focus_on_press=true,
    made_for=loc,
    loc~,
  )
  |> ignore
}

///|
/// The slider's layout height (28pt, preserving reader panel row geometry), unified iOS 27 capsule track height (6pt),
/// end inset (4pt, tucked under flush 38x24 white capsule thumb), rest track ink alpha (16%), and thumb travel room
/// (38pt, matching flush=true).
let slider_outer_h : Double = 28.0

///|
let slider_track_h : Double = @glass.slider_track_h

///|
let slider_track_in : Double = @glass.slider_track_h / 2.0 + 1.0

///|
let slider_rest : Double = 0.16

///|
let slider_thumb_room : Double = @glass.slider_thumb_w

///|
/// The layout's sheet's title's row (the old host's reader sheet's: 18 in, 4 over, 10 under).
// kept across runs: a value (no field of it changes)
let layout_sheet_head : @ui.Style = @ui.css("row w=Full px=S4_5 pt=S1 pb=S2_5 align=ACenter")
