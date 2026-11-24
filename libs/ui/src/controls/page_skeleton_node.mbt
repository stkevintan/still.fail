// Lightweight page skeletons (<= 8 parameters) with block reuse on by default:
// - `reused_page_node`: concise entry over `page_node` where all blocks default to pooled reuse (`shape = Some(0)`).
// - `list_page_node`: generic virtualized + block-reused list page (`View::scrolls_reused`) with `min_height(Some(0.0))`,
//   safe-area insets, narrow/wide layout lending, loading skeleton, empty state, and `TipLayer`.
// - `detail_page_node`: scrollable detail/form page with `Scroll::list()`, `min_height(Some(0.0))`, safe-area insets,
//   wide centered reading column (`lane_node`), narrow page margins (`page_block`), back/actions, and loading skeleton.

///|
/// Concise `page_node` entry with block reuse enabled by default (`shape` defaults to `Some(0)`): callers provide a
/// single reactive `block(room, kind, key)` instead of writing separate `block` and `make_reused` builders.
#callsite(autofill(loc))
pub fn reused_page_node(
  v : @view.View,
  title : () -> String,
  blocks : () -> Array[String],
  block : (@view.View, Int, () -> String) -> Unit,
  on_back~ : () -> Unit,
  shape? : (String) -> Int? = fn(_) { Some(0) },
  frame? : () -> PageFrame = fn() { no_frame },
  width? : () -> Double,
  loc~ : SourceLoc,
) -> Unit {
  v.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
  v.box(made_for=loc, fn(host) {
    host.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
    page_node(
      host,
      title,
      blocks,
      fn(room, k) { block(room, 0, fn() { k }) },
      on_back~,
      frame~,
      width?,
      reused=shape,
      make_reused=block,
    )
  })
  |> ignore
}

///|
/// Optional configuration for `list_page_node`.
pub(all) struct ListPageOpts[K] {
  shape : (K) -> Int
  reuses : (K) -> Bool
  est : Double
  frame : () -> PageFrame
  width : (() -> Double)?
  scroll : @view.Scroll?
  actions : ((@view.View) -> Unit)?
  empty : ((@view.View) -> Unit)?
  loading : (() -> Bool)?
  loading_view : ((@view.View) -> Unit)?
  near_foot : (Double, () -> Bool, () -> Unit)?
}

///|
/// Default `ListPageOpts`: all keys share reuse pool `0`, reuse enabled, standard block estimate, `no_frame`.
pub fn[K] ListPageOpts::default() -> ListPageOpts[K] {
  {
    shape: fn(_) { 0 },
    reuses: fn(_) { true },
    est: pg_block_est,
    frame: fn() { no_frame },
    width: None,
    scroll: None,
    actions: None,
    empty: None,
    loading: None,
    loading_view: None,
    near_foot: None,
  }
}

///|
// kept across runs: TipLayer lent by list_page_node / detail_page_node, released with the page
let skeleton_tips_lent : @view.Lent[TipLayer] = @view.Lent::new()

///|
/// Three mutually exclusive body states for `list_page_node`.
#derive(Eq)
priv enum ListPageState {
  ListLoading
  ListEmpty
  ListReady
}

