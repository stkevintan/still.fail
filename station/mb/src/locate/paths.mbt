// Where a session's transcripts are, as station/src/read/transcript.ts finds them (`transcriptPathsLooking`,
// `transcriptSourcesLooking` and what they call): its paths made as Node's path.join makes them, the filesystem asked
// through the shell (`fs.stat`, `fs.readdir`, `fs.realpath`, as Node's stat, readdir and realpath answer), and the
// in-process hints it keeps (`elsewhere`, `rollouts`, `saidRollouts`) given for each batch by the station
// (`transcriptLocationHints`) and given back after it.

///|
/// A Codex rollout path a running thread said (transcript.ts `SaidRollout`).
pub(all) struct Said {
  suffix : String
  mut seen : Bool
}

///|
/// What finds transcripts: the shell, the platform's separator and the hints of the batch being looked for.
pub struct Finder {
  priv host : @host.Host
  priv sep : String
  priv elsewhere : Map[String, String?]
  priv rollouts : Map[String, String]
  priv said : Map[String, Map[String, Said]]
  priv track_failed_dirs : Bool
  priv failed_dirs : Set[String]
  priv readdir_err : Set[String]
  /// Whether what the directories hold is read once and kept for this finder's life (`cache_dirs`): for one pass of
  /// many lookups (the replica export's), never a finder that lives on across them (the live `Locator`).
  priv cache_dirs : Bool
  priv real_cache : Map[String, String?]
  priv entries_cache : Map[String, Array[String]?]
  priv rollout_cache : Map[String, Rollouts]
  priv claude_cache : Map[String, ClaudeIndex?]
  /// How many times the shell was asked (`fs.stat`, `fs.readdir`, `fs.realpath`): what a test bounds.
  priv mut asked : Int
}

///|
/// The Codex rollout files under a directory, in the order `Finder::rollout` meets them, and the directories under it
/// that could not be read (the directory itself among them when it could not).
priv struct Rollouts {
  files : Array[(String, String)]
  failed : Array[String]
}

///|
/// A Claude transcripts directory read once: by session id, the first project (in the directory's order) keeping its
/// transcript, with that project's place in the order and the transcript's path; and the projects that could not be
/// read, with their places, looked in one by one as before.
priv struct ClaudeIndex {
  kept : Map[String, (Int, String)]
  failed : Array[(Int, String)]
}

///|
pub fn Finder::new(
  host : @host.Host,
  sep : String,
  track_failed_dirs? : Bool = false,
  readdir_err? : Set[String] = Set([]),
  cache_dirs? : Bool = false,
) -> Finder {
  {
    host,
    sep,
    elsewhere: Map([]),
    rollouts: Map([]),
    said: Map([]),
    track_failed_dirs,
    failed_dirs: Set([]),
    readdir_err,
    cache_dirs,
    real_cache: Map([]),
    entries_cache: Map([]),
    rollout_cache: Map([]),
    claude_cache: Map([]),
    asked: 0,
  }
}

///|
/// How many times this finder asked the shell about the filesystem.
pub fn Finder::asked(self : Finder) -> Int {
  self.asked
}

///|
/// Directories that could not be read, met again in what was kept of them: told again, as reading them would.
fn Finder::failed_again(self : Finder, dirs : Array[String]) -> Unit {
  if self.track_failed_dirs {
    for d in dirs {
      self.failed_dirs.add(d)
    }
  }
}

///|
/// Returns and clears directories whose `fs.readdir` failed during discovery (for unreadable-path protection).
pub fn Finder::take_failed_dirs(self : Finder) -> Array[String] {
  let out = self.failed_dirs.iter().collect()
  self.failed_dirs.clear()
  out
}

///|
/// Node's path.join (posix's, or win32's when the separator is `\`): the parts joined, then normalized.
pub fn Finder::join(self : Finder, parts : Array[String]) -> String {
  @nodepath.join(self.sep, parts)
}

