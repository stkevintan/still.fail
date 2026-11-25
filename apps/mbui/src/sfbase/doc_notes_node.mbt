// The notes kept on a document in the viewer, listed: at the stage's side where it is wide enough (a column of cards
// beside the pages, as a word processor's comments stand), else behind a count at its foot that opens them in a sheet
// (a panel: a sheet from the foot on a phone), so the pages keep their width to read. What a note is of, where it is
// and how it is opened, taken off or sent are the document's (DocNotes): this knows nothing of a PDF's pages, so
// another kind of document kept in the viewer lists its notes the same way.

///|
/// One note as it is listed: where it is (`place`: a page), what it is of (`excerpt`: the words picked, or what an
/// area is), what was said of it ("" nothing yet).
#derive(Eq)
pub(all) struct DocNote {
  id : String
  place : String
  excerpt : String
  comment : String
}

///|
/// A document's notes and what can be done with them: `notes` and `current` are read as signals (the note being
/// written or opened, "" none); `field` is what the current one is written in, `done` keeps what it says; `open` brings
/// a note into sight and opens it to be written; `remove` takes it off; `send` puts all of them into the chat's draft;
/// `clear` takes all of them off.
pub(all) struct DocNotes {
  notes : () -> Array[DocNote]
  current : () -> String
  field : @ui.Field
  done : () -> Unit
  open : (String) -> Unit
  remove : (String) -> Unit
  send : () -> Unit
  clear : () -> Unit
}

///|
/// How wide the column of notes is at the stage's side.
pub let doc_notes_side_w : Double = 300.0

///|
/// How wide the stage is at least for the notes to stand at its side, the pages narrowed for them.
pub let doc_notes_side_least : Double = 900.0

///|
/// The room the column takes from the pages: its width and the gaps round it.
pub let doc_notes_side_room : Double = 324.0

///|
/// Whether the notes stand at the side of a stage `width` wide: there are some and there is room.
pub fn doc_notes_side(width : Double, count : Int) -> Bool {
  count > 0 && width >= doc_notes_side_least
}

///|
/// The notes as rows in `v`: where each is, what it is of (two lines at most) and what was said of it; a press on
/// one opens it (`opened` first, a sheet closing), its bin takes it off. The one open stands out.
pub fn doc_notes_list_node(v : @view.View, of : DocNotes, opened : () -> Unit) -> Unit {
  v.gap(Is(6.0)) |> ignore
  v.each(of.notes, fn(n) { n.id }, fn(row, n) {
    row.row(Is(true)).lines_up(Is(Some(Start))).gap(Is(2.0)) |> ignore
    @sf.action_box_node(
      row,
      fn() { n.get().place + " " + n.get().excerpt },
      fn(_) {
        // (the sheet let go of first: going, it gives the focus back to what opened it, unless the note has it)
        opened()
        (of.open)(n.get().id)
      },
      fn(b) {
        b
        .grow(Is(1.0))
        .basis(Is(Some(0.0)))
        .shrink(Is(1.0))
        .radius(Is(@sf.row_corner))
        .padding(Is((10.0, 8.0, 6.0, 8.0)))
        .gap(Is(4.0))
        // (dark: fainter, or its muted words fall under 4.5:1 on it: 4.34:1 at 0.22)
        .ground(By(fn() {
          if (of.current)() == n.get().id {
            @sf.alpha(0xF5C518FFL, if @sf.theme().dark { 0.16 } else { 0.22 })
          } else {
            0L
          }
        }))
        |> ignore
        @sf.hover_ground_node(b)
        doc_note_line(b, fn() { n.get().place }, 12.0, 600, 1, fn() { @sf.theme().p.muted })
        doc_note_line(b, fn() { n.get().excerpt }, 13.0, 400, 2, fn() { @sf.theme().p.muted })
        doc_note_line(
          b,
          fn() { if n.get().comment == "" { pv("android-chat.pdf.note.empty") } else { n.get().comment } },
          14.0,
          500,
          4,
          fn() { if n.get().comment == "" { @sf.theme().p.muted } else { @sf.theme().p.text } },
        )
      },
    )
    |> ignore
    note_key_node(row, "trash", 16.0, 0L, @sf.theme().p.muted, pv("android-chat.annotate.remove"), fn() {
      (of.remove)(n.get().id)
    })
  },
  at_once=true,
  )
}

