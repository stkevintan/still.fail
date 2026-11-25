// A workspace's stations keeping each other's copies (replica/copies.ts, peers.ts, places.ts), over a mesh of the test's
// (a request's JSON and the bytes after it, as the station transport carries them; a station away fails it) and on the
// test's clock: a lost station's chats come back complete in a new one, from the stations that keep them; one away a
// month catches up; the stations that keep a copy change without fewer than two holding it; a
// workspace's copies stay with its stations; a station rolled back loses nothing they hold.
import assert from "node:assert/strict";
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { afterEach, test } from "node:test";
import { Effect, Exit, Scope, type Clock } from "effect";
import { TestClock } from "effect/testing";
import { type Fs, direct } from "../src/drive/fs.ts";
import { PeerBus, Refused, bytesOf, withBytes } from "../src/mesh/bus.ts";
import { oneBytes } from "../src/mesh/files.ts";
import { type Line, hearLines } from "../src/ops/log.ts";
import { Fibers } from "../src/ops/fibers.ts";
import { Copies, HANDOVER_QUIET_MS, keptDir } from "../src/replica/copies.ts";
import { type Head, asHead, isHex64 } from "../src/replica/format.ts";
import { keepers } from "../src/replica/peers.ts";
import { FolderPlace, type Place, level, nothingHeld } from "../src/replica/places.ts";
import { readCopy, takeBack } from "./reference/replica-restore.ts";
import { InlineRunner } from "./reference/replica-work.ts";
import { Store } from "../src/store/store.ts";
import { HOME, OTHER, chat, dataDir, rowsOf, station } from "./replica-fakes.ts";

type Json = any;
const scopes: Scope.Closeable[] = [];
const closing: (() => Promise<void>)[] = [];
afterEach(async () => {
  for (const c of closing.splice(0).reverse()) await c().catch(() => {});
  for (const s of scopes.splice(0)) await Effect.runPromise(Scope.close(s, Exit.void));
});

function testClock(): Clock.Clock & { move: (ms: number) => Promise<void> } {
  const scope = Effect.runSync(Scope.make());
  scopes.push(scope);
  const clock = Effect.runSync(Scope.provide(TestClock.make(), scope));
  return Object.assign(clock, { move: (ms: number) => Effect.runPromise(clock.adjust(`${ms} millis`)) });
}

/// What crosses the mesh: its JSON as a copy, the bytes after it as they are.
function across(v: Json): Json {
  const bytes = bytesOf(v);
  const copy = JSON.parse(JSON.stringify(v));
  return bytes === null ? copy : withBytes(copy, bytes);
}

type Node = { id: string; data: string; store: Store; copies: Copies; up: boolean; workspaces: string[]; bus: PeerBus };

/// A workspace's stations on the test's mesh, each in the workspaces it says; its roster is `roster` as it is now.
class Mesh {
  readonly nodes = new Map<string, Node>();
  readonly rosters = new Map<string, string[]>();
  readonly clock = testClock();
  asks = 0;
  /// The requests each station was asked, by method (and kind, for `replica.put`).
  readonly asked = new Map<string, Map<string, number>>();
  /// Stations from before copies: they refuse every `replica.*` as an old station's default handler does.
  readonly old = new Set<string>();

  add(id: string, workspaces: string[], made?: { data: string; store: Store }): Node {
    const data = made?.data ?? dataDir(id.slice(0, 4));
    const store = made?.store ?? Store.open(join(data, "stillfail.db"), join(data, "archive"));
    const bus = new PeerBus({ sleep: async () => {} });
    const fibers = new Fibers("copies", this.clock);
    const node = { id, data, store, up: true, workspaces, bus } as Node;
    bus.attach(async (to, ws, request) => {
      this.asks++;
      let m = this.asked.get(to);
      if (m === undefined) this.asked.set(to, (m = new Map()));
      const what = request?.method === "replica.put" ? `put:${request.kind}` : String(request?.method);
      m.set(what, (m.get(what) ?? 0) + 1);
      const there = this.nodes.get(to);
      if (there === undefined || !there.up || !node.up) throw new Error("station unreachable");
      if (ws !== null && (!there.workspaces.includes(ws) || !(this.rosters.get(ws) ?? []).includes(id))) throw new Error("peer is not another station in this workspace");
      if (this.old.has(to)) throw new Refused("session and task key are required (at most 256 / 128 bytes)");
      return across(await there.bus.handle(ws ?? "", id, across(request)));
    });
    const runner = new InlineRunner({ db: join(data, "stillfail.db"), replica: join(data, "replica"), dataDir: data, origin: id, now: () => this.clock.currentTimeMillisUnsafe() });
    node.copies = new Copies({
      data,
      here: () => id,
      places: () => ({ home: node.workspaces[0] ?? null, workspaces: node.workspaces.map((w) => ({ workspace: w, name: `${id.slice(0, 4)} in ${w}` })) }),
      roster: (ws) => (this.rosters.get(ws) ?? []).map((s) => ({ id: s, name: s.slice(0, 4) })),
      ask: (s, r) => bus.ask(s, r),
      runner,
      fibers,
      changed: () => {},
      restart: async () => null,
    });
    (node as Json).runner = runner;
    bus.on("replica.", node.copies.answers());
    store.subscribe((c) => node.copies.told(c));
    this.nodes.set(id, node);
    closing.push(async () => {
      await node.copies.close();
      await runner.close();
      await fibers.close();
      try { store.close(); } catch {}
    });
    return node;
  }

  /// Every station's export and places brought to rest.
  async settle(): Promise<void> {
    for (let i = 0; i < 3; i++) for (const n of this.nodes.values()) if (n.up) await n.copies.settle();
  }
}

const id = (c: string) => c.repeat(64);

/// The stations that hold `origin`'s copy in `ws` (a head there), of `among`.
function holders(mesh: Mesh, ws: string, origin: string): string[] {
  return [...mesh.nodes.values()].filter((n) => existsSync(join(keptDir(n.data), ws, origin)) && readdirSync(join(keptDir(n.data), ws, origin)).some((g) => existsSync(join(keptDir(n.data), ws, origin, g, "head.json")))).map((n) => n.id);
}

/// `node` started again after its restore was brought: what it brought put in before its store opens.
function startAgain(node: Node): DatabaseSync {
  node.store.close();
  const ready = takeBack(node.data, join(node.data, "stillfail.db"), 0);
  assert.ok(ready !== null, "a restore was waiting");
  return new DatabaseSync(join(node.data, "stillfail.db"));
}

/// Every row that must survive of `ws`'s chats on `before` equals what `after` holds now, paths moved.
function same(before: DatabaseSync, beforeData: string, after: DatabaseSync, afterData: string, ws: string | null) {
  const want = rowsOf(before, ws, beforeData, afterData);
  const got = rowsOf(after, ws);
  for (const table of Object.keys(want)) assert.deepEqual([...got[table]!.entries()].sort(), [...want[table]!.entries()].sort(), `${table} as it was`);
  assert.ok(want.entries!.size > 30, "it had messages");
}

test("a lost station's chats come back complete in a new station, from the stations that keep them", async () => {
  const mesh = new Mesh();
  const [A, B, C, D] = [id("a"), id("b"), id("c"), id("d")];
  mesh.rosters.set(HOME, [A, B, C]);
  const made = station();
  const a = mesh.add(A, [HOME], made);
  mesh.add(B, [HOME]);
  mesh.add(C, [HOME]);
  for (const n of mesh.nodes.values()) await n.copies.start();
  await mesh.settle();
  // deleted after it was copied: deleted in the copies too
  made.store.deleteSession(made.deleted);
  await mesh.settle();
  assert.deepEqual(holders(mesh, HOME, A).sort(), keepers(HOME, A, [A, B, C]).sort());
  assert.deepEqual(holders(mesh, HOME, A).sort(), [B, C]);
  // a new station while A is there: A's backup is not offered (A answers; its chats are its own)
  mesh.rosters.set(HOME, [A, B, C, D]);
  const d = mesh.add(D, [HOME]);
  await d.copies.start();
  await mesh.settle();
  await mesh.clock.move(60_000);
  await mesh.settle();
  assert.equal(((await d.copies.restorable(HOME)) as Json[]).some((o) => o.station === A), false, "a station that is there is not offered");
  // A is lost
  a.up = false;
  const before = new DatabaseSync(made.db);
  const offered = (await d.copies.restorable(HOME)) as Json[];
  const of = offered.find((o) => o.station === A);
  assert.ok(of, "the lost station's copy is offered");
  assert.equal(of.chats, 2);
  // (D came: it is one of the two that keep A's copy now, the one it took the place of gave it up)
  assert.deepEqual(of.from.map((f: Json) => f.station).sort(), keepers(HOME, A, [A, B, C, D]).sort());
  await d.copies.restore(HOME, A, of.gen, { station: of.from.find((f: Json) => f.station !== D).station });
  const after = startAgain(d);
  same(before, made.data, after, d.data, null);
  // its file, as it was, where its message says
  const path = (JSON.parse((after.prepare("SELECT attachments FROM entries WHERE ts = 'a.pic'").get() as { attachments: string }).attachments) as { path: string }[])[0]!.path;
  assert.ok(path.startsWith(d.data));
  assert.equal(readFileSync(path, "utf8"), "a picture");
  // the deleted chat stays deleted; the archived one is there, archived
  assert.equal(after.prepare("SELECT COUNT(*) AS n FROM sessions WHERE key = 'chat:gone'").get()!.n, 0);
  assert.equal(JSON.stringify(after.prepare("SELECT text FROM entries").all()).includes("chat:gone"), false);
  assert.notEqual((after.prepare("SELECT archived_at FROM sessions WHERE key = 'chat:b'").get() as Json).archived_at, null);
  // the other workspace's chat was not in this one's copy
  assert.equal(after.prepare("SELECT COUNT(*) AS n FROM sessions WHERE key = 'chat:o'").get()!.n, 0);
  after.close();
  before.close();
});

