// The export (station/test/reference/replica-export.ts `Exporter`, src/replica/AGENTS.md): what must survive of this
// station's conversations, read from stillfail.db and written as batches, a generation of them per workspace, under
// <replica>/own/<workspace>/<gen>/, the exporter's own state in <replica>/export.db. The same reads, records, state and
// files as the TypeScript exporter's, so either takes up where the other left off.

///|
let pass_rows : Int = 5000

///|
let fold_run : Int = 4

///|
let fold_small : Double = 1048576.0

///|
let runs_kept : Int = 512

///|
pub let chunk_plain_bytes : Int = 4194304

///|
let default_transcript_pass_files : Int = 512

///|
let default_transcript_pass_bytes : Int = 33554432

///|
let default_transcript_pass_deletes : Int = 2000

///|
pub let transcript_pass_files : Int = default_transcript_pass_files

///|
pub let transcript_pass_bytes : Int = default_transcript_pass_bytes

///|
pub let transcript_pass_deletes : Int = default_transcript_pass_deletes

///|
let default_chunk_gc_grace_ms : Double = 600000.0

///|
pub let chunk_gc_grace_ms : Double = default_chunk_gc_grace_ms

///|
let state_schema : String =
  #|CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT NOT NULL) WITHOUT ROWID;
  #|CREATE TABLE IF NOT EXISTS digests (ws TEXT NOT NULL, k TEXT NOT NULL, d TEXT NOT NULL, PRIMARY KEY (ws, k)) WITHOUT ROWID;
  #|CREATE TABLE IF NOT EXISTS threads (ws TEXT NOT NULL, thread INTEGER NOT NULL, PRIMARY KEY (ws, thread)) WITHOUT ROWID;
  #|CREATE TABLE IF NOT EXISTS files (path TEXT PRIMARY KEY, size INTEGER NOT NULL, mtime INTEGER NOT NULL, hash TEXT NOT NULL) WITHOUT ROWID;
  #|CREATE INDEX IF NOT EXISTS files_hash ON files (hash);
  #|CREATE TABLE IF NOT EXISTS sent (ws TEXT NOT NULL, path TEXT NOT NULL, PRIMARY KEY (ws, path)) WITHOUT ROWID;
  #|CREATE TABLE IF NOT EXISTS entering (ws TEXT NOT NULL, thread INTEGER NOT NULL, tbl TEXT NOT NULL, after INTEGER NOT NULL, upto INTEGER NOT NULL, PRIMARY KEY (ws, thread, tbl)) WITHOUT ROWID;
  #|CREATE TABLE IF NOT EXISTS transcript_files (ws TEXT NOT NULL, path TEXT NOT NULL, room TEXT, size INTEGER NOT NULL, mtime INTEGER NOT NULL, mode INTEGER NOT NULL, chunks_json TEXT NOT NULL, PRIMARY KEY (ws, path)) WITHOUT ROWID;
  #|CREATE TABLE IF NOT EXISTS transcript_chunks (plain_hash TEXT PRIMARY KEY, chunk_hash TEXT NOT NULL, comp_size INTEGER NOT NULL) WITHOUT ROWID;
  #|CREATE INDEX IF NOT EXISTS transcript_chunks_hash ON transcript_chunks (chunk_hash);
  #|CREATE TABLE IF NOT EXISTS transcript_chunk_gc (chunk_hash TEXT PRIMARY KEY, gone_at INTEGER NOT NULL) WITHOUT ROWID;

///|
let small_tables : Array[String] = [
  "sessions", "threads", "thread_sessions", "runtime_sessions", "closed_cards", "reads", "hidden_chats", "muted_chats",
  "kept_chats", "dismissed", "pins", "opened_chats",
]

///|
let thread_marks : Array[String] = ["reads", "hidden_chats", "muted_chats", "kept_chats", "dismissed"]

///|
fn page_of(table : String) -> String {
  "SELECT rowid AS _rowid, * FROM \{table} WHERE rowid > ? ORDER BY rowid LIMIT ?"
}

///|
fn marks_of(table : String, column : String) -> String {
  "WITH RECURSIVE viewers(viewer) AS (\n  SELECT (SELECT viewer FROM \{table} ORDER BY viewer LIMIT 1)\n  UNION ALL SELECT (SELECT viewer FROM \{table} WHERE viewer > v.viewer ORDER BY viewer LIMIT 1) FROM viewers v WHERE v.viewer IS NOT NULL\n) SELECT m.* FROM viewers v CROSS JOIN \{table} m ON m.viewer = v.viewer AND m.\{column} = ? WHERE v.viewer IS NOT NULL"
}

///|
fn by_key(table : String, cols : Array[String]) -> String {
  "SELECT * FROM \{table} WHERE \{cols.map(c => "\{c} = ?").join(" AND ")}"
}

///|
fn digest(row : JValue) -> String {
  sha1_hex(stringify(row)).view(end_offset=16).to_string()
}

///|
/// A record of two fields, in their order.
fn rec2(k1 : String, v1 : JValue, k2 : String, v2 : JValue) -> JValue {
  Obj([(k1, v1), (k2, v2)])
}

///|
/// A workspace's generation as a pass writes it: its head and the record lines it adds.
priv struct Out {
  mut head : JValue
  lines : Array[String]
  mut bytes : Int
  files : Array[(String, Double)]
  /// Where each hash is in `files`.
  file_at : Map[String, Int]
  mut gone : Bool
  mut messages : Double
}

///|
/// The workspaces this station is in (`Places`).
priv struct Places {
  home : String?
  workspaces : Array[(String, JValue)]
}

///|
/// Optional test-only fault injection hooks (zero overhead when `None` in production).
pub struct TestFaults {
  lstat_err : Set[String]
  readdir_err : Set[String]
  finder_readdir_err : Set[String]
  forbid_readdir : Set[String]
  read_short : Set[String]
  read_short_after_first : Set[String]
  other_kind : Set[String]
  /// The most a pass's transcript finder may ask the shell (`Finder::asked`): more fails the pass.
  finder_asked_most : Int?
}

///|
pub fn TestFaults::from_jvalue(v : JValue) -> TestFaults? {
  guard v is Obj(_) else { return None }
  let set_of = (k : String) => {
    let s : Set[String] = Set([])
    for item in strings_of(get(v, k)) {
      s.add(item)
    }
    s
  }
  Some({
    lstat_err: set_of("lstat_err"),
    readdir_err: set_of("readdir_err"),
    finder_readdir_err: set_of("finder_readdir_err"),
    forbid_readdir: set_of("forbid_readdir"),
    read_short: set_of("read_short"),
    read_short_after_first: set_of("read_short_after_first"),
    other_kind: set_of("other_kind"),
    finder_asked_most: match get(v, "finder_asked_most") {
      Some(Num(n)) => Some(n.to_int())
      _ => None
    },
  })
}

///|
pub fn TestFaults::from_json(raw : String) -> TestFaults? {
  let v = @jsjson.parse(raw) catch { _ => return None }
  TestFaults::from_jvalue(v)
}

///|
pub struct Exporter {
  priv host : @host.Host
  priv files : Files
  priv db : @sql.Db
  priv state : @sql.Db
  priv replica : String
  priv data_dir : String
  priv origin : String
  priv most : Int
  priv chunk_bytes : Int
  priv transcript_pass_files : Int
  priv transcript_pass_bytes : Int
  priv transcript_pass_deletes : Int
  priv chunk_gc_grace_ms : Double
  priv fold : Bool
  priv compact_heads : Bool
  priv now : () -> Double
  priv mut places : Places
  priv mut known : Bool
  priv mut transcripts_pending : Bool
  priv tf_cache : Map[String, Array[(String, JValue)]]
  /// Where a transcript sweep cut short by the pass budget goes on, by workspace: the first path it did not get to.
  /// The next pass starts there, not from the first path again: a session written all the time sorted early would
  /// otherwise use the budget each pass and nothing after it would ever be exported.
  priv transcript_cursor : Map[String, String]
  /// Workspaces whose paths this sweep has gone through to the end; only their `tr_del`s may be left.
  priv transcript_scan_done : Set[String]
  /// Workspaces this sweep is done with, `tr_del`s too.
  priv transcript_ws_done : Set[String]
  /// A pass told of transcripts while a sweep was under way: what it told of may lie behind the cursor, so another
  /// sweep follows this one.
  priv mut transcript_resweep : Bool
  /// Each generation's `head.json` as last read or written, by its directory, with the size and mtime it had on disk:
  /// a head of many transcripts is megabytes of JSON, parsed again only when the file changed.
  priv head_cache : Map[String, (Double, Double, JValue)]
  priv manifest_cache : Map[String, (String, Array[String])]
  priv mut manifest_live : Set[String]
  priv manifest_superseded_at : Map[String, Double]
  priv mut test_faults : TestFaults?
  /// This run of the exporter.
  run : String
  priv mut read : Int
}

///|
pub fn Exporter::new(
  host : @host.Host,
  sep : String,
  db : String,
  replica : String,
  data_dir : String,
  origin : String,
  now : () -> Double,
  batch_bytes? : Int = batch_bytes,
  chunk_bytes? : Int = chunk_plain_bytes,
  transcript_pass_files? : Int = transcript_pass_files,
  transcript_pass_bytes? : Int = transcript_pass_bytes,
  transcript_pass_deletes? : Int = transcript_pass_deletes,
  chunk_gc_grace_ms? : Double = chunk_gc_grace_ms,
  fold? : Bool = true,
  compact_heads? : Bool = false,
  test_faults? : TestFaults? = None,
) -> Exporter raise {
  let files = { host, sep }
  let reading = @sql.Db::attach(host, db, wait=5000)
  files.mkdir(replica)
  let state = @sql.Db::create(host, files.join([replica, "export.db"]), wait=5000)
  state.exec("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;")
  state.exec(state_schema)
  let e = {
    host,
    files,
    db: reading,
    state,
    replica,
    data_dir,
    origin,
    most: batch_bytes,
    chunk_bytes: if chunk_bytes > 0 { chunk_bytes } else { chunk_plain_bytes },
    transcript_pass_files: if transcript_pass_files > 0 { transcript_pass_files } else { default_transcript_pass_files },
    transcript_pass_bytes: if transcript_pass_bytes > 0 { transcript_pass_bytes } else { default_transcript_pass_bytes },
    transcript_pass_deletes: if transcript_pass_deletes > 0 { transcript_pass_deletes } else { default_transcript_pass_deletes },
    chunk_gc_grace_ms: if chunk_gc_grace_ms >= 0.0 { chunk_gc_grace_ms } else { default_chunk_gc_grace_ms },
    fold,
    compact_heads,
    now,
    places: { home: None, workspaces: [] },
    known: false,
    transcripts_pending: false,
    tf_cache: Map([]),
    transcript_cursor: Map([]),
    transcript_scan_done: Set([]),
    transcript_ws_done: Set([]),
    transcript_resweep: false,
    head_cache: Map([]),
    manifest_cache: Map([]),
    manifest_live: Set([]),
    manifest_superseded_at: Map([]),
    test_faults,
    run: files.random(4),
    read: 0,
  }
  // A database rolled back under its exporter (a backup put back): what it says now was never exported as it is.
  let at = e.meta("entries")
  let max = num(e.first("SELECT MAX(rowid) AS m FROM entries", []).bind(r => get(r, "m")))
  if at is Some(a) && (@string.parse_double(a) catch { _ => 0.0 }) > max {
    e.forget()
  }
  e
}

