// Who people, agents and Slack's places are, in words, as the chat list says them (station/src/read/views.ts
// `creator`, `people`, `authorNames`, `origin`, `messageView`; read/slack-known.ts): the cloud's names the pool gives with
// each read, the connects' names and Slack workspaces of config.json and the names books of the data directory, read
// once a read. What the station would say in words of its own (the local page, its admin) the pool gives too, in the
// language asked (`words`), so that none is kept here.

///|
/// A connect's place on its platform, what that place is called and the names book it is in (slack-known.ts `Team`).
priv struct Place {
  id : String
  name : String
  book : String
}

///|
/// What a read of the chat list knows besides its database: what the pool gives with it, and what of the data directory
/// it read (each file once).
priv struct Known {
  host : @host.Host
  data : String
  sep : String
  /// People's names by email (the pool's `names`), the hub's process states and client keys.
  names : Map[String, String]
  processes : Map[String, String]
  client_keys : Map[String, String]
  /// The words for the local page and its admin where the pool gives them (`words`: `localPage`, `admin`: what the station
  /// says to Comma). None for a device: the client names them in its own language (core-ts present.ts, entries.ts).
  local_page : String?
  admin : String?
  /// The time of day as the read was asked, ms (`args.now`).
  now : Double
  mut places : Map[String, Place]?
  books : Map[String, @jsjson.JValue]
  mut config : (Array[(String, String)], Bool)?
  mut has_runtime_sessions_ordered : Bool?
  original_runtimes : Map[String, Json]
}

///|
fn pairs_of(v : Json?) -> Map[String, String] {
  let out : Map[String, String] = Map([])
  if v is Some(Array(items)) {
    for item in items {
      if item is Array([String(k), String(v)]) {
        out[k] = v
      }
    }
  }
  out
}

///|
/// What the pool gave with a read (read/mb-reader.ts `Ask`: `names`, `processes`, `clientKeys`; `args.words`).
fn Known::of(host : @host.Host, data : String, sep : String, ask : Json) -> Known {
  let words = ask.value("args").unwrap_or(Json::null()).value("words")
  let word = (k : String) => match words {
    Some(w) =>
      match w.value(k) {
        Some(String(s)) => Some(s)
        _ => None
      }
    None => None
  }
  {
    host,
    data,
    sep,
    names: pairs_of(ask.value("names")),
    processes: pairs_of(ask.value("processes")),
    client_keys: pairs_of(ask.value("clientKeys")),
    local_page: word("localPage"),
    admin: word("admin"),
    now: match ask.value("args").unwrap_or(Json::null()).value("now") {
      Some(Number(n, ..)) => n
      _ => 0.0
    },
    places: None,
    books: Map([]),
    config: None,
    has_runtime_sessions_ordered: None,
    original_runtimes: Map([]),
  }
}

///|
/// slack-known.ts `teams`: each connect's Slack workspace, Feishu company or Comma group, with its name, this station's
/// over those of other stations whose chats run here.
fn Known::places(self : Known) -> Map[String, Place] raise {
  if self.places is Some(p) {
    return p
  }
  let out : Map[String, Place] = Map([])
  let text = (v : @jsjson.JValue?) => match v {
    Some(Str(s)) => Some(@jsjson.sanitize_str(s))
    _ => None
  }
  let remote = read_json(self.host, join_path(self.sep, self.data, "remote-connects.json"))
  for e in entries_of(Some(remote)) {
    let d = jget(Some(e.1), "described")
    match text(jget(d, "kind")) {
      Some("feishu") => out[e.0] = { id: e.0, name: text(jget(jget(d, "identity"), "team")).unwrap_or(""), book: "feishu" }
      Some("slack") =>
        match text(jget(d, "team")) {
          Some(t) if t != "" =>
            out[e.0] = { id: t, name: text(jget(jget(d, "identity"), "team")).unwrap_or(""), book: "slack" }
          _ => ()
        }
      _ => ()
    }
  }
  let own = read_json(self.host, join_path(self.sep, self.data, "config.json"))
  if jget(Some(own), "connects") is Some(Arr(connects)) {
    for c in connects {
      guard text(jget(Some(c), "id")) is Some(id) else { continue }
      match text(jget(Some(c), "kind")) {
        Some("feishu") =>
          out[id] = { id, name: text(jget(jget(jget(Some(c), "feishu"), "tenant"), "name")).unwrap_or(""), book: "feishu" }
        Some("comma") => out[id] = { id, name: "", book: "comma" }
        Some("group") => out[id] = { id, name: "", book: "group" }
        _ => {
          let team = jget(jget(Some(c), "slack"), "team")
          match text(jget(team, "id")) {
            Some(t) if t != "" => out[id] = { id: t, name: text(jget(team, "name")).unwrap_or(""), book: "slack" }
            _ => ()
          }
        }
      }
    }
  }
  self.places = Some(out)
  out
}

