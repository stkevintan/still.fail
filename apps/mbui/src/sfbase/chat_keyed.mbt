// A chat read by key (the core's own way: client/core-ts AGENTS.md, rule 6): its head (all its view says but its
// messages) worked out of the topic's value as anything but a message changes it, and its messages kept by key as the
// core changes them item by item (@core.Sub::keyed's @signals.KeyedList), each read as a Message only as its item
// changes. So an in-place update to one message tells what reads that message and nothing else: no reader walks the
// chat, and what one change costs is the same in a chat of 50 messages as in one of 5,000. What reads the chat whole
// (view_of_chat: the old page, a chat's sheets) reads it as before.

///|
/// A chat's messages by key (the core's key of them as its JSON text: `seq` and `outgoing`), each read as a Message
/// only as its item changes (the same item, the same Message).
pub struct ChatMessages {
  priv list : @signals.KeyedList[String, Json]
  priv read : Map[String, (Json, Message)]
}

///|
/// Its keys in order: what reads them is told as one comes, goes or moves, never as a message changes.
pub fn ChatMessages::keys(self : ChatMessages) -> Array[String] {
  self.list.keys()
}

///|
/// Its keys in order as they stand, read by nothing.
pub fn ChatMessages::peek_keys(self : ChatMessages) -> Array[String] {
  self.list.peek_keys()
}

///|
/// Message `k` (none where it is not there): what reads it is told as that message changes, comes or goes.
pub fn ChatMessages::get(self : ChatMessages, k : String) -> Message? {
  match self.list.get(k) {
    Some(j) => Some(self.of(k, j))
    None => {
      self.read.remove(k)
      None
    }
  }
}

///|
/// Message `k`'s item as the core keeps it, its JSON (none where it is not there), not read as a Message: what reads it
/// is told as that message changes, comes or goes. For what is worked out of a field or two of every message the list
/// holds (which rows each is shown in), so that only those that show are read whole (get).
pub fn ChatMessages::raw(self : ChatMessages, k : String) -> Json? {
  self.list.get(k)
}

///|
/// Message `k` as it stands, read by nothing.
pub fn ChatMessages::peek(self : ChatMessages, k : String) -> Message? {
  match self.list.peek(k) {
    Some(j) => Some(self.of(k, j))
    None => None
  }
}

///|
/// How many it holds, read by nothing.
pub fn ChatMessages::count(self : ChatMessages) -> Int {
  self.list.count()
}

///|
/// Message `k`'s item `j` read: as it was where it is the same item.
fn ChatMessages::of(self : ChatMessages, k : String, j : Json) -> Message {
  match self.read.get(k) {
    Some((was, m)) if physical_equal(was, j) => m
    _ => {
      chat_messages_read.val += 1
      let m = message_read(j)
      self.read[k] = (j, m)
      m
    }
  }
}

///|
/// How many messages chat_messages has read as Messages (message_of) in this run: what a test of the work a change
/// costs counts.
// kept across runs: a count a test reads as the difference over what it does, never its value
pub let chat_messages_read : Ref[Int] = Ref(0)

///|
// kept across runs: each kept by its list, which is its subscription's; one whose list is another made again
let chat_messages_kept : Map[String, ChatMessages] = Map([])

///|
/// Chat `r`'s messages by key as `src` keeps them (Source's topic_keyed), the same subscription its topic is read by:
/// none where the source keeps none (a made-up core that gives values whole: read through view_of_chat).
pub fn chat_messages(src : Source, r : ChatRef) -> ChatMessages? {
  let list = @signals.untracked(fn() {
    (src.topic_keyed)("chat", chat_params(r), "messages", ["seq", "outgoing"])
  })
  guard list is Some(list) else { return None }
  let key = chat_inputs_key(r)
  match chat_messages_kept.get(key) {
    Some(m) if physical_equal(m.list, list) => Some(m)
    was => {
      // (its messages as they were read where it was read before: as its page was left (chat_messages_seeds), or by
      // the list before this one; each taken only while its item is the same JSON: ChatMessages::of)
      let read = match seeds_take(chat_messages_seeds, key) {
        Some(read) => read
        None =>
          match was {
            Some(w) => chat_messages_read_of(w)
            None => {}
          }
      }
      let m = { list, read }
      chat_messages_kept[key] = m
      Some(m)
    }
  }
}

