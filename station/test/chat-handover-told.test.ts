// What is told and answered of a chat that moved (replica/handover.ts, api/, move/routes.ts): the rows put in, a row's
// `from`, reads and letters followed there, messages under a key answered once, a write answered where it went (409
// `moved`), the move routes, a device told only once the other shows it, the move page's reads. Split from
// chat-handover.test.ts by subject; its stations are move-world.ts's.
import assert from "node:assert/strict";
import { join } from "node:path";
import { test } from "node:test";
import { sessionKey } from "../src/sessions/hub.ts";
import { NOTICE_MARK } from "../src/sessions/chat.ts";
import { newSession, say } from "../src/sessions/lifecycle.ts";
import { moveView } from "../src/move/routes.ts";
import { MoveAsks } from "../src/tools/move.ts";
import type { Request } from "../src/api/request.ts";
import { tell } from "../src/replica/copies.ts";
import { Exporter, genDir, nothingTold, ownDir } from "./reference/replica-export.ts";
import { readCopy } from "./reference/replica-restore.ts";
import { message, reply } from "./hub-fakes.ts";
import { Readers } from "../src/read/pool.ts";
import { elsewhere } from "../src/api/seen.ts";
import { RETRY_MS } from "../src/replica/retire.ts";
import { WS, A, B, C, type Station, world, endTurn, stillfailChat, entries, homeThread, retiredCopy } from "./move-world.ts";

type Json = any;

test("what the move page reads of a chat says where it is and where what it waits for is: a chat at a third station `at` it, one stopped here for a login on the other `waitsAt` it; an ordinary row neither", async () => {
  const w = world([A, B, C]);
  const a = w.get(A);
  const atC = await stillfailChat(a);
  const plain = await stillfailChat(a);
  a.rig.raw.profiles.push({ id: "solo", runtime: "claude", home: "homes/solo" });
  const [stopped, t] = await newSession(a.rig.hub, { runtime: "claude", profile: "solo", createdBy: "p@x" });
  say(a.rig.hub, t.id, "p@x", "hi");
  await endTurn(a, stopped);
  assert.equal((await a.moves.scheduler.move(WS, C, { module: "chats", item: atC.key })).failed, null);
  await w.quiet();
  assert.equal((await a.moves.scheduler.move(WS, B, { module: "accounts", item: `own:solo@${A}` })).failed, null);
  await w.quiet();
  const name = (id: string) => ({ [A]: "A", [B]: "B", [C]: "C" })[id] ?? id;
  const view = moveView(await a.moves.scheduler.plan(WS, B), a.moves.modules.map((m) => m.id), a.moves.scheduler.stopped(), { limit: 50 }, null, false, name);
  const row = (id: string) => view.modules.find((m: Json) => m.id === "chats").items.find((x: Json) => x.id === id);
  assert.equal(row(atC.key).at, "C", "a chat at a third station says which");
  assert.deepEqual([row(stopped).state, row(stopped).waitsFor, row(stopped).waitsAt], ["stopped", `accounts own:solo@${A}`, "B"], "stopped here, waiting for a login on B");
  assert.ok(!("at" in row(plain.key)) && !("waitsAt" in row(plain.key)), "an ordinary row neither");
  // (toward the station a chat is at, it is simply there)
  const toward = moveView(await a.moves.scheduler.plan(WS, C), a.moves.modules.map((m) => m.id), a.moves.scheduler.stopped(), { limit: 50 }, null, false, name);
  assert.ok(!("at" in toward.modules.find((m: Json) => m.id === "chats").items.find((x: Json) => x.id === atC.key)), "there, toward where it is");
});

test("a letter to a chat that moved, from a chat still here, reaches it there; reading it from here reads it there", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  const mover = await stillfailChat(a);
  await a.moves.scheduler.move(WS, B, { module: "chats", item: mover.key });
  await w.quiet();
  const said = await a.rig.call(key, "session_send", { to: mover.key, text: "where are you now?" });
  await w.quiet();
  assert.match(said, /Sent to/);
  assert.ok(b.rig.claude.sessions.flatMap((s) => s.prompts).join("\n").includes("where are you now?"), "delivered there");
});

