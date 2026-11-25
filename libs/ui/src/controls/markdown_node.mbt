// Markdown as nodes of the window's tree, made once (the web's `.markdown`): the blocks the
// core read the words in (blocks_of over md_core's tree, asked of the core once for all that read the same words:
// md_ask, md_answered), each as markdown draws it, as far apart as the larger of the margins between each two; each
// paragraph's words in pieces as the core read them (runs_of: bold, muted emphasis, code, struck through, links, a chat's
// mention), its links pressed where they lead. As the words or their reading change, the same nodes told anew; a block
// of another kind made again in its place.

///|
/// Grouped typography scaling & CJK companion overrides for `markdown_node` (paragraphs, headings, code blocks, and
/// tables). `markdown_node`'s `size` parameter is the unscaled base font size; `prose_scale` scales prose, headings,
/// code blocks, and tables uniformly once.
#derive(Eq)
pub(all) struct MdTypography {
  prose_scale : Double
  code_scale : Double
  line_scale : Double
  text_cjk : @view.CjkOverride?
  code_cjk : @view.CjkOverride?
}

///|
// kept across runs: a value (no field of it changes)
pub let md_typography_default : MdTypography = {
  prose_scale: 1.0,
  code_scale: 1.0,
  line_scale: 1.0,
  text_cjk: None,
  code_cjk: None,
}

///|
pub fn MdTypography::default() -> MdTypography {
  md_typography_default
}

///|
/// `text` as Markdown in `parent` (markdown's): `tree`, its reading where it is told one (a message's `md`: nothing
/// asked of the core); `size` its words', as it changes (0: the theme's body), on lines `line` times it high, as it
/// changes (0: Md::lh's); `apart`: a part after another (a reader's block after the one over it), its first block as far
/// below it as after a paragraph, or its own margin where that is more (markdown_part's);
/// `ink` (0: the theme's text); `document`: its headings a document's; `bleed`: how far past its column either side its
/// tables scroll, as it changes (a chat's margin, by the width its list is given: bound, its tables kept); `copy`: its tables offer to be copied; `fit_tables`: each table shown whole in the column, as much
/// smaller as makes it fit, rather than part of it left to scroll to (a chat's shared picture: markdown's); `paths`: the files its paths name are a session's (chips);
/// `found`: words found, in bold; `found_at`, where a find marks them (None: in bold alone): each coloured in, the one it
/// is at (counting them through all its words, -1 none) with a line at its foot (found_marks); `lit`, a passage of
/// its words and the ground it is lit on now, where a paragraph's words have it (passage_marks: a quote's that led
/// here, as it flashes); `on_link` where a link leads, `on_link_hold` a link held; `on_link_shown`, each
/// paragraph's links as they are (its words' node, each link's way, its words and its first run: what shows over one
/// while it is pointed at, @ui.runs_links' `shown`); `link_cards`, the card each link has (drawn in its layer while a
/// mouse rests on that link: link_cards_node); `one_line`: its first block's words alone, on one line as wide as
/// they are, cut with an ellipsis where the column is narrower (markdown's: a notice closed); `one_line_by`: so while it
/// says, and else all of it, those words one node either way (a notice opened and closed: their way); `chat_title`, what a bare
/// link to a chat reads as; `code`, a fenced block of a language drawn another way (what draws it, its code as it
/// changes); `files`, the files it names by their names, drawn where it names them (a paragraph of only a link to one,
/// or its images); `screens`, its links to screens: a paragraph of only one its card, one bare in a sentence its title.
/// `serif`: its words (not its code) in the serif face, as it says now (a reader's layout); `nodes`: its blocks as the core
/// read them told, its nodes of `text` (a reader's block of a book: none asked of the core). `piece_by`: the piece it
/// draws as it is now, where `piece` is one block alone (a page's list's block put by and taken for another message's
/// piece of one block: View::scrolls_window's `reused`), which block it is read through it, the same nodes.
/// The node.
#callsite(autofill(loc))
pub fn markdown_node(
  parent : @view.View,
  text : () -> String,
  tree? : () -> Json? = fn() { None },
  size? : () -> Double = fn() { 0.0 },
  line? : () -> Double = fn() { 0.0 },
  apart? : Bool = false,
  ink? : () -> Int64 = fn() { 0L },
  document? : Bool = false,
  bleed? : () -> Double = fn() { 0.0 },
  copy? : Bool = true,
  fit_tables? : Bool = false,
  paths? : Bool = false,
  found? : () -> Array[String] = fn() { [] },
  found_at? : () -> Int? = fn() { None },
  lit? : () -> (String, Int64) = fn() { ("", 0L) },
  on_link? : (String) -> Unit = fn(_) {  },
  on_link_hold? : ((String, (Double, Double, Double, Double)) -> Unit)? = None,
  on_link_shown? : (@view.View, Array[(String, String, Int)]) -> Unit,
  link_cards? : (TipLayer, (LinkOf) -> LinkCard?),
  one_line? : Bool = false,
  one_line_by? : () -> Bool,
  chat_title? : (String) -> String? = fn(_) { None },
  code? : (String) -> ((@view.View, () -> String) -> Unit)? = fn(_) { None },
  files? : (String) -> PlacedNode?,
  screens? : ScreensNode,
  piece? : MdPiece? = None,
  piece_by? : () -> MdPiece?,
  across_of? : (Int) -> @view.Scroll = fn(_) { @view.Scroll::across() },
  tracks_of? : (Int) -> @view.TracksKept? = fn(_) { None },
  text_face? : () -> Int? = fn() { None },
  code_face? : () -> Int? = fn() { None },
  typography? : () -> MdTypography = fn() { md_typography_default },
  serif? : () -> Bool = fn() { false },
  nodes? : () -> Array[Json],
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(col) {
    // (its words asked of the core as it is made and as they change, none where it is told their reading; read by it
    // till they change or it is let go: md_read_by, as table_node's)
    let reading = Ref("")
    let raw_text = @signals.computed(fn(_) { if tree() is None { text() } else { "" } }, same=fn(a, b) { a == b })
    col.reacts(fn() { raw_text.get() }, fn(now) {
      md_read_by(now, 1)
      md_read_by(reading.val, -1)
      reading.val = now
      md_ask(now)
    })
    col.owns(fn() {
      md_read_by(reading.val, -1)
      reading.val = ""
    })
    |> ignore
    let md : MdNode = {
      size: fn() {
        let now = size()
        let base = if now > 0.0 { now } else { theme().t.body }
        let ps = (typography)().prose_scale
        if ps == 1.0 { base } else { base * ps }
      },
      line,
      apart,
      ink: fn() {
        let i = ink()
        if i != 0L { i } else { theme().p.text }
      },
      document,
      bleed,
      copy,
      fit: fit_tables,
      paths,
      found,
      found_at,
      lit,
      lits: match parent.lent(md_lits) {
        Some(f) => f
        None => fn() { [] }
      },
      before: fn() { 0 },
      on_link,
      on_link_hold,
      on_link_shown,
      link_cards,
      chat_title,
      code,
      files: files.unwrap_or(fn(_) { None }),
      places: files is Some(_),
      screens,
      block_at: -1,
      table_rows: piece.bind(fn(p) { p.rows }),
      rows_by: match (piece.bind(fn(p) { p.rows }), piece_by) {
        (Some(_), Some(by)) => Some(fn() { by().bind(fn(p) { p.rows }) })
        _ => None
      },
      across_of,
      tracks_of,
      text_face,
      code_face,
      typography,
      serif,
    }
    // (where its nodes are told (`nodes`: a reader's block of a book the core read, its own nodes of the whole
    // `text`), its blocks those; else as its words are read)
    let blocks = match nodes {
      Some(given) => @signals.computed(fn(_) { core_blocks(given(), text()) })
      None => @signals.computed(fn(_) { md_node_blocks(text(), tree()) })
    }
    if one_line_by is Some(closed) {
      // (its first block's words one node, on one line cut short while `closed`, broken into lines and the rest of its
      // blocks under them while not: the same words broken anew at another width, never one copy for another, so on a
      // way they are drawn at their size and cut, not drawn smaller and grown back (mbui's grown_cut_of))
      md_words_node(col, md, fn() { first_words(blocks.get()) }, md.size, 0, one_line=closed)
      col.show(fn() { !closed() && blocks.get().length() > 1 }, fn(rest) {
        md_blocks_node(rest, md, fn() { blocks.get() }, false, range=Some((1, 1 << 30)))
      })
    } else if one_line {
      // (its first block's words on one line, cut short: markdown's one_line)
      md_words_node(col, md, fn() { first_words(blocks.get()) }, md.size, 0, wrap=false, cut=true)
    } else {
      let from_by = match (piece, piece_by) {
        (Some(p), Some(by)) => Some(fn() { by().map(fn(n) { n.from }).unwrap_or(p.from) })
        _ => None
      }
      md_blocks_node(col, md, fn() { blocks.get() }, false, range=piece.map(fn(p) { (p.from, p.upto) }), from_by?)
    }
  })
}

///|
/// A piece of what a markdown_node draws (markdown_node's `piece`): its blocks from `from` up to (not) `upto`; where
/// it is some rows of a table or some items of a list (`rows`: from, up to, not; a table's head's row its 0), that
/// table or list alone, `from` its block; `last`,
/// whether it is the last piece.
#derive(Eq, Debug)
pub(all) struct MdPiece {
  from : Int
  upto : Int
  rows : (Int, Int)?
  last : Bool
}

