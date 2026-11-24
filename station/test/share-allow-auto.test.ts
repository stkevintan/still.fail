// A shared profile whose stations follow the workspace's whitelist (src/share/index.ts `allowAuto`): who may use it is
// this station and each other that says it takes automatically assigned chats, as each says that changed
// (share.autoChats) or answers `describe`; a station never heard from is left out, one not answering now keeps its copy.
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { checkConfig } from "../src/accounts/check.ts";
import { Cloud } from "../src/cloud/state.ts";
import { Refused } from "../src/mesh/bus.ts";
import { ConfigFile } from "../src/ops/config.ts";
import { Sharing } from "../src/share/index.ts";

const A = "a".repeat(64);
const B = "b".repeat(64);
const C = "c".repeat(64);

/// One workspace's roster, as still.fail cloud says it.
class World {
  roster = [A, B, C];
  /// What each station says of itself: on the whitelist (takes automatically assigned chats), or not.
  accepts: Record<string, boolean> = { [A]: false, [B]: true, [C]: false };
  /// Stations that do not answer now.
  away = new Set<string>();
  /// The `describe`s asked, by whom of whom.
  described: string[] = [];
  stations = new Map<string, Station>();
  cloudFor(station: string) {
    const world = this;
    return Object.defineProperties(Object.create(Cloud.prototype), Object.getOwnPropertyDescriptors({
      peersCurrent: true,
      lock: null,
      get state() {
        return { station, workspace: "w", workspace_name: "w", peers: world.roster.map((id) => ({ id, name: id.slice(0, 1) })), revocations: [], joined: [] } as any;
      },
      listen() {
        return () => {};
      },
    })) as any;
  }
}

type Station = { data: string; config: ConfigFile; sharing: Sharing };
const made: Sharing[] = [];
after(() => Promise.all(made.map((s) => s.close())));

function station(world: World, id: string, profiles: any[] = [], data = mkdtempSync(join(tmpdir(), "share-auto-"))): Station {
  writeFileSync(join(data, "config.json"), JSON.stringify({ profiles }));
  const config = new ConfigFile(data);
  config.check = checkConfig;
  mkdirSync(join(data, "agent", "skills"), { recursive: true });
  const sharing = new Sharing({
    data, config, cloud: world.cloudFor(id),
    // As remote.ts takes it: `describe` answered by the station itself (jobs/remote.ts), share.* by its sharing.
    ask: async (to, _workspace, request) => {
      const other = world.stations.get(to);
      if (!other || world.away.has(to)) throw new Error("peer unavailable");
      if (request.method === "describe") {
        world.described.push(`${id.slice(0, 1)}>${to.slice(0, 1)}`);
        return { protocol: 1, acceptAutoChats: world.accepts[to] === true };
      }
      return other.sharing.handle(id, request, "w");
    },
    agentHome: () => join(data, "agent"),
    env: {},
    claudeToken: async (p) => ({ token: `token-of-${p.id}`, expiresAt: Date.now() + 2 * 3600_000 }),
    codexRenewRunning: async () => false,
    status: async () => ({ check: null, quota: null }),
    changed: () => {},
    autoChats: () => ({ accept: world.accepts[id] === true, tasksOnly: false }),
  });
  made.push(sharing);
  const s = { data, config, sharing };
  world.stations.set(id, s);
  return s;
}

const settle = async (...stations: Station[]) => {
  for (let i = 0; i < 5; i++) {
    await new Promise((r) => setImmediate(r));
    await Promise.all(stations.map((s) => s.sharing.reconcile()));
  }
  await Promise.all(stations.map((s) => s.sharing.stateWritten()));
};

const KEY = { id: "deepseek", name: "DeepSeek", access: { kind: "api-provider", provider: "deepseek", key: "sk-secret" }, home: "homes/deepseek", env: {} };
const has = (s: Station, id: string) => s.config.raw().profiles.some((p: any) => p.share?.id === id && p.share.borrowed === true);

test("a profile following the whitelist reaches those on it, follows each as it says it changed, and its host is always among them", async () => {
  const world = new World();
  const a = station(world, A, [KEY]);
  const b = station(world, B);
  const c = station(world, C);
  await a.sharing.shareProfile("deepseek", true, null, null, null, true);
  const share = a.config.raw().profiles[0].share;
  assert.deepEqual({ allow: share.allow, allowAuto: share.allowAuto }, { allow: null, allowAuto: true }, "kept as a rule, not a list");
  await settle(a, b, c);
  const id = share.id;
  assert.deepEqual([has(b, id), has(c, id)], [true, false], "B is on the whitelist, C is not");
  const view = a.sharing.profileView(a.config.raw().profiles[0], "w")!;
  assert.equal(view.allowAuto, true);
  assert.deepEqual([...view.allow!].sort(), [A, B], "the stations it makes now, the host among them: a list apps from before read");
  // A station turned on: it tells the others, and gets the profile.
  world.accepts[C] = true;
  c.sharing.notifyAutoChats();
  await settle(a, b, c);
  assert.equal(has(c, id), true, "C turned on gets it");
  // One turned off: told it is not for it, its copy taken away.
  world.accepts[B] = false;
  b.sharing.notifyAutoChats();
  await settle(a, b, c);
  assert.deepEqual([has(b, id), has(c, id)], [false, true], "B turned off loses it");
  assert.deepEqual([...a.sharing.profileView(a.config.raw().profiles[0], "w")!.allow!].sort(), [A, C]);
  // What it heard is kept: a host started again leaves nobody out that was in, then asks each again.
  assert.deepEqual(JSON.parse(readFileSync(join(a.data, "share", "state.json"), "utf8")).autoPeers, { [B]: false, [C]: true });
});