test("the rows put in tell what they are, marks and reads among them, as the copies' export reads them", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key, thread } = await stillfailChat(a);
  a.rig.store.setRead("p@x", thread, 2);
  a.rig.store.setPin("p@x", key, true);
  const told = nothingTold();
  const off = b.rig.store.subscribe((c) => void tell(told, c));
  await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  off();
  const there = homeThread(b, key);
  assert.ok(told.marks.some((m) => m.table === "reads" && m.key.thread === there && m.key.viewer === "p@x"), JSON.stringify(told.marks));
  assert.ok(told.marks.some((m) => m.table === "pins" && m.key.session === key));
  assert.ok(told.sessions.includes(key));
  assert.ok(told.threads.includes(there));
});

test("what the app's page reads of a move: the modules in order with their needs, done of total, how many cannot move of all, each item as it stands", async () => {
  const w = world();
  const a = w.get(A);
  const { key } = await stillfailChat(a);
  await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  // (a chat on this machine's own login, which cannot go, and one working outside the station's data: each cannot move)
  await newSession(a.rig.hub, { runtime: "claude", profile: "mine", createdBy: "p@x" });
  const [outside] = await newSession(a.rig.hub, { runtime: "claude", profile: "cc", createdBy: "p@x" });
  a.rig.store.db.prepare("UPDATE sessions SET workspace = ? WHERE key = ?").run("/elsewhere/proj", outside);
  const one = moveView(await a.moves.scheduler.plan(WS, B), a.moves.modules.map((m) => m.id), a.moves.scheduler.stopped(), { limit: 1 });
  assert.deepEqual(one.modules.map((m: Json) => [m.id, m.cannot]).filter(([, n]: [string, number]) => n > 0), [["accounts", 1], ["chats", 1]], "counted of all, not of a page of one");
  const view = moveView(await a.moves.scheduler.plan(WS, B), a.moves.modules.map((m) => m.id), a.moves.scheduler.stopped(), { limit: 10 });
  assert.deepEqual(view.modules.map((m: Json) => m.id), ["accounts", "chats", "jobs", "connects", "repos", "vault", "settings"]);
  const chats = view.modules.find((m: Json) => m.id === "chats");
  assert.deepEqual(chats.needs, ["accounts", "connects", "repos", "vault"]);
  assert.equal(chats.done, 1);
  assert.deepEqual(chats.items.find((x: Json) => x.id === key), { id: key, label: a.rig.session(key).title ?? key, state: "there", needs: ["accounts share:sh-cc"] });
  assert.equal(view.moving, null);
});

test("a chat's row says the station it came from: none where it began, the one before where it went on, none again back where it began", async () => {
  const w = world([A, B, C]);
  const a = w.get(A);
  const b = w.get(B);
  const c = w.get(C);
  const { key } = await stillfailChat(a);
  assert.equal(a.rig.session(key).from, undefined, "it began here");
  await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  assert.equal(b.rig.session(key).from, A);
  const on = await b.moves.scheduler.move(WS, C, { module: "chats", item: key });
  await w.quiet();
  assert.equal(on.failed, null, JSON.stringify(on));
  assert.equal(c.rig.session(key).from, B, "the station before");
  assert.equal(b.rig.store.handedTo(key)?.station, C, "and B says where it went");
  const home = await c.moves.scheduler.move(WS, A, { module: "chats", item: key });
  await w.quiet();
  assert.equal(home.failed, null, JSON.stringify(home));
  assert.equal(a.rig.session(key).from, undefined, "back where it began: none");
  assert.equal(a.rig.store.handedTo(key), null);
});

test("reading a chat that moved, from a chat still here, reads it there: chat_read and session_history", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  const mover = await stillfailChat(a);
  await a.moves.scheduler.move(WS, B, { module: "chats", item: mover.key });
  await w.quiet();
  const there = homeThread(b, mover.key);
  say(b.rig.hub, there, "p@x", "said only there");
  await w.quiet();
  const read = await a.rig.call(key, "chat_read", { chat: mover.key });
  assert.match(read, /Read from station/);
  assert.ok(read.includes("said only there"), read);
  const history = await a.rig.call(key, "session_history", { chat: mover.key }).catch((e: Error) => e.message);
  assert.match(history, new RegExp(`station ${B}|Read from station`), history);
});

