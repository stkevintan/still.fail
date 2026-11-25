// What of the window's tree's words is picked with the pointer (tree_select.mbt), as a page made of nodes reads it to
// do something with it (a chat's quote of what is picked in its messages, as an old page reads Ctx::selected_text and
// Ctx::selection_end): followed as a signal (picked_now), once the pointer has let it go; what each paragraph's words are
// of, as what holds them says (picked_of); where it ends, as a piece of the node it ends in for what goes beside it
// (picked_end_piece: placed as the tree is laid out, never read back); let go by a handler (picked_let_go), kept by a
// press on what says so (keeps_picked).

///|
/// What of the window's tree's words is picked with the pointer, once the pointer has let it go (picked_now).
#derive(Eq, Debug)
pub struct WordsPicked {
  /// the words picked, each paragraph's on a line of its own in the page's order (Ctx::selected_text's)
  text : String
  /// what each paragraph picked is of, as what holds it said (picked_of), in the page's order, one said by paragraphs
  /// next to each other once; those whose holders said none left out
  of : Array[String]
  /// the selection scope root (words_picked) that this selection belongs to
  within : @view.NodeId
  /// how many non-empty selected paragraphs had no `picked_of` owner
  strays : Int
  /// the node of the tree's whose words it ends in (where the pointer let it go: dragged down, its last; dragged up,
  /// its first), as it was shown when that paragraph was last found (picked_end_piece: where in it)
  ends_in : @view.NodeId
  /// the pointer let go at the start of what is picked, rather than its end
  ends_at_start : Bool
  /// where in its first paragraph's words (in the page's order) what is picked begins, and where in its last it ends:
  /// code units of what that paragraph's node shows (a code viewer's exact lines)
  first_at : Int
  last_at : Int
  /// what its first paragraph's node shows before what is picked begins there (`first_at`'s words): which of the
  /// times its words are in that paragraph, and which paragraph, is the one picked
  first_before : String
  /// picked by a finger (held on its words: its handles and the system's text menu over it)
  finger : Bool
  /// which selection it is (Ctx::selection_made): another number for each a press begins
  made : Int
}

///|
/// What of kind `of` the words node `v` holds are of, said for what is picked of them (WordsPicked's `of`: a message's
/// id, by its row). The nearest that says it, it or what holds it.
// kept across runs: what each node lends (View::lends), let go with it
let picked_ofs : @view.Lent[String] = @view.Lent::new()

///|
/// A press on what node `v` holds, or on it, keeps what is picked with the pointer (keeps_picked).
// kept across runs: what each node lends (View::lends), let go with it
let keeps_picks : @view.Lent[Bool] = @view.Lent::new()

///|
/// Whether what node `v` holds is said whole of what it is of (picked_of's `whole`), the nearest that says it.
// kept across runs: what each node lends (View::lends), let go with it
let picked_wholes : @view.Lent[Bool] = @view.Lent::new()

///|
/// The words node `v` holds (its own and those of what it holds that are picked with the pointer: words_picked) are
/// of `of` (a message's id), said for what is picked of them (WordsPicked's `of`). Said `whole`, they are one whole
/// to a select all over a finger's pick in them (the system's text menu's): it takes all the words said of what is
/// picked, not all the page's (finger_select_all: a message's 全选). `v`.
pub fn picked_of(v : @view.View, of : String, whole? : Bool = false) -> @view.View {
  v.lends(picked_wholes, whole).lends(picked_ofs, of)
}

///|
/// A press on node `v` or on what it holds (the mouse's down, a finger's tap) keeps what is picked with the pointer, as
/// an old view's Ctx::keeps_selection: a control that does something with it (a quote of it). `v`.
pub fn keeps_picked(v : @view.View) -> @view.View {
  v.lends(keeps_picks, true)
}