///|
/// How many rows of a table a piece of it holds at most (markdown_pieces'), its head's row one of them.
let md_table_piece_rows : Int = 4

///|
/// How many items of a list a piece of it holds at most (markdown_pieces'): a list of 17 items with links' cards made
/// 241 nodes in the frame it came into view (2026-11-15).
let md_list_piece_items : Int = 3

///|
/// The pieces `text` is drawn in as the core read it (`tree`, a message's `md`) where a list makes it a block a piece
/// (markdown_node's `piece`): a block each, a table md_table_piece_rows of its rows a piece, a list md_list_piece_items
/// of its items a piece (what an item holds, a list in it too, with it). None where it is not read
/// yet, or it is one piece. Of the core's tree, worked out of its shape alone (core_pieces: none of its words read and
/// nothing kept), so a list may ask it of every message it holds, those far out of sight too.
pub fn markdown_pieces(text : String, tree : Json?) -> Array[MdPiece]? {
  guard tree is Some(_) && text != "" else { return None }
  let out : Array[MdPiece] = []
  match tree {
    Some(Array(nodes)) => core_pieces(nodes, Ref(0), out)
    _ => {
      let at = Ref(0)
      for b in blocks_of(text, tree) {
        match b {
          Table(t) => md_pieces_put(out, at, t.rows.length() + 1, md_table_piece_rows)
          List(l) => md_pieces_put(out, at, l.items.length(), md_list_piece_items)
          _ => md_pieces_put(out, at, 1, 1)
        }
      }
    }
  }
  guard out.length() > 1 else { return None }
  let n = out.length()
  out[n - 1] = { ..out[n - 1], last: true }
  Some(out)
}

///|
/// Which of `pieces` (markdown_pieces' of `text` as `tree` reads it) holds what a go-to brings before the eyes: the
/// `passage` a quote quoted, where a paragraph of it has it (find_passage, as passage_marks lights it), else the `at`th
/// time (0 the first; less than 0, found_all among them, the first) `words` are in it as a find counts and marks them
/// (md_found_in's: paragraphs, headings, quotes, lists' items); 0 where none does.
pub fn markdown_piece_with(
  text : String,
  tree : Json?,
  pieces : Array[MdPiece],
  passage? : String = "",
  words? : Array[String] = [],
  at? : Int = -1,
) -> Int {
  let blocks = blocks_of(text, tree)
  if passage != "" {
    for i, pc in pieces {
      for b in pc.from..<pc.upto {
        if blocks.get(b) is Some(block) && md_has_passage(block, passage, pc.rows) {
          return i
        }
      }
    }
    return 0
  }
  guard words.length() > 0 else { return 0 }
  let want = if at < 0 { 0 } else { at }
  let mut n = 0
  for i, pc in pieces {
    for b in pc.from..<pc.upto {
      match blocks.get(b) {
        Some(block) => n = n + md_words_in(block, words, pc.rows)
        None => ()
      }
    }
    if n > want {
      return i
    }
  }
  0
}

///|
/// How many times `words` are in `text` as markdown_node draws it (`tree` its read) and marks them: what a find counts
/// in a message drawn so (md_found_in's of all its blocks).
pub fn markdown_found_count(text : String, tree : Json?, words : Array[String]) -> Int {
  blocks_of(text, tree).fold(init=0, fn(n, b) { n + md_words_in(b, words, None) })
}

///|
/// How many times `words` are in block `b` as md_found_in counts them, of its list's items `rows` alone where it is a
/// piece of one (none: all).
fn md_words_in(b : MdBlock, words : Array[String], rows : (Int, Int)?) -> Int {
  match b {
    Paragraph(xs) | Heading(_, xs) => find_words(md_plain(xs), words).length()
    Quote(bs) => bs.fold(init=0, fn(n, x) { n + md_words_in(x, words, None) })
    List(l) => {
      let mut n = 0
      for i, it in l.items {
        if rows is Some((from, upto)) && (i < from || i >= upto) {
          continue
        }
        n = n + it.blocks.fold(init=0, fn(k, x) { k + md_words_in(x, words, None) })
      }
      n
    }
    _ => 0
  }
}

///|
/// Whether a paragraph of block `b` (of its list's items or its table's rows `rows` alone where it is a piece of one)
/// has `passage` (find_passage's).
fn md_has_passage(b : MdBlock, passage : String, rows : (Int, Int)?) -> Bool {
  let within = fn(i : Int) {
    match rows {
      Some((from, upto)) => i >= from && i < upto
      None => true
    }
  }
  match b {
    Paragraph(xs) | Heading(_, xs) => find_passage(md_plain(xs), passage) is Some(_)
    Quote(bs) => bs.iter().any(fn(x) { md_has_passage(x, passage, None) })
    List(l) => {
      for i, it in l.items {
        if within(i) && it.blocks.iter().any(fn(x) { md_has_passage(x, passage, None) }) {
          return true
        }
      }
      false
    }
    Table(t) => {
      let cells = fn(row : Array[Array[MdInline]]) { row.iter().any(fn(c) { find_passage(md_plain(c), passage) is Some(_) }) }
      if within(0) && cells(t.head) {
        return true
      }
      for i, row in t.rows {
        if within(i + 1) && cells(row) {
          return true
        }
      }
      false
    }
    _ => false
  }
}

///|
/// What every block of a markdown_node is drawn with (Md's, of the window's tree).
priv struct MdNode {
  size : () -> Double
  /// a line as a share of the words' size, as it changes (0: Md::lh's)
  line : () -> Double
  /// a part after another: its first block apart from it (markdown_node's `apart`)
  apart : Bool
  ink : () -> Int64
  document : Bool
  bleed : () -> Double
  copy : Bool
  /// its tables shown whole in the column (markdown_node's `fit_tables`)
  fit : Bool
  paths : Bool
  found : () -> Array[String]
  /// where a find marks what is found (markdown_node's `found_at`), and how many of its matches come before this part
  /// of the words (in their order: what the one it is at is counted by)
  found_at : () -> Int?
  /// a passage lit where a paragraph's words have it, and its ground now (markdown_node's `lit`)
  lit : () -> (String, Int64)
  /// passages kept marked where a paragraph's words have them, each with its ground and where (md_lits: a reader's
  /// notes)
  lits : () -> Array[(String, Int64, String?)]
  before : () -> Int
  on_link : (String) -> Unit
  on_link_hold : ((String, (Double, Double, Double, Double)) -> Unit)?
  on_link_shown : ((@view.View, Array[(String, String, Int)]) -> Unit)?
  link_cards : (TipLayer, (LinkOf) -> LinkCard?)?
  chat_title : (String) -> String?
  code : (String) -> ((@view.View, () -> String) -> Unit)?
  files : (String) -> PlacedNode?
  /// whether it was told its files at all (markdown_node's `files`): where not, none is placed and no cell of a table
  /// is images, so nothing is made to choose between them (md_cell_images)
  places : Bool
  screens : ScreensNode?
  /// which of the blocks it is drawn for (md_blocks_node's: none, -1)
  block_at : Int
  /// the rows of its table or the items of its list it draws where it is a piece of one (markdown_node's `piece`):
  /// none, all of them; none in what a block holds (a list's item, a quote)
  table_rows : (Int, Int)?
  /// those rows or items as they are now, where the piece is told as it changes (markdown_node's `piece_by`: a message's
  /// table updated in place, with later slices growing as rows are added), none: table_rows all along
  rows_by : (() -> (Int, Int)?)?
  /// what the table at a block scrolls across with (markdown_node's `across_of`: the pieces of one table as one)
  across_of : (Int) -> @view.Scroll
  /// what the pieces of the table at a block keep of its columns together (markdown_node's `tracks_of`: measured once
  /// for all of them, View::tracks' `kept`), none: each its own
  tracks_of : (Int) -> @view.TracksKept?
  /// faces tried for prose and code, as they are now (markdown_node's `text_face`, `code_face`; Md's: None the chosen
  /// face, Some(0) the app's face for that kind)
  text_face : () -> Int?
  code_face : () -> Int?
  typography : () -> MdTypography
  /// its words in the serif face (a reader's layout: code stays in the code face), as it is now
  serif : () -> Bool
}

///|
/// A file the message places (Placed's, of the window's tree): `draw` it in a node on a line of its own; an image's
/// width over its height and its drawing in a node as wide as it is given (`image`, the width as a row of them has it
/// now).
pub(all) struct PlacedNode {
  draw : (@view.View) -> Unit
  image : (Double, (@view.View, () -> Double) -> Unit)?
}

///|
/// Links to a station's screens and 共享调试 as a chat draws them (Screens', of the window's tree): `card` in a node, its
/// address, what it is to and its words (none where bare); `title`, what one written bare reads as.
pub(all) struct ScreensNode {
  card : (@view.View, String, LinkTo, String?) -> Unit
  title : (String, LinkTo) -> String
}

///|
/// `text`'s blocks as the core read it (markdown's): as told (`tree`), else as its answer came (md_answer, what its
/// readers hold: md_held), else as kept or read now; while a live core has not read them yet, 正在排版 in the subtle tone.
fn md_node_blocks(text : String, tree : Json?) -> Array[MdBlock] {
  if text == "" {
    return []
  }
  let blocks = match tree {
    Some(_) => blocks_of(text, tree)
    None => {
      md_answer(text).get() |> ignore
      match md_held.get(text) {
        Some(b) => b
        None => blocks_of(text, None)
      }
    }
  }
  if blocks.is_empty() && tree is None && markdown_read.val is Some(_) && !core_parsed.contains(text) {
    [Paragraph([Text(if language() == "en" { "Formatting" } else { "正在排版" })])]
  } else {
    blocks
  }
}

