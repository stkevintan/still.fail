// Tests for Wave 4-D' unified reader selection, Pion capability gate (static table + async `--version` probe),
// permissive `config.json` `readers` validation, live in-memory config snapshots, hot-reload on next spawn,
// real SQLite builder wiring, RequestedBuilder error boundary, rig Remote wiring, and per-station PackedProgram isolation.
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { Effect } from "effect";
import { checkConfig } from "../src/accounts/check.ts";
import type { Jobs } from "../src/jobs/jobs.ts";
import { Remote } from "../src/jobs/remote.ts";
import { ConfigFile } from "../src/ops/config.ts";
import { hearLines, type Line } from "../src/ops/log.ts";
import { platform } from "../src/platform/index.ts";
import { ArchiveMarkBuilder } from "../src/read/archive-mark-builder.ts";
import {
  parsePionVersionModes,
  pionBinary,
  pionSupportedModes,
  probePionSupportedModes,
  resetReaderSelectionStateForTest,
  resolveReaderSelection,
} from "../src/read/mb-reader.ts";
import { resolveReaderEngine } from "../src/read/reader-select.ts";
import { RequestedBuilder } from "../src/read/requested-builder.ts";
import { makeReaderConfigSnapshot } from "../src/services.ts";
import { workspaceFile } from "../src/sessions/archive.ts";
import { measureRoom } from "../src/sessions/footprint.ts";
import { PackedProgram, runPackedOnce } from "../src/sessions/packed-mb.ts";
import { MemoryProgram } from "../src/share/memory-mb.ts";
import { Store } from "../src/store/store.ts";
import { buildLegacyEntryLookups } from "../src/store/legacy-said-builder.ts";
import { installPageLetterIndex } from "../src/store/page-letter-index.ts";
import { buildWorkspaceActivity } from "../src/sessions/workspace-activity-builder.ts";
import { retireAfterPrevious } from "../src/usage/module.ts";
import { UseIndex } from "../src/vault/use-index.ts";
import { DatabaseSync } from "node:sqlite";

const tempDirs: string[] = [];
after(() => {
  for (const dir of tempDirs) {
    rmSync(dir, { recursive: true, force: true });
  }
});

function freshDir(prefix = "reader-config-select-"): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  tempDirs.push(dir);
  return dir;
}

const skipPosixStubs = platform.os === "windows" ? "POSIX shell stubs are not directly spawnable without shell: true on Windows" : false;

function makeStubBinary(dir: string, name: string, jsBody: string): string {
  const scriptPath = join(dir, `${name}.mjs`);
  writeFileSync(scriptPath, jsBody, "utf8");
  const shPath = join(dir, name);
  writeFileSync(shPath, `#!/bin/sh\nexec "${process.execPath}" "${scriptPath}" "$@"\n`, "utf8");
  chmodSync(shPath, 0o755);
  return shPath;
}

