// `task.list` (station_task action list): a session's tasks on a station are all its history there, and the answer goes
// back to the source as one line its peer reads at most `MAX_MESSAGE` (1 MiB) of. Listing them whole, long commands and
// all, a session's list failed for good with "head too large" (FB-40): it is bounded, the running and queued first.
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { Jobs } from "../src/jobs/jobs.ts";
import { Remote, hash } from "../src/jobs/remote.ts";
import type { Stream } from "../src/mesh/endpoint.ts";
import { Reader } from "../src/mesh/wire.ts";
import { type Json, Store } from "../src/store/store.ts";

const MAX_MESSAGE = 1024 * 1024; // mesh/peer.ts's
const BOUND = 256 * 1024;

const cleanup: (() => Promise<void> | void)[] = [];
after(async () => {
  for (const c of cleanup.reverse()) await c();
});

function station() {
  const dir = mkdtempSync(join(tmpdir(), "task-list-bounded-"));
  const store = Store.open(":memory:");
  const jobs = new Jobs({ store, data: dir, notify: () => {}, link: () => null });
  const remote = new Remote({ data: dir, store, jobs, notify: () => {}, version: "0.1.1" });
  cleanup.push(async () => {
    await remote.close();
    await jobs.shutdown();
    store.close();
    rmSync(dir, { recursive: true, force: true });
  });
  return { store, remote };
}

/// The answer's line as the source reads it off the peer's stream (peer.ts: `new Reader(stream, MAX_MESSAGE)`).
async function overWire(answer: Json): Promise<Json> {
  const line = Buffer.from(JSON.stringify({ result: answer }) + "\n");
  let at = 0;
  const stream = { read: async () => at >= line.length ? null : line.subarray(at, (at += 64 * 1024)) } as unknown as Stream;
  return (await new Reader(stream, MAX_MESSAGE).line()).result;
}

// A command of 16 KiB, half of it Chinese (three bytes a character), so that a clip could land inside a character.
const command = (i: number) => `echo ${i} ` + "构建并运行测试".repeat(400) + "x".repeat(8000);

test("a session's task list stays within a peer's message, its running and queued tasks first", async () => {
  const { store, remote } = station();
  const incoming = join(remote.root, "incoming");
  const keys: string[] = [];
  for (let i = 0; i < 150; i++) {
    const key = `k${String(i).padStart(3, "0")}`;
    keys.push(key);
    const dir = join(incoming, hash(["ws", "peer-a", "s", key]));
    mkdirSync(dir, { recursive: true });
    const back = Array.from({ length: 40 }, (_, j) => `out/${"目录".repeat(100)}/${j}.log`);
    writeFileSync(join(dir, "task.json"), JSON.stringify({ workspace: "ws", station: "peer-a", session: "s", key, layout: "session", spec: { name: key, command: command(i), back } }));
    if (i === 149) continue; // prepared, never started
    // The oldest ones run (two) and wait in the queue (two); the others ended, the later the newer.
    const running = i === 3 || i === 7, queued = i === 5 || i === 9;
    store.insertJob({ id: `remote_${hash(["ws", "peer-a", "s", key])}`, sessionKey: "remote", name: key, command: command(i), cwd: "/",
      port: null, token: key, state: running || queued ? "running" : "exited", pgid: null, exitCode: running || queued ? null : 0,
      startedAt: 1000 + i, endedAt: running || queued ? null : 5000 + i, restarts: 0, log: "/dev/null", watch: false, queued });
  }
  const raw = JSON.stringify((await remote.handle("ws", "peer-a", { method: "task.list", session: "s" })));
  assert.ok(Buffer.byteLength(raw) > 0);
  const answer = await overWire(JSON.parse(raw));
  assert.ok(Buffer.byteLength(raw) < BOUND, `the list is ${Buffer.byteLength(raw)} bytes`);
  assert.equal(answer.total, 150);
  assert.equal(answer.truncated, true);
  assert.match(answer.note, /action get/);
  const listed = answer.tasks.map((t: Json) => t.key);
  assert.ok(listed.length > 10 && listed.length <= 100, `${listed.length} listed`);
  assert.deepEqual(listed.slice(0, 6), ["k007", "k003", "k009", "k005", "k148", "k147"], "running, then queued, then the latest");
  for (const t of answer.tasks) {
    for (const text of [t.spec.command, t.job?.command, t.spec.back[0]]) {
      if (text === undefined) continue;
      assert.ok(Buffer.byteLength(text) <= 256 + 3, "clipped to 256 bytes and an ellipsis");
      assert.ok(text.endsWith("…"));
      assert.ok(!text.includes("�"), "never half a character");
      assert.equal(Buffer.from(text, "utf8").toString("utf8"), text);
    }
    assert.equal(t.spec.back.length, 16);
    assert.equal(t.spec.backMore, 24);
  }
  assert.ok(command(7).startsWith(answer.tasks[0].spec.command.slice(0, -1)));

  // The whole of a task is still said by `task.get`.
  const one = await remote.handle("ws", "peer-a", { method: "task.get", session: "s", key: "k007" });
  assert.equal(one.job.command, command(7));

  // No tasks, as before.
  assert.deepEqual(await remote.handle("ws", "peer-a", { method: "task.list", session: "other" }), { tasks: [], total: 0 });
  // Few short ones: listed whole, none left out, nothing noted.
  const few = await remote.handle("ws", "peer-b", { method: "task.prepare", session: "s", key: "short", spec: { command: "true" } });
  assert.equal(few.prepared, true);
  assert.deepEqual(await remote.handle("ws", "peer-b", { method: "task.list", session: "s" }), { tasks: [{ key: "short", spec: { command: "true" }, job: null }], total: 1 });
});
