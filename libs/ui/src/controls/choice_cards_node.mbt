// A choice of a few ways of showing one thing, as cards side by side (列表 | 看板, say, at a panel's top): each an icon
// over its one line of words in its middle, as wide as the others, the one chosen lifted (the theme's lifted, a
// hairline round it and its shadow, as a segmented choice's thumb), the others quiet on a faint ground that the hand
// warms; each chosen by a press, the arrows along them, a screen reader's Activate, read out as a radio of a group
// (mbui's headless radio_group: this is its look alone).

///|
/// How tall a card is, how far apart they are, their icon and the room between it and the words.
let choice_card_h : Double = 58.0

///|
let choice_card_gap : Double = 6.0

///|
let choice_card_icon : Double = 20.0

///|
let choice_card_icon_gap : Double = 4.0

///|
/// The cards of `items` in `parent` (each its icon's name and its words), `chosen()` the one chosen, `choose` told the
/// one a press, an arrow or a screen reader chooses (the caller says it chosen then: `chosen` follows it), `said` what
/// a screen reader calls them. Their corner is a row's (@sf.row_corner): in a panel, its padding round them, concentric
/// with the panel's own (r_menu).
#callsite(autofill(loc))
pub fn choice_cards_node(
  parent : @view.View,
  items : () -> Array[(String, String)],
  chosen : () -> Int,
  choose : (Int) -> Unit,
  said? : String = "",
  loc~ : SourceLoc,
) -> @view.View {
  // (a node of its own, the group's: as wide as what holds it, whichever way that lays out, the cards sharing it)
  parent.box(made_for=loc, fn(line) {
  line.width_share(Is(1.0)) |> ignore
  @headless.radio_group(line, fn() { said }, chosen, choose, in_node=true, fn(g, rg) {
    g.row(Is(true)).gap(Is(choice_card_gap)) |> ignore
    // (as many as there are as they are made; their words and icons as they are said)
    for k in 0..<@signals.untracked(items).length() {
      let icon = fn() { items().get(k).map(fn(i) { i.0 }).unwrap_or("") }
      let label = fn() { items().get(k).map(fn(i) { i.1 }).unwrap_or("") }
      rg.item(g, fn() { k }, label, fn(c, item) {
        let on = fn() { item.chosen() }
        // (the hand on it, as a button's: how far its ground has gone towards its warmed one)
        let lit = fn() { !on() && (item.hovered() || item.focus_shown() || item.pressed()) }
        let hand = @motion.NodeWay::new(if @signals.untracked(lit) { 1.0 } else { 0.0 })
        c.reacts(lit, fn(l) { hand.go_ms(c, if l { 1.0 } else { 0.0 }, dur_ms) })
        let ink = fn() { if on() { theme().p.text } else { theme().p.muted } }
        c
        .row(Is(false))
        .grow(Is(1.0))
        .basis(Is(Some(0.0)))
        .min_width(Is(Some(0.0)))
        // (as tall at least: taller with the system's words larger)
        .min_height(Is(Some(choice_card_h)))
        .padding(Is((8.0, 8.0, 8.0, 8.0)))
        .radius(Is(row_corner))
        .lines_up(Is(Some(Middle)))
        .lies_along(Is(Middle))
        .gap(Is(choice_card_icon_gap))
        .ground(By(fn() {
          if on() {
            @ui.tree_theme().lifted
          } else {
            over(alpha(theme().p.text, 0.04), alpha(theme().p.hover, hand.shown(c)))
          }
        }))
        // (the chosen one's hairline, the keyboard's focus a ring of the theme's where it is shown)
        .edge(By(fn() {
          if item.focus_shown() {
            (@ui.tree_theme().focus_w, @ui.tree_theme().focus)
          } else if on() {
            (control_edge_w, theme().p.line)
          } else {
            (0.0, 0L)
          }
        }))
        .shadow(By(fn() {
          if on() && !@ui.tree_theme().dark {
            (1.0, 0.0, theme().p.shadow)
          } else {
            (0.0, 0.0, 0L)
          }
        }))
        .shadow_outside(Is(true))
        |> ignore
        icon_node(c, "", choice_card_icon, By(ink), name_now=icon) |> ignore
        c.box(fn(w) {
          w
          .words(By(label))
          .words_look(By(fn() {
            // (its line so many times its size as drawn, at the system's size of words: view_line's)
            {
              size: theme().t.ui,
              weight: if on() { 500 } else { 400 },
              line: -@ui.tree_theme().text_line,
              wrap: false,
              tracking: @view.letters_own,
              balance: false,
              max_lines: 0,
            }
          }))
          .ink(By(ink))
          .cuts(Is(true))
          .min_width(Is(Some(0.0)))
          .allow_ellipsis(Is(true))
          |> ignore
        })
        |> ignore
      })
      |> ignore
    }
  })
  |> ignore
  })
}
