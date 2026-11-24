// A chat's list's rows by key (chat_body_node's, where its source keeps the chat's messages by key: sfbase's
// ChatMessages): each message's rows (the unread line over it where it is there, its blocks, what went elsewhere after
// it) worked out of that message alone, its own computed, and the list's keys of each message's keys and the chat's
// head (its page before, its emptiness, what went elsewhere before its messages; what is newer, where it stands and
// its agents at work after them). So a message updated in place works out that message's rows and reads none of
// the others; the list's keys are made again only as a message comes, goes or moves, or a message's own keys change
// (one gone elsewhere after it), and a row reads only what it is; how many slices a message's words are drawn in
// (View::scrolls_window's `slices`) worked out of that message's JSON alone, its own computed too (chat_said_slices_raw). What is sent from here and what waits in the outbox are
// chat_body_rows' still: while there is any, the list goes by it (ChatBodyList::of_made).

///|
/// Build `(first_index, dup_last_index)` maps for `ks`.
/// `first_index` keeps the first occurrence (matching `Array::search`); `dup_last_index` is only populated when a key
/// appears more than once (matching reverse-scan last-occurrence lookup with zero extra entries for unique keys).
fn chat_keys_index_of(ks : Array[String]) -> (Map[String, Int], Map[String, Int]) {
  let first : Map[String, Int] = Map([], capacity=ks.length())
  let dup_last : Map[String, Int] = Map([])
  for i, k in ks {
    if first.contains(k) {
      dup_last[k] = i
    } else {
      first[k] = i
    }
  }
  (first, dup_last)
}

///|
/// Single-slot cache returning `(first_index, dup_last_index)` for `ks`, rebuilt only when `ks` changes identity,
/// paired with a `clear` closure called when the page parks so parked views release the cached array and maps.
fn chat_keys_index_cache() -> ((Array[String]) -> (Map[String, Int], Map[String, Int]), () -> Unit) {
  let cached_ks : Ref[Array[String]?] = Ref(None)
  let cached_idx : Ref[(Map[String, Int], Map[String, Int])] = Ref((Map([]), Map([])))
  let lookup = fn(ks : Array[String]) -> (Map[String, Int], Map[String, Int]) {
    match cached_ks.val {
      Some(prev) if physical_equal(prev, ks) => cached_idx.val
      _ => {
        let m = chat_keys_index_of(ks)
        cached_ks.val = Some(ks)
        cached_idx.val = m
        m
      }
    }
  }
  let clear = fn() -> Unit {
    cached_ks.val = None
    cached_idx.val = (Map([]), Map([]))
  }
  (lookup, clear)
}

///|
/// A chat's list as its rows read it: its keys (told only as they change) and each row by its key (told only as that
/// row is another).
priv struct ChatBodyList {
  keys : () -> Array[String]
  /// cached `(first_index, dup_last_index)` maps for a `keys` snapshot returned by `self.keys`
  keys_index : (Array[String]) -> (Map[String, Int], Map[String, Int])
  row : (String) -> ChatBodyRow?
  /// how many slices row `k` is drawn in (chat_body_pieces': a long agent's message a block a piece; 1 for any other),
  /// told only as that changes
  slices : (String) -> Int
  /// how many of what was sent from here the core's rows took over, as they did (told as one more is)
  taken : () -> Int
  /// what it worked out that nothing follows let go of what that read (read untracked as its list was laid out, told
  /// what is in sight, or read once more as its page is left): as its page is put by at rest, and after that last read
  rest_unwatched : () -> Unit
}

///|
/// Whether the list has a row of key `k`, as its keys say.
fn ChatBodyList::has(self : ChatBodyList, k : String) -> Bool {
  (self.row)(k) is Some(_)
}

///|
/// The list of rows chat_body_rows made, as `made` gives them as they change (each read of a row reads all of them).
fn ChatBodyList::of_made(made : () -> ChatBodyRows, rest? : () -> Unit = fn() {  }) -> ChatBodyList {
  let (keys_index, clear_index) = chat_keys_index_cache()
  {
    keys: fn() { made().keys },
    keys_index,
    row: fn(k) { made().rows.get(k) },
    slices: fn(k) { made().rows.get(k).map_or(1, fn(r) { r.slices }) },
    taken: fn() {
      made() |> ignore
      0
    },
    rest_unwatched: fn() {
      clear_index()
      rest()
    },
  }
}

