// Laid out Medium with a sidebar to show (or beside the system's bars: rail_native.mbt), the wide frame's tape as nodes
// of the window's tree (mbui's view package, the way there's 4: from the outside in), made once:
//
//   - a row as wide as the tape, drawn moved as far as the tape has got (its offset, worked out as it is drawn from the
//     tape's move, committed once at its cause: tape_goes), holding the panels side by side as the tree lays them out:
//     the rail and the sidebar's column, the page's panel, a chat's side panel while it is open or closes (a node of its
//     own, `show`), each as wide as its binding says (tape_room: the window, the sidebar's width, the side panel's);
//   - in each panel, what it holds an old view (an island), built for the room the tree gives it; over each panel not in
//     use, a cover of the tree's: a tap or a secondary press brings it over, a drag across pulls it with the finger and,
//     let go, over or back, a finger held still on it handed to the words under it (the long press's), each at its
//     event's moment; what it says a screen reader reads, its press of it the same as a tap, at that press's moment
//     (tape_cover); on the one in use, a finger's swipe across brings what is beside it over, whatever holds it not
//     taking it its own way first (tape_swipes);
//   - over the panels, an old view taking presses where it draws them alone: the edges dragged (tape_edge).
//
// The tape's move is a trajectory committed at its cause (tape_moves_from): where everything was at that moment,
// worked out of the trajectory before it alone (never of a state already changed), and where it all goes, as the
// change has it. What brings a panel over: a cover pressed, back, what is shown in the page (show_page, bring_page:
// wide.tape_ask), a chat's side panel opened or closed, another chat come, another place's sidebar (tape_settle, one
// change at its moment); the page waited for till the core has given what it shows or its wait is over (the same as
// what the page's panel shows: page_wait.mbt, at its causes, the one before kept by the stack meanwhile). What the
// window, an edge dragged or the keyboard does to where things go is no move: there at once. Its end is a moment of the
// timeline: the panel closed while in use let go there (side_left).
//
// A page pushed over the page's own stack (Nav::push_over) slides in at its causes: the stack held by the page's panel
// (tape_page.mbt: @ui.nav_flat_view, Nav::held_by), each of its pages a node of its own. Still the old frame's (the way
// there): what the side panels hold (their islands). A passage picked brings the page over as it is picked
// (tape_page.mbt's tape_pick_said). The edges and back are nodes of the
// tree's (tape_side_edge, tape_panel_edge; wide_takes_back, wide_back_step).

///|
/// The tape's move, committed at its cause: its way (from 0 as it set out to 1), and of each thing it moves where it was
/// then and where it goes: how far the tape is moved (the one in use: not a finger's pull, added as it is drawn), how wide
/// the page's panel is, where the sidebar's column ends (where the page's panel starts on the tape), how far behind each
/// panel is (Side, Page, Panel: 0 in use, 1 its ground a step darker). Whether the tape is at rest (its way's end come),
/// what is due at that end; the side panel last open (closed while in use: shown, as it was, while the tape moves off it);
/// the finger pulling a panel over (where it went down across, the window's; where and when it was last, how fast it went
/// there, px/s).
priv struct TapeGoes {
  way : @motion.Way
  x : FixedArray[Double]
  page : FixedArray[Double]
  col : FixedArray[Double]
  behind : FixedArray[Double]
  rest : @signals.Signal[Bool]
  mut end_due : () -> Unit
  last_side : @signals.Signal[SideOf?]
  /// told as a move is committed or where things go is put (what works out where they are from it reads it)
  said : @signals.Signal[Int]
  mut pull_x0 : Double
  /// the window's tree's node holding the tape, while it does (what its moves and its room are worked out of), and the
  /// side panel open on the page on top
  mut node : @view.View?
  /// its row, the sidebar's column, the page's panel's column, as made (for what is asked of them: tape_seen)
  parts : Array[@view.View]
  mut panel_of : () -> SideOf?
  mut shown_side_of : (() -> SideOf?)?
  mut room_of : (() -> TapeRoom)?
  /// whether the core has given what the page shows of a page (sfapp's pane_ready), waited for that long at most
  mut ready : (Page) -> Bool
  mut most : Double
}

///|
// kept across runs: put back as a run begins (tape_goes_reset)
let tape_goes : TapeGoes = {
  way: @motion.Way::new(1.0),
  x: FixedArray::make(2, 0.0),
  page: FixedArray::make(2, 0.0),
  col: FixedArray::make(2, 0.0),
  behind: FixedArray::make(6, 0.0),
  rest: @signals.signal(true, same=fn(a, b) { a == b }),
  end_due: fn() {  },
  last_side: @signals.signal(None, same=fn(a, b) { a == b }),
  said: @signals.signal(0),
  pull_x0: 0.0,
  node: None,
  parts: [],
  panel_of: fn() { None },
  shown_side_of: None,
  room_of: None,
  ready: fn(_) { true },
  most: 0.0,
}

///|
/// The chats' pages on the tape made as nodes whole, by their stack's serial: each its chat and the source its page reads
/// by (chat_page_made's), its side panel made in that and kept with it (tape_side_node), let go with it.
// kept across runs: let go of by tape_goes_reset
let tape_chat_entries : Map[Int, (ChatRef, Source)] = Map([])

///|
/// Told as tape_chat_entries changes.
// kept across runs: a counter
let tape_chat_entries_rev : @signals.Signal[Int] = @signals.signal(0, same=fn(a, b) { a == b })

///|
fn tape_goes_reset() -> Unit {
  tape_chat_entries.clear()
  tape_chat_entries_rev.set(tape_chat_entries_rev.untracked() + 1)
  tape_bars.clear()
  (tape_goes.end_due)()
  tape_goes.end_due = fn() {  }
  tape_page_wait.reset()
  tape_goes.way.put(1.0)
  for a in [tape_goes.x, tape_goes.page, tape_goes.col, tape_goes.behind] {
    for i in 0..<a.length() {
      a[i] = 0.0
    }
  }
  tape_goes.rest.set(true)
  tape_goes.last_side.set(None)
  tape_goes.pull_x0 = 0.0
  tape_goes.node = None
  tape_goes.parts.clear()
  tape_goes.panel_of = fn() { None }
  tape_goes.shown_side_of = None
  tape_goes.room_of = None
}

///|
/// Off the tape (the frame's, frame.mbt): nothing asked of it, no finger on it, its move over.
fn tape_off() -> Unit {
  wide.tape_ask.set(None)
  wide.tape_chat.set("")
  wide.tape_panel.set("")
  wide.tape_pull.set(None)
  wide.tape_drag.set(0.0)
  wide.tape_backing = false
  wide.tape_last_side = None
}

///|
/// Whether the signed-in frame with workspace `w` in view, a window `width` wide, is the tape (tape_view): laid out Medium
/// (or beside the system's bars: an iPhone Duo's, rail_native.mbt), with a sidebar to show (not a device waiting to be
/// confirmed in the workspace's safe mode, nor 连接 or 用量, a page across the pane).
pub fn tape_holds(src : Source, w : Workspace, width : Double) -> Bool {
  let gated = lit_place() != "settings" && @settings.lock_waiting(settings_core(src, w), w.id)
  let bare = place_bare(lit_place())
  !gated && !bare && (@sf.layout(width) is Medium || @sf.native_on() || @sf.native_able())
}

///|
/// What the tape is laid out by, a window `ww` by `wh`: what the window leaves beside the column of the system's glass
/// at its right (`tw`: @sf.side_clear) and that column (`under`: the last panel's ground goes on under it); the sidebar's
/// width and the column it is in (the rail's, the sidebar's, 6 from the window, 8 from the page: where the page's panel
/// starts), as tape_side_w has it now; the bars' room at the top and the foot; the panels' top and height (6 in from the
/// bars); the page's panel's width with the side panel open (`open`) or not, and the side panel's while it shows
/// (`shown`: open, or closing).
#derive(Eq)
priv struct TapeRoom {
  tw : Double
  under : Double
  s : Double
  col : Double
  top : Double
  foot : Double
  panel_top : Double
  panel_h : Double
  main_to : Double
  panel_w : Double
}

///|
fn tape_room(ww : Double, wh : Double, ime : Double, open : Bool, shown : Bool) -> TapeRoom {
  let under = @sf.native_clear()
  let tw = ww - under
  let s = tape_side_w(tw, wide.side_w.get())
  // (on the tape apart from the page: its panel 6 in from the window's edge, 8 from the page's: tape_apart; as much
  // wider as its rail shows more there, its places in the panel's corners concentric with it: rail_open_tape)
  let col = rail_left() + s + bar_in_now() + bar_gap_now() + rail_more()
  let bars = @ui.system_bars()
  let top = bars.top
  // (down the side, the cards to the column's own foot, the home indicator's line under their ground: cards_foot; the
  // soft keyboard up, the window ends where it starts: the cards end on it from its first point on. A touch device's
  // navigation bar over the app, edge to edge, the cards' ground under it to the window's foot, what is in them clear
  // of it; not a window's on a computer, whose foot is its own; nor an iPhone Duo's upright, the system's tabs across
  // its foot in that room: the user, 2026-10-28)
  let edge = @sf.native_side() || (@sf.native_input() is Finger && !@sf.native_on())
  let foot = if @sf.native_side() {
    cards_foot
  } else if edge {
    dmin(bars.bottom, cards_foot + ime)
  } else {
    bars.bottom
  }
  let page_h = dmax(0.0, wh - top - foot)
  let panel_top = top + bar_in_now()
  let panel_h = dmax(0.0, page_h - 2.0 * bar_in_now())
  let main_to = if open && !@sf.native_side() {
    dmax(0.0, tw - tape_shows_left() - tape_shows_right() - 2.0 * bar_gap_now())
  } else {
    // The system's trailing column already separates the active pane from what
    // peeks beside it. Do not reserve a second strip of chat width for details.
    tape_one_beside(tw, tape_shows_left())
  }
  let panel_w = if shown { tape_panel_w(tw) } else { 0.0 }
  { tw, under, s, col, top, foot, panel_top, panel_h, main_to, panel_w }
}

