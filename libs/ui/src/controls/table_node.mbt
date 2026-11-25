// A Markdown table as nodes of the window's tree (Md::table's, narrow: as a message's table is drawn): its columns as
// wide as table_widths shares the room it is laid out in, its head and its rows each a row of cells (the head's words
// muted, smaller, medium; the rest the words' own), ruled between them; wider than its room, it scrolls across
// (Scroll::across), `bleed` past its room either side, its bar under the room alone. Its table as the core read the
// Markdown (blocks_of: core_blocks), each cell's words in pieces as the message's (runs_of: bold, muted emphasis, code, struck
// through, links pressed where they lead: runs_links). As what it is told changes, each cell's words told anew, nothing
// made again but cells and rows come or gone. Its picture (the copy key's) its own frame's, made as nodes
// apart and taken whole (take_picture).

///|
/// The core's answers about each text read as Markdown, by the text, as they come: every reader of the same text
/// follows the one cell (md_answer), whichever asked (a tree's reader, md_ask, or an old view's markdown); what asked
/// it gone or not. Each kept while something of the window's tree reads its text (md_readers) or its answer is kept
/// (parsed): let go as both are gone, never kept for each text there ever was.
// kept across runs: put back as a run begins (on_reset)
let md_answered : Map[String, @signals.Signal[Int]] = Map([])

///|
/// How many of the window's tree's readers read each text now (table_node's, as made and as they say another).
// kept across runs: put back as a run begins (on_reset)
let md_readers : Map[String, Int] = Map([])

///|
/// The core's reading of each text something of the window's tree reads now (md_readers), held by them while they do,
/// whatever the texts read lately (blocks_of's, which others push out): from its answer, or as it was kept as the
/// first of them came; let go as the last goes.
// kept across runs: put back as a run begins (on_reset)
let md_held : Map[String, Array[MdBlock]] = Map([])

///|
fn init {
  @ui.on_reset(fn() {
    md_answered.clear()
    md_readers.clear()
    md_held.clear()
  })
}

///|
/// The cell told as the core answers about `text` (made as it is first asked for: no answer yet).
fn md_answer(text : String) -> @signals.Signal[Int] {
  match md_answered.get(text) {
    Some(c) => c
    None => {
      let c = @signals.signal(0)
      md_answered[text] = c
      c
    }
  }
}

///|
/// The core's answer about `text` (`value`, its tree: words alone where it says none) kept (blocks_of) and told to all
/// that read it (md_answer): what both an old view's markdown and a tree's reader do as it comes.
fn md_answered_now(text : String, value : Json?) -> Unit {
  let ready = match value {
    Some(Array(_)) => value
    _ => Some(Json::array([["p", [Json::string(text)]]]))
  }
  let blocks = blocks_of(text, ready)
  // (held by what reads it now, as long as it does: md_held)
  if md_readers.contains(text) {
    md_held[text] = blocks
  }
  match md_answered.get(text) {
    Some(c) => c.set(c.untracked() + 1)
    None => ()
  }
}

///|
/// `text`'s answer let go of as its kept reading is (blocks_of's budget): its cell gone where nothing reads it now.
fn md_forgotten(text : String) -> Unit {
  if md_readers.get(text).unwrap_or(0) == 0 {
    md_answered.remove(text)
  }
}

///|
/// A reader of the window's tree come to `text`, or gone from it (`by` 1 or -1): its cell let go as the last goes,
/// where its reading is not kept.
fn md_read_by(text : String, by : Int) -> Unit {
  if text == "" {
    return
  }
  let n = md_readers.get(text).unwrap_or(0) + by
  if n > 0 {
    md_readers[text] = n
    // (the first: what the core read of it already, held from now)
    if !md_held.contains(text) && core_parsed.contains(text) && parsed.get(text) is Some(b) {
      md_held[text] = b
    }
  } else {
    md_readers.remove(text)
    md_held.remove(text)
    if !parsed.contains(text) {
      md_answered.remove(text)
    }
  }
}

///|
/// The core asked to read `text` as Markdown (as @sf.markdown asks it), once for all its readers: its answer told to
/// them all (md_answered_now), at once if it answers at once. Nothing asked where it was read or asked already (by an
/// old view's markdown too), where those reading it hold its answer, or there is no core. At a cause (a reader made or told another text), never as it is read.
fn md_ask(text : String) -> Unit {
  // (none either where its readers hold its answer, pushed out of what was read lately or not: md_held)
  if text == "" || core_parsed.contains(text) || markdown_asked.contains(text) || md_held.contains(text) {
    return
  }
  match markdown_read.val {
    Some(f) => {
      markdown_asked[text] = true
      f(text, fn(value) { md_answered_now(text, value) })
    }
    None => ()
  }
}