///|
/// Whether a press at (x, y) in the window goes to what keeps what is picked (keeps_picked): the node of the tree's it
/// is for, or what holds it, says so.
fn tree_keeps_picked_at(tree : @view.Tree, x : Double, y : Double) -> Bool {
  let id = match tree.target_at(x, y) {
    Pressed(id) | Dragged(id) => id
    _ => return false
  }
  match tree.view_of(id) {
    Some(v) => v.lent(keeps_picks) == Some(true)
    None => false
  }
}

///|
/// What node of the tree's last showed each paragraph that can be picked, what its words were said to be of
/// (picked_of), and its selection scope root (words_picked), as they were found (tree_sels): what is picked is told by
/// them, those scrolled away as they were.
// kept across runs: said as paragraphs are found, those picked kept, the rest let go past a few hundred
let picked_shown : Map[SelKey, (@view.NodeId, String?, @view.NodeId)] = Map([])

///|
/// Paragraph `base` found shown by node `v` in selection scope `scope_id` (tree_sels).
fn picked_shown_by(base : SelKey, v : @view.View, scope_id : @view.NodeId) -> Unit {
  picked_shown[base] = (v.id(), v.lent(picked_ofs), scope_id)
  if picked_shown.length() > 512 {
    let gone : Array[SelKey] = []
    picked_shown.each(fn(k, _) {
      if !picked.spans.contains(k) {
        gone.push(k)
      }
    })
    for k in gone {
      picked_shown.remove(k)
    }
  }
}

///|
/// What is picked of each paragraph (those of which some is), in the page's order, and the paragraph it ends in (where
/// the pointer let it go: dragged down, the last; dragged up, the first); None where none is.
fn picked_in_order() -> (Array[(SelKey, SelSpan)], SelKey)? {
  let spans : Array[(SelKey, SelSpan)] = []
  picked.spans.each(fn(k, s) {
    if s.a < s.b {
      let at = refresh_at(k, s.at, s.row_depth)
      spans.push((k, { ..s, at }))
    }
  })
  guard !spans.is_empty() else { return None }
  spans.sort_by(fn(p, q) { order_cmp(p.1.at, q.1.at) })
  let from = refresh_spot(picked.from)
  let to = refresh_spot(picked.to)
  let down = spot_cmp(from, to) <= 0
  Some((spans, if down { spans[spans.length() - 1].0 } else { spans[0].0 }))
}

///|
/// What is picked now, as picked_now says it.
// kept across runs: said again as what is picked changes
let picked_now_said : Ref[@signals.Signal[WordsPicked?]] = Ref(@signals.signal(None, same=fn(a, b) { a == b }))

///|
/// What of the window's tree's words is picked with the pointer, followed as it changes: once the pointer has let it go
/// (a mouse's button let up, a finger lifted off it or its handle); None while it is dragged, where none is, or where
/// what is picked is an old view's.
pub fn picked_now() -> WordsPicked? {
  picked_now_said.val.get()
}

///|
/// What is picked in `v`'s selection scope (`words_picked`), followed as it changes; `None` if nothing is picked or the
/// selection belongs to another scope.
pub fn picked_now_in(v : @view.View) -> WordsPicked? {
  guard v.lent(words_picks) is Some(scope) else { return None }
  match picked_now() {
    Some(p) if p.within == scope => Some(p)
    _ => None
  }
}

///|
/// The currently selected words if and only if the selection belongs to `v`'s selection scope (`words_picked`); `""`
/// otherwise.
pub fn picked_words_in(v : @view.View) -> String {
  guard v.lent(words_picks) is Some(scope) else { return "" }
  guard tree_scope_live(scope) else { return "" }
  match picked.layer {
    TreeScope(_, within) if within == scope => selected_words()
    _ => ""
  }
}

