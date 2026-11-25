// The values of a copy (station/src/replica): rows and records as JavaScript has them (keys in their order, numbers and
// strings written as JSON.stringify writes them), what the shell is asked of the filesystem, and SHA-1 for the digests
// of what was written.

///|
using @jsjson { type JValue }

///|
/// A string as a JSON string value.
pub fn str(s : String) -> JValue {
  Str(s)
}

///|
/// A value the shell gave (a row's column) as JavaScript has it.
pub fn of_json(j : Json) -> JValue {
  @jsjson.JValue::of_json(j)
}

///|
/// A row the shell gave, by its columns' names in their order.
fn row_of(m : Map[String, Json]) -> JValue {
  Obj(m.to_array().map(e => (e.0, of_json(e.1))))
}

///|
/// A value as a statement's parameter (as node:sqlite binds a number, a string, null).
fn param(v : JValue?) -> Json {
  match v {
    Some(Num(d)) => Json::number(d)
    Some(Str(s)) => Json::string(@jsjson.sanitize_str(s))
    Some(Bool(b)) => Json::boolean(b)
    Some(Null) | None => Json::null()
    Some(v) => Json::string(@jsjson.stringify(v))
  }
}

///|
fn get(v : JValue, name : String) -> JValue? {
  match v {
    Obj(_) => v.get(name)
    _ => None
  }
}

///|
/// `num` of station/test/reference/replica-export.ts: a number as it is, anything else 0.
fn num(v : JValue?) -> Double {
  match v {
    Some(Num(d)) => d
    _ => 0.0
  }
}

///|
fn text_of(v : JValue?) -> String? {
  match v {
    Some(Str(s)) => Some(@jsjson.sanitize_str(s))
    _ => None
  }
}

///|
/// `o` with `name` set: where it is, in its place, else last (as `{...o, name}` has it).
fn set(o : JValue, name : String, v : JValue) -> JValue {
  guard o is Obj(entries) else { return Obj([(name, v)]) }
  let out = []
  let mut found = false
  for e in entries {
    if e.0 == name {
      if !found {
        out.push((name, v))
        found = true
      }
    } else {
      out.push(e)
    }
  }
  if !found {
    out.push((name, v))
  }
  Obj(out)
}

///|
/// `o` with each of `pairs` set, as `set` of each in turn gives, in one walk of `o` (`pairs` have distinct names).
fn set_all(o : JValue, pairs : Array[(String, JValue)]) -> JValue {
  let entries = match o {
    Obj(entries) => entries
    _ => if pairs.length() == 0 { return o } else { [] }
  }
  let at : Map[String, Int] = Map([])
  for i, p in pairs {
    at[p.0] = i
  }
  let put = FixedArray::make(pairs.length(), false)
  let out = []
  for e in entries {
    match at.get(e.0) {
      Some(i) =>
        if !put[i] {
          out.push(pairs[i])
          put[i] = true
        }
      None => out.push(e)
    }
  }
  for i, p in pairs {
    if !put[i] {
      out.push(p)
    }
  }
  Obj(out)
}

///|
/// `o` without `name`.
fn without(o : JValue, name : String) -> JValue {
  guard o is Obj(entries) else { return o }
  Obj(entries.filter(e => e.0 != name))
}

///|
fn keys_of(o : JValue) -> Array[String] {
  match o {
    Obj(entries) => {
      let out : Array[String] = []
      for e in entries {
        let k = @jsjson.sanitize_str(e.0)
        if !out.contains(k) {
          out.push(k)
        }
      }
      out
    }
    _ => []
  }
}

///|
fn stringify(v : JValue) -> String {
  @jsjson.stringify(v)
}

///|
/// How many bytes `s` is in UTF-8, as Buffer.from(s, "utf8") makes it (a lone surrogate three, as U+FFFD).
pub fn utf8_length(s : String) -> Int {
  @jsjson.js_utf8_len(s)
}

///|
/// SHA-1 of `s` in UTF-8, as lowercase hex (createHash("sha1").update(s)).
pub fn sha1_hex(s : String) -> String {
  @hash.sha1_utf8_hex(s)
}

///|
/// What the program asks of the filesystem, through the shell.
pub struct Files {
  host : @host.Host
  /// The platform's separator (Node's path.sep).
  sep : String
}

///|
fn Files::call(self : Files, op : String, args : Json) -> Json raise {
  if looking.val is Some(seen) && args is { "path": String(p), .. } {
    seen.push((op, p))
  }
  self.host.shell_sync(op, args)
}

