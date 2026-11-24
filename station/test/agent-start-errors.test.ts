// What made sessions fail to start on 2026-11-16, and what they lost doing so: a conversation left for a new one when
// resuming it failed for the network or a borrowing (tokyo-mac-studio-0, as the machine came up), the MoonBit actor's
// errors said as their types' names ("station/wire.ShellError.ShellError", Office-VM-1), and a turn a restart cut off
// left running for ever where its recovery failed.
import assert from "node:assert/strict";
import { test } from "node:test";
import { hearLines, type Line } from "../src/ops/log.ts";
import { Said } from "../src/ops/i18n.ts";
import { isNonSessionOpenError } from "../src/sessions/actor.ts";
import { sessionKey } from "../src/sessions/hub.ts";
import { Store } from "../src/store/store.ts";
import { FakeDriver, Rig, message, reply, settle } from "./hub-fakes.ts";

test("what keeps a conversation when resuming it fails: the station's words, the network, the account, a limit; not a conversation the runtime lost", () => {
  assert.equal(isNonSessionOpenError(new Said("未能借出")), true);
  assert.equal(isNonSessionOpenError(new Error("connection failed")), true);
  assert.equal(isNonSessionOpenError(new Error("Antigravity CLI could not load its model catalog: connection failed")), true);
  assert.equal(isNonSessionOpenError(new Error("Authentication required")), true);
  assert.equal(isNonSessionOpenError(Object.assign(new Error("agy"), { missing: true })), true);
  assert.equal(isNonSessionOpenError(new Error("no such session")), false);
  assert.equal(isNonSessionOpenError(new Error("trajectory not found")), false);
  assert.equal(isNonSessionOpenError(null), false);
});

for (const [what, error] of [
  ["the network", () => new Error("connection failed")],
  ["a borrowed sign-in not lent", () => new Said("未能借出这个账号的登录")],
] as const) {
  test(`resuming a conversation that fails for ${what} keeps it: no new one opened, resumed as it was once that passes`, async () => {
    const r = new Rig();
    const m = message();
    await r.accept(m);
    await settle();
    const key = sessionKey("cl", "C1", m.threadTs);
    const old = r.claude.last();
    old.end({ kind: "failed", reason: "exited", message: "gone" });
    old.events({ type: "closed", why: "gone" });
    await settle();
    assert.equal(r.session(key).runtimeSessionId, old.sessionId);
    r.claude.resumeFailsOnce.set(old.sessionId, error());
    await r.accept(reply(m, "9999.4", "still there?"));
    await settle();
    assert.equal(r.claude.count(), 1, "no new conversation opened in its place");
    assert.equal(r.session(key).runtimeSessionId, old.sessionId, "the conversation is still the session's");
    await r.accept(reply(m, "9999.5", "and now?"));
    await settle();
    const now = r.claude.last();
    assert.notEqual(now, old);
    assert.equal(now.options.resume, old.sessionId, "resumed where it was");
    assert.ok(!now.prompts.some((p) => p.includes("could not be restored")), JSON.stringify(now.prompts));
    assert.equal(r.session(key).runtimeSessionId, old.sessionId);
    await r.close();
  });
}

test("a conversation the runtime cannot resume (gone from its store) is still left for a new one", async () => {
  const r = new Rig();
  const m = message();
  await r.accept(m);
  await settle();
  const old = r.claude.last();
  old.end({ kind: "failed", reason: "exited", message: "gone" });
  old.events({ type: "closed", why: "gone" });
  await settle();
  r.claude.unresumable.add(old.sessionId);
  await r.accept(reply(m, "9999.4", "still there?"));
  await settle();
  assert.equal(r.claude.last().options.resume, undefined);
  assert.equal(r.session(sessionKey("cl", "C1", m.threadTs)).runtimeSessionId, r.claude.last().sessionId);
  await r.close();
});

test("the database's error is said in its words where an agent could not start, not as the MoonBit error's type", async () => {
  const r = new Rig();
  // As a write held too long by the station's main thread fails it (Office-VM-1, 2026-11-16).
  r.store.db.exec("CREATE TRIGGER held BEFORE INSERT ON turns BEGIN SELECT RAISE(ABORT, 'database is locked'); END");
  await r.accept(message());
  await settle();
  const said = r.chat.texts().join("\n");
  assert.match(said, /database is locked/);
  assert.doesNotMatch(said, /station\/wire\.ShellError|ShellError/);
  await r.close();
});

