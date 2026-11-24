// The chat list as the station makes it once for everyone who sees it (station/src/read/views.ts `sharedChats`, of the
// list shown, not the archive's): `sharedOf`, told to every event stream that makes its sidebar of it, and `sharedChats`
// (GET /chats?shared=1), what a viewer's workspace sees of it. Whole, or the rows a change of some sessions and threads
// can touch (`scopeOf`) and the ids of those. Each row as the TypeScript makes it, field for field.

///|
/// views.ts LAST_CHARS and ANSWERED_WITHIN.
let last_chars : Int = 200

///|
let answered_within : Double = 129600000.0

///|
/// views.ts `Scope`: the ids of the rows a change can touch, the sessions and threads they are made of.
priv struct Scope {
  rows : Array[String]
  sessions : Array[String]
  threads : Array[Json]
}

///|
fn push_new(out : Array[String], seen : Set[String], s : String) -> Unit {
  if !seen.contains(s) {
    seen.add(s)
    out.push(s)
  }
}

///|
/// store.ts `threadsOfSessions`: the threads sessions take part in, each once.
fn threads_of_sessions(db : @sql.Db, keys : Array[String]) -> Array[Json] raise {
  if keys.length() == 0 {
    return []
  }
  let marks = keys.map(_ => "?")
  db
  .all("SELECT DISTINCT thread FROM thread_sessions WHERE session IN (\{marks.join(", ")})", keys.map(Json::string))
  .map(r => field(r, "thread"))
}

///|
fn members_of(db : @sql.Db, ids : Array[Json]) -> Array[String] raise {
  let out : Array[String] = []
  let seen : Set[String] = Set::new()
  for id in ids {
    for m in db.all("SELECT * FROM thread_sessions WHERE thread = ? ORDER BY joined_at, rowid", [id]) {
      push_new(out, seen, js_text(field(m, "session")))
    }
  }
  out
}

///|
fn unique_ids(lists : Array[Array[Json]]) -> Array[Json] {
  let out : Array[Json] = []
  let seen : Set[String] = Set::new()
  for l in lists {
    for id in l {
      if !seen.contains(id.stringify()) {
        seen.add(id.stringify())
        out.push(id)
      }
    }
  }
  out
}

///|
fn unique_keys(lists : Array[Array[String]]) -> Array[String] {
  let out : Array[String] = []
  let seen : Set[String] = Set::new()
  for l in lists {
    for k in l {
      push_new(out, seen, k)
    }
  }
  out
}

///|
/// views.ts `scopeOf`.
fn scope_of(db : @sql.Db, sessions : Array[String], threads : Array[Json]) -> Scope raise {
  let touched = unique_ids([threads, threads_of_sessions(db, sessions)])
  let rows = unique_keys([sessions, members_of(db, touched)])
  let theirs = threads_of_sessions(db, rows)
  let agents = unique_keys([rows, members_of(db, theirs)])
  { rows, sessions: agents, threads: unique_ids([touched, theirs, threads_of_sessions(db, agents)]) }
}

///|
/// A thread for the list (store.ts `listThreads` with no viewer, what `sharedChats` reads of it): the thread, its
/// sessions, its latest message, who wrote in it and the first thing said.
priv struct Listed {
  thread : Map[String, Json]
  sessions : Array[Map[String, Json]]
  last_message : Json
  people : Json
  first_text : Json
  last_at : Double
}

///|
/// UTF-8 / SQLite BINARY order comparison (Unicode code point order equals UTF-8 byte order).
fn utf8_less(a : String, b : String) -> Bool {
  let ca = a.iter().collect()
  let cb = b.iter().collect()
  let n = @cmp.minimum(ca.length(), cb.length())
  for i in 0..<n {
    if ca[i] != cb[i] {
      return ca[i].to_int() < cb[i].to_int()
    }
  }
  ca.length() < cb.length()
}

