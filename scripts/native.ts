// The native parts the TypeScript station and clients use, prebuilt: each one
// is named by a key, the hash of all that goes into it (its sources, as git has them, not its tests, and every vendored
// crate it uses; its Cargo.lock; the Rust toolchain; the target; how it is built), and found, in this order, in
//   1. the cache on this machine, which every worktree shares: ~/Library/Caches/stillfail-native (macOS),
//      $XDG_CACHE_HOME/stillfail-native or ~/.cache/stillfail-native (Linux), %LOCALAPPDATA%\stillfail-native (Windows),
//      or $STILLFAIL_NATIVE_CACHE;
//   2. $STILLFAIL_NATIVE_INBOX, a directory of artifacts (CI: those a branch's natives job built, as a run artifact);
//   3. the release `native-artifacts` of AFK-surf/monoid on GitHub (public: plain HTTPS, no login), which CI
//      publishes to from main;
//   4. built here, from the checkout (and said so).
// So an everyday build or test compiles no Rust; only a change to a part's own sources builds it, once per machine.
//
//   node scripts/native.ts path <part> [target]        where it is (a directory), getting or building it first
//   node scripts/native.ts file <part> [target]        its main file (mesh.node, stillfail-runner, …)
//   node scripts/native.ts file-key <part> <target> <key>  a prebuilt part by its already computed key (never builds)
//   node scripts/native.ts key <part> [target]         its key
//   node scripts/native.ts fetch <part> [target]       into the cache, never building (fails when not prebuilt)
//   node scripts/native.ts build <part> [target]       built here, into the cache, whatever is there
//   node scripts/native.ts trim                        the cache within STILLFAIL_NATIVE_CACHE_MAX_BYTES (unset: 10 GiB)
//   node scripts/native.ts run <part>… -- <command…>   the command, with each part's variable set (STILLFAIL_MESH_NATIVE, …)
//   node scripts/native.ts iroh-pkg [dir]              the web's iroh (iroh-wasm) put in web/src/core/iroh-pkg
//   node scripts/native.ts status                      every part and target: key, and whether cached / published
//   node scripts/native.ts missing [--windows] [--mac] [--linux] [part[:target]…]    those (default: all of ours) the release
//        and the store lack, one a line: every flag's and every part named, each once
//   node scripts/native.ts parts [--windows|--mac|--linux]      what missing and ensure take by default, one a line
//   node scripts/native.ts missing --prebuilt          the prebuilt ones (`msvc`: the shell and engine, Android's,
//        Windows' and Linux', which the mbui app's jobs only fetch; `prebuilt`: ghostty-vt) in neither the store nor
//        the release, one a line
//   node scripts/native.ts ensure [--windows] [--publish] [--outbox DIR] [part[:target]…]
//        CI: each (default: all) in the cache, built when not prebuilt; --publish uploads what the release and the
//        store lack (gh, main only), then prunes those parts and targets to the newest 20; --outbox copies the artifacts the
//        release lacks there (a branch's run artifact)
//        The default leaves out what only Windows builds (MSVC's: the mbui app's shell and engine); --windows is those.
//        Never what only Linux builds (the mbui app's Linux shell and engine: the prebuild workflow's alone), nor
//        what is built only by hand (`prebuilt`: ghostty-vt, prebuild --release on a Mac).
//   node scripts/native.ts prune [N]                   the release keeps the newest N (20) of each part and target
//   node scripts/native.ts prebuild [--release] [part:target…]   each (default: the Windows parts) in neither the store
//        (STORE: the releases bucket's natives/) nor the release, got or built here (Windows builds the Windows ones, a
//        Mac cross-builds them), then put in the store (scripts/release-put.sh: CLOUDFLARE_API_TOKEN, the releases
//        bucket's), for CI to fetch. CI builds those (`msvc`) only when asked, in the prebuild workflow
//        (.github/workflows/prebuild.yml, run by hand); its other jobs fetch them, or fail saying to run it.
//        --release: in the release native-artifacts instead (gh), which native.ts fetches from after the store (the
//        workflow's, and a machine's without the bucket's token).
//   node scripts/native.ts store-sync                  CI on main: each prebuilt part at its key that the release has and
//        the store lacks, copied there (release-put.sh, CLOUDFLARE_API_TOKEN); never built. (Every part, not only the
//        Windows ones: the release's download answered GitHub's runners 504 again and again on 2026-11-08, iroh-wasm's,
//        failing every branch's bundle, static and check-linux; the store is asked first. And the readers: the release
//        keeps 20 of a part, a few hours of main's, so a stable release of the day before found its readers gone and
//        built all four in its station job, past its 10 minutes. scripts/release-prune.ts deletes a reader there after
//        14 days. Not reader-harness, the tests' alone.)
//
// STILLFAIL_NATIVE=build never downloads (builds what the cache lacks); STILLFAIL_NATIVE=offline neither downloads nor
// builds. Builds go to $CARGO_TARGET_DIR/native/<part> when it is set (station crates add the target to the part),
// else the crate's own target/ (a worktree's own:
// a vendored crate built from two checkouts in one target confuses rustc, docs/operations.md).
import { execFileSync, spawn, spawnSync, type SpawnSyncOptions } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { Resolver } from "node:dns/promises";
import {
  copyFileSync, existsSync, lstatSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync,
} from "node:fs";
import { homedir, hostname, platform as osPlatform, arch as osArch, tmpdir } from "node:os";
import { request as httpsRequest } from "node:https";
import { basename, delimiter, dirname, join, resolve } from "node:path";
import { Readable } from "node:stream";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
/// The Rust every part is built with (rustup installs it on first use): part of each key, so a newer one is a rebuild.
const TOOLCHAIN = "1.95.0";
/// The NDK and the lowest Android API the app supports.
const NDK = "28.2.13676358";
const ANDROID_API = 29;
/// zig, for the Linux builds from a Mac (cargo-zigbuild): only its own version builds what gets published.
const ZIG = "0.16.0";
const REPO = process.env.STILLFAIL_NATIVE_REPO ?? "AFK-surf/monoid";
const RELEASE = process.env.STILLFAIL_NATIVE_RELEASE ?? "native-artifacts";
/// The store of the parts prebuilt on a development machine (`prebuild`): the releases bucket's natives/, served by
/// still.fail cloud (install.ts releaseType) to anyone, as the release is by GitHub.
const STORE = process.env.STILLFAIL_NATIVE_STORE ?? "https://app.still.fail/releases/natives";
/// GitHub and its API, where the release is (others only for scripts/native-download-test.mjs's server of its own).
const GITHUB = process.env.STILLFAIL_NATIVE_GITHUB ?? "https://github.com";
const GITHUB_API = process.env.STILLFAIL_NATIVE_GITHUB_API ?? "https://api.github.com";

/// the CI Mac's CI may resolve the release store directly, just as release-put.sh does for Cloudflare's API. Keep the
/// original Host and TLS name, and leave GitHub and any other store or redirect to the machine's usual routing.
export async function fetchNative(at: string, init: RequestInit = {}, redirects = 0): Promise<Response> {
  const url = new URL(at), dns = process.env.STILLFAIL_DIRECT_DNS;
  if (!dns || url.protocol !== "https:" || url.hostname !== "app.still.fail" || (init.method && init.method !== "GET")) return fetch(at, init);
  if (redirects > 20) throw new Error("too many native store redirects");
  try {
    const resolver = new Resolver();
    resolver.setServers([dns]);
    const abort = () => resolver.cancel();
    init.signal?.addEventListener("abort", abort, { once: true });
    let addresses: string[];
    try {
      init.signal?.throwIfAborted();
      addresses = await resolver.resolve4(url.hostname);
    } finally { init.signal?.removeEventListener("abort", abort); }
    const address = addresses[0];
    if (!address) throw new Error("no IPv4 address for the native store");
    const headers = Object.fromEntries(new Headers(init.headers));
    headers.host = url.host;
    const response = await new Promise<import("node:http").IncomingMessage>((ok, fail) => {
      const request = httpsRequest({ hostname: address, port: url.port || 443, servername: url.hostname,
        path: `${url.pathname}${url.search}`, method: "GET", headers, signal: init.signal ?? undefined }, ok);
      request.on("error", fail);
      request.end();
    });
    const status = response.statusCode ?? 0, location = response.headers.location;
    if ([301, 302, 303, 307, 308].includes(status) && location && init.redirect !== "manual") {
      response.resume();
      if (init.redirect === "error") throw new Error("native store redirected");
      return fetchNative(new URL(location, url).toString(), init, redirects + 1);
    }
    const resultHeaders = new Headers();
    for (const [name, value] of Object.entries(response.headers)) {
      if (Array.isArray(value)) for (const item of value) resultHeaders.append(name, item);
      else if (value !== undefined) resultHeaders.set(name, value);
    }
    const body = [204, 205, 304].includes(status) ? null : Readable.toWeb(response) as ReadableStream<Uint8Array>;
    if (!body) response.resume();
    return new Response(body, { status, headers: resultHeaders });
  } catch (error) {
    if (init.signal?.aborted) throw error;
    log(`direct native store connection failed (${(error as Error).message}); using the usual route`);
    return fetch(at, init);
  }
}
/// still.fail Helper's icon (design/brand/make.py draws it): in its own directory, one of its inputs.
const HELPER_ICON = "station/native/helper/icon.png";
const VENDORED = ["vendor/iroh", "vendor/iroh-mdns-address-lookup", "vendor/n0-mainline", "vendor/noq-udp", "vendor/swarm-discovery"];
/// The Hermes of the core's engine: React Native's `rn` (on Android its hermes-android, libhermes.so and its headers, as
/// apps/mbui/scripts/android-core.sh packs it), and on Windows, which has no prebuilt one with its C++ API,
/// facebook/hermes at the tag that Hermes is made from.
const HERMES = { rn: "0.81.4", tag: "hermes-2025-07-07-RNv0.81.0-e0fc67142ec0763c6b6153ca2bf96df815539782" };
/// How Hermes and the engine are built on Linux: clang, CMake and Ninja, a release with no debugger, position
/// independent (linked into the engine's shared library), ICU the build machine's shared libraries (Ubuntu's: its
/// static ones are not position independent on x86-64, and a shared library cannot take them), carried beside the
/// engine and hermesc (ICU_LINUX), which find them there ($ORIGIN): the same ICU on every distribution whatever it has,
/// as Windows' takes the system's.
const HERMES_LINUX_CMAKE = ["-G", "Ninja", "-DCMAKE_C_COMPILER=clang", "-DCMAKE_CXX_COMPILER=clang++", "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_POSITION_INDEPENDENT_CODE=ON", "-DHERMES_ENABLE_DEBUGGER=OFF", "-DHERMES_ENABLE_TEST_SUITE=OFF", "-DHERMES_USE_STATIC_ICU=OFF", "-DCMAKE_BUILD_RPATH=$ORIGIN", "-DBUILD_SHARED_LIBS=OFF", "-DHERMES_BUILD_SHARED_JSI=OFF"];
/// ICU's libraries the Linux engine carries: Ubuntu 24.04's (the prebuild workflow's), what its build links.
const ICU_LINUX = ["libicuuc.so.74", "libicui18n.so.74", "libicudata.so.74"];
/// How Hermes and the engine are built on Windows: clang-cl (MSVC's own fails on HadesGC.cpp at this tag), CMake and
/// Ninja, as a release with no debugger and the CRT linked in (a clean Windows install need not have VC++ redist).
const HERMES_CMAKE = ["-G", "Ninja", "-DCMAKE_C_COMPILER=clang-cl", "-DCMAKE_CXX_COMPILER=clang-cl", "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_POLICY_DEFAULT_CMP0091=NEW", "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded", "-DCMAKE_CXX_FLAGS=/DWIN32 /D_WINDOWS /W3 /GR /EHsc /D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH", "-DHERMES_ENABLE_DEBUGGER=OFF", "-DHERMES_ENABLE_TEST_SUITE=OFF"];
/// The bsdtar Windows has (Git Bash's GNU tar takes C:\… for a remote host).
const TAR = osPlatform() === "win32" ? join(process.env.SystemRoot ?? "C:\\Windows", "System32", "tar.exe") : "tar";

/// Packages transitively imported by `station/mb/src/reader` (kept in sync with `station/mb/build.sh`
/// and guarded by `station/test/mb-reader-deps-guard.test.ts`). Frozen whole-station packages such as
/// `station_main`, `drive`, `cloud_lock`, `api_routes`, `session_hub` are excluded so edits there
/// never invalidate `stillfail-reader`'s native cache key.
const READER_PKGS = [
  "acp", "activity", "admit", "archivelast", "bindings", "cards", "cc", "claude", "codex", "counts",
  "cursor", "dsh", "footprint", "front", "history", "host", "jobs", "jscase", "jsjson", "legacy",
  "letters", "live_wire", "locate", "lookups", "marks", "memory", "nodepath", "outflow", "packed", "pi",
  "pieces", "posts", "reader", "readops", "recent", "replica", "said", "search", "searchscope", "sessions",
  "shim_plan", "signin", "sql", "turns", "upjobs", "usage", "usagecount", "usagefill", "vaultuses", "widgets", "wire",
];
const READER_COMMON_INPUTS = [
  "station/mb/moon.mod", "station/mb/moon.work", "station/mb/build.sh",
  "libs/base/src", "libs/base/moon.mod",
  "libs/ui/src/effect", "libs/ui/src/halt", "libs/ui/moon.mod",
  "libs/ui/scripts/mbc", "libs/ui/scripts/mbc-stub.sh", "libs/ui/tools/mbc",
  "libs/ui/tools/moon.mod", "libs/ui/tools/moon.work",
  ":(exclude,glob)**/*_test.mbt", ":(exclude,glob)**/*_wbtest.mbt", ":(exclude,glob)**/pkg.generated.mbti",
];
/// Shipped `stillfail-reader`: only its transitive packages, `cprep`, and common MoonBit workspace files.
const READER_INPUTS = [
  ...READER_PKGS.map((p) => `station/mb/src/${p}`),
  "station/mb/src/cprep",
  ...READER_COMMON_INPUTS,
];
/// Tests' `stillfail-reader-harness`: full `station/mb/src` (including frozen `station_main` & harnesses) and `rules/`.
const HARNESS_INPUTS = [
  "station/mb/src", "rules/src", "rules/moon.mod",
  ...READER_COMMON_INPUTS,
];
const readerRecipe = (t: Target) => ({ moon: "native release", shell: t === "darwin-arm64" ? key("shell-apple", t) : key("shell-station", t) });
type Target = "darwin-arm64" | "linux-x64" | "linux-arm64" | "win32-x64" | "wasm32" | "android-arm64" | "ios-arm64" | "ios-sim-arm64";
type Part = {
  /// What the artifact holds.
  files: (target: Target) => string[];
  targets: Target[];
  /// The targets CI publishes (default: all).
  publish?: Target[];
  /// The variable its users read its main file from (`run`).
  env?: string;
  /// What goes into it, as git paths (by target when they differ); and how it is built, as data (both are in the key).
  inputs?: string[] | ((target: Target) => string[]);
  recipe: (target: Target) => unknown;
  /// Built with no Rust: the toolchain is not in its key. With its own zig: that one is (not ZIG).
  rust?: false;
  zig?: string;
  /// Its win32-x64 is MSVC's (clang-cl's), built on a Windows machine, not MinGW's from a Mac: CI's natives-win job.
  msvc?: true;
  /// Built only by hand (`prebuild`), never by CI: a build of all its targets takes longer than a job may (ghostty-vt's
  /// eight, ~10 min), and what it is made of changes only as its pinned release does. CI's jobs fetch it, or fail saying
  /// to prebuild it; `ensure` and `missing` leave it out of their default.
  prebuilt?: true;
  /// Built into `out` (a fresh directory).
  build: (target: Target, out: string) => void;
};

const host = (): Target => {
  const os = osPlatform(), cpu = osArch();
  if (os === "darwin" && cpu === "arm64") return "darwin-arm64";
  if (os === "linux" && cpu === "x64") return "linux-x64";
  if (os === "linux" && cpu === "arm64") return "linux-arm64";
  if (os === "win32" && cpu === "x64") return "win32-x64";
  throw new Error(`no native parts for ${os}-${cpu}`);
};
const TRIPLES: Record<string, string> = {
  "darwin-arm64": "aarch64-apple-darwin",
  "linux-x64": "x86_64-unknown-linux-gnu",
  "linux-arm64": "aarch64-unknown-linux-gnu",
  "win32-x64": "x86_64-pc-windows-gnu",
  "android-arm64": "aarch64-linux-android",
};
const TRIPLE = (t: Target): string => TRIPLES[t] ?? fail(`no Rust target for ${t}`);
const LINUX = (t: Target): boolean => t === "linux-x64" || t === "linux-arm64";
function fail(message: string): never {
  throw new Error(message);
}
const STATION: Target[] = ["darwin-arm64", "linux-x64", "linux-arm64"];
/// The station's own executables: Windows' too ("Windows"), named as it names them.
const STATION_BINS: Target[] = [...STATION, "win32-x64"];
const exe = (name: string) => (t: Target) => (t === "win32-x64" ? `${name}.exe` : name);

