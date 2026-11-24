// What a chat's page made as nodes tells the core of what is read and where the chat is, out of one fact: what its list
// has in sight (@view.ListPlace::on_sight), as the old page's list told it (sfbase's chat_list.mbt): the chat shows
// (`client.focus {chat}`) as that changes, where it is (`chat.place`) at rest alone. The chat shows: its end seen (at
// its foot with all there drawn whole, a message on its way in not yet: Sight's `foot_whole`; the window not short of
// the chat's end) and the last message seen whole (drawn whole), which marks what is read and
// places the unread line; where it is (`chat.place`): the message at the top and how far its top
// is under the list's (in the screen's pixels), none at its end, told as the message at the top changes; as the page goes
// (sfapp's chat_left, chat_read_left), that it shows no more and where it was left. Told while the page is drawn (sfbase's
// chat_page_made's `drawn`, what the old page's view was built by: none of it while another page covers it, what is in
// sight then told as it comes to be drawn again) and the app is shown, never with Source.read_only; the same fields the
// old page tells (sfbase's tell_focus, tell_place), the core unchanged.

///|
/// What a chat's page last told the core, to tell only as it differs: what its list last had in sight and its rows then
/// (to tell where it was left), the last message seen whole (the furthest: read up, what was read stays read), the
/// message at the top and its top under the list's (in points), the screen's scale, the last message its rows had as
/// they were last in sight (-1 none: what its end is said to be as it is left, its chat let go of by then). Where the
/// core was last told the
/// chat is, the chat's Reading keeps (sfbase's reading_of, told_place and told_at): one account of it with the old
/// page's list, which still draws the chat beside a page over it on the wide frame (a service's, its tab shown).
/// What its page last made of it, to tell where it is left as it is (chat_read_left, the app going behind:
/// chat_reads_behind, the page covered): its source `src` and chat `chat`, its view as it changes (`view`), and
/// `refresh`, what its list has in sight this moment taken (where a fling or a notch still goes on: ListPlace::sight_live,
/// not where it will rest), so that what is told is where the reader left it.
priv struct ChatRead {
  mut sight : (@view.Sight[String], ChatBodyNow)?
  mut whole : Double
  mut top : ChatReaderAt?
  mut scale : Double
  mut last : Double
  mut sight_end_seq : Double
  mut told_focus : String
  mut src : Source
  chat : ChatRef
  mut view : () -> ChatView
  mut refresh : () -> Unit
  mut page : @view.View?
  /// what its page's list worked out that nothing follows let go of (ChatBodyList's rest_unwatched): after it is read
  /// once more as the chat is left (chat_read_left)
  mut rest_unwatched : () -> Unit
}

///|
/// Last wholly-read message sequence at or before the last occurrence of `w` in `rs`.
/// A multi-slice message at `w` counts only when `whole_slice` reaches its last slice.
fn chat_read_whole_seq(rs : ChatBodyNow, w : String, whole_slice : Int) -> Double {
  let mut i = rs.last_index_of(w).unwrap_or(-1)
  while i >= 0 {
    match rs.get(rs.keys[i]) {
      Some({ entry: Said(m), .. }) if rs.keys[i] != w || whole_slice >= rs.slices(w) - 1 =>
        return m.notice_last_seq
      _ => i = i - 1
    }
  }
  -1.0
}

///|
/// What each chat open on a page made as nodes was told, by its key (station + "\u{1}" + session): taken as the chat
/// is left (chat_read_left).
let chat_reads : Map[String, ChatRead] = Map([])