///|
fn listed_threads(db : @sql.Db, of : Array[Json]?) -> Array[Listed] raise {
  if of is Some([]) {
    return []
  }
  db.exec("SAVEPOINT listed_threads_read")
  defer (db.exec("RELEASE listed_threads_read") catch { _ => () })
  let base = "SELECT t.*, COALESCE(r.n, 0) AS read_n FROM threads t LEFT JOIN reads r ON r.thread = t.id AND r.viewer = ?1"
  let (rows, ids_param) = match of {
    // (every thread: the archive's whole list, for a device from before)
    None => (db.all(base, [Json::string("")]), None)
    Some(ids) => {
      let param = ids_json(ids)
      (db.all("\{base} WHERE t.id IN (SELECT value FROM json_each(?2))", [Json::string(""), param]), Some(param))
    }
  }
  if rows.length() == 0 {
    return []
  }
  let sessions_rows = match ids_param {
    None => db.all("SELECT * FROM thread_sessions ORDER BY thread, joined_at, rowid", [])
    Some(p) => db.all("SELECT * FROM thread_sessions WHERE thread IN (SELECT value FROM json_each(?1)) ORDER BY thread, joined_at, rowid", [p])
  }
  let sessions_by : Map[String, Array[Map[String, Json]]] = Map([])
  for m in sessions_rows {
    let k = field(m, "thread").stringify()
    match sessions_by.get(k) {
      Some(arr) => arr.push(m)
      None => sessions_by[k] = [m]
    }
  }
  let people_rows = match ids_param {
    None => db.all("SELECT thread, author FROM thread_people ORDER BY thread, first_n", [])
    Some(p) => db.all("SELECT thread, author FROM thread_people WHERE thread IN (SELECT value FROM json_each(?1)) ORDER BY thread, first_n", [p])
  }
  let people_by : Map[String, Array[Json]] = Map([])
  for p in people_rows {
    let k = field(p, "thread").stringify()
    let author = field(p, "author")
    match people_by.get(k) {
      Some(arr) => arr.push(author)
      None => people_by[k] = [author]
    }
  }
  let merged_ready = @legacy.merged_read_ready(db)
  let last_said_by : Map[String, Json] = Map([])
  let first_text_by : Map[String, Json] = Map([])
  if merged_ready {
    let last_rows = match ids_param {
      None => db.all(listed_last_said_all_sql, [])
      Some(p) => db.all(listed_last_said_of_sql, [p])
    }
    for r in last_rows {
      last_said_by[field(r, "thread").stringify()] = to_message(r)
    }
    let first_rows = match ids_param {
      None => db.all(listed_first_text_all_sql, [])
      Some(p) => db.all(listed_first_text_of_sql, [p])
    }
    for r in first_rows {
      first_text_by[field(r, "thread").stringify()] = field(r, "t")
    }
  }
  let out : Array[Listed] = []
  for r in rows {
    let id = field(r, "id")
    let id_key = id.stringify()
    let sessions = sessions_by.get(id_key).unwrap_or([])
    let authors = people_by.get(id_key).unwrap_or([])
    let people = if field(r, "surface") == Json::string("chat") {
      Json::array(authors)
    } else {
      let mut min_c : String? = None
      for m in sessions {
        if field(m, "connect") is String(c) {
          match min_c {
            None => min_c = Some(c)
            Some(cur) => if utf8_less(c, cur) { min_c = Some(c) }
          }
        }
      }
      match min_c {
        Some(c) => Json::array(authors.map(a => Json::string("slack:\{c}:\{js_text(a)}")))
        None => Json::array([])
      }
    }
    let (last_message, first_text) = if merged_ready {
      (last_said_by.get(id_key).unwrap_or(Json::null()), first_text_by.get(id_key).unwrap_or(Json::null()))
    } else {
      (last_said(db, id), first_text(db, id))
    }
    let last_at = match last_message.value("createdAt") {
      Some(Number(n, ..)) => n
      _ => 0.0
    }
    out.push({ thread: r, sessions, last_message, people, first_text, last_at })
  }
  stable_sort(out, (a, b) => {
    if a.last_at != b.last_at {
      return if b.last_at > a.last_at { 1 } else { -1 }
    }
    let ca = num(field(a.thread, "created_at"))
    let cb = num(field(b.thread, "created_at"))
    if ca != cb {
      return if cb > ca { 1 } else { -1 }
    }
    let ia = num(field(a.thread, "id"))
    let ib = num(field(b.thread, "id"))
    if ia != ib {
      return if ib > ia { 1 } else { -1 }
    }
    0
  })
}

///|
/// The name a chat was given (titles.ts `givenTitle`), whether it has one.
fn given_title(thread : Map[String, Json]) -> Bool {
  let text = (k : String) => match field(thread, k) {
    String(s) => @jscase.trim_white(s)
    _ => ""
  }
  text("title") != "" || text("autoTitle") != "" || text("auto_title") != ""
}

///|
/// rows.ts `takeChars`: the first `n` characters (code points).
fn take_chars(s : String, n : Int) -> String {
  let buf = StringBuilder::new()
  let mut count = 0
  for c in s {
    if count >= n {
      break
    }
    count += 1
    buf.write_char(c)
  }
  buf.to_string()
}

