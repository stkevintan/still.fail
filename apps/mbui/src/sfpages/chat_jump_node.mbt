// What takes a chat's page made as nodes elsewhere in its list (the old list's to_latest and list_after's go-to, as
// results): the way back to the newest, and a message gone to. Out of what the list has in sight (ListPlace::on_sight,
// told at causes) and what the chat is told to go to (sfbase's go_tos, told by go_tos_said); its own state made with
// the list and let go with it (ChatJump). What floats over the list's foot with the way to the newest (the bell to what
// waits to be decided, the round button to 对话目录; 对话目录's rail at the list's right on a wide page), and what a
// message gone to shows of it (its flash; a search's words marked in it).

///|
/// What a chat's list keeps of its way to the newest: whether it is away from its end (more than a corner of the screen
/// as it was last in sight); its latest page asked (chat.latest), the list to its end as it comes, and whether the way to
/// the newest asked it (turning till it comes, pressed no more meanwhile); the first and the last
/// key it had in sight (none before it was laid out: what waits to be decided is out of view only once it is); whether
/// it stands where a go-to put it (1 brought, 2 there: the page before not asked till the reader moves it; 0 not) and
/// the message that go-to went to and its top under the list's (-1 none); where the page last put the list itself (a
/// block brought, its offset as ListPlace::bring takes it and whether what it marks sought was brought too: chat_stand)
/// while the reader has not moved it since, whether it is still on its way there, and where that block's top then
/// stood under what covers the list's top (none where it lies further down than the block after the first in sight:
/// then where the first in sight stood); the message a go-to last asked the
/// window moved about (chat.around, -1 none); the message whose ask the bell went to (-1 none)
/// and that message's key while its ask is what a go-to brings before the eyes ("" none); the row last gone to that
/// flashes, the moment it was gone to and the passage of it a quote that led there quoted, where its words have it ("" none: the row lit
/// whole); the row a search opened the chat at and its words,
/// marked there for as long as the list is; 对话目录's round button while it shows (what ⌘G opens the outline beside);
/// where the reader is as the list last had it in sight (the message at the top of what shows, whether at the chat's
/// end: what the rail's long tick follows); 对话目录's rail while it shows (what ⌘G opens it beside where the round
/// button does not show); whether it is on its glide back to its end that the way to the newest asked (the old list's
/// `gliding`: that way shows none meanwhile), till it gets there or another way stops it (the hand, another ask, the
/// glide ended short of it, the list going further from its end: the wheel's), and how far from its end it was last
/// seen on it; the moment its list was first in sight (none yet: +inf): what floats over its foot stands
/// as it is found till then, coming and going by its motion only after (the old page's floats_settled).
priv struct ChatJump {
  away : @signals.Signal[Bool]
  gliding : @signals.Signal[Bool]
  mut glide_left : Double
  mut sight_from : Double
  mut latest : Bool
  latest_asked : @signals.Signal[Bool]
  sight : @signals.Signal[(String, String, Int)?]
  put : @signals.Signal[Int]
  mut went : (Double, Double)
  mut stand : (String, Int, ChatStandAt, Bool)?
  mut stand_cover : Double
  mut landing : Bool
  mut stood : (Double?, String, Double)
  mut around : Double
  mut beyond : Double
  mut ask_to : Double
  asked_card : @signals.Signal[String]
  flashed : @signals.Signal[(String, Double, String)]
  found : @signals.Signal[(String, Array[String])]
  mut outline_at : @view.View?
  reader : @signals.Signal[(Double, Bool)]
  mut rail_at : @view.View?
}

///|
/// Where the page puts a block of a chat's list (chat_stand), kept as such while the reader has not moved it, so that
/// what covers the list's top coming to be another height (the bar's second row measured, or pressed open or shut:
/// chat_stand_again) leaves it where it was meant.
priv enum ChatStandAt {
  /// its top `kept` under the list's window's top, as a place is kept (sfbase's KeptPlace, the core's `atOffset`, a
  /// place to go back to): where the reader left it, whatever covers the top
  AtWindow(Double)
  /// its top `into` over the foot of what covers the list's top (under it where less than 0: ListPlace::bring's
  /// offset), wherever that comes to be: a go-to's, the unread line's, the core's `at` with no offset
  UnderBar(Double)
}

///|
/// ListPlace::bring's offset of a block standing at `at`, what covers the list's top `cover` tall.
fn chat_stand_offset(at : ChatStandAt, cover : Double) -> Double {
  match at {
    AtWindow(kept) => @sfbase.kept_place_under(kept, cover)
    UnderBar(into) => into
  }
}

///|
/// None away yet, nothing asked, nothing gone to, no round button.
fn ChatJump::new() -> ChatJump {
  {
    away: @signals.signal(false, same=fn(a, b) { a == b }),
    gliding: @signals.signal(false, same=fn(a, b) { a == b }),
    glide_left: @double.infinity,
    sight_from: @double.infinity,
    latest: false,
    latest_asked: @signals.signal(false, same=fn(a, b) { a == b }),
    sight: @signals.signal(None, same=fn(a, b) { a == b }),
    put: @signals.signal(0, same=fn(a, b) { a == b }),
    went: (-1.0, 0.0),
    stand: None,
    stand_cover: 0.0,
    landing: false,
    stood: (None, "", 0.0),
    around: -1.0,
    beyond: -1.0,
    ask_to: -1.0,
    asked_card: @signals.signal("", same=fn(a, b) { a == b }),
    flashed: @signals.signal(("", -1.0, ""), same=fn(a, b) { a == b }),
    found: @signals.signal(("", []), same=fn(a, b) { a == b }),
    outline_at: None,
    reader: @signals.signal((-1.0, true), same=fn(a, b) { a == b }),
    rail_at: None,
  }
}

///|
/// How far from its end the list is before the way to the newest shows (list_after's `away`: a corner of the screen).
let to_newest_away : Double = 120.0

///|
/// The top of slice `slice` of block `k` under what covers the list's top as `s` (what the list of rows `rs` has in
/// sight) counts it: the first in sight's, or the one right after it's (where the first's foot is: its next slice, or
/// the next key's first after its last); none for one further down (none of their heights is in what is told).
fn chat_top_in_sight(s : @view.Sight[String], rs : ChatBodyNow, k : String, slice? : Int = 0) -> Double? {
  if s.first == k && s.slice == slice {
    return Some(-s.into)
  }
  if s.first == k && s.slice + 1 == slice {
    return Some(s.tall - s.into)
  }
  guard slice == 0 && s.slice == rs.slices(s.first) - 1 else { return None }
  match rs.index_of(s.first) {
    Some(i) if rs.keys.get(i + 1) == Some(k) => Some(s.tall - s.into)
    _ => None
  }
}

///|
/// Where the reader is (chat_reader_at): the message at the top and how far its top is under the list's window's top,
/// as kept (sfbase's kept_place_of); of a message drawn in pieces, the piece at the top (-1 a message of one) and how far
/// that piece's top is under it, as kept.
priv struct ChatReaderAt {
  seq : Double
  off : Double
  piece : Int
  piece_off : Double
}

///|
/// Where the reader is in what the list of rows `rs` has in sight (`s`), as the chat's reading keeps it (sfbase's
/// Reading's top_seq and top_off) and tells it the core (chat_read_node): the first message whose block shows under what
/// covers the list's top (`cover` tall) more than the room the list keeps under it (`top` the two: what of a block over
/// one gone to shows there, whatever the room over that one, is a tail of what was read; the last in sight whatever
/// shows of it), its
/// top as kept (sfbase's kept_place_of); past a row that is no message (the page before's row, the unread line, what is
/// sent from here), the message after it (its top counted where the row is the first in sight's next, else the next's:
/// how far further down is not told). One read for every way the reader's place is taken (a go-to's, ⌘F's start, the
/// outline's, the place told the core). None where what shows holds no message.
fn chat_reader_at(
  s : @view.Sight[String],
  rs : ChatBodyNow,
  place : @view.ListPlace[String],
  cover : Double,
  top : Double,
) -> ChatReaderAt? {
  guard rs.index_of(s.first) is Some(i) else { return None }
  // (the block looked at: its key's place among the rows, which slice of it, how far its top is under the window's top,
  // and whether it is the first in sight. Past the first in sight where little of it shows: the next slice of the same
  // key where it has one, else the next key's first, its top where the first's block ends)
  let mut j = i
  let mut slice = s.slice
  let mut at = -s.into
  let mut first = true
  while j < rs.keys.length() {
    let k = rs.keys[j]
    match rs.get(k).map(fn(row) { row.entry }) {
      Some(Said(m)) if !first ||
        s.tall - s.into > top - cover + 0.5 ||
        (k == s.last && slice >= s.last_slice) => {
        let top = at
        // (a slice of a long message: that slice's top as well, and the whole message's by how far down it the slice
        // lies as the list counts them)
        let sliced = rs.slices(k) > 1
        // (its slices over it not all measured (read up into it from its foot): how far down it the slice lies only
        // guessed; the first message after it whose top is in sight taken instead, where one is, its top as measured,
        // what is kept and told then known to the pixel)
        if slice > 0 && place.span_between(k, k, to_slice=slice, measured=true) is None {
          let mut q = j + 1
          while q < rs.keys.length() {
            let qk = rs.keys[q]
            match rs.get(qk).map(fn(row) { row.entry }) {
              Some(Said(next)) =>
                match place.span_between(s.first, qk, from_slice=s.slice, measured=true) {
                  Some(sp) => {
                    let at = @sfbase.kept_place_of(sp - s.into, cover)
                    return Some({ seq: next.seq, off: at, piece: if rs.slices(qk) > 1 { 0 } else { -1 }, piece_off: at })
                  }
                  None => break
                }
              _ => ()
            }
            if qk == s.last {
              break
            }
            q = q + 1
          }
        }
        let span = if slice > 0 { place.span_between(k, k, to_slice=slice).unwrap_or(0.0) } else { 0.0 }
        return Some({
          seq: m.seq,
          off: @sfbase.kept_place_of(top - span, cover),
          piece: if sliced { slice } else { -1 },
          piece_off: @sfbase.kept_place_of(top, cover),
        })
      }
      _ => ()
    }
    if first && slice + 1 < rs.slices(k) {
      slice = slice + 1
      at = s.tall - s.into
      first = false
      continue
    }
    if k == s.last {
      break
    }
    at = if first {
      s.tall - s.into
    } else {
      match rs.keys.get(j + 1) {
        Some(nk) => place.span_between(s.first, nk, from_slice=s.slice).unwrap_or(s.tall) - s.into
        None => s.tall - s.into
      }
    }
    j = j + 1
    slice = 0
    first = false
  }
  None
}

