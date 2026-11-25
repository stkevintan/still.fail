import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import {
  appendFileSync,
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { createServer, type AddressInfo, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join, sep } from "node:path";
import { after, test } from "node:test";
import { zstdCompressSync } from "node:zlib";
import {
  mbReaderBinary,
  pionBinary,
  resetReaderSelectionStateForTest,
  setPionProbeRunnerForTest,
} from "../src/read/mb-reader.ts";
import { Store } from "../src/store/store.ts";
import { UsageCounter } from "../src/usage/counter.ts";
import { testClock } from "./hub-fakes.ts";

const dirs: string[] = [];
const cleanup: (() => Promise<void> | void)[] = [];
after(async () => {
  for (const f of cleanup) await f();
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

function tempdir(prefix = "w6-usage-switch-"): string {
  const d = mkdtempSync(join(tmpdir(), prefix));
  dirs.push(d);
  return d;
}

function resolveDualBinaries(t: { skip: (msg: string) => void }): { mb: string; pion: string } | null {
  const realMb = mbReaderBinary();
  const explicitPion = process.env.STILLFAIL_PION_READER?.trim();
  const requireDual = process.env.STILLFAIL_REQUIRE_DUAL_READER === "1";
  const realPion = pionBinary();

  if (realMb === null) {
    if (process.env.CI || requireDual) assert.fail("stillfail-reader binary is required in CI");
    t.skip("stillfail-reader not built here");
    return null;
  }
  if (explicitPion || requireDual) {
    assert.ok(realPion !== null, `STILLFAIL_PION_READER is required (${explicitPion ?? "unset"}) but resolved to null`);
  } else if (realPion === null) {
    t.skip("STILLFAIL_PION_READER / built stillfail-pion binary not present in this environment");
    return null;
  }
  assert.notEqual(realpathSync(realMb), realpathSync(realPion), "MB and Pion binaries must be distinct files");
  const ver = execFileSync(realPion, ["--version"], { encoding: "utf8" });
  assert.match(ver, /modes:[^\n]*usage-counter/, `Pion --version must advertise usage-counter: ${ver}`);
  return { mb: realMb, pion: realPion };
}

function makeRecordingWrapper(dir: string, name: string, realBin: string, logFile: string): string {
  const wrapper = join(dir, name);
  const sh = [
    "#!/bin/sh",
    `printf '%s %s\\n' "$$" "$*" >> ${JSON.stringify(logFile)}`,
    `exec ${JSON.stringify(realBin)} "$@"`,
    "",
  ].join("\n");
  writeFileSync(wrapper, sh, "utf8");
  chmodSync(wrapper, 0o755);
  return wrapper;
}

function readSpawns(logFile: string): string[] {
  if (!existsSync(logFile)) return [];
  return readFileSync(logFile, "utf8").split("\n").map((s) => s.trim()).filter(Boolean);
}

async function withEnv<T>(overrides: Record<string, string | undefined>, fn: () => Promise<T>): Promise<T> {
  const saved = new Map<string, string | undefined>();
  for (const [k, v] of Object.entries(overrides)) {
    saved.set(k, process.env[k]);
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  resetReaderSelectionStateForTest();
  try {
    return await fn();
  } finally {
    for (const [k, v] of saved) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
    resetReaderSelectionStateForTest();
  }
}

function claudeProject(path: string): string {
  return Array.from(path, (c) => (/[A-Za-z0-9]/.test(c) ? c : "-")).join("");
}

function iso(ms: number): string {
  return new Date(ms).toISOString();
}

function claudeLine(
  id: string,
  at: number,
  model: string,
  input: number,
  output: number,
  extra: { pad?: string; cacheRead?: number; cacheWrite?: number } = {},
): string {
  const usage: Record<string, unknown> = {
    input_tokens: input,
    cache_read_input_tokens: extra.cacheRead ?? 0,
    cache_creation_input_tokens: extra.cacheWrite ?? 0,
    output_tokens: output,
  };
  const rec: Record<string, unknown> = {
    type: "assistant",
    timestamp: iso(at),
    message: { id, model, usage },
  };
  if (extra.pad) rec.pad = extra.pad;
  return JSON.stringify(rec);
}

function appendLines(path: string, lines: string[]): void {
  mkdirSync(dirname(path), { recursive: true });
  appendFileSync(path, lines.map((l) => `${l}\n`).join(""));
}

function dumpUsageDb(store: Store) {
  return {
    usage: store.db
      .prepare(
        "SELECT id, at, session, turn, thread, person, profile, runtime, model, subagent, fast, input, cache_read, cache_write, cache_write_long, output, calls, context, context_window, gen_ms, gen_output FROM usage ORDER BY id",
      )
      .all(),
    files: store.db
      .prepare("SELECT path, session, offset, model, counter_cutoff, counter_anchor, speed FROM usage_files ORDER BY path")
      .all(),
    counter: store.db.prepare("SELECT since, through FROM usage_counter WHERE id = 1").get(),
  };
}

function sendRawLines(binary: string, dbPath: string, rawChunks: Buffer[]): Promise<string[]> {
  return new Promise((resolve, reject) => {
    const child = spawn(binary, ["--builder", "usage-counter", "--db", dbPath, "--sep", sep], {
      stdio: ["pipe", "pipe", "pipe"],
    });
    const outChunks: Buffer[] = [];
    const errChunks: Buffer[] = [];
    child.stdout.on("data", (d: Buffer) => {
      outChunks.push(d);
    });
    child.stderr.on("data", (d: Buffer) => {
      errChunks.push(d);
    });
    child.on("error", reject);
    child.on("close", (code) => {
      const out = Buffer.concat(outChunks).toString("utf8");
      const err = Buffer.concat(errChunks).toString("utf8");
      if (code !== 0) reject(new Error(`exit ${code}: ${err}`));
      else resolve(out.split("\n").filter((l) => l.length > 0));
    });
    for (const chunk of rawChunks) {
      child.stdin.write(chunk);
    }
    child.stdin.end();
  });
}

test("dual-engine 0-diff: partial commit, file replacement re-read, and segmented zst resume", async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;

  // 1. Partial commit (WRITE_BATCH=64) on timed_again failure + recovery
  {
    const dir = tempdir("w6-usage-partial-");
    const time = testClock();
    const t0 = Date.parse("2026-11-24T10:00:00Z");
    await time.adjust(t0);
    const ws = join(dir, "ws-partial");
    mkdirSync(ws, { recursive: true });
    const transcript = join(dir, "transcripts/claude", claudeProject(ws), "r1.jsonl");
    const asked = (at: number) =>
      JSON.stringify({ type: "user", message: { role: "user", content: "go" }, timestamp: iso(at) });
    const lines: string[] = [];
    for (let i = 0; i < 150; i++) {
      lines.push(
        asked(t0 + 1_000 + i * 1_000),
        claudeLine(`c${String(i).padStart(3, "0")}`, t0 + 1_500 + i * 1_000, "claude-opus-5-5", 10, 5),
      );
    }
    appendLines(transcript, lines);

    const runOne = async (label: string, bin: string) => {
      const store = Store.open(join(dir, `${label}.db`), null, time.clock);
      cleanup.unshift(() => store.close());
      store.insertSession({
        key: "chat:c-partial",
        connect: "ember",
        runtime: "claude",
        profile: "cc",
        workspace: ws,
        token: "tok",
        createdAt: t0 - 1_000,
        lastActiveAt: t0 - 1_000,
        ws: "mine",
      });
      store.startTurnFor("t1", "chat:c-partial", "input", { profile: "cc", person: "a@x", thread: null });
      const counter = new UsageCounter({ store, config: () => ({ dataDir: dir, profiles: [] }), clock: time.clock, mb: bin });
      cleanup.unshift(() => counter.stop());
      assert.equal(await counter.read(new Set(["chat:c-partial"])), 150);

      store.db.exec(
        "UPDATE usage SET gen_ms = 0, gen_output = 0; UPDATE usage_files SET speed = NULL; " +
          "CREATE TRIGGER fail_c100 BEFORE UPDATE OF gen_ms ON usage WHEN NEW.id = 'c100' BEGIN SELECT RAISE(ABORT, 'boom c100'); END;",
      );
      // Recycle worker so it reloads `usage_files.speed = NULL` from SQLite (simulating a station restart).
      assert.equal(counter.trimIdle(), 1);
      await assert.rejects(counter.read(new Set(["chat:c-partial"]), t0), /boom c100/);
      const midCount = (store.db.prepare("SELECT COUNT(*) AS n FROM usage WHERE gen_ms > 0").get() as { n: number }).n;
      const midSpeed = (store.db.prepare("SELECT speed FROM usage_files").get() as { speed: string | null }).speed;
      assert.equal(midCount, 64, `${label}: first WRITE_BATCH=64 must stay committed`);
      assert.equal(midSpeed, null, `${label}: speed cursor must remain NULL on partial failure`);

      store.db.exec("DROP TRIGGER fail_c100");
      assert.equal(await counter.read(new Set(["chat:c-partial"]), t0), 0);
      return dumpUsageDb(store);
    };

    const mbDump = await runOne("mb", bins.mb);
    const pionDump = await runOne("pion", bins.pion);
    assert.deepEqual(pionDump, mbDump, "partial commit + recovery must be 0-diff between MB and Pion");
  }

  // 1b. Main read path `flush` partial commit (WRITE_BATCH=64) on INSERT failure + recovery
  {
    const dir = tempdir("w6-usage-flush-");
    const time = testClock();
    const t0 = Date.parse("2026-11-24T10:30:00Z");
    await time.adjust(t0);
    const ws = join(dir, "ws-flush");
    mkdirSync(ws, { recursive: true });
    // Two files under the same Claude project dir:
    // - f1.jsonl has 70 calls (>= WRITE_BATCH=64) -> flushed in batch 1
    // - f2.jsonl has 50 calls -> hits trigger on call #100 (f099) during batch 2 flush
    const f1 = join(dir, "transcripts/claude", claudeProject(ws), "f1.jsonl");
    const f2 = join(dir, "transcripts/claude", claudeProject(ws), "f2.jsonl");
    appendLines(
      f1,
      Array.from({ length: 70 }, (_, i) => claudeLine(`f${String(i).padStart(3, "0")}`, t0 + 1_000 + i * 100, "claude-opus-5-5", 10, 5)),
    );
    appendLines(
      f2,
      Array.from({ length: 50 }, (_, i) => claudeLine(`f${String(70 + i).padStart(3, "0")}`, t0 + 10_000 + i * 100, "claude-opus-5-5", 12, 6)),
    );

    const runFlush = async (label: string, bin: string) => {
      const store = Store.open(join(dir, `${label}.db`), null, time.clock);
      cleanup.unshift(() => store.close());
      store.insertSession({
        key: "chat:c-flush",
        connect: "ember",
        runtime: "claude",
        profile: "cc",
        workspace: ws,
        token: "tok",
        createdAt: t0 - 1_000,
        lastActiveAt: t0 - 1_000,
        ws: "mine",
      });
      store.startTurnFor("t1", "chat:c-flush", "input", { profile: "cc", person: "a@x", thread: null });
      store.db.exec(
        "CREATE TRIGGER fail_f099 BEFORE INSERT ON usage WHEN NEW.id = 'f099' BEGIN SELECT RAISE(ABORT, 'boom flush'); END;",
      );
      const counter = new UsageCounter({ store, config: () => ({ dataDir: dir, profiles: [] }), clock: time.clock, mb: bin });
      cleanup.unshift(() => counter.stop());

      await assert.rejects(counter.read(new Set(["chat:c-flush"])), /boom flush/);
      const midCalls = (store.db.prepare("SELECT COUNT(*) AS n FROM usage").get() as { n: number }).n;
      assert.equal(midCalls, 64, `${label}: batch 1 (WRITE_BATCH=64 calls) must stay committed after batch 2 flush failure`);

      store.db.exec("DROP TRIGGER fail_f099");
      // Same worker process (no trimIdle): `self.files = None` on flush error must allow clean recovery.
      assert.equal(await counter.read(new Set(["chat:c-flush"])), 56, `${label}: recovery read must ingest remaining 56 calls`);
      const finalCalls = (store.db.prepare("SELECT COUNT(*) AS n FROM usage").get() as { n: number }).n;
      assert.equal(finalCalls, 120);
      return dumpUsageDb(store);
    };

    const mbDump = await runFlush("mb", bins.mb);
    const pionDump = await runFlush("pion", bins.pion);
    assert.deepEqual(pionDump, mbDump, "main-path flush partial commit + recovery must be 0-diff between MB and Pion");
  }

  // 2. File replacement (anchor mismatch) + segmented .zst resume (>= 2 real frames) + single-frame .zst resume
  {
    const dir = tempdir("w6-usage-replace-");
    const time = testClock();
    const t0 = Date.parse("2026-11-24T11:00:00Z");
    await time.adjust(t0);

    const parseSeekTable = (zstPath: string): { numFrames: number; frame0Decomp: number } => {
      const buf = readFileSync(zstPath);
      const magic = buf.readUInt32LE(buf.length - 4);
      assert.equal(magic, 0x8f92eab1, "must have zstd seekable format magic");
      const desc = buf[buf.length - 5]!;
      const hasChecksum = (desc & 0x80) !== 0;
      const numFrames = buf.readUInt32LE(buf.length - 9);
      const entrySize = hasChecksum ? 12 : 8;
      const tableStart = buf.length - 9 - numFrames * entrySize;
      const frame0Decomp = buf.readUInt32LE(tableStart + 4);
      return { numFrames, frame0Decomp };
    };

    const writeSeekableTwoFrameZst = (rawPath: string, splitAt: number) => {
      const raw = readFileSync(rawPath);
      assert.ok(splitAt > 0 && splitAt < raw.length, "splitAt must divide raw transcript into 2 non-empty frames");
      const f0Raw = raw.subarray(0, splitAt);
      const f1Raw = raw.subarray(splitAt);
      const f0Comp = zstdCompressSync(f0Raw);
      const f1Comp = zstdCompressSync(f1Raw);
      // Zstd seekable format skippable frame: magic 0x184D2A5E + payloadLen (2*8+9=25) + 2 entries + numFrames + desc + 0x8F92EAB1
      const footer = Buffer.alloc(8 + 25);
      footer.writeUInt32LE(0x184d2a5e, 0);
      footer.writeUInt32LE(25, 4);
      footer.writeUInt32LE(f0Comp.length, 8);
      footer.writeUInt32LE(f0Raw.length, 12);
      footer.writeUInt32LE(f1Comp.length, 16);
      footer.writeUInt32LE(f1Raw.length, 20);
      footer.writeUInt32LE(2, 24);
      footer[28] = 0; // no checksum
      footer.writeUInt32LE(0x8f92eab1, 29);
      writeFileSync(`${rawPath}.zst`, Buffer.concat([f0Comp, f1Comp, footer]));
      unlinkSync(rawPath);
    };

    const runScenario = async (mode: "replaced" | "segmented" | "single-frame") => {
      const subDir = join(dir, mode);
      const ws = join(subDir, "ws");
      mkdirSync(ws, { recursive: true });
      const transcript = join(subDir, "transcripts/claude", claudeProject(ws), "r.jsonl");
      const filler = "z".repeat(400);
      const initialCount = 30;
      appendLines(
        transcript,
        Array.from({ length: initialCount }, (_, i) => claudeLine(`a${i}`, t0 + i * 100, "claude-opus-5-5", i + 1, 2, { pad: filler })),
      );

      const mbStore = Store.open(join(subDir, "mb.db"), null, time.clock);
      const pionStore = Store.open(join(subDir, "pion.db"), null, time.clock);
      cleanup.unshift(() => mbStore.close(), () => pionStore.close());
      for (const s of [mbStore, pionStore]) {
        s.insertSession({
          key: "k",
          connect: "ember",
          runtime: "claude",
          profile: "cc",
          workspace: ws,
          token: "tok",
          createdAt: t0 - 120_000,
          lastActiveAt: t0 - 120_000,
          ws: "mine",
        });
        s.setRuntimeSessionId("k", "r");
        s.startTurn("t", "k", "input");
      }
      const mbCounter = new UsageCounter({ store: mbStore, config: () => ({ dataDir: subDir, profiles: [] }), clock: time.clock, mb: bins.mb });
      const pionCounter = new UsageCounter({ store: pionStore, config: () => ({ dataDir: subDir, profiles: [] }), clock: time.clock, mb: bins.pion });
      cleanup.unshift(() => mbCounter.stop(), () => pionCounter.stop());

      assert.equal(await mbCounter.read(new Set(["k"])), initialCount);
      assert.equal(await pionCounter.read(new Set(["k"])), initialCount);

      if (mode === "replaced") {
        writeFileSync(
          transcript,
          Array.from({ length: 35 }, (_, i) => `${claudeLine(`c${i}`, t0 + 5_000 + i * 100, "claude-opus-5-5", i + 2, 3, { pad: filler })}\n`).join(""),
        );
      } else {
        appendLines(transcript, [
          claudeLine("late-old", t0 - 10, "claude-opus-5-5", 2, 1),
          claudeLine("after-pack", t0 + 10_000, "claude-opus-5-5", 5, 4),
        ]);
        if (mode === "segmented") {
          const savedOffset = (mbStore.db.prepare("SELECT offset FROM usage_files").get() as { offset: number }).offset;
          // Put frame boundary at half of savedOffset so savedOffset lies strictly inside frame 2.
          writeSeekableTwoFrameZst(transcript, Math.floor(savedOffset / 2));
          const { numFrames, frame0Decomp } = parseSeekTable(`${transcript}.zst`);
          assert.ok(numFrames >= 2, `segmented zst must have >= 2 real frames (got ${numFrames})`);
          assert.ok(
            savedOffset > frame0Decomp,
            `saved offset (${savedOffset}) must lie inside frame >= 2 (frame0Decomp=${frame0Decomp})`,
          );
        } else {
          writeFileSync(`${transcript}.zst`, zstdCompressSync(readFileSync(transcript)));
          unlinkSync(transcript);
        }
      }

      const mbAdded = await mbCounter.read(new Set(["k"]));
      const pionAdded = await pionCounter.read(new Set(["k"]));
      assert.equal(pionAdded, mbAdded, `${mode}: added count must match`);
      assert.deepEqual(dumpUsageDb(pionStore), dumpUsageDb(mbStore), `${mode}: final DB state must be 0-diff`);
    };

    await runScenario("replaced");
    await runScenario("segmented");
    await runScenario("single-frame");
  }
});

test("cross-engine state handover: MB reads first half (writing usage_files & speed cursor) -> Pion resumes with 0-diff", async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;

  const dir = tempdir("w6-usage-handover-");
  const time = testClock();
  const t0 = Date.parse("2026-11-24T12:00:00Z");
  await time.adjust(t0);

  const wsClaude = join(dir, "ws-claude");
  const wsAgy = join(dir, "ws-agy");
  mkdirSync(wsClaude, { recursive: true });
  mkdirSync(wsAgy, { recursive: true });

  const claudeFile = join(dir, "transcripts/claude", claudeProject(wsClaude), "rc1.jsonl");
  const agyFile = join(dir, "transcripts/agy/ra1.jsonl");

  // Part 1: Claude mid-turn + Agy mid-turn (open speed cursors persisted in usage_files.speed)
  appendLines(claudeFile, [
    JSON.stringify({ type: "user", message: { role: "user", content: "q1" }, timestamp: iso(t0 + 1_000) }),
    claudeLine("cl-1", t0 + 2_200, "claude-opus-5-5", 100, 40),
    // Start a second prompt whose assistant response arrives in part 2!
    JSON.stringify({ type: "user", message: { role: "user", content: "q2" }, timestamp: iso(t0 + 5_000) }),
  ]);
  appendLines(agyFile, [
    JSON.stringify({ type: "user", time: t0 + 1_000 }),
    JSON.stringify({ type: "tool", startedAt: t0 + 1_200, time: t0 + 1_500 }),
    JSON.stringify({ type: "usage", run: "u1", time: t0 + 2_500, model: "gemini-4-neon", usage: { inputTokens: 80, outputTokens: 60 } }),
  ]);

  const setupStore = (name: string) => {
    const s = Store.open(join(dir, `${name}.db`), null, time.clock);
    cleanup.unshift(() => s.close());
    s.insertSession({
      key: "ses-claude",
      connect: "ember",
      runtime: "claude",
      profile: "cc",
      workspace: wsClaude,
      token: "tok1",
      createdAt: t0 - 1_000,
      lastActiveAt: t0 - 1_000,
      ws: "mine",
    });
    s.setRuntimeSessionId("ses-claude", "rc1");
    s.startTurnFor("tc1", "ses-claude", "input", { profile: "cc", person: "u@x", thread: null });

    s.insertSession({
      key: "ses-agy",
      connect: "ember",
      runtime: "agy",
      profile: "ag",
      workspace: wsAgy,
      token: "tok2",
      createdAt: t0 - 1_000,
      lastActiveAt: t0 - 1_000,
      ws: "mine",
    });
    s.setRuntimeSessionId("ses-agy", "ra1");
    s.startTurnFor("ta1", "ses-agy", "input", { profile: "ag", person: "u@x", thread: null });
    return s;
  };

  const baselineStore = setupStore("baseline-mb");
  const handoverStore = setupStore("handover-mb-to-pion");

  const baselineMb = new UsageCounter({ store: baselineStore, config: () => ({ dataDir: dir, profiles: [] }), clock: time.clock, mb: bins.mb });
  const handoverMb = new UsageCounter({ store: handoverStore, config: () => ({ dataDir: dir, profiles: [] }), clock: time.clock, mb: bins.mb });
  cleanup.unshift(() => baselineMb.stop(), () => handoverMb.stop());

  // Both read Part 1 with MB
  assert.equal(await baselineMb.read(new Set(["ses-claude", "ses-agy"])), 2);
  assert.equal(await handoverMb.read(new Set(["ses-claude", "ses-agy"])), 2);
  await handoverMb.stop();

  // Verify MB wrote non-zero offsets & speed cursors into handoverStore
  const midFiles = handoverStore.db.prepare("SELECT path, offset, speed FROM usage_files ORDER BY path").all() as Array<{
    path: string;
    offset: number;
    speed: string | null;
  }>;
  assert.equal(midFiles.length, 2);
  assert.ok(midFiles.every((f) => f.offset > 0 && f.speed !== null), `expected MB to persist cursors: ${JSON.stringify(midFiles)}`);

  // Part 2: Complete Claude's second turn & Agy's open turn + add a new call
  appendLines(claudeFile, [
    claudeLine("cl-2", t0 + 6_500, "claude-opus-5-5", 120, 55),
  ]);
  appendLines(agyFile, [
    JSON.stringify({ type: "usage", run: "u2", time: t0 + 3_500, model: "gemini-4-neon", usage: { inputTokens: 90, outputTokens: 70 } }),
    JSON.stringify({ type: "end", time: t0 + 3_600 }),
  ]);

  // Baseline continues with MB; handover resumes with Pion!
  const handoverPion = new UsageCounter({ store: handoverStore, config: () => ({ dataDir: dir, profiles: [] }), clock: time.clock, mb: bins.pion });
  cleanup.unshift(() => handoverPion.stop());

  assert.equal(await baselineMb.read(new Set(["ses-claude", "ses-agy"])), 2);
  assert.equal(await handoverPion.read(new Set(["ses-claude", "ses-agy"])), 2);

  assert.deepEqual(
    dumpUsageDb(handoverStore),
    dumpUsageDb(baselineStore),
    "MB -> Pion cross-engine handover must produce 0-diff final DB state (including mid-turn speed cursors)",
  );
});

test("wire protocol & edge cases: bad JSON, missing/arbitrary JSON id, empty lines, incomplete trailing line, split UTF-8", async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;

  const dir = tempdir("w6-usage-wire-");
  const time = testClock();
  const t0 = Date.parse("2026-11-24T13:00:00Z");
  await time.adjust(t0);

  const ws = join(dir, "ws-wire");
  mkdirSync(ws, { recursive: true });
  const transcript = join(dir, "transcripts/claude", claudeProject(ws), "rw.jsonl");
  // Include multi-byte UTF-8 and an incomplete trailing line (no \n)
  mkdirSync(dirname(transcript), { recursive: true });
  const validLine = claudeLine("w1", t0 + 1_000, "claude-opus-5-5", 15, 25, { pad: "中文🚀" });
  const partialLine = claudeLine("w2-incomplete", t0 + 2_000, "claude-opus-5-5", 10, 10);
  writeFileSync(transcript, `${validLine}\n${partialLine}`, "utf8"); // intentionally no trailing \n

  const runWire = async (label: string, bin: string) => {
    const dbPath = join(dir, `${label}.db`);
    const store = Store.open(dbPath, null, time.clock);
    cleanup.unshift(() => store.close());
    store.insertSession({
      key: "kw",
      connect: "ember",
      runtime: "claude",
      profile: "cc",
      workspace: ws,
      token: "tok",
      createdAt: t0 - 1_000,
      lastActiveAt: t0 - 1_000,
      ws: "mine",
    });
    store.setRuntimeSessionId("kw", "rw");
    store.startTurn("tw", "kw", "input");

    // Split a request with multi-byte UTF-8 across two raw stdin chunks, include empty line,
    // bad JSON, missing id, arbitrary JSON id (array + string), and omitted op.
    const req1 = Buffer.from(
      "\n" +
        "{not valid json\n" +
        JSON.stringify({ dataDir: dir, homes: [], only: ["kw"], started: t0 + 5_000, last: 0, hints: { elsewhere: [], rollouts: [], said: [] } }) +
        "\n",
      "utf8",
    );
    const fullReq2 = Buffer.from(
      JSON.stringify({
        id: ["arr", "中文🚀", 42],
        // op intentionally omitted (no extra validation on op)
        dataDir: dir,
        homes: [],
        only: ["kw"],
        started: t0 + 6_000,
        last: 0,
        hints: { elsewhere: [], rollouts: [], said: [] },
      }) + "\n",
      "utf8",
    );
    const req3 = Buffer.from(JSON.stringify({ id: "str-err-id" }) + "\n", "utf8");
    const rocketIdx = fullReq2.indexOf(Buffer.from("🚀", "utf8"));
    assert.ok(rocketIdx > 0, "fullReq2 must contain multi-byte rocket emoji");
    // Split right in the middle of the 4-byte UTF-8 sequence for 🚀 (after byte 2).
    const splitAt = rocketIdx + 2;
    const answers = await sendRawLines(bin, dbPath, [req1, fullReq2.subarray(0, splitAt), fullReq2.subarray(splitAt), req3]);
    return {
      answers: answers.map((l) => JSON.parse(l)),
      db: dumpUsageDb(store),
    };
  };

  const mbRes = await runWire("mb", bins.mb);
  const pionRes = await runWire("pion", bins.pion);

  const normalizeErr = (ans: Record<string, unknown>) =>
    typeof ans.error === "string"
      ? { ...ans, error: ans.error.replace(/^src\/[^ ]+ FAILED: /, "") }
      : ans;

  assert.equal(pionRes.answers.length, 4, "empty line ignored; 4 requests -> 4 responses");
  assert.deepEqual(
    pionRes.answers.map(normalizeErr),
    mbRes.answers.map(normalizeErr),
    "wire responses must be 0-diff between MB and Pion",
  );
  assert.equal(pionRes.answers[0].id, null);
  assert.equal(pionRes.answers[0].error, "no data directory");
  assert.equal(pionRes.answers[1].id, null);
  assert.equal(pionRes.answers[1].added, 1, "only complete line w1 counted; incomplete trailing line buffered");
  assert.deepEqual(pionRes.answers[2].id, ["arr", "中文🚀", 42]);
  assert.equal(pionRes.answers[2].added, 0);
  assert.equal(pionRes.answers[3].id, "str-err-id");
  assert.equal(pionRes.answers[3].error, "no data directory");
  assert.deepEqual(pionRes.db, mbRes.db, "DB state after wire edge cases must be 0-diff");

  // Also test > 1 MiB transcript where a multi-byte UTF-8 call id ("中"/"🚀") straddles the exact CHUNK=1,048,576 boundary.
  {
    const CHUNK = 1_048_576;
    const bigDir = tempdir("w6-usage-chunk-utf8-");
    const bigWs = join(bigDir, "ws-big");
    mkdirSync(bigWs, { recursive: true });
    const bigTranscript = join(bigDir, "transcripts/claude", claudeProject(bigWs), "rbig.jsonl");
    mkdirSync(dirname(bigTranscript), { recursive: true });

    const crossId = "c-中文-🚀-cross";
    const crossLine = `${claudeLine(crossId, t0 + 9_000, "claude-opus-5-5", 77, 88)}\n`;
    const crossBuf = Buffer.from(crossLine, "utf8");
    const rocketInLine = crossBuf.indexOf(Buffer.from("🚀", "utf8"));
    assert.ok(rocketInLine > 0, "crossLine must contain 🚀");
    // Pad prefix lines so that `rocketInLine + 2` lands at exact byte offset CHUNK (1,048,576).
    const targetPrefixBytes = CHUNK - (rocketInLine + 2);
    const prefixChunks: Buffer[] = [];
    let prefixLen = 0;
    let padIdx = 0;
    while (prefixLen + 4000 < targetPrefixBytes) {
      const line = `${claudeLine(`p${padIdx++}`, t0 + 1_000 + padIdx, "claude-opus-5-5", 1, 1, { pad: "x".repeat(3800) })}\n`;
      const b = Buffer.from(line, "utf8");
      prefixChunks.push(b);
      prefixLen += b.length;
    }
    const baseExact = `${claudeLine(`p${padIdx++}`, t0 + 5_000, "claude-opus-5-5", 1, 1, { pad: "y" })}\n`;
    const remain = targetPrefixBytes - prefixLen - Buffer.byteLength(baseExact, "utf8");
    assert.ok(remain >= 0, `expected non-negative exact padding, got ${remain}`);
    const exactLine = `${claudeLine(`p${padIdx - 1}`, t0 + 5_000, "claude-opus-5-5", 1, 1, { pad: "y".repeat(remain + 1) })}\n`;
    prefixChunks.push(Buffer.from(exactLine, "utf8"));
    const prefixBuf = Buffer.concat(prefixChunks);
    assert.equal(prefixBuf.length, targetPrefixBytes);
    assert.equal(prefixBuf.length + rocketInLine + 2, CHUNK, "🚀 must straddle CHUNK=1,048,576 exactly");
    writeFileSync(bigTranscript, Buffer.concat([prefixBuf, crossBuf]));

    const runBig = async (label: string, bin: string) => {
      const store = Store.open(join(bigDir, `${label}.db`), null, time.clock);
      cleanup.unshift(() => store.close());
      store.insertSession({
        key: "kbig",
        connect: "ember",
        runtime: "claude",
        profile: "cc",
        workspace: bigWs,
        token: "tok",
        createdAt: t0 - 1_000,
        lastActiveAt: t0 - 1_000,
        ws: "mine",
      });
      store.setRuntimeSessionId("kbig", "rbig");
      store.startTurn("tbig", "kbig", "input");
      const counter = new UsageCounter({ store, config: () => ({ dataDir: bigDir, profiles: [] }), clock: time.clock, mb: bin });
      cleanup.unshift(() => counter.stop());
      await counter.read(new Set(["kbig"]));
      const found = store.db.prepare("SELECT id, input, output FROM usage WHERE id = ?").get(crossId) as
        | { id: string; input: number; output: number }
        | undefined;
      assert.ok(found, `${label}: must decode cross-CHUNK multi-byte call id`);
      assert.deepEqual({ ...found }, { id: crossId, input: 77, output: 88 }, `${label}: must decode cross-CHUNK multi-byte call id`);
      const off = (store.db.prepare("SELECT offset FROM usage_files").get() as { offset: number }).offset;
      assert.equal(off, prefixBuf.length + crossBuf.length, `${label}: exact byte offset`);
      return dumpUsageDb(store);
    };

    const mbBig = await runBig("mb", bins.mb);
    const pionBig = await runBig("pion", bins.pion);
    assert.deepEqual(pionBig, mbBig, ">1 MiB cross-CHUNK UTF-8 transcript must be 0-diff between MB and Pion");
  }
});

test("production new UsageCounter (no mb): cold-start/hot-reload hits Pion on first spawn, mb:null throws, hot-switch does not disrupt in-flight read", async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;

  const dir = tempdir("w6-usage-prod-");
  const time = testClock();
  const t0 = Date.parse("2026-11-24T14:00:00Z");
  await time.adjust(t0);

  const mbLog = join(dir, "mb-spawns.log");
  const pionLog = join(dir, "pion-spawns.log");
  const mbWrap = makeRecordingWrapper(dir, "mb-wrap.sh", bins.mb, mbLog);

  // Event-driven localhost TCP handshake (zero setTimeout/setInterval polling):
  // wrapper connects on request #2, signals "seen", and waits for the test to send "go"
  // after hot-switching config, proving read #2 is truly in-flight on the live Pion worker.
  let gateSocket: Socket | null = null;
  let gateReleased = false;
  let resolveReq2Seen!: () => void;
  const req2SeenPromise = new Promise<void>((r) => {
    resolveReq2Seen = r;
  });
  const releaseReq2Gate = () => {
    gateReleased = true;
    if (gateSocket && !gateSocket.destroyed) {
      gateSocket.end("go\n");
    }
  };
  const gateServer = createServer((sock) => {
    gateSocket = sock;
    if (gateReleased) {
      sock.end("go\n");
    }
    resolveReq2Seen();
  });
  await new Promise<void>((resolve) => gateServer.listen(0, "127.0.0.1", () => resolve()));
  const gatePort = (gateServer.address() as AddressInfo).port;
  const cleanupGateServer = () => {
    releaseReq2Gate();
    if (gateSocket && !gateSocket.destroyed) {
      gateSocket.destroy();
    }
    return new Promise<void>((resolve) => gateServer.close(() => resolve()));
  };
  cleanup.unshift(cleanupGateServer);

  const pionGateJs = join(dir, "pion-gate.mjs");
  writeFileSync(
    pionGateJs,
    `import { spawn } from "node:child_process";
import { appendFileSync } from "node:fs";
import { createConnection } from "node:net";
const [realBin, logFile, gatePortStr, ...args] = process.argv.slice(2);
const gatePort = Number(gatePortStr);
appendFileSync(logFile, args.join(" ") + "\\n");
const child = spawn(realBin, args, { stdio: ["pipe", "inherit", "inherit"] });
let pending = Buffer.alloc(0);
let reqCount = 0;
let chain = Promise.resolve();
let failed = false;
const GO_TOKEN = Buffer.from("go\\n");
function waitForGate() {
  return new Promise((resolve, reject) => {
    const sock = createConnection({ host: "127.0.0.1", port: gatePort });
    let chunks = [];
    let settled = false;
    const ok = () => {
      if (settled) return;
      settled = true;
      sock.destroy();
      resolve();
    };
    const fail = (reason) => {
      if (settled) return;
      settled = true;
      sock.destroy();
      reject(new Error("gate handshake failed: " + reason));
    };
    sock.on("data", (d) => {
      chunks.push(d);
      if (Buffer.concat(chunks).includes(GO_TOKEN)) ok();
    });
    sock.once("end", () => fail("premature EOF before go"));
    sock.once("close", () => fail("socket closed before go"));
    sock.once("error", (err) => fail(err?.message ?? String(err)));
  });
}
process.stdin.on("data", (chunk) => {
  pending = Buffer.concat([pending, chunk]);
  let idx;
  while ((idx = pending.indexOf(0x0a)) >= 0) {
    const lineBuf = pending.subarray(0, idx + 1);
    pending = pending.subarray(idx + 1);
    const n = ++reqCount;
    chain = chain
      .then(async () => {
        if (failed) return;
        if (n === 2) await waitForGate();
        child.stdin.write(lineBuf);
      })
      .catch((err) => {
        failed = true;
        process.stderr.write(String(err) + "\\n");
        child.stdin.destroy();
        child.kill("SIGTERM");
        process.exit(1);
      });
  }
});
process.stdin.on("end", () => {
  void chain.finally(() => {
    if (failed) return;
    if (pending.length > 0) child.stdin.write(pending);
    child.stdin.end();
  });
});
child.on("exit", (code, sig) => process.exit(code ?? (sig ? 1 : 0)));
`,
    "utf8",
  );
  const pionWrap = join(dir, "pion-wrap.sh");
  writeFileSync(
    pionWrap,
    `#!/bin/sh\nexec ${JSON.stringify(process.execPath)} ${JSON.stringify(pionGateJs)} ${JSON.stringify(bins.pion)} ${JSON.stringify(pionLog)} ${JSON.stringify(String(gatePort))} "$@"\n`,
    { mode: 0o755 },
  );

  const ws = join(dir, "ws-prod");
  mkdirSync(ws, { recursive: true });
  const transcript = join(dir, "transcripts/claude", claudeProject(ws), "rp.jsonl");
  appendLines(transcript, [claudeLine("p1", t0 + 1_000, "claude-opus-5-5", 11, 22)]);

  const store = Store.open(join(dir, "prod.db"), null, time.clock);
  cleanup.unshift(() => store.close());
  store.insertSession({
    key: "kp",
    connect: "ember",
    runtime: "claude",
    profile: "cc",
    workspace: ws,
    token: "tok",
    createdAt: t0 - 1_000,
    lastActiveAt: t0 - 1_000,
    ws: "mine",
  });
  store.setRuntimeSessionId("kp", "rp");
  store.startTurn("tp", "kp", "input");

  // 1. Explicit mb: null must throw missing-reader error
  assert.throws(
    () => new UsageCounter({ store, config: () => ({ dataDir: dir, profiles: [] }), clock: time.clock, mb: null }),
    /needs the MoonBit reader/,
  );

  // 2. Cold-start with suspended probe: first spawn of production `new UsageCounter` (no `mb`) hits Pion
  await withEnv(
    {
      STILLFAIL_MB_READER: mbWrap,
      STILLFAIL_PION_READER: pionWrap,
      STILLFAIL_READER_USAGE_COUNTER: undefined,
      STILLFAIL_READER_ENGINE: undefined,
    },
    async () => {
      let releaseProbe!: () => void;
      const probeGate = new Promise<void>((r) => {
        releaseProbe = r;
      });
      let probeCalls = 0;
      setPionProbeRunnerForTest(async () => {
        probeCalls++;
        await probeGate;
        return new Set(["usage-counter"]);
      });
      try {
        let currentEngine: "pion" | "mb" = "pion";
        const counter = new UsageCounter({
          store,
          config: () => ({ dataDir: dir, profiles: [] }),
          clock: time.clock,
          readers: () => ({ readers: { "usage-counter": currentEngine } }),
        });
        cleanup.unshift(() => counter.stop());

        const firstRead = counter.read(new Set(["kp"]));
        // While probe is suspended, neither binary has spawned yet
        await new Promise((r) => setImmediate(r));
        assert.equal(probeCalls, 1, "probe must start once on cold start");
        assert.equal(readSpawns(mbLog).length, 0, "0 MB spawns while probe pending");
        assert.equal(readSpawns(pionLog).length, 0, "0 Pion spawns while probe pending");

        releaseProbe();
        const added1 = await firstRead;
        assert.equal(added1, 1);
        assert.equal(readSpawns(pionLog).length, 1, "first spawn must hit Pion wrapper");
        assert.equal(readSpawns(mbLog).length, 0, "MB must not be spawned on cold start");
        assert.match(readSpawns(pionLog)[0]!, /--builder usage-counter/);

        // 3. Real in-flight hot-switch (Pion -> MB): pause 2nd request inside Pion wrapper via
        //    event-driven TCP handshake, flip config to "mb" while read #2 is truly in flight, then release.
        //    Race req2SeenPromise against inFlight so gate or worker-reuse regressions fail fast.
        appendLines(transcript, [claudeLine("p2", t0 + 2_000, "claude-opus-5-5", 13, 24)]);
        const inFlight = counter.read(new Set(["kp"]));
        const gateOutcome = await Promise.race([
          req2SeenPromise.then(() => ({ kind: "seen" as const })),
          inFlight.then(
            (count) => ({ kind: "bypassed" as const, count }),
            (err: unknown) => ({ kind: "error" as const, err }),
          ),
        ]);
        if (gateOutcome.kind === "error") throw gateOutcome.err;
        if (gateOutcome.kind === "bypassed") {
          assert.fail(
            `2nd read completed (${gateOutcome.count}) before gate; worker not reused`,
          );
        }
        currentEngine = "mb";
        assert.equal(readSpawns(mbLog).length, 0, "no MB spawn while Pion read is in flight");
        releaseReq2Gate();
        assert.equal(await inFlight, 1, "in-flight read must complete uninterrupted during hot-switch");
        assert.equal(readSpawns(pionLog).length, 1, "in-flight read reused existing Pion worker");
        assert.equal(readSpawns(mbLog).length, 0, "no MB spawn until worker recycles");

        assert.equal(counter.trimIdle(), 1, "trimIdle releases idle Pion worker");
        appendLines(transcript, [claudeLine("p3", t0 + 3_000, "claude-opus-5-5", 15, 26)]);
        assert.equal(await counter.read(new Set(["kp"])), 1);
        assert.equal(readSpawns(mbLog).length, 1, "next spawn after trimIdle picks up hot-switched MB engine");
        assert.match(readSpawns(mbLog)[0]!, /--builder usage-counter/);

        // 4. MB -> Pion hot-reload with suspended probe: recycle MB worker, suspend probe,
        //    verify first read after recycle spawns ONLY Pion wrapper.
        currentEngine = "pion";
        assert.equal(counter.trimIdle(), 1, "trimIdle releases idle MB worker");
        resetReaderSelectionStateForTest();
        let releaseProbe2!: () => void;
        const probeGate2 = new Promise<void>((r) => {
          releaseProbe2 = r;
        });
        let probeCalls2 = 0;
        setPionProbeRunnerForTest(async () => {
          probeCalls2++;
          await probeGate2;
          return new Set(["usage-counter"]);
        });
        appendLines(transcript, [claudeLine("p4", t0 + 4_000, "claude-opus-5-5", 17, 28)]);
        const reloadRead = counter.read(new Set(["kp"]));
        await new Promise((r) => setImmediate(r));
        assert.equal(probeCalls2, 1, "hot-reload probe must start once");
        assert.equal(readSpawns(pionLog).length, 1, "0 new Pion spawns while hot-reload probe is pending");
        assert.equal(readSpawns(mbLog).length, 1, "0 new MB spawns while hot-reload probe is pending");
        releaseProbe2();
        assert.equal(await reloadRead, 1);
        assert.equal(readSpawns(pionLog).length, 2, "hot-reload first spawn hits Pion wrapper");
        assert.equal(readSpawns(mbLog).length, 1, "hot-reload must not spawn MB");

        await counter.stop();
      } finally {
        releaseReq2Gate();
        setPionProbeRunnerForTest(null);
        resetReaderSelectionStateForTest();
      }
    },
  );
});