///|
/// slack-known.ts `book`: a platform's names book, `{}` when it is not there or is no object.
fn Known::book(self : Known, platform : String) -> @jsjson.JValue raise {
  let file = match platform {
    "feishu" => "feishu-names.json"
    "comma" => "comma-names.json"
    "group" => "group-names.json"
    _ => "slack-names.json"
  }
  if self.books.get(file) is Some(b) {
    return b
  }
  let b = match read_json(self.host, join_path(self.sep, self.data, file)) {
    Obj(_) as b => b
    _ => Obj([])
  }
  self.books[file] = b
  b
}

///|
/// views.ts `configOf`: the config's connects, each with what it is called (its bot's name, else its id), and whether
/// the archive review is on.
fn Known::config(self : Known) -> (Array[(String, String)], Bool) raise {
  if self.config is Some(c) {
    return c
  }
  let connects : Array[(String, String)] = []
  let mut reviews = false
  match read_text(self.host, join_path(self.sep, self.data, "config.json"), strict=false) {
    Some(t) =>
      match (try { Ok(@jsjson.parse(t)) } catch { e => Err(e) }) {
        Ok(raw) => {
          reviews = jget(jget(jget(Some(raw), "automaticDecisions"), "completion"), "enabled") is Some(Bool(true))
          // (`raw.connects` of a value that is none throws there, after the review's flag was read)
          if raw is (Obj(_) | Arr(_) | Str(_) | Num(_) | Bool(_)) && jget(Some(raw), "connects") is Some(Arr(cs)) {
            for c in cs {
              guard jget(Some(c), "id") is Some(Str(id)) else { continue }
              let bot = match jget(jget(Some(c), "slack"), "botName") {
                Some(Str(b)) if @jsjson.sanitize_str(b) != "" => Some(@jsjson.sanitize_str(b))
                _ => None
              }
              connects.push((@jsjson.sanitize_str(id), bot.unwrap_or(@jsjson.sanitize_str(id))))
            }
          }
        }
        Err(_) => ()
      }
    None => ()
  }
  let c = (connects, reviews)
  self.config = Some(c)
  c
}

///|
/// slack-known.ts `teamOf`: a connect's place by its id, or, for one named `<connect>@<station>` (a connect moved here
/// from another station, as its chats said it before), by the connect of that name here.
fn Known::place(self : Known, connect : String) -> Place? raise {
  let places = self.places()
  match places.get(connect) {
    Some(p) => Some(p)
    None =>
      match connect.find("@") {
        Some(at) if at > 0 => places.get(connect.view(end_offset=at).to_owned())
        _ => None
      }
  }
}

///|
/// slack-known.ts `knownPerson`: a person of a connect's platform, as far as known: (name, email, picture), "" for
/// what is not.
fn Known::person(self : Known, connect : String, user : String) -> (String, String, String)? raise {
  let place = self.place(connect)
  let book = self.book(match place { Some(p) => p.book; None => "slack" })
  let person = jget(jget(Some(book), "u:\{match place { Some(p) => p.id; None => "?" }}:\{user}"), "person")
  guard jget(person, "name") is Some(Str(name)) else { return None }
  let said = (v : @jsjson.JValue?) => match v {
    Some(Str(s)) => @jsjson.sanitize_str(s)
    _ => ""
  }
  Some((@jsjson.sanitize_str(name), said(jget(person, "email")), said(jget(person, "picture"))))
}

///|
/// slack-known.ts `knownChannel`.
fn Known::channel(self : Known, connect : String?, channel : Json) -> Json raise {
  guard connect is Some(connect) else { return Json::null() }
  let place = self.place(connect)
  let book = self.book(match place { Some(p) => p.book; None => "slack" })
  match jget(jget(Some(book), "c:\{match place { Some(p) => p.id; None => "?" }}:\{js_text(channel)}"), "channel") {
    Some(Str(name)) => Json::string(@jsjson.sanitize_str(name))
    _ => Json::null()
  }
}