///|
/// Blocks (`blocks`, as they change) in `col`, one under another (stack's): each as far under the one before as the
/// larger of the margins between them (Md::piece's), the first's top and the last's foot the column's own; `tight`: a
/// tight list's item's (its paragraphs keep no margin of their own). Each by its place among them, made again where its
/// kind changes. `range`: only those from its first up to (not) its second, the first as far under the one before it as
/// among all (a piece of a long message, a block of a page's list: the margin between two blocks of it the piece's own,
/// so the pieces one under another are the message as drawn whole). `from_by`, where `range` is one block: which block
/// that is as it is now (markdown_node's `piece_by`).
#callsite(autofill(loc))
fn md_blocks_node(
  col : @view.View,
  md : MdNode,
  blocks : () -> Array[MdBlock],
  tight : Bool,
  range? : (Int, Int)? = None,
  from_by? : () -> Int,
  loc~ : SourceLoc,
) -> Unit {
  // (block `i` (`block`, as it is now) in its box `slot`: as far under the one before as the larger of the margins
  // between them, drawn by its kind, made again where that changes)
  let block_slot = fn(slot : @view.View, block : () -> MdBlock?, i : Int) {
    // (the first, or a table's rows or a list's items after its first piece's: right under those over them, as far as
    // its first row or item keeps itself)
    if i == 0 && md.apart && md.table_rows is None {
      // (a part after another: as far below it as after a paragraph, or its first block's own margin where more)
      let top_pad = @signals.computed(fn(_) {
        match block() {
          Some(b) => dmax(paragraph_after, md_node_margins(md, b, tight).0)
          None => 0.0
        }
      })
      slot.padding(By(fn() { (0.0, top_pad.get(), 0.0, 0.0) })) |> ignore
    } else if i == 0 || (md.table_rows is Some((r, _)) && r > 0) {
      slot.padding(Is((0.0, 0.0, 0.0, 0.0))) |> ignore
    } else {
      let top_pad = @signals.computed(fn(_) {
        let bs = blocks()
        match (bs.get(i - 1), bs.get(i)) {
          (Some(a), Some(b)) => dmax(md_node_margins(md, a, tight).1, md_node_margins(md, b, tight).0)
          // (none there now: no room for it)
          _ => 0.0
        }
      }, same=fn(a, b) { a == b })
      slot.padding(By(fn() { (0.0, top_pad.get(), 0.0, 0.0) })) |> ignore
    }
    // (the matches before it: those before the blocks and in the blocks over it)
    let here = { ..md, before: fn() { (md.before)() + md_found_in(md, blocks(), i) }, block_at: i }
    let kind_sig = @signals.computed(fn(_) { block().map(fn(x) { md_block_kind(md, x) }).unwrap_or(-1) }, same=fn(a, b) { a == b })
    slot.pick(fn() { kind_sig.get() }, fn(p, kind) {
      md_block_node(p, here, kind, block, tight)
    })
  }
  // (a piece of one block, as a long message's pieces each are (markdown_pieces): that block alone in a box of its own,
  // as the one the list below would make it, read through what it is now, so what changes in the others tells it
  // nothing; where the blocks hold it no more, nothing in it and no room kept for it, as the list would have none)
  match (range, from_by) {
    // (which block it is read as it is now: as far under the one before it as among all, its matches before it, and
    // drawn as its kind draws it, as were it made for that block; a table made again for another, its pieces scrolled
    // across as one by the block it is)
    (Some((from, upto)), Some(at)) if upto == from + 1 && md.table_rows is None => {
      let block = @signals.computed(fn(_) { blocks().get(at()) })
      col.box(made_for=loc, fn(slot) {
        let top_pad = @signals.computed(fn(_) {
          let i = at()
          let bs = blocks()
          if i == 0 {
            match bs.get(0) {
              Some(b) if md.apart => dmax(paragraph_after, md_node_margins(md, b, tight).0)
              _ => 0.0
            }
          } else {
            match (bs.get(i - 1), bs.get(i)) {
              (Some(a), Some(b)) => dmax(md_node_margins(md, a, tight).1, md_node_margins(md, b, tight).0)
              _ => 0.0
            }
          }
        }, same=fn(a, b) { a == b })
        slot.padding(By(fn() { (0.0, top_pad.get(), 0.0, 0.0) })) |> ignore
        let kind_sig = @signals.computed(fn(_) { block.get().map(fn(x) { md_block_kind(md, x) }).unwrap_or(-1) }, same=fn(a, b) { a == b })
        // (the same nodes whichever block it is of its kind: what scrolls in it scrolled as that block's message has it,
        // the list's, @view.View::reused_bool's)
        slot.pick(fn() { kind_sig.get() }, fn(p, kind) {
          let here = { ..md, before: fn() { (md.before)() + md_found_in(md, blocks(), at()) }, block_at: @signals.untracked(at) }
          md_block_node(p, here, kind, fn() { block.get() }, tight)
        })
      })
      |> ignore
      return
    }
    (Some((from, upto)), _) if upto == from + 1 => {
      let block = @signals.computed(fn(_) { blocks().get(from) })
      col.box(made_for=loc, fn(slot) { block_slot(slot, fn() { block.get() }, from) }) |> ignore
      return
    }
    _ => ()
  }
  let count = @signals.computed(
    fn(_) {
      let n = blocks().length()
      match range {
        Some((from, upto)) => {
          let from = if from < n { from } else { n }
          let upto = if upto < n { upto } else { n }
          Array::makei(if upto > from { upto - from } else { 0 }, fn(i) { from + i })
        }
        None => Array::makei(n, fn(i) { i })
      }
    },
    same=fn(a, b) { a == b },
  )
  col.each(fn() { count.get() }, fn(i) { i }, fn(slot, i) {
    let i = i.untracked()
    block_slot(slot, fn() { blocks().get(i) }, i)
  })
}

///|
/// How many matches of what is found (`md`'s) the first `upto` of `blocks` hold, as the find counts them through the
/// words (a paragraph's, a heading's, a quote's and a list's; no table's or code's, whose words it marks not).
fn md_found_in(md : MdNode, blocks : Array[MdBlock], upto : Int) -> Int {
  guard (md.found_at)() is Some(_) else { return 0 }
  let words = (md.found)()
  fn count(b : MdBlock) -> Int {
    match b {
      Paragraph(xs) | Heading(_, xs) => find_words(md_plain(xs), words).length()
      Quote(bs) => bs.fold(init=0, fn(n, x) { n + count(x) })
      List(l) => l.items.fold(init=0, fn(n, it) { n + it.blocks.fold(init=0, fn(k, x) { k + count(x) }) })
      _ => 0
    }
  }
  let mut n = 0
  for k = 0; k < upto && k < blocks.length(); k = k + 1 {
    n = n + count(blocks[k])
  }
  n
}

///|
/// A block's kind, by which it is drawn (made again where it changes): a code block of a language drawn another way
/// (`md`'s `code`) its own.
fn md_block_kind(md : MdNode, b : MdBlock) -> Int {
  match b {
    // (a paragraph as it is drawn: words, a screen's card alone, a file alone, images side by side, words and images)
    Paragraph(xs) => md_paragraph_kind(md, xs)
    // (by its level: its words' size its own)
    Heading(level, _) => 10 + level
    Quote(_) => 2
    List(_) => 3
    CodeBlock(lang, _, _) => if (md.code)(lang) is Some(_) { 8 } else { 4 }
    MathBlock(_, _) => 5
    Rule => 6
    Table(_) => 7
  }
}

///|
/// How a paragraph (`xs`) is drawn (Md::piece's, Md::placed's): its words (0); only a link to a screen, its card (20);
/// only a link to a file the message places, that file (21); two or more of its images and nothing else, side by side
/// (22); words with images among them, each image on a line of its own between them (23).
fn md_paragraph_kind(md : MdNode, xs : Array[MdInline]) -> Int {
  if md.screens is Some(_) && screen_alone(xs) is Some(_) {
    return 20
  }
  let file_of = fn(x : MdInline) -> PlacedNode? {
    match x {
      Link(href, _, _) => (md.files)(file_name_of(href))
      Image(src, _) => (md.files)(file_name_of(src))
      _ => None
    }
  }
  let parts = md_parts_of(xs)
  if parts.length() == 1 && parts[0] is Link(_, _, _) && file_of(parts[0]) is Some(_) {
    return 21
  }
  if parts.length() > 1 && parts.iter().all(fn(x) { x is Image(_, _) && file_of(x).bind(fn(p) { p.image }) is Some(_) }) {
    return 22
  }
  if xs.iter().any(fn(x) { x is Image(_, _) && file_of(x) is Some(_) }) {
    return 23
  }
  0
}

///|
/// A paragraph's parts that are something (screen_alone's): no blank words, no soft breaks.
fn md_parts_of(xs : Array[MdInline]) -> Array[MdInline] {
  xs.filter(fn(x) {
    match x {
      Text(t) => t.trim(chars=" \n\t").to_owned() != ""
      _ => true
    }
  })
}

