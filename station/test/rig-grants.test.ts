// A rig's own record of who may use it (rig/grants.ts, a station that only runs tasks in one or more workspaces): only
// what its person signed with a key on the lock the rig pinned counts; a grant lasts as a vault's does (fixed, or until
// idle, a running task being use); taken back or 免批准 turned off, what the chats left without a grant run there stops.
import assert from "node:assert/strict";
import { createHash, generateKeyPairSync, sign as nodeSign } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { type GrantBody, type Kind, type Timeout, latest, signedBytes } from "../../client/core-ts/src/rig-form.ts";
import { type Entry, entryHash, signedBytes as entryBytes } from "../../shared/lock.ts";
import { applyState, replaySkippedRigFrame } from "../src/cloud/presence.ts";
import { rigAllowed } from "../src/mesh/peer-http.ts";
import { Cloud, MODE_PENDING_S, readState, rigGrantsPath, writeState } from "../src/cloud/state.ts";
import { Fibers } from "../src/ops/fibers.ts";
import { type Ended, RigGrants } from "../src/rig/grants.ts";
import { settle, testClock } from "./hub-fakes.ts";

const WS = "01WORKSPACE";
const WS2 = "02WORKSPACE";
const RIG = "aa".repeat(32);
const STATION = "bb".repeat(32);
const OTHER = "cc".repeat(32);
const START = 1_800_000_000_000;
const sha256 = (bytes: Uint8Array) => createHash("sha256").update(bytes).digest();

function ed() {
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const hex = (publicKey.export({ format: "der", type: "spki" }) as Buffer).subarray(-32).toString("hex");
  return { hex, id: `ed25519:${hex}`, sign: (bytes: Uint8Array) => nodeSign(null, bytes, privateKey).toString("hex") };
}
type Key = ReturnType<typeof ed>;

/// A person's own lock: its chain as made so far, and a statement signed by one of its keys.
function person(sub: string) {
  const first = ed();
  const chain: Entry[] = [];
  const add = (kind: string, body: unknown, by: Key) => {
    const last = chain[chain.length - 1];
    const e = { v: 1, ws: `person:${sub}`, seq: chain.length, prev: last ? entryHash(last) : null, at: 1000, kind, body } as Omit<Entry, "sig">;
    chain.push({ ...e, sig: { key: by.id, alg: "Ed25519", sig: by.sign(entryBytes(entryHash(e as Entry))) } } as Entry);
  };
  add("genesis", { sub, device: { key: first.id, id: ed().hex, label: "first" } }, first);
  const says = <B>(kind: Kind, body: B, by: Key = first) => ({ body, sig: { key: by.id, sig: by.sign(signedBytes(kind, body, sha256)) } });
  return { sub, first, chain, add, says, genesis: () => entryHash(chain[0]!) };
}

async function world(workspaces: string[] = [WS]) {
  const dir = mkdtempSync(join(tmpdir(), "rig-grants-"));
  const time = testClock();
  await time.adjust(START);
  const fibers = new Fibers("rig-test", time.clock);
  const owner = person("pat");
  const busy = new Set<string>();
  const stopped: string[] = [];
  const ended: Ended[] = [];
  const cuts: string[] = [];
  let changes = 0;
  const made: RigGrants[] = [];
  const make = (wsList: string[] = workspaces) => {
    const rig = new RigGrants({
      path: join(dir, "grants.json"),
      selfFor: (ws) => (wsList.includes(ws) ? { id: RIG, workspace: ws, owner: "pat", person: owner.genesis() } : null),
      workspaces: () => wsList.map((ws) => ({ id: RIG, workspace: ws, owner: "pat", person: owner.genesis() })),
      busy: (ws, station, session) => busy.has(`${ws}/${station}/${session}`) || busy.has(`${station}/${session}`),
      stop: (_ws, station, session) => void stopped.push(`${station}/${session}`),
      running: () => [...busy].map((k) => {
        const parts = k.split("/");
        return parts.length === 3 ? { workspace: parts[0]!, station: parts[1]!, session: parts[2]! } : { workspace: WS, station: parts[0]!, session: parts[1]! };
      }),
      ended: (e) => void ended.push(e),
      changed: () => void changes++,
      cut: (_ws, device, station, session) => void cuts.push(`${device}:${station ?? "*"}/${session ?? "*"}`),
      fibers,
    });
    made.push(rig);
    return rig;
  };
  const now = () => Math.floor(fibers.now() / 1000);
  const grant = (request: string, session: string, timeout: Timeout, more: Partial<GrantBody> = {}, by?: Key) => {
    const at = now();
    return owner.says("grant", { v: 1, sub: "pat", ws: WS, rig: RIG, station: STATION, session, chat: `CHAT/${session}`, request, title: `chat ${session}`, by: "lee@example.com", timeout, at, exp: latest(at, timeout), ...more } as GrantBody, by);
  };
  return {
    dir, owner, make, grant, busy, stopped, ended, cuts, now, changes: () => changes,
    pass: (ms: number) => time.adjust(ms),
    close: async () => {
      await fibers.close();
      for (const r of made) await r.close();
      rmSync(dir, { recursive: true, force: true });
    },
  };
}