///|
/// What `ms` read of its messages that its list holds now (ChatMessages' `read`, those gone from it left out).
fn chat_messages_read_of(ms : ChatMessages) -> Map[String, (Json, Message)] {
  let read : Map[String, (Json, Message)] = Map([])
  for k in ms.list.peek_keys() {
    match ms.read.get(k) {
      Some(p) => read[k] = p
      None => ()
    }
  }
  read
}

///|
/// The messages read of each chat by key as its page was left (ChatMessages' `read`, chat_seeds_put), the last
/// `chats_kept` of them by the chat's key: taken by its messages by key as they are read again (chat_messages), so a
/// page of it opened again reads none of those whose item is the same JSON (the core's client keeps the chat's value
/// as it lets it go: @core.Client::keep).
// kept across runs: emptied as a run begins (chat_seeds_reset)
let chat_messages_seeds : Array[(String, Map[String, (Json, Message)])] = []

///|
/// The heads read of chats as their pages were left (chat_head_read's, chat_seeds_put), the last `chats_kept` of them:
/// a page of one opened again (a source of its own) reads its head from the one kept where it is the same chat's
/// (chat_head_seed), as from the head before.
// kept across runs: emptied as a run begins (chat_seeds_reset)
let chat_head_seeds : Array[(String, ChatHead)] = []

///|
/// The head kept of the chat whose value `v` is (chat_head_seeds): one whose value is it, or whose people's or agents'
/// are the same JSON as its (the newest first); none else.
fn chat_head_seed(v : Json) -> ChatHead? {
  let s = Some(v)
  let mut i = chat_head_seeds.length() - 1
  while i >= 0 {
    let w = chat_head_seeds[i].1
    if physical_equal(w.raw, v) || chat_head_part_same(field(s, "people"), field(Some(w.raw), "people")) ||
      chat_head_part_same(field(s, "agents"), field(Some(w.raw), "agents")) {
      return Some(w)
    }
    i -= 1
  }
  None
}

///|
/// Whether parts `a` and `b` of two chats' values are the same JSON (none is no part).
fn chat_head_part_same(a : Json?, b : Json?) -> Bool {
  match (a, b) {
    (Some(x), Some(y)) => physical_equal(x, y)
    _ => false
  }
}

///|
/// What was read of chat `key` as a page of it is left (by its source: its read whole, `read`; its head, `head`; its
/// messages by key, chat_messages_kept's), kept for a page of it opened again (chat_read_seeds, chat_head_seeds,
/// chat_messages_seeds), each the newest `chats_kept`.
fn chat_seeds_put(key : String, read : ChatRead?, head : ChatHead?) -> Unit {
  match read {
    Some(c) => seeds_put(chat_read_seeds, key, c)
    None => ()
  }
  match head {
    Some(h) => seeds_put(chat_head_seeds, key, h)
    None => ()
  }
  match chat_messages_kept.get(key) {
    Some(ms) => seeds_put(chat_messages_seeds, key, chat_messages_read_of(ms))
    None => ()
  }
}

///|
/// `value` kept for `key` in `seeds`, in place of one kept for it before, the oldest let go past `chats_kept`.
fn[T] seeds_put(seeds : Array[(String, T)], key : String, value : T) -> Unit {
  match seeds.search_by(fn(s) { s.0 == key }) {
    Some(i) => seeds.remove(i) |> ignore
    None => ()
  }
  seeds.push((key, value))
  while seeds.length() > chats_kept {
    seeds.remove(0) |> ignore
  }
}