///|
/// The last message the list of rows `rs` has in sight (`s`; -1 none): what ⌘F starts at lies between it and the
/// reader's (sfbase's Reading's bottom_seq).
fn chat_bottom_in_sight(s : @view.Sight[String], rs : ChatBodyNow) -> Double {
  guard rs.index_of(s.last) is Some(j) else { return -1.0 }
  let mut i = j
  while i >= 0 {
    match rs.get(rs.keys[i]).map(fn(row) { row.entry }) {
      Some(Said(m)) => return m.seq
      _ => ()
    }
    if rs.keys[i] == s.first {
      break
    }
    i = i - 1
  }
  -1.0
}

///|
/// Block `k` of chat `chat`'s list (its slice `slice`: View::scrolls_window's `slices`) brought to its top by the page
/// (`offset` as ListPlace::bring takes it, `sought` what it marks sought too, gliding where `glide`): where the list
/// stands now, kept as such till the reader moves it (chat_stand_left), so that what covers its top grown meanwhile (the
/// bar's second row measured: chat_stand_again) puts it there again.
fn chat_stand(
  jump : ChatJump,
  place : @view.ListPlace[String],
  k : String,
  at : ChatStandAt,
  cover : Double,
  slice? : Int = 0,
  sought? : Bool = false,
  glide? : Bool = false,
) -> Unit {
  jump.stand = Some((k, slice, at, sought))
  jump.stand_cover = cover
  if jump.gliding.untracked() {
    jump.gliding.set(false)
  }
  jump.landing = true
  jump.stood = (None, "", 0.0)
  place.bring(k, slice~, offset=chat_stand_offset(at, cover), glide~, sought~)
}

///|
/// The list put again where the page last put it (chat_stand), what covers its top coming to be `to` tall from `now`
/// (as it is drawn now, on its way there): that block's place under it as it was meant, not under the cover's foot as
/// it was then, gliding there as the cover goes. Nothing where the reader has moved it since.
fn chat_stand_again(jump : ChatJump, place : @view.ListPlace[String], to : Double, now : Double) -> Unit {
  guard jump.stand is Some((k, slice, at, sought)) else { return }
  jump.landing = true
  jump.stood = (None, "", 0.0)
  // (kept as it was meant: where a place kept has it in the window, the cover laid out at once (its second row first
  // measured), nothing of it moving; the cover pressed open or shut (on its way), as much further down or up, gliding
  // there with it, not under its second row; under the cover as it comes to be, gliding there as the cover goes)
  let gliding = (to - now).abs() > 0.5
  let offset = match at {
    AtWindow(kept) =>
      if gliding {
        let next = kept + (to - jump.stand_cover)
        jump.stand = Some((k, slice, AtWindow(next), sought))
        @sfbase.kept_place_under(next, now)
      } else {
        @sfbase.kept_place_under(kept, now)
      }
    UnderBar(into) => into - (to - now)
  }
  jump.stand_cover = to
  place.bring(k, slice~, offset~, glide=gliding, sought~)
}

///|
/// The reader moved chat `chat`'s list (the hand on it, the wheel, a key that scrolls it, the page asked it elsewhere):
/// no longer where the page put it, nor where a go-to put it (the page before asked as it nears it again), and what that
/// go-to lit no longer where the reader is (sfbase's Reading's flash: reader_top's).
fn chat_stand_left(jump : ChatJump, chat : String) -> Unit {
  jump.stand = None
  jump.landing = false
  jump.stood = (None, "", 0.0)
  if jump.put.untracked() != 0 {
    jump.put.set(0)
  }
  let rd = @sfbase.reading_of(chat)
  rd.flash = ""
  rd.flash_passage = ""
}

///|
/// Which slice of the row `k` of chat `chat`'s message `m` (among the list's rows `rs`) holds what a go-to brings before
/// the eyes: its last where its ask is what is gone to (`card`); where it is drawn in slices (chat_body_pieces), the one
/// the passage a quote quoted is in (`passage`), else the one where the `at`th time of `words` is (markdown_piece_with);
/// its first else.
fn chat_piece_sought(
  rs : ChatBodyNow,
  k : String,
  m : Message,
  card : Bool,
  passage : String,
  words : Array[String],
  at : Int,
) -> Int {
  let n = rs.slices(k)
  guard n > 1 else { return 0 }
  if card {
    return n - 1
  }
  guard passage != "" || words.length() > 0 else { return 0 }
  guard chat_body_pieces(Said(m)) is Some(pieces) else { return 0 }
  let b = @sf.markdown_piece_with(m.text, m.md, pieces, passage~, words~, at~)
  if b >= 0 && b < n {
    b
  } else {
    0
  }
}

///|
/// The message each chat's ⌘F last went to (chat_nodes_find_list's `go`), by chat: gone to without flashing, its
/// time the reader is at brought before the eyes (find_at_in), taken as it is gone to.
let find_goes : Map[String, Double] = Map([])

