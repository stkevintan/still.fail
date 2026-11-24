// What a confirm, a question, a menu and a pick show on 小屏 as a page of a sheet of the window's tree (sheet_node), as
// the host's sheet showed them (sheet_body): each a panel whose body is nodes (PanelOf's `nodes`), titled by the sheet
// as a panel is (its title's row, a back key before it on a level past the first). A confirm: its words, its warning,
// cancel and its action at their end, on one line where they have the room, the action under cancel where not (a
// reverse wrap, the action kept at the foot's end). A question: its line (input_node, the keys its as the sheet opens:
// panel_opens_in_node), its hint, cancel and its action as a confirm's. A menu: its rows, a heading as a sheet's title,
// a line between parts (none at either end nor twice: menu_clean_items); an item that opens a menu opens it as a level
// of the same sheet (present: panel_page), back to this one. A pick: its choices as a menu's rows, each its icon or its
// mark before its words, its value at its end, its note under them, a check on the one chosen; one of pick_search_from
// choices or more a share of the window tall (sheet_long_pick), its list scrolling in the room it leaves, its search
// over it where it has one (not given the keys as it opens: a sheet's search is looked at first).

///|
/// The panel a sheet of the window's tree shows `p` as on 小屏 (presented_nodes' sheet_node): a panel's own, else what
/// a confirm, a question, a menu or a pick is there (sheet_shows_panel).
fn sheet_panel_now(p : Presented) -> PanelOf {
  match p.shows {
    Panel(x) => x
    _ => sheet_shows_panel(p)
  }
}

///|
/// What a confirm, a question, a menu or a pick presented as `p` shows on a sheet, as a panel whose body is nodes.
fn sheet_shows_panel(p : Presented) -> PanelOf {
  let serial = p.serial
  match p.shows {
    Confirm(title, words, warning, action, danger, run) =>
      sheet_nodes_panel(title, 0.0, fn(col, close) {
        sheet_confirm_node(col, words, warning, action, danger, fn() { dismissed_now(serial) }, fn() {
          close()
          run()
        })
      })
    Ask(title, value, placeholder, action, hint, secret, empty, run) =>
      sheet_nodes_panel(title, 0.0, fn(col, close) {
        sheet_ask_node(col, title, p.line, value, placeholder, action, hint, secret, empty, fn() { dismissed_now(serial) }, fn(
          line,
        ) {
          close()
          run(line)
        })
      })
    // (what it holds as it is now, where it is kept: given anew there whole, then told, presented_changed)
    Menu(items, title, _, _) => menu_sheet_panel(serial, title, fn() { presented_items_of(serial, items) })
    Pick(title, choices, chosen, choose, _, _, search) => {
      let many = choices.length() >= pick_search_from
      sheet_nodes_panel(title, if many { sheet_long_pick } else { 0.0 }, fn(col, close) {
        sheet_pick_node(col, choices, chosen, p.line, many, search && many, fn(k) {
          close()
          choose(k)
        })
      })
    }
    Panel(x) => x
  }
}

///|
/// A menu of `items` (as they are now) titled `title` as a page of the sheet presented as `serial`: its first, or a
/// level a menu's item opened (present's, headed by its back key whatever its title).
fn menu_sheet_panel(serial : Int, title : String, items : () -> Array[MenuItem?]) -> PanelOf {
  sheet_nodes_panel(title, 0.0, fn(col, close) {
    sheet_menu_node(col, fn() { menu_clean_items(items()) }, close, fn() { presented_open_of(serial) }, serial~)
  })
}

///|
/// A panel titled `title` whose body is `body` made as nodes, `tall` a share of the window (0: as tall as it holds), for
/// a sheet of the window's tree alone.
fn sheet_nodes_panel(title : String, tall : Double, body : (@view.View, () -> Unit) -> Unit) -> PanelOf {
  {
    title,
    description: "",
    w: panel_w,
    fits: false,
    wide: false,
    live: None,
    tall,
    grows: false,
    focus: true,
    ruled: false,
    fade_out_together: false,
    form: false,
    popover: false,
    stage: false,
    above: None,
    heads_itself: false,
    side: Bottom,
    along: Start,
    offset: panel_offset,
    match_panel: 0,
    scrolls_under: false,
    on_back: None,
    nodes: {
      body,
      foot: None,
      hugs: false,
      hugs_centred: false,
      steps: false,
      sheet_heads: false,
      heads: false,
      top: 0.0,
      most: None,
      flush: true,
      head_end: None,
    },
  }
}

