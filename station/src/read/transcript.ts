// Where a runtime's own session transcripts are (each runtime's place in a home, the shared place, a session's places
// and what was learned of where its files went), the shape of an entry of a timeline, and times as transcripts write
// them. Reading a transcript into entries is the MoonBit program's (mb/src/history: the readers' pages, the live view's
// `tailRead`); the TypeScript that read them before is the tests' (test/reference/transcript.ts), which the program is
// compared with. Nothing here touches the file system: a transcript is looked for by a `Looking`, which
// read/transcript-soon.ts answers off the station's thread.
import { basename, isAbsolute, join, relative, sep } from "node:path";
import { runtimeKind, type RuntimeKind } from "../agents/runtime.ts";

/// TimelineEntry as serde writes it: `tool`, `ok`, `callId`, `subagent` left out when none; `brief` when what it says is
/// cut to what a history shows before it is opened (`brief`).
/// `inScript`: a call's result that is in its script's output (said so by the client in its words, its text "").
export type TimelineEntry = { at: string | null; kind: string; text: string; tool?: string; ok?: boolean; callId?: string; subagent?: boolean; brief?: boolean; inScript?: true };

/// Where a transcript's reading stands (mb/src/history `Tail` `snapshot`): where its next read goes on from and what it
/// keeps between reads, without the entries read; a read made from it reads on as the one it was taken of would.
export type TailState = { path: string; runtime?: RuntimeKind; offset: number; partial: string; count: number; inner: [string, number][]; packedStamp: string | null };
/// A transcript and the runtime that wrote it. A plain path uses the chain's default runtime.
export type TranscriptRef = string | { path: string; runtime: RuntimeKind };

/// What finding a transcript asks of the file system, a question at a time (a step of a `Looking`): whether a path is
/// there (`there`, its links followed), whether it is a file (`file`), the names a directory lists (`names`, null: it
/// lists none), a path with its links resolved (`real`, null: it is not there), and where under `path` a Codex rollout
/// of `id` is (`rollout`, null: none). The station answers them off its thread (read/transcript-soon.ts `looked`); the
/// tests' reference answers them with node:fs's synchronous calls (test/reference/transcript-paths.ts), the one way of
/// looking both share, so the two find the same.
export type Look = { ask: "there" | "file" | "names" | "real"; path: string } | { ask: "rollout"; path: string; id: string };
export type Looking<T> = Generator<Look, T, unknown>;

function* there(path: string): Looking<boolean> {
  return (yield { ask: "there", path }) as boolean;
}
function* isFile(path: string): Looking<boolean> {
  return (yield { ask: "file", path }) as boolean;
}
function* entriesOf(path: string): Looking<string[] | null> {
  return (yield { ask: "names", path }) as string[] | null;
}
function* realOf(path: string): Looking<string | null> {
  return (yield { ask: "real", path }) as string | null;
}
/// archive.rs `storage`: the file, or its `.zst` once put away.
export function* storageLooking(path: string): Looking<string> {
  return (yield* there(path)) ? path : `${path}.zst`;
}
/// Whether a transcript is there as a file, or put away beside it.
function* stored(path: string): Looking<boolean> {
  return yield* isFile(yield* storageLooking(path));
}

/// Where in a home a runtime keeps its transcripts: Claude Code's projects/, Codex's sessions/, DeepSeek Harness's
/// dsh-sessions/ as dsh.ts sets it, Grok Build's grok/sessions/, Cursor's and Devin's cursor/sessions/ and devin/sessions/
/// as cursor.ts and devin.ts keep them, Pi's pi/sessions/ as pi.ts names them. In a home the station keeps it is a link
/// to the runtime's shared place (`sharedTranscripts`, sessions/agent-home.ts `linkTranscripts`).
export const transcriptDir = (runtime: string) => (runtime === "claude" ? "projects" : runtime === "codex" ? "sessions" : runtime === "grok" ? "grok/sessions" : runtime === "cursor" ? "cursor/sessions" : runtime === "devin" ? "devin/sessions" : runtime === "hermes" ? "hermes/sessions" : runtime === "agy" ? "agy/sessions" : runtime === "pi" ? "pi/sessions" : "dsh-sessions");