///|
/// Chat `r`'s list (`jump` what it keeps of it, `place`, its rows `rows`, its view `view`, `width` wide, `scroll` what it
/// scrolls by): what it has in sight kept
/// (whether it is away from its end; where the reader is, for a go-to inside the chat to keep: sfbase's Reading,
/// keep_place_of: chat_reader_at), the kept place
/// forgotten at its end; and the message the chat is to go to (sfbase's go_tos) brought to the list's top, its words
/// (what is read in it, under the room over its block) `top` under the list's (the chat's bar and the room under it;
/// places counted under what covers it, `cover` tall: the bar), whatever the room over its block (the list's first, one
/// joined to the one before, one apart: chat_body_gap_room), or where the reader was (go_back_to's offset, as kept:
/// sfbase's kept_place_under), once its row is among the keys (a notice folding it, where one does); while it is not, the
/// window moved about it (chat.around, `src` asked) where it is before the window and the chat has more before, or
/// after it and the chat more after; given up where none is left, said where the chat had it nowhere. Asked as the
/// list is made, as its keys change and as the chat is told to go somewhere.
fn chat_goes_to(
  v : @view.View,
  src : Source,
  r : ChatRef,
  jump : ChatJump,
  place : @view.ListPlace[String],
  scroll : @view.Scroll,
  rows : ChatBodyList,
  view : () -> ChatView,
  cover : () -> Double,
  top : () -> Double,
  width : () -> Double,
  shows : () -> Bool,
) -> Unit {
  let chat = r.station + "\u{1}" + r.session
  // (where the reader is said to be, chat `r`'s reading (sfbase's), as what shows `s` has it: as it is placed, and as
  // its page shows again with nothing of it moved (taken back from the stack's kept left, its reading let go of as it
  // left: chat.mbt's), where the list's sight is not told again)
  let sync_reading_with = fn(s : @view.Sight[String], cv : ChatView, rs : ChatBodyNow) {
    let at_foot = s.at_foot || s.from_foot <= 0.5
    // (placed while it shows: sfbase's keep_place_of)
    let rd = @sfbase.reading_of(chat)
    rd.placed = @signals.untracked(shows)
    match chat_reader_at(s, rs, place, @signals.untracked(cover), @signals.untracked(top)) {
      Some(at) => {
        rd.top_seq = at.seq
        rd.top_off = at.off
        rd.top_piece = at.piece
        rd.top_piece_off = at.piece_off
      }
      None => ()
    }
    rd.bottom_seq = chat_bottom_in_sight(s, rs)
    // (standing where a go-to put it: the reader at the message gone to, put under the bar, whatever of the one over
    // it shows under the bar too: reader_top's)
    match jump.went {
      (seq, off) if jump.put.untracked() == 2 && seq >= 0.0 => {
        rd.top_seq = seq
        rd.top_off = off
        rd.top_piece = -1
        rd.top_piece_off = 0.0
      }
      _ => ()
    }
    rd.far = cv.newer || (!at_foot && s.from_foot > s.shows)
    // (at the chat's end: what the steps to what a person said and 对话目录 take the reader to be at, outline_current)
    rd.at_end = at_foot && !cv.newer
    if at_foot && !cv.newer {
      @sfbase.place_forget(chat)
    }
    // (where the reader is, told: the rail's long tick)
    jump.reader.set((rd.top_seq, rd.at_end))
  }
  let sync_reading = fn(s : @view.Sight[String]) {
    let cv = @signals.untracked(view)
    let rs = @signals.untracked(fn() { rows.read() })
    sync_reading_with(s, cv, rs)
  }
  place.on_sight(fn(s) {
    let cv = @signals.untracked(view)
    let rs = @signals.untracked(fn() { rows.read() })
    // (at its foot within half a point, as Scroll::at_foot_now has it: what the way to the newest and the place told go by)
    let at_foot = s.at_foot || s.from_foot <= 0.5
    // (first in sight: what floats over its foot stands as it is found then, chat_float_stand)
    // (not while the chat is not there yet (no thread, nothing but its top and its empty row): what comes as it is
    // first there is there at once, its buttons with it)
    if jump.sight_from == @double.infinity &&
      (cv.thread is Some(_) || rs.keys.iter().any(fn(k) { k != "top" && k != "empty" })) {
      jump.sight_from = v.cause_at()
    }
    // (on its glide back to its end: there, the glide over short of it (what it holds changed under it), or going
    // further from it (the wheel's), no longer)
    let mut stop_gliding = false
    if jump.gliding.untracked() {
      if at_foot || (!place.asking() && scroll.glides_till() is None) || s.from_foot > jump.glide_left + 0.5 {
        stop_gliding = true
      } else {
        jump.glide_left = s.from_foot
      }
    }
    // (scrolled by the hand once it was in sight, shown: what floats over its foot comes and goes on its way; as it is
    // first in sight, at once, @view.transition)
    let away_now = !at_foot && s.from_foot > to_newest_away
    let sight_now = Some((s.first, s.last, s.last_slice))
    if stop_gliding || away_now != jump.away.untracked() || sight_now != jump.sight.untracked() {
      if v.cause_at() > jump.sight_from && @signals.untracked(shows) {
        @view.transition(fn() {
          if stop_gliding {
            jump.gliding.set(false)
          }
          jump.away.set(away_now)
          jump.sight.set(sight_now)
        })
      } else {
        if stop_gliding {
          jump.gliding.set(false)
        }
        jump.away.set(away_now)
        jump.sight.set(sight_now)
      }
    }
    // (where the page put it: there once what it asked is done, its block's top as it then stood; moved off it since,
    // the reader's (a message arriving or growing at the foot, a page before come in over it, a row over it measured
    // anew move none of it: the list holds what is read))
    match jump.stand {
      // (not while a glide it asked goes on: where it stood is taken once it ends)
      Some((k, slice, _, _)) if !place.asking() && scroll.glides_till() is None =>
        if jump.landing {
          jump.landing = false
          jump.stood = (chat_top_in_sight(s, rs, k, slice~), s.first, s.into)
          if jump.put.untracked() == 1 {
            jump.put.set(2)
          }
        } else {
          let moved = match (jump.stood, chat_top_in_sight(s, rs, k, slice~)) {
            ((Some(was), _, _), Some(now)) => (now - was).abs() > 0.5
            ((Some(_), _, _), None) => true
            ((None, first, into), _) => first != s.first || (into - s.into).abs() > 0.5
          }
          if moved {
            chat_stand_left(jump, chat)
          }
        }
      _ => ()
    }
    sync_reading_with(s, cv, rs)
  })
  // (the hand on it: the reader's from then)
  v.reacts(
    fn() { scroll.in_hand() },
    fn(held) {
      if held && jump.stand is Some(_) {
        chat_stand_left(jump, chat)
      }
      // (the hand's from then: no longer on the glide the way to the newest asked)
      if held && jump.gliding.untracked() {
        jump.gliding.set(false)
      }
    },
    at_start=false,
  )
  v.reacts(
    shows,
    fn(on) {
      match place.sight_now() {
        Some(s) if on => sync_reading(s)
        _ => @sfbase.reading_of(chat).placed = false
      }
    },
    at_start=false,
  )
  // (put by on the stack's kept left and taken back (its reading let go of as it left: chat.mbt's), showing all along:
  // said again as it wakes, nothing of it moved)
  v.on_rest(fn() { @sfbase.reading_of(chat).placed = false }, wake=fn() {
    if @signals.untracked(shows) {
      match place.sight_now() {
        Some(s) => sync_reading(s)
        None => ()
      }
    }
  })
  |> ignore
  // (given up: nothing left to go to, said where the chat had messages and none is it)
  let give_up = fn(said : Bool) {
    @sfbase.go_tos.remove(chat)
    @sfbase.go_to_passages.remove(chat)
    @sfbase.go_to_words.remove(chat)
    @sfbase.go_back_offsets.remove(chat)
    @sfbase.go_back_pieces.remove(chat)
    @sfbase.go_to_around.remove(chat)
    find_goes.remove(chat)
    jump.around = -1.0
    jump.beyond = -1.0
    jump.ask_to = -1.0
    if said {
      @sfbase.toast_later(@sf.t("web-main.chat.messageGone"))
    }
  }
  let goes = fn() {
    guard @sfbase.go_tos.get(chat) is Some(target) else { return }
    let rs = @signals.untracked(fn() { rows.read() })
    let cv = @signals.untracked(view)
    // (the first and the last message the window holds, none where it holds none (a message's seq may be below 0: one
    // sent from here); the row of the one gone to, else of a notice folding it)
    let mut first : Double? = None
    let mut last : Double? = None
    let mut at : (String, Message)? = None
    let mut folded : (String, Message)? = None
    for k in rs.keys {
      match rs.get(k).map(fn(row) { row.entry }) {
        Some(Said(m)) => {
          if first is None {
            first = Some(m.seq)
          }
          match last {
            Some(l) if m.seq <= l => ()
            _ => last = Some(m.seq)
          }
          if m.seq == target && at is None {
            at = Some((k, m))
          } else if folded is None && m.seq < target && target <= m.notice_last_seq {
            folded = Some((k, m))
          }
        }
        _ => ()
      }
    }
    let at = match at {
      Some(_) => at
      None => folded
    }
    match at {
      Some((k, m)) => {
        // (the passage a quote that led here quoted, where the message's words have it: lit alone as it flashes,
        // chat_passage_lit; else the row lit whole, Chat.tsx Quotes' jump)
        let passage = match @sfbase.go_to_passages.get(chat) {
          Some(p) if !m.system && @sf.find_passage(m.text, p) is Some(_) => p
          _ => ""
        }
        @sfbase.go_tos.remove(chat)
        @sfbase.go_to_passages.remove(chat)
        @sfbase.go_to_around.remove(chat)
        let back = @sfbase.go_back_offsets.get(chat)
        @sfbase.go_back_offsets.remove(chat)
        let back_piece = @sfbase.go_back_pieces.get(chat)
        @sfbase.go_back_pieces.remove(chat)
        let words = @sfbase.go_to_words.get(chat).unwrap_or([])
        @sfbase.go_to_words.remove(chat)
        // (⌘F's: no flash, the time the reader is at brought before the eyes; the bell's: its ask)
        let finds = find_goes.get(chat) == Some(target)
        find_goes.remove(chat)
        let card = jump.ask_to == target
        jump.ask_to = -1.0
        jump.around = -1.0
        jump.beyond = -1.0
        // (the slice of a long message that holds what was meant in it: its block brought, View::sought's there)
        // (back where the reader was: the slice that was at the top, where the place said one and it is one still)
        let back_at = match (back, back_piece) {
          (Some(_), Some((pc, poff))) if pc >= 0 && pc < rs.slices(k) => Some((pc, poff))
          _ => None
        }
        let pk = if back_at is Some((b, _)) {
          b
        } else if back is Some(_) {
          0
        } else if finds {
          chat_piece_sought(rs, k, m, false, "", find_words_in(chat), find_k())
        } else {
          chat_piece_sought(rs, k, m, card, passage, words, @sf.found_all)
        }
        // (where it is put, as kept: a message gone to with what is read in it at the list's top, under the bar and its
        // room, the room over its block over that; a slice after its first has none over it)
        let c = @signals.untracked(cover)
        let gap = match rs.get(k) {
          Some(row) if pk == 0 => chat_body_gap_room(row.gap, @signals.untracked(width))
          _ => 0.0
        }
        let off = match back {
          Some(off) => off
          None => @sfbase.kept_place_of(@signals.untracked(top) - c - gap, c)
        }
        // (where the reader is: the message, where its first slice is the one brought)
        jump.went = if pk == 0 { (target, off) } else { (-1.0, 0.0) }
        // (back where the reader was: where it was in the window, as kept (its piece's top, where that is brought),
        // whatever covers its top; else under what covers it as a go-to puts it)
        let stand_at = match (back_at, back) {
          (Some((_, poff)), _) => AtWindow(poff)
          (None, Some(off)) => AtWindow(off)
          (None, None) => UnderBar(@sfbase.kept_place_under(off, c))
        }
        // (what was meant in it before the eyes too, where it lies low in a long message: a search's words, a quote's
        // passage, the bell's ask; not back where the reader was: ListPlace::bring's `sought`, what its words mark:
        // View::sought. One in sight already glides there, the eyes taken along to it as it lights (what is between
        // measured as it shows); one out of sight, its place only counted, there at once: `glide`)
        let in_sight = match jump.sight.untracked() {
          Some((first, last, _)) =>
            match (rs.keys.search(first), rs.keys.search(k), rs.keys.search(last)) {
              (Some(a), Some(i), Some(b)) => a <= i && i <= b
              _ => false
            }
          None => false
        }
        // (what it marks said before it is brought, so the row reads what it marks sought as the list lays it out
        // there: back where the reader was, nothing of it shown; ⌘F's, its words marked by the find, nothing flashing;
        // a search's, its words marked, nothing flashing; else it flashes, from now)
        jump.asked_card.set(if card { k } else { "" })
        if back is None && !finds {
          if words.length() > 0 {
            jump.found.set((k, words))
          } else {
            let at = v.cause_at()
            jump.flashed.set((k, at, passage))
            @sfbase.flash_rest_nodes.val = at + @sfbase.flash_ms
            // (the chat's reading told the message gone to and what of it is lit, as the old page's list tells it:
            // where the reader is, reader_top's)
            let rd = @sfbase.reading_of(chat)
            rd.flash = m.ts
            rd.flash_passage = passage
          }
        }
        jump.put.set(1)
        chat_stand(jump, place, k, stand_at, c, slice=pk, glide=back is None && in_sight, sought=back is None)
      }
      None if first is Some(f) && last is Some(l) && target >= f && target <= l => give_up(true)
      // (past all the device holds of the chat, none said to come after it: not on the device yet (a notification
      // tapped before what it tells was brought), waited for as the chat's rows come, never said gone; the hand on the
      // list lets it go)
      None if !cv.newer && (match last { Some(l) => target > l; None => true }) => jump.beyond = target
      None => {
        let before = cv.more && (match first { Some(f) => target < f; None => true })
        let after = cv.newer && (match last { Some(l) => target > l; None => true })
        match cv.thread {
          // (not in the chat's window, the chat holding more before or after it: the window moved about it
          // (chat.around), once for each; already moved so as it was asked (a quote's: go_to_quoted))
          Some(th) if before || after =>
            if @sfbase.go_to_around.get(chat) == Some(target) {
              @sfbase.go_to_around.remove(chat)
              jump.around = target
            } else if jump.around != target {
              jump.around = target
              (src.call)(
                "chat.around",
                { "station": Json::string(r.station), "thread": Json::number(th), "seq": Json::number(target) },
                fn(res) {
                  guard @sfbase.go_tos.get(chat) == Some(target) && jump.around == target else { return }
                  match res {
                    // (the core holds it nowhere: none to go to)
                    Ok(Object(o)) if o.get("seq") is Some(Null) => give_up(true)
                    Ok(_) => ()
                    Err(_) => give_up(false)
                  }
                },
              )
            }
          // (none left to bring in: it is not in the chat)
          _ => give_up(first is Some(_))
        }
      }
    }
  }
  v.reacts(fn() { ((rows.keys)(), @sfbase.go_tos_said.get()) }, fn(_) { goes() })
  // (a message waited for past the chat's end, the reader's hand on the list meanwhile: let go of, unsaid)
  v.reacts(
    fn() { scroll.in_hand() },
    fn(held) {
      if held && jump.beyond >= 0.0 && @sfbase.go_tos.get(chat) == Some(jump.beyond) {
        give_up(false)
      }
    },
    at_start=false,
  )
  // (its latest page come in place of a window short of the chat's end, asked: the list at its end)
  v.reacts(
    fn() { view().newer },
    fn(newer) {
      if !newer {
        jump.latest_asked.set(false)
      }
      if !newer && jump.latest {
        jump.latest = false
        place.to_end(glide=false)
      }
    },
    at_start=false,
  )
}