///|
/// The rows of one message (chat_body_parts_by's): their keys in order, each row by its key.
priv struct ChatBodyParts {
  keys : Array[String]
  rows : Map[String, ChatBodyRow]
}

///|
/// The rows message `m` is shown in, as chat_body_rows has them: the unread line over it where the chat's unread line
/// (`unread`) is at it; its own (in as many slices as it is in pieces: chat_body_slices), by its key (chat_body_key's, what was sent from
/// here as as `kept` says); what went elsewhere after it. The first of them, where it is the list's first (`first`), with
/// no room over it; the message's as it joins the one before or not; the rest apart. `followed` where what is sent from
/// here after it goes close under it (sent_among's).
fn chat_body_parts_by(kept : ChatBodyKept, m : Message, unread : Double?, first : Bool, followed : Bool) -> ChatBodyParts {
  let m = if followed && !m.followed { { ..m, followed: true } } else { m }
  let keys : Array[String] = []
  let rows : Map[String, ChatBodyRow] = Map([])
  let mut lead = first
  let gap_of = fn(joined : Bool) {
    if lead {
      NoGap
    } else if joined {
      Joined
    } else {
      Apart
    }
  }
  if unread == Some(m.seq) {
    keys.push("line")
    rows["line"] = { entry: Entry::Line, gap: gap_of(false), slices: 1 }
    lead = false
  }
  let e = Entry::Said(m)
  if m.outgoing != "" {
    kept.sent[m.seq] = m.outgoing
  }
  let k = chat_body_key(kept, e)
  let gap = gap_of(m.joined)
  lead = false
  rows[k] = { entry: e, gap, slices: chat_body_slices(e) }
  keys.push(k)
  for s in m.elsewhere {
    let se = Entry::Sent(s)
    let sk = se.id()
    rows[sk] = { entry: se, gap: Apart, slices: 1 }
    keys.push(sk)
  }
  { keys, rows }
}

///|
/// The keys of the rows a message is shown in (chat_body_parts_by's, in its order) worked out of what it says of itself:
/// its `seq`, `ts` and `outgoing`, the keys of what went elsewhere after it (`elsewhere`); the unread line over it where
/// `unread` is at it. Its slices are no keys of the list's (chat_said_slices_raw).
fn chat_said_keys(
  kept : ChatBodyKept,
  unread : Double?,
  seq : Double,
  ts : String,
  outgoing : String,
  elsewhere : Array[String],
) -> Array[String] {
  let keys : Array[String] = []
  if unread == Some(seq) {
    keys.push("line")
  }
  if outgoing != "" {
    kept.sent[seq] = outgoing
  }
  // (chat_body_key's of Entry::Said: the outbox entry it was sent from here as, else its own; what was sent from here
  // as where that took it over)
  let core_key = match kept.sent.get(seq) {
    Some(o) => "o:" + o
    None => "m:" + ts
  }
  keys.push(kept.sent_as.get(core_key).unwrap_or(core_key))
  for e in elsewhere {
    // (Entry::Sent's id)
    keys.push("s:" + e)
  }
  keys
}

///|
/// The keys of the rows message JSON `j` is shown in (chat_body_parts_by's of it read as a Message), read of the few
/// fields that say them alone: what a message's place among the list's keys costs, never the message read whole.
fn chat_said_keys_raw(kept : ChatBodyKept, unread : Double?, j : Json) -> Array[String] {
  let s = Some(j)
  chat_said_keys(
    kept,
    unread,
    number(s, "seq"),
    text(s, "ts"),
    text(s, "outgoing"),
    items(s, "elsewhere").map(fn(e) { text(Some(e), "key") }),
  )
}