test("the copies' export on the station a chat went to carries it in its next pass: its rows, marks and reads", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key, thread } = await stillfailChat(a);
  a.rig.store.setRead("p@x", thread, 2);
  a.rig.store.setPin("q@x", key, true);
  a.rig.store.setChatHidden("r@x", thread, true);
  const e = new Exporter({ db: join(b.rig.dir, "stillfail.db"), replica: join(b.rig.dir, "replica-copy"), dataDir: b.rig.dir, origin: B, now: () => 1_000 });
  e.setPlaces({ home: WS, workspaces: [{ workspace: WS, name: "B" }] });
  let p = e.pass(nothingTold());
  while (p.more) p = e.pass(nothingTold());
  const told = nothingTold();
  const off = b.rig.store.subscribe((c) => void tell(told, c));
  await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  off();
  p = e.pass(told);
  while (p.more) p = e.pass(nothingTold());
  const head = p.heads[WS] ?? e.heads()[WS]!;
  const { folded } = readCopy(genDir(ownDir(join(b.rig.dir, "replica-copy")), WS, head.gen));
  e.close();
  const there = homeThread(b, key);
  assert.ok(folded.table("sessions").some((r) => r.key === key), "its session");
  assert.equal(folded.table("entries").filter((r) => r.thread === there).length, b.rig.store.entriesAfter(there, 0).length, "its log");
  assert.ok(folded.table("reads").some((r) => r.viewer === "p@x" && r.thread === there), "a read");
  assert.ok(folded.table("pins").some((r) => r.viewer === "q@x" && r.session === key), "a pin");
  assert.ok(folded.table("hidden_chats").some((r) => r.viewer === "r@x" && r.thread === there), "a hidden mark");
});

test("a chat in a turn moved, its turn waited for: the move page's row and the moving one say it waits for the turn to end (`waits: \"turn\"`), not stuck; the turn ended, it goes, and nothing says so any more", async () => {
  const w = world();
  const a = w.get(A);
  const [key, t] = await newSession(a.rig.hub, { runtime: "claude", profile: "cc", createdBy: "p@x" });
  say(a.rig.hub, t.id, "p@x", "busy now");
  await a.rig.quiet();
  assert.equal(a.rig.hub.busy(key), true);
  // (told the moment the hand-over begins to wait for the turn)
  const waiting = Promise.withResolvers<void>();
  const hub = a.rig.hub;
  const turnEnded = hub.turnEnded.bind(hub);
  hub.turnEnded = (k: string) => {
    const ended = turnEnded(k);
    waiting.resolve();
    return ended;
  };
  const moving = a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await waiting.promise;
  const name = (id: string) => ({ [A]: "A", [B]: "B" })[id] ?? id;
  const view = async () => moveView(await a.moves.scheduler.plan(WS, B), a.moves.modules.map((m) => m.id), a.moves.scheduler.stopped(), { limit: 50 }, null, false, name);
  const during = await view();
  const row = (v: Json) => v.modules.find((m: Json) => m.id === "chats").items.find((x: Json) => x.id === key);
  assert.deepEqual([row(during).state, row(during).waits], ["moving", "turn"], "its row: moving, waiting for the turn");
  assert.deepEqual([during.moving?.id, during.moving?.waits], [key, "turn"], "the moving one says so too");
  assert.equal(a.rig.hub.chatHeld(key), null, "not held while its turn goes on");
  await a.rig.call(key, "chat_state", { kind: "final" });
  a.rig.claude.last().complete();
  const out = await moving;
  await w.quiet();
  assert.equal(out.failed, null, JSON.stringify(out));
  assert.equal(a.rig.store.handedTo(key)?.station, B, "it went once the turn ended");
  const after = await view();
  assert.deepEqual([row(after).state, "waits" in row(after), after.moving], ["there", false, null]);
});

test("a station's notice that comes back through another bot's connect wakes nothing and brings no chat back; that bot's ordinary message is taken", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  // B runs a bot of its own (gpt) in the same channel; A's cl bot is told to B as A's connect hears its first event
  b.rig.raw.connects = [{ id: "gpt", bind: { runtime: "codex" } }];
  b.rig.raw.profiles.push({ id: "cxb2", runtime: "codex", home: "homes/cxb2" });
  const first = message({ text: "<@UGPT> hello", user: "U1" });
  await b.connects.receive("gpt", { type: "message", message: first });
  const key = sessionKey("gpt", first.channel, first.threadTs);
  await endTurn(b, key, "codex");
  b.rig.store.setArchived(key, true, "auto");
  await a.connects.receive("cl", { type: "message", message: message({ text: "<@UBOT> elsewhere" }) });
  await w.quiet();
  assert.ok(b.rig.hub.toldBots.get(A)?.has("UBOT"), "told, not asked");
  const prompts = () => b.rig.codex.sessions.flatMap((s) => s.prompts).join("\n");
  // A's notice, as Slack hands it to B's bot: no person's message
  await b.connects.receive("gpt", { type: "message", message: reply(first, "1900.1", `⚠️ the chat stopped${NOTICE_MARK}`, { user: "UBOT" }) });
  await w.quiet();
  assert.ok(!prompts().includes("the chat stopped"), "woke nothing");
  assert.equal(b.rig.session(key).archivedBy, "auto", "still archived");
  // A's agent's own answer through its bot is a message as any other bot's
  await b.connects.receive("gpt", { type: "message", message: reply(first, "1900.2", "<@UGPT> what do you think?", { user: "UBOT", addressed: true }) });
  await w.quiet();
  assert.ok(prompts().includes("what do you think?"), "taken");
});

