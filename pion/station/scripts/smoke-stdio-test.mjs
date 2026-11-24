#!/usr/bin/env node
// Regression self-test for `smoke-stdio.mjs`: proves it fails loudly on
// (a) early exit 17 with no frames, (b) truncated binary tail with exit 0,
// (c) unexpected extra trailing frame with exit 0, and passes on a valid double.

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const harness = join(here, "smoke-stdio.mjs");

function runDouble(script) {
  return spawnSync(process.execPath, [harness, process.execPath, "-e", script], {
    encoding: "utf8",
    timeout: 10_000,
  });
}

// (a) Read first line, emit nothing, exit 17 -> must fail non-zero (never false-green).
{
  const res = runDouble(`
    process.stdin.once("data", () => process.exit(17));
  `);
  assert.notEqual(res.status, 0, "expected non-zero exit when child exits 17 with no frames");
  assert.match(res.stderr, /code=17/, `expected code=17 in stderr, got: ${res.stderr}`);
}

// (b) Reply echo, then emit a 32-byte binary header with only 10 bytes and exit 0 -> must fail non-zero.
{
  const res = runDouble(`
    let acc = "";
    process.stdin.on("data", (d) => {
      acc += d.toString("utf8");
      while (acc.includes("\\n")) {
        const idx = acc.indexOf("\\n");
        const msg = JSON.parse(acc.slice(0, idx));
        acc = acc.slice(idx + 1);
        if (msg.op === "echo") {
          process.stdout.write(JSON.stringify({ id: msg.id, ok: true, text: msg.text }) + "\\n");
        } else if (msg.op === "binary") {
          process.stdout.write(JSON.stringify({ id: msg.id, ok: true, bytes: 32 }) + "\\n");
          process.stdout.write(Buffer.alloc(10, 0x41));
          process.exit(0);
        }
      }
    });
  `);
  assert.notEqual(res.status, 0, "expected non-zero exit on truncated binary frame + exit 0");
  assert.match(res.stderr, /pendingHead=yes/, `expected pendingHead=yes in stderr, got: ${res.stderr}`);
}

// (c) Valid 4 frames plus an extra unsolicited trailing frame before exit 0 -> must fail non-zero.
{
  const res = runDouble(`
    let acc = "";
    const cancelled = new Set();
    process.stdin.on("data", (d) => {
      acc += d.toString("utf8");
      while (acc.includes("\\n")) {
        const idx = acc.indexOf("\\n");
        const msg = JSON.parse(acc.slice(0, idx));
        acc = acc.slice(idx + 1);
        if (msg.op === "cancel") {
          cancelled.add(msg.target);
          process.stdout.write(JSON.stringify({ id: msg.id, ok: true, cancelled: msg.target }) + "\\n");
        } else if (cancelled.has(msg.id)) {
          process.stdout.write(JSON.stringify({ id: msg.id, ok: false, cancelled: true }) + "\\n");
        } else if (msg.op === "echo") {
          process.stdout.write(JSON.stringify({ id: msg.id, ok: true, text: msg.text }) + "\\n");
        } else if (msg.op === "binary") {
          const b = Buffer.alloc(msg.size);
          for (let i = 0; i < msg.size; i++) b[i] = (msg.byte + i) & 0xff;
          process.stdout.write(JSON.stringify({ id: msg.id, ok: true, bytes: b.length }) + "\\n");
          process.stdout.write(b);
        }
      }
    });
    process.stdin.on("end", () => {
      process.stdout.write(JSON.stringify({ unsolicited: true }) + "\\n");
      process.exit(0);
    });
  `);
  assert.notEqual(res.status, 0, "expected non-zero exit on unsolicited extra trailing frame");
  assert.match(res.stderr, /extraFrames=1/, `expected extraFrames=1 in stderr, got: ${res.stderr}`);
}

// (d) Valid 4 frames plus invalid trailing JSON before immediate exit 0 -> must fail non-zero.
{
  const res = runDouble(`
    let acc = "";
    const cancelled = new Set();
    process.stdin.on("data", (d) => {
      acc += d.toString("utf8");
      while (acc.includes("\\n")) {
        const idx = acc.indexOf("\\n");
        const msg = JSON.parse(acc.slice(0, idx));
        acc = acc.slice(idx + 1);
        if (msg.op === "cancel") {
          cancelled.add(msg.target);
          process.stdout.write(JSON.stringify({ id: msg.id, ok: true, cancelled: msg.target }) + "\\n");
        } else if (cancelled.has(msg.id)) {
          process.stdout.write(JSON.stringify({ id: msg.id, ok: false, cancelled: true }) + "\\n");
        } else if (msg.op === "echo") {
          process.stdout.write(JSON.stringify({ id: msg.id, ok: true, text: msg.text }) + "\\n");
        } else if (msg.op === "binary") {
          const b = Buffer.alloc(msg.size);
          for (let i = 0; i < msg.size; i++) b[i] = (msg.byte + i) & 0xff;
          process.stdout.write(JSON.stringify({ id: msg.id, ok: true, bytes: b.length }) + "\\n");
          process.stdout.write(b);
        }
      }
    });
    process.stdin.on("end", () => {
      process.stdout.write("not-json\\n");
      process.exit(0);
    });
  `);
  assert.notEqual(res.status, 0, "expected non-zero exit on trailing invalid JSON + exit 0");
}

// (e) Valid test double -> must exit 0.
{
  const res = runDouble(`
    let acc = "";
    const cancelled = new Set();
    process.stdin.on("data", (d) => {
      acc += d.toString("utf8");
      while (acc.includes("\\n")) {
        const idx = acc.indexOf("\\n");
        const msg = JSON.parse(acc.slice(0, idx));
        acc = acc.slice(idx + 1);
        if (msg.op === "cancel") {
          cancelled.add(msg.target);
          process.stdout.write(JSON.stringify({ id: msg.id, ok: true, cancelled: msg.target }) + "\\n");
        } else if (cancelled.has(msg.id)) {
          process.stdout.write(JSON.stringify({ id: msg.id, ok: false, cancelled: true }) + "\\n");
        } else if (msg.op === "echo") {
          process.stdout.write(JSON.stringify({ id: msg.id, ok: true, text: msg.text }) + "\\n");
        } else if (msg.op === "binary") {
          const b = Buffer.alloc(msg.size);
          for (let i = 0; i < msg.size; i++) b[i] = (msg.byte + i) & 0xff;
          process.stdout.write(JSON.stringify({ id: msg.id, ok: true, bytes: b.length }) + "\\n");
          process.stdout.write(b);
        }
      }
    });
  `);
  assert.equal(res.status, 0, `expected valid double to pass, got stderr: ${res.stderr}`);
}

console.log("smoke-stdio-test: ALL PASSED (4 negative + 1 positive)");