///|
/// How many slices message JSON `j`'s own row is drawn in (chat_body_slices' of it read as a Message), read of the few
/// fields that say it alone: an agent's words in as many as sf's markdown_pieces cuts them into, but where a card is
/// drawn in their place (message_cards_node's in_place_of); 1 for any other. Never the message read whole.
fn chat_said_slices_raw(j : Json) -> Int {
  let s = Some(j)
  let author_kind = text(s, "authorKind")
  let in_place = match field(s, "card") {
    Some(Object(_)) as c =>
      ["vaultAsk", "phoneAsk", "signinAsk", "rigAsk"].iter().any(fn(n) { field(c, n) is Some(Object(_)) })
    _ => false
  }
  guard !flag(s, "mine") && !flag(s, "system") && author_kind != "person" && !in_place else { return 1 }
  match @sf.markdown_pieces(text(s, "text"), field(s, "md")) {
    Some(ps) if ps.length() > 1 => ps.length()
    _ => 1
  }
}

///|
/// The rows of a chat's head `v` over its messages and under them, as chat_entries and chat_body_rows have them: the
/// page before, the chat empty, what went elsewhere before its messages; what is newer, then what is on its way: the outbox, then what
/// was sent from here the core has not taken over yet (`still`, its row before it followed where it goes close under
/// it), each by the key it was sent as where a row of the core's took it over (`kept`'s sent_as), then where it stands
/// and its agents at work, then the agents what is on its way set at work (`answered`: answered_at's).
fn chat_body_ends(
  kept : ChatBodyKept,
  v : ChatView,
  empty : Bool,
  still : Array[@sfbase.LocalSent],
  answered : Array[Agent],
  turns : ChatTurnsOut,
) -> (ChatBodyParts, ChatBodyParts) {
  let over : ChatBodyParts = { keys: [], rows: Map([]) }
  let under : ChatBodyParts = { keys: [], rows: Map([]) }
  // (the list's first row has no room over it: the first over the messages, or under them where nothing is over them)
  let put = fn(p : ChatBodyParts, e : Entry, first : Bool) {
    let k = e.id()
    p.rows[k] = { entry: e, gap: if first { NoGap } else { Apart }, slices: 1 }
    p.keys.push(k)
  }
  if v.more {
    put(over, Entry::Older(if v.older == "failed" { v.older_failed } else { "" }), over.keys.is_empty())
  }
  if empty && v.outbox.length() == 0 && v.elsewhere.length() == 0 && !v.more {
    put(over, Entry::Empty, over.keys.is_empty())
  }
  for e in v.elsewhere {
    put(over, Entry::Sent(e), over.keys.is_empty())
  }
  let lone = fn() { empty && over.keys.is_empty() && under.keys.is_empty() }
  // (one sent from here: by the key it was sent as, close under the row before it where it joins it)
  let out = fn(o : Outgoing) {
    let ck = "o:" + o.id
    let k = kept.sent_as.get(ck).unwrap_or(ck)
    let first = lone()
    under.rows[k] = { entry: Entry::Out(o), gap: if first { NoGap } else if o.joined { Joined } else { Apart }, slices: 1 }
    under.keys.push(k)
  }
  if v.newer {
    put(under, Entry::Newer, lone())
  }
  for o in v.outbox {
    out(o)
  }
  for j, l in still {
    // (its row before it followed where it goes close under it: one of these before it; a message's, its own rows')
    if l.row.joined && j == 0 && under.keys.length() > 0 {
      let pk = under.keys[under.keys.length() - 1]
      match under.rows.get(pk) {
        Some(r) =>
          match r.entry {
            Out(o) if !o.followed => under.rows[pk] = { ..r, entry: Entry::Out({ ..o, followed: true }) }
            _ => ()
          }
        None => ()
      }
    }
    let row = if l.row.joined && j + 1 < still.length() && still[j + 1].row.joined {
      { ..l.row, followed: true }
    } else {
      l.row
    }
    out(row)
  }
  if !v.newer {
    // (where it stood gone in the frame words are sent from here and not offline, as chat_body_rows has it)
    let online_send = !still.is_empty() && !v.offline
    let put_tail = fn(e : Entry) {
      if !(online_send && chat_entry_policy(e).hide_on_online_send) {
        put(under, e, lone())
      }
    }
    match v.state {
      Some((words, lead, rest)) => put_tail(Entry::State(words, lead, rest))
      None => ()
    }
    for a in chat_working_kept(v, turns) {
      put_tail(Entry::Working(a))
    }
    if !v.archived {
      match v.cache_cold {
        Some((session, status, detail, afresh)) =>
          put_tail(Entry::CacheCold(session, status, detail, afresh))
        None => ()
      }
    }
    if v.archived {
      put_tail(Entry::Archived)
    }
  }
  for a in answered {
    put(under, Entry::Working(a), lone())
  }
  (over, under)
}

