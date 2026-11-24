// The bar across the top of a file opened over a wide window (viewer_bar's) as nodes of the window's
// tree (the way there 4): what it says bound to what says it as that changes (the way back's words,
// the name, the line about it, where the file is, the window's width, the ink), its tools nodes of their own
// (tool_node), its way back and each tool done at the press's moment. Gone up out of the way (hidden: a picture left
// alone) from the moment it is told so, as far as that way has it by the moment each frame is drawn, whatever frames
// come between; taking no press while it goes or is gone.

///|
/// The bar across the top in `parent` (a layer over the viewer's, all of its room): the file's ground (`ink`) at 82%
/// over a 20 blur, saturated, 45 high under the room's top (`top`: a tablet's status bar, its ground on under it); the
/// way back first (`back`'s words after the chevron, `went` as it is pressed), clear of the window's buttons where they
/// are the system's at its left; `name` and `meta` under it in the middle, as wide as they are (the window's `width`
/// less viewer_bar_sides at most), where the file is (`title`, none: "") its tip while the pointer is over them; what `tools` makes in
/// the row at its end (the corner each is round at given: the window's followed at its corner, a bar's buttons'), the
/// last as far in from the window's side as a page's bar's last (`capsule_end`: a capsule of words, past the window's
/// corner as far as a long capsule stands: window_corner_past; `capsule_now`: while it says so, followed). There while `hidden` holds not (gone up its height and
/// faded over 240 ms, eased out, from where it is at the moment it is told, and back so; at once with motion
/// reduced), as far in as `shown` says of the node as it is drawn (the viewer's fade). A press on it where nothing of it
/// takes one is its own, moving the window while it has none of the system's title bar (the app's own top row). Its
/// tips in `tips`. The bar's node.
#callsite(autofill(loc))
pub fn viewer_bar_node(
  parent : @view.View,
  back : () -> String,
  name : () -> String,
  meta : () -> String,
  title : () -> String,
  hidden : () -> Bool,
  shown : (@view.View) -> Double,
  top : () -> Double,
  width : () -> Double,
  ink : () -> ViewerInk,
  tools : (@view.View, @view.Live[Double]) -> Unit,
  went : () -> Unit,
  tips : TipLayer,
  capsule_end? : Bool = false,
  capsule_now? : () -> Bool = fn() { false },
  middle? : (@view.View) -> Unit,
  middle_shown? : () -> Bool = fn() { true },
  loc~ : SourceLoc,
) -> @view.View {
  // (what stands in the name's place while `middle_shown` says so (a screen's tabs: viewer_bar's `middle`), the way
  // back as wide as it alone then)
  let held = fn() { middle is Some(_) && middle_shown() }
  // (hidden as it is made: gone whole, not gone up; its way a motion's, there at once with motion reduced)
  let gone = @motion.NodeWay::new(if @signals.untracked(hidden) { 1.0 } else { 0.0 })
  let mut bar : @view.View? = None
  parent.box(made_for=loc, fn(room) {
    room.over(Is(true)) |> ignore
    room.reacts(hidden, fn(off) { gone.go_ms(room, if off { 1.0 } else { 0.0 }, viewer_bar_ms) })
    let b = room.box(fn(b) {
      let bar_over = fn() { window_keys_bar_over_now() }
      b
      .alpha(By(fn() { (1.0 - gone.shown(b)) * shown(b) }))
      .offset(By(fn() { (0.0, -(viewer_bar_h + bar_over() + top()) * gone.shown(b)) }))
      // (gone or going, it takes no press: what is under it does)
      .presses(By(fn() { !hidden() }))
      |> ignore
      // (the app's own top row while the window has none of the system's: not full screen)
      b.moves_window(By(@ui.window_inset_now)) |> ignore
      // Progressive blur soft scroll-edge backdrop (zero hidden glass when bar is fully hidden)
      let edge_h = fn(s : @view.View) {
        if hidden() && !gone.goes(s) {
          0.0
        } else {
          viewer_bar_h + bar_over() + top() + 12.0
        }
      }
      @glass.liquid_scroll_edge_node(
        b,
        edge_h,
        edge_h,
        side=Top,
        bg=fn() { ink().ground },
        shield=false,
        pure=true,
      )
      |> ignore
      // (its ground on under the status bar where the system's bars are over the window: a tablet's)
      b.box(fn(s) { s.height(By(fn() { Some(top()) })) |> ignore }) |> ignore
      // (what the window's buttons take of each side, the system's at its left (a Mac's), the app's at its right
      // (Windows', Linux's): the way back's and the tools' sides given what the other side has more, so the name
      // stands in the window's middle whichever side they are on; short of room, that given first)
      let left_edge = fn() {
        bar_start_in() +
        (if @ui.window_keys_left_now() { viewer_buttons_w + @ui.Space::px(S4) } else { 0.0 })
      }
      let right_edge = fn() { bar_end_in(width(), capsule_end || capsule_now()) }
      b.box(fn(row) {
        row
        .row(Is(true))
        .lines_up(Is(Some(Middle)))
        .height(By(fn() { Some(viewer_bar_h + bar_over()) }))
        .gap(Is(@ui.Space::px(S4)))
        .padding(
          By(fn() {
            (bar_start_in(), bar_over(), bar_end_in(width(), capsule_end || capsule_now()), hairline_h)
          }),
        )
        |> ignore
        // clear of the window's buttons at its left, the system's (not in full screen)
        row.show(@ui.window_keys_left_now, fn(k) { k.width(Is(Some(viewer_buttons_w))) |> ignore })
        // the way back, at its start; short of room, its words give way, the chevron stays
        row.box(fn(start) {
          // (as wide as the tools' side, whatever each holds: the middle in the window's middle, viewer_bar's grow)
          start
          .row(Is(true))
          .lines_up(Is(Some(Middle)))
          .basis(By(fn() { if held() { None } else { Some(dmax(0.0, right_edge() - left_edge())) } }))
          .grow(By(fn() { if held() { 0.0 } else { 1.0 } }))
          // (short of room, what it was given for the other side's buttons given back first, before the name is cut;
          // a way back in it gives way as the name does)
          .shrink(By(fn() { if held() || back() != "" { 1.0 } else { viewer_side_gives } }))
          .min_width(Is(Some(0.0)))
          |> ignore
          // (no way back where there is nowhere to go back to: a page alone in a window of its own, whose window's own
          // close closes it; its room kept, the name in the middle as ever)
          start.show(fn() { back() != "" }, fn(k) { back_node(k, back, ink, went) |> ignore })
        })
        |> ignore
        row.pick(at_once=true, held, fn(slot, is_held) {
          slot.shrink(Is(1.0)).min_width(Is(Some(0.0))).grow(Is(if is_held { 1.0 } else { 0.0 })) |> ignore
          match middle {
            // what stands in the name's place (a screen's tabs): grown between the way back and the tools
            Some(made) if is_held => {
              slot.row(Is(true)).lines_up(Is(Some(Middle))).clips(Is(true)) |> ignore
              made(slot)
            }
            _ => {
              // the middle, as wide as what it says, the sides kept for the way back and the tools
              let middle = slot.box(fn(m) {
                m
                .lines_up(Is(Some(Middle)))
                .max_width(By(fn() {
                  Some(dmax(viewer_none, width() - (left_edge() + right_edge() + 2.0 * @ui.Space::px(S4))))
                }))
                .shrink(Is(1.0))
                .min_width(Is(Some(0.0)))
                .adaptive_ink(Is(true))
                |> ignore
                m.box(fn(n) {
                  n
                  .words(By(name))
                  .words_look(By(fn() { bar_words(Ui, L6, 600) }))
                  .cuts(Is(true))
                  .allow_ellipsis(Is(true))
                  .min_width(Is(Some(0.0)))
                  .ink(By(fn() { ink().ink }))
                  .says(By(fn() { Some(@view.said(Text, label=name())) }))
                  |> ignore
                })
                |> ignore
                m.show(fn() { meta() != "" }, fn(l) {
                  l
                  .words(By(meta))
                  .words_look(By(fn() { bar_words(Caption, L4, 400) }))
                  .cuts(Is(true))
                  .allow_ellipsis(Is(true))
                  .min_width(Is(Some(0.0)))
                  .ink(By(fn() { ink().muted }))
                  .says(By(fn() { Some(@view.said(Text, label=meta())) }))
                  |> ignore
                })
              })
              // (where the file is, over its name while the pointer is there)
              tip_node(tips, middle, title, within=true) |> ignore
            }
          }
        })
        // (short of room, the tools kept whole: the way back and the name give way)
        row.box(fn(end) {
          // (its tools kept whole, the way back and the name giving way first: viewer_bar's keep; what of them may leave
          // (View::drops: a file's keys in a window of its own at its least) leaving into their ⋯ before that, the rest
          // kept whole: View::fits)
          end
          .row(Is(true))
          .lines_up(Is(Some(Middle)))
          .gap(Is(keys_apart()))
          .basis(By(fn() { Some(dmax(0.0, left_edge() - right_edge())) }))
          .grow(Is(1.0))
          .shrink(Is(viewer_side_gives))
          .fits(Is(true))
          .keeps_held(Is(true))
          |> ignore
          // (at its end, nothing before them but what is left: viewer_bar_end's justify end)
          end.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
          let is_capsule = fn() { capsule_end || capsule_now() }
          let pill_corner = fn() { bar_tools_pill_corner(is_capsule()) }
          end.box(fn(pill) {
            pill
            .row(Is(true))
            .lines_up(Is(Some(Middle)))
            .gap(Is(keys_apart()))
            .gone_empty(Is(true))
            .padding(Is((viewer_tools_pad, viewer_tools_pad, viewer_tools_pad, viewer_tools_pad)))
            .radius(By(pill_corner))
            .fits(Is(true))
            .keeps_held(Is(true))
            |> ignore
            @glass.liquid_capsule_decorate(
              pill,
              glass=fn(_) { viewer_bar_pill_glass(ink()) },
              shadow=glass_control_shadow,
              solid_edge=@glass.liquid_solid_edge,
            )
            |> ignore
            corner_card_node(pill, pill_corner, inset=fn() { viewer_tools_pad })
            pill.lends(viewer_tools_pill_lent, true) |> ignore
            // (one hover ground for its tools, going from the one the hand left to the next: RovingHover)
            pill.lends(rove_lent, RovingHover::new()) |> ignore
            tools(pill, bar_tool_corner(is_capsule))
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    bar = Some(b)
  })
  |> ignore
  bar.unwrap()
}

///|
/// How much more readily the way back's and the tools' sides give way than the name, short of room
/// (viewer_bar_node's): what each was given for the window's buttons on the other side goes before a letter of the
/// name is cut.
let viewer_side_gives : Double = 10000.0

///|
/// Padding inside the right tools liquid glass pill (`2.0`, matching `window_keys_pill_pad`: 32pt tools + 2×2pt = 36pt).
let viewer_tools_pad : Double = 2.0

///|
/// Lent on the right tools liquid glass pill so embedded controls (such as `seg_node`) match `tool_side` (32pt) height.
let viewer_tools_pill_lent : @view.Lent[Bool] = @view.Lent::new()

///|
/// How far in from the window's side the bar's tools pill stands, the window `w` wide (viewer_bar's end): clear of the
/// window's buttons where they are the app's (12pt gap between pills); on rounded windows following the window's corner
/// (macOS 16pt), symmetric `bar_keys_top() - viewer_tools_pad` (4pt) so the pill is concentric with the window corner
/// and the last tool button inside stays at `window_end_in` (6pt); otherwise `window_end_in`.
fn bar_end_in(w : Double, capsule : Bool) -> Double {
  ignore(w)
  let roots = @ui.tree_corner_roots_now()
  if @ui.window_keys_own_now() {
    // (they stand on its line, over all the window: window_keys' whole)
    window_keys_room(roots~) + viewer_bar_in
  } else if capsule {
    // (a capsule of words at its end, past the window's corner: viewer_bar's capsule_end, window_clear_in)
    window_corner_past(viewer_bar_in, roots~)
  } else {
    let link = viewer_tools_pill_corner()
    if link.follows(roots) && link.radius(roots) <= (tool_side + 2.0 * viewer_tools_pad) / 2.0 + 0.5 {
      bar_keys_top() - viewer_tools_pad
    } else {
      window_end_in(viewer_bar_in, roots~)
    }
  }
}

///|
/// How far in from the window's left the bar's way back stands (viewer_bar's start): at the window's corner where nothing
/// of the system's is there (viewer_bar_start_in, the theme's Xl where it cannot follow it), as the window's corner is now
/// for the window's tree, followed; 12 after the system's buttons.
fn bar_start_in() -> Double {
  if @ui.window_keys_left_now() {
    viewer_bar_in
  } else {
    viewer_bar_start_in(@ui.tree_theme().corner(Xl), @ui.tree_corner_roots_now())
  }
}

///|
/// The corner of the bar's way back (viewer_bar's): the window's followed at its top left corner (viewer_back_corner) as
/// the window's corner is now for the window's tree; the theme's Xl after the system's buttons, or where it cannot.
fn bar_back_corner() -> Double {
  let alone = @ui.tree_theme().corner(Xl)
  if @ui.window_keys_left_now() {
    alone
  } else {
    viewer_back_corner(alone).radius(@ui.tree_corner_roots_now())
  }
}

///|
/// The corner spec of the bar's tools pill at the window's top right corner: concentric with the window corner from
/// `bar_keys_top() - viewer_tools_pad` (4pt), falling back to a full 18pt capsule where it cannot follow.
fn viewer_tools_pill_corner() -> @ui.CornerOf {
  Follow(Window, bar_keys_top() - viewer_tools_pad, (tool_side + 2.0 * viewer_tools_pad) / 2.0)
}

///|
/// The corner radius of the bar's right tools pill: full 18pt capsule beside the app's window controls (matching
/// `window_keys_node`) or when holding word-capsule buttons past the window corner (`capsule`), or concentric with the
/// window corner otherwise.
fn bar_tools_pill_corner(capsule : Bool) -> Double {
  let pill_r = (tool_side + 2.0 * viewer_tools_pad) / 2.0
  if @ui.window_keys_own_now() || capsule {
    pill_r
  } else {
    viewer_tools_pill_corner().radius(@ui.tree_corner_roots_now())
  }
}

///|
/// The corner of the bar's tools inside the right tools pill: concentric with `bar_tools_pill_corner` less
/// `viewer_tools_pad` (`2.0`).
fn bar_tool_corner(capsule : () -> Bool) -> @view.Live[Double] {
  By(fn() { dmax(0.0, bar_tools_pill_corner(capsule()) - viewer_tools_pad) })
}

///|
/// Words in the bar as viewer_bar sets them: the theme's `size`, `line` a line, `weight`, on one line.
fn bar_words(size : @ui.TextSize, line : @ui.Leading, weight : Int) -> @view.WordsLook {
  let th = @ui.tree_theme()
  let (px, own) = th.text_size(size)
  { size: px, weight, line: th.leading(line).unwrap_or(own), wrap: false, tracking: @view.letters_own, balance: false, max_lines: 0 }
}

///|
/// Single-layer adaptive liquid glass recipe for floating capsules in `viewer_bar_node`: picks
/// `@glass.liquid_viewer_dark_glass` on dark media grounds and `@glass.liquid_viewer_clear_glass` on light/paper
/// grounds, with `adaptive: true` so capsules adapt optical density and ink over bright or dark media underneath.
fn viewer_bar_pill_glass(k : ViewerInk, spot? : (Double, Double)? = None) -> @ui.Glass {
  // kept in viewer_bar.mbt (outside Track Q2 file boundary)
  ignore(viewer_bar_share)
  let r = ((k.ground >> 24) & 0xFFL).to_double()
  let g = ((k.ground >> 16) & 0xFFL).to_double()
  let b = ((k.ground >> 8) & 0xFFL).to_double()
  let lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
  if lum < 0.35 {
    { ..@glass.liquid_viewer_dark_glass(spot~, solid=k.ground, sharing=true), adaptive: true }
  } else {
    { ..@glass.liquid_viewer_clear_glass(spot~, solid=k.ground, sharing=true), adaptive: true }
  }
}

///|
/// The way back in `parent`: 32 high, 4 before the chevron and 10 after the words,
/// at the window's corner following it (bar_back_corner); the chevron and `words` in the ink's own, its hover ground
/// where the hand is on it (or the keyboard's focus shows); `went` as it is pressed, at the press's moment. Read out a
/// button, by its words.
#callsite(autofill(loc))
fn back_node(
  parent : @view.View,
  words : () -> String,
  ink : () -> ViewerInk,
  went : () -> Unit,
  loc~ : SourceLoc,
) -> @view.View {
  @headless.button(made_for=loc, parent, words, fn(_) { went() }, fn(v, b) {
    let lit = fn() {
      b.focus_shown() ||
      (match @ui.pointing() {
        Mouse => b.hovered()
        Finger => b.pressed()
      })
    }
    v
    .row(Is(true))
    .lines_up(Is(Some(Middle)))
    .height(Is(Some(@ui.Space::px(S8))))
    .padding(Is((@ui.Space::px(S1), 0.0, @ui.Space::px(S2_5), 0.0)))
    .gap(Is(@ui.Space::px(S0_5)))
    .radius(By(bar_back_corner))
    .shrink(Is(1.0))
    .min_width(Is(Some(0.0)))
    |> ignore
    @glass.liquid_capsule_decorate(
      v,
      interactive=true,
      glass=fn(spot) { viewer_bar_pill_glass(ink(), spot~) },
      shadow=glass_control_shadow,
      solid_edge=@glass.liquid_solid_edge,
      clips=true,
    )
    .ground(By(fn() { if lit() { ink().hover } else { 0L } }))
    |> ignore
    v.box(fn(i) {
      i
      .width(Is(Some(viewer_back_icon)))
      .height(Is(Some(viewer_back_icon)))
      .shapes(Is(back_shapes()))
      .drawn_as(Is("/icon/chevron-left/"))
      .tint(By(fn() { ink().ink }))
      |> ignore
    })
    |> ignore
    v.box(fn(w) {
      w
      .words(By(words))
      .words_look(By(fn() { bar_words(Ui, L6, 400) }))
      .ink(By(fn() { ink().ink }))
      .shrink(Is(1.0))
      .min_width(Is(Some(0.0)))
      |> ignore
    })
    |> ignore
  })
}

///|
/// The chevron of the way back, viewer_back_icon across, in no colour of its own (the node's tint).
fn back_shapes() -> Array[@ui.Shape] {
  match icon_numbers("chevron-left") {
    Some(d) => icon_shapes(d, viewer_back_icon / 24.0, 0x000000FFL)
    None => []
  }
}

///|
/// How much of a file opened has come, in the bar across the top beside its tools, as nodes
/// : "正在读取 **1.2 MB** / 3.4 MB" in the meta's size in the ink's quieter colour, the
/// size so far in bold in its own, then a progress bar 120 wide (progress_node); before the core has said how much and
/// with no size it was sent with, 正在打开 over a bar that sweeps. `got`: what has come and its whole size; `size`: the
/// size it was sent with. Each as it changes. `lead`: 正在读取 before the sizes (none in the floating bar, where the
/// bar beside them says it and the file's name keeps its room); `track`: how wide its bar is. The row's node.
#callsite(autofill(loc))
pub fn viewer_coming_node(
  parent : @view.View,
  got : () -> (Double, Double?)?,
  size : () -> Double,
  ink : () -> ViewerInk,
  lead? : Bool = true,
  track? : Double = vfr_coming_track,
  loc~ : SourceLoc,
) -> @view.View {
  let total = fn() -> Double? {
    match got() {
      Some((_, Some(n))) if n > 0.0 => Some(n)
      _ => if size() > 0.0 { Some(size()) } else { None }
    }
  }
  parent.box(made_for=loc, fn(row) {
    row
    .row(Is(true))
    .lines_up(Is(Some(Middle)))
    .gap(Is(@ui.Space::px(S2_5)))
    .padding(Is((@ui.Space::px(S2), 0.0, @ui.Space::px(S2), 0.0)))
    |> ignore
    row.box(fn(w) {
      w
      .words_runs(By(fn() {
        match (got(), total()) {
          (Some((loaded, _)), Some(n)) =>
            [
              @view.words_run(if lead { t("web-main.preview.loadingLabel") + " " } else { "" }),
              @view.words_run(file_size(loaded), weight=600, ink=ink().ink),
              @view.words_run(" / " + file_size(n)),
            ]
          _ => [@view.words_run(t("common.opening"))]
        }
      }))
      .words_look(By(fn() {
        let (size, line) = @ui.tree_theme().text_size(Meta)
        { size, weight: 400, line, wrap: false, tracking: @view.letters_own, balance: false, max_lines: 0 }
      }))
      .ink(By(fn() { ink().muted }))
      |> ignore
    })
    |> ignore
    progress_node(
      row,
      fn() {
        match (got(), total()) {
          (Some((loaded, _)), Some(n)) => Some(if loaded >= n { 1.0 } else { loaded / n })
          _ => None
        }
      },
      fn() { @ui.tree_theme().line },
      fn() { theme().p.accent },
    )
    .width(Is(Some(track)))
    |> ignore
  })
}
