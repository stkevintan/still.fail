// The target's side of the remote tasks (remote.ts `task` and what it stands on): a source session's tasks here, their
// shared directory and its mirrors, and their cleanup (`sweep`, `relieve`; the upkeep's `expire` and `budget`).

///|
fn refusal(m : String) -> Error {
  Asked({ "message": jstr(m) })
}

///|
///|
/// Effective room/incoming peer key from a task's metadata: `<station>:sandbox:<sandbox>` for cross-station sandbox
/// tasks, otherwise `<station>`. `meta.station` itself stays the real source station id for `push_out` and `revoke`.
fn meta_room_peer(meta : Json) -> String {
  let st = text_of(meta, "station")
  let sb = text_of(meta, "sandbox")
  if sb != "" { "\{st}:sandbox:\{sb}" } else { st }
}

///|
async fn Actors::task(
  self : Actors,
  workspace : String,
  peer : String,
  method : String,
  request : Json,
  load : @effect.Deferred[Json]?,
) -> Json raise {
  let sandbox_arg = text_of(request, "sandbox")
  let room_peer = if sandbox_arg != "" { "\{peer}:sandbox:\{sandbox_arg}" } else { peer }
  if method == "task.gets" {
    // What `task.get` says of each, in one request (a source follows all its tasks here at once).
    let asked = match field_of(request, "tasks") {
      Array(a) if a.length() <= gets_max => a
      _ => raise refusal("tasks are required (at most \{gets_max})")
    }
    let reading : @effect.Deferred[Json] = @effect.Deferred::new()
    let mut read = false
    let tasks : Array[Json] = []
    for one in asked {
      let (session, key) = (field_of(one, "session"), field_of(one, "key"))
      if !read {
        read = true
        self.spawn(() => {
          let l = self.rnode("load", []) catch { e => ({ "unavailable": jstr(FsError::of(e)) } : Json) }
          ignore(reading.succeed(l))
        })
      }
      let sub_req : Json = if sandbox_arg != "" {
        { "session": session, "key": key, "sandbox": jstr(sandbox_arg) }
      } else {
        { "session": session, "key": key }
      }
      let got : Json = try {
        { "session": session, "key": key, "result": self.task(workspace, peer, "task.get", sub_req, Some(reading)) }
      } catch {
        e => ({ "session": session, "key": key, "error": jstr(FsError::of(e)) } : Json)
      }
      tasks.push(got)
    }
    return { "tasks": Json::array(tasks) }
  }
  let session = text_of(request, "session")
  let session_needed = () => if session == "" || bytes_len(session) > 256 { raise refusal("session is required") }
  if method == "session.size" {
    session_needed()
    let room = self.room(workspace, room_peer, session)
    self.written(self.rjoin([room, "session.json"]))
    // (and what Node wrote of it: a room used by work() there)
    ignore(self.rnode("written", [jstr(self.rjoin([room, "session.json"]))]))
    if !self.there(self.rjoin([room, "session.json"])) {
      return { "present": jbool(false) }
    }
    let path = self.rjoin([room, "work"])
    let cutoff = match field_of(request, "limit") {
      Null => Json::null()
      Number(n, ..) if n >= 1.0 && n == n.floor() => jnum(n)
      _ => raise refusal("limit must be a positive whole number of bytes")
    }
    return self.rnode("workspaceSize", [jstr(path), cutoff])
  }
  if method == "task.mirrors" || method == "task.clean" {
    session_needed()
    let room = self.room(workspace, room_peer, session)
    self.written(self.rjoin([room, "session.json"]))
    // (and what Node wrote of it: a room used by work() there)
    ignore(self.rnode("written", [jstr(self.rjoin([room, "session.json"]))]))
    let mirrors = if self.there(self.rjoin([room, "session.json"])) { self.mirrors_of(workspace, room_peer, session, self.remote_now()) } else { [] }
    // Unlike the automatic sweep's age-based recovery, an explicit cleanup must not interrupt even a slow sync.
    let syncing_now : Map[String, Bool] = {}
    for m in mirrors {
      if self.there(self.rjoin([room, "sync", m.name])) {
        syncing_now[m.name] = true
      }
    }
    let in_use = (m : MirrorUse) => m.busy || syncing_now.contains(m.name)
    if method == "task.mirrors" {
      return {
        "mirrors": Json::array(
          mirrors.map(m => ({ "name": jstr(m.name), "path": jstr(self.rjoin([room, "work", m.name])), "busy": jbool(in_use(m)), "lastUsed": jnum(m.used) } : Json)),
        ),
      }
    }
    let name = text_of(request, "mirror")
    if name == "" {
      raise refusal("mirror is required")
    }
    // The name must be one the station itself listed for this peer's session, never a supplied path.
    guard mirrors.search_by(m => m.name == name) is Some(i) else { return { "mirror": jstr(name), "removed": jbool(false) } }
    if in_use(mirrors[i]) {
      raise refusal("mirror is in use by a task or sync")
    }
    if !self.drop_mirror(workspace, room_peer, session, name, "requested") {
      raise refusal("mirror could not be removed completely")
    }
    return { "mirror": jstr(name), "removed": jbool(true) }
  }
  if method == "task.list" {
    session_needed()
    let listed : Array[(Int, Double, String, Json)] = []
    for t in self.tasks_of(workspace, room_peer, session) {
      let job = self.rstore("getJob", [jstr(self.job_of_task(t.dir))])
      let shown = if job is Null { Json::null() } else { self.rnode("jobJson", [job]) }
      listed.push((list_rank(shown), list_time(shown), text_of(t.meta, "key"), { "key": field_of(t.meta, "key"), "spec": field_of(t.meta, "spec"), "job": shown }))
    }
    return list_bounded(listed)
  }
  if method == "session.close" {
    session_needed()
    ignore(self.close_here(workspace, room_peer, session, None))
    return { "closed": jbool(true) }
  }
  let key = text_of(request, "key")
  if session == "" || bytes_len(session) > 256 || key == "" || bytes_len(key) > 128 {
    raise refusal("session and task key are required (at most 256 / 128 bytes)")
  }
  let id = rhash(Json::array([jstr(workspace), jstr(room_peer), jstr(session), jstr(key)]))
  let dir = self.rjoin([self.remote.root, "incoming", id])
  let record = self.rjoin([dir, "task.json"])
  let job_id = "remote_\{id}"
  let owner = "remote:\{workspace}:\{room_peer}:\{session}"
  if method == "task.prepare" {
    let spec = field_of(request, "spec")
    if text_of(spec, "command").trim_space().to_string() == "" {
      raise refusal("command is required")
    }
    match field_of(spec, "small") {
      Null | True | False => ()
      _ => raise refusal("small must be a boolean")
    }
    if field_of(spec, "small") is True && field_of(spec, "screen") is True {
      raise refusal("a small task cannot use the screen")
    }
    let from = field_of(spec, "dir")
    match from {
      Null => ()
      String(f) if f != "" && bytes_len(f) <= 4096 => ()
      _ => raise refusal("dir must be a path")
    }
    let meta = if self.there(record) {
      let meta = self.read_json(record)
      if js_text(field_of(meta, "spec")) != js_text(spec) && !json_equal(field_of(meta, "spec"), spec) {
        raise refusal("task key already used with different inputs; choose a new key for new work")
      }
      meta
    } else {
      let m : Map[String, Json] = { "spec": spec, "workspace": jstr(workspace), "station": jstr(peer), "session": jstr(session), "key": jstr(key), "layout": jstr("session") }
      if sandbox_arg != "" {
        m["sandbox"] = jstr(sandbox_arg)
      }
      if from is String(f) {
        m["mirror"] = jstr(self.mirror_name(workspace, room_peer, session, f))
      }
      self.mkdirs(dir)
      self.write_json(record, Json::object(m))
      Json::object(m)
    }
    ignore(self.seen(workspace, room_peer, session))
    return match field_of(meta, "mirror") {
      String(mirror) => { "key": jstr(key), "prepared": jbool(true), "dir": jstr(mirror) }
      _ => { "key": jstr(key), "prepared": jbool(true) }
    }
  }
  let meta = self.read_json(record) catch { _ => raise refusal("unknown task") }
  let job = self.rstore("getJob", [jstr(job_id)])
  // Tasks prepared before shared session directories keep their own.
  let work = if text_of(meta, "layout") == "session" {
    if method == "task.start" || method == "file.put" || method == "sync.begin" {
      self.seen(workspace, room_peer, session)
    } else {
      self.rjoin([self.room(workspace, room_peer, session), "work"])
    }
  } else {
    self.rjoin([dir, "work"])
  }
  // A task with a directory runs in its mirror, a directory of the session's.
  let mirror = match field_of(meta, "mirror") {
    String(m) => Some(m)
    _ => None
  }
  let room = self.room(workspace, room_peer, session)
  let manifest_path = match mirror { Some(m) => self.rjoin([room, "mirrors", "\{m}.json"]); None => "" }
  let syncing = match mirror { Some(m) => self.rjoin([room, "sync", m]); None => "" }
  if method.has_prefix("sync.") && mirror is None {
    raise refusal("this task has no directory to sync")
  }
  let refuse_busy = async fn() raise {
    let tasks = self.tasks_of(workspace, room_peer, session).filter(t => t.dir != dir && field_of(t.meta, "mirror") == (match mirror { Some(m) => jstr(m); None => Json::null() }))
    for t in tasks {
      if self.task_running(t.dir) {
        raise refusal("task \{text_of(t.meta, "key")} is running in \{mirror.unwrap_or("")} on this station; wait for it or stop it")
      }
    }
    for t in tasks {
      if field_of(t.meta, "safe") is True && !(field_of(t.meta, "collected") is True) && !(self.rstore("getJob", [jstr(self.job_of_task(t.dir))]) is Null) {
        raise refusal("task \{text_of(t.meta, "key")} is still bringing back its results from \{mirror.unwrap_or("")}; wait for its completion notice")
      }
    }
  }
  let ongoing = async fn() -> Json raise {
    let state = self.read_json(self.rjoin([syncing, "state.json"])) catch { _ => Json::null() }
    if state is Null || text_of(state, "id") != text_of(request, "id") || text_of(state, "key") != key {
      raise refusal("this sync is over or another one began; start again")
    }
    state
  }
  let m = mirror.unwrap_or("")
  match method {
    "task.start" => {
      match field_of(meta, "uploads") {
        Object(u) if u.values().any(v => !(v is True)) => raise refusal("input upload is incomplete; finish it before starting")
        _ => ()
      }
      let mut cwd = work
      if mirror is Some(_) && job is Null {
        if !(field_of(meta, "synced") is True) {
          raise refusal("this task's directory has not been synced; start it from a station that syncs directories")
        }
        refuse_busy()
      }
      if mirror is Some(_) {
        cwd = self.file_path(work, m, false)
        self.used_mirror(workspace, room_peer, session, m)
      }
      let spec = field_of(meta, "spec")
      // Through the station's queue (admit): started now if there is room, else when there is. A sandbox's (local or
      // remote Colab): run there, nothing of this machine's taken, so not queued here.
      let sandbox_target = if sandbox_arg != "" {
        sandbox_arg
      } else if peer.has_prefix("sandbox:") {
        peer.view(start_offset=8).to_string()
      } else {
        ""
      }
      let in_sandbox = sandbox_target != ""
      if in_sandbox && field_of(spec, "screen") is True {
        raise refusal("a sandbox has no screen: run what needs one on a station")
      }
      if in_sandbox {
        ignore(self.rnode("ensureIdentity", [jstr(sandbox_target), jstr(workspace)]))
      }
      let back = match field_of(spec, "back") {
        Array(b) => Json::array(b.filter(x => x is String(_)))
        _ => Json::array([])
      }
      // In a mirror with submodules, their checkout first (dirsync.mbt `with_submodules`).
      let command = match (mirror, field_of(spec, "command")) {
        (Some(_), String(c)) => match self.with_submodules(manifest_path, c) { Some(w) => jstr(w); None => jstr(c) }
        (_, c) => c
      }
      let sbx_session = if sandbox_arg != "" { "\{peer}:\{session}" } else { session }
      let started = if in_sandbox {
        self.locked(() => self.start_id([jstr(owner), field_of(spec, "name"), command, jstr(cwd), Json::null(), jbool(false), jstr(job_id), jbool(false), Json::null(), { "sandbox": jstr(sandbox_target), "session": jstr(sbx_session), "back": back, "workspace": jstr(workspace) }]))
      } else {
        self.locked(() => self.start_id([jstr(owner), field_of(spec, "name"), command, jstr(cwd), Json::null(), jbool(false), jstr(job_id), jbool(false), { "screen": jbool(field_of(spec, "screen") is True), "small": jbool(field_of(spec, "small") is True) }, Json::null()]))
      }
      // Where its source wants to be told of it (`push_out`): from its first start, as it is then.
      let push = text_of(request, "push")
      let meta = if is_hex64(push) && text_of(meta, "push") != push {
        let meta = with_field(with_field(meta, "push", jstr(push)), "pushed", self.said(id))
        self.write_json(record, meta)
        meta
      } else {
        meta
      }
      let queue = self.queued(text_of(started, "id"), load)
      let now = self.rstore("getJob", [jstr(job_id)])
      let out : Map[String, Json] = { "key": jstr(key), "job": self.rnode("jobJson", [if now is Null { started } else { now }]) }
      for k, v in queue {
        out[k] = v
      }
      if !(field_of(meta, "push") is Null) {
        out["push"] = jbool(true)
      }
      Json::object(out)
    }
    "sync.begin" => {
      if !(job is Null) {
        return { "key": jstr(key), "started": jbool(true) }
      }
      refuse_busy()
      self.remove(syncing, recursive=true)
      self.mkdirs(syncing)
      self.mkdirs(self.rjoin([room, "mirrors"]))
      self.used_mirror(workspace, room_peer, session, m)
      // (the manifest, what the mirror has now and the conflict base: dirsync.mbt)
      let version = self.sync_begin(manifest_path, self.rjoin([work, m]), syncing)
      let sid = self.random_hex(12)
      self.write_json(self.rjoin([syncing, "state.json"]), { "id": jstr(sid), "key": jstr(key), "version": jnum(version) })
      if field_of(request, "safe") == jnum(1.0) {
        self.write_json(record, with_field(meta, "safe", jbool(true)))
      }
      { "key": jstr(key), "id": jstr(sid), "dir": jstr(m), "version": jnum(version), "safe": jnum(1.0) }
    }
    "sync.manifest" | "sync.base" => {
      ignore(ongoing())
      let after = as_u64(field_of(request, "after")).unwrap_or(0.0)
      let file = if method == "sync.manifest" { "actual.json" } else { "base.json" }
      self.written(self.rjoin([syncing, file]))
      let files = match self.read_json(self.rjoin([syncing, file])) {
        Object(f) => f
        _ => {}
      }
      page_of(listed_entries(files), after.to_int())
    }
    "sync.put" => {
      ignore(ongoing())
      // The packed pieces after the request (Node landed them in a file: `landed`); from a station from before, base64
      // in it. Unpacked and written here (dirsync.mbt).
      let landed = str_of(Some(field_of(request, "landed")))
      { "pieces": jnum(self.put_blobs(self.rjoin([syncing, "blobs"]), field_of(request, "blobs"), landed, field_of(request, "data")).to_double()) }
    }
    "sync.commit" => {
      let state = ongoing()
      let part = plan_part(request)
      ignore(self.fs("fs.put", { "path": jstr(self.rjoin([syncing, "plan.jsonl"])) }, bytes=@utf8.encode(js_text(part) + "\n")))
      if !(field_of(request, "final") is True) {
        return { "key": jstr(key), "planned": jbool(true) }
      }
      refuse_busy()
      let submodules = submodules_part(request)
      // (the plan checked against what the mirror has and written: dirsync.mbt)
      let done = self.sync_commit(work, m, syncing, manifest_path, field_of(state, "version"), text_of(field_of(meta, "spec"), "dir"), submodules)
      self.write_json(record, with_field(meta, "synced", jbool(true)))
      self.remove(syncing, recursive=true)
      self.used_mirror(workspace, room_peer, session, m)
      let out : Map[String, Json] = { "key": jstr(key) }
      match done {
        Object(d) => for k, v in d { out[k] = v }
        _ => ()
      }
      Json::object(out)
    }
    "sync.changes" => {
      if job is Null || str_of(job.value("state")) == Some("running") {
        raise refusal("the task has not finished")
      }
      let base = self.file_path(work, m, false)
      let found = self.sync_changes(manifest_path, base)
      { "key": jstr(key), "base": jstr(m), "changes": field_of(found, "changes"), "more": field_of(found, "more") }
    }
    "task.collected" => {
      if job is Null || str_of(job.value("state")) == Some("running") {
        raise refusal("the task has not finished")
      }
      self.write_json(record, with_field(meta, "collected", jbool(true)))
      { "key": jstr(key), "collected": jbool(true) }
    }
    "task.files" => {
      if str_of(job.value("state")) == Some("running") {
        raise refusal("wait for the task to finish before downloading artifacts")
      }
      let paths = match field_of(request, "paths") {
        Array(p) if p.length() <= 100 && p.iter().all(x => x is String(_)) => p.map(x => str_of(Some(x)).unwrap_or(""))
        _ => raise refusal("paths are required (at most 100)")
      }
      let cwd = if mirror is None { work } else { self.file_path(work, m, false) }
      let files : Array[Json] = []
      for p in paths {
        self.visit_files(cwd, p, files)
      }
      { "key": jstr(key), "base": jstr(m), "files": Json::array(files) }
    }
    "task.get" | "task.log" => {
      let lines = match as_u64(field_of(request, "lines")) {
        Some(n) => if n < 1.0 { 1.0 } else if n > 1000.0 { 1000.0 } else { n }
        None => 50.0
      }
      let queue = self.queued(job_id, load)
      let current = self.rstore("getJob", [jstr(job_id)])
      let out : Map[String, Json] = {
        "key": jstr(key),
        "job": if current is Null { Json::null() } else { self.rnode("jobJson", [current]) },
        "log": if current is Null { Json::null() } else { self.rnode("tail", [field_of(current, "log"), jnum(lines)]) },
        "notices": self.rstore("jobNotices", [jstr(job_id), jnum(20.0)]),
      }
      for k, v in queue {
        out[k] = v
      }
      if field_of(meta, "push") is String(_) {
        out["push"] = jbool(true)
      }
      Json::object(out)
    }
    "task.stop" => {
      if job is Null {
        raise refusal("task has not started")
      }
      { "key": jstr(key), "job": self.rnode("jobJson", [self.job_stop(text_of(job, "id"))]) }
    }
    "file.put" => {
      if !(job is Null) {
        raise refusal("inputs are immutable after a task starts")
      }
      let name = text_of(request, "path")
      let path = self.file_path(work, name, true)
      let uploads = match field_of(meta, "uploads") {
        Object(u) => u.copy()
        _ => {}
      }
      uploads[name] = jbool(false)
      let meta = with_field(meta, "uploads", Json::object(uploads))
      self.write_json(record, meta)
      // (the bytes Node holds for the request, or a chunk of base64 in it: written there by Node)
      let put = self.rnode("filePut", [jstr(path), request])
      if put.value("whole") is Some(True) {
        uploads[name] = jbool(true)
        self.write_json(record, with_field(meta, "uploads", Json::object(uploads)))
      }
      { "bytes": put.value("bytes").unwrap_or(jnum(0.0)) }
    }
    "file.get" => {
      if str_of(job.value("state")) == Some("running") {
        raise refusal("wait for the task to finish before downloading artifacts")
      }
      let path = self.file_path(work, text_of(request, "path"), false)
      // (read and sent by Node: whole after the answer, or a chunk)
      self.rnode("fileGet", [jstr(path), request])
    }
    _ => raise refusal("unsupported peer method: \{method}")
  }
}