///|
/// The side panel shown on the tape: the one open on the page on top, else the one last open while it closes (what it
/// showed kept as it goes: side_leaving).
fn tape_shown_side_uncached() -> SideOf? {
  match (tape_goes.panel_of)() {
    Some(s) => Some(s)
    None =>
      match tape_goes.last_side.get() {
        Some(s) if side_leaving(s.key()) is Some(_) => Some(s)
        _ => None
      }
  }
}

///|
fn tape_shown_side() -> SideOf? {
  match tape_goes.shown_side_of {
    Some(f) => f()
    None => tape_shown_side_uncached()
  }
}

///|
/// The tape's room now (tape_room), its window as the tree's frames give it.
fn tape_room_now_uncached() -> TapeRoom {
  let (ww, wh, ime) = match tape_goes.node {
    Some(v) => {
      let (w, h) = v.window()
      (w, h, v.keyboard_inset())
    }
    None => (0.0, 0.0, 0.0)
  }
  tape_room(ww, wh, ime, (tape_goes.panel_of)() is Some(_), tape_shown_side_uncached() is Some(_))
}

///|
fn tape_room_now() -> TapeRoom {
  match (tape_goes.node, tape_goes.room_of) {
    (Some(_), Some(f)) => f()
    _ => tape_room_now_uncached()
  }
}

///|
/// Where what the tape moves goes, as the state is now (`r`, the one in use): how far the tape is moved (no finger's
/// pull), how wide the page's panel is, where the sidebar's column ends, how far behind each panel is.
#derive(Eq)
priv struct TapeTo {
  x : Double
  page : Double
  col : Double
  behind : FixedArray[Double]
}

///|
fn tape_to_of(r : TapeRoom) -> TapeTo {
  let at = tape_at(r.tw, r.col, r.main_to, r.panel_w)
  let p = wide.tape_at.get()
  {
    x: tape_x_of(at, p),
    page: r.main_to,
    col: r.col,
    behind: [Side, Page, Panel].map(fn(q) { if q == p { 0.0 } else { 1.0 } }) |> FixedArray::from_array,
  }
}

///|
/// `a`'s value (from, to) as far as the tape's move has got at `t`.
fn tape_along(a : FixedArray[Double], i : Int, t : Double) -> Double {
  let from = a[2 * i]
  from + (a[2 * i + 1] - from) * tape_goes.way.value_at(t)
}

///|
/// Where the sidebar's column ends at `t`, how wide the page's panel is, how far behind panel `p` is, how far the tape
/// is moved (its move's alone: tape_x_at adds a finger's pull), as the move committed has them.
fn tape_col_at(t : Double) -> Double {
  tape_along(tape_goes.col, 0, t)
}

///|
fn tape_page_at(t : Double) -> Double {
  tape_along(tape_goes.page, 0, t)
}

fn tape_col_in(n : @view.View) -> Double {
  tape_goes.said.get() |> ignore
  if tape_goes.col[0] == tape_goes.col[1] {
    return tape_goes.col[1]
  }
  tape_goes.way.said()
  tape_col_at(n.drawn_while(fn(t) { tape_goes.way.goes_at(t) }))
}

///|
fn tape_page_in(n : @view.View) -> Double {
  tape_goes.said.get() |> ignore
  if tape_goes.page[0] == tape_goes.page[1] {
    return tape_goes.page[1]
  }
  tape_goes.way.said()
  tape_page_at(n.drawn_while(fn(t) { tape_goes.way.goes_at(t) }))
}

///|
fn tape_behind_in(p : TapePane, n : @view.View) -> Double {
  if wide.tape_pull.get() is Some(_) {
    return tape_behind_at(p, @double.infinity)
  }
  tape_goes.said.get() |> ignore
  let i = tape_index(p)
  if tape_goes.behind[2 * i] == tape_goes.behind[2 * i + 1] {
    return tape_goes.behind[2 * i + 1]
  }
  tape_goes.way.said()
  tape_along(tape_goes.behind, i, n.drawn_while(fn(t) { tape_goes.way.goes_at(t) }))
}

///|
/// How much narrower than it is drawn in node `n` a chat page's column in the page's panel is laid out, and how far across
/// it is moved (chat_page_made's `narrower`, laid_across): while the tape's move takes the page's panel to another width
/// (a side panel opened or closed beside it, another place's sidebar), as at the narrower of where it set off and where
/// it goes; at rest none, laid out as wide as it is.
fn tape_page_narrower(n : @view.View) -> @sfbase.ColumnLaid {
  tape_goes.said.get() |> ignore
  if tape_goes.page[0] == tape_goes.page[1] {
    let at = tape_goes.page[1]
    return { by: 0.0, across: 0.0, laid: at, toward: at, toward_by: 0.0 }
  }
  let t = tape_drawn_at(n)
  if t == @double.infinity || !tape_goes.way.goes_at(t) {
    let at = tape_page_at(t)
    return { by: 0.0, across: 0.0, laid: at, toward: at, toward_by: 0.0 }
  }
  laid_across(tape_page_at(t), dmin(tape_goes.page[0], tape_goes.page[1]), dmax(tape_goes.page[0], tape_goes.page[1]))
}

///|
fn tape_behind_at(p : TapePane, t : Double) -> Double {
  match wide.tape_pull.get() {
    Some(pull_target) => {
      let ends = tape_ends(tape_room_now())
      let cur = wide.tape_at.get()
      let span = tape_x_of(ends, pull_target) - tape_x_of(ends, cur)
      let pulled = tape_pull_clamp(ends, pull_target, wide.tape_drag.get())
      let frac = if span.abs() > 0.5 { dmax(0.0, dmin(1.0, pulled / span)) } else { 0.0 }
      if p == cur {
        frac
      } else if p == pull_target {
        1.0 - frac
      } else {
        1.0
      }
    }
    None => tape_along(tape_goes.behind, tape_index(p), t)
  }
}

///|
fn tape_index(p : TapePane) -> Int {
  match p {
    Side => 0
    Page => 1
    Panel => 2
  }
}

///|
/// Where the tape has each of its panels in use, as the state is now (tape_at): what a finger's pull is held within.
fn tape_ends(r : TapeRoom) -> (Double, Double, Double) {
  tape_at(r.tw, r.col, r.main_to, r.panel_w)
}

///|
/// How far the tape is moved at `t`: where its move committed has got, and as far as a finger pulls another over
/// (no further than where that has it in use).
fn tape_x_at(r : TapeRoom, t : Double) -> Double {
  let pulled = match wide.tape_pull.get() {
    Some(p) => tape_pull_clamp(tape_ends(r), p, wide.tape_drag.get())
    None => 0.0
  }
  tape_along(tape_goes.x, 0, t) + pulled
}

///|
/// The moment the tape is drawn at by what reads it in node `n`: the frame's while its move goes, else after it (at
/// rest: the clock read no more).
fn tape_drawn_at(n : @view.View) -> Double {
  tape_goes.said.get() |> ignore
  tape_goes.way.said()
  n.drawn_while(fn(t) { tape_goes.way.goes_at(t) })
}

///|
/// The tape's move committed at `at` (its cause's moment) as `change` says (another brought over, a pull let go back,
/// another place's sidebar): each thing it moves from where the move before had it then (and the tape where a finger
/// had pulled it), to where the state `change` leaves has it; one way, as long as the furthest goes (a Move: @ui.move_ms),
/// its end a moment of the tree's timeline.
fn tape_moves_from(at : Double, change : () -> Unit, velocity_px? : Double = 0.0) -> Unit {
  @signals.untracked(fn() {
    let x = tape_x_at(tape_room_now(), at)
    let page = tape_page_at(at)
    let col = tape_col_at(at)
    let behind = [tape_behind_at(Side, at), tape_behind_at(Page, at), tape_behind_at(Panel, at)]
    let old_vx = if tape_goes.way.goes_at(at) {
      (tape_goes.x[1] - tape_goes.x[0]) * tape_goes.way.at(at).1
    } else {
      0.0
    }
    change()
    let to = tape_to_of(tape_room_now())
    tape_goes.x[0] = x
    tape_goes.x[1] = to.x
    tape_goes.page[0] = page
    tape_goes.page[1] = to.page
    // (the chat's page going to another width with the tape: what it lays out by its width set off on that way too, as
    // a side panel sliding beside it does (panel_node's), @sfbase.column_sets_off)
    if (to.page - page).abs() > 0.5 {
      match app.nav.top() {
        Chat(r) => @sfbase.column_sets_off(r.station + "\u{1}" + r.session)
        _ => ()
      }
    }
    tape_goes.col[0] = col
    tape_goes.col[1] = to.col
    for i in 0..<3 {
      tape_goes.behind[2 * i] = behind[i]
      tape_goes.behind[2 * i + 1] = to.behind[i]
    }
    let far = dmax(dmax((to.x - x).abs(), (to.page - page).abs()), (to.col - col).abs())
    let v_phys = if velocity_px != 0.0 { velocity_px } else { old_vx }
    let dx = to.x - x
    let v_norm = if dx.abs() > 1.0 { dmax(-6.0, dmin(6.0, v_phys / dx)) } else { 0.0 }
    tape_goes.way.put(0.0)
    tape_goes.way.go(1.0, @motion.moved(over=far), velocity=v_norm, at~)
    tape_said()
    tape_rest_at(tape_goes.way.ends_at())
  })
}

///|
/// Where what the tape moves goes changed with no cause of a move (the window, an edge dragged, the keyboard, a side
/// panel shown as its chat's view came): there at once, the move going on (if one goes) for the rest of it.
fn tape_put(to : TapeTo) -> Unit {
  let put = fn(a : FixedArray[Double], i : Int, v : Double) {
    if a[2 * i + 1] != v {
      a[2 * i] = v
      a[2 * i + 1] = v
    }
  }
  put(tape_goes.x, 0, to.x)
  put(tape_goes.page, 0, to.page)
  put(tape_goes.col, 0, to.col)
  for i in 0..<3 {
    put(tape_goes.behind, i, to.behind[i])
  }
  tape_said()
}