///|
pub fn Exporter::set_test_faults(self : Exporter, faults : TestFaults?) -> Unit {
  self.test_faults = faults
}

///|
pub fn Exporter::close(self : Exporter) -> Unit {
  self.db.close()
  self.state.close()
}

///|
fn Exporter::first(self : Exporter, sql : String, params : Array[Json]) -> JValue? raise {
  match self.db.all(sql, params) {
    [r, ..] => Some(row_of(r))
    _ => None
  }
}

///|
fn Exporter::meta(self : Exporter, k : String) -> String? raise {
  match self.state.all("SELECT v FROM meta WHERE k = ?", [s(k)]) {
    [r, ..] => Some(field_text(r, "v"))
    _ => None
  }
}

///|
fn Exporter::set_meta(self : Exporter, k : String, v : String) -> Unit raise {
  ignore(self.state.run("INSERT INTO meta (k, v) VALUES (?, ?) ON CONFLICT (k) DO UPDATE SET v = excluded.v", [s(k), s(v)]))
}

///|
/// Everything exported is forgotten: the next pass writes it all again, in new generations.
fn Exporter::forget(self : Exporter) -> Unit raise {
  self.state.exec("DELETE FROM meta WHERE k <> 'after'; DELETE FROM digests; DELETE FROM threads; DELETE FROM sent; DELETE FROM entering; DELETE FROM transcript_files; DELETE FROM transcript_chunk_gc;")
  self.known = false
  self.transcripts_pending = false
  self.forget_sweep()
  self.tf_cache.clear()
  self.head_cache.clear()
  self.manifest_cache.clear()
  self.manifest_live = Set([])
  self.manifest_superseded_at.clear()
}

///|
/// The transcript sweep starts again from each workspace's first path.
fn Exporter::forget_sweep(self : Exporter) -> Unit {
  self.end_sweep()
  self.transcript_resweep = false
}

///|
/// A sweep over: the next starts from each workspace's first path.
fn Exporter::end_sweep(self : Exporter) -> Unit {
  self.transcript_cursor.clear()
  self.transcript_scan_done.clear()
  self.transcript_ws_done.clear()
}

///|
fn Exporter::in_transcript_sweep(self : Exporter) -> Bool {
  !self.transcript_cursor.is_empty() || !self.transcript_scan_done.is_empty() || !self.transcript_ws_done.is_empty()
}

///|
/// The workspaces this station is in, as the station says them: `{home, workspaces: [{workspace, name}]}`.
pub fn Exporter::set_places(self : Exporter, places : JValue) -> Unit {
  let home = text_of(get(places, "home"))
  let workspaces = match get(places, "workspaces") {
    Some(Arr(items)) =>
      items.filter_map(w => match text_of(get(w, "workspace")) {
        Some(ws) => Some((ws, get(w, "name").unwrap_or(Null)))
        None => None
      })
    _ => []
  }
  self.places = { home, workspaces }
}

///|
/// A new generation for each workspace, begun after `after` (`newGenerations`).
pub fn Exporter::new_generations(self : Exporter, after : Double) -> Unit raise {
  self.forget()
  self.set_meta("after", @jsjson.stringify(Num(after)))
}

///|
fn Exporter::root(self : Exporter) -> String {
  self.files.join([self.replica, "own"])
}

///|
fn Exporter::gen_dir(self : Exporter, ws : String, gen : String) -> String {
  self.files.join([self.root(), ws, gen])
}

///|
fn Exporter::read_head(self : Exporter, dir : String) -> JValue? {
  let path = self.files.join([dir, "head.json"])
  guard self.files.meta(path) is Some((size, mtime)) else {
    self.head_cache.remove(dir)
    return None
  }
  if self.head_cache.get(dir) is Some((c_size, c_mtime, cached)) && c_size == size && c_mtime == mtime {
    return Some(cached)
  }
  let text = (try { self.files.read(path) } catch { _ => None })
  let parsed = match text {
    Some(t) => Some(@jsjson.parse(t)) catch { _ => None }
    None => None
  }
  match parsed {
    Some(head) => self.head_cache[dir] = (size, mtime, head)
    None => self.head_cache.remove(dir)
  }
  parsed
}

///|
/// A new generation's name: when it began (base 36) and a random part (`genName`).
fn gen_name(now : Double, random : String) -> String {
  let mut v = @math.floor(if now > 0.0 { now } else { 0.0 })
  let digits = "0123456789abcdefghijklmnopqrstuvwxyz"
  let out : Array[Char] = []
  if v == 0.0 {
    out.push('0')
  }
  while v >= 1.0 {
    let d = (v - 36.0 * @math.floor(v / 36.0)).to_int()
    out.push(digits.unsafe_charcode_at(d).unsafe_to_char())
    v = @math.floor(v / 36.0)
  }
  out.rev_in_place()
  String::from_array(out) + "-" + random.view(end_offset=if random.length() < 8 { random.length() } else { 8 }).to_string()
}

///|
/// The generation being written for `ws`, made where there is none.
fn Exporter::gen_of(self : Exporter, ws : String) -> String raise {
  let known = self.meta("gen:\{ws}")
  if known is Some(g) && self.files.exists(self.gen_dir(ws, g)) {
    return g
  }
  if known is Some(g) {
    self.head_cache.remove(self.gen_dir(ws, g))
  }
  let after = match self.meta("after") {
    Some(a) => @string.parse_double(a) catch { _ => 0.0 }
    None => 0.0
  }
  let now = (self.now)()
  let gen = gen_name(if now > after + 1.0 { now } else { after + 1.0 }, self.files.random(4))
  self.set_meta("gen:\{ws}", gen)
  for t in ["digests", "threads", "sent", "entering"] {
    ignore(self.state.run("DELETE FROM \{t} WHERE ws = ?", [s(ws)]))
  }
  let dropped = self.state.run("DELETE FROM transcript_files WHERE ws = ?", [s(ws)])
  self.tf_cache.remove(ws)
  self.manifest_cache.remove(ws)
  // Its transcripts are written again, all of them: none is behind a cursor of the generation before. A workspace
  // with none exported (one with nothing written has no generation directory, so comes here every pass) asks for no scan.
  self.transcript_cursor.remove(ws)
  self.transcript_scan_done.remove(ws)
  self.transcript_ws_done.remove(ws)
  if dropped > 0 {
    self.transcripts_pending = true
  }
  gen
}

///|
/// The heads of this station's generations now, by workspace.
pub fn Exporter::heads(self : Exporter) -> JValue raise {
  let out : Array[(String, JValue)] = []
  for w in self.places.workspaces {
    match self.meta("gen:\{w.0}") {
      Some(gen) =>
        match self.read_head(self.gen_dir(w.0, gen)) {
          Some(head) => out.push((w.0, head))
          None => ()
        }
      None => ()
    }
  }
  Obj(out)
}

///|
/// A pass failed: `export.db` goes back to before it, and what is kept of it in memory goes too.
fn Exporter::roll_back(self : Exporter, known : Bool, pending : Bool) -> Unit {
  self.state.exec("ROLLBACK") catch {
    _ => ()
  }
  self.tf_cache.clear()
  self.head_cache.clear()
  self.manifest_cache.clear()
  self.forget_sweep()
  self.known = known
  self.transcripts_pending = pending
}

///|
/// One pass (`pass`): what changed, as told and as found, written as batches. Its answer as the TypeScript one's
/// (`Passed` and whether the station has no chat of its own).
pub async fn Exporter::pass(self : Exporter, told : JValue) -> JValue {
  guard self.places.home is Some(home) && self.places.workspaces.length() > 0 else {
    return Obj([
      ("heads", Obj([])),
      ("more", Bool(false)),
      ("wrote", Num(0.0)),
      ("read", Num(0.0)),
      ("empty", Bool(self.empty())),
    ])
  }
  // A pass that fails leaves what it was to do as it found it: it may have said the transcripts were done.
  let known = self.known
  let pending = self.transcripts_pending
  self.state.exec("BEGIN IMMEDIATE")
  let passed = self.pass_in(told, home) catch {
    e => {
      self.roll_back(known, pending)
      raise e
    }
  }
  self.state.exec("COMMIT") catch {
    e => {
      self.roll_back(known, pending)
      raise e
    }
  }
  set(passed, "empty", Bool(self.empty()))
}

///|
fn list_of(v : JValue?) -> Array[JValue] {
  match v {
    Some(Arr(items)) => items
    _ => []
  }
}