///|
/// What stat says a path is ("file", "dir", "other"), none when it cannot.
fn Finder::stat(self : Finder, path : String) -> String? {
  self.asked += 1
  match (try { Ok(self.host.shell_sync("fs.stat", { "path": Json::string(path) })) } catch { e => Err(e) }) {
    Ok(String(kind)) => Some(kind)
    _ => None
  }
}

///|
fn Finder::is_file(self : Finder, path : String) -> Bool {
  self.stat(path) == Some("file")
}

///|
fn Finder::is_dir(self : Finder, path : String) -> Bool {
  self.stat(path) == Some("dir")
}

///|
/// archive.rs `storage`: the file, or its `.zst` once put away.
fn Finder::storage(self : Finder, path : String) -> String {
  if self.stat(path) is Some(_) {
    path
  } else {
    path + ".zst"
  }
}

///|
fn Finder::kept(self : Finder, path : String) -> Bool {
  self.is_file(self.storage(path))
}

///|
fn Finder::readdir_json(self : Finder, dir : String, types : Bool) -> Json? {
  self.asked += 1
  if self.readdir_err.contains(dir) {
    return None
  }
  let args : Json = if types {
    { "path": Json::string(dir), "types": true }
  } else {
    { "path": Json::string(dir) }
  }
  match (try { Ok(self.host.shell_sync("fs.readdir", args)) } catch { e => Err(e) }) {
    Ok(Array(_) as arr) => Some(arr)
    _ => None
  }
}

///|
/// A directory's names, none when it cannot be read.
fn Finder::entries(self : Finder, dir : String) -> Array[String]? {
  match self.readdir_json(dir, false) {
    Some(Array(names)) => Some(names.filter_map(n => if n is String(s) { Some(s) } else { None }))
    _ => {
      if self.track_failed_dirs {
        self.failed_dirs.add(dir)
      }
      None
    }
  }
}

///|
/// A directory's names with their kinds as the directory says them ("file", "dir", "link", "other").
fn Finder::typed_entries(self : Finder, dir : String) -> Array[(String, String)]? {
  match self.readdir_json(dir, true) {
    Some(Array(entries)) =>
      Some(
        entries.filter_map(e => if e is Array([String(name), String(kind)]) { Some((name, kind)) } else { None }),
      )
    _ => {
      if self.track_failed_dirs {
        self.failed_dirs.add(dir)
      }
      None
    }
  }
}

///|
fn Finder::real(self : Finder, path : String) -> String? {
  if self.cache_dirs {
    if self.real_cache.get(path) is Some(known) {
      return known
    }
    let found = self.real_uncached(path)
    self.real_cache[path] = found
    return found
  }
  self.real_uncached(path)
}

///|
fn Finder::real_uncached(self : Finder, path : String) -> String? {
  self.asked += 1
  match (try { Ok(self.host.shell_sync("fs.realpath", { "path": Json::string(path) })) } catch { e => Err(e) }) {
    Ok(String(p)) => Some(p)
    _ => None
  }
}

///|
/// transcript.ts `transcriptDir`.
pub fn transcript_dir(runtime : String) -> String {
  match runtime {
    "claude" => "projects"
    "codex" => "sessions"
    "grok" => "grok/sessions"
    "cursor" => "cursor/sessions"
    "devin" => "devin/sessions"
    "hermes" => "hermes/sessions"
    "agy" => "agy/sessions"
    "pi" => "pi/sessions"
    _ => "dsh-sessions"
  }
}

///|
/// agents/runtime.ts `RUNTIME_KINDS`.
pub fn runtime_kind(runtime : String) -> Bool {
  ["claude", "codex", "dsh", "grok", "cursor", "devin", "hermes", "agy", "pi"].contains(runtime)
}

///|
/// transcript.ts `claudeProject`: each character but an ASCII letter or digit a dash, none past 200 (UTF-16 units).
pub fn claude_project(cwd : String) -> String? {
  if cwd.length() > 200 {
    return None
  }
  let out = StringBuilder::new()
  for i in 0..<cwd.length() {
    let c = cwd.unsafe_charcode_at(i)
    if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') {
      out.write_char(c.unsafe_to_char())
    } else {
      out.write_char('-')
    }
  }
  Some(out.to_string())
}