///|
/// What is committed of the tape's move told (tape_moves_from, tape_put).
fn tape_said() -> Unit {
  tape_goes.said.set(tape_goes.said.untracked() + 1)
}

///|
/// Where what the tape moves goes, as committed (tape_moves_from, tape_put).
fn tape_committed() -> TapeTo {
  {
    x: tape_goes.x[1],
    page: tape_goes.page[1],
    col: tape_goes.col[1],
    behind: [tape_goes.behind[1], tape_goes.behind[3], tape_goes.behind[5]] |> FixedArray::from_array,
  }
}

///|
/// The tape at rest from `end` (-1: at once, its move none: motion reduced), what is due then done then: the side panel
/// closed while in use let go once the tape is at the page (tape_left).
fn tape_rest_at(end : Double) -> Unit {
  (tape_goes.end_due)()
  tape_goes.end_due = fn() {  }
  match tape_goes.node {
    Some(n) if end >= 0.0 => {
      tape_goes.rest.set(false)
      tape_goes.end_due = n.at_moment(end, fn() {
        tape_goes.rest.set(true)
        tape_left()
      })
    }
    _ => {
      tape_goes.rest.set(true)
      tape_left()
    }
  }
}

///|
/// The side panel closed while in use, shown as it was while the tape moved off it, let go once the tape rests at the
/// page (panel.mbt side_left).
fn tape_left() -> Unit {
  @signals.untracked(fn() {
    if (tape_goes.panel_of)() is None && tape_goes.rest.get() && wide.tape_at.get() == Page {
      match tape_goes.last_side.get() {
        Some(s) => side_left(s.key())
        None => ()
      }
    }
  })
}

///|
/// `p` brought over at `at`, from where the tape is drawn then: no longer what a finger pulled (if it was), the field of
/// the page no more in use letting go of the keyboard (what shows of it takes nothing).
fn tape_to(p : TapePane, at : Double, velocity_px? : Double = 0.0) -> Unit {
  tape_moves_from(
    at,
    fn() {
      wide.tape_at.set(p)
      if wide.tape_pull.get() == Some(p) {
        wide.tape_pull.set(None)
        wide.tape_drag.set(0.0)
        wide.tape_backing = false
      }
    },
    velocity_px~,
  )
  if p != Page {
    match tape_goes.node {
      Some(v) => v.focus_let_go()
      None => ()
    }
  }
}

///|
/// A key that asks for what is in the page (its composer: Space, 按空格输入) pressed at `at` while the tape holds the
/// window with the page behind: the page brought over at that moment, as a press on what shows of it brings it
/// (tape_cover), what the key asked given it as the page is in use (Ctx::focus_field's ask kept till then).
pub fn tape_page_for_key(at : Double) -> Unit {
  if wide.tape.get() && wide.tape_at.get() != Page {
    wide.tape_ask.set(Some(Page))
    tape_take_ask(at) |> ignore
  }
}

///|
/// Whether the page's panel shows the page on top, as it does once the core has given what it shows or its wait is over:
/// one put in place as tape_page_wait says, one pushed over the one in place as the stack says (Nav::top_waits: its
/// wait the stack's, Nav::held_by), each at its causes.
fn tape_page_ready() -> Bool {
  tape_page_wait.shows_top() && !app.nav.top_waits()
}

///|
/// What was asked of the tape (wide.tape_ask: a cover pressed, back, what is shown in the page), as of `at`: the page
/// once it has what was put on it (as a phone's page slides in once it has what it shows, not sliding over with the page
/// before on it), asked still till then; the side panel only while one is open. True where the tape set out.
fn tape_take_ask(at : Double) -> Bool {
  @signals.untracked(fn() {
    match wide.tape_ask.get() {
      Some(Page) if wide.tape_at.get() != Page && !tape_page_ready() => false
      Some(p) => {
        wide.tape_ask.set(None)
        if p != wide.tape_at.get() && !(p == Panel && (tape_goes.panel_of)() is None) {
          tape_to(p, at)
          true
        } else {
          false
        }
      }
      None => false
    }
  })
}

///|
/// The one pulled over let go at `at` (`v`: the finger's speed across as it left, px/s): brought over when landing past
/// a fifth of the way (tape_pull_far at most) or flung toward it, else back to the one in use; on from where the finger
/// left the tape.
fn tape_let_go(p : TapePane, v : Double, at : Double) -> Unit {
  @signals.untracked(fn() {
    let ends = tape_ends(tape_room_now())
    let span = tape_x_of(ends, p) - tape_x_of(ends, wide.tape_at.get())
    if tape_goes_over(tape_pull_clamp(ends, p, wide.tape_drag.get()), span, v) {
      tape_to(p, at, velocity_px=v)
    } else {
      tape_moves_from(
        at,
        fn() {
          wide.tape_pull.set(None)
          wide.tape_drag.set(0.0)
          wide.tape_backing = false
        },
        velocity_px=v,
      )
    }
  })
}

///|
/// Back (`sign = 1.0`) or forward (`sign = -1.0`) on the tape bringing `p` over, step by step as the gesture goes: the
/// tape in its hand from where it began, moved as far as the gesture has come; let go, over or back as a finger's is;
/// called off, back where it was. Each at its step's moment.
fn tape_gesture(p : TapePane, step : @ui.BackStep, sign : Double) -> Unit {
  let now = match @ui.tree_cause() {
    Some(t) => t
    None =>
      match tape_goes.node {
        Some(v) => v.cause_at()
        None => 0.0
      }
  }
  match step {
    Began(x, t) =>
      if wide.tape_pull.get() is None {
        wide.tape_pull.set(Some(p))
        wide.tape_drag.set(0.0)
        wide.tape_backing = true
        wide.tape_back_x0 = x
        wide.tape_back_last = (x, t)
        wide.tape_back_v = 0.0
      }
    Moved(x, t) | LetGo(x, t) =>
      if wide.tape_backing {
        let (x1, t1) = wide.tape_back_last
        // (let go where it last moved to, as a system's back always says it, later: the speed it last moved at, none
        // where it stood still there longer than a pause first; never worked out of that place said again)
        if step is LetGo(_, _) && x == x1 {
          if t - t1 > @view.tracker_gap_ms {
            wide.tape_back_v = 0.0
          }
        } else if t > t1 {
          wide.tape_back_v = sign * (x - x1) / (t - t1) * 1000.0
          wide.tape_back_last = (x, t)
        }
        wide.tape_drag.set(sign * (x - wide.tape_back_x0))
        if step is LetGo(_, _) {
          wide.tape_backing = false
          match wide.tape_pull.get() {
            Some(q) => tape_let_go(q, wide.tape_back_v, t)
            None => ()
          }
        }
      }
    CalledOff =>
      if wide.tape_backing {
        tape_moves_from(now, fn() {
          wide.tape_pull.set(None)
          wide.tape_drag.set(0.0)
          wide.tape_backing = false
        })
      }
    Back =>
      if wide.tape_backing {
        match wide.tape_pull.get() {
          Some(q) => tape_to(q, now)
          None => ()
        }
      } else {
        wide.tape_ask.set(Some(p))
        tape_take_ask(now) |> ignore
      }
  }
}

///|
/// Whether back is the wide frame's now (the tape's, or the frame's off it: its node, tape_view, pane_view), as the shell
/// has it (wide_back): somewhere to go (a panel brought over, a page popped, another place's sidebar back to the chats',
/// the entry before in the history, what is over the whole window put away). All it reads is told as it changes (the
/// stack, the panel in use, the history's entries: sfbase's history_said).
pub fn wide_takes_back(src : Source) -> Bool {
  wide_back(src) is Some(_)
}

///|
/// Whether forward is the wide frame's now (the tape's, or the frame's off it: tape_view, pane_view).
pub fn wide_takes_forward(src : Source) -> Bool {
  wide_forward(src) is Some(_)
}

///|
/// What back or forward on the wide frame does, as it is chosen: a panel of the tape brought over, followed as the
/// gesture goes (tape_gesture); a one-shot navigation step done once as the gesture goes through; nothing.
priv enum WideBack {
  Follows(TapePane)
  Once(() -> Unit)
  Nothing
}

///|
/// What back on the wide frame does now.
fn wide_back_what(src : Source) -> WideBack {
  match tape_back_to() {
    Some(p) => Follows(p)
    None =>
      match wide_back(src) {
        Some(f) => Once(f)
        None => Nothing
      }
  }
}

///|
/// What forward on the wide frame does now.
fn wide_forward_what(src : Source) -> WideBack {
  match tape_forward_to() {
    Some(p) => Follows(p)
    None =>
      match wide_forward(src) {
        Some(f) => Once(f)
        None => Nothing
      }
  }
}

///|
/// A step of back on the wide frame (its node's: tape_view's, pane_view's), at its moment: what it does chosen as a gesture begins, the whole
/// gesture's (`held`, while it goes), or as a back with no gesture comes (wide_back_what); each step to that alone,
/// whatever changed meanwhile.
fn wide_back_step(src : Source, held : Ref[WideBack?], hint : BackHint, step : @ui.BackStep) -> Unit {
  let what = match (step, held.val) {
    (Began(_, _), _) => {
      let w = wide_back_what(src)
      held.val = Some(w)
      w
    }
    (_, Some(w)) => w
    (Back, None) => wide_back_what(src)
    _ => return
  }
  if step is (LetGo(_, _) | CalledOff | Back) {
    held.val = None
  }
  match what {
    Follows(p) => tape_gesture(p, step, 1.0)
    Once(f) => if hint.step(step) { f() }
    Nothing => ()
  }
}

