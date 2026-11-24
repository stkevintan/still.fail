// The stations of a workspace as the migration's tests make them (chat-handover*.test.ts, move-plan-bounded.test.ts):
// each a Rig (hub-fakes.ts) with its connects (connects/workspace.ts) and its moves (move/station.ts), over a transport
// of the test's; and a station shaped like the one moving was measured for (`officeShape`).
import { execFileSync } from "node:child_process";
import assert from "node:assert/strict";
import { mkdirSync, readFileSync, readdirSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { rm } from "node:fs/promises";
import { dirname, join } from "node:path";
import { afterEach } from "node:test";
import { PeerBus, bytesOf, withBytes } from "../src/mesh/bus.ts";
import { WorkspaceConnects } from "../src/connects/workspace.ts";
import { Fibers } from "../src/ops/fibers.ts";
import { type CarriedJob, gatherSoon, placeSoon, sizesSoon } from "../src/replica/carry.ts";
import { flushesOnce } from "../src/replica/sending.ts";
import { hubConfig } from "../src/sessions/config.ts";
import { newSession, say } from "../src/sessions/lifecycle.ts";
import { Moves } from "../src/move/station.ts";
import { moveRoutes } from "../src/move/routes.ts";
import type { Request } from "../src/api/request.ts";
import { plainStore } from "../src/vault/plain.ts";
import { vaultStore } from "../src/vault/store.ts";
import { METHOD, fromPeer } from "../src/sessions/messages.ts";
import { READ, forPeer } from "../src/sessions/others.ts";
import { Rig, testClock } from "./hub-fakes.ts";
import { MANUAL } from "../src/store/rows.ts";
import { Admin } from "../src/api/admin.ts";
import { newCtx } from "../src/store/handover.ts";

type Json = any;
export const WS = "ws";
export const A = "a".repeat(64);
export const B = "b".repeat(64);
export const C = "c".repeat(64);

function across(v: Json): Json {
  const bytes = bytesOf(v);
  const copy = JSON.parse(JSON.stringify(v));
  return bytes === null ? copy : withBytes(copy, bytes);
}

export type Station = {
  id: string; rig: Rig; bus: PeerBus; connects: WorkspaceConnects; moves: Moves; fibers: Fibers; up: boolean;
  /// Its API as a device asks it (api/admin.ts): what keeps a keyed write to once.
  admin: Admin;
  /// Moving switched on here (config.json `move`).
  on: boolean;
  /// The chats a plan reads at a time (none: the module's own).
  page?: number;
  /// The repositories found on the machine outside the repository cache (its RepoIndex's, the hub's).
  elsewhere?: string[];
  /// The holds of its self-update now (updates/holds.ts, its own here); a move of an account that never ends.
  holds: number;
  profileHangs?: boolean;
  /// Called as its config.json is written by a module (a setting taken).
  onUpdate?: () => void;
  /// Waited for before a hand-over's files are placed here (each placing, its index's path): a placing that takes long.
  placing?: (index: string) => Promise<void>;
  /// Called as a placing here ended.
  placed?: () => void;
  /// What a placing here took written out (sending.ts `flushOnce`), each its directory: none, nothing done.
  flushing?: (dir: string) => Promise<void>;
  /// When its machine started (handover.ts `boot`; none: 0).
  boot?: number;
  /// Waited for before a gathering here (each, the room's scratch), before git runs here (each command), before a drop
  /// here takes its files out, and before a clone here is removed: work that takes long.
  gathering?: (scratch: string) => Promise<void>;
  /// The most bytes one `handover.lacking` hashes here (none: the station's own).
  hashMost?: number;
  /// The most files and bytes of a pack sent from here (none: the station's own).
  packMost?: { files?: number; bytes?: number };
  /// What it answers a request, changed on its way back (a test's: a station from before).
  answered?: (request: Json, answer: Json) => Json;
  gitting?: (args: string[]) => Promise<void>;
  dropping?: (id: string) => Promise<void>;
  removing?: (dir: string) => Promise<void>;
  /// Its routes of move/routes.ts, as a device asks them.
  ask(method: string, path: string, body: Json, role?: string, query?: [string, string][]): Promise<{ status: number; body: Json }>;
  jobs: (CarriedJob & { id: string })[]; started: string[]; free: number; total?: number; sized: string[]; fails: Set<string>; onFail: ((step: string) => void | Promise<void>) | null;
  /// The jobs' rows read so far, as the store reads them (live.ts `up`): a session's by its index, a workspace's whole.
  jobsRead: number;
  /// Its own connects' surfaces, by their id here; git run as the station runs it.
  local: Map<string, Json>;
  git: (dir: string, args: string[]) => Promise<string>;
  make(previous?: Promise<void>): Moves;
};

const open: (() => Promise<void>)[] = [];
afterEach(async () => {
  for (const c of open.splice(0).reverse()) await c().catch(() => {});
});

/// How long a request's answer is waited for between stations (mesh/peer.ts ANSWER_MS).
export const ANSWER_MS = 30_000;

/// Stations of workspace "ws" (each its own Rig, its connects and its moves); A has the Slack connects cl and gpt.
/// `answerMs`: each request between them fails as mesh/peer.ts fails it when its answer did not come within ANSWER_MS
/// on the test's clock (the station asked goes on with it).
export function world(ids: string[] = [A, B], o: { answerMs?: boolean; packMost?: { files?: number; bytes?: number } } = {}) {
  const t = testClock();
  const stations = new Map<string, Station>();
  const roster = ids.map((id) => ({ id, name: id.slice(0, 1).toUpperCase() }));
  /// A request on its way, changed (a test's: a hash refused).
  let tamper: ((to: string, request: Json) => Json) | null = null;
  /// After a request was taken there, whether its answer is lost on the way back (a test's: what it fails with then).
  let lose: ((to: string, request: Json) => Error | null) | null = null;
  /// Each request asked between the stations, as it went and as it was answered (on the test's clock): what a test of
  /// the answers' bounds reads.
  const heard: { from: string; to: string; method: string; name?: string; at: number; answered: number | null; failed: string | null }[] = [];
  const make = (id: string): Station => {
    const rig = new Rig({ place: { workspace: WS, station: id }, workspaces: [WS], fileStore: true, clock: t.clock });
    const st = { id, rig, up: true, on: true, holds: 0, jobs: [], started: [], free: 1e15, sized: [], fails: new Set<string>(), onFail: null, jobsRead: 0, ...(o.packMost !== undefined ? { packMost: o.packMost } : {}) } as unknown as Station;
    st.bus = new PeerBus({ sleep: async () => {} });
    st.bus.attach(async (to, ws, request) => {
      const there = stations.get(to);
      if (there === undefined || !there.up || !st.up) throw new Error("station unreachable");
      const sent = tamper === null ? request : tamper(to, request);
      const seen = { from: id, to, method: String(request?.method ?? ""), ...(typeof request?.name === "string" ? { name: request.name as string } : {}), at: st.fibers.now(), answered: null as number | null, failed: null as string | null };
      heard.push(seen);
      const handled = there.bus.handle(ws ?? WS, id, across(sent));
      let late = () => {};
      const deadline = o.answerMs !== true ? null : new Promise<never>((_, reject) => (late = st.fibers.after(ANSWER_MS, () => reject(new Error("peer request timed out; execution may have happened — query the same task key"))))); // timer: a deadline (an answer's, as mesh/peer.ts waits for it)
      let answer: Json;
      try {
        answer = across(await (deadline === null ? handled : Promise.race([handled, deadline])));
        if (there.answered !== undefined) answer = there.answered(sent, answer);
        seen.answered = st.fibers.now();
      } catch (e) {
        seen.failed = (e as Error).message;
        handled.catch(() => {});
        throw e;
      } finally {
        late();
      }
      const lost = lose === null ? null : lose(to, sent);
      if (lost !== null) throw lost;
      return answer;
    });
    const tag = id.slice(0, 1);
    rig.raw.profiles = id === A
      ? [{ id: "cc", runtime: "claude", home: "homes/cc", share: { id: "sh-cc" } }, { id: "cx", runtime: "codex", home: "homes/cx", env: { OPENAI_API_KEY: "k" } }, { id: "mine", runtime: "claude", home: "homes/mine", machine: true }]
      : [{ id: `cc${tag}`, runtime: "claude", home: `homes/cc${tag}`, share: { id: "sh-cc", borrowed: true, host: A } }, { id: `cx${tag}`, runtime: "codex", home: `homes/cx${tag}`, env: { OPENAI_API_KEY: "k" } }];
    if (id !== A) rig.raw.connects = [];
    else rig.raw.connects = rig.raw.connects.filter((c: Json) => c.id !== "team");
    st.local = new Map<string, Json>([["cl", rig.chat], ["gpt", rig.gptChat]]);
    const config = () => {
      const read = hubConfig(rig.raw, rig.dir);
      read.connects.push(...st.connects.remote.connects());
      return read;
    };
    Object.defineProperty(rig, "config", { get: config, configurable: true });
    rig.hub = rig.newHub({ chats: (c) => (rig.raw.connects.some((e: Json) => e.id === c) ? st.local.get(c) : undefined) ?? st.connects.remote.surface(c) });
    st.connects = new WorkspaceConnects({
      data: rig.dir, hub: () => rig.hub, store: rig.store, config: { raw: () => rig.raw, updateSoon: async (f) => f(rig.raw) }, bus: st.bus,
      here: () => id, home: () => WS, stations: (ws) => (ws === WS ? roster : []), names: () => null,
    });
    st.fibers = new Fibers("move", t.clock);
    st.admin = new Admin({ names: new Map(), read: async () => "{}" } as Json, { store: rig.store, agents: () => ({ hub: rig.hub }) as Json, clock: t.clock });
    st.make = (previous?: Promise<void>) => {
      const wc = st.connects;
      const hub = rig.hub;
      const moves = new Moves({
        previous,
        data: rig.dir, store: rig.store, fibers: st.fibers, here: () => id, home: () => WS, roster: () => roster,
        ask: (s, r) => st.bus.ask(s, r),
        hub: { holdChat: (k, w, n) => hub.holdChat(k, w, n), releaseChat: (k) => hub.releaseChat(k), wakeChat: (k) => hub.wakeChat(k), busy: (k) => hub.busy(k), turnEnded: (k) => hub.turnEnded(k), drained: (c, ch, ts) => hub.drained(c, ch, ts), wsOf: (k) => hub.wsOf(k) },
        connects: {
          route: (c, ch, ts, to) => wc.route(c, ch, ts, to), describedFor: (c) => wc.describedFor(c), learnOf: (k, s, d) => wc.learnOf(k, s, d), kindOf: (c) => wc.kindOf(c),
          own: () => wc.ownIds(), ownIn: (ws) => wc.ownKinds(ws), runsOn: (c) => wc.runsOn(c), move: (c, to, awaiting) => wc.move(c, to, null, undefined, undefined, awaiting ?? []), movedAway: (ws) => wc.movedAway(ws), arrived: (keys) => wc.arrived(keys),
        },
        jobs: {
          up: (keys, ws) => {
            const up = st.jobs.filter((j) => (keys === null ? ws === undefined || hub.ofWorkspace(j.session, ws) : keys.includes(j.session)));
            st.jobsRead += keys === null ? st.jobs.length : up.length;
            return up;
          },
          stop: async (jid) => void (st.jobs = st.jobs.filter((j) => j.id !== jid)),
          start: (j) => {
            st.jobs.push({ ...j, id: `${tag}-job-${st.started.length}` });
            // (one started while its chat is away from this station says so: never meant to be)
            st.started.push(`${j.session}#${j.name}@${j.cwd}${rig.store.handedTo(j.session) !== null ? " (its chat away)" : ""}`);
          },
          stopNamed: async (s, n) => void (st.jobs = st.jobs.filter((j) => !(j.session === s && j.name === n))),
        },
        profiles: () => rig.raw.profiles,
        moveProfile: async (pid, to) => {
          if (st.profileHangs) return await new Promise<never>(() => {});
          const p = rig.raw.profiles.find((x: Json) => x.id === pid);
          const there = stations.get(to)!;
          there.rig.raw.profiles.push(structuredClone(p));
          rig.raw.profiles = rig.raw.profiles.filter((x: Json) => x.id !== pid);
          return { id: pid };
        },
        sessionsIn: (ws, after, limit) => rig.store.sessionPageOfWs(ws === WS ? null : ws, WS, after, limit),
        reposDir: join(rig.dir, "repos"),
        clonesElsewhere: async () => st.elsewhere ?? [],
        room: async () => ({ free: st.free, total: st.total ?? null }),
        // (sized as a move would gather them, at once; each session sized here named, the other side's by its places)
        sizes: async (keys, sizing) => {
          st.sized.push(...keys, ...(sizing.places ?? []).map((p) => `there:${p.key}`));
          return sizesSoon(rig.dir, join(rig.dir, "stillfail.db"), keys, sizing);
        },
        hasGit: async () => true,
        // (the machine's own flush is sending-flush.test.ts's: here only what a test says)
        flush: flushesOnce ? (dir) => (st.flushing ?? (async () => {}))(dir) : null,
        boot: () => st.boot ?? 0,
        lackMost: 50,
        hashMost: st.hashMost,
        packMost: st.packMost,
        remove: async (dir) => {
          await st.removing?.(dir);
          await rm(dir, { recursive: true, force: true });
        },
        work: {
          gather: async (...args) => {
            await st.gathering?.(args[4]);
            return gatherSoon(...args);
          },
          drop: async (hid) => void (await st.dropping?.(hid)),
          place: async (dataDir, index, from, made, aside, placed, projects) => {
            await st.placing?.(index);
            try {
              return await placeSoon(dataDir, index, from, made ?? null, aside ?? null, placed ?? null, projects ?? false);
            } finally {
              st.placed?.();
            }
          },
        },
        fail: (step) => {
          const waited = st.onFail?.(step);
          if (st.fails.delete(step)) throw new Error(`the test failed ${step}`);
          return waited;
        },
        git: st.git,
        config: { raw: () => rig.raw, updateSoon: async (f) => (st.onUpdate?.(), f(rig.raw)) },
        moveOn: () => st.on,
        planPage: st.page,
        hold: () => {
          st.holds++;
          let gone = false;
          return () => void (gone || ((gone = true), st.holds--));
        },
        keptSends: (threads) => st.admin.keptSends(threads),
        keepSends: (sends) => st.admin.keepSends(sends),
        vault: {
          owners: (ws) => (rig.store.db.prepare("SELECT DISTINCT owner FROM vault_plain WHERE ws = ?").all(ws) as { owner: string }[]).map((r) => r.owner),
          grantOwners: () => new Map(),
          plain: plainStore(rig.store.db),
          vaults: vaultStore(rig.store.db) as Json,
        },
      });
      st.bus.on("handover.", moves.answers(() => true));
      st.bus.on("move.", moves.answers(() => true));
      return moves;
    };
    st.git = async (dir: string, args: string[]) => (await st.gitting?.(args), execFileSync("git", ["-C", dir, ...args], { encoding: "utf8", env: gitEnv(rig.dir), stdio: ["ignore", "pipe", "pipe"] }).trim());
    st.moves = st.make();
    const routes = moveRoutes({
      scheduler: { busy: () => st.moves.scheduler.busy(), last: (ws: string) => st.moves.scheduler.last(ws), plan: (ws: string, to: string) => st.moves.scheduler.plan(ws, to), planShown: (ws: string, to: string) => st.moves.scheduler.planShown(ws, to), held: (ws: string, to: string) => st.moves.scheduler.held(ws, to), stopped: () => st.moves.scheduler.stopped(), move: (...a: Parameters<Moves["scheduler"]["move"]>) => st.moves.scheduler.move(...a), back: (...a: Parameters<Moves["scheduler"]["back"]>) => st.moves.scheduler.back(...a), stopTurn: (by: string | null) => st.moves.scheduler.stopTurn(by), stopping: () => st.moves.scheduler.stopping(), current: () => st.moves.scheduler.current() } as Json,
      order: () => st.moves.modules.map((m) => m.id), home: () => WS, here: () => id, rig: () => false,
      station: (_ws, v) => (roster.some((r) => r.id === v || r.name === v) ? { id: roster.find((r) => r.id === v || r.name === v)!.id, tasks: false } : null),
      refusal: (ws, s, lang) => st.moves.refusal(ws, s, lang),
      chatOf: (k) => st.moves.handover.chatOf(k),
    });
    st.ask = async (method, path, body, role = "owner", query = []) => {
      const route = routes.find((r) => r.method === method && r.pattern.test(path))!;
      const r: Request = { method, path, query, headers: {}, body: Buffer.from(body === null ? "" : JSON.stringify(body)), viewer: { sub: "o", email: `${role}@x`, name: role, role, workspace: WS, device: "d" } as Json, lang: "en" };
      const a = await route.handle(r, []);
      return { status: a.status, body: JSON.parse(String(a.body)) };
    };
    // (a letter to a chat of another station's, and one there coming here: messages.ts)
    rig.hub.onPeer((station, request) => st.bus.ask(station, request));
    st.bus.on(METHOD, (peer, request, ws) => fromPeer(rig.hub, peer, request, ws ?? null));
    st.bus.on(READ, (peer, request, ws) => forPeer(rig.hub, peer, request, ws ?? null));
    // (a station heard from again: what is owed to it is told now, as move/live.ts has it)
    st.bus.heard((peer) => {
      st.moves.handover.reached(peer);
      st.moves.heard(peer);
    });
    stations.set(id, st);
    open.push(async () => {
      await st.moves.close();
      await st.fibers.close();
      await rig.close();
    });
    return st;
  };
  for (const id of ids) make(id);
  const quiet = async () => {
    for (let i = 0; i < 3; i++) for (const s of stations.values()) {
      await s.moves.handover.settle();
      await s.rig.quiet();
    }
  };
  return { t, stations, get: (id: string) => stations.get(id)!, quiet, heard, tamper: (f: typeof tamper) => void (tamper = f), lose: (f: typeof lose) => void (lose = f) };
}

/// The running turn of a station's session ended with a state, as its agent would.
export async function endTurn(st: Station, key: string, driver: "claude" | "codex" = "claude") {
  await st.rig.quiet();
  await st.rig.call(key, "chat_state", { kind: "final" });
  // (its own runtime session: a station with more chats keeps a process for each)
  const own = st.rig[driver].sessions.filter((s) => s.options.key === key).at(-1);
  if (own === undefined) throw new Error(`no ${driver} session of ${key}`);
  own.complete();
  await st.rig.quiet();
}

/// A still.fail chat of A's with a turn behind it (its runtime session `claude-1` on account cc) and a file of its own.
export async function stillfailChat(st: Station) {
  const [key, thread] = await newSession(st.rig.hub, { runtime: "claude", profile: "cc", createdBy: "p@x" });
  say(st.rig.hub, thread.id, "p@x", "look at the build");
  await st.rig.quiet();
  await endTurn(st, key);
  const ws = st.rig.session(key).workspace;
  mkdirSync(ws, { recursive: true });
  writeFileSync(join(ws, "notes.md"), "what I was doing");
  return { key, thread: thread.id };
}

export const gitEnv = (home: string) => ({ ...process.env, GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@x", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@x", GIT_CONFIG_NOSYSTEM: "1", HOME: home });

/// The files under `dir`, by their path in it, with their bytes (what a room holds).
export function filesOf(dir: string): Record<string, string> {
  const out: Record<string, string> = {};
  const walk = (at: string) => {
    for (const name of readdirSync(at)) {
      const path = join(at, name);
      if (statSync(path).isDirectory()) walk(path);
      else out[path.slice(dir.length + 1)] = readFileSync(path, "utf8");
    }
  };
  walk(dir);
  return out;
}

export const entries = (st: Station, thread: number) => st.rig.store.entriesAfter(thread, 0).map((e) => `${e.authorKind}:${e.text ?? ""}`);
export const homeThread = (st: Station, key: string) => st.rig.store.homeChat(key)?.id ?? st.rig.store.sessionThreads(key)[0]!.thread.id;

/// A's chats as the station moving was measured for had them (Office-VM-1, 2026-11-14: 2,384 in its home workspace, 149
/// of them live, most of them Slack threads' chats, 9 accounts, 5 connects, 6 jobs), `n` of them in that shape: each a
/// Slack thread of one of A's Slack connects with three messages and a runtime session, those past the live ones
/// archived; half saying no workspace, half the home's id; 30 canonical clones in the repository cache, a linked
/// worktree of one of them in every sixth chat's room, 400 at most (as git leaves them, without git).
/// `git`: the clones and worktrees made by git, each clone's remote a bare repository of the test's (what a move of
/// them runs); else only the files git would leave, which a plan reads.
export function officeShape(n: number, o: { git?: boolean } = {}) {
  const w = world();
  const a = w.get(A);
  for (let k = 0; k < 6; k++) a.rig.raw.profiles.push({ id: `p${k}`, runtime: "claude", home: `homes/p${k}`, share: { id: `sh-p${k}` } });
  for (let k = 0; k < 3; k++) a.rig.raw.connects.push({ id: `sl${k}`, slack: { botName: `bot ${k}` }, bind: { runtime: "claude" } });
  const store = a.rig.store;
  const profiles = ["cc", "p0", "p1", "p2", "p3", "p4", "p5", "cx", "mine"];
  const live = Math.round((n * 149) / 2384);
  const keys: string[] = [];
  for (let i = 0; i < n; i++) {
    const ts = `${1700000000 + i}.000100`;
    const connect = ["cl", "cl", "cl", "sl0", "sl1", "sl2", "gpt"][i % 7]!;
    const key = `${connect}:C1:${ts}`;
    const profile = profiles[i % profiles.length]!;
    store.insertSession({ key, connect, runtime: "claude", profile, workspace: join(a.rig.dir, "sessions", `s${i}`, "workspace"), token: `office${i}`, createdAt: 1, lastActiveAt: 1, ws: i % 2 === 0 ? null : WS });
    const t = store.openThread("slack:T1", "C1", ts, null, "p@x");
    store.joinThread(t.id, key, connect);
    for (let m = 0; m < 3; m++) store.insertMessage({ thread: t.id, ts: `${1700000000 + i}.00010${m}`, authorKind: "person", author: "U1", text: "hi" });
    store.ranIn(key, `run-${i}`, profile);
    if (i >= live) store.setArchived(key, true, MANUAL);
    keys.push(key);
  }
  for (let k = 0; k < 6; k++) a.jobs.push({ id: `A-job-${k}`, session: keys[k]!, name: `dev${k}`, cwd: join(a.rig.dir, "sessions", `s${k}`, "workspace"), command: "npm run dev" } as Json);
  const run = (dir: string, ...args: string[]) => execFileSync("git", ["-C", dir, ...args], { encoding: "utf8", env: gitEnv(a.rig.dir), stdio: ["ignore", "pipe", "pipe"] });
  for (let c = 0; c < 30; c++) {
    const repo = join(a.rig.dir, "repos", `r${c}`);
    if (o.git === true) {
      const bare = join(a.rig.dir, "remotes", `r${c}.git`);
      mkdirSync(bare, { recursive: true });
      run(bare, "init", "-q", "--bare", "-b", "main");
      execFileSync("git", ["clone", "-q", bare, repo], { env: gitEnv(a.rig.dir), stdio: "ignore" });
      writeFileSync(join(repo, "README"), `r${c}\n`);
      run(repo, "add", "-A");
      run(repo, "commit", "-q", "-m", "first");
      run(repo, "push", "-q", "origin", "HEAD:main");
      continue;
    }
    mkdirSync(join(repo, ".git"), { recursive: true });
    writeFileSync(join(repo, ".git", "config"), `[remote "origin"]\n\turl = https://example.test/r${c}.git\n`);
  }
  for (let i = 0; i < n && i < 6 * 400; i += 6) {
    const repo = join(a.rig.dir, "repos", `r${i % 30}`);
    const at = join(a.rig.dir, "sessions", `s${i}`, "workspace", `r${i % 30}`);
    if (o.git === true) {
      mkdirSync(dirname(at), { recursive: true });
      run(repo, "worktree", "add", "-q", "-b", `s${i}`, at);
      continue;
    }
    mkdirSync(join(repo, ".git", "worktrees", `s${i}`), { recursive: true });
    writeFileSync(join(repo, ".git", "worktrees", `s${i}`, "gitdir"), `${join(at, ".git")}\n`);
    mkdirSync(at, { recursive: true });
    writeFileSync(join(at, ".git"), `gitdir: ${join(repo, ".git", "worktrees", `s${i}`)}\n`);
  }
  return { w, a, keys, live };
}

/// B holding a retired copy of A's chat as the switched-off retirement left it (ws `retired:<ws>`, its threads put in
/// with B's own ids, its files in place, their times kept): what A's rows and room were then.
export function retiredCopy(a: Station, b: Station, key: string, ws: string | null = `retired:${WS}`) {
  const ctx = newCtx({ from: A, here: B, fromData: a.rig.dir, toData: b.rig.dir, connects: {}, profiles: { cc: "ccb" }, ws: ws as string }); // (none: a live row of the home workspace)
  b.rig.store.importRows(ctx, "sessions", a.rig.store.chatPage("sessions", key, null, 500, [key]));
  for (const t of a.rig.store.chatThreads([key], 0, 200)) {
    for (const table of ["threads", "thread_sessions", "entries", "letters"] as const) b.rig.store.importRows(ctx, table, a.rig.store.chatPage(table, t, null, 500, [key]));
  }
  const from = a.rig.session(key).workspace;
  const to = b.rig.session(key).workspace;
  mkdirSync(to, { recursive: true });
  for (const n of readdirSync(from)) {
    if (!statSync(join(from, n)).isFile()) continue;
    writeFileSync(join(to, n), readFileSync(join(from, n)));
    const st = statSync(join(from, n));
    utimesSync(join(to, n), st.atime, st.mtime);
  }
}

/// What a device and the move page read of chat `key` on each station of `w` (where it is, in sight, held, its row,
/// its page's log, the jobs), started again: the same as before (a start at rest changes nothing).
export async function startedAgainChangesNothing(w: ReturnType<typeof world>, key: string, how: string) {
  const read = async () => {
    const out: Json = {};
    for (const st of w.stations.values()) {
      const row = st.rig.store.getSession(key);
      const other = [...w.stations.keys()].find((id) => id !== st.id)!;
      const item = (await st.moves.scheduler.plan(WS, other)).items.find((x) => x.module === "chats" && x.id === key);
      const home = row === null ? null : st.rig.store.homeChat(key);
      out[st.id.slice(0, 1)] = {
        row: row === null ? null : { ws: row.ws, archivedAt: row.archivedAt },
        handedTo: st.rig.store.handedTo(key)?.station.slice(0, 1) ?? null,
        held: st.rig.hub.chatHeld(key),
        item: item === undefined ? null : { state: item.state },
        log: home === null ? null : entries(st, home.id),
        jobs: st.jobs.map((j) => `${j.session}#${j.name}`),
      };
    }
    return out;
  };
  // (kept stopped and held as stopped are one fact on every station: neither without the other)
  const oneFact = (when: string) => {
    for (const st of w.stations.values()) {
      const listed = st.moves.scheduler.stopped().some((s) => s.item.module === "chats" && s.item.id === key);
      const held = /^stopped: /.test(st.rig.hub.chatHeld(key) ?? "");
      assert.equal(listed, held, `${how}, ${when}: on ${st.id.slice(0, 1)} the chat is ${listed ? "kept stopped but not held" : "held as stopped but not kept so"}`);
      // (and nothing kept stopped of a chat that is not here: handed away, it waits for nothing here)
      if (listed) assert.equal(st.rig.store.handedTo(key), null, `${how}, ${when}: on ${st.id.slice(0, 1)} the chat is kept stopped though it was handed away`);
    }
  };
  oneFact("at rest");
  const before = await read();
  for (const st of w.stations.values()) {
    await st.moves.close();
    st.moves = st.make();
  }
  for (const st of w.stations.values()) await st.moves.start();
  await w.quiet();
  assert.deepEqual(await read(), before, `${how}: a start at rest changes nothing`);
  oneFact("started again");
}