///|
/// The table `text` says (its Markdown, a table alone) as the core read it, followed (md_answer: as its answer comes);
/// `tree`, as told where that says one (a made-up one's: nothing asked). None till it is read, or with no table.
fn table_of(text : String, tree : Json?) -> MdTable? {
  if text == "" {
    return None
  }
  let blocks = match tree {
    Some(_) => blocks_of(text, tree)
    None => {
      md_answer(text).get() |> ignore
      // (what its readers hold, whatever the texts read lately pushed out; else as kept or read now)
      match md_held.get(text) {
        Some(b) => b
        None => blocks_of(text, None)
      }
    }
  }
  for b in blocks {
    match b {
      Table(t) => return Some(t)
      _ => ()
    }
  }
  None
}

///|
/// A cell's words as pieces the tree draws (View::words_runs: each its own way, as a message's: runs_of, a chat's
/// mention in the accent's ink), its links among them.
fn table_cell_runs(cell : Array[MdInline], head : Bool) -> Array[@ui.Run] {
  let runs = []
  let ink = if head { web().muted } else { theme().p.text }
  runs_of(cell, runs, false, false, false, "", theme().p.accent_text, emph_ink_for(ink), {}, false)
  runs
}

///|
/// How a table's cell's pieces are set where a piece says nothing of it itself, as Md::words sets a message's
/// paragraph: links in the theme's blue, code in its code ink on no ground of its own at 0.9 of the words' size, the
/// words a person's.
fn table_runs_look(
  code_scale? : Double = 1.0,
  cjk? : @view.CjkOverride? = None,
  code_cjk? : @view.CjkOverride? = None,
) -> @view.RunsLook {
  let p = theme().p
  { link: p.blue, pressed: alpha(p.blue, 0.14), code_ink: p.code_ink, code_ground: 0L, code_scale: 0.9 * code_scale, words: true, cjk, code_cjk }
}

///|
/// The table `text` says (the core's reading of it: table_of; `tree`, its reading as told where that says one: a
/// made-up one's, nothing asked of the core), in `parent`: as Md::table draws it narrow, `bleed` past its room either
/// side where it scrolls across. Its columns' widths from the room it is given as it is laid out (View::by_room), at
/// the system's size of words.
#callsite(autofill(loc))
pub fn table_node(
  parent : @view.View,
  text : () -> String,
  bleed? : Double = 0.0,
  tree? : () -> Json? = fn() { None },
  copy? : Bool = true,
  on_link? : (String) -> Unit = fn(_) {  },
  on_link_hold? : ((String, (Double, Double, Double, Double)) -> Unit)? = None,
  loc~ : SourceLoc,
) -> Unit {
  // (read once as its text or its reading changes, what reads it many times over (its columns, each cell) reading that)
  let table_now = @signals.computed(fn(_) { table_of(text(), tree()) })
  let table = fn() { table_now.get() }
  parent.box(made_for=loc, fn(outer) {
    // (its text asked of the core as it is made and as it says another, none where it is told its reading; read by it
    // till it says another or is let go: md_read_by)
    let reading = Ref("")
    outer.reacts(fn() { if tree() is None { text() } else { "" } }, fn(t) {
      md_read_by(t, 1)
      md_read_by(reading.val, -1)
      reading.val = t
      md_ask(t)
    })
    outer.owns(fn() {
      md_read_by(reading.val, -1)
      reading.val = ""
    })
    |> ignore
    md_table_body_node(outer, table, Is(bleed), copy, on_link, on_link_hold)
  })
  |> ignore
}