///|
/// views.ts `answeredView`, with who answered.
fn answered_view(known : Known, a : Answer, by? : Bool = true) -> Json raise {
  let q = (k : String) => a.question.value(k).unwrap_or(Json::null())
  let v : Map[String, Json] = { "seq": q("n"), "text": q("text"), "askedAt": q("createdAt"), "answeredAt": a.at, "card": a.card }
  if a.answer is Null {
    v["closed"] = true
  } else {
    v["reply"] = a.answer.value("text").unwrap_or(Json::null())
    let quoted = match a.answer.value("quotes") {
      Some(Array(qs)) => qs.iter().any(x => x.value("ts") == Some(q("ts")))
      _ => false
    }
    v["quoted"] = Json::boolean(quoted)
  }
  if by {
    v["by"] = known.creator(a.by)
  }
  Json::object(v)
}

///|
/// views.ts `cardView`: a chat's card still waiting, as `pendingCard` finds it (`kept` none) or as kept (`kept`: its
/// entry, null when none waits), `dismissed` when the viewer let it go (`dismissed`: theirs, "thread:n").
fn card_view(db : @sql.Db, thread : Json, names : Names, dismissed? : Set[String] = Set::new(), kept? : Json) -> Json raise {
  let pending = match kept {
    None => review_pending_card(db, { "thread": thread })
    Some(Null) => return Json::null()
    Some(n) => card_at(db, thread, n)
  }
  guard pending is Array([m, card]) else { return Json::null() }
  let message = match message_view(db, m, names) {
    Object(o) => Map::from_array(o.to_array())
    _ => Map([])
  }
  if card.value("type") == Some(Json::string("options")) {
    message["options"] = card.value("options").unwrap_or(Json::null())
  }
  message["card"] = card
  let seq = m.value("n").unwrap_or(Json::null())
  let before : Array[Json] = []
  if messages_before(db, thread, seq, Some(Json::number(2.0))) is Array(xs) {
    for b in xs {
      before.push(message_view(db, b, names))
    }
  }
  let v : Map[String, Json] = { "seq": seq, "card": card, "message": Json::object(message), "before": Json::array(before) }
  if dismissed.contains("\{js_text(thread)}:\{js_text(seq)}") {
    v["dismissed"] = true
  }
  Json::object(v)
}

///|
/// views.ts `needView`: what one of a chat's agents needs a person for without a card.
fn need_view(db : @sql.Db, thread : Json, agents : Array[Json], names : Names, dismissed? : Set[String] = Set::new()) -> Json raise {
  let turn = agents.iter().map(a => a.value("lastTurn").unwrap_or(Json::null())).find_first(t => match t.value("ending") {
    Some(String(e)) => e == "need_help" || e == "need_decision"
    _ => t.value("declared") == Some(Json::string("block"))
  })
  guard turn is Some(turn) else { return Json::null() }
  let about = turn.value("about").unwrap_or(Json::null())
  let seq = match about {
    Object(_) if about.value("thread") == Some(thread) && is_integer(about.value("seq").unwrap_or(Json::null())) =>
      about.value("seq").unwrap()
    _ => Json::null()
  }
  let started = turn.value("startedAt").unwrap_or(Json::null())
  let ended = turn.value("endedAt").unwrap_or(Json::null())
  let from = if is_integer(started) { started } else { Json::number(0.0) }
  let to = if is_integer(ended) { ended } else { as_integer(Json::string(i64_max)) }
  guard asking_message(db, thread, seq, from, to) is Some((m, earlier)) else { return Json::null() }
  let before = earlier.map(b => message_view(db, b, names)) catch { e => raise e }
  let v : Map[String, Json] = { "seq": m.value("n").unwrap_or(Json::null()), "message": message_view(db, m, names), "before": Json::array(before) }
  // (whom it asks: the person it was answering, by their address, card-kinds.ts ASKER_BEFORE)
  match one(db, asker_before_sql, [thread, m.value("n").unwrap_or(Json::null())]) {
    Some(r) =>
      match field(r, "author") {
        String(a) if a.contains("@") => v["decider"] = Json::string(@jscase.lower(a))
        _ => ()
      }
    None => ()
  }
  if dismissed.contains("\{js_text(thread)}:\{js_text(m.value("n").unwrap_or(Json::null()))}") {
    v["dismissed"] = true
  }
  Json::object(v)
}