test("a station away for a month catches up when it is back, told by nobody but its coming back", async () => {
  const mesh = new Mesh();
  const [A, B, C] = [id("a"), id("b"), id("c")];
  mesh.rosters.set(HOME, [A, B, C]);
  const made = station();
  const a = mesh.add(A, [HOME], made);
  const b = mesh.add(B, [HOME]);
  mesh.add(C, [HOME]);
  for (const n of mesh.nodes.values()) await n.copies.start();
  await mesh.settle();
  b.up = false;
  const thread = made.store.sessionThreads("chat:a")[0]!.thread.id;
  const day = 86_400_000;
  for (let i = 0; i < 30; i++) {
    made.store.insertMessage({ thread, ts: `day.${i}`, authorKind: "person", author: "p@x", text: `day ${i}` });
    await a.copies.settle();
    await mesh.clock.move(day);
  }
  const head = ((await a.copies.overview(HOME)) as Json);
  const was = mesh.asks;
  // a month of tries backing off: a few a day at most, none at all once it is back
  await mesh.clock.move(day);
  assert.ok(mesh.asks - was <= 24 * 6 + 10, `${mesh.asks - was} asks a day while it was away`);
  b.up = true;
  await b.copies.start();
  await mesh.settle();
  const keptB = new FolderPlace(keptDir(b.data));
  const held = await keptB.held(HOME, A);
  assert.equal(held.gens.at(-1)!.head!.to, head.to, "it holds as much as A has");
  const { folded } = readCopy(join(keptDir(b.data), HOME, A, held.gens.at(-1)!.gen));
  assert.ok(folded.table("entries").some((r) => r.text === "day 29"));
});

test("the stations that keep a copy change as stations come, and never fewer than two hold it meanwhile", async () => {
  const mesh = new Mesh();
  const A = id("a");
  const others = ["b", "c", "d", "e", "f", "1", "2", "3", "4", "5"].map(id);
  // a fourth station that takes one of the first three's place as A's keeper
  const first = [others[0]!, others[1]!, others[2]!];
  const newcomer = others.slice(3).find((s) => keepers(HOME, A, [A, ...first, s]).includes(s))!;
  assert.ok(newcomer);
  mesh.rosters.set(HOME, [A, ...first]);
  mesh.add(A, [HOME], station());
  for (const s of first) mesh.add(s, [HOME]);
  for (const n of mesh.nodes.values()) await n.copies.start();
  await mesh.settle();
  const was = holders(mesh, HOME, A);
  assert.equal(was.length, 2);
  // the newcomer joins but is not reached yet: the one it displaces keeps its copy
  mesh.rosters.set(HOME, [A, ...first, newcomer]);
  const n = mesh.add(newcomer, [HOME]);
  n.up = false;
  for (const x of mesh.nodes.values()) if (x.up) await x.copies.placesChanged();
  await mesh.settle();
  assert.ok(holders(mesh, HOME, A).length >= 2, "two hold it while the newcomer is away");
  assert.deepEqual(holders(mesh, HOME, A).sort(), was.sort());
  // it is reached: it is given the copy, then the one it displaced lets its own go
  n.up = true;
  await n.copies.start();
  await mesh.settle();
  await mesh.clock.move(60_000);
  await mesh.settle();
  assert.deepEqual(holders(mesh, HOME, A).sort(), keepers(HOME, A, [A, ...first, newcomer]).sort());
});

test("a workspace's copies are kept only by its own stations, and a station that leaves one keeps nothing of it", async () => {
  const mesh = new Mesh();
  const [S, P, Q] = [id("a"), id("b"), id("c")];
  mesh.rosters.set(HOME, [S, P]);
  mesh.rosters.set(OTHER, [S, Q]);
  const made = station();
  const s = mesh.add(S, [HOME, OTHER], made);
  const p = mesh.add(P, [HOME]);
  const q = mesh.add(Q, [OTHER]);
  // P keeps a chat of its own in the home workspace: S keeps P's copy
  chat(p.store, p.data, "chat:p", null, 3);
  for (const n of mesh.nodes.values()) await n.copies.start();
  await mesh.settle();
  const inP = await new FolderPlace(keptDir(p.data)).origins(OTHER);
  assert.equal(inP.length, 0, "P keeps nothing of the other workspace");
  const keptP = (await new FolderPlace(keptDir(p.data)).origins(HOME)).find((o) => o.origin === S)!;
  const { folded: atP } = readCopy(join(keptDir(p.data), HOME, S, keptP.heads.at(-1)!.gen));
  assert.equal(atP.table("sessions").some((r) => r.key === "chat:o"), false);
  const keptQ = (await new FolderPlace(keptDir(q.data)).origins(OTHER)).find((o) => o.origin === S)!;
  const { folded: atQ } = readCopy(join(keptDir(q.data), OTHER, S, keptQ.heads.at(-1)!.gen));
  assert.deepEqual(atQ.table("sessions").map((r) => r.key), ["chat:o"]);
  assert.equal(JSON.stringify(atQ.table("entries")).includes("chat:a says"), false);
  assert.equal((await new FolderPlace(keptDir(q.data)).origins(HOME)).length, 0);
  // S leaves the home workspace: nothing of it stays on S
  assert.ok(existsSync(join(keptDir(s.data), HOME, P)));
  s.workspaces = [OTHER];
  await s.copies.placesChanged();
  assert.equal(existsSync(join(keptDir(s.data), HOME)), false);
  assert.equal(existsSync(join(s.data, "replica", "own", HOME)), false);
  // and P asked by a station not of the workspace refuses
  await assert.rejects(q.bus.ask(P, { method: "replica.list", workspace: HOME }));
});

test("a station rolled back to an older copy of its data loses nothing the others hold: a new generation beside it", async () => {
  const mesh = new Mesh();
  const [A, B, C] = [id("a"), id("b"), id("c")];
  mesh.rosters.set(HOME, [A, B, C]);
  const made = station();
  const a = mesh.add(A, [HOME], made);
  mesh.add(B, [HOME]);
  mesh.add(C, [HOME]);
  for (const n of mesh.nodes.values()) await n.copies.start();
  await mesh.settle();
  // its data as a backup keeps it
  const backup = dataDir("backup");
  rmSync(backup, { recursive: true, force: true });
  made.store.db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
  cpSync(made.data, backup, { recursive: true });
  const thread = made.store.sessionThreads("chat:a")[0]!.thread.id;
  made.store.insertMessage({ thread, ts: "after.backup", authorKind: "person", author: "p@x", text: "said after the backup" });
  await mesh.settle();
  const held = await new FolderPlace(keptDir(mesh.nodes.get(B)!.data)).held(HOME, A);
  const genBefore = held.gens.at(-1)!;
  // the backup put back, the station started again
  await a.copies.close();
  a.up = false;
  a.store.close();
  rmSync(made.data, { recursive: true, force: true });
  cpSync(backup, made.data, { recursive: true });
  mesh.nodes.delete(A);
  const again = mesh.add(A, [HOME], { data: made.data, store: Store.open(made.db, join(made.data, "archive")) });
  again.store.insertMessage({ thread, ts: "after.restore", authorKind: "person", author: "p@x", text: "said after it was put back" });
  await again.copies.start();
  await mesh.settle();
  for (const keeper of [B, C]) {
    const gens = (await new FolderPlace(keptDir(mesh.nodes.get(keeper)!.data)).held(HOME, A)).gens;
    assert.equal(gens.length, 2, "both generations kept");
    const old = gens.find((g) => g.gen === genBefore.gen)!;
    assert.equal(old.head!.to, genBefore.head!.to, "the older generation as it was");
    const { folded: lost } = readCopy(join(keptDir(mesh.nodes.get(keeper)!.data), HOME, A, old.gen));
    assert.ok(lost.table("entries").some((r) => r.text === "said after the backup"), "what the backup lacks is still held");
    const { folded: now } = readCopy(join(keptDir(mesh.nodes.get(keeper)!.data), HOME, A, gens.find((g) => g.gen !== genBefore.gen)!.gen));
    assert.ok(now.table("entries").some((r) => r.text === "said after it was put back"));
  }
});