///|
fn is_hex64(s : String) -> Bool {
  s.length() == 64 && s.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
}

///|
/// isDeepStrictEqual of two JSON values (keys in any order).
fn json_equal(a : Json, b : Json) -> Bool {
  match (a, b) {
    (Object(x), Object(y)) => x.length() == y.length() && x.iter().all(e => y.get(e.0) is Some(v) && json_equal(e.1, v))
    (Array(x), Array(y)) => x.length() == y.length() && x.mapi((i, v) => json_equal(v, y[i])).iter().all(b => b)
    _ => a == b
  }
}

///|
/// task.files: what of `rel` there is, files by size, a directory's files in name order (1000 at most).
async fn Actors::visit_files(self : Actors, cwd : String, rel : String, files : Array[Json]) -> Unit raise {
  if files.length() >= 1000 {
    raise refusal("more than 1000 files to bring back")
  }
  let st = try {
    self.lstat(self.file_path(cwd, rel, false))
  } catch {
    _ => None
  }
  match st {
    None => files.push(Json::array([jstr(rel), Json::null()]))
    Some(st) =>
      match kind_of_stat(st) {
        "file" => files.push(Json::array([jstr(rel), st.value("size").unwrap_or(jnum(0.0))]))
        "dir" => {
          let names = self.readdir_names(self.rjoin([cwd, rel]))
          names.sort_by(@search.compare_units) // (as JavaScript sorts them: MoonBit's compare puts the shorter first)
          let base = trim_slashes(rel)
          for name in names {
            self.visit_files(cwd, "\{base}/\{name}", files)
          }
        }
        _ => ()
      }
  }
}