///|
/// A table (`table`, as it changes) as nodes in `outer` (table_node's, whatever reads its Markdown: a table alone, or
/// one of a message's blocks, markdown_node's): its columns' widths from the room `outer` is given (View::by_room), `bleed()` past
/// it either side where it scrolls across, as it changes (bound: the same nodes, its bar in from its ends as far as it
/// was as it was made); its copy key where `copy`; its links taken by `on_link` (`on_link_hold`); a
/// cell of only the message's images drawn as those (`cell_images`: md_cell_images, Md::cell_images'). `rows`: only
/// those of its rows (from, up to, not; its head's row 0), a piece of it a block of a page's list, its columns' widths
/// those of all of it, scrolled across with the others (`across`: what they scroll beside, Scroll::beside), its copy key
/// with its head's row and its bar under its last row (as it is now: its last as its table grows past it no longer),
/// its columns measured and shared out once for all its pieces (`tracks_kept`: what they keep together, View::tracks).
#callsite(autofill(loc))
fn md_table_body_node(
  outer : @view.View,
  table : () -> MdTable?,
  bleed : @view.Live[Double],
  copy : Bool,
  on_link : (String) -> Unit,
  on_link_hold : ((String, (Double, Double, Double, Double)) -> Unit)?,
  fit? : Bool = false,
  cell_images? : (Array[MdInline]) -> Array[(Double, (@view.View, () -> Double) -> Unit)]?,
  rows? : (Int, Int)? = None,
  rows_by? : () -> (Int, Int)?,
  across? : @view.Scroll = @view.Scroll::across(),
  tracks_kept? : @view.TracksKept,
  cell_runs? : (Array[MdInline], Bool) -> Array[@ui.Run] = table_cell_runs,
  line_share? : () -> Double,
  typography? : (() -> MdTypography)? = None,
  link_cards? : (TipLayer, (LinkOf) -> LinkCard?)? = None,
  on_link_shown? : ((@view.View, Array[(String, String, Int)]) -> Unit)? = None,
  loc~ : SourceLoc,
) -> Unit {
  // (said once, bound as such: no binding run for what never changes (table_node's); a chat's message's by its list's
  // width)
  let bleed_now = fn() {
    match bleed {
      Is(b) => b
      By(f) => f()
    }
  }
  let by_bleed = fn(f : (Double) -> (Double, Double, Double, Double)) -> @view.Live[(Double, Double, Double, Double)] {
    match bleed {
      Is(b) => Is(f(b))
      By(g) => By(fn() { f(g()) })
    }
  }
    let has_head = match rows {
      Some((r, _)) => r == 0
      None => true
    }
    // (its bar under its last row: where it is in pieces, the one its table ends in now, followed as it grows)
    let has_foot = match (rows, rows_by) {
      (Some(_), Some(by)) =>
        Some(fn() {
          let upto = by().map_or(0, fn(r) { r.1 })
          table().map_or(true, fn(t) { upto >= t.rows.length() + 1 })
        })
      (Some((_, upto)), None) => Some(fn() { table().map_or(true, fn(t) { upto >= t.rows.length() + 1 }) })
      (None, _) => None
    }
    // (table id shared across all 4-row slices of the same table: taken from the parent `across` before `beside()`)
    let table_id = across.serial()
    let across = match rows {
      Some(_) => across.beside()
      None => across
    }
    outer.margin(by_bleed(fn(b) { (-b, 0.0, -b, 0.0) })) |> ignore
    // (its columns by the room it is given, laid out in that same layout)
    outer.by_room(fn(outer, given) {
      let room = fn() { given.width() - 2.0 * bleed_now() }
      // (each cell as it is drawn: its pieces at its look, or its images' row at their width; the head's row first)
      let cells_of = fn(t : MdTable) -> Array[Array[@view.TrackCell]] {
        let rows = [t.head]
        rows.append(t.rows)
        rows.mapi(fn(r, row) {
          row.map(fn(cell) -> @view.TrackCell {
            match cell_images.bind(fn(f) { f(cell) }) {
              // (a cell of images as wide as their row: Md::table's)
              Some(images) => Wide(cell_images_node_width(images))
              None => {
                let ty = match typography {
                  Some(f) => f()
                  None => md_typography_default
                }
                Said(
                  cell_runs(cell, r == 0),
                  table_words_look_line(
                    r == 0,
                    ty.prose_scale,
                    match line_share {
                      Some(f) => f()
                      None => 0.0
                    },
                    line_scale=ty.line_scale,
                  ),
                  table_runs_look(
                    code_scale=ty.code_scale,
                    cjk=ty.text_cjk,
                    code_cjk=ty.code_cjk,
                  ),
                )
              }
            }
          })
        })
      }
      // (its cells measured as the tree measures what they draw, once as the table changes; the room shared out among
      // its columns as Md::table shares it, again as the room or they change: View::tracks)
      let tracks = outer.tracks(
        fn() {
          match table() {
            Some(t) => cells_of(t)
            None => []
          }
        },
        room,
        fn(extents, avail) {
          table_widths_worked.val += 1
          table_widths(extents.map(fn(row) { row.map(fn(e) { (e.least, e.whole, e.wide) }) }), avail, fit, fn(x) {
            node_sp(outer, x)
          })
        },
        kept?=tracks_kept,
      )
      let widths = tracks.widths
      let widths_for = fn(t : MdTable) { (tracks.of)(cells_of(t)) }
      // (its head's row's height, as it comes to in its room: where its copy key's middle is)
      let head_h : Ref[@view.View?] = Ref(None)
      // (its own key, whatever its words: two tables of the same each their own menu, copy and picture)
      let scrolled = fn(outer : @view.View) {
        let id = outer.id()
        let key = "sf-table/\{id.at}.\{id.gen}"
        let in_rows = fn(held : @view.View) {
          held.padding(by_bleed(fn(b) { (b, 0.0, b, 0.0) })) |> ignore
          // (it, then its copy key past it, from their tops: table_beside's; the key hung out in `bleed` where that has
          // its whole room, as Md::table has it)
          held.box(fn(beside) {
            beside
            .row(Is(true))
            .lines_up(Is(Some(Start)))
            // (pointed at as a whole, its key with it: what shows its key; taking no press nor hold for it)
            .points(Is(copy))
            // (every piece of a table in pieces as wide as the first, whose key the others have not: scrolled across as
            // one, each goes as far, its rows' cells under the head's whichever is moved)
            .margin(by_bleed(fn(b) {
              let hung = b >= table_key_room
              let end = if !copy {
                0.0
              } else if has_head {
                if hung { -table_key_room } else { 0.0 }
              } else if hung {
                0.0
              } else {
                table_key_room
              }
              (0.0, 0.0, end, 0.0)
            }))
            |> ignore
            table_frame_node(
              beside,
              table,
              widths,
              table_id~,
              head_h~,
              on_link~,
              on_link_hold~,
              cell_images?,
              rows~,
              rows_by?,
              cell_runs~,
              line_share?,
              typography~,
              link_cards~,
              on_link_shown~,
            )
            if copy && has_head {
              table_key_node(beside, key, fn() { table() }, fn() {
                match head_h.val {
                  Some(h) => given.tall(h)
                  None => 0.0
                }
              }, widths_for)
            }
          })
          |> ignore
        }
        // (its bar under its last row alone, where it is in pieces: drawn, and its room kept, only there)
        outer.scrolls(
          across,
          slop=@ui.touch_slop(),
          bar=@ui.tree_scroll_bar(),
          bar_in=@signals.untracked(bleed_now),
          bar_here?=has_foot,
          in_rows,
        )
        |> ignore
      }
      // (as wide as its columns, scrolled across where wider than its room: every table but a chat's shared picture's,
      // nothing to choose between)
      if !fit {
        scrolled(outer)
        return
      }
      // (shown whole in the column (`fit`, a chat's shared picture): its every part as much smaller as makes it as wide
      // as the room where it fits not, as it is where it does, nothing of it to scroll to either way: Md::table's. One
      // node whatever the room, bound to it, never a structure switched by it; no copy key: a picture offers none
      // (message_agent_node's `copy` none where it is `fit`))
      let scale = fn() {
        let total = widths().1
        let avail = room()
        if total > avail && avail > 0.0 {
          avail / total
        } else {
          1.0
        }
      }
      outer.box(made_for=loc, fn(whole) {
        // (cut to its room where it fits, as what scrolls across is (Md::table's sideways), not where it is made smaller
        // to fit it (its box as wide as the room): the same picture as either)
        whole.padding(by_bleed(fn(b) { (b, 0.0, b, 0.0) })).clips(By(fn() { scale() >= 1.0 })) |> ignore
        table_frame_node(
          whole,
          table,
          fn() {
            let (ws, total) = widths()
            let k = scale()
            (ws.map(fn(w) { w * k }), total * k)
          },
          table_id~,
          scale=Some(scale),
          on_link~,
          on_link_hold~,
          cell_images?,
          rows~,
          rows_by?,
          cell_runs~,
          line_share?,
          typography~,
          link_cards~,
          on_link_shown~,
        )
      })
      |> ignore
    })
    |> ignore
}

