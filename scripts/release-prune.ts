// The releases bucket keeps, of the desktop, Android and Linux apps, the installer each feed names and any newer (a
// release whose files are put but whose feed is not yet, scripts/release-put.sh), and the installers (zip, exe, apk,
// tar.gz) its deltas are from: what the next release's deltas are made from (scripts/release-deltas.ts, up to 10 builds
// back, the betas' as the stable apps'; the owner, 2026-11-11). Not the newest N: Android's APK is put for every main
// commit before its feed, so installers that never were a feed would take the places. Of the betas also 30
// .blockmap/.sig. Other older installers are deleted, and older beta blockmaps; a stable release's blockmaps all stay
// (a few hundred KB each). A desktop app updates from the version it runs by fetching that version's blockmap (when it
// has not kept it) and the new file's changed blocks: no old installer is needed, so a beta up to 30 releases behind
// still updates by difference. A Windows installer's raw form (.raw.zst) stays as long as its installer. A delta
// (….from-<n>.delta) stays while its feed offers it (and when it is newer than what the feed names: being put); the
// station's archives kept under their own names (station/archive/<channel>/…) while their channel's feed names them,
// as its build, a base of its deltas or a release a station may go back to (its `earlier`), or are newer than it, and
// its deltas while it offers them. The web archives
// the beta Electron app took without a new app (made until 2026-10-26, when that app was moved to mbui's): the one its
// feed names, any newer, and the newest 5. What a station's job staged (staged/<when>-<commit>/: scripts/release-put.sh
// --stage) and no put took back and deleted: after two days. An Android release's native symbols (symbols/android/…:
// scripts/release.sh, read by scripts/crash-symbols.ts) once older than 30 days by the time the bucket says it was put
// (its listing's last_modified; the owner, 2026-11-11): one whose time cannot be read stays. The station's readers in
// the prebuilt store (natives/reader-<platform>-<key>.tar.gz: scripts/native.ts store-sync) once older than 14 days by
// the same word; the store's other parts never. The stations' own names, Node and the feeds are never touched.
// CI runs it after `put` (.github/workflows/pipeline.yml). An old file it could not delete stays for the next run's
// prune: a release already put and told never goes red for it (as scripts/native.ts's prune).
//   node scripts/release-prune.ts [--dry-run] [--ci-natives-only]
// Needs CLOUDFLARE_API_TOKEN (and CLOUDFLARE_ACCOUNT_ID, else the token's first account).

import { baseFile } from "./release-deltas.ts";

const BUCKET = "stillfail-releases";
export const FEEDS = [
  "desktop/stillfail-beta-mac.yml", "desktop/stillfail-beta.yml", "android/beta/latest.json",
  "desktop/stillfail-mac.yml", "desktop/stillfail.yml", "android/latest.json", "android/mbui/latest.json", "mac/mbui/latest.json",
  "mac/latest.json", "mac/beta/latest.json", "win/mbui/latest.json", "win/latest.json", "win/beta/latest.json",
  "linux/mbui/latest.json", "linux-arm64/mbui/latest.json", "station.json", "station-beta.json",
];
/** An installer: its name before and after the version, and the version; then what goes with it (.blockmap, .sig, its
 * raw form, a delta to it) when it is one. */
const INSTALLER = /^((?:desktop|android|mac|win|linux)\/stillfail-(?:beta-|mbui-)?)(\d+(?:\.\d+\.\d+)?)(-[\w-]+\.(?:zip|exe|tar\.gz)|\.apk)(\.blockmap|\.sig|\.raw\.zst|\.from-\d+\.delta)?$/;
/** How many of a beta's newest blockmaps and .sigs stay. */
const BETA_BLOCKMAPS = 30;
/** The beta Electron app's web app: its feed, its archives, and how many of the newest stay. */
const WEB_FEED = "desktop/web/stillfail-beta-web.json";
const WEB_ARCHIVE = /^desktop\/web\/stillfail-beta-web-0\.\d+\.(\d+)\.tar\.gz$/;
const WEB_ARCHIVES = 5;
const CI_NATIVE_PREFIX = "staged/ci-natives/";
const CI_NATIVE = /^staged\/ci-natives\/(\d+)-/;
const CI_NATIVE_SECONDS = 7 * 86400;