///|
/// Generic virtualized list page with block reuse on by default (`View::scrolls_reused`): automatically applies
/// `grow(1.0)` + `min_height(Some(0.0))`, derives `Look` from `opts.width`, lends `part_at`, renders safe-area insets,
/// standard narrow/wide header with back & actions, loading skeleton, centered empty state, and `TipLayer`.
#callsite(autofill(loc))
pub fn[K : Hash + Eq] list_page_node(
  v : @view.View,
  title : () -> String,
  keys : () -> Array[K],
  item : (@view.View, () -> K) -> Unit,
  on_back~ : () -> Unit,
  opts? : ListPageOpts[K],
  loc~ : SourceLoc,
) -> Unit {
  let opts = opts.unwrap_or_else(fn() { ListPageOpts::default() })
  v.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
  let look = match opts.width {
    Some(w) => fn() { look_for(w()) }
    None => fn() { Narrow }
  }
  let own_scroll = @view.Scroll::list()
  let scroll = opts.scroll.unwrap_or(own_scroll)
  let tips_at : Ref[@view.View?] = Ref(None)
  let tips = TipLayer::new(fn() { tips_at.val })
  v.lends(skeleton_tips_lent, tips) |> ignore
  let is_loading = opts.loading.unwrap_or(fn() { false })
  let state = fn() -> ListPageState {
    if is_loading() {
      ListLoading
    } else if keys().is_empty() {
      ListEmpty
    } else {
      ListReady
    }
  }
  v.pick(look, fn(p, l) {
    p.grow(Is(1.0)).min_height(Is(Some(0.0))).lends(part_at, { look: l, section: false, list: false, card: false }) |> ignore
    p.pick(state, at_once=true, fn(stage, st) {
      stage.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      match st {
        ListLoading =>
          skeleton_page_loading(loc~, stage, l, title, on_back, opts.frame, opts.actions, tips, opts.loading_view)
        ListEmpty =>
          skeleton_page_empty(loc~, stage, l, title, on_back, opts.frame, opts.actions, tips, opts.empty)
        ListReady =>
          stage.box(made_for=loc, fn(sc) {
            sc.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
            sc.scrolls_reused(
              scroll,
              keys,
              fn(s, key) {
                match l {
                  Narrow => {
                    s.grow(Is(1.0)) |> ignore
                    page_block(s, fn(room) { item(room, key) })
                  }
                  Wide =>
                    lane_node(s, fn(col) {
                      col.box(fn(room) {
                        room.padding(Is((desk_column_in, 0.0, desk_column_in, 0.0))) |> ignore
                        item(room, key)
                      })
                      |> ignore
                    })
                }
              },
              shape=opts.shape,
              reuses=opts.reuses,
              est=opts.est,
              bar=@ui.tree_scroll_bar(),
              near_foot?=opts.near_foot,
              head=fn(h) { skeleton_page_head(h, l, title, on_back, opts.frame, opts.actions, tips) },
              foot_clear=fn() { skeleton_page_foot_h(sc, l, opts.frame) },
            )
            |> ignore
          })
          |> ignore
      }
    })
  })
  v.box(fn(t) {
    t.over(Is(true)) |> ignore
    tips_at.val = Some(t)
  })
  |> ignore
}