test("a copy whose writer stopped between a batch and its head is the copy as its head says, and the next batch goes on from it", async () => {
  const mesh = new Mesh();
  const [A, B, D] = [id("a"), id("b"), id("d")];
  mesh.rosters.set(HOME, [A, B]);
  const made = station();
  const a = mesh.add(A, [HOME], made);
  const b = mesh.add(B, [HOME]);
  for (const n of mesh.nodes.values()) await n.copies.start();
  await mesh.settle();
  const place = new FolderPlace(keptDir(b.data));
  const gen = (await place.held(HOME, A)).gens[0]!;
  // a batch put there whole, then the writer stopped before the head (and half of another, left as it was)
  const stray = "9999999990-9999999990-deadbeef.ndjson.zst";
  mkdirSync(join(place.dir(HOME, A), gen.gen, "log"), { recursive: true });
  await place.put(HOME, A, gen.gen, "batch", stray, Buffer.from("not a whole batch"));
  const before = new DatabaseSync(made.db);
  a.up = false;
  mesh.rosters.set(HOME, [A, B, D]);
  const d = mesh.add(D, [HOME]);
  await d.copies.start();
  const of = ((await d.copies.restorable(HOME)) as Json[]).find((o) => o.station === A)!;
  await d.copies.restore(HOME, A, of.gen, { station: B });
  const after = startAgain(d);
  same(before, made.data, after, d.data, null);
  after.close();
  before.close();
  // the writer back (started again): what it writes next goes on from the head, and the stray batch goes
  a.up = true;
  mesh.rosters.set(HOME, [A, B]);
  await a.copies.start();
  const thread = made.store.sessionThreads("chat:a")[0]!.thread.id;
  made.store.insertMessage({ thread, ts: "on", authorKind: "person", author: "p@x", text: "goes on" });
  await a.copies.settle();
  const now = (await place.held(HOME, A)).gens[0]!;
  assert.equal(now.batches.includes(stray), false);
  assert.ok(now.head!.to > gen.head!.to);
});

test("a keeper is sent each new batch and head alone: what it holds is asked only as the station starts", async () => {
  const mesh = new Mesh();
  const [A, B] = [id("a"), id("b")];
  mesh.rosters.set(HOME, [A, B]);
  const made = station();
  const a = mesh.add(A, [HOME], made);
  mesh.add(B, [HOME]);
  for (const n of mesh.nodes.values()) await n.copies.start();
  await mesh.settle();
  const before = new Map(mesh.asked.get(B));
  const thread = made.store.sessionThreads("chat:a")[0]!.thread.id;
  const N = 12;
  for (let i = 0; i < N; i++) {
    made.store.insertMessage({ thread, ts: `n.${i}`, authorKind: "person", author: "p@x", text: `message ${i}` });
    await a.copies.settle();
  }
  // a pass with nothing new levels nothing
  await a.copies.settle();
  const after = mesh.asked.get(B)!;
  const delta = (k: string) => (after.get(k) ?? 0) - (before.get(k) ?? 0);
  assert.equal(delta("replica.held"), 0, "no listing asked of it");
  assert.equal(delta("put:head"), N, "a head a pass");
  // (a batch a pass, and those small batches folded into one now and then)
  assert.ok(delta("put:batch") >= N && delta("put:batch") <= N + Math.ceil(N / 3), `${delta("put:batch")} batches sent`);
  const { folded } = readCopy(join(keptDir(mesh.nodes.get(B)!.data), HOME, A, (await new FolderPlace(keptDir(mesh.nodes.get(B)!.data)).held(HOME, A)).gens[0]!.gen));
  assert.ok(folded.table("entries").some((r) => r.text === `message ${N - 1}`));
});

test("while a keeper is not reached, the next station holds the copy; once it is back, it is given the copy and the next lets its own go", async () => {
  const mesh = new Mesh();
  const A = id("a");
  const others = ["b", "c", "d"].map(id);
  mesh.rosters.set(HOME, [A, ...others]);
  const a = mesh.add(A, [HOME], station());
  for (const s of others) mesh.add(s, [HOME]);
  const [first, second] = keepers(HOME, A, [A, ...others]);
  const third = others.find((s) => s !== first && s !== second)!;
  const down = mesh.nodes.get(first!)!;
  down.up = false;
  for (const n of mesh.nodes.values()) if (n.up) await n.copies.start();
  await mesh.settle();
  await mesh.clock.move(60_000);
  await mesh.settle();
  assert.deepEqual(holders(mesh, HOME, A).sort(), [second!, third].sort(), "the next one holds it while the first is away");
  const o = (await a.copies.overview(HOME)) as Json;
  const away = o.keepers.find((k: Json) => k.station === first);
  assert.equal(away.reason, "offline");
  assert.equal(o.keepers.find((k: Json) => k.station === third).error, null, "the next one is among those said to hold it");
  // the first back: it is brought the copy, the third hands over and lets its own go
  down.up = true;
  await down.copies.start();
  await mesh.settle();
  await mesh.clock.move(60_000);
  await mesh.settle();
  assert.deepEqual(holders(mesh, HOME, A).sort(), [first!, second!].sort());
});

test("a keeper from before copies is said old, warned of and asked nothing again until it says it is up; the next station holds the copy meanwhile", async () => {
  const mesh = new Mesh();
  const A = id("a");
  const others = ["b", "c", "d"].map(id);
  mesh.rosters.set(HOME, [A, ...others]);
  const a = mesh.add(A, [HOME], station());
  for (const s of others) mesh.add(s, [HOME]);
  const [first, second] = keepers(HOME, A, [A, ...others]);
  const third = others.find((s) => s !== first && s !== second)!;
  mesh.old.add(first!);
  const lines: Line[] = [];
  hearLines((l) => lines.push(l));
  try {
    for (const n of mesh.nodes.values()) if (n.id !== first) await n.copies.start();
    await mesh.settle();
    await mesh.clock.move(60_000);
    await mesh.settle();
    assert.deepEqual(holders(mesh, HOME, A).sort(), [second!, third].sort(), "the next one holds it in the old one's place");
    const o = (await a.copies.overview(HOME)) as Json;
    const old = o.keepers.find((k: Json) => k.station === first);
    assert.equal(old.reason, "old");
    assert.match(old.error, /are required/);
    assert.equal(o.keepers.find((k: Json) => k.station === third).error, null);
    const asked = () => [...(mesh.asked.get(first!) ?? new Map()).values()].reduce((x, y) => x + y, 0);
    const before = asked();
    // a pass, and an hour on the clock: nothing asked of it again
    const thread = a.store.sessionThreads("chat:a")[0]!.thread.id;
    a.store.insertMessage({ thread, ts: "old.1", authorKind: "person", author: "p@x", text: "while it is old" });
    for (let i = 0; i < 6; i++) {
      await mesh.clock.move(10 * 60_000);
      await mesh.settle();
    }
    assert.equal(asked(), before, "no retry of a station from before copies");
    assert.deepEqual(lines.filter((l) => l.message === "a place not brought level" && l.fields.place === first), [], "no warning of it");
    // updated, it says it is up: brought level at once, and the third lets its own go
    mesh.old.delete(first!);
    await mesh.nodes.get(first!)!.copies.start();
    await mesh.settle();
    await mesh.clock.move(60_000);
    await mesh.settle();
    assert.deepEqual(holders(mesh, HOME, A).sort(), [first!, second!].sort());
    assert.equal(((await a.copies.overview(HOME)) as Json).keepers.find((k: Json) => k.station === first).error, null);
  } finally {
    hearLines(null);
  }
});

test("the export failing is said in the settings, and tried again with a backoff until it goes", async () => {
  const mesh = new Mesh();
  const A = id("a");
  mesh.rosters.set(HOME, [A]);
  const a = mesh.add(A, [HOME], station());
  await a.copies.start();
  await mesh.settle();
  // its thread ends: every pass fails until it is started again
  const fail = { on: true };
  const real = (a as Json).runner as InlineRunner;
  const pass = real.pass.bind(real);
  real.pass = (told) => (fail.on ? Promise.reject(new Error("the copies' thread ended (1)")) : pass(told));
  const thread = a.store.sessionThreads("chat:a")[0]!.thread.id;
  a.store.insertMessage({ thread, ts: "x", authorKind: "person", author: "p@x", text: "while it is down" });
  await a.copies.settle();
  const o = (await a.copies.overview(HOME)) as Json;
  assert.match(o.stopped.error, /thread ended/);
  const tries = o.stopped.tries;
  await mesh.clock.move(4_000);
  assert.equal(((await a.copies.overview(HOME)) as Json).stopped.tries, tries, "not again before its backoff");
  fail.on = false;
  await mesh.clock.move(60_000);
  await a.copies.settle();
  assert.equal(((await a.copies.overview(HOME)) as Json).stopped, null);
});