///|
/// views.ts `sharedChats(station, false, scope)`: the rows shown (of `scope`, its rows alone).
fn shared_rows(db : @sql.Db, known : Known, scope : Scope?, archived? : Bool = false) -> Array[Json] raise {
  let (_, reviews) = known.config()
  // The sessions the rows are made of: those shown, else those of the scope, the latest active first.
  let sessions = match scope {
    None =>
      if archived {
        db.all("SELECT * FROM sessions ORDER BY last_active_at DESC", [])
      } else {
        db.all(shown_sessions_sql, [])
      }
    Some(sc) => {
      let seen_k : Set[String] = Set::new()
      let found : Array[Map[String, Json]] = []
      let load_one = (k : String) => {
        if !seen_k.contains(k) {
          seen_k.add(k)
          if one(db, "SELECT * FROM sessions WHERE key = ?", [Json::string(k)]) is Some(s) {
            found.push(s)
          }
        }
      }
      for k in sc.sessions {
        load_one(k)
        let anchor = @sql.conversation_of(db, k)
        load_one(anchor)
        for m in @sql.members_of(db, anchor) {
          load_one(m)
        }
      }
      stable_sort(found, (a, b) => {
        let d = num(field(b, "last_active_at")) - num(field(a, "last_active_at"))
        if d < 0.0 { -1 } else if d > 0.0 { 1 } else { 0 }
      })
    }
  }
  let shown : Map[String, Map[String, Json]] = Map([])
  let all : Map[String, Map[String, Json]] = Map([])
  let order : Array[String] = []
  let in_rows : Set[String] = Set::new()
  if scope is Some(sc) {
    for k in sc.rows {
      in_rows.add(k)
    }
  }
  let conv_of = (x : Map[String, Json]) => match field(x, "conv") {
    String(c) if c != "" => c
    _ => js_text(field(x, "key"))
  }
  let grouped_anchors : Set[String] = Set::new()
  for x in sessions {
    let key = js_text(field(x, "key"))
    let anchor = conv_of(x)
    if anchor != key {
      grouped_anchors.add(anchor)
    }
    all[key] = x
    if scope is Some(_) && in_rows.contains(key) {
      in_rows.add(anchor)
    }
    if !(field(x, "archived_at") is Null) == archived {
      shown[key] = x
      if scope is None || in_rows.contains(key) || in_rows.contains(anchor) {
        order.push(key)
      }
    }
  }
  // (a chat's own session, its thread's `home`: one put away with it, archived or hidden, whichever of the two says so;
  // two stations merged once left them apart, a chat archived shown again untitled as its session alone, 2026-11-17)
  let home_of = (t : Listed) => match field(t.thread, "home") { String(h) => Some(h); _ => None }
  let put_away = (t : Listed) => !(field(t.thread, "hidden_at") is Null) ||
    (home_of(t) is Some(h) && all.get(h) is Some(x) && !(field(x, "archived_at") is Null))
  // (in the archive, a chat of its own shows its agents whatever they are doing elsewhere; one with a home, that home)
  let in_chat = (t : Listed) => {
    let alone = archived && home_of(t) is None
    let home = if archived { home_of(t) } else { None }
    t.sessions
    .filter(m => {
      let k = js_text(field(m, "session"))
      (if alone { all } else { shown }).contains(k) || (home == Some(k) && all.contains(k))
    })
    .map(m => js_text(field(m, "session")))
  }
  let listed = (t : Listed) => put_away(t) == archived
  let watches = watching(db, scope.map(sc => sc.sessions))
  let of = match scope {
    Some(sc) => Some(sc.threads)
    None if archived => None
    None =>
      Some(db
      .all("SELECT DISTINCT thread FROM thread_sessions WHERE session IN (SELECT session FROM thread_sessions WHERE thread IN (\n       SELECT ts.thread FROM thread_sessions ts JOIN sessions x ON x.key = ts.session WHERE x.archived_at IS NULL))", [])
      .map(r => field(r, "thread")))
  }
  let threads = listed_threads(db, of).filter(t => t.sessions.iter().any(m => all.contains(js_text(field(m, "session")))))
  let stats = if of is None {
    session_activity_all(db)
  } else {
    let thread_sessions_keys : Array[String] = []
    for t in threads {
      for m in t.sessions {
        thread_sessions_keys.push(js_text(field(m, "session")))
      }
    }
    let stat_keys = unique_keys([
      match scope { Some(sc) => sc.sessions; None => shown.keys().collect() },
      thread_sessions_keys,
    ])
    session_activity(db, stat_keys)
  }
  let waiting_jobs : Set[String] = Set::new()
  let waiting_led : Set[String] = Set::new()
  match scope {
    None => {
      for r in db.all(waiting_jobs_all_sql, []) {
        waiting_jobs.add(js_text(field(r, "session_key")))
      }
      for r in db.all(waiting_led_all_sql, []) {
        waiting_led.add(js_text(field(r, "parent")))
      }
    }
    Some(_) => {
      let all_keys = all.keys().collect()
      if all_keys.length() > 0 {
        let param = [ids_json(all_keys.map(Json::string))]
        for r in db.all(waiting_jobs_of_sql, param) {
          waiting_jobs.add(js_text(field(r, "session_key")))
        }
        for r in db.all(waiting_led_of_sql, param) {
          waiting_led.add(js_text(field(r, "parent")))
        }
      }
    }
  }
  let agent = (key : String) => {
    let x = all.get(key).unwrap()
    let process = known.processes.get(key).unwrap_or("cold")
    let v : Map[String, Json] = {
      "key": Json::string(key),
      "runtime": field(x, "runtime"),
      "model": field(x, "model"),
      "effort": field(x, "effort"),
      "process": Json::string(if process == "warmFailed" { "warm" } else if process == "coldFailed" { "cold" } else { process }),
      "pending": match stats.get(key) { Some((p, _)) => p; None => Json::number(0.0) },
      "lastTurn": match stats.get(key) { Some((_, t)) => t; None => Json::null() },
    }
    if process == "warmFailed" || process == "coldFailed" {
      v["startFailed"] = true
    }
    if watches.get(key) is Some(w) {
      v["watch"] = w
    }
    // (it waits on work it started that is not a watch: client/core-ts chat-stage.ts keeps such a chat at work)
    if waiting_jobs.contains(key) || waiting_led.contains(key) {
      v["waitingAsync"] = true
    }
    Json::object(v)
  }
  // Per agent: the Slack thread it came from (the latest one it is in), whether it has a chat of its own, and who wrote
  // in its Slack threads.
  let origins : Map[String, Listed] = Map([])
  let chatted : Set[String] = Set::new()
  let chatted_convs : Set[String] = Set::new()
  let spoke : Map[String, Array[Json]] = Map([])
  for t in threads {
    let own = field(t.thread, "surface") == Json::string("chat")
    if own && listed(t) {
      if home_of(t) is Some(h) {
        chatted_convs.add(h)
      }
    }
    let writers = if own { [] } else { known.people(t.people) }
    for m in t.sessions {
      let s = js_text(field(m, "session"))
      if own {
        if listed(t) || home_of(t) == Some(s) {
          chatted.add(s)
        }
      } else {
        if !origins.contains(s) {
          origins[s] = t
        }
        if writers.length() > 0 {
          spoke[s] = spoke.get(s).unwrap_or([]) + writers
        }
      }
    }
  }
  let item_threads = threads.filter(t => field(t.thread, "surface") == Json::string("chat") && listed(t) && in_chat(t).length() > 0)
  let carded = if archived { [] } else { threads_with_cards(db, item_threads.map(t => field(t.thread, "id"))) }
  let carded_set : Set[String] = Set::new()
  for c in carded {
    carded_set.add(c.stringify())
  }
  require_card_posts(db, carded)
  let legacy = has_legacy_said(db)
  let said_by : Map[String, Json] = Map([])
  let need_said : Array[Json] = []
  if !legacy && item_threads.length() > 0 {
    let (batch_said, batch_need) = said_of_batch(db, item_threads.map(t => field(t.thread, "id")))
    for k, v in batch_said {
      said_by[k] = v
    }
    need_said.append(batch_need)
  } else {
    for t in item_threads {
      let id = field(t.thread, "id")
      let said = try { Some(said_of(db, legacy, id)) } catch {
        Refused(503, m) if m.has_prefix(said_pending) => {
          let more : Json = @json.parse(m.view(start_offset=said_pending.length()).to_owned()) catch { _ => Json::array([]) }
          if more is Array(xs) {
            need_said.append(xs)
          }
          None
        }
        e => raise e
      }
      if said is Some(s) {
        said_by[id.stringify()] = s
      }
    }
  }
  if need_said.length() > 0 {
    raise Refused(503, said_pending + Json::array(unique_ids([need_said])).stringify())
  }
  let missing_runtime_authors : Array[String] = []
  let seen_missing_authors : Set[String] = Set::new()
  for t in item_threads {
    if t.last_message is Object(_) && t.last_message.value("authorKind") == Some(Json::string("agent")) {
      let has_said_runtime = match t.last_message.value("agentIdentity") {
        Some(Object(_) as id_obj) => id_obj.value("runtime") is Some(String(_))
        _ => false
      }
      if !has_said_runtime {
        if t.last_message.value("author") is Some(String(author)) {
          let has_session_original = match all.get(author) {
            Some(s) => s.get("original_runtime") is Some(r) && !(r is Null)
            None => false
          }
          if !has_session_original {
            push_new(missing_runtime_authors, seen_missing_authors, author)
          }
        }
      }
    }
  }
  if missing_runtime_authors.length() > 1 {
    known.prefetch_original_runtimes(db, missing_runtime_authors)
  }
  let answered : Map[String, Array[Json]] = Map([])
  for a in answers_since(db, Json::number(known.now - answered_within), carded) {
    let k = a.question.value("thread").unwrap_or(Json::null()).stringify()
    let v = answered_view(known, a)
    match answered.get(k) {
      Some(l) => l.push(v)
      None => answered[k] = [v]
    }
  }
  let rows : Array[Json] = []
  let ids : Array[String] = []
  let row_members : Array[Array[String]] = []
  for t in item_threads {
    let id = field(t.thread, "id")
    let from = t.sessions.iter().filter_map(m => origins.get(js_text(field(m, "session")))).head()
    let chat_keys = in_chat(t)
    let agents = chat_keys.map(agent)
    let origin = match from { Some(f) => known.origin(f.thread, f.sessions); None => Json::null() }
    let creator = known.creator(field(t.thread, "created_by"))
    let people = known.people(t.people)
    let names = known.author_names_preloaded(db, field(t.thread, "surface"), t.sessions, all)
    let last_view = if t.last_message is Null { Json::null() } else { message_view(db, t.last_message, names) }
    let starters = agents.map(a => known.creator(match all.get(js_text(a.value("key").unwrap())) { Some(x) => field(x, "created_by"); None => Json::null() })) catch {
      e => raise e
    }
    let key = match home_of(t) {
      Some(h) if all.contains(h) && grouped_anchors.contains(h) => h
      _ => js_text(agents[0].value("key").unwrap())
    }
    let named : Json = match from {
      Some(f) if !(origin is Null) && !given_title(t.thread) =>
        { "thread": thread_json(f.thread), "firstText": f.first_text, "channelName": origin.value("channelName").unwrap_or(Json::null()) }
      _ => { "thread": thread_json(t.thread), "firstText": t.first_text, "channelName": Json::null() }
    }
    let last = match last_view {
      Object(_) => {
        let g = (k : String) => last_view.value(k).unwrap_or(Json::null())
        let text0 = match g("text") { String(s) => @jscase.trim_white(s); _ => "" }
        let quoted_only = text0 == "" && (g("quotes") is Array(qs) && qs.length() > 0)
        let l : Map[String, Json] = {
          "seq": g("seq"),
          "authorKind": g("authorKind"),
          "author": g("author"),
          "authorName": g("authorName"),
          "text": if g("text") is String(_) { Json::string(take_chars(text0, last_chars)) } else { Json::null() },
          "createdAt": g("createdAt"),
        }
        if quoted_only {
          l["quotedOnly"] = true
        }
        if last_view.value("authorPicture") is Some(p) {
          l["authorPicture"] = p
        }
        if !(g("agentIdentity") is Null) {
          l["agentIdentity"] = g("agentIdentity")
        }
        if last_view.value("authorModel") is Some(p) {
          l["authorModel"] = p
        }
        if last_view.value("authorRuntime") is Some(p) {
          l["authorRuntime"] = p
        }
        Json::object(l)
      }
      _ => Json::null()
    }
    let created_at = num(field(t.thread, "created_at"))
    let row : Map[String, Json] = {
      "id": Json::string(key),
      "session": Json::string(key),
      "thread": id,
      "title": "",
      "agents": Json::array(agents),
      "last": last,
      "unread": false,
      "mine": false,
      "lastActiveAt": Json::number(if created_at > t.last_at { created_at } else { t.last_at }),
      "connect": match from { Some(f) => match slack_connect_of(f.sessions) { Some(c) => Json::string(c); None => Json::null() }; None => Json::null() },
      "origin": origin,
      "creator": creator,
      "people": Json::array(people),
    }
    row["ws"] = match all.get(key) {
      Some(x) => field(x, "ws")
      None => match all.get(js_text(agents[0].value("key").unwrap())) { Some(x) => field(x, "ws"); None => Json::null() }
    }
    row["named"] = named
    let mine_of : Array[Json] = [creator] + people + starters
    for a in agents {
      mine_of.append(spoke.get(js_text(a.value("key").unwrap())).unwrap_or([]))
    }
    row["mineOf"] = Json::array(mine_of.filter(p => !(p is Null)))
    row["said"] = said_by.get(id.stringify()).unwrap_or(Json::null())
    row["archiveReminderDismissed"] = false
    row["archiveRecommended"] = Json::boolean(!archived && archive_suggested(db, id))
    if reviews {
      row["archiveReviewed"] = true
      let verdict = if archived { Json::null() } else { archive_verdict(db, id) }
      if !(verdict is Null) {
        row["archiveCheck"] = verdict
      }
    }
    if known.client_keys.get(key) is Some(k) {
      row["clientKey"] = Json::string(k)
    }
    let card = if !archived && carded_set.contains(id.stringify()) { card_view(db, id, names) } else { Json::null() }
    if card is Object(_) {
      let c = card.value("card").unwrap_or(Json::null())
      if c.value("type") == Some(Json::string("options")) {
        // (serde_json's swap_remove of `card`: `before` takes its place)
        row["decision"] = {
          "seq": card.value("seq").unwrap(),
          "before": card.value("before").unwrap(),
          "message": card.value("message").unwrap(),
          "options": c.value("options").unwrap_or(Json::null()),
        }
      }
      row["card"] = card
    } else if !archived {
      let need = need_view(db, id, agents, names)
      if !(need is Null) {
        row["need"] = need
      }
    }
    if answered.get(id.stringify()) is Some(list) {
      answered.remove(id.stringify())
      row["answeredBy"] = Json::array(list)
    }
    if archived {
      row["archived"] = match field(t.thread, "home") {
        String(h) if all.get(h) is Some(home) && !(field(home, "archived_at") is Null) => archived_of(home)
        String(h) if all.contains(h) =>
          {
            "at": match field(t.thread, "hidden_at") { Null => Json::number(0.0); a => a },
            "by": match field(t.thread, "hidden_by") { Null => Json::string("manual"); b => b },
            "alone": false,
          }
        _ =>
          {
            "at": match field(t.thread, "hidden_at") { Null => Json::number(0.0); a => a },
            "by": match field(t.thread, "hidden_by") { Null => Json::string("manual"); b => b },
            "alone": true,
          }
      }
    }
    rows.push(Json::object(row))
    ids.push(key)
    let mkeys : Array[String] = [key]
    for mk in chat_keys {
      if !mkeys.contains(mk) {
        mkeys.push(mk)
      }
    }
    row_members.push(mkeys)
  }
  let conv_order : Array[String] = []
  let conv_members : Map[String, Array[String]] = Map([])
  for key in order {
    let x = shown.get(key).unwrap()
    let anchor = conv_of(x)
    if chatted.contains(key) || chatted_convs.contains(anchor) {
      continue
    }
    match conv_members.get(anchor) {
      Some(ms) =>
        if !ms.contains(key) {
          ms.push(key)
        }
      None => {
        conv_order.push(anchor)
        conv_members[anchor] = [key]
      }
    }
  }
  for anchor in conv_order {
    let raw_ms = conv_members.get(anchor).unwrap()
    let ms = raw_ms.copy()
    ms.sort_by((a, b) => {
      let ca = match all.get(a) { Some(x) => num(field(x, "created_at")); None => 0.0 }
      let cb = match all.get(b) { Some(x) => num(field(x, "created_at")); None => 0.0 }
      if ca != cb {
        if ca < cb { -1 } else { 1 }
      } else {
        a.compare(b)
      }
    })
    let ax = match shown.get(anchor) {
      Some(x) => x
      None => match all.get(anchor) { Some(x) => x; None => shown.get(ms[0]).unwrap() }
    }
    let from = match origins.get(anchor) {
      Some(f) => Some(f)
      None => ms.iter().filter_map(mk => origins.get(mk)).head()
    }
    let origin = match from { Some(f) => known.origin(f.thread, f.sessions); None => Json::null() }
    let own = match field(ax, "title") { String(s) => @jscase.trim_white(s); _ => "" }
    let named : Json = if own != "" {
      { "thread": { "surface": "chat", "title": Json::string(own) } }
    } else {
      match from {
        Some(f) if !(origin is Null) =>
          { "thread": thread_json(f.thread), "firstText": f.first_text, "channelName": origin.value("channelName").unwrap_or(Json::null()) }
        _ => { "thread": { "surface": "chat" } }
      }
    }
    let starter = known.creator(field(ax, "created_by"))
    let mut max_active = num(field(ax, "last_active_at"))
    let mut last_active_json = field(ax, "last_active_at")
    let mine_of : Array[Json] = []
    for mk in ms {
      let mx = shown.get(mk).unwrap()
      let la = num(field(mx, "last_active_at"))
      if la > max_active {
        max_active = la
        last_active_json = field(mx, "last_active_at")
      }
      let st = known.creator(field(mx, "created_by"))
      if !(st is Null) {
        mine_of.push(st)
      }
      mine_of.append(spoke.get(mk).unwrap_or([]))
    }
    let people_arr : Array[Json] = if ms.length() == 1 {
      if starter is Null { [] } else { [starter] }
    } else {
      match from {
        Some(f) => {
          let ps = known.people(f.people)
          if ps.length() > 0 { ps } else if starter is Null { [] } else { [starter] }
        }
        None => if starter is Null { [] } else { [starter] }
      }
    }
    let row : Map[String, Json] = {
      "id": Json::string(anchor),
      "session": Json::string(anchor),
      "thread": Json::null(),
      "title": "",
      "agents": Json::array(ms.map(agent)),
      "last": Json::null(),
      "unread": false,
      "mine": false,
      "lastActiveAt": last_active_json,
      "connect": if field(ax, "connect") == Json::string("chat") { Json::null() } else { field(ax, "connect") },
      "origin": origin,
      "people": Json::array(people_arr),
      "creator": starter,
    }
    row["ws"] = field(ax, "ws")
    row["named"] = named
    row["mineOf"] = Json::array(mine_of.filter(p => !(p is Null)))
    if archived {
      row["archived"] = archived_of(ax)
    }
    rows.push(Json::object(row))
    ids.push(anchor)
    let mkeys : Array[String] = [anchor]
    for mk in ms {
      if !mkeys.contains(mk) {
        mkeys.push(mk)
      }
    }
    row_members.push(mkeys)
  }
  let wanted = match scope {
    None => None
    Some(_) => {
      let ws : Array[String] = []
      for i, k in ids {
        if in_rows.contains(k) {
          for mk in row_members[i] {
            if !ws.contains(mk) {
              ws.push(mk)
            }
          }
        }
      }
      Some(ws)
    }
  }
  let (openers, opened) = openers_opened(db, wanted)
  let shares = chat_shares(db, wanted, known.now)
  let out : Array[Json] = []
  for i, r in rows {
    let key = ids[i]
    if scope is Some(_) && !in_rows.contains(key) {
      continue
    }
    guard r is Object(o) else { continue }
    let row = Map::from_array(o.to_array())
    row["pinned"] = Json::null()
    let mkeys = row_members[i]
    for mk in mkeys {
      if openers.get(mk) is Some(op) {
        row["opener"] = op
        break
      }
    }
    let merged_opened : Array[Json] = []
    for mk in mkeys {
      if opened.get(mk) is Some(children) {
        for c in children {
          if !merged_opened.contains(c) {
            merged_opened.push(c)
          }
        }
      }
    }
    if merged_opened.length() > 0 {
      row["opened"] = Json::array(merged_opened)
    }
    for mk in mkeys {
      if shares.get(mk) is Some(s) {
        row["xshare"] = s
        break
      }
    }
    out.push(Json::object(row))
  }
  out
}