///|
/// A confirm's words in `col` of its sheet (sheet_body's): `words`, its `warning` in red, then cancel and `action` (red
/// where `danger`), at their end.
#callsite(autofill(loc))
fn sheet_confirm_node(
  col : @view.View,
  words : String,
  warning : String,
  action : String,
  danger : Bool,
  cancel : () -> Unit,
  confirm : () -> Unit,
  loc~ : SourceLoc,
) -> Unit {
  col.box(made_for=loc, fn(b) {
    style_node(b, fn() { sheet_says_at.then(panel_words_in_node(col)) })
    words_node(b, fn() { words }, fn() { sheet_lead }) |> ignore
    if warning != "" {
      words_node(b, fn() { warning }, fn() { sheet_warning }) |> ignore
    }
    sheet_actions_node(b, fn(f) {
      button_node(f, fn() { t("common.cancel") }, cancel) |> ignore
      // (its action the default where it can be undone, as the dialog's: confirm_panel's)
      button_node(f, fn() { action }, confirm, tone=if danger { DangerSolid } else { Primary }, default_on?=if danger {
        None
      } else {
        Some(fn() { true })
      })
      |> ignore
    })
  })
  |> ignore
}

///|
/// A question's line in `col` of its sheet (sheet_body's), titled `title` (its field read out by it where it shows no
/// placeholder): its field (`line`, `placeholder` while empty, as dots where
/// `secret`), the keys its as the sheet opens; its `hint` under it; cancel and `action`, which can be pressed while the
/// line, trimmed, can be said (ask_can). `say` with it, once, by its action or Enter.
#callsite(autofill(loc))
fn sheet_ask_node(
  col : @view.View,
  title : String,
  line : @ui.Field,
  value : String,
  placeholder : String,
  action : String,
  hint : String,
  secret : Bool,
  empty : Bool,
  cancel : () -> Unit,
  say : (String) -> Unit,
  loc~ : SourceLoc,
) -> Unit {
  let words = fn() { line.text().trim(chars=" \t\n").to_owned() }
  let can = fn() { ask_can(words(), value, empty) }
  let said = Ref(false)
  let go = fn() {
    if !said.val && @signals.untracked(can) {
      said.val = true
      say(@signals.untracked(words))
    }
  }
  col.box(made_for=loc, fn(b) {
    style_node(b, fn() { sheet_says_at.then(panel_words_in_node(col)) })
    let field = input_node(b, line, placeholder~, label=if placeholder == "" { title } else { "" }, secret~, submitted=fn(
      _,
    ) {
      go()
    })
    panel_opens_in_node(field)
    if hint != "" {
      words_node(b, fn() { hint }, fn() { sheet_hint }) |> ignore
    }
    sheet_actions_node(b, fn(f) {
      button_node(f, fn() { t("common.cancel") }, cancel) |> ignore
      button_node(f, fn() { action }, go, tone=Primary, disabled=fn() { !can() }) |> ignore
    })
  })
  |> ignore
}

///|
/// What a confirm's and a question's words stand in on a sheet (sheet_words_at's, its sides the column's): 10 apart.
// kept across runs: a value (no field of it changes)
let sheet_says_at : @ui.Style = @ui.css("w=Full gap=S2_5")

///|
/// A confirm's and a question's buttons in `parent` (sheet_actions'): at their end, 8 apart, 6 under what is over them
/// (the sheet's own room under them); where they have not the room on one line, those made first on a line over the
/// last, which stays at the foot's end (a reverse wrap: the action at the foot, by the thumb).
#callsite(autofill(loc))
fn sheet_actions_node(parent : @view.View, buttons : (@view.View) -> Unit, loc~ : SourceLoc) -> Unit {
  parent.box(made_for=loc, fn(f) {
    style_node(f, fn() {
      let ft = (panel_in_of(f).round_foot)()
      if ft > 0.001 {
        let at = @ui.capsule_in(pane_corner, button_height())
        sheet_actions_at.then(@ui.style(mr=room((at - sheet_panel_sides) * ft), mb=room((at - sheet_panel_foot) * ft)))
      } else {
        sheet_actions_at
      }
    })
    f.wraps(By(fn() { Some(ask_foot_lines()) }), reverse=true) |> ignore
    buttons(f)
  })
  |> ignore
}