test("what Node answered a prompt with, failing, is logged in its words, not as the MoonBit error's type", async () => {
  const lines: Line[] = [];
  hearLines((l) => lines.push(l));
  try {
    const r = new Rig();
    const m = message();
    await r.accept(m);
    await settle();
    const first = r.claude.last();
    await r.call(sessionKey("cl", "C1", m.threadTs), "chat_post", { to: `C1/${m.threadTs}`, text: "done", kind: "final" });
    first.complete();
    await settle();
    // Its process gone under it (the actor not told): the next prompt fails in Node, and the runtime is opened again.
    first.disposed = true;
    await r.accept(reply(m, "9999.4", "again"));
    await settle();
    const failed = lines.find((l) => l.message === "prompt failed, reopening the runtime");
    assert.ok(failed, JSON.stringify(lines.map((l) => l.message)));
    assert.equal(failed.fields?.error, "disposed");
    assert.ok(!lines.some((l) => JSON.stringify(l.fields ?? {}).includes("station/reader.Asked")));
    assert.ok(r.claude.last().prompts.some((p) => p.includes("again")));
    await r.close();
  } finally {
    hearLines(() => {});
  }
});

test("a turn its runtime began of its own as a prompt was given: the prompt steered into it, its process kept", async () => {
  const lines: Line[] = [];
  hearLines((l) => lines.push(l));
  try {
    const r = new Rig();
    const m = message();
    await r.accept(m);
    await settle();
    const first = r.claude.last();
    await r.call(sessionKey("cl", "C1", m.threadTs), "chat_post", { to: `C1/${m.threadTs}`, text: "done", kind: "final" });
    first.complete();
    await settle();
    // Idle as the next message comes; busy with a turn of its own by the time it is prompted.
    first.startsOwnTurn = true;
    await r.accept(reply(m, "9999.4", "again"));
    await settle();
    assert.ok(!lines.some((l) => l.message === "prompt failed, reopening the runtime"), JSON.stringify(lines.map((l) => l.message)));
    assert.equal(first.disposed, false);
    assert.equal(r.claude.last(), first, "no runtime opened again");
    assert.ok(first.steers.some((t) => t.includes("again")), JSON.stringify(first.steers));
    // Its own turn ends as the turn begun for the message: the session is idle after it.
    await r.call(sessionKey("cl", "C1", m.threadTs), "chat_post", { to: `C1/${m.threadTs}`, text: "done again", kind: "final" });
    first.complete();
    await settle();
    assert.equal(r.store.getSession(sessionKey("cl", "C1", m.threadTs))!.running, false);
    await r.close();
  } finally {
    hearLines(() => {});
  }
});

test("what a turn is prompted with is delivered before the prompt is written: a post the runtime makes at once is not held", async () => {
  // check-station on 2026-11-19: an agent posted `all_done` on reading its first message before the prompt's answer
  // came back, the message still undelivered then, and the post was held as one written before it was read.
  const r = new Rig();
  const m = message();
  const key = sessionKey("cl", "C1", m.threadTs);
  const waiting: string[][] = [];
  r.claude.beforePrompt = () => void waiting.push(r.store.pendingMessages(key).map((p) => p.message.text));
  await r.accept(m);
  await settle();
  assert.equal(r.claude.last().prompts.length, 1);
  assert.deepEqual(waiting, [[]], "nothing waits as it is prompted");
  await r.close();
});

test("a prompt that fails as its runtime is opened again leaves what it was handed waiting, to be handed again", async () => {
  const r = new Rig();
  const m = message();
  const key = sessionKey("cl", "C1", m.threadTs);
  await r.accept(m);
  await settle();
  const first = r.claude.last();
  await r.call(key, "chat_post", { to: `C1/${m.threadTs}`, text: "done", kind: "final" });
  first.complete();
  await settle();
  const refused = () => {
    throw new Error("refused");
  };
  first.beforePrompt = refused;
  r.claude.beforePrompt = refused;
  await r.accept(reply(m, "9999.4", "again"));
  await settle();
  assert.equal(r.claude.count(), 2, "its runtime opened again");
  assert.deepEqual(r.store.pendingMessages(key).map((p) => p.message.text), ["again"]);
  await r.close();
});