///|
async fn Exporter::pass_in(self : Exporter, told : JValue, home : String) -> JValue {
  let names = self.places.workspaces
  let ws_of_session = (ws : JValue?) => match ws {
    Some(Str(u)) if u.length() > 0 => @jsjson.sanitize_str(u)
    _ => home
  }
  let outs : Map[String, Out] = Map([])
  for w in names {
    let ws = w.0
    let gen = self.gen_of(ws)
    let dir = self.gen_dir(ws, gen)
    let head = match self.read_head(dir) {
      Some(h) => h
      None =>
        Obj([
          ("v", Num(version.to_double())),
          ("origin", str(self.origin)),
          ("workspace", str(ws)),
          ("gen", str(gen)),
          ("name", match w.1 { Null => str(""); v => v }),
          ("dataDir", str(self.data_dir)),
          ("made", Num(0.0)),
          ("to", Num(0.0)),
          ("batches", Arr([])),
          ("files", Obj([])),
          ("chats", Num(0.0)),
          ("messages", Num(0.0)),
          ("bytes", Num(0.0)),
          ("runs", Arr([])),
        ])
    }
    outs[ws] = { head, lines: [], bytes: 0, files: [], file_at: Map([]), gone: false, messages: 0.0 }
  }
  if self.meta("entries") is None {
    for k in ["entries", "letters", "turns"] {
      self.set_meta(k, "0")
    }
    self.set_meta("ended", "[-1,0]")
    self.known = false
  }
  let say = (ws : String, rec : JValue) => {
    guard outs.get(ws) is Some(out) else { return }
    let line = stringify(rec)
    out.lines.push(line)
    out.bytes += utf8_length(line) + 1
    if get(rec, "gone") is Some(_) {
      out.gone = true
    }
    if get(rec, "file") is Some(Str(f)) {
      let h = @jsjson.sanitize_str(f)
      let size = num(get(rec, "size"))
      match out.file_at.get(h) {
        Some(i) => out.files[i] = (h, size)
        None => {
          out.file_at[h] = out.files.length()
          out.files.push((h, size))
        }
      }
    }
  }
  let most = self.most
  let enough = () => {
    if self.read >= pass_rows {
      return true
    }
    for _, o in outs {
      if o.bytes >= most {
        return true
      }
    }
    false
  }
  self.read = 0
  let all = (sql : String, params : Array[Json]) => {
    let rows = self.db.all(sql, params)
    self.read += rows.length()
    rows.map(row_of)
  }
  let get_digest = (ws : String, k : String) => match self.state.all("SELECT d FROM digests WHERE ws = ? AND k = ?", [s(ws), s(k)]) {
    [r, ..] => Some(field_text(r, "d"))
    _ => None
  }
  let has_thread = (ws : String, thread : Double) => self.state.all("SELECT 1 FROM threads WHERE ws = ? AND thread = ?", [s(ws), Json::number(thread)]).length() > 0
  let drop_thread = (ws : String, thread : Double) => ignore(self.state.run("DELETE FROM threads WHERE ws = ? AND thread = ?", [s(ws), Json::number(thread)]))
  let drop_digest = (ws : String, k : String) => ignore(self.state.run("DELETE FROM digests WHERE ws = ? AND k = ?", [s(ws), s(k)]))
  // A row of a table that changes in place, written where it differs from what was written of it.
  let changed = (ws : String, table : String, row : JValue) => {
    let clean = without(row, "_rowid")
    let k = "\{table}|\{key_of(table, clean)}"
    let d = digest(clean)
    if get_digest(ws, k) == Some(d) {
      return
    }
    ignore(self.state.run("INSERT INTO digests (ws, k, d) VALUES (?, ?, ?) ON CONFLICT (ws, k) DO UPDATE SET d = excluded.d", [s(ws), s(k), s(d)]))
    say(ws, rec2("r", str(table), "row", clean))
  }
  let thread_ws : Map[Double, Array[String]] = Map([])
  let ws_of_thread = (thread : Double) => match thread_ws.get(thread) {
    Some(w) => w
    None => {
      let of = all("SELECT s.ws AS ws FROM thread_sessions ts JOIN sessions s ON s.key = ts.session WHERE ts.thread = ?", [Json::number(thread)]).map(r => ws_of_session(get(r, "ws")))
      let list : Array[String] = []
      if of.length() == 0 {
        list.push(home)
      } else {
        for w in of {
          if !list.contains(w) {
            list.push(w)
          }
        }
      }
      let kept = list.filter(w => outs.contains(w))
      thread_ws[thread] = kept
      kept
    }
  }
  let files_said : Array[(String, Array[String])] = []
  let attached = (ws : String, row : JValue) => {
    for path in attached_paths(row) {
      match files_said.search_by(e => e.0 == ws) {
        Some(i) => if !files_said[i].1.contains(path) { files_said[i].1.push(path) }
        None => files_said.push((ws, [path]))
      }
    }
  }
  let cursor_entries = @string.parse_double(self.meta("entries").unwrap_or("0")) catch { _ => 0.0 }
  let cursor_letters = @string.parse_double(self.meta("letters").unwrap_or("0")) catch { _ => 0.0 }
  let thread_rows = (ws : String, thread : Double) => {
    match all("SELECT * FROM threads WHERE id = ?", [Json::number(thread)]) {
      [t, ..] => changed(ws, "threads", t)
      _ => ()
    }
    for r in all("SELECT * FROM thread_sessions WHERE thread = ?", [Json::number(thread)]) {
      changed(ws, "thread_sessions", r)
    }
    for r in all("SELECT * FROM closed_cards WHERE thread = ?", [Json::number(thread)]) {
      changed(ws, "closed_cards", r)
    }
    for table in thread_marks {
      for r in all(marks_of(table, "thread"), [Json::number(thread)]) {
        changed(ws, table, r)
      }
    }
  }
  let enter = (thread : Double) => {
    for ws in ws_of_thread(thread) {
      if has_thread(ws, thread) {
        continue
      }
      ignore(self.state.run("INSERT OR IGNORE INTO threads (ws, thread) VALUES (?, ?)", [s(ws), Json::number(thread)]))
      thread_rows(ws, thread)
      if cursor_entries > 0.0 {
        ignore(self.state.run("INSERT OR IGNORE INTO entering (ws, thread, tbl, after, upto) VALUES (?, ?, ?, 0, ?)", [s(ws), Json::number(thread), s("entries"), Json::number(cursor_entries)]))
      }
      if cursor_letters > 0.0 {
        ignore(self.state.run("INSERT OR IGNORE INTO entering (ws, thread, tbl, after, upto) VALUES (?, ?, ?, 0, ?)", [s(ws), Json::number(thread), s("letters"), Json::number(cursor_letters)]))
      }
    }
  }
  let count_message = (ws : String, table : String, r : JValue) => {
    if table == "entries" && get(r, "kind") is Some(Str(k)) && @jsjson.sanitize_str(k) == "message" {
      match outs.get(ws) {
        Some(o) => o.messages += 1.0
        None => ()
      }
    }
  }
  let drain_entering = () => {
    while true {
      if enough() {
        return true
      }
      let next = self.state.all("SELECT ws, thread, tbl, after, upto FROM entering LIMIT 1", [])
      guard next is [e, ..] else { return false }
      let ws = field_text(e, "ws")
      let thread = field_num(e, "thread")
      let tbl = field_text(e, "tbl")
      let key = [s(ws), Json::number(thread), s(tbl)]
      if !outs.contains(ws) {
        ignore(self.state.run("DELETE FROM entering WHERE ws = ? AND thread = ? AND tbl = ?", key))
        continue
      }
      let sql = if tbl == "entries" {
        "SELECT rowid AS _rowid, * FROM entries WHERE thread = ? AND n > ? ORDER BY n LIMIT ?"
      } else {
        "SELECT rowid AS _rowid, * FROM letters WHERE thread = ? AND n > ? ORDER BY n LIMIT ?"
      }
      let rows = all(sql, [Json::number(thread), Json::number(field_num(e, "after")), ni(page)])
      let upto = field_num(e, "upto")
      for r in rows {
        if num(get(r, "_rowid")) > upto {
          continue
        }
        say(ws, rec2("r", str(tbl), "row", without(r, "_rowid")))
        attached(ws, r)
        count_message(ws, tbl, r)
      }
      if rows.length() < page {
        ignore(self.state.run("DELETE FROM entering WHERE ws = ? AND thread = ? AND tbl = ?", key))
      } else {
        ignore(self.state.run("UPDATE entering SET after = ? WHERE ws = ? AND thread = ? AND tbl = ?", [Json::number(num(get(rows[rows.length() - 1], "n"))), key[0], key[1], key[2]]))
      }
    }
    false
  }
  let session_ws = (table : String, row : JValue) => self.session_ws(table, row, ws_of_session)
  let session_rows = (key : String) => {
    guard all("SELECT * FROM sessions WHERE key = ?", [s(key)]) is [sess, ..] else { return }
    let ws = ws_of_session(get(sess, "ws"))
    if !outs.contains(ws) {
      return
    }
    changed(ws, "sessions", sess)
    for r in all("SELECT * FROM thread_sessions WHERE session = ?", [s(key)]) {
      changed(ws, "thread_sessions", r)
      enter(num(get(r, "thread")))
    }
    for r in all("SELECT * FROM runtime_sessions WHERE session_key = ?", [s(key)]) {
      changed(ws, "runtime_sessions", r)
    }
    for r in all("SELECT rowid AS _rowid, * FROM turns WHERE session_key = ? ORDER BY started_at DESC LIMIT 2", [s(key)]) {
      changed(ws, "turns", r)
    }
    for r in all("SELECT * FROM opened_chats WHERE child_station = '' AND child = ?", [s(key)]) {
      changed(ws, "opened_chats", r)
    }
    for r in all(marks_of("pins", "session"), [s(key)]) {
      changed(ws, "pins", r)
    }
  }
  let mut more = false
  let want_transcripts = get(told, "transcripts") is Some(Bool(true))
  let scan_transcripts = !self.known || want_transcripts || self.transcripts_pending
  let sess_rows : Array[JValue] = []
  let run_rows : Map[String, Array[JValue]] = Map([])
  // Whether `sess_rows` and `run_rows` hold the sessions already (the small tables were read whole this pass).
  let mut loaded_transcript_sessions = false
  self.db.exec("BEGIN")
  let body = () => {
    // What was deleted, as told.
    for r in list_of(get(told, "removedSessions")) {
      let key = text_of(get(r, "key")).unwrap_or("")
      let w = ws_of_session(get(r, "ws"))
      say(w, rec2("gone", str("session"), "key", str(key)))
      let k = "sessions|\{stringify(Arr([str(key)]))}"
      ignore(self.state.run("DELETE FROM digests WHERE ws = ? AND k >= ? AND k < ?", [s(w), s(k), s(k + "\u{ffff}")]))
    }
    for r in list_of(get(told, "removedThreads")) {
      let id = num(get(r, "id"))
      let wss = match get(r, "ws") {
        None | Some(Null) => outs.keys().collect()
        ws => [ws_of_session(ws)]
      }
      for w in wss {
        if !has_thread(w, id) {
          continue
        }
        say(w, rec2("gone", str("thread"), "id", Num(id)))
        drop_thread(w, id)
      }
    }
    // The small tables whole, once a run.
    if !self.known {
      let seen : Map[String, Set[String]] = Map([])
      for table in small_tables {
        let mut after = 0.0
        while true {
          let rows = all(page_of(table), [Json::number(after), ni(page)])
          for r in rows {
            if table == "sessions" {
              sess_rows.push(r)
            } else if table == "runtime_sessions" {
              if text_of(get(r, "session_key")) is Some(sk) {
                match run_rows.get(sk) {
                  Some(xs) => xs.push(r)
                  None => run_rows[sk] = [r]
                }
              }
            }
            let wss = if table == "sessions" || table == "runtime_sessions" || table == "pins" || table == "opened_chats" {
              session_ws(table, r)
            } else {
              ws_of_thread(num(get(r, if table == "threads" { "id" } else { "thread" })))
            }
            for ws in wss {
              if !outs.contains(ws) {
                continue
              }
              if table == "threads" {
                enter(num(get(r, "id")))
              }
              changed(ws, table, r)
              let set = match seen.get(ws) {
                Some(x) => x
                None => {
                  let x : Set[String] = Set([])
                  seen[ws] = x
                  x
                }
              }
              set.add("\{table}|\{key_of(table, without(r, "_rowid"))}")
            }
          }
          if rows.length() < page {
            break
          }
          after = num(get(rows[rows.length() - 1], "_rowid"))
        }
      }
      // What was written of before and is not there now: gone.
      for ws in outs.keys().collect() {
        let set = seen.get(ws).unwrap_or(Set([]))
        for d in self.state.all("SELECT k FROM digests WHERE ws = ?", [s(ws)]) {
          let k = field_text(d, "k")
          if set.contains(k) || k.has_prefix("turns|") {
            continue
          }
          let bar = k.find("|").unwrap_or(0)
          let table = k.view(end_offset=bar).to_string()
          let key = match (@jsjson.parse(k.view(start_offset=bar + 1).to_string()) catch { _ => Arr([]) }) {
            Arr(items) => items
            _ => []
          }
          drop_digest(ws, k)
          if table == "sessions" {
            let v = key.get(0).unwrap_or(Null)
            say(ws, rec2("gone", str("session"), "key", str(match v { Str(u) => @jsjson.sanitize_str(u); Null => "null"; x => stringify(x) })))
          } else if table == "threads" {
            let id = num(key.get(0))
            say(ws, rec2("gone", str("thread"), "id", Num(id)))
            drop_thread(ws, id)
          } else {
            let named = key_columns(table).mapi((i, c) => (c, key.get(i).unwrap_or(Null)))
            say(ws, rec2("del", str(table), "key", Obj(named)))
          }
        }
      }
      self.known = true
      loaded_transcript_sessions = true
    }
    // What changed in place, as told.
    for k in list_of(get(told, "sessions")) {
      match text_of(Some(k)) {
        Some(key) => session_rows(key)
        None => ()
      }
    }
    for t in list_of(get(told, "threads")) {
      let thread = num(Some(t))
      enter(thread)
      for ws in ws_of_thread(thread) {
        thread_rows(ws, thread)
      }
    }
    for m in list_of(get(told, "marks")) {
      let table = text_of(get(m, "table")).unwrap_or("")
      let key = get(m, "key").unwrap_or(Obj([]))
      let cols = key_columns(table)
      let row = all(by_key(table, cols), cols.map(c => param(get(key, c)))).get(0)
      let wss = if table == "pins" { session_ws("pins", key) } else { ws_of_thread(num(get(key, "thread"))) }
      for ws in wss {
        let k = "\{table}|\{key_of(table, key)}"
        match row {
          Some(r) => changed(ws, table, r)
          None =>
            if get_digest(ws, k) is Some(_) {
              drop_digest(ws, k)
              say(ws, rec2("del", str(table), "key", key))
            }
        }
      }
    }
    // A thread new to a workspace: its logs before.
    if drain_entering() {
      more = true
    }
    // The logs, past where they were exported.
    for pair in [("entries", cursor_entries), ("letters", cursor_letters)] {
      let (table, start) = pair
      let mut at = start
      while true {
        if enough() {
          more = true
          break
        }
        let rows = all("SELECT rowid AS _rowid, * FROM \{table} WHERE rowid > ? ORDER BY rowid LIMIT ?", [Json::number(at), ni(page)])
        for r in rows {
          let thread = num(get(r, "thread"))
          enter(thread)
          for ws in ws_of_thread(thread) {
            say(ws, rec2("r", str(table), "row", without(r, "_rowid")))
            attached(ws, r)
            count_message(ws, table, r)
          }
          at = num(get(r, "_rowid"))
        }
        if rows.length() < page {
          break
        }
      }
      self.set_meta(table, @jsjson.stringify(Num(at)))
    }
    for k in ["turns", "ended"] {
      let mut at = if k == "turns" {
        (@string.parse_double(self.meta("turns").unwrap_or("0")) catch { _ => 0.0 }, 0.0)
      } else {
        match (@jsjson.parse(self.meta("ended").unwrap_or("[-1,0]")) catch { _ => Arr([]) }) {
          Arr([a, b, ..]) => (num(Some(a)), num(Some(b)))
          _ => (-1.0, 0.0)
        }
      }
      while true {
        if enough() {
          more = true
          break
        }
        let rows = if k == "turns" {
          all("SELECT rowid AS _rowid, * FROM turns WHERE rowid > ? ORDER BY rowid LIMIT ?", [Json::number(at.0), ni(page)])
        } else {
          all("SELECT rowid AS _rowid, * FROM turns INDEXED BY turns_ended WHERE ended_at > ?1 OR (ended_at = ?1 AND rowid > ?2) ORDER BY ended_at, rowid LIMIT ?3", [
            Json::number(at.0),
            Json::number(at.1),
            ni(page),
          ])
        }
        for r in rows {
          match session_ws("turns", r).get(0) {
            Some(ws) if outs.contains(ws) => changed(ws, "turns", r)
            _ => ()
          }
          at = if k == "turns" { (num(get(r, "_rowid")), 0.0) } else { (num(get(r, "ended_at")), num(get(r, "_rowid"))) }
        }
        if rows.length() < page {
          break
        }
      }
      self.set_meta(k, if k == "turns" { @jsjson.stringify(Num(at.0)) } else { stringify(Arr([Num(at.0), Num(at.1)])) })
    }
  }
  body() catch {
    e => {
      self.db.exec("COMMIT") catch {
        _ => ()
      }
      raise e
    }
  }
  self.db.exec("COMMIT")
  // The files the rows name, each once in a generation: by the hash of what it holds.
  for e in files_said {
    let (ws, paths) = e
    for path in paths {
      if self.state.all("SELECT 1 FROM sent WHERE ws = ? AND path = ?", [s(ws), s(path)]).length() > 0 {
        continue
      }
      guard self.hashed(path) is Some((hash, size)) else { continue }
      ignore(self.state.run("INSERT OR IGNORE INTO sent (ws, path) VALUES (?, ?)", [s(ws), s(path)]))
      say(ws, Obj([("file", str(hash)), ("size", Num(size)), ("path", str(path))]))
    }
  }
  let mut sweep_completed = false
  if scan_transcripts {
    if want_transcripts && self.in_transcript_sweep() {
      self.transcript_resweep = true
    }
    if more {
      self.transcripts_pending = true
    } else {
      // The sessions the transcripts are found by, read only once the logs are caught up and outside the pass's row
      // budget: read before, on a station with more sessions than `pass_rows`, they used up every pass's budget ahead of
      // the logs, so `more` never came false and nothing after them (logs, transcripts) was exported again.
      if !loaded_transcript_sessions {
        self.transcript_sessions(sess_rows, run_rows)
      }
      let transcripts_more = self.export_transcripts(outs, sess_rows, run_rows, ws_of_session, say)
      if transcripts_more {
        self.transcripts_pending = true
        more = true
      } else {
        sweep_completed = true
        if self.transcript_resweep {
          self.transcript_resweep = false
          self.transcripts_pending = true
          more = true
        } else {
          self.transcripts_pending = false
        }
      }
    }
  }
  let mut wrote = 0
  let heads : Array[(String, JValue)] = []
  for w in names {
    guard outs.get(w.0) is Some(out) else { continue }
    if out.lines.length() > 0 {
      self.write(w.0, out)
      wrote += 1
    }
    heads.push((w.0, if self.compact_heads { self.compact_head(w.0, out.head) } else { out.head }))
  }
  if self.compact_heads {
    self.gc_manifests(outs)
  }
  // After each whole sweep, a sweep to follow or not: never in the middle of one.
  if sweep_completed {
    self.gc_transcript_chunks()
  }
  Obj([
    ("heads", Obj(heads)),
    ("more", Bool(more)),
    ("wrote", Num(wrote.to_double())),
    ("read", Num(self.read.to_double())),
  ])
}