///|
// kept across runs: a value (no field of it changes)
let sheet_actions_at : @ui.Style = @ui.css("row w=Full pt=S1_5 gap=S2 justify=JEnd")

///|
/// A menu's rows in `col` of its sheet (menu_rows'): each of `items()` by its place and its kind, a row pressed while
/// its sheet is `open()` closing it (`close`) and then doing what it does (chosen in the sheet presented as `serial`:
/// what it waits for may hold it open, choice_held); a heading a sheet's title, None a line between parts.
#callsite(autofill(loc))
fn sheet_menu_node(
  col : @view.View,
  items : () -> Array[MenuItem?],
  close : () -> Unit,
  open : () -> Bool,
  serial~ : Int,
  loc~ : SourceLoc,
) -> Unit {
  col.box(made_for=loc, fn(rows) {
    rows.each(fn() { items().mapi(fn(i, x) { (i, menu_kind(x)) }) }, fn(k) { k }, fn(cell, k) {
      let (i, kind) = k.untracked()
      let item = fn() {
        match items().get(i) {
          Some(Some(item)) => item
          _ => menu_none
        }
      }
      match kind {
        0 => cell.box(fn(r) { style_node(r, fn() { sheet_rule_across }) }) |> ignore
        1 =>
          cell.box(fn(h) {
            style_node(h, fn() { sheet_heading_across })
            // (a part of it in the accent where it is marked so: title_accent.mbt, as a sheet's title)
            if title_marked(@signals.untracked(fn() { item().label })) {
              h.box(fn(w) {
                w
                .words_runs(By(fn() { title_runs(item().label, theme().p.accent_text) }))
                .words_look(By(fn() { @ui.style_words(sheet_title_words) }))
                .ink(By(fn() { @ui.style_ink(sheet_title_words) }))
                |> ignore
              })
              |> ignore
            } else {
              words_node(h, fn() { item().label }, fn() { sheet_title_words }) |> ignore
            }
          })
          |> ignore
        _ =>
          sheet_row_node(
            cell,
            fn() { item().label },
            fn() { item().chosen == Some(true) },
            fn() {
              let it = @signals.untracked(item)
              // (once, while its sheet is open: a page gone back to is open again, chosen in anew)
              if open() {
                close()
                chosen_in(serial, it.select)
              }
            },
            icon=fn() { item().icon },
            danger=fn() { item().danger },
            disabled=fn() { item().disabled },
            further=fn() { item().further },
          )
      }
    })
  })
  |> ignore
}