///|
/// What the program asked of the filesystem, each ask's op and path, where a test asked to be told
/// (station/test/carry-walk-bounded.test.ts: a gathering looks at the disk as main's walk did, and at the sign alone).
let looking : Ref[Array[(String, String)]?] = { val: None }

///|
/// From now on what is asked of the filesystem is kept, to be said with the answer (`looked`).
pub fn count_looks() -> Unit {
  looking.val = Some([])
}

///|
fn Files::join(self : Files, parts : Array[String]) -> String {
  @nodepath.join(self.sep, parts)
}

///|
/// `path`'s folder (path.dirname, for a path this program made).
fn Files::dirname(self : Files, path : String) -> String {
  let slash = path.rev_find("/").unwrap_or(-1)
  let back = if self.sep == "\\" { path.rev_find("\\").unwrap_or(-1) } else { -1 }
  let cut = if slash > back { slash } else { back }
  if cut <= 0 {
    if cut == 0 { self.sep } else { "." }
  } else {
    path.view(end_offset=cut).to_string()
  }
}

///|
/// Whether something is there (existsSync: links followed).
fn Files::exists(self : Files, path : String) -> Bool {
  match (try { Ok(self.call("fs.stat", { "path": Json::string(path) })) } catch { e => Err(e) }) {
    Ok(String(_)) => true
    _ => false
  }
}

///|
fn Files::kind(self : Files, path : String) -> String? {
  match (try { Ok(self.call("fs.stat", { "path": Json::string(path) })) } catch { e => Err(e) }) {
    Ok(String(k)) => Some(k)
    _ => None
  }
}

///|
/// A file's size and modification time (ms, floored), none when it is not there.
fn Files::meta(self : Files, path : String) -> (Double, Double)? {
  match (try { Ok(self.call("fs.meta", { "path": Json::string(path) })) } catch { e => Err(e) }) {
    Ok({ "size": Number(size, ..), "mtimeMs": Number(mtime, ..), .. }) => Some((size, mtime))
    Ok({ "size": Number(size, ..), .. }) => Some((size, 0.0))
    _ => None
  }
}

///|
fn Files::size(self : Files, path : String) -> Double raise {
  match self.meta(path) {
    Some((size, _)) => size
    None => fail("ENOENT: no such file or directory, stat '\{path}'")
  }
}

///|
/// A file's text (zstd's frames read as what they hold, with `zstd`); none where it does not open.
fn Files::read(self : Files, path : String, zstd? : Bool = false) -> String? raise {
  match self.call("fs.read", { "path": Json::string(path), "zstd": Json::boolean(zstd) }) {
    String(s) => Some(s)
    _ => None
  }
}

///|
/// `text` written whole at `path` (zstd's frame of it, with `zstd`): the SHA-256 of what was written.
fn Files::write(self : Files, path : String, text : String, zstd? : Bool = false) -> String raise {
  match self.call("fs.write", { "path": Json::string(path), "text": Json::string(text), "zstd": Json::boolean(zstd) }) {
    { "sha256": String(h), .. } => h
    _ => fail("the shell wrote nothing")
  }
}

///|
fn Files::hash(self : Files, path : String) -> String? raise {
  match self.call("fs.hash", { "path": Json::string(path) }) {
    String(h) => Some(h)
    _ => None
  }
}

///|
fn Files::mkdir(self : Files, path : String) -> Unit raise {
  ignore(self.call("fs.mkdir", { "path": Json::string(path) }))
}

///|
fn Files::remove(self : Files, path : String, recursive? : Bool = false) -> Unit raise {
  ignore(self.call("fs.remove", { "path": Json::string(path), "recursive": Json::boolean(recursive) }))
}

///|
fn Files::rename(self : Files, from : String, to : String) -> Unit raise {
  ignore(self.call("fs.rename", { "from": Json::string(from), "to": Json::string(to) }))
}

///|
fn Files::copy(self : Files, from : String, to : String) -> Unit raise {
  ignore(self.call("fs.copy", { "from": Json::string(from), "to": Json::string(to) }))
}

///|
/// A folder's names in readdirSync's order; none where it does not read.
fn Files::names(self : Files, path : String) -> Array[String]? {
  match (try { Ok(self.call("fs.readdir", { "path": Json::string(path) })) } catch { e => Err(e) }) {
    Ok(Array(names)) => Some(names.filter_map(n => if n is String(s) { Some(s) } else { None }))
    _ => None
  }
}

///|
/// `n` random bytes, as hex (randomBytes(n).toString("hex")).
fn Files::random(self : Files, n : Int) -> String raise {
  match self.call("crypto.random", { "bytes": Json::number(n.to_double()) }) {
    String(h) => h
    _ => fail("the shell gave no random bytes")
  }
}
