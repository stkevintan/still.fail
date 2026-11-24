// The reads of a chat's pending card (station/src/read/store.ts `pendingCardNumber`, `statePendingCard`,
// `deliveryCardState`): by the card posts' index once a chat's posts are all in it, refused while they are being
// put in (the pool then has them prepared and asks again).

///|
let card_posts_pending : String = "card posts pending:"

// The two kinds of card (station/src/store/card-kinds.ts, one text each): a system card (a login, a vault's secret, a
// phone, a rig, a sign-in) waits until it is closed, several at once (pending_system_cards); a conversational one until
// it is closed, a newer one replaces it, or a person's message after it reached its agent (in a still.fail chat any, in
// a platform's thread one handed to a session).

///|
/// card-kinds.ts `systemCardSql`.
fn system_card_sql(col : String) -> String {
  "(CASE WHEN \{col} IS NULL OR NOT json_valid(\{col}) THEN 0 ELSE COALESCE(json_extract(\{col}, '$.type') = 'login'" +
  " OR json_type(\{col}, '$.vault') = 'object' OR json_type(\{col}, '$.adb') = 'object'" +
  " OR json_type(\{col}, '$.rig') = 'object' OR json_type(\{col}, '$.signin') = 'object', 0) END)"
}

///|
/// card-kinds.ts `reachedSql`.
fn reached_sql(thread : String, n : String) -> String {
  "((SELECT surface FROM threads WHERE id = \{thread}) = 'chat' OR EXISTS (SELECT 1 FROM deliveries d WHERE d.thread = \{thread} AND d.n = \{n}))"
}

///|
/// card-kinds.ts ANSWER_AFTER.
let answer_after_sql : String = "SELECT 1 AS x FROM entries p WHERE p.thread = ?1 AND p.kind = 'message' AND p.author_kind = 'person' AND p.n > ?2 AND " +
  reached_sql("?1", "p.n") +
  " LIMIT 1"

///|
/// card-kinds.ts ANSWER_BETWEEN.
let answer_between_sql : String = "SELECT 1 AS x FROM entries p WHERE p.thread = ?1 AND p.kind = 'message' AND p.author_kind = 'person' AND p.n > ?2 AND p.n < ?3 AND " +
  reached_sql("?1", "p.n") +
  " LIMIT 1"

///|
/// card-kinds.ts ANSWER_AT.
let answer_at_sql : String = "SELECT 1 AS x FROM entries p WHERE p.thread = ?1 AND p.n = ?2 AND p.kind = 'message' AND p.author_kind = 'person' AND " +
  reached_sql("?1", "?2")

///|
/// card-kinds.ts CONVERSATION_CARD_BEFORE.
let conversation_card_before_sql : String = "SELECT CAST(c.n AS TEXT) AS n FROM card_posts c JOIN entries e ON e.thread = c.thread AND e.n = c.n WHERE c.thread = ?1 AND c.n < ?2 AND NOT " +
  system_card_sql("e.card") +
  " ORDER BY c.n DESC LIMIT 1"

///|
/// card-kinds.ts CONVERSATION_CARD_LATEST.
let conversation_card_latest_sql : String = "SELECT CAST(c.n AS TEXT) AS n FROM card_posts c JOIN entries e ON e.thread = c.thread AND e.n = c.n WHERE c.thread = ?1 AND NOT " +
  system_card_sql("e.card") +
  " ORDER BY c.n DESC LIMIT 1"

///|
/// card-kinds.ts SYSTEM_CARD_WAITING.
let system_card_waiting_sql : String = "SELECT CAST(s.n AS TEXT) AS n FROM pending_system_cards s WHERE s.thread = ?1 AND NOT EXISTS (SELECT 1 FROM closed_cards c WHERE c.thread = s.thread AND c.n = s.n) ORDER BY s.n DESC LIMIT 1"