///|
/// Every session and runtime session, for finding transcripts by: in a short read of their own, not counted in the
/// pass's rows.
fn Exporter::transcript_sessions(self : Exporter, sess_rows : Array[JValue], run_rows : Map[String, Array[JValue]]) -> Unit raise {
  self.db.exec("BEGIN")
  let read = () => {
    for table in ["sessions", "runtime_sessions"] {
      let mut after = 0.0
      while true {
        let rows = self.db.all(page_of(table), [Json::number(after), ni(page)]).map(row_of)
        for r in rows {
          if table == "sessions" {
            sess_rows.push(r)
          } else if text_of(get(r, "session_key")) is Some(sk) {
            match run_rows.get(sk) {
              Some(xs) => xs.push(r)
              None => run_rows[sk] = [r]
            }
          }
        }
        if rows.length() < page {
          break
        }
        after = num(get(rows[rows.length() - 1], "_rowid"))
      }
    }
  }
  read() catch {
    e => {
      self.db.exec("COMMIT") catch {
        _ => ()
      }
      raise e
    }
  }
  self.db.exec("COMMIT")
}

///|
fn Exporter::session_ws(self : Exporter, table : String, row : JValue, ws_of : (JValue?) -> String) -> Array[String] raise {
  let key = get(row, if table == "sessions" { "key" } else if table == "pins" { "session" } else if table == "opened_chats" { "child" } else { "session_key" })
  if table == "opened_chats" && !(get(row, "child_station") is Some(Str(""))) {
    return []
  }
  if table == "sessions" {
    return [ws_of(get(row, "ws"))]
  }
  match self.db.all("SELECT ws FROM sessions WHERE key = ?", [param(key)]) {
    [r, ..] => {
      self.read += 1
      [ws_of(get(row_of(r), "ws"))]
    }
    _ => []
  }
}

///|
/// The hash and size of the file at `path`, read once while it is as it was; none where it is not there.
fn Exporter::hashed(self : Exporter, path : String) -> (String, Double)? raise {
  guard self.files.kind(path) is Some("file") else { return None }
  guard self.files.meta(path) is Some((size, mtime)) else { return None }
  match self.state.all("SELECT size, mtime, hash FROM files WHERE path = ?", [s(path)]) {
    [k, ..] if field_num(k, "size") == size && field_num(k, "mtime") == mtime => return Some((field_text(k, "hash"), size))
    _ => ()
  }
  guard self.files.hash(path) is Some(hash) else { return None }
  ignore(
    self.state.run("INSERT INTO files (path, size, mtime, hash) VALUES (?, ?, ?, ?) ON CONFLICT (path) DO UPDATE SET size = excluded.size, mtime = excluded.mtime, hash = excluded.hash", [
      s(path),
      Json::number(size),
      Json::number(mtime),
      s(hash),
    ]),
  )
  Some((hash, size))
}