///|
/// How a table's cell's words are set (its head's, muted, smaller and medium; the rest the words' own), at `scale` of
/// their size: what it is drawn and measured at (table_frame_node, md_table_body_node's tracks).
fn table_words_look(head : Bool, scale : Double) -> @view.WordsLook {
  let size = (if head { 12.0 } else { 13.0 }) * scale
  {
    size,
    weight: if head { 500 } else { 400 },
    line: (Float::from_double(size) * (1.65 : Float)).to_double(),
    wrap: true,
    tracking: @view.letters_own,
    balance: false,
    max_lines: 0,
  }
}

///|
/// How a table's cell's words are set (table_words_look), on lines `line_share` of their size where that is said (more
/// than 0: a message's, as its words are, Md::words' `line_em`).
fn table_words_look_line(
  head : Bool,
  scale : Double,
  line_share : Double,
  line_scale? : Double = 1.0,
) -> @view.WordsLook {
  let look = table_words_look(head, scale)
  if line_share > 0.0 {
    { ..look, line: -(line_share * line_scale) }
  } else if line_scale != 1.0 {
    { ..look, line: look.line * line_scale }
  } else {
    look
  }
}

///|
/// How many times a table's room was shared out among its columns (md_table_body_node's tracks' `share`): what its tests
/// count.
// kept across runs: it goes on counting
let table_widths_worked : Ref[Int] = Ref(0)