/// A Rust crate of its own (station/native/*), for a station platform: Linux from a Mac with cargo-zigbuild, for
/// glibc 2.28 and later (Debian 10, Ubuntu 20.04, RHEL 8 on); Windows with it too, as MinGW's (napi-rs finds Node's
/// symbols in the process at run time, so no MSVC import library is needed). `name`: the file kept, by target.
function stationCrate(dir: string, artifact: (t: Target) => string, name: string | ((t: Target) => string), extra: string[] = []): Part {
  const named = (t: Target) => (typeof name === "string" ? name : name(t));
  return {
    files: (t) => [named(t)],
    targets: STATION,
    inputs: [dir, ...extra],
    recipe: (t) => ({ cargo: cargoCommand(t), artifact: artifact(t), name: named(t) }),
    build(t, out) {
      const target = stationTargetDir(dir, t);
      cargo(cargoCommand(t), join(ROOT, dir), { CARGO_TARGET_DIR: target, ...(t === "win32-x64" ? noLibnode(target) : {}) });
      copyFileSync(join(target, TRIPLE(t), "release", artifact(t)), join(out, named(t)));
    },
  };
}
/// Concurrent station targets must not share Cargo's artifact lock in a CI job.
const stationTargetDir = (dir: string, t: Target) => targetDir(join(ROOT, dir, "target"), `${basename(dir)}-${t}`);

/// napi-build links a MinGW addon to libnode.dll, which Node does not have on Windows: its Node-API is in
/// the executable, and napi-sys (dyn-symbols, its default) looks every function up there when the addon loads. So it
/// is given an empty import library to link (nothing is taken from it) and a libnode.dll to find beside it.
function noLibnode(target: string): Record<string, string> {
  const dir = join(target, "no-libnode");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "libnode.dll"), "");
  writeFileSync(join(dir, "libnode.a"), "!<arch>\n");
  return { LIBNODE_PATH: dir };
}
const cargoCommand = (t: Target, more: string[] = []) =>
  t === "darwin-arm64"
    ? ["build", "--release", "--locked", ...more, "--target", TRIPLE(t)]
    : ["zigbuild", "--release", "--locked", ...more, "--target", t === "win32-x64" ? TRIPLE(t) : `${TRIPLE(t)}.2.28`];

/// The launcher's part: Windows' has its windowless start beside it (station/native/launcher/src/hidden.rs).
function withHidden(part: Part): Part {
  const hidden = "stillfail-station-w.exe";
  return {
    ...part,
    targets: STATION_BINS,
    env: "STILLFAIL_LAUNCHER",
    files: (t) => (t === "win32-x64" ? [...part.files(t), hidden] : part.files(t)),
    build(t, out) {
      part.build(t, out);
      if (t === "win32-x64") copyFileSync(join(stationTargetDir("station/native/launcher", t), TRIPLE(t), "release", hidden), join(out, hidden));
    },
  };
}

/// The Windows screen helper's part: ships its LocalSystem service binary beside stillfail-screen.exe.
function withScreenService(part: Part): Part {
  const svc = "stillfail-screen-svc.exe";
  return {
    ...part,
    targets: ["win32-x64"],
    env: "STILLFAIL_SCREEN",
    files: (t) => [...part.files(t), svc],
    build(t, out) {
      part.build(t, out);
      copyFileSync(join(stationTargetDir("station/native/screen", t), TRIPLE(t), "release", svc), join(out, svc));
    },
  };
}

const MESH_LIB = (t: Target) => (t === "darwin-arm64" ? "libstillfail_mesh.dylib" : t === "win32-x64" ? "stillfail_mesh.dll" : "libstillfail_mesh.so");

/// libghostty-vt (the app's terminal, the runner's copy of one's screen): Ghostty's source and dependency tarballs of a
/// release, whose minisign signatures (Ghostty's key, RWQlAjJC23149WL2sEpT/l0QKy7hMIFhYdQOFy0Z7z7PbneUgvlsnYcV) were
/// checked as the version was taken and whose sha256 is checked here, built with no network (`--system`, the deps) by
/// the zig that release asks for (its build.zig.zon's `minimum_zig_version`: its minor exactly), fetched here by its
/// own sha256 into the build directory, so no machine needs it installed. A static library and the headers; the web's
/// a module (wasm32-freestanding, ReleaseSmall, only what a terminal shown and typed into needs).
const GHOSTTY_VT = {
  version: "1.0.1",
  source: "333dfce97641ef9b536bb9e08907ad86abaaada50e8f7417b70d9284adef37aa",
  deps: "91a4e10960a52bf5bf4b15aa2a2cddaff8a89d6cd903d3055bda4fd17de3356d",
  zig: "0.17.0",
  zigs: {
    "aarch64-macos": "b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a",
    "x86_64-windows": "b5663f69581dcf391293fbf16c06cb80d81d806545ce618b4d0bab7f0eb8c428",
  } as Record<string, string>,
};
/// zig's target of each of ours: macOS and iOS at the shell's oldest (APPLE_MIN), Android at the app's lowest API,
/// Linux for glibc 2.28 on (as the station's crates), Windows MinGW's (the runner's; whether the app's MSVC build links
/// it, or needs one of its own built on Windows, is for when the app's Windows terminal is made).
const GHOSTTY_VT_TARGETS: Partial<Record<Target, string>> = {
  "darwin-arm64": "aarch64-macos.11.0",
  "ios-arm64": "aarch64-ios.17.0",
  "ios-sim-arm64": "aarch64-ios.17.0-simulator",
  "android-arm64": `aarch64-linux-android.${ANDROID_API}`,
  "linux-x64": "x86_64-linux-gnu.2.28",
  "linux-arm64": "aarch64-linux-gnu.2.28",
  "win32-x64": "x86_64-windows-gnu",
  wasm32: "wasm32-freestanding",
};
const GHOSTTY_VT_FLAGS = (t: Target): string[] =>
  t === "wasm32"
    ? ["-Doptimize=ReleaseSmall", "-Dvt-features=-all,+render-state,+input-encode,+selection,+color"]
    : ["-Doptimize=ReleaseFast", "-Dcpu=baseline"];
const ghosttyVtLib = (t: Target) => (t === "wasm32" ? "bin/ghostty-vt.wasm" : t === "win32-x64" ? "lib/ghostty-vt-static.lib" : "lib/libghostty-vt.a");
/// A file fetched into `dir` once, by its sha256.
function fetched(dir: string, url: string, sha256: string): string {
  const file = join(dir, basename(url));
  const sum = (f: string) => createHash("sha256").update(readFileSync(f)).digest("hex");
  if (!existsSync(file) || sum(file) !== sha256) {
    mkdirSync(dir, { recursive: true });
    run("curl", ["-fsSL", "--retry", "5", "--retry-all-errors", url, "-o", `${file}.part`]);
    const got = sum(`${file}.part`);
    if (got !== sha256) throw new Error(`${url}: sha256 ${got}, not ${sha256}`);
    renameSync(`${file}.part`, file);
  }
  return file;
}
function ghosttyVt(): Part {
  const v = GHOSTTY_VT;
  return {
    files: (t) => [ghosttyVtLib(t), ...(t === "wasm32" ? [] : ["include/ghostty/vt.h"])],
    targets: Object.keys(GHOSTTY_VT_TARGETS) as Target[],
    rust: false,
    zig: v.zig,
    prebuilt: true,
    recipe: (t) => ({ version: v.version, source: v.source, deps: v.deps, zig: v.zig, target: GHOSTTY_VT_TARGETS[t], flags: GHOSTTY_VT_FLAGS(t) }),
    build(t, out) {
      const zigHost = osPlatform() === "darwin" && osArch() === "arm64" ? "aarch64-macos" : osPlatform() === "win32" && osArch() === "x64" ? "x86_64-windows" : fail("ghostty-vt is built on an Apple Silicon Mac or on Windows");
      const work = join(BUILD(), "ghostty-vt");
      const at = `https://release.files.ghostty.org/libghostty-vt/${v.version}`;
      const source = fetched(work, `${at}/libghostty-vt-${v.version}.tar.gz`, v.source);
      const deps = fetched(work, `${at}/libghostty-vt-${v.version}-deps.tar.gz`, v.deps);
      const zipped = zigHost === "x86_64-windows";
      const zigArchive = fetched(work, `https://ziglang.org/download/${v.zig}/zig-${zigHost}-${v.zig}.${zipped ? "zip" : "tar.xz"}`, v.zigs[zigHost]!);
      const zig = join(work, `zig-${zigHost}-${v.zig}`, zipped ? "zig.exe" : "zig");
      if (!existsSync(zig)) run(TAR, ["-xf", zigArchive, "-C", work]);
      // (each target from the tarballs anew: zig's build writes into the source's own .zig-cache)
      const src = join(work, `src-${t}`);
      rmSync(src, { recursive: true, force: true });
      mkdirSync(src, { recursive: true });
      run(TAR, ["-xzf", source, "-C", src]);
      run(TAR, ["-xzf", deps, "-C", src]);
      run(zig, ["build", "--prefix", out, "--system", join(src, `libghostty-vt-${v.version}-deps`), `-Dtarget=${GHOSTTY_VT_TARGETS[t]}`, ...GHOSTTY_VT_FLAGS(t)], {
        cwd: join(src, `libghostty-vt-${v.version}`),
        env: { ...process.env, ZIG_GLOBAL_CACHE_DIR: join(work, "zig-cache") },
      });
      rmSync(src, { recursive: true, force: true });
    },
  };
}

/// A crate that links libghostty-vt where it is made for macOS, Linux or Windows: that build of it is in its key, and
/// its build is told where it is (GHOSTTY_VT_DIR, which the crate's build.rs reads).
function withGhosttyVt(part: Part): Part {
  const linked = (t: Target) => t === "darwin-arm64" || LINUX(t) || t === "win32-x64";
  return {
    ...part,
    recipe: (t) => ({ ...(part.recipe(t) as object), ...(linked(t) ? { ghosttyVt: key("ghostty-vt", t) } : {}) }),
    build(t, out) {
      const before = process.env.GHOSTTY_VT_DIR;
      if (linked(t)) process.env.GHOSTTY_VT_DIR = ensure("ghostty-vt", t);
      try { part.build(t, out); } finally { if (before === undefined) delete process.env.GHOSTTY_VT_DIR; else process.env.GHOSTTY_VT_DIR = before; }
    },
  };
}

/// An mbui offscreen program and its portable launcher. The sources are conservative: a change to an app component or
/// the framework selects a new binary. A separate scene or drive file is never part of the key.
function mbuiRenderer(app: string, launcher: string): Part {
  return {
    files: () => [app, launcher],
    targets: ["darwin-arm64"],
    // Their own workflow tests and publishes them without holding up unrelated native parts.
    publish: [],
    rust: false,
    // Generated interface summaries are not compiler inputs; `moon check` can rewrite them without changing a scene.
    inputs: ["apps/mbui/src", "libs/ui/src", "libs/ui/tools", "libs/ui/scripts",
      "apps/mbui/moon.mod", "apps/mbui/moon.work", "libs/ui/moon.mod",
      "apps/mbui/scripts/env.sh", "apps/mbui/scripts/mbui.sh", "apps/mbui/scripts/mac.sh", `apps/mbui/scripts/${launcher}`,
      ":(exclude,glob)apps/mbui/**/*_test.mbt", ":(exclude,glob)apps/mbui/**/*_wbtest.mbt",
      ":(exclude,glob)apps/mbui/**/pkg.generated.mbti", ":(exclude,glob)libs/ui/**/*_test.mbt",
      ":(exclude,glob)libs/ui/**/*_wbtest.mbt", ":(exclude,glob)libs/ui/**/pkg.generated.mbti"],
    recipe: () => ({ app, target: "native", mode: "release", host: "macOS", scene: 1 }),
    build(t, out) {
      if (t !== "darwin-arm64" || osPlatform() !== "darwin" || osArch() !== "arm64") {
        throw new Error(`${app} is built on an Apple Silicon Mac`);
      }
      const module = join(ROOT, "apps/mbui");
      // (for the macOS the app runs on, as mac-app.sh builds it: left to the host's, Xcode 27's SDK held
      // apple_stream.m's AVAudioEngine connect:to:format: and play deprecated there and the build failed,
      // mbui-media-runtime's film on main b3e22352 43591756793, 2026-11-14)
      run("bash", [join(module, "scripts/mac.sh"), "build"], {
        cwd: module, env: { ...process.env, APP: app, MODE: "release", MACOSX_DEPLOYMENT_TARGET: "12.0" },
      });
      copyFileSync(join(module, `_build/native/release/build/stillfail/${app}/${app}.exe`), join(out, app));
      copyFileSync(join(module, "scripts", launcher), join(out, launcher));
    },
  };
}

/// The same scene in classic Wasm, with the Mac's offscreen text, pictures and Metal renderer. Stills only.
function mbuiWasmFilm(): Part {
  const base = mbuiRenderer("sffilm", "media.sh");
  if (!Array.isArray(base.inputs)) throw new Error("mbui renderer inputs must be a list");
  return {
    ...base,
    files: () => ["sffilm", "media.sh", "scene.wasm", "native.node", "run.mjs", "compact.mjs"],
    inputs: [...base.inputs, "apps/mbui/tools/wasm-film", ":(exclude,glob)apps/mbui/tools/wasm-film/*test.mjs", "apps/mbui/scripts/wasm-film-build.sh"],
    recipe: () => ({ app: "sfwasmfilm", target: "wasm", mode: "release", host: "macOS", scene: 1 }),
    build(t, out) {
      if (t !== "darwin-arm64" || osPlatform() !== "darwin" || osArch() !== "arm64") {
        throw new Error("sfwasmfilm is built on an Apple Silicon Mac");
      }
      const module = join(ROOT, "apps/mbui");
      run("bash", [join(module, "scripts/wasm-film-build.sh"), out], { cwd: module });
    },
  };
}