///|
/// A batch written whole under `dir`'s log, named by its numbers and its bytes' hash.
fn Exporter::write_batch(self : Exporter, dir : String, gen : String, from : Int64, to : Int64, made : Double, lines : Array[String]) -> String raise {
  let log = self.files.join([dir, "log"])
  let writing = self.files.join([log, "\{pad10(from)}-\{pad10(to)}.writing"])
  let sha = self.files.write(writing, batch_text(gen, from, to, made, lines), zstd=true)
  let name = batch_name(from, to, sha)
  self.files.rename(writing, self.files.join([log, name]))
  name
}

///|
fn strings_of(v : JValue?) -> Array[String] {
  list_of(v).filter_map(x => text_of(Some(x)))
}

///|
fn strs(list : Array[String]) -> JValue {
  Arr(list.map(str))
}

///|
/// Batches of what `out` says, then the head that names them; folded as batches build up.
fn Exporter::write(self : Exporter, ws : String, out : Out) -> Unit raise {
  let head = out.head
  let gen = text_of(get(head, "gen")).unwrap_or("")
  let dir = self.gen_dir(ws, gen)
  let made = (self.now)()
  let mut n = num(get(head, "to")).to_int64()
  let names : Array[String] = []
  let first = n + 1L
  let runs = Runs::new(self.most, run => {
    n += 1L
    names.push(self.write_batch(dir, gen, n, n, made, run))
  })
  for l in out.lines {
    runs.push(l)
  }
  runs.finish()
  let runs_list = list_of(get(head, "runs"))
  let last_run = match runs_list.last() {
    Some(r) => text_of(get(r, "run"))
    None => None
  }
  let runs_list = if runs_list.length() == 0 || last_run != Some(self.run) {
    runs_list + [Obj([("run", str(self.run)), ("from", Num(first.to_double()))])]
  } else {
    runs_list
  }
  let kept = if runs_list.length() > runs_kept { runs_list[runs_list.length() - runs_kept:].to_array() } else { runs_list }
  let files = set_all(get(head, "files").unwrap_or(Obj([])), out.files.map(f => (f.0, Num(f.1))))
  let chats = match self.state.all("SELECT COUNT(*) AS n FROM threads WHERE ws = ?", [s(ws)]) {
    [r, ..] => field_num(r, "n")
    _ => 0.0
  }
  let mut next = head
  next = set(next, "made", Num(made))
  next = set(next, "to", Num(n.to_double()))
  next = set(next, "batches", strs(strings_of(get(head, "batches")) + names))
  next = set(next, "runs", Arr(kept))
  next = set(next, "files", files)
  let tf_entries = match self.tf_cache.get(ws) {
    Some(cached) => cached
    None => {
      let entries = self.transcript_files_map(ws)
      self.tf_cache[ws] = entries
      entries
    }
  }
  if tf_entries.length() > 0 {
    next = set(next, "transcriptFiles", Obj(tf_entries))
  } else {
    next = without(next, "transcriptFiles")
  }
  next = set(next, "chats", Num(chats))
  next = set(next, "messages", Num(num(get(head, "messages")) + out.messages))
  out.head = self.fold_gen(dir, next, out.gone)
}

///|
fn Exporter::write_head(self : Exporter, dir : String, head : JValue) -> Unit raise {
  let path = self.files.join([dir, "head.json"])
  self.head_cache.remove(dir)
  ignore(self.files.write(path, @jsjson.stringify_indent(head, 1)))
  match self.files.meta(path) {
    Some((size, mtime)) => self.head_cache[dir] = (size, mtime, head)
    None => ()
  }
}

///|
/// The generation's batches folded where they built up (`#fold`).
fn Exporter::fold_gen(self : Exporter, dir : String, head : JValue, everything : Bool) -> JValue raise {
  let log = self.files.join([dir, "log"])
  let size = (b : String) => self.files.size(self.files.join([log, b]))
  let level = (b : String) => {
    let sz = size(b)
    @math.floor(@math.ln((if sz > 4096.0 { sz } else { 4096.0 }) / 4096.0) / @math.ln(fold_run.to_double()))
  }
  let mut h = head
  while self.fold {
    let bs = strings_of(get(h, "batches"))
    let take = if everything {
      if bs.length() == 0 {
        break
      }
      bs
    } else {
      if bs.length() < fold_run {
        break
      }
      let tail = bs[bs.length() - fold_run:].to_array()
      let l = level(tail[0])
      let mut same = true
      let mut total = 0.0
      for b in tail {
        if level(b) != l {
          same = false
        }
        total += size(b)
      }
      if !same || total >= fold_small {
        break
      }
      tail
    }
    let work = self.files.join([self.replica, "fold.db"])
    self.files.remove(work)
    let folded = Folded::new(self.host, work)
    let step = () => {
      for b in take {
        for line in batch_lines(self.files, self.files.join([log, b])) {
          folded.apply(line)
        }
      }
      let (from, _) = batch_span(take[0]).unwrap()
      let (_, to) = batch_span(take[take.length() - 1]).unwrap()
      let whole = take.length() == bs.length()
      let names : Array[String] = []
      let gen = text_of(get(h, "gen")).unwrap_or("")
      let made = num(get(h, "made"))
      let runs = Runs::new(self.most, run => names.push(self.write_batch(dir, gen, from, to, made, run)))
      if whole {
        folded.records(line => runs.push(line))
      } else {
        folded.partial(line => runs.push(line))
      }
      runs.finish()
      let mut next = h
      next = set(next, "batches", strs(bs[0:bs.length() - take.length()].to_array() + names))
      if whole {
        let files : Array[(String, JValue)] = []
        let file_idx : Map[String, Int] = Map([])
        folded.each_named_file((_, hash, sz) => {
          match file_idx.get(hash) {
            Some(i) => files[i] = (hash, Num(sz))
            None => {
              file_idx[hash] = files.length()
              files.push((hash, Num(sz)))
            }
          }
        })
        next = set(next, "files", Obj(files))
        let (chats, messages) = folded.counts()
        next = set(next, "chats", Num(chats))
        next = set(next, "messages", Num(messages))
      } else {
        next = set(next, "files", get(h, "files").unwrap_or(Obj([])))
        next = set(next, "chats", get(h, "chats").unwrap_or(Null))
        next = set(next, "messages", get(h, "messages").unwrap_or(Null))
      }
      h = next
      self.write_head(dir, h)
      for b in take {
        if !names.contains(b) {
          self.files.remove(self.files.join([log, b]))
        }
      }
    }
    step() catch {
      e => {
        folded.close()
        self.files.remove(work) catch {
          _ => ()
        }
        raise e
      }
    }
    folded.close()
    self.files.remove(work)
    if everything || strings_of(get(h, "batches")).length() >= bs.length() {
      break
    }
  }
  h = set(h, "bytes", Num(self.bytes(dir, h)))
  self.write_head(dir, h)
  // (a batch written by a run that ended before its head was, or half of one: never named, let go)
  let named = strings_of(get(h, "batches"))
  for b in self.files.names(log).unwrap_or([]) {
    if !named.contains(b) {
      self.files.remove(self.files.join([log, b]))
    }
  }
  h
}

///|
fn Exporter::bytes(self : Exporter, dir : String, h : JValue) -> Double {
  let mut n = 0.0
  for b in strings_of(get(h, "batches")) {
    match self.files.meta(self.files.join([dir, "log", b])) {
      Some((size, _)) => n += size
      None => ()
    }
  }
  let seen : Set[String] = Set([])
  match get(h, "files") {
    Some(Obj(entries)) =>
      for e in entries {
        seen.add(e.0)
        n += num(Some(e.1))
      }
    _ => ()
  }
  match get(h, "transcriptFiles") {
    Some(Obj(entries)) =>
      for e in entries {
        if !seen.contains(e.0) {
          seen.add(e.0)
          n += num(Some(e.1))
        }
      }
    _ => ()
  }
  n
}

///|
/// Whether this station has no chat of its own yet.
pub fn Exporter::empty(self : Exporter) -> Bool raise {
  self.db.all("SELECT 1 FROM sessions LIMIT 1", []).length() == 0 && self.db.all("SELECT 1 FROM threads LIMIT 1", []).length() == 0
}

///|
/// Above this many hashes, `sources` reads the files table once instead of once a hash.
const SOURCES_POINT_MOST = 32

///|
/// Where the files of `hashes` are now on this station, for a place that lacks them (`sources`). A level of a first copy
/// asks it of every chunk of every transcript (246k on a real station): each hash is looked at once, the files table
/// read once for many, and each candidate stat'ed here rather than through the shell.
pub fn Exporter::sources(self : Exporter, hashes : Array[String]) -> JValue raise {
  let by_hash : Map[String, Array[String]]? = if hashes.length() > SOURCES_POINT_MOST {
    // (the table's rows are read whole, once; only the paths of the hashes asked are kept past it)
    let m : Map[String, Array[String]] = Map([])
    for h in hashes {
      m[h] = []
    }
    for r in self.state.all("SELECT hash, path FROM files ORDER BY path", []) {
      if m.get(field_text(r, "hash")) is Some(paths) {
        paths.push(field_text(r, "path"))
      }
    }
    Some(m)
  } else {
    None
  }
  let out : Array[(String, JValue)] = []
  let seen : Set[String] = Set([])
  for h in hashes {
    if seen.contains(h) {
      continue
    }
    seen.add(h)
    let paths = match by_hash {
      Some(m) => m.get(h).unwrap_or([])
      None => self.state.all("SELECT path FROM files WHERE hash = ? ORDER BY path", [s(h)]).map(r => field_text(r, "path"))
    }
    let mut found = false
    for path in paths {
      if self.files.is_regular_file(path) {
        out.push((h, str(path)))
        found = true
        break
      }
    }
    if !found {
      let chunk = self.files.join([self.replica, "chunks", h])
      if self.files.is_regular_file(chunk) {
        out.push((h, str(chunk)))
        found = true
      }
    }
    if !found {
      let manifest = self.files.join([self.replica, "manifests", h])
      if self.files.is_regular_file(manifest) {
        out.push((h, str(manifest)))
      }
    }
  }
  Obj(out)
}

///|
/// Strict whitelist for transcript backup/restore paths: only under `<dataDir>/transcripts*` or AGY `cli_kept`
/// (`homes/<profile>/agy/.gemini/antigravity-cli/{conversations,brain,annotations}`). Never `sessions/*/workspace`.
fn Files::is_transcript_path(self : Files, data : String, path : String) -> Bool {
  guard self.under_of(data, path) is Some(rel) && rel != "" else { return false }
  let parts : Array[String] = rel.split(self.sep).map(x => x.to_string()).collect()
  for p in parts {
    if p == "" || p == "." || p == ".." {
      return false
    }
  }
  parts.length() > 1 && (parts[0].has_prefix("transcripts") || cli_kept(parts))
}

///|
#borrow(path)
extern "C" fn missing_ffi(path : Bytes, follow : Int) -> Int = "sfc_missing"