///|
/// A step of forward on the wide frame (tape_view's, pane_view's), at its moment: what it does chosen as a gesture
/// begins, the whole gesture's (`held`, while it goes); each step to that alone, whatever changed meanwhile.
fn wide_forward_step(src : Source, held : Ref[WideBack?], hint : BackHint, step : @ui.BackStep) -> Unit {
  let what = match (step, held.val) {
    (Began(_, _), _) => {
      let w = wide_forward_what(src)
      held.val = Some(w)
      w
    }
    (_, Some(w)) => w
    (Back, None) => wide_forward_what(src)
    _ => return
  }
  if step is (LetGo(_, _) | CalledOff | Back) {
    held.val = None
  }
  match what {
    Follows(p) => tape_gesture(p, step, -1.0)
    Once(f) => if hint.step(step, forward=true) { f() }
    Nothing => ()
  }
}

///|
/// The wide frame's node taking back let go at `at` (back no longer its: the tree tells it nothing more of a gesture
/// going on to it): the gesture it held let go, a panel of the tape it pulled over back where it was in use, from there.
fn wide_back_left(held : Ref[WideBack?], hint : BackHint, at : Double) -> Unit {
  guard held.val is Some(_) else { return }
  held.val = None
  hint.clear()
  // (the tape itself let go with it: nothing of it moves, what it held let go as the tape is: tape_view)
  if wide.tape_backing && tape_goes.node is Some(_) {
    tape_moves_from(at, fn() {
      wide.tape_pull.set(None)
      wide.tape_drag.set(0.0)
      wide.tape_backing = false
    })
  }
}

///|
/// The tape as of `at`, one change at its moment (tape_view's reaction): what the shown chat's side panel and its chat
/// ask of it (the panel opened beside the same chat as before, its view come: the panel comes over; closed while in use,
/// the page; another chat shown while a panel was in use: its page, not the panel open in it: pengxiao, 2026-10-25, the
/// chat in the middle is what one comes to; a panel shown as its view comes is not one opened), then what was asked
/// taken (tape_take_ask); with no move set out, where things go changed by what is no cause of a move put there at once.
fn tape_settle(chat : String, open : String, known : Bool, at : Double) -> Unit {
  @signals.untracked(fn() {
    if wide.tape_ask.get() is None {
      if chat != wide.tape_chat.get() {
        if wide.tape_at.get() == Panel {
          wide.tape_ask.set(Some(Page))
        }
      } else if open != "" &&
        open != wide.tape_panel.get() &&
        wide.tape_panel.get() != tape_unknown &&
        known &&
        side_under_chat.val != chat {
        // (not a panel opened under the whole window only for what goes there: panel.mbt's side_under_chat)
        wide.tape_ask.set(Some(Panel))
      } else if open == "" && known && wide.tape_at.get() == Panel {
        wide.tape_ask.set(Some(Page))
      }
    }
    wide.tape_chat.set(chat)
    wide.tape_panel.set(if known { open } else { tape_unknown })
    if !tape_take_ask(at) {
      let to = tape_to_of(tape_room_now())
      if to != tape_committed() {
        tape_put(to)
      }
    }
  })
}

///|
/// Chat `r`'s side panel asked to show a tab (opened or brought to the front) while it was open already (another tab, or
/// this one, the page slid back over it): on the tape, with `r` shown, the panel brought over, as tape_settle does as
/// it first opens (it tells only the panel's being open, which this does not change: a card pressed in the chat did
/// nothing, the panel standing under the system's bars at a Duo's side).
fn tape_bring_side_if_hidden(r : ChatRef) -> Bool {
  let shown = match app.nav.top() {
    Chat(top) | History(top, _, _) => chat_key(top) == chat_key(r)
    _ => false
  }
  if shown && wide.tape.untracked() && wide.tape_at.untracked() != Panel {
    wide.tape_ask.set(Some(Panel))
    true
  } else {
    false
  }
}

///|
fn tape_bring_side(r : ChatRef) -> Unit {
  tape_bring_side_if_hidden(r) |> ignore
}

///|
/// Whether a chat's side panel on the tape is out of sight: another panel in use, at rest, none pulling it over
/// (side_screen_page_node: its screen let go of meanwhile), followed.
fn tape_side_hidden() -> Bool {
  wide.tape.get() && wide.tape_at.get() != Panel && wide.tape_pull.get() != Some(Panel) && tape_goes.rest.get()
}

///|
/// The page the tape is laid out for: the stack's top, under what is over the whole window (a station's screen, its
/// terminal, a drive's text read or its film played: sfapp's wide_page), which leaves the tape as it was, back to it as
/// it was left (as the pane's: pane_shows), so a screen's 全屏 from a chat's side panel goes back to that panel.
fn tape_top() -> Page {
  let pages = app.nav.pages()
  for i = pages.length() - 1; i >= 0; i = i - 1 {
    if !(pages[i] is (Screen(_) | Terminal(_) | DriveRead(_) | DrivePlay(_))) {
      return pages[i]
    }
  }
  app.nav.top()
}