///|
/// slack-known.ts `teamName`.
fn Known::team_name(self : Known, connect : String) -> Json raise {
  match self.places().get(connect) {
    Some(p) if p.name != "" => Json::string(p.name)
    _ => Json::null()
  }
}

///|
/// views.ts `creator`: a creator reference in words.
fn Known::creator(self : Known, reference : Json) -> Json raise {
  guard reference is String(r) else { return Json::null() }
  if r == "local" {
    return { "id": "local", "name": match self.local_page { Some(w) => Json::string(w); None => Json::null() }, "email": Json::null(), "via": "local" }
  }
  if r.has_prefix("slack:") {
    let rest = r.view(start_offset=6).to_owned()
    match rest.find(":") {
      Some(colon) if colon > 0 && colon < rest.length() - 1 => {
        let connect = rest.view(end_offset=colon).to_owned()
        let user = rest.view(start_offset=colon + 1).to_owned()
        let person = self.person(connect, user)
        let out : Map[String, Json] = {
          "id": Json::string(r),
          "name": Json::string(match person { Some((n, _, _)) if n != "" => n; _ => user }),
          "email": match person { Some((_, e, _)) if e != "" => Json::string(e); _ => Json::null() },
          "via": Json::string(match self.place(connect) { Some(p) => p.book; None => "slack" }),
        }
        if person is Some((_, _, p)) && p != "" {
          out["picture"] = Json::string(p)
        }
        return Json::object(out)
      }
      _ => ()
    }
  }
  { "id": Json::string(r), "name": Json::string(self.names.get(r).unwrap_or(r)), "email": Json::string(r), "via": "cloud" }
}

///|
/// views.ts `people`: several people, once each (by their email, else their id).
fn Known::people(self : Known, refs : Json) -> Array[Json] raise {
  let seen : Set[String] = Set::new()
  let out : Array[Json] = []
  guard refs is Array(refs) else { return out }
  for r in refs {
    let p = self.creator(r)
    if p is Null {
      continue
    }
    let key = match (p.value("email"), p.value("id")) {
      (Some(String(e)), _) => e
      (_, Some(String(i))) => i
      _ => ""
    }
    if seen.contains(key) {
      continue
    }
    seen.add(key)
    out.push(p)
  }
  out
}

///|
/// views.ts `slackConnectOf`: the first of a thread's sessions' connects that is not the station's own.
fn slack_connect_of(sessions : Array[Map[String, Json]]) -> String? {
  for m in sessions {
    match field(m, "connect") {
      String(c) if c != "chat" => return Some(c)
      _ => ()
    }
  }
  None
}

///|
/// views.ts `origin`: where a Slack thread is.
fn Known::origin(self : Known, thread : Map[String, Json], sessions : Array[Map[String, Json]]) -> Json raise {
  let connect = slack_connect_of(sessions)
  let out : Map[String, Json] = {
    "teamName": match connect { Some(c) => self.team_name(c); None => Json::null() },
    "channel": field(thread, "channel"),
    "channelName": self.channel(connect, field(thread, "channel")),
    "threadTs": field(thread, "thread_ts"),
    "surface": field(thread, "surface"),
  }
  match parsed_thread_links(field(thread, "links")) {
    Some(l) => out["links"] = l
    None => ()
  }
  Json::object(out)
}

///|
/// Who wrote in a thread, in words and pictures, each author asked once (views.ts `authorNames`).
priv struct Names {
  known : Known
  db : @sql.Db
  surface : Json
  members : Array[Map[String, Json]]
  sessions : Map[String, Map[String, Json]]?
  names : Map[String, Json]
  pictures : Map[String, String]
}

///|
fn Known::author_names(self : Known, db : @sql.Db, thread : Json) -> Names raise {
  let surface = match one(db, "SELECT * FROM threads WHERE id = ?", [thread]) {
    Some(t) => field(t, "surface")
    None => Json::null()
  }
  {
    known: self,
    db,
    surface,
    members: db.all("SELECT * FROM thread_sessions WHERE thread = ? ORDER BY joined_at, rowid", [thread]),
    sessions: None,
    names: Map([]),
    pictures: Map([]),
  }
}

///|
fn Known::author_names_preloaded(
  self : Known,
  db : @sql.Db,
  surface : Json,
  members : Array[Map[String, Json]],
  sessions : Map[String, Map[String, Json]],
) -> Names {
  { known: self, db, surface, members, sessions: Some(sessions), names: Map([]), pictures: Map([]) }
}