///|
/// Chat `r`'s list (`jump` what it keeps of it, `place`, its view `view`) taken back to the newest: to where a go-to
/// inside the chat kept the reader first (go_back_to), else to its end, asking the chat's latest page first where the
/// window is short of it. The way to the newest pressed, and its key (chat.latest: chat_body_node's action).
fn chat_to_newest(
  src : Source,
  r : ChatRef,
  jump : ChatJump,
  place : @view.ListPlace[String],
  view : () -> ChatView,
) -> Unit {
  // (its latest page asked and still coming: nothing more till it comes, as the old page's to_latest took no press
  // meanwhile)
  if @signals.untracked(fn() { chat_latest_coming(src, r, jump, view()) }) {
    return
  }
  if (src.asks_outline)() && @sfbase.go_back_to(r) {
    return
  }
  let cv = @signals.untracked(view)
  // (where it could not be had, the list no longer waiting for it: chat_goes_to's `newer`)
  if @sfbase.chat_latest_now(src, r, cv, @sf.t("web-main.chat.toLatest"), failed=fn() {
      jump.latest = false
      jump.latest_asked.set(false)
    }) {
    jump.latest = true
    jump.latest_asked.set(true)
  } else {
    chat_to_end(jump, place)
  }
}

///|
/// Whether chat `r`'s latest page (`cv` its view as it is now) is asked and still coming in place of a window short of
/// its end: asked from here (`jump`'s `latest_asked`, from the press on) or under way as the core's `doing` says (asked
/// elsewhere too: the menu bar's), as the old page's to_latest's `coming`.
fn chat_latest_coming(src : Source, r : ChatRef, jump : ChatJump, cv : ChatView) -> Bool {
  cv.newer &&
  (
    jump.latest_asked.get() ||
    (match cv.thread {
      Some(th) => @sfbase.core_doing(src, ["chat.latest"], [("station", r.station), ("thread", th.to_int().to_string())])
      None => false
    })
  )
}

///|
/// The list (`place`, `jump` what it keeps of it) back to its end, gliding there where it is near (ListPlace::to_end):
/// away from it, on that glide till it gets there (ChatJump's `gliding`), the way to the newest gone meanwhile, as the
/// old list's.
fn chat_to_end(jump : ChatJump, place : @view.ListPlace[String]) -> Unit {
  // (where the way shows: at its end already, nothing to hide)
  if jump.away.untracked() {
    jump.glide_left = @double.infinity
    jump.gliding.set(true)
  }
  place.to_end()
}

///|
/// Whether the way to the newest shows: the list away from its end and not on its glide back there, or the window
/// short of the chat's end.
fn chat_jumps(jump : ChatJump, view : () -> ChatView) -> Bool {
  (jump.away.get() && !jump.gliding.get()) || view().newer
}

///|
/// Whether 对话目录's round button shows: with the way to the newest, where the outline may be asked for (not in a replay
/// of a run from before it, Source's `asks_outline`) and the chat is made.
fn chat_outlines(src : Source, jump : ChatJump, view : () -> ChatView) -> Bool {
  (src.asks_outline)() && chat_jumps(jump, view) && view().thread is Some(_)
}