///|
/// The tape in node `v` (the signed-in shell's, filling the window: sfapp's taped_shell), in the workspace in view (its
/// file's head): the page brought over once `ready` says the core has given what it shows of the page put on it, `most`
/// ms after it was put there at the latest.
pub fn tape_view(v : @view.View, src : Source, ready~ : (Page) -> Bool, most~ : Double) -> Unit {
  wide.tape.set(true)
  board_frame_src.val = Some(src)
  // (a workspace come in view that shows its chats as the board: its page's panel brought over, the board what it
  // holds; at once as the frame is made, on the tape's way as another workspace comes in view)
  let board_ws = Ref("")
  v.reacts(fn() { @sfbase.workspace_in_view(src).0.map(fn(w) { w.id }).unwrap_or("") }, fn(ws) {
    let first = board_ws.val == ""
    board_ws.val = ws
    guard ws != "" && @signals.untracked(fn() { @sfbase.board_on_of(src, ws) }) else { return }
    guard app.nav.depth() == 1 && app.nav.top() is Home else { return }
    if first {
      wide.tape_at.set(Page)
    } else if wide.tape_at.untracked() != Page {
      wide.tape_ask.set(Some(Page))
    }
  })
  tape_goes.node = Some(v)
  tape_goes.ready = ready
  tape_goes.most = most
  let panel_raw = fn() {
    match @sfbase.workspace_in_view(src).0 {
      Some(w) => side_open_for(src, w, tape_top())
      None => None
    }
  }
  let panel_c = @signals.computed(fn(_) { panel_raw() }, same=fn(a, b) { a == b })
  let panel_of = fn() { if @signals.active_sub() is None { panel_raw() } else { panel_c.get() } }
  let shown_raw = fn() {
    match panel_of() {
      Some(s) => Some(s)
      None =>
        match tape_goes.last_side.get() {
          Some(s) if side_leaving(s.key()) is Some(_) => Some(s)
          _ => None
        }
    }
  }
  let shown_c = @signals.computed(fn(_) { shown_raw() }, same=fn(a, b) { a == b })
  let shown_of = fn() { if @signals.active_sub() is None { shown_raw() } else { shown_c.get() } }
  let room_raw = fn() {
    let (w, h) = v.window()
    tape_room(w, h, v.keyboard_inset(), panel_of() is Some(_), shown_of() is Some(_))
  }
  let room_c = @signals.computed(fn(_) { room_raw() }, same=fn(a, b) { a == b })
  let room_of = fn() { if @signals.active_sub() is None { room_raw() } else { room_c.get() } }
  tape_goes.panel_of = panel_of
  tape_goes.shown_side_of = Some(shown_of)
  tape_goes.room_of = Some(room_of)
  // (where the system lays out the app's tabs, its bars handed what the tape's frame has for them each frame it shows:
  // rail_native.mbt nav_frame)
  nav_hold(src)
  // (the window's buttons, a Mac's, as far lower as its panels stand under the window's top: as far below the panel
  // showing at the window's left as they are in from the window's side, the side panel's edge out of the window there;
  // the user, 2026-11-09: 红绿灯位置不对. Back where they were as the tape goes; each way moved, not put there: 不要瞬移.)
  @hostapi.window_buttons_down(bar_in_now(), @ui.move_ms(bar_in_now()))
  // (at rest where it is in use as it is made: no move from wherever another frame left it)
  tape_goes.way.put(1.0)
  tape_goes.rest.set(true)
  tape_put(tape_to_of(tape_room_now()))
  v.owns(fn() {
    // (left for the frame off the tape, at this change's moment: the block closes from where the tape had it then, its
    // column and how far the tape was moved (with a finger's pull), pane_view)
    let at = v.cause_at()
    let r = tape_room_now()
    fold_goes.left_tape = Some(fold_look_tape(r.s, tape_col_at(at), r.top, r.foot, x=tape_x_at(r, at)))
    (tape_goes.end_due)()
    tape_goes.end_due = fn() {  }
    tape_goes.node = None
    tape_goes.parts.clear()
    tape_goes.panel_of = fn() { None }
    tape_goes.shown_side_of = None
    tape_goes.room_of = None
    room_c.dispose()
    shown_c.dispose()
    panel_c.dispose()
    nav_held.val = fn() { None }
    // (a panel pulled over, by a finger or back's gesture, let go with it: nothing of it on the tape made next)
    wide.tape_pull.set(None)
    wide.tape_drag.set(0.0)
    wide.tape_backing = false
    wide.tape.set(false)
    @hostapi.window_buttons_down(0.0, @ui.move_ms(bar_in_now()))
  })
  |> ignore
  // what the page's panel shows as the page on top changes, at its cause's moment (page_wait.mbt)
  tape_page_wait.follow(v, fn(p) { (tape_goes.ready)(p) }, fn() { tape_goes.most })
  // the side panel last open, kept while it closes (tape_shown_side); let go once the tape rests at the page
  v.reacts(fn() { (tape_goes.panel_of)() }, fn(side) {
    match side {
      Some(_) => tape_goes.last_side.set(side)
      None => ()
    }
  })
  v.reacts(fn() { (panel_own.leaving.get(), (tape_goes.panel_of)() is None) }, fn(_) { tape_left() })
  // another place's sidebar at its own width (side_take: as it was left): the tape moved to it from where it is then, as
  // the sidebar is (brand.tsx moveSidebar, 380 ms); not the width the edge drags, which is followed at once
  let side_took = Ref(false)
  v.reacts(
    fn() {
      match @sfbase.workspace_in_view(src).0 {
        Some(w) if src.topic("prefs", {}).get().value is Some(_) => w.id + "\n" + side_group(src, w.id)
        _ => ""
      }
    },
    fn(key) {
      if key == "" {
        return
      }
      let take = fn() {
        match @sfbase.workspace_in_view(src).0 {
          Some(w) => side_take(src, w.id) |> ignore
          None => ()
        }
      }
      if side_took.val && !wide.edge_held.get() {
        tape_moves_from(v.cause_at(), take)
      } else {
        take()
      }
      side_took.val = true
    },
  )
  // the tape as each change has it, at its moment (tape_settle): what is asked of it, what the shown chat and its side
  // panel ask, the page waited for come or its wait over, where things go
  v.reacts(
    fn() {
      let top = tape_top()
      let chat = match top {
        Chat(r) | History(r, _, _) => chat_key(r)
        // a chat's detail asked as a page, on its way to its chat's side panel (beside_follow): still that chat, not another
        // come (its panel, opening, comes over)
        p if laid_beside(p) => wide.tape_chat.untracked()
        _ => ""
      }
      let open = match (tape_goes.panel_of)() {
        Some(side) => side.key()
        None => ""
      }
      // (the chat shown has its view: what its side panel shows is known)
      let known = match top {
        Chat(r) | History(r, _, _) => @sfbase.chat_head_json(src, r) is Some(_)
        _ => true
      }
      (chat, open, known, wide.tape_ask.get(), tape_page_ready(), tape_to_of(tape_room_now()))
    },
    fn(said) {
      let (chat, open, known, _, _, _) = said
      tape_settle(chat, open, known, v.cause_at())
    },
  )
  // (a chat's detail asked as a page put beside its chat as it comes on top, before a frame builds it: after the tape's
  // reaction, so the tape takes the page come and then its chat's panel opened, which comes over, as when the page was
  // built first and told it; on top as the tape is made too)
  beside_follow(v, src)
  // back while the wide frame takes it (wide_takes_back), a node of the window's tree's: drawn before the panels, what an old
  // view in one of them says takes back (a page's own stack) taking it before it, what is over them too; whose it is
  // said at the cause that changes it, each step taken at its moment (wide_back_step)
  let held : Ref[WideBack?] = Ref(None)
  let fwd_held : Ref[WideBack?] = Ref(None)
  let hint = back_hint_new(v)
  v.show(at_once=true, fn() { wide_takes_back(src) }, fn(b) {
    b.follows_back(fn(step) { wide_back_step(src, held, hint, step) }) |> ignore
    // (let go as a gesture goes on to it, as what it takes back by is (told nothing more): what it held of it let go
    // here, the tape back where it was in use)
    b.owns(fn() { wide_back_left(held, hint, v.cause_at()) }) |> ignore
  })
  v.follows_forward(when=fn() { wide_takes_forward(src) }, fn(step) { wide_forward_step(src, fwd_held, hint, step) })
  |> ignore
  v.owns(fn() { wide_back_left(fwd_held, hint, v.cause_at()) }) |> ignore
  v.box(fn(row) {
    tape_goes.parts.clear()
    tape_goes.parts.push(row)
    row
    .row(Is(true))
    .grow(Is(1.0))
    // (as wide as the tape: its panels side by side, the last on to the window's edge under the system's column)
    .width(By(fn() {
      let r = tape_room_now()
      Some(
        tape_col_in(row) +
        tape_page_in(row) +
        (if tape_shown_side() is Some(_) { bar_gap_now() + r.panel_w } else { 0.0 }) +
        r.under,
      )
    }))
    // moved as a whole, as far as the tape has got: nothing in it laid out again as it moves
    .offset(By(fn() {
      let r = tape_room_now()
      let x = tape_x_at(r, tape_drawn_at(row))
      native_floating_schedule()
      (x, 0.0)
    }))
    |> ignore
    // the rail and the sidebar's column (its panel 6 in from the window's edge and the bars, 8 from the page's)
    row.box(fn(side) {
      tape_goes.parts.push(side)
      side.width(By(fn() {
        let w = tape_col_in(side)
        native_floating_schedule()
        Some(w)
      }))
      |> ignore
      tape_in_use(side, Side)
      tape_swipes(side, Side)
      let side_geom_c = @signals.computed(fn(_) { tape_side_geom(side) }, same=fn(a, b) { a == b })
      let side_ground_c = @signals.computed(fn(_) { tape_side_ground(side) }, same=fn(a, b) { a == b })
      let rail_geom_c = @signals.computed(fn(_) { rail_at_tape(apart_ground()) }, same=fn(a, b) { a == b })
      side.owns(fn() {
        side_geom_c.dispose()
        side_ground_c.dispose()
        rail_geom_c.dispose()
      })
      |> ignore
      let side_geom = fn() { if @signals.active_sub() is None { tape_side_geom(side) } else { side_geom_c.get() } }
      let side_ground = fn() { if @signals.active_sub() is None { tape_side_ground(side) } else { side_ground_c.get() } }
      let rail_geom = fn() { if @signals.active_sub() is None { rail_at_tape(apart_ground()) } else { rail_geom_c.get() } }
      // (the block, the tree's: its ground, the rail and a place's sidebar not made once in it, dock_node)
      side.box(fn(b) {
        b.over(Is(true)) |> ignore
        let tips = @sf.TipLayer::new(fn() { tape_goes.node })
        dock_node(
          b,
          side_geom,
          fn(r) {
            // (nothing of it read out while the panel is behind the one in use: tape_behind's)
            r.hides(By(fn() { wide.tape_at.get() != Side })) |> ignore
            rail_node(r, src, tips, rail_geom, under=side_ground)
          },
          ground=side_ground,
        )
      })
      |> ignore
      // (the sidebar made once, the tree's, over the panel where it lays its sidebar out; nothing of it read out while
      // the panel is behind the one in use: tape_behind's)
      side.box(fn(sides) {
        sides.over(Is(true)).hides(By(fn() { wide.tape_at.get() != Side })) |> ignore
        side_node(sides, src, @sf.TipLayer::new(fn() { tape_goes.node }), side_geom, ground=side_ground)
      })
      |> ignore
      // (the block's line over all it holds: dock_edge_node)
      side.box(fn(line) {
        line.over(Is(true)) |> ignore
        dock_edge_node(line, side_geom)
      })
      |> ignore
      tape_cover(side, Side, fn() {
        let r = tape_room_now()
        let wh = side.window_h()
        // The cover can reopen the sidebar, but never takes the system window buttons' row.
        let top = if @ui.window_inset() {
          dmax(r.panel_top, @ui.window_points_to_content_now(window_buttons_row) + bar_in_now())
        } else { r.panel_top }
        (bar_in_now(), top, bar_gap_now(), dmax(0.0, wh - r.panel_top - r.panel_h))
      })
    })
    |> ignore
    // the page's panel, 6 in from the bars
    row.box(fn(page) {
      tape_goes.parts.push(page)
      page
      .width(By(fn() {
        let r = tape_room_now()
        let w = tape_page_in(page)
        Some(if tape_shown_side() is None { w + r.under } else { w })
      }))
      |> ignore
      tape_swipes(page, Page)
      tape_panel_box(page, Page, 0.0, fn(pane) { tape_page_pane(pane, src) })
      tape_cover(page, Page, fn() { tape_panel_room(page) })
    })
    |> ignore
    // a chat's side panel, 8 from the page's, while it is open or closes
    // (kept, laid out nowhere, while it shows none, once a chat's page made as nodes holds one at rest: tape_side_node)
    let panel_made = Ref(false)
    row.show(fn() {
      let open = tape_shown_side() is Some(_)
      if open {
        panel_made.val = true
      }
      tape_chat_entries_rev.get() |> ignore
      open || (panel_made.val && !tape_chat_entries.is_empty())
    }, fn(panel) {
      panel
      .laid_nowhere(By(fn() { tape_shown_side() is None }))
      .width(By(fn() {
        let r = tape_room_now()
        Some(bar_gap_now() + r.panel_w + r.under)
      }))
      |> ignore
      tape_swipes(panel, Panel)
      tape_panel_box(panel, Panel, bar_gap_now(), fn(pane) { tape_side_node(pane, src) })
      tape_cover(panel, Panel, fn() {
        let (_, t, _, b) = tape_panel_room(panel)
        (bar_gap_now(), t, 0.0, b)
      })
    })
    // the edges, the tree's, over the panels: what is done with them taken at each event's moment, how they look drawn
    // by them (whether each is in hand, this tape's)
    let edges_on : TapeEdgesOn = { side: tape_edge_on(), panel: tape_edge_on() }
    let tips = @sf.TipLayer::new(fn() { Some(v) })
    row.box(fn(edges) {
      edges.over(Is(true)) |> ignore
      // (the one in the other's place at once: what a finger takes at the tape's edge, nothing that is seen open)
      edges.show(at_once=true, fn() { wide.tape_at.get() == Side }, fn(e) {
        tape_side_edge(e, edges, src, tips, edges_on.side)
      })
      edges.show(at_once=true, fn() { wide.tape_at.get() == Panel && tape_shown_side() is Some(_) }, fn(e) {
        tape_panel_edge(e, edges, tips, edges_on.panel)
      })
    })
    |> ignore
  })
  |> ignore
  back_hint_node(v, hint)
}

///|
/// What the window's tree has of the tape, for a test: who its shell, its row, the sidebar's column and the page's panel
/// are (made once: the same while the tape is shown), where the row is drawn across (how far the tape is moved, as the
/// tree has drawn it) and how wide the page's panel's column is laid out. None off the tape.
pub fn tape_seen() -> (Array[@view.NodeId], Double, Double)? {
  match tape_goes.node {
    Some(v) if tape_goes.parts.length() == 3 => {
      let ids = [v.id()] + tape_goes.parts.map(fn(p) { p.id() })
      let (x, _, _, _) = tape_goes.parts[0].rect()
      let (_, _, w, _) = tape_goes.parts[2].rect()
      Some((ids, x, w))
    }
    _ => None
  }
}

