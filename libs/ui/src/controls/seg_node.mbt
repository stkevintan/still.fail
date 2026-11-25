// A choice of a few as nodes of the window's tree (segmented's, parts.mbt, its wide way: the web's Segmented): a quiet
// pill track, the chosen one lifted out of it (the theme's lifted, a hairline round it) sliding to it as a thing moved
// does (@motion's move_spring), its options equal columns as wide as the widest of their words in the chosen weight with
// segmented_in either side, `item_w` at least; each chosen by a press, the arrows along it, a screen reader's
// Activate, read out as a radio of a group.

///|
/// Its options' columns as segmented has them: each as wide as the widest of their words in the chosen weight with
/// segmented_in either side, `item_w` at least.
fn seg_node_cols(v : @view.View, labels : Array[String], item_w : Double) -> Double {
  let size = node_sp(v, theme().t.ui)
  labels.fold(init=item_w, fn(m, l) { dmax(m, node_words_w(l, size, weight=500) + 2.0 * segmented_in) })
}

///|
/// `labels`' options fitted to `room` as node `v` draws them (fitted's): their words at the system's size of words in
/// its tree, in the theme its tree's words are drawn in.
fn node_fitted(
  v : @view.View,
  labels : Array[String],
  room : Double,
  base : Double,
  weight : Int,
  side : Double,
  least : Double,
) -> Fitted {
  fitted_by(fn(x) { node_sp(v, x) }, @ui.tree_theme().tabular, labels, room, base, weight, side, least)
}