///|
fn Names::session_of(self : Names, author : String) -> Map[String, Json]? raise {
  match self.sessions {
    Some(cache) =>
      match cache.get(author) {
        Some(s) => Some(s)
        None => one(self.db, "SELECT * FROM sessions WHERE key = ?", [Json::string(author)])
      }
    None => one(self.db, "SELECT * FROM sessions WHERE key = ?", [Json::string(author)])
  }
}

///|
fn Names::name(self : Names, kind : String, author : String) -> Json raise {
  let key = "\{kind}:\{author}"
  if self.names.get(key) is Some(n) {
    return n
  }
  let name = if kind == "station" {
    Json::string("still.fail")
  } else if kind == "agent" {
    // An agent goes by the name of the connect it posts through (on the page, of the connect that started it).
    let session = self.session_of(author)
    let via = self.members.search_by(m => field(m, "session") == Json::string(author)).map(i => field(self.members[i], "connect"))
    let connect = match via {
      Some(String(c)) if c != "chat" => Json::string(c)
      _ =>
        match session {
          Some(s) => field(s, "connect")
          None => Json::null()
        }
    }
    let (connects, _) = self.known.config()
    match connects.search_by(c => Json::string(c.0) == connect) {
      Some(i) => Json::string(connects[i].1)
      None =>
        match session {
          Some(s) => field(s, "title")
          None => Json::null()
        }
    }
  } else if self.surface == Json::string("chat") {
    if author == "local" {
      match self.known.admin { Some(w) => Json::string(w); None => Json::null() }
    } else {
      Json::string(self.known.names.get(author).unwrap_or(author))
    }
  } else {
    // A Slack person: by the name their connect's Slack gives them, as far as known.
    let connect = slack_connect_of(self.members)
    let person = match connect {
      Some(c) => self.known.person(c, author)
      None => None
    }
    if person is Some((_, _, p)) && p != "" {
      self.pictures[key] = p
    }
    match person {
      Some((n, _, _)) if n != "" => Json::string(n)
      _ => Json::null()
    }
  }
  self.names[key] = name
  name
}

///|
fn Names::picture(self : Names, kind : String, author : String) -> String? raise {
  ignore(self.name(kind, author))
  self.pictures.get("\{kind}:\{author}")
}

///|
fn Known::runtime_sessions_ordered(self : Known, db : @sql.Db) -> Bool raise {
  match self.has_runtime_sessions_ordered {
    Some(v) => v
    None => {
      let v = exists_in(db, "index", "runtime_sessions_ordered")
      self.has_runtime_sessions_ordered = Some(v)
      v
    }
  }
}

///|
/// store.ts `originalRuntime`: the runtime a session began in (a message from before each said its own was of it).
fn original_runtime_with_ordered(db : @sql.Db, key : Json, ordered : Bool) -> Json raise {
  let runtime = (sql : String) => match one(db, sql, [key]) {
    Some(r) => field(r, "runtime")
    None => Json::null()
  }
  let first = try {
    runtime(
      if ordered {
        "SELECT COALESCE(s.original_runtime,\n  (SELECT r.runtime FROM runtime_sessions r INDEXED BY runtime_sessions_ordered WHERE r.session_key = s.key ORDER BY r.at, r.rowid LIMIT 1),\n  s.runtime) AS runtime FROM sessions s WHERE s.key = ?"
      } else {
        "SELECT COALESCE(original_runtime, runtime) AS runtime FROM sessions WHERE key = ?"
      },
    )
  } catch {
    _ => {
      if ordered {
        let found = try {
          Some(
            match runtime("SELECT runtime FROM runtime_sessions INDEXED BY runtime_sessions_ordered WHERE session_key = ? ORDER BY at, rowid LIMIT 1") {
              Null => runtime("SELECT runtime FROM sessions WHERE key = ?")
              r => r
            },
          )
        } catch {
          _ => None
        }
        if found is Some(r) {
          return r
        }
      }
      return runtime("SELECT runtime FROM sessions WHERE key = ?")
    }
  }
  first
}

///|
fn original_runtime(db : @sql.Db, key : Json) -> Json raise {
  original_runtime_with_ordered(db, key, exists_in(db, "index", "runtime_sessions_ordered"))
}