///|
/// A chat's list by key (the head above): its head `head` as it changes (sfbase's chat_head: none of its messages),
/// its messages `msgs` by key (sfbase's ChatMessages), what was sent from here as `kept` keeps it (read again as
/// `kept_told` changes: chat_body_rows wrote it). Each message's rows a computed of its own, made as its key is first
/// seen and let go as it goes.
fn chat_body_keyed(
  kept : ChatBodyKept,
  kept_told : @signals.Computed[Int],
  head : () -> ChatView,
  msgs : @sfbase.ChatMessages,
  sending? : () -> Array[@sfbase.LocalSent] = fn() { [] },
  card? : () -> (String, Message)? = fn() { None },
  turns? : ChatTurnsOut = { answered: @sf.LiveMap::new(), lingers: @sf.LiveMap::new() },
) -> ChatBodyList {
  // what was sent from here a row of the core's took over (chat_body_rows' `sent_as`): the first of this device's own
  // not there as it was sent (an outbox entry, or a message after the newest there then), looked for among the
  // messages from the newest back no further than that newest, then the outbox; what is still on its way, as it is
  let taken = @signals.computed_by(
    fn(_) {
      let v = head()
      for o in v.outbox {
        if o.seq >= 0.0 {
          kept.sent[o.seq] = o.id
        }
      }
      let on_way = sending()
      let taken_by : Map[String, Bool] = Map([])
      for k in kept.sent_as.values() {
        taken_by[k] = true
      }
      let still : Array[@sfbase.LocalSent] = []
      guard !on_way.is_empty() else { return (still, kept.sent_as.length()) }
      let least = on_way.fold(init=@double.infinity, fn(n, l) { if l.newest < n { l.newest } else { n } })
      // (the core's rows of this device's own after the newest there as any of these was sent, in the list's order)
      let came : Array[(Message, String)] = []
      let keys = msgs.keys()
      let mut i = keys.length() - 1
      while i >= 0 {
        match msgs.get(keys[i]) {
          Some(m) => {
            if m.seq <= least {
              break
            }
            if m.outgoing != "" {
              kept.sent[m.seq] = m.outgoing
            }
            if m.mine && !m.system {
              came.push((m, chat_body_key_core(kept, m)))
            }
          }
          None => ()
        }
        i = i - 1
      }
      came.rev_in_place()
      for l in on_way {
        let key = "o:" + l.row.id
        kept.here[key] = true
        if taken_by.contains(key) {
          continue
        }
        let mut done = false
        for c in came {
          let (m, k) = c
          if m.seq > l.newest && !l.before.contains(k) && !kept.sent_as.contains(k) {
            kept.sent_as[k] = key
            taken_by[key] = true
            done = true
            break
          }
        }
        if !done {
          for o in v.outbox {
            let k = "o:" + o.id
            if !l.before.contains(k) && !kept.sent_as.contains(k) {
              kept.sent_as[k] = key
              taken_by[key] = true
              done = true
              break
            }
          }
        }
        if !done {
          still.push(l)
        }
      }
      (still, kept.sent_as.length())
    },
    same=fn(a, b) {
      a.1 == b.1 && a.0.length() == b.0.length() && a.0.iter().zip(b.0.iter()).all(fn(x) { physical_equal(x.0, x.1) })
    },
  )
  // (the message whose first row is the list's first: the first, where nothing of the head is over it)
  let first = @signals.computed(
    fn(_) {
      let v = head()
      if v.more || !v.elsewhere.is_empty() {
        None
      } else {
        msgs.keys().get(0)
      }
    },
    same=fn(a, b) { a == b },
  )
  let unread = @signals.computed(fn(_) { head().unread_line }, same=fn(a, b) { a == b })
  // (the message the card words sent from here answer is: sfbase's chat_sent_here)
  let card_at = @signals.computed(fn(_) { card().map(fn(c) { c.0 }) }, same=fn(a, b) { a == b })
  // (the message what is sent from here goes close under, its time under it alone: the last, where nothing else of the
  // list is between them, sent_among's)
  let followed_at = @signals.computed(
    fn(_) {
      let (still, _) = taken.get()
      let v = head()
      guard still.get(0) is Some(l) && l.row.joined && !v.newer && v.outbox.is_empty() else { return None }
      let keys = msgs.keys()
      // (one of the viewer's own, not a station's line or another's: what goes close under it is theirs)
      guard keys.last() is Some(k) &&
        msgs.raw(k) is Some(j) &&
        items(Some(j), "elsewhere").is_empty() &&
        flag(Some(j), "mine") &&
        !flag(Some(j), "system") else {
        return None
      }
      Some(k)
    },
    same=fn(a, b) { a == b },
  )
  // (where the head's marks stand, one computed every message's rows read: the unread line's seq, the list's first, the
  // one followed close under, the one the card words answer; how many were taken over and what chat_body_rows told of
  // `kept`, as they change what key a message goes by. So a change of the head reaches each message by one link, not
  // five, and wakes none where no mark moved)
  let marks = @signals.computed(
    fn(_) {
      let (_, n) = taken.get()
      (unread.get(), first.get(), followed_at.get(), card_at.get(), n, kept_told.get())
    },
    same=fn(a, b) { a == b },
  )
  let parts : Map[String, @signals.Computed[ChatBodyParts]] = Map([])
  let part_keys : Map[String, @signals.Computed[Array[String]]] = Map([])
  let parts_of = fn(mk : String) -> @signals.Computed[ChatBodyParts] {
    match parts.get(mk) {
      Some(p) => p
      None => {
        let none : ChatBodyParts = { keys: [], rows: Map([]) }
        // (what its rows were last made of: the message, where it stands as the marks say (the unread line over it,
        // the list's first, followed close under), the key it goes by; its rows made again only as one of these is
        // another, else the same rows given again, so the marks moving for another message wake nothing of it)
        let made_of : Ref[(Message, Bool, Bool, Bool, String)?] = Ref(None)
        let p = @signals.computed_by(
          fn(was) {
            let (unread_at, lead_mk, followed_mk, card_mk, _, _) = marks.get()
            let own = msgs.get(mk)
            let m = if card_mk == Some(mk) {
              match @signals.untracked(card) {
                Some((_, c)) => Some(c)
                None => own
              }
            } else {
              own
            }
            guard m is Some(m) else {
              made_of.val = None
              return none
            }
            let line = unread_at == Some(m.seq)
            let lead = lead_mk == Some(mk)
            let followed = followed_mk == Some(mk)
            if m.outgoing != "" {
              kept.sent[m.seq] = m.outgoing
            }
            let key = chat_body_key(kept, Entry::Said(m))
            match (was, made_of.val) {
              (Some(w), Some((pm, pl, pf, pfo, pk))) if physical_equal(pm, m) &&
                pl == line &&
                pf == lead &&
                pfo == followed &&
                pk == key => w
              _ => {
                made_of.val = Some((m, line, lead, followed, key))
                chat_body_parts_by(kept, m, if line { Some(m.seq) } else { None }, lead, followed)
              }
            }
          },
          same=fn(a, b) { physical_equal(a, b) },
        )
        parts[mk] = p
        p
      }
    }
  }
  // (whose each message-owned row is: a message's key, maintained solely by keys_of; head rows over/under never write here)
  let msg_owner : Map[String, String] = Map([])
  // (each message's rows' keys, worked out of its JSON's few fields that say them (chat_said_keys_raw), never of its
  // rows: so the list's keys read no message whole, and a message is read as a Message (parts_of, ChatMessages::get)
  // only as a row of it is asked, as it comes to show; told only as its keys change, not as a word comes into it)
  let keys_of = fn(mk : String) -> @signals.Computed[Array[String]] {
    match part_keys.get(mk) {
      Some(p) => p
      None => {
        let p = @signals.computed(
          fn(was : Array[String]?) {
            let (unread_at, _, _, card_mk, _, _) = marks.get()
            let own = msgs.raw(mk)
            // (the card the words sent from here answer: as parts_of has it, the same keys as its own)
            let answered = if card_mk == Some(mk) {
              @signals.untracked(card).map(fn(c) { c.1 })
            } else {
              None
            }
            let now = match (answered, own) {
              (Some(m), _) =>
                chat_said_keys(kept, unread_at, m.seq, m.ts, m.outgoing, m.elsewhere.map(fn(e) { e.key }))
              (None, Some(j)) => chat_said_keys_raw(kept, unread_at, j)
              (None, None) => []
            }
            match was {
              Some(w) => for k in w { if msg_owner.get(k) == Some(mk) { msg_owner.remove(k) } }
              None => ()
            }
            for k in now {
              msg_owner[k] = mk
            }
            now
          },
          same=fn(a, b) { a == b },
        )
        part_keys[mk] = p
        p
      }
    }
  }
  // (how many slices each message's own row is drawn in, worked out of its JSON's few fields (chat_said_slices_raw), as
  // its keys are: told only as that count changes, an in-place update to it waking nothing else)
  let slice_counts : Map[String, @signals.Computed[Int]] = Map([])
  let slices_of = fn(mk : String) -> @signals.Computed[Int] {
    match slice_counts.get(mk) {
      Some(p) => p
      None => {
        let p = @signals.computed(
          fn(_) {
            let (_, _, _, card_mk, _, _) = marks.get()
            let answered = if card_mk == Some(mk) {
              @signals.untracked(card).map(fn(c) { c.1 })
            } else {
              None
            }
            match (answered, msgs.raw(mk)) {
              (Some(m), _) => chat_body_slices(Entry::Said(m))
              (None, Some(j)) => chat_said_slices_raw(j)
              (None, None) => 1
            }
          },
          same=fn(a, b) { a == b },
        )
        slice_counts[mk] = p
        p
      }
    }
  }
  let ends = @signals.computed_by(
    fn(_) {
      let v = head()
      let (still, _) = taken.get()
      chat_body_ends(kept, v, msgs.keys().is_empty(), still, chat_body_answered(v, msgs, still, card), turns)
    },
    same=fn(a, b) {
      a.0.keys == b.0.keys &&
      a.1.keys == b.1.keys &&
      a.0.keys.iter().all(fn(k) { chat_body_row_same(a.0.rows[k], b.0.rows[k]) }) &&
      a.1.keys.iter().all(fn(k) { chat_body_row_same(a.1.rows[k], b.1.rows[k]) })
    },
  )
  let keys = @signals.computed(
    fn(was) {
      let (over, under) = ends.get()
      let order = msgs.keys()
      let msg_ks : Array[Array[String]] = []
      for mk in order {
        msg_ks.push(keys_of(mk).get())
      }
      // (a message gone: its rows' computeds let go before assembling out, so msg_owner reflects order alone)
      if part_keys.length() > order.length() || parts.length() > order.length() {
        let here : Map[String, Bool] = Map([])
        for mk in order {
          here[mk] = true
        }
        let gone = part_keys.keys().filter(fn(mk) { !here.contains(mk) }).collect()
        for mk in gone {
          // (its rows' keys read once more, none now: what it owned let go)
          match part_keys.get(mk) {
            Some(p) => @signals.untracked(fn() { p.get() }) |> ignore
            None => ()
          }
          parts.remove(mk)
          part_keys.remove(mk)
        }
        for mk in parts.keys().filter(fn(mk) { !here.contains(mk) }).collect() {
          parts.remove(mk)
        }
        for mk in slice_counts.keys().filter(fn(mk) { !here.contains(mk) }).collect() {
          slice_counts.remove(mk)
        }
      }
      let out : Array[String] = []
      let seen : Map[String, Bool] = Map([])
      for k in over.keys {
        if !msg_owner.contains(k) && !seen.contains(k) {
          seen[k] = true
          out.push(k)
        }
      }
      for ks in msg_ks {
        for k in ks {
          if !seen.contains(k) {
            seen[k] = true
            out.push(k)
          }
        }
      }
      for k in under.keys {
        if !msg_owner.contains(k) && !seen.contains(k) {
          seen[k] = true
          out.push(k)
        }
      }
      // (the same keys the same object as before: worked out anew as its page is woken from rest, what lays them out
      // finds them as it left them)
      match was {
        Some(prev) if physical_equal(prev, out) || prev == out => prev
        _ => out
      }
    },
    same=fn(a, b) { physical_equal(a, b) || a == b },
  )
  let (keys_index, clear_index) = chat_keys_index_cache()
  // (what nothing follows let go of, from what reads the others down: each let go leaves what it read unread by it, so
  // that, where nothing else reads it, is let go of next)
  let rest_unwatched = fn() {
    clear_index()
    if !keys.watched() {
      keys.dispose()
    }
    if !ends.watched() {
      ends.dispose()
    }
    for _, p in part_keys {
      if !p.watched() {
        p.dispose()
      }
    }
    for _, p in parts {
      if !p.watched() {
        p.dispose()
      }
    }
    for _, p in slice_counts {
      if !p.watched() {
        p.dispose()
      }
    }
    if !marks.watched() {
      marks.dispose()
    }
    if !taken.watched() {
      taken.dispose()
    }
  }
  {
    rest_unwatched,
    keys: fn() { keys.get() },
    keys_index,
    taken: fn() { taken.get().1 },
    row: fn(k) {
      keys.get() |> ignore
      match msg_owner.get(k) {
        Some(mk) => parts_of(mk).get().rows.get(k)
        None => {
          let (over, under) = ends.get()
          match over.rows.get(k) {
            Some(r) => Some(r)
            None => under.rows.get(k)
          }
        }
      }
    },
    slices: fn(k) {
      // (a message's own row alone: its unread line and what went elsewhere after it are one each)
      guard k != "line" && !k.has_prefix("s:") else { return 1 }
      match msg_owner.get(k) {
        Some(mk) => slices_of(mk).get()
        None => 1
      }
    },
  }
}