/** A branch's native chunks stay as long as the run's receipts. */
function expiredCiNative(key: string, now: number): boolean | undefined {
  const native = CI_NATIVE.exec(key);
  return native ? Number(native[1]) < now - CI_NATIVE_SECONDS : undefined;
}

/** What a station's job staged, by when (seconds since 1970), and how long it may stay there. */
const STAGED = /^staged\/(\d+)-/;
const STAGED_SECONDS = 2 * 24 * 3600;
/** An Android release's symbols, and how long they stay after they were put. */
const SYMBOLS = /^symbols\//;
const SYMBOLS_SECONDS = 30 * 24 * 3600;
/** The station's readers main built, copied into the prebuilt store (scripts/native.ts store-sync), and how long they
 * stay after they were put: a stable release of up to a few days before fetches its own. One main still builds with is
 * copied again by its next run. The store's other parts (prebuilt by hand: shell, engine, ghostty-vt…) never go. */
const READER_NATIVE = /^natives\/reader-(darwin-arm64|linux-x64|linux-arm64|win32-x64)-[0-9a-f]{24}\.tar\.gz$/;
const READER_NATIVE_SECONDS = 14 * 24 * 3600;
/** The station's archives under their own names, and their deltas (scripts/release-deltas.ts). */
const STATION_ARCHIVE = /^station\/archive\/(stable|beta)\/(\d+)-([0-9a-f]{64})-([a-z0-9-]+?)(\.tar\.gz|\.zip|\.from-\d+-[0-9a-f]{16}\.delta)$/;
/** The station's signed included-changes manifests (scripts/release-included.ts). */
const STATION_INCLUDED = /^station\/included\/(\d+)-([0-9a-f]{16})\.json$/;

const older = (a: string, b: string) => {
  const [x, y] = [a.split(".").map(Number), b.split(".").map(Number)];
  for (let i = 0; i < Math.max(x.length, y.length); i++) if ((x[i] ?? 0) !== (y[i] ?? 0)) return (x[i] ?? 0) < (y[i] ?? 0);
  return false;
};
/** An installer's group (its name without the version), version, and what it is beside an installer. */
const installer = (key: string) => {
  const m = key.match(INSTALLER);
  // (still.fail mbui's, android/stillfail-mbui-<n>.apk, kept as a beta's)
  return m ? { group: m[1]! + m[3]!, version: m[2]!, beta: m[1]!.endsWith("beta-") || m[1]!.endsWith("mbui-"), extra: m[4] ?? "" } : null;
};


/** Of the apps' feeds: the version each names, by group (the desktop's feeds name the file without its directory),
 * every delta one offers, and the versions of the installers its deltas are from, by group. */
const appFeeds = (feeds: Record<string, string>) => {
  const current = new Map<string, string>();
  const offered = new Set<string>();
  const bases = new Map<string, Set<string>>();
  for (const feed of FEEDS) {
    const text = feeds[feed];
    if (text === undefined || feed.startsWith("station")) continue;
    // (a name ending there: not a delta's nor a raw form's, which name the installer at their start)
    for (const m of text.matchAll(/[\w.\/-]+?\.(?:zip|exe|apk|tar\.gz)(?=[^\w.\/-]|$)/g)) {
      const named = installer(m[0].includes("/") ? m[0] : `${feed.split("/")[0]}/${m[0]}`);
      if (named) current.set(named.group, named.version);
    }
    for (const m of text.matchAll(/[\w.\/-]+\.delta/g)) offered.add(m[0]);
    if (!feed.endsWith(".json")) continue;
    let f: any;
    try { f = JSON.parse(text); } catch { continue; }
    if (!Number.isSafeInteger(f?.versionCode) || typeof f.file !== "string" || !Array.isArray(f.deltas)) continue;
    for (const d of f.deltas) {
      const base = Number.isSafeInteger(d?.from) ? installer(baseFile(f.file, f.versionCode, d.from)) : null;
      if (base) bases.set(base.group, (bases.get(base.group) ?? new Set()).add(base.version));
    }
  }
  return { current, offered, bases };
};