///|
/// transcript.ts `placedIn`.
fn Finder::placed_in(self : Finder, runtime : String, dir : String, id : String, places : Array[String]) -> String? {
  if runtime != "claude" {
    return None
  }
  for place in places {
    let ways = match self.real(place) {
      Some(at) => if at == place { [place] } else { [place, at] }
      None => [place]
    }
    for way in ways {
      guard claude_project(way) is Some(project) else { continue }
      let path = self.join([dir, project, id + ".jsonl"])
      if self.kept(path) {
        return Some(path)
      }
    }
  }
  None
}

///|
/// transcript.ts `transcriptIn`.
fn Finder::transcript_in(self : Finder, runtime : String, dir : String, id : String, placed : Bool, anywhere : Bool) -> String? {
  match runtime {
    "dsh" => return self.dsh(dir, id)
    "grok" => return self.grok(dir, id)
    "cursor" | "devin" | "hermes" | "agy" | "pi" => {
      let path = self.join([dir, id + ".jsonl"])
      return if self.kept(path) { Some(path) } else { None }
    }
    "claude" => {
      let at = dir + "\u{0}" + id
      match self.elsewhere.get(at) {
        Some(None) => if placed { return None }
        Some(Some(kept)) => if self.kept(kept) { return Some(kept) }
        None => ()
      }
      if !anywhere {
        return None
      }
      if self.cache_dirs {
        return self.claude_indexed(dir, id, at, placed)
      }
      guard self.entries(dir) is Some(projects) else { return None }
      for project in projects {
        let path = self.join([dir, project, id + ".jsonl"])
        if self.kept(path) {
          self.elsewhere[at] = Some(path)
          return Some(path)
        }
      }
      if placed {
        self.elsewhere[at] = None
      }
      return None
    }
    _ => ()
  }
  let at = dir + "\u{0}" + id
  if self.rollouts.get(at) is Some(kept) && self.kept(kept) {
    return Some(kept)
  }
  let found = self.rollout(dir, id)
  if found is Some(path) {
    self.rollouts[at] = path
  }
  found
}

///|
/// A Codex rollout file under `dir`, through its days' directories, as `transcriptIn`'s `find`.
fn Finder::rollout(self : Finder, dir : String, id : String) -> String? {
  if self.cache_dirs {
    return self.rollout_indexed(dir, id)
  }
  guard self.typed_entries(dir) is Some(entries) else { return None }
  for entry in entries {
    let (name, kind) = entry
    let path = self.join([dir, name])
    if kind == "dir" || (kind != "file" && self.is_dir(path)) {
      if self.rollout(path, id) is Some(found) {
        return Some(found)
      }
    } else if name.has_prefix("rollout-") && name.has_suffix(id + ".jsonl") {
      return Some(path)
    } else if name.has_prefix("rollout-") && name.has_suffix(id + ".jsonl.zst") {
      return Some(path.view(end_offset=path.length() - 4).to_owned())
    }
  }
  None
}

///|
/// `Finder::rollout` over the rollouts under `dir` read once: the same file, the same directories told unreadable.
fn Finder::rollout_indexed(self : Finder, dir : String, id : String) -> String? {
  let found = match self.rollout_cache.get(dir) {
    Some(known) => {
      self.failed_again(known.failed)
      known
    }
    None => {
      let r : Rollouts = { files: [], failed: [] }
      self.gather_rollouts(dir, r)
      self.rollout_cache[dir] = r
      r
    }
  }
  let plain = id + ".jsonl"
  let packed = id + ".jsonl.zst"
  for file in found.files {
    let (name, path) = file
    if name.has_suffix(plain) {
      return Some(path)
    } else if name.has_suffix(packed) {
      return Some(path.view(end_offset=path.length() - 4).to_owned())
    }
  }
  None
}