///|
fn trim_slashes(s : String) -> String {
  let mut t = s
  while t.has_suffix("/") {
    t = t.view(end_offset=t.length() - 1).to_string()
  }
  t
}

///|
/// What the task here with this id has come to: its job's state and what it said, hashed (None before it started).
async fn Actors::said(self : Actors, id : String) -> Json raise {
  let job_id = "remote_\{id}"
  let job = self.rstore("getJob", [jstr(job_id)])
  if job is Null {
    return Json::null()
  }
  jstr(rhash(Json::array([field_of(job, "state"), field_of(job, "endedAt"), self.rstore("jobNotices", [jstr(job_id), jnum(20.0)])])))
}

///|
/// What a task waiting in the queue is told of it: its place, what blocks it, and the measured machine's capacity.
async fn Actors::queued(self : Actors, job_id : String, load : @effect.Deferred[Json]?) -> Map[String, Json] raise {
  // (one not waiting is told at once, not behind the jobs' permit: a stop holds it while it signals)
  let job = self.jstore("getJob", [jstr(job_id)])
  if job is Null || str_of(job.value("state")) != Some("running") || !(job.value("queued") is Some(True)) {
    return {}
  }
  if self.locked(() => self.queue_of(job_id)) is Null {
    return {}
  }
  let measured = match load {
    Some(d) => d.wait() catch { _ => Json::null() }
    None => self.rnode("load", []) catch { e => ({ "unavailable": jstr(FsError::of(e)) } : Json) }
  }
  // It may have started while the host was being read; its old queued state is not given.
  let q = self.locked(() => self.queue_of(job_id))
  if q is Null {
    return {}
  }
  let place = num_of(q.value("place")).unwrap_or(1.0)
  let why = match str_of(q.value("why")) {
    Some("memory") => "the machine's memory is under pressure"
    Some("screen") =>
      match str_of(q.value("holder")) {
        Some(h) => "the screen is held by \{h}"
        None => "the screen is held or an earlier request is waiting for it"
      }
    Some("person") => "a person is using this machine's screen (its input not idle): no task is given it meanwhile"
    Some("small") => "another small task is using the station's small-work slot"
    _ => "it is waiting for its turn"
  }
  let at = if place == 1.0 { "next" } else { "number \{place.to_int()}" }
  let out = match q {
    Object(m) => m.copy()
    _ => {}
  }
  out["load"] = measured
  out["note"] = jstr("Waiting in this station's queue (\{at}): \{why}. It starts by itself when there is room; you are told when it ends, as for any task.")
  { "queue": Json::object(out) }
}

