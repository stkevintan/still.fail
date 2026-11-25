import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, sep } from "node:path";
import { test } from "node:test";
import {
  MbProcess,
  mbReaderBinary,
  pionBinary,
  probePionSupportedModes,
  resetReaderSelectionStateForTest,
  resolveReaderSelection,
} from "../src/read/mb-reader.ts";
import { LiveLocator } from "../src/sessions/live-locator.ts";
import { Store } from "../src/store/store.ts";

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
  assert.match(ver, /modes:[^\n]*live-locator/, `Pion --version must advertise live-locator: ${ver}`);
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

function makeFixture() {
  const dir = mkdtempSync(join(tmpdir(), "w6-locate-switch-"));
  const dbPath = join(dir, "stillfail.db");
  const store = Store.open(dbPath);
  const wsA = join(dir, "wsA");
  const wsB = join(dir, "wsB");
  const wsSnap = join(dir, "wsSnap");
  mkdirSync(wsA, { recursive: true });
  mkdirSync(wsB, { recursive: true });
  mkdirSync(wsSnap, { recursive: true });
  const profHome = join(dir, "home");
  mkdirSync(join(profHome, "projects"), { recursive: true });

  // Session A: claude with 2 transcripts under shared transcripts/claude/<project>/<id>.jsonl
  store.insertSession({
    key: "ses-a",
    connect: "ember",
    runtime: "claude",
    profile: "p1",
    workspace: wsA,
    token: "tok-a",
    createdAt: 100,
    lastActiveAt: 100,
    ws: "mine",
  });
  store.setRuntimeSessionId("ses-a", "rt-a1");
  store.db.prepare("INSERT INTO runtime_sessions (session_key, id, runtime, profile, at) VALUES (?, ?, ?, ?, ?)").run("ses-a", "rt-a0", "claude", "p1", 50);
  store.db.prepare("INSERT INTO runtime_sessions (session_key, id, runtime, profile, at) VALUES (?, ?, ?, ?, ?)").run("ses-a", "rt-a1", "claude", "p1", 100);

  const projA = wsA.replace(/[^a-zA-Z0-9]/g, "-");
  const sharedClaudeA = join(dir, "transcripts", "claude", projA);
  mkdirSync(sharedClaudeA, { recursive: true });
  writeFileSync(join(sharedClaudeA, "rt-a0.jsonl"), "{\"type\":\"a0\"}\n");
  writeFileSync(join(sharedClaudeA, "rt-a1.jsonl"), "{\"type\":\"a1\"}\n");

  // Session B: agy with 1 transcript under shared transcripts/agy/<id>.jsonl
  store.insertSession({
    key: "ses-b",
    connect: "ember",
    runtime: "agy",
    profile: "p1",
    workspace: wsB,
    token: "tok-b",
    createdAt: 200,
    lastActiveAt: 200,
    ws: "mine",
  });
  store.setRuntimeSessionId("ses-b", "rt-b1");
  const sharedAgy = join(dir, "transcripts", "agy");
  mkdirSync(sharedAgy, { recursive: true });
  writeFileSync(join(sharedAgy, "rt-b1.jsonl"), "{\"type\":\"b1\"}\n");

  // Session C: codex session for empty/duplicate `said` hints 0-diff parity
  store.insertSession({
    key: "ses-codex",
    connect: "ember",
    runtime: "codex",
    profile: "p1",
    workspace: wsA,
    token: "tok-c",
    createdAt: 250,
    lastActiveAt: 250,
    ws: "mine",
  });
  store.setRuntimeSessionId("ses-codex", "cx-1");
  store.db.prepare("INSERT INTO runtime_sessions (session_key, id, runtime, profile, at) VALUES (?, ?, ?, ?, ?)").run("ses-codex", "cx-1", "codex", "p1", 250);

  // Session Snap: 70 runtime_sessions spanning the 64-entry batch boundary + pre-created rt-new on disk
  store.insertSession({
    key: "ses-snap",
    connect: "ember",
    runtime: "agy",
    profile: "p1",
    workspace: wsSnap,
    token: "tok-snap",
    createdAt: 300,
    lastActiveAt: 300,
    ws: "mine",
  });
  store.setRuntimeSessionId("ses-snap", "snap-069");
  const ins = store.db.prepare("INSERT INTO runtime_sessions (session_key, id, runtime, profile, at) VALUES (?, ?, ?, ?, ?)");
  for (let i = 0; i < 70; i++) {
    const id = `snap-${String(i).padStart(3, "0")}`;
    ins.run("ses-snap", id, "agy", "p1", 300 + i);
    writeFileSync(join(sharedAgy, `${id}.jsonl`), `{"type":"${id}"}\n`);
  }
  // Pre-create the 71st transcript file on disk before inserting its DB row mid-locate
  writeFileSync(join(sharedAgy, "snap-new.jsonl"), "{\"type\":\"snap-new\"}\n");

  return { dir, dbPath, store, profHome, wsA, wsB, sharedAgy };
}