///|
/// A segmented choice of `labels` in `parent`, `chosen()` the one chosen, `choose` told the one a press, an arrow, a
/// screen reader or its pick chooses (the caller says it chosen then: `chosen` follows it), `item_w` each option at
/// least, `said` what a screen reader calls it. Its thumb slides from where it is to the one chosen as that changes, at
/// that moment. Where its columns need more room than there is (its track laid out narrower than they are: it gives
/// way, as segmented's cut to where it is), its options share what there is as option_widths has them, as segmented's
/// do: as alike as their words let them, their sides narrower, else their words smaller alike (to the system's own
/// size of words), else the chosen one alone in its track with a chevron, the others in a pick (@sf.pick) a press on
/// it opens. Always one line, each one's words whole.
#callsite(autofill(loc))
pub fn seg_node(
  parent : @view.View,
  labels : () -> Array[String],
  chosen : () -> Int,
  choose : (Int) -> Unit,
  item_w? : Double = 0.0,
  each_own? : Bool = false,
  said? : String = "",
  loc~ : SourceLoc,
) -> @view.View {
  // (measured again as all words are, the system's size of words changed: View::words_redone)
  let col = fn() {
    parent.words_redone() |> ignore
    seg_node_cols(parent, labels(), item_w)
  }
  // (each option as wide as its own words, `each_own`, or all of them as the widest's)
  let cols = fn() -> Array[Double] {
    if each_own {
      parent.words_redone() |> ignore
      labels().map(fn(l) { seg_node_cols(parent, [l], item_w) })
    } else {
      Array::make(labels().length(), col())
    }
  }
  let in_viewer_pill = parent.lent(viewer_tools_pill_lent).unwrap_or(false)
  let seg_pad = if in_viewer_pill { 2.0 } else { segmented_pad }
  let seg_base_h = if in_viewer_pill { tool_side - 2.0 * seg_pad } else { segmented_h }
  let gaps = fn() { segmented_gap * (labels().length() - 1).to_double() }
  // (as wide as its columns, its track round them: what it is laid out before it gives way)
  let whole = fn() { cols().fold(init=0.0, fn(a, c) { a + c }) + gaps() + 2.0 * seg_pad }
  // (a line of its own round its track, whatever way `parent` lays out what it holds: the track's basis its width
  // there; it gives way as the track does, down to nothing)
  parent.box(made_for=loc, fn(line) {
    line.row(Is(true)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
    line.box(fn(track) {
      let opt_h = fn() {
        track.words_redone() |> ignore
        dmax(seg_base_h, node_sp(track, theme().t.ui * @ui.tree_theme().text_line).ceil() + 2.0 * 2.0)
      }
      // (its pad round its options inside what it holds: what is said of it as a group (View::by_room's) out to its edges)
      track
      .row(Is(true))
      // (as wide as its columns where its line has the room, giving way to what it has: down to nothing, its options
      // fitted to it)
      .basis(By(fn() { Some(whole()) }))
      // (as high as its options with its pad round them: not stretched to its line's height)
      .height(By(fn() { Some(opt_h() + 2.0 * seg_pad) }))
      .shrink(Is(1.0))
      .min_width(Is(Some(0.0)))
      |> ignore
      // (what it holds by the room the track is given, its options fitted to that as the layout comes to it)
      track.by_room(fn(inner, given) {
        // how its options fit the room its track is given (none: their columns whole), as segmented's
        let fit : () -> Fitted? = fn() {
          let room = given.width()
          if room < whole() - 0.5 {
            inner.words_redone() |> ignore
            Some(node_fitted(inner, labels(), room - 2.0 * seg_pad - gaps(), theme().t.ui, 500, segmented_in, segmented_least))
          } else {
            None
          }
        }
        let menu = fn() { fit() is Some({ fit: Menu, .. }) }
        // (each option's width: its column, or its share of the room as fitted; its words that much smaller)
        let widths = fn() {
          match fit() {
            Some({ widths, fit: Whole | Smaller(_) }) => widths
            _ => cols()
          }
        }
        let smaller = fn() {
          match fit() {
            Some({ fit: Smaller(k), .. }) => k
            _ => 1.0
          }
        }
        let ink = fn() { theme().p.text }
        let seg = @glass.liquid_segmented_node(
          inner,
          labels,
          chosen,
          choose,
          glass_track=false,
          pad=seg_pad,
          gap=segmented_gap,
          widths~,
          height_by=fn() { opt_h() + 2.0 * seg_pad },
          text_size=fn() { theme().t.ui * smaller() },
          kind=Radio,
          said~,
          shown=fn() { !menu() },
          loc~,
        )
        seg.laid_nowhere(By(menu)) |> ignore
        // not side by side: the chosen one's words as its option has them (cut short where they must be), a chevron at its
        // end; pressed, a pick of them all beside it, the chosen one marked (search none: a few short words)
        inner.box(fn(menu_track) {
          menu_track
          .row(Is(true))
          .laid_nowhere(By(fn() { !menu() }))
          .padding(Is((seg_pad, seg_pad, seg_pad, seg_pad)))
          .height(By(fn() { Some(opt_h() + 2.0 * seg_pad) }))
          .radius(By(fn() { opt_h() / 2.0 + seg_pad }))
          .ground(By(@glass.ctrl_seg_embedded_track_ink))
          |> ignore
          let words = fn() { labels().get(chosen()).unwrap_or("") }
          // (the pick it opened, as presented: 0, none yet; open while it is drawn, presented_drawn_of)
          let opened : @signals.Signal[Int] = @signals.signal(0)
          let open = fn() {
            let s = opened.get()
            s != 0 && presented_drawn_of(s)
          }
          @headless.disclosure(
            menu_track,
            fn() { if said == "" { words() } else { said + " " + words() } },
            open,
            fn(m) {
              let (x, y, w, h) = m.rect()
              let all = @signals.untracked(labels)
              let now = @signals.untracked(chosen)
              pick(
                "",
                all.mapi(fn(i, l) { choice(i.to_string(), l) }),
                now.to_string(),
                fn(k) {
                  let i = labels_at(all, k, now)
                  if i != now {
                    choose(i)
                  }
                },
                from=At(x, y, w, h),
                search=false,
              )
              opened.set(last_presented())
            },
            fn(m, _) {
              m
              .row(Is(true))
              .grow(Is(1.0))
              .height(By(fn() { Some(opt_h()) }))
              .lines_up(Is(Some(Middle)))
              .padding(Is((segmented_least, 0.0, segmented_least, 0.0)))
              .gap(Is(segmented_least))
              |> ignore
              m.box(fn(w) {
                w
                .grow(Is(1.0))
                .shrink(Is(1.0))
                .min_width(Is(Some(0.0)))
                .words(By(words))
                .words_look(By(fn() {
                  let size = theme().t.ui
                  { size, weight: 500, line: @ui.tree_theme().text_line * size, wrap: false, tracking: @view.letters_own, balance: false, max_lines: 0 }
                }))
                .ink(By(ink))
                |> ignore
              })
              |> ignore
              icon_node(m, "chevron-down", segmented_chevron, By(fn() { theme().p.muted })) |> ignore
            },
          )
          |> ignore
        })
        |> ignore
      })
      .grow(Is(1.0))
      .shrink(Is(1.0))
      .min_width(Is(Some(0.0)))
      |> ignore
    })
    |> ignore
  })
}

///|
/// The thumb's motion belongs to the view that keeps the selection across page changes.
pub struct SegThumb {
  priv dd : @glass.DampedDrag
}

///|
/// Keep the thumb's current position and press motion on `owner`, so a new view can draw the same motion.
pub fn SegThumb::new(owner : @view.View, chosen : () -> Int) -> SegThumb {
  let init = @signals.untracked(chosen).to_double()
  let dd = @glass.DampedDrag::new(init, lo=0.0, hi=dmax(1.0, init), held_scale=@glass.ctrl_seg_held_scale)
  dd.attach(owner)
  { dd, }
}

///|
/// A narrow page's choice of a few (seg's filling Seg, as nodes: segmented's on a narrow page) in `parent`: as wide as
/// where it is, `labels` sharing it alike, none narrower than its words with their sides (fitted: where they need more,
/// their sides narrower, else their words smaller alike, else the chosen one alone with a chevron, the others in a pick a
/// press on it opens), on a neutral capsule track, 34 high, 2 in. A thumb in the theme's lifted colour sits under the
/// chosen one's words and slides to the new option when the selection changes. On a hold or horizontal drag,
/// a glass lens grows over the thumb. The thumb follows the nearest option and leans toward the finger.
/// The finger can leave the track. Release selects the nearest option. `chosen()` gives the selected option.
/// `choose` receives the option a press, an arrow, a screen
/// reader or its pick chooses (the caller says it chosen then: `chosen` follows it); `said` what a screen reader calls
/// it. As wide as where it is laid out, its words at the system's size of words, in the language as it is, as those
/// change. `labels()` says how many options there are once, as it is made: their words may change (another language),
/// their number not.
#callsite(autofill(loc))
pub fn seg_fill_node(
  parent : @view.View,
  labels : () -> Array[String],
  chosen : () -> Int,
  choose : (Int) -> Unit,
  said? : String = "",
  thumb? : SegThumb,
  loc~ : SourceLoc,
) -> @view.View {
  let labels_now = @signals.computed(fn(_) { labels() })
  let labels = fn() { labels_now.get() }
  let chosen_now = @signals.computed(fn(_) { chosen() })
  let chosen = fn() { chosen_now.get() }
  parent.by_room(fn(inner, given) {
    let thumb = match thumb {
      Some(kept) => kept
      None => SegThumb::new(inner, chosen)
    }
    let track_h = fn() {
      inner.words_redone() |> ignore
      let (_, line) = @ui.tree_theme().text_size(Base)
      dmax(segmented_narrow_h, node_sp(inner, line).ceil() + 2.0 * seg_inset)
    }
    inner
    .made_for(loc)
    .row(Is(true))
    .height(By(fn() { Some(track_h()) }))
    .shrink(Is(1.0))
    .min_width(Is(Some(0.0)))
    |> ignore
    // how its options share the room its track is given, as seg's: where their words with their sides come to
    // more than it, fitted to it (seg's fitted); else none, the layout sharing it alike (none narrower than its words
    // with their sides: Seg's flex)
    let fit : () -> Fitted? = fn() {
      inner.words_redone() |> ignore
      let base = @ui.tree_theme().text_size(Base).0
      let size = node_sp(inner, base)
      let room = given.width() - 2.0 * seg_inset
      let need = labels().fold(init=0.0, fn(s, l) { s + node_words_w(l, size) + 2.0 * seg_side })
      if need > room + 0.5 {
        Some(node_fitted(inner, labels(), room, base, 400, seg_side, seg_least))
      } else {
        None
      }
    }
    // (each option's share of the room where none is fitted: alike, none narrower than its words with their sides, as
    // Seg's flex shares it; worked out here from the room it is given, what each is laid out at and where the thumb goes
    // one number)
    let shared = fn() {
      inner.words_redone() |> ignore
      let size = node_sp(inner, @ui.tree_theme().text_size(Base).0)
      seg_shares(given.width() - 2.0 * seg_inset, labels().map(fn(l) { node_words_w(l, size) + 2.0 * seg_side }))
    }
    let menu = fn() { fit() is Some({ fit: Menu, .. }) }
    let widths = fn() {
      match fit() {
        Some({ widths, fit: Whole | Smaller(_) }) => widths
        _ => []
      }
    }
    let item_widths = fn() {
      let ws = widths()
      if ws.length() > 0 { ws } else { shared() }
    }
    let smaller = fn() {
      match fit() {
        Some({ fit: Smaller(k), .. }) => k
        _ => 1.0
      }
    }
    let seg = @glass.liquid_segmented_node(
      inner,
      labels,
      chosen,
      choose,
      drag=thumb.dd,
      glass_track=false,
      pad=seg_inset,
      gap=0.0,
      widths=item_widths,
      height_by=track_h,
      kind=Radio,
      said~,
      shown=fn() { !menu() },
      render_item=fn(opt, idx, _is_chosen) {
        let idx_f = idx.to_double()
        opt.box(fn(w) {
          w
          .words(By(fn() { labels().get(idx).unwrap_or("") }))
          .words_look(By(fn() {
            opt.words_redone() |> ignore
            let (size, line) = @ui.tree_theme().text_size(Base)
            let k = smaller()
            let (size, line) = if k == 1.0 {
              (size, line)
            } else {
              (node_sp_of(w, node_sp(w, size) * k), node_sp_of(w, node_sp(w, line) * k))
            }
            { size, weight: 400, line, wrap: false, tracking: @view.letters_own, balance: false, max_lines: 0 }
          }))
          .ink(By(fn() {
            let lit = dclamp(1.0 - (thumb.dd.value(w) - idx_f).abs(), 0.0, 1.0)
            @ui.blend(theme().p.muted, theme().p.text, lit)
          }))
          |> ignore
        })
        |> ignore
      },
      loc~,
    )
    seg.grow(Is(1.0)).laid_nowhere(By(menu)) |> ignore
    // not side by side: the chosen one's words (cut short where they must be), a chevron at its end; pressed, a pick of
    // them all beside it, the chosen one marked
    let words = fn() { labels().get(chosen()).unwrap_or("") }
    let opened : @signals.Signal[Int] = @signals.signal(0)
    let open = fn() {
      let s = opened.get()
      s != 0 && presented_drawn_of(s)
    }
    @headless.disclosure(
      inner,
      fn() { if said == "" { words() } else { said + " " + words() } },
      open,
      fn(m) {
        let (x, y, w, h) = m.rect()
        let all = @signals.untracked(labels)
        let now = @signals.untracked(chosen)
        pick(
          "",
          all.mapi(fn(i, l) { choice(i.to_string(), l) }),
          now.to_string(),
          fn(k) {
            let i = labels_at(all, k, now)
            if i != now {
              choose(i)
            }
          },
          from=At(x, y, w, h),
          search=false,
        )
        opened.set(last_presented())
      },
      fn(m, _) {
        m
        .row(Is(true))
        .grow(Is(1.0))
        .laid_nowhere(By(fn() { !menu() }))
        .height(By(fn() { Some(track_h()) }))
        .radius(By(fn() { track_h() / 2.0 }))
        .ground(By(@glass.ctrl_seg_embedded_track_ink))
        .lines_up(Is(Some(Middle)))
        .padding(Is((seg_inset + seg_menu_in, seg_inset, seg_inset + seg_menu_in, seg_inset)))
        .gap(Is(seg_menu_gap))
        |> ignore
        // (where even its ellipsis has not the room, that drawn past its words' box into the gap before the chevron, as
        // seg_menu_words' `w=Cut` words are drawn)
        m.box(fn(w) { styled_words(w.grow(Is(1.0)), words, fn() { seg_menu_words }).ellipsis_past(Is(true)) |> ignore })
        |> ignore
        icon_node(m, "chevron-down", seg_chevron, By(fn() { theme().p.muted })) |> ignore
      },
    )
    |> ignore
  })
}

///|
/// How `room` is shared among items each `least` wide at least, as flex shares it among items grown alike from nothing:
/// alike, one that would come out narrower than its least kept at it and what is left shared among the others.
fn seg_shares(room : Double, least : Array[Double]) -> Array[Double] {
  let n = least.length()
  let kept = Array::make(n, false)
  let mut share = 0.0
  let mut again = true
  while again {
    again = false
    let mut left = room
    let mut free = 0
    for i in 0..<n {
      if kept[i] {
        left = left - least[i]
      } else {
        free = free + 1
      }
    }
    share = if free > 0 { dmax(0.0, left) / free.to_double() } else { 0.0 }
    for i in 0..<n {
      if !kept[i] && least[i] > share {
        kept[i] = true
        again = true
      }
    }
  }
  least.mapi(fn(i, l) { if kept[i] { l } else { share } })
}

///|
/// How wide a filling Seg of `labels` is with their words whole at their size with their sides, and how narrow it may
/// go: the chosen one's (the widest's) words with the chevron (seg_room's, the old view's), as node `v` has the system's
/// size of words and the theme as they change (a binding reading it follows them).
fn seg_room_of(v : @view.View, labels : Array[String]) -> (Double, Double) {
  v.words_redone() |> ignore
  let t = @ui.tree_theme()
  let size = node_sp(v, t.text_size(Base).0)
  let whole = labels.fold(init=2.0 * seg_inset, fn(s, l) { s + node_words_w(l, size) + 2.0 * seg_side })
  let menu = node_sp(v, t.text_size(Body).0)
  let widest = labels.fold(init=0.0, fn(m, l) { dmax(m, node_words_w(l, menu)) })
  (whole, 2.0 * seg_inset + 2.0 * seg_menu_in + widest + seg_menu_gap + seg_chevron)
}

///|
/// A narrow page's choice at a head's end (segmented's there: seg_room), in `parent`: a Seg as wide as its options
/// with their words whole at their size with their sides, as narrow as the chosen one's (the widest's) words with the
/// chevron where its line has less (giving way first: what is at a head's end does), filling what that leaves it, as
/// seg_fill_node is; its words at the system's size of words as that changes. `labels`, `chosen`, `choose`, `said`:
/// seg_fill_node's.
#callsite(autofill(loc))
pub fn seg_head_node(
  parent : @view.View,
  labels : () -> Array[String],
  chosen : () -> Int,
  choose : (Int) -> Unit,
  said? : String = "",
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(b) {
    let room = fn() { seg_room_of(b, labels()) }
    b
    .width(By(fn() { Some(room().0) }))
    .min_width(By(fn() { Some(room().1) }))
    .shrink(Is(1.0))
    |> ignore
    seg_fill_node(b, labels, chosen, choose, said~) |> ignore
  })
}