///|
/// A table's frame as nodes in `beside` (md_table_body_node's, and its picture's: table_key_node): its head's row and
/// its rows (`table`, as it changes), each a row of cells its columns `widths` wide, ruled between them; its head's row
/// told `head_h` as it is made, its links taken by `on_link` (`on_link_hold`); a cell of only the message's images
/// those images in a row (`cell_images`, md_table_body_node's).
#callsite(autofill(loc))
fn table_frame_node(
  beside : @view.View,
  table : () -> MdTable?,
  widths : () -> (Array[Double], Double),
  table_id? : Int = 0,
  head_h? : Ref[@view.View?] = Ref(None),
  on_link? : (String) -> Unit = fn(_) {  },
  on_link_hold? : ((String, (Double, Double, Double, Double)) -> Unit)? = None,
  scale? : (() -> Double)? = None,
  cell_images? : (Array[MdInline]) -> Array[(Double, (@view.View, () -> Double) -> Unit)]?,
  rows? : (Int, Int)? = None,
  rows_by? : () -> (Int, Int)?,
  cell_runs? : (Array[MdInline], Bool) -> Array[@ui.Run] = table_cell_runs,
  line_share? : () -> Double,
  typography? : (() -> MdTypography)? = None,
  link_cards? : (TipLayer, (LinkOf) -> LinkCard?)? = None,
  on_link_shown? : ((@view.View, Array[(String, String, Int)]) -> Unit)? = None,
  loc~ : SourceLoc,
) -> Unit {
  let some = rows
  // (as it is drawn, all of it at 1 where it is said no scale (every table but one shown whole smaller): each cell's
  // look and each rule's height said once, not bound)
  let scale_by = scale
  let scale = fn() {
    match scale_by {
      Some(f) => f()
      None => 1.0
    }
  }
  // (read out as a table (@headless.table): its rows, its head's cells naming its columns, its cells, each the node
  // it is drawn by and no node more)
  @headless.table(beside, made_for=loc, fn(frame, tb) {
    frame.width(By(fn() { Some(widths().1) })) |> ignore
    // (all its rows, its head's 0: how many, the last ruled under by none)
    let all = fn() { table().map_or(0, fn(t) { t.rows.length() + 1 }) }
    let rows = fn() {
      let n = all()
      // (those its piece draws as it is now, where it is told so: additional rows added in place go into later slices)
      let some = match rows_by {
        Some(f) => f()
        None => some
      }
      match some {
        Some((from, upto)) => {
          let upto = if upto < n { upto } else { n }
          Array::makei(if upto > from { upto - from } else { 0 }, fn(i) { from + i })
        }
        None => Array::makei(n, fn(i) { i })
      }
    }
    frame.each(rows, fn(r) { r }, fn(line, r) {
      let r = r.untracked()
      let head = r == 0
      tb.row(line, fn(cells, tr) {
        // (its head's row: where its copy key's middle is, as the frame measured it)
        if head {
          head_h.val = Some(cells)
        }
        cells.row(Is(true)).lines_up(Is(None)) |> ignore
        let cols = fn() { Array::makei(widths().0.length(), fn(k) { k }) }
        cells.each(cols, fn(k) { k }, fn(cell, k) {
          let k = k.untracked()
          // (its head's a column's name, the rest its cells: the node the row made it)
          let said = fn(cell : @view.View, look : (@view.View) -> Unit) {
            if head {
              tr.header(cell, in_node=true, look)
            } else {
              tr.cell(cell, in_node=true, look)
            }
          }
          said(cell, fn(cell) {
            @ui.words_hit_box(cell)
            @ui.words_shaped(cell, fn() { @ui.WordsShape::Cell(table_id, r, k, head) }) |> ignore
            let words = fn() {
              match table() {
                Some(t) => (if head { t.head } else { t.rows.get(r - 1).unwrap_or([]) }).get(k).unwrap_or([])
                None => []
              }
            }
            // (its width and its sides, one binding for both)
            cell
            .sets_together(fn() {
              let ws = widths().0
              (ws.get(k), table_cell_pad(k, ws.length()), scale())
            }, fn(s) {
              let (w, (pl, pr), k) = s
              cell.width(Is(w)).padding(Is((pl * k, table_cell_y * k, pr * k, table_cell_y * k))) |> ignore
            })
            .lies_along(Is(Middle))
            |> ignore
            // its words (as a message's, in pieces, a press on a link where it leads, made as it first has one:
            // words_links_node)
            let words_box = fn(cell : @view.View) {
              // (its pieces worked out once as its words change, what draws them and what presses their links reading that)
              let runs_now = @signals.computed(fn(_) { cell_runs(words(), head) })
              let runs = fn() { runs_now.get() }
              let look = fn() {
                let ty = match typography {
                  Some(f) => f()
                  None => md_typography_default
                }
                table_words_look_line(
                  head,
                  scale() * ty.prose_scale,
                  match line_share {
                    Some(f) => f()
                    None => 0.0
                  },
                  line_scale=ty.line_scale,
                )
              }
              let runs_look_now = fn() {
                let ty = match typography {
                  Some(f) => f()
                  None => md_typography_default
                }
                table_runs_look(code_scale=ty.code_scale, cjk=ty.text_cjk, code_cjk=ty.code_cjk)
              }
              let w = cell.box(fn(w) {
                // (its pieces first: saying them says the words' look and ink plain, what follows says them)
                w.words_runs(By(runs)) |> ignore
                // (its look said once where it is drawn at 1 on lines of its own; how its pieces are set and in what
                // ink, all from the theme: one binding for both; on the message's lines as they change, one binding for
                // the three, as a message's words have them: md_words_node)
                if line_share is Some(_) {
                  w.sets_together(fn() { (look(), runs_look_now(), if head { web().muted } else { theme().p.text }) }, fn(s) {
                    w.words_look(Is(s.0)).runs_look(Is(s.1)).ink(Is(s.2)) |> ignore
                  })
                  |> ignore
                } else {
                  if scale_by is None && typography is None {
                    w.words_look(Is(look())) |> ignore
                  } else {
                    w.words_look(By(look)) |> ignore
                  }
                  w.sets_together(fn() { (runs_look_now(), if head { web().muted } else { theme().p.text }) }, fn(s) {
                    w.runs_look(Is(s.0)).ink(Is(s.1)) |> ignore
                  })
                  |> ignore
                }
              })
              // (its links pressed and their cards, told as they are shown, as a message's words: md_words_node)
              let told = on_link_shown is Some(_) || link_cards is Some(_)
              words_links_node(cell, w, runs, on_link, hold=on_link_hold, cards=link_cards, shown=if told {
                Some(fn(now) {
                  match on_link_shown {
                    Some(f) => f(w, now)
                    None => ()
                  }
                })
              } else {
                None
              })
            }
            // its images in a row where it is only the message's images (CellImageRow: 6 apart, 4 over and under, each
            // cell_image_width wide), else its words, made again only as it comes to hold images or no longer does; where
            // it is given no images (`cell_images` none: every table but one of a message that places its files), its
            // words alone, nothing made for the choice
            match cell_images {
              None => words_box(cell)
              Some(of_cell) => {
                let images = fn() { of_cell(words()) }
                // (made again only as it comes to hold images or no longer does; its images each a row of the row's
                // own, by their place, made and let go as their number changes)
                cell.pick(at_once=true, fn() { images().map_or(0, fn(ims) { ims.length() }) > 0 }, fn(cell, held) {
                  if held {
                    cell.box(fn(row) {
                      row.row(Is(true)).gap(By(fn() { 6.0 * scale() })).padding(By(fn() { (0.0, 4.0 * scale(), 0.0, 4.0 * scale()) })) |> ignore
                      row.each(
                        fn() { Array::makei(images().map_or(0, fn(ims) { ims.length() }), fn(i) { i }) },
                        fn(i) { i },
                        at_once=true,
                        fn(im, i) {
                          let i = i.untracked()
                          let width = fn() {
                            cell_image_width(images().bind(fn(ims) { ims.get(i) }).map_or(1.0, fn(x) { x.0 })) * scale()
                          }
                          im.width(By(fn() { Some(width()) })) |> ignore
                          match @signals.untracked(fn() { images().bind(fn(ims) { ims.get(i) }) }) {
                            Some((_, draw)) => draw(im, width)
                            None => ()
                          }
                        },
                      )
                    })
                    |> ignore
                    return
                  }
                  words_box(cell)
                })
                |> ignore
              }
            }
          })
          |> ignore
        })
      })
      |> ignore
      // (a rule under each but the last, as faint as is seen: as wide as its row, none under the last (no room, no
      // ink), one binding for all of it and no structure for whether it is)
      line.box(fn(rule) {
        rule
        .fills_across(Is(true))
        .sets_together(fn() { (r < all() - 1, rule_w * scale(), rule_color()) }, fn(s) {
          let (ruled, k, ink) = s
          rule.height(Is(Some(if ruled { k } else { 0.0 }))).ground(Is(if ruled { ink } else { 0L })) |> ignore
        })
        |> ignore
      })
      |> ignore
    })
  })
  |> ignore
}