test("a station never heard from is left out; one that does not answer for now keeps its copy and is asked again", async () => {
  const world = new World();
  world.away.add(C);
  world.accepts[C] = true;
  const a = station(world, A, [KEY]);
  const b = station(world, B);
  const c = station(world, C);
  await a.sharing.shareProfile("deepseek", true, null, null, null, true);
  await settle(a, b);
  const id = a.config.raw().profiles[0].share.id;
  assert.equal(has(c, id), false, "never heard from: left out, nothing sent to it");
  // Asked by it before its host heard from it, and it does not answer `describe`: refused for now, never NOT_FOR_IT.
  await assert.rejects(a.sharing.handle(C, { method: "share.get", id }, "w"), /has not heard yet/);
  // It answers again: asked, then let in.
  world.away.delete(C);
  await settle(a, b, c);
  assert.equal(has(c, id), true);
  // Away a while: what it said last stands, its copy kept.
  world.away.add(C);
  world.described.length = 0;
  await settle(a, b);
  assert.equal(has(c, id), true, "a station away keeps its copy");
  assert.deepEqual(world.described, [], "nobody asked again in the same run once heard");
});

test("asked by one not heard from, a host started again asks it first: on the whitelist it is answered, else NOT_FOR_IT", async () => {
  const world = new World();
  const a = station(world, A, [KEY]);
  const b = station(world, B);
  station(world, C);
  await a.sharing.shareProfile("deepseek", true, null, null, null, true);
  const id = a.config.raw().profiles[0].share.id;
  // (none heard from yet: no pass made)
  assert.equal((await a.sharing.handle(B, { method: "share.version", id }, "w")).version >= 0, true);
  await assert.rejects(a.sharing.handle(C, { method: "share.version", id }, "w"), /not for this station/);
  // (each asked once, whether by the request or by the pass sharing it began: one question a station at a time)
  assert.deepEqual([...world.described].sort(), ["a>b", "a>c"]);
  await settle(a, b);
});

test("a move's lending to a station off the whitelist lets it besides, and undoing it leaves the whitelist followed", async () => {
  const world = new World();
  const a = station(world, A, [KEY]);
  const b = station(world, B);
  const c = station(world, C);
  await a.sharing.shareProfile("deepseek", true, null, null, null, true);
  await settle(a, b, c);
  const lent = await a.sharing.lendTo("deepseek", C);
  assert.equal(lent.widened, true);
  const share = () => a.config.raw().profiles[0].share;
  assert.deepEqual({ allow: share().allow, allowAuto: share().allowAuto }, { allow: [C], allowAuto: true });
  assert.equal(has(c, lent.share), true, "lent its copy at once");
  await a.sharing.unlend(lent.share, C, lent.made, lent.widened);
  assert.deepEqual({ allow: share().allow, allowAuto: share().allowAuto }, { allow: null, allowAuto: true });
  await settle(a, b, c);
  assert.equal(has(c, lent.share), false, "the move done with it, C is left out again");
});

test("chosen among the workspace's stations again, one that followed the whitelist starts from the stations it made", async () => {
  const world = new World();
  const a = station(world, A, [KEY]);
  const b = station(world, B);
  const c = station(world, C);
  await a.sharing.shareProfile("deepseek", true, null, null, null, true);
  await settle(a, b, c);
  // B and C chosen by hand among the workspace's stations: a list, not following the whitelist any more.
  await a.sharing.shareProfile("deepseek", true, [A, C], [A, B, C]);
  const share = a.config.raw().profiles[0].share;
  assert.equal(share.allowAuto, undefined);
  assert.deepEqual([...share.allow].sort(), [A, C]);
  await settle(a, b, c);
  const id = share.id;
  assert.deepEqual([has(b, id), has(c, id)], [false, true]);
});

test("a station from before, refusing share.autoChats, is not told again", async () => {
  const world = new World();
  const a = station(world, A, [KEY]);
  const b = station(world, B);
  // (B from before: share.autoChats unknown to it)
  const handle = b.sharing.handle.bind(b.sharing);
  let told = 0;
  b.sharing.handle = async (peer, request, ws) => {
    if (request.method === "share.autoChats") {
      told++;
      throw new Refused("this station does not share that");
    }
    return handle(peer, request, ws);
  };
  await settle(a, b);
  await settle(a, b);
  assert.equal(told, 1);
});
