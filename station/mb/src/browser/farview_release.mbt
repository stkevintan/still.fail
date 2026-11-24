// Farview's release (src/browser/farview-release.ts; AFK-surf/farview-legacy's `tools/package.sh`: bin/host.exe,
// bin/agent.exe, lib/), got by a station that has it nowhere else: where config.json names no directory of its own, a
// station on a system Farview is built for takes the release this station's version names (its commit, as
// apps/mbui/farview.pin pins the client the app draws its tabs with, and the SHA-256 of its tarball), downloaded the
// first time a chat's Farview is started, its digest checked before anything of it is unpacked, and kept in the
// machine's cache of native parts. Farview is private: its releases are that repository's own (the release `builds`),
// got with the machine's `gh` (the lead, 2026-11-16); then still.fail's store of native parts and the release
// `native-artifacts` of AFK-surf/monoid.

///|
/// A release of Farview's: the commit it was built from and its tarball's SHA-256.
pub(all) struct FarviewRelease {
  rev : String
  sha256 : String
}

///|
/// The release a station of this version takes, by the system it runs on (`<os>-<arch>`). Its commit is the one
/// apps/mbui/farview.pin names (test/farview-release.test.ts holds them together).
pub fn farview_releases() -> Array[(String, FarviewRelease)] {
  [
    (
      "darwin-arm64",
      {
        rev: "29078d90f4351482fcd30a4afb4c7c545d8be37e",
        sha256: "6123f7df492a2d9d56729fa4defad4ac7930dc17e1aa4e3cd20ebf241cf53ab7",
      },
    ),
    (
      "linux-x64",
      {
        rev: "29078d90f4351482fcd30a4afb4c7c545d8be37e",
        sha256: "eaa82500b0e6b7b643ad83ac31c4edc3a2fb12c148d2d650f230bac9bc6c90c8",
      },
    ),
    (
      "linux-arm64",
      {
        rev: "29078d90f4351482fcd30a4afb4c7c545d8be37e",
        sha256: "5aff264c70cb40fb0135de607a12e4ea6b05061c325f76d2e30757150acd50c5",
      },
    ),
  ]
}

///|
/// The system a station runs on, as the releases name them (`other` for an OS no build names).
pub fn farview_target(build_os : String?, arch : String) -> String {
  "\{build_os.unwrap_or("other")}-\{arch}"
}

///|
/// The tarball's name, in the store and the release alike.
pub fn farview_asset(target : String, release : FarviewRelease) -> String {
  "farview-\{target}-\{slice(release.rev, 0, b=12)}.tar.gz"
}

///|
/// Where a release is kept, unpacked (bin/host.exe in it), under the machine's cache of native parts.
pub fn farview_cache_dir(native_cache : String, target : String, release : FarviewRelease) -> String {
  pjoin([native_cache, "farview", "\{slice(release.rev, 0, b=12)}-\{target}"])
}

///|
/// Where a release's tarball is asked for, in turn: each of $STILLFAIL_FARVIEW_SOURCES (comma-separated: an address the
/// name goes after, or `gh:<owner>/<repo>@<tag>`, a release `gh` downloads), else Farview's own release (`gh`),
/// still.fail's store of native parts and the GitHub release of them.
pub fn farview_sources(name : String, env : Map[String, String]) -> Array[String] {
  let said = env
    .get("STILLFAIL_FARVIEW_SOURCES")
    .unwrap_or("")
    .split(",")
    .map(s => trim(s.to_string()))
    .filter(s => s != "")
    .collect()
  if said.length() > 0 {
    return said.map(s => "\{s}/\{name}")
  }
  let store = env.get("STILLFAIL_NATIVE_STORE").unwrap_or("https://app.still.fail/releases/natives")
  let repo = env.get("STILLFAIL_NATIVE_REPO").unwrap_or("AFK-surf/monoid")
  let release = env.get("STILLFAIL_NATIVE_RELEASE").unwrap_or("native-artifacts")
  [
    "gh:AFK-surf/farview-legacy@builds/\{name}", "\{store}/\{name}", "https://github.com/\{repo}/releases/download/\{release}/\{name}",
  ]
}

///|
fn no_space(s : String) -> Bool {
  for i in 0..<s.length() {
    if @jscase.is_space(s.unsafe_charcode_at(i)) {
      return false
    }
  }
  true
}