class MessageQueue {
  #items: any[] = [];
  #waiters: ((v: any) => void)[] = [];
  push(v: any) {
    const w = this.#waiters.shift();
    if (w) w(v);
    else this.#items.push(v);
  }
  next(): Promise<any> {
    if (this.#items.length > 0) return Promise.resolve(this.#items.shift());
    return new Promise((resolve) => this.#waiters.push(resolve));
  }
}

test("live-locator Pion protocol: interleaved A/B ACK, accepted:false retry, cancel A while B finishes, unknown cancel, error phase, multi-batch snapshot isolation, Codex hints 0-diff", async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;
  const { mb, pion } = bins;
  const fx = makeFixture();
  const proc = new MbProcess(pion, ["--builder", "live-locator", "--db", fx.dbPath, "--data", fx.dir, "--sep", sep]);
  const q = new MessageQueue();
  proc.on("message", (m: any) => q.push(m));
  try {
    const profiles = [{ id: "p1", home: fx.profHome }];

    // 1. Interleaved A (id=1) and B (id=2): answer B before A, test accepted:false retry on A
    proc.postMessage({ type: "locate", id: 1, key: "ses-a", profiles });
    proc.postMessage({ type: "locate", id: 2, key: "ses-b", profiles });
    // Duplicate in-flight locate for id=1 must be ignored
    proc.postMessage({ type: "locate", id: 1, key: "ses-a", profiles });

    const h1 = await q.next();
    const h2 = await q.next();
    assert.equal(h1.type, "hints");
    assert.equal(h1.id, 1);
    assert.equal(h2.type, "hints");
    assert.equal(h2.id, 2);

    // Reply B first -> B gets batch, accepts, finishes done while A is still waiting on hints!
    proc.postMessage({ type: "hints", id: 2, hints: { elsewhere: [], rollouts: [], said: [] } });
    const bBatch = await q.next();
    assert.equal(bBatch.type, "batch");
    assert.equal(bBatch.id, 2);
    assert.equal(bBatch.current, true);
    assert.equal(bBatch.paths.length, 1);
    proc.postMessage({ type: "accepted", id: 2, accepted: true });
    const bDone = await q.next();
    assert.equal(bDone.type, "done");
    assert.equal(bDone.id, 2);
    assert.equal(bDone.runtime, "agy");
    assert.equal(bDone.current, true);
    assert.equal(typeof bDone.identity?.tokenHash, "string");
    assert.equal(bDone.identity.tokenHash.length, 64);

    // Reply A hints -> batch -> reject with accepted:false -> must re-ask hints for same batch!
    proc.postMessage({ type: "hints", id: 1, hints: { elsewhere: [], rollouts: [], said: [] } });
    const aBatch1 = await q.next();
    assert.equal(aBatch1.type, "batch");
    assert.equal(aBatch1.id, 1);
    assert.equal(aBatch1.paths.length, 2);
    proc.postMessage({ type: "accepted", id: 1, accepted: false });
    const aReask = await q.next();
    assert.equal(aReask.type, "hints");
    assert.equal(aReask.id, 1);
    assert.deepEqual(aReask.sources, h1.sources);

    // Now accept A
    proc.postMessage({ type: "hints", id: 1, hints: { elsewhere: [], rollouts: [], said: [] } });
    const aBatch2 = await q.next();
    assert.equal(aBatch2.type, "batch");
    assert.equal(aBatch2.id, 1);
    proc.postMessage({ type: "accepted", id: 1, accepted: true });
    const aDone = await q.next();
    assert.equal(aDone.type, "done");
    assert.equal(aDone.id, 1);
    assert.equal(aDone.current, true);

    // 2. Unknown id cancel -> cancelled
    proc.postMessage({ type: "cancel", id: 999 });
    const unkCancel = await q.next();
    assert.deepEqual(unkCancel, { type: "cancelled", id: 999 });

    // 3. Cancel A (id=10) while B (id=11) completes
    proc.postMessage({ type: "locate", id: 10, key: "ses-a", profiles });
    proc.postMessage({ type: "locate", id: 11, key: "ses-b", profiles });
    const h10 = await q.next();
    const h11 = await q.next();
    assert.equal(h10.id, 10);
    assert.equal(h11.id, 11);

    proc.postMessage({ type: "cancel", id: 10 });
    const c10 = await q.next();
    assert.deepEqual(c10, { type: "cancelled", id: 10 });

    proc.postMessage({ type: "hints", id: 11, hints: { elsewhere: [], rollouts: [], said: [] } });
    const b11 = await q.next();
    assert.equal(b11.id, 11);
    assert.equal(b11.paths.length, 1);
    proc.postMessage({ type: "accepted", id: 11, accepted: true });
    const d11 = await q.next();
    assert.equal(d11.type, "done");
    assert.equal(d11.id, 11);

    // 4. Multi-batch snapshot isolation across the 64-entry batch boundary:
    //    Insert `snap-new` (whose file already exists on disk) AFTER batch 1's hints arrive
    //    (proving the DB snapshot was released and doesn't block WAL writers).
    //    The in-flight locate must return exactly 70 paths without `snap-new`;
    //    the immediately following locate must return 71 paths including `snap-new`.
    proc.postMessage({ type: "locate", id: 15, key: "ses-snap", profiles });
    const snapH1 = await q.next();
    assert.equal(snapH1.type, "hints");
    assert.equal(snapH1.id, 15);
    assert.equal(snapH1.sources.length, 64);

    // Mutate DB while locate id=15 is paused between batch 1 and batch 2
    fx.store.db.prepare("INSERT INTO runtime_sessions (session_key, id, runtime, profile, at) VALUES (?, ?, ?, ?, ?)").run("ses-snap", "snap-new", "agy", "p1", 999);

    const inFlightPaths: { path: string }[] = [];
    proc.postMessage({ type: "hints", id: 15, hints: { elsewhere: [], rollouts: [], said: [] } });
    for (;;) {
      const m = await q.next();
      assert.equal(m.id, 15);
      if (m.type === "hints") {
        proc.postMessage({ type: "hints", id: 15, hints: { elsewhere: [], rollouts: [], said: [] } });
      } else if (m.type === "batch") {
        inFlightPaths.push(...m.paths);
        proc.postMessage({ type: "accepted", id: 15, accepted: true });
      } else {
        assert.equal(m.type, "done");
        break;
      }
    }
    assert.equal(inFlightPaths.length, 70, "in-flight multi-batch locate must stay on its snapshot");
    assert.ok(!inFlightPaths.some((p) => p.path.includes("snap-new")), "in-flight locate must NOT include post-snapshot row");

    // Next locate sees the newly committed 71st row
    proc.postMessage({ type: "locate", id: 16, key: "ses-snap", profiles });
    const nextPaths: { path: string }[] = [];
    for (;;) {
      const m = await q.next();
      assert.equal(m.id, 16);
      if (m.type === "hints") {
        proc.postMessage({ type: "hints", id: 16, hints: { elsewhere: [], rollouts: [], said: [] } });
      } else if (m.type === "batch") {
        nextPaths.push(...m.paths);
        proc.postMessage({ type: "accepted", id: 16, accepted: true });
      } else {
        assert.equal(m.type, "done");
        break;
      }
    }
    assert.equal(nextPaths.length, 71, "subsequent locate must see newly inserted runtime_session");
    assert.ok(nextPaths.some((p) => p.path.includes("snap-new")), "subsequent locate must include snap-new.jsonl");

    // 5. Wrong phase error removes only that id and returns exact error message
    proc.postMessage({ type: "locate", id: 20, key: "ses-b", profiles });
    await q.next(); // hints
    proc.postMessage({ type: "accepted", id: 20, accepted: true }); // wrong phase!
    const err20 = await q.next();
    assert.equal(err20.type, "error");
    assert.equal(err20.id, 20);
    assert.equal(err20.error, "expected transcript location hints");

    // 6. Dual-binary 0-diff parity vs MB on:
    //    (a) normal claude session,
    //    (b) Codex session with empty `said:[["x",[]]]`, duplicate id replacement, and missing `seen` key!
    const runWire = async (bin: string, key: string, hintsPayload: Record<string, unknown>) => {
      const p = new MbProcess(bin, ["--builder", "live-locator", "--db", fx.dbPath, "--data", fx.dir, "--sep", sep]);
      const mq = new MessageQueue();
      p.on("message", (m: any) => mq.push(m));
      try {
        p.postMessage({ type: "locate", id: 1, key, profiles });
        const out: any[] = [];
        for (;;) {
          const msg = await mq.next();
          out.push(msg);
          if (msg.type === "hints") p.postMessage({ type: "hints", id: 1, hints: hintsPayload });
          else if (msg.type === "batch") p.postMessage({ type: "accepted", id: 1, accepted: true });
          else break;
        }
        return out;
      } finally {
        await p.terminate();
      }
    };

    const [mbA, pionA] = await Promise.all([
      runWire(mb, "ses-a", { elsewhere: [], rollouts: [], said: [] }),
      runWire(pion, "ses-a", { elsewhere: [], rollouts: [], said: [] }),
    ]);
    assert.deepEqual(pionA, mbA, "Pion live-locator wire output must match MB 0-diff on claude");

    const codexHints = {
      elsewhere: [],
      rollouts: [],
      said: [
        ["x", []],
        ["dup", [["/d1", { suffix: ".jsonl", seen: true }]]],
        ["dup", [["/d2", { suffix: ".jsonl", seen: false }], ["/d3", { suffix: ".jsonl" }]]],
      ],
    };
    const [mbCodex, pionCodex] = await Promise.all([
      runWire(mb, "ses-codex", codexHints),
      runWire(pion, "ses-codex", codexHints),
    ]);
    assert.deepEqual(pionCodex, mbCodex, "Pion live-locator wire output must match MB 0-diff on Codex hints with empty said:[[\"x\",[]]], duplicate id, and missing seen");
  } finally {
    await proc.terminate();
    fx.store.close();
    rmSync(fx.dir, { recursive: true, force: true });
  }
});

test("production LiveLocator switches cleanly between real MB and real Pion wrappers via ReaderConfig and rejects shadow", async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;
  const { mb, pion } = bins;
  const fx = makeFixture();
  const mbLog = join(fx.dir, "mb-spawns.log");
  const pionLog = join(fx.dir, "pion-spawns.log");
  const mbWrap = makeRecordingWrapper(fx.dir, "mb-wrap.sh", mb, mbLog);
  const pionWrap = makeRecordingWrapper(fx.dir, "pion-wrap.sh", pion, pionLog);

  await withEnv({ STILLFAIL_MB_READER: mbWrap, STILLFAIL_PION_READER: pionWrap }, async () => {
    let modeCfg: "mb" | "pion" | "shadow" = "mb";
    const profiles = [{ id: "p1", home: fx.profHome }];
    const locator = new LiveLocator(
      fx.dir,
      (k) => fx.store.getSession(k),
      () => profiles,
      undefined,
      undefined,
      () => ({ readers: { "live-locator": modeCfg } }),
    );
    try {
      // 1. Default / mb + TRUE IN-FLIGHT hot-switch:
      //    Start locate #1 on real MB, hold the first `{ type: "hints" }` ACK reply to MB mid-flight
      //    (proving locate #1 is still active and has NOT received `done`), flip `modeCfg = "pion"`,
      //    release the held ACK, verify locate #1 completes cleanly on the old MB worker (0 Pion spawns),
      //    then trimIdle() and issue locate #2 -> verify locate #2 spawns Pion wrapper!
      assert.equal(resolveReaderSelection("live-locator", { config: { readers: { "live-locator": "mb" } } }).primaryBinary, mbWrap);
      const inFlightLocator = new LiveLocator(
        fx.dir,
        (k) => fx.store.getSession(k),
        () => profiles,
        undefined,
        undefined,
        () => ({ readers: { "live-locator": modeCfg } }),
      );
      const origPost = MbProcess.prototype.postMessage;
      let releaseHintsAck: (() => void) | null = null;
      const hintsAckHeld = new Promise<void>((res) => {
        let held = false;
        MbProcess.prototype.postMessage = function (this: MbProcess, msg: unknown) {
          if (!held && typeof msg === "object" && msg !== null && (msg as { type?: string }).type === "hints") {
            held = true;
            MbProcess.prototype.postMessage = origPost;
            const self = this;
            releaseHintsAck = () => origPost.call(self, msg);
            res();
            return;
          }
          return origPost.call(this, msg);
        };
      });
      try {
        let locate1Settled = false;
        const locate1P = inFlightLocator.locate("ses-a").then((v) => {
          locate1Settled = true;
          return v;
        });
        await Promise.race([
          hintsAckHeld,
          locate1P.then(() => {
            throw new Error("locate #1 settled before hints ACK was intercepted");
          }),
        ]);
        assert.equal(locate1Settled, false, "locate #1 must still be in-flight at hints ACK (not done)");
        assert.equal(readSpawns(mbLog).filter((l) => l.includes("--builder live-locator")).length, 1, "MB wrapper must be running for locate #1");
        assert.equal(readSpawns(pionLog).length, 0, "0 Pion spawns before hot-reload");

        // Hot-reload config to pion while locate #1 is paused mid-flight!
        modeCfg = "pion";
        releaseHintsAck!();
        const resMb = await locate1P;
        assert.ok(resMb !== null && resMb.paths.length === 2);
        assert.equal(readSpawns(pionLog).length, 0, "in-flight locate #1 must finish on old MB worker without spawning/probing Pion");

        // 2. Shadow forbidden -> falls back to mb
        const shadowSel = resolveReaderSelection("live-locator", { config: { readers: { "live-locator": "shadow" } } });
        assert.equal(shadowSel.engine, "mb");
        assert.equal(shadowSel.selection.reason, "shadow-forbidden");

        // 3. After trimming idle MB worker, locate #2 probes Pion wrapper (`--version`) AND spawns Pion wrapper (`--builder live-locator`)!
        assert.equal(inFlightLocator.trimIdle(), 1);
        const resPion = await inFlightLocator.locate("ses-a");
        assert.deepEqual(resPion, resMb);
        const pionSpawns = readSpawns(pionLog);
        assert.ok(pionSpawns.some((l) => l.includes("--version")), `expected Pion --version probe, got: ${JSON.stringify(pionSpawns)}`);
        assert.equal(
          pionSpawns.filter((l) => l.includes("--builder live-locator")).length,
          1,
          `expected production LiveLocator to actually spawn Pion --builder live-locator, got: ${JSON.stringify(pionSpawns)}`,
        );
        assert.equal(
          readSpawns(mbLog).filter((l) => l.includes("--builder live-locator")).length,
          1,
          "MB wrapper must NOT be spawned again after switching to pion",
        );
        const modes = await probePionSupportedModes(pionWrap);
        assert.ok(modes?.has("live-locator"));
      } finally {
        MbProcess.prototype.postMessage = origPost;
        await inFlightLocator.close();
      }
    } finally {
      await locator.close();
      fx.store.close();
      rmSync(fx.dir, { recursive: true, force: true });
    }
  });
});