test("a message a device sent here under its key, asked again there after the chat moved, is in the log there once", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key, thread } = await stillfailChat(a);
  const viewer = { sub: "p", email: "p@x", name: "P", role: "member", workspace: WS, device: "d" };
  const send = (st: Station, id: number, text: string, once: string) =>
    st.admin.handle({ method: "POST", path: `/threads/${id}/messages`, query: [], headers: { "idempotency-key": once }, body: Buffer.from(JSON.stringify({ text })), viewer, lang: "en" });
  // Sent here, its answer lost on the way: the device asks again, by then of the station the chat went to.
  const first = await send(a, thread, "only once", "k1");
  assert.equal(first.status, 200);
  await endTurn(a, key);
  await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  const there = homeThread(b, key);
  const again = await send(b, there, "only once", "k1");
  assert.equal(again.status, 200);
  assert.deepEqual(JSON.parse(String(again.body)), JSON.parse(String(first.body)), "answered as it was here");
  assert.equal(entries(b, there).filter((e) => e === "person:only once").length, 1, entries(b, there).join("\n"));
  assert.equal(b.rig.claude.count(), 0, "nothing started there by it");
  // Another key there is another message.
  assert.equal((await send(b, there, "a new one", "k2")).status, 200);
  await w.quiet();
  assert.equal(entries(b, there).filter((e) => e === "person:a new one").length, 1);
});

test("a message written here under its key by the program's way (`claimSay`, the say path), asked again there after the chat moved, is answered as here and not posted twice", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key, thread } = await stillfailChat(a);
  const viewer = { sub: "p", email: "p@x", name: "P", role: "member", workspace: WS, device: "d" } as Json;
  // (the program claims the key, writes the message, and settles the key with its answer)
  const claimed = await a.admin.claimSay(viewer, `/threads/${thread}/messages`, "k1", "en");
  assert.ok("ts" in claimed, JSON.stringify(claimed));
  say(a.rig.hub, thread, "p@x", "only once");
  const body = Buffer.from(JSON.stringify({ ok: true, ts: claimed.ts }));
  claimed.settle({ status: 200, headers: { "content-type": "application/json" }, body });
  await endTurn(a, key);
  await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  const there = homeThread(b, key);
  // (its answer lost on the way, the device asks again, of the station the chat went to)
  const again = await b.admin.claimSay(viewer, `/threads/${there}/messages`, "k1", "en");
  assert.ok("kept" in again, `answered as it was here, not claimed anew: ${JSON.stringify(again)}`);
  assert.deepEqual(JSON.parse(String(again.kept.body)), JSON.parse(String(body)));
  assert.equal(entries(b, there).filter((e) => e === "person:only once").length, 1, entries(b, there).join("\n"));
  // (a new message by that way to the chat here, where it went from: answered where it went, never written here)
  const here = await a.admin.claimSay(viewer, `/threads/${thread}/messages`, "k2", "en");
  assert.ok("refused" in here && here.refused.status === 409, `answered where it went: ${JSON.stringify(here)}`);
  assert.equal(JSON.parse(String(here.refused.body)).moved?.station, B, "pointed at the station it went to");
});

/// Every write a device makes to a chat (api/routes/marks.ts, a message: routes/hub.ts), as it asks it.
const WRITES = (thread: number, key: string): [string, string, Json?][] => [
  ["PUT", `/threads/${thread}/read`, { n: 1 }], ["PUT", `/threads/${thread}/hidden`, { hidden: true }], ["PUT", `/threads/${thread}/muted`, { muted: true }],
  ["PUT", `/threads/${thread}/keep`], ["DELETE", `/threads/${thread}/keep`], ["PUT", `/threads/${thread}/title`, { title: "Named" }],
  ["PUT", `/threads/${thread}/dismissed`, { n: 1 }], ["PUT", `/sessions/${key}/pin`], ["DELETE", `/sessions/${key}/pin`], ["POST", `/sessions/${key}/title`, { title: "Named" }],
];