///|
/// The margins Md::piece keeps over and under block `b` (top, bottom).
fn md_node_margins(md : MdNode, b : MdBlock, tight : Bool) -> (Double, Double) {
  let s = (md.size)()
  match b {
    Paragraph(xs) =>
      match md_paragraph_kind(md, xs) {
        // (a screen's card, a file, alone: 8 over and under, Md::piece's and Md::placed's)
        20 | 21 => (8.0, 8.0)
        _ => if tight { (0.0, 0.0) } else { (0.0, paragraph_after) }
      }
    Heading(level, _) if md.document && level <= 3 => {
      let em = if level == 1 { 1.5 } else if level == 2 { 1.3 } else { 1.12 }
      (s * em, s * em / 2.0)
    }
    Heading(level, _) =>
      if level == 5 {
        let m = 1.67 * 0.83 * s
        (m, m)
      } else if level == 6 {
        let m = 2.33 * 0.67 * s
        (m, m)
      } else {
        (14.0, 6.0)
      }
    Quote(inner) => {
      let top = match inner.get(0) {
        Some(f) => dmax(0.0, md_node_margins(md, f, false).0)
        None => 0.0
      }
      let bottom = match inner.last() {
        Some(l) => {
          let b = md_node_margins(md, l, false).1
          if b > 8.0 { b } else { 8.0 }
        }
        None => 8.0
      }
      (top, bottom)
    }
    List(l) => {
      let top = match l.items.get(0) {
        Some(item) =>
          match item.blocks.get(0) {
            Some(f) => dmax(0.0, md_node_margins(md, f, l.tight).0)
            None => 0.0
          }
        None => 0.0
      }
      let bottom = match l.items.last() {
        Some(item) =>
          match item.blocks.last() {
            Some(f) => {
              let b = md_node_margins(md, f, l.tight).1
              if b > 8.0 { b } else { 8.0 }
            }
            None => 8.0
          }
        None => 8.0
      }
      (top, bottom)
    }
    CodeBlock(lang, _, _) => if (md.code)(lang) is Some(_) { (0.0, 4.0) } else { (0.0, 8.0) }
    MathBlock(_, _) | Table(_) => (0.0, 8.0)
    Rule => (s / 2.0, s / 2.0)
  }
}

///|
/// A block of kind `kind` (md_block_kind) in `p`, as `block` says it now (Md::piece's).
#callsite(autofill(loc))
fn md_block_node(
  p : @view.View,
  md : MdNode,
  kind : Int,
  block : () -> MdBlock?,
  tight : Bool,
  loc~ : SourceLoc,
) -> Unit {
  let s = md.size
  match kind {
    0 =>
      md_words_node(p, md, fn() {
        match block() {
          Some(Paragraph(xs)) => xs
          _ => []
        }
      }, s, 0)
    level if level >= 11 && level <= 16 => {
      let level = level - 10
      // (copied as a heading of its level: @ui.picked_html)
      @ui.words_shaped(p, fn() { @ui.WordsShape::Heading(level) }) |> ignore
      let em = if md.document && level <= 3 {
        if level == 1 { 1.5 } else if level == 2 { 1.3 } else { 1.12 }
      } else if level == 5 {
        0.83
      } else if level == 6 {
        0.67
      } else {
        1.0
      }
      md_words_node(p, md, fn() {
        match block() {
          Some(Heading(_, xs)) => xs
          _ => []
        }
      }, fn() { s() * em }, 700)
    }
    2 => {
      // beside a 2 bar of line_strong, in the web's muted, its tables in its column
      p.row(Is(true)) |> ignore
      p.box(made_for=loc, fn(bar) {
        bar.width(Is(Some(md_quote_bar))).ground(By(fn() { theme().p.line_strong })) |> ignore
      })
      |> ignore
      p.box(fn(inner) {
        inner.grow(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))).padding(Is((md_quote_in, 0.0, 0.0, 0.0))) |> ignore
        // (its paragraphs copied as one quote: @ui.picked_html)
        @ui.words_shaped(inner, fn() { @ui.WordsShape::Quote(inner.id()) }) |> ignore
        let quoted = { ..md, ink: fn() { web().muted }, bleed: fn() { 0.0 } }
        md_blocks_node(inner, quoted, fn() {
          match block() {
            Some(Quote(bs)) => bs
            _ => []
          }
        }, false)
      })
      |> ignore
    }
    3 =>
      md_list_node(p, md, fn() {
        match block() {
          Some(List(l)) => Some(l)
          _ => None
        }
      }, 1, items=md.table_rows, items_by?=md.rows_by)
    4 => {
      let lang = fn() {
        match block() {
          Some(CodeBlock(l, _, _)) => l
          _ => ""
        }
      }
      let source = fn() {
        match block() {
          Some(CodeBlock(_, c, _)) => c
          _ => ""
        }
      }
      code_block_node(p, source, lang, fn() {
        match block() {
          Some(CodeBlock(_, _, colours)) => colours
          _ => None
        }
      }, face=md.code_face, scale=fn() {
        let t = (md.typography)()
        t.prose_scale * t.code_scale
      }, code_cjk=fn() { (md.typography)().code_cjk })
    }
    // (drawn another way, as its language says: a chart, its code as it changes; another language's made again)
    8 => {
      let lang = fn() {
        match block() {
          Some(CodeBlock(l, _, _)) => l
          _ => ""
        }
      }
      p.pick(lang, fn(q, l) {
        match (md.code)(l) {
          Some(draw) =>
            draw(q, fn() {
              match block() {
                Some(CodeBlock(_, c, _)) => c
                _ => ""
              }
            })
          None => ()
        }
      })
    }
    5 =>
      // (on one line as written, scrolled across where wider than its column)
      p.scrolls(@view.Scroll::across(), slop=@ui.touch_slop(), bar=@ui.tree_scroll_bar(), fn(held) {
        held.lines_up(Is(Some(Start))) |> ignore
        md_words_node(held, md, fn() {
          match block() {
            Some(MathBlock(source, drawing)) => [Formula(source, drawing)]
            _ => []
          }
        }, s, 0, wrap=false)
      })
      |> ignore
    6 => p.height(Is(Some(md_rule_h))).ground(By(fn() { web().line })) |> ignore
    7 =>
      // (a long table's pieces scrolled across as one, by the block it is (never one block of a list taken for another's
      // row); a table in one block scrolled across on its own, as far as the message it is of has it where its block is
      // taken for another's: the list's, reused_state.mbt)
      md_table_body_node(
        p,
        fn() {
          match block() {
            Some(Table(t)) => Some(t)
            _ => None
          }
        },
        By(md.bleed),
        md.copy,
        md.on_link,
        md.on_link_hold,
        fit=md.fit,
        rows=md.table_rows,
        rows_by?=md.rows_by,
        across=match md.table_rows {
          Some(_) => @signals.untracked(fn() { (md.across_of)(md.block_at) })
          None => @view.Scroll::across()
        },
        // (a table in one block measured on its own; one in pieces once for all of them)
        tracks_kept?=match md.table_rows {
          Some(_) => @signals.untracked(fn() { (md.tracks_of)(md.block_at) })
          None => None
        },
        cell_images?=if md.places { Some(fn(cell) { md_cell_images(md, cell) }) } else { None },
        // (its cells' words as the message's are, measured as they are drawn: its files' chips, a bare link's title)
        cell_runs=fn(cell, head) {
          md_inlines_runs(md, cell, 0, block_ink=Some(if head { web().muted } else { theme().p.text }))
        },
        line_share=md.line,
        typography=Some(md.typography),
        link_cards=md.link_cards,
        on_link_shown=md.on_link_shown,
      )
    20 => {
      // (by what it links to, as it is now: another's card made again in its place)
      let alone = fn() {
        match block() {
          Some(Paragraph(xs)) => screen_alone(xs)
          _ => None
        }
      }
      p.pick(alone, fn(q, now) {
        match (md.screens, now) {
          (Some(sc), Some((href, to, words))) => (sc.card)(q, href, to, words)
          _ => ()
        }
      })
    }
    21 => {
      // (by the file it names, as it is now: another file made again in its place)
      let name = fn() {
        match block() {
          Some(Paragraph(xs)) =>
            match md_parts_of(xs).get(0) {
              Some(Link(href, _, _)) => file_name_of(href)
              _ => ""
            }
          _ => ""
        }
      }
      p.pick(name, fn(q, n) {
        match (md.files)(n) {
          Some(f) => (f.draw)(q)
          None => ()
        }
      })
    }
    22 =>
      md_image_rows_node(p, md, fn() {
        match block() {
          Some(Paragraph(xs)) =>
            md_parts_of(xs).filter_map(fn(x) {
              match x {
                Image(src, _) => {
                  let n = file_name_of(src)
                  (md.files)(n).bind(fn(f) { f.image }).map(fn(im) { (n, im.0) })
                }
                _ => None
              }
            })
          _ => []
        }
      })
    23 =>
      // (its words between its images, each image on a line of its own 8 over and under: Md::placed's)
      p.each(
        fn() {
          match block() {
            Some(Paragraph(xs)) => md_placed_runs(md, xs).mapi(fn(i, _) { i })
            _ => []
          }
        },
        fn(i) { i },
        fn(slot, i) {
          let i = i.untracked()
          let part = fn() {
            match block() {
              Some(Paragraph(xs)) => md_placed_runs(md, xs).get(i)
              _ => None
            }
          }
          slot.pick(fn() { part().map(fn(x) { x.0 }).unwrap_or(-1) }, fn(q, which) {
            if which == 1 {
              q.padding(Is((0.0, 8.0, 0.0, 8.0))) |> ignore
              // (by the file it names, as it is now)
              let name = fn() {
                match part() {
                  Some((_, xs)) =>
                    match xs.get(0) {
                      Some(Image(src, _)) => file_name_of(src)
                      _ => ""
                    }
                  None => ""
                }
              }
              q.pick(name, fn(r, n) {
                match (md.files)(n) {
                  Some(f) => (f.draw)(r)
                  None => ()
                }
              })
            } else {
              md_words_node(q, md, fn() { part().map(fn(x) { x.1 }).unwrap_or([]) }, s, 0)
            }
          })
        },
      )
    _ => ()
  }
  ignore(tight)
}