const PARTS: Record<string, Part> = {
  "mbui-figure": mbuiRenderer("sffigure", "figure-run.sh"),
  "mbui-film": mbuiRenderer("sffilm", "media.sh"),
  "mbui-film-wasm": mbuiWasmFilm(),
  "ghostty-vt": ghosttyVt(),
  // The station's iroh and image codecs, a Node addon ( §3); the core on Node (its tests,
  // apps/mbui's e2e peer) uses it too.
  mesh: {
    ...stationCrate("station/native/mesh", MESH_LIB, "mesh.node", ["client/shell/src/mesh.rs", "libs/mesh-transport/src", "libs/mesh-transport/Cargo.toml", ...VENDORED]),
    targets: STATION_BINS,
    env: "STILLFAIL_MESH_NATIVE",
  },
  // The TypeScript station's launcher (§2) and an agent's runner (§1).
  // On Windows with stillfail-station-w.exe beside it: the launcher as the logon task runs it, with no window.
  launcher: withHidden(stationCrate("station/native/launcher", exe("stillfail-station"), exe("stillfail-station"))),
  // With libghostty-vt linked (macOS, Linux, Windows), the screen of a terminal it keeps (its build.rs, src/ghostty.rs).
  runner: withGhosttyVt({ ...stationCrate("station/native/runner", exe("stillfail-runner"), exe("stillfail-runner")), targets: STATION_BINS, env: "STILLFAIL_RUNNER" }),
  // Windows' display as the station's desktop screen, what still.fail Helper is on macOS,
  // with its optional LocalSystem service binary beside it for UAC / elevated windows / lock screen.
  screen: withScreenService(stationCrate("station/native/screen", () => "stillfail-screen.exe", "stillfail-screen.exe")),
  // Linux's native display capture, OpenH264/JPEG encoding, and input helper.
  "screen-linux": { ...stationCrate("station/native/screen-linux", () => "stillfail-screen-linux", "stillfail-screen-linux"), targets: ["linux-x64", "linux-arm64"], env: "STILLFAIL_SCREEN_LINUX" },
  // For the station's tests: the Rust station's cold storage as a command (test/cold-compat.test.ts), and a member's
  // client asking a station over iroh (tools/load: test/e2e.sh, compare.sh). This machine's only.
  "archive-rs": {
    ...stationCrate("station/test/archive-rs", () => "archive-rs", "archive-rs"),
    env: "ARCHIVE_RS",
    publish: ["darwin-arm64", "linux-x64"],
  },
  "station-load": { ...stationCrate("station/tools/load", () => "station-load", "station-load", VENDORED), env: "E2E_LOAD", publish: ["darwin-arm64"] },
  // The browser's iroh (web/src/core/iroh-pkg): wasm-bindgen's module, by client/iroh-wasm/build.sh.
  "iroh-wasm": {
    files: () => ["stillfail_iroh_wasm.js", "stillfail_iroh_wasm.d.ts", "stillfail_iroh_wasm_bg.wasm", "stillfail_iroh_wasm_bg.wasm.d.ts"],
    targets: ["wasm32"],
    inputs: ["client/iroh-wasm", "libs/mesh-transport/src", "libs/mesh-transport/Cargo.toml", "client/Cargo.toml", "client/Cargo.lock", ...VENDORED],
    recipe: () => ({ script: "client/iroh-wasm/build.sh" }),
    build(_t, out) {
      const target = targetDir(join(ROOT, "client/target"), "iroh-wasm");
      rustTarget("wasm32-unknown-unknown");
      run("sh", [join(ROOT, "client/iroh-wasm/build.sh"), out], { env: rustEnv({ CARGO_TARGET_DIR: target }) });
      for (const f of ["built.js", "built.d.ts"]) rmSync(join(out, f), { force: true });
    },
  },
  // The core's native shell (client/shell): HTTP, the cloud's socket, files, SQLite and iroh, behind a C ABI. Android's,
  // and the mbui app's on Windows (MSVC's: a DLL and its import library, which the engine links) and Linux (a shared
  // library the app links beside the engine).
  shell: {
    // Windows': with its tests, built beside it, for a Windows machine to run (CI's natives-win)
    files: (t) => (t === "win32-x64" ? ["stillfail_shell.dll", "stillfail_shell.dll.lib", "tests"] : ["libstillfail_shell.so"]),
    targets: ["android-arm64", "win32-x64", "linux-x64", "linux-arm64"],
    msvc: true,
    inputs: ["client/shell", "libs/mesh-transport/src", "libs/mesh-transport/Cargo.toml", "client/Cargo.toml", "client/Cargo.lock", "vendor/libadb", ...VENDORED],
    recipe: (t) =>
      t === "win32-x64" ? { cargo: SHELL_TESTS, rustflags: SHELL_WIN_RUSTFLAGS, xwin: XWIN }
      : LINUX(t) ? { cargo: shellLinux(t) }
      : { ndk: NDK, api: ANDROID_API, cargo: shellCommand(), rustflags: SHELL_RUSTFLAGS },
    build(t, out) {
      const target = targetDir(join(ROOT, "client/target"), "shell");
      if (t === "win32-x64") return shellWin(out);
      if (LINUX(t)) return shellLinuxBuild(t, target, out);
      cargo(shellCommand(), join(ROOT, "client"), { CARGO_TARGET_DIR: target, ...ndkEnv() });
      copyFileSync(join(target, "aarch64-linux-android/release/libstillfail_shell.so"), join(out, "libstillfail_shell.so"));
    },
  },
  // The station's reader in MoonBit (station/mb: read/mb-reader.ts), for every station: its C made by moon, compiled
  // and linked for each target (station/mb/build.sh: zig for Linux and Windows, on a Mac or a Linux x86-64 machine),
  // with the shell's static library for it (shell-apple's on the Mac, shell-station's elsewhere: its key in this one's).
  reader: {
    files: (t) => [exe("stillfail-reader")(t)],
    targets: STATION_BINS,
    env: "STILLFAIL_MB_READER",
    rust: false,
    inputs: READER_INPUTS,
    recipe: readerRecipe,
    build(t, out) {
      const mac = osPlatform() === "darwin" && osArch() === "arm64";
      const linux = osPlatform() === "linux" && osArch() === "x64";
      if (!mac && !(linux && t !== "darwin-arm64")) {
        throw new Error(`the reader for ${t} is built on an Apple Silicon Mac${t !== "darwin-arm64" ? " or a Linux x86-64 machine" : ""}`);
      }
      const shell = ensure(t === "darwin-arm64" ? "shell-apple" : "shell-station", t);
      run("bash", [join(ROOT, "station/mb/build.sh"), t, join(out, exe("stillfail-reader")(t))], { env: { ...process.env, SHELL_LIB: join(shell, "libstillfail_shell.a") } });
    },
  },
  // The tests' program beside it (station/mb/src/reader_harness: every package's harness, `--builder harness-*`, which
  // station/test/mb-*.test.ts hold to the TypeScript), kept out of the reader every station runs: built as it is
  // (build.sh --harness), for this machine's tests and CI's check-station alone (published for Linux x86-64 only: no
  // station, release or Apple job takes it).
  "reader-harness": {
    files: (t) => [exe("stillfail-reader-harness")(t)],
    targets: ["darwin-arm64", "linux-x64"],
    publish: ["linux-x64"],
    env: "STILLFAIL_MB_HARNESS",
    rust: false,
    inputs: HARNESS_INPUTS,
    recipe: (t) => ({ ...readerRecipe(t), harness: true }),
    build(t, out) {
      const mac = osPlatform() === "darwin" && osArch() === "arm64";
      const linux = osPlatform() === "linux" && osArch() === "x64";
      if (!mac && !(linux && t !== "darwin-arm64")) {
        throw new Error(`the reader's harness for ${t} is built on an Apple Silicon Mac${t !== "darwin-arm64" ? " or a Linux x86-64 machine" : ""}`);
      }
      const shell = ensure(t === "darwin-arm64" ? "shell-apple" : "shell-station", t);
      run("bash", [join(ROOT, "station/mb/build.sh"), "--harness", t, join(out, exe("stillfail-reader-harness")(t))], { env: { ...process.env, SHELL_LIB: join(shell, "libstillfail_shell.a") } });
    },
  },
  // The shell (client/shell) as a static library for the stations that are not Macs, the reader's (above): built on a
  // Mac with zig, as the station's crates are (Linux for glibc 2.28 on, Windows MinGW's).
  "shell-station": {
    files: () => ["libstillfail_shell.a"],
    targets: ["linux-x64", "linux-arm64", "win32-x64"],
    inputs: ["client/shell", "libs/mesh-transport/src", "libs/mesh-transport/Cargo.toml", "client/Cargo.toml", "client/Cargo.lock", "vendor/libadb", ...VENDORED],
    recipe: (t) => ({ cargo: shellStation(t) }),
    build(t, out) {
      const target = targetDir(join(ROOT, "client/target"), "shell-station");
      rustTarget(TRIPLE(t));
      run("cargo-zigbuild", shellStation(t), { cwd: join(ROOT, "client"), env: rustEnv({ CARGO_TARGET_DIR: target }) });
      copyFileSync(join(target, TRIPLE(t), "release/libstillfail_shell.a"), join(out, "libstillfail_shell.a"));
    },
  },
  // The core's shell for the mbui app on Apple (scripts/core.sh shell's): the crate as a static library, with what it
  // needs of the system (rustc's native-static-libs), for macOS (rustc's oldest, 11.0, below the app's 12.0) and iOS (17.0, a
  // device's and the simulator's). Built on a Mac by CI's natives job, fetched by the mbui app's builds: built in each
  // build, it was 160-240 s of the macOS job's 440-580 s (its cache by the shell's sources never kept, 2026-10-23).
  "shell-apple": {
    files: () => ["libstillfail_shell.a", "libstillfail_shell.libs"],
    targets: ["darwin-arm64", "ios-arm64", "ios-sim-arm64"],
    inputs: ["client/shell", "libs/mesh-transport/src", "libs/mesh-transport/Cargo.toml", "client/Cargo.toml", "client/Cargo.lock", "vendor/libadb", ...VENDORED],
    recipe: (t) => ({ cargo: shellApple(t), min: APPLE_MIN[t], c: appleCOldest(t) }),
    build(t, out) {
      const triple = APPLE_TRIPLES[t]!;
      const target = targetDir(join(ROOT, "client/target"), "shell-apple");
      rustTarget(triple);
      // (macOS's oldest is rustc's own, no MACOSX_DEPLOYMENT_TARGET: that is the host's too, and Xcode 27's ld links
      // the build's proc-macros for 12.0 so that dyld refuses them, "mis-aligned LINKEDIT string pool": E0463 on the CI Mac.
      // The C its crates build (ring's assembly, sqlite) is told the same oldest for the target alone: left to the
      // SDK's own, it was for macOS 27.0, below which the linker warned, 2026-10-24)
      const env = rustEnv({ CARGO_TARGET_DIR: target, ...appleCOldest(t) });
      // (the crate itself built again, its dependencies kept: rustc says what it links only when it builds it)
      run("cargo", ["clean", "--release", "-p", "stillfail-shell", "--target", triple], { cwd: join(ROOT, "client"), env });
      const done = spawnSync("cargo", shellApple(t), { cwd: join(ROOT, "client"), env, encoding: "utf8", stdio: ["ignore", "inherit", "pipe"] });
      process.stderr.write(done.stderr ?? "");
      if (done.status !== 0) throw new Error(`cargo ${shellApple(t).join(" ")}: exit ${done.status ?? done.signal}`);
      const libs = /native-static-libs: (.*)/.exec(done.stderr ?? "")?.[1];
      if (!libs) throw new Error("shell-apple: rustc said no native-static-libs");
      copyFileSync(join(target, triple, "release/libstillfail_shell.a"), join(out, "libstillfail_shell.a"));
      writeFileSync(join(out, "libstillfail_shell.libs"), libs.trim() + "\n");
    },
  },
  // The core's engine (apps/mbui/engine: one source, its C API engine.h the mbui app calls): Hermes and the core's loop
  // on it, linked to the shell. Android's: hermes-android's libhermes.so (HERMES.rn) with the JSI built beside it, the
  // NDK's CMake (apps/mbui/engine/android). Windows': Hermes built from its source (HERMES) with clang-cl, static, in one
  // DLL with the loop; with that build's hermesc, for the core's bytecode. Linux's: the same from its source with
  // clang, in one shared library, ICU's beside it (HERMES_LINUX_CMAKE).
  engine: {
    // With the NDK's C++ runtime it was linked against, which the CMake build packs.
    files: (t) =>
      t === "win32-x64" ? ["stillfail_engine.dll", "stillfail_engine.lib", "hermesc.exe"]
      : LINUX(t) ? ["libstillfail_engine.so", "hermesc", ...ICU_LINUX]
      : ["libjsi.so", "libstillfail_hermes.so", "libc++_shared.so"],
    targets: ["android-arm64", "win32-x64", "linux-x64", "linux-arm64"],
    msvc: true,
    inputs: ["apps/mbui/engine"],
    recipe: (t) =>
      t === "win32-x64" ? { hermes: HERMES, cmake: HERMES_CMAKE, targets: ["stillfail_engine", "hermesc"] }
      : LINUX(t) ? { hermes: HERMES, cmake: HERMES_LINUX_CMAKE, targets: ["stillfail_engine", "hermesc"] }
      : { ndk: NDK, api: ANDROID_API, hermes: HERMES.rn, cmake: ENGINE_ANDROID_CMAKE },
    build(t, out) {
      if (t === "win32-x64") return engineWin(out);
      if (LINUX(t)) return engineLinux(t, out);
      engineAndroid(out);
    },
  },
  // still.fail Helper (station/native/helper §4): the station's macOS app for what macOS
  // grants an app (the screen), Swift built with the Mac's Xcode, put in its bundle with its
  // Info.plist and still.fail's icon (its permission window and System Settings show it) and signed ad hoc (a
  // release signs it again, scripts/station-bundle.sh).
  helper: {
    files: () => [HELPER_APP],
    targets: ["darwin-arm64"],
    env: "STILLFAIL_HELPER",
    inputs: ["station/native/helper", "vendor/PermissionFlow", "vendor/serve-sim"],
    recipe: () => ({ swift: SWIFT_BUILD, app: HELPER_APP, agentDesktop: AGENT_DESKTOP["darwin-arm64"] }),
    build(_t, out) {
      const dir = join(ROOT, "station/native/helper");
      const scratch = process.env.CARGO_TARGET_DIR ? join(process.env.CARGO_TARGET_DIR, "native", "helper") : join(dir, ".build");
      run("swift", [...SWIFT_BUILD, "--scratch-path", scratch], { cwd: dir });
      const app = join(out, HELPER_APP);
      mkdirSync(join(app, "Contents/MacOS"), { recursive: true });
      copyFileSync(swiftProduct(scratch, "stillfail-helper"), join(app, "Contents/MacOS/stillfail-helper"));
      copyFileSync(join(dir, "Info.plist"), join(app, "Contents/Info.plist"));
      const iconset = join(out, "AppIcon.iconset");
      mkdirSync(iconset);
      for (const size of [16, 32, 128, 256, 512]) {
        for (const scale of [1, 2]) {
          const name = `icon_${size}x${size}${scale === 2 ? "@2x" : ""}.png`;
          run("sips", ["-z", String(size * scale), String(size * scale), join(ROOT, HELPER_ICON), "--out", join(iconset, name)], { stdio: ["ignore", "ignore", process.stderr] });
        }
      }
      mkdirSync(join(app, "Contents/Resources"), { recursive: true });
      run("iconutil", ["-c", "icns", iconset, "-o", join(app, "Contents/Resources/AppIcon.icns")]);
      // An iPhone Duo's hinge, run inside the simulator (vendor/serve-sim SimDuoHID); a Mac without its SDK builds none, and
      // its poses are not offered.
      try {
        const sdk = execFileSync("xcrun", ["--sdk", "iphonesimulator", "--show-sdk-path"], { encoding: "utf8" }).trim();
        run("xcrun", ["--sdk", "iphonesimulator", "clang", "-arch", "arm64", "-mios-simulator-version-min=15.0", "-isysroot", sdk, "-fobjc-arc", "-framework", "Foundation", "-Wl,-adhoc_codesign", "-o", join(app, "Contents/Resources/stillfail-duo-hid"), join(ROOT, "vendor/serve-sim/Sources/SimDuoHID/main.m")], {});
      } catch (error) {
        console.error(`native: no iPhone Duo hinge in the helper: ${(error as Error).message}`);
      }
      rmSync(iconset, { recursive: true });
      writeFileSync(join(app, "Contents/PkgInfo"), "APPL????");
      // agent-desktop beside its executable (Ui.swift): run by the app, it has the app's grants. Signed before the
      // app, which seals it (a release signs them again in the same order, scripts/station-bundle.sh).
      const tree = ensure("agent-desktop", "darwin-arm64");
      for (const f of AGENT_DESKTOP_FILES.darwin) {
        copyFileSync(join(tree, f), join(app, "Contents/MacOS", f));
        run("codesign", ["--force", "--sign", "-", "--identifier", `fail.still.${f}`, join(app, "Contents/MacOS", f)]);
      }
      run("codesign", ["--force", "--sign", "-", "--identifier", "fail.still.helper", app]);
    },
  },
  // agent-desktop (vercel-labs/agent-desktop, Apache-2.0): the apps' accessibility trees, read and acted on by ref
  // ("Agents on a screen"). Its release's own build, checked against the SHA-256 its
  // checksums.txt gives: still.fail Helper carries macOS's, the station Windows' beside stillfail-screen.exe.
  "agent-desktop": {
    files: (t) => (t === "win32-x64" ? AGENT_DESKTOP_FILES.win32 : AGENT_DESKTOP_FILES.darwin),
    targets: ["darwin-arm64", "win32-x64"],
    env: "STILLFAIL_AGENT_DESKTOP",
    rust: false,
    recipe: (t) => AGENT_DESKTOP[t] ?? null,
    build(t, out) {
      const { url, sha256 } = AGENT_DESKTOP[t] ?? fail(`no agent-desktop for ${t}`);
      const tgz = join(out, "agent-desktop.tar.gz");
      run("curl", ["-fsSL", "--retry", "5", "--retry-all-errors", url, "-o", tgz]);
      const got = createHash("sha256").update(readFileSync(tgz)).digest("hex");
      if (got !== sha256) throw new Error(`${url}: sha256 ${got}, not ${sha256}`);
      run(TAR, ["-xzf", tgz, "-C", out]);
      rmSync(tgz);
    },
  },
  // iroh's relay in dev mode, for the core's mesh tests (client/core-ts/test/mesh.test.ts): n0's own build, the
  // version still.fail's relays run (cloud/Dockerfile).
  "iroh-relay": {
    files: () => ["iroh-relay"],
    targets: ["darwin-arm64", "linux-x64", "linux-arm64"],
    env: "STILLFAIL_RELAY_BIN",
    recipe: (t) => RELAY[t] ?? null,
    build(t, out) {
      const { url, sha256 } = RELAY[t] ?? fail(`no relay for ${t}`);
      const tgz = join(out, "relay.tar.gz");
      run("curl", ["-fsSL", "--retry", "5", "--retry-all-errors", url, "-o", tgz]);
      const got = createHash("sha256").update(readFileSync(tgz)).digest("hex");
      if (got !== sha256) throw new Error(`${url}: sha256 ${got}, not ${sha256}`);
      run("tar", ["-xzf", tgz, "-C", out]);
      rmSync(tgz);
    },
  },
  // still.fail's own relay (libs/mesh-transport's mesh-relay), for the side runs' tests of it
  // (station/side/mesh-relay-daemon.test.ts, cloud/side/mesh-relay.test.ts): built where it runs, published nowhere
  // (`publish: []`, so no CI job builds or fetches it for a release).
  "mesh-relay": {
    files: () => ["mesh-relay"],
    targets: ["darwin-arm64", "linux-x64", "linux-arm64"],
    publish: [],
    env: "STILLFAIL_MESH_RELAY_BIN",
    inputs: ["libs/mesh-transport/src", "libs/mesh-transport/Cargo.toml", "libs/mesh-transport/Cargo.lock", ...VENDORED],
    // (the same key wherever it is built: which cargo builds it is the machine's, not what it is made of)
    recipe: (t) => ({ cargo: cargoCommand(t, ["--bin", "mesh-relay"]) }),
    build(t, out) {
      const target = stationTargetDir("libs/mesh-transport", t);
      cargo(meshRelayCargo(t), join(ROOT, "libs/mesh-transport"), { CARGO_TARGET_DIR: target });
      copyFileSync(join(target, TRIPLE(t), "release", "mesh-relay"), join(out, "mesh-relay"));
    },
  },
};
/// mesh-relay's build: cargo's own on a machine of its target (a Mac, a Linux of the target's), else cross-built.
const meshRelayCargo = (t: Target) =>
  t === "darwin-arm64" || (osPlatform() === "linux" && host() === t)
    ? ["build", "--release", "--locked", "--bin", "mesh-relay", "--target", TRIPLE(t)]
    : cargoCommand(t, ["--bin", "mesh-relay"]);