test("a write to a chat handed to another station is answered where it went (409 `moved`) on every write route, a message too; before it went written; a read of it, and a write to one still coming, not there (404)", async () => {
  const w = world();
  const a = w.get(A);
  // (its turn ended: stillfailChat's)
  const { key, thread } = await stillfailChat(a);
  const viewer = { sub: "p", email: "p@x", name: "P", role: "member", workspace: WS, device: "d" } as Json;
  const ask = (method: string, path: string, body?: Json) =>
    a.admin.handle({ method, path, query: [], headers: {}, body: Buffer.from(body === undefined ? "" : JSON.stringify(body)), viewer, lang: "en" } as Request);
  const said = (x: { body: unknown }) => { try { return JSON.parse(String(x.body)); } catch { return String(x.body); } };
  // Before it went: each written here (a card to dismiss there is none: refused for that, not as a chat not there).
  for (const [method, path, body] of WRITES(thread, key)) {
    const r = await ask(method, path, body);
    assert.ok(r.status !== 409 && !/unknown (session|thread)/.test(JSON.stringify(said(r))), `${method} ${path} before it went: ${r.status} ${JSON.stringify(said(r))}`);
  }
  await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  assert.ok(a.rig.store.sessionWs(key)?.startsWith("handed:"), "gone from here");
  const there = homeThread(w.get(B), key);
  for (const [method, path, body] of [...WRITES(thread, key), ["POST", `/threads/${thread}/messages`, { text: "after" }] as [string, string, Json]]) {
    const r = await ask(method, path, body);
    assert.equal(r.status, 409, `${method} ${path} after it went: ${JSON.stringify(said(r))}`);
    assert.deepEqual(said(r).moved, { session: key, station: B, thread, there }, `${method} ${path}: pointed where it went`);
  }
  assert.ok(!entries(a, thread).includes("person:after"), "the message not written here");
  // A read of it stays not there; so does a write from a member of another workspace.
  for (const path of [`/threads/${thread}`, `/sessions/${key}`]) assert.equal((await ask("GET", path)).status, 404, `GET ${path}`);
  const other = await a.admin.handle({ method: "PUT", path: `/sessions/${key}/pin`, query: [], headers: {}, body: Buffer.alloc(0), viewer: { ...viewer, workspace: "elsewhere", home: false }, lang: "en" } as Request);
  assert.equal(other.status, 404, "another workspace's member is told nothing of where it went");
  // One still coming here (not shown yet): not there.
  a.rig.store.insertSession({ key: "arriving", connect: "chat", runtime: "claude", profile: "cc", workspace: "/w", token: "t-arriving", createdAt: 1, lastActiveAt: 1, ws: `coming:${WS}` } as Json);
  assert.equal((await ask("PUT", "/sessions/arriving/pin")).status, 404, "one still coming");
});

test("a person moves a chat with POST /move and back with POST /move/back: a member is refused, a second while one runs is 409, GET /move shows it there with the last outcome", async () => {
  const w = world();
  const a = w.get(A);
  const { key } = await stillfailChat(a);
  const member = await a.ask("POST", "/move", { to: B, module: "chats", item: key }, "member");
  assert.equal(member.status, 403);
  assert.match(member.body.error, /owner or admin/);
  const first = await a.ask("POST", "/move", { to: B, module: "chats", item: key });
  assert.deepEqual(first, { status: 202, body: { started: true } });
  const second = await a.ask("POST", "/move", { to: B, module: "chats", item: key });
  assert.equal(second.status, 409);
  assert.match(second.body.error, /Another move is under way/);
  await a.moves.scheduler.settle();
  await w.quiet();
  assert.equal(a.rig.store.handedTo(key)?.station, B);
  const view = await a.ask("GET", "/move", null, "member", [["to", B]]);
  assert.equal(view.status, 200);
  assert.equal(view.body.modules.find((m: Json) => m.id === "chats").items.find((x: Json) => x.id === key).state, "there");
  assert.deepEqual({ ...view.body.last, at: 0 }, { at: 0, by: "owner@x", how: "move", station: B, done: [`chats ${key}`], refused: [], stopped: [], resumed: [], failed: null });
  const back = await a.ask("POST", "/move/back", { from: B, module: "chats", item: key });
  assert.equal(back.status, 202);
  await a.moves.scheduler.settle();
  await w.quiet();
  assert.equal(a.rig.store.handedTo(key), null);
  assert.equal(a.rig.hub.handedOver(key), false);
  const after = await a.ask("GET", "/move", null, "owner", [["to", B]]);
  assert.equal(after.body.last.how, "back");
  assert.deepEqual(after.body.last.done, [`chats ${key}`]);
});