///|
priv struct IncomingTask {
  dir : String
  meta : Json
}

///|
priv struct MirrorUse {
  name : String
  used : Double
  busy : Bool
}

///|
/// The owners of the tasks here, kept by session off the records (remote.ts `indexIncoming`): only new or unreadable
/// ones read, the directory's stamp telling whether anything came or went meanwhile.
async fn Actors::index_incoming(self : Actors) -> Unit raise {
  let incoming = self.rjoin([self.remote.root, "incoming"])
  let stamp = async fn() -> String raise {
    match self.lstat(incoming) {
      Some(st) => "\{st.value("ino").unwrap_or(Json::null()).stringify()}:\{st.value("mtimeMs").unwrap_or(Json::null()).stringify()}:\{st.value("ctimeMs").unwrap_or(Json::null()).stringify()}"
      None => ""
    }
  }
  while true {
    let before = stamp()
    if Some(before) == self.remote.incoming_stamp && self.remote.unreadable.length() == 0 {
      return
    }
    let names = self.readdir_names(incoming)
    let present : Map[String, Bool] = {}
    for n in names {
      present[n] = true
    }
    for name in self.remote.task_owners.keys().collect() {
      if !present.contains(name) {
        self.forget_task(name)
      }
    }
    for name in self.remote.unreadable.keys().collect() {
      if !present.contains(name) {
        self.remote.unreadable.remove(name)
      }
    }
    for name in names {
      if self.remote.task_owners.contains(name) {
        continue
      }
      let meta = self.read_json(self.rjoin([incoming, name, "task.json"])) catch { _ => Json::null() }
      if meta is Null {
        // A directory can exist before its record is written, even across a station handover: tried again.
        self.remote.unreadable[name] = true
        continue
      }
      let owner = js_text(Json::array([jstr(text_of(meta, "workspace")), jstr(meta_room_peer(meta)), jstr(text_of(meta, "session"))]))
      self.remote.task_owners[name] = owner
      let owned = self.remote.owner_tasks.get(owner).unwrap_or({})
      owned[name] = true
      self.remote.owner_tasks[owner] = owned
      self.remote.unreadable.remove(name)
    }
    let after = stamp()
    if before == after {
      self.remote.incoming_stamp = Some(after)
      return
    }
    self.remote.incoming_stamp = None
  }
}

///|
fn Actors::forget_task(self : Actors, name : String) -> Unit {
  if self.remote.task_owners.get(name) is Some(owner) {
    if self.remote.owner_tasks.get(owner) is Some(names) {
      names.remove(name)
      if names.length() == 0 {
        self.remote.owner_tasks.remove(owner)
      }
    }
    self.remote.task_owners.remove(name)
  }
  self.remote.unreadable.remove(name)
}

///|
/// The task records (incoming/<id>) of a source session, read afresh (the index only says which).
async fn Actors::tasks_of(self : Actors, workspace : String, peer : String, session : String) -> Array[IncomingTask] raise {
  match self.remote.indexing {
    Some(d) => d.wait() catch { _ => () }
    None => {
      let d : @effect.Deferred[Unit] = @effect.Deferred::new()
      self.remote.indexing = Some(d)
      defer {
        self.remote.indexing = None
        ignore(d.succeed(()))
      }
      self.index_incoming()
    }
  }
  let owner = js_text(Json::array([jstr(workspace), jstr(peer), jstr(session)]))
  let names = match self.remote.owner_tasks.get(owner) {
    Some(n) => n.keys().collect()
    None => []
  }
  let found : Array[IncomingTask] = []
  for name in names {
    let dir = self.rjoin([self.remote.root, "incoming", name])
    let meta = self.read_json(self.rjoin([dir, "task.json"])) catch { _ => continue }
    if text_of(meta, "workspace") == workspace && meta_room_peer(meta) == peer && text_of(meta, "session") == session {
      found.push({ dir, meta })
    }
  }
  found
}