///|
/// Where the tape's move committed has the sidebar's column end at `t` (where the page's panel starts on the tape), for a
/// test.
pub fn tape_col_now(t : Double) -> Double {
  tape_col_at(t)
}

///|
/// Where the tape's move committed has the tape at `t` (its own: no finger's pull) and how wide it has the page's panel,
/// worked out of the move alone, for a test.
pub fn tape_along_at(t : Double) -> (Double, Double) {
  (tape_along(tape_goes.x, 0, t), tape_page_at(t))
}

///|
/// How far behind the one in use panel `p` is at `t` (0 in use, 1 behind), for a test.
pub fn tape_behind_now(p : TapePane, t : Double) -> Double {
  tape_behind_at(p, t)
}

///|
/// The room round a panel in column `n` (the page's, the side panel's): from the bars, 6 in, and before it what is
/// between it and the one before (the side panel's 8 from the page's).
fn tape_panel_room(n : @view.View) -> (Double, Double, Double, Double) {
  let r = tape_room_now()
  let wh = n.window_h()
  (0.0, r.panel_top, 0.0, dmax(0.0, wh - r.panel_top - r.panel_h))
}

///|
/// Whether panel `p` (what node `n` holds of it: the sidebar's column, its rail and sidebar; a panel's room, all it shows
/// but its cover, which is the tape's: tape_cover) is the one in use as the keyboard has it
/// (View::in_use): from the moment the tape is asked to it (its way there on) to the moment it is asked to another,
/// wide.tape_at set at the cause's moment. Behind, nothing of it is gone to by Tab or given the focus (the rail, the
/// sidebar, a page's bar, its old view and the composer in it, the side panel), what in it has the focus letting it go
/// then; a press, a long press, a drag or the pointer on what shows of it are as they are (tape_cover).
fn tape_in_use(n : @view.View, p : TapePane) -> Unit {
  n.in_use(By(fn() { wide.tape_at.get() == p })) |> ignore
}

///|
/// The panel `p` in column `n`, its room round it (tape_panel_room) and `before` it (the side panel's 8 from the
/// page's), what `held` puts in it; in use as the keyboard has it while it is the one in use (tape_in_use).
fn tape_panel_box(n : @view.View, p : TapePane, before : Double, held : (@view.View) -> Unit) -> Unit {
  n.box(fn(room) {
    tape_in_use(room, p)
    room
    .over(Is(true))
    .padding(By(fn() {
      let (_, t, _, b) = tape_panel_room(n)
      (before, t, 0.0, b)
    }))
    |> ignore
    room.box(fn(pane) {
      pane.grow(Is(1.0)) |> ignore
      held(pane)
    })
    |> ignore
  })
  |> ignore
}

///|
/// Over panel `p` in column `n` (its room round it: `room`, at its left, top, right and bottom), while it is not in use
/// (or a finger pulls it over): a cover of the tree's drawing nothing, what is done on it its own, each at its event's
/// moment. A tap, or the pointer's secondary button (no menu of what it holds), brings it over; a drag across brings it
/// with the finger (the tape in the hand from there) and, let go, over or back. Drags on the one in use are its own.
fn tape_cover(n : @view.View, p : TapePane, room : () -> (Double, Double, Double, Double)) -> Unit {
  // (where and when the finger went down on it, the window's: where a pull begins from, however the cover moved since)
  let down : Ref[(Double, Double)?] = Ref(None)
  n.box(fn(holder) {
    holder.over(Is(true)).padding(By(room)) |> ignore
    holder.show(
      // (the one in use, at rest, takes what is done on it; moving to it, or pulled, still the cover's)
      fn() { tape_covered(p) },
      fn(cover) {
        // (a finger's press on it keeps what a finger picked: its pull begins all the same, as the old cover's)
        @ui.keeps_picked(cover) |> ignore
        // (what a screen reader says of it: a button, what pressing it does; none of the one in use, on its way to it
        // or pulled over, its own widgets read out; pressed by a screen reader: brought over at that moment, as a tap
        // brings it; a finger and the pointer its gesture's, as ever: what drags a node is what a press on it finds)
        @sf.action_box_node(
          cover,
          fn() { tape_words(p) },
          fn(_) {
            wide.tape_ask.set(Some(p))
            tape_take_ask(cover.cause_at()) |> ignore
          },
          in_node=true,
          focusable=false,
          fn(cover) {
            cover
            .grow(Is(1.0))
            .hides(By(fn() { wide.tape_at.get() == p }))
            // (the page's, while the sidebar is in use: a stop of the keyboard's after the sidebar's own, Enter or Space
            // bringing the page over as a press does; the keyboard's one way to it, all of the page behind taking none:
            // tape_in_use)
            .focusable(By(fn() { p == Page && wide.tape_at.get() == Side }))
            .focus_ring(Is(Some((-1.0, -4.0, 0L))))
            .on_menu(fn(m) {
              wide.tape_ask.set(Some(p))
              tape_take_ask(m.at) |> ignore
            })
            .gesture(
              @ui.press_slop,
              // (a finger held still on it the long press's while: handed to what is under it, the panel's own words
              // picked as it is brought over)
              through=@ui.long_press_ms,
              press=fn(d) { down.val = Some((d.wx, d.at)) },
              tap=fn(d) {
                down.val = None
                wide.tape_ask.set(Some(p))
                tape_take_ask(d.at) |> ignore
              },
              drag=fn(d) {
                tape_pulled(p, d, down.val.unwrap_or((d.wx, d.at)))
                if d.kind is (Up | Off) {
                  down.val = None
                }
              },
            )
            |> ignore
          },
        )
        |> ignore
        // (the keyboard's focus on it: a ring in the panel it covers, the theme's gap and width in from its edges,
        // concentric with its corners)
        cover.show(fn() { cover.focus_shown() }, fn(ring) {
          let inset = fn() {
            let t = @ui.tree_theme()
            t.focus_gap + t.focus_w
          }
          ring
          .over(Is(true))
          .margin(By(fn() {
            let i = inset()
            (i, i, i, i)
          }))
          .radius(By(fn() { @ui.concentric(@sf.tape_corner, inset()) }))
          .edge(By(fn() { (@ui.tree_theme().focus_w, @ui.tree_theme().focus) }))
          |> ignore
        })
      },
    )
  })
  |> ignore
}

///|
/// A finger dragging panel `p`'s cover across (tape_cover), gone down at `down` (where across the window, when): the tape
/// in its hand from where it went down (unless another is in its hand: back's), moved as far as it has come from there;
/// let go, over or back (tape_let_go), as fast as the finger went as it left (Drag::vx: a lift saying its last place
/// again, as a device's always does, later, takes none of it, Tracker::up);
/// called off, back.
fn tape_pulled(p : TapePane, d : @view.Drag, down : (Double, Double)) -> Unit {
  let begin = fn() {
    wide.tape_pull.set(Some(p))
    wide.tape_drag.set(0.0)
    tape_goes.pull_x0 = down.0
  }
  let moved = fn() {
    wide.tape_drag.set(tape_pull_clamp(tape_ends(tape_room_now()), p, d.wx - tape_goes.pull_x0))
  }
  let mine = wide.tape_pull.get() == Some(p) && !wide.tape_backing
  let free = p != wide.tape_at.get() && wide.tape_pull.get() is None
  match d.kind {
    Down =>
      if free {
        begin()
        moved()
      }
    Moved => if mine { moved() }
    Up =>
      // (let go past the slop with no move told before: its end alone, from where it went down)
      if mine || free {
        if free {
          begin()
        }
        moved()
        tape_let_go(p, d.vx() * 1000.0, d.at)
      }
    Off =>
      if mine {
        tape_moves_from(d.at, fn() {
          wide.tape_pull.set(None)
          wide.tape_drag.set(0.0)
        })
      }
  }
}

///|
/// Which panel a finger moved (dx, dy) since it went down on panel `p` brings over: past the slop, steeply more across
/// than up or down (a chat scrolled at a slant stays scrolled), toward the panel beside `p` that way; none but on the one
/// in use at rest, a finger's alone (a pointer's drag picks words), nor over what back leaves the tape's (a screen, a
/// file read: tape_back_to).
fn tape_swiped(p : TapePane, dx : Double, dy : Double) -> TapePane? {
  guard !@sf.pointer_rests() &&
    wide.tape_at.get() == p &&
    !tape_covered(p) &&
    !(app.nav.top() is (Screen(_) | Terminal(_) | DriveRead(_) | DrivePlay(_))) &&
    dx.abs() > @ui.press_slop &&
    dx.abs() > dy.abs() * tape_swipe_steep else {
    return None
  }
  match (p, dx > 0.0) {
    (Panel, true) | (Side, false) => Some(Page)
    (Page, true) => Some(Side)
    (Page, false) if (tape_goes.panel_of)() is Some(_) => Some(Panel)
    _ => None
  }
}

///|
/// Panel `p`'s column `n` taking a finger's swipe across it over (tape_swiped), from wherever it went down on what it
/// holds: what the panel holds that goes that way (a code block with further to scroll, a row swiped, a column's edge)
/// has it first; from there the tape in its hand, as on a cover (tape_pulled).
fn tape_swipes(n : @view.View, p : TapePane) -> Unit {
  let to : Ref[TapePane?] = Ref(None)
  n
  .claims(fn(dx, dy) {
    to.val = tape_swiped(p, dx, dy)
    to.val is Some(_)
  })
  .on_drag(fn(d) {
    match to.val {
      Some(q) => {
        tape_pulled(q, d, (d.wx, d.at))
        if d.kind is (Up | Off) {
          to.val = None
        }
      }
      None => ()
    }
  })
  |> ignore
}

///|
/// The ground of a panel `k` of the way behind the one in use: the page's in use, a step darker that far behind.
fn tape_ground(k : Double) -> Int64 {
  if k <= 0.0 {
    @sf.theme().p.bg
  } else {
    @sf.behind_ground(k~)
  }
}