function deferred<T = void>() {
  let resolve!: (v: T | PromiseLike<T>) => void;
  const promise = new Promise<T>((r) => { resolve = r; });
  return { promise, resolve };
}

test("a batch compacted away while an export pass is in flight: Copies waits for #passing and retries with the newer head without warning", async () => {
  const mesh = new Mesh();
  const [A, B] = [id("a"), id("b")];
  mesh.rosters.set(HOME, [A, B]);
  const made = station();
  const a = mesh.add(A, [HOME], made);
  const b = mesh.add(B, [HOME]);

  // Intercept B's first replica.held so A's initial #level pauses while holding head1 (keeping.error is null).
  const heldReached = deferred<void>();
  const heldGate = deferred<void>();
  const origHandle = b.bus.handle.bind(b.bus);
  let interceptHeld = true;
  b.bus.handle = async (ws, peer, req) => {
    if (interceptHeld && req?.method === "replica.held") {
      interceptHeld = false;
      heldReached.resolve();
      await heldGate.promise;
    }
    return origHandle(ws, peer, req);
  };

  // Wrap A's runner.pass: on the second pass, simulate compaction replacing b1 with b1New before #passing finishes.
  const real = (a as Json).runner as InlineRunner;
  const realPass = real.pass.bind(real);
  const passStarted = deferred<void>();
  const passGate = deferred<void>();
  let passCount = 0;
  let replacedFrom: string | null = null;
  let replacedTo: string | null = null;
  let replacedLogDir: string | null = null;
  real.pass = async (told) => {
    passCount++;
    const res = await realPass(told);
    const h = res.heads[HOME];
    if (passCount === 2 && h !== undefined && h.batches.length > 0) {
      const b1 = h.batches[0]!;
      const logDir = join(a.data, "replica", "own", HOME, h.gen, "log");
      const b1Path = join(logDir, b1);
      const b1New = b1.replace(/-([0-9a-f]{8})\.ndjson\.zst$/, "-deadbeef.ndjson.zst");
      cpSync(b1Path, join(logDir, b1New));
      rmSync(b1Path);
      replacedFrom = b1;
      replacedTo = b1New;
      replacedLogDir = logDir;
      h.batches = h.batches.map((x) => (x === b1 ? b1New : x));
      passStarted.resolve();
      await passGate.promise;
    } else if (replacedFrom !== null && replacedTo !== null && h !== undefined) {
      h.batches = h.batches.map((x) => (x === replacedFrom ? replacedTo! : x));
    }
    return res;
  };

  const lines: Line[] = [];
  hearLines((l) => lines.push(l));
  try {
    await b.copies.start();
    const aStart = a.copies.start();
    await heldReached.promise;

    // Trigger an in-flight #pass() on A that deletes b1 and holds #passing open on passGate.
    const thread = made.store.sessionThreads("chat:a")[0]!.thread.id;
    made.store.insertMessage({ thread, ts: "race.2", authorKind: "person", author: "p@x", text: "during compact" });
    await mesh.clock.move(1_000);
    await passStarted.promise;

    // Release replica.held: A's #level tries own.batch(b1) -> ENOENT -> awaits in-flight #passing.
    heldGate.resolve();
    await readFile(join(replacedLogDir!, replacedFrom!)).catch(() => {});
    passGate.resolve();

    await aStart;
    await mesh.settle();

    assert.deepEqual(
      lines.filter((l) => l.message === "a place not brought level"),
      [],
      "no warning emitted when ENOENT recovers via in-flight #passing",
    );
    const o = (await a.copies.overview(HOME)) as Json;
    assert.equal(o.keepers.find((k: Json) => k.station === B).error, null);
    const keptB = new FolderPlace(keptDir(b.data));
    const heldAfter = await keptB.held(HOME, A);
    const { folded } = readCopy(join(keptDir(b.data), HOME, A, heldAfter.gens.at(-1)!.gen));
    assert.ok(folded.table("entries").some((r) => r.text === "during compact"));
  } finally {
    hearLines(null);
  }
});

test("level treats putFile ENOENT for an ordinary attachment as missing, while rethrowing ENOENT for transcriptFiles chunks", async () => {
  const origin = id("a");
  const fileHash = "1".repeat(64);
  const chunkHash = "2".repeat(64);
  const batch = "0000000001-0000000004-00000000.ndjson.zst";
  const enoent = (path: string) => Object.assign(new Error(`ENOENT: no such file or directory, open '${path}'`), { code: "ENOENT" });

  // Case 1: ordinary attachment disappears between sources() and putFile() -> missing += 1, head still written.
  const putKinds: string[] = [];
  const place1: Place = {
    held: async () => nothingHeld(),
    put: async (_ws, _origin, _gen, kind, name) => { putKinds.push(`${kind}:${name}`); },
    putFile: async (_ws, _origin, _hash, source) => { throw enoent(String(source)); },
    drop: async () => {},
  };
  const head1: Head = {
    v: 1,
    origin,
    workspace: HOME,
    name: "a",
    dataDir: "",
    gen: "lz5x0-0123abcd",
    to: 4,
    made: 40,
    chats: 1,
    messages: 1,
    bytes: 10,
    batches: [batch],
    files: { [fileHash]: 10 },
    runs: [{ run: "r1", from: 1 }],
  };
  const done1 = await level(place1, HOME, {
    head: head1,
    batch: async () => Buffer.from("b"),
    sources: async () => new Map([[fileHash, "/gone/attachment"]]),
  });
  assert.equal(done1.behind, false);
  if (!done1.behind) {
    assert.equal(done1.missing, 1);
    assert.equal(done1.known.files.has(fileHash), false);
  }
  assert.deepEqual(putKinds, [`batch:${batch}`, "head:head.json"]);

  // Case 2: transcriptFiles chunk disappears -> ENOENT still throws so outer levelNewest can retry with a newer head.
  const head2: Head = {
    ...head1,
    files: {},
    transcriptFiles: { [chunkHash]: 10 },
  };
  await assert.rejects(
    level(place1, HOME, {
      head: head2,
      batch: async () => Buffer.from("b"),
      sources: async () => new Map([[chunkHash, "/gone/chunk"]]),
    }),
    (e: unknown) => (e as { code?: unknown } | null)?.code === "ENOENT",
  );
});

test("level puts the chats' head before the transcripts it lacks, partial, and the whole head after them", async () => {
  const origin = id("a");
  const fileHash = "1".repeat(64);
  const t = ["2", "3", "4", "5"].map((c) => c.repeat(64));
  const batch = "0000000001-0000000004-00000000.ndjson.zst";
  const head: Head = {
    v: 1,
    origin,
    workspace: HOME,
    name: "a",
    dataDir: "",
    gen: "lz5x0-0123abcd",
    to: 4,
    made: 40,
    chats: 1,
    messages: 1,
    bytes: 10,
    batches: [batch],
    files: { [fileHash]: 10 },
    transcriptFiles: Object.fromEntries(t.map((h) => [h, 1])),
    runs: [{ run: "r1", from: 1 }],
  };
  const puts: string[] = [];
  const heads: Head[] = [];
  const sent: string[] = [];
  let failAt: string | null = t[2]!;
  let held = { gens: [] as { gen: string; head: Head | null; batches: string[] }[], files: [t[0]!] };
  const place: Place = {
    held: async () => held,
    put: async (_ws, _origin, _gen, kind, name, bytes) => {
      puts.push(`${kind}:${name}`);
      if (kind === "head") heads.push(JSON.parse(Buffer.from(bytes).toString("utf8")) as Head);
    },
    putFile: async (_ws, _origin, hash) => {
      if (hash === failAt) throw new Error("connection lost");
      sent.push(hash);
    },
    drop: async () => {},
  };
  const own = { head, batch: async () => Buffer.from("b"), sources: async (hs: string[]) => new Map(hs.map((h) => [h, `/src/${h}`])) };
  await assert.rejects(level(place, HOME, own), /connection lost/);
  // The chat's file and batch went, then a head naming only the transcripts held, then the sending failed.
  assert.deepEqual(puts, [`batch:${batch}`, "head:head.json"]);
  assert.deepEqual(sent, [fileHash, t[1]]);
  assert.deepEqual(Object.keys(heads[0]!.transcriptFiles!), [t[0]]);
  assert.deepEqual(heads[0]!.files, head.files);
  assert.equal(heads[0]!.to, 4);
  assert.equal(heads[0]!.partial, true);
  // Asked again: the place holds the partial head at the same `to`, so the whole head still goes once all is sent.
  held = { gens: [{ gen: head.gen, head: heads[0]!, batches: [batch] }], files: [t[0]!, fileHash, t[1]!] };
  failAt = null;
  puts.length = 0;
  const done = await level(place, HOME, own);
  assert.equal(done.behind, false);
  if (!done.behind) assert.equal(done.missing, 0);
  assert.deepEqual(puts, ["head:head.json"]);
  assert.deepEqual(heads[1], head);
});