///|
/// The directory in a session's that mirrors the source's `dir` (its last name; with a part of its hash when another
/// directory of the source's has that name there already).
async fn Actors::mirror_name(self : Actors, workspace : String, peer : String, session : String, dir : String) -> String raise {
  let parts = dir.split("/").flat_map(p => p.split("\\")).map(p => p.to_string()).filter(p => p != "").collect()
  let last = if parts.length() > 0 { parts[parts.length() - 1] } else { "" }
  let cleaned = StringBuilder::new()
  let mut n = 0
  for c in last {
    if n >= 100 {
      break
    }
    let ok = c.is_ascii_alphabetic() || c.is_ascii_digit() || c == '.' || c == '_' || c == ' ' || c == '-' || c.to_int() > 127
    cleaned.write_char(if ok { c } else { '_' })
    n += if c.to_int() > 0xFFFF { 2 } else { 1 }
  }
  let mut name = cleaned.to_string()
  if name == "" || name == "." || name == ".." {
    name = "dir"
  }
  let claimed : Map[String, String] = {}
  for t in self.tasks_of(workspace, peer, session) {
    if field_of(t.meta, "mirror") is String(m) {
      claimed[m] = text_of(field_of(t.meta, "spec"), "dir")
    }
  }
  let mirrors = self.rjoin([self.room(workspace, peer, session), "mirrors"])
  for file in self.readdir_names(mirrors) {
    match self.read_manifest(self.rjoin([mirrors, file])) {
      None => ()
      Some(m) => claimed[text_of(m, "name")] = text_of(m, "dir")
    }
  }
  match claimed.get(name) {
    None => name
    Some(owner) if owner == dir => name
    _ => "\{name}-\{rhash(jstr(dir)).view(end_offset=8)}"
  }
}

///|
/// A task ran in or synced `mirror` now. Callers are in the session's lane.
async fn Actors::used_mirror(self : Actors, workspace : String, peer : String, session : String, mirror : String) -> Unit raise {
  let record = self.rjoin([self.room(workspace, peer, session), "mirrors-used.json"])
  let now = self.remote_now()
  ignore(self.update_json(record, used => Some(with_field(used, mirror, jnum(now))), missing={}))
}

///|
/// A session's mirrors here: when a task last ran in or synced each, and whether one runs there or syncs to it now
/// (those marked used now).
async fn Actors::mirrors_of(self : Actors, workspace : String, peer : String, session : String, now : Double) -> Array[MirrorUse] raise {
  let room = self.room(workspace, peer, session)
  let record = self.rjoin([room, "mirrors-used.json"])
  let running : Map[String, Bool] = {}
  let ended : Map[String, Double] = {}
  for t in self.tasks_of(workspace, peer, session) {
    guard field_of(t.meta, "mirror") is String(mirror) else { continue }
    let job = self.rstore("getJob", [jstr(self.job_of_task(t.dir))])
    if str_of(job.value("state")) == Some("running") ||
      (!(job is Null) && field_of(t.meta, "safe") is True && !(field_of(t.meta, "collected") is True)) {
      running[mirror] = true
    }
    if num_of(job.value("endedAt")) is Some(at) && at != 0.0 {
      ended[mirror] = if ended.get(mirror).unwrap_or(0.0) > at { ended.get(mirror).unwrap_or(0.0) } else { at }
    }
  }
  let mirrors = self.readdir_names(self.rjoin([room, "mirrors"])).filter(f => f.has_suffix(".json")).map(f => f.view(end_offset=f.length() - 5).to_string())
  let busy : Map[String, Bool] = {}
  for name in mirrors {
    if running.contains(name) || self.syncing_recently(self.rjoin([room, "sync", name]), now) {
      busy[name] = true
    }
  }
  let used = self.read_json(record) catch { _ => Json::object({}) }
  let marked = mirrors.filter(name => as_i64(field_of(used, name)) is None || busy.contains(name))
  let used = if marked.length() > 0 {
    ignore(self.update_json(record, kept => {
      let m = match kept { Object(m) => m.copy(); _ => {} }
      for name in marked {
        m[name] = jnum(now)
      }
      Some(Json::object(m))
    }, missing={})) catch { _ => () }
    let m = match used { Object(m) => m.copy(); _ => {} }
    for name in marked {
      m[name] = jnum(now)
    }
    Json::object(m)
  } else {
    used
  }
  mirrors.map(name => {
    let u = as_i64(field_of(used, name)).unwrap_or(now)
    let e = ended.get(name).unwrap_or(0.0)
    { name, used: if u > e { u } else { e }, busy: busy.contains(name) }
  })
}

///|
/// A sync to a mirror is under way: its directory there, it or what is in it touched within MIRROR_RECENT_MS.
async fn Actors::syncing_recently(self : Actors, dir : String, now : Double) -> Bool raise {
  let mut latest = 0.0
  let paths = [dir]
  for name in self.readdir_names(dir) {
    paths.push(self.rjoin([dir, name]))
  }
  for p in paths {
    match self.fs("fs.lstat", { "path": jstr(p) }) {
      Null => ()
      st => {
        let at = num_of(st.value("mtimeMs")).unwrap_or(0.0)
        if at > latest {
          latest = at
        }
      }
    }
  }
  now - latest < mirror_recent_ms
}

///|
/// Removes a mirror and what its tasks made in it; its tasks that have not started sync again first. Callers are in
/// the session's lane.
async fn Actors::drop_mirror(self : Actors, workspace : String, peer : String, session : String, mirror : String, why : String) -> Bool {
  let room = self.room(workspace, peer, session)
  let done = try {
    for t in self.tasks_of(workspace, peer, session) {
      let path = self.rjoin([t.dir, "task.json"])
      let meta = self.read_json(path)
      if field_of(meta, "mirror") == jstr(mirror) && field_of(meta, "synced") is True {
        self.write_json(path, with_field(meta, "synced", jbool(false)))
      }
    }
    let tree = self.rjoin([room, "work", mirror])
    // Over its budget (`budget`): as much is to be freed as it is over by.
    if self.remote.over > 0.0 {
      self.remote.over -= num_of(Some(self.rnode("treeBytes", [jstr(tree)]))).unwrap_or(0.0)
    }
    ignore(self.rnode("removeMirror", [jstr(tree)]))
    self.remove(self.rjoin([room, "sync", mirror]), recursive=true)
    self.remove(self.rjoin([room, "mirrors", "\{mirror}.json"]))
    ignore(self.update_json(self.rjoin([room, "mirrors-used.json"]), used => match used {
      Object(m) => {
        let m = m.copy()
        m.remove(mirror)
        Some(Json::object(m))
      }
      _ => None
    })) catch { _ => () }
    self.rlog("info", "remote mirror removed", fields={ "workspace": jstr(workspace), "station": jstr(peer), "session": jstr(session), "mirror": jstr(mirror), "why": jstr(why) })
    true
  } catch {
    e => {
      self.rlog("warn", "remote mirror not removed", fields={ "mirror": jstr(mirror), "error": jstr(FsError::of(e)) })
      false
    }
  }
  done
}