///|
/// Every rollout file under `dir`, through all its directories, in the order `Finder::rollout` goes through them.
fn Finder::gather_rollouts(self : Finder, dir : String, into : Rollouts) -> Unit {
  guard self.typed_entries(dir) is Some(entries) else {
    into.failed.push(dir)
    return
  }
  for entry in entries {
    let (name, kind) = entry
    let path = self.join([dir, name])
    if kind == "dir" || (kind != "file" && self.is_dir(path)) {
      self.gather_rollouts(path, into)
    } else if name.has_prefix("rollout-") && (name.has_suffix(".jsonl") || name.has_suffix(".jsonl.zst")) {
      into.files.push((name, path))
    }
  }
}

///|
/// Whether `kept(join([dir, name]))`, answered from `dir`'s listing (`kinds`) and asking stat only of a link or an
/// entry of no kind: a name not listed is not there, one listed a directory is not a file.
fn Finder::kept_listed(self : Finder, kinds : Map[String, String], dir : String, name : String) -> Bool {
  let packed = () => match kinds.get(name + ".zst") {
    Some("file") => true
    Some("dir") | None => false
    Some(_) => self.is_file(self.join([dir, name + ".zst"]))
  }
  match kinds.get(name) {
    Some("file") => true
    Some("dir") => false
    Some(_) =>
      match self.stat(self.join([dir, name])) {
        Some(kind) => kind == "file"
        None => packed()
      }
    None => packed()
  }
}

///|
/// The Claude transcripts directory `dir` read once: each project read, its transcripts' ids kept.
fn Finder::claude_index(self : Finder, dir : String) -> ClaudeIndex? {
  match self.claude_cache.get(dir) {
    Some(Some(known)) => {
      self.failed_again(known.failed.map(f => f.1))
      return Some(known)
    }
    Some(None) => {
      self.failed_again([dir])
      return None
    }
    None => ()
  }
  guard self.typed_entries(dir) is Some(projects) else {
    self.claude_cache[dir] = None
    return None
  }
  let index : ClaudeIndex = { kept: Map([]), failed: [] }
  for i, entry in projects {
    let (project, pkind) = entry
    let project_dir = self.join([dir, project])
    guard pkind == "dir" || (pkind != "file" && self.is_dir(project_dir)) else { continue }
    guard self.typed_entries(project_dir) is Some(names) else {
      index.failed.push((i, project_dir))
      continue
    }
    let kinds : Map[String, String] = Map([])
    for n in names {
      kinds[n.0] = n.1
    }
    for n in names {
      let name = n.0
      let fid = if name.has_suffix(".jsonl") {
        name.view(end_offset=name.length() - 6).to_string()
      } else if name.has_suffix(".jsonl.zst") {
        name.view(end_offset=name.length() - 10).to_string()
      } else {
        continue
      }
      if index.kept.contains(fid) || !self.kept_listed(kinds, project_dir, fid + ".jsonl") {
        continue
      }
      index.kept[fid] = (i, self.join([dir, project, fid + ".jsonl"]))
    }
  }
  self.claude_cache[dir] = Some(index)
  Some(index)
}

///|
/// `transcriptIn`'s look through every Claude project for `id`, over the directory read once: the same first project
/// keeping it, the projects that could not be read looked in as before, and no answer kept for an id not found while
/// some could not be read.
fn Finder::claude_indexed(self : Finder, dir : String, id : String, at : String, placed : Bool) -> String? {
  guard self.claude_index(dir) is Some(index) else { return None }
  let hit = index.kept.get(id)
  for f in index.failed {
    let (i, project_dir) = f
    if hit is Some((first, _)) && i > first {
      break
    }
    let path = self.join([project_dir, id + ".jsonl"])
    if self.kept(path) {
      self.elsewhere[at] = Some(path)
      return Some(path)
    }
  }
  if hit is Some((_, path)) {
    self.elsewhere[at] = Some(path)
    return Some(path)
  }
  if placed && index.failed.is_empty() {
    self.elsewhere[at] = None
  }
  None
}