///|
/// Chat `r`'s page (in `v`, its view `view` as it changes) telling the core what is read and where it is from what its
/// list `place` has in sight (the file's head), its rows as `rows` has them, while `shows` (it is drawn), where it is
/// at rest (`scroll`, the list's, neither in the hand nor going on by itself); where it is kept and told as a place is (sfbase's
/// kept_place_of), what covers the list's top `cover` tall, and the room the list keeps under it with it `top` tall.
fn chat_read_node(
  v : @view.View,
  src : Source,
  r : ChatRef,
  view : () -> ChatView,
  place : @view.ListPlace[String],
  scroll : @view.Scroll,
  rows : ChatBodyList,
  shows : () -> Bool,
  cover : () -> Double,
  top : () -> Double,
  rest? : () -> Unit = fn() {  },
  reopening? : () -> Bool = fn() { false },
  on_reopened? : Ref[(Bool) -> Unit] = Ref(fn(_) {  }),
  on_stack? : () -> Bool = fn() { true },
) -> Unit {
  let k = r.station + "\u{1}" + r.session
  // (the chat's while it is open: a page made again for it, as another comes over it and goes, goes on from it)
  let a : ChatRead = match chat_reads.get(k) {
    Some(was) => was
    None =>
      ChatRead::{
        sight: None,
        whole: -1.0,
        top: None,
        scale: 1.0,
        last: -1.0,
        sight_end_seq: -1.0,
        told_focus: "",
        src,
        chat: r,
        view,
        refresh: fn() {  },
        page: None,
        rest_unwatched: fn() {  },
      }
  }
  // (the chat's read by this page only once a frame has drawn it, still shown: a page made and gone before that (pushed
  // and popped in one go, or an entry of the same chat made over the one drawn) takes nothing of the chat's read, tells
  // the core nothing, and leaves the one drawn its own; drawn_once, register below)
  let drawn_once = Ref(false)
  // (while the chat is open, none once it is left, and its page is drawn)
  let live = fn() {
    drawn_once.val && chat_reads.get(k) is Some(now) && physical_equal(now, a) && @signals.untracked(shows)
  }
  // what is in sight taken as it changes, the hand on it or not, as the old page's list read it each frame (sfbase's
  // read_place): where it is (where it was left, to the pixel, as it is left there: chat_read_left) and the last
  // message seen whole
  let taken = fn(s : @view.Sight[String]) {
    let rs = @signals.untracked(fn() { rows.read() })
    let cv = @signals.untracked(view)
    a.sight = Some((s, rs))
    if v.alive() {
      a.scale = @signals.untracked(fn() { v.pixel_scale() })
    }
    // (the last message its rows have: what its end is as it is left, whatever of the chat is let go of by then)
    let mut j = rs.keys.length() - 1
    while j >= 0 {
      match rs.get(rs.keys[j]).map(fn(row) { row.entry }) {
        Some(Said(m)) => {
          a.last = m.seq
          break
        }
        _ => j = j - 1
      }
    }
    // (the last message laid out in this Sight `s` itself — anchored at `s.last`, never `rs.keys`'s tail — so a newer
    // ChatView arriving before a stale `on_sight` callback never advances `endSeq` past what was actually laid out;
    // folded notices carry `notice_last_seq`)
    let mut end_seq = -1.0
    match rs.index_of(s.last) {
      Some(idx) => {
        let mut k = idx
        while k >= 0 {
          match rs.get(rs.keys[k]).map(fn(row) { row.entry }) {
            Some(Said(m)) => {
              end_seq = m.notice_last_seq
              break
            }
            _ => k = k - 1
          }
        }
      }
      None => ()
    }
    a.sight_end_seq = end_seq
    // the message at the top, its top under the list's: where the reader is (chat_reader_at: what is read under the bar,
    // not a tail of what was over it, nor a row of no message), as a go-to and the outline take it (else as it was)
    match chat_reader_at(s, rs, place, @signals.untracked(cover), @signals.untracked(top)) {
      Some(top) => a.top = Some(top)
      None => ()
    }
    // the last message seen whole: the message the last key wholly in sight is, or the last before it; a slice of a
    // long message seen whole is not the message seen whole but where it is its last
    match s.whole {
      Some(w) if !cv.newer => {
        let seq = chat_read_whole_seq(rs, w, s.whole_slice)
        if seq > a.whole {
          a.whole = seq
        }
      }
      _ => ()
    }
  }
  // told once the frame (or the change between frames) that took it is over, as the old page told it once its
  // frame's builds were over (sfbase's after_build_or_scroll): what is in sight then, the last of what its passes
  // told (a moment's layout tells it again as the rows it brought in are measured, each nearer what is so). That it
  // shows, its end seen or not and the last message seen whole, as either changes (sfbase's tell_focus, the old page
  // telling it moving or not); where it is only where it was owed at rest (`placing`, settle's)
  let telling = Ref(false)
  let placing = Ref(false)
  let deferred = Ref(false)
  let flush_tell = fn() {
    guard live() && a.sight is Some((s, _)) else {
      placing.val = false
      deferred.val = false
      return
    }
    if reopening() {
      deferred.val = true
      return
    }
    deferred.val = false
    let cv = @signals.untracked(view)
    // (its end seen: at its foot with all there drawn whole, not a message still on its way in; @view.Sight's; only
    // while the app is in front, what comes behind it not read)
    if app_in_front() {
      chat_read_focus(src, r, cv, a, !cv.newer && s.foot_whole)
    }
    // (where it is, the app in front or not: a glide that ends as it goes behind still leaves it there)
    if placing.val && !@signals.untracked(fn() { scroll.in_hand() }) {
      placing.val = false
      chat_read_place(src, r, cv, a, exact=false)
    }
  }
  let tell = fn() {
    guard !telling.val else { return }
    telling.val = true
    @ui.after_frame(fn() {
      telling.val = false
      flush_tell()
    })
  }
  on_reopened.val = fn(clear_stale) {
    if clear_stale {
      deferred.val = false
      placing.val = false
    } else if deferred.val {
      flush_tell()
    }
  }
  // where it is (`chat.place`) told at rest alone, as the old page told it only while its list was not moving (ui's
  // Ctx::list_moving: held, flung, easing): never while the hand holds the list (each move of a finger is an input the
  // list tells what is in sight at), nor while it goes on by itself after (a fling's glide, a notch of the wheel easing
  // in: Scroll::glides_till), but once as the hand lets go with nothing to go on by, or as that ends; a pixel wheel's
  // stroke, which eases not, leaves it at rest at once, told then, as the old page did
  let owed = Ref(false)
  let due : Ref[() -> Unit] = Ref(fn() {  })
  fn settle() -> Unit {
    guard owed.val else { return }
    guard live() else {
      owed.val = false
      return
    }
    guard !@signals.untracked(fn() { scroll.in_hand() }) else { return }
    (due.val)()
    due.val = fn() {  }
    match scroll.glides_till() {
      Some(end) if end > v.cause_at() => due.val = v.at_moment(end, settle)
      _ => {
        owed.val = false
        placing.val = true
        tell()
      }
    }
  }
  let seen = fn(s : @view.Sight[String]) {
    guard drawn_once.val && live() else { return }
    taken(s)
    owed.val = true
    tell()
    settle()
  }
  place.on_sight(seen)
  // (what it has in sight this moment while the list still goes by itself (a fling's glide, a notch easing in) or is in
  // the hand: what was last told is where it was let go, not where it is. At rest what was last told is where it is,
  // taken as it came to rest: read again as the page goes, it would be read off a list laid out for leaving)
  let refresh = fn() {
    guard @signals.untracked(fn() { scroll.in_hand() }) || scroll.glides_till() is Some(_) else { return }
    match place.sight_live() {
      Some(s) if !(a.sight is Some((was, _)) && was == s) => taken(s)
      _ => ()
    }
  }
  // (this page the chat's read's, once drawn: what it is read by, where it is, what in sight then told)
  let register = fn() {
    drawn_once.val = true
    a.rest_unwatched = fn() {
      (rows.rest_unwatched)()
      rest()
    }
    a.refresh = refresh
    if !(chat_reads.get(k) is Some(now) && physical_equal(now, a)) {
      chat_reads[k] = a
      a.told_focus = ""
    }
    a.src = src
    a.view = view
    a.page = Some(v)
    if place.sight_now() is Some(s) {
      seen(s)
    }
  }
  // (as a frame has drawn it, shown and still made: register)
  let register_drawn = fn() {
    @ui.after_drawn_frame(fn() {
      if !drawn_once.val && v.alive() && @signals.untracked(shows) && @signals.untracked(on_stack) {
        register()
      }
    })
  }
  register_drawn()
  // (its page let go: where it was left this moment, before what its list counts goes; chat_read_left tells it)
  v.owns(fn() { if chat_reads.get(k) is Some(now) && physical_equal(now, a) { (a.refresh)() } }) |> ignore
  // (put by at rest on the stack's kept left: where it was left this moment, its page no longer one that shows it
  // (chat_read_left's `unless_shown`); taken back, its page again, and the chat's read again where it shows then, told
  // anew that it shows (its `shows` the same as it rested, so the reaction under tells nothing))
  // (what its list read let go of, as chat_read_left lets a drawn one's go: a page never drawn left by nothing else)
  let rest_undrawn = fn() {
    (rows.rest_unwatched)()
    rest()
  }
  // (put by now: between on_rest and its wake)
  let resting = Ref(false)
  v.on_rest(
    fn() {
      resting.val = true
      // (put by never drawn (an entry over another of its chat, kept left before a frame drew it): nothing told of it
      // leaving, what it read let go of all the same, as a drawn one's chat_read_left lets go)
      if !drawn_once.val {
        rest_undrawn()
        @ui.after_frame(fn() {
          if !drawn_once.val && v.alive() && resting.val {
            rest_undrawn()
          }
        })
      }
      if chat_reads.get(k) is Some(now) && physical_equal(now, a) {
        (a.refresh)()
      }
      if a.page is Some(pv) && pv.id() == v.id() {
        a.page = None
      }
    },
    wake=fn() {
      resting.val = false
      guard @signals.untracked(on_stack) else { return }
      guard drawn_once.val else {
        register_drawn()
        return
      }
      a.src = src
      a.view = view
      a.page = Some(v)
      if @signals.untracked(shows) {
        if !(chat_reads.get(k) is Some(now) && physical_equal(now, a)) {
          chat_reads[k] = a
          a.told_focus = ""
        }
        if place.sight_now() is Some(s) {
          seen(s)
        }
      }
    },
  )
  |> ignore
  v.reacts(fn() { scroll.in_hand() }, fn(held) { if !held { settle() } }, at_start=false)
  // (told only as what is in sight differs: as it comes to be drawn again, what is in sight then; a page kept as its chat
  // was left (chat_read_left: a place of the bar's, a page kept under another) the chat's again as it is drawn again,
  // told anew that it shows, so that it tells, and ⌘F goes along its list (chat_nodes_find_list), as a page made anew)
  v.reacts(
    shows,
    fn(on) {
      // (covered by another page over it (小屏's stack): the core told it is not before the eyes, its end not seen,
      // told again that it is as it is drawn again)
      guard on else {
        if chat_reads.get(k) is Some(now) && physical_equal(now, a) {
          // (and where it was left as it was covered, to the pixel, a glide still going or not: the page under another
          // may be let go before it is drawn again)
          (a.refresh)()
          let cv = @signals.untracked(view)
          if app_in_front() {
            chat_read_focus(src, r, cv, a, false)
          }
          chat_read_place(src, r, cv, a, exact=true)
        }
        return
      }
      guard drawn_once.val else {
        register_drawn()
        return
      }
      if !(chat_reads.get(k) is Some(now) && physical_equal(now, a)) {
        chat_reads[k] = a
        a.told_focus = ""
      }
      if place.sight_now() is Some(s) {
        seen(s)
      }
    },
    at_start=false,
  )
}