///|
/// A chat's list as read at once (ChatBodyList::read): its keys then, their snapshot-bound key indices, and each row by
/// its key as it is asked.
priv struct ChatBodyNow {
  keys : Array[String]
  key_index : Map[String, Int]
  key_dup_last : Map[String, Int]
  row_of : (String) -> ChatBodyRow?
  slices_of : (String) -> Int
}

///|
/// Its keys as they are now, and its rows as each is asked (what reads them in a computed follows what it reads).
fn ChatBodyList::read(self : ChatBodyList) -> ChatBodyNow {
  let ks = (self.keys)()
  let (key_index, key_dup_last) = (self.keys_index)(ks)
  { keys: ks, key_index, key_dup_last, row_of: self.row, slices_of: self.slices }
}

///|
/// First index of key `k` in this `ChatBodyNow.keys` snapshot (matching `Array::search`).
fn ChatBodyNow::index_of(self : ChatBodyNow, k : String) -> Int? {
  self.key_index.get(k)
}

///|
/// Last index of key `k` in this `ChatBodyNow.keys` snapshot (matching a reverse scan from the end).
fn ChatBodyNow::last_index_of(self : ChatBodyNow, k : String) -> Int? {
  match self.key_dup_last.get(k) {
    Some(i) => Some(i)
    None => self.key_index.get(k)
  }
}