const RELAY_URL = (triple: string) => `https://github.com/n0-computer/iroh/releases/download/v1.1.0/iroh-relay-v1.1.0-${triple}.tar.gz`;
const RELAY: Record<string, { url: string; sha256: string }> = {
  "darwin-arm64": { url: RELAY_URL("aarch64-apple-darwin"), sha256: "abe9606e28749b7be4b602cbf48a7795755dfe484ccc9ff6f17a9c1b3cfd5c3f" },
  "linux-x64": { url: RELAY_URL("x86_64-unknown-linux-musl"), sha256: "9a68108b824e4164ad2eec729cf0e8167e4cb50581cb745a242bace135df7614" },
  "linux-arm64": { url: RELAY_URL("aarch64-unknown-linux-musl"), sha256: "1b4261b6dd0d17ae9a7516aa6d122b296a77678bac174ce30262702c9f91cb00" },
};
const AGENT_DESKTOP_VERSION = "1.0.2";
const AGENT_DESKTOP_URL = (triple: string) => `https://github.com/vercel-labs/agent-desktop/releases/download/v${AGENT_DESKTOP_VERSION}/agent-desktop-v${AGENT_DESKTOP_VERSION}-${triple}.tar.gz`;
const AGENT_DESKTOP: Record<string, { url: string; sha256: string }> = {
  "darwin-arm64": { url: AGENT_DESKTOP_URL("aarch64-apple-darwin"), sha256: "7bee385196d7b478de80cf05ca4304aaa38f0eba593b3406ad3c247c1773be19" },
  "win32-x64": { url: AGENT_DESKTOP_URL("x86_64-pc-windows-msvc"), sha256: "2186c76e7df197c0e67365e45d36d869f74714c56bb8a73817e2a66f3e18e222" },
};
/// What its archives hold: the command, and on macOS the helper it starts beside itself (the clipboard's).
const AGENT_DESKTOP_FILES = { darwin: ["agent-desktop", "agent-desktop-macos-helper"], win32: ["agent-desktop.exe"] };
const SWIFT_BUILD = ["build", "-c", "release", "--arch", "arm64"];
/// Where `swift build` put a release product: SwiftPM's own build system's place, or (Swift 6.4's swift-build) its
/// `out/Products/Release`; the newer where a scratch path has both.
const swiftProduct = (scratch: string, name: string) =>
  [join(scratch, "arm64-apple-macosx/release", name), join(scratch, "out/Products/Release", name)]
    .filter((p) => existsSync(p))
    .sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs)[0] ?? join(scratch, "arm64-apple-macosx/release", name);
const HELPER_APP = "still.fail Helper.app";
const APPLE_TRIPLES: Partial<Record<Target, string>> = { "darwin-arm64": "aarch64-apple-darwin", "ios-arm64": "aarch64-apple-ios", "ios-sim-arm64": "aarch64-apple-ios-sim" };
/// (macOS: rustc's for aarch64-apple-darwin, below the app's 12.0)
const APPLE_MIN: Partial<Record<Target, string>> = { "darwin-arm64": "11.0", "ios-arm64": "17.0", "ios-sim-arm64": "17.0" };
/// What tells an Apple target's C (the cc crate's) its oldest system: iOS by IPHONEOS_DEPLOYMENT_TARGET (not the host's),
/// macOS by its target's CFLAGS alone (MACOSX_DEPLOYMENT_TARGET is the host's too: shell-apple's build above).
const appleCOldest = (t: Target): Record<string, string> =>
  t === "darwin-arm64"
    ? { CFLAGS_aarch64_apple_darwin: `-mmacosx-version-min=${APPLE_MIN[t]}` }
    : { IPHONEOS_DEPLOYMENT_TARGET: APPLE_MIN[t]! };
/// The shell's static library for Apple, as scripts/core.sh shell makes it (the crate untouched: a staticlib by rustc),
/// rebuilt so that rustc says what it links (--print native-static-libs, said only when it builds)
const shellApple = (t: Target) => [
  "rustc", "--locked", "--release", "-p", "stillfail-shell", "--lib", "--crate-type", "staticlib", "--target", APPLE_TRIPLES[t]!,
  "--", "--print", "native-static-libs",
];
/// The shell as a static library for a station that is not a Mac (cargo-zigbuild's rustc: `cargo zigbuild` builds what the
/// manifest says, a cdylib and an rlib; Linux for glibc 2.28 on).
const shellStation = (t: Target) => [
  "rustc", "--locked", "--release", "-p", "stillfail-shell", "--lib", "--crate-type", "staticlib",
  "--target", t === "win32-x64" ? TRIPLE(t) : `${TRIPLE(t)}.2.28`,
];
const SHELL_RUSTFLAGS = "-C link-arg=-Wl,-z,max-page-size=16384";
const shellCommand = () => [
  "rustc", "--locked", "-p", "stillfail-shell", "--lib", "--crate-type", "cdylib", "--target", "aarch64-linux-android", "--release",
  // Named by its file (SONAME): the engine that links it is then given its name, not where it was built.
  "--", "-C", "link-arg=-Wl,-soname,libstillfail_shell.so",
];
/// The Linux shell: the crate's cdylib, built on Linux (the prebuild workflow's Ubuntu: glibc 2.39, as the app's GTK 4 needs a
/// system that new anyway), named by its file as Android's.
const shellLinux = (t: Target) => [
  "rustc", "--locked", "-p", "stillfail-shell", "--lib", "--crate-type", "cdylib", "--target", TRIPLE(t), "--release",
  "--", "-C", "link-arg=-Wl,-soname,libstillfail_shell.so",
];
function shellLinuxBuild(t: Target, target: string, out: string) {
  if (osPlatform() !== "linux" || host() !== t) throw new Error(`shell ${t} is built on a Linux ${t} machine (the prebuild workflow's)`);
  rustTarget(TRIPLE(t));
  cargo(shellLinux(t), join(ROOT, "client"), { CARGO_TARGET_DIR: target });
  copyFileSync(join(target, TRIPLE(t), "release/libstillfail_shell.so"), join(out, "libstillfail_shell.so"));
}
/// The Windows shell: the crate's cdylib (a DLL with its import library, which the engine links) and its tests, in one
/// build, the tests' (whose library is the DLL: the crate has no dev-dependency to build what is below it with other
/// features), not run (a Mac builds them; CI's Windows runs them). Two builds took 2 of the 8 minutes, 2026-10-23.
const SHELL_TESTS = ["test", "--release", "--locked", "-p", "stillfail-shell", "--target", "x86_64-pc-windows-msvc", "--no-run", "--message-format=json-render-diagnostics"];
const SHELL_WIN_RUSTFLAGS = "-C target-feature=+crt-static";
/// cargo-xwin, which cross-builds the Windows parts on a Mac with the Windows SDK and MSVC's CRT (Microsoft's, which it
/// downloads: xwin), clang-cl and lld-link (Homebrew's llvm and lld).
const XWIN = "0.23.1";
/// Where a development machine keeps the cross-builds' tools and output (cargo-xwin, the SDK, cargo's target, Hermes's
/// checkout and builds): beside the cache, shared by every worktree, so a change builds only what it changed.
const BUILD = () => process.env.STILLFAIL_NATIVE_BUILD ?? join(CACHE, ".build");
const LLVM = "/opt/homebrew/opt/llvm/bin";
/// cargo-xwin's environment on a Mac (installed into BUILD once): the SDK it keeps there, clang-cl first on PATH.
function xwinEnv(): { XWIN_CACHE_DIR: string; PATH: string } {
  const tools = join(BUILD(), "tools");
  const env = { XWIN_CACHE_DIR: join(BUILD(), "xwin"), PATH: [join(tools, "bin"), join(homedir(), ".cargo/bin"), LLVM, "/opt/homebrew/bin", process.env.PATH].join(delimiter) };
  rustTarget();
  if (!existsSync(join(tools, "bin", "cargo-xwin"))) {
    if (!existsSync(join(LLVM, "clang-cl"))) throw new Error("cross-building for Windows needs Homebrew's llvm and lld (brew install llvm lld)");
    run("cargo", ["install", "--locked", "--root", tools, "cargo-xwin", "--version", XWIN], { env: rustEnv(env) });
  }
  return env;
}
/// The Windows shell and its tests, here: natively on Windows, with cargo-xwin on a Mac.
function shellWin(out: string) {
  const cross = osPlatform() === "darwin";
  const target = cross ? join(BUILD(), "target") : targetDir(join(ROOT, "client/target"), "shell");
  const env = { CARGO_TARGET_DIR: target, CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_RUSTFLAGS: SHELL_WIN_RUSTFLAGS, ...(cross ? xwinEnv() : {}) };
  const xwin = (args: string[]) => (cross ? ["xwin", ...args] : args);
  // the library and the tests' executables, from cargo's own account of what it built
  rustTarget("x86_64-pc-windows-msvc");
  const done = spawnSync("cargo", xwin(SHELL_TESTS), { cwd: join(ROOT, "client"), env: rustEnv(env), encoding: "utf8", maxBuffer: 256 << 20, stdio: ["ignore", "pipe", "inherit"] });
  if (done.status !== 0) throw new Error(`cargo ${xwin(SHELL_TESTS).join(" ")}: exit ${done.status}`);
  mkdirSync(join(out, "tests"));
  for (const line of done.stdout.split("\n")) {
    if (!line.startsWith("{")) continue;
    const m = JSON.parse(line);
    if (m.reason !== "compiler-artifact") continue;
    // the library (not its tests): the DLL, and its import library beside it
    const dll = (m.filenames as string[]).find((f) => basename(f) === "stillfail_shell.dll");
    if (!m.profile?.test && dll) for (const f of ["stillfail_shell.dll", "stillfail_shell.dll.lib"]) copyFileSync(join(dirname(dll), f), join(out, f));
    if (!m.profile?.test || !m.executable) continue;
    copyFileSync(m.executable, join(out, "tests", `${m.target.kind.includes("lib") ? "lib" : m.target.name}.exe`));
  }
  if (!existsSync(join(out, "stillfail_shell.dll"))) throw new Error("the shell's DLL was not built");
  if (readdirSync(join(out, "tests")).length === 0) throw new Error("the shell's tests were not built");
}
/// The Windows engine (apps/mbui/engine) in Hermes's own CMake build (its libhermes, static, linked into the DLL),
/// linked to the shell by name (an import library made from the shell's C ABI, stillfail_shell.def: the shell itself
/// is not needed to build it). The checkout and the build stay in the part's target directory, so a change to the loop
/// alone compiles only it.
function engineWin(out: string) {
  // natively on Windows; on a Mac with clang-cl and xwin's SDK (cargo-xwin's), Hermes's own tools built for the Mac
  const cross = osPlatform() === "darwin";
  const work = cross ? join(BUILD(), "hermes") : targetDir(join(ROOT, "apps/mbui/engine/target"), "engine");
  const src = hermesSource(work);
  const build = join(work, "build");
  run("cmake", ["-S", src, "-B", build, ...(cross ? hermesCross(src, work) : HERMES_CMAKE)]);
  run("cmake", ["--build", build, "--target", "stillfail_engine", "hermesc"]);
  for (const f of ["stillfail_engine.dll", "stillfail_engine.lib"]) copyFileSync(join(build, "stillfail-engine", f), join(out, f));
  copyFileSync(join(build, "bin", "hermesc.exe"), join(out, "hermesc.exe"));
}
/// Hermes's source at HERMES.tag in `work`/hermes (got once), with the engine's in it as one of its directories (it
/// links Hermes's own targets), put there afresh: its checkout.
function hermesSource(work: string): string {
  const src = join(work, "hermes");
  mkdirSync(work, { recursive: true });
  if (!existsSync(join(src, ".stillfail-tag")) || readFileSync(join(src, ".stillfail-tag"), "utf8") !== HERMES.tag) {
    rmSync(src, { recursive: true, force: true });
    // the tag's tarball, tried again on the way (a clone over a test Mac's TLS broke off, 2026-10-19)
    mkdirSync(src, { recursive: true });
    const tgz = join(work, "hermes.tar.gz");
    run("curl", ["-fsSL", "--retry", "5", "--retry-all-errors", "--retry-delay", "5", "-o", tgz, `https://github.com/facebook/hermes/archive/refs/tags/${HERMES.tag}.tar.gz`]);
    run(TAR, ["-xzf", tgz, "-C", src, "--strip-components=1"]);
    rmSync(tgz, { force: true });
    writeFileSync(join(src, "CMakeLists.txt"), readFileSync(join(src, "CMakeLists.txt"), "utf8") + "\nadd_subdirectory(stillfail-engine)\n");
    writeFileSync(join(src, ".stillfail-tag"), HERMES.tag);
  }
  rmSync(join(src, "stillfail-engine"), { recursive: true, force: true });
  mkdirSync(join(src, "stillfail-engine"));
  for (const e of readdirSync(join(ROOT, "apps/mbui/engine"), { withFileTypes: true })) {
    if (e.isFile()) copyFileSync(join(ROOT, "apps/mbui/engine", e.name), join(src, "stillfail-engine", e.name));
  }
  return src;
}
/// The Linux engine (apps/mbui/engine), as Windows' is built on Windows: in Hermes's own CMake build, on a Linux machine
/// of the target's (the prebuild workflow's Ubuntu), its libhermes linked into libstillfail_engine.so; with that build's
/// hermesc, and the ICU libraries both link (ICU_LINUX: those the loader finds for the engine, as they are named).
function engineLinux(t: Target, out: string) {
  if (osPlatform() !== "linux" || host() !== t) throw new Error(`engine ${t} is built on a Linux ${t} machine (the prebuild workflow's)`);
  const work = targetDir(join(ROOT, "apps/mbui/engine/target"), "engine");
  const src = hermesSource(work);
  const build = join(work, "build");
  run("cmake", ["-S", src, "-B", build, ...HERMES_LINUX_CMAKE]);
  run("cmake", ["--build", build, "--target", "stillfail_engine", "hermesc"]);
  const engine = join(build, "stillfail-engine", "libstillfail_engine.so");
  copyFileSync(engine, join(out, "libstillfail_engine.so"));
  copyFileSync(join(build, "bin", "hermesc"), join(out, "hermesc"));
  // (ldd's lines: `libicuuc.so.74 => /usr/lib/x86_64-linux-gnu/libicuuc.so.74 (0x…)`)
  const icu = new Map<string, string>();
  for (const line of execFileSync("ldd", [engine], { encoding: "utf8" }).split("\n")) {
    const m = /^\s*(libicu\S+)\s+=>\s+(\S+)/.exec(line);
    if (m) icu.set(m[1]!, m[2]!);
  }
  const names = [...icu.keys()].sort();
  if (names.join(" ") !== [...ICU_LINUX].sort().join(" ")) throw new Error(`the engine links ICU's ${names.join(", ") || "none"}, not ICU_LINUX's ${ICU_LINUX.join(", ")}`);
  for (const [name, path] of icu) copyFileSync(path, join(out, name));
}
/// How Android's engine is built (apps/mbui/engine/android): the NDK's toolchain for arm64, its C++ runtime shared, a
/// release.
const ENGINE_ANDROID_CMAKE = ["-G", "Ninja", "-DANDROID_ABI=arm64-v8a", "-DANDROID_STL=c++_shared", "-DCMAKE_BUILD_TYPE=Release"];
/// Android's engine: hermes-android's AAR (HERMES.rn: Gradle's cache, else Maven Central) for libhermes.so and its
/// headers, the shell this target's, and the SDK's CMake with the NDK's toolchain; the NDK's libc++_shared.so beside.
function engineAndroid(out: string) {
  const sdk = androidHome();
  const ndk = join(sdk, "ndk", NDK);
  const work = join(BUILD(), "engine-android");
  mkdirSync(work, { recursive: true });
  const hermes = join(work, `hermes-android-${HERMES.rn}`);
  if (!existsSync(join(hermes, "jni/arm64-v8a/libhermes.so"))) {
    rmSync(hermes, { recursive: true, force: true });
    mkdirSync(hermes, { recursive: true });
    run("unzip", ["-q", "-o", hermesAar(work), "jni/arm64-v8a/libhermes.so", "prefab/modules/libhermes/include/*", "-d", hermes]);
  }
  const shell = join(ensure("shell", "android-arm64"), "libstillfail_shell.so");
  const cmakeDir = readdirSync(join(sdk, "cmake")).sort((a, b) => a.localeCompare(b, undefined, { numeric: true })).pop();
  if (!cmakeDir) throw new Error(`no CMake in ${join(sdk, "cmake")}: install the SDK's cmake`);
  const bin = join(sdk, "cmake", cmakeDir, "bin");
  const build = join(work, "build");
  rmSync(build, { recursive: true, force: true });
  run(join(bin, "cmake"), ["-S", join(ROOT, "apps/mbui/engine/android"), "-B", build, ...ENGINE_ANDROID_CMAKE,
    `-DCMAKE_MAKE_PROGRAM=${join(bin, "ninja")}`, `-DCMAKE_TOOLCHAIN_FILE=${join(ndk, "build/cmake/android.toolchain.cmake")}`,
    `-DANDROID_PLATFORM=android-${ANDROID_API}`, `-DHERMES_SO=${join(hermes, "jni/arm64-v8a/libhermes.so")}`,
    `-DHERMES_INCLUDE=${join(hermes, "prefab/modules/libhermes/include")}`, `-DSHELL_SO=${shell}`]);
  run(join(bin, "cmake"), ["--build", build]);
  for (const name of ["libstillfail_hermes.so", "libjsi.so"]) copyFileSync(join(build, name), join(out, name));
  const sysroot = join(ndk, "toolchains/llvm/prebuilt", osPlatform() === "darwin" ? "darwin-x86_64" : "linux-x86_64", "sysroot");
  copyFileSync(join(sysroot, "usr/lib/aarch64-linux-android/libc++_shared.so"), join(out, "libc++_shared.so"));
}
/// hermes-android's AAR at HERMES.rn: Gradle's cache where it has it, else downloaded once into `work`.
function hermesAar(work: string): string {
  const name = `hermes-android-${HERMES.rn}-release.aar`;
  const cache = join(homedir(), ".gradle/caches/modules-2/files-2.1/com.facebook.react/hermes-android", HERMES.rn);
  if (existsSync(cache)) {
    const found = findFile(cache, (p) => p.endsWith(`/${name}`));
    if (found) return found;
  }
  const aar = join(work, name);
  if (!existsSync(aar)) {
    run("curl", ["-fsSL", "--retry", "5", "--retry-all-errors", "--retry-delay", "5", "-o", `${aar}.part`,
      `https://repo1.maven.org/maven2/com/facebook/react/hermes-android/${HERMES.rn}/${name}`]);
    renameSync(`${aar}.part`, aar);
  }
  return aar;
}
/// Hermes for Windows from a Mac: the hermesc it compiles its own JS with built for the Mac first (Hermes's cross build
/// imports it), then a CMake toolchain of clang-cl, lld-link and llvm-lib on xwin's SDK and CRT (the release CRT: xwin
/// has no debug one, so CMake's own test compiles are release builds too).
function hermesCross(src: string, work: string): string[] {
  const env = xwinEnv();
  const sdk = join(env.XWIN_CACHE_DIR, "xwin");
  if (!existsSync(join(sdk, "crt"))) run("cargo", ["xwin", "env", "--target", "x86_64-pc-windows-msvc"], { env: rustEnv(env), stdio: ["ignore", "ignore", process.stderr] });
  if (!existsSync(join(sdk, "crt"))) throw new Error(`no Windows SDK in ${sdk} (cargo-xwin's)`);
  const host = join(work, "hermesc-host");
  run("cmake", ["-S", src, "-B", host, "-G", "Ninja", "-DCMAKE_BUILD_TYPE=Release", "-DHERMES_ENABLE_DEBUGGER=OFF", "-DHERMES_ENABLE_TEST_SUITE=OFF"]);
  run("cmake", ["--build", host, "--target", "hermesc"]);
  const inc = ["crt/include", "sdk/include/ucrt", "sdk/include/um", "sdk/include/shared"].map((d) => `/imsvc${join(sdk, d)}`).join(" ");
  const libs = ["crt/lib/x86_64", "sdk/lib/um/x86_64", "sdk/lib/ucrt/x86_64"].map((d) => `/libpath:${join(sdk, d)}`).join(" ");
  const toolchain = join(work, "clang-cl-windows.cmake");
  writeFileSync(toolchain, [
    "set(CMAKE_SYSTEM_NAME Windows)",
    "set(CMAKE_SYSTEM_PROCESSOR AMD64)",
    `set(CMAKE_C_COMPILER ${LLVM}/clang-cl)`,
    `set(CMAKE_CXX_COMPILER ${LLVM}/clang-cl)`,
    `set(CMAKE_LINKER ${existsSync(join(LLVM, "lld-link")) ? join(LLVM, "lld-link") : "/opt/homebrew/bin/lld-link"})`,
    `set(CMAKE_AR ${LLVM}/llvm-lib)`,
    `set(CMAKE_RC_COMPILER ${LLVM}/llvm-rc)`,
    `set(CMAKE_MT ${LLVM}/llvm-mt)`,
    `set(CMAKE_C_FLAGS_INIT "--target=x86_64-pc-windows-msvc ${inc}")`,
    `set(CMAKE_CXX_FLAGS_INIT "--target=x86_64-pc-windows-msvc ${inc}")`,
    ...["EXE", "SHARED", "MODULE"].map((k) => `set(CMAKE_${k}_LINKER_FLAGS_INIT "${libs} /manifest:no")`),
    "set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)",
    "set(CMAKE_TRY_COMPILE_CONFIGURATION Release)",
    "set(CMAKE_MSVC_RUNTIME_LIBRARY MultiThreaded)",
    "set(CMAKE_POLICY_DEFAULT_CMP0091 NEW)",
    "",
  ].join("\n"));
  return ["-G", "Ninja", `-DCMAKE_TOOLCHAIN_FILE=${toolchain}`, "-DCMAKE_BUILD_TYPE=Release", "-DHERMES_ENABLE_DEBUGGER=OFF", "-DHERMES_ENABLE_TEST_SUITE=OFF", `-DIMPORT_HERMESC=${join(host, "ImportHermesc.cmake")}`];
}
const P = (name: string): Part => PARTS[name] ?? fail(`no such part: ${name} (${Object.keys(PARTS).join(", ")})`);
const inputsFor = (p: Part, t: Target): string[] => (typeof p.inputs === "function" ? p.inputs(t) : p.inputs ?? []);
/// Built only on Windows (msvc).
const onWindows = (part: string, t: Target): boolean => t === "win32-x64" && P(part).msvc === true;
/// Built only on Linux, a machine of the target's (msvc's Linux targets: the prebuild workflow's Ubuntu): never by the
/// Mac's natives job nor Windows'.
const onLinux = (part: string, t: Target): boolean => LINUX(t) && P(part).msvc === true;
/// This machine's when the part is built for it, else the part's first target (Android's shell and engine on a Mac).
const defaultTarget = (part: string): Target => {
  const { targets } = P(part);
  let here: Target | null = null;
  try { here = host(); } catch {}
  return here && targets.includes(here) ? here : targets[0]!;
};

