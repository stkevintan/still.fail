// Farview's release (AFK-surf/farview-legacy's `tools/package.sh`: bin/host.exe, bin/agent.exe, lib/), got by a station
// that has it nowhere else: where config.json names no directory of its own, a station on a system Farview is built
// for takes the release this station's version names (FARVIEW_RELEASES: its commit, as apps/mbui/farview.pin pins the
// client the app draws its tabs with, and the SHA-256 of its tarball), downloaded the first time a chat's Farview is
// started, its digest checked before anything of it is unpacked, and kept in the machine's cache of native parts,
// which every station process and worktree shares. Farview is private (AFK-surf/farview-legacy): its releases are that
// repository's own (the release `builds`), got with the machine's `gh` and its sign-in, never published where anyone
// may download them until its owner says so (the lead, 2026-11-16); then still.fail's store of native parts and the
// release `native-artifacts` of AFK-surf/monoid, as scripts/native.ts gets the native parts, are asked after it.
import { execFile } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { access, mkdir, mkdtemp, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { platform } from "../platform/index.ts";

const run = promisify(execFile);

/// A release of Farview's: the commit it was built from and its tarball's SHA-256.
export type FarviewRelease = { rev: string; sha256: string };

/// The release a station of this version takes, by the system it runs on (`process.platform`-`process.arch`). Its
/// commit is the one apps/mbui/farview.pin names, so a station's tabs speak the protocol the app's client does
/// (test/farview-release.test.ts holds them together).
export const FARVIEW_RELEASES: Readonly<Record<string, FarviewRelease>> = {
  "darwin-arm64": { rev: "29078d90f4351482fcd30a4afb4c7c545d8be37e", sha256: "6123f7df492a2d9d56729fa4defad4ac7930dc17e1aa4e3cd20ebf241cf53ab7" },
  "linux-x64": { rev: "29078d90f4351482fcd30a4afb4c7c545d8be37e", sha256: "eaa82500b0e6b7b643ad83ac31c4edc3a2fb12c148d2d650f230bac9bc6c90c8" },
  "linux-arm64": { rev: "29078d90f4351482fcd30a4afb4c7c545d8be37e", sha256: "5aff264c70cb40fb0135de607a12e4ea6b05061c325f76d2e30757150acd50c5" },
};

/// The system this station runs on, as FARVIEW_RELEASES names them (none: one no release is built for).
export const farviewTarget = (): string => `${platform.buildOs ?? "other"}-${process.arch}`;

/// The tarball's name, in the store and the release alike.
export const farviewAsset = (target: string, release: FarviewRelease): string => `farview-${target}-${release.rev.slice(0, 12)}.tar.gz`;

/// The machine's cache of native parts (scripts/native.ts's: platform.nativeCache).
export const nativeCache = (env: NodeJS.ProcessEnv = process.env, of: Pick<typeof platform, "nativeCache"> = platform): string =>
  of.nativeCache(env, homedir());

/// Where a release is kept, unpacked (bin/host.exe in it).
export const farviewCacheDir = (target: string, release: FarviewRelease, env: NodeJS.ProcessEnv = process.env): string =>
  join(nativeCache(env), "farview", `${release.rev.slice(0, 12)}-${target}`);

/// Where a release's tarball is asked for, in turn: each of $STILLFAIL_FARVIEW_SOURCES (comma-separated: an address
/// the name goes after, or `gh:<owner>/<repo>@<tag>`, a release `gh` downloads), else Farview's own release (`gh`),
/// still.fail's store of native parts and the GitHub release of them.
export function farviewSources(name: string, env: NodeJS.ProcessEnv = process.env): string[] {
  const said = (env.STILLFAIL_FARVIEW_SOURCES ?? "").split(",").map((s) => s.trim()).filter((s) => s !== "");
  if (said.length > 0) return said.map((s) => `${s}/${name}`);
  const store = env.STILLFAIL_NATIVE_STORE ?? "https://app.still.fail/releases/natives";
  const repo = env.STILLFAIL_NATIVE_REPO ?? "AFK-surf/monoid";
  const release = env.STILLFAIL_NATIVE_RELEASE ?? "native-artifacts";
  return [`gh:AFK-surf/farview-legacy@builds/${name}`, `${store}/${name}`, `https://github.com/${repo}/releases/download/${release}/${name}`];
}

/// The bytes at an address, null where it has none (or it cannot be reached).
export type Fetch = (url: string) => Promise<Uint8Array | null>;

/// A `gh:<owner>/<repo>@<tag>/<name>` source as `gh release download` takes it; null for any other.
export function ghSource(url: string): { repo: string; tag: string; name: string } | null {
  const m = /^gh:([^/@\s]+\/[^/@\s]+)@([^/\s]+)\/([^/\s]+)$/.exec(url);
  return m === null ? null : { repo: m[1]!, tag: m[2]!, name: m[3]! };
}

export const fetchBytes: Fetch = async (url) => {
  const gh = ghSource(url);
  if (gh !== null) {
    // (a private repository's: the machine's gh, signed in; none, or not let in: none from here)
    const dir = await mkdtemp(join(tmpdir(), "farview-gh-"));
    try {
      await run("gh", ["release", "download", gh.tag, "-R", gh.repo, "-p", gh.name, "-D", dir]);
      return new Uint8Array(await readFile(join(dir, gh.name)));
    } catch {
      return null;
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  }
  try {
    const r = await fetch(url, { redirect: "follow" });
    if (!r.ok) {
      await r.body?.cancel().catch(() => {});
      return null;
    }
    return new Uint8Array(await r.arrayBuffer());
  } catch {
    return null;
  }
};

/// Release `release` for `target` unpacked at `dir`, got from `sources` in turn where it is not there yet: a tarball
/// whose SHA-256 is not the release's is refused (and the next source asked), nothing of it unpacked. Unpacked beside
/// `dir` and moved there whole, so a station that stops half way, or another that unpacks it too, leaves no half of
/// one where it is looked for.
export async function unpackRelease(dir: string, target: string, release: FarviewRelease, sources: string[], get: Fetch = fetchBytes): Promise<void> {
  try {
    await access(join(dir, "bin", "host.exe"));
    return;
  } catch {}
  const name = farviewAsset(target, release);
  const refused: string[] = [];
  let bytes: Uint8Array | null = null;
  for (const url of sources) {
    const got = await get(url);
    if (got === null) continue;
    const sha = createHash("sha256").update(got).digest("hex");
    if (sha === release.sha256) {
      bytes = got;
      break;
    }
    refused.push(`${url} (SHA-256 ${sha}, not ${release.sha256})`);
  }
  if (bytes === null) {
    throw new Error(
      refused.length > 0
        ? `Farview's release ${name} was refused: ${refused.join("; ")}`
        : `Farview's release ${name} could not be downloaded (${sources.join(", ")}): say where an unpacked one is in config.json \`browser.farview\`, or \`browser.farview: false\` for Chrome alone.`,
    );
  }
  const parent = join(dir, "..");
  await mkdir(parent, { recursive: true });
  const work = join(parent, `.${name}.${randomBytes(6).toString("hex")}`);
  await mkdir(work, { recursive: true });
  try {
    const tgz = join(work, name);
    await writeFile(tgz, bytes);
    const out = join(work, "out");
    await mkdir(out);
    await run("tar", ["-xzf", tgz, "-C", out]);
    // (the tarball holds the release in a directory of its own: farview-macos-arm64/bin/host.exe)
    let root = out;
    try {
      await access(join(out, "bin", "host.exe"));
    } catch {
      const inner = (await readdir(out)).filter((n) => !n.startsWith("."));
      if (inner.length !== 1) throw new Error(`Farview's release ${name} holds no bin/host.exe`);
      root = join(out, inner[0]!);
      await access(join(root, "bin", "host.exe"));
    }
    try {
      await rename(root, dir);
    } catch (e) {
      // (another station process unpacked it meanwhile: theirs is the same release)
      try {
        await access(join(dir, "bin", "host.exe"));
      } catch {
        throw e;
      }
    }
  } finally {
    await rm(work, { recursive: true, force: true });
  }
}