///|
/// How many slices row `k` is drawn in (1 at least).
fn ChatBodyNow::slices(self : ChatBodyNow, k : String) -> Int {
  (self.slices_of)(k)
}

///|
/// Row `k`.
fn ChatBodyNow::get(self : ChatBodyNow, k : String) -> ChatBodyRow? {
  (self.row_of)(k)
}

///|
/// Chat `r`'s view `v` with its messages: as it is where it holds them (read whole: view_of_chat's), else its head with
/// those `src` keeps by key (sfbase's ChatMessages), all of them read. For what a press reads of the whole chat (the
/// outline's steps, a message found by its time), never as a row is drawn.
fn chat_whole(src : Source, r : ChatRef, v : ChatView) -> ChatView {
  guard v.messages.is_empty() else { return v }
  { ..v, messages: chat_said_all(src, r, fn() { v }) }
}

///|
/// Chat `r`'s messages, its view `view`'s where it holds them, else those `src` keeps by key: read at once, followed by
/// nothing (a press's).
fn chat_said_all(src : Source, r : ChatRef, view : () -> ChatView) -> Array[Message] {
  @signals.untracked(fn() {
    let v = view()
    guard v.messages.is_empty() else { return v.messages }
    match @sfbase.chat_messages(src, r) {
      Some(ms) => ms.peek_keys().filter_map(fn(k) { ms.peek(k) })
      // (a source that keeps none by key: the chat read whole)
      None =>
        match @sfbase.view_of_chat(src, r).0 {
          Some(w) => w.messages
          None => v.messages
        }
    }
  })
}