///|
/// A root's names for `dsh` and `grok`, read once when the finder keeps what directories hold.
fn Finder::root_entries(self : Finder, root : String) -> Array[String]? {
  guard self.cache_dirs else { return self.entries(root) }
  match self.entries_cache.get(root) {
    Some(known) => {
      if known is None {
        self.failed_again([root])
      }
      known
    }
    None => {
      let found = self.entries(root)
      self.entries_cache[root] = found
      found
    }
  }
}

///|
/// The N of `session.v<N>.jsonl` (as Number reads its digits), none for another name.
fn dsh_version(name : String) -> Double? {
  guard name.has_prefix("session.v") && name.has_suffix(".jsonl") else { return None }
  let digits = name.view(start_offset=9, end_offset=name.length() - 6)
  if digits.length() == 0 {
    return None
  }
  let mut n = 0.0
  for c in digits {
    guard c >= '0' && c <= '9' else { return None }
    n = n * 10.0 + (c.to_int() - '0'.to_int()).to_double()
  }
  Some(n)
}

///|
/// transcript.ts `dshTranscript`: the highest version's file (the first of equal ones) in the first directory with one.
fn Finder::dsh(self : Finder, root : String, id : String) -> String? {
  for dir in self.root_entries(root).unwrap_or([]) {
    let mut best : (String, Double)? = None
    for name in self.entries(self.join([root, dir, id])).unwrap_or([]) {
      guard dsh_version(name) is Some(v) else { continue }
      match best {
        Some((_, b)) => if v > b { best = Some((name, v)) }
        None => best = Some((name, v))
      }
    }
    if best is Some((name, _)) {
      return Some(self.join([root, dir, id, name]))
    }
  }
  None
}

///|
/// transcript.ts `grokTranscript`.
fn Finder::grok(self : Finder, root : String, id : String) -> String? {
  for dir in self.root_entries(root).unwrap_or([]) {
    let path = self.join([root, dir, id, "chat_history.jsonl"])
    if self.kept(path) {
      return Some(path)
    }
  }
  None
}

///|
/// transcript.ts `homesFirst`.
fn homes_first(profiles : Array[(String, String)], first : String?) -> Array[String] {
  let out = []
  for p in profiles {
    if Some(p.0) == first {
      out.push(p.1)
    }
  }
  for p in profiles {
    if Some(p.0) != first {
      out.push(p.1)
    }
  }
  out
}

///|
/// transcript.ts `transcriptPathsLooking` for one id: its path, if found (`anywhere` false: a Claude one in its places alone).
pub fn Finder::transcript_path(
  self : Finder,
  runtime : String,
  data : String,
  homes : Array[String],
  id : String,
  places : Array[String],
  anywhere : Bool,
) -> String? {
  let shared = self.join([data, "transcripts", runtime])
  let ways = homes.map(home => self.join([home, transcript_dir(runtime)]))
  let said_dirs = if runtime == "codex" { [shared, ..ways] } else { [] }
  let dirs = [shared]
  let mut next_way = 0
  let mut seen : Set[String]? = None
  let dir_at = (i : Int) => {
    while dirs.length() <= i && next_way < ways.length() {
      let s = match seen {
        Some(s) => s
        None => {
          let s = Set([self.real(shared).unwrap_or(shared)])
          seen = Some(s)
          s
        }
      }
      let dir = ways[next_way]
      next_way += 1
      if self.real(dir) is Some(at) && !s.contains(at) {
        s.add(at)
        dirs.push(dir)
      }
    }
    if i < dirs.length() {
      Some(dirs[i])
    } else {
      None
    }
  }
  let in_dirs = (look : (String) -> String?) => {
    for i = 0; dir_at(i) is Some(dir); i = i + 1 {
      if look(dir) is Some(path) {
        return Some(path)
      }
    }
    None
  }
  let placed = places.length() > 0
  let mut reported : Said? = None
  if runtime == "codex" {
    for dir in said_dirs {
      let known = match self.said.get(id) {
        Some(m) =>
          match m.get(dir) {
            Some(s) => Some(s)
            None => m.get(self.real(dir).unwrap_or(dir))
          }
        None => None
      }
      guard known is Some(said) else { continue }
      if reported is None {
        reported = Some(said)
      }
      let path = self.join([dir, said.suffix])
      if self.kept(path) {
        said.seen = true
        return Some(path)
      }
      if !said.seen && !anywhere {
        return None
      }
    }
  }
  let path = match in_dirs(dir => self.placed_in(runtime, dir, id, places)) {
    Some(p) => Some(p)
    None => in_dirs(dir => self.transcript_in(runtime, dir, id, placed, anywhere))
  }
  if path is Some(_) && reported is Some(said) {
    said.seen = true
  }
  path
}