// ── keys ──

function git(args: string[], input?: string, cwd = ROOT): string {
  return execFileSync("git", args, { cwd, encoding: "utf8", input, maxBuffer: 64 << 20 });
}
/// Each input file and its content's git hash: as committed or staged, and as it is in the worktree when it differs
/// there (an edit not yet committed is another key), new files not ignored included. A command that asks of many parts
/// (`useTree`) reads them off one listing of the whole checkout (`tree`), not two git processes a part and target:
/// `missing --linux` and `--mac` asked git 75 times and took 20-40 s of plan's natives step (main 44674271258,
/// 2026-11-20). A pathspec that listing cannot answer exactly (`pathspec`) is still git's, as is all of a command of one
/// part: listing the whole checkout, its build directories walked for new files, took `key` 16 s and `path` 14 s beside
/// the iOS app's moonc (45386683892, 2026-11-24).
function inputs(paths: string[]): [string, string][] {
  if (paths.length === 0) return [];
  if (!useTree) return inputsByGit(paths);
  checkout ??= tree(ROOT);
  return inputsIn(checkout, paths) ?? inputsByGit(paths);
}
/// What git lists of the checkout, once a process, and the worktree's hashes of its changed files as they are asked
/// for. Dropped after a build (`buildHere`), which may write into the checkout.
export type Tree = { root: string; staged: [string, string][]; dirty: string[]; hashes: Map<string, string> };
let checkout: Tree | null = null;
/// Whether this process reads its parts' inputs off that listing: main's, for the commands of many parts.
let useTree = false;
export function tree(root: string): Tree {
  const staged: [string, string][] = [];
  for (const line of git(["ls-files", "-s", "-z"], undefined, root).split("\0")) {
    if (!line) continue;
    const [meta, path] = line.split("\t");
    staged.push([path!, meta!.split(" ")[1]!]);
  }
  const dirty = git(["ls-files", "-m", "-o", "--exclude-standard", "-z"], undefined, root).split("\0").filter(Boolean);
  return { root, staged, dirty, hashes: new Map() };
}
/// inputs() from a listing; null where a pathspec is not one `pathspec` answers as git does.
export function inputsIn(t: Tree, paths: string[]): [string, string][] | null {
  if (paths.length === 0) return [];
  const match = pathspec(paths);
  if (!match) return null;
  const files = new Map<string, string>();
  for (const [path, hash] of t.staged) if (match(path)) files.set(path, hash);
  const dirty = t.dirty.filter(match);
  const present = [...new Set(dirty)].filter((p) => existsSync(join(t.root, p)) && statSync(join(t.root, p)).isFile());
  for (const p of dirty) if (!present.includes(p)) files.delete(p);
  const unhashed = present.filter((p) => !t.hashes.has(p));
  if (unhashed.length > 0) {
    const hashes = git(["hash-object", "--stdin-paths"], unhashed.join("\n") + "\n", t.root).trim().split("\n");
    unhashed.forEach((p, i) => t.hashes.set(p, hashes[i]!));
  }
  for (const p of present) files.set(p, t.hashes.get(p)!);
  return settle(files);
}
/// inputs() asked of git with the pathspecs themselves: two processes a call.
export function inputsByGit(paths: string[], root = ROOT): [string, string][] {
  if (paths.length === 0) return [];
  const files = new Map<string, string>();
  for (const line of git(["ls-files", "-s", "-z", "--", ...paths], undefined, root).split("\0")) {
    if (!line) continue;
    const [meta, path] = line.split("\t");
    files.set(path!, meta!.split(" ")[1]!);
  }
  const dirty = git(["ls-files", "-m", "-o", "--exclude-standard", "-z", "--", ...paths], undefined, root).split("\0").filter(Boolean);
  const present = [...new Set(dirty)].filter((p) => existsSync(join(root, p)) && statSync(join(root, p)).isFile());
  for (const p of dirty) if (!present.includes(p)) files.delete(p);
  if (present.length > 0) {
    const hashes = git(["hash-object", "--stdin-paths"], present.join("\n") + "\n", root).trim().split("\n");
    present.forEach((p, i) => files.set(p, hashes[i]!));
  }
  return settle(files);
}
function settle(files: Map<string, string>): [string, string][] {
  // A crate's tests, benches and examples are not in what it builds: changed, it is the same part (a test-only change
  // built the launcher and runner again for three platforms on 2026-10-04).
  for (const p of [...files.keys()]) if (/(^|\/)(tests|benches|examples)\//.test(p)) files.delete(p);
  return [...files].sort(([a], [b]) => (a < b ? -1 : 1));
}
/// Whether a file is in the pathspecs as `git ls-files -- <paths>` takes them, for the two kinds the parts use: a file
/// or a directory named as it is, and `:(exclude,glob)` with `*`, `?` and `**/` (git's wildmatch with WM_PATHNAME).
/// Anything else (other magic, a wildcard in a plain path, `.`, `./`, a trailing slash, a class): null, for git.
export function pathspec(paths: string[]): ((file: string) => boolean) | null {
  const named: string[] = [], excluded: RegExp[] = [];
  for (const p of paths) {
    if (p.startsWith(":(exclude,glob)")) {
      const re = globRe(p.slice(":(exclude,glob)".length));
      if (!re) return null;
      excluded.push(re);
    } else if (!p || p.startsWith(":") || /[*?[\\]/.test(p) || p.endsWith("/") || p.startsWith("/")
      || p.split("/").some((s) => s === "" || s === "." || s === "..")) {
      return null;
    } else named.push(p);
  }
  if (named.length === 0) return null;
  return (file) => named.some((p) => file === p || file.startsWith(p + "/")) && !excluded.some((re) => re.test(file));
}
function globRe(glob: string): RegExp | null {
  if (!glob || /[[\\]/.test(glob) || glob.startsWith(":")) return null;
  let re = "";
  for (let i = 0; i < glob.length;) {
    if (glob.startsWith("**/", i) && (i === 0 || glob[i - 1] === "/")) { re += "(?:.*/)?"; i += 3; }
    else if (glob.startsWith("**", i) && i + 2 === glob.length && i > 0 && glob[i - 1] === "/") { re += ".*"; i += 2; }
    else if (glob.startsWith("**", i)) return null;
    else if (glob[i] === "*") { re += "[^/]*"; i++; }
    else if (glob[i] === "?") { re += "[^/]"; i++; }
    else { re += glob[i]!.replace(/[.+^${}()|\\/]/g, "\\$&"); i++; }
  }
  return new RegExp(`^${re}$`);
}
export function key(part: string, target: Target, of: (paths: string[]) => [string, string][] = inputs): string {
  const p = P(part);
  const zig = target.startsWith("linux") || (target === "win32-x64" && !onWindows(part, target)) ? (p.zig ?? ZIG) : undefined;
  const what = { part, target, toolchain: p.rust === false ? undefined : TOOLCHAIN, zig, recipe: p.recipe(target), files: p.files(target), inputs: of(inputsFor(p, target)) };
  return createHash("sha256").update(JSON.stringify(what)).digest("hex").slice(0, 24);
}
const asset = (part: string, target: Target, k: string) => `${part}-${target}-${k}.tar.gz`;

// ── the cache ──

const CACHE = process.env.STILLFAIL_NATIVE_CACHE ??
  (osPlatform() === "darwin" ? join(homedir(), "Library/Caches/stillfail-native")
    : osPlatform() === "win32" ? join(process.env.LOCALAPPDATA ?? join(homedir(), "AppData/Local"), "stillfail-native")
    : join(process.env.XDG_CACHE_HOME ?? join(homedir(), ".cache"), "stillfail-native"));
const cached = (part: string, target: Target, k: string) => join(CACHE, part, `${target}-${k}`);
const log = (msg: string) => process.stderr.write(`native: ${msg}\n`);

// A path handed to a caller may be used after native.ts exits. On the CI Mac, CI sets a budget and versions not
// requested for six hours are evicted first (the renderer jobs time out after five minutes; trimCache says what goes
// after them). A day's grace let hundreds of renderer versions fill the disk. Older caches without a usage record are first marked now, so jobs started before
// tracking was introduced get the same grace period. Records live outside artifacts: they must not become part of
// published archives.
const accessRecord = (dir: string) => join(CACHE, ".access", basename(dirname(dir)), basename(dir));
function noteUse(dir: string) {
  const record = accessRecord(dir);
  try {
    mkdirSync(dirname(record), { recursive: true });
    writeFileSync(record, "");
  } catch { /* A read-only cache can still be used. */ }
}
const cacheBudget = () => {
  const bytes = Number(process.env.STILLFAIL_NATIVE_CACHE_MAX_BYTES);
  return Number.isSafeInteger(bytes) && bytes > 0 ? bytes : 0;
};
// Without a budget (a person's machine, a station whose agents build), what a new version was built or downloaded into
// is trimmed to this after it: unbounded, a Mac whose agents built every commit held 398 reader versions, 51 GiB, its
// disk down to 34 GiB free (2026-11-20). Only then, so a cache hit walks nothing.
const LOCAL_BUDGET_BYTES = 10 * 1024 ** 3;

/// One process at a time gets or builds a key on this machine (the others wait for it): a directory made atomically,
/// holding the pid, taken over when that process is gone.
function acquire(dir: string): () => void {
  const lock = `${dir}.lock`;
  mkdirSync(dirname(lock), { recursive: true });
  let said = false;
  for (;;) {
    try {
      mkdirSync(lock);
      writeFileSync(join(lock, "pid"), String(process.pid));
      return () => rmSync(lock, { recursive: true, force: true });
    } catch {
      let pid = 0;
      try { pid = Number(readFileSync(join(lock, "pid"), "utf8")); } catch {}
      let alive = pid > 0;
      if (alive) try { process.kill(pid, 0); } catch { alive = false; }
      // A lock just made has no pid yet (one that stays without for a minute was left by a crash); one whose holder
      // is gone is taken.
      let old = false;
      try { old = !pid && Date.now() - statSync(lock).mtimeMs > 60_000; } catch {}
      if ((!alive && pid > 0) || old) { rmSync(lock, { recursive: true, force: true }); continue; }
      if (!said) { log(`waiting for another process (${pid || "?"}) getting ${basename(dir)}`); said = true; }
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 500);
    }
  }
}

// Never wait on a particular artifact while pruning: another build may hold it while requesting a second one.
function tryAcquire(dir: string): (() => void) | null {
  const lock = `${dir}.lock`;
  let made = false;
  try {
    mkdirSync(lock);
    made = true;
    writeFileSync(join(lock, "pid"), String(process.pid));
    return () => rmSync(lock, { recursive: true, force: true });
  } catch {
    if (made) rmSync(lock, { recursive: true, force: true });
    return null;
  }
}

function allocated(dir: string): number {
  const s = lstatSync(dir);
  if (!s.isDirectory()) return s.blocks * 512;
  return s.blocks * 512 + readdirSync(dir).reduce((n, name) => n + allocated(join(dir, name)), 0);
}

// Over the budget after that, versions unused for a quarter of an hour go too, oldest first: a burst of merges makes
// a renderer version per commit, and versions all used within six hours held 7-10 GiB with the budget at 5 (Mini1's
// ENOSPC, 44253499545, 2026-11-18). A quarter of an hour is three jobs' five minutes: no running job still holds one.
const COLD_MS = 6 * 60 * 60 * 1000, OVER_BUDGET_MS = 15 * 60 * 1000;
function trimCache(limit: number) {
  // Serialize the accounting, so concurrent jobs do not each remove enough versions to reach the budget.
  const release = acquire(join(CACHE, ".prune"));
  try {
    const entries: { dir: string; bytes: number; used: number }[] = [];
    for (const [part, spec] of Object.entries(PARTS)) {
      const parent = join(CACHE, part);
      if (!existsSync(parent)) continue;
      for (const e of readdirSync(parent, { withFileTypes: true })) {
        if (!e.isDirectory() || !spec.targets.some((target) =>
          new RegExp(`^${target}-[0-9a-f]{24}$`).test(e.name))) continue;
        const dir = join(parent, e.name), record = accessRecord(dir);
        try {
          if (!existsSync(record)) {
            const unlock = tryAcquire(dir);
            if (unlock) try { if (!existsSync(record) && existsSync(dir)) noteUse(dir); } finally { unlock(); }
          }
          // A locked or unwritable legacy entry has no trustworthy last-use time and is never evicted.
          const used = existsSync(record) ? statSync(record).mtimeMs : Date.now();
          entries.push({ dir, used, bytes: allocated(dir) });
        } catch { /* A concurrent build may have replaced this entry. */ }
      }
    }
    let total = entries.reduce((n, e) => n + e.bytes, 0);
    entries.sort((a, b) => a.used - b.used);
    const gone = new Set<string>();
    for (const cutoff of [Date.now() - COLD_MS, Date.now() - OVER_BUDGET_MS]) {
      for (const e of entries) {
        if (total <= limit) return;
        if (e.used >= cutoff || gone.has(e.dir)) continue;
        const unlock = tryAcquire(e.dir);
        if (!unlock) continue;
        try {
          // A caller may have requested it since the accounting pass.
          const record = accessRecord(e.dir);
          if (!existsSync(record) || statSync(record).mtimeMs >= cutoff) continue;
          rmSync(e.dir, { recursive: true, force: true });
          rmSync(record, { force: true });
          total -= e.bytes;
          gone.add(e.dir);
          log(`removed ${Date.now() - e.used > COLD_MS ? "cold" : "over-budget"} cache ${basename(dirname(e.dir))}/${basename(e.dir)}`);
        } finally { unlock(); }
      }
    }
  } finally { release(); }
}

/// Puts a finished directory in place of `final` (a rename: whoever looks sees all of it or nothing).
function install(tmp: string, final: string, manifest: object) {
  writeFileSync(join(tmp, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n");
  rmSync(final, { recursive: true, force: true });
  renameSync(tmp, final);
}
function fresh(part: string): string {
  const parent = join(CACHE, part);
  mkdirSync(parent, { recursive: true });
  // What a process killed while getting one left.
  for (const name of readdirSync(parent)) {
    const pid = Number(name.match(/^\.tmp-(\d+)-/)?.[1] ?? 0);
    if (!pid || pid === process.pid) continue;
    try { process.kill(pid, 0); } catch { rmSync(join(parent, name), { recursive: true, force: true }); }
  }
  const dir = join(parent, `.tmp-${process.pid}-${randomBytes(4).toString("hex")}`);
  mkdirSync(dir);
  return dir;
}
const complete = (dir: string, part: string, target: Target) =>
  existsSync(join(dir, "manifest.json")) && P(part).files(target).every((f) => existsSync(join(dir, f)));

function unpack(tgz: string, part: string, target: Target, k: string, from: string): string {
  const tmp = fresh(part);
  try {
    run(TAR, ["-xzf", tgz, "-C", tmp]);
    if (!P(part).files(target).every((f) => existsSync(join(tmp, f)))) throw new Error(`${basename(tgz)} lacks ${P(part).files(target).join(", ")}`);
    const manifest = existsSync(join(tmp, "manifest.json")) ? JSON.parse(readFileSync(join(tmp, "manifest.json"), "utf8")) : {};
    for (const [field, expected] of Object.entries({ part, target, key: k })) {
      if (manifest[field] !== undefined && manifest[field] !== expected) {
        throw new Error(`${basename(tgz)} has a different ${field} in its manifest`);
      }
    }
    const final = cached(part, target, k);
    install(tmp, final, { ...manifest, part, target, key: k, from });
    return final;
  } catch (error) {
    rmSync(tmp, { recursive: true, force: true });
    throw error;
  }
}

/// How long a download may go with nothing coming (no connection, no answer, no byte) before it is given up on and the
/// next place asked. The CI Macs' route to the store stalls now and then, and a stall waited out to the download's
/// 300 s cut the stable release's jobs at their limit (43458373814, 43460534865, 2026-11-13: four stalls of 177-303 s
/// in one night, the same part from GitHub's release in 4 s); a part sent at all comes far faster than this.
const STALLED_MS = 15_000;
/// A download still coming slower than this after SLOW_AFTER_MS is given up on as a stall is, and the next place asked.
/// The CI Mac's direct route to the store (STILLFAIL_DIRECT_DNS) trickled for 300 s and broke off, part after part, while
/// the usual route sent the same part in 20 s (mini1, Publish stable 43616763857, 2026-11-15: four attempts of the
/// station job, each cut at its 10 minutes by one such part); every part is at most tens of MB.
const SLOW_AFTER_MS = 20_000;
const SLOWEST_BYTES_PER_S = 200_000;
/// A download given up on as stalled or too slow (STALLED_MS, SLOWEST_BYTES_PER_S): the next place is asked, not this.
class Stalled extends Error {}
const stalledOut = (e: unknown) => e instanceof Stalled || (e as Error | undefined)?.name === "TimeoutError";
/// A place that answered 5xx or 429, or whose connection or stream broke off (not a stall), is asked again, ATTEMPTS
/// times in all, RETRY_MS × the tries so far between: a gateway's one 504 said a part was not prebuilt, the release's
/// download and then its API each asked once (preview's ios, main eb3f3a3a, 43992166607, 2026-11-17: 504, then 403
/// without GH_TOKEN). A 404 is an answer: never asked again.
const ATTEMPTS = 3;
const RETRY_MS = Number(process.env.STILLFAIL_NATIVE_RETRY_MS ?? 2_000);
const passing = (status: number) => status >= 500 || status === 429;
const pause = (ms: number) => new Promise<void>((done) => setTimeout(done, ms)); // timer: a retry after a failure, with a backoff

async function fetchWatchedBytes(getResponse: (signal: AbortSignal) => Promise<Response>): Promise<{ response: Response; bytes: Buffer | null }> {
  const stalled = new AbortController();
  let timer: ReturnType<typeof setTimeout> | undefined;
  const moved = () => {
    clearTimeout(timer);
    timer = setTimeout(() => stalled.abort(new Stalled(`nothing came for ${STALLED_MS / 1000} s`)), STALLED_MS);
  };
  moved();
  const begun = Date.now();
  let got = 0;
  const slow = setInterval(() => { // timer: a deadline, the download's rate looked at
    const ms = Date.now() - begun;
    if (ms >= SLOW_AFTER_MS && got / (ms / 1000) < SLOWEST_BYTES_PER_S) {
      stalled.abort(new Stalled(`${(got / 1e6).toFixed(1)} MB in ${(ms / 1000).toFixed(0)} s`));
    }
  }, 1_000);
  try {
    const signal = AbortSignal.any([stalled.signal, AbortSignal.timeout(300_000)]);
    const response = await getResponse(signal);
    moved();
    if (!response.ok) return { response, bytes: null };
    const chunks: Uint8Array[] = [];
    if (response.body) {
      const reader = response.body.getReader();
      for (let next = await reader.read(); !next.done; next = await reader.read()) {
        chunks.push(next.value);
        got += next.value.length;
        moved();
      }
    }
    return { response, bytes: Buffer.concat(chunks) };
  } finally { clearTimeout(timer); clearInterval(slow); }
}

// The browser download endpoint can fail while GitHub's release API and the asset itself are still available. Only
// try this after that endpoint fails, so an unpublished part does not spend an API request on every build.
async function releaseThroughApi(name: string): Promise<{ bytes: Buffer; url: string } | null> {
  for (let n = 1; ; n++) {
    const got = await releaseThroughApiOnce(name);
    if (got !== "again") return got;
    if (n >= ATTEMPTS) return null;
    await pause(RETRY_MS * n);
  }
}
/// One try of it: "again" where what failed may pass (5xx, 429, a connection or a stream broken off).
async function releaseThroughApiOnce(name: string): Promise<{ bytes: Buffer; url: string } | null | "again"> {
  const [owner, repo, extra] = REPO.split("/");
  if (!owner || !repo || extra !== undefined) return null;
  const root = `${GITHUB_API}/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/releases`;
  const token = process.env.GH_TOKEN ?? process.env.GITHUB_TOKEN;
  const api = async (url: string, accept: string, signal: AbortSignal): Promise<Response> => {
    const get = (authenticated: boolean) => fetch(url, {
      headers: { accept, ...(authenticated && token ? { authorization: `Bearer ${token}` } : {}) },
      // Keep the token at api.github.com; an asset redirect goes to a separate, signed download URL.
      redirect: "manual", signal,
    });
    const r = await get(Boolean(token));
    return token && (r.status === 401 || r.status === 403) ? get(false) : r;
  };
  try {
    const found = await api(`${root}/tags/${encodeURIComponent(RELEASE)}`, "application/vnd.github+json", AbortSignal.timeout(30_000));
    if (!found.ok) {
      log(`release API answered ${found.status}`);
      await found.body?.cancel().catch(() => {});
      return passing(found.status) ? "again" : null;
    }
    const release = await found.json() as { assets?: { name?: unknown; id?: unknown; digest?: unknown }[] };
    const asset = Array.isArray(release.assets) ? release.assets.find((a) => a.name === name) : undefined;
    if (!asset || typeof asset.id !== "number" || !Number.isSafeInteger(asset.id) || asset.id <= 0) return null;
    const url = `${root}/assets/${asset.id}`;
    const initial = await api(url, "application/octet-stream", AbortSignal.timeout(STALLED_MS));
    let response: Response;
    let bytes: Buffer | null;
    if ([301, 302, 303, 307, 308].includes(initial.status)) {
      const location = initial.headers.get("location");
      await initial.body?.cancel().catch(() => {});
      if (location === null) return null;
      const destination = new URL(location, url);
      // (https: only, as the API's own is; http: only for the test's server)
      if (destination.protocol !== new URL(root).protocol) return null;
      ({ response, bytes } = await fetchWatchedBytes((signal) =>
        fetch(destination, { headers: { accept: "application/octet-stream" }, redirect: "follow", signal })));
    } else if (!initial.ok) {
      log(`release asset API answered ${initial.status}`);
      await initial.body?.cancel().catch(() => {});
      return passing(initial.status) ? "again" : null;
    } else {
      ({ response, bytes } = await fetchWatchedBytes(async () => initial));
    }
    if (!response.ok || !bytes) { log(`release asset API answered ${response.status}`); return passing(response.status) ? "again" : null; }
    // Some GitHub API versions answer metadata rather than bytes when they cannot serve the asset.
    if (bytes[0] !== 0x1f || bytes[1] !== 0x8b) { log("release asset API did not give a gzip archive"); return null; }
    if (typeof asset.digest === "string" && asset.digest.startsWith("sha256:") &&
        asset.digest !== `sha256:${createHash("sha256").update(bytes).digest("hex")}`) {
      log("release asset API gave bytes with a different digest");
      return null;
    }
    return { bytes, url };
  } catch (e) {
    log(`release API could not give ${name} (${(e as Error).message})`);
    return stalledOut(e) ? null : "again";
  }
}

async function download(part: string, target: Target, k: string): Promise<string | null> {
  const name = asset(part, target, k);
  const inbox = process.env.STILLFAIL_NATIVE_INBOX;
  if (inbox && existsSync(join(inbox, name))) {
    log(`${part} ${target} ${k}: from ${inbox}`);
    return unpack(join(inbox, name), part, target, k, "inbox");
  }
  // a prebuilt one's store, then the release CI publishes to
  const started = Date.now();
  let url = "";
  let bytes: Buffer | null = null;
  // (set from inside each try, below)
  const release = { failed: false, notFound: false };
  const releaseUrl = `${GITHUB}/${REPO}/releases/download/${RELEASE}/${name}`;
  // (each place in turn: one that answers and then breaks off is said so, and the next one asked: a body cut short
  // failed the whole job with only the socket's error, 39431384793)
  // (the store by the direct route where the CI Mac has one, then by the usual route, then the release)
  const places: [string, boolean][] = [[`${STORE}/${name}`, true]];
  if (process.env.STILLFAIL_DIRECT_DNS) places.push([`${STORE}/${name}`, false]);
  places.push([releaseUrl, false]);
  // One try of a place: its bytes, "next" (its answer, or a stall: the next place asked) or "again" (5xx, 429,
  // a connection or a stream broken off: this place asked again, ATTEMPTS in all)
  const once = async (at: string, direct: boolean): Promise<Buffer | "next" | "again"> => {
    let answered = false;
    // (given up on once nothing came for STALLED_MS, the connection's or a byte's, or once it still comes slower than
    // SLOWEST_BYTES_PER_S after SLOW_AFTER_MS, and the next place asked)
    const stalled = new AbortController();
    let timer: ReturnType<typeof setTimeout> | undefined;
    const moved = () => {
      clearTimeout(timer);
      timer = setTimeout(() => stalled.abort(new Stalled(`nothing came for ${STALLED_MS / 1000} s`)), STALLED_MS);
    };
    moved();
    const begun = Date.now();
    let got = 0;
    const slow = setInterval(() => { // timer: a deadline, the download's rate looked at
      const ms = Date.now() - begun;
      if (ms >= SLOW_AFTER_MS && got / (ms / 1000) < SLOWEST_BYTES_PER_S) {
        stalled.abort(new Stalled(`${(got / 1e6).toFixed(1)} MB in ${(ms / 1000).toFixed(0)} s`));
      }
    }, 1_000);
    try {
      const signal = AbortSignal.any([stalled.signal, AbortSignal.timeout(300_000)]);
      const r = direct ? await fetchNative(at, { redirect: "follow", signal }) : await fetch(at, { redirect: "follow", signal });
      moved();
      if (!r.ok) {
        if (at === releaseUrl) {
          if (r.status === 404) release.notFound = true;
          else release.failed = true;
        }
        if (r.status !== 404) log(`${part} ${target}: ${at} answered ${r.status}`);
        await r.body?.cancel().catch(() => {});
        return passing(r.status) ? "again" : "next";
      }
      answered = true;
      const chunks: Uint8Array[] = [];
      if (r.body) {
        const reader = r.body.getReader();
        for (let next = await reader.read(); !next.done; next = await reader.read()) { chunks.push(next.value); got += next.value.length; moved(); }
      }
      return Buffer.concat(chunks);
    } catch (e) {
      if (at === releaseUrl) release.failed = true;
      const cause = (e as Error & { cause?: Error }).cause?.message;
      log(`${part} ${target}: ${answered ? `${at} broke off while sending it` : `could not reach ${new URL(at).host}`} (${(e as Error).message}${cause ? `: ${cause}` : ""})`);
      return stalledOut(e) ? "next" : "again";
    } finally { clearTimeout(timer); clearInterval(slow); }
  };
  places: for (const [at, direct] of places) {
    for (let n = 1; ; n++) {
      const tried = await once(at, direct);
      if (Buffer.isBuffer(tried)) { bytes = tried; url = at; break places; }
      if (tried === "next" || n >= ATTEMPTS) break;
      await pause(RETRY_MS * n);
    }
  }
  // A 404 there is asked of the API too in CI's consumer jobs (STILLFAIL_NATIVE_INBOX, set by .github/actions/natives):
  // the download endpoint's edge kept answering 404 for a part 47 s after the natives job had published it, while the
  // API had it (check-station 44892476775); elsewhere a 404 spends no API request.
  if (!bytes && (release.failed || (release.notFound && Boolean(process.env.STILLFAIL_NATIVE_INBOX)))) {
    const fromApi = await releaseThroughApi(name);
    if (fromApi !== null) { bytes = fromApi.bytes; url = fromApi.url; }
  }
  if (!bytes) return null;
  const tgz = join(tmpdir(), `${name}.${process.pid}`);
  writeFileSync(tgz, bytes);
  try {
    const dir = unpack(tgz, part, target, k, url);
    log(`${part} ${target} ${k}: downloaded (${(bytes.length / 1e6).toFixed(1)} MB, ${((Date.now() - started) / 1000).toFixed(1)} s)`);
    return dir;
  } finally { rmSync(tgz, { force: true }); }
}

function buildHere(part: string, target: Target, k: string): string {
  const started = Date.now();
  if (onWindows(part, target) && !["win32", "darwin"].includes(osPlatform())) throw new Error(`${part} ${target} ${k} is not prebuilt: Windows builds it, or a Mac cross-builds it (node scripts/native.ts prebuild ${part}:${target})`);
  if (onLinux(part, target) && osPlatform() !== "linux") throw new Error(`${part} ${target} ${k} is not prebuilt: a Linux ${target} machine builds it (the prebuild workflow, gh workflow run prebuild.yml -R ${REPO} --ref <branch>)`);
  log(`${part} ${target} ${k}: not prebuilt; building it here${P(part).inputs && P(part).rust !== false ? " (cargo)" : ""}…`);
  const tmp = fresh(part);
  try {
    P(part).build(target, tmp);
  } catch (e) {
    rmSync(tmp, { recursive: true, force: true });
    throw e;
  } finally {
    checkout = null;
  }
  const final = cached(part, target, k);
  install(tmp, final, { part, target, key: k, from: "built", host: hostname(), builtAt: new Date().toISOString(), toolchain: TOOLCHAIN, commit: git(["rev-parse", "HEAD"]).trim() });
  log(`${part} ${target} ${k}: built in ${((Date.now() - started) / 1000).toFixed(0)} s`);
  return final;
}

/// The part's directory in the cache: there already, downloaded, or built ("prebuild": the prebuild command's, the one
/// that builds a prebuilt part on CI).
async function getKey(part: string, target: Target, k: string, mode: "any" | "fetch" | "build" | "prebuild" = "any"): Promise<string> {
  const dir = cached(part, target, k);
  const budget = cacheBudget();
  if (!budget && mode !== "build" && complete(dir, part, target)) { noteUse(dir); return dir; }
  const policy = process.env.STILLFAIL_NATIVE ?? "";
  let made = false;
  const result = await lockedAsync(dir, async () => {
    if (mode !== "build" && complete(dir, part, target)) { noteUse(dir); return dir; }
    made = true;
    // Room before a download or a build writes tens of MB: on a disk near full the write failed (ENOSPC) before the
    // trim after it was reached (44253499545, 2026-11-18).
    if (budget) try { trimCache(budget); } catch (e) { log(`could not trim the cache: ${(e as Error).message}`); }
    if (mode !== "build" && policy !== "build" && policy !== "offline") {
      const got = await download(part, target, k);
      if (got) { noteUse(got); return got; }
    }
    // What is prebuilt (`msvc`) CI builds only in the prebuild workflow, run by hand: anywhere else said, with how.
    if (mode !== "prebuild" && P(part).prebuilt && process.env.CI) {
      throw new Error(`${part} ${target} ${k} is not prebuilt: on a Mac, node scripts/native.ts prebuild --release ${part}:${target} (every target: prebuild --release ${P(part).targets.map((t) => `${part}:${t}`).join(" ")})`);
    }
    if (mode !== "prebuild" && P(part).msvc && (mode === "fetch" || ((onWindows(part, target) || onLinux(part, target)) && process.env.CI))) {
      throw new Error(`${part} ${target} ${k} is not prebuilt: run the prebuild workflow on the branch, gh workflow run prebuild.yml -R ${REPO} --ref ${process.env.GITHUB_REF_NAME || "<branch>"} (or on a Mac, node scripts/native.ts prebuild ${part}:${target})`);
    }
    if (mode === "fetch" || policy === "offline") throw new Error(`${part} ${target} ${k} is not prebuilt (STILLFAIL_NATIVE=${policy || "-"}, ${mode})`);
    // n0's relay is downloaded from n0 whatever the policy: "building" it is that.
    const built = buildHere(part, target, k);
    noteUse(built);
    return built;
  });
  const after = budget || (made ? LOCAL_BUDGET_BYTES : 0);
  if (after) try { trimCache(after); } catch (e) { log(`could not trim the cache: ${(e as Error).message}`); }
  return result;
}

async function get(part: string, target: Target, mode: "any" | "fetch" | "build" | "prebuild" = "any"): Promise<string> {
  return getKey(part, target, key(part, target), mode);
}
async function lockedAsync<T>(dir: string, f: () => Promise<T>): Promise<T> {
  const release = acquire(dir);
  try { return await f(); } finally { release(); }
}
/// For the builds of other parts (the engine needs the shell): synchronously, from the cache or built.
function ensure(part: string, target: Target): string {
  const k = key(part, target);
  const dir = cached(part, target, k);
  if (complete(dir, part, target)) {
    if (!cacheBudget()) { noteUse(dir); return dir; }
    const release = acquire(dir);
    try { if (complete(dir, part, target)) { noteUse(dir); return dir; } } finally { release(); }
  }
  const out = execFileSync(process.execPath, [join(ROOT, "scripts/native.ts"), "path", part, target], { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] });
  return out.trim();
}

// ── building ──

function run(cmd: string, args: string[], options: SpawnSyncOptions = {}) {
  const done = spawnSync(cmd, args, { stdio: ["ignore", process.stderr, process.stderr], ...options });
  if (done.error) throw done.error;
  if (done.status !== 0) throw new Error(`${cmd} ${args.join(" ")}: exit ${done.status ?? done.signal}`);
}
function rustEnv(extra: Record<string, string> = {}): NodeJS.ProcessEnv {
  const home = homedir();
  return {
    ...process.env,
    PATH: [join(home, ".cargo/bin"), "/opt/homebrew/bin", process.env.PATH].join(delimiter),
    RUSTUP_TOOLCHAIN: TOOLCHAIN,
    CARGO_INCREMENTAL: "0",
    ...extra,
  };
}
/// The toolchain and (when given) the target, installed when missing (serialized behind a lock so parallel builds do
/// not race in rustup).
export function rustTarget(triple?: string) {
  const env = rustEnv();
  // `ensure` runs up to 3 builds in parallel; rustup mutates shared ~/.rustup downloads and toolchain dirs in place,
  // so concurrent installs corrupt the toolchain on fresh runners (45460250774, 45461499107). The lock lives in CACHE
  // (one per user/runner by default; separate STILLFAIL_NATIVE_CACHE dirs on one host do not share it).
  const release = acquire(join(CACHE, ".rustup"));
  try {
    let installed = spawnSync("rustup", ["target", "list", "--installed", "--toolchain", TOOLCHAIN], { env, encoding: "utf8" });
    if (installed.status !== 0) {
      run("rustup", ["toolchain", "install", TOOLCHAIN, "--profile", "minimal"], { env });
      if (triple) installed = spawnSync("rustup", ["target", "list", "--installed", "--toolchain", TOOLCHAIN], { env, encoding: "utf8" });
    }
    if (triple && !(installed.stdout ?? "").split(/\r?\n/).includes(triple)) {
      run("rustup", ["target", "add", "--toolchain", TOOLCHAIN, triple], { env });
    }
  } finally {
    release();
  }
}
function cargo(args: string[], cwd: string, extra: Record<string, string>) {
  const env = rustEnv(extra);
  rustTarget(args[args.indexOf("--target") + 1]!.replace(/\.2\.28$/, ""));
  if (args[0] === "zigbuild") {
    const zig = spawnSync("zig", ["version"], { env, encoding: "utf8" }).stdout?.trim();
    if (zig !== ZIG) log(`zig ${zig ?? "(none)"} here, the key assumes ${ZIG}`);
  }
  run("cargo", args, { cwd, env });
}
/// Where a part's cargo build goes: the job's own target (CI sets CARGO_TARGET_DIR), a directory of its own in it.
const targetDir = (own: string, part: string) => (process.env.CARGO_TARGET_DIR ? join(process.env.CARGO_TARGET_DIR, "native", part) : own);
function androidHome(): string {
  return process.env.ANDROID_HOME ?? (osPlatform() === "darwin" ? join(homedir(), "Library/Android/sdk") : join(homedir(), "Android/Sdk"));
}
function androidEnv(): Record<string, string> {
  const env: Record<string, string> = { ANDROID_HOME: androidHome(), ANDROID_NDK_HOME: join(androidHome(), "ndk", NDK) };
  if (!process.env.JAVA_HOME && existsSync("/usr/libexec/java_home")) env.JAVA_HOME = execFileSync("/usr/libexec/java_home", { encoding: "utf8" }).trim();
  return env;
}
function ndkEnv(): Record<string, string> {
  const ndk = join(androidHome(), "ndk", NDK);
  const llvm = join(ndk, "toolchains/llvm/prebuilt", osPlatform() === "darwin" ? "darwin-x86_64" : "linux-x86_64", "bin");
  const clang = join(llvm, `aarch64-linux-android${ANDROID_API}-clang`);
  if (!existsSync(clang)) throw new Error(`Missing NDK: install ndk;${NDK} in ${androidHome()}`);
  return {
    ...androidEnv(),
    CC_aarch64_linux_android: clang,
    AR_aarch64_linux_android: join(llvm, "llvm-ar"),
    CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER: clang,
    // Android 15+ devices may use 16 KiB pages.
    CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS: SHELL_RUSTFLAGS,
  };
}
function findFile(dir: string, match: (path: string) => boolean): string | null {
  if (!existsSync(dir)) return null;
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) { const f = findFile(p, match); if (f) return f; } else if (match(p)) return p;
  }
  return null;
}

// ── publishing (CI on main) ──

function gh(args: string[], options: { allowFail?: boolean } = {}): string {
  const done = spawnSync("gh", args, { encoding: "utf8", maxBuffer: 64 << 20 });
  if (done.status !== 0 && !options.allowFail) throw new Error(`gh ${args.join(" ")}: ${done.stderr}`);
  return done.status === 0 ? done.stdout : "";
}
// A file put on the release, tried again twice when GitHub's answer does not get through (EOF from the CI Mac,
// mbui-media-runtime 41766375019, 2026-11-04), over what a broken try left of it (--clobber: the same name, the same key).
function upload(file: string): void {
  for (let attempt = 1; ; attempt++) {
    try {
      gh(["release", "upload", RELEASE, file, "-R", REPO, ...(attempt > 1 ? ["--clobber"] : [])]);
      return;
    } catch (e) {
      if (attempt === 3) throw e;
      console.error(`${basename(file)}: not uploaded (try ${attempt}), trying again: ${String(e).trim()}`);
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10_000);
    }
  }
}
// The release keeps the newest KEEP of each part and target (`only`: of those groups, `part-target`). GitHub takes at
// most 1000 assets on a release; every publisher prunes what it published, so none grows past KEEP: mbui-figure's film
// and figure, published on every change to mbui, reached 150 each while only pipeline's natives job pruned, and the
// release's 1000 failed main's mbui-media-runtime (42734298404, 2026-11-10).
const KEEP = 20;
function prune(keep: number, only?: Set<string>): void {
  // (a list GitHub's answer did not get through for prunes nothing, left for the next prune as one DELETE dropped is
  // below: an EOF on it failed main's mbui-media-runtime film with both its programs already published, 89ddb06c
  // 42961511598, 2026-11-11)
  const listed = gh(["api", "--paginate", `repos/${REPO}/releases/tags/${RELEASE}`, "--jq", "[.assets[] | {id, name, created_at}]"], { allowFail: true });
  if (!listed) {
    console.log(`the release's assets not listed: the next prune prunes them`);
    return;
  }
  const assets = JSON.parse(listed) as { id: number; name: string; created_at: string }[];
  const groups = new Map<string, typeof assets>();
  for (const a of assets) {
    const g = a.name.replace(/-[0-9a-f]{24}\.tar\.gz$/, "");
    if (!only || only.has(g)) groups.set(g, [...(groups.get(g) ?? []), a]);
  }
  for (const [, list] of groups) {
    list.sort((a, b) => (a.created_at < b.created_at ? 1 : -1));
    // (one GitHub dropped is left for the next prune: an EOF on one DELETE failed main's natives job, 6484574c, 2026-11-04)
    for (const a of list.slice(keep)) {
      const done = spawnSync("gh", ["api", "-X", "DELETE", `repos/${REPO}/releases/assets/${a.id}`], { encoding: "utf8" });
      console.log(done.status === 0 ? `deleted ${a.name}` : `${a.name} not deleted (${done.stderr.trim()}): the next prune deletes it`);
    }
  }
}
async function published(): Promise<Set<string> | null> {
  // (one request, by fetch with the job's token where there is one: the release's own answer lists every asset, 180 of
  // them as they are kept. Through gh it was 21-35 s of Windows mbui runs with nothing missing, its first call in the job
  // (a later one 1 s), curl or fetch 0-1 s, on GitHub's Windows runner, 2026-10-24/25)
  const token = process.env.GH_TOKEN ?? process.env.GITHUB_TOKEN;
  if (token) {
    try {
      const r = await fetch(`${GITHUB_API}/repos/${REPO}/releases/tags/${RELEASE}`, {
        headers: { authorization: `Bearer ${token}`, accept: "application/vnd.github+json" },
        signal: AbortSignal.timeout(30_000),
      });
      if (r.ok) return new Set(((await r.json()) as { assets: { name: string }[] }).assets.map((a) => a.name));
    } catch {
      // (gh, as without a token)
    }
  }
  const out = gh(["api", `repos/${REPO}/releases/tags/${RELEASE}`, "--jq", ".assets[].name"], { allowFail: true });
  return out ? new Set(out.split("\n").filter(Boolean)) : null;
}
/// A fetch asked again, ATTEMPTS times in all and RETRY_MS × the tries so far between, when it threw (a connection or
/// its body broken off: one `fetch failed` ended main's store-sync after seven parts downloaded, none put, 44669202703,
/// 2026-11-20) or answered 5xx or 429; read takes an answer's body inside the try, so a body cut short is asked again
/// too. Each try is given its own init (a fresh AbortSignal.timeout). What still fails is thrown, or answered.
async function fetchRetry<T>(url: string, init: () => RequestInit, read: (r: Response) => Promise<T>, attempts = ATTEMPTS): Promise<{ response: Response; value: T | null }> {
  for (let n = 1; ; n++) {
    try {
      const response = await fetch(url, init());
      if (passing(response.status) && n < attempts) await response.body?.cancel().catch(() => {});
      else if (!response.ok) { await response.body?.cancel().catch(() => {}); return { response, value: null }; }
      else return { response, value: await read(response) };
    } catch (e) {
      if (n >= attempts) throw e;
    }
    await pause(RETRY_MS * n);
  }
}
async function exists(name: string): Promise<boolean> {
  const { response } = await fetchRetry(`${GITHUB}/${REPO}/releases/download/${RELEASE}/${name}`,
    () => ({ method: "HEAD", redirect: "manual", signal: AbortSignal.timeout(30_000) }), async () => null);
  return response.status === 302 || response.status === 200;
}
/// Whether the store of prebuilt parts has it (asked twice when the first try threw: one break taken for its lack sent
/// the part to be downloaded and put again).
async function inStore(name: string): Promise<boolean> {
  for (let n = 1; ; n++) {
    try {
      // (its first byte: the store answers HEAD 404 for what it has)
      const r = await fetchNative(`${STORE}/${name}`, { headers: { Range: "bytes=0-0" }, redirect: "follow", signal: AbortSignal.timeout(30_000) });
      await r.body?.cancel();
      return r.ok;
    } catch {
      if (n >= 2) return false;
    }
    await pause(RETRY_MS * n);
  }
}
/// Each of items through f, at most `width` at once, the answers in the items' order.
async function inTurn<T, U>(items: T[], width: number, f: (item: T) => Promise<U>): Promise<U[]> {
  const out: U[] = new Array(items.length);
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(width, items.length) }, async () => {
    while (next < items.length) { const i = next++; out[i] = await f(items[i]!); }
  }));
  return out;
}
// pigz gzips on every core (a reader's package took ~10 s of one with tar's gzip): the same .tar.gz, read by tar -xzf
// and gunzipSync. --use-compress-program, which GNU tar and bsdtar both take (bsdtar's -I is -T); not on Windows;
// STILLFAIL_NO_PIGZ=1 turns it off.
let pigzHere: boolean | undefined;
const pigz = (): boolean =>
  (pigzHere ??= osPlatform() !== "win32" && process.env.STILLFAIL_NO_PIGZ !== "1" && spawnSync("pigz", ["--version"], { stdio: "ignore" }).status === 0);