///|
/// What `seeds` keeps for `key`, taken out of it.
fn[T] seeds_take(seeds : Array[(String, T)], key : String) -> T? {
  match seeds.search_by(fn(s) { s.0 == key }) {
    Some(i) => Some(seeds.remove(i).1)
    None => None
  }
}

///|
fn init {
  // a run anew (a Tester begun: another test's) keeps nothing read of another's chats
  @ui.on_reset(chat_seeds_reset)
}

///|
/// What was kept of chats read to be read again let go (chat_seeds_put's, chat_opening's).
fn chat_seeds_reset() -> Unit {
  chat_read_seeds.clear()
  chat_head_seeds.clear()
  chat_messages_seeds.clear()
  chat_openings.clear()
  messages_read_last.clear()
}

///|
/// A chat's head as chat_head_read made it: the topic's value it was read from and the view.
priv struct ChatHead {
  raw : Json
  view : ChatView
}

///|
/// Whether chat heads `a` and `b` say the same (each part chat_view_of keeps as it was where its JSON is: by identity;
/// the rest by value).
fn chat_head_same(a : ChatView, b : ChatView) -> Bool {
  a.title == b.title &&
  a.thread == b.thread &&
  a.unread == b.unread &&
  physical_equal(a.people, b.people) &&
  physical_equal(a.agents, b.agents) &&
  physical_equal(a.elsewhere, b.elsewhere) &&
  a.more == b.more &&
  a.newer == b.newer &&
  a.first_entry == b.first_entry &&
  a.last_entry == b.last_entry &&
  a.older == b.older &&
  a.older_failed == b.older_failed &&
  a.letters == b.letters &&
  a.at == b.at &&
  a.at_offset == b.at_offset &&
  a.unread_line == b.unread_line &&
  a.unread_above == b.unread_above &&
  physical_equal(a.outbox, b.outbox) &&
  a.joins_until == b.joins_until &&
  a.offline == b.offline &&
  a.offline_note == b.offline_note &&
  a.updating == b.updating &&
  a.moving == b.moving &&
  a.cache_cold == b.cache_cold &&
  a.state == b.state &&
  a.state_ask == b.state_ask &&
  a.ask_clear == b.ask_clear &&
  a.archived == b.archived &&
  a.archivable == b.archivable &&
  a.pending == b.pending &&
  a.key == b.key &&
  physical_equal(a.asks, b.asks) &&
  physical_equal(a.station_update, b.station_update) &&
  a.me == b.me &&
  physical_equal(a.tabs, b.tabs) &&
  physical_equal(a.cc, b.cc) &&
  physical_equal(a.screens, b.screens) &&
  physical_equal(a.opener, b.opener) &&
  physical_equal(a.openers, b.openers) &&
  physical_equal(a.opened, b.opened) &&
  a.opened_text == b.opened_text
}

///|
/// A chat's head: its view as the core gives it but its messages (none read: ChatMessages' by key), each part read
/// again only where its JSON is another (chat_view_of's `was`), and the view of before where it says the same, so what
/// reads it is told only as its head changes, not as a word comes into a message.
// kept across runs: what it keeps is let go of by a run anew and by reset (derived.mbt)
let chat_head_read : Derived[ChatHead] = Derived::new_by(
  "chat",
  fn(v, was) {
    // (made from nothing, a source's first: from the head read of this chat as a page of it was left: chat_head_seeds)
    let was = match was {
      Some(_) => was
      None => chat_head_seed(v)
    }
    let view = chat_view_of(v, [], match was {
      Some(w) => Some((w.raw, w.view))
      None => None
    })
    match was {
      Some(w) if chat_head_same(w.view, view) => { raw: v, view: w.view }
      _ => { raw: v, view }
    }
  },
  // (what reads it told only as the view is another: a topic changed where the head is not, the view kept, tells none)
  same=fn(a, b) { physical_equal(a.view, b.view) },
)

///|
// kept across runs: the Kept is registered on first use and its stored values are cleared by kept_reset (derived.mbt)
let chat_heads : SourceKept[(ChatView?, Json?)] = { kept: {}, listed: false }