///|
#borrow(path)
extern "C" fn dir_missing_ffi(path : Bytes) -> Int = "sfc_dir_missing"

///|
#borrow(path)
extern "C" fn dir_readable_ffi(path : Bytes) -> Int = "sfc_dir_readable"

///|
#borrow(path)
extern "C" fn is_file_ffi(path : Bytes) -> Int = "sfc_is_file"

///|
/// Whether `path` is a regular file, links followed (`kind(path) is Some("file")`), asked of the shell only where the
/// system's answer here may differ from its (a long Windows path).
fn Files::is_regular_file(self : Files, path : String) -> Bool {
  match is_file_ffi(c_path(path)) {
    1 => true
    0 => false
    _ => self.kind(path) is Some("file")
  }
}

///|
fn Files::is_missing(self : Files, path : String, follow? : Bool = true) -> Bool {
  ignore(self)
  missing_ffi(c_path(path), if follow { 1 } else { 0 }) == 1
}

///|
fn Files::is_dir_missing(self : Files, path : String) -> Bool {
  ignore(self)
  dir_missing_ffi(c_path(path)) == 1
}

///|
fn Exporter::dir_unreadable_checked(self : Exporter, dir : String) -> Bool raise {
  if self.test_faults is Some(f) {
    if f.forbid_readdir.contains(dir) {
      fail("BUG: descended into pruned directory \{dir}")
    }
    if f.readdir_err.contains(dir) {
      return true
    }
  }
  dir_readable_ffi(c_path(dir)) == 0
}

///|
fn path_under_any_dir(path : String, dirs : Set[String], sep : String) -> Bool {
  for d in dirs {
    let prefix = if d.has_suffix(sep) { d } else { d + sep }
    if path == d || path.has_prefix(prefix) {
      return true
    }
  }
  false
}

///|
fn is_pruned_brain_rel(rel_parts : Array[String]) -> Bool {
  match rel_parts {
    [".system_generated", "steps"] => true
    [".system_generated", "logs", "chunks"] => true
    ["scratch"] => true
    _ => false
  }
}

///|
/// Whether `path` lies under one of the three pruned AGY brain derived cache subtrees.
fn Files::is_pruned_brain_path(self : Files, data : String, path : String) -> Bool {
  guard self.under_of(data, path) is Some(rel) && rel != "" else { return false }
  let parts : Array[String] = rel.split(self.sep).map(x => x.to_string()).collect()
  guard parts.length() >= 8 &&
    parts[0] == "homes" &&
    one_segment(parts[1]) &&
    parts[2] == "agy" &&
    parts[3] == ".gemini" &&
    parts[4] == "antigravity-cli" &&
    parts[5] == "brain" &&
    one_segment(parts[6]) else {
    return false
  }
  if parts[7] == "scratch" {
    return true
  }
  if parts.length() >= 9 && parts[7] == ".system_generated" && parts[8] == "steps" {
    return true
  }
  if parts.length() >= 10 && parts[7] == ".system_generated" && parts[8] == "logs" && parts[9] == "chunks" {
    return true
  }
  false
}

///|
/// `lstat` distinguishing confirmed missing (`Ok(None)`) from unreadable error (`Err(())`).
fn Exporter::lstat_checked(self : Exporter, path : String) -> Result[(String, Double, Int, Double)?, Unit] {
  if self.test_faults is Some(f) && f.lstat_err.contains(path) {
    return Err(())
  }
  match self.files.lstat(path) {
    Some(st) => Ok(Some(st))
    None => if self.files.is_missing(path, follow=false) { Ok(None) } else { Err(()) }
  }
}

///|
/// `listing` distinguishing confirmed missing (`Ok(None)`) from unreadable error (`Err(())`).
fn Exporter::listing_checked(self : Exporter, dir : String) -> Result[Array[(String, String)]?, Unit] raise {
  if self.test_faults is Some(f) {
    if f.forbid_readdir.contains(dir) {
      fail("BUG: descended into pruned directory \{dir}")
    }
    if f.readdir_err.contains(dir) {
      return Err(())
    }
  }
  match self.files.listing(dir) {
    Some(entries) =>
      match self.test_faults {
        Some(f) if !f.other_kind.is_empty() =>
          Ok(
            Some(
              entries.map(e => {
                let (name, kind) = e
                let path = self.files.join([dir, name])
                if f.other_kind.contains(path) {
                  (name, "other")
                } else {
                  (name, kind)
                }
              }),
            ),
          )
        _ => Ok(Some(entries))
      }
    None => if self.files.is_dir_missing(dir) { Ok(None) } else { Err(()) }
  }
}

///|
fn Exporter::walk_transcript_dir(
  self : Exporter,
  dir : String,
  add : (String) -> Unit,
  on_error? : (String) -> Unit = _ => (),
  on_unreadable_path? : (String) -> Unit = _ => (),
) -> Unit raise {
  let entries = match self.listing_checked(dir) {
    Ok(Some(es)) => es
    Ok(None) => return
    Err(_) => {
      on_error(dir)
      return
    }
  }
  for e in entries {
    let (name, kind) = e
    let path = self.files.join([dir, name])
    if kind == "dir" {
      self.walk_transcript_dir(path, add, on_error~, on_unreadable_path~)
    } else if kind == "file" {
      add(path)
    } else if kind == "other" {
      match self.lstat_checked(path) {
        Ok(Some(("file", _, _, _))) => add(path)
        Ok(Some(("dir", _, _, _))) => self.walk_transcript_dir(path, add, on_error~, on_unreadable_path~)
        Ok(_) => ()
        Err(_) => {
          on_unreadable_path(path)
          on_error(path)
        }
      }
    }
  }
}

///|
/// Dedicated walker for AGY `brain/<id>/` that prunes the three derived cache subtrees by exact relative path segments
/// before descending (never enters or reads pruned directories).
/// `dir` is a transcript path (`Files::is_transcript_path`), so is each path under it made of a name of its own: `add`
/// is given those without asking again. `rel_parts` is `dir`'s place under the brain, given back as it came.
fn Exporter::walk_brain_dir(
  self : Exporter,
  dir : String,
  rel_parts : Array[String],
  add : (String) -> Unit,
  on_error : (String) -> Unit,
  on_unreadable_path : (String) -> Unit,
) -> Unit raise {
  let entries = match self.listing_checked(dir) {
    Ok(Some(es)) => es
    Ok(None) => return
    Err(_) => {
      on_error(dir)
      return
    }
  }
  fn descend(path : String, name : String) -> Unit raise {
    rel_parts.push(name)
    defer ignore(rel_parts.pop())
    if !is_pruned_brain_rel(rel_parts) {
      self.walk_brain_dir(path, rel_parts, add, on_error, on_unreadable_path)
    }
  }
  for e in entries {
    let (name, kind) = e
    if name == "" || name == "." || name == ".." || name.contains(self.files.sep) {
      continue
    }
    let path = self.files.join([dir, name])
    if kind == "dir" {
      descend(path, name)
    } else if kind == "file" {
      add(path)
    } else if kind == "other" {
      match self.lstat_checked(path) {
        Ok(Some(("file", _, _, _))) => add(path)
        Ok(Some(("dir", _, _, _))) => descend(path, name)
        Ok(_) => ()
        Err(_) => {
          on_unreadable_path(path)
          on_error(path)
        }
      }
    }
  }
}