/// The one place a runtime's transcripts are kept on the station, whichever account's home wrote them.
export const sharedTranscripts = (dataDir: string, runtime: string) => join(dataDir, "transcripts", runtime);

/// The directory Claude Code keeps a working directory's transcripts in, in projects/ (its sanitizePath): each character
/// but an ASCII letter or digit a dash. Past 200 characters it shortens the name and adds a hash of it: none said.
export function claudeProject(cwd: string): string | null {
  const name = cwd.replace(/[^a-zA-Z0-9]/g, "-");
  return name.length <= 200 ? name : null;
}

/// Where a Claude session's transcript is in a directory of them when it ran in one of `places` (the session's working
/// directories): looked for there alone, a file or two, not in every project's directory (the shared place has one for
/// each chat the station ever had: many on a station, each looked at in turn).
function* placedIn(runtime: RuntimeKind, dir: string, id: string, places: readonly string[]): Looking<string | null> {
  if (runtime !== "claude") return null;
  // Claude Code names it by the directory as its process sees it (symbolic links resolved): one reached through a link
  // is looked for by both.
  for (const place of places) {
    const at = yield* realOf(place);
    for (const each of at === null || at === place ? [place] : [place, at]) {
      const project = claudeProject(each);
      if (project === null) continue;
      const path = join(dir, project, `${id}.jsonl`);
      if (yield* stored(path)) return path;
    }
  }
  return null;
}

/// The Claude transcripts found in a project not of their session's places (it ran before the data directory moved, or
/// in a terminal's directory), by directory and id: a transcript stays where it is (put away, its `.zst` beside), so each
/// is looked for in every project once a process. Null: looked for with its places and in no project then. One a
/// session writes from now on is in its places (`placedIn`, asked first every time), so it is not looked for again: a
/// new session's is not written until its conversation begins, and every project (many on a station) was looked in at each
/// read until then, 25 seconds on the station's thread while memory was short.
const elsewhere = new Map<string, string | null>();
const hintListeners = new Set<(id: string) => void>();
const hintChanged = (id: string) => { for (const listener of hintListeners) { try { listener(id); } catch {} } };

/// A live locator can discard a result if a relevant in-process path hint changed after its batch was read.
export function onTranscriptHintsChanged(listener: (id: string) => void): () => void {
  hintListeners.add(listener);
  return () => { hintListeners.delete(listener); };
}

/// Clears in-process `elsewhere` and `rollouts` caches (for tests verifying fresh Finder directory scans).
export function resetTranscriptLocateCache(): void {
  elsewhere.clear();
  rollouts.clear();
}

/// Where a session's transcript is in a directory of the runtime's transcripts (a home's, `transcriptDir`, or the shared
/// place), if it is there. `placed`: a Claude one was looked for in its session's places first. `anywhere`: one not
/// found there yet is looked for in every project of the directory (read/transcript-soon.ts `transcriptPathsSoon`).
export function* transcriptInLooking(runtime: RuntimeKind, dir: string, id: string, placed = false, anywhere = true): Looking<string | null> {
  if (runtime === "dsh") return yield* dshTranscript(dir, id);
  if (runtime === "grok") return yield* grokTranscript(dir, id);
  if (runtime === "cursor" || runtime === "devin" || runtime === "hermes" || runtime === "agy" || runtime === "pi") {
    const path = join(dir, `${id}.jsonl`);
    return (yield* stored(path)) ? path : null;
  }
  if (runtime === "claude") {
    const at = `${dir}\0${id}`;
    const kept = elsewhere.get(at);
    if (kept === null && placed) return null;
    if (kept != null && (yield* stored(kept))) return kept;
    if (!anywhere) return null;
    const projects = yield* entriesOf(dir);
    if (projects === null) return null; // readdir failure must not poison elsewhere negative cache
    for (const project of projects) {
      const path = join(dir, project, `${id}.jsonl`);
      if (yield* stored(path)) {
        if (elsewhere.get(at) !== path) { elsewhere.set(at, path); hintChanged(id); }
        return path;
      }
    }
    if (placed && (!elsewhere.has(at) || elsewhere.get(at) !== null)) { elsewhere.set(at, null); hintChanged(id); }
    return null;
  }
  // Codex's: its file is where it was found (put away, its `.zst` beside) once a process.
  const at = `${dir}\0${id}`;
  const kept = rollouts.get(at);
  if (kept !== undefined && (yield* stored(kept))) return kept;
  const found = (yield { ask: "rollout", path: dir, id }) as string | null;
  if (found !== null && rollouts.get(at) !== found) { rollouts.set(at, found); hintChanged(id); }
  return found;
}

