import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

const nativeModule = new URL("../scripts/native.ts", import.meta.url).href;

function makeFakeRustup(binDir: string) {
  mkdirSync(binDir, { recursive: true });
  const fakeRustup = join(binDir, "rustup");
  writeFileSync(fakeRustup, `#!${process.execPath}
import { appendFileSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { connect } from "node:net";

const args = process.argv.slice(2);
const stateFile = process.env.FAKE_RUSTUP_STATE;
const logFile = process.env.FAKE_RUSTUP_LOG;
const busyDir = process.env.FAKE_RUSTUP_BUSY;
const failOnceFile = process.env.FAKE_RUSTUP_FAIL_ONCE;
const gatePort = Number(process.env.FAKE_RUSTUP_GATE_PORT || "0");

if (args[0] === "target" && args[1] === "list") {
  if (!existsSync(stateFile)) process.exit(1);
  process.stdout.write(readFileSync(stateFile, "utf8"));
  process.exit(0);
}

try {
  mkdirSync(busyDir);
} catch {
  process.stderr.write("CONCURRENT_RUSTUP\\n");
  process.exit(2);
}

const releaseBusy = () => rmSync(busyDir, { recursive: true, force: true });

if (args[0] === "toolchain" && args[1] === "install") {
  appendFileSync(logFile, "install:" + args[2] + "\\n");
  if (failOnceFile && existsSync(failOnceFile)) {
    rmSync(failOnceFile, { force: true });
    releaseBusy();
    process.stderr.write("simulated install failure\\n");
    process.exit(1);
  }
  const finish = () => {
    writeFileSync(stateFile, "aarch64-apple-darwin\\n");
    releaseBusy();
    process.exit(0);
  };
  if (gatePort > 0) {
    const sock = connect(gatePort, "127.0.0.1", () => sock.write("in-install\\n"));
    sock.on("end", finish);
    sock.on("error", (err) => {
      releaseBusy();
      process.stderr.write(String(err) + "\\n");
      process.exit(3);
    });
  } else {
    finish();
  }
} else if (args[0] === "target" && args[1] === "add") {
  const triple = args[args.length - 1];
  appendFileSync(logFile, "add:" + triple + "\\n");
  appendFileSync(stateFile, triple + "\\n");
  releaseBusy();
  process.exit(0);
} else {
  releaseBusy();
  process.stderr.write("unexpected args: " + args.join(" ") + "\\n");
  process.exit(4);
}
`);
  chmodSync(fakeRustup, 0o755);
}

function spawnRustTarget(triple: string | undefined, env: Record<string, string>) {
  const call = triple === undefined ? "rustTarget();" : `rustTarget(${JSON.stringify(triple)});`;
  const child = spawn(
    process.execPath,
    ["--input-type=module", "-e", `import { rustTarget } from ${JSON.stringify(nativeModule)}; ${call}`],
    { env: { ...process.env, ...env } },
  );
  let stderr = "";
  let onWaiting: (() => void) | null = null;
  const waiting = new Promise<void>((resolve) => {
    onWaiting = resolve;
  });
  child.stderr.on("data", (chunk: Buffer) => {
    stderr += chunk.toString("utf8");
    if (stderr.includes("waiting for another process")) onWaiting?.();
  });
  const done = once(child, "exit").then(([code]) => ({ code: code ?? 1, stderr }));
  const waitOrFail = (label: string) =>
    Promise.race([
      waiting,
      done.then((r) => assert.fail(`${label} exited (${r.code}) before waiting on lock:\n${r.stderr}`)),
    ]);
  return { waitOrFail, done };
}