///|
fn keys_arg(v : Json?) -> Array[String]? {
  match v {
    Some(Array(xs)) => Some(xs.map(js_text))
    _ => None
  }
}

///|
/// views.ts `archivedOf`: when a session was archived, by whom, not alone.
fn archived_of(x : Map[String, Json]) -> Json {
  {
    "at": match field(x, "archived_at") { Null => Json::number(0.0); a => a },
    "by": match field(x, "archived_by") { Null => Json::string("manual"); b => b },
    "alone": false,
  }
}

///|
/// views.ts `sharedOf`: the list whole (`scope` null), or the rows a change of some sessions and threads can touch and
/// the ids of those, for everyone.
pub fn shared_of(db : @sql.Db, host : @host.Host, data : String, sep : String, ask : Json) -> Json raise {
  let args = ask.value("args").unwrap_or(Json::null())
  let known = Known::of(host, data, sep, ask)
  match (keys_arg(args.value("sessions")), args.value("threads")) {
    (Some(sessions), Some(Array(threads))) => {
      let scope = scope_of(db, sessions, threads)
      { "rows": Json::array(shared_rows(db, known, Some(scope))), "scope": Json::array(scope.rows.map(Json::string)) }
    }
    _ => { "rows": Json::array(shared_rows(db, known, None)), "scope": Json::null() }
  }
}