///|
/// A runtime session whose transcript is looked for (live-location-protocol.ts `LiveSource`).
pub(all) struct Source {
  id : String
  runtime : String
  profile : String?
}

///|
/// transcript.ts `transcriptSourcesLooking`: each source's path with its runtime, and whether the last one's was found
/// (`anywhere` false, as the live locator asks: a Claude one looked for in its places alone).
pub fn Finder::sources(
  self : Finder,
  data : String,
  profiles : Array[(String, String)],
  sources : Array[Source],
  places : Array[String],
  anywhere? : Bool = false,
) -> (Array[(String, String)], Bool) {
  let paths = []
  let mut current = false
  for source in sources {
    if !runtime_kind(source.runtime) {
      current = false
      continue
    }
    let found = self.transcript_path(source.runtime, data, homes_first(profiles, source.profile), source.id, places, anywhere)
    current = found is Some(_)
    if found is Some(path) {
      paths.push((path, source.runtime))
    }
  }
  (paths, current)
}

///|
/// test/reference/transcript-paths.ts `useTranscriptLocationHints`: the hints of one batch, read from what the station sent.
pub fn Finder::use_hints(self : Finder, hints : Json) -> Unit {
  self.elsewhere.clear()
  self.rollouts.clear()
  self.said.clear()
  if hints is { "elsewhere": Array(pairs), .. } {
    for pair in pairs {
      match pair {
        [String(key), String(path)] => self.elsewhere[key] = Some(path)
        [String(key), Null] => self.elsewhere[key] = None
        _ => ()
      }
    }
  }
  if hints is { "rollouts": Array(pairs), .. } {
    for pair in pairs {
      if pair is [String(key), String(path)] {
        self.rollouts[key] = path
      }
    }
  }
  if hints is { "said": Array(ids), .. } {
    for entry in ids {
      guard entry is [String(id), Array(dirs)] else { continue }
      let m : Map[String, Said] = Map([])
      for d in dirs {
        if d is [String(dir), { "suffix": String(suffix), "seen": seen, .. }] {
          m[dir] = { suffix, seen: seen is True }
        }
      }
      self.said[id] = m
    }
  }
}

///|
/// The hints as the batch left them, to be given back (`TranscriptLocationHints`): only this batch's are kept here.
pub fn Finder::hints(self : Finder) -> Json {
  let elsewhere : Array[Json] = []
  for key, path in self.elsewhere {
    elsewhere.push([Json::string(key), match path { Some(p) => Json::string(p); None => Json::null() }])
  }
  let rollouts : Array[Json] = []
  for key, path in self.rollouts {
    rollouts.push([Json::string(key), Json::string(path)])
  }
  let said : Array[Json] = []
  for id, dirs in self.said {
    let entries : Array[Json] = []
    for dir, s in dirs {
      entries.push([Json::string(dir), { "suffix": Json::string(s.suffix), "seen": Json::boolean(s.seen) }])
    }
    said.push([Json::string(id), Json::array(entries)])
  }
  { "elsewhere": Json::array(elsewhere), "rollouts": Json::array(rollouts), "said": Json::array(said) }
}