///|
/// The list ⌘F goes along where chat `r`'s page is made as nodes (find.mbt's FindList): the messages showing out of
/// what its list last had in sight as it was told the core (the first message in sight and the last; none where it was
/// told none), the list to a message as any go-to inside the chat is (sfbase's go_to: chat_goes_to brings it just under
/// the list's room; the words found are bold in every row while the bar is open in it, find_words_in, so a go-to's own
/// words are not kept for it), not flashing, the time the reader is at brought before the eyes (find_goes); nothing
/// left to go to as it is let go; how many times words are in each message asked that its rows hold as they draw them
/// (`drawn`).
fn chat_nodes_find_list(r : ChatRef) -> FindList {
  let k = r.station + "\u{1}" + r.session
  {
    showing: fn() {
      guard chat_reads.get(k) is Some(a) && a.sight is Some((s, rs)) else { return (-1.0, -1.0) }
      let seq = fn(key : String) {
        match rs.get(key).map(fn(row) { row.entry }) {
          Some(Said(m)) => Some(m.seq)
          _ => None
        }
      }
      let (from, to) = match (rs.index_of(s.first), rs.index_of(s.last)) {
        (Some(a), Some(b)) => (a, b)
        _ => return (-1.0, -1.0)
      }
      let mut first = -1.0
      for i = from; i <= to; i = i + 1 {
        if seq(rs.keys[i]) is Some(q) {
          first = q
          break
        }
      }
      let mut last = -1.0
      for i = to; i >= from; i = i - 1 {
        if seq(rs.keys[i]) is Some(q) {
          last = q
          break
        }
      }
      (first, last)
    },
    go: fn(seq, _) {
      find_goes[k] = seq
      @sfbase.go_to(r, seq, keep_place=false)
    },
    forget: fn() {
      @sfbase.go_tos.remove(k)
      find_goes.remove(k)
    },
    drawn: fn(words, seqs) {
      guard chat_reads.get(k) is Some(a) && a.sight is Some((_, rs)) else { return Map([]) }
      let out : Map[Double, Int] = Map([])
      for key in rs.keys {
        match rs.get(key) {
          Some({ entry: Said(m), .. }) if seqs.contains(m.seq) =>
            out[m.seq] = find_times_drawn(m, words)
          _ => ()
        }
      }
      out
    },
  }
}

