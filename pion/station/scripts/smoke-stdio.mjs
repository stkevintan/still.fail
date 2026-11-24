#!/usr/bin/env node
// Streaming chunk-by-chunk stdio smoke verifier for `stillfail-pion --smoke-stdio`.
// Rejects early child exit/crash, malformed JSON headers, truncated binary tails,
// non-zero exit codes, and unconsumed trailing frames.
//
// Usage:
//   node pion/station/scripts/smoke-stdio.mjs <bin> [args...]
//   (defaults to ["--smoke-stdio"] when no args are given)

import { spawn } from "node:child_process";

const [, , bin, ...rest] = process.argv;
if (!bin) {
  console.error("usage: node smoke-stdio.mjs <bin> [args...]");
  process.exit(2);
}

const args = rest.length > 0 ? rest : ["--smoke-stdio"];
const child = spawn(bin, args, { stdio: ["pipe", "pipe", "pipe"] });

let buf = Buffer.alloc(0);
let pendingHead = null;
const frames = [];
const waiters = [];
let stderr = "";
let fatalErr = null;
let parseErr = null;
let resolveClosed;
const closed = new Promise((resolve) => {
  resolveClosed = resolve;
});

function failAll(err) {
  if (!fatalErr) fatalErr = err;
  while (waiters.length > 0) {
    const w = waiters.shift();
    w.reject(fatalErr);
  }
}

function nextFrame() {
  if (frames.length > 0) {
    return Promise.resolve(frames.shift());
  }
  if (fatalErr) {
    return Promise.reject(fatalErr);
  }
  return new Promise((resolve, reject) => {
    waiters.push({ resolve, reject });
  });
}

function emit(frame) {
  if (waiters.length > 0) {
    const w = waiters.shift();
    w.resolve(frame);
  } else {
    frames.push(frame);
  }
}

child.stdin.on("error", () => {
  // Handled via child close/error; avoid unhandled EPIPE masking real exit status.
});

child.on("error", (err) => {
  const e = new Error(`child spawn error: ${err.message}`);
  if (!parseErr) parseErr = e;
  failAll(e);
  resolveClosed({ code: -1, signal: null });
});

child.on("close", (code, signal) => {
  failAll(
    new Error(
      `child exited prematurely (code=${code}, signal=${signal}, pendingHead=${pendingHead ? "yes" : "no"}, rem=${buf.length})${stderr ? ` stderr=${stderr.trim()}` : ""}`,
    ),
  );
  resolveClosed({ code, signal });
});

child.stderr.on("data", (d) => {
  stderr += d.toString("utf8");
});

child.stdout.on("data", (d) => {
  try {
    buf = Buffer.concat([buf, d]);
    while (buf.length > 0) {
      if (pendingHead !== null) {
        if (buf.length < pendingHead.bytes) break;
        const body = buf.subarray(0, pendingHead.bytes);
        buf = buf.subarray(pendingHead.bytes);
        const head = pendingHead;
        pendingHead = null;
        emit({ ...head, body });
        continue;
      }
      const nl = buf.indexOf(10);
      if (nl < 0) break;
      const line = buf.subarray(0, nl).toString("utf8");
      buf = buf.subarray(nl + 1);
      const obj = JSON.parse(line);
      if (obj === null || typeof obj !== "object") {
        throw new Error(`expected JSON object frame, got: ${line}`);
      }
      if (typeof obj.bytes === "number") {
        if (!Number.isInteger(obj.bytes) || obj.bytes < 0) {
          throw new Error(`invalid binary frame byte count: ${obj.bytes}`);
        }
        pendingHead = obj;
      } else {
        emit(obj);
      }
    }
  } catch (err) {
    const e = err instanceof Error ? err : new Error(String(err));
    if (!parseErr) parseErr = e;
    failAll(e);
    child.kill();
  }
});

async function run() {
  child.stdin.write(JSON.stringify({ id: 1, op: "echo", text: "hello-pion" }) + "\n");
  const f1 = await nextFrame();
  if (f1.text !== "hello-pion") {
    throw new Error(`echo mismatch: ${JSON.stringify(f1)}`);
  }

  child.stdin.write(JSON.stringify({ id: 2, op: "binary", size: 32, byte: 0 }) + "\n");
  const f2 = await nextFrame();
  if (
    !Buffer.isBuffer(f2.body) ||
    f2.body.length !== 32 ||
    f2.body[0] !== 0 ||
    f2.body[10] !== 10 ||
    f2.body[31] !== 31
  ) {
    throw new Error("binary tail with NUL and LF mismatch");
  }

  child.stdin.write(JSON.stringify({ id: 3, op: "cancel", target: 4 }) + "\n");
  const f3 = await nextFrame();
  if (f3.cancelled !== 4) {
    throw new Error(`cancel ack mismatch: ${JSON.stringify(f3)}`);
  }

  child.stdin.write(JSON.stringify({ id: 4, op: "echo", text: "should-cancel" }) + "\n");
  const f4 = await nextFrame();
  if (f4.cancelled !== true) {
    throw new Error(`cancelled req mismatch: ${JSON.stringify(f4)}`);
  }

  child.stdin.end();
  const { code, signal } = await closed;
  if (parseErr) {
    throw parseErr;
  }
  if (
    code !== 0 ||
    signal !== null ||
    buf.length !== 0 ||
    pendingHead !== null ||
    frames.length !== 0
  ) {
    throw new Error(
      `bad EOF exit: code=${code} signal=${signal} rem=${buf.length} pendingHead=${pendingHead ? "yes" : "no"} extraFrames=${frames.length} stderr=${stderr}`,
    );
  }
  console.log("smoke-stdio ok (streaming + pure EOF): 4 frames");
}

run().catch((err) => {
  console.error(err instanceof Error ? err.message : String(err));
  try {
    child.kill();
  } catch {}
  process.exit(1);
});