///|
/// Chat `r`'s first and last messages (its view `view`'s, else those `src` keeps by key: the first and last of its keys),
/// as they change.
fn chat_said_ends(src : Source, r : ChatRef, view : () -> ChatView) -> (Message?, Message?) {
  let v = view()
  guard v.messages.is_empty() else { return (v.messages.get(0), v.messages.last()) }
  match @sfbase.chat_messages(src, r) {
    Some(ms) => {
      let keys = ms.keys()
      (keys.get(0).bind(fn(k) { ms.get(k) }), keys.last().bind(fn(k) { ms.get(k) }))
    }
    None => (None, None)
  }
}

///|
/// The newest of chat `r`'s messages' seqs (-1: none), as chat_said_ends reads them: its last.
fn chat_said_latest(src : Source, r : ChatRef, view : () -> ChatView) -> Double {
  let v = view()
  guard v.messages.is_empty() else {
    return v.messages.fold(init=-1.0, fn(m, x) { if x.seq > m { x.seq } else { m } })
  }
  match chat_said_ends(src, r, view).1 {
    Some(m) => m.seq
    None => -1.0
  }
}

///|
/// The entries a chat's page reads where its rows are by key (none: chat_body_keyed's own), the same each time.
// kept across runs: never written
let chat_no_entries : Array[Entry] = []

