import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { withBytes } from "../src/mesh/bus.ts";
import { Moves } from "../src/move/station.ts";
import { Fibers } from "../src/ops/fibers.ts";
import {
  MbProcess,
  mbReaderBinary,
  pionBinary,
  probePionSupportedModes,
  resetReaderSelectionStateForTest,
  resolveReaderSelection,
  resolveReaderSelectionAsync,
  setMbReaderBinaryOverrideForTest,
  setPionProbeRunnerForTest,
  warmPionProbeForConfig,
} from "../src/read/mb-reader.ts";
import { type ReaderSelectConfig, setReaderModeImplementedForTest } from "../src/read/reader-select.ts";
import { gatherSoon, inProgram, placeSoon, previewSoon } from "../src/replica/carry.ts";
import { readyFile, takeBackSoon } from "../src/replica/restore.ts";
import { Retire } from "../src/replica/retire.ts";
import { ProgramRunner } from "../src/replica/runner.ts";
import { Search } from "../src/search/search.ts";
import { restoreReaderConfig } from "../src/services.ts";
import { LiveLocator } from "../src/sessions/live-locator.ts";
import { Store } from "../src/store/store.ts";
import { UsageCounter } from "../src/usage/counter.ts";

function resolveDual(t: { skip: (msg: string) => void }): { mb: string; pion: string } | null {
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
  assert.notEqual(realpathSync(realMb), realpathSync(realPion), "MB and Pion binaries must be distinct");
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

/// Recording wrapper for `$STILLFAIL_PION_READER` that logs every invocation to `logFile`,
/// executes real `$BIN_PION` for `--version` and implemented modes (`live-locator`, etc.),
/// and forwards the 5 not-yet-implemented Wave 6 modes (`search`, `usage-counter`,
/// `replica-export`, `replica-carry`, `replica-restore`) to `$BIN_MB` ONLY AFTER recording
/// the Pion spawn in `logFile` so tests prove production DI actually selected & spawned Pion.
function makePionForwardingWrapper(dir: string, name: string, realPion: string, realMb: string, logFile: string): string {
  const wrapper = join(dir, name);
  const sh = [
    "#!/bin/sh",
    `printf '%s %s\\n' "$$" "$*" >> ${JSON.stringify(logFile)}`,
    'if [ "${1:-}" = "--builder" ]; then',
    '  case "${2:-}" in',
    "    search|usage-counter|replica-export|replica-carry|replica-restore)",
    `      exec ${JSON.stringify(realMb)} "$@"`,
    "      ;;",
    "  esac",
    "fi",
    `exec ${JSON.stringify(realPion)} "$@"`,
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

function countBuilder(logFile: string, mode: string): number {
  return readSpawns(logFile).filter((l) => l.includes(`--builder ${mode}`)).length;
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

function makeControlledProbe() {
  let calls = 0;
  let release!: (modes: ReadonlySet<string> | null) => void;
  const started = new Promise<void>((res) => {
    setPionProbeRunnerForTest(async () => {
      calls++;
      res();
      return new Promise<ReadonlySet<string> | null>((r) => {
        release = r;
      });
    });
  });
  return {
    get calls() { return calls; },
    started,
    release: (modes: ReadonlySet<string> | null) => release(modes),
  };
}

test("zero probe on default mb, explicit binary, baseline modes, and restore without ready.json", async (t) => {
  const bins = resolveDual(t);
  if (!bins) return;
  const { mb } = bins;
  resetReaderSelectionStateForTest();
  let probeCalls = 0;
  setPionProbeRunnerForTest(async () => {
    probeCalls++;
    return new Set(["footprint", "packed", "memory", "live-locator"]);
  });
  const dir = mkdtempSync(join(tmpdir(), "w6-zero-probe-"));
  try {
    assert.equal(resolveReaderSelection("live-locator", { env: {} }).engine, "mb");
    assert.equal(probeCalls, 0);

    assert.equal(resolveReaderSelection("live-locator", { binary: mb, config: { readers: { "live-locator": "pion" } }, env: {} }).primaryBinary, mb);
    assert.equal(probeCalls, 0);

    for (const m of ["footprint", "packed", "memory"] as const) {
      assert.equal(resolveReaderSelection(m, { config: { readers: { [m]: "pion" } }, env: {} }).engine, "pion");
    }
    assert.equal(probeCalls, 0);

    await warmPionProbeForConfig(undefined, {});
    await warmPionProbeForConfig({ readers: { footprint: "pion", packed: "pion", memory: "pion" } }, {});
    assert.equal(probeCalls, 0);

    const res = await takeBackSoon(dir, join(dir, "stillfail.db"), Date.now(), undefined, {
      readers: restoreReaderConfig({ readers: { "replica-restore": "pion" } }),
    });
    assert.equal(res, null);
    assert.equal(probeCalls, 0);
  } finally {
    rmSync(dir, { recursive: true, force: true });
    resetReaderSelectionStateForTest();
  }
});

test("warmPionProbeForConfig probes once when an implemented non-baseline non-restore mode requests pion", async (t) => {
  if (!resolveDual(t)) return;
  resetReaderSelectionStateForTest();
  let probeCalls = 0;
  setPionProbeRunnerForTest(async () => {
    probeCalls++;
    return new Set(["footprint", "packed", "memory", "live-locator"]);
  });
  try {
    await warmPionProbeForConfig({ readers: { "live-locator": "pion" } }, {});
    assert.equal(probeCalls, 1);
    const sel = resolveReaderSelection("live-locator", { config: { readers: { "live-locator": "pion" } }, env: {} });
    assert.equal(sel.engine, "pion");
    assert.equal(probeCalls, 1, "cached after warm");
  } finally {
    resetReaderSelectionStateForTest();
  }
});

test("cold-start pending probe -> first spawn hits Pion wrapper & pending close/stop causes 0 late spawns across LiveLocator, Search, public UsageCounter, and ProgramRunner", async (t) => {
  const bins = resolveDual(t);
  if (!bins) return;
  const { mb, pion } = bins;
  const dir = mkdtempSync(join(tmpdir(), "w6-cold-all4-"));
  const mbLog = join(dir, "mb.log");
  const pionLog = join(dir, "pion.log");
  const mbWrap = makeRecordingWrapper(dir, "mb-wrap.sh", mb, mbLog);
  const pionWrap = makePionForwardingWrapper(dir, "pion-wrap.sh", pion, mb, pionLog);

  const restores = [
    setReaderModeImplementedForTest("search", true),
    setReaderModeImplementedForTest("usage-counter", true),
    setReaderModeImplementedForTest("replica-export", true),
  ];
  await withEnv({ STILLFAIL_MB_READER: mbWrap, STILLFAIL_PION_READER: pionWrap }, async () => {
    const dbPath = join(dir, "stillfail.db");
    const store = Store.open(dbPath);
    store.insertSession({
      key: "k1", connect: "ember", runtime: "agy", profile: "p1", workspace: dir, token: "t", createdAt: 1, lastActiveAt: 1, ws: "mine",
    });
    const allModes = new Set(["footprint", "packed", "memory", "live-locator", "search", "usage-counter", "replica-export"]);
    try {
      // 1. LiveLocator: hot-reload to pion -> awaits pending probe -> first spawn hits Pion wrapper; close while pending -> 0 late spawns
      let locCfg: ReaderSelectConfig = { readers: { "live-locator": "mb" } };
      const locator = new LiveLocator(dir, (k) => store.getSession(k), () => [], undefined, undefined, () => locCfg);
      const ctrl1 = makeControlledProbe();
      locCfg = { readers: { "live-locator": "pion" } };
      const pLoc = locator.locate("k1");
      await ctrl1.started;
      assert.equal(locator.running, false);
      assert.equal(countBuilder(mbLog, "live-locator"), 0);
      ctrl1.release(allModes);
      assert.equal(await pLoc, null);
      assert.equal(countBuilder(pionLog, "live-locator"), 1, "LiveLocator first spawn must hit Pion wrapper");
      assert.equal(countBuilder(mbLog, "live-locator"), 0);
      await locator.close();

      resetReaderSelectionStateForTest();
      const ctrl1b = makeControlledProbe();
      const loc2 = new LiveLocator(dir, (k) => store.getSession(k), () => [], undefined, undefined, () => locCfg);
      const pLoc2 = loc2.locate("k1");
      await ctrl1b.started;
      const closeLoc2 = loc2.close();
      await assert.rejects(pLoc2, /cancelled/);
      ctrl1b.release(allModes);
      await closeLoc2;
      await probePionSupportedModes(pionWrap);
      await new Promise((r) => setImmediate(r));
      assert.equal(loc2.running, false);
      assert.equal(countBuilder(pionLog, "live-locator"), 1, "0 late LiveLocator spawns after close()");

      // 2. Search: pending probe -> first query hits Pion wrapper; stop while pending -> 0 late spawns
      resetReaderSelectionStateForTest();
      const ctrl2 = makeControlledProbe();
      const search = new Search({ data: dir, backfill: { readers: () => ({ readers: { search: "pion" } }) } });
      const pSearch = search.query("no-hit-xyz", { workspace: "mine", home: true, scopes: ["write"] }, { kinds: ["message"] });
      await ctrl2.started;
      assert.equal(search.running, false);
      assert.equal(countBuilder(mbLog, "search"), 0);
      ctrl2.release(allModes);
      await pSearch;
      assert.equal(countBuilder(pionLog, "search"), 1, "Search first spawn must hit Pion wrapper");
      assert.equal(countBuilder(mbLog, "search"), 0);
      await search.stop();

      resetReaderSelectionStateForTest();
      const ctrl2b = makeControlledProbe();
      const search2 = new Search({ data: dir, backfill: { readers: () => ({ readers: { search: "pion" } }) } });
      const pSearch2 = search2.query("no-hit-xyz", { workspace: "mine", home: true, scopes: ["write"] }, { kinds: ["message"] });
      await ctrl2b.started;
      const stopSearch2 = search2.stop();
      ctrl2b.release(allModes);
      await stopSearch2;
      await assert.rejects(pSearch2, /stopped/);
      await probePionSupportedModes(pionWrap);
      await new Promise((r) => setImmediate(r));
      assert.equal(search2.running, false);
      assert.equal(countBuilder(pionLog, "search"), 1, "0 late Search spawns after stop()");

      // 3. Public UsageCounter (NOT direct MbUsageCounter): pending probe -> first read hits Pion wrapper; stop while pending -> 0 late spawns
      resetReaderSelectionStateForTest();
      const ctrl3 = makeControlledProbe();
      const counter = new UsageCounter({
        store,
        config: () => ({ dataDir: dir, profiles: [] }),
        readers: () => ({ readers: { "usage-counter": "pion" } }),
      });
      const pUc = counter.read(new Set(["k1"]));
      await ctrl3.started;
      assert.equal(countBuilder(mbLog, "usage-counter"), 0);
      ctrl3.release(allModes);
      assert.equal(await pUc, 0);
      assert.equal(countBuilder(pionLog, "usage-counter"), 1, "Public UsageCounter first spawn must hit Pion wrapper");
      assert.equal(countBuilder(mbLog, "usage-counter"), 0);
      await counter.stop();

      resetReaderSelectionStateForTest();
      const ctrl3b = makeControlledProbe();
      const counter2 = new UsageCounter({
        store,
        config: () => ({ dataDir: dir, profiles: [] }),
        readers: () => ({ readers: { "usage-counter": "pion" } }),
      });
      const pUc2 = counter2.read(new Set(["k1"]));
      await ctrl3b.started;
      const stopUc2 = counter2.stop();
      ctrl3b.release(allModes);
      await stopUc2;
      await pUc2.catch(() => {});
      await probePionSupportedModes(pionWrap);
      await new Promise((r) => setImmediate(r));
      assert.equal(countBuilder(pionLog, "usage-counter"), 1, "0 late UsageCounter spawns after stop()");

      // 4. ProgramRunner: pending probe -> first ask hits Pion wrapper; close while pending -> 0 late spawns
      resetReaderSelectionStateForTest();
      const ctrl4 = makeControlledProbe();
      const runner = new ProgramRunner({
        db: dbPath,
        replica: join(dir, "replica"),
        dataDir: dir,
        origin: "st1",
        readers: () => ({ readers: { "replica-export": "pion" } }),
      });
      const pRun = runner.sources([]);
      await ctrl4.started;
      assert.equal(countBuilder(mbLog, "replica-export"), 0);
      ctrl4.release(allModes);
      assert.deepEqual(await pRun, {});
      assert.equal(countBuilder(pionLog, "replica-export"), 1, "ProgramRunner first spawn must hit Pion wrapper");
      assert.equal(countBuilder(mbLog, "replica-export"), 0);
      await runner.close();

      resetReaderSelectionStateForTest();
      const ctrl4b = makeControlledProbe();
      const runner2 = new ProgramRunner({
        db: dbPath,
        replica: join(dir, "replica"),
        dataDir: dir,
        origin: "st1",
        readers: () => ({ readers: { "replica-export": "pion" } }),
      });
      const pRun2 = runner2.sources([]);
      await ctrl4b.started;
      const closeRun2 = runner2.close();
      ctrl4b.release(allModes);
      await closeRun2;
      await assert.rejects(pRun2, /closed/);
      await probePionSupportedModes(pionWrap);
      await new Promise((r) => setImmediate(r));
      assert.equal(countBuilder(pionLog, "replica-export"), 1, "0 late ProgramRunner spawns after close()");
    } finally {
      for (const r of restores) r();
      store.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

test("Pion-only cold start (deterministic via setMbReaderBinaryOverrideForTest) succeeds via resolveReaderSelectionAsync and LiveLocator", async (t) => {
  const bins = resolveDual(t);
  if (!bins) return;
  const { pion } = bins;
  const dir = mkdtempSync(join(tmpdir(), "w6-pion-only-"));
  const pionLog = join(dir, "pion-only.log");
  const pionWrap = makeRecordingWrapper(dir, "pion-wrap.sh", pion, pionLog);

  await withEnv({ STILLFAIL_PION_READER: pionWrap }, async () => {
    setMbReaderBinaryOverrideForTest(() => null);
    const store = Store.open(join(dir, "stillfail.db"));
    store.insertSession({
      key: "k-only", connect: "ember", runtime: "agy", profile: "p1", workspace: dir, token: "t", createdAt: 1, lastActiveAt: 1, ws: "mine",
    });
    const cfg: ReaderSelectConfig = { readers: { "live-locator": "pion" } };
    const locator = new LiveLocator(dir, (k) => store.getSession(k), () => [], undefined, undefined, () => cfg);
    try {
      assert.equal(mbReaderBinary(), null, "MB binary must be deterministically null via test override");
      const sel = await resolveReaderSelectionAsync("live-locator", { config: cfg, env: {} });
      assert.equal(sel.engine, "pion");
      assert.equal(sel.primaryBinary, pionWrap);

      resetReaderSelectionStateForTest();
      setMbReaderBinaryOverrideForTest(() => null);
      assert.equal(await locator.locate("k-only"), null);
      assert.equal(countBuilder(pionLog, "live-locator"), 1, "Pion-only LiveLocator must spawn Pion wrapper directly");
    } finally {
      setMbReaderBinaryOverrideForTest(undefined);
      await locator.close();
      store.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

test("resolveReaderSelectionAsync & carry: concurrent callers share pending probe; abort A -> 'called off', B spawns Pion wrapper; post-probe spawn error rejects cleanly", async (t) => {
  const bins = resolveDual(t);
  if (!bins) return;
  const { mb, pion } = bins;
  const dir = mkdtempSync(join(tmpdir(), "w6-carry-async-"));
  const dbPath = join(dir, "stillfail.db");
  const store = Store.open(dbPath);
  const mbLog = join(dir, "mb.log");
  const pionLog = join(dir, "pion.log");
  const mbWrap = makeRecordingWrapper(dir, "mb-wrap.sh", mb, mbLog);
  const pionWrap = makePionForwardingWrapper(dir, "pion-wrap.sh", pion, mb, pionLog);

  const restoreCarry = setReaderModeImplementedForTest("replica-carry", true);
  await withEnv({ STILLFAIL_MB_READER: mbWrap, STILLFAIL_PION_READER: pionWrap }, async () => {
    try {
      // 1. resolveReaderSelectionAsync shared probe + abort A without cancelling B
      const ctrl = makeControlledProbe();
      const acA = new AbortController();
      const acB = new AbortController();
      const opts = { config: { readers: { "live-locator": "pion" } }, env: {} };
      const pA = resolveReaderSelectionAsync("live-locator", opts, acA.signal);
      const pB = resolveReaderSelectionAsync("live-locator", opts, acB.signal);
      await ctrl.started;
      assert.equal(ctrl.calls, 1);
      acA.abort();
      await assert.rejects(pA, /called off/);
      ctrl.release(new Set(["footprint", "packed", "memory", "live-locator"]));
      const resB = await pB;
      assert.equal(resB.engine, "pion");
      assert.equal(resB.primaryBinary, pionWrap);

      // 2. Two concurrent carry calls share pending probe -> abort A -> release WITH replica-carry -> B spawns PION wrapper!
      resetReaderSelectionStateForTest();
      const ctrlCarry = makeControlledProbe();
      const acCarryA = new AbortController();
      const carryCfg: ReaderSelectConfig = { readers: { "replica-carry": "pion" } };
      const carryA = inProgram<{ chats: number }>({ op: "preview", dataDir: dir, db: dbPath, ws: "w", home: true }, acCarryA.signal, undefined, carryCfg);
      const carryB = previewSoon(dir, dbPath, "w", true, carryCfg);
      await ctrlCarry.started;
      assert.equal(ctrlCarry.calls, 1, "two carry calls share one probe");
      acCarryA.abort();
      await assert.rejects(carryA, /called off/);

      ctrlCarry.release(new Set(["footprint", "packed", "memory", "live-locator", "replica-carry"]));
      const preview = await carryB;
      assert.equal(preview.chats, 0);
      assert.equal(countBuilder(pionLog, "replica-carry"), 1, "carry B must actually spawn Pion wrapper (not MB fallback)");
      assert.equal(countBuilder(mbLog, "replica-carry"), 0, "MB wrapper must NOT be spawned when replica-carry is supported");

      // 3. Post-probe postMessage throw in carry rejects cleanly (never hangs!)
      resetReaderSelectionStateForTest();
      const ctrlErr = makeControlledProbe();
      const origPost = MbProcess.prototype.postMessage;
      MbProcess.prototype.postMessage = () => {
        throw new Error("simulated postMessage boom");
      };
      try {
        const failingCarry = inProgram({ op: "preview", dataDir: dir, db: dbPath, ws: "w", home: true }, undefined, undefined, carryCfg);
        await ctrlErr.started;
        ctrlErr.release(new Set(["footprint", "packed", "memory", "live-locator", "replica-carry"]));
        await assert.rejects(failingCarry, /simulated postMessage boom/);
      } finally {
        MbProcess.prototype.postMessage = origPost;
      }
    } finally {
      restoreCarry();
      store.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

test("failed probe enters cooldown with reason pion-probe-failed and unsupported mode falls back to mb cleanly", async (t) => {
  const bins = resolveDual(t);
  if (!bins) return;
  const { mb } = bins;
  resetReaderSelectionStateForTest();
  try {
    let failCalls = 0;
    setPionProbeRunnerForTest(async () => {
      failCalls++;
      return null;
    });
    const resFail = await resolveReaderSelectionAsync("live-locator", {
      config: { readers: { "live-locator": "pion" } },
      env: {},
    });
    assert.equal(resFail.engine, "mb");
    assert.equal(resFail.primaryBinary, mb);
    assert.equal(resFail.selection.reason, "pion-probe-failed");
    assert.equal(failCalls, 1);

    const resCool = resolveReaderSelection("live-locator", {
      config: { readers: { "live-locator": "pion" } },
      env: {},
    });
    assert.equal(resCool.engine, "mb");
    assert.equal(resCool.selection.reason, "pion-probe-failed");
    assert.equal(failCalls, 1);

    resetReaderSelectionStateForTest();
    setPionProbeRunnerForTest(async () => new Set(["footprint", "packed", "memory"]));
    const resOld = await resolveReaderSelectionAsync("live-locator", {
      config: { readers: { "live-locator": "pion" } },
      env: {},
    });
    assert.equal(resOld.engine, "mb");
    assert.equal(resOld.selection.reason, "pion-binary-unsupported-mode");
  } finally {
    resetReaderSelectionStateForTest();
  }
});

test("dual-station MB vs Pion DI through real Retire (default & fallback preview), Handover, Moves (sizesSoon), and restoreReaderConfig", async (t) => {
  const bins = resolveDual(t);
  if (!bins) return;
  const { mb, pion } = bins;
  const dir = mkdtempSync(join(tmpdir(), "w6-dual-station-di-"));
  const st1Dir = join(dir, "st1");
  const st2Dir = join(dir, "st2");
  mkdirSync(st1Dir, { recursive: true });
  mkdirSync(st2Dir, { recursive: true });
  const st1Store = Store.open(join(st1Dir, "stillfail.db"));
  const st2Store = Store.open(join(st2Dir, "stillfail.db"));
  const mbLog = join(dir, "mb.log");
  const pionLog = join(dir, "pion.log");
  const mbWrap = makeRecordingWrapper(dir, "mb-wrap.sh", mb, mbLog);
  const pionWrap = makePionForwardingWrapper(dir, "pion-wrap.sh", pion, mb, pionLog);

  const restores = [
    setReaderModeImplementedForTest("replica-carry", true),
    setReaderModeImplementedForTest("replica-restore", true),
  ];
  await withEnv({ STILLFAIL_MB_READER: mbWrap, STILLFAIL_PION_READER: pionWrap }, async () => {
    setPionProbeRunnerForTest(async () => new Set(["footprint", "packed", "memory", "live-locator", "replica-carry", "replica-restore"]));
    const fibers1 = new Fibers("w6-st1");
    const fibers2 = new Fibers("w6-st2");
    try {
      // UsageCounter explicit mb: null must still preserve missing-binary error
      assert.throws(
        () => new UsageCounter({ store: st1Store, config: () => ({ dataDir: st1Dir, profiles: [] }), mb: null }),
        /MoonBit reader/,
      );

      const cfgMb: ReaderSelectConfig = { readers: { "replica-carry": "mb" } };
      const cfgPion: ReaderSelectConfig = { readers: { "replica-carry": "pion" } };

      const wsId = "01J00000000000000000000000";
      const hereId = "a".repeat(64);
      const peerId = "b".repeat(64);
      const emptyCarryBuf = Buffer.from(JSON.stringify({ v: 2, dataDir: "/from", sessions: [], gits: [], skipped: [], jobs: [], bundles: {}, files: 0, bytes: 0 }));
      const emptyCarryHash = createHash("sha256").update(emptyCarryBuf).digest("hex");
      const asBytes = (b: Buffer) => (async function* () { yield b; })();

      // 1. Real Retire (default preview, fallback preview, gather, AND place) for Station 1 (MB) vs Station 2 (Pion)
      const makeRetire = (
        data: string,
        fibers: Fibers,
        readers: () => ReaderSelectConfig,
        hooks?: { onAfterGather?: () => void; onAfterPlace?: () => void },
        work?: { gather: typeof gatherSoon; place: typeof placeSoon },
      ) =>
        new Retire({
          data,
          here: () => hereId,
          home: () => wsId,
          roster: () => [{ id: peerId, name: "peer" }],
          ask: async (_to: string, req: any) => {
            if (req.method === "retire.begin") return { ok: true, free: 10e9, clones: true };
            hooks?.onAfterGather?.();
            throw new Error("stop-after-gather");
          },
          askItself: async () => ({ ok: true }),
          fibers,
          changed: () => {},
          copies: {
            settleExport: async () => {},
            bringTo: async () => "g1",
            takeOver: async () => {
              hooks?.onAfterPlace?.();
              throw new Error("stop-after-place");
            },
            formerly: () => [],
            restored: () => null,
          },
          quiet: async () => [],
          unquiet: () => {},
          retired: () => {},
          accounts: { own: () => [], move: async () => ({ id: "p1" }) },
          connectsOf: () => [],
          bindingsOf: () => ({}),
          moveConnects: async () => {},
          took: () => {},
          reposDir: join(data, "repos"),
          connectsNamed: () => [],
          jobsIn: () => [],
          readers,
          ...(work ? { work } : {}),
        } as any);

      let r1Gathered!: () => void;
      const r1GatherDone = new Promise<void>((res) => { r1Gathered = res; });
      let r1Placed!: () => void;
      const r1PlaceDone = new Promise<void>((res) => { r1Placed = res; });
      let r2Gathered!: () => void;
      const r2GatherDone = new Promise<void>((res) => { r2Gathered = res; });
      let r2Placed!: () => void;
      const r2PlaceDone = new Promise<void>((res) => { r2Placed = res; });
      const r1 = makeRetire(st1Dir, fibers1, () => cfgMb, { onAfterGather: r1Gathered, onAfterPlace: r1Placed });
      const r2 = makeRetire(st2Dir, fibers2, () => cfgPion, { onAfterGather: r2Gathered, onAfterPlace: r2Placed });
      const r2Fallback = makeRetire(st2Dir, fibers2, () => cfgPion, undefined, { gather: gatherSoon, place: placeSoon });
      // (a) Retire.preview (default & fallback)
      await r1.preview(wsId);
      assert.equal(countBuilder(mbLog, "replica-carry"), 1, "Station 1 Retire.preview must spawn MB wrapper");
      assert.equal(countBuilder(pionLog, "replica-carry"), 0);
      await r2.preview(wsId);
      assert.equal(countBuilder(pionLog, "replica-carry"), 1, "Station 2 Retire.preview (default) must spawn Pion wrapper");
      await r2Fallback.preview(wsId);
      assert.equal(countBuilder(pionLog, "replica-carry"), 2, "Station 2 Retire.preview (fallback) must spawn Pion wrapper");

      // (b) Retire.gather (Station 1 -> MB, Station 2 -> Pion)
      await r1.retire(wsId, peerId, "me");
      await r1GatherDone;
      assert.equal(countBuilder(mbLog, "replica-carry"), 2, "Station 1 Retire gather must spawn MB wrapper");
      await r2.retire(wsId, peerId, "me");
      await r2GatherDone;
      assert.equal(countBuilder(pionLog, "replica-carry"), 3, "Station 2 Retire gather must spawn Pion wrapper");

      // (c) Retire.place (Station 1 -> MB, Station 2 -> Pion)
      const r1Ans = r1.answers(() => true);
      await r1Ans(peerId, { method: "retire.begin", workspace: wsId, origin: peerId, name: "peer" }, wsId);
      await r1Ans(peerId, withBytes({ method: "retire.put", workspace: wsId, origin: peerId, name: emptyCarryHash }, asBytes(emptyCarryBuf)), wsId);
      await r1Ans(peerId, { method: "retire.take", workspace: wsId, origin: peerId, carry: emptyCarryHash, gen: "g1-01234567", name: "peer", home: false, connects: {}, jobs: [] }, wsId);
      await r1PlaceDone;
      assert.equal(countBuilder(mbLog, "replica-carry"), 3, "Station 1 Retire place must spawn MB wrapper");

      const r2Ans = r2.answers(() => true);
      await r2Ans(peerId, { method: "retire.begin", workspace: wsId, origin: peerId, name: "peer" }, wsId);
      await r2Ans(peerId, withBytes({ method: "retire.put", workspace: wsId, origin: peerId, name: emptyCarryHash }, asBytes(emptyCarryBuf)), wsId);
      await r2Ans(peerId, { method: "retire.take", workspace: wsId, origin: peerId, carry: emptyCarryHash, gen: "g1-01234567", name: "peer", home: false, connects: {}, jobs: [] }, wsId);
      await r2PlaceDone;
      assert.equal(countBuilder(pionLog, "replica-carry"), 4, "Station 2 Retire place must spawn Pion wrapper");
      await r1.close();
      await r2.close();

      // 2. Real Moves (`move/station.ts`) driving:
      //    (a) standalone `sizesSoon` (`move.sizes`),
      //    (b) internally assembled `Moves.handover` `gather` (`handOver`),
      //    (c) internally assembled `Moves.handover` `place` (`handover.place`)!
      st1Store.insertSession({ key: "ho-1", connect: "ember", runtime: "agy", profile: "p1", workspace: join(st1Dir, "sessions", "ho-1"), token: "t1", createdAt: 1, lastActiveAt: 1, ws: wsId });
      st2Store.insertSession({ key: "ho-2", connect: "ember", runtime: "agy", profile: "p1", workspace: join(st2Dir, "sessions", "ho-2"), token: "t2", createdAt: 1, lastActiveAt: 1, ws: wsId });
      const makeMoves = (data: string, store: Store, fibers: Fibers, readers: () => ReaderSelectConfig) =>
        new Moves({
          data,
          here: () => hereId,
          home: () => wsId,
          roster: () => [{ id: peerId, name: "peer" }],
          ask: async (_to: string, req: any) => {
            if (req.method === "handover.begin") return { ok: true, id: req.id, free: 10e9, total: 10e9, git: true };
            throw new Error("stop-after-gather");
          },
          fibers,
          store,
          hub: { wsOf: () => wsId, busy: () => false, holdChat: async () => {}, releaseChat: () => true, wakeChat: () => {}, turnEnded: async () => {}, drained: async () => {} },
          connects: null,
          jobs: { up: () => [], stop: async () => {}, start: async () => {}, stopNamed: async () => {} },
          profiles: () => [{ id: "p1", runtime: "agy" }],
          moveProfile: async () => ({ ok: true }),
          sessionsIn: () => ({ rows: [], more: false }),
          reposDir: join(data, "repos"),
          changed: () => {},
          readers,
        } as any);

      const m1 = makeMoves(st1Dir, st1Store, fibers1, () => cfgMb);
      const m2 = makeMoves(st2Dir, st2Store, fibers2, () => cfgPion);
      const m1Ans = m1.answers(() => true);
      const m2Ans = m2.answers(() => true);

      // (a) Moves standalone `sizesSoon`
      await m1Ans(peerId, { method: "move.sizes", workspace: wsId, fromData: st1Dir, places: [] }, wsId);
      assert.equal(countBuilder(mbLog, "replica-carry"), 4, "Station 1 Moves move.sizes must spawn MB wrapper");
      await m2Ans(peerId, { method: "move.sizes", workspace: wsId, fromData: st2Dir, places: [] }, wsId);
      assert.equal(countBuilder(pionLog, "replica-carry"), 5, "Station 2 Moves move.sizes must spawn Pion wrapper");

      // (b) Moves-assembled `handover.handOver` (`gather`)
      await m1.handover.handOver("ho-1", peerId).catch(() => {});
      assert.equal(countBuilder(mbLog, "replica-carry"), 5, "Station 1 Moves.handover gather must spawn MB wrapper");
      await m2.handover.handOver("ho-2", peerId).catch(() => {});
      assert.equal(countBuilder(pionLog, "replica-carry"), 6, "Station 2 Moves.handover gather must spawn Pion wrapper");

      // (c) Moves-assembled `handover.place` (`place`)
      const hoIn1 = "ho-in-1";
      await m1Ans(peerId, { method: "handover.begin", workspace: wsId, origin: peerId, id: hoIn1, keys: ["ho-x"], ws: wsId, dataDir: "/from", accounts: {}, nowhere: [], connects: {}, described: [], stoppedFor: null, bindings: {} }, wsId);
      await m1Ans(peerId, withBytes({ method: "handover.put", workspace: wsId, origin: peerId, id: hoIn1, name: emptyCarryHash }, asBytes(emptyCarryBuf)), wsId);
      await m1Ans(peerId, { method: "handover.place", workspace: wsId, origin: peerId, id: hoIn1, carry: emptyCarryHash, held: false }, wsId);
      assert.equal(countBuilder(mbLog, "replica-carry"), 6, "Station 1 Moves.handover place must spawn MB wrapper");

      const hoIn2 = "ho-in-2";
      await m2Ans(peerId, { method: "handover.begin", workspace: wsId, origin: peerId, id: hoIn2, keys: ["ho-y"], ws: wsId, dataDir: "/from", accounts: {}, nowhere: [], connects: {}, described: [], stoppedFor: null, bindings: {} }, wsId);
      await m2Ans(peerId, withBytes({ method: "handover.put", workspace: wsId, origin: peerId, id: hoIn2, name: emptyCarryHash }, asBytes(emptyCarryBuf)), wsId);
      await m2Ans(peerId, { method: "handover.place", workspace: wsId, origin: peerId, id: hoIn2, carry: emptyCarryHash, held: false }, wsId);
      assert.equal(countBuilder(pionLog, "replica-carry"), 7, "Station 2 Moves.handover place must spawn Pion wrapper");

      // 4. Cold restore (`takeBackSoon`) via production `restoreReaderConfig(raw)` helper: MB -> Pion switch!
      const rData = join(dir, "restore-station");
      mkdirSync(join(rData, "restore"), { recursive: true });
      writeFileSync(readyFile(rData), JSON.stringify({ origin: "lost-1", workspace: "w", gen: "g1", name: "lost", from: "peer" }));
      await takeBackSoon(rData, join(rData, "stillfail.db"), Date.now(), undefined, {
        readers: restoreReaderConfig({ readers: { "replica-restore": "mb" } }),
      }).catch(() => {});
      assert.equal(countBuilder(mbLog, "replica-restore"), 1, "restoreReaderConfig(mb) must spawn MB wrapper");
      assert.equal(countBuilder(pionLog, "replica-restore"), 0);

      const rData2 = join(dir, "restore-station-2");
      mkdirSync(join(rData2, "restore"), { recursive: true });
      writeFileSync(readyFile(rData2), JSON.stringify({ origin: "lost-2", workspace: "w", gen: "g1", name: "lost", from: "peer" }));
      await takeBackSoon(rData2, join(rData2, "stillfail.db"), Date.now(), undefined, {
        readers: restoreReaderConfig({ readers: { "replica-restore": "pion" } }),
      }).catch(() => {});
      assert.equal(countBuilder(pionLog, "replica-restore"), 1, "restoreReaderConfig(pion) must spawn Pion wrapper");
    } finally {
      for (const r of restores) r();
      await fibers1.close();
      await fibers2.close();
      st1Store.close();
      st2Store.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