/// The Codex transcripts found, by directory and id: kept by date (sessions/<year>/<month>/<day>/rollout-…-<id>.jsonl),
/// each was looked for through every day's directory at each read, seconds on the station's thread on a station.
const rollouts = new Map<string, string>();

/// A running Codex thread says its own rollout path. The file may not exist until its first turn: keep the path even
/// then, so following it does not visit every older day's directory while waiting for that file to appear.
type SaidRollout = { suffix: string; seen: boolean };
const saidRollouts = new Map<string, Map<string, SaidRollout>>();

/// The rollout path a Codex thread said, kept where it is under its home's sessions/ (as reached, and with its links
/// resolved): the path, or null where it is none of the thread's there.
export function* rememberCodexRolloutLooking(home: string, id: string, path: unknown): Looking<string | null> {
  if (typeof path !== "string" || !isAbsolute(path) || /[\\/\0]/.test(id)) return null;
  const name = basename(path);
  if (!name.startsWith("rollout-") || !name.endsWith(`-${id}.jsonl`)) return null;
  const dir = join(home, "sessions");
  const real = (yield* realOf(dir)) ?? dir;
  const within = (root: string) => {
    const part = relative(root, path);
    return part !== "" && part !== ".." && !part.startsWith(`..${sep}`) && !isAbsolute(part);
  };
  if (!within(dir) && !within(real)) return null;
  const entry = { suffix: relative(within(dir) ? dir : real, path), seen: false };
  let dirs = saidRollouts.get(id);
  if (dirs === undefined) saidRollouts.set(id, (dirs = new Map()));
  dirs.set(dir, entry);
  dirs.set(real, entry);
  hintChanged(id);
  return path;
}

/// dsh's: the session's directory holds one file per format it was written in (session.v<N>.jsonl); the current is the
/// highest N. Its directory is under one named for its working directory (any).
function* dshTranscript(root: string, id: string): Looking<string | null> {
  for (const dir of (yield* entriesOf(root)) ?? []) {
    const files = ((yield* entriesOf(join(root, dir, id))) ?? [])
      .map((name) => [name, /^session\.v(\d+)\.jsonl$/.exec(name)?.[1]] as const)
      .filter((f): f is readonly [string, string] => f[1] !== undefined)
      .sort((a, b) => Number(b[1]) - Number(a[1]));
    if (files.length > 0) return join(root, dir, id, files[0]![0]);
  }
  return null;
}

/// Grok Build's: sessions/<working directory, escaped>/<id>/chat_history.jsonl in its home (agents/grok.ts).
function* grokTranscript(root: string, id: string): Looking<string | null> {
  for (const dir of (yield* entriesOf(root)) ?? []) {
    const path = join(root, dir, id, "chat_history.jsonl");
    if (yield* stored(path)) return path;
  }
  return null;
}