///|
/// How wide a table's cell of images is (cell_images_width's): their widths and the gaps between them.
fn cell_images_node_width(images : Array[(Double, (@view.View, () -> Double) -> Unit)]) -> Double {
  let mut w = 0.0
  for i, im in images {
    w = w + cell_image_width(im.0) + (if i > 0 { 6.0 } else { 0.0 })
  }
  w
}

///|
/// A table's copy key as nodes (table_key's), in `beside` past the table (it and its key, View::points): its
/// own `key`, table_key_gap past it and before what follows, its middle on its head's row's (`head_h`, as laid out);
/// pressed, its menu (table_copy_button_node). Faded in (nav_fade) as the table or its key is pointed at (`beside`
/// saying it is pointed at alone, View::points; what is over it taking the pointer: not), its menu open or it saying it
/// copied, always to a finger; there while it shows and as it fades out (View::show's `leave`: the same key come back
/// where it shows again before it is gone, its fade turned back where it had it); its room kept either way, as tall as
/// the key, nothing in it to press or read out once it has faded out.
#callsite(autofill(loc))
fn table_key_node(
  beside : @view.View,
  key : String,
  table : () -> MdTable?,
  head_h : () -> Double,
  widths_for : (MdTable) -> (Array[Double], Double),
  loc~ : SourceLoc,
) -> Unit {
  let copied = @signals.signal(false)
  // (what says it copied no more, a moment of the key's)
  let copied_off : Ref[() -> Unit] = Ref(fn() {  })
  let menu_open = @signals.signal(false)
  beside.box(made_for=loc, fn(k) {
    k.transitions_only().owns(fn() { (copied_off.val)() }) |> ignore
    // (its room kept, as tall as the key, whether it shows or not)
    let top = fn() { dmax(0.0, (head_h() - table_key_size) / 2.0) }
    k
    .width(Is(Some(table_key_gap + table_key_size + table_key_gap)))
    .min_height(By(fn() { Some(top() + table_key_size) }))
    .padding(By(fn() { (table_key_gap, top(), table_key_gap, 0.0) }))
    |> ignore
    let shown = fn() { beside.pointed_in() || menu_open.get() || copied.get() || @ui.pointing() is Finger }
    let shown_open = @signals.signal(@signals.untracked(shown), same=fn(a, b) { a == b })
    // (how far it shows: set off as it comes to show or not, turned back from where it has it)
    let seen = @motion.NodeWay::new(0.0)
    k.reacts(shown, fn(on) {
      seen.go_ms(k, if on { 1.0 } else { 0.0 }, dur_ms)
      @view.transition(within=k, fn() { shown_open.set(on) })
    })
    k.alpha(By(fn() { seen.shown(k) })) |> ignore
    // (its block of a list taken for another message's table: copied said of none of it, the moment that would have
    // said so no more, its menu not open on it, and shown as it is for that one at once, no fade of the one before's)
    k.on_reused(fn() {
      (copied_off.val)()
      copied_off.val = fn() {  }
      copied.set(false)
      menu_open.set(false)
      let on = @signals.untracked(shown)
      seen.put(if on { 1.0 } else { 0.0 })
      shown_open.set(on)
    })
    // (the key itself at once: what it is is there as it fades in, all of it, nothing of its place making its way in a
    // room kept as tall as it)
    k.show(fn() { shown_open.get() }, leave=dur_ms, at_once=true, fn(slot) {
      table_copy_button_node(slot, k, key, table, widths_for, copied, copied_off, menu_open)
    })
  })
  |> ignore
}