///|
/// The round buttons floating over the list's foot `foot` at its top (a row of no height, they standing on it: where
/// the composer is, whatever its height), right over the send button (the composer's column `width` across, `float_in`
/// in from its side, float_lift over the top of what the composer shows, `drop` under the foot's top as the composer
/// tells it): 待处理's bell (chat_ask_shown), 对话目录's (chat_outlines) and the way to
/// the newest (chat_jumps) one over another on one capsule of glass (@sf.float_pill_group_node), as many as show; the
/// way to the newest under it on a button of its own while it says how many new messages wait (words the capsule has
/// no room for). Shown while any is, fading in and out over float_ms.
fn chat_floats_node(
  foot : @view.View,
  src : Source,
  r : ChatRef,
  jump : ChatJump,
  place : @view.ListPlace[String],
  view : () -> ChatView,
  rows : ChatBodyList,
  width : () -> Double,
  tips : @sf.TipLayer,
  stint : () -> Int,
  drop? : (@view.View, Double) -> Double = fn(_, _) { 0.0 },
) -> Unit {
  let chat = r.station + "\u{1}" + r.session
  let ask_shown = chat_ask_shown(jump, view, rows)
  let outline_shown = fn() { chat_outlines(src, jump, view) }
  let latest_shown = fn() { chat_jumps(jump, view) }
  let latest_count = fn() {
    let cv = view()
    if cv.newer && cv.unread > 0.0 {
      @sf.t("web-main.chat.newMessages", args=[("n", cv.unread.to_int().to_string())])
    } else {
      ""
    }
  }
  let latest_has_count = fn() { latest_shown() && latest_count() != "" }
  let latest_in_pill = fn() { latest_shown() && latest_count() == "" }
  let pill_shown = fn() { ask_shown() || outline_shown() || latest_in_pill() }
  // (not in a replay of a run from before the outline, whose way to the newest went to the end alone: `asks_outline`)
  let back = fn() { (src.asks_outline)() && @sfbase.place_kept(chat) }
  let latest_label = fn() { @sf.t(if back() { "web-main.outline.back" } else { "web-main.chat.toLatest" }) }
  let latest_press = fn() { chat_to_newest(src, r, jump, place, view) }
  // (its latest page asked and coming: turning, pressed no more meanwhile, as the old page's to_latest)
  let latest_busy = fn() { chat_latest_coming(src, r, jump, view()) }
  // (the column's right edge where the composer's capsules end, `float_in` in from the composer's side, for what is
  // drawn of each: the room `reach` round a float_button_node's taken back)
  let right_in = fn(v : @view.View, reach : Double) {
    let c = @sfbase.column_laid(chat, v)
    let w = width() + c.by
    (w - composer_width_on(w, c)) / 2.0 + float_in - reach
  }
  // (which of them show on the capsule, in this order)
  let pill_keys = fn() {
    let keys : Array[String] = []
    if ask_shown() {
      keys.push("ask")
    }
    if outline_shown() {
      keys.push("outline")
    }
    if latest_in_pill() {
      keys.push("latest")
    }
    keys
  }
  foot.show(pill_shown, at_once=true, leave=float_ms, fn(stand) {
    chat_float_stand(stand, jump, chat)
    // (as found as it comes and as an answer tells it: at once; else one coming or going opens or shuts its room on the
    // capsule from that cause (View::comes); none left as it fades out, the capsule kept as it was till it is gone)
    let shown_keys : @signals.Signal[Array[String]] = @signals.signal(@signals.untracked(pill_keys))
    let g = @sf.float_pill_group_node(stand, fn(g) {
      // (one slot a button, made once for its key as it comes: a moment's one, two or three)
      g.each(fn() { shown_keys.get() }, fn(k) { k }, fn(s, k) {
        match k.untracked() {
          "ask" =>
            @sf.float_pill_item_node(s, "bell", fn() { @sf.t("web-main.chat.asks.go") }, chat_ask_press(src, r, jump, place, view), tips~)
            |> ignore
          "outline" => chat_outline_item(s, src, r, jump, view, tips, stint)
          _ =>
            @sf.float_pill_item_node(s, "arrow-down", latest_label, latest_press, busy=latest_busy, tips~, shortcut="chat.latest")
            |> ignore
        }
      })
    })
    stand.reacts(
      pill_keys,
      fn(want) {
        guard !want.is_empty() && stand.alive() else { return }
        if stand.cause_at() <= jump.sight_from || @view.answering_now() {
          shown_keys.set(want)
        } else {
          @view.transition(within=g, fn() { shown_keys.set(want) })
        }
      },
      at_start=false,
    )
    // (over the way to the newest saying how many wait, float_gap over it, while it shows: moved there from its cause,
    // found there as it comes and as an answer tells it)
    let over_at = fn() { if latest_has_count() { @sf.float_button_side + float_gap } else { 0.0 } }
    let over = @motion.NodeWay::new(@signals.untracked(over_at))
    stand.reacts(
      over_at,
      fn(to) {
        if stand.cause_at() <= jump.sight_from || @view.answering_now() {
          over.put(to)
        } else {
          over.go(g, to, @motion.move_damped)
        }
      },
      at_start=false,
    )
    g.margin(By(fn() { (0.0, 0.0, right_in(g, 0.0), float_lift - drop(g, width()) + over.shown(g)) })) |> ignore
  })
  foot.show(latest_has_count, at_once=true, leave=float_ms, fn(stand) {
    chat_float_stand(stand, jump, chat)
    let reach = @sf.float_button_reach
    let o = @sf.float_button_node(stand, "arrow-down", latest_label, latest_press, count=latest_count, busy=latest_busy, tips~, shortcut="chat.latest")
    o.margin(By(fn() { (0.0, 0.0, right_in(o, reach), float_lift - reach - drop(o, width())) })) |> ignore
  })
}

///|
/// A stand `stand` of chat_floats_node's over the list's foot: a row of no height, what it holds standing on its foot
/// at its right, as wide as its column is drawn, where it is drawn, as the composer under it is, whatever the column is
/// laid out at on its way to another width (@sfbase.column_laid; over the composer's send button all the way), fading
/// in and out over float_ms.
fn chat_float_stand(stand : @view.View, jump : ChatJump, chat : String) -> Unit {
  stand.row(Is(true)).lies_along(Is(End)).lines_up(Is(Some(End))).height(Is(Some(0.0))) |> ignore
  // (none at rest: bound once a column has first set off on such a way, at that cause, never before)
  let bound = Ref(false)
  stand.reacts(fn() { @sfbase.column_set_off_count() > 0 }, fn(going) {
    if going && !bound.val && stand.alive() {
      bound.val = true
      stand
      .margin(By(fn() { (0.0, 0.0, -@sfbase.column_laid(chat, stand).by, 0.0) }))
      .offset(By(fn() { (-@sfbase.column_laid(chat, stand).across, 0.0) }))
      |> ignore
    }
  })
  // (fading in and out over float_ms (the old page's float_trans), leaving over as long; standing as it is found as its
  // list is first in sight and as an answer tells it (ChatJump's `sight_from`, @view.answering), coming by nothing)
  let settled = stand.cause_at() <= jump.sight_from || @view.answering_now()
  let presence = @motion.presence_in(stand, @motion.tween(float_ms, ease=Out), from=if settled { 1.0 } else { 0.0 })
  stand.alpha(By(fn() { presence() * @sf.sheet_foot_alpha(stand) })) |> ignore
}

///|
/// 对话目录's round button (outline_float's) in `o` (chat_floats_node's capsule); pressed, chat `r`'s outline beside it
/// (a sheet on Small), at the message the reader is at (outline_current: what the list last had in sight, sfbase's
/// Reading); what ⌘G opens it beside while it shows (`jump`'s outline_at). Its page's time on top `stint`.
fn chat_outline_item(
  o : @view.View,
  src : Source,
  r : ChatRef,
  jump : ChatJump,
  view : () -> ChatView,
  tips : @sf.TipLayer,
  stint : () -> Int,
) -> Unit {
  let chat = r.station + "\u{1}" + r.session
  let button : Ref[@view.View] = Ref(o)
  let press = fn() {
    let cv = @signals.untracked(view)
    guard cv.thread is Some(th) else { return }
    let rd = @sfbase.reading_of(chat)
    let current = outline_current(said_in_view(chat_whole(src, r, cv)), rd.top_seq, rd.at_end)
    open_outline(src, r, th, current, from=Node(button.val), side=Left, stint=@signals.untracked(stint))
  }
  button.val = @sf.float_pill_item_node(o, "list", fn() { @sf.t("web-main.outline.title") }, press, tips~, shortcut="chat.outline")
  // (⌘G's outline beside it while it shows: chat_body_node's chat.outline)
  jump.outline_at = Some(button.val)
  o.owns(fn() { if jump.outline_at.map(fn(b) { b.id() }) == Some(button.val.id()) { jump.outline_at = None } }) |> ignore
  // (a screen's fixture: the outline opened from it as it shows, its words typed, its field taking the keys, in the
  // button's moment's turn: outline_presets)
  match outline_presets.get(chat) {
    Some(words) => {
      outline_presets.remove(chat) |> ignore
      o.at_moment(o.cause_at(), fn() {
        let cv = @signals.untracked(view)
        guard cv.thread is Some(th) else { return }
        let rd = @sfbase.reading_of(chat)
        let current = outline_current(said_now(src, r, chat_whole(src, r, cv)), rd.top_seq, rd.at_end)
        open_outline(src, r, th, current, from=Node(button.val), side=Left, keys=true, stint=@signals.untracked(stint), typed=words)
      })
      |> ignore
    }
    None => ()
  }
}