test("concurrent replica.put during handover aborts deletion without ENOENT/ENOTEMPTY and hands over cleanly after quiet window", async () => {
  const mesh = new Mesh();
  const A = id("a");
  const others = ["b", "c", "d"].map(id);
  mesh.rosters.set(HOME, [A, ...others]);
  const a = mesh.add(A, [HOME], station());
  for (const s of others) mesh.add(s, [HOME]);
  const [first, second] = keepers(HOME, A, [A, ...others]);
  const third = others.find((s) => s !== first && s !== second)!;
  const firstNode = mesh.nodes.get(first!)!;
  const thirdNode = mesh.nodes.get(third)!;

  // Start with first offline so A overflows to third.
  firstNode.up = false;
  for (const n of mesh.nodes.values()) if (n.up) await n.copies.start();
  await mesh.settle();
  assert.deepEqual(holders(mesh, HOME, A).sort(), [second!, third].sort());

  // Advance past HANDOVER_QUIET_MS so third is eligible to start handover once first returns.
  await mesh.clock.move(HANDOVER_QUIET_MS + 5_000);
  await mesh.settle();

  // Pause third's handover between `this.kept.held(HOME, A)` and directory removal by intercepting third's
  // `replica.held` call to first during handover.
  const handoverPaused = deferred<void>();
  const handoverRelease = deferred<void>();
  let pausedOnce = false;
  const origFirstHandle = firstNode.bus.handle.bind(firstNode.bus);
  firstNode.bus.handle = async (ws, peer, req) => {
    if (!pausedOnce && peer === third && req?.method === "replica.held" && req?.origin === A) {
      pausedOnce = true;
      handoverPaused.resolve();
      await handoverRelease.promise;
    }
    return origFirstHandle(ws, peer, req);
  };

  const lines: Line[] = [];
  hearLines((l) => lines.push(l));
  try {
    // Bring first back up: first announces itself, A syncs to first, and third begins handing over A's copy.
    firstNode.up = true;
    const startFirst = firstNode.copies.start();
    await handoverPaused.promise;

    // While third's handover is in flight, a new replica.put arrives on third for A.
    const freshHash = "f".repeat(64);
    const freshBody = Buffer.from("written-during-handover");
    await a.bus.ask(third, withBytes({ method: "replica.put", workspace: HOME, origin: A, kind: "file", name: freshHash }, oneBytes(freshBody)));

    // Resume third's handover and let it finish its current pass.
    handoverRelease.resolve();
    await startFirst;
    await mesh.settle();

    // Third MUST NOT have deleted A's directory or the newly written file because writeSeq changed during handover.
    const thirdOriginDir = join(keptDir(thirdNode.data), HOME, A);
    assert.ok(existsSync(thirdOriginDir), "handover aborts deletion when a concurrent write arrives");
    assert.equal(readFileSync(join(thirdOriginDir, "files", freshHash), "utf8"), "written-during-handover");

    // Still within HANDOVER_QUIET_MS: triggering handover again keeps the directory intact.
    await mesh.clock.move(5_000);
    await mesh.settle();
    assert.ok(existsSync(thirdOriginDir), "handover respects HANDOVER_QUIET_MS quiet window");

    // Once writes stop and clock advances past HANDOVER_QUIET_MS, handover completes cleanly and copies freshHash.
    await mesh.clock.move(HANDOVER_QUIET_MS + 10_000);
    await mesh.settle();

    assert.equal(existsSync(thirdOriginDir), false, "source directory removed after quiet window");
    const wsEntries = existsSync(join(keptDir(thirdNode.data), HOME)) ? readdirSync(join(keptDir(thirdNode.data), HOME)) : [];
    assert.deepEqual(wsEntries.filter((e) => e.startsWith(".dropping-")), [], "no leftover .dropping-* directories");
    assert.deepEqual(holders(mesh, HOME, A).sort(), [first!, second!].sort());
    assert.equal(readFileSync(join(keptDir(firstNode.data), HOME, A, "files", freshHash), "utf8"), "written-during-handover");
    assert.equal(readFileSync(join(keptDir(mesh.nodes.get(second!)!.data), HOME, A, "files", freshHash), "utf8"), "written-during-handover");
    assert.deepEqual(
      lines.filter((l) => l.message === "copies not handed over" || /ENOENT|ENOTEMPTY/i.test(String(l.fields?.error ?? ""))),
      [],
      "zero ENOENT/ENOTEMPTY or handover failures",
    );
  } finally {
    hearLines(null);
  }
});

test("primary keeper recovery cancels overflow keeper retry timer and stops zombie replica requests", async () => {
  const mesh = new Mesh();
  const A = id("a");
  const others = ["b", "c", "d"].map(id);
  mesh.rosters.set(HOME, [A, ...others]);
  const a = mesh.add(A, [HOME], station());
  for (const s of others) mesh.add(s, [HOME]);
  const [first, second] = keepers(HOME, A, [A, ...others]);
  const third = others.find((s) => s !== first && s !== second)!;
  const firstNode = mesh.nodes.get(first!)!;
  const thirdNode = mesh.nodes.get(third)!;

  // Start with first offline so A overflows to third.
  firstNode.up = false;
  for (const n of mesh.nodes.values()) if (n.up) await n.copies.start();
  await mesh.settle();
  assert.deepEqual(holders(mesh, HOME, A).sort(), [second!, third].sort());

  // Make third fail once so A arms `keeping.again` retry timer on third.
  thirdNode.up = false;
  const thread = a.store.sessionThreads("chat:a")[0]!.thread.id;
  a.store.insertMessage({ thread, ts: "overflow.fail", authorKind: "person", author: "p@x", text: "triggers third retry" });
  await a.copies.settle();
  const oBefore = (await a.copies.overview(HOME)) as Json;
  assert.notEqual(oBefore.keepers.find((k: Json) => k.station === third)?.error, null, "third failed and armed retry");

  // Bring both first and third back online; first syncs successfully and prunes third's retry timer.
  thirdNode.up = true;
  firstNode.up = true;
  await firstNode.copies.start();
  await mesh.settle();

  const askedThird = () => {
    const m = mesh.asked.get(third) ?? new Map<string, number>();
    return (m.get("replica.held") ?? 0) + (m.get("put:batch") ?? 0) + (m.get("put:head") ?? 0) + (m.get("put:file") ?? 0);
  };
  const afterRecovery = askedThird();

  // Advance clock 60s and settle: third's old retry timer must NOT fire zombie replica.held/replica.put requests,
  // and third cleanly hands over its stale copy of A.
  await mesh.clock.move(60_000);
  await mesh.settle();
  assert.equal(askedThird(), afterRecovery, "no zombie replica.held/replica.put sent to overflow keeper after primary recovery");
  assert.deepEqual(holders(mesh, HOME, A).sort(), [first!, second!].sort());
});

test("in-flight busy overflow keeper fails after primary recovery without arming retry or leaving stale error state", async () => {
  const mesh = new Mesh();
  const A = id("a");
  const others = ["b", "c", "d"].map(id);
  mesh.rosters.set(HOME, [A, ...others]);
  const a = mesh.add(A, [HOME], station());
  for (const s of others) mesh.add(s, [HOME]);
  const [first, second] = keepers(HOME, A, [A, ...others]);
  const third = others.find((s) => s !== first && s !== second)!;
  const firstNode = mesh.nodes.get(first!)!;
  const thirdNode = mesh.nodes.get(third)!;

  // Start with first offline so A overflows to third.
  firstNode.up = false;
  for (const n of mesh.nodes.values()) if (n.up) await n.copies.start();
  await mesh.settle();
  assert.deepEqual(holders(mesh, HOME, A).sort(), [second!, third].sort());

  // Intercept A's next replica.put to third so third stays `busy` in-flight while first recovers, then fails.
  const putStarted = deferred<void>();
  const failPut = deferred<void>();
  let interceptOnce = true;
  const origThirdHandle = thirdNode.bus.handle.bind(thirdNode.bus);
  thirdNode.bus.handle = async (ws, peer, req) => {
    if (interceptOnce && peer === A && req?.method === "replica.put") {
      interceptOnce = false;
      putStarted.resolve();
      await failPut.promise;
      throw new Error("station unreachable");
    }
    return origThirdHandle(ws, peer, req);
  };

  const thread = a.store.sessionThreads("chat:a")[0]!.thread.id;
  a.store.insertMessage({ thread, ts: "busy.overflow", authorKind: "person", author: "p@x", text: "in-flight to third" });
  await mesh.clock.move(1_000);
  await putStarted.promise;

  // Primary keeper `first` recovers and syncs successfully while `third` is still `busy`.
  firstNode.up = true;
  await firstNode.copies.start();
  // Wait for first to receive the new copy from A.
  await mesh.clock.move(1_000);

  // Release the in-flight `third` write as a failure: must NOT arm a retry timer or leave stale error state.
  failPut.resolve();
  await mesh.settle();

  const askedThird = () => {
    const m = mesh.asked.get(third) ?? new Map<string, number>();
    return (m.get("replica.held") ?? 0) + (m.get("put:batch") ?? 0) + (m.get("put:head") ?? 0) + (m.get("put:file") ?? 0);
  };
  const afterFailure = askedThird();

  await mesh.clock.move(60_000);
  await mesh.settle();
  assert.equal(askedThird(), afterFailure, "no zombie retry after busy overflow keeper failed post-recovery");
  assert.deepEqual(holders(mesh, HOME, A).sort(), [first!, second!].sort());

  // If primary goes down again later, third has no leftover error/backoff state and syncs immediately.
  firstNode.up = false;
  a.store.insertMessage({ thread, ts: "overflow.again", authorKind: "person", author: "p@x", text: "clean re-overflow" });
  await a.copies.settle();
  const oAfter = (await a.copies.overview(HOME)) as Json;
  assert.equal(oAfter.keepers.find((k: Json) => k.station === third)?.error, null, "re-overflow to third succeeds immediately with no stale retry state");
});