///|
/// Words `now` of a message as the pieces they are drawn in (`weight`: 600 or more bold), as md_words_node and a table's
/// cell draw them: a bare link to a screen or a chat read as its title, a file's chip where the message marks paths,
/// what a find found in its weight, in the faces tried and the serif face where the message is told them (Md::words').
fn md_inlines_runs(
  md : MdNode,
  now : Array[MdInline],
  weight : Int,
  block_ink? : Int64? = None,
) -> Array[@ui.Run] {
  let titles : Map[String, String] = Map([])
  // (a bare link to a screen reads as its title, a chat's too where the message says it: Md::words')
  match md.screens {
    Some(sc) => {
      let bare = []
      bare_screens(now, bare)
      for b in bare {
        titles[b.0] = (sc.title)(b.0, b.1)
      }
    }
    None => ()
  }
  let chats = []
  bare_chats(now, chats)
  for href in chats {
    match (md.chat_title)(href) {
      Some(title) => titles[href] = title
      None => ()
    }
  }
  let out = []
  let ink = match block_ink {
    Some(c) => c
    None => (md.ink)()
  }
  runs_of(now, out, weight >= 600, false, false, "", theme().p.accent_text, emph_ink_for(ink), titles, md.paths)
  let runs = found_weight(out, (md.found)())
  // (in the faces tried, where it is told them: Md::words')
  let text_face = (md.text_face)()
  let code_face = (md.code_face)()
  let runs = if (md.serif)() { runs.map(fn(x) { if x.mono || x.code { x } else { { ..x, serif: true } } }) } else { runs }
  if text_face is None && code_face is None {
    runs
  } else {
    runs.map(fn(run) {
      let face = if run.code || run.mono { code_face } else { text_face }
      match face {
        Some(_) => { ..run, face }
        None => run
      }
    })
  }
}

///|
/// A block's words (`xs`, as they change) as one paragraph of pieces (Md::words'): `size` and `weight` (0: 400), on
/// Markdown's lines, in the block's ink; links in blue pressed where they lead, code in its ink at 0.9; a bare link to
/// a chat its title; words found in bold.
#callsite(autofill(loc))
fn md_words_node(
  p : @view.View,
  md : MdNode,
  xs : () -> Array[MdInline],
  size : () -> Double,
  weight : Int,
  wrap? : Bool = true,
  cut? : Bool = false,
  one_line? : () -> Bool,
  loc~ : SourceLoc,
) -> Unit {
  // (worked out once as what they are worked out of changes, what reads them many times over reading that)
  let runs_now = @signals.computed(fn(_) { md_inlines_runs(md, xs(), weight) })
  let runs = fn() { runs_now.get() }
  let look = fn() -> @view.WordsLook {
    let size = size()
    // (a line said as a share of the size (`line`): that share of the words as they are drawn, the system's size of
    // words applied first, as the old view's paragraph's line_em; else Md::lh's points)
    let share = (md.line)()
    let ls = (md.typography)().line_scale
    let line = if share > 0.0 { -(share * ls) } else { md_line(md, size) }
    let wrap = match one_line {
      Some(f) => !f()
      None => wrap
    }
    { size, weight: if weight > 0 { weight } else { 400 }, line, wrap, tracking: @view.letters_own, balance: false, max_lines: 0 }
  }
  let words = p.box(made_for=loc, fn(w) {
    // (how they are set, all from the theme and their size: one binding for the three)
    w
    .words_runs(By(runs))
    .sets_together(fn() {
      let ty = (md.typography)()
      let cs = ty.code_scale
      let tc = ty.text_cjk
      let cc = ty.code_cjk
      let rl = table_runs_look()
      let rl = if cs == 1.0 && tc is None && cc is None {
        rl
      } else {
        { ..rl, code_scale: rl.code_scale * cs, cjk: tc, code_cjk: cc }
      }
      (look(), rl, (md.ink)())
    }, fn(s) {
      w.words_look(Is(s.0)).runs_look(Is(s.1)).ink(Is(s.2)) |> ignore
    })
    |> ignore
    // (what a find marks of them, as what it found and where it is change: found_marks, the one it is at counted
    // through all the words; a search's, every one; and a passage lit where these words have it: passage_marks)
    let found = fn() {
      match (md.found_at)() {
        Some(at) =>
          found_marks(runs(), (md.found)(), if at == found_all { at } else if at < 0 { -1 } else { at - (md.before)() })
        None => []
      }
    }
    // (no find and no passage lit, as nearly always: none, their words not read for it)
    w.runs_marks(By(fn() {
      let lit = (md.lit)()
      let lits = (md.lits)()
      if (md.found_at)() is None && lit.0 == "" && lits.is_empty() {
        []
      } else {
        let now = runs()
        let kept = lits.map(fn(l) { passage_marks(now, (l.0, l.1), before?=l.2) }).flatten()
        found() + kept + passage_marks(now, lit)
      }
    }))
    |> ignore
    // (what a go-to brings before the eyes in them, where they have it: sought_part)
    w.sought(fn() { sought_part(runs(), found(), (md.lit)().0).map(fn(r) { @ui.runs_piece(w, r.0, r.1) }) }) |> ignore
    // (on one line as wide as they are, cut short with an ellipsis where the column is narrower: one_line's)
    match one_line {
      Some(f) =>
        w.cuts(By(f)).min_width(By(fn() { if f() { Some(0.0) } else { None } })).allow_ellipsis(By(f)) |> ignore
      None =>
        if cut {
          w.cuts(Is(true)).min_width(Is(Some(0.0))).allow_ellipsis(Is(true)) |> ignore
        }
    }
  })
  // (its links pressed and their cards, made once it has one: words_links_node)
  let told = md.on_link_shown is Some(_) || md.link_cards is Some(_)
  words_links_node(p, words, runs, md.on_link, hold=md.on_link_hold, cards=md.link_cards, shown=if told {
    Some(fn(now) {
      match md.on_link_shown {
        Some(f) => f(words, now)
        None => ()
      }
    })
  } else {
    None
  }, loc~)
}

///|
/// The links of node `words` (its words in pieces, `runs` as they change) pressed where they lead (`tap`; held, `hold`),
/// `shown` told each as they are, and their cards (`cards`: drawn in its layer while a mouse rests on one,
/// link_cards_node, made in `parent`), as @ui.runs_links presses them: made as the words first have a link, words with
/// none (most of a chat's) made nothing for it, no node and no binding. Till then the words are a
/// ground under the arrow, as runs_links has words with no link (no hand, nothing pressed, a finger and a right click
/// going on to what is under them), and told they have no link once, as runs_links tells it as it is made; made in
/// place as a link comes, nothing let go.
#callsite(autofill(loc))
pub fn words_links_node(
  parent : @view.View,
  words : @view.View,
  runs : () -> Array[@ui.Run],
  tap : (String) -> Unit,
  hold? : ((String, (Double, Double, Double, Double)) -> Unit)? = None,
  cards? : (TipLayer, (LinkOf) -> LinkCard?)? = None,
  shown? : ((Array[(String, String, Int)]) -> Unit)? = None,
  loc~ : SourceLoc,
) -> Unit {
  let has_links = @signals.computed(fn(_) { runs().iter().any(fn(r) { r.link != "" }) })
  let made = Ref(false)
  let make = fn() {
    guard !made.val else { return }
    made.val = true
    let now : @signals.Signal[Array[(String, String, Int)]] = @signals.signal([])
    let told = shown is Some(_) || cards is Some(_)
    let links = @ui.runs_links(words, runs, tap, hold?=hold, shown?=if told {
      Some(fn(l) {
        now.set(l)
        match shown {
          Some(f) => f(l)
          None => ()
        }
      })
    } else {
      None
    })
    match cards {
      Some((layer, card_of)) => link_cards_node(parent, layer, words, links, fn() { now.get() }, card_of, loc~) |> ignore
      None => ()
    }
  }
  if @signals.untracked(fn() { has_links.get() }) {
    make()
  } else {
    // (nothing made for their cards till a link comes: link_cards_node's box, over `parent` and taking no room, made in
    // it then. A room held for them in every paragraph with none was once (#6597) what kept `parent` a ride kept with
    // the words its one child (view_ride's ride_holder, #6613): no more)
    words.as_ground().cursor(Is(Some(@view.Cursor::Arrow))) |> ignore
    match shown {
      Some(f) => f([])
      None => ()
    }
    words.reacts(fn() { has_links.get() }, fn(on) { if on { make() } }, at_start=false)
  }
}

///|
/// A line of `size`'s words (Md::lh's).
fn md_line(md : MdNode, size : Double) -> Double {
  let ls = (md.typography)().line_scale
  let share = (md.line)()
  if share > 0.0 {
    return (size * share * ls).round()
  }
  let k : Float = 1.65
  let base = (Float::from_double(size) * k).to_double()
  if ls == 1.0 { base } else { base * ls }
}