function pack(dir: string, name: string, into: string): string {
  const file = join(into, name);
  run(TAR, pigz() ? ["--use-compress-program=pigz", "-cf", file, "-C", dir, "."] : ["-czf", file, "-C", dir, "."]);
  return file;
}

// ── commands ──

export const pair = (args: string[]): [string, Target] => {
  const part = args[0] ?? fail("which part?");
  P(part);
  const target = (args[1] as Target) ?? defaultTarget(part);
  if (!P(part).targets.includes(target)) throw new Error(`${part} has no target ${target} (${P(part).targets.join(", ")})`);
  return [part, target];
};
const mainFile = (part: string, target: Target, dir: string) => join(dir, P(part).files(target)[0]!);

async function main(argv: string[]) {
  const [cmd, ...args] = argv;
  useTree = ["status", "missing", "ensure", "prebuild", "store-sync"].includes(cmd ?? "") || (cmd === "run" && args.indexOf("--") > 1);
  switch (cmd) {
    case "key": { const [p, t] = pair(args); console.log(key(p, t)); return; }
    case "path": { const [p, t] = pair(args); console.log(await get(p, t)); return; }
    case "file": { const [p, t] = pair(args); console.log(mainFile(p, t, await get(p, t))); return; }
    case "file-key": {
      const [p, target, k] = args;
      if (!p || !target || !k || args.length !== 3 || !/^[0-9a-f]{24}$/.test(k) || !P(p).targets.includes(target as Target)) {
        throw new Error("usage: native.ts file-key <part> <target> <24-digit key>");
      }
      const t = target as Target;
      const dir = await getKey(p, t, k, "fetch");
      const manifest = JSON.parse(readFileSync(join(dir, "manifest.json"), "utf8"));
      if (manifest.part !== p || manifest.target !== t || manifest.key !== k) {
        throw new Error(`${p} ${t} ${k}: cached manifest does not match the requested version`);
      }
      console.log(mainFile(p, t, dir));
      return;
    }
    case "fetch": { const [p, t] = pair(args); console.log(await get(p, t, "fetch")); return; }
    // The cache within STILLFAIL_NATIVE_CACHE_MAX_BYTES, for jobs that get no part (.github/actions/setup-mac/prune-disk.sh).
    case "trim": { trimCache(cacheBudget() || LOCAL_BUDGET_BYTES); return; }
    case "build": { const [p, t] = pair(args); console.log(await get(p, t, "build")); return; }
    case "run": {
      const at = args.indexOf("--");
      if (at < 1) throw new Error("usage: native.ts run <part>… -- <command…>");
      const env = { ...process.env };
      for (const part of args.slice(0, at)) {
        const [p, t] = pair([part]);
        const name = P(p).env;
        if (!name) throw new Error(`${p} has no variable`);
        if (!env[name]) env[name] = mainFile(p, t, await get(p, t));
      }
      const [command, ...rest] = args.slice(at + 1);
      const done = spawnSync(command ?? fail("no command"), rest, { stdio: "inherit", env });
      process.exit(done.status ?? 1);
    }
    case "iroh-pkg": {
      const out = resolve(args[0] ?? join(ROOT, "web/src/core/iroh-pkg"));
      const k = key("iroh-wasm", "wasm32");
      // Put there once per key: a dev server watching it sees a change only when there is one.
      if (existsSync(join(out, ".key")) && readFileSync(join(out, ".key"), "utf8").trim() === k && !existsSync(join(out, ".stand-in"))) { console.log(out); return; }
      const dir = await get("iroh-wasm", "wasm32");
      rmSync(out, { recursive: true, force: true });
      mkdirSync(out, { recursive: true });
      for (const f of P("iroh-wasm").files("wasm32")) copyFileSync(join(dir, f), join(out, f));
      // When this core was put here: a page on a newer one starts its own worker, and the older retires (web/src/core/built.ts).
      writeFileSync(join(out, "built.js"), `export const BUILT_AT = ${Date.now()};\n`);
      writeFileSync(join(out, "built.d.ts"), "export declare const BUILT_AT: number;\n");
      writeFileSync(join(out, ".key"), k + "\n");
      console.log(out);
      return;
    }
    case "status": {
      const remote = await published();
      for (const [p, part] of Object.entries(PARTS)) for (const t of part.targets) {
        const k = key(p, t);
        const local = complete(cached(p, t, k), p, t) ? "cached" : "-";
        const up = remote ? (remote.has(asset(p, t, k)) ? "published" : "-") : (await exists(asset(p, t, k))) ? "published" : "-";
        console.log(`${p.padEnd(12)} ${t.padEnd(14)} ${k}  ${local.padEnd(7)} ${up}`);
      }
      return;
    }
    case "parts": {
      // What `ensure` and `missing` take without parts named, one a line (CI's natives-main takes them less one).
      for (const [p, t] of defaults(args.includes("--windows"), args.includes("--mac"), args.includes("--linux"))) console.log(`${p}:${t}`);
      return;
    }
    case "missing": {
      // Each part (default: all of ours) the release lacks, one a line: CI's plan skips the natives job when none is.
      // --windows: those only Windows builds (the natives-win job's); --mac: Apple's (natives-mac); --linux: the rest
      // that CI builds on ci-1 (natives); without them, all of ours that CI builds. Flags and parts named together are
      // all of them, each once (`missingWanted`): plan asks once for every list it splits (pipeline.yml's natives step).
      // --prebuilt: the prebuilt ones (`msvc`) that neither the store nor the release has (the prebuild workflow's).
      if (args.includes("--prebuilt")) {
        for (const [p, t] of ours()) {
          if (!P(p).msvc && !P(p).prebuilt) continue;
          const name = asset(p, t, key(p, t));
          if (!(await inStore(name)) && !(await exists(name))) console.log(`${p}:${t}`);
        }
        return;
      }
      const wanted = missingWanted(args);
      const remote = (await published()) ?? fail("the release's assets could not be listed");
      // (one the release pruned, KEEP of its group, but the store keeps (store-sync): not missing. The store asked only
      // of those the release lacks, side by side)
      const lacking = wanted.filter(([p, t]) => !remote.has(asset(p, t, key(p, t))));
      const stored = await Promise.all(lacking.map(([p, t]) => inStore(asset(p, t, key(p, t)))));
      lacking.forEach(([p, t], i) => { if (!stored[i]) console.log(`${p}:${t}`); });
      return;
    }
    case "ensure": {
      let publish = false, outbox = "", windows = false, mac = false, linux = false;
      const wanted: [string, Target][] = [];
      for (let i = 0; i < args.length; i++) {
        if (args[i] === "--publish") publish = true;
        else if (args[i] === "--windows") windows = true;
        else if (args[i] === "--mac") mac = true;
        else if (args[i] === "--linux") linux = true;
        else if (args[i] === "--outbox") outbox = args[++i] ?? fail("--outbox DIR");
        else { const [p, t] = args[i]!.split(":"); wanted.push(pair(t ? [p!, t] : [p!])); }
      }
      // Default: all of ours that this kind of machine builds (--windows: MSVC's; --mac: Apple's; --linux: ci-1's).
      if (wanted.length === 0) wanted.push(...defaults(windows, mac, linux));
      const listed = await published();
      const remote = listed ?? new Set<string>();
      // Its assets listed: it is there. Else asked again, and said missing only when GitHub says so: a request that did
      // not get through (EOF) was taken for a missing release (mbui-media-runtime 41457910309).
      if (publish && listed === null) {
        try {
          gh(["release", "view", RELEASE, "-R", REPO, "--json", "name"]);
        } catch (e) {
          if (!/release not found/i.test(String(e))) throw e;
          throw new Error(`the release ${RELEASE} is not on ${REPO}: make it once`);
        }
      }
      if (outbox) mkdirSync(outbox, { recursive: true });
      // Those not here yet, each in a process of its own, three side by side: one after another a branch that changed
      // the shell built shell-station and the reader for each target in turn, its natives job stopped at its 5 minutes
      // (opus-screen-audio 43149224744; the reader's three alone 217 s, mbui-halt-flush-prototype 43154389365,
      // 2026-11-12). What two of them share (shell-apple, a reader's moon build) one takes and the other waits for
      // (`get`'s lock, moon's).
      const todo = wanted.filter(([p, t]) => !complete(cached(p, t, key(p, t)), p, t));
      // The readers sharing the cores are those built here, not those asked for: a caller counts what the store and the
      // release lack, one of which may be in this machine's cache (stable's reader:linux-x64 on ci-1, its linux-arm64
      // left alone at -j 8 of 16, 130 s, the job cut at its 5 minutes, 44770813931).
      const readersToBuild = Math.max(1, Math.min(3, todo.filter(([p]) => p === "reader").length));
      if (todo.length <= 1 && !process.env.STILLFAIL_NATIVE_ONE) process.env.STILLFAIL_NATIVE_READERS = "1";
      if (todo.length > 1 && !process.env.STILLFAIL_NATIVE_ONE) {
        const flags = [...(publish ? ["--publish"] : []), ...(outbox ? ["--outbox", outbox] : []), ...(windows ? ["--windows"] : []), ...(mac ? ["--mac"] : []), ...(linux ? ["--linux"] : [])];
        const one = (p: string, t: Target) => new Promise<number>((done) => {
          const child = spawn(process.execPath, [fileURLToPath(import.meta.url), "ensure", ...flags, `${p}:${t}`],
            { stdio: ["ignore", "inherit", "inherit"], env: { ...process.env, STILLFAIL_NATIVE_ONE: "1", STILLFAIL_NATIVE_READERS: String(readersToBuild) } });
          child.on("exit", (code) => done(code ?? 1));
        });
        const queue = [...wanted];
        const failed: string[] = [];
        await Promise.all([0, 1, 2].map(async () => {
          for (let next = queue.shift(); next; next = queue.shift()) if (await one(...next)) failed.push(next.join(":"));
        }));
        if (failed.length) throw new Error(`not got: ${failed.join(" ")}`);
        return;
      }
      const work = join(tmpdir(), `stillfail-native-${process.pid}`);
      mkdirSync(work, { recursive: true });
      const summary: string[] = [];
      const publishedNow = new Set<string>();
      for (const [p, t] of wanted) {
        const k = key(p, t);
        const name = asset(p, t, k);
        // (in the store, where store-sync keeps what the release pruned: not published again)
        const there = remote.has(name) || (await inStore(name));
        const before = complete(cached(p, t, k), p, t);
        const started = Date.now();
        // Known absent from the release and the store, and not in the inbox: built without asking the download endpoint
        // first, whose 404 its edge then kept serving to the jobs fetching the part just published (44892476775).
        const inboxed = Boolean(process.env.STILLFAIL_NATIVE_INBOX && existsSync(join(process.env.STILLFAIL_NATIVE_INBOX, name)));
        const dir = await get(p, t, !before && listed !== null && !there && !inboxed ? "build" : "any");
        const took = ((Date.now() - started) / 1000).toFixed(0);
        const how = before ? "cached" : JSON.parse(readFileSync(join(dir, "manifest.json"), "utf8")).from === "built" ? "built" : "downloaded";
        let note = "";
        if (!there && publish) {
          const file = pack(dir, name, work);
          upload(file);
          publishedNow.add(`${p}-${t}`);
          note = " → published";
        } else if (!there && outbox) {
          pack(dir, name, outbox);
          note = " → outbox";
        }
        summary.push(`${p} ${t} ${k}: ${how} (${took} s)${there ? ", published already" : note}`);
      }
      rmSync(work, { recursive: true, force: true });
      for (const line of summary) console.log(line);
      if (publishedNow.size) prune(KEEP, publishedNow);
      return;
    }
    case "prebuild": {
      const toRelease = args.includes("--release");
      const wanted: [string, Target][] = [];
      for (const a of args.filter((a) => a !== "--release")) { const [p, t] = a.split(":"); wanted.push(pair(t ? [p!, t] : [p!])); }
      if (wanted.length === 0) for (const [p, t] of ours()) if (onWindows(p, t)) wanted.push([p, t]);
      const work = join(tmpdir(), `stillfail-prebuild-${process.pid}`);
      mkdirSync(join(work, "natives"), { recursive: true });
      let any = false;
      for (const [p, t] of wanted) {
        const k = key(p, t);
        const name = asset(p, t, k);
        // (in either: fetch takes it from both, and main's store-sync copies the release's into the store)
        if ((await inStore(name)) || (await exists(name))) { console.log(`${p} ${t} ${k}: there already`); continue; }
        const started = Date.now();
        const dir = await get(p, t, "prebuild");
        pack(dir, name, join(work, "natives"));
        console.log(`${p} ${t} ${k}: ready (${((Date.now() - started) / 1000).toFixed(0)} s), putting it in the ${toRelease ? "release" : "store"}`);
        any = true;
      }
      try {
        if (any && toRelease) {
          for (const f of readdirSync(join(work, "natives"))) upload(join(work, "natives", f));
          prune(KEEP, new Set(wanted.map(([p, t]) => `${p}-${t}`)));
        }
        else if (any) run("sh", [join(ROOT, "scripts/release-put.sh"), "--files", work], { stdio: "inherit" });
      } finally { rmSync(work, { recursive: true, force: true }); }
      return;
    }
    case "store-sync": {
      const work = join(tmpdir(), `stillfail-store-sync-${process.pid}`);
      mkdirSync(join(work, "natives"), { recursive: true });
      let any = false;
      try {
        // (not the tests' program, reader-harness: only check-station runs it, from the release)
        const parts = ours().filter(([p]) => p !== "reader-harness").map(([p, t]) => ({ p, t, name: asset(p, t, key(p, t)) }));
        // (the store asked 8 at a time, and the release once for all it lacks, by its API: each asked in turn, a HEAD
        // a part for the release, was ~45 s of the job, 44669202703)
        const stored = await inTurn(parts, 8, ({ name }) => inStore(name));
        const release = stored.every(Boolean) ? null : await published();
        for (const [i, { p, t, name }] of parts.entries()) {
          if (stored[i]) { console.log(`${name}: in the store`); continue; }
          // (one the release does not give now is left for main's next run, as prune leaves one GitHub dropped)
          try {
            if (!(release ? release.has(name) : await exists(name))) { console.log(`${name}: in neither (prebuild it: the prebuild workflow, or node scripts/native.ts prebuild ${p}:${t})`); continue; }
            const { response, value } = await fetchRetry(`${GITHUB}/${REPO}/releases/download/${RELEASE}/${name}`,
              () => ({ redirect: "follow", signal: AbortSignal.timeout(300_000) }), async (r) => Buffer.from(await r.arrayBuffer()));
            if (value === null) { console.log(`${name}: the release answered ${response.status}; the next run copies it`); continue; }
            writeFileSync(join(work, "natives", name), value);
          } catch (e) {
            const cause = (e as Error & { cause?: Error }).cause?.message;
            console.log(`${name}: the release failed (${(e as Error).message}${cause ? `: ${cause}` : ""}); the next run copies it`);
            continue;
          }
          console.log(`${name}: from the release, to the store`);
          any = true;
        }
        if (any) run("sh", [join(ROOT, "scripts/release-put.sh"), "--files", work], { stdio: "inherit" });
      } finally { rmSync(work, { recursive: true, force: true }); }
      return;
    }
    case "prune": {
      prune(Number(args[0] ?? KEEP));
      return;
    }
    default:
      process.stderr.write(readFileSync(new URL(import.meta.url), "utf8").split("\n").filter((l) => l.startsWith("//")).map((l) => l.slice(3)).join("\n") + "\n");
      process.exit(cmd ? 2 : 0);
  }
}