test("asHead and isHex64 validate 64-char lowercase hex keys without false accepts or rejects", () => {
  const validHex = "0123456789abcdef".repeat(4);
  assert.equal(isHex64(validHex), true);
  assert.equal(isHex64(validHex.toUpperCase()), false);
  assert.equal(isHex64(validHex.slice(0, 63)), false);
  assert.equal(isHex64(`${validHex}0`), false);
  assert.equal(isHex64(`g${validHex.slice(1)}`), false);
  assert.equal(isHex64(`/${validHex.slice(1)}`), false);
  assert.equal(isHex64(`:${validHex.slice(1)}`), false);
  assert.equal(isHex64(`\`${validHex.slice(1)}`), false);

  const makeHead = (overrides: Record<string, unknown> = {}): Record<string, unknown> => ({
    v: 1,
    origin: id("a"),
    workspace: HOME,
    gen: "1a2b3c-deadbeef",
    name: "test",
    dataDir: "/tmp/d",
    made: 1000,
    to: 1,
    batches: ["0000000001-0000000001-01234567.ndjson.zst"],
    files: { [validHex]: 123 },
    chats: 1,
    messages: 1,
    bytes: 123,
    runs: [{ run: "abcd1234", from: 1 }],
    ...overrides,
  });

  // Large transcriptFiles map accepted
  const largeTf: Record<string, number> = {};
  for (let i = 0; i < 1_000; i++) {
    largeTf[i.toString(16).padStart(64, "0")] = i + 1;
  }
  assert.notEqual(asHead(makeHead({ transcriptFiles: largeTf })), null);

  // Invalid files / transcriptFiles rejected
  assert.equal(asHead(makeHead({ files: null })), null);
  assert.equal(asHead(makeHead({ files: [] })), null);
  assert.equal(asHead(makeHead({ files: { [validHex.toUpperCase()]: 1 } })), null);
  assert.equal(asHead(makeHead({ files: { short: 1 } })), null);
  assert.equal(asHead(makeHead({ transcriptFiles: null })), null);
  assert.equal(asHead(makeHead({ transcriptFiles: [] })), null);
  assert.equal(asHead(makeHead({ transcriptFiles: { [`z${validHex.slice(1)}`]: 1 } })), null);
});

test("FolderPlace caches head metadata by (mtimeMs, size), skips re-reading head.json and readdir(files) in drop, and clears on remove", async () => {
  const root = dataDir("fp-cache");
  let headReads = 0;
  let filesDirReads = 0;
  const countingFs: Fs = {
    ...direct,
    async readAll(path: string) {
      if (path.endsWith("head.json")) headReads++;
      return direct.readAll(path);
    },
    async names(dir: string) {
      if (dir.endsWith("/files") || dir.endsWith("\\files")) filesDirReads++;
      return direct.names(dir);
    },
  };

  const place = new FolderPlace(root, countingFs);
  const origin = id("a");
  const gen1 = "1000-aaaaaaaa";
  const gen2 = "2000-bbbbbbbb";
  const b1 = "0000000001-0000000001-11111111.ndjson.zst";
  const b2 = "0000000002-0000000002-22222222.ndjson.zst";
  const fKeep = id("1");
  const fShared = id("2");
  const fOrphan = id("3");

  const makeHead = (gen: string, to: number, batches: string[], files: Record<string, number>, transcriptFiles?: Record<string, number>): Head => ({
    v: 1,
    origin,
    workspace: HOME,
    gen,
    name: "n",
    dataDir: "/d",
    made: to * 1000,
    to,
    batches,
    files,
    ...(transcriptFiles !== undefined ? { transcriptFiles } : {}),
    chats: 1,
    messages: to,
    bytes: 10,
    runs: [{ run: "12345678", from: 1 }],
  });

  await place.put(HOME, origin, gen1, "batch", b1, Buffer.from("batch1"));
  await place.put(HOME, origin, gen1, "batch", b2, Buffer.from("batch2"));
  await place.putFile(HOME, origin, fKeep, Buffer.from("keep"));
  await place.putFile(HOME, origin, fShared, Buffer.from("shared"));
  await place.putFile(HOME, origin, fOrphan, Buffer.from("orphan"));

  // First put("head"): head.json doesn't exist yet -> 0 reads, writes & caches.
  await place.put(HOME, origin, gen1, "head", "head.json", Buffer.from(JSON.stringify(makeHead(gen1, 1, [b1], { [fKeep]: 4, [fShared]: 6, [fOrphan]: 6 }))));
  assert.equal(headReads, 0);

  // Second put("head"): hits cache -> 0 reads, updates cache.
  await place.put(HOME, origin, gen1, "head", "head.json", Buffer.from(JSON.stringify(makeHead(gen1, 2, [b2], { [fKeep]: 4 }))));
  assert.equal(headReads, 0);

  // Stale head (to=1 < cached to=2): ignored with 0 reads.
  await place.put(HOME, origin, gen1, "head", "head.json", Buffer.from(JSON.stringify(makeHead(gen1, 1, [b1], { [fKeep]: 4 }))));
  assert.equal(headReads, 0);
  const headPath1 = join(place.dir(HOME, origin), gen1, "head.json");
  assert.equal((JSON.parse(readFileSync(headPath1, "utf8")) as Head).to, 2);

  // Put gen2 referencing fShared in transcriptFiles.
  await place.put(HOME, origin, gen2, "batch", b1, Buffer.from("batch1-g2"));
  await place.put(HOME, origin, gen2, "head", "head.json", Buffer.from(JSON.stringify(makeHead(gen2, 1, [b1], {}, { [fShared]: 6 }))));
  assert.equal(headReads, 0);

  // drop() on gen1: drops b1 and fOrphan, keeps b2, fKeep, and fShared (referenced by gen2).
  // Must NOT read head.json again and must NOT call names("files").
  await place.drop(HOME, origin, gen1, [b1, b2], [fOrphan, fShared, fKeep]);
  assert.equal(headReads, 0, "drop uses cached head metadata");
  assert.equal(filesDirReads, 0, "drop must not readdir(files)");
  assert.equal(existsSync(join(place.dir(HOME, origin), gen1, "log", b1)), false);
  assert.equal(existsSync(join(place.dir(HOME, origin), gen1, "log", b2)), true);
  assert.equal(existsSync(join(place.dir(HOME, origin), "files", fOrphan)), false);
  assert.equal(existsSync(join(place.dir(HOME, origin), "files", fShared)), true);
  assert.equal(existsSync(join(place.dir(HOME, origin), "files", fKeep)), true);

  // Externally overwrite head.json on disk with higher to=5 and newer mtime -> cache invalidates automatically.
  const externalHead = makeHead(gen1, 5, [b2], { [fKeep]: 4 });
  writeFileSync(headPath1, JSON.stringify(externalHead, null, 2));
  utimesSync(headPath1, new Date(1_800_000_000_000), new Date(1_800_000_000_000));
  await place.put(HOME, origin, gen1, "head", "head.json", Buffer.from(JSON.stringify(makeHead(gen1, 3, [b2], { [fKeep]: 4 }))));
  assert.equal(headReads, 1, "external disk modification invalidates cache and triggers re-read");
  assert.equal((JSON.parse(readFileSync(headPath1, "utf8")) as Head).to, 5, "externally written newer head is not overwritten");

  // remove() clears cache: re-putting to=1 after remove succeeds without stale cache interference.
  await place.remove(HOME, origin);
  await place.put(HOME, origin, gen1, "batch", b1, Buffer.from("batch1-again"));
  await place.put(HOME, origin, gen1, "head", "head.json", Buffer.from(JSON.stringify(makeHead(gen1, 1, [b1], { [fKeep]: 4 }))));
  assert.equal((JSON.parse(readFileSync(headPath1, "utf8")) as Head).to, 1);
});