test("only what the rig's person signed with a key on the lock it pinned gives a chat the rig", async () => {
  const w = await world();
  try {
    const rig = w.make();
    assert.match(rig.refusal(WS, STATION, "s1")!, /no grant of this station, which only runs tasks: ask for one with station_use/);
    assert.match(rig.refusal("other", STATION, "s1")!, /another workspace/);
    const signed = w.grant("r1", "s1", { kind: "idle", seconds: 3600 });
    assert.throws(() => rig.grant(WS, STATION, signed), /not on this rig's person's own lock/);
    assert.throws(() => rig.grant(WS, OTHER, signed, w.owner.chain), /brought by its chat's own station/);
    assert.throws(() => rig.grant(WS, STATION, w.grant("r1", "s1", { kind: "idle", seconds: 3600 }, { rig: "dd".repeat(32) }), w.owner.chain), /another rig or workspace/);
    assert.throws(() => rig.grant(WS, STATION, w.grant("r1", "s1", { kind: "idle", seconds: 3600 }, { sub: "mallory" }), w.owner.chain), /not signed by this rig's person/);
    assert.throws(() => rig.grant(WS, STATION, { ...signed, body: { ...signed.body, session: "s2" } }, w.owner.chain), /signature does not hold/);
    const stranger = ed();
    assert.throws(() => rig.grant(WS, STATION, w.grant("r1", "s1", { kind: "idle", seconds: 3600 }, {}, stranger), w.owner.chain), /not on this rig's person's own lock/);
    assert.throws(() => rig.grant(WS, STATION, signed, person("pat").chain), /not the one this rig's person pinned/);
    assert.match(rig.refusal(WS, STATION, "s1")!, /no grant/);

    assert.deepEqual(rig.grant(WS, STATION, signed, w.owner.chain), { until: signed.body.exp });
    assert.equal(rig.refusal(WS, STATION, "s1"), null);
    assert.match(rig.refusal(WS, STATION, "s2")!, /no grant/);
    assert.match(rig.refusal(WS, OTHER, "s1")!, /no grant/);
    assert.equal(rig.stationRefusal(WS, STATION), null);
    assert.match(rig.stationRefusal(WS, OTHER)!, /no chat of that station/);
    assert.deepEqual(rig.view(WS)!.grants.map((g) => [g.request, g.station, g.session, g.title, g.by, g.timeout.kind]), [["r1", STATION, "s1", "chat s1", "lee@example.com", "idle"]]);

    const second = ed();
    w.owner.add("device", { key: second.id, id: ed().hex, label: "second" }, w.owner.first);
    assert.deepEqual(rig.grant(WS, STATION, w.grant("r2", "s2", { kind: "fixed", seconds: 600 }, {}, second), w.owner.chain), { until: w.now() + 600 });
    const before = [...w.owner.chain];
    w.owner.add("device.remove", { key: second.id }, w.owner.first);
    rig.takeChain(WS, w.owner.chain);
    assert.throws(() => rig.grant(WS, STATION, w.grant("r3", "s3", { kind: "fixed", seconds: 600 }, {}, second), before), /not on this rig's person's own lock/);
  } finally {
    await w.close();
  }
});

test("a grant ends when its time is up or the chat has used the rig for nothing that long; a running task is use", async () => {
  const w = await world();
  try {
    const rig = w.make();
    rig.grant(WS, STATION, w.grant("fixed", "s1", { kind: "fixed", seconds: 600 }), w.owner.chain);
    rig.grant(WS, STATION, w.grant("idle", "s2", { kind: "idle", seconds: 600 }), w.owner.chain);
    await w.pass(300_000);
    assert.equal(rig.refusal(WS, STATION, "s1"), null);
    assert.equal(rig.refusal(WS, STATION, "s2"), null);
    await w.pass(300_000);
    assert.deepEqual(w.ended, [{ workspace: WS, request: "fixed", station: STATION, session: "s1", why: "expired" }]);
    assert.deepEqual(w.stopped, [`${STATION}/s1`]);
    assert.match(rig.refusal(WS, STATION, "s1")!, /no grant/);
    w.busy.add(`${STATION}/s2`);
    await w.pass(600_000);
    await w.pass(600_000);
    assert.equal(w.ended.length, 1);
    w.busy.delete(`${STATION}/s2`);
    await w.pass(600_000);
    assert.deepEqual(w.ended.at(-1), { workspace: WS, request: "idle", station: STATION, session: "s2", why: "idle" });
    assert.deepEqual(w.stopped, [`${STATION}/s1`, `${STATION}/s2`]);
    assert.deepEqual(rig.view(WS)!.grants, []);
  } finally {
    await w.close();
  }
});

test("a grant is kept across a restart, taken back by its person's word alone, and given back by its own station", async () => {
  const w = await world();
  try {
    let rig = w.make();
    const signed = w.grant("r1", "s1", { kind: "idle", seconds: 3600 });
    rig.grant(WS, STATION, signed, w.owner.chain);
    rig.grant(WS, STATION, w.grant("r2", "s2", { kind: "idle", seconds: 3600 }), w.owner.chain);
    await rig.close();
    await rig.written();
    rig = w.make();
    assert.equal(rig.refusal(WS, STATION, "s1"), null, "kept with the lock it was checked against");

    assert.equal(rig.release(WS, OTHER, "r2"), false);
    assert.equal(rig.release(WS, STATION, "r2"), true);
    assert.deepEqual(w.ended.at(-1), { workspace: WS, request: "r2", station: STATION, session: "s2", why: "released" });

    const revoke = { v: 1 as const, sub: "pat", ws: WS, rig: RIG, request: "r1", at: w.now() };
    assert.throws(() => rig.revoke(WS, w.owner.says("revoke", revoke, ed())), /not on this rig's person's own lock/);
    assert.equal(rig.refusal(WS, STATION, "s1"), null);
    rig.revoke(WS, w.owner.says("revoke", revoke));
    assert.deepEqual(w.ended.at(-1), { workspace: WS, request: "r1", station: STATION, session: "s1", why: "revoked" });
    assert.match(rig.refusal(WS, STATION, "s1")!, /no grant/);
    assert.throws(() => rig.grant(WS, STATION, signed, w.owner.chain), /taken back/);
  } finally {
    await w.close();
  }
});

test("免批准: on, every chat of the workspace uses the rig; off again, those with no grant lose what they run", async () => {
  const w = await world();
  try {
    const rig = w.make();
    const settings = (seq: number, open: boolean) => w.owner.says("settings", { v: 1 as const, sub: "pat", ws: WS, rig: RIG, seq, open, at: w.now() });
    assert.equal(rig.open(WS), false);
    assert.throws(() => rig.settings(WS, w.owner.says("settings", { v: 1 as const, sub: "pat", ws: WS, rig: RIG, seq: 1, open: true, at: w.now() }, ed()), w.owner.chain), /not on this rig's person's own lock/);
    rig.settings(WS, settings(1, true), w.owner.chain);
    assert.equal(rig.open(WS), true);
    assert.equal(rig.refusal(WS, OTHER, "anyone"), null);
    assert.equal(rig.stationRefusal(WS, OTHER), null);
    assert.match(rig.refusal("other", OTHER, "anyone")!, /another workspace/);
    rig.grant(WS, STATION, w.grant("r1", "s1", { kind: "idle", seconds: 3600 }), w.owner.chain);
    w.busy.add(`${STATION}/s1`);
    w.busy.add(`${OTHER}/free`);
    rig.settings(WS, settings(2, false));
    assert.equal(rig.open(WS), false);
    assert.deepEqual(w.stopped, [`${OTHER}/free`], "the chat with a grant goes on");
    assert.throws(() => rig.settings(WS, settings(1, true)), /older than the settings/);
    assert.equal(rig.open(WS), false);
    assert.match(rig.refusal(WS, OTHER, "free")!, /no grant/);
    assert.equal(rig.refusal(WS, STATION, "s1"), null);
  } finally {
    await w.close();
  }
});

test("what another station may reach of a rig's services (mesh/peer-http.ts `allowed`): a grant of a chat of it or 免批准 lets it, nothing else", async () => {
  const w = await world();
  try {
    const grants = w.make();
    // As rig/module.ts asks its grants, and as rig/main.ts (a rig alone) and mesh.ts (a rig in WS beside whole ones) ask it.
    const side: { current: { stationRefusal(peer: string, workspace: string): string | null } | null } = { current: null };
    const alone = rigAllowed(side);
    const beside = rigAllowed(side, (ws) => ws === WS);
    for (const allowed of [alone, beside]) assert.equal(allowed(STATION, WS), "the rig is starting");
    assert.equal(beside(STATION, "whole"), null, "a whole workspace refuses none of its stations");
    side.current = { stationRefusal: (peer, workspace) => grants.stationRefusal(workspace, peer) };
    for (const allowed of [alone, beside]) {
      assert.equal(allowed(STATION, WS), "no chat of that station has a grant of this one");
      assert.equal(allowed(OTHER, WS), "no chat of that station has a grant of this one");
    }
    grants.grant(WS, STATION, w.grant("r1", "s1", { kind: "idle", seconds: 3600 }), w.owner.chain);
    for (const allowed of [alone, beside]) {
      assert.equal(allowed(STATION, WS), null, "a station with a granted chat is let through");
      assert.equal(allowed(OTHER, WS), "no chat of that station has a grant of this one");
    }
    grants.settings(WS, w.owner.says("settings", { v: 1 as const, sub: "pat", ws: WS, rig: RIG, seq: 1, open: true, at: w.now() }), w.owner.chain);
    for (const allowed of [alone, beside]) assert.equal(allowed(OTHER, WS), null, "免批准 lets every station of the workspace through");
    assert.equal(alone(OTHER, WS2), "this rig is of another workspace");
  } finally {
    await w.close();
  }
});

test("whole again and join: only its person's signature, lately made, is kept for it", async () => {
  const w = await world();
  try {
    const rig = w.make();
    const full = (at: number, by?: Key) => w.owner.says("full", { v: 1 as const, sub: "pat", ws: WS, rig: RIG, at }, by);
    assert.throws(() => rig.full(WS, full(w.now())), /not on this rig's person's own lock/);
    assert.throws(() => rig.full(WS, full(w.now(), ed()), w.owner.chain), /not on this rig's person's own lock/);
    assert.throws(() => rig.full(WS, w.owner.says("full", { v: 1 as const, sub: "mallory", ws: WS, rig: RIG, at: w.now() }), w.owner.chain), /not signed by this rig's person/);
    assert.throws(() => rig.full(WS, full(w.now() - 2 * 3600), w.owner.chain), /signed too long ago/);
    const grant = w.grant("r1", "s1", { kind: "idle", seconds: 3600 });
    assert.throws(() => rig.full(WS, { body: { v: 1, sub: "pat", ws: WS, rig: RIG, at: grant.body.at }, sig: grant.sig }, w.owner.chain), /signature does not hold/);
    assert.equal(rig.full(WS, full(w.now()), w.owner.chain).body.sub, "pat");

    // rig.join signature verification (ws is the TARGET workspace to join, not the current rig workspace; no person field)
    const joinBody = (at: number, targetWs = WS2) => ({ v: 1 as const, sub: "pat", ws: targetWs, rig: RIG, token: "tok-123", at });
    assert.throws(() => rig.join(WS, w.owner.says("join", joinBody(w.now(), WS)), w.owner.chain), /already a rig in that workspace/);
    assert.throws(() => rig.join(WS, w.owner.says("join", joinBody(w.now()), ed()), w.owner.chain), /not on this rig's person's own lock/);
    assert.throws(() => rig.join(WS, w.owner.says("join", joinBody(w.now() - 2 * 3600)), w.owner.chain), /signed too long ago/);
    assert.throws(() => rig.join(WS, { body: joinBody(grant.body.at), sig: grant.sig }, w.owner.chain), /signature does not hold/);
    assert.equal(rig.join(WS, w.owner.says("join", joinBody(w.now())), w.owner.chain).body.token, "tok-123");
  } finally {
    await w.close();
  }
});

test("two rig workspaces stay strictly isolated for grants, open, devices, and clearWorkspace", async () => {
  const w = await world([WS, WS2]);
  try {
    const rig = w.make();
    const cam1 = { id: "0123456789abcdef", name: "cam1", kind: "tcp" as const, target: "192.168.1.20:554" };
    const cam2 = { id: "fedcba9876543210", name: "cam2", kind: "tcp" as const, target: "192.168.1.21:554" };
    rig.settings(WS, w.owner.says("settings", { v: 1 as const, sub: "pat", ws: WS, rig: RIG, seq: 1, open: true, at: w.now() }), w.owner.chain);
    assert.equal(rig.open(WS), true);
    assert.equal(rig.open(WS2), false, "open in WS does not leak to WS2");
    assert.equal(rig.refusal(WS, STATION, "s1"), null);
    assert.match(rig.refusal(WS2, STATION, "s1")!, /no grant/);

    // Grant in WS2 does not grant in WS (once WS open is off), and devices are isolated per workspace.
    rig.device(WS, w.owner.says("device", { v: 1 as const, sub: "pat", ws: WS, rig: RIG, device: cam1, removed: false, at: w.now() }));
    rig.device(WS2, w.owner.says("device", { v: 1 as const, sub: "pat", ws: WS2, rig: RIG, device: cam2, removed: false, at: w.now() }));
    assert.deepEqual(rig.devices(WS).map((d) => d.id), [cam1.id]);
    assert.deepEqual(rig.devices(WS2).map((d) => d.id), [cam2.id]);
    assert.match(rig.deviceRefusal(WS, STATION, "s1", cam2.id)!, /no such device/);

    const g2 = w.grant("r-ws2", "s2", { kind: "fixed", seconds: 600 }, { ws: WS2 });
    rig.grant(WS2, STATION, g2);
    assert.equal(rig.refusal(WS2, STATION, "s2"), null);
    assert.deepEqual(rig.view(WS)!.grants, []);
    assert.deepEqual(rig.view(WS2)!.grants.map((g) => g.request), ["r-ws2"]);

    // Clearing WS removes only WS state; WS2 grants and devices remain untouched.
    rig.clearWorkspace(WS);
    assert.equal(rig.open(WS), false);
    assert.deepEqual(rig.devices(WS), []);
    assert.equal(rig.refusal(WS2, STATION, "s2"), null);
    assert.deepEqual(rig.devices(WS2).map((d) => d.id), [cam2.id]);
  } finally {
    await w.close();
  }
});

test("legacy grants.json and legacy cloud.json migrate cleanly on load", async () => {
  const w = await world([WS]);
  try {
    const cam = { id: "0123456789abcdef", name: "cam", kind: "tcp" as const, target: "192.168.1.20:554" };
    const signedSettings = w.owner.says("settings", { v: 1 as const, sub: "pat", ws: WS, rig: RIG, seq: 1, open: true, at: w.now() });
    const signedDevice = w.owner.says("device", { v: 1 as const, sub: "pat", ws: WS, rig: RIG, device: cam, removed: false, at: w.now() });
    const signedGrant = w.grant("legacy-g", "s1", { kind: "fixed", seconds: 600 });
    writeFileSync(join(w.dir, "grants.json"), JSON.stringify({
      chain: w.owner.chain,
      settings: signedSettings,
      add: null,
      grants: { "legacy-g": { signed: signedGrant, usedAt: w.now() * 1000 } },
      revoked: {},
      devices: { [cam.id]: signedDevice },
      deviceSettings: {},
    }));
    const rig = w.make([WS]);
    assert.equal(rig.open(WS), true);
    assert.deepEqual(rig.devices(WS).map((d) => d.id), [cam.id]);
    assert.deepEqual(rig.view(WS)!.grants.map((g) => g.request), ["legacy-g"]);
  } finally {
    await w.close();
  }

  // Legacy cloud.json fields (single rig_pending, boolean rig_due, single full_pending) normalize to per-ws shapes.
  const data = mkdtempSync(join(tmpdir(), "rig-legacy-cloud-"));
  try {
    const now = Math.floor(Date.now() / 1000);
    mkdirSync(join(data, "mesh"), { recursive: true });
    writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({
      origin: "https://app.still.fail",
      station: STATION,
      workspace: WS,
      workspace_name: "Home",
      name: "nas",
      peers: [],
      rig_pending: { owner: "pat", owner_email: "pat@example.com", owner_name: "Pat", person: "ee".repeat(32), at: now },
      rig_due: true,
      full_pending: { at: now },
    }));
    const read = readState(data)!;
    assert.deepEqual(read.rig_due, [WS]);
    assert.equal(read.rig_pending?.[WS]?.owner, "pat");
    assert.equal(read.full_pending?.[WS]?.at, now);
  } finally {
    rmSync(data, { recursive: true, force: true });
  }
});

test("what a machine is changes only by what was asked of it and the control plane listing it so, never by either alone", async () => {
  const data = mkdtempSync(join(tmpdir(), "rig-mode-"));
  const now = Math.floor(Date.now() / 1000);
  const base = { origin: "https://app.still.fail", station: STATION, workspace: WS, workspace_name: "Home", name: "nas", peers: [] };
  const frame = (more: object) => JSON.stringify({ type: "state", workspace: WS, workspace_name: "Home", name: "nas", peers: [{ id: OTHER, name: "willow" }], ...more });
  const pat = { owner: "pat", owner_email: "pat@example.com", owner_name: "Pat", person: "ee".repeat(32) };
  try {
    writeState(data, base as any);
    let s = new Cloud(data, false);
    applyState(s, frame({ rig: { owner: "pat" } }));
    assert.equal(readState(data)!.rig, undefined);
    assert.equal(readState(data)!.rig_due, undefined);

    // Asked by a member's device (per-ws rig_pending), then listed as theirs: due to become one. Listed as another's: not.
    s.update((st) => void (st.rig_pending = { [WS]: { ...pat, at: now } }));
    applyState(s, frame({ rig: { owner: "mallory" } }));
    assert.equal(readState(data)!.rig_due, undefined);
    // Works in multi-workspace too: switching WS to rig while WS2 stays full!
    applyState(s, frame({ rig: { owner: "pat" }, workspaces: [{ workspace: WS2, workspace_name: "Other", name: "nas", peers: [] }] }));
    assert.deepEqual(readState(data)!.rig_due, [WS]);
    assert.equal(readState(data)!.rig, undefined, "it stops what it runs as a station first (sessions/agents.ts)");

    // What was asked too long ago is forgotten.
    s.update((st) => {
      delete st.rig_due;
      st.rig_pending = { [WS]: { ...pat, at: now - MODE_PENDING_S - 60 } };
    });
    applyState(s, frame({ rig: { owner: "pat" } }));
    assert.deepEqual([readState(data)!.rig_due, readState(data)!.rig_pending], [undefined, undefined]);
    s.close();

    // A rig: the plane listing it as a whole station changes nothing by itself.
    const { at: _, ...self } = { ...pat, at: 0 };
    writeState(data, { ...base, rig: self } as any);
    mkdirSync(join(data, "rig"), { recursive: true });
    writeFileSync(rigGrantsPath(data), "{}");
    s = new Cloud(data, false);
    applyState(s, frame({}));
    assert.deepEqual(readState(data)!.rig, self);
    s.update((st) => void (st.full_pending = { [WS]: { at: now } }));
    applyState(s, frame({ rig: { owner: "pat" } }));
    assert.deepEqual(readState(data)!.rig, self);
    // rig -> full transition keeps the same frame's rigs list instead of discarding it until the next frame
    const peerRig = { id: "dd".repeat(32), name: "other-rig", owner: "pat", owner_email: "pat@example.com", owner_name: "Pat" };
    applyState(s, frame({ rigs: [peerRig] }));
    assert.equal(readState(data)!.rig, undefined);
    assert.equal(readState(data)!.full_pending, undefined);
    assert.deepEqual(readState(data)!.rigs?.map((r) => r.id), [peerRig.id]);
    await settle();
    assert.equal(existsSync(rigGrantsPath(data)), false);
    s.close();

    // Race protection: a state frame listing a newly joined rig workspace BEFORE cloud.json writes RigSelf
    // must NOT admit it as a full workspace; once cloud.json gets RigSelf, replaySkippedRigFrame restores it with peers.
    writeState(data, base as any);
    s = new Cloud(data, false);
    const rigPeer = { id: STATION, name: "peer-station", ips: ["127.0.0.1:41641"] };
    applyState(s, frame({
      workspaces: [{ workspace: WS2, workspace_name: "RigWS", name: "nas", peers: [rigPeer], rig: { owner: "pat" } }],
    }));
    assert.equal(s.fullMemberships().some((m) => m.workspace === WS2), false, "unwritten rig workspace must never appear as full");
    assert.equal(s.state!.joined?.some((j) => j.workspace === WS2) ?? false, false, "skipped until local RigSelf exists");
    // Now local join finishes and writes RigSelf for WS2
    s.update((st) => {
      st.joined = [{ workspace: WS2, workspace_name: "RigWS", name: "nas", peers: [], revocations: [], rig: self }];
    });
    assert.equal(replaySkippedRigFrame(s), true);
    assert.equal(s.rigMemberships().some((m) => m.workspace === WS2), true);
    assert.deepEqual(s.membership(WS2)?.peers.map((p) => p.id), [STATION]);
    assert.equal(s.fullMemberships().some((m) => m.workspace === WS2), false);
    s.close();
  } finally {
    rmSync(data, { recursive: true, force: true });
  }
});

test("a device on the rig: attached and taken off only by what its person signed; a chat reaches it by a grant of it or of the rig, or 免批准", async () => {
  const w = await world();
  try {
    const rig = w.make();
    const cam = { id: "0123456789abcdef", name: "cam", kind: "tcp" as const, target: "192.168.1.20:554" };
    const attach = (removed = false, at = w.now()) => w.owner.says("device", { v: 1, sub: "pat", ws: WS, rig: RIG, device: cam, removed, at });
    rig.takeChain(WS, w.owner.chain);
    assert.match(rig.deviceRefusal(WS, STATION, "s1", cam.id)!, /no such device/);
    const stranger = person("pat");
    assert.throws(() => rig.device(WS, stranger.says("device", { v: 1, sub: "pat", ws: WS, rig: RIG, device: cam, removed: false, at: w.now() })), /not on this rig's person's own lock/);
    rig.device(WS, attach());
    assert.deepEqual(rig.devices(WS).map((d) => d.name), ["cam"]);
    assert.equal(rig.view(WS)!.devices[0]!.open, false);
    assert.match(rig.deviceRefusal(WS, STATION, "s1", cam.id)!, /no grant of this device: ask for one with device_use/);
    rig.grant(WS, STATION, w.grant("d1", "s1", { kind: "fixed", seconds: 600 }, { device: cam.id }));
    assert.equal(rig.deviceRefusal(WS, STATION, "s1", cam.id), null);
    assert.match(rig.refusal(WS, STATION, "s1")!, /no grant of this station/);
    assert.match(rig.stationRefusal(WS, STATION)!, /no chat of that station has a grant/);
    rig.grant(WS, STATION, w.grant("r2", "s2", { kind: "fixed", seconds: 600 }));
    assert.equal(rig.deviceRefusal(WS, STATION, "s2", cam.id), null);
    assert.throws(() => rig.grant(WS, STATION, w.grant("d9", "s3", { kind: "fixed", seconds: 600 }, { device: "fedcba9876543210" })), /no such device/);
    const settings = (seq: number, open: boolean) => w.owner.says("settings", { v: 1 as const, sub: "pat", ws: WS, rig: RIG, seq, open, at: w.now(), device: cam.id });
    rig.settings(WS, settings(1, true));
    assert.equal(rig.deviceRefusal(WS, STATION, "s3", cam.id), null);
    assert.equal(rig.refusal(WS, STATION, "s3") !== null, true);
    rig.settings(WS, settings(2, false));
    assert.deepEqual(w.cuts, [`${cam.id}:*/*`]);
    assert.throws(() => rig.settings(WS, settings(1, true)), /older than the settings this device has/);
    await w.pass(601_000);
    rig.view(WS);
    assert.ok(w.cuts.includes(`${cam.id}:${STATION}/s1`));
    rig.grant(WS, STATION, w.grant("d2", "s4", { kind: "fixed", seconds: 600 }, { device: cam.id }));
    rig.device(WS, attach(true));
    assert.deepEqual(rig.devices(WS), []);
    assert.ok(w.ended.some((e) => e.request === "d2" && e.why === "removed" && e.device === cam.id));
    rig.device(WS, attach(false, w.now() + 1));
    await rig.written();
    assert.deepEqual(w.make().devices(WS).map((d) => d.id), [cam.id]);
  } finally {
    await w.close();
  }
});