test("moving switched off here refuses POST /move, POST /move/back and station_move, holding nothing; on here and off there refuses before the chat is held", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  const asks = new MoveAsks({ data: a.rig.dir, scheduler: a.moves.scheduler, here: () => A, wsOf: () => WS, roster: () => [{ id: A, name: "A" }, { id: B, name: "B" }], cards: { post: async () => null }, notify: () => {}, refusal: (ws, s) => a.moves.refusal(ws, s) });
  const held: string[] = [];
  const hold = a.rig.hub.holdChat.bind(a.rig.hub);
  a.rig.hub.holdChat = ((k: string, why: string) => (held.push(k), hold(k, why))) as typeof a.rig.hub.holdChat;
  a.on = false;
  const off = /not open on this station yet|这台 station 还没开放/;
  const moved = await a.ask("POST", "/move", { to: B, module: "chats", item: key });
  assert.equal(moved.status, 409);
  assert.match(moved.body.error, off);
  const backed = await a.ask("POST", "/move/back", { from: B, module: "chats", item: key });
  assert.equal(backed.status, 409);
  assert.match(backed.body.error, off);
  await assert.rejects(asks.toolIn(WS, key, { action: "move", to: "B", module: "chats", item: key }), off);
  await assert.rejects(asks.toolIn(WS, key, { action: "back", to: "B", module: "chats", item: key }), off);
  await assert.rejects(asks.toolIn(WS, key, { action: "move", to: "B", all: true }), off);
  // (and the scheduler itself, as a card's confirmation reaches it)
  await assert.rejects(a.moves.scheduler.move(WS, B, { module: "chats", item: key }), off);
  // Read-only, the plan still answers.
  assert.equal((await a.ask("GET", "/move", null, "owner", [["to", B]])).status, 200);
  // On here, off there: refused naming that station, before anything is held or sent.
  a.on = true;
  b.on = false;
  const there = await a.ask("POST", "/move", { to: B, module: "chats", item: key });
  assert.equal(there.status, 409);
  assert.match(there.body.error, /not open on station “B” yet/);
  const offThere = /not open on station “B” yet|station「B」还没开放/;
  await assert.rejects(a.moves.scheduler.move(WS, B, { module: "chats", item: key }), offThere);
  // (a station that asks it directly is refused by it too)
  await assert.rejects(a.bus.ask(B, { method: "handover.begin", keys: [key], ws: WS, id: "x" }), offThere);
  await w.quiet();
  assert.deepEqual(held, [], "never held");
  assert.equal(a.rig.hub.chatHeld(key), null);
  assert.equal(a.rig.store.handedTo(key), null);
  assert.equal(b.rig.store.getSession(key), null, "nothing of it there");
  assert.match(a.moves.scheduler.last(WS)!.failed!.error, offThere);
  // Not reached at all: said to be out of reach, not to have moving switched off.
  b.on = true;
  b.up = false;
  const away = await a.ask("POST", "/move/back", { from: B, module: "chats", item: key });
  assert.equal(away.status, 409);
  assert.match(away.body.error, /Station “B” cannot be reached now: nothing was moved/);
  await assert.rejects(a.moves.scheduler.move(WS, B, { module: "chats", item: key }), /cannot be reached now|现在连不上/);
});

/// What a device reads of chat `key`'s page on `st` (its thread `thread` there), through the station's readers as it
/// serves them: the session, its timeline, the thread, its entries after the first; each answered or why not.
async function pageReads(st: Station, key: string, thread: number): Promise<string[]> {
  const viewer = { sub: "u", email: "p@x", name: "P", role: "owner", workspace: WS, device: "d", home: true } as Json;
  const readers = new Readers(st.rig.dir, 1);
  const out: string[] = [];
  const one = async (what: string, path: string, op: string, args: Json) => {
    const no = elsewhere(st.rig.store, path, viewer);
    if (no !== null) return void out.push(`${what}: ${no}`);
    out.push(await readers.read(op, args, "en").then(() => `${what}: ok`, (e: Error) => `${what}: ${e.message}`));
  };
  try {
    await one("session", `/sessions/${key}`, "session", { key, viewer, lang: "en", turns: null, jobs: null });
    await one("timeline", `/sessions/${key}/timeline`, "timeline", { key, before: undefined, limit: "50", lang: "en" });
    await one("thread", `/threads/${thread}`, "thread", { id: String(thread), viewer, lang: "en" });
    await one("entries", `/threads/${thread}/entries`, "entries", { viewer, thread, params: [["after", "1"], ["limit", "50"]] });
  } finally {
    await readers.close();
  }
  return out;
}