///|
/// A `gh:<owner>/<repo>@<tag>/<name>` source as `gh release download` takes it (repo, tag, name); None for any other.
pub fn gh_source(url : String) -> (String, String, String)? {
  if !url.has_prefix("gh:") {
    return None
  }
  let rest = slice(url, 3)
  let at_ = index_of(rest, "@")
  if at_ < 0 {
    return None
  }
  let repo = slice(rest, 0, b=at_)
  let after = slice(rest, at_ + 1)
  let rparts = repo.split("/").map(p => p.to_string()).collect()
  let aparts = after.split("/").map(p => p.to_string()).collect()
  if rparts.length() != 2 || aparts.length() != 2 {
    return None
  }
  for p in rparts + aparts {
    if p == "" || !no_space(p) {
      return None
    }
  }
  Some((repo, aparts[0], aparts[1]))
}

///|
/// The SHA-256 of `b`, in lowercase hex.
pub fn sha256_of(b : Bytes) -> String {
  @hash.sha256_hex(b)
}

///|
/// What unpacking a release asks of the machine besides its files: a tarball's bytes written, a gzip'd tar unpacked
/// (`tar -xzf <tgz> -C <out>`), random bytes in hex.
pub(all) struct ReleaseIo {
  write_bytes : async (String, Bytes) -> Unit
  untar : async (String, String) -> Unit
  random_hex : (Int) -> String
}

///|
/// Release `release` for `target` unpacked at `dir`, got from `sources` in turn where it is not there yet: a tarball
/// whose SHA-256 is not the release's is refused (and the next source asked), nothing of it unpacked. Unpacked beside
/// `dir` and moved there whole, so a station that stops half way, or another that unpacks it too, leaves no half of one
/// where it is looked for.
pub async fn unpack_release(
  dir : String,
  target : String,
  release : FarviewRelease,
  sources : Array[String],
  get : async (String) -> Bytes?,
  files : Files,
  io : ReleaseIo,
) -> Unit {
  let host_exe = (d : String) => pjoin([d, "bin", "host.exe"])
  if (files.exists)(host_exe(dir)) {
    return
  }
  let name = farview_asset(target, release)
  let refused = []
  let mut bytes : Bytes? = None
  for url in sources {
    guard get(url) is Some(got) else { continue }
    let sha = sha256_of(got)
    if sha == release.sha256 {
      bytes = Some(got)
      break
    }
    refused.push("\{url} (SHA-256 \{sha}, not \{release.sha256})")
  }
  guard bytes is Some(got) else {
    raise fail_(
      if refused.length() > 0 {
        "Farview's release \{name} was refused: \{refused.join("; ")}"
      } else {
        "Farview's release \{name} could not be downloaded (\{sources.join(", ")}): say where an unpacked one is in config.json `browser.farview`, or `browser.farview: false` for Chrome alone."
      },
    )
  }
  let parent = pjoin([dir, ".."])
  (files.mkdir)(parent, 0o777)
  let work = pjoin([parent, ".\{name}.\{(io.random_hex)(6)}"])
  (files.mkdir)(work, 0o777)
  let r = attempt(async fn() {
    let tgz = pjoin([work, name])
    (io.write_bytes)(tgz, got)
    let out = pjoin([work, "out"])
    (files.mkdir)(out, 0o777)
    (io.untar)(tgz, out)
    // (the tarball holds the release in a directory of its own: farview-macos-arm64/bin/host.exe)
    let mut root = out
    if !(files.exists)(host_exe(out)) {
      let inner = (files.readdir)(out).filter(n => !n.has_prefix("."))
      if inner.length() != 1 {
        raise fail_("Farview's release \{name} holds no bin/host.exe")
      }
      root = pjoin([out, inner[0]])
      if !(files.exists)(host_exe(root)) {
        raise FsError("ENOENT", "ENOENT: no such file or directory, access '\{host_exe(root)}'")
      }
    }
    match attempt(async fn() { (files.rename)(root, dir) }) {
      Ok(_) => ()
      // (another station process unpacked it meanwhile: theirs is the same release)
      Err(e) => if !(files.exists)(host_exe(dir)) { raise e }
    }
  })
  (files.rm)(work, true) catch {
    _ => ()
  }
  match r {
    Ok(_) => ()
    Err(e) => raise e
  }
}
