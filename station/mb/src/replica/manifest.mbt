// Two-level 256-bucket canonical pure JSON manifest for replica transcript chunks
// (mirrors station/src/replica/manifest.ts byte-for-byte).
//
// Root manifest (`<rootHash>` = SHA-256 of canonical UTF-8 bytes, no whitespace):
//   {"v":1,"buckets":{"00":"<leafHash>",...}}
// Bucket leaf (`<leafHash>`):
//   {"v":1,"files":{"<chunkHash>":<compSize>,...}}

///|
pub let manifest_version : Int = 1

///|
pub let manifest_max_bytes : Int = 67108864

///|
pub let manifest_max_entries : Int = 500000

///|
pub let manifest_max_buckets : Int = 256

///|
pub let manifest_gc_grace_ms : Double = 600000.0

///|
pub struct EncodedManifest {
  root_hash : String
  root_bytes : Bytes
  buckets : Array[(String, String)]
  leaves : Array[(String, String, Bytes)]
}

///|
fn hex2_ok(s : String) -> Bool {
  if s.length() != 2 {
    return false
  }
  for i in 0..<2 {
    let c = s.unsafe_charcode_at(i)
    if !((c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x66)) {
      return false
    }
  }
  true
}

///|
fn non_neg_safe_int(v : Double) -> Bool {
  !(v == 0.0 && 1.0 / v < 0.0) && v >= 0.0 && v == @math.floor(v) && v <= 9007199254740991.0
}

///|
fn hex_nibble(n : Int) -> Char {
  if n < 10 {
    (0x30 + n).unsafe_to_char()
  } else {
    (0x61 + n - 10).unsafe_to_char()
  }
}

///|
fn hex_byte_index(s : String) -> Int {
  let hi = s.unsafe_charcode_at(0)
  let lo = s.unsafe_charcode_at(1)
  let h = if hi >= 0x30 && hi <= 0x39 { hi - 0x30 } else { hi - 0x61 + 10 }
  let l = if lo >= 0x30 && lo <= 0x39 { lo - 0x30 } else { lo - 0x61 + 10 }
  h * 16 + l
}

///|
fn bucket_name(idx : Int) -> String {
  let out = StringBuilder::new(size_hint=2)
  out.write_char(hex_nibble(idx / 16))
  out.write_char(hex_nibble(idx % 16))
  out.to_string()
}

///|
/// Encodes `(chunk_hash, comp_size)` pairs into a canonical 2-level 256-bucket manifest.
pub fn encode_transcript_manifest(entries : Array[(String, Double)]) -> EncodedManifest raise {
  let grouped : Array[Array[(String, Double)]] = Array::makei(256, _ => [])
  let seen : Set[String] = Set([])
  let mut total_entries = 0
  for e in entries {
    let (h, sz) = e
    if !hash_ok(h) {
      fail("invalid transcript chunk hash: \{h}")
    }
    if !non_neg_safe_int(sz) {
      fail("invalid transcript chunk size for \{h}")
    }
    if seen.contains(h) {
      fail("duplicate transcript chunk hash: \{h}")
    }
    seen.add(h)
    total_entries += 1
    if total_entries > manifest_max_entries {
      fail("transcript manifest exceeds max entries (\{manifest_max_entries})")
    }
    grouped[hex_byte_index(h)].push((h, sz))
  }
  let buckets : Array[(String, String)] = []
  let leaves : Array[(String, String, Bytes)] = []
  let mut total_bytes = 0
  for idx in 0..<256 {
    let list = grouped[idx]
    if list.length() == 0 {
      continue
    }
    list.sort_by((a, b) => compare_units(a.0, b.0))
    let b = bucket_name(idx)
    let sb = StringBuilder::new()
    sb.write_string("{\"v\":1,\"files\":{")
    for i, item in list {
      if i > 0 {
        sb.write_char(',')
      }
      sb.write_char('"')
      sb.write_string(item.0)
      sb.write_string("\":")
      sb.write_string(item.1.to_int64().to_string())
    }
    sb.write_string("}}")
    let leaf_bytes = @utf8.encode(sb.to_string())
    total_bytes += leaf_bytes.length()
    if total_bytes > manifest_max_bytes {
      fail("transcript manifest exceeds max bytes (\{manifest_max_bytes})")
    }
    let leaf_hash = @hash.sha256_hex(leaf_bytes[:])
    buckets.push((b, leaf_hash))
    leaves.push((b, leaf_hash, leaf_bytes))
  }
  let rsb = StringBuilder::new()
  rsb.write_string("{\"v\":1,\"buckets\":{")
  for i, item in buckets {
    if i > 0 {
      rsb.write_char(',')
    }
    rsb.write_char('"')
    rsb.write_string(item.0)
    rsb.write_string("\":\"")
    rsb.write_string(item.1)
    rsb.write_char('"')
  }
  rsb.write_string("}}")
  let root_bytes = @utf8.encode(rsb.to_string())
  total_bytes += root_bytes.length()
  if total_bytes > manifest_max_bytes {
    fail("transcript manifest exceeds max bytes (\{manifest_max_bytes})")
  }
  let root_hash = @hash.sha256_hex(root_bytes[:])
  { root_hash, root_bytes, buckets, leaves }
}