///|
/// A line of a note's row: its words `size` big, `weight` heavy, `lines` at most, in `ink`.
fn doc_note_line(b : @view.View, words : () -> String, size : Double, weight : Int, lines : Int, ink : () -> Int64) -> Unit {
  b.box(fn(t) {
    t
    .words(By(words))
    .words_look(Is({
      size,
      weight,
      line: @ui.tree_theme().text_line * size,
      wrap: true,
      tracking: @view.letters_own,
      balance: false,
      max_lines: lines,
    }))
    .ink(By(ink))
    .allow_ellipsis(Is(true))
    |> ignore
  })
  |> ignore
}

///|
/// The notes at the side of `parent` (the stage) while `shown()`: a column `doc_notes_side_w` wide, `top()` under the
/// stage's top and clear of its foot by `foot()`; its head says how many, its rows scroll, its foot clears or sends
/// them all.
pub fn doc_notes_side_node(parent : @view.View, of : DocNotes, shown : () -> Bool, top : () -> Double, foot : () -> Double) -> Unit {
  parent.show(shown, fn(l) {
    l.over(Is(true)).row(Is(true)).padding(By(fn() { (0.0, top(), 12.0, foot()) })) |> ignore
    l.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
    l.box(fn(p) {
      p
      .width(Is(Some(doc_notes_side_w)))
      .padding(Is((8.0, 12.0, 8.0, 10.0)))
      .gap(Is(8.0))
      |> ignore
      @sf.panel_surface_decorate(p, radius=14.0, solid=fn() { @sf.panel_ground() }, clips=false) |> ignore
      @sf.floating_host_lend(p)
      doc_note_line(p, fn() { pv_fill("android-chat.pdf.notes.count", [("n", "\{(of.notes)().length()}")]) }, 15.0, 600, 1, fn() {
        @sf.theme().p.text
      })
      let ring_inset = fn() {
        let t = @ui.tree_theme()
        t.focus_gap + t.focus_w
      }
      p.box(fn(s) {
        s
        .grow(Is(1.0))
        .basis(Is(Some(0.0)))
        .min_height(Is(Some(0.0)))
        .margin(By(fn() {
          let o = ring_inset()
          (-o, -o, -o, -o)
        }))
        |> ignore
        s.scrolls(@view.Scroll::new(), fn(c) {
          c.padding(By(fn() {
            let o = ring_inset()
            (o, o, o, o)
          }))
          |> ignore
          doc_notes_list_node(c, of, fn() {  })
        })
        |> ignore
      })
      |> ignore
      doc_notes_foot_keys(p, of, fn() {  })
    })
    |> ignore
  })
}

///|
/// 全部清除 and 发送 N 条标注 in a row in `v`, each then `after()` (a sheet closing).
fn doc_notes_foot_keys(v : @view.View, of : DocNotes, after : () -> Unit) -> Unit {
  v.box(fn(r) {
    r.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(8.0)) |> ignore
    @sf.button_node(r, fn() { pv("android-chat.pdf.marks.clear") }, fn() {
      (of.clear)()
      after()
    })
    |> ignore
    r.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
    @sf.button_node(
      r,
      fn() { pv_fill("android-chat.pdf.marks.send", [("n", "\{(of.notes)().length()}")]) },
      fn() {
        (of.send)()
        after()
      },
      tone=Primary,
    )
    |> ignore
  })
  |> ignore
}

///|
/// The notes in a panel of their own (a sheet from the foot on a phone): their rows, and at its foot 全部清除 and 发送;
/// a press on a row opens that note on the page, the panel closed.
pub fn doc_notes_sheet(of : DocNotes) -> Unit {
  @sf.panel_nodes(
    pv("android-chat.pdf.notes.title"),
    fn(v, close) { doc_notes_list_node(v, of, close) },
    from=Unanchored,
    foot=fn(v, close) { doc_notes_foot_keys(v, of, close) },
  )
}

///|
/// The note card's corner: its round keys' (18) and the 6 round them.
let doc_note_corner : Double = 24.0

///|
/// How wide the card a note is written in is.
let doc_note_w : Double = 320.0