///|
/// The core told chat `r` (view `v`) shows, its end seen or not (with `endSeq` from the laid-out Sight), and the last
/// message seen whole, as any changes.
fn chat_read_focus(src : Source, r : ChatRef, v : ChatView, a : ChatRead, end : Bool) -> Unit {
  let end_seq = if end {
    if a.sight_end_seq >= 0.0 {
      a.sight_end_seq
    } else {
      0.0
    }
  } else {
    -1.0
  }
  let said = "\{end} \{end_seq} \{a.whole}"
  guard !src.read_only && a.told_focus != said else { return }
  a.told_focus = said
  let chat = @sfbase.focus_chat(r, v, Some(end))
  if end {
    match chat {
      Object(o) => o["endSeq"] = Json::number(end_seq)
      _ => ()
    }
  }
  if a.whole >= 0.0 {
    match chat {
      Object(o) => o["seen"] = Json::number(a.whole)
      _ => ()
    }
  }
  (src.call)("client.focus", { "chat": chat }, @sfbase.answer_unread)
}

///|
/// The core told where chat `r` (view `v`) is (`chat.place`): the message at the top and its top under the list's in the
/// screen's pixels, none at its end; told again as the message at the top changes, and to the pixel as it is left
/// (`exact`). Kept for opening it again this run (sfbase's kept_places).
fn chat_read_place(src : Source, r : ChatRef, v : ChatView, a : ChatRead, exact~ : Bool, leaving? : Bool = false) -> Unit {
  guard a.sight is Some((s, _)) else { return }
  // (at its foot within half a point, as Scroll::at_foot_now has it: a fraction of a point short of it is no place)
  let end = !v.newer && (s.at_foot || s.from_foot <= 0.5)
  match a.top {
    Some(at) =>
      @sfbase.kept_places[r.station + "\u{1}" + r.session] = {
        top: at.seq,
        offset: at.off,
        piece: at.piece,
        piece_offset: at.piece_off,
        bottom: if !end {
          -1.0
        } else if leaving || !@signals.untracked(fn() { (src.topic_alive)() }) {
          // (its page let go of, or put by at rest, as it is left: its last message as its rows last had it, nothing of
          // the chat read again for it)
          a.last
        } else {
          match chat_said_ends(src, r, fn() { v }).1 {
            Some(m) => m.seq
            None => a.last
          }
        },
      }
    None => ()
  }
  guard v.thread is Some(th) && !src.read_only else { return }
  let place : Map[String, Json] = { "station": Json::string(r.station), "thread": Json::number(th) }
  let mut at = ""
  match a.top {
    Some(top) if !end => {
      place["seq"] = Json::number(top.seq)
      place["offset"] = Json::number((top.off * a.scale).round())
      at = Json::number(top.seq).stringify()
    }
    _ => ()
  }
  let said = Json::object(place).stringify()
  let rd = @sfbase.reading_of(r.station + "\u{1}" + r.session)
  if said == rd.told_place || (!exact && at == rd.told_at) {
    return
  }
  rd.told_place = said
  rd.told_at = at
  (src.call)("chat.place", Json::object(place), @sfbase.answer_unread)
}