///|
/// Stops a source session's tasks and removes their records and its shared directory (`idle_at`: the target's own
/// cleanup, only what is idle). Callers are in its lane.
async fn Actors::close_here(self : Actors, workspace : String, peer : String, session : String, idle_at : Double?) -> Bool raise {
  let tasks = self.tasks_of(workspace, peer, session)
  let room = self.room(workspace, peer, session)
  // (work() can be called outside the lane: what goes is taken out of its place in one step where work() runs, Node,
  // its use asked again just before; then removed here)
  let moved = match idle_at {
    Some(at) => {
      let recorded = self.read_json(self.rjoin([room, "session.json"])) catch { _ => return false }
      let seen_here = num_of(Some(self.rnode("seenAt", [jstr(room)]))).unwrap_or(0.0)
      let rec = as_i64(field_of(recorded, "seen")).unwrap_or(at)
      let seen = if rec > seen_here { rec } else { seen_here }
      if at - seen < idle_ms || seen_here > seen {
        return false
      }
      for t in tasks {
        if self.task_running(t.dir) {
          return false
        }
      }
      self.rnode("closeRoom", [jstr(room), Json::array(tasks.map(t => jstr(t.dir))), jnum(seen)])
    }
    None => {
      for t in tasks {
        if self.task_running(t.dir) {
          ignore(self.job_stop(self.job_of_task(t.dir)))
        }
        ignore(self.rnode("removeTask", [jstr(t.dir)]))
      }
      self.rnode("closeRoom", [jstr(room), Json::array([]), Json::null()])
    }
  }
  // {aside: the tasks' directories moved, room: where the room went (null: it was not there)}; null: used meanwhile
  if moved is Null {
    return false
  }
  match field_of(moved, "aside") {
    Array(a) =>
      for d in a {
        if d is String(p) {
          ignore(self.rnode("removeTask", [jstr(p)])) catch { _ => () }
        }
      }
    _ => ()
  }
  if field_of(moved, "room") is String(gone) {
    self.rlog("info", "remote session directory removed", fields={ "workspace": jstr(workspace), "station": jstr(peer), "session": jstr(session) })
    self.remove(gone, recursive=true) catch { _ => () }
  }
  true
}

///|
/// The target's own cleanup: a source session's directory unused for IDLE_MS, with nothing running, goes; so do task
/// directories from before shared session directories; mirrors unused for MIRROR_IDLE_MS.
async fn Actors::sweep(self : Actors, now : Double) -> Unit raise {
  let sessions = self.rjoin([self.remote.root, "sessions"])
  for name in self.readdir_names(sessions) {
    if self.remote.stopped {
      return
    }
    let meta = self.read_json(self.rjoin([sessions, name, "session.json"])) catch { _ => continue }
    let (workspace, peer, session) = (text_of(meta, "workspace"), text_of(meta, "station"), text_of(meta, "session"))
    self.in_lane(self.room(workspace, peer, session), async fn() raise {
      let again = self.read_json(self.rjoin([sessions, name, "session.json"])) catch { _ => return }
      let seen_here = num_of(Some(self.rnode("seenAt", [jstr(self.rjoin([sessions, name]))]))).unwrap_or(0.0)
      let rec = as_i64(field_of(again, "seen")).unwrap_or(now)
      let seen = if rec > seen_here { rec } else { seen_here }
      if now - seen >= idle_ms {
        let closed = try {
          self.close_here(workspace, peer, session, Some(now))
        } catch {
          e => {
            self.rlog("warn", "idle remote session directory not removed", fields={ "error": jstr(FsError::of(e)) })
            return
          }
        }
        if closed {
          return
        }
      }
      for m in self.mirrors_of(workspace, peer, session, now) {
        if !m.busy && now - m.used >= mirror_idle_ms {
          ignore(self.drop_mirror(workspace, peer, session, m.name, "unused"))
        }
      }
    })
  }
  let incoming = self.rjoin([self.remote.root, "incoming"])
  for name in self.readdir_names(incoming) {
    if self.remote.stopped {
      return
    }
    let dir = self.rjoin([incoming, name])
    let record = self.rjoin([dir, "task.json"])
    let meta = self.read_json(record) catch { _ => continue }
    if text_of(meta, "layout") == "session" {
      continue
    }
    let (workspace, peer, session) = (text_of(meta, "workspace"), text_of(meta, "station"), text_of(meta, "session"))
    self.in_lane(self.room(workspace, peer, session), async fn() raise {
      let meta = self.read_json(record) catch { _ => return }
      let modified = match self.lstat(record) {
        Some(st) => num_of(st.value("mtimeMs")).unwrap_or(now).floor()
        None => return
      }
      if text_of(meta, "layout") == "session" || now - modified < idle_ms || self.task_running(dir) {
        return
      }
      self.remove(dir, recursive=true)
    })
  }
}

///|
/// The disk of the station's data low (ops/disk.ts): mirrors go, the longest unused first, until there is enough again.
/// One a task runs in or syncs to, or used within MIRROR_RECENT_MS, stays.
async fn Actors::relieve(self : Actors, now : Double) -> Unit raise {
  // (over its budget too: `budget`)
  let low = async fn() -> Bool raise { self.remote.over > 0.0 || truthy(self.rnode("diskLow", [jstr(self.remote.root)])) }
  if !low() {
    return
  }
  let sessions = self.rjoin([self.remote.root, "sessions"])
  let candidates : Array[(String, String, String, String, Double)] = []
  for name in self.readdir_names(sessions) {
    let meta = self.read_json(self.rjoin([sessions, name, "session.json"])) catch { _ => continue }
    let (workspace, peer, session) = (text_of(meta, "workspace"), text_of(meta, "station"), text_of(meta, "session"))
    self.in_lane(self.room(workspace, peer, session), async fn() raise {
      for m in self.mirrors_of(workspace, peer, session, now) {
        if !m.busy && now - m.used >= mirror_recent_ms {
          candidates.push((workspace, peer, session, m.name, m.used))
        }
      }
    })
  }
  candidates.sort_by((a, b) => a.4.compare(b.4))
  for c in candidates {
    if !low() {
      return
    }
    let (workspace, peer, session, name, _) = c
    self.in_lane(self.room(workspace, peer, session), async fn() raise {
      let ms = self.mirrors_of(workspace, peer, session, now)
      if ms.search_by(x => x.name == name) is Some(i) && !ms[i].busy && now - ms[i].used >= mirror_recent_ms {
        ignore(self.drop_mirror(workspace, peer, session, name, "disk low"))
      }
    })
  }
}

///|
/// A room used within this stays, over its budget or not (remote.ts `ROOM_RECENT_MS`).
let room_recent_ms : Double = 3600000.0

///|
/// A task done here (incoming/<task>), and one started from here whose end was told (outgoing/<id>.json), kept this
/// long after (remote.ts `TASKS_KEPT_MS`).
let tasks_kept_ms : Double = 7.0 * 24.0 * 3600.0 * 1000.0

///|
priv struct RoomUse {
  dir : String
  bytes : Double
  seen : Double
  owner : (String, String, String)?
}

///|
/// The source sessions' rooms here (sessions/<id>), each with how much it takes and when it was last used (its record's
/// time, or Node's of a use since: `roomInfo`).
async fn Actors::rooms(self : Actors) -> Array[RoomUse] raise {
  let sessions = self.rjoin([self.remote.root, "sessions"])
  let out : Array[RoomUse] = []
  for name in self.readdir_names(sessions) {
    if self.remote.stopped {
      break
    }
    let dir = self.rjoin([sessions, name])
    let meta = self.read_json(self.rjoin([dir, "session.json"])) catch { _ => Json::null() }
    let info = self.rnode("roomInfo", [jstr(dir)])
    let recorded = match field_of(meta, "seen") {
      Number(n, ..) => n
      _ => 0.0
    }
    let here = num_of(Some(field_of(info, "seenAt"))).unwrap_or(0.0)
    let owner = match (field_of(meta, "workspace"), field_of(meta, "station"), field_of(meta, "session")) {
      (String(w), String(s), String(x)) => Some((w, s, x))
      _ => None
    }
    out.push({ dir, bytes: num_of(Some(field_of(info, "bytes"))).unwrap_or(0.0), seen: if here > recorded { here } else { recorded }, owner })
  }
  out
}