test("level() fast path, missing+oldFiles cleanup, includeTranscripts:false drop, and overlap ENOENT semantics", async () => {
  const origin = id("a");
  const gen = "1000-aaaaaaaa";
  const fChat = id("1");
  const fOverlap = id("2");
  const fTr = id("3");
  const fOld = id("4");
  const fMissing = id("5");

  const makeHead = (to: number, files: Record<string, number>, transcriptFiles?: Record<string, number>): Head => ({
    v: 1,
    origin,
    workspace: HOME,
    gen,
    name: "n",
    dataDir: "/d",
    made: to * 1000,
    to,
    batches: [],
    files,
    ...(transcriptFiles !== undefined ? { transcriptFiles } : {}),
    chats: 1,
    messages: to,
    bytes: 0,
    runs: [{ run: "12345678", from: 1 }],
  });

  // 1. Fast path (no old files) -> drop not called.
  const drops: { batches: string[]; files: string[] }[] = [];
  const memFiles = new Set<string>([fChat, fTr]);
  const fakePlace: Place = {
    async held() {
      return { gens: [{ gen, head: makeHead(1, { [fChat]: 1 }, { [fTr]: 1 }), batches: [] }], files: [...memFiles] };
    },
    async put() {},
    async putFile(_ws, _o, hash) {
      memFiles.add(hash);
    },
    async drop(_ws, _o, _g, batches, files) {
      drops.push({ batches, files });
      for (const f of files) memFiles.delete(f);
    },
  };
  const r1 = await level(fakePlace, HOME, {
    head: makeHead(2, { [fChat]: 1 }, { [fTr]: 1 }),
    batch: async () => Buffer.alloc(0),
    sources: async () => new Map(),
  });
  assert.equal(r1.behind, false);
  assert.equal(r1.missing, 0);
  assert.equal(drops.length, 0, "fast path skips drop when k.files matches wanted");

  // 2. missing > 0 while an old file is in k.files AND chat/transcript hashes overlap -> old file is still dropped, overlap/live files kept!
  memFiles.add(fOld);
  memFiles.add(fOverlap);
  r1.known.files.add(fOld);
  r1.known.files.add(fOverlap);
  const r2 = await level(
    fakePlace,
    HOME,
    {
      head: makeHead(3, { [fChat]: 1, [fOverlap]: 1, [fMissing]: 1 }, { [fOverlap]: 1, [fTr]: 1 }),
      batch: async () => Buffer.alloc(0),
      sources: async () => new Map(), // fMissing has no source -> missing = 1
    },
    r1.known,
  );
  assert.equal(r2.behind, false);
  assert.equal(r2.missing, 1);
  assert.deepEqual(drops.at(-1)?.files, [fOld], "old file is dropped even when missing > 0 with overlapping chat+transcript hash");
  assert.equal(r2.known.files.has(fChat), true);
  assert.equal(r2.known.files.has(fOverlap), true);
  assert.equal(r2.known.files.has(fTr), true);

  // 3. includeTranscripts: false -> drops transcript-only files, keeps chat and overlap files.
  const r3 = await level(
    fakePlace,
    HOME,
    {
      head: makeHead(4, { [fChat]: 1, [fOverlap]: 1 }, { [fOverlap]: 1, [fTr]: 1 }),
      batch: async () => Buffer.alloc(0),
      sources: async () => new Map(),
    },
    r2.known,
    { includeTranscripts: false },
  );
  assert.equal(r3.behind, false);
  assert.deepEqual(drops.at(-1)?.files, [fTr], "includeTranscripts:false drops transcript-only hash");
  assert.equal(r3.known.files.has(fOverlap), true, "overlap hash in files is preserved");

  // 4. ENOENT semantics: chat-only hash swallows ENOENT into missing++, overlap (chat+transcript) hash rethrows ENOENT.
  const enoentPlace: Place = {
    async held() {
      return nothingHeld();
    },
    async put() {},
    async putFile() {
      throw Object.assign(new Error("ENOENT: gone"), { code: "ENOENT" });
    },
    async drop() {},
  };
  const rChatEnoent = await level(enoentPlace, HOME, {
    head: makeHead(1, { [fChat]: 1 }),
    batch: async () => Buffer.alloc(0),
    sources: async (hs) => new Map(hs.map((h) => [h, `/tmp/${h}`])),
  });
  assert.equal(rChatEnoent.behind, false);
  assert.equal(rChatEnoent.missing, 1, "chat-only ENOENT counted as missing");

  await assert.rejects(
    level(enoentPlace, HOME, {
      head: makeHead(1, { [fOverlap]: 1 }, { [fOverlap]: 1 }),
      batch: async () => Buffer.alloc(0),
      sources: async (hs) => new Map(hs.map((h) => [h, `/tmp/${h}`])),
    }),
    /ENOENT/,
    "overlap chat+transcript hash must rethrow ENOENT",
  );
});

test("FolderPlace serializes concurrent put('head') and drop() to prevent stale overwrite or cache-disk divergence", async () => {
  const root = dataDir("fp-race");
  const origin = id("a");
  const gen = "1000-aaaaaaaa";
  const b1 = "0000000001-0000000001-11111111.ndjson.zst";
  const b2 = "0000000002-0000000002-22222222.ndjson.zst";
  const b3 = "0000000003-0000000003-33333333.ndjson.zst";

  let pauseNextHeadRename = false;
  let renamePaused = deferred<void>();
  let releaseRename = deferred<void>();
  const raceFs: Fs = {
    ...direct,
    async rename(from: string, to: string) {
      if (pauseNextHeadRename && to.endsWith("head.json")) {
        pauseNextHeadRename = false;
        renamePaused.resolve();
        await releaseRename.promise;
      }
      return direct.rename(from, to);
    },
  };

  const place = new FolderPlace(root, raceFs);
  await place.put(HOME, origin, gen, "batch", b1, Buffer.from("b1"));
  await place.put(HOME, origin, gen, "batch", b2, Buffer.from("b2"));
  await place.put(HOME, origin, gen, "batch", b3, Buffer.from("b3"));

  const makeHead = (to: number, batches: string[]): Head => ({
    v: 1,
    origin,
    workspace: HOME,
    gen,
    name: "n",
    dataDir: "/d",
    made: to * 1000,
    to,
    batches,
    files: {},
    chats: 1,
    messages: to,
    bytes: 0,
    runs: [{ run: "12345678", from: 1 }],
  });

  // Case 1: older put(to=1) pauses before rename while newer put(to=2) arrives concurrently -> final disk & cache hold to=2.
  pauseNextHeadRename = true;
  const pOld = place.put(HOME, origin, gen, "head", "head.json", Buffer.from(JSON.stringify(makeHead(1, [b1]))));
  await renamePaused.promise;
  const pNew = place.put(HOME, origin, gen, "head", "head.json", Buffer.from(JSON.stringify(makeHead(2, [b1, b2]))));
  releaseRename.resolve();
  await Promise.all([pOld, pNew]);

  const headPath = join(place.dir(HOME, origin), gen, "head.json");
  assert.equal((JSON.parse(readFileSync(headPath, "utf8")) as Head).to, 2);
  // drop([b2]) must NOT delete b2 because to=2 references it.
  await place.drop(HOME, origin, gen, [b2], []);
  assert.equal(existsSync(join(place.dir(HOME, origin), gen, "log", b2)), true);

  // Case 2: newer put(to=3, [b1,b2,b3]) pauses before rename while older put(to=2) and drop([b3]) arrive concurrently.
  renamePaused = deferred<void>();
  releaseRename = deferred<void>();
  pauseNextHeadRename = true;
  const pNewest = place.put(HOME, origin, gen, "head", "head.json", Buffer.from(JSON.stringify(makeHead(3, [b1, b2, b3]))));
  await renamePaused.promise;
  const pStale = place.put(HOME, origin, gen, "head", "head.json", Buffer.from(JSON.stringify(makeHead(2, [b1, b2]))));
  const pDrop = place.drop(HOME, origin, gen, [b3], []);
  releaseRename.resolve();
  await Promise.all([pNewest, pStale, pDrop]);

  assert.equal((JSON.parse(readFileSync(headPath, "utf8")) as Head).to, 3, "stale concurrent put does not overwrite newer head");
  assert.equal(existsSync(join(place.dir(HOME, origin), gen, "log", b3)), true, "concurrent drop does not delete batch referenced by newer head");

  // Subsequent older put(to=2) is still rejected by cached to=3.
  await place.put(HOME, origin, gen, "head", "head.json", Buffer.from(JSON.stringify(makeHead(2, [b1]))));
  assert.equal((JSON.parse(readFileSync(headPath, "utf8")) as Head).to, 3);
});