///|
/// The currently selected words if the selection belongs to the scope covering window point `(x, y)` (or an old view);
/// `""` if the selection belongs to a different visible scope.
pub fn picked_words_at(x : Double, y : Double) -> String {
  match picked.layer {
    TreeScope(_, within) => {
      guard view_app.val is Some(tree) else { return "" }
      guard tree.view_of(within) is Some(v) && !v.shown_nowhere() && tree.allows(within) else { return "" }
      match tree.drop_at(x, y) {
        Some(OnNode(hit_id)) =>
          match tree.view_of(hit_id).bind(fn(hv) { hv.lent(words_picks) }) {
            Some(hit_scope) => return if hit_scope == within { selected_words() } else { "" }
            None => ()
          }
        _ => ()
      }
      let (rx, ry, rw, rh) = v.rect()
      let (bx0, by0, bx1, by1) = tree.seen_bounds(within)
      let x0 = dmax(rx, bx0)
      let y0 = dmax(ry, by0)
      let x1 = dmin(rx + rw, bx1)
      let y1 = dmin(ry + rh, by1)
      if x >= x0 && x < x1 && y >= y0 && y < y1 {
        selected_words()
      } else {
        ""
      }
    }
    OldLayer(_) => selected_words()
  }
}

///|
/// What is picked with the pointer told to what follows it (picked_now), as it changes and as the pointer lets it go.
fn picked_now_tell() -> Unit {
  picked_now_said.val.set(picked_now_worked())
}

///|
/// What picked_now says, worked out of what is picked.
fn picked_now_worked() -> WordsPicked? {
  guard picked.layer is TreeScope(_, within) && !picked.dragging else { return None }
  guard tree_scope_live(within) else { return None }
  guard picked_in_order() is Some((spans, end)) else { return None }
  guard picked_shown.get(end) is Some((ends_in, _, end_scope)) && end_scope == within else { return None }
  guard view_app.val is Some(tree) else { return None }
  guard tree.view_of(ends_in) is Some(end_v) && !end_v.shown_nowhere() && end_v.lent(words_picks) == Some(within) else { return None }
  let of : Array[String] = []
  let mut strays = 0
  for e in spans {
    let owner = match e.1.of {
      Some(o) => Some(o)
      None =>
        match picked_shown.get(e.0) {
          Some((_, Some(o), _)) => Some(o)
          _ => None
        }
    }
    match owner {
      Some(o) => if of.last() != Some(o) { of.push(o) }
      None => strays = strays + 1
    }
  }
  let from = refresh_spot(picked.from)
  let to = refresh_spot(picked.to)
  Some({
    text: selected_words(),
    of,
    within,
    strays,
    ends_in,
    ends_at_start: spot_cmp(from, to) > 0,
    first_at: spans[0].1.a,
    first_before: spans[0].1.text.clamped_view(end=spans[0].1.a).to_owned(),
    last_at: spans[spans.length() - 1].1.b,
    finger: picked.finger,
    made: picked.made,
  })
}

///|
/// Where what `p` says is picked ends (where the pointer let it go: dragged down, the right end of its last line;
/// dragged up, the left end of its first), as a piece of the node it ends in (`p.ends_in`) for what goes beside it
/// (View::beside's `piece`): the end's place on its line and the line's top and height, no wide, laid out as wide as
/// that node is as it is placed, in its own terms. None where its words hold no end of what is picked now (let go, or
/// another picked).
pub fn picked_end_piece(p : WordsPicked) -> (Double, Double) -> (Double, Double, Double, Double)? {
  fn(w, _h) {
    guard picked.made == p.made && view_app.val is Some(tree) else { return None }
    guard tree.view_of(p.ends_in) is Some(v) else { return None }
    let base = tree_key(v)
    guard picked_in_order() is Some((_, end)) && base == end else { return None }
    let (rs, look, set) = v.runs_set_now()
    guard !rs.is_empty() else { return None }
    let (_, lay, _) = view_runs_laid(rs, look, set, w, tree.words_scale_of(v.id()), kept=v.words_breaks_now(), tabular=v.words_tabular_now())
    let rects = selected_rects(base, lay)
    guard !rects.is_empty() else { return None }
    let down = spot_cmp(refresh_spot(picked.from), refresh_spot(picked.to)) <= 0
    let mut r = rects[0]
    for q in rects {
      let later = q.1 > r.1 || (q.1 == r.1 && q.0 > r.0)
      if later == down {
        r = q
      }
    }
    let shift = rich_shift_at(lay, r.1 + r.3 / 2.0, if v.words_centered_now() { w } else { -1.0 })
    Some((r.0 + shift + (if down { r.2 } else { 0.0 }), r.1, 0.0, r.3))
  }
}