/// A turn running as the station stopped with no runner keeping its process (a crash, the machine restarted).
async function cutOff(declare?: (r: Rig, key: string) => Promise<unknown>) {
  const r = new Rig();
  const m = message();
  await r.accept(m);
  await settle();
  const key = sessionKey("cl", "C1", m.threadTs);
  if (declare) await declare(r, key);
  await r.hub.shutdown();
  const cut = r.store.listTurns(key).at(-1)!;
  assert.equal(cut.summary.endedAt, null, "left running by the station that stopped");
  return { r, m, key, cut };
}

test("after a non-update restart, the turn it cut off is ended as aborted and awaits manual resume", async () => {
  const { r, key, cut } = await cutOff();
  const claude = new FakeDriver("claude");
  r.hub = r.newHub({ chats: (id) => (id === "cl" ? r.chat : undefined), drivers: [claude, new FakeDriver("codex")], internal: false });
  await r.hub.takeUp();
  r.hub.recover();
  await settle();
  // Non-update restart does not auto-spawn the runtime process
  assert.equal(claude.count(), 0);
  const turns = r.store.listTurns(key);
  const ended = turns.find((t) => t.id === cut.id)!.summary;
  assert.deepEqual([ended.outcome, ended.detail, ended.declared], ["aborted", "other: cut off by restart", null]);
  assert.notEqual(ended.endedAt, null);
  assert.equal(turns.filter((t) => t.summary.endedAt === null).length, 0, "no turn left running");
  const interrupted = r.hub.interruptedIn({ workspace: "", home: true });
  assert.equal(interrupted.count, 1);
  assert.equal(interrupted.items[0]!.key, key);
  assert.ok(r.chat.posts.some((p) => p[1].includes("station 重启导致本轮中断")));
  // Batch resume starts the session with RESUME_AFTER_RESTART and clears interruptedIn
  assert.equal(r.hub.resumeInterrupted({ workspace: "", home: true }), 1);
  await settle();
  assert.equal(r.hub.interruptedIn({ workspace: "", home: true }).count, 0);
  assert.ok(claude.last().prompts[0]!.includes("restarted while you were in the middle of a turn"));
  await r.close();
});

test("after a non-update restart, an interrupted chat is listed under the title its agent gave it", async () => {
  const { r, key } = await cutOff();
  const thread = r.store.latestThread(key)!.thread.id;
  r.store.setAutoTitle(thread, "字体设置细化方案设计", false);
  r.hub = r.newHub({ chats: (id) => (id === "cl" ? r.chat : undefined), drivers: [new FakeDriver("claude"), new FakeDriver("codex")], internal: false });
  await r.hub.takeUp();
  r.hub.recover();
  await settle();
  const interrupted = r.hub.interruptedIn({ workspace: "", home: true });
  assert.deepEqual(interrupted.items.map((i) => i.title), ["字体设置细化方案设计"]);
  await r.close();
});

test("after a non-update restart, single-chat retryFailed resumes with RESUME_AFTER_RESTART and clears interrupted list", async () => {
  const { r, key } = await cutOff();
  const claude = new FakeDriver("claude");
  r.hub = r.newHub({ chats: (id) => (id === "cl" ? r.chat : undefined), drivers: [claude, new FakeDriver("codex")], internal: false });
  await r.hub.takeUp();
  r.hub.recover();
  await settle();
  assert.equal(claude.count(), 0);
  assert.equal(r.hub.interruptedIn({ workspace: "", home: true }).count, 1);
  const last = r.store.lastTurn(key)!;
  assert.ok(last.about !== null, "cut-off turn about points to the restart notice");
  await r.hub.retryFailed(key, last.about!.thread, last.about!.seq);
  await settle();
  assert.ok(claude.last().prompts[0]!.includes("restarted while you were in the middle of a turn"));
  assert.equal(r.hub.interruptedIn({ workspace: "", home: true }).count, 0);
  await r.close();
});