///|
/// Chat `r`'s head as `src` reads it (chat_head_read: its view but its messages) and its topic's error: what reads
/// it is told only as the head or the error is another, not as a message changes.
pub fn chat_head(src : Source, r : ChatRef) -> (ChatView?, Json?) {
  let head = chat_heads.read(
    src,
    chat_inputs_key(r),
    fn(_) {
      let (read, topic) = chat_head_read.read(src, chat_params(r))
      (read.map(fn(h) { h.view }), topic.error)
    },
    same=fn(a, b) {
      let same_view = match (a.0, b.0) {
        (Some(x), Some(y)) => physical_equal(x, y)
        (None, None) => true
        _ => false
      }
      same_view && a.1 == b.1
    },
  )
  // (what the page reads of the chat kept for as it is left, as view_of_chat keeps it: pages.mbt's page_chat_view_read;
  // a page that reads the chat by key reads its head alone)
  page_chat_view_read(src, r, head.0)
  head
}

///|
// kept across runs: the Kept is registered on first use and its stored values are cleared by kept_reset (derived.mbt)
let chat_head_jsons : SourceKept[Json?] = { kept: {}, listed: false }

///|
/// Chat `r`'s topic's value as `src` holds it but its messages (an object of every other field of it, none while it has
/// none): the same object while each of those fields is the same JSON (the core's deltas keep what they do not touch:
/// core's delta.mbt), so what reads a field of the chat's head that its view does not say (its row's `place`, its
/// agents' sessions, `watch`, `xshare`) is told as that changes, never as a word comes into a message.
pub fn chat_head_json(src : Source, r : ChatRef) -> Json? {
  chat_head_jsons.read(
    src,
    chat_inputs_key(r),
    fn(was) {
      guard src.topic("chat", chat_params(r)).get().value is Some(Object(o)) else { return None }
      let n = if o.contains("messages") { o.length() - 1 } else { o.length() }
      match was {
        Some(Some(Object(w) as before)) if w.length() == n &&
          o.iter().all(fn(kv) { kv.0 == "messages" || (w.get(kv.0) is Some(x) && physical_equal(x, kv.1)) }) =>
          Some(before)
        _ => {
          let head : Map[String, Json] = Map([])
          for k, x in o {
            if k != "messages" {
              head[k] = x
            }
          }
          Some(Json::object(head))
        }
      }
    },
    same=fn(a, b) {
      match (a, b) {
        (Some(x), Some(y)) => physical_equal(x, y)
        (None, None) => true
        _ => false
      }
    },
  )
}

///|
/// Chat `r`'s view for what reads its head alone (its bar, its composer, whether it needs the viewer): its head
/// (chat_head, what is on its way from here answering its last card as the core will say: chat_sent_here) where it is
/// no chat just made from here with none of the core's messages in it yet (chat_keyed_now) and `src` keeps its messages
/// by key (what wants them reads them so: chat_messages), else
/// as view_of_chat works it out (sent_here_view's the same). Told as the head changes, not as a word
/// comes into a message.
pub fn chat_view_now(src : Source, r : ChatRef) -> ChatView? {
  // (no chat yet, a new chat's composer's: none, its topic never asked)
  guard r.session != "" else { return None }
  // (the head read first: what holds the topic, whose messages by key are then there; what is on its way from here
  // answering its last card, as the core will say once it has it)
  match chat_head(src, r).0 {
    Some(h) =>
      match chat_messages(src, r) {
        Some(ms) if chat_keyed_now(r, ms) => return Some(chat_sent_here(r, h, ms).0)
        _ => ()
      }
    None => ()
  }
  match view_of_chat(src, r) {
    (Some(v), _, _) => Some(v)
    // (none read yet where no error says why: a page taken back from the stack's kept left, its chat asked again, shows
    // what it read last till the core's first answer, never its bones in between)
    (None, _, None) => page_chat_view_kept(src, r)
    _ => None
  }
}