///|
/// What a node offers to do with words a finger picked in what it holds, in the system's floating text menu
/// (picked_menu): its items for what is picked, each its words and what choosing it does.
// kept across runs: what each node lends (View::lends), let go with it
let picked_menus : @view.Lent[(WordsPicked) -> Array[(String, () -> Unit)]] = @view.Lent::new()

///|
/// Words a finger picked in what node `v` holds (the node they end in, or what holds it) offer the items `items` says
/// for them in the system's floating text menu over them, in its order, after its copy and select all
/// (@hostapi.text_menu_own: Android's text toolbar, its overflow where they do not fit; iOS's edit menu, paged; the
/// web's bar), each its words and what choosing it does (a quote of them, reading picked_now and letting them go with
/// picked_let_go; the message's share; its link copied), the menu then gone; none (picked across messages, where only
/// one's are quoted), nothing added; @hostapi.text_menu_own_most at most, the rest left out, and those whose words are
/// none. Asked, untracked, as the menu is put up and as what is picked changes. A mouse's pick offers none: no such
/// menu comes over it (what a page shows by it is its own). `v`.
pub fn picked_menu(v : @view.View, items : (WordsPicked) -> Array[(String, () -> Unit)]) -> @view.View {
  v.lends(picked_menus, items)
}

///|
/// What the system's floating text menu offers of the app's own over words a finger picked of the tree's (picked_menu),
/// in its order: what holds the node they end in says; none where nothing does, or where they are not a finger's, not
/// let go, or an old view's.
fn picked_menu_own() -> Array[(String, () -> Unit)] {
  guard picked.finger && picked_now_worked() is Some(p) && view_app.val is Some(tree) else { return [] }
  guard tree.view_of(p.ends_in) is Some(v) && v.lent(picked_menus) is Some(items) else { return [] }
  let all = @signals.untracked(fn() { items(p) }).filter(fn(i) { i.0 != "" && !i.0.contains("\n") })
  if all.length() > @hostapi.text_menu_own_most {
    all.truncate(@hostapi.text_menu_own_most)
  }
  all
}

///|
/// What is picked with the pointer let go, by a handler (a quote taken of it), as Ctx::selection_clear.
pub fn picked_let_go() -> Unit {
  select_none()
}

///|
/// Whether what holds node `v` draws its own bar over words a finger picked in it (picked_bar), the nearest that says it.
// kept across runs: what each node lends (View::lends), let go with it
let picked_bars : @view.Lent[Bool] = @view.Lent::new()

///|
/// Words a finger picked in what node `v` holds (the node they end in, or what holds it) have a bar of the page's own
/// over them (a chat's 引用, 复制, 全选: drawn by the page beside where they end, picked_now saying when), not the
/// system's floating text menu: none is put up over them. `v`.
pub fn picked_bar(v : @view.View) -> @view.View {
  v.lends(picked_bars, true)
}

///|
/// Whether words a finger picked of the tree's, let go of, end in what draws its own bar over them (picked_bar).
fn picked_bar_own() -> Bool {
  guard picked.finger && picked_now_worked() is Some(p) && view_app.val is Some(tree) else { return false }
  guard tree.view_of(p.ends_in) is Some(v) else { return false }
  v.lent(picked_bars) == Some(true)
}

///|
/// All the words of what a finger picked is in, picked, by a handler (a bar's 全选: the system's menu's select all,
/// finger_select_all's: a message's alone where its words are said whole of it).
pub fn picked_select_all() -> Unit {
  g().finger_select_all()
}