///|
/// Discovers all session transcripts for active workspaces, chunks changed files into 4 MiB zstd CAS blobs under
/// `<replica>/chunks/<chunk_hash>`, emits `tr` and `tr_del` records, and updates `transcript_files` / `transcript_chunks`.
async fn Exporter::export_transcripts(
  self : Exporter,
  outs : Map[String, Out],
  sess_rows : Array[JValue],
  run_rows : Map[String, Array[JValue]],
  ws_of_session : (JValue?) -> String,
  say : (String, JValue) -> Unit,
) -> Bool {
  let finder_readdir_err : Set[String] = Set([])
  if self.test_faults is Some(f) {
    for d in f.readdir_err {
      finder_readdir_err.add(d)
    }
    for d in f.finder_readdir_err {
      finder_readdir_err.add(d)
    }
  }
  // One finder for the pass, keeping what each directory holds: each session's look through every Claude project or
  // Codex day reads them once in the pass, not once a session.
  let finder = @locate.Finder::new(
    self.host,
    self.files.sep,
    track_failed_dirs=true,
    readdir_err=finder_readdir_err,
    cache_dirs=true,
  )
  let by_ws : Map[String, Map[String, String?]] = Map([])
  let unreadable_dirs_by_ws : Map[String, Set[String]] = Map([])
  let unreadable_paths_by_ws : Map[String, Set[String]] = Map([])
  for ws, _ in outs {
    by_ws[ws] = Map([])
    unreadable_dirs_by_ws[ws] = Set([])
    unreadable_paths_by_ws[ws] = Set([])
  }
  // The brains walked in each workspace: sessions of one workspace sharing a brain walk it once.
  let walked_brains : Map[String, Set[String]] = Map([])
  for sess in sess_rows {
    let ws = ws_of_session(get(sess, "ws"))
    guard by_ws.get(ws) is Some(found_map) else { continue }
    // A workspace whose transcripts are all exported this sweep is not looked at again until the next one.
    if self.transcript_ws_done.contains(ws) {
      continue
    }
    let unreadable_dirs = unreadable_dirs_by_ws.get(ws).unwrap_or(Set([]))
    let unreadable_paths_ws = unreadable_paths_by_ws.get(ws).unwrap_or(Set([]))
    let add_unreadable_dir = (d : String) => unreadable_dirs.add(d)
    let add_unreadable_path = (p : String) => unreadable_paths_ws.add(p)
    let key = text_of(get(sess, "key")).unwrap_or("")
    let s_runtime = text_of(get(sess, "runtime")).unwrap_or("")
    let orig_runtime = text_of(get(sess, "original_runtime")).unwrap_or(s_runtime)
    let s_profile = text_of(get(sess, "profile"))
    let s_workspace = text_of(get(sess, "workspace")).unwrap_or("")
    let s_cwd = text_of(get(sess, "cwd"))
    let room : String? = match s_cwd {
      Some(c) if c != "" => Some(c)
      _ => if s_workspace != "" { Some(s_workspace) } else { None }
    }
    let places : Array[String] = []
    if s_cwd is Some(c) && c != "" && c != s_workspace {
      places.push(c)
    }
    if s_workspace != "" {
      places.push(s_workspace)
    }
    let sources : Array[@locate.Source] = []
    let seen_ids : Set[String] = Set([])
    for r in run_rows.get(key).unwrap_or([]) {
      let id = text_of(get(r, "id")).unwrap_or("")
      if id == "" {
        continue
      }
      let rt = text_of(get(r, "runtime")).unwrap_or(orig_runtime)
      let prof = match text_of(get(r, "profile")) {
        Some(p) => Some(p)
        None => s_profile
      }
      sources.push({ id, runtime: rt, profile: prof })
      seen_ids.add(id)
    }
    if text_of(get(sess, "runtime_session_id")) is Some(cid) && cid != "" && !seen_ids.contains(cid) {
      sources.push({ id: cid, runtime: s_runtime, profile: s_profile })
    }
    if sources.length() == 0 {
      continue
    }
    let add_path = (p : String) => {
      if self.files.is_transcript_path(self.data_dir, p) && !found_map.contains(p) {
        found_map[p] = room
      }
    }
    let valid_sources = sources.filter(r => @locate.runtime_kind(r.runtime))
    if valid_sources.length() > 0 {
      let (located, _) = finder.sources(self.data_dir, [], valid_sources, places, anywhere=true)
      for d in finder.take_failed_dirs() {
        if !self.files.is_dir_missing(d) {
          add_unreadable_dir(d)
        }
      }
      for t in located {
        let (path, kind) = t
        let actual = if self.files.exists(path) { path } else { path + ".zst" }
        add_path(actual)
        if kind == "claude" {
          let name = path.view(start_offset=path.rev_find(self.files.sep).unwrap_or(-1) + 1).to_string()
          let id = if name.has_suffix(".jsonl") { name.view(end_offset=name.length() - 6).to_string() } else { name }
          let sub = self.files.join([self.files.dir_of(path), id])
          match self.lstat_checked(sub) {
            Ok(Some(("dir", _, _, _))) => self.walk_transcript_dir(sub, add_path, on_error=add_unreadable_dir, on_unreadable_path=add_unreadable_path)
            Ok(_) => ()
            Err(_) => add_unreadable_dir(sub)
          }
        }
      }
    }
    // AGY cli_kept: homes/<profile>/agy/.gemini/antigravity-cli/{conversations,annotations,brain}
    for r in sources {
      guard r.runtime == "agy" && r.profile is Some(profile) && one_segment(profile) && one_segment(r.id) else { continue }
      let cli = self.files.join([self.data_dir, "homes", profile, "agy", ".gemini", "antigravity-cli"])
      add_path(self.files.join([cli, "conversations", r.id + ".db"]))
      add_path(self.files.join([cli, "conversations", r.id + ".db-wal"]))
      add_path(self.files.join([cli, "annotations", r.id + ".pbtxt"]))
      let brain = self.files.join([cli, "brain", r.id])
      let walked = match walked_brains.get(ws) {
        Some(w) => w
        None => {
          let w : Set[String] = Set([])
          walked_brains[ws] = w
          w
        }
      }
      if walked.contains(brain) {
        continue
      }
      walked.add(brain)
      let add_found = (p : String) => if !found_map.contains(p) { found_map[p] = room }
      match self.lstat_checked(brain) {
        Ok(Some(("dir", _, _, _))) =>
          if self.files.is_transcript_path(self.data_dir, brain) {
            self.walk_brain_dir(brain, [], add_found, add_unreadable_dir, add_unreadable_path)
          }
        Ok(_) => ()
        Err(_) => add_unreadable_dir(brain)
      }
    }
  }
  if self.test_faults is Some({ finder_asked_most: Some(most), .. }) && finder.asked() > most {
    fail("BUG: the transcript finder asked the shell \{finder.asked()} times in a pass, more than \{most}")
  }
  let mut done_files = 0
  let mut done_bytes = 0
  let mut done_deletes = 0
  let mut truncated = false
  let parent_unreadable_cache : Map[String, Bool] = Map([])
  let ancestor_lstat_cache : Map[String, String] = Map([])
  let ws_order : Array[String] = by_ws.keys().collect()
  ws_order.sort_by(compare_units)
  for ws in ws_order {
    if truncated {
      break
    }
    if self.transcript_ws_done.contains(ws) {
      continue
    }
    let found_map = by_ws.get(ws).unwrap_or(Map([]))
    let unreadable_dirs = unreadable_dirs_by_ws.get(ws).unwrap_or(Set([]))
    let unreadable_paths = unreadable_paths_by_ws.get(ws).unwrap_or(Set([]))
    let paths = found_map.keys().collect()
    paths.sort_by(compare_units)
    // What `transcript_files` holds for the workspace, read once rather than a query a path.
    let existing_by_path : Map[String, (String?, Double, Double)] = Map([])
    for row in self.state.all("SELECT path, room, size, mtime FROM transcript_files WHERE ws = ?", [s(ws)]) {
      let prev_room = match row.get("room") {
        Some(String(r)) => Some(r)
        _ => None
      }
      existing_by_path[field_text(row, "path")] = (prev_room, field_num(row, "size"), field_num(row, "mtime"))
    }
    let active : Set[String] = Set([])
    let mut ws_truncated = false
    let scan_done = self.transcript_scan_done.contains(ws)
    let cursor = self.transcript_cursor.get(ws)
    for path in paths {
      // A path is found whether or not it is there (a `.db-wal`, an annotation): one gone is not kept.
      let (kind, size, mode, mtime) = match self.lstat_checked(path) {
        Ok(Some(st)) => st
        Ok(None) => continue
        Err(_) => {
          unreadable_paths.add(path)
          continue
        }
      }
      if kind != "file" {
        continue
      }
      // Gone through already in this sweep: kept as found, not read again until the next sweep.
      if scan_done || (cursor is Some(c) && compare_units(path, c) < 0) {
        active.add(path)
        continue
      }
      let room = found_map.get(path).unwrap_or(None)
      let m = mode & 0o777
      let mtime_ms = @math.floor(mtime)
      let unchanged = match existing_by_path.get(path) {
        Some((prev_room, prev_size, prev_mtime)) => prev_size == size && prev_mtime == mtime_ms && prev_room == room
        None => false
      }
      if unchanged {
        active.add(path)
        continue
      }
      if done_files > 0 && (done_files >= self.transcript_pass_files || done_bytes >= self.transcript_pass_bytes) {
        truncated = true
        ws_truncated = true
        self.transcript_cursor[ws] = path
        break
      }
      let chunks : Array[String] = []
      let total = size.to_int()
      let mut offset = 0
      let mut read_failed = false
      while offset < total {
        let want = if total - offset < self.chunk_bytes { total - offset } else { self.chunk_bytes }
        let injected_short = match self.test_faults {
          Some(f) => f.read_short.contains(path) || (offset > 0 && f.read_short_after_first.contains(path))
          None => false
        }
        let plain_opt = if injected_short {
          None
        } else {
          self.host.read_bytes(path, from=offset, length=want) catch { _ => None }
        }
        guard plain_opt is Some(plain) && plain.length() > 0 else {
          read_failed = true
          break
        }
        let plain_hash = @hash.sha256_hex(plain[:])
        let chunk_hash = match self.state.all("SELECT chunk_hash FROM transcript_chunks WHERE plain_hash = ?", [s(plain_hash)]) {
          [row, ..] => {
            let ch = field_text(row, "chunk_hash")
            if self.files.kind(self.files.join([self.replica, "chunks", ch])) is Some("file") {
              Some(ch)
            } else {
              None
            }
          }
          _ => None
        }
        let ch = match chunk_hash {
          Some(c) => c
          None => {
            let (_, zst_opt) = self.host.shell("zstd.compress", { "level": Json::number(3.0), "window": Json::number(20.0) }, bytes=plain)
            guard zst_opt is Some(zst) else { fail("zstd.compress returned no bytes") }
            let h = @hash.sha256_hex(zst[:])
            let comp_size = zst.length().to_double()
            let chunk_path = self.files.join([self.replica, "chunks", h])
            if !(self.files.kind(chunk_path) is Some("file")) {
              self.host.write_atomic(chunk_path, zst, mode=0o644, sync=false, mkdir=true, sep=self.files.sep)
            }
            ignore(
              self.state.run("INSERT OR REPLACE INTO transcript_chunks (plain_hash, chunk_hash, comp_size) VALUES (?, ?, ?)", [
                s(plain_hash),
                s(h),
                Json::number(comp_size),
              ]),
            )
            h
          }
        }
        chunks.push(ch)
        offset += plain.length()
      }
      if read_failed || offset != total {
        unreadable_paths.add(path)
        continue
      }
      active.add(path)
      let chunks_json = stringify(strs(chunks))
      let room_param = match room {
        Some(r) => s(r)
        None => Json::null()
      }
      ignore(
        self.state.run("INSERT OR REPLACE INTO transcript_files (ws, path, room, size, mtime, mode, chunks_json) VALUES (?, ?, ?, ?, ?, ?, ?)", [
          s(ws),
          s(path),
          room_param,
          Json::number(size),
          Json::number(mtime_ms),
          ni(m),
          s(chunks_json),
        ]),
      )
      self.tf_cache.remove(ws)
      self.manifest_cache.remove(ws)
      say(
        ws,
        Obj([
          ("tr", str(path)),
          ("room", match room { Some(r) => str(r); None => Null }),
          ("size", Num(size)),
          ("mtime", Num(mtime_ms)),
          ("mode", Num(m.to_double())),
          ("chunks", strs(chunks)),
        ]),
      )
      done_files += 1
      done_bytes += offset
    }
    let old_paths : Array[String] = existing_by_path.keys().collect()
    old_paths.sort_by(compare_units)
    if ws_truncated {
      // The derived caches no longer exported go whatever else is found: by their path alone, so a sweep that keeps
      // being cut short still lets them go. That path says it, not the disk: no readability check is needed.
      let mut deleted_in_ws = false
      for old_path in old_paths {
        if active.contains(old_path) || !self.files.is_pruned_brain_path(self.data_dir, old_path) {
          continue
        }
        if done_deletes >= self.transcript_pass_deletes {
          break
        }
        ignore(self.state.run("DELETE FROM transcript_files WHERE ws = ? AND path = ?", [s(ws), s(old_path)]))
        deleted_in_ws = true
        say(ws, Obj([("tr_del", str(old_path))]))
        done_deletes += 1
      }
      if deleted_in_ws {
        self.tf_cache.remove(ws)
        self.manifest_cache.remove(ws)
      }
    } else {
      self.transcript_cursor.remove(ws)
      self.transcript_scan_done.add(ws)
      let mut deleted_in_ws = false
      let mut deletes_cut = false
      for old_path in old_paths {
        if active.contains(old_path) || unreadable_paths.contains(old_path) || path_under_any_dir(old_path, unreadable_dirs, self.files.sep) {
          continue
        }
        if !self.files.is_pruned_brain_path(self.data_dir, old_path) {
          match self.files.under_of(self.data_dir, old_path) {
            Some(rel) if rel != "" => {
              let parts : Array[String] = rel.split(self.files.sep).map(x => x.to_string()).collect()
              let ancestors : Array[String] = []
              let mut cur = self.data_dir
              let mut keep = false
              let mut all_real_dirs = true
              for i = 0; i + 1 < parts.length(); i = i + 1 {
                cur = self.files.join([cur, parts[i]])
                let kind = match ancestor_lstat_cache.get(cur) {
                  Some(k) => k
                  None => {
                    let k = match self.lstat_checked(cur) {
                      Err(_) => "err"
                      Ok(Some(("dir", _, _, _))) => "dir"
                      Ok(_) => "other"
                    }
                    ancestor_lstat_cache[cur] = k
                    k
                  }
                }
                if kind == "err" {
                  keep = true
                  break
                } else if kind != "dir" {
                  all_real_dirs = false
                  break
                }
                ancestors.push(cur)
              }
              if keep {
                continue
              }
              if all_real_dirs {
                match self.lstat_checked(old_path) {
                  Err(_) => continue
                  Ok(None) => ()
                  Ok(Some(_)) => {
                    let mut ancestor_unreadable = false
                    let check_dir = (d : String) => {
                      match parent_unreadable_cache.get(d) {
                        Some(b) => b
                        None => {
                          let bad = self.dir_unreadable_checked(d)
                          parent_unreadable_cache[d] = bad
                          bad
                        }
                      }
                    }
                    if check_dir(self.data_dir) {
                      ancestor_unreadable = true
                    } else {
                      for a in ancestors {
                        if check_dir(a) {
                          ancestor_unreadable = true
                          break
                        }
                      }
                    }
                    if ancestor_unreadable {
                      continue
                    }
                  }
                }
              }
            }
            _ => ()
          }
        }
        if done_deletes >= self.transcript_pass_deletes {
          truncated = true
          deletes_cut = true
          break
        }
        ignore(self.state.run("DELETE FROM transcript_files WHERE ws = ? AND path = ?", [s(ws), s(old_path)]))
        deleted_in_ws = true
        say(ws, Obj([("tr_del", str(old_path))]))
        done_deletes += 1
      }
      if deleted_in_ws {
        self.tf_cache.remove(ws)
        self.manifest_cache.remove(ws)
      }
      if !deletes_cut {
        self.transcript_ws_done.add(ws)
      }
    }
  }
  if !truncated {
    self.end_sweep()
  }
  truncated
}