///|
/// Strict JSON parser for manifests that rejects duplicate keys, `-0`, non-integer / scientific / out-of-safe-range numbers,
/// extra tokens, invalid escapes, and enforces depth-1 entry limits during parsing before materializing oversized objects.
priv struct StrictManifestParser {
  text : String
  mut at : Int
  mut depth1_entries : Int
  max_depth1_entries : Int
  depth1_limit_msg : String
}

///|
priv enum MVal {
  MNum(Double)
  MStr(String)
  MObj(Array[(String, MVal)])
}

///|
fn StrictManifestParser::peek(self : StrictManifestParser) -> Int {
  if self.at < self.text.length() {
    self.text.unsafe_charcode_at(self.at)
  } else {
    -1
  }
}

///|
fn StrictManifestParser::skip(self : StrictManifestParser) -> Unit {
  while self.peek() is (0x20 | 0x09 | 0x0a | 0x0d) {
    self.at += 1
  }
}

///|
fn StrictManifestParser::hex_digit(c : Int) -> Int {
  if c >= 0x30 && c <= 0x39 {
    c - 0x30
  } else if c >= 0x61 && c <= 0x66 {
    c - 0x61 + 10
  } else if c >= 0x41 && c <= 0x46 {
    c - 0x41 + 10
  } else {
    -1
  }
}

///|
fn StrictManifestParser::string(self : StrictManifestParser) -> String raise {
  if self.peek() != 0x22 {
    fail("expected '\"' at \{self.at}")
  }
  self.at += 1
  let start = self.at
  let mut end = self.at
  let mut has_escape = false
  while end < self.text.length() {
    let c = self.text.unsafe_charcode_at(end)
    if c == 0x22 {
      break
    }
    if c == 0x5c {
      has_escape = true
      end += 2
    } else {
      if !has_escape && c < 0x20 {
        fail("unescaped control char at \{end}")
      }
      end += 1
    }
  }
  if !has_escape && end < self.text.length() && self.text.unsafe_charcode_at(end) == 0x22 {
    self.at = end + 1
    return self.text.unsafe_substring(start=start, end=end)
  }
  let out = StringBuilder::new()
  while true {
    let c = self.peek()
    if c < 0 || c < 0x20 {
      fail("unterminated or invalid string at \{self.at}")
    }
    self.at += 1
    if c == 0x22 {
      break
    }
    if c != 0x5c {
      out.write_char(c.unsafe_to_char())
      continue
    }
    let e = self.peek()
    self.at += 1
    match e {
      0x22 | 0x5c | 0x2f => out.write_char(e.unsafe_to_char())
      0x62 => out.write_char('\u{08}')
      0x66 => out.write_char('\u{0c}')
      0x6e => out.write_char('\n')
      0x72 => out.write_char('\r')
      0x74 => out.write_char('\t')
      0x75 => {
        let mut v = 0
        for _ in 0..<4 {
          let h = StrictManifestParser::hex_digit(self.peek())
          if h < 0 {
            fail("invalid \\u escape at \{self.at}")
          }
          v = v * 16 + h
          self.at += 1
        }
        out.write_char(v.unsafe_to_char())
      }
      _ => fail("invalid escape at \{self.at}")
    }
  }
  out.to_string()
}

///|
/// Accepts only strict non-negative decimal integers (`0` or `[1-9][0-9]*`) within `[0, 9007199254740991]`.
fn StrictManifestParser::number(self : StrictManifestParser) -> Double raise {
  let start = self.at
  let first = self.peek()
  if first == 0x30 {
    self.at += 1
    let next = self.peek()
    if (next >= 0x30 && next <= 0x39) || next is (0x2e | 0x65 | 0x45) {
      fail("invalid integer in manifest at \{start}")
    }
    return 0.0
  }
  if first < 0x31 || first > 0x39 {
    fail("invalid integer in manifest at \{start}")
  }
  let mut acc : Int64 = 0L
  let max_safe : Int64 = 9007199254740991L
  while true {
    let c = self.peek()
    if c < 0x30 || c > 0x39 {
      break
    }
    let d = (c - 0x30).to_int64()
    if acc > (max_safe - d) / 10L {
      fail("integer out of safe range in manifest at \{start}")
    }
    acc = acc * 10L + d
    self.at += 1
  }
  if self.peek() is (0x2e | 0x65 | 0x45) {
    fail("invalid integer in manifest at \{start}")
  }
  acc.to_double()
}