///|
/// What 对话目录's rail of chat `r` (its view `view`) shows: each day's count of what people said, their seqs and each
/// day's heading as the core says it (今天, 11月19日), oldest first (the core's chatOutline, subscribed only while it may show), while the outline may be asked for (Source's
/// `asks_outline`), the chat is made, the list `width` wide leaves the rail room at its right (rail_fits) and people
/// said three things or more (rail_least); none otherwise. `outline`: the chat's outline, read only then.
fn chat_rail_said(
  src : Source,
  outline : @signals.Computed[@sfbase.TopicState],
  view : () -> ChatView,
  width : () -> Double,
) -> (Array[Int], Array[Double], Array[String])? {
  guard (src.asks_outline)() && rail_fits(width()) && view().thread is Some(_) else { return None }
  let value = outline.get().value
  let said = outline_seqs(value)
  guard said.length() >= rail_least else { return None }
  let days = items(value, "days")
  Some(
    (
      days.map(fn(d) { items(Some(d), "seqs").length() }),
      said,
      days.map(fn(d) {
        let day = text(Some(d), "day")
        if day != "" {
          day
        } else {
          text(Some(d), "date")
        }
      }),
    ),
  )
}

///|
/// A tick of the rail as its row draws it (rail_ticks' RailTick, laid out one under another): its place, the message it
/// stands for (its place among what people said), how long its turn is, whether it is the reader's, whether a day starts
/// at it after another (a day's gap over it, a dot in its middle) and that day's heading (`name`: said by a tip as the
/// pointer is in that gap; "" where no day starts at it).
#derive(Eq)
priv struct ChatRailTick {
  i : Int
  at : Int
  turn : Int
  reader : Bool
  day : Bool
  name : String
}

///|
/// The rail's ticks in a row, one after another, for what `said` says (chat_rail_said's), the reader at `reader`
/// (ChatJump's: the message at the top of what shows, whether at the end), the chat's newest message `latest`, in
/// `most` tall.
fn chat_rail_ticks(
  said : (Array[Int], Array[Double], Array[String]),
  reader : (Double, Bool),
  latest : Double,
  most : Double,
) -> Array[ChatRailTick] {
  let (days, seqs, names) = said
  // (the headings of the days anyone said anything on, as rail_ticks' groups are those days)
  let names = {
    let out : Array[String] = []
    for i, k in days {
      if k > 0 {
        out.push(names.get(i).unwrap_or(""))
      }
    }
    out
  }
  let current = outline_current(seqs, reader.0, reader.1)
  let at = seqs.search(current).unwrap_or(seqs.length() - 1)
  let out : Array[ChatRailTick] = []
  for g, group in rail_ticks(days, at, rail_turns(seqs, latest), most) {
    for j, t in group {
      let day = g > 0 && j == 0
      let name = if day { names.get(g).unwrap_or("") } else { "" }
      out.push({ i: out.length(), at: t.at, turn: t.turn, reader: t.reader, day, name })
    }
  }
  out
}

///|
/// Index (`t.i`) of the tick in `ticks` nearest to vertical coordinate `y` within `chat_rail_press` (exact mirror of
/// its `min_h=rail_press_w`, `py=rail_pad`, `justify=JCenter` layout, with no layout read-back). Returns -1 when empty.
fn chat_rail_tick_index_at(ticks : Array[ChatRailTick], y : Double) -> Int {
  guard !ticks.is_empty() else { return -1 }
  let room = tick_thick + tick_gap.px()
  let tall = ticks.fold(init=0.0, fn(a, t) { a + room + (if t.day { tick_day_gap.px() } else { 0.0 }) })
  let rail_h = dmax(rail_press_w, tall + 2.0 * rail_pad.px())
  let mut top = dmax(rail_pad.px(), (rail_h - tall) / 2.0)
  let mut best = -1
  let mut far = 1.0e9
  for t in ticks {
    if t.day {
      top = top + tick_day_gap.px()
    }
    let d = (top + room / 2.0 - y).abs()
    if d < far {
      far = d
      best = t.i
    }
    top = top + room
  }
  best
}

///|
/// Index (`t.i`) of the first tick of the day whose gap (tick_day_gap over that tick) holds vertical coordinate `y`
/// within `chat_rail_press`, laid out as chat_rail_tick_index_at has it; -1 where `y` is on no day's gap.
fn chat_rail_day_at(ticks : Array[ChatRailTick], y : Double) -> Int {
  guard !ticks.is_empty() else { return -1 }
  let room = tick_thick + tick_gap.px()
  let tall = ticks.fold(init=0.0, fn(a, t) { a + room + (if t.day { tick_day_gap.px() } else { 0.0 }) })
  let rail_h = dmax(rail_press_w, tall + 2.0 * rail_pad.px())
  let mut top = dmax(rail_pad.px(), (rail_h - tall) / 2.0)
  for t in ticks {
    if t.day {
      // (the gap and half a tick_gap either side of it: the rooms of the ticks over and under it keep the rest)
      if y >= top - tick_gap.px() / 2.0 && y < top + tick_day_gap.px() + tick_gap.px() / 2.0 {
        return t.i
      }
      top = top + tick_day_gap.px()
    }
    top = top + room
  }
  -1
}

///|
/// What of the rail the pointer at vertical coordinate `y` within `chat_rail_press` is on, as one piece (the press's
/// View::pointer_piece keeps only the first `piece` it is asked with, so a day's gap and a tick are told apart in one):
/// `-2 - t.i` in the gap over tick `t.i` (chat_rail_day_at), else the nearest tick's `t.i` (chat_rail_tick_index_at); -1
/// where there are no ticks.
fn chat_rail_piece_at(ticks : Array[ChatRailTick], y : Double) -> Int {
  let day = chat_rail_day_at(ticks, y)
  if day >= 0 {
    -2 - day
  } else {
    chat_rail_tick_index_at(ticks, y)
  }
}

///|
/// Which of `ticks` (chat_rail_ticks') a press at `y` down the rail's press `h` tall lies on: the one whose middle is
/// nearest, as they are laid out in its middle (each tick_gap and its line tall, a day's tick_day_gap over the first of
/// a day). None where there are none.
fn chat_rail_tick_at(ticks : Array[ChatRailTick], y : Double, h : Double) -> ChatRailTick? {
  let room = tick_thick + tick_gap.px()
  let tall = ticks.fold(init=0.0, fn(a, t) { a + room + (if t.day { tick_day_gap.px() } else { 0.0 }) })
  let mut top = (h - tall) / 2.0
  let mut best : ChatRailTick? = None
  let mut far = 1.0e9
  for t in ticks {
    if t.day {
      top = top + tick_day_gap.px()
    }
    let d = (top + room / 2.0 - y).abs()
    if d < far {
      far = d
      best = Some(t)
    }
    top = top + room
  }
  best
}