test("a device is told a chat moved only once the station it went to shows it: until then the station it left serves its page as it went and takes what is sent, which goes after it; told, the page there is read from the first ask (a fresh chat, over a retired copy, the station it left started again in between, the other not reached for a while)", async () => {
  for (const how of ["fresh", "leftover", "a-restart", "b-down"] as const) {
    const w = world();
    const a = w.get(A);
    const b = w.get(B);
    const { key, thread } = await stillfailChat(a);
    if (how === "leftover") retiredCopy(a, b, key);
    const ok = ["session: ok", "timeline: ok", "thread: ok", "entries: ok"];
    // Each time a device is told it moved: what a device reading it there would be answered then.
    const told: string[] = [];
    const viewer = { sub: "u", email: "p@x", name: "P", role: "owner", workspace: WS, device: "d", home: true } as Json;
    const off = a.rig.store.subscribe((c) => {
      if (c.type !== "moved" || c.key !== key) return;
      const there = b.rig.store.homeChat(key)?.id ?? -1;
      told.push(`${elsewhere(b.rig.store, `/sessions/${key}`, viewer) ?? "session seen"} | ${elsewhere(b.rig.store, `/threads/${there}/entries`, viewer) ?? "thread seen"}`);
    });
    // A message taken here as the show is on its way there, after the chat's rows last went: it goes after them.
    let atShow = false;
    w.tamper((to, r) => {
      if (to === B && r.method === "handover.show" && !atShow) (atShow = true), say(a.rig.hub, thread, "p@x", "said as it was shown");
      return r;
    });
    // The show held back: refused once (or the other not reached until let up).
    a.onFail = (step) => {
      if (step !== "show") return;
      a.onFail = null;
      if (how === "b-down" || how === "a-restart") b.up = false;
      else throw new Error("the show held back");
    };
    const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
    await w.quiet();
    assert.equal(out.failed, null, `${how}: ${JSON.stringify(out)}`);
    // (a device told it moved reads it there at once: what that would be answered)
    for (const t of told) assert.equal(t, "session seen | thread seen", `${how}: told it moved while there it is not to be read`);
    assert.deepEqual(told, [], `${how}: no device told it moved before it is shown there`);
    assert.equal(a.rig.store.handedTo(key)?.station, B, `${how}: where it went kept`);
    assert.deepEqual(await pageReads(a, key, thread), ok, `${how}: its page here as it went`);
    say(a.rig.hub, thread, "p@x", "said in between");
    await w.quiet();
    assert.equal(a.rig.claude.count(), 1, `${how}: no turn here`);
    if (how === "a-restart") {
      await a.moves.close();
      a.moves = a.make();
      await a.moves.start();
      await w.quiet();
      assert.deepEqual(told, [], `${how}: still not told`);
      assert.notEqual(a.rig.hub.chatHeld(key), null, `${how}: still held here`);
      assert.deepEqual(await pageReads(a, key, thread), ok, `${how}: its page here still`);
      b.up = true;
    }
    if (how === "b-down") {
      await w.t.adjust(RETRY_MS);
      await w.quiet();
      assert.deepEqual(told, [], `${how}: not told while it is not reached`);
      assert.deepEqual(await pageReads(a, key, thread), ok, `${how}: its page here meanwhile`);
      b.up = true;
    }
    await w.t.adjust(RETRY_MS * 4);
    await w.quiet();
    off();
    assert.equal(told.length, 1, `${how}: told once: ${JSON.stringify(told)}`);
    assert.equal(told[0], "session seen | thread seen", `${how}: read there from the first ask`);
    const there = homeThread(b, key);
    assert.deepEqual(await pageReads(b, key, there), ok, `${how}: its page there`);
    assert.equal(entries(b, there).filter((e) => e === "person:said in between").length, 1, `${how}: what was sent in between there once`);
    assert.ok(b.rig.claude.sessions.flatMap((x) => x.prompts).join("\n").includes("said in between"), `${how}: and handed to its agent there`);
    assert.ok(atShow, how);
    assert.equal(entries(b, there).filter((e) => e === "person:said as it was shown").length, 1, `${how}: what was taken as it was shown there once`);
    assert.ok(b.rig.claude.sessions.flatMap((x) => [...x.prompts, ...x.steers]).join("\n").includes("said as it was shown"), `${how}: and handed to its agent there`);
    assert.equal(a.rig.hub.chatHeld(key), null, `${how}: let go here`);
    assert.equal(a.rig.claude.count(), 1, `${how}: never a turn here`);
  }
});