///|
/// Chat `r`'s page made as nodes gone (sfapp's chat_left, as the page goes), its view `v` as it was left: the core told
/// it shows no more, and where it was left, to the pixel (once its list was laid out). False where no such page was the
/// chat's (the old page's, which tells it itself).
pub fn chat_read_left(src : Source, r : ChatRef, v : ChatView?, unless_shown? : Bool = false) -> Bool {
  let k = r.station + "\u{1}" + r.session
  guard chat_reads.get(k) is Some(a) else { return false }
  // (`unless_shown`: left by a place that is not the stack's (the board's side), the chat may be made on another page
  // already (opened over the whole page from it): that one's, nothing told of it left)
  if unless_shown && a.page is Some(pv) && pv.alive() {
    return true
  }
  // (where it was left this moment, a glide still going or not)
  (a.refresh)()
  chat_reads.remove(k)
  // (what it was to go to, and where back to, gone with it: not gone to in a page made for it later)
  @sfbase.go_tos.remove(k)
  @sfbase.go_to_passages.remove(k)
  @sfbase.go_to_words.remove(k)
  @sfbase.go_back_offsets.remove(k)
  @sfbase.go_back_pieces.remove(k)
  @sfbase.go_to_around.remove(k)
  @sfbase.place_forget(k)
  find_goes.remove(k)
  match v {
    Some(view) if !src.read_only => {
      (src.call)("client.focus", { "left": @sfbase.focus_chat(r, view, None) }, @sfbase.answer_unread)
      chat_read_place(src, r, view, a, exact=true, leaving=true)
    }
    _ => ()
  }
  // (what its list was read for that once more, nothing following it, let go of what that read)
  (a.rest_unwatched)()
  true
}

///|
/// The app gone behind (the shell's `behind`: a phone's app sent away, after which no frame may come): where each chat
/// open on a page made as nodes is, to the pixel as it is this moment (a glide still going or not), kept and told the
/// core, so that it opens there again whatever becomes of the app.
pub fn chat_reads_behind() -> Unit {
  for _, a in chat_reads {
    (a.refresh)()
    chat_read_place(a.src, a.chat, @signals.untracked(a.view), a, exact=true)
  }
}