///|
/// The notes at the foot of `parent` (the stage), as the pick bar over words is (the same glass, the same buttons):
/// how many (pressed, them in a sheet: doc_notes_sheet) and 发送; while one is written, its card there in their place,
/// as a picture's note is written at its viewer's foot (note_box_node), never over the words round it. While `side()`,
/// the notes stand at the stage's side (doc_notes_side_node) and only the card is here. None while there are none.
pub fn doc_notes_foot_node(parent : @view.View, of : DocNotes, side : () -> Bool, hidden? : () -> Bool = fn() { false }) -> Unit {
  let count = fn() { (of.notes)().length() }
  // (`hidden`: what else stands at the stage's foot now (a reader's phone bars), the notes' bar away for it)
  parent.show(fn() { count() > 0 && !hidden() }, fn(l) {
    // (nothing of its own to press but its keys: what is under it keeps the rest)
    l.over(Is(true)).lines_up(Is(Some(Middle))) |> ignore
    l.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
    l.box(fn(r) {
      r.padding(Is((12.0, 0.0, 12.0, 16.0))).lines_up(Is(Some(Middle))) |> ignore
      r.pick(
        fn() {
          // (the note being written; else, where the notes stand at the side, nothing more here ("-side"); else the
          // bar, with as many notes as it says ("-bar"))
          if (of.current)() != "" {
            ((of.current)(), 0)
          } else if side() {
            ("-side", 0)
          } else {
            ("-bar", count())
          }
        },
        fn(holds, now) {
          if now.0 == "-bar" {
            // (N 条标注 opens them in a sheet, to read, open, take off; 发送 puts them all in the draft)
            @sf.pick_bar_node(holds, [
              {
                label: pv_fill("android-chat.pdf.notes.count", [("n", "\{now.1}")]),
                icon: "list",
                mark: false,
                press: fn() { doc_notes_sheet(of) },
              },
              { label: pv("android-chat.pdf.notes.send"), icon: "send", mark: false, press: fn() { (of.send)() } },
            ])
            |> ignore
          } else if now.0 != "-side" {
            doc_note_card_node(holds, of)
          }
        },
      )
    })
    |> ignore
  })
}

///|
/// The note being written, at the stage's foot: as wide as there is room for, `doc_note_w` at most, in the pick bar's
/// glass and ink; what it is of on a line over 删除批注, the field and 完成 in a row.
fn doc_note_card_node(holds : @view.View, of : DocNotes) -> Unit {
  holds.box(fn(card) {
    @sf.glass_capsule_node(card, radius=Some(doc_note_corner), sharing=false, solid=fn() { @sf.panel_ground() })
    .max_width(Is(Some(doc_note_w)))
    .width(Is(Some(doc_note_w)))
    .shrink(Is(1.0))
    .padding(Is((6.0, 10.0, 6.0, 6.0)))
    .gap(Is(2.0))
    |> ignore
    // (what it is said of, a line, over the field)
    card.box(fn(t) {
      t.padding(Is((10.0, 0.0, 10.0, 0.0))) |> ignore
      doc_note_line(t, fn() {
        let id = (of.current)()
        match (of.notes)().search_by(fn(n) { n.id == id }) {
          Some(k) => {
            let n = (of.notes)()[k]
            n.place + " · " + n.excerpt
          }
          None => ""
        }
      }, 12.0, 400, 1, fn() { @sf.theme().p.muted })
    })
    |> ignore
    card.box(fn(row) {
      row.row(Is(true)).lines_up(Is(Some(End))).gap(Is(4.0)) |> ignore
      note_key_node(row, "trash", 17.0, 0L, @sf.theme().p.muted, pv("android-chat.annotate.remove"), fn() {
        (of.remove)(@signals.untracked(of.current))
      })
      row.box(fn(f) {
        f
        .grow(Is(1.0))
        .basis(Is(Some(0.0)))
        .shrink(Is(1.0))
        .padding(Is((8.0, 7.0, 8.0, 7.0)))
        .min_height(Is(Some(36.0)))
        .row(Is(true))
        .lines_up(Is(Some(Middle)))
        |> ignore
        @ui.field(
          f,
          of.field,
          placeholder=pv("android-chat.annotate.write"),
          font_size=16.0,
          line=21.0,
          max_lines=6,
          color=@sf.theme().p.text,
          placeholder_color=@sf.theme().p.muted,
          caret_color=@sf.theme().p.accent,
          enter_sends=false,
        )
        .grow(Is(1.0))
        |> ignore
      })
      |> ignore
      note_key_node(row, "check", 18.0, @sf.theme().p.text, @sf.theme().p.bg, pv("android-chat.annotate.done"), fn() {
        (of.done)()
      })
    })
    |> ignore
  })
  |> ignore
}