/// What `missing` asks of the release: each flag's defaults (--windows, --mac, --linux) and each part named, in that
/// order, each once; with neither, all of ours CI builds. One flag and no part, or parts and no flag, is what it was.
export function missingWanted(args: string[]): [string, Target][] {
  const flags = ["--windows", "--mac", "--linux"];
  const wanted: [string, Target][] = [];
  for (const f of flags) if (args.includes(f)) wanted.push(...defaults(f === "--windows", f === "--mac", f === "--linux"));
  for (const a of args.filter((a) => !flags.includes(a))) { const [p, t] = a.split(":"); wanted.push(pair(t ? [p!, t] : [p!])); }
  if (wanted.length === 0) wanted.push(...defaults(false, false, false));
  const seen = new Set<string>();
  return wanted.filter(([p, t]) => !seen.has(`${p}:${t}`) && !!seen.add(`${p}:${t}`));
}

/// What `ensure` and `missing` take where no part is named: all of ours that this kind of machine builds (--windows:
/// MSVC's; --mac: Apple's; --linux: ci-1's; none of them: all but MSVC's), never what is prebuilt by hand.
export function defaults(windows: boolean, mac: boolean, linux: boolean): [string, Target][] {
  const wanted: [string, Target][] = [];
  for (const [p, t] of ours()) {
    if (onWindows(p, t) !== windows || onLinux(p, t) || P(p).prebuilt) continue;
    if (!windows && mac && !(t in APPLE_TRIPLES)) continue;
    if (!windows && linux && (t in APPLE_TRIPLES)) continue;
    wanted.push([p, t]);
  }
  return wanted;
}

/// Every part and target of ours CI publishes (n0's relay is not ours to publish).
function ours(): [string, Target][] {
  const all: [string, Target][] = [];
  for (const [p, part] of Object.entries(PARTS)) if (p !== "iroh-relay") for (const t of part.publish ?? part.targets) all.push([p, t]);
  return all;
}

/// Every part's name.
export const partNames = (): string[] => Object.keys(PARTS);
/// What a part is made of, as paths in the repository: for every target.
export const inputsOf = (part: string): string[] => [...new Set(P(part).targets.flatMap((t) => inputsFor(P(part), t)))];
/// The targets a part is built for.
export const targetsOf = (part: string): string[] => P(part).targets;
/// The files a part's artifact holds for a target.
export const filesOf = (part: string, target: string): string[] => P(part).files(target as Target);
/// Whether there is such a part.
export const isPart = (name: string): boolean => Object.hasOwn(PARTS, name);

if (import.meta.main) {
  main(process.argv.slice(2)).catch((e) => {
    log((e as Error).message);
    process.exit(1);
  });
}