///|
/// Lightweight scrollable detail/form page skeleton (<= 8 arguments): provides `Scroll::list()`,
/// `min_height(Some(0.0))`, safe-area insets, wide centered reading column (`lane_node`), narrow page margins
/// (`page_block`), back & actions, loading skeleton state, and a mounted `TipLayer` overlay.
#callsite(autofill(loc))
pub fn detail_page_node(
  v : @view.View,
  title : () -> String,
  body : (@view.View) -> Unit,
  on_back~ : () -> Unit,
  frame? : () -> PageFrame = fn() { no_frame },
  width? : () -> Double,
  actions? : (@view.View) -> Unit,
  loading? : () -> Bool = fn() { false },
  loc~ : SourceLoc,
) -> Unit {
  v.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
  let look = match width {
    Some(w) => fn() { look_for(w()) }
    None => fn() { Narrow }
  }
  let scroll = @view.Scroll::list()
  let tips_at : Ref[@view.View?] = Ref(None)
  let tips = TipLayer::new(fn() { tips_at.val })
  v.lends(skeleton_tips_lent, tips) |> ignore
  v.pick(look, fn(p, l) {
    p.grow(Is(1.0)).min_height(Is(Some(0.0))).lends(part_at, { look: l, section: false, list: false, card: false }) |> ignore
    p.box(made_for=loc, fn(sc) {
      sc
      .grow(Is(1.0))
      .min_height(Is(Some(0.0)))
      .scrolls(scroll, bar=@ui.tree_scroll_bar(), fn(content) {
        skeleton_page_head(content, l, title, on_back, frame, actions, tips)
        content.pick(loading, at_once=true, fn(slot, is_load) {
          if is_load {
            skeleton_page_bones(slot, l)
          } else {
            match l {
              Narrow => page_block(slot, body)
              Wide =>
                lane_node(slot, fn(col) {
                  col.box(fn(room) {
                    room.padding(Is((desk_column_in, desk_first_top, desk_column_in, 0.0))) |> ignore
                    body(room)
                  })
                  |> ignore
                })
            }
          }
        })
        content.box(fn(f) { f.height(By(fn() { Some(skeleton_page_foot_h(f, l, frame)) })) |> ignore }) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  v.box(fn(t) {
    t.over(Is(true)) |> ignore
    tips_at.val = Some(t)
  })
  |> ignore
}

///|
/// Non-generic header helper shared by `list_page_node` and `detail_page_node`: safe-area top spacer plus standard
/// narrow (`nav_back_node` + `pg_title` + wrapping `actions`) or wide (`lane_node` + `wide_head_node`) header.
fn skeleton_page_head(
  parent : @view.View,
  look : Look,
  title : () -> String,
  on_back : () -> Unit,
  frame : () -> PageFrame,
  actions : ((@view.View) -> Unit)?,
  tips : TipLayer,
) -> Unit {
  parent.show(fn() { frame().top > 0.0 }, at_once=true, fn(top) {
    top.height(By(fn() { Some(frame().top) })) |> ignore
  })
  match look {
    Narrow => {
      parent.show(fn() { frame().back is Some(_) && !frame().named }, at_once=true, fn(b) {
        b
        .row(Is(true))
        .gap(Is(8.0))
        .padding(Is((pg_back_pill_x, pg_back_top, pg_back_pill_x, pg_back_foot + pg_back_content_gap)))
        .lines_up(Is(Some(Middle)))
        |> ignore
        let left_extra : @signals.Signal[Double] = @signals.signal(0.0)
        let balance_owner : Ref[Int] = Ref(0)
        b.box(fn(left) {
          // (the room mirroring the trailing pill gives way first where the bar is short of room, so the title goes off
          // its centre before the trailing actions are cut: pg_balance_yields)
          left
          .row(Is(true))
          .lies_along(Is(Start))
          .lines_up(Is(Some(Middle)))
          .shrink(Is(pg_balance_yields))
          .min_width(Is(Some(pg_back_pill_h)))
          |> ignore
          nav_back_circle_node(left, fn() { frame().back.unwrap_or("") }, on_back)
          left.box(fn(bal) {
            bal.width(By(fn() { Some(left_extra.get()) })).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
          })
          |> ignore
        })
        |> ignore
        b.box(fn(mid) {
          mid
          .grow(Is(1.0))
          .shrink(Is(1.0))
          .min_width(Is(Some(pg_title_least)))
          .lines_up(Is(Some(Middle)))
          .lies_along(Is(Middle))
          |> ignore
          mid.box(fn(w) {
            styled_words(w, title, fn() { nav_title_words }).cuts(Is(true)).min_width(Is(Some(0.0))) |> ignore
          })
          |> ignore
        })
        |> ignore
        b.box(fn(right) {
          right
          .row(Is(true))
          .shrink(Is(1.0))
          .min_width(Is(Some(pg_back_pill_h)))
          .lies_along(Is(End))
          .lines_up(Is(Some(Middle)))
          |> ignore
          match actions {
            Some(f) =>
              right.box(fn(a) {
                a.row(Is(true)).gap(Is(8.0)).lines_up(Is(Some(Middle))).shrink(Is(1.0)) |> ignore
                a.lends(back_bar_lent, true) |> ignore
                a.lends(back_bar_balance, (left_extra, balance_owner)) |> ignore
                f(a)
              })
              |> ignore
            None => ()
          }
        })
        |> ignore
      })
      parent.show(fn() { frame().back is None && !frame().named }, at_once=true, fn(s) {
        s
        .padding(By(fn() {
          let f = frame()
          let alone = f.back is None && f.top <= 0.0
          (pg_title_x, if alone { pg_title_alone_top } else { 0.0 }, pg_title_end, pg_title_foot)
        }))
        |> ignore
        s.box(fn(l) {
          l
          .row(Is(true))
          .gap(Is(pg_title_gap))
          .wraps(Is(Some(pg_title_lines)))
          .wraps_at_least(Is(true))
          .lies_along(Is(End))
          .lines_up(Is(Some(Middle)))
          |> ignore
          l.box(fn(w) {
            w.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(pg_title_least))) |> ignore
            w.box(fn(t) { styled_words(t, title, fn() { pg_title }) |> ignore }) |> ignore
          })
          |> ignore
          match actions {
            Some(f) =>
              l.box(fn(a) {
                a.row(Is(true)).gap(Is(pg_title_gap)).lines_up(Is(Some(Middle))).shrink(Is(1.0)) |> ignore
                f(a)
              })
              |> ignore
            None => ()
          }
        })
        |> ignore
      })
    }
    Wide =>
      parent.show(fn() { !frame().named }, at_once=true, fn(s) {
        lane_node(s, fn(col) { wide_head_node(col, title, on_back, frame, fn() { "" }, actions, fn() { "" }, tips) })
      })
  }
}

///|
/// Non-generic loading view for `list_page_node`.
#callsite(autofill(loc))
fn skeleton_page_loading(
  parent : @view.View,
  look : Look,
  title : () -> String,
  on_back : () -> Unit,
  frame : () -> PageFrame,
  actions : ((@view.View) -> Unit)?,
  tips : TipLayer,
  loading_view : ((@view.View) -> Unit)?,
  loc~ : SourceLoc,
) -> Unit {
  parent.box(made_for=loc, fn(b) {
    b.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
    skeleton_page_head(b, look, title, on_back, frame, actions, tips)
    match loading_view {
      Some(custom) => custom(b)
      None => skeleton_page_bones(b, look)
    }
    b.box(fn(f) { f.height(By(fn() { Some(skeleton_page_foot_h(f, look, frame)) })) |> ignore }) |> ignore
  })
  |> ignore
}

///|
/// Default loading skeleton cards laid out in narrow page margins or wide centered lane.
fn skeleton_page_bones(parent : @view.View, look : Look) -> Unit {
  let cards = fn(room : @view.View) {
    room.box(fn(col) {
      col.gap(Is(skeleton_cards_gap)) |> ignore
      for _ in 0..<skeleton_cards_count {
        skeleton_card_node(col, lines=2) |> ignore
      }
    })
    |> ignore
  }
  match look {
    Narrow => page_block(parent, cards)
    Wide =>
      lane_node(parent, fn(col) {
        col.box(fn(room) {
          room.padding(Is((desk_column_in, desk_first_top, desk_column_in, 0.0))) |> ignore
          cards(room)
        })
        |> ignore
      })
  }
}

///|
/// Non-generic centered empty state for `list_page_node`.
#callsite(autofill(loc))
fn skeleton_page_empty(
  parent : @view.View,
  look : Look,
  title : () -> String,
  on_back : () -> Unit,
  frame : () -> PageFrame,
  actions : ((@view.View) -> Unit)?,
  tips : TipLayer,
  empty : ((@view.View) -> Unit)?,
  loc~ : SourceLoc,
) -> Unit {
  parent.box(made_for=loc, fn(b) {
    b.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
    skeleton_page_head(b, look, title, on_back, frame, actions, tips)
    b.box(fn(center) {
      center.grow(Is(1.0)).min_height(Is(Some(0.0))).lies_along(Is(Middle)).lines_up(Is(Some(Middle))) |> ignore
      match empty {
        Some(custom) => custom(center)
        None => empty_state_node(center, "list", fn() { title() }) |> ignore
      }
    })
    |> ignore
    b.box(fn(f) { f.height(By(fn() { Some(skeleton_page_foot_h(f, look, frame)) })) |> ignore }) |> ignore
  })
  |> ignore
}

///|
/// Foot clearance matching `page_node` (narrow `page_foot`, wide `desk_foot_h`) plus `frame().foot`.
fn skeleton_page_foot_h(v : @view.View, look : Look, frame : () -> PageFrame) -> Double {
  let base = match look {
    Narrow => page_foot(v)
    Wide => desk_foot_h
  }
  base + frame().foot
}

///|
let skeleton_cards_count : Int = 3

///|
let skeleton_cards_gap : Double = 12.0