/// Profiles' homes, `first`'s (a session's profile, if it still has one) first.
export const homesFirst = (profiles: readonly { id: string; home: string }[], first: string | null): string[] => [
  ...profiles.filter((p) => p.id === first).map((p) => p.home),
  ...profiles.filter((p) => p.id !== first).map((p) => p.home),
];

/// The transcripts of a session's runtime sessions (`ids`, the first first, ending with its current one): each looked
/// for in the runtime's shared place in data directory `dataDir`, where every home the station keeps has its runtimes
/// write them, whichever account and home a runtime session ran on and whatever the config says now; then in each of
/// `homes` (its profile's first) for a home that keeps its own (one outside the data directory that had transcripts in
/// it before it was a profile's, agent-home.ts `linkTranscripts`). `current` is whether the current one's is there: a
/// runtime writes it only once its conversation has begun. `places`: where the session works and worked (`sessionPlaces`),
/// where a Claude transcript is looked for first, in every directory, before anywhere else in them. `anywhere` false: a
/// Claude transcript is looked for in its places alone, never through every project (one that ran before the data
/// directory moved, or in a terminal's directory): what the live view of the sessions at work asks (sessions/hub.ts).
/// There each new chat, its transcript not written yet, had every project looked in (many on a station), every device
/// held 22 s and 45 s while memory was short and all their connections lost (2026-11-02). A session at work writes in
/// its places.
export function* transcriptPathsLooking(runtime: RuntimeKind, dataDir: string, homes: string[], ids: string[], places: readonly string[] = [], { anywhere = true }: { anywhere?: boolean } = {}): Looking<{ paths: string[]; current: boolean }> {
  // Each directory once, however it is reached (a home's that links to the shared place is that place), the homes' made
  // out only once one is to be looked in: nearly every transcript is in the shared place, the first.
  const shared = sharedTranscripts(dataDir, runtime);
  const ways = homes.map((home) => join(home, transcriptDir(runtime)));
  const saidDirs = runtime === "codex" ? [shared, ...ways] : [];
  let seen: Set<string> | null = null;
  const dirs = [shared];
  function* dirAt(i: number): Looking<string | undefined> {
    while (dirs.length <= i && ways.length > 0) {
      if (seen === null) seen = new Set([(yield* realOf(shared)) ?? shared]);
      const dir = ways.shift()!;
      const at = yield* realOf(dir);
      if (at !== null && !seen.has(at)) (seen.add(at), dirs.push(dir));
    }
    return dirs[i];
  }
  function* inDirs(look: (dir: string) => Looking<string | null>): Looking<string | null> {
    for (let i = 0; (yield* dirAt(i)) !== undefined; i++) {
      const path = yield* look(dirs[i]!);
      if (path !== null) return path;
    }
    return null;
  }
  const placed = places.length > 0;
  function* one(id: string): Looking<string | null> {
    let reported: { suffix: string; seen: boolean } | undefined;
    if (runtime === "codex") {
      for (const dir of saidDirs) {
        const kept = saidRollouts.get(id);
        const said = kept?.get(dir) ?? (kept === undefined ? undefined : kept.get((yield* realOf(dir)) ?? dir));
        if (!said) continue;
        reported ??= said;
        const path = join(dir, said.suffix);
        if (yield* stored(path)) { if (!said.seen) { said.seen = true; hintChanged(id); } return path; }
        if (!said.seen && !anywhere) return null;
        // History also looks elsewhere: a file may have moved before this process saw it at the reported path.
      }
    }
    const path = (yield* inDirs((dir) => placedIn(runtime, dir, id, places))) ?? (yield* inDirs((dir) => transcriptInLooking(runtime, dir, id, placed, anywhere)));
    // If a history read found the file elsewhere, later live reads may use that cached location too.
    if (path !== null && reported && !reported.seen) { reported.seen = true; hintChanged(id); }
    return path;
  }
  const found: (string | null)[] = [];
  for (const id of ids) found.push(yield* one(id));
  return { paths: found.filter((p) => p !== null), current: found.at(-1) != null };
}