async function withEnv<T>(overrides: Record<string, string | undefined>, fn: () => Promise<T>): Promise<T> {
  const saved = new Map<string, string | undefined>();
  for (const [k, v] of Object.entries(overrides)) {
    saved.set(k, process.env[k]);
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  try {
    return await fn();
  } finally {
    for (const [k, v] of saved) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
}

function withEnvSync<T>(overrides: Record<string, string | undefined>, fn: () => T): T {
  const saved = new Map<string, string | undefined>();
  for (const [k, v] of Object.entries(overrides)) {
    saved.set(k, process.env[k]);
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  try {
    return fn();
  } finally {
    for (const [k, v] of saved) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
}

function versionAndTagStubBody(versionLine: string, tag: string, recordFile?: string): string {
  const recordSnippet = recordFile
    ? `import { appendFileSync, writeFileSync } from "node:fs";\n`
    : `import { writeFileSync } from "node:fs";\n`;
  const appendOnLine = recordFile
    ? `appendFileSync(${JSON.stringify(recordFile)}, ${JSON.stringify(`${tag}\n`)});\n`
    : "";
  return `
${recordSnippet}import { createInterface } from "node:readline";
if (process.argv.includes("--version")) {
  process.stdout.write(${JSON.stringify(versionLine)} + "\\n");
  process.exit(0);
}
const rl = createInterface({ input: process.stdin });
rl.on("line", (line) => {
  if (!line) return;
  const ask = JSON.parse(line);
  ${appendOnLine}if (ask.op === "workspace.file") {
    writeFileSync(ask.out, ${JSON.stringify(tag)}, "utf8");
    process.stdout.write(JSON.stringify({ id: ask.id, found: true }) + "\\n");
  } else if (ask.op) {
    process.stdout.write(JSON.stringify({ id: ask.id, tag: ${JSON.stringify(tag)}, tags: [${JSON.stringify(tag)}] }) + "\\n");
  } else if ("path" in ask) {
    process.stdout.write(JSON.stringify({ size: ${tag === "pion" ? 2048 : 1024}, complete: true, rebuild: [] }) + "\\n");
    process.exit(0);
  } else {
    process.stdout.write(JSON.stringify({ done: true }) + "\\n");
  }
});
`;
}

test("precedence matrix: per-mode env > config.readers[mode] > global env > mb", () => {
  assert.equal(resolveReaderEngine("packed", { config: undefined, env: {}, hasPionBinary: true }).engine, "mb");
  const globalOnly = resolveReaderEngine("packed", {
    config: undefined,
    env: { STILLFAIL_READER_ENGINE: "pion" },
    hasPionBinary: true,
  });
  assert.equal(globalOnly.engine, "pion");
  assert.equal(globalOnly.source, "env");
  const configWins = resolveReaderEngine("packed", {
    config: { readers: { packed: "mb" } },
    env: { STILLFAIL_READER_ENGINE: "pion" },
    hasPionBinary: true,
  });
  assert.equal(configWins.engine, "mb");
  assert.equal(configWins.source, "config");
  const configPionWins = resolveReaderEngine("memory", {
    config: { readers: { memory: "pion" } },
    env: { STILLFAIL_READER_ENGINE: "mb" },
    hasPionBinary: true,
  });
  assert.equal(configPionWins.engine, "pion");
  assert.equal(configPionWins.source, "config");
  const perModeWins = resolveReaderEngine("packed", {
    config: { readers: { packed: "pion" } },
    env: { STILLFAIL_READER_ENGINE: "pion", STILLFAIL_READER_PACKED: "mb" },
    hasPionBinary: true,
  });
  assert.equal(perModeWins.engine, "mb");
  assert.equal(perModeWins.source, "env");
  for (const badReaders of [["pion"], "pion", 42, true] as unknown[]) {
    const sel = resolveReaderEngine("packed", {
      config: { readers: badReaders as Record<string, unknown> },
      env: {},
      hasPionBinary: true,
    });
    assert.equal(sel.engine, "mb");
    assert.equal(sel.source, "default");
    assert.equal(sel.fallback, false);
  }
});

test("checkConfig never rejects invalid/unknown/non-object readers so unrelated ConfigFile.update succeeds (Opus P1-b)", () => {
  for (const readersValue of [
    { footprint: "not-a-valid-engine", "unknown-future-mode": "pion", packed: 123 },
    "pion",
    42,
    ["footprint"],
    null,
  ]) {
    const dir = freshDir("config-readers-");
    const cfgPath = join(dir, "config.json");
    writeFileSync(cfgPath, JSON.stringify({ language: "zh", readers: readersValue }, null, 2), "utf8");
    withEnvSync({ STILLFAIL_CONFIG: cfgPath }, () => {
      const cfg = new ConfigFile(dir);
      cfg.check = checkConfig;
      const updated = cfg.update((raw) => {
        raw.language = "en";
        raw.channel = "beta";
      });
      assert.equal(updated.language, "en");
      assert.equal(updated.channel, "beta");
      assert.deepEqual(updated.readers, readersValue);
    });
  }
});

test("same PackedProgram, MemoryProgram, and RequestedBuilder hot-switch from mb to pion on next spawn without disrupting in-flight work (Astra P1-1)", { skip: skipPosixStubs }, async () => {
  const dir = freshDir("hot-switch-");
  const cfgDir = freshDir("hot-switch-cfg-");
  const cfgPath = join(cfgDir, "config.json");
  const shellDir = freshDir("hot-switch-shell-");
  const targetDir = freshDir("hot-switch-target-");
  const builderLog = join(dir, "requested-builder-spawns.txt");

  const mbStub = makeStubBinary(dir, "stub-mb", versionAndTagStubBody("mb-reader 1.0", "mb"));
  const pionStub = makeStubBinary(dir, "stub-pion", versionAndTagStubBody("stillfail-pion 0.1.0 modes:footprint,packed,memory", "pion"));
  const builderMbStub = makeStubBinary(dir, "builder-mb", versionAndTagStubBody("mb-reader 1.0", "mb", builderLog));
  const builderPionStub = makeStubBinary(dir, "builder-pion", versionAndTagStubBody("stillfail-pion 0.1.0", "pion", builderLog));

  const gateFile = join(dir, "release-gate");
  const gatedMbStub = makeStubBinary(
    dir,
    "stub-mb-gated",
    `
import { existsSync, watch } from "node:fs";
import { dirname } from "node:path";
import { createInterface } from "node:readline";
const gate = ${JSON.stringify(gateFile)};
const rl = createInterface({ input: process.stdin });
rl.on("line", (line) => {
  if (!line) return;
  const ask = JSON.parse(line);
  const reply = () => {
    process.stdout.write(JSON.stringify({ id: ask.id, tag: "mb", tags: ["mb"] }) + "\\n");
  };
  if (ask.op === "wait-gate" && !existsSync(gate)) {
    const w = watch(dirname(gate), () => {
      if (existsSync(gate)) { w.close(); reply(); }
    });
    if (existsSync(gate)) { w.close(); reply(); }
  } else {
    reply();
  }
});
`,
  );

  await withEnv({ STILLFAIL_CONFIG: cfgPath }, async () => {
    const cfg = new ConfigFile(cfgDir);
    cfg.check = checkConfig;
    const snap = makeReaderConfigSnapshot(cfg);

    try {
      await withEnv({
        STILLFAIL_MB_READER: gatedMbStub,
        STILLFAIL_PION_READER: pionStub,
        STILLFAIL_READER_PACKED: undefined,
        STILLFAIL_READER_MEMORY: undefined,
        STILLFAIL_READER_FOOTPRINT: undefined,
        STILLFAIL_READER_ENGINE: undefined,
      }, async () => {
        const packed = new PackedProgram({ readers: snap.get });
        try {
          assert.equal((await packed.ask<{ tag: string }>("table", {})).tag, "mb");
          assert.equal(packed.started, 1);

          const inFlight = packed.ask<{ tag: string }>("wait-gate", {});
          await cfg.updateSoon((raw) => {
            raw.readers = { packed: "pion", memory: "pion", footprint: "pion" };
          });
          assert.equal(snap.get()?.readers?.packed, "pion");

          writeFileSync(gateFile, "go", "utf8");
          assert.equal((await inFlight).tag, "mb");
          assert.equal(packed.started, 1);

          assert.equal(packed.trimIdle(), 1);
          assert.equal((await packed.ask<{ tag: string }>("table", {})).tag, "pion");
          assert.equal(packed.started, 2);

          assert.equal((await runPackedOnce<{ tag: string }>("table", {}, { readers: snap.get })).tag, "pion");
        } finally {
          await packed.close();
        }
      });

      await cfg.updateSoon((raw) => {
        raw.readers = { packed: "mb", memory: "mb", footprint: "mb" };
      });

      await withEnv({
        STILLFAIL_MB_READER: mbStub,
        STILLFAIL_PION_READER: pionStub,
        STILLFAIL_READER_PACKED: undefined,
        STILLFAIL_READER_MEMORY: undefined,
        STILLFAIL_READER_FOOTPRINT: undefined,
        STILLFAIL_READER_ENGINE: undefined,
      }, async () => {
        assert.equal((await measureRoom(targetDir, undefined, snap.get)).bytes, 1024);
        await cfg.updateSoon((raw) => {
          raw.readers = { memory: "mb", footprint: "pion" };
        });
        assert.equal((await measureRoom(targetDir, undefined, snap.get)).bytes, 2048);

        const mem = new MemoryProgram(shellDir, { readers: snap.get });
        try {
          assert.deepEqual((await mem.ask<{ tags: string[] }>("tags", { names: ["a"] })).tags, ["mb"]);
          assert.equal(mem.started, 1);

          await cfg.updateSoon((raw) => {
            raw.readers = { memory: "pion", footprint: "pion" };
          });
          assert.deepEqual((await mem.ask<{ tags: string[] }>("tags", { names: ["b"] })).tags, ["mb"]);
          assert.equal(mem.started, 1);

          assert.equal(mem.trimIdle(), 1);
          assert.deepEqual((await mem.ask<{ tags: string[] }>("tags", { names: ["c"] })).tags, ["pion"]);
          assert.equal(mem.started, 2);
        } finally {
          await mem.close();
        }

        await cfg.updateSoon((raw) => {
          raw.readers = { "session-counts": "mb" };
        });
        const builder = new RequestedBuilder<string>(
          { readers: snap.get },
          {
            binary: () => (snap.get()?.readers?.["session-counts"] === "pion" ? builderPionStub : builderMbStub),
            args: ["--builder", "session-counts", "--db", join(dir, "fake.db")],
          },
          "scope",
          "test dynamic builder",
        );
        try {
          await builder.ready(["one"]);
          await cfg.updateSoon((raw) => {
            raw.readers = { "session-counts": "pion" };
          });
          assert.equal(builder.trimIdle(), true);
          await builder.ready(["two"]);
        } finally {
          await builder.close();
        }

        // Exact full spawn sequence (dedicated builderLog, never slice(-2)).
        const lines = readFileSync(builderLog, "utf8").trim().split("\n").filter(Boolean);
        assert.deepEqual(lines, ["mb", "pion"]);
      });
    } finally {
      snap.stop();
    }
  });
});

test("real ArchiveMarkBuilder wires config.readers (unsupported-binary fallback warn) and RequestedBuilder catches synchronous binary() throws cleanly", { skip: skipPosixStubs }, async () => {
  resetReaderSelectionStateForTest();
  const dir = freshDir("builder-wire-");
  const mbStub = makeStubBinary(dir, "stub-mb", versionAndTagStubBody("mb-reader 1.0", "mb"));
  const pionStub = makeStubBinary(dir, "stub-pion", versionAndTagStubBody("stillfail-pion 0.1.0", "pion"));

  const unhandled: unknown[] = [];
  const onUnhandled = (err: unknown) => unhandled.push(err);
  process.on("unhandledRejection", onUnhandled);
  const logs: Line[] = [];
  hearLines((l) => logs.push(l));

  try {
    // 1. ArchiveMarkBuilder reads options.readers() on spawn; when the probed Pion binary omits
    //    `archive-marks`, it logs a deduped pion-binary-unsupported-mode warning and runs mb.
    const supported = await probePionSupportedModes(pionStub);
    assert.ok(supported !== null && !supported.has("archive-marks"));
    let readerCalls = 0;
    await withEnv({
      STILLFAIL_MB_READER: mbStub,
      STILLFAIL_PION_READER: pionStub,
      STILLFAIL_READER_ARCHIVE_MARKS: undefined,
      STILLFAIL_READER_ENGINE: undefined,
    }, async () => {
      const builder = new ArchiveMarkBuilder(join(dir, "fake.db"), {
        readers: () => {
          readerCalls++;
          return { readers: { "archive-marks": "pion" } };
        },
      });
      try {
        await builder.readyIndex();
        assert.equal(builder.trimIdle(), true);
        await builder.readyIndex();
      } finally {
        await builder.close();
      }
    });
    assert.equal(readerCalls, 2, "expected ArchiveMarkBuilder to read options.readers() on each spawn");
    const unsupportedWarns = logs.filter(
      (l) => l.level === "WARN" && l.at === "readers" && l.fields.mode === "archive-marks" && l.fields.reason === "pion-binary-unsupported-mode",
    );
    assert.equal(unsupportedWarns.length, 1, "expected exactly 1 deduped pion-binary-unsupported-mode warning");

    // 2. RequestedBuilder dynamic binary() throw rejects ready() cleanly without unhandledRejection and allows retry.
    let shouldThrow = true;
    const flaky = new RequestedBuilder<string>(
      {},
      {
        binary: () => {
          if (shouldThrow) throw new Error("boom: reader binary unavailable");
          return mbStub;
        },
        args: ["--builder", "archive-marks", "--db", join(dir, "fake.db")],
      },
      "scope",
      "test throw recovery",
    );
    try {
      await assert.rejects(flaky.ready(["first"]), /boom: reader binary unavailable/);
      shouldThrow = false;
      await flaky.ready(["second"]);
    } finally {
      await flaky.close();
    }
    assert.deepEqual(unhandled, [], "synchronous binary() throw must never produce unhandledRejection");
  } finally {
    hearLines(null);
    process.off("unhandledRejection", onUnhandled);
  }
});

test("Remote passes readers config to WorkspaceReader footprint measurements (Astra P1-2)", { skip: skipPosixStubs }, async () => {
  const dir = freshDir("rig-remote-");
  const dataDir = join(dir, "data");
  const wsDir = freshDir("rig-ws-");
  const cfgPath = join(dataDir, "config.json");
  const mbStub = makeStubBinary(dir, "stub-mb", versionAndTagStubBody("mb", "mb"));
  const pionStub = makeStubBinary(dir, "stub-pion", versionAndTagStubBody("stillfail-pion 0.1.0", "pion"));

  await withEnv({
    STILLFAIL_CONFIG: cfgPath,
    STILLFAIL_MB_READER: mbStub,
    STILLFAIL_PION_READER: pionStub,
    STILLFAIL_READER_FOOTPRINT: undefined,
    STILLFAIL_READER_ENGINE: undefined,
  }, async () => {
    const cfg = new ConfigFile(dataDir);
    const snap = makeReaderConfigSnapshot(cfg);
    const store = Store.open(":memory:", join(dataDir, "archive"));
    const jobs = {
      program: { shell() {}, call: async () => null },
      onRemote() {},
    } as unknown as Jobs;
    const remote = new Remote({ data: dataDir, store, jobs, notify: () => {}, readers: snap.get });
    try {
      await cfg.updateSoon((raw) => {
        raw.readers = { footprint: "pion" };
      });
      // Kick off measurement on workspaceReader (async queue, returns null first then caches size=2048 from pionStub).
      assert.equal(remote.workspaceReader.size(wsDir, 10_000), null);
      await remote.workspaceReader.idle();
      const reading = remote.workspaceReader.size(wsDir, 10_000);
      assert.ok(reading !== null, "expected Remote workspaceReader to complete footprint measurement");
      assert.equal(reading.bytes, 2048, "expected Remote workspaceReader to route footprint to Pion via ReaderConfig");
    } finally {
      await remote.close();
      store.close();
      snap.stop();
    }
  });
});

test("workspaceFile routes through the passed PackedProgram readers config (mb vs pion)", { skip: skipPosixStubs }, async () => {
  const dir = freshDir("workspace-file-");
  const room = freshDir("workspace-room-");
  writeFileSync(join(room, "workspace.tar.zst"), "stub-archive", "utf8");
  const mbStub = makeStubBinary(dir, "stub-mb", versionAndTagStubBody("mb", "mb"));
  const pionStub = makeStubBinary(dir, "stub-pion", versionAndTagStubBody("stillfail-pion 0.1.0", "pion"));

  await withEnv({
    STILLFAIL_MB_READER: mbStub,
    STILLFAIL_PION_READER: pionStub,
    STILLFAIL_READER_PACKED: undefined,
    STILLFAIL_READER_ENGINE: undefined,
  }, async () => {
    let mode: "mb" | "pion" = "mb";
    const program = new PackedProgram({ readers: () => ({ readers: { packed: mode } }) });
    try {
      const fromMb = await workspaceFile(room, "hello.txt", { program });
      assert.equal(fromMb?.toString("utf8"), "mb");

      mode = "pion";
      assert.equal(program.trimIdle(), 1);
      const fromPion = await workspaceFile(room, "hello.txt", { program });
      assert.equal(fromPion?.toString("utf8"), "pion");
    } finally {
      await program.close();
    }
  });
});

test("retireAfterPrevious catches synchronous reader binary resolution errors and resolves false instead of dying", async () => {
  const dir = freshDir("usage-retire-");
  const store = Store.open(join(dir, "station.db"), join(dir, "archive"));
  try {
    const ok = await Effect.runPromise(
      retireAfterPrevious(store, Promise.resolve(), undefined, () => {
        throw new Error("boom: reader binary resolution failed");
      }),
    );
    assert.equal(ok, false);
  } finally {
    store.close();
  }
});

test("two independent station PackedProgram instances with distinct ReaderConfig snapshots never interfere (Astra P2-3)", { skip: skipPosixStubs }, async () => {
  const dir = freshDir("packed-iso-");
  const mbStub = makeStubBinary(dir, "stub-mb", versionAndTagStubBody("mb", "mb"));
  const pionStub = makeStubBinary(dir, "stub-pion", versionAndTagStubBody("stillfail-pion 0.1.0", "pion"));

  await withEnv({
    STILLFAIL_MB_READER: mbStub,
    STILLFAIL_PION_READER: pionStub,
    STILLFAIL_READER_PACKED: undefined,
    STILLFAIL_READER_ENGINE: undefined,
  }, async () => {
    const stationA = new PackedProgram({ readers: () => ({ readers: { packed: "mb" } }) });
    const stationB = new PackedProgram({ readers: () => ({ readers: { packed: "pion" } }) });
    try {
      const [a1, b1] = await Promise.all([
        stationA.ask<{ tag: string }>("table", {}),
        stationB.ask<{ tag: string }>("table", {}),
      ]);
      assert.equal(a1.tag, "mb");
      assert.equal(b1.tag, "pion");

      assert.equal(stationA.trimIdle(), 1);
      assert.equal(stationB.trimIdle(), 1);

      const [a2, b2] = await Promise.all([
        stationA.ask<{ tag: string }>("table", {}),
        stationB.ask<{ tag: string }>("table", {}),
      ]);
      assert.equal(a2.tag, "mb");
      assert.equal(b2.tag, "pion");
    } finally {
      await Promise.all([stationA.close(), stationB.close()]);
    }
  });
});

test("old stillfail-pion binary capability probe: baseline 3 modes work, unannounced SQL mode falls back to mb with deduped warn and no restart loop (Astra P1-2)", { skip: skipPosixStubs }, async () => {
  resetReaderSelectionStateForTest();
  const dir = freshDir("cap-probe-");
  const mbStub = makeStubBinary(dir, "stub-mb", versionAndTagStubBody("mb-reader 1.0", "mb"));
  const oldPionStub = makeStubBinary(dir, "stub-pion-old", versionAndTagStubBody("stillfail-pion 0.1.0", "pion"));
  const partialPionStub = makeStubBinary(
    dir,
    "stub-pion-partial",
    versionAndTagStubBody("stillfail-pion 0.2.0 modes:footprint,packed,memory", "pion"),
  );
  const newPionStub = makeStubBinary(
    dir,
    "stub-pion-new",
    versionAndTagStubBody("stillfail-pion 0.3.0 modes:footprint,packed,memory,session-counts", "pion"),
  );
  const failingPionStub = makeStubBinary(dir, "stub-pion-fail", "process.exit(1);\n");

  assert.deepEqual([...parsePionVersionModes("stillfail-pion 0.1.0")].sort(), ["footprint", "memory", "packed"]);
  assert.deepEqual(
    [...parsePionVersionModes("stillfail-pion 0.3.0 modes:footprint,packed,memory,session-counts")].sort(),
    ["footprint", "memory", "packed", "session-counts"],
  );

  const logs: Line[] = [];
  hearLines((l) => logs.push(l));
  try {
    await withEnv({
      STILLFAIL_MB_READER: mbStub,
      STILLFAIL_PION_READER: oldPionStub,
      STILLFAIL_READER_ENGINE: undefined,
    }, async () => {
      for (const mode of ["footprint", "packed", "memory"] as const) {
        const res = resolveReaderSelection(mode, {
          config: { readers: { [mode]: "pion" } },
          env: {},
        });
        assert.equal(res.engine, "pion");
        assert.equal(res.primaryBinary, oldPionStub);
      }

      const first = resolveReaderSelection("session-counts", {
        config: { readers: { "session-counts": "pion" } },
        env: {},
        pionImplemented: true,
        logAt: "cap-test",
      });
      assert.equal(first.engine, "mb");
      assert.equal(first.primaryBinary, mbStub);

      const supported = await probePionSupportedModes(oldPionStub);
      assert.ok(supported !== null);
      assert.equal(supported.has("footprint"), true);
      assert.equal(supported.has("packed"), true);
      assert.equal(supported.has("memory"), true);
      assert.equal(supported.has("session-counts"), false);

      for (let i = 0; i < 3; i++) {
        const next = resolveReaderSelection("session-counts", {
          config: { readers: { "session-counts": "pion" } },
          env: {},
          pionImplemented: true,
          logAt: "cap-test",
        });
        assert.equal(next.engine, "mb");
        assert.equal(next.primaryBinary, mbStub);
        assert.equal(next.selection.fallback, true);
        assert.equal(next.selection.reason, "pion-binary-unsupported-mode");
      }
      const unsupportedWarns = logs.filter(
        (l) => l.level === "WARN" && l.at === "cap-test" && l.fields.reason === "pion-binary-unsupported-mode",
      );
      assert.equal(unsupportedWarns.length, 1, "expected exactly 1 deduped pion-binary-unsupported-mode warning");
    });

    await withEnv({
      STILLFAIL_MB_READER: mbStub,
      STILLFAIL_PION_READER: partialPionStub,
    }, async () => {
      const supported = await probePionSupportedModes(partialPionStub);
      assert.ok(supported !== null);
      assert.equal(supported.has("post-blocks"), false);
      const res = resolveReaderSelection("post-blocks", {
        config: { readers: { "post-blocks": "pion" } },
        env: {},
        pionImplemented: true,
      });
      assert.equal(res.engine, "mb");
      assert.equal(res.selection.reason, "pion-binary-unsupported-mode");
    });

    await withEnv({
      STILLFAIL_MB_READER: mbStub,
      STILLFAIL_PION_READER: newPionStub,
    }, async () => {
      assert.equal(pionSupportedModes(newPionStub), null);
      const whileProbing = resolveReaderSelection("session-counts", {
        config: { readers: { "session-counts": "pion" } },
        env: {},
        pionImplemented: true,
      });
      assert.equal(whileProbing.engine, "mb");

      const supported = await probePionSupportedModes(newPionStub);
      assert.ok(supported !== null);
      assert.equal(supported.has("session-counts"), true);

      const afterProbe = resolveReaderSelection("session-counts", {
        config: { readers: { "session-counts": "pion" } },
        env: {},
        pionImplemented: true,
      });
      assert.equal(afterProbe.engine, "pion");
      assert.equal(afterProbe.primaryBinary, newPionStub);
      assert.equal(afterProbe.selection.fallback, false);
    });

    // Failing `--version` probe returns null (transient cooldown, not permanently cached as unsupported).
    const failed = await probePionSupportedModes(failingPionStub);
    assert.equal(failed, null);
    assert.equal(pionSupportedModes(failingPionStub), null);
  } finally {
    hearLines(null);
  }
});

test("default mb does zero pionBinary() probe and explicit binary override always wins with source=explicit", { skip: skipPosixStubs }, async () => {
  resetReaderSelectionStateForTest();
  const dir = freshDir("zero-probe-");
  const mbStub = makeStubBinary(dir, "stub-mb", versionAndTagStubBody("mb", "mb"));
  const explicitStub = makeStubBinary(dir, "stub-explicit", versionAndTagStubBody("explicit", "explicit"));
  const deferredPion = join(dir, "deferred-pion");

  await withEnv({
    STILLFAIL_MB_READER: mbStub,
    STILLFAIL_PION_READER: deferredPion,
    STILLFAIL_READER_ENGINE: undefined,
    STILLFAIL_READER_PACKED: undefined,
  }, async () => {
    const mbRes = resolveReaderSelection("packed", { config: undefined, env: {} });
    assert.equal(mbRes.engine, "mb");
    assert.equal(mbRes.primaryBinary, mbStub);

    const explicitRes = resolveReaderSelection("packed", {
      binary: explicitStub,
      config: { readers: { packed: "pion" } },
      env: { STILLFAIL_READER_PACKED: "pion" },
    });
    assert.equal(explicitRes.primaryBinary, explicitStub);
    assert.equal(explicitRes.selection.source, "explicit");

    makeStubBinary(dir, "deferred-pion", versionAndTagStubBody("stillfail-pion 0.1.0", "pion"));
    assert.equal(pionBinary(), deferredPion);
    const pionRes = resolveReaderSelection("packed", {
      config: { readers: { packed: "pion" } },
      env: {},
    });
    assert.equal(pionRes.engine, "pion");
    assert.equal(pionRes.primaryBinary, deferredPion);
  });
});

test("vault-uses UseIndex (file-backed DB) and session-backfill builders resolve ReaderConfig lazily and fall back to mb when Pion stub lacks mode", { skip: skipPosixStubs }, async () => {
  resetReaderSelectionStateForTest();
  const dir = freshDir("w5-di-");
  const spawnLog = join(dir, "spawns.log");
  const vaultStub = makeStubBinary(
    dir,
    "stub-mb-vault",
    `
import { appendFileSync } from "node:fs";
import { createInterface } from "node:readline";
appendFileSync(${JSON.stringify(spawnLog)}, process.argv.slice(2).join(" ") + "\\n");
const rl = createInterface({ input: process.stdin });
rl.on("line", (line) => {
  if (!line) return;
  const ask = JSON.parse(line);
  if (ask.op === "ready" && ask.q) {
    process.stdout.write(JSON.stringify({ answered: { id: ask.q.id, bodies: [] } }) + "\\n");
  } else if (ask.op === "uses" || ask.op === "rebox") {
    process.stdout.write(JSON.stringify({ done: true }) + "\\n");
  } else {
    process.stdout.write(JSON.stringify({ done: true }) + "\\n");
  }
});
`,
  );
  const pionStub = makeStubBinary(dir, "stub-pion-w5", versionAndTagStubBody("stillfail-pion 0.1.0", "pion"));

  const logs: Line[] = [];
  hearLines((l) => logs.push(l));
  try {
    await withEnv({
      STILLFAIL_MB_READER: vaultStub,
      STILLFAIL_PION_READER: pionStub,
      STILLFAIL_READER_ENGINE: undefined,
      STILLFAIL_READER_VAULT_USES: undefined,
      STILLFAIL_READER_SESSION_BACKFILL: undefined,
    }, async () => {
      // 1. vault-uses: real file-backed DB triggers UseIndex.#start() -> resolveReaderSelection("vault-uses")
      const dbPath = join(dir, "vault.db");
      const db = new DatabaseSync(dbPath);
      db.exec(`
        CREATE TABLE vault_requests (ws TEXT NOT NULL, id TEXT NOT NULL, status TEXT NOT NULL, body TEXT NOT NULL, PRIMARY KEY (ws, id));
        CREATE TABLE vault_devices (ws TEXT NOT NULL, device TEXT NOT NULL, body TEXT NOT NULL, PRIMARY KEY (ws, device));
      `);
      let vaultConfigReads = 0;
      const uses = new UseIndex(db, {
        readers: () => {
          vaultConfigReads++;
          return { readers: { "vault-uses": "pion" } };
        },
      });
      try {
        const bodies = await uses.read("ws1", "v1", null, 10);
        assert.deepEqual(bodies, []);
        assert.equal(vaultConfigReads, 1, "UseIndex.#start() must read readers() lazily on spawn");
      } finally {
        await uses.close();
        db.close();
      }

      // 2. session-backfill: buildWorkspaceActivity & buildLegacyEntryLookups resolve ReaderConfig lazily
      const storePath = join(dir, "station.db");
      const store = Store.open(storePath, join(dir, "archive"));
      // Mark workspace_activity_meta incomplete so buildWorkspaceActivity sees work and spawns the worker.
      store.db.exec("UPDATE workspace_activity_meta SET complete = 0");
      let activityConfigReads = 0;
      const activity = buildWorkspaceActivity(store, Promise.resolve(), undefined, () => {
        activityConfigReads++;
        return { readers: { "session-backfill": "pion" } };
      });
      try {
        assert.equal(await activity.ready, true);
        assert.ok(activityConfigReads >= 1, "buildWorkspaceActivity must read readers() on spawn");
      } finally {
        await activity.close();
      }

      let legacyConfigReads = 0;
      const legacyBins: string[] = [];
      // Install page-letter index and seed a garbage row so buildLegacyEntryLookups genuinely spawns startWorker.
      installPageLetterIndex(store.db);
      store.db.exec("INSERT OR REPLACE INTO page_letter_garbage VALUES (1, 'stale-tok')");
      const legacySpawned = Promise.withResolvers<void>();
      const legacy = buildLegacyEntryLookups(
        store,
        Promise.resolve(),
        undefined,
        (bin) => {
          legacyBins.push(bin);
          legacySpawned.resolve();
          return new (class FakeWorker extends EventEmitter {
            readonly threadId = 1;
            postMessage() { setImmediate(() => this.emit("message", { done: true })); }
            unref() {}
            async terminate() { setImmediate(() => this.emit("exit", 0)); return 0; }
          })() as never;
        },
        () => {
          legacyConfigReads++;
          return { readers: { "session-backfill": "pion" } };
        },
      );
      await legacySpawned.promise;
      await legacy.close();
      store.close();

      assert.ok(legacyConfigReads >= 1, "buildLegacyEntryLookups must read readers() lazily on spawn");
      assert.deepEqual(legacyBins, [vaultStub], "buildLegacyEntryLookups must select vaultStub via resolveReaderSelection");

      // Verify both modes fell back to mbStub (both vault-uses and session-backfill are enabled and fall back on the legacy pionStub via capability gate) and spawned real processes.
      const spawns = readFileSync(spawnLog, "utf8").trim().split("\n").filter(Boolean);
      assert.ok(spawns.some((l) => l.includes("--builder vault-uses")), `expected vault-uses spawn, got ${JSON.stringify(spawns)}`);
      assert.ok(spawns.some((l) => l.includes("--builder session-backfill")), `expected session-backfill spawn, got ${JSON.stringify(spawns)}`);
      // Direct resolveReaderSelection check confirms exact fallback reasons.
      const vSel = resolveReaderSelection("vault-uses", { config: { readers: { "vault-uses": "pion" } }, env: {} });
      assert.equal(vSel.engine, "mb");
      assert.equal(vSel.selection.reason, "pion-binary-unsupported-mode");
      const sSel = resolveReaderSelection("session-backfill", { config: { readers: { "session-backfill": "pion" } }, env: {} });
      assert.equal(sSel.engine, "mb");
      assert.equal(sSel.selection.reason, "pion-binary-unsupported-mode");
    });
  } finally {
    hearLines(null);
  }
});

test("file-backed UseIndex preserves #known across idle release and binary switch without rescanning uses/rebox", { skip: skipPosixStubs }, async () => {
  resetReaderSelectionStateForTest();
  const dir = freshDir("use-index-idle-known-");
  const opsLogA = join(dir, "ops-a.log");
  const opsLogB = join(dir, "ops-b.log");
  const makeVaultRecorderStub = (name: string, tag: string, logPath: string) =>
    makeStubBinary(
      dir,
      name,
      `
import { appendFileSync } from "node:fs";
import { createInterface } from "node:readline";
const rl = createInterface({ input: process.stdin });
rl.on("line", (line) => {
  if (!line) return;
  const ask = JSON.parse(line);
  appendFileSync(${JSON.stringify(logPath)}, ask.op + "\\n");
  if (ask.op === "ready" && ask.q) {
    process.stdout.write(JSON.stringify({ answered: { id: ask.q.id, bodies: [${JSON.stringify(tag)}] } }) + "\\n");
  } else {
    process.stdout.write(JSON.stringify({ done: true }) + "\\n");
  }
});
`,
    );

  const stubA = makeVaultRecorderStub("vault-a", "from-a", opsLogA);
  const stubB = makeVaultRecorderStub("vault-b", "from-b", opsLogB);
  const dbPath = join(dir, "vault-idle.db");
  const db = new DatabaseSync(dbPath);
  db.exec(`
    CREATE TABLE vault_requests (ws TEXT NOT NULL, id TEXT NOT NULL, status TEXT NOT NULL, body TEXT NOT NULL, PRIMARY KEY (ws, id));
    CREATE TABLE vault_devices (ws TEXT NOT NULL, device TEXT NOT NULL, body TEXT NOT NULL, PRIMARY KEY (ws, device));
  `);

  let fireIdle: (() => void) | null = null;
  let idleArmed = Promise.withResolvers<void>();
  const afterFn = (_ms: number, f: () => void) => {
    fireIdle = f;
    idleArmed.resolve();
    return () => { fireIdle = null; };
  };

  await withEnv({
    STILLFAIL_MB_READER: stubA,
    STILLFAIL_READER_ENGINE: undefined,
    STILLFAIL_READER_VAULT_USES: undefined,
  }, async () => {
    const uses = new UseIndex(db, { after: afterFn });
    try {
      // Round 1: stub A answers read and completes uses + rebox background, then arms idle timer.
      assert.deepEqual(await uses.read("ws1", "v1", null, 10), ["from-a"]);
      await idleArmed.promise;
      assert.equal(uses.running, true);
      // Trigger idle release -> preserves #known = { uses: true, rebox: true } and lets stub A go.
      fireIdle!();
      assert.equal(uses.running, false);

      const opsA = readFileSync(opsLogA, "utf8").trim().split("\n").filter(Boolean);
      assert.ok(opsA.includes("uses") && opsA.includes("rebox"), `stub A must run initial uses+rebox, got ${JSON.stringify(opsA)}`);

      // Round 2: switch STILLFAIL_MB_READER to stub B and read again; stub B must NOT re-run uses or rebox.
      process.env.STILLFAIL_MB_READER = stubB;
      idleArmed = Promise.withResolvers<void>();
      assert.deepEqual(await uses.read("ws1", "v1", null, 10), ["from-b"]);
      await idleArmed.promise;
      const opsB = readFileSync(opsLogB, "utf8").trim().split("\n").filter(Boolean);
      assert.deepEqual(opsB, ["ready"], `stub B must skip already-settled uses/rebox and only run ready, got ${JSON.stringify(opsB)}`);
    } finally {
      await uses.close();
      db.close();
    }
  });
});