///|
fn Known::prefetch_original_runtimes(self : Known, db : @sql.Db, keys : Array[String]) -> Unit raise {
  if keys.length() == 0 {
    return
  }
  let ordered = self.runtime_sessions_ordered(db)
  let param = [ids_json(keys.map(Json::string))]
  let rows = try {
    db.all(
      if ordered {
        "SELECT s.key, COALESCE(s.original_runtime,\n  (SELECT r.runtime FROM runtime_sessions r INDEXED BY runtime_sessions_ordered WHERE r.session_key = s.key ORDER BY r.at, r.rowid LIMIT 1),\n  s.runtime) AS runtime FROM sessions s WHERE s.key IN (SELECT value FROM json_each(?1))"
      } else {
        "SELECT key, COALESCE(original_runtime, runtime) AS runtime FROM sessions WHERE key IN (SELECT value FROM json_each(?1))"
      },
      param,
    )
  } catch {
    _ =>
      if ordered {
        let found = try {
          Some(
            db.all(
              "SELECT s.key, COALESCE(\n  (SELECT r.runtime FROM runtime_sessions r INDEXED BY runtime_sessions_ordered WHERE r.session_key = s.key ORDER BY r.at, r.rowid LIMIT 1),\n  s.runtime) AS runtime FROM sessions s WHERE s.key IN (SELECT value FROM json_each(?1))",
              param,
            ),
          )
        } catch {
          _ => None
        }
        match found {
          Some(rs) => rs
          None => db.all("SELECT key, runtime FROM sessions WHERE key IN (SELECT value FROM json_each(?1))", param)
        }
      } else {
        db.all("SELECT key, runtime FROM sessions WHERE key IN (SELECT value FROM json_each(?1))", param)
      }
  }
  for r in rows {
    self.original_runtimes[js_text(field(r, "key"))] = field(r, "runtime")
  }
  for k in keys {
    if !self.original_runtimes.contains(k) {
      self.original_runtimes[k] = Json::null()
    }
  }
}

///|
fn Known::original_runtime_of(self : Known, db : @sql.Db, author_json : Json, author : String, session : Map[String, Json]?) -> Json raise {
  if self.original_runtimes.get(author) is Some(r) {
    return r
  }
  if session is Some(s) && s.get("original_runtime") is Some(r) && !(r is Null) {
    self.original_runtimes[author] = r
    return r
  }
  let r = original_runtime_with_ordered(db, author_json, self.runtime_sessions_ordered(db))
  self.original_runtimes[author] = r
  r
}

///|
/// views.ts `messageView`: a merged message as lists show it, with its author's name.
fn message_view(db : @sql.Db, m : Json, names : Names) -> Json raise {
  let get = (k : String) => m.value(k).unwrap_or(Json::null())
  let kind = js_text(get("authorKind"))
  let author = js_text(get("author"))
  let identity = get("agentIdentity")
  let v : Map[String, Json] = {
    "agentIdentity": identity,
    "seq": get("n"),
    "thread": get("thread"),
    "ts": get("ts"),
    "authorKind": get("authorKind"),
    "author": get("author"),
    "authorName": names.name(kind, author),
    "text": get("text"),
    "attachments": get("attachments"),
    "quotes": get("quotes"),
    "declared": get("declared"),
    "createdAt": get("createdAt"),
    "editedAt": get("editedAt"),
  }
  if names.picture(kind, author) is Some(p) {
    v["authorPicture"] = Json::string(p)
  }
  if kind == "agent" {
    let said_runtime = match identity {
      Object(_) => identity.value("runtime")
      _ => None
    }
    let session = match said_runtime {
      Some(String(_)) => None
      _ =>
        match get("author") {
          String(a) => names.session_of(a)
          other => one(db, "SELECT * FROM sessions WHERE key = ?", [other])
        }
    }
    // (`agentIdentity?.runtime ?? originalRuntime(author) ?? session?.runtime`)
    let runtime = match said_runtime {
      Some(Null) | None =>
        match names.known.original_runtime_of(db, get("author"), author, session) {
          Null =>
            match session {
              Some(s) => s.get("runtime")
              None => None
            }
          r => Some(r)
        }
      r => r
    }
    if runtime is Some(String(_) as r) {
      v["authorRuntime"] = r
    }
    let model = match identity {
      Object(_) => identity.value("model")
      _ =>
        match session {
          Some(s) if runtime == s.get("runtime") => s.get("model")
          _ => None
        }
    }
    if model is Some(String(_) as md) {
      v["authorModel"] = md
    }
  }
  if get("declared") is String(d) {
    v["declared"] = Json::string(said_before(d))
    v["ending"] = Json::string(ending_of(d))
  }
  Json::object(v)
}