///|
/// A table's copy key's button (table_key_node's), in `slot`: pressed, its menu (copy it as Markdown, as CSV, as the
/// core wrote them; as a picture: the table whole, its columns `widths_for` it as they are then, its frame as drawn
/// here (table_frame_node) on the page's ground, taken once: take_picture), `menu_open` while it is; once one is
/// copied a check, `copied` for copied_ms (said on the timeline of `keeps`, the key's room: there however long a
/// picture takes to be handed out, the key faded out meanwhile or not; `copied_off` calls it off, the key's own).
fn table_copy_button_node(
  slot : @view.View,
  keeps : @view.View,
  key : String,
  table : () -> MdTable?,
  widths_for : (MdTable) -> (Array[Double], Double),
  copied : @signals.Signal[Bool],
  copied_off : Ref[() -> Unit],
  menu_open : @signals.Signal[Bool],
) -> Unit {
  let button : Ref[@view.View?] = Ref(None)
  let said = fn() {
    // (a check a moment: said again, from then)
    (copied_off.val)()
    copied.set(true)
    copied_off.val = keeps.at_moment(keeps.logic_at() + copied_ms, fn() { copied.set(false) })
  }
  let press = fn() {
    match (table(), button.val) {
      (Some(tb), Some(b)) => {
        menu_open.set(true)
        let closed = fn() { menu_open.set(false) }
        let words = fn(s : String) {
          closed()
          @ui.clipboard_set(s)
          said()
        }
        let items : Array[MenuItem?] = []
        if tb.md != "" {
          items.push(Some(menu_item_of(t("web-main.prose.copyMarkdown"), fn() { words(tb.md) })))
        }
        if tb.csv != "" {
          items.push(Some(menu_item_of(t("web-main.prose.copyCsv"), fn() { words(tb.csv) })))
        }
        let album = picture_to_album()
        items.push(
          Some(
            menu_item_of(picture_out_way().0, fn() {
              closed()
              // (the table as it is as this is chosen, its rows and its columns' widths read together then, whole,
              // past what scrolls)
              // (the table now, or as the menu opened on it where it is not read now: its widths worked out for
              // that one, never another's)
              let (now, (ws, total)) = @signals.untracked(fn() {
                let now = table().unwrap_or(tb)
                (now, widths_for(now))
              })
              @ui.take_picture(
                key + "/picture",
                total + 2.0 * table_shot_in,
                fn(paper) {
                  paper
                  .padding(Is((table_shot_in, table_shot_in, table_shot_in, table_shot_in)))
                  .ground(By(fn() { theme().p.bg }))
                  |> ignore
                  table_frame_node(paper, fn() { Some(now) }, fn() { (ws, total) })
                },
                fn(png) { if (picture_out_now_by.val)(png, !album) && !album { said() } },
                scale=dmax(slot.pixel_scale(), table_shot_scale),
              )
            }),
          ),
        )
        let (x, y, w, h) = b.rect()
        menu(items, from=At(x, y, w, h), along=End, gone=closed)
      }
      _ => ()
    }
  }
  button.val = Some(
    icon_button_node(
      slot,
      "copy",
      fn() { if copied.get() { t("common.copied") } else { t("web-main.prose.copyTable") } },
      press,
      size=table_key_size,
      icon_now=fn() { if copied.get() { "check" } else { "copy" } },
    ),
  )
}