/** The installers of `keys` newer than the version their feed names (a release being put, or never to be a feed). */
export function aheadOf(keys: string[], feeds: Record<string, string>): string[] {
  const { current } = appFeeds(feeds);
  return keys.filter((key) => {
    const file = installer(key);
    const named = file?.extra === "" && current.get(file.group);
    return !!named && older(named, file!.version);
  });
}

/**
 * Which of the bucket's `keys` go: `feeds` the feeds' text by name (a feed not there: absent), `webNamed` the build the
 * web archives' feed names, `now` seconds since 1970, `putAt` when each key was put by the bucket's word (seconds since
 * 1970; a key without one: not known).
 */
export function doomedOf(keys: string[], feeds: Record<string, string>, webNamed: number | null, now: number, putAt: ReadonlyMap<string, number> = new Map()): string[] {
  const { current, offered, bases } = appFeeds(feeds);
  // The station's feeds: by channel, the build each names, the archives (by sha256) it names as its own or as a base
  // of its deltas, and its deltas.
  const station = new Map<string, { build: number; named: Set<string>; deltas: Set<string> }>();
  const stationIncluded = new Set<string>();
  for (const [feed, channel] of [["station.json", "stable"], ["station-beta.json", "beta"]] as const) {
    const text = feeds[feed];
    if (text === undefined) continue;
    try {
      const f = JSON.parse(text), words = JSON.parse(Buffer.from(f.release, "base64").toString("utf8"));
      const named = new Set<string>(Object.values(words.builds ?? {}).map((b: any) => String(b.sha256)));
      if (typeof words.included?.file === "string") stationIncluded.add(words.included.file);
      const deltas = new Set<string>();
      for (const list of Object.values(f.deltas ?? {})) for (const d of list as any[]) { named.add(String(d.base)); deltas.add(String(d.file)); }
      // (the releases a station may go back to: their archives and included manifests, by their signed words)
      for (const e of Array.isArray(f.earlier) ? f.earlier : []) {
        try {
          const ew = JSON.parse(Buffer.from(e.release, "base64").toString("utf8"));
          for (const b of Object.values<any>(ew.builds ?? {})) named.add(String(b.sha256));
          if (typeof ew.included?.file === "string") stationIncluded.add(ew.included.file);
        } catch {}
      }
      station.set(channel, { build: Number(words.build), named, deltas });
    } catch {
      // (a feed not read as one: nothing of its channel goes)
      station.set(channel, { build: Infinity, named: new Set(), deltas: new Set() });
    }
  }
  const maxStationBuild = station.size === 0 ? Infinity : Math.max(...[...station.values()].map((s) => s.build));

  // The versions of each installer's blockmaps and of its .sigs, newest first.
  const kind = (file: { group: string; extra: string }) => file.group + file.extra;
  const versions = new Map<string, string[]>();
  for (const key of keys) {
    const file = installer(key);
    if (file && (file.extra === ".blockmap" || file.extra === ".sig")) versions.set(kind(file), [...(versions.get(kind(file)) ?? []), file.version]);
  }
  for (const list of versions.values()) list.sort((a, b) => (older(a, b) ? 1 : older(b, a) ? -1 : 0));
  const webBuilds = keys.map((key) => Number(key.match(WEB_ARCHIVE)?.[1])).filter((n) => Number.isSafeInteger(n)).sort((a, b) => b - a);

  return keys.filter((key) => {
    const native = expiredCiNative(key, now);
    if (native !== undefined) return native;
    const staged = Number(key.match(STAGED)?.[1]);
    if (Number.isSafeInteger(staged)) return staged < now - STAGED_SECONDS;
    if (SYMBOLS.test(key)) {
      const put = putAt.get(key);
      return put !== undefined && Number.isFinite(put) && put < now - SYMBOLS_SECONDS;
    }
    if (READER_NATIVE.test(key)) {
      const put = putAt.get(key);
      return put !== undefined && Number.isFinite(put) && put < now - READER_NATIVE_SECONDS;
    }
    const web = Number(key.match(WEB_ARCHIVE)?.[1]);
    if (Number.isSafeInteger(web)) return webNamed !== null && web < webNamed && webBuilds.indexOf(web) >= WEB_ARCHIVES;
    const archive = key.match(STATION_ARCHIVE);
    if (archive) {
      const feed = station.get(archive[1]!);
      if (!feed || Number(archive[2]) > feed.build) return false;
      return archive[5]!.endsWith(".delta") ? !feed.deltas.has(key) : !feed.named.has(archive[3]!);
    }
    const inc = key.match(STATION_INCLUDED);
    if (inc) {
      if (Number(inc[1]) > maxStationBuild) return false;
      return !stationIncluded.has(key);
    }
    const file = installer(key);
    const named = file && current.get(file.group);
    if (!file || !named || !older(file.version, named)) {
      // (a delta to the build its feed names that the feed does not offer: made by a run before this one's)
      return !!file && !!named && file.extra.endsWith(".delta") && file.version === named && !offered.has(key);
    }
    if (file.extra.endsWith(".delta")) return true;
    if (file.extra === ".blockmap" || file.extra === ".sig") {
      if (!file.beta) return false;
      return versions.get(kind(file))!.indexOf(file.version) >= BETA_BLOCKMAPS;
    }
    // (an installer, and its raw form with it: a base of its feed's deltas stays)
    return !bases.get(file.group)?.has(file.version);
  });
}