///|
/// card-kinds.ts SYSTEM_CARDS_WAITING.
let system_cards_waiting_sql : String = "SELECT CAST(s.n AS TEXT) AS n FROM pending_system_cards s WHERE s.thread = ?1 AND NOT EXISTS (SELECT 1 FROM closed_cards c WHERE c.thread = s.thread AND c.n = s.n) ORDER BY s.n DESC LIMIT 16"

///|
/// What thread `thread` asks and waits on: its system cards still waiting, the latest first, then its latest
/// conversational card while it waits (no person's message reached its agent since, not closed), by their numbers.
pub fn asks_waiting(db : @sql.Db, thread : Json) -> Array[Json] raise {
  let out : Array[Json] = []
  for r in db.all(system_cards_waiting_sql, [thread]) {
    if n_of(Some(r)) is Some(n) {
      out.push(n)
    }
  }
  guard n_of(one(db, conversation_card_latest_sql, [thread])) is Some(n) else { return out }
  if one(db, answer_after_sql, [thread, n]) is Some(_) ||
    one(db, "SELECT 1 AS x FROM closed_cards WHERE thread = ? AND n = ?", [thread, n]) is Some(_) {
    return out
  }
  out.push(n)
  out
}

///|
/// card-kinds.ts SYSTEM_CARD_AT.
let system_card_at_sql : String = "SELECT 1 AS x FROM entries e WHERE e.thread = ?1 AND e.n = ?2 AND e.kind = 'message' AND " +
  system_card_sql("e.card")

///|
/// card-kinds.ts SYSTEM_CARD_KEPT.
let system_card_kept_sql : String = "SELECT 1 AS x FROM pending_system_cards WHERE thread = ?1 AND n = ?2"

///|
/// card-kinds.ts ASKED_LATEST.
let asked_latest_sql : String = "SELECT n FROM entries WHERE thread = ? AND kind = 'message' AND author_kind = 'agent' AND at <= ? ORDER BY at DESC LIMIT 1"

///|
/// The number a `CAST(n AS TEXT)` row says, none where there is no row.
fn n_of(row : Map[String, Json]?) -> Json? {
  match row {
    Some(r) if field(r, "n") is String(_) => Some(number_of(field(r, "n")))
    _ => None
  }
}

///|
/// read/store.ts `cardAt`'s test: whether the card at `n` still waits as kept (a system card until it is closed and
/// let go, a conversational one until it is closed or a person's message after it reached its agent).
fn card_still_waits(db : @sql.Db, thread : Json, n : Json) -> Bool raise {
  if one(db, "SELECT 1 AS x FROM closed_cards WHERE thread = ? AND n = ?", [thread, n]) is Some(_) {
    return false
  }
  if one(db, system_card_at_sql, [thread, n]) is Some(_) {
    return one(db, system_card_kept_sql, [thread, n]) is Some(_)
  }
  one(db, answer_after_sql, [thread, n]) is None
}

///|
/// read/store.ts `cardWaits`: as `card_still_waits`, a conversational card only while it is the chat's latest.
fn card_waits(db : @sql.Db, thread : Json, n : Json) -> Bool raise {
  if one(db, "SELECT 1 AS x FROM closed_cards WHERE thread = ? AND n = ?", [thread, n]) is Some(_) {
    return false
  }
  if one(db, system_card_at_sql, [thread, n]) is Some(_) {
    return one(db, system_card_kept_sql, [thread, n]) is Some(_)
  }
  if !@cards.ready(db, thread) {
    raise pending(thread)
  }
  guard n_of(one(db, conversation_card_latest_sql, [thread])) is Some(latest) && num(latest) == num(n) else {
    return false
  }
  one(db, answer_after_sql, [thread, n]) is None
}

///|
fn one(db : @sql.Db, sql : String, params : Array[Json]) -> Map[String, Json]? raise {
  db.all(sql, params).get(0)
}