///|
fn StrictManifestParser::value(self : StrictManifestParser, depth : Int) -> MVal raise {
  if depth > 2 {
    fail("manifest JSON nesting too deep")
  }
  self.skip()
  let c = self.peek()
  if c == 0x7b {
    if depth >= 2 {
      fail("manifest JSON nesting too deep")
    }
    self.at += 1
    let entries : Array[(String, MVal)] = []
    let seen : Set[String] = Set([])
    self.skip()
    if self.peek() == 0x7d {
      self.at += 1
      return MObj(entries)
    }
    let mut count = 0
    while true {
      self.skip()
      let key = self.string()
      if seen.contains(key) {
        fail("duplicate JSON key: \{key}")
      }
      seen.add(key)
      count += 1
      if depth == 0 && count > 2 {
        fail("manifest JSON top-level object has too many keys")
      }
      if depth == 1 {
        self.depth1_entries += 1
        if self.depth1_entries > self.max_depth1_entries {
          fail(self.depth1_limit_msg)
        }
      }
      self.skip()
      if self.peek() != 0x3a {
        fail("expected ':' at \{self.at}")
      }
      self.at += 1
      let v = self.value(depth + 1)
      entries.push((key, v))
      self.skip()
      let next = self.peek()
      if next == 0x2c {
        self.at += 1
        continue
      }
      if next == 0x7d {
        self.at += 1
        return MObj(entries)
      }
      fail("expected ',' or '}' at \{self.at}")
    }
    MObj(entries)
  } else if c == 0x22 {
    MStr(self.string())
  } else if c >= 0x30 && c <= 0x39 {
    MNum(self.number())
  } else {
    fail("unexpected token in manifest JSON at \{self.at}")
  }
}

///|
fn parse_strict_manifest_obj(
  bytes : Bytes,
  max_depth1_entries : Int,
  depth1_limit_msg : String,
) -> Array[(String, MVal)] raise {
  let text = @utf8.decode(bytes[:]) catch { _ => fail("invalid UTF-8 in manifest") }
  let p : StrictManifestParser = { text, at: 0, depth1_entries: 0, max_depth1_entries, depth1_limit_msg }
  let v = p.value(0)
  p.skip()
  if p.at != p.text.length() {
    fail("unexpected trailing token in manifest JSON at \{p.at}")
  }
  match v {
    MObj(entries) => entries
    _ => fail("manifest JSON must be an object")
  }
}

///|
/// Validates and parses a root manifest against `expected_hash` and anti-bomb byte limits.
pub fn parse_root_manifest(bytes : Bytes, expected_hash : String, budget_bytes : Ref[Int]) -> Array[(String, String)] raise {
  if !hash_ok(expected_hash) {
    fail("invalid manifest root hash: \{expected_hash}")
  }
  let next_bytes = budget_bytes.val + bytes.length()
  if next_bytes > manifest_max_bytes {
    fail("transcript manifest exceeds max bytes (\{manifest_max_bytes})")
  }
  budget_bytes.val = next_bytes
  let actual = @hash.sha256_hex(bytes[:])
  if actual != expected_hash {
    fail("manifest root hash mismatch: expected \{expected_hash}, got \{actual}")
  }
  let entries = parse_strict_manifest_obj(
    bytes,
    manifest_max_buckets,
    "manifest root exceeds max buckets (\{manifest_max_buckets})",
  )
  if entries.length() != 2 {
    fail("manifest root must have only keys 'v' and 'buckets'")
  }
  let mut has_v = false
  let mut buckets_val : Array[(String, MVal)]? = None
  for e in entries {
    if e.0 == "v" {
      match e.1 {
        MNum(v) if v == manifest_version.to_double() => has_v = true
        _ => fail("unsupported manifest root version")
      }
    } else if e.0 == "buckets" {
      match e.1 {
        MObj(bs) => buckets_val = Some(bs)
        _ => fail("manifest root 'buckets' must be an object")
      }
    } else {
      fail("unexpected top-level key in manifest root: \{e.0}")
    }
  }
  guard has_v && buckets_val is Some(raw_buckets) else {
    fail("manifest root must have only keys 'v' and 'buckets'")
  }
  if raw_buckets.length() > manifest_max_buckets {
    fail("manifest root exceeds max buckets (\{manifest_max_buckets})")
  }
  let out : Array[(String, String)] = []
  for e in raw_buckets {
    if !hex2_ok(e.0) {
      fail("invalid manifest bucket key: \{e.0}")
    }
    match e.1 {
      MStr(lh) if hash_ok(lh) => out.push((e.0, lh))
      _ => fail("invalid manifest leaf hash for bucket \{e.0}")
    }
  }
  out
}