test("after a non-update restart, dismissInterrupted clears the interrupted list without starting agents", async () => {
  const { r } = await cutOff();
  const claude = new FakeDriver("claude");
  r.hub = r.newHub({ chats: (id) => (id === "cl" ? r.chat : undefined), drivers: [claude, new FakeDriver("codex")], internal: false });
  await r.hub.takeUp();
  r.hub.recover();
  await settle();
  assert.equal(r.hub.interruptedIn({ workspace: "", home: true }).count, 1);
  assert.equal(r.hub.dismissInterrupted({ workspace: "", home: true }), 1);
  assert.equal(r.hub.interruptedIn({ workspace: "", home: true }).count, 0);
  assert.equal(claude.count(), 0);
  await r.close();
});

test("after a non-update restart, pending user messages deliver directly without an interrupted notice", async () => {
  const { r, m } = await cutOff();
  const claude = new FakeDriver("claude");
  r.hub = r.newHub({ chats: (id) => (id === "cl" ? r.chat : undefined), drivers: [claude, new FakeDriver("codex")], internal: false });
  await r.hub.takeUp();
  // User sends a new message while station was down / before recover
  await r.hub.accept("cl", { ...m, ts: "1700000009.000100", text: "继续吧" });
  r.hub.recover();
  await settle();
  assert.equal(r.hub.interruptedIn({ workspace: "", home: true }).count, 0);
  assert.ok(!r.chat.posts.some((p) => p[1].includes("station 重启导致本轮中断")));
  assert.ok(claude.last().prompts[0]!.includes("继续吧"));
  await r.close();
});

test("after a restart whose recovery cannot start an agent, the turn it cut off is ended all the same", async () => {
  const { r, key, cut } = await cutOff();
  const claude = new FakeDriver("claude");
  claude.refuses = "spawn claude ENOMEM";
  r.hub = r.newHub({ chats: (id) => (id === "cl" ? r.chat : undefined), drivers: [claude, new FakeDriver("codex")], internal: false });
  await r.hub.takeUp();
  r.hub.recover();
  await settle();
  assert.equal(claude.count(), 0);
  const turns = r.store.listTurns(key);
  const ended = turns.find((t) => t.id === cut.id)!.summary;
  assert.deepEqual([ended.outcome, ended.detail], ["aborted", "other: cut off by restart"]);
  assert.equal(turns.filter((t) => t.summary.endedAt === null).length, 0, "no turn left running");
  assert.equal(r.store.lastTurn(key)!.endedAt !== null, true);
  await r.close();
});

test("a turn a restart cut off keeps the state it said it ends in, but not a wait", async () => {
  const done = await cutOff((r, key) => r.call(key, "chat_state", { kind: "all_done", done: "合进 main" }));
  const claude = new FakeDriver("claude");
  done.r.hub = done.r.newHub({ chats: (id) => (id === "cl" ? done.r.chat : undefined), drivers: [claude, new FakeDriver("codex")], internal: false });
  await done.r.hub.takeUp();
  done.r.hub.recover();
  await settle();
  const ended = done.r.store.listTurns(done.key).find((t) => t.id === done.cut.id)!.summary;
  assert.deepEqual([ended.outcome, ended.ending], ["aborted", "all_done"]);
  assert.equal(done.r.hub.interruptedIn({ workspace: "", home: true }).count, 0, "declared all_done turn is not listed as interrupted");
  assert.ok(!done.r.chat.posts.some((p) => p[1].includes("station 重启导致本轮中断")));
  await done.r.close();

  // The store's own (a store in memory, as Node's is asked): a wait said is no wait once cut off.
  const store = Store.open(":memory:");
  store.insertSession({ key: "s", connect: "ds", runtime: "claude", profile: "cc", workspace: "/w/s", token: "s", createdAt: 1, lastActiveAt: 1 });
  for (const [id, declared, wait] of [["w", "waiting", 60], ["d", "all_done", null]] as const) {
    store.startTurn(id, "s", "message");
    store.declareTurn(id, declared, wait);
  }
  assert.equal(store.endCutOff("s"), 2);
  const turns = new Map(store.listTurns("s").map((t) => [t.id, t.summary]));
  assert.deepEqual([turns.get("w")!.outcome, turns.get("w")!.declared, turns.get("w")!.waitSeconds], ["aborted", null, null]);
  assert.deepEqual([turns.get("d")!.outcome, turns.get("d")!.ending], ["aborted", "all_done"]);
  assert.equal(store.endCutOff("s"), 0, "none left to end");
  store.close();
});