///|
/// rows.ts `sees`: whether a viewer sees what is of the workspace `ws`.
fn sees(viewer : Json, ws : Json) -> Bool {
  ws == viewer.value("workspace").unwrap_or(Json::null()) || (ws is Null && viewer.value("home") != Some(Json::boolean(false)))
}

///|
/// views.ts `sharedChatRows` (GET /chats?shared=1): what the viewer's workspace sees of the list; of some sessions and
/// threads with the ids those can touch.
pub fn shared_chats(db : @sql.Db, host : @host.Host, data : String, sep : String, ask : Json) -> Json raise {
  let args = ask.value("args").unwrap_or(Json::null())
  let viewer = args.value("viewer").unwrap_or(Json::null())
  let seen = (rows : Array[Json]) => Json::array(rows.filter(r => sees(viewer, r.value("ws").unwrap_or(Json::null()))))
  let known = Known::of(host, data, sep, ask)
  match (keys_arg(args.value("sessions")), args.value("threads")) {
    (Some(sessions), Some(Array(threads))) => {
      let scope = scope_of(db, sessions, threads)
      { "rows": seen(shared_rows(db, known, Some(scope))), "scope": Json::array(scope.rows.map(Json::string)) }
    }
    _ => seen(shared_rows(db, known, None))
  }
}