///|
/// Validates and parses a bucket leaf manifest against `expected_hash`, `expected_bucket`, and anti-bomb limits.
pub fn parse_leaf_manifest(
  bytes : Bytes,
  expected_hash : String,
  expected_bucket : String,
  budget_bytes : Ref[Int],
  budget_entries : Ref[Int],
) -> Array[(String, Double)] raise {
  if !hash_ok(expected_hash) {
    fail("invalid manifest leaf hash: \{expected_hash}")
  }
  if !hex2_ok(expected_bucket) {
    fail("invalid manifest bucket: \{expected_bucket}")
  }
  let next_bytes = budget_bytes.val + bytes.length()
  if next_bytes > manifest_max_bytes {
    fail("transcript manifest exceeds max bytes (\{manifest_max_bytes})")
  }
  budget_bytes.val = next_bytes
  let actual = @hash.sha256_hex(bytes[:])
  if actual != expected_hash {
    fail("manifest leaf hash mismatch: expected \{expected_hash}, got \{actual}")
  }
  let remaining_entries = if manifest_max_entries > budget_entries.val {
    manifest_max_entries - budget_entries.val
  } else {
    0
  }
  let entries = parse_strict_manifest_obj(
    bytes,
    remaining_entries,
    "transcript manifest exceeds max entries (\{manifest_max_entries})",
  )
  if entries.length() != 2 {
    fail("manifest leaf must have only keys 'v' and 'files'")
  }
  let mut has_v = false
  let mut files_val : Array[(String, MVal)]? = None
  for e in entries {
    if e.0 == "v" {
      match e.1 {
        MNum(v) if v == manifest_version.to_double() => has_v = true
        _ => fail("unsupported manifest leaf version")
      }
    } else if e.0 == "files" {
      match e.1 {
        MObj(fs) => files_val = Some(fs)
        _ => fail("manifest leaf 'files' must be an object")
      }
    } else {
      fail("unexpected top-level key in manifest leaf: \{e.0}")
    }
  }
  guard has_v && files_val is Some(raw_files) else {
    fail("manifest leaf must have only keys 'v' and 'files'")
  }
  let out : Array[(String, Double)] = []
  for e in raw_files {
    budget_entries.val += 1
    if budget_entries.val > manifest_max_entries {
      fail("transcript manifest exceeds max entries (\{manifest_max_entries})")
    }
    if !hash_ok(e.0) {
      fail("invalid chunk hash in manifest leaf: \{e.0}")
    }
    if e.0.view(end_offset=2).to_string() != expected_bucket {
      fail("chunk hash \{e.0} does not match bucket \{expected_bucket}")
    }
    match e.1 {
      MNum(sz) if non_neg_safe_int(sz) => out.push((e.0, sz))
      _ => fail("invalid chunk size in manifest leaf for \{e.0}")
    }
  }
  out
}

///|
async fn read_manifest_file_checked(host : @host.Host, files : Files, path : String, remaining_bytes : Int) -> Bytes {
  guard files.meta(path) is Some((size, _)) else {
    fail("ENOENT: manifest object missing at \{path}")
  }
  if size < 0.0 || size > remaining_bytes.to_double() {
    fail("transcript manifest exceeds max bytes (\{manifest_max_bytes})")
  }
  let len = size.to_int()
  if len == 0 {
    return b""
  }
  guard host.read_bytes(path, from=0, length=len) is Some(bytes) else {
    fail("failed to read manifest object at \{path}")
  }
  bytes
}

///|
/// Verifies a full 2-level manifest rooted at `root_hash` inside `dir` (e.g. `<restore>/copy/files`).
pub async fn verify_manifest_dir(host : @host.Host, files : Files, dir : String, root_hash : String) -> Array[(String, Double)] {
  let budget_bytes = Ref(0)
  let budget_entries = Ref(0)
  let root_bytes = read_manifest_file_checked(host, files, files.join([dir, root_hash]), manifest_max_bytes)
  let buckets = parse_root_manifest(root_bytes, root_hash, budget_bytes)
  let all : Array[(String, Double)] = []
  for b in buckets {
    let remaining = manifest_max_bytes - budget_bytes.val
    let leaf_bytes = read_manifest_file_checked(host, files, files.join([dir, b.1]), remaining)
    let leaf_files = parse_leaf_manifest(leaf_bytes, b.1, b.0, budget_bytes, budget_entries)
    for f in leaf_files {
      all.push(f)
    }
  }
  all
}