///|
/// 对话目录's rail (the old view's outline_rail, made once as nodes): where the list `width` wide leaves it room at its
/// right, while chat_rail_said says what it shows, a strip of ticks, one for each message a person said, as long as its
/// turn, the reader's (ChatJump's `reader`) longest and in the ink; standing in the middle of the list `anchor` (what
/// holds the page's list), at its right, clear of its scroll bar. Made in the list's foot `foot` (a stand of no height
/// there), so a wheel over it is the list's as anywhere (what holds it the list's foot); placed beside nothing but the
/// list, out of any column's flow, so it comes and goes at once, with the page as it is made, never making its way in
/// (no cause of its own: the outline answered, the page made wider). Pressed with the hand where a tick is, the chat goes
/// to its message (@sfbase.go_to: flashing, where the reader was kept for ↓); pressed by the keys or a screen reader,
/// the outline opens beside it. As tall as a press at least, its ticks half the list's height at most (of the window's,
/// under the bar's `top`): past that a steady map of the whole chat (rail_ticks). Its tip says ⌘G's 对话目录. While it
/// shows, ⌘G opens the outline beside it (`jump`'s rail_at) where the round button does not show.
fn chat_rail_node(
  foot : @view.View,
  src : Source,
  r : ChatRef,
  jump : ChatJump,
  view : () -> ChatView,
  width : () -> Double,
  top : () -> Double,
  anchor : @view.View,
  tips : @sf.TipLayer,
  stint : () -> Int,
  scroll? : @view.Scroll,
  room? : () -> Double = fn() { 0.0 },
  bar? : () -> Double = top,
) -> Unit {
  let said = @signals.computed(
    fn(was) {
      // (its outline asked only where the rail asks it and has room for it: chat_rail_said's own guard, before the topic)
      guard (src.asks_outline)() && rail_fits(width()) else { return None }
      match view().thread {
        Some(th) => {
          let outline = src.topic("chatOutline", outline_params(r, th))
          let t = outline.get()
          // (asked again, as a page taken back from the stack's kept left reads it: what it last said till the core's
          // first answer, never the rail let go of and made again; sfbase's asked_again.mbt)
          if t.value is None && t.error is None && (src.asks_outline)() && rail_fits(width()) {
            match was {
              Some(Some(prev)) => return Some(prev)
              _ => ()
            }
          }
          chat_rail_said(src, outline, view, width)
        }
        None => None
      }
    },
    same=fn(a, b) {
      match (a, b) {
        (Some((d1, s1, n1)), Some((d2, s2, n2))) => d1 == d2 && s1 == s2 && n1 == n2
        (None, None) => true
        _ => false
      }
    },
  )
  foot.box(fn(stand) {
    stand.height(Is(Some(0.0))) |> ignore
    stand.show(fn() { said.get() is Some(_) }, at_once=true, fn(o) {
      o
      // (in the middle of what shows of the list between its bar's foot (`bar`) and the composer's own room under it (its
      // foot as tall as it is laid out less the room under the last row, `room`), as the old page's outline_rail)
      .beside(
        anchor.id(),
        side=Right,
        along=Middle,
        offset=-(rail_press_w + @ui.scroll_bar_room),
        padding=0.0,
        flip=false,
        piece=fn(w, h) {
          let t = bar()
          let under = match scroll {
            Some(s) => dmax(0.0, s.foot_tall() - room())
            None => 0.0
          }
          Some((0.0, t, w, dmax(0.0, h - t - under)))
        },
      )
      // (at its column's right as that is drawn on its way to another width: @sfbase.column_laid)
      .offset(By(fn() {
        let c = @sfbase.column_laid(r.station + "\u{1}" + r.session, o)
        (c.by - c.across, 0.0)
      }))
      |> ignore
      let ticks = @signals.computed(fn(_) {
        match said.get() {
          Some(s) => {
            let latest = chat_said_latest(src, r, view)
            let h = o.window_h()
            let most = dmax(0.0, (h - top()) * rail_share - 2.0 * rail_pad.px())
            chat_rail_ticks(s, jump.reader.get(), latest, most)
          }
          None => []
        }
      }, same=fn(a, b) { a == b })
      let go = fn(t : ChatRailTick) {
        guard @signals.untracked(fn() { said.get() }) is Some((_, seqs, _)) && seqs.get(t.at) is Some(seq) else { return }
        @sfbase.go_to(r, seq)
      }
      // (the keys' or a screen reader's press: the outline beside it, at the message the reader is at)
      let hover_close : Ref[() -> Unit] = Ref(fn() {  })
      @sf.action_box_node(o, fn() { @sf.t("web-main.outline.title") }, fn(press) {
        (hover_close.val)()
        let cv = @signals.untracked(view)
        guard cv.thread is Some(th) && @signals.untracked(fn() { said.get() }) is Some((_, seqs, _)) else { return }
        let (seq, at_end) = jump.reader.untracked()
        let current = outline_current(seqs, seq, at_end)
        open_outline(src, r, th, current, from=Node(press), side=Left, along=Middle, stint=@signals.untracked(stint))
      }, fn(press) {
        @sf.style_node(press, fn() { chat_rail_press })
        // (what of the rail the pointer is on: a day's gap or a tick, asked of the press once, chat_rail_piece_at)
        let pointed_piece = fn() -> Int {
          if press.pointed_in() {
            press.pointer_piece(fn(_px, py) { chat_rail_piece_at(ticks.get(), py) })
          } else {
            -1
          }
        }
        // (the heading of the day whose gap the pointer is in: said by a tip, no tick lit nor the outline opened there)
        let pointed_day = fn() -> String {
          let p = pointed_piece()
          if p <= -2 {
            match ticks.get().get(-2 - p) {
              Some(t) => t.name
              None => ""
            }
          } else {
            ""
          }
        }
        let hovered_idx = fn() -> Int? {
          if @sf.pointer_rests() && pointed_day() == "" {
            let i = pointed_piece()
            if i >= 0 { Some(i) } else { None }
          } else {
            None
          }
        }
        let hovered_is = press.selected(hovered_idx)
        let hovered_seq = fn() -> Double {
          match hovered_idx() {
            Some(i) =>
              match (ticks.get().get(i), said.get()) {
                (Some(tk), Some((_, seqs, _))) => seqs.get(tk.at).unwrap_or(-1.0)
                _ => -1.0
              }
            None => -1.0
          }
        }
        let panel_held : Ref[() -> Bool] = Ref(fn() { false })
        let panel_held_ver : @signals.Signal[Int] = @signals.signal(0, same=fn(a, b) { a == b })
        let hand = @sf.hover_panel_node(
          tips,
          press,
          @sf.t("web-main.outline.title"),
          fn(col, close) {
            let cv = @signals.untracked(view)
            guard cv.thread is Some(th) && @signals.untracked(fn() { said.get() }) is Some((_, seqs, _)) else { return }
            let (seq, at_end) = jump.reader.untracked()
            let current = outline_current(seqs, seq, at_end)
            open_outline_hover_body(
              col,
              src,
              r,
              th,
              current,
              close,
              @signals.untracked(stint),
              hovered_seq,
              fn() { @sf.pointer_rests() && press.pointed_in() },
              fn(h) {
                panel_held.val = h
                panel_held_ver.set(panel_held_ver.untracked() + 1)
                col.owns(fn() {
                  panel_held.val = fn() { false }
                  panel_held_ver.set(panel_held_ver.untracked() + 1)
                })
                |> ignore
              },
            )
          },
          held=fn() {
            panel_held_ver.get() |> ignore
            (panel_held.val)()
          },
          pointed=fn() { press.pointed_in() && pointed_day() == "" },
        )
        hover_close.val = hand.close
        // (by the press pointed at, not `within`: that marks the press as only pointing (View::points), which takes its
        // presses, its tap gesture and its hand cursor away; beside the pointer, as far left of it as the longest tick
        // reaches in from the press's right and a little more, so from wherever in the press the pointer is it covers
        // no tick)
        @sf.tip_node(tips, press, pointed_day, side=Left, gap=rail_day_tip_gap, at_pointer=true) |> ignore
        let closer_id = rail_hover_register(hand.close)
        press
        // (as the old composer's foot came down at once at words sent, drawn from where it stood down to where it is
        // placed on the composer's ground's way, never stepped by half of that in a frame, the user 2026-11-17:
        // @sfbase.chat_foot_dropped)
        .moved_by(
          fn(_, _, t) { (0.0, @sfbase.chat_foot_dropped_off(r.station + ":" + r.session, t).0) },
          fn(_, _) { @sfbase.chat_foot_dropped_off(r.station + ":" + r.session, 0.0).1 },
        )
        .cursor(Is(Some(Hand)))
        // (the hand's, a finger's or the pointer's: the message of the tick it went down on; touch long-press opens the
        // hover panel)
        .gesture(
          @ui.touch_slop(),
          tap=fn(d) {
            (hand.close)()
            match chat_rail_tick_at(@signals.untracked(fn() { ticks.get() }), d.y, d.h) {
              Some(t) => go(t)
              None => ()
            }
          },
          hold=(@ui.long_press_ms, fn(_) { if !@sf.pointer_rests() { (hand.hold)() } }),
        )
        |> ignore
        // (its ticks changed as the chat goes on while it shows (a message said, the reader moved along it): a live cause
        // of its own, judged as it reads them, so what comes on it and what moves along it goes its way, @view.transition;
        // as it is first there, at once)
        let judged : Ref[Array[ChatRailTick]?] = Ref(None)
        press.each(
          fn() {
            let ts = ticks.get()
            match judged.val {
              Some(was) if !physical_equal(was, ts) && @signals.untracked(@ui.app_visible) =>
                @view.transition(within=o, fn() {  })
              _ => ()
            }
            judged.val = Some(ts)
            ts
          },
          // (each by its place on the rail and whether a day starts at it: as a message comes the ticks there already
          // keep theirs (the map's stand each for a share of the chat, which moves as it grows: by what they stand for,
          // all of them would be made again); one a day comes to start or stops starting at is another, going as it
          // comes on the column's one way, never a gap's height switched in a frame)
          fn(t) { (t.i, t.day) },
          fn(row, t) {
            let idx = t.untracked().i
            // (a day's gap over the first of a day after another, a dot in its middle saying a day starts there)
            if t.untracked().day {
              row.box(fn(g) {
                @sf.style_node(g, fn() { rail_day_gap })
                g.height(Is(Some(tick_day_gap.px()))) |> ignore
                g.box(fn(dot) { @sf.style_node(dot, fn() { rail_day_dot }) }) |> ignore
              })
              |> ignore
            }
            row.box(fn(room) {
              @sf.style_node(room, fn() { tick_room })
              room.box(fn(line) {
                line
                .width(By(fn() {
                  let tk = t.get()
                  Some(
                    if tk.reader {
                      tick_long
                    } else if hovered_is(idx) {
                      tick_hover_w(tk.turn)
                    } else {
                      tick_w(tk.turn)
                    },
                  )
                }))
                .height(Is(Some(tick_thick)))
                .radius(Is(tick_thick / 2.0))
                .ground(By(fn() {
                  let tk = t.get()
                  @ui.tree_theme().color(if tk.reader { Fg } else if hovered_is(idx) { Muted } else { Line })
                }))
                |> ignore
              })
              |> ignore
            })
            |> ignore
          },
        )
        jump.rail_at = Some(press)
        press.owns(fn() {
          rail_hover_unregister(closer_id)
          if jump.rail_at.map(fn(b) { b.id() }) == Some(press.id()) {
            jump.rail_at = None
          }
        })
        |> ignore
      })
      |> ignore
    })
  })
  |> ignore
}