///|
/// Whether chat `r`, its messages by key `ms`, is read by its head and those (chat_view_now, the chat's page made as
/// nodes): but the chat a new chat became (fresh_view) till the core's view of it holds a message, which view_of_chat
/// makes never empty meanwhile (its first words in it from the frame they were sent). Told, while it is that chat, as
/// a message comes.
pub fn chat_keyed_now(r : ChatRef, ms : ChatMessages) -> Bool {
  fresh_view(r) is None || ms.keys().length() > 0
}

///|
/// A chat's messages by key of list `list` (a subscription's, Sub::keyed's; a test's own), each read as a Message as it
/// is asked.
pub fn chat_messages_of(list : @signals.KeyedList[String, Json]) -> ChatMessages {
  { list, read: {} }
}

///|
/// How many times chat_read worked a chat out whole in this run (its view, its entries): what a test of the work a
/// change costs counts.
// kept across runs: a count a test reads as the difference over what it does, never its value
pub let chat_read_made : Ref[Int] = Ref(0)

///|
/// What words sent from here before the core has them make of chat `r`'s head `head` and its messages by key `ms`
/// (sent_here_view's, by key): where the chat's last card still waits and they were sent as it showed, with no
/// person's words after it, they answer it at once (no more asked, its decision theirs, the chat's asks without it,
/// where it stands gone as its agent has words to take), as the core will say once it has them. The head so, and the
/// card's message so by its key (none where they answer none). Looked for from the newest back no further than that card
/// or a person's words after it. Answering none, words on their way end the turn before's line of where it stands (one
/// asking nothing of the viewer) at once.
pub fn chat_sent_here(
  r : ChatRef,
  head : ChatView,
  ms : ChatMessages,
) -> (ChatView, (String, Message)?) {
  match chat_sent_card(r, ms) {
    Some((k, m)) => {
      let asks = head.asks.filter(fn(seq) { seq != m.seq })
      (
        { ..head, asks, ask_clear: head.ask_clear && !asks.is_empty(), state: None, state_ask: None },
        Some((k, chat_card_answered(m))),
      )
    }
    None =>
      // (new words sent from here end the turn before's line of where it stands (done, nothing asked of the viewer) at
      // once, never leaving it under the words flying in till the core says it gone)
      if !sending_now(r.station + "\u{1}" + r.session).is_empty() && head.state is Some(_) && head.state_ask is None {
        ({ ..head, state: None }, None)
      } else {
        (head, None)
      }
  }
}

///|
/// The card of chat `r` that words sent from here before the core has them answer (chat_sent_here's), by its key, as the
/// core has it still (none where they answer none): read of its messages by key `ms` and what is on its way, none of
/// its head.
pub fn chat_sent_card(r : ChatRef, ms : ChatMessages) -> (String, Message)? {
  let sending = sending_now(r.station + "\u{1}" + r.session)
  guard !sending.is_empty() else { return None }
  let keys = ms.keys()
  let mut i = keys.length() - 1
  let mut card : (String, Message)? = None
  while i >= 0 {
    match ms.get(keys[i]) {
      Some(m) if m.card is Some(_) => {
        card = Some((keys[i], m))
        break
      }
      // (a person's words after the last card: the core's word stands)
      Some(m) if m.author_kind == "person" => return None
      _ => ()
    }
    i = i - 1
  }
  guard card is Some((_, m)) else { return None }
  guard m.decision is Some(d) && !d.resolved else { return None }
  guard sending.iter().any(fn(l) { m.seq <= l.newest }) else { return None }
  card
}

///|
/// Card `m` as answered by words sent from here (chat_sent_here's): no more asked, its decision theirs.
pub fn chat_card_answered(m : Message) -> Message {
  let said = @sf.t("core-logic.decisions.replied", args=[("name", @sf.t("core-logic.decisions.you"))])
  { ..m, asked: false, decision: Some({ resolved: true, dismissed: false, text: Some(said), chosen: None }) }
}