///|
/// A pick's choices in `col` of its sheet (sheet_body's): each a row, the one `chosen` checked; `many` (a share of the
/// window tall) its list scrolling in the room it leaves, `search` (its line, `line`) over it, what is typed finding
/// by the words (pick_found), none found said so. `choose` with a choice's key, once.
#callsite(autofill(loc))
fn sheet_pick_node(
  col : @view.View,
  choices : Array[Choice],
  chosen : String,
  line : @ui.Field,
  many : Bool,
  search : Bool,
  choose : (String) -> Unit,
  loc~ : SourceLoc,
) -> Unit {
  let found = fn() { if search { pick_found(choices, line.text()) } else { choices } }
  let said = Ref(false)
  let go = fn(k : String) {
    if !said.val {
      said.val = true
      choose(k)
    }
  }
  // (its choices by key, once: they are what it was given, the same while it is open; the first of a key the one)
  let by_key : Map[String, Choice] = Map([])
  for x in choices {
    if !by_key.contains(x.key) {
      by_key[x.key] = x
    }
  }
  let rows = fn(b : @view.View) {
    b.each(fn() { found().map(fn(x) { x.key }) }, fn(k) { k }, fn(cell, k) {
      match by_key.get(k.untracked()) {
        Some(x) =>
          sheet_row_node(
            cell,
            fn() { x.label },
            fn() { x.key == chosen },
            fn() { go(x.key) },
            note=x.note,
            value=x.value,
            icon=fn() { x.icon },
            mark?=x.mark.map(fn(m) { fn(b, size) { choice_mark_node(b, m, size) } }),
            // (one not to be chosen: faint, taking no press, its note saying why: Choice's `disabled`)
            disabled=fn() { x.disabled },
          )
        None => ()
      }
    })
  }
  col.box(made_for=loc, fn(all) {
    if many {
      // (its list down to the sheet's foot, as the host's long pick had it: past the room its column leaves under it,
      // sheet_capped_room's)
      all.grow(Is(1.0)).shrink(Is(1.0)).min_height(Is(Some(0.0))).margin(Is((0.0, 0.0, 0.0, -sheet_panel_foot))) |> ignore
    }
    if search {
      // (its search, as far in as its rows: sheet_search_at's, entered from its words: Enter picks the first found)
      all.box(fn(s) {
        style_node(s, fn() { sheet_search_in })
        input_node(s, line, placeholder_by=fn() { t("common.search") }, submitted=fn(_) {
          match @signals.untracked(found).iter().find_first(fn(x) { !x.disabled }) {
            Some(x) => go(x.key)
            None => ()
          }
        })
        |> ignore
      })
      |> ignore
      all.show(fn() { found().is_empty() }, fn(e) {
        style_node(e, fn() { panel_words_in_node(col) })
        words_node(e, fn() { t("common.noMatch") }, fn() { sheet_lead }) |> ignore
      })
    }
    if many {
      // (the rest of the sheet, scrolling)
      let list = @view.Scroll::new()
      all.box(fn(l) {
        l.grow(Is(1.0)).shrink(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        l.scrolls(list, slop=@ui.touch_slop(), bar=@ui.tree_scroll_bar(), rows)
        .clips(By(fn() { list.goes() }))
        .bounds_input(By(fn() { list.goes() }))
        |> ignore
      })
      |> ignore
    } else {
      all.box(rows) |> ignore
    }
  })
  |> ignore
}

///|
/// A sheet's row across its column, flush with the sheet's sides (PanelNodes' `flush`): sheet_row_box's but its sides,
/// which are its column's (panel_row_in_node: its words as far in as the sheet's, its ground square).
// kept across runs: a value (no field of it changes)
let sheet_row_across : @ui.Style = @ui.css("row w=Full py=S3 gap=S3 align=ACenter")

///|
/// A line between a menu's rows across its column (sheet_rule's): as far in as the rows' words, sheet_row_sides and
/// its S2 in from the sheet's sides as the host's.
// kept across runs: a value (no field of it changes)
let sheet_rule_across : @ui.Style = sheet_rule.then(@ui.style(mx=room(panel_words)))

///|
/// A menu's heading across its column (sheet_title_row's, in the host's rows' room in: sheet_row_sides past it).
// kept across runs: a value (no field of it changes)
let sheet_heading_across : @ui.Style = sheet_title_row.then(@ui.style(px=room(sheet_row_sides + sheet_panel_sides)))

///|
/// A long pick's search on a sheet (sheet_search_at's: as far in as the host's rows, 10 under it).
// kept across runs: a value (no field of it changes)
let sheet_search_in : @ui.Style = @ui.css("w=Full pb=S2_5").then(@ui.style(px=room(sheet_row_sides)))

///|
/// A row of a sheet (sheet_row's) in `parent`: its icon (`icon()`, muted, red where `danger()`) or its `mark` before its
/// words, its words (`label()`, one line, cut short where it has not the room), its `value` at its end, a check in the
/// accent while `on()`, a chevron at its end while it asks more first (`further()`), its `note` under them (what leads it
/// by its first line); red where `danger()`, faint and taking
/// no press where `disabled()`; lit under the hand, rippling under a finger's press; pressed, `press`. Across its
/// column, flush with the sheet's sides (panel_row_in_node): its ground takes its shape from the sheet's, square (the
/// corner rule's "one across its container").
#callsite(autofill(loc))
fn sheet_row_node(
  parent : @view.View,
  label : () -> String,
  on : () -> Bool,
  press : () -> Unit,
  note? : String = "",
  value? : String = "",
  icon? : () -> String = fn() { "" },
  mark? : (@view.View, Double) -> Unit,
  danger? : () -> Bool = fn() { false },
  disabled? : () -> Bool = fn() { false },
  further? : () -> Bool = fn() { false },
  loc~ : SourceLoc,
) -> Unit {
  let th = fn() { theme() }
  let ink = fn() {
    let p = th().p
    if disabled() {
      p.subtle
    } else if danger() {
      p.red
    } else {
      p.text
    }
  }
  let leads = mark is Some(_) || @signals.untracked(icon) != ""
  // (read out by all its words, its value and what it is with them, as a long pick's row is: pick_row_node)
  let said = fn() { [label(), value, note].filter(fn(s) { s != "" }).join(" ") }
  @headless.choice(made_for=loc, parent, Button, said, on, fn(_) { press() }, disabled~, fn(r, ch) {
    style_node(r, fn() { sheet_row_across.then(panel_row_in_node(r)) })
    r
    .min_height(By(fn() { Some(th().items.least) }))
    .lines_up(Is(Some(if note == "" { Middle } else { Start })))
    |> ignore
    r.focus_ring_theme() |> ignore
    hover_ground_node(r, on=fn() { !disabled() })
    rippled_look(r, Is(0.0), fn() { ch.press() })
    // (its icon or its mark, on its first line: first_line_node)
    let lead = fn(at : @view.View) {
      first_line_node(at, Ui, fn(l) {
        match mark {
          Some(m) => l.box(fn(b) { m(b, th().items.mark) }) |> ignore
          None =>
            l.show(fn() { icon() != "" }, at_once=true, fn(i) {
              i.pick(icon, at_once=true, fn(slot, name) {
                icon_node(slot, name, th().items.mark, By(fn() { if danger() { ink() } else { th().p.muted } })) |> ignore
              })
            })
        }
      }, leading=th().items.mark_line)
      |> ignore
    }
    let first = fn(at : @view.View) {
      // (its words as wide as they are, in the room the row leaves them, cut short where they have not the room: the
      // host's row's, its words' box growing, the words in it their own width)
      at.box(fn(w) {
        w.row(Is(true)).lines_up(Is(Some(Middle))).grow(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
        words_node(w, label, fn() { th().items.name.then(sheet_row_words).then(@ui.text_style(color=Data(ink()))) })
        .shrink(Is(1.0))
        .min_width(Is(Some(0.0)))
        |> ignore
      })
      |> ignore
      // (what it is at now, a word or two, at its end)
      if value != "" {
        words_node(at, fn() { value }, fn() { pick_value }) |> ignore
      }
      at.show(on, at_once=true, fn(k) {
        k.lines_up(Is(Some(Middle))) |> ignore
        icon_node(k, "check", sheet_row_check, By(fn() { th().p.accent })) |> ignore
      })
      // (one that asks more first: its chevron at its end, after its check)
      at.show(further, at_once=true, fn(k) {
        k.lines_up(Is(Some(Middle))) |> ignore
        icon_node(k, "chevron-right", panel_end_icon, By(fn() { th().p.subtle })) |> ignore
      })
    }
    if note == "" {
      if leads {
        lead(r)
      }
      first(r)
    } else {
      // (what it is under its words, as far in as they are; what leads it in its first line's row, that line as tall as
      // the taller of the two: lead_by_first_line)
      r.box(fn(lines) {
        lines.grow(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
        lines.box(fn(l) {
          l.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(sheet_row_gap)) |> ignore
          if leads {
            lead(l)
          }
          first(l)
        })
        |> ignore
        // (in past what leads it and the gap after it: lead_in)
        lines.box(fn(under) {
          under.padding(Is((if leads { th().items.mark + sheet_row_gap } else { 0.0 }, 0.0, 0.0, 0.0))) |> ignore
          words_node(under, fn() { note }, fn() { sheet_row_note }) |> ignore
        })
        |> ignore
      })
      |> ignore
    }
  })
  |> ignore
}