///|
/// A day's gap on the rail: across the press, what it holds in its middle at its right.
// kept across runs: a value (no field of it changes)
let rail_day_gap : @ui.Style = @ui.css("w=Full align=AEnd justify=JCenter")

///|
/// The dot in a day's gap: S1 round, in the ticks' own colour (the line's), so a day starting reads as one and not as
/// ticks gone missing, and no louder than the ticks it parts.
// kept across runs: a value (no field of it changes)
let rail_day_dot : @ui.Style = @ui.css("w=S1 h=S1 radius=Full bg=Line")

///|
/// How far left of the pointer a day's tip stands: past the longest tick (tick_long, rail_pad in from the press's
/// right) and S1 more, so it covers none of the rail's ticks.
let rail_day_tip_gap : Double = tick_long + rail_pad.px() + @ui.Space::px(S1)

///|
/// The rail's press (rail_press's): 44 wide and 44 tall at least, its ticks one under another in its middle at its
/// right, rail_pad in over, under and at its right.
// kept across runs: a value (no field of it changes)
let chat_rail_press : @ui.Style = @ui.style(
  w=Fixed(rail_press_w),
  min_h=Fixed(rail_press_w),
  align=AEnd,
  justify=JCenter,
  py=rail_pad,
  pr=rail_pad,
)

///|
/// Whether 待处理's bell (to_ask's: the core's `asks`) shows in chat_floats_node's capsule: while any of chat `view`'s
/// asks is not among the rows the list has in sight (once it has any; `rows` its rows): a post's under its words, seen
/// where its last piece is (a long message's ask under the last of them).
fn chat_ask_shown(jump : ChatJump, view : () -> ChatView, rows : ChatBodyList) -> () -> Bool {
  fn() {
    let v = view()
    let asks = asks_of(v)
    guard asks.length() > 0 && jump.sight.get() is Some((first, last, last_slice)) else { return false }
    let rs = rows.read()
    // (each post asked about seen among the rows in sight: shown while any of them is not, as the old page's
    // asks_in_view, every one in view to hide it; the one the chat's end says it stands on (the core's `stateAsk`)
    // seen where that line is, not its post, as ask_rows_of has it)
    let seen : Array[Double] = []
    match rs.index_of(first) {
      Some(start) => {
        let reversed = match rs.index_of(last) {
          Some(end_idx) => end_idx < start
          None => false
        }
        if !reversed {
          let mut i = start
          while i < rs.keys.length() {
            let k = rs.keys[i]
            match rs.get(k).map(fn(row) { row.entry }) {
              Some(Said(m)) if asks.contains(m.seq) &&
                v.state_ask != Some(m.seq) &&
                !seen.contains(m.seq) &&
                // (what it asks under its last slice: seen where that is, the last in sight's only where it is that slice)
                (k != last || last_slice >= rs.slices(k) - 1) => seen.push(m.seq)
              Some(State(_, _, _)) =>
                match v.state_ask {
                  Some(seq) if asks.contains(seq) && !seen.contains(seq) => seen.push(seq)
                  _ => ()
                }
              _ => ()
            }
            if k == last {
              break
            }
            i = i + 1
          }
        }
      }
      None => ()
    }
    asks.iter().any(fn(a) { !seen.contains(a) })
  }
}

///|
/// 待处理's bell pressed, in chat `r`: the next ask the next time (ask_turns), the list (`place`) to where it is: the
/// chat's end where it is the one the chat's end says it stands on (the line saying so, as it is seen there), else the
/// chat to its post (@sfbase.go_to) with its ask brought before the eyes (ChatJump's ask_to: the post's last piece, the
/// ask marked sought there), not the post's top, a long report's screens over it.
fn chat_ask_press(
  src : Source,
  r : ChatRef,
  jump : ChatJump,
  place : @view.ListPlace[String],
  view : () -> ChatView,
) -> () -> Unit {
  let chat = r.station + "\u{1}" + r.session
  fn() {
    let asks = asks_of(@signals.untracked(view))
    guard asks.length() > 0 else { return }
    let turn = ask_turns.get(chat).unwrap_or(0)
    let seq = asks[turn % asks.length()]
    ask_turns[chat] = turn + 1
    let cv = @signals.untracked(view)
    if cv.state_ask == Some(seq) {
      // (the one the chat's end stands on: the chat's end, its latest page first where the window is short of it)
      if @sfbase.chat_latest_now(src, r, cv, @sf.t("web-main.chat.toLatest"), failed=fn() {
          jump.latest = false
          jump.latest_asked.set(false)
        }) {
        jump.latest = true
        jump.latest_asked.set(true)
      } else {
        chat_to_end(jump, place)
      }
      return
    }
    jump.ask_to = seq
    @sfbase.go_to(r, seq)
  }
}

///|
/// A message lit as all of it, in `v` (the node the list draws its band in, under all the rows of the message, across
/// the list from edge to edge: chat_body_bands): its flash (message `key` gone to, `flash` chat_flash_way's, not a
/// passage of it: chat_passage_lit's then) in the theme's secondary emphasis ground, and over that its menu's band
/// (`band` message_menu_band_way's) in the pointer's ground, composited as View::ground_over is. One binding.
fn chat_band_lit(v : @view.View, key : () -> String, jump : ChatJump, flash : @motion.Way, band : @motion.Way) -> Unit {
  v.ground(
    By(fn() {
      let flashed = match chat_gone(jump) {
        (k, _, "") if k == key() => lit_by(@sf.theme().flash_bg(), flash.shown_on(v))
        _ => 0L
      }
      @view.blend_ground(flashed, lit_by(@ui.tree_theme().color(Hover), band.shown_on(v)))
    }),
  )
  |> ignore
}

///|
/// The passage of row `key` a quote that led there quoted (ChatJump's `flashed`), lit where its words have it as the
/// row's flash goes (chat_flash_way, in node `v`, what makes the row): its words and the ground it is drawn on now, the
/// accent's as a passage picked in a message is (picked_alpha), as lit as the flash is; ("", clear) for another row, or
/// one lit whole. What a message's words mark it by (passage_marks). As lit as the row's flash is (`flash`, read in
/// node `v`: chat_flash_way's for it).
fn chat_passage_lit(v : @view.View, key : () -> String, jump : ChatJump, flash : @motion.Way) -> () -> (String, Int64) {
  fn() {
    match chat_gone(jump) {
      (k, _, passage) if k == key() && passage != "" =>
        (passage, lit_by(@sf.alpha(@sf.theme().p.accent, @sfbase.picked_alpha), flash.shown_on(v)))
      _ => ("", 0L)
    }
  }
}

///|
/// How lit row `key` gone to is (0 to 1), followed in node `b` (what makes the row): coming in over flash_in_ms on the
/// ease-out, held to flash_held_ms, gone by flash_ms on Leave, from the moment the chat went to it (ChatJump's
/// `flashed`: the press's, its cause), made then or later; with motion reduced lit whole for flash_ms, then not. Its
/// row's key as it is now (`key`): taken for another row's (a block put by and taken again: View::scrolls_window's
/// `reused`), the flash of the one before let go at once, and that row's as a row made for it would have it.
fn chat_flash_way(b : @view.View, key : () -> String, jump : ChatJump) -> @motion.Way {
  @motion.flash_way_keyed(
    b,
    key,
    fn() {
      let (k, at, _) = chat_gone(jump)
      (k, at)
    },
    in_ms=@sfbase.flash_in_ms,
    held_ms=@sfbase.flash_held_ms,
    total_ms=@sfbase.flash_ms,
    hold=fn() { @sfbase.flash_held.val },
  )
}

///|
/// The row the chat last went to that flashes, the moment it was gone to and the passage of it lit ("" none), followed.
fn chat_gone(jump : ChatJump) -> (String, Double, String) {
  jump.flashed.get()
}

///|
/// Colour `c` (0xRRGGBBAA) as clear as `k` (0 to 1) of it; none at all (0) where none of it shows, so a box whose ground
/// it is draws nothing of its own then (a row gone to at rest, a message's menu shut): not a clear ground over every
/// row, a box of its own whose height what judges a drawn box's size (ui's sizes_steady) reads as the row's.
fn lit_by(c : Int64, k : Double) -> Int64 {
  let a = (c & 0xFFL).to_double() * (if k < 0.0 { 0.0 } else if k > 1.0 { 1.0 } else { k })
  let a = (a + 0.5).to_int64()
  if a <= 0L {
    0L
  } else {
    (c & 0xFFFFFF00L) | a
  }
}