///|
fn rooms_bytes(rooms : Array[RoomUse]) -> Double {
  rooms.fold(init=0.0, (n, r) => n + r.bytes)
}

///|
/// The source sessions with a task running here (incoming's records, their jobs `remote_<task>` running), as JSON of
/// [workspace, station, session]: the records read here, never on Node's thread.
async fn Actors::running_owners(self : Actors) -> Map[String, Bool] raise {
  let owners : Map[String, Bool] = {}
  guard self.rstore("jobsUp", []) is Array(jobs) else { return owners }
  for job in jobs {
    let id = text_of(job, "id")
    if !id.has_prefix("remote_") {
      continue
    }
    let record = self.rjoin([self.remote.root, "incoming", id.view(start_offset=7).to_string(), "task.json"])
    let meta = self.read_json(record) catch { _ => continue }
    owners[js_text(Json::array([field_of(meta, "workspace"), jstr(meta_room_peer(meta)), field_of(meta, "session")]))] = true
  }
  owners
}

///|
/// remote/sessions held to `budget` (remote.ts `budget`): the mirrors not in use go first, the longest unused first
/// (`relieve`, told the disk is low until as much as it is over by went); then the rooms with no task running there,
/// the longest unused first. One used within ROOM_RECENT_MS, and anything a task runs in, stays. The bytes freed.
async fn Actors::budget(self : Actors, now : Double, budget : Double) -> Double raise {
  let before = rooms_bytes(self.rooms())
  if before <= budget || self.remote.stopped {
    return 0.0
  }
  self.rlog("warn", "other stations' rooms here over their budget: the longest unused go", fields={ "bytes": jnum(before), "budget": jnum(budget) })
  self.remote.over = before - budget
  let failed = try {
    self.relieve(now)
    None
  } catch {
    e => Some(e)
  }
  self.remote.over = 0.0
  if failed is Some(e) {
    raise e
  }
  let rooms = self.rooms()
  let mut total = rooms_bytes(rooms)
  let running = self.running_owners()
  rooms.sort_by((a, b) => a.seen.compare(b.seen))
  for room in rooms {
    if total <= budget || self.remote.stopped {
      break
    }
    guard room.owner is Some((workspace, station, session)) else { continue }
    let owner = js_text(Json::array([jstr(workspace), jstr(station), jstr(session)]))
    if now - room.seen < room_recent_ms || running.contains(owner) {
      continue
    }
    // Taken out in one step with its use asked again (Node's `closeRoom`): one used since it was looked at stays.
    let moved = self.rnode("closeRoom", [jstr(room.dir), Json::array([]), jnum(now - room_recent_ms)])
    if field_of(moved, "room") is String(gone) {
      ignore(self.rnode("removeTask", [jstr(gone)])) catch { _ => () }
      total -= room.bytes
      self.rlog("info", "remote session directory removed", fields={
        "why": jstr("over budget"),
        "bytes": jnum(room.bytes),
        "workspace": jstr(workspace),
        "station": jstr(station),
        "session": jstr(session),
      })
    }
  }
  if before - total > 0.0 { before - total } else { 0.0 }
}

///|
let expire_batch_size : Int = 500

///|
/// Tasks long over let go of (remote.ts `expire`): incoming/<task> whose job ended TASKS_KEPT_MS ago (or the store no
/// longer has, and unchanged as long), and outgoing/<id>.json told its end (`delivered`) and unchanged as long. How
/// many.
async fn Actors::expire(self : Actors, now : Double) -> Int raise {
  let mut gone = 0
  let up : Map[String, Bool] = {}
  if self.rstore("jobsUp", []) is Array(jobs) {
    for job in jobs {
      up[text_of(job, "id")] = true
    }
  }
  let incoming = self.rjoin([self.remote.root, "incoming"])
  let names = self.readdir_names(incoming)
  let mut offset = 0
  while offset < names.length() {
    if self.remote.stopped {
      return gone
    }
    let end = if offset + expire_batch_size < names.length() {
      offset + expire_batch_size
    } else {
      names.length()
    }
    let chunk : Array[(String, String)] = []
    let chunk_ids : Array[Json] = []
    for i in offset..<end {
      let name = names[i]
      let id = "remote_\{name}"
      if !up.contains(id) {
        chunk.push((name, id))
        chunk_ids.push(jstr(id))
      }
    }
    offset = end
    if chunk.length() == 0 {
      continue
    }
    let ends = self.rstore("jobsEnds", [Json::array(chunk_ids)])
    for item in chunk {
      if self.remote.stopped {
        return gone
      }
      let (name, id) = item
      let job = field_of(ends, id)
      let dir = self.rjoin([incoming, name])
      let mut at = now
      if job is Null {
        let record = self.lstat(self.rjoin([dir, "task.json"])) catch { _ => None }
        let st = match record {
          Some(st) => Some(st)
          None => self.lstat(dir) catch { _ => None }
        }
        if st is Some(st) {
          at = num_of(Some(field_of(st, "mtimeMs"))).unwrap_or(now)
        }
      } else {
        guard text_of(job, "state") != "running" && num_of(Some(field_of(job, "endedAt"))) is Some(ended) else { continue }
        at = ended
      }
      if now - at < tasks_kept_ms {
        continue
      }
      self.remove(dir, recursive=true) catch { _ => () }
      gone += 1
    }
  }
  let outgoing = self.rjoin([self.remote.root, "outgoing"])
  for name in self.readdir_names(outgoing) {
    if self.remote.stopped || !name.has_suffix(".json") {
      continue
    }
    let file = self.rjoin([outgoing, name])
    let st = self.lstat(file) catch { _ => None }
    guard st is Some(st) else { continue }
    if now - num_of(Some(field_of(st, "mtimeMs"))).unwrap_or(now) < tasks_kept_ms {
      continue
    }
    let record = self.read_json(file) catch { _ => Json::null() }
    if !(field_of(record, "delivered") is True) {
      continue
    }
    self.remove(file) catch { _ => () }
    gone += 1
  }
  if gone > 0 {
    self.rlog("info", "tasks long over let go of", fields={ "count": jnum(gone.to_double()) })
  }
  gone
}