///|
/// The key message `m` goes by among the core's rows (chat_body_rows' core key): the outbox entry it was sent from here
/// as, else its own; before what was sent from here as takes it over (sent_as).
fn chat_body_key_core(kept : ChatBodyKept, m : Message) -> String {
  match kept.sent.get(m.seq) {
    Some(o) => "o:" + o
    None => "m:" + m.ts
  }
}

///|
/// The agents of chat head `v` what is on its way from here sets at work (sfbase's answered_at, by key: its outbox and
/// `still`, the chat's messages `msgs` looked through from the newest back for the cards they quote and for the last that
/// is no system line, `card`'s answer in its place): at work from the frame it is sent, after the agents at work.
fn chat_body_answered(
  v : ChatView,
  msgs : @sfbase.ChatMessages,
  still : Array[@sfbase.LocalSent],
  card : () -> (String, Message)?,
) -> Array[Agent] {
  let outs : Array[Outgoing] = v.outbox.filter(fn(o) { o.state != "failed" })
  for l in still {
    if l.row.state != "failed" {
      outs.push(l.row)
    }
  }
  guard !outs.is_empty() else { return [] }
  let over = card()
  let message = fn(k : String, m : Message) {
    match over {
      Some((ck, c)) if ck == k => c
      _ => m
    }
  }
  let out : Array[Agent] = []
  let take = fn(by : String) {
    match v.agents.search_by(fn(a) { a.key == by }) {
      Some(i) => {
        let a = v.agents[i]
        let at_work = a.status == "running" || a.status == "queued"
        let shown = at_work && !v.newer
        if !at_work && !shown && !out.iter().any(fn(x) { x.key == a.key }) {
          out.push({ ..a, status: "queued", started: true })
        }
      }
      None => ()
    }
  }
  let keys = msgs.keys()
  let last : Message? = {
    let mut i = keys.length() - 1
    let mut found : Message? = None
    while i >= 0 {
      match msgs.get(keys[i]) {
        Some(m) if !m.system => {
          found = Some(message(keys[i], m))
          break
        }
        _ => ()
      }
      i = i - 1
    }
    found
  }
  for o in outs {
    for q in o.quotes {
      guard q.role == "agent" && q.ts != "" else { continue }
      let mut i = keys.length() - 1
      while i >= 0 {
        match msgs.get(keys[i]) {
          Some(m) if m.ts == q.ts => {
            if m.card is Some(_) {
              take(m.by.agent)
            }
            break
          }
          _ => ()
        }
        i = i - 1
      }
    }
    match last {
      Some(m) if m.card is Some(_) && m.by.agent != "" && (m.decision is Some(d) && d.resolved && !d.dismissed) =>
        take(m.by.agent)
      _ => ()
    }
  }
  out
}