///|
/// store.ts `threadsWithCards` for one chat: whether it has a post with a card or options at all.
fn has_cards(db : @sql.Db, thread : Json) -> Bool raise {
  one(db, "SELECT 1 AS x FROM entries INDEXED BY entries_cards WHERE thread = ? AND card IS NOT NULL LIMIT 1", [thread]) is Some(_) ||
  one(db, "SELECT 1 AS x FROM entries INDEXED BY entries_options WHERE thread = ? AND options IS NOT NULL LIMIT 1", [thread]) is Some(_)
}

///|
fn pending(thread : Json) -> Refused {
  Refused(503, card_posts_pending + Json::array([thread]).stringify())
}

///|
/// A JSON column as JSON.parse reads it, none when it does not parse (rows.ts `parsed`).
fn parsed(v : Json) -> @jsjson.JValue? {
  match v {
    String(s) => Some(@jsjson.parse(s)) catch { _ => None }
    _ => None
  }
}

///|
/// A value JSON.parse read, as the answer carries it.
pub fn to_json(v : @jsjson.JValue) -> Json {
  v.to_json_lossy()
}

///|
/// rows.ts `cardOf`: its own card, else its options as an options card.
fn card_of(card : Json, options : Json) -> Json? {
  match parsed(card) {
    Some(c) => Some(to_json(c))
    None =>
      match parsed(options) {
        Some(o) => Some({ "type": "options", "options": to_json(o) })
        None => None
      }
  }
}

///|
/// store.ts `pendingCardNumber`: the chat's card still waiting, by its number.
pub fn pending_card_number(db : @sql.Db, thread : Json) -> Json raise {
  db.exec("SAVEPOINT pending_card_number_read")
  defer (db.exec("RELEASE pending_card_number_read") catch { _ => () })
  if !@cards.ready(db, thread) {
    let indexed = match
      one(db, "SELECT COUNT(*) AS n FROM sqlite_master WHERE type = 'index' AND name IN ('entries_cards', 'entries_options')", []) {
      Some(r) => r.get("n") is Some(Number(2.0, ..))
      None => false
    }
    if indexed && !has_cards(db, thread) {
      return Json::null()
    }
    raise pending(thread)
  }
  // (a system card waiting comes first: it is settled only where it is decided)
  if n_of(one(db, system_card_waiting_sql, [thread])) is Some(system) {
    return system
  }
  guard n_of(one(db, conversation_card_latest_sql, [thread])) is Some(n) else { return Json::null() }
  guard one(db, "SELECT card, options FROM entries WHERE thread = ? AND n = ? AND kind = 'message'", [thread, n]) is Some(post) &&
    card_of(field(post, "card"), field(post, "options")) is Some(_) else {
    return Json::null()
  }
  if one(db, answer_after_sql, [thread, n]) is Some(_) {
    return Json::null()
  }
  if one(db, "SELECT 1 AS x FROM closed_cards WHERE thread = ? AND n = ?", [thread, n]) is Some(_) {
    return Json::null()
  }
  n
}

///|
/// A number read as text (an id past 2^53 kept as SQLite has it, as near as a double holds it, as node reads it).
fn number_of(n : Json) -> Json {
  match n {
    String(s) => @json.parse(s) catch { _ => Json::null() }
    v => v
  }
}