///|
/// Prepared records from before they were kept by session (prepared/<hash>.json) moved into their session's: linked
/// there, never over a newer prepare's record (one there already: the old one goes).
async fn Actors::move_prepared(self : Actors) -> Unit raise {
  let dir = self.rjoin([self.remote.root, "prepared"])
  for name in self.readdir_names(dir) {
    if self.remote.stopped {
      return
    }
    if !name.has_suffix(".json") {
      continue
    }
    let file = self.rjoin([dir, name])
    let v = self.read_json(file) catch { _ => Json::null() }
    let session = text_of(v, "session")
    if session == "" {
      self.remove(file) catch { _ => () }
      continue
    }
    self.mkdirs(self.prepared_dir(session)) catch { _ => () }
    // (true: linked; false: one there already, EEXIST: either way the old one goes)
    let linked = try {
      ignore(self.fs("fs.link", { "from": jstr(file), "to": jstr(self.rjoin([self.prepared_dir(session), name])) }))
      true
    } catch {
      _ => false
    }
    if linked {
      self.remove(file) catch { _ => () }
    }
  }
}

///|
/// Peers removed from a workspace (or the workspace left) have their tasks stopped, without touching any local jobs.
/// `rosters`: each workspace the station is in now, with its other stations.
async fn Actors::revoke(self : Actors, rosters : Json, current : Bool) -> Unit raise {
  if !current {
    return
  }
  let list = match rosters { Array(a) => a; _ => [] }
  let incoming = self.rjoin([self.remote.root, "incoming"])
  for name in self.readdir_names(incoming) {
    let meta = self.read_json(self.rjoin([incoming, name, "task.json"])) catch { _ => continue }
    let peer = text_of(meta, "station")
    if list.iter().any(r => text_of(r, "workspace") == text_of(meta, "workspace") && (match field_of(r, "peers") { Array(p) => p.contains(jstr(peer)); _ => false })) {
      continue
    }
    // A sandbox's task is this station's own, not a peer's.
    if peer.has_prefix("sandbox:") {
      continue
    }
    let id = "remote_\{name}"
    if str_of(self.rstore("getJob", [jstr(id)]).value("state")) == Some("running") {
      ignore(self.job_stop(id)) catch { _ => () }
    }
  }
}

///|
/// `task.list` answers at most this many tasks, in at most this many bytes of JSON: a session's tasks are all its
/// history there, and the answer goes back as one line a peer reads at most 1 MiB of (mesh/peer.ts `MAX_MESSAGE`).
let list_most : Int = 100

///|
let list_bytes : Int = 256 * 1024

///|
/// A listed task's command, name and each path it brings back, at most (UTF-8 bytes); `task.get` says its job whole.
let list_text_bytes : Int = 256

///|
/// A listed task's paths it brings back, at most.
let list_back_most : Int = 16

///|
/// The longest start of `s` of at most `most` UTF-8 bytes (as `bytes_len` counts them), never half a character.
fn clip_utf8(s : String, most : Int) -> String? {
  if bytes_len(s) <= most {
    return None
  }
  let mut n = 0
  let mut i = 0
  while i < s.length() {
    let c = s.unsafe_get(i).to_int()
    let (bytes, units) = if c < 0x80 {
      (1, 1)
    } else if c < 0x800 {
      (2, 1)
    } else if c >= 0xd800 && c <= 0xdbff && i + 1 < s.length() && s.unsafe_get(i + 1).to_int() >= 0xdc00 && s.unsafe_get(i + 1).to_int() <= 0xdfff {
      (4, 2)
    } else {
      (3, 1)
    }
    if n + bytes > most {
      break
    }
    n += bytes
    i += units
  }
  Some(s.exact_view(end=i).to_owned() + "…")
}

///|
/// `v` with its text `key` clipped to `list_text_bytes`, and whether it was.
fn clip_field(v : Json, key : String) -> (Json, Bool) {
  match field_of(v, key) {
    String(t) =>
      match clip_utf8(t, list_text_bytes) {
        Some(c) => (with_field(v, key, jstr(c)), true)
        None => (v, false)
      }
    _ => (v, false)
  }
}

///|
/// A listed task as `task.list` says it: its spec's and job's command and name clipped, its paths brought back at most
/// `list_back_most`, each clipped (`backMore` says how many more there are), and whether anything was.
fn list_entry(entry : Json) -> (Json, Bool) {
  let mut clipped = false
  let mut spec = field_of(entry, "spec")
  for k in ["command", "name"] {
    let (v, c) = clip_field(spec, k)
    spec = v
    clipped = clipped || c
  }
  if field_of(spec, "back") is Array(back) {
    let kept : Array[Json] = []
    for p in back {
      if kept.length() >= list_back_most {
        break
      }
      match p {
        String(t) =>
          match clip_utf8(t, list_text_bytes) {
            Some(c) => {
              kept.push(jstr(c))
              clipped = true
            }
            None => kept.push(p)
          }
        _ => kept.push(p)
      }
    }
    if back.length() > kept.length() {
      spec = with_field(spec, "backMore", jnum((back.length() - kept.length()).to_double()))
      clipped = true
    }
    if clipped {
      spec = with_field(spec, "back", Json::array(kept))
    }
  }
  let mut job = field_of(entry, "job")
  if !(job is Null) {
    for k in ["command", "name"] {
      let (v, c) = clip_field(job, k)
      job = v
      clipped = clipped || c
    }
  }
  ({ "key": field_of(entry, "key"), "spec": spec, "job": job }, clipped)
}

///|
/// Where a task is listed: running first (holding a place of the station's), then waiting in its queue, then the rest.
fn list_rank(job : Json) -> Int {
  if text_of(job, "state") != "running" {
    2
  } else if field_of(job, "queued") is True {
    1
  } else {
    0
  }
}

///|
/// When a task last did anything (its end, or its start), 0 if never started.
fn list_time(job : Json) -> Double {
  let n = (k : String) => match field_of(job, k) {
    Number(x, ..) => x
    _ => 0.0
  }
  if n("endedAt") > n("startedAt") { n("endedAt") } else { n("startedAt") }
}

///|
/// `task.list`'s answer of the tasks listed (rank, time, key, entry): running and queued first, then the latest, ties by
/// key; at most `list_most` of them in at most `list_bytes`. `total` says how many there are; `truncated`, only when
/// not all are said, and `note`, when anything was left out or clipped.
fn list_bounded(listed : Array[(Int, Double, String, Json)]) -> Json {
  listed.sort_by((a, b) => if a.0 != b.0 {
    a.0.compare(b.0)
  } else if a.1 != b.1 {
    b.1.compare(a.1)
  } else {
    @search.compare_units(a.2, b.2)
  })
  let tasks : Array[Json] = []
  // `{"tasks":[` … `],"total":N,"truncated":true,"note":"…"}`: room kept for all but the tasks.
  let mut used = 1024
  let mut clipped = false
  for one in listed {
    if tasks.length() >= list_most {
      break
    }
    let (entry, c) = list_entry(one.3)
    let size = bytes_len(js_text(entry)) + 1
    if used + size > list_bytes {
      break
    }
    used += size
    clipped = clipped || c
    tasks.push(entry)
  }
  let answer : Map[String, Json] = { "tasks": Json::array(tasks), "total": jnum(listed.length().to_double()) }
  if tasks.length() < listed.length() {
    answer["truncated"] = jbool(true)
  }
  if tasks.length() < listed.length() || clipped {
    answer["note"] = jstr(
      "\{tasks.length()} of \{listed.length()} tasks listed (running and queued first, then the latest), long commands and paths clipped (…); action get with a task's key says its job whole",
    )
  }
  Json::object(answer)
}