test("FolderPlace handles corrupted head.json in drop, enforces LRU cap on #headFiles, and clears cache on forget()", async () => {
  const root = dataDir("fp-lru");
  const headReads = new Map<string, number>();
  const countingFs: Fs = {
    ...direct,
    async readAll(path: string) {
      if (path.endsWith("head.json")) {
        headReads.set(path, (headReads.get(path) ?? 0) + 1);
      }
      return direct.readAll(path);
    },
  };

  const place = new FolderPlace(root, countingFs);
  const origin = id("a");
  const fOrphan = id("9");
  await place.putFile(HOME, origin, fOrphan, Buffer.from("orphan"));

  const makeHead = (ws: string, gen: string, to: number, files: Record<string, number>): Head => ({
    v: 1,
    origin,
    workspace: ws,
    gen,
    name: "n",
    dataDir: "/d",
    made: to * 1000,
    to,
    batches: [],
    files,
    chats: 1,
    messages: to,
    bytes: 0,
    runs: [{ run: "12345678", from: 1 }],
  });

  // 1. Put 9 origins (> MAX_FILES_ENTRIES = 8) so origin0 is evicted from #headFiles while origin1..origin8 stay cached.
  const gen = "1000-00000001";
  const origins = ["0", "1", "2", "3", "4", "5", "6", "7", "8"].map(id);
  for (let i = 0; i < origins.length; i++) {
    const o = origins[i]!;
    await place.putFile(HOME, o, fOrphan, Buffer.from("orphan"));
    await place.put(HOME, o, gen, "head", "head.json", Buffer.from(JSON.stringify({
      ...makeHead(HOME, gen, 1, { [id(String(i))]: 1 }),
      origin: o,
    })));
  }
  assert.equal(headReads.size, 0, "putting 9 heads does not re-read any head.json");

  // Most recent origin8 is still cached in #headFiles -> 0 reads on drop.
  await place.drop(HOME, origins[8]!, gen, [], [fOrphan]);
  assert.equal(headReads.size, 0, "most recent origin stays cached in #headFiles");
  assert.equal(existsSync(join(place.dir(HOME, origins[8]!), "files", fOrphan)), false, "unreferenced file unlinked");

  // Oldest origin0 was evicted by LRU cap -> re-read once on drop.
  await place.drop(HOME, origins[0]!, gen, [], [fOrphan]);
  const origin0Head = join(place.dir(HOME, origins[0]!), gen, "head.json");
  assert.equal(headReads.get(origin0Head), 1, "oldest entry was evicted by LRU cap and re-read on drop");
  assert.equal(existsSync(join(place.dir(HOME, origins[0]!), "files", fOrphan)), false, "unreferenced file unlinked on evicted origin");

  // 2. Corrupted head.json on disk: fail-closed drop() MUST reject and preserve all files without unlinking.
  const corruptGen = "9999-cccccccc";
  const corruptDir = join(place.dir(HOME, origin), corruptGen);
  mkdirSync(corruptDir, { recursive: true });
  writeFileSync(join(corruptDir, "head.json"), "{corrupted-json");
  const fOrphan2 = id("e");
  await place.putFile(HOME, origin, fOrphan2, Buffer.from("orphan2"));
  await assert.rejects(() => place.drop(HOME, origin, corruptGen, [], [fOrphan2]), /corrupted head\.json/);
  assert.equal(existsSync(join(place.dir(HOME, origin), "files", fOrphan2)), true, "fail-closed drop preserves files on corrupted head.json");

  // 3. forget(ws, origin) and forget(ws) clear cache so subsequent put/drop re-reads disk cleanly.
  const origin8Head = join(place.dir(HOME, origins[8]!), gen, "head.json");
  const origin8Payload = Buffer.from(JSON.stringify({ ...makeHead(HOME, gen, 1, { [id("8")]: 1 }), origin: origins[8]! }));
  headReads.clear();
  place.forget(HOME, origins[8]!);
  await place.put(HOME, origins[8]!, gen, "head", "head.json", origin8Payload);
  assert.equal(headReads.get(origin8Head), 1, "forget(ws, origin) evicted cache entry");

  headReads.clear();
  place.forget(HOME);
  await place.put(HOME, origins[8]!, gen, "head", "head.json", origin8Payload);
  assert.equal(headReads.get(origin8Head), 1, "forget(ws) evicted cache entry");
});

test("D71: level() pages place.drop() by dropFilesPage, preserves remaining files on mid-page error, and drops batches-only", async () => {
  const origin = id("a");
  const gen = "1000-aaaaaaaa";
  const b1 = "0000000001-0000000001-11111111.ndjson.zst";
  const b2 = "0000000002-0000000002-22222222.ndjson.zst";
  const oldFiles = ["1", "2", "3", "4", "5"].map(id);
  const liveFile = id("9");

  const makeHead = (to: number, batches: string[], files: Record<string, number>): Head => ({
    v: 1,
    origin,
    workspace: HOME,
    gen,
    name: "n",
    dataDir: "/d",
    made: to * 1000,
    to,
    batches,
    files,
    chats: 1,
    messages: to,
    bytes: 0,
    runs: [{ run: "12345678", from: 1 }],
  });

  // 1. 5 oldFiles, dropFilesPage=2, oldBatches=[b1] -> 3 calls: ([b1], 2), ([], 2), ([], 1)
  const calls: { batches: string[]; files: string[] }[] = [];
  const place1: Place = {
    async held() {
      return { gens: [{ gen, head: makeHead(1, [b1], { [liveFile]: 1 }), batches: [b1] }], files: [liveFile, ...oldFiles] };
    },
    async put() {},
    async putFile() {},
    async drop(_ws, _o, _g, batches, files) {
      calls.push({ batches: [...batches], files: [...files] });
    },
  };
  const r1 = await level(
    place1,
    HOME,
    { head: makeHead(2, [b2], { [liveFile]: 1 }), batch: async () => Buffer.from("b2"), sources: async () => new Map() },
    null,
    { dropFilesPage: 2 },
  );
  assert.equal(r1.behind, false);
  assert.equal(calls.length, 3);
  assert.deepEqual(calls[0], { batches: [b1], files: oldFiles.slice(0, 2) });
  assert.deepEqual(calls[1], { batches: [], files: oldFiles.slice(2, 4) });
  assert.deepEqual(calls[2], { batches: [], files: oldFiles.slice(4, 5) });
  assert.deepEqual([...r1.known.batches], [b2]);
  assert.deepEqual([...r1.known.files], [liveFile]);

  // 2. Page 2 throws -> page 1's oldBatches and 2 files removed from k, remaining 3 files kept in k.files for retry
  let callNum = 0;
  const known2 = {
    gen,
    batches: new Set([b1, b2]),
    files: new Set([liveFile, ...oldFiles]),
    others: new Set<string>(),
    to: 1,
    made: 1000,
  };
  const place2: Place = {
    async held() {
      return nothingHeld();
    },
    async put() {},
    async putFile() {},
    async drop() {
      callNum++;
      if (callNum === 2) throw new Error("page 2 network failure");
    },
  };
  await assert.rejects(
    level(
      place2,
      HOME,
      { head: makeHead(2, [b2], { [liveFile]: 1 }), batch: async () => Buffer.from("b2"), sources: async () => new Map() },
      known2,
      { dropFilesPage: 2 },
    ),
    /page 2 network failure/,
  );
  assert.equal(known2.batches.has(b1), false, "page 1 oldBatch removed before page 2 failed");
  assert.equal(known2.files.has(oldFiles[0]!), false, "page 1 file 0 removed");
  assert.equal(known2.files.has(oldFiles[1]!), false, "page 1 file 1 removed");
  assert.equal(known2.files.has(oldFiles[2]!), true, "page 2 file 2 retained for retry");
  assert.equal(known2.files.has(oldFiles[3]!), true, "page 2 file 3 retained for retry");
  assert.equal(known2.files.has(oldFiles[4]!), true, "page 3 file 4 retained for retry");

  // 3. oldFiles=[] and oldBatches=[b1] -> 1 call place.drop(..., [b1], [])
  const batchOnlyCalls: { batches: string[]; files: string[] }[] = [];
  const place3: Place = {
    async held() {
      return { gens: [{ gen, head: makeHead(1, [b1], { [liveFile]: 1 }), batches: [b1] }], files: [liveFile] };
    },
    async put() {},
    async putFile() {},
    async drop(_ws, _o, _g, batches, files) {
      batchOnlyCalls.push({ batches: [...batches], files: [...files] });
    },
  };
  const r3 = await level(
    place3,
    HOME,
    { head: makeHead(2, [b2], { [liveFile]: 1 }), batch: async () => Buffer.from("b2"), sources: async () => new Map() },
    null,
    { dropFilesPage: 2 },
  );
  assert.equal(r3.behind, false);
  assert.deepEqual(batchOnlyCalls, [{ batches: [b1], files: [] }]);
  assert.deepEqual([...r3.known.batches], [b2]);
});