///|
/// store.ts `statePendingCard`: the latest card waiting among the chats, `[thread, n, ts]`.
pub fn state_pending_card(db : @sql.Db, args : Json) -> Json raise {
  db.exec("SAVEPOINT state_pending_card_read")
  defer (db.exec("RELEASE state_pending_card_read") catch { _ => () })
  let threads = match args.value("threads") {
    Some(Array(ts)) => ts
    _ => []
  }
  let cards : Array[(Json, Json, Json, Double)] = []
  for thread in threads {
    let n = pending_card_number(db, thread)
    if n is Null {
      continue
    }
    if one(db, "SELECT ts, at FROM entries WHERE thread = ? AND n = ? AND kind = 'message'", [thread, n]) is Some(row) {
      let ts = match field(row, "ts") {
        Null => Json::string("")
        t => t
      }
      let at = match field(row, "at") {
        Number(a, ..) => a
        _ => 0.0 / 0.0
      }
      cards.push((thread, n, ts, at))
    }
  }
  // (sorted as Array.prototype.sort sorts by `a.at - b.at`: stable, a NaN compare equal)
  let sorted = stable_sort(cards, (a, b) => {
    let d = a.3 - b.3
    if d < 0.0 { -1 } else if d > 0.0 { 1 } else { 0 }
  })
  match sorted.last() {
    Some((thread, n, ts, _)) => Json::array([thread, n, ts])
    None => Json::null()
  }
}

///|
/// Bottom-up iterative merge sort (O(N log N), stable).
fn[T] stable_sort(xs : Array[T], cmp : (T, T) -> Int) -> Array[T] {
  let n = xs.length()
  if n <= 1 {
    return xs.copy()
  }
  let buf = xs.copy()
  let tmp = xs.copy()
  let mut width = 1
  while width < n {
    let mut i = 0
    while i < n {
      let mid = @cmp.minimum(i + width, n)
      let right = @cmp.minimum(i + 2 * width, n)
      let mut l = i
      let mut r = mid
      let mut k = i
      while l < mid && r < right {
        if cmp(buf[l], buf[r]) <= 0 {
          tmp[k] = buf[l]
          l += 1
        } else {
          tmp[k] = buf[r]
          r += 1
        }
        k += 1
      }
      while l < mid {
        tmp[k] = buf[l]
        l += 1
        k += 1
      }
      while r < right {
        tmp[k] = buf[r]
        r += 1
        k += 1
      }
      i += 2 * width
    }
    for j in 0..<n {
      buf[j] = tmp[j]
    }
    width *= 2
  }
  buf
}

///|
/// store.ts `deliveryCardState`: the card a person's message answered, and the card waiting now.
pub fn delivery_card_state(db : @sql.Db, args : Json) -> Json raise {
  let thread = args.value("thread").unwrap_or(Json::null())
  let n = args.value("n").unwrap_or(Json::null())
  db.exec("SAVEPOINT delivery_card_state_read")
  defer (db.exec("RELEASE delivery_card_state_read") catch { _ => () })
  if one(db, answer_at_sql, [thread, n]) is None {
    return Json::null()
  }
  if !@cards.ready(db, thread) {
    if !has_cards(db, thread) {
      return Json::null()
    }
    raise pending(thread)
  }
  guard n_of(one(db, conversation_card_before_sql, [thread, n])) is Some(asked) else { return Json::null() }
  if one(db, answer_between_sql, [thread, asked, n]) is Some(_) {
    return Json::null()
  }
  if one(db, "SELECT 1 AS x FROM closed_cards WHERE thread = ? AND n = ?", [thread, asked]) is Some(_) {
    return Json::null()
  }
  guard one(db, "SELECT ts, author, card, options FROM entries WHERE thread = ? AND n = ? AND kind = 'message'", [thread, asked]) is Some(post) else {
    return Json::null()
  }
  guard card_of(field(post, "card"), field(post, "options")) is Some(card) else { return Json::null() }
  let current_n = pending_card_number(db, thread)
  let current = if current_n is Null {
    Json::null()
  } else {
    match one(db, "SELECT ts FROM entries WHERE thread = ? AND n = ? AND kind = 'message'", [thread, current_n]) {
      Some(c) => ({ "ts": or_empty(field(c, "ts")) } : Json)
      None => Json::null()
    }
  }
  { "ended": { "author": field(post, "author"), "ts": or_empty(field(post, "ts")) }, "card": card, "current": current }
}

///|
fn or_empty(v : Json) -> Json {
  match v {
    Null => Json::string("")
    t => t
  }
}