/** An object's key as the path of R2's REST API takes it: each segment escaped, its slashes kept. */
export const encodeObjectKey = (key: string) => key.split("/").map(encodeURIComponent).join("/");

/** How long to wait after a 429: its Retry-After in seconds, held to 1..15 s; none read, 5 s. */
export const retryAfterMs = (response: Response): number => {
  const header = response.headers.get("retry-after");
  const seconds = header === null ? NaN : Number(header);
  return Number.isFinite(seconds) ? Math.min(15_000, Math.max(1_000, seconds * 1000)) : 5_000;
};

export type Fetch = (url: string, init: RequestInit) => Promise<Response>;
export type Sleep = (ms: number) => Promise<void>;

/**
 * Cloudflare's REST API asked up to three times: a connection reset or a request past its 30 s (thrown), a 429 (after
 * its Retry-After) or another answer neither 2xx nor 404 is asked again; the third answer is returned as it is, the
 * third throw thrown.
 */
export async function apiWithRetry(fetchFn: Fetch, sleep: Sleep, token: string, path: string, init: RequestInit = {}): Promise<Response> {
  for (let attempt = 1; ; attempt++) {
    let response: Response;
    try {
      response = await fetchFn(`https://api.cloudflare.com/client/v4${path}`, {
        ...init, headers: { Authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(30_000),
      });
    } catch (error) {
      if (attempt === 3) throw error;
      await sleep(5_000);
      continue;
    }
    if (response.ok || response.status === 404 || attempt === 3) return response;
    // (the body read and dropped, so that the connection goes back to the pool)
    await response.arrayBuffer().catch(() => {});
    await sleep(response.status === 429 ? retryAfterMs(response) : 5_000);
  }
}

/**
 * The doomed keys deleted 8 at a time. One that will not go (its last answer neither 2xx nor 404, or thrown) is said and
 * left for the next prune, which finds it again: old files left a run longer never fail a release that was put.
 */
export async function deleteDoomed(doomed: string[], del: (key: string) => Promise<Response>, log: (line: string) => void = console.error): Promise<{ deleted: number; left: number }> {
  let left = 0;
  for (let i = 0; i < doomed.length; i += 8) {
    await Promise.all(doomed.slice(i, i + 8).map(async (key) => {
      try {
        const response = await del(key);
        if (response.ok || response.status === 404) return;
        left++;
        log(`deleting ${key} failed (${response.status}): the next prune deletes it`);
      } catch (error) {
        left++;
        log(`deleting ${key} failed (${error instanceof Error ? error.message : String(error)}): the next prune deletes it`);
      }
    }));
  }
  return { deleted: doomed.length - left, left };
}

if (import.meta.main) {
  const dryRun = process.argv.includes("--dry-run");
  const ciNativesOnly = process.argv.includes("--ci-natives-only");
  const token = process.env.CLOUDFLARE_API_TOKEN;
  if (!token) throw new Error("CLOUDFLARE_API_TOKEN is not set");

  const api = (path: string, init: RequestInit = {}) =>
    apiWithRetry(fetch, (ms) => new Promise((r) => setTimeout(r, ms)), token, path, init);
  const json = async (path: string): Promise<any> => {
    const response = await api(path);
    if (!response.ok) throw new Error(`${path}: ${response.status} ${await response.text()}`);
    return response.json();
  };

  let account = process.env.CLOUDFLARE_ACCOUNT_ID;
  if (!account) {
    const { result: accounts } = await json("/accounts");
    if (ciNativesOnly && accounts.length !== 1) throw new Error("Expected one Cloudflare account for CI archive cleanup");
    account = accounts[0].id;
  }
  const objects = `/accounts/${account}/r2/buckets/${BUCKET}/objects`;

  // (each object's last_modified, an ISO 8601 time, when it was written: Cloudflare's R2 List Objects; one not read as a
  // time is left out of putAt, and what goes by it stays)
  const keys: string[] = [];
  const putAt = new Map<string, number>();
  for (let cursor = ""; ;) {
    const query = new URLSearchParams({ per_page: "1000" });
    if (ciNativesOnly) query.set("prefix", CI_NATIVE_PREFIX);
    if (cursor) query.set("cursor", cursor);
    const page = await json(`${objects}?${query}`);
    for (const o of page.result as { key: string; last_modified?: unknown }[]) {
      keys.push(o.key);
      const put = typeof o.last_modified === "string" ? Date.parse(o.last_modified) / 1000 : NaN;
      if (Number.isFinite(put)) putAt.set(o.key, put);
    }
    cursor = page.result_info?.cursor ?? "";
    if (!page.result_info?.is_truncated || !cursor) break;
  }

  const now = Date.now() / 1000;
  let doomed: string[];
  if (ciNativesOnly) {
    doomed = keys.filter((key) => expiredCiNative(key, now) === true);
    console.log(`${doomed.length} expired CI chunks to delete`);
  } else {
    const feeds: Record<string, string> = {};
    for (const feed of FEEDS) {
      const response = await api(`${objects}/${encodeObjectKey(feed)}`);
      if (response.status === 404) continue;
      if (!response.ok) throw new Error(`${feed}: ${response.status}`);
      feeds[feed] = await response.text();
    }
    // The web archives: the build the feed names (none: the feed is not out yet, and nothing goes).
    const webFeed = await api(`${objects}/${encodeObjectKey(WEB_FEED)}`);
    if (!webFeed.ok && webFeed.status !== 404) throw new Error(`${WEB_FEED}: ${webFeed.status}`);
    const webNamed = webFeed.ok ? Number((await webFeed.json()).build) : null;

    doomed = doomedOf(keys, feeds, webNamed, now, putAt);
    // (said each, so that what goes can be read from CI's log)
    for (const key of aheadOf(keys, feeds)) console.log(`above its feed: ${key}`);
    console.log(`${keys.length} files, ${doomed.length} old installers, deltas, blockmaps, archives, staged files, symbols and readers to delete`);
  }
  for (const key of doomed) console.log(`  ${key}`);
  if (dryRun) process.exit(0);
  const { deleted, left } = await deleteDoomed(doomed, (key) => api(`${objects}/${encodeObjectKey(key)}`, { method: "DELETE" }));
  console.log(`deleted ${deleted} (${left} left for next prune)`);
}