test("the move page read while a turn runs answers from the turn's own plan: a chat gone there, the one moving, the module's count kept as each ends; after the turn's end, planned anew", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const first = await stillfailChat(a);
  const second = await stillfailChat(a);
  // (the second chat's files held as they are placed there: the first gone by then)
  const gate = Promise.withResolvers<void>();
  const at = Promise.withResolvers<void>();
  let placings = 0;
  b.placing = async () => {
    if (++placings < 3) return;
    at.resolve();
    await gate.promise;
  };
  const turn = a.moves.scheduler.move(WS, B, { module: "chats" });
  await at.promise;
  const page = async () => (await a.ask("GET", "/move", null, "owner", [["to", B], ["module", "chats"], ["limit", "50"]])).body.modules.find((m: Json) => m.id === "chats");
  const during = await page();
  const row = (v: Json, k: string) => v.items.find((x: Json) => x.id === k);
  const [gone, moving] = a.rig.store.handedTo(first.key) !== null ? [first.key, second.key] : [second.key, first.key];
  assert.equal(row(during, gone)?.state, "there", "the chat gone: there, as it is now");
  assert.equal(row(during, moving)?.state, "moving", "the one under way: moving");
  assert.equal(during.done, 1, "its module's count: one there, kept as it ended");
  b.placing = undefined;
  gate.resolve();
  assert.equal((await turn).failed, null);
  await w.quiet();
  // (at rest: planned anew, a chat made since listed)
  const third = await stillfailChat(a);
  const after = await page();
  assert.equal(row(after, third.key)?.state, "here", "a chat made after the turn's end is on the page");
  assert.equal(after.done, 2);
});

test("a plan with no station named (the station page's own row) asks nothing of anyone and says nothing of the other side", async () => {
  const w = world();
  const a = w.get(A);
  await stillfailChat(a);
  const asked: string[] = [];
  const ask = a.bus.ask.bind(a.bus);
  a.bus.ask = ((station: string, r: Json) => (asked.push(`${station || "nobody"} ${r?.method}`), ask(station, r))) as typeof a.bus.ask;
  const plan = await a.moves.scheduler.plan(WS, "");
  assert.deepEqual(asked, [], "nothing asked of anyone");
  assert.deepEqual(plan.items.filter((x) => x.again === true).map((x) => x.id), [], "nothing said not answered");
});

test("a chat asked to move by any of its sessions (a chat's menu names its own) goes whole; while it goes, what moves says it with each of its sessions, where to and whether it is held yet (the overview's move.chats, a device's composer shut), and nothing once it is there", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const first = message({ text: "<@UBOT> one" });
  await a.connects.receive("cl", { type: "message", message: first });
  await a.connects.receive("gpt", { type: "message", message: first });
  const cl = sessionKey("cl", first.channel, first.threadTs);
  const gpt = sessionKey("gpt", first.channel, first.threadTs);
  await endTurn(a, cl);
  await endTurn(a, gpt, "codex");
  const both = [cl, gpt].sort();
  assert.deepEqual(a.moves.handover.moving(), [], "nothing moves yet");
  // (what moves, as each step of it is held: the first pass's files, then the hold)
  const seen: Json[] = [];
  const hold = a.rig.hub.holdChat.bind(a.rig.hub);
  a.rig.hub.holdChat = ((k: string, why: string, n?: () => string) => (seen.push(a.moves.handover.moving()), hold(k, why, n))) as typeof a.rig.hub.holdChat;
  // (asked by the one of its sessions the plan does not list it by)
  const asked = both[1]!;
  const started = await a.ask("POST", "/move", { to: B, module: "chats", item: asked });
  assert.deepEqual(started, { status: 202, body: { started: true } });
  await a.moves.scheduler.settle();
  await w.quiet();
  assert.equal(a.rig.store.handedTo(cl)?.station, B);
  assert.equal(a.rig.store.handedTo(gpt)?.station, B);
  assert.ok(b.rig.store.getSession(asked) !== null, "there");
  assert.ok(seen.length > 0, "held on its way");
  assert.deepEqual(seen[0], [{ sessions: both, ws: WS, to: B, toName: "B", held: false }], "said as it is held: its sessions, where it goes");
  assert.deepEqual(a.moves.handover.moving(), [], "nothing once it is there");
});