///|
/// A choice of a few on a page made once (segmented's), by how the page is laid out (look_node), in `slot`, which it
/// lays out: narrow, Seg (seg_fill_node) sharing its line, the slot growing from none to what the line leaves it, or
/// at a head's end (`head`) as wide as its options (seg_head_node); wide, the web's Segmented (seg_node), as wide as
/// its options, the slot as wide as it. Inside a pushed narrow page's floating liquid glass top bar (`back_bar_lent`),
/// `head=true` is omitted from the bar and must be paired with `narrow_bar_choice_node` at the top of the page body.
/// `labels`, `chosen`, `choose`, `said`: theirs.
#callsite(autofill(loc))
pub fn segmented_node(
  slot : @view.View,
  labels : () -> Array[String],
  chosen : () -> Int,
  choose : (Int) -> Unit,
  head? : Bool = false,
  said? : String = "",
  loc~ : SourceLoc,
) -> Unit {
  match look_node(slot) {
    Wide => seg_node(loc~, slot, labels, chosen, choose, said~) |> ignore
    Narrow if head =>
      if !slot.lent(back_bar_lent).unwrap_or(false) {
        seg_head_node(slot, labels, chosen, choose, said~) |> ignore
      }
    Narrow => {
      slot.grow(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
      seg_fill_node(slot, labels, chosen, choose, said~) |> ignore
    }
  }
}

///|
/// How high segmented_node stands in a page laid out `look`: wide, the web's Segmented's track round its options; narrow,
/// Seg's (segmented_height's).
pub fn segmented_node_height(look : Look) -> Double {
  match look {
    Narrow => segmented_narrow_h
    Wide => segmented_h + 2.0 * segmented_pad
  }
}

///|
/// A choice of a few ways, an icon each, among a bar's buttons (segmented's of icons in a bar: `bar` with `icons`), as
/// nodes in `parent`, over mbui's headless radio group: as high as the bar's buttons, its track 2 round its options, each
/// option square, the chosen one on the lifted thumb, which goes to the one chosen as that changes; its icons the ink
/// where chosen or pointed at, else muted. `ways` are its options by key (each key's icon and what it is called, read
/// out and its tip), as they are now; `chosen` the key chosen, `choose` told the one pressed (the one chosen again
/// too: where the room has not what was chosen before, the one shown is chosen again). The node.
#callsite(autofill(loc))
pub fn seg_icons_node(
  parent : @view.View,
  ways : () -> Array[(String, String, String)],
  chosen : () -> String,
  choose : (String) -> Unit,
  said? : String = "",
  tips? : TipLayer,
  loc~ : SourceLoc,
) -> @view.View {
  let pad = segmented_bar_pad
  let high = icon_button_side - 2.0 * pad
  let at = fn() { ways().search_by(fn(w) { w.0 == chosen() }).unwrap_or(0) }
  let g = @glass.liquid_segmented_node(
    parent,
    fn() { ways().map(fn(w) { w.2 }) },
    at,
    fn(i) {
      match @signals.untracked(ways).get(i) {
        Some((k, _, _)) => choose(k)
        None => ()
      }
    },
    glass_track=false,
    pad~,
    gap=segmented_gap,
    widths=fn() { Array::make(ways().length(), high) },
    height_by=fn() { icon_button_side },
    kind=Radio,
    said~,
    in_node=true,
    render_item=fn(seg, idx, is_chosen) {
      icon_node(
        seg,
        "",
        16.0,
        By(fn() {
          if is_chosen() || seg.pointed() {
            theme().p.text
          } else {
            theme().p.muted
          }
        }),
        name_now=fn() { ways().get(idx).map(fn(w) { w.1 }).unwrap_or("") },
      )
      |> ignore
      match tips {
        Some(layer) =>
          tip_node(layer, seg, fn() { ways().get(idx).map(fn(w) { w.2 }).unwrap_or("") }) |> ignore
        None => ()
      }
    },
    loc~,
  )
  g
  .width(By(fn() {
    let n = ways().length()
    Some(2.0 * pad + n.to_double() * high + dmax(0.0, (n - 1).to_double()) * segmented_gap)
  }))
  .shrink(Is(0.0))
  |> ignore
  g
}