/// Resolve each segment with the runtime and account that wrote it, keeping their conversation order.
export function* transcriptSourcesLooking(dataDir: string, profiles: readonly { id: string; home: string }[], sources: readonly { id: string; runtime: string; profile: string | null }[], places: readonly string[] = [], options: { anywhere?: boolean } = {}): Looking<{ paths: { path: string; runtime: RuntimeKind }[]; current: boolean }> {
  const paths: { path: string; runtime: RuntimeKind }[] = [];
  let current = false;
  for (const source of sources) {
    const runtime = runtimeKind(source.runtime);
    const found = runtime ? yield* transcriptPathsLooking(runtime, dataDir, homesFirst(profiles, source.profile), [source.id], places, options) : null;
    current = found?.current === true;
    if (runtime && found?.paths[0]) paths.push({ path: found.paths[0], runtime });
  }
  return { paths, current };
}

/// The in-process hints a live transcript locator needs. They are copied for one bounded batch of sources; locations
/// found in a worker are only accepted if the main thread's hints did not change while it was looking.
export type TranscriptLocationHints = {
  elsewhere: [string, string | null][];
  rollouts: [string, string][];
  said: [string, [string, SaidRollout][]][];
};

export function transcriptLocationHints(dataDir: string, profiles: readonly { home: string }[],
  sources: readonly { id: string; runtime: string }[]): { value: TranscriptLocationHints; current(): boolean; merge(found: TranscriptLocationHints): boolean } {
  const claude = new Set<string>(), codex = new Map<string, string>(), reported = new Set<string>();
  for (const source of sources) {
    if (source.runtime !== "claude" && source.runtime !== "codex") continue;
    const dirs = [sharedTranscripts(dataDir, source.runtime), ...profiles.map((p) => join(p.home, transcriptDir(source.runtime)))];
    for (const dir of dirs) {
      const key = `${dir}\0${source.id}`;
      if (source.runtime === "claude") claude.add(key);
      else codex.set(key, source.id);
    }
    if (source.runtime === "codex") reported.add(source.id);
  }
  const beforeElsewhere = new Map([...claude].flatMap((key) => elsewhere.has(key) ? [[key, elsewhere.get(key) as string | null] as const] : []));
  const beforeRollouts = new Map([...codex.keys()].flatMap((key) => rollouts.has(key) ? [[key, rollouts.get(key)!] as const] : []));
  const beforeSaid = new Map([...reported].map((id) => [id, new Map(saidRollouts.get(id) ?? [])] as const));
  const beforeSeen = new Map([...beforeSaid].map(([id, dirs]) => [id, new Map([...dirs].map(([dir, entry]) => [dir, entry.seen]))] as const));
  const value: TranscriptLocationHints = {
    elsewhere: [...beforeElsewhere], rollouts: [...beforeRollouts], said: [...beforeSaid].map(([id, dirs]) => [id, [...dirs]]),
  };
  const same = <T>(keys: Set<string>, before: Map<string, T>, now: Map<string, T>) => [...keys].every((key) =>
    before.has(key) === now.has(key) && before.get(key) === now.get(key));
  const current = () => same(claude, beforeElsewhere, elsewhere) && same(new Set(codex.keys()), beforeRollouts, rollouts) && [...reported].every((id) => {
    const before = beforeSaid.get(id)!, now = saidRollouts.get(id);
    if ((now?.size ?? 0) !== before.size) return false;
    return [...before].every(([dir, entry]) => now?.get(dir) === entry && beforeSeen.get(id)!.get(dir) === entry.seen);
  });
  return {
    value,
    current,
    merge(found) {
      if (!current()) return false;
      for (const [key, path] of found.rollouts) {
        const id = codex.get(key);
        if (id !== undefined && rollouts.get(key) !== path) { rollouts.set(key, path); hintChanged(id); }
      }
      for (const [id, dirs] of found.said) for (const [dir, entry] of dirs) {
        const old = beforeSaid.get(id)?.get(dir);
        if (old !== undefined && old.suffix === entry.suffix && entry.seen && !old.seen) { old.seen = true; hintChanged(id); }
      }
      return true;
    },
  };
}

