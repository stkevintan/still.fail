// Farview's release got by a station whose config names no directory of its own (src/browser/farview-release.ts),
// from Farview's own private release first:
// downloaded once however many chats ask meanwhile, its SHA-256 checked before anything of it is unpacked, the next
// source asked where one gives other bytes, kept where the cache says; the `browser` tool telling an agent how files
// go into a page and come out of it; the release a station takes being the commit the app's client is pinned to.
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { chmod, mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { promisify } from "node:util";
import { FarviewTabs, farviewConfig, farviewHowTo } from "../src/browser/farview.ts";
import { unix } from "../src/platform/unix.ts";
import { windows } from "../src/platform/windows.ts";
import { FARVIEW_RELEASES, farviewAsset, farviewSources, ghSource, nativeCache, unpackRelease } from "../src/browser/farview-release.ts";

const run = promisify(execFile);

/// A release's tarball as tools/package.sh makes one (its directory, bin/host.exe in it), and its SHA-256.
async function tarball(root: string): Promise<{ bytes: Uint8Array; sha256: string }> {
  const src = join(root, "src", "farview-macos-arm64");
  await mkdir(join(src, "bin"), { recursive: true });
  await mkdir(join(src, "lib"), { recursive: true });
  await writeFile(join(src, "bin", "host.exe"), "#!/bin/sh\n");
  await chmod(join(src, "bin", "host.exe"), 0o755);
  await writeFile(join(src, "bin", "agent.exe"), "#!/bin/sh\n");
  const tgz = join(root, "release.tar.gz");
  await run("tar", ["-czf", tgz, "-C", join(root, "src"), "farview-macos-arm64"]);
  const bytes = new Uint8Array(await readFile(tgz));
  return { bytes, sha256: createHash("sha256").update(bytes).digest("hex") };
}

test("a release is downloaded once for every chat that asks meanwhile, checked, and unpacked where the cache keeps it", { skip: process.platform === "win32" && "tar" }, async () => {
  const root = await mkdtemp(join(tmpdir(), "fv-release-"));
  try {
    const { bytes, sha256 } = await tarball(root);
    const releases = { "darwin-arm64": { rev: "0123456789abcdef0123", sha256 } };
    const env = { STILLFAIL_NATIVE_CACHE: join(root, "cache") };
    const config = farviewConfig({}, "darwin-arm64", releases, env)!;
    assert.equal(config.dir, join(root, "cache", "farview", "0123456789ab-darwin-arm64"));
    const asked: string[] = [];
    let let_go!: () => void;
    const held = new Promise<void>((done) => (let_go = done));
    const fv = new FarviewTabs({
      dir: join(root, "data"),
      config: () => config,
      sources: (name) => [`https://store.test/${name}`, `https://release.test/${name}`],
      fetch: async (url) => {
        asked.push(url);
        await held;
        return url.startsWith("https://store.test/") ? null : bytes;
      },
    });
    // three chats at once: one download
    const three = Promise.all([fv.ready(config), fv.ready(config), fv.ready(config)]);
    let_go();
    await three;
    assert.deepEqual(asked, ["https://store.test/farview-darwin-arm64-0123456789ab.tar.gz", "https://release.test/farview-darwin-arm64-0123456789ab.tar.gz"]);
    assert.ok((await stat(config.host)).isFile());
    assert.ok((await stat(config.agent)).isFile());
    // there already: none again, whoever asks
    await fv.ready(config);
    await unpackRelease(config.dir, "darwin-arm64", releases["darwin-arm64"], ["https://nowhere.test/x"], async () => assert.fail("asked again"));
    assert.equal(asked.length, 2);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("a tarball whose SHA-256 is not the release's is refused, nothing of it unpacked, and the next source asked", { skip: process.platform === "win32" && "tar" }, async () => {
  const root = await mkdtemp(join(tmpdir(), "fv-release-"));
  try {
    const { bytes, sha256 } = await tarball(root);
    const release = { rev: "fedcba9876543210", sha256 };
    const dir = join(root, "cache", "farview", "fedcba987654-linux-x64");
    const forged = new Uint8Array([...bytes, 0]);
    // every source's bytes not the release's: refused, saying whose, and nothing where it is looked for
    await assert.rejects(unpackRelease(dir, "linux-x64", release, ["https://a.test/x", "https://b.test/x"], async () => forged), /refused: https:\/\/a\.test\/x \(SHA-256 [0-9a-f]{64}, not [0-9a-f]{64}\); https:\/\/b\.test\/x/);
    await assert.rejects(stat(dir));
    assert.deepEqual(await readdir(join(root, "cache", "farview")).catch(() => []), []);
    // none to be had: said so, with what to do
    await assert.rejects(unpackRelease(dir, "linux-x64", release, ["https://a.test/x"], async () => null), /could not be downloaded.*browser\.farview/);
    // a forged one, then the release's: the release's
    const asked: string[] = [];
    await unpackRelease(dir, "linux-x64", release, ["https://a.test/x", "https://b.test/x"], async (url) => (asked.push(url), url.includes("a.test") ? forged : bytes));
    assert.deepEqual(asked, ["https://a.test/x", "https://b.test/x"]);
    assert.ok((await stat(join(dir, "bin", "host.exe"))).isFile());
    // a failed download is tried again the next time a chat asks
    const config = { ...farviewConfig({}, "linux-x64", { "linux-x64": release }, { STILLFAIL_NATIVE_CACHE: join(root, "other") })! };
    let tries = 0;
    const fv = new FarviewTabs({ dir: join(root, "data"), config: () => config, sources: () => ["https://a.test/x"], fetch: async () => (++tries === 1 ? null : bytes) });
    await assert.rejects(fv.ready(config), /could not be downloaded/);
    await fv.ready(config);
    assert.equal(tries, 2);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("a release is asked of Farview's own private release first, then of still.fail's store and the public one, or where the environment says; kept in the cache native.ts keeps", () => {
  assert.deepEqual(farviewSources("farview-darwin-arm64-0123456789ab.tar.gz", {}), [
    "gh:AFK-surf/farview-legacy@builds/farview-darwin-arm64-0123456789ab.tar.gz",
    "https://app.still.fail/releases/natives/farview-darwin-arm64-0123456789ab.tar.gz",
    "https://github.com/AFK-surf/monoid/releases/download/native-artifacts/farview-darwin-arm64-0123456789ab.tar.gz",
  ]);
  assert.deepEqual(farviewSources("x.tar.gz", { STILLFAIL_FARVIEW_SOURCES: "http://127.0.0.1:9/a, gh:o/r@t" }), ["http://127.0.0.1:9/a/x.tar.gz", "gh:o/r@t/x.tar.gz"]);
  assert.deepEqual(ghSource("gh:AFK-surf/farview-legacy@builds/farview-darwin-arm64-0123456789ab.tar.gz"), { repo: "AFK-surf/farview-legacy", tag: "builds", name: "farview-darwin-arm64-0123456789ab.tar.gz" });
  assert.equal(ghSource("https://github.com/AFK-surf/farview-legacy/x"), null);
  assert.equal(ghSource("gh:AFK-surf/farview-legacy/x"), null);
  assert.equal(nativeCache({ STILLFAIL_NATIVE_CACHE: "/c" }), "/c");
  assert.match(nativeCache({}), /stillfail-native$/);
  // (each system's place, as scripts/native.ts has it)
  assert.equal(windows.nativeCache({ LOCALAPPDATA: "C:\\L" }, "C:\\h"), join("C:\\L", "stillfail-native"));
  if (unix.clonesFiles) assert.equal(unix.nativeCache({ XDG_CACHE_HOME: "/x" }, "/h"), join("/h", "Library", "Caches", "stillfail-native"));
  else {
    assert.equal(unix.nativeCache({ XDG_CACHE_HOME: "/x" }, "/h"), join("/x", "stillfail-native"));
    assert.equal(unix.nativeCache({}, "/h"), join("/h", ".cache", "stillfail-native"));
  }
  assert.equal(farviewAsset("linux-x64", { rev: "0123456789abcdef", sha256: "" }), "farview-linux-x64-0123456789ab.tar.gz");
});

test("the release a station takes is the commit the app's Farview client is pinned to", async () => {
  const pin = (await readFile(join(import.meta.dirname, "..", "..", "apps", "mbui", "farview.pin"), "utf8")).trim();
  assert.ok(Object.keys(FARVIEW_RELEASES).length > 0);
  for (const [target, r] of Object.entries(FARVIEW_RELEASES)) {
    assert.equal(r.rev, pin, `${target}'s release is not the client farview.pin names`);
    assert.match(r.sha256, /^[0-9a-f]{64}$/);
  }
});

test("an agent is told how files go into a page and how what it downloads comes out", () => {
  const config = { dir: "/opt/fv", host: "/opt/fv/bin/host.exe", agent: "/opt/fv/bin/agent.exe", engine: "chrome" as const, sessions: [] };
  const told = farviewHowTo(config, [{ id: "fv_x", title: "", url: "about:blank", attached: false, session: "chat:a", agent: 4100 }]);
  assert.match(told, /`upload:<selector>=<file>\[,<file>\.\.\.\]`/);
  assert.match(told, /`downloads\/`/);
  assert.match(told, /the step `downloads` lists each file saved there/);
});