///|
/// Whether panel `p` has its cover over it (tape_cover): not in use, or on its way to be, or pulled over by a finger.
fn tape_covered(p : TapePane) -> Bool {
  wide.tape_at.get() != p || !tape_goes.rest.get() || wide.tape_pull.get() == Some(p)
}

///|
/// Where the sidebar's panel on the tape lays its sidebar out as node `side` (its column) is drawn: as dock_node
/// lays it out (dock_side_at, the tape's look), in the column's own room. Geometry only (ground is separate so drag
/// dimming does not re-evaluate layout bindings).
fn tape_side_geom(side : @view.View) -> SideAt {
  let r = tape_room_now()
  let col = tape_col_in(side)
  let s = dmax(0.0, col - rail_left() - bar_in_now() - bar_gap_now() - rail_more())
  let top = if side_full_height(false) { 0.0 } else { r.top }
  // (its top row the tape's, its band the bar's, as tape_under says them: side_brand_h)
  {
    ..dock_side_at(false, false, s, col, top, r.foot, 0.0, side.window_h(), None),
    ground: apart_ground(),
    brand: side_brand_h(false, r.top),
    band: 1.0,
    list_brand: side_brand_h(false, r.top),
    list_band: 1.0,
    tape: true,
  }
}

///|
/// The sidebar panel's ground on the tape: behind the panel in use, a step darker as far as the tape's move or pull
/// has got.
fn tape_side_ground(side : @view.View) -> Int64 {
  let k = tape_behind_in(Side, side)
  if k <= 0.0 { apart_ground() } else { @sf.behind_ground(k~) }
}

///|
/// A chat's side panel on the tape in node `pane` (tape_panel_box's, 6 in from the bars, 8 from the page's), the tree's:
/// its ground, corners and line round what is in it as the page's panel's are (tape_page_pane), the panel's room beside
/// the system's column its ground alone; its bar over whatever tab is in front (side_bar_node, on the tape's line, a tab
/// alone its title), none where what is in front has its own (side_own_bar_node); under it an agent's history
/// (side_history_node), a file in the viewer (side_view_node), a station's screen (side_screen_node), 任务, agent 往来 and
/// 图片、文件和链接 (side_own_node). A new chat's Station 文件 the same panel round its one tab (new_side_bar_node, on the
/// tape's line, and files_tab_node, as beside the page: new_side_node.mbt).
fn tape_side_node(pane : @view.View, src : Source) -> Unit {
  let tips = @sf.TipLayer::new(fn() { tape_goes.node })
  // (a chat's while it shows a tab: its view gone (its workspace left), the island's, as a new chat's)
  let chat = fn() {
    match tape_shown_side() {
      Some(ChatSide(r)) if tape_side_shown(src, r).0.length() > 0 => Some(r)
      _ => None
    }
  }
  // (a chat's page made as nodes whole on the stack (tape_chat_entries): its panel read by its page's source, kept with
  // it as it is put by on the stack's kept left and taken back with it; one on top waiting for what it shows none
  // meanwhile; another chat's (the old page's) as ever, by the tape's source)
  let entry_for = fn(r : ChatRef) -> (Int, Source)? {
    tape_chat_entries_rev.get() |> ignore
    let mut kept : (Int, Source)? = None
    for k, e in tape_chat_entries {
      if e.0.station == r.station && e.0.session == r.session {
        if !app.nav.is_kept_left(k) {
          return Some((k, e.1))
        }
        kept = Some((k, e.1))
      }
    }
    kept
  }
  let shown_keys = fn() -> Array[String] {
    match tape_shown_side() {
      Some(ChatSide(r)) =>
        match entry_for(r) {
          Some((k, page_src)) =>
            if app.nav.top_waits() && app.nav.waiting_taken_back(k) {
              []
            } else if tape_side_shown(page_src, r).0.length() > 0 {
              ["e:" + k.to_string()]
            } else {
              []
            }
          None => if chat() is Some(r) { ["c:" + chat_key(r)] } else { [] }
        }
      Some(NewSide(ws)) => ["n:" + ws]
      None => []
    }
  }
  let kept_keys = fn() -> Array[String] {
    tape_chat_entries_rev.get() |> ignore
    let ks : Array[String] = []
    for k, _ in tape_chat_entries {
      if app.nav.page_of(k) is Some((Chat(_), _)) {
        ks.push("e:" + k.to_string())
      }
    }
    ks
  }
  pane.each(shown_keys, fn(id) { id }, at_once=true, keeps=kept_keys, fn(q, id_sig) {
    q.grow(Is(1.0)) |> ignore
    let id = id_sig.untracked()
    let shown = if id.has_prefix("e:") {
      let mut found : (ChatRef, Source)? = None
      for k, e in tape_chat_entries {
        if "e:" + k.to_string() == id {
          found = Some(e)
        }
      }
      match found {
        Some((r, page_src)) => {
          let (q_src, q_park) = page_src.owned_by_parkable(q)
          q.on_rest(fn() { q_park(true) }, wake=fn() { q_park(false) }) |> ignore
          Some((r, q_src))
        }
        None => None
      }
    } else if id.has_prefix("c:") {
      match tape_shown_side() {
        Some(ChatSide(r)) => Some((r, src.owned_by(q)))
        _ => None
      }
    } else {
      None
    }
    // (the panel's ground, line and corners as the page's panel's, whichever it holds)
    q
    .clips(Is(true))
    .ground(By(fn() { tape_ground(tape_behind_in(Panel, q)) }))
    .edge(By(fn() { (1.0, @sf.theme().p.line) }))
    .padding(By(fn() { (0.0, 0.0, tape_room_now().under, 0.0) }))
    |> ignore
    @ui.tree_corners_linked(q, fn() { Some(tape_pane_corners(Panel, true)) })
    guard shown is Some((r, q_src)) else {
      if id.has_prefix("n:") {
        tape_new_side_node(q, src.owned_by(q), id.exact_view(start=2).to_owned(), tips)
      }
      return
    }
    let src = q_src
    let shown = fn() { tape_side_shown(src, r) }
    q.show(at_once=true, fn() {
      let (tabs, front) = shown()
      !side_own_bar_node(q, tabs, front, true)
    }, fn(b) {
      tape_side_bar_clip_node(b, fn(inner) { side_bar_node(inner, src, r, shown, true, tips) })
    })
    let front = fn() {
      match shown().1 {
        front if side_node_tab(front) => full_elsewhere(r, front)
        _ => ""
      }
    }
    // (a file in the viewer: its tools and stage, as beside the page; a station's screen; 任务, agent
    // 往来, 图片、文件和链接 each its nodes, a card across the foot in the panel's corners; 文件 and a station's 文件 the
    // tab's nodes, 添加 in those corners too; a station's page its page's nodes; any other tab its old view)
    q.pick(at_once=true, front, fn(s, agent) {
      s.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
      if agent == tab_full_mark {
        // (over the whole window: nothing of it here meanwhile, tab_full_node.mbt)
        ()
      } else if agent == "" {
        // (no tab of the tree's in front: nothing, every tab the panel shows is the tree's, side_node_tab)
        ()
      } else if @sfbase.view_tab_file(agent) is Some(_) {
        tab_held_beside(s, r, agent)
        side_view_node(s, src, r, agent, fn(n) { side_whole(src, n) }, full_of(r, agent))
      } else if tab_service(agent) is Some(job) {
        tab_held_beside(s, r, agent)
        // (alone on the tape: its bar the panel's, its × closing the panel, in the panel's corners)
        let round = Some(beside_column(tape_pane_corners(Panel, true), tape_room_now().under))
        let alone = @signals.untracked(fn() { shown().0.length() == 1 && !column_short.get() })
        service_tab_node(
          s,
          src,
          r,
          job,
          if alone { Some(fn() { side_change(src, r, "clear", None) }) } else { None },
          full_of(r, agent),
          round,
          tips,
        )
      } else if tab_file(agent) is Some((session, path, name)) {
        tab_held_beside(s, r, agent)
        file_tab_node(s, src, r, session, path, name, full_of(r, agent), tips)
      } else if side_screen_tab(agent) is Some(_) {
        side_screen_node(s, src, r, agent, fn() { shown().0 }, true)
      } else if side_adb_tab(agent) is Some(station) {
        side_adb_node(s, src, station)
      } else if side_files_tab(agent) is Some(station) {
        // (添加 in the panel's foot corner, concentric with it)
        side_files_node(s, src, r, station, fn() {
          @sf.pane_round.val = Some(beside_column(tape_pane_corners(Panel, true), tape_room_now().under))
          let st = @sf.foot_corner(@sf.button_height(), ftab_side, ftab_under)
          @sf.pane_round.val = None
          st
        }, tips)
      } else if side_station_tab(agent) is Some(station) {
        // (as wide as the panel on the tape is laid out now)
        side_station_node(s, src, station, tips, fn() { tape_room_now().panel_w }, true)
      } else if side_terminal_tab(agent) {
        side_terminal_node(s, src, r, agent)
      } else if side_own_tab(agent) {
        side_own_node(s, src, r, agent, tips, fn() {
          @sf.pane_round.val = Some(beside_column(tape_pane_corners(Panel, true), tape_room_now().under))
          let st = @sf.pane_foot_card()
          @sf.pane_round.val = None
          st
        })
      } else {
        side_history_node(s, src, r, agent, tips)
      }
    })
  })
}

///|
/// What chat `r`'s panel on the tape shows: its tabs as its view has them; closed while in use, as the tape moves off
/// it, what it had.
fn tape_side_shown(src : Source, r : ChatRef) -> (Array[String], String) {
  // (its head alone: sfbase's chat_view_now)
  match @sfbase.chat_view_now(src, r) {
    Some(view) =>
      if (tape_goes.panel_of)() is None {
        side_leaving(chat_key(r)).unwrap_or(side_of(view))
      } else {
        side_of(view)
      }
    None => ([], "")
  }
}

///|
/// Whether one of the tape's edges is in hand, as its node says it (its look drawn by it: tape_edge_at), this tape's.
priv struct TapeEdgeOn {
  held : @signals.Signal[Bool]
}