test("parallel rustTarget calls serialize rustup install and target add without racing", async (t) => {
  const dir = mkdtempSync(join(tmpdir(), "native-rustup-lock-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const home = join(dir, "home");
  const cache = join(dir, "cache");
  const stateFile = join(dir, "installed");
  const logFile = join(dir, "calls.log");
  const busyDir = join(dir, "busy");
  makeFakeRustup(join(home, ".cargo", "bin"));

  let holdSocket: Socket | null = null;
  let onEnteredInstall: (() => void) | null = null;
  const enteredInstall = new Promise<void>((resolve) => {
    onEnteredInstall = resolve;
  });
  const gate = createServer((socket) => {
    holdSocket = socket;
    socket.once("data", () => onEnteredInstall?.());
  });
  gate.listen(0, "127.0.0.1");
  await once(gate, "listening");
  t.after(() => {
    holdSocket?.destroy();
    gate.close();
  });
  const gatePort = (gate.address() as { port: number }).port;

  const env = {
    HOME: home,
    USERPROFILE: home,
    STILLFAIL_NATIVE_CACHE: cache,
    FAKE_RUSTUP_STATE: stateFile,
    FAKE_RUSTUP_LOG: logFile,
    FAKE_RUSTUP_BUSY: busyDir,
    FAKE_RUSTUP_GATE_PORT: String(gatePort),
  };

  // Start worker 1 and pause it deterministically inside `rustup toolchain install`.
  const w1 = spawnRustTarget("aarch64-apple-darwin", env);
  await Promise.race([
    enteredInstall,
    w1.done.then((r) => assert.fail(`worker 1 exited (${r.code}) before entering install:\n${r.stderr}`)),
  ]);

  // Start workers 2 and 3 while worker 1 holds `.rustup.lock`, and verify both queue on the lock.
  const w2 = spawnRustTarget("aarch64-apple-ios", env);
  const w3 = spawnRustTarget("aarch64-apple-ios-sim", env);
  await Promise.all([w2.waitOrFail("worker 2"), w3.waitOrFail("worker 3")]);

  // Release worker 1's install; all three must finish cleanly without overlapping rustup calls.
  holdSocket!.end();
  const [r1, r2, r3] = await Promise.all([w1.done, w2.done, w3.done]);
  assert.equal(r1.code, 0, r1.stderr);
  assert.equal(r2.code, 0, r2.stderr);
  assert.equal(r3.code, 0, r3.stderr);
  assert.ok(!existsSync(join(cache, ".rustup.lock")), "lock directory should be removed after completion");

  const calls = readFileSync(logFile, "utf8").trim().split("\n");
  assert.equal(calls[0], "install:1.95.0");
  assert.deepEqual(calls.slice(1).sort(), ["add:aarch64-apple-ios", "add:aarch64-apple-ios-sim"]);
});

test("rustTarget releases the lock when rustup fails so later callers proceed", async (t) => {
  const dir = mkdtempSync(join(tmpdir(), "native-rustup-lock-fail-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const home = join(dir, "home");
  const cache = join(dir, "cache");
  const stateFile = join(dir, "installed");
  const logFile = join(dir, "calls.log");
  const busyDir = join(dir, "busy");
  const failOnceFile = join(dir, "fail-once");
  writeFileSync(failOnceFile, "1");
  makeFakeRustup(join(home, ".cargo", "bin"));

  const env = {
    HOME: home,
    USERPROFILE: home,
    STILLFAIL_NATIVE_CACHE: cache,
    FAKE_RUSTUP_STATE: stateFile,
    FAKE_RUSTUP_LOG: logFile,
    FAKE_RUSTUP_BUSY: busyDir,
    FAKE_RUSTUP_FAIL_ONCE: failOnceFile,
  };

  const first = await spawnRustTarget("aarch64-apple-darwin", env).done;
  assert.notEqual(first.code, 0);
  assert.ok(!existsSync(join(cache, ".rustup.lock")), "lock directory should be released on error");

  const second = await spawnRustTarget(undefined, env).done;
  assert.equal(second.code, 0, second.stderr);
  assert.deepEqual(readFileSync(logFile, "utf8").trim().split("\n"), ["install:1.95.0", "install:1.95.0"]);
});