///|
/// A list (`list`, as it changes) at `depth` (Md::list's): each item a row, its marker in a 20 indent (a number right
/// up to 5 from its words, as wide as the last one's; a disc, a circle, a square by depth), a task's box after it, its
/// blocks beside them; its tables in its indent.
fn md_list_node(
  p : @view.View,
  md : MdNode,
  list : () -> MdList?,
  depth : Int,
  items? : (Int, Int)? = None,
  items_by? : () -> (Int, Int)?,
) -> Unit {
  let inner_md = { ..md, bleed: fn() { 0.0 }, table_rows: None, rows_by: None }
  let s = md.size
  // (the list's own, worked out once for all its items as what they are worked out of changes)
  let ordered_now = @signals.computed(fn(_) { list().map(fn(l) { l.ordered }).unwrap_or(false) })
  let ordered = fn() { ordered_now.get() }
  let tight_now = @signals.computed(fn(_) { list().map(fn(l) { l.tight }).unwrap_or(false) })
  let tight = fn() { tight_now.get() }
  let marker_w_now = @signals.computed(fn(_) {
    match list() {
      Some(l) if l.ordered =>
        dmax(md_marker_w, @ui.text_advance("\{l.start + l.items.length() - 1}.", size=node_sp(p, s())) + md_marker_gap)
      _ => md_marker_w
    }
  })
  let marker_w = fn() { marker_w_now.get() }
  // (whether any of its items is a task, as nearly no list's is: what each item's box is shown by asks it first)
  let has_task = @signals.computed(fn(_) {
    list().map(fn(l) { l.items.iter().any(fn(it) { it.task is Some(_) }) }).unwrap_or(false)
  })
  // (all its items, or those of them its piece draws (`items`), each by its place among all)
  let count = fn() {
    let n = list().map(fn(l) { l.items.length() }).unwrap_or(0)
    // (those its piece draws as it is now, where it is told so: more items may be added when the list is edited in
    // place)
    let items = match items_by {
      Some(f) => f()
      None => items
    }
    match items {
      Some((from, upto)) => {
        let upto = if upto < n { upto } else { n }
        Array::makei(if upto > from { upto - from } else { 0 }, fn(i) { from + i })
      }
      None => Array::makei(n, fn(i) { i })
    }
  }
  p.each(count, fn(i) { i }, fn(row, i) {
    let i = i.untracked()
    let item = fn() { list().bind(fn(l) { l.items.get(i) }) }
    // (as far under the item before as the larger of their margins: stack's; the first right at the top)
    row.row(Is(true)).lines_up(Is(Some(Start))) |> ignore
    // (copied as an item of its list, at its depth, numbered as the list is then: @ui.picked_html)
    @ui.words_shaped(row, fn() {
      // (read as it is copied, a press's: not followed)
      let number = @signals.untracked(fn() {
        if ordered() {
          list().map(fn(l) { l.start }).unwrap_or(1) + i
        } else {
          0
        }
      })
      @ui.WordsShape::Item(depth, number, row.id())
    })
    |> ignore
    if i == 0 {
      row.padding(Is((0.0, 0.0, 0.0, 0.0))) |> ignore
    } else {
      row.padding(By(fn() {
        match (list().bind(fn(l) { l.items.get(i - 1) }), item()) {
          (Some(a), Some(b)) => {
            let before = match a.blocks.last() {
              Some(x) => md_node_margins(inner_md, x, tight()).1
              None => 0.0
            }
            let top = match b.blocks.get(0) {
              Some(x) => md_node_margins(inner_md, x, tight()).0
              None => 0.0
            }
            (0.0, dmax(before, top), 0.0, 0.0)
          }
          _ => (0.0, 0.0, 0.0, 0.0)
        }
      }))
      |> ignore
    }
    let line = fn() {
      row.words_redone() |> ignore
      node_sp(row, md_line(md, s()))
    }
    row.pick(ordered, fn(m, numbered) {
      if numbered {
        m
        .row(Is(true))
        .min_width(By(fn() { Some(marker_w()) }))
        .padding(Is((0.0, 0.0, md_marker_gap, 0.0)))
        .lies_along(Is(End))
        |> ignore
        m.box(fn(n) {
          n
          .words(By(fn() { "\{list().map(fn(l) { l.start }).unwrap_or(1) + i}." }))
          .words_look(By(fn() { md_plain_look(s(), md_line(md, s())) }))
          .ink(By(md.ink))
          |> ignore
        })
        |> ignore
      } else {
        md_bullet_node(m, depth, s, line, md.ink)
      }
    })
    row.show(fn() { has_task.get() && item().bind(fn(it) { it.task }) is Some(_) }, fn(t) {
      md_task_node(t, fn() { item().bind(fn(it) { it.task }).unwrap_or(false) }, line)
    })
    row.box(fn(blocks) {
      blocks.grow(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
      // (a nested list a level deeper; the rest as the list's own blocks)
      let bs = fn() { item().map(fn(it) { it.blocks }).unwrap_or([]) }
      let count = fn() { Array::makei(bs().length(), fn(k) { k }) }
      blocks.each(count, fn(k) { k }, fn(slot, k) {
        let k = k.untracked()
        let b = fn() { bs().get(k) }
        // (the matches before it: the list's, the items' over it as quoted blocks, its own blocks' over it)
        let inner_md = {
          ..inner_md,
          before: fn() {
            let items = list().map(fn(l) { l.items }).unwrap_or([])
            (md.before)() + md_found_in(md, items.map(fn(it) { Quote(it.blocks) }), i) + md_found_in(md, bs(), k)
          },
        }
        // (its first block right at the item's top)
        if k == 0 {
          slot.padding(Is((0.0, 0.0, 0.0, 0.0))) |> ignore
        } else {
          slot
          .padding(By(fn() {
            let all = bs()
            let before = md_node_margins(inner_md, all[k - 1], tight()).1
            let top = match all.get(k) {
              Some(x) => md_node_margins(inner_md, x, tight()).0
              None => 0.0
            }
            (0.0, dmax(before, top), 0.0, 0.0)
          }))
          |> ignore
        }
        slot.pick(fn() { b().map(fn(x) { md_block_kind(inner_md, x) }).unwrap_or(-1) }, fn(q, kind) {
          if kind == 3 {
            md_list_node(q, inner_md, fn() {
              match b() {
                Some(List(sub)) => Some(sub)
                _ => None
              }
            }, depth + 1)
          } else {
            md_block_node(q, inner_md, kind, b, @signals.untracked(tight))
          }
        })
      })
    })
    |> ignore
  })
}

///|
/// A bulleted item's marker (bullet's): a third of the words' size across, its middle 5 into the indent, on the first
/// line's middle (`line`); a disc, then a circle, then a square.
#callsite(autofill(loc))
fn md_bullet_node(
  m : @view.View,
  depth : Int,
  size : () -> Double,
  line : () -> Double,
  ink : () -> Int64,
  loc~ : SourceLoc,
) -> Unit {
  let side = fn() { (size() / 3.0 * 2.0).round() / 2.0 }
  m
  .width(Is(Some(md_marker_w)))
  .lies_along(Is(Middle))
  .height(By(fn() { Some(line()) }))
  .lines_up(Is(Some(Start)))
  |> ignore
  m.box(made_for=loc, fn(b) {
    // (all of it from its size and ink: one binding)
    b.sets_together(fn() { (side(), ink()) }, fn(now) {
      let (side, ink) = now
      b
      .width(Is(Some(side)))
      .height(Is(Some(side)))
      .offset(Is((5.0 - side / 2.0, 0.0)))
      .radius(Is(if depth >= 3 { 0.0 } else { side / 2.0 }))
      .ground(Is(if depth == 2 { 0L } else { ink }))
      // (no edge an edge of its ground's colour, as a box drawn without one)
      .edge(Is(if depth == 2 { (1.0, ink) } else { (0.0, ink) }))
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// A task's box (task_box's): 13 across in its room (task_room at the system's size, 4 before and 8 after), on the
/// first line's middle; faint grey, filled and ticked when `done`. Read out a checkbox that takes nothing.
#callsite(autofill(loc))
fn md_task_node(t : @view.View, done : () -> Bool, line : () -> Double, loc~ : SourceLoc) -> Unit {
  let faint = fn() { if theme().dark { 0xA0A0A066L } else { 0x7676764DL } }
  let filled = fn() { if theme().dark { 0xA0A0A066L } else { 0x6E6E6EE6L } }
  let tick_k = md_task_side / check_side
  let tick_pts = check_tick_points.map(fn(p) { (p.0 * tick_k, p.1 * tick_k) })
  let tick_w = check_tick_w * tick_k
  t
  .row(Is(true))
  .width(By(fn() {
    t.words_redone() |> ignore
    Some(node_sp(t, task_room))
  }))
  .height(By(fn() { Some(line()) }))
  .padding(Is((4.0, 0.0, 8.0, 0.0)))
  .lies_along(Is(Middle))
  .lines_up(Is(Some(Middle)))
  |> ignore
  t.box(made_for=loc, fn(b) {
    b
    .row(Is(true))
    .width(Is(Some(md_task_side)))
    .height(Is(Some(md_task_side)))
    .radius(Is(md_task_side / 3.0))
    .lies_along(Is(Middle))
    .lines_up(Is(Some(Middle)))
    .ground(By(fn() { if done() { filled() } else { alpha(theme().p.canvas, 0.6) } }))
    .edge(By(fn() { if done() { (0.0, filled()) } else { (1.0, faint()) } }))
    .says(By(fn() { Some(@view.said(Checkbox, check=if done() { On } else { Off })) }))
    .presses(Is(false))
    |> ignore
    b.show(done, at_once=true, fn(c) {
      c
      .width(Is(Some(md_task_side)))
      .height(Is(Some(md_task_side)))
      .lines(By(fn() {
        let ink = if theme().dark { alpha(theme().p.text, 0.9) } else { 0xFFFFFFFFL }
        [@paint.line(tick_pts, width=tick_w, color=ink, upto=1.0)]
      }))
      |> ignore
    })
  })
  |> ignore
}

///|
/// A code block (code_block's) in `p`: on the code ground, row_corner round, cut to it; its language and its copy key
/// (a capsule, concentric with the block's corner) on a row of their own over the code with either input (code_block's);
/// the code in the code face, in the colours the core said (`colours`), 12 on 18 (on a
/// desktop's width 12 on 1.6), scrolled across, or wrapped at its width once its wrap key (before the copy key) is
/// pressed, till it is pressed again. Pressed, the copy key copies the code and says so copied_ms. `face`: a face
/// tried for the code, as it is now (code_block's: None or Some(0) the code's own). `command`: a command to copy and
/// run elsewhere (添加 station's, a profile's sign-in on its machine): on its one line, scrolled across, its copy key
/// beside it (no bar, no language, no wrap key: the user,
/// 2026-11-17, 「为啥上面空了那么多」). Otherwise, with a mouse, no bar: its wrap and copy keys are icons in its top right
/// corner (code_block's tray), taking no room, shown while the pointer is on the block, or always (`keys_always`; the
/// user, 2026-11-17: 「hover 才显示，不占空间，悬浮，可以配置成永远显示」, then the icons of GitHub's and Cursor's, 方案 2);
/// with a finger, which hovers over nothing, on their bar over it. The app's one block of code or of a command to copy
/// (the user, 2026-11-17: 「合成一个组件」).
#callsite(autofill(loc))
pub fn code_block_node(
  p : @view.View,
  code : () -> String,
  lang : () -> String,
  colours : () -> String?,
  face? : () -> Int? = fn() { None },
  scale? : () -> Double = fn() { 1.0 },
  code_cjk? : () -> @view.CjkOverride? = fn() { None },
  command? : Bool = false,
  keys_always? : Bool = false,
  loc~ : SourceLoc,
) -> Unit {
  let over = native_input() is Mouse
  let key_inset = @ui.capsule_in(row_corner, code_key_h)
  let copied = @signals.signal(false)
  // (wrapped as the message it is of has it, where its block of a list is taken for another's: the list's)
  let wrapped = p.reused_bool()
  let copied_off : Ref[() -> Unit] = Ref(fn() {  })
  p.owns(fn() { (copied_off.val)() }) |> ignore
  // (taken for another message's: copied said of none of it, the moment that would have said so no more)
  p.on_reused(fn() {
    (copied_off.val)()
    copied_off.val = fn() {  }
    copied.set(false)
  })
  // (a column as wide as its room, its bar over the code)
  p
  .row(Is(false))
  .lines_up(Is(None))
  .radius(Is(row_corner))
  .clips(Is(true))
  .ground(By(fn() { theme().p.code_ground }))
  |> ignore
  // (its code in a box of its own: wrapped at its width, or on its lines as written in one that scrolls across, what
  // is over it staying)
  let words = fn(w : @view.View, wrap : Bool) {
    let runs = fn() {
      let runs = match colours() {
        Some(ink) => core_ink(code(), ink, theme().dark)
        None => [@ui.span(code(), mono=true)]
      }
      // (in the face tried, where it is told one: code_block's paragraph's `face`)
      match face() {
        Some(f) if f != 0 => runs.map(fn(run) { { ..run, face: Some(f) } })
        _ => runs
      }
    }
    let look = fn() -> @view.WordsLook {
      let sc = scale()
      {
        size: theme().t.caption * sc,
        weight: 400,
        line: (if over { code_line_wide } else { 18.0 }) * sc,
        wrap,
        tracking: @view.letters_own,
        balance: false,
        max_lines: 0,
      }
    }
    // (each of its lines a line of its own, scrolled across or wrapped: code_block's `breaks`)
    w
    .words_runs(By(runs))
    .words_look(By(look))
    .runs_look(By(fn() {
      match code_cjk() {
        Some(_) as cc => { ..@view.runs_plain, code_cjk: cc }
        None => @view.runs_plain
      }
    }))
    .words_breaks(Is(true))
    .ink(By(fn() { theme().p.text }))
    |> ignore
    // (copied as the block of code it is: @ui.picked_html)
    @ui.words_shaped(w, fn() { @ui.WordsShape::Code(p.id()) }) |> ignore
  }
  // (its copy key: copies the code and says so copied_ms)
  let copy_key = fn(b : @view.View) {
    b.box(fn(k) {
      k
      .row(Is(true))
      .min_height(Is(Some(code_key_h)))
      .padding(Is((7.0, 1.0, 7.0, 1.0)))
      .gap(Is(4.0))
      .lines_up(Is(Some(Middle)))
      .radius(Is(code_key_h / 2.0))
      .ground(By(fn() { alpha(theme().p.canvas, 0.8) }))
      |> ignore
      pressed_node(k, fn() {
        @ui.clipboard_set(@signals.untracked(code))
        // (pressed again while it says so: from then)
        (copied_off.val)()
        copied.set(true)
        copied_off.val = k.at_moment(k.logic_at() + copied_ms, fn() { copied.set(false) })
      }, Is(code_key_h / 2.0), Button, fn() { md_copy_words(copied.get()) })
      icon_node(k, "copy", 12.0, By(fn() { web().muted }), name_now=fn() { if copied.get() { "check" } else { "copy" } }) |> ignore
      k.box(fn(n) {
        let look = @signals.untracked(fn() { md_plain_look(theme().t.caption, 0.0) })
        n.words(By(fn() { md_copy_words(copied.get()) }), look~).ink(By(fn() { web().muted })) |> ignore
      })
      |> ignore
    })
    |> ignore
  }
  // (a command: its words beside its copy key, their first line in the middle of it, wrapped at what is left of the
  // width; no bar over them to stand empty)
  if command {
    let line = if over { code_line_wide } else { 18.0 }
    let first = key_inset + (code_key_h - line) / 2.0
    p.row(Is(true)).lines_up(Is(Some(Start))) |> ignore
    // (on its one line, scrolled across: nobody reads it whole before copying it, and who does scrolls; the user,
    // 2026-11-17: 「不用折行，没啥人会看，要看的自己横向滚动」)
    p.box(made_for=loc, fn(q) {
      q.grow(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
      q.scrolls(@view.Scroll::across(), slop=@ui.touch_slop(), bar=@ui.tree_scroll_bar(), fn(held) {
        held.padding(Is((14.0, first, 8.0, first))).lines_up(Is(Some(Start))) |> ignore
        held.box(fn(w) { words(w, false) }) |> ignore
      })
      |> ignore
    })
    |> ignore
    p.box(fn(k) {
      k.padding(Is((0.0, key_inset, key_inset, key_inset))) |> ignore
      copy_key(k)
    })
    |> ignore
    return
  }
  let bar = fn(b : @view.View) {
    b
    .row(Is(true))
    .min_height(Is(Some(key_inset + code_key_h)))
    .padding(Is((key_inset, key_inset, key_inset, 0.0)))
    .lies_along(Is(End))
    .lines_up(Is(Some(Middle)))
    |> ignore
    b.box(fn(l) {
      l.padding(Is((6.0, 0.0, 6.0, 0.0))) |> ignore
      // (floating over the code: on a capsule of its own as the keys are, so the code under it does not show through)
      let size = if over { code_lang_wide } else { 10.0 }
      l.box(fn(n) {
        let look = @signals.untracked(fn() { md_plain_look(size, 0.0) })
        n.words(By(fn() { if lang() == "" { "text" } else { lang() } }), look~).ink(By(fn() { web().subtle })) |> ignore
      })
      |> ignore
    })
    |> ignore
    // (wrapped at the block's width, or on its lines as written, scrolled across: a press each way)
    b.box(fn(k) {
      k
      .row(Is(true))
      .min_height(Is(Some(code_key_h)))
      .padding(Is((7.0, 1.0, 7.0, 1.0)))
      .lines_up(Is(Some(Middle)))
      .radius(Is(code_key_h / 2.0))
      .ground(By(fn() { alpha(theme().p.canvas, 0.8) }))
      |> ignore
      pressed_node(k, fn() { wrapped.set(!wrapped.get()) }, Is(code_key_h / 2.0), Button, fn() {
        md_wrap_words(wrapped.get())
      })
      k.box(fn(n) {
        let look = @signals.untracked(fn() { md_plain_look(theme().t.caption, 0.0) })
        n.words(By(fn() { md_wrap_words(wrapped.get()) }), look~).ink(By(fn() { web().muted })) |> ignore
      })
      |> ignore
    })
    |> ignore
    // (apart as an old view's keys are: code_keys_apart)
    b.box(fn(g) { g.width(Is(Some(code_keys_gap))) |> ignore }) |> ignore
    copy_key(b)
  }
  // (with a mouse its keys are the tray's, after the code; with a finger, which hovers over nothing, on their bar over it)
  if !over {
    p.box(made_for=loc, bar) |> ignore
  }
  p.box(fn(sc) {
    sc.pick(fn() { if wrapped.get() { 1 } else { 0 } }, fn(q, kind) {
      if kind == 1 {
        q.padding(Is((14.0, 12.0, 14.0, 12.0))) |> ignore
        q.box(fn(w) { words(w, true) }) |> ignore
      } else {
        // (its bar clear of the block's round corners)
        q.scrolls(@view.Scroll::across(), slop=@ui.touch_slop(), bar=@ui.tree_scroll_bar(), fn(held) {
          held.padding(Is((14.0, 12.0, 14.0, 12.0))).lines_up(Is(Some(Start))) |> ignore
          held.box(fn(w) { words(w, false) }) |> ignore
        })
        |> ignore
      }
    })
    |> ignore
  })
  |> ignore
  // (with a mouse: code_block's tray, its wrap and copy keys icons on the canvas within a hairline, concentric with
  // the block's corner a step of the ladder in, as high as a line of code and its room less that step)
  if over {
    let in_ = row_corner - small_corner
    let side = code_line_wide + code_room_y * 2.0 - in_ * 2.0
    p.box(made_for=loc, fn(o) {
      o
      .over(Is(true), from_top=true)
      .row(Is(true))
      .lies_along(Is(End))
      .padding(Is((0.0, in_, in_, 0.0)))
      |> ignore
      // (made only while the pointer is on the block, it says it copied, or it is said to show always)
      o.show(at_once=true, fn() { keys_always || copied.get() || p.pointer_within() }, fn(t) {
        t.row(Is(true)).gap(Is(code_keys_gap)) |> ignore
        let key = fn(icon : String, said : () -> String, press : () -> Unit, icon_now : () -> String, on : () -> Bool) {
          t.box(fn(k) {
            style_node(k, fn() { code_tray_key_look })
            k.radius(Is(small_corner)) |> ignore
            icon_button_node(k, icon, said, press, size=side, icon_size=code_tray_icon, icon_now~, grounded=false, on~) |> ignore
          })
          |> ignore
        }
        key("wrap", fn() { md_wrap_words(wrapped.get()) }, fn() { wrapped.set(!wrapped.get()) }, fn() { "wrap" }, fn() { wrapped.get() })
        key(
          "copy",
          fn() { md_copy_words(copied.get()) },
          fn() {
            @ui.clipboard_set(@signals.untracked(code))
            (copied_off.val)()
            copied.set(true)
            copied_off.val = p.at_moment(p.logic_at() + copied_ms, fn() { copied.set(false) })
          },
          fn() { if copied.get() { "check" } else { "copy" } },
          fn() { false },
        )
      })
    })
    |> ignore
  }
}

///|
/// A code block's tray key's hairline (code_block's).
let code_tray_key_look : @ui.Style = @ui.css("bg=Surface border=B0_5 border_color=Line")

///|
/// How far apart a code block's keys stand (code_keys_apart's 4).
let code_keys_gap : Double = 4.0

///|
/// The wrap key's words: what pressing it does (wrapped, back on its lines as written).
fn md_wrap_words(wrapped : Bool) -> String {
  if language() == "en" {
    if wrapped { "No wrap" } else { "Wrap" }
  } else if wrapped {
    "不换行"
  } else {
    "换行"
  }
}

///|
/// The copy key's words (common.copied).
fn md_copy_words(copied : Bool) -> String {
  if language() == "en" {
    if copied { "Copied" } else { "Copy" }
  } else if copied {
    "已复制"
  } else {
    "复制"
  }
}

///|
/// A quote's bar (2 of line_strong) and how far in its words stand from it (10).
let md_quote_bar : Double = 2.0

///|
let md_quote_in : Double = 10.0

///|
/// A rule's line (1).
let md_rule_h : Double = 1.0

///|
/// A task's box side (13pt, radius md_task_side / 3.0).
let md_task_side : Double = 13.0

///|
/// Words of `size` on one line, in 400, on lines `line` high (0: the theme's line for that size as they are drawn, the
/// system's size of words applied first, as old text's with none said: style_words' share of their size).
fn md_plain_look(size : Double, line : Double) -> @view.WordsLook {
  { size, weight: 400, line: if line > 0.0 { line } else { -@ui.tree_theme().text_line }, wrap: false, tracking: @view.letters_own, balance: false, max_lines: 0 }
}

///|
/// A table's cell of only the message's images (Md::cell_images'): each one's width over its height (no wider than 4
/// to 1 nor taller than 1 to 4) and its drawing (its file's, PlacedNode's `image`); None for any other cell, drawn as
/// words.
fn md_cell_images(md : MdNode, cell : Array[MdInline]) -> Array[(Double, (@view.View, () -> Double) -> Unit)]? {
  let out = []
  for x in cell {
    match x {
      Text(t) if t.trim(chars=" \n\t").to_owned() == "" => ()
      HardBreak => ()
      Image(src, _) =>
        match (md.files)(file_name_of(src)) {
          Some({ image: Some((r, draw)), .. }) => out.push((dmax(dmin(r, 4.0), 0.25), draw))
          _ => return None
        }
      _ => return None
    }
  }
  if out.length() == 0 {
    None
  } else {
    Some(out)
  }
}

///|
/// A paragraph with images among its words in its parts (Md::placed's): its words between them (0, the words) and each
/// image it places (1, the image alone), in order; words that are only blanks none.
fn md_placed_runs(md : MdNode, xs : Array[MdInline]) -> Array[(Int, Array[MdInline])] {
  let out : Array[(Int, Array[MdInline])] = []
  let mut run : Array[MdInline] = []
  let flush = fn() {
    if run.iter().any(fn(x) {
        match x {
          Text(t) => t.trim(chars=" ").to_owned() != ""
          HardBreak => false
          _ => true
        }
      }) {
      out.push((0, run))
    }
    run = []
  }
  for x in xs {
    match x {
      Image(src, _) if (md.files)(file_name_of(src)) is Some(_) => {
        flush()
        out.push((1, [x]))
      }
      _ => run.push(x)
    }
  }
  flush()
  out
}

///|
/// A paragraph's images in rows (image_rows'), each by the file it names and its width over its height (`images`, as they
/// change): 8 apart either way, 8 over and under; as many on a row as fit the room it is given at least 120 high,
/// then grown alike to fill it, 200 high at most; a row's images one height. Each drawn by its file (`md`'s `files`) at
/// the width it has now, kept by the file and which of its showings in the paragraph it is; another file made again in
/// its place.
fn md_image_rows_node(p : @view.View, md : MdNode, images : () -> Array[(String, Double)]) -> Unit {
  p.padding(Is((0.0, image_row_gap, 0.0, image_row_gap))) |> ignore
  // (its rows by the room it is given, laid out in that same layout)
  p.by_room(fn(p, given) {
    p.gap(Is(image_row_gap)) |> ignore
    let room = fn() {
      p.words_redone() |> ignore
      given.width()
    }
    // (each by its key, the file and how many of it are before it: one file twice two images)
    let rows = fn() {
      let out : Array[Array[(String, String, Double)]] = [[]]
      let mut used = 0.0
      let r = room()
      let seen : Map[String, Int] = Map([])
      for named in images() {
        let k = seen.get(named.0).unwrap_or(0)
        seen[named.0] = k + 1
        let im = (named.0 + "#" + k.to_string(), named.0, named.1)
        let row = out[out.length() - 1]
        let w = im.2 * image_row_least + (if row.length() > 0 { image_row_gap } else { 0.0 })
        if row.length() > 0 && used + w > r {
          out.push([im])
          used = im.2 * image_row_least
        } else {
          row.push(im)
          used = used + w
        }
      }
      out
    }
    p.each(fn() { rows().mapi(fn(i, _) { i }) }, fn(i) { i }, fn(line, i) {
      let i = i.untracked()
      line.row(Is(true)).gap(Is(image_row_gap)) |> ignore
      let row = fn() { rows().get(i).unwrap_or([]) }
      let h = fn() {
        let all = row()
        let ratios = all.fold(init=0.0, fn(n, im) { n + im.2 })
        if ratios <= 0.0 { 0.0 } else { dmin(image_row_most, (room() - image_row_gap * (all.length() - 1).to_double()) / ratios) }
      }
      // (the row's images kept by key: an image's cell told as that image changes, comes or goes, never as another does)
      let by_key = line.keyed_by(row, fn(im) { im.0 })
      line.each(fn() { by_key.keys() }, fn(k) { k }, fn(cell, k) {
        let k = k.untracked()
        let width = fn() {
          match by_key.get(k) {
            Some(im) => (im.2 * h()).floor()
            None => 0.0
          }
        }
        let n = @signals.untracked(fn() { by_key.get(k).map(fn(im) { im.1 }).unwrap_or("") })
        match (md.files)(n).bind(fn(f) { f.image }) {
          Some(im) => (im.1)(cell, width)
          None => ()
        }
        cell.width(By(fn() { Some(width()) })) |> ignore
      })
    })
  })
  |> ignore
}

///|
/// Passages what holds a Markdown text marks on its paragraphs where they have them, each with its ground (a reader's
/// notes kept on its words: reader_marks; a chat message's words a note was asked of), and where in them it was
/// picked where that is known (passage_marks' `before`: only that time the words are in them), read as a paragraph's
/// marks are drawn.
// kept across runs: what each node lends (View::lends), let go with it
pub let md_lits : @view.Lent[() -> Array[(String, Int64, String?)]] = @view.Lent::new()