///|
fn Exporter::transcript_files_map(self : Exporter, ws : String) -> Array[(String, JValue)] raise {
  let rows = self.state.all("SELECT chunks_json FROM transcript_files WHERE ws = ?", [s(ws)])
  if rows.length() == 0 {
    return []
  }
  let chunk_sizes : Map[String, Double] = Map([])
  for r in self.state.all("SELECT chunk_hash, comp_size FROM transcript_chunks", []) {
    let ch = field_text(r, "chunk_hash")
    if !chunk_sizes.contains(ch) {
      chunk_sizes[ch] = field_num(r, "comp_size")
    }
  }
  let sizes : Map[String, Double] = Map([])
  for row in rows {
    let parsed = @jsjson.parse(field_text(row, "chunks_json")) catch { _ => Arr([]) }
    for ch in strings_of(Some(parsed)) {
      if sizes.contains(ch) {
        continue
      }
      let sz = match chunk_sizes.get(ch) {
        Some(s) => s
        None =>
          match self.files.meta(self.files.join([self.replica, "chunks", ch])) {
            Some((size, _)) => size
            None => 0.0
          }
      }
      sizes[ch] = sz
    }
  }
  let keys = sizes.keys().collect()
  keys.sort_by(compare_units)
  keys.map(k => (k, Num(sizes.get(k).unwrap_or(0.0))))
}

///|
fn Exporter::gc_transcript_chunks(self : Exporter) -> Unit raise {
  let now = (self.now)()
  let chunks_dir = self.files.join([self.replica, "chunks"])
  let live : Set[String] = Set([])
  for row in self.state.all("SELECT chunks_json FROM transcript_files", []) {
    let parsed = @jsjson.parse(field_text(row, "chunks_json")) catch { _ => Arr([]) }
    for ch in strings_of(Some(parsed)) {
      live.add(ch)
    }
  }
  let pending : Map[String, Double] = Map([])
  for row in self.state.all("SELECT chunk_hash, gone_at FROM transcript_chunk_gc", []) {
    pending[field_text(row, "chunk_hash")] = field_num(row, "gone_at")
  }
  for ch in pending.keys().collect() {
    if live.contains(ch) {
      ignore(self.state.run("DELETE FROM transcript_chunk_gc WHERE chunk_hash = ?", [s(ch)]))
    }
  }
  let kept_on_disk : Set[String] = Set([])
  match self.files.names(chunks_dir) {
    Some(names) =>
      for name in names {
        if live.contains(name) {
          continue
        }
        if self.chunk_gc_grace_ms <= 0.0 {
          self.files.remove(self.files.join([chunks_dir, name])) catch {
            _ => ()
          }
          if pending.contains(name) {
            ignore(self.state.run("DELETE FROM transcript_chunk_gc WHERE chunk_hash = ?", [s(name)]))
          }
          continue
        }
        match pending.get(name) {
          None => {
            ignore(
              self.state.run(
                "INSERT OR REPLACE INTO transcript_chunk_gc (chunk_hash, gone_at) VALUES (?, ?)",
                [s(name), Json::number(now)],
              ),
            )
            kept_on_disk.add(name)
          }
          Some(gone_at) =>
            if now - gone_at >= self.chunk_gc_grace_ms {
              self.files.remove(self.files.join([chunks_dir, name])) catch {
                _ => ()
              }
              ignore(self.state.run("DELETE FROM transcript_chunk_gc WHERE chunk_hash = ?", [s(name)]))
            } else {
              kept_on_disk.add(name)
            }
        }
      }
    None => ()
  }
  for ch in pending.keys().collect() {
    if !live.contains(ch) && !kept_on_disk.contains(ch) {
      ignore(self.state.run("DELETE FROM transcript_chunk_gc WHERE chunk_hash = ?", [s(ch)]))
    }
  }
  for row in self.state.all("SELECT plain_hash, chunk_hash FROM transcript_chunks", []) {
    let ch = field_text(row, "chunk_hash")
    if !live.contains(ch) && !kept_on_disk.contains(ch) {
      ignore(self.state.run("DELETE FROM transcript_chunks WHERE plain_hash = ?", [s(field_text(row, "plain_hash"))]))
    }
  }
}

///|
/// Writes the canonical 2-level transcript manifest for `head` under `<replica>/manifests/<hash>` (atomic tmp + fsync
/// + rename, skipping existing files) and returns the compact IPC head carrying `transcriptManifest` instead of inline
/// `transcriptFiles`. Disk `own/<ws>/<gen>/head.json` keeps inline `transcriptFiles` unchanged (D72a invariant).
async fn Exporter::compact_head(self : Exporter, ws : String, head : JValue) -> JValue {
  match get(head, "transcriptFiles") {
    Some(Obj(entries)) if entries.length() > 0 => {
      let manifests_dir = self.files.join([self.replica, "manifests"])
      let root_hash = match self.manifest_cache.get(ws) {
        Some((rh, _)) if self.files.kind(self.files.join([manifests_dir, rh])) is Some("file") => rh
        _ => {
          let pairs : Array[(String, Double)] = entries.map(e => (@jsjson.sanitize_str(e.0), num(Some(e.1))))
          let enc = encode_transcript_manifest(pairs)
          let leaf_hashes : Array[String] = []
          for leaf in enc.leaves {
            let (_, lh, lbytes) = leaf
            leaf_hashes.push(lh)
            let lp = self.files.join([manifests_dir, lh])
            if !(self.files.kind(lp) is Some("file")) {
              self.host.write_atomic(lp, lbytes, mode=0o644, sync=true, mkdir=true, sep=self.files.sep)
            }
          }
          let rp = self.files.join([manifests_dir, enc.root_hash])
          if !(self.files.kind(rp) is Some("file")) {
            self.host.write_atomic(rp, enc.root_bytes, mode=0o644, sync=true, mkdir=true, sep=self.files.sep)
          }
          self.manifest_cache[ws] = (enc.root_hash, leaf_hashes)
          enc.root_hash
        }
      }
      set(without(head, "transcriptFiles"), "transcriptManifest", str(root_hash))
    }
    _ => {
      self.manifest_cache.remove(ws)
      without(head, "transcriptManifest")
    }
  }
}

///|
/// Reclaims unreferenced manifest files under `<replica>/manifests/` after a 10-minute grace period
/// measured from when a manifest hash leaves the live set (falling back to mtime for cross-process leftovers),
/// always preserving root + leaf hashes referenced by current `own` heads.
fn Exporter::gc_manifests(self : Exporter, outs : Map[String, Out]) -> Unit raise {
  let now = (self.now)()
  let manifests_dir = self.files.join([self.replica, "manifests"])
  let live : Set[String] = Set([])
  for ws, out in outs {
    match self.manifest_cache.get(ws) {
      Some((rh, leaves)) => {
        live.add(rh)
        for lh in leaves {
          live.add(lh)
        }
      }
      None =>
        match get(out.head, "transcriptFiles") {
          Some(Obj(entries)) if entries.length() > 0 => {
            let pairs : Array[(String, Double)] = entries.map(e => (@jsjson.sanitize_str(e.0), num(Some(e.1))))
            let enc = encode_transcript_manifest(pairs)
            live.add(enc.root_hash)
            for leaf in enc.leaves {
              live.add(leaf.1)
            }
          }
          _ => ()
        }
    }
  }
  for h in live {
    self.manifest_superseded_at.remove(h)
  }
  for prev in self.manifest_live {
    if !live.contains(prev) && !self.manifest_superseded_at.contains(prev) {
      self.manifest_superseded_at[prev] = now
    }
  }
  self.manifest_live = live
  let on_disk : Set[String] = Set([])
  guard self.files.names(manifests_dir) is Some(names) else { return }
  for name in names {
    on_disk.add(name)
    if live.contains(name) {
      continue
    }
    match self.manifest_superseded_at.get(name) {
      Some(superseded_at) =>
        if now - superseded_at >= manifest_gc_grace_ms {
          let p = self.files.join([manifests_dir, name])
          self.files.remove(p) catch {
            _ => ()
          }
          self.manifest_superseded_at.remove(name)
        }
      None =>
        // First time this process observes an unreferenced file on disk (e.g. after restart):
        // record `now` and grant a full 10-minute grace period before reclaiming.
        self.manifest_superseded_at[name] = now
    }
  }
  let stale_keys : Array[String] = []
  for k, _ in self.manifest_superseded_at {
    if !on_disk.contains(k) {
      stale_keys.push(k)
    }
  }
  for k in stale_keys {
    self.manifest_superseded_at.remove(k)
  }
}
