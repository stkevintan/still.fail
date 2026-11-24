// What the launcher kept of what it did to recover (station/native/launcher/src/lifecycle.rs `record`), said by the
// station that comes up next (src/ops/launcher-events.ts): each event once, with only its own fields, at its level.
import assert from "node:assert/strict";
import { existsSync, mkdirSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { launcherEventOf, nodeCrashOf, recordNodeCrash, reportLauncherEvents, reportNodeCrash } from "../src/ops/launcher-events.ts";
import { tempDir } from "./temp-dir.ts";

function dataWith(lines: string[] | null): string {
  const data = tempDir(join(tmpdir(), "launcher-events-"));
  mkdirSync(join(data, "run"));
  if (lines !== null) writeFileSync(join(data, "run", "launcher-events.jsonl"), lines.join("\n") + "\n");
  return data;
}

function heard() {
  const said: { level: string; message: string; fields: Record<string, unknown> }[] = [];
  return { said, emit: (level: "error" | "warn", message: string, fields: Record<string, unknown>) => void said.push({ level, message, fields }) };
}

const HUNG = { at: 1795091426000, kind: "node_hung_killed", level: "error", pid: 4242, version: "0.1.1000", uptimeMs: 3600000, heartbeatTimeoutMs: 90000, healthAgeMs: 92000, rssBytes: 734003200, openFds: 812, heldMaxMs: 1200, front: "ok", presenceOnline: true, relayConflict: false };

test("each event is said once at its level, and the file is gone", async () => {
  const data = dataWith([JSON.stringify(HUNG), JSON.stringify({ at: 1, kind: "front_gone", level: "warn", retries: 2 })]);
  const { said, emit } = heard();
  assert.equal(await reportLauncherEvents(data, emit), 2);
  const { level: _, ...fields } = HUNG;
  assert.deepEqual(said, [
    { level: "error", message: "node_hung_killed", fields },
    { level: "warn", message: "front_gone", fields: { at: 1, kind: "front_gone", retries: 2 } },
  ]);
  assert.deepEqual(readdirSync(join(data, "run")), [], "neither the file nor the one taken is left");
  assert.equal(await reportLauncherEvents(data, emit), 0, "said once");
  assert.equal(said.length, 2);
});

test("no file: nothing said", async () => {
  const data = dataWith(null);
  const { said, emit } = heard();
  assert.equal(await reportLauncherEvents(data, emit), 0);
  assert.deepEqual(said, []);
  assert.equal(await reportLauncherEvents(join(data, "none"), emit), 0, "nor a run/ at all");
});

test("lines that are not events are passed over", async () => {
  const data = dataWith(["{\"at\":1,\"kind\":\"node_cra", "", "[1,2]", "null", "{\"at\":2}", JSON.stringify({ at: 3, kind: "handoff_failed", level: "warn", reason: "the new station exited with 1 before it was ready" })]);
  const { said, emit } = heard();
  assert.equal(await reportLauncherEvents(data, emit), 1);
  assert.deepEqual(said, [{ level: "warn", message: "handoff_failed", fields: { at: 3, kind: "handoff_failed", reason: "the new station exited with 1 before it was ready" } }]);
  assert.equal(existsSync(join(data, "run", "launcher-events.jsonl")), false);
});

test("only the launcher's own fields are said", () => {
  const event = launcherEventOf(JSON.stringify({ at: 5, kind: "node_crashed", level: "error", pid: 7, how: "was ended by signal 9", taken: true, failures: 0, home: "/Users/someone", token: "secret", nested: { a: 1 } }));
  assert.deepEqual(event, { level: "error", kind: "node_crashed", fields: { at: 5, kind: "node_crashed", pid: 7, how: "was ended by signal 9", taken: true, failures: 0 } });
});

test("hung diagnostics fields pass through while unknown fields stay filtered", () => {
  const diag = {
    ...HUNG,
    procState: "S",
    wchan: "futex_wait_queue",
    pcpu: 1.5,
    threads: 14,
    kernelStack: "futex_wait_queue+0x60/0x90 <- futex_wait+0x170/0x260",
    mainStack: "start (in dyld) -> main (in node)",
    argv: ["/Users/someone/secret"],
  };
  const event = launcherEventOf(JSON.stringify(diag));
  const { level: _, argv: _argv, ...expected } = diag;
  assert.deepEqual(event, { level: "error", kind: "node_hung_killed", fields: expected });
});

test("with no level said, a kill or a crash is an error and the rest warnings", () => {
  const level = (kind: string, said?: string) => launcherEventOf(JSON.stringify({ at: 1, kind, ...(said ? { level: said } : {}) }))?.level;
  assert.deepEqual(["node_hung_killed", "node_crashed", "front_hung_killed", "front_gone", "handoff_failed", "retiring_killed", "something_new"].map((k) => level(k)), ["error", "error", "error", "warn", "warn", "warn", "warn"]);
  assert.equal(level("front_gone", "error"), "error", "as the launcher said it");
  assert.equal(level("node_crashed", "info"), "error", "a level it does not know: by its kind");
});

// What ended a Node station by a fatal error (src/main.ts), kept as it ends and said once by the next.

function crashes() {
  const said: Record<string, unknown>[] = [];
  return { said, emit: (fields: Record<string, unknown>) => void said.push(fields) };
}

test("a crash kept is said once by the next station, and the file is gone", async () => {
  const data = dataWith(null);
  recordNodeCrash(data, { origin: "uncaughtException", error: "Error: boom\n    at x (main.js:1:1)", version: "0.1.1000", pid: 4242, at: 1795091426000 });
  const { said, emit } = crashes();
  assert.equal(await reportNodeCrash(data, emit), true);
  assert.deepEqual(said, [{ at: 1795091426000, pid: 4242, version: "0.1.1000", origin: "uncaughtException", error: "Error: boom\n    at x (main.js:1:1)" }]);
  assert.deepEqual(readdirSync(join(data, "run")), [], "neither the file nor the one taken is left");
  assert.equal(await reportNodeCrash(data, emit), false, "said once");
  assert.equal(said.length, 1);
});

test("no crash kept: nothing said", async () => {
  const data = dataWith(null);
  const { said, emit } = crashes();
  assert.equal(await reportNodeCrash(data, emit), false);
  assert.equal(await reportNodeCrash(join(data, "none"), emit), false, "nor a run/ at all");
  assert.deepEqual(said, []);
});

test("a crash is kept where run/ is not there yet, with this process's pid", async () => {
  const data = join(dataWith(null), "fresh");
  recordNodeCrash(data, { origin: "fiberExit", error: "Exit.die", version: "0.1.2" });
  const { said, emit } = crashes();
  assert.equal(await reportNodeCrash(data, emit), true);
  assert.equal(said[0]?.pid, process.pid);
  assert.equal(typeof said[0]?.at, "number");
});

test("only a crash's own fields are said", () => {
  assert.deepEqual(
    nodeCrashOf(JSON.stringify({ at: 5, pid: 7, version: "0.1.3", origin: "unhandledRejection", error: "Error: no", home: "/Users/someone", token: "secret", nested: { a: 1 } })),
    { at: 5, pid: 7, version: "0.1.3", origin: "unhandledRejection", error: "Error: no" },
  );
});

test("a long error is kept to its first 4000 characters", async () => {
  const data = dataWith(null);
  recordNodeCrash(data, { origin: "uncaughtException", error: "x".repeat(10_000), version: "0.1.4", pid: 1, at: 1 });
  const { said, emit } = crashes();
  assert.equal(await reportNodeCrash(data, emit), true);
  assert.equal((said[0]?.error as string).length, 4_000);
});

test("a file that is not a crash is passed over and removed", async () => {
  for (const text of ["{\"origin\":\"uncaughtExc", "[1]", "null", JSON.stringify({ origin: "uncaughtException" }), JSON.stringify({ error: "Error" }), JSON.stringify({ origin: "", error: "Error" }), JSON.stringify({ origin: "x", error: 3 })]) {
    const data = dataWith(null);
    writeFileSync(join(data, "run", "node-crash.json"), text);
    const { said, emit } = crashes();
    assert.equal(await reportNodeCrash(data, emit), false, text);
    assert.deepEqual(said, [], text);
    assert.deepEqual(readdirSync(join(data, "run")), [], text);
  }
});