///|
fn tape_edge_on() -> TapeEdgeOn {
  { held: @signals.signal(false, same=fn(a, b) { a == b }) }
}

///|
/// The tape's two edges' (TapeEdgeOn), this tape's.
priv struct TapeEdgesOn {
  side : TapeEdgeOn
  panel : TapeEdgeOn
}

///|
/// How far the edge reaches past the gap, before it and after it (`edge`: the side the one in use has it on), into what
/// is beside the gap (@sf.edge_reach: the drags across that land there its own).
fn tape_edge_reach(edge : @ui.Side) -> (Double, Double) {
  let (into_in, into_page) = @sf.edge_reach(bar_gap_now())
  if edge is Left {
    (into_page, into_in)
  } else {
    (into_in, into_page)
  }
}

///|
/// Where the edge whose gap begins at `gap(t)` across the tape is, in node `n` (over the tape's row, moved with it): as
/// wide as the gap and what it reaches past it, as high as the panels, the tape as of the moment it is drawn at; the node
/// put in it by `made`, its look in the gap's middle (@sf.edge_look_node: shown as @sf.edge_over has it, always to
/// touch, which points at nothing; on it while the pointer is on it or it is in hand, `on`'s held; active in hand).
fn tape_edge_at(
  n : @view.View,
  holder : @view.View,
  edge : @ui.Side,
  gap : (Double) -> Double,
  on : TapeEdgeOn,
  made : (@view.View, @sf.EdgePull) -> @view.View,
) -> Unit {
  n
  .width(By(fn() {
    let (before, after) = tape_edge_reach(edge)
    Some(before + bar_gap_now() + after)
  }))
  .height(By(fn() { Some(tape_room_now().panel_h) }))
  .offset(By(fn() {
    let (before, _) = tape_edge_reach(edge)
    (gap(tape_drawn_at(holder)) - before, tape_room_now().panel_top)
  }))
  |> ignore
  // (dragged on past either end, its line drawn aside as a string, sprung back as it is let go: @sf.EdgePull)
  let pull = @sf.EdgePull::new()
  let e = made(n, pull)
  e.box(fn(g) {
    g
    .over(Is(true))
    .padding(By(fn() {
      let (before, _) = tape_edge_reach(edge)
      (before + (bar_gap_now() - @sf.handle_w) / 2.0, 0.0, 0.0, 0.0)
    }))
    |> ignore
    @sf.edge_look_node(g, @sf.edge_over, fn() { e.pointed() || on.held.get() }, fn() { on.held.get() }, pull~)
    |> ignore
  })
  |> ignore
  n.owns(fn() { on.held.set(false) }) |> ignore
}

///|
/// The sidebar's edge on the tape while the sidebar is in use, in node `n` (over the tape's row `holder`): dragged, the
/// sidebar's width (kept as the wide frame's is: side_follow), the page beside it showing what it leaves; the second of
/// two presses, its own width again; a press where it lies over what shows of the page, the page brought over, as a
/// press there without it would. Held, the wide frame's edge_held.
fn tape_side_edge(
  n : @view.View,
  holder : @view.View,
  src : Source,
  tips : @sf.TipLayer,
  on : TapeEdgeOn,
) -> Unit {
  tape_edge_at(n, holder, Right, fn(t) { tape_col_at(t) - bar_gap_now() }, on, fn(n, pull) {
    @sf.edge_node(
      n,
      fn() { @sf.t("web-pages.workspace.resizeSidebar") },
      fn() { tape_side_w(tape_room_now().tw, wide.side_w.get()) },
      fn() { side_min },
      fn() { tape_side_most(tape_room_now().tw) },
      Right,
      fn(said, _) {
        match said {
          Dragging(x) | Dropped(x) => wide.side_w.set(x)
          Twice =>
            match @sfbase.workspace_in_view(src).0 {
              Some(w) => wide.side_w.set(side_default(side_group(src, w.id)))
              None => ()
            }
          Pressed | Untouched => ()
        }
      },
      fn(h) {
        on.held.set(h)
        wide.edge_held.set(h)
      },
      // (where the page shows from in it, as the gap and its reach are at the press: what it is drawn by then)
      on_beside=fn(x) { x >= tape_edge_reach(Right).0 + bar_gap_now() },
      beside=fn(at) {
        wide.tape_ask.set(Some(Page))
        tape_take_ask(at) |> ignore
      },
      tips~,
      side=Right,
      pull~,
    )
  })
}

///|
/// The side panel's edge on the tape while the panel is in use, in node `n` (over the tape's row `holder`): dragged, the
/// panel's width, the page beside it showing what it leaves; the second of two presses, its own width again; a press
/// where it lies over what shows of the page, the page brought over.
fn tape_panel_edge(n : @view.View, holder : @view.View, tips : @sf.TipLayer, on : TapeEdgeOn) -> Unit {
  tape_edge_at(n, holder, Left, fn(t) { tape_col_at(t) + tape_page_at(t) }, on, fn(n, pull) {
    @sf.edge_node(
      n,
      fn() { @sf.t("web-pages.chat.resizePanel") },
      fn() { tape_room_now().panel_w },
      fn() {
        let r = tape_room_now()
        dmin(panel_min, tape_one_beside(r.tw, tape_shows_left()))
      },
      fn() { tape_one_beside(tape_room_now().tw, tape_shows_left()) },
      Left,
      fn(said, _) {
        match said {
          Dragging(x) | Dropped(x) => panel_own.width.set(Some(x))
          Twice => panel_own.width.set(None)
          Pressed | Untouched => ()
        }
      },
      fn(h) { on.held.set(h) },
      on_beside=fn(x) { x < tape_edge_reach(Left).0 },
      beside=fn(at) {
        wide.tape_ask.set(Some(Page))
        tape_take_ask(at) |> ignore
      },
      tips~,
      side=Left,
      pull~,
    )
  })
}

///|
/// What the old frame does under the tape's panels with workspace `w` in view, before the old views it holds (sfapp's
/// view_in, on the tape): how the lists take the hand, the system's tabs where it has its own bars, what the page's bars
/// and the sidebar's parts work out from (as open, apart: on the tape nothing of them moves). The sidebar as it was
/// left, the chat landed on. The window's buttons' row is the tree's (sfapp's wide_top_node).
pub fn tape_under(c : @ui.Ctx, src : Source, w : Workspace, all : Array[Workspace]) -> Unit {
  c.mouse_drags_lists(pane_finger())
  wide.side_place = side_place()
  side_follow(c, src, w.id)
  wide.tape.set(true)
  wide.crowded = false
  side_crowded()
  wide.peeking.set(false)
  native_frame(c, src, w, all)
  wide.closed.set(false)
  // (what the page's bars and the sidebar's parts work out from: open, apart, nothing of them moving on the tape)
  let r = tape_room_now()
  // (a page's title on the panel's words' line, panel_words, its row's own 8 (chat_bar_title_in) in from this)
  wide.bar_pl = @sf.panel_words - chat_bar_title_in
  wide.bar_ml = 0.0
  wide.bar_mr = 0.0
  wide.brand_h = side_brand_h(false, r.top)
  wide.band = 1.0
  wide.mark = 0.0
  land(src, w)
  // (beside the system's action at the column's foot, the cards' foot corners the one the composer stands concentric in
  // on its line: said before any of them is built, the window's tree reading it, as for the screen's corner:
  // rail_native.mbt native_frame)
  @sf.native_foot_set(r.panel_top + r.panel_h, keyboard=c.ime_inset()) |> ignore
  // (back, the shell's one way: the tape's node's, tape_view, wide_takes_back)
}

///|
/// Whether the panel is a station's screen alone in a panel of its own on the tape: its top bar the panel's, named by it
/// and closed from its end (the user, 2026-11-05: its name twice, its × alone in a row of its own; 2026-11-06: its × among
/// the chat's actions in a Duo's system bars read as another thing's, so there too it is the bar's own).
fn screen_tab_alone(tabs : Array[String]) -> Bool {
  wide.tape.get() && tabs.length() == 1 && station_tab(tabs[0]) is Some(("screen", _, _))
}

///|
/// Whether the one pulled `pulled` of its way `span` over, let go going `v` (px a second), is brought over: flung toward
/// it, or landing past tape_pull_over of the way (tape_pull_far at most) on from that speed (@ui.lands_past) and not
/// flung away.
fn tape_goes_over(pulled : Double, span : Double, v : Double) -> Bool {
  let fling = v.abs() > tape_fling
  let toward = fling && (v > 0.0) == (span > 0.0)
  let away = fling && !toward
  let far = dmin(tape_pull_far, tape_pull_over * span.abs())
  let line = if span > 0.0 { far } else { -far }
  let over = span != 0.0 && @ui.lands_past(pulled, v / 1000.0, line)
  toward || (over && !away)
}

///|
/// Wraps a tape side panel's top bar (`make`) in a container that clips it clear of Windows' own window keys (`| - □ ×`)
/// while the tape slides, without shrinking the bar's inner layout width.
fn tape_side_bar_clip_node(parent : @view.View, make : (@view.View) -> Unit) -> Unit {
  if !@ui.window_keys_own() {
    make(parent)
    return
  }
  parent.box(fn(c) {
    let sliding_win = fn() {
      let t = tape_drawn_at(c)
      t != @double.infinity && tape_goes.way.goes_at(t)
    }
    c
    .shrink(Is(0.0))
    .clips(By(sliding_win))
    .width(
      By(fn() {
        if sliding_win() {
          let r = tape_room_now()
          let t = tape_drawn_at(c)
          let panel_left = tape_x_at(r, t) + tape_col_at(t) + tape_page_at(t) + bar_gap_now()
          Some(dmax(0.0, r.tw - @sf.window_keys_room_tape(roots=@ui.tree_corner_roots_now()) - panel_left))
        } else {
          None
        }
      }),
    )
    |> ignore
    c.box(fn(inner) {
      inner.shrink(Is(0.0)).width(By(fn() { Some(tape_room_now().panel_w) })) |> ignore
      make(inner)
    })
    |> ignore
  })
  |> ignore
}