/// Every in-process hint, for the usage counter's program (usage/counter-mb.ts), which finds transcripts as
/// `transcriptPathsLooking` here and gives back what it found (`takeTranscriptHints`).
export function allTranscriptHints(): TranscriptLocationHints {
  return {
    elsewhere: [...elsewhere], rollouts: [...rollouts],
    said: [...saidRollouts].map(([id, dirs]) => [id, [...dirs].map(([dir, entry]) => [dir, { ...entry }] as [string, SaidRollout])]),
  };
}

/// What another process found looking for transcripts with `allTranscriptHints`: the places found kept as if found
/// here, a reported rollout seen once there.
export function takeTranscriptHints(found: TranscriptLocationHints): void {
  for (const [key, path] of found.elsewhere) {
    const id = key.slice(key.indexOf("\0") + 1);
    if (!elsewhere.has(key) || elsewhere.get(key) !== path) { elsewhere.set(key, path); hintChanged(id); }
  }
  for (const [key, path] of found.rollouts) {
    if (rollouts.get(key) !== path) { rollouts.set(key, path); hintChanged(key.slice(key.indexOf("\0") + 1)); }
  }
  for (const [id, dirs] of found.said) for (const [dir, entry] of dirs) {
    const old = saidRollouts.get(id)?.get(dir);
    if (old !== undefined && old.suffix === entry.suffix && entry.seen && !old.seen) { old.seen = true; hintChanged(id); }
  }
}

/// The hints this process keeps, for what the tests' reference does with them (test/reference/transcript-paths.ts
/// `useTranscriptLocationHints`: a locator's worker of before, given a batch's).
export const keptTranscriptHints = () => ({ elsewhere, rollouts, saidRollouts });

/// Where a session works and worked, for `transcriptPathsLooking`: the directory it was moved to, and its workspace.
export const sessionPlaces = (row: { cwd: string | null; workspace: string }): string[] => (row.cwd !== null && row.cwd !== row.workspace ? [row.cwd, row.workspace] : [row.workspace]);

const divEuclid = (a: number, b: number) => Math.floor(a / b);

/// iso: an ISO timestamp of milliseconds since the epoch, as toISOString writes it (any year, as the Rust does).
export function iso(ms: number): string {
  const days = divEuclid(ms, 86_400_000);
  const rest = ms - days * 86_400_000;
  const z = days + 719_468;
  const era = divEuclid(z, 146_097);
  const doe = z - era * 146_097;
  const yoe = Math.trunc((doe - Math.trunc(doe / 1460) + Math.trunc(doe / 36_524) - Math.trunc(doe / 146_096)) / 365);
  const doy = doe - (365 * yoe + Math.trunc(yoe / 4) - Math.trunc(yoe / 100));
  const mp = Math.trunc((5 * doy + 2) / 153);
  const d = doy - Math.trunc((153 * mp + 2) / 5) + 1;
  const m = mp < 10 ? mp + 3 : mp - 9;
  const y = yoe + era * 400 + (m <= 2 ? 1 : 0);
  const pad = (n: number, w: number) => (n < 0 ? `-${String(-n).padStart(w - 1, "0")}` : String(n).padStart(w, "0"));
  const [h, mi, s, milli] = [Math.trunc(rest / 3_600_000), Math.trunc(rest / 60_000) % 60, Math.trunc(rest / 1000) % 60, rest % 1000];
  return `${pad(y, 4)}-${pad(m, 2)}-${pad(d, 2)}T${pad(h, 2)}:${pad(mi, 2)}:${pad(s, 2)}.${pad(milli, 3)}Z`;
}
