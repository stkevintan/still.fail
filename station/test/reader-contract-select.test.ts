import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import {
  isReaderMode,
  READER_MODES,
  type ReaderMode,
  readerModeEnvKey,
  resolveReaderEngine,
} from "../src/read/reader-select.ts";

const MAIN_MBT_PATH = fileURLToPath(new URL("../mb/src/reader/main.mbt", import.meta.url));

/** Extract every `--builder <name>` plus top-level `--data`/`--serve`/`--sessions` mode from `main.mbt`. */
function modesInMainMbt(): string[] {
  const src = readFileSync(MAIN_MBT_PATH, "utf8");
  const mainStart = src.indexOf("\nfn main {");
  assert.ok(mainStart >= 0, "fn main { found in station/mb/src/reader/main.mbt");
  const mainBody = src.slice(mainStart);
  const modes = new Set<string>(["data", "serve", "sessions"]);
  for (const match of mainBody.matchAll(/\(\s*Some\("([a-z0-9-]+)"\)\s*,/g)) {
    modes.add(match[1]!);
  }
  return [...modes].sort();
}

test("READER_MODES strictly matches all modes in station/mb/src/reader/main.mbt and allows shadow ONLY for footprint", () => {
  const registered = Object.keys(READER_MODES).sort();
  const fromMainMbt = modesInMainMbt();
  assert.deepEqual(
    registered,
    fromMainMbt,
    "READER_MODES must match every --builder and top-level mode in station/mb/src/reader/main.mbt",
  );

  const shadowAllowed = (Object.entries(READER_MODES) as [ReaderMode, (typeof READER_MODES)[ReaderMode]][])
    .filter(([, meta]) => meta.allowShadow)
    .map(([mode]) => mode)
    .sort();
  assert.deepEqual(
    shadowAllowed,
    ["footprint"],
    "only footprint is currently certified pure read-only and permitted to run in shadow mode",
  );

  const pionImplemented = (Object.entries(READER_MODES) as [ReaderMode, (typeof READER_MODES)[ReaderMode]][])
    .filter(([, meta]) => meta.pionImplemented)
    .map(([mode]) => mode)
    .sort();
  assert.deepEqual(
    pionImplemented,
    [
      "archive-last",
      "archive-marks",
      "card-posts",
      "closed-cards",
      "footprint",
      "memory",
      "outflow-chats",
      "packed",
      "page-letters",
      "people-since",
      "post-blocks",
      "search-scope",
      "session-bindings",
      "session-counts",
      "session-list",
      "session-up-jobs",
      "signin-save",
      "usage-retire",
      "widget-sources",
      "workspace-up-jobs",
    ],
    "only the implemented baseline + builders_core + builders_index + builders_stateful modes are currently enabled in Pion",
  );

  assert.equal(readerModeEnvKey("footprint"), "STILLFAIL_READER_FOOTPRINT");
  assert.equal(readerModeEnvKey("replica-export"), "STILLFAIL_READER_REPLICA_EXPORT");
  assert.equal(readerModeEnvKey("live-locator"), "STILLFAIL_READER_LIVE_LOCATOR");
  for (const [mode, meta] of Object.entries(READER_MODES) as [ReaderMode, (typeof READER_MODES)[ReaderMode]][]) {
    assert.equal(isReaderMode(mode), true);
    assert.match(readerModeEnvKey(mode), /^STILLFAIL_READER_[A-Z0-9_]+$/);
    assert.equal(
      meta.allowShadow,
      meta.sideEffect === "read-only",
      `allowShadow must match read-only sideEffect for ${mode}`,
    );
  }
  assert.equal(isReaderMode("unknown-mode"), false);
  assert.equal(isReaderMode("toString"), false);
});

test("defaults to mb for every mode regardless of hasPionBinary", () => {
  for (const mode of Object.keys(READER_MODES) as ReaderMode[]) {
    for (const hasPionBinary of [true, false]) {
      const sel = resolveReaderEngine(mode, { config: undefined, env: {}, hasPionBinary });
      assert.deepEqual(sel, {
        mode,
        engine: "mb",
        requested: null,
        rawRequested: null,
        source: "default",
        fallback: false,
      });
    }
  }
});

test("config.readers selects mb, pion, and shadow (for footprint)", () => {
  assert.deepEqual(
    resolveReaderEngine("footprint", { config: { readers: { footprint: "mb" } }, env: {}, hasPionBinary: true }),
    { mode: "footprint", engine: "mb", requested: "mb", rawRequested: "mb", source: "config", fallback: false },
  );
  assert.deepEqual(
    resolveReaderEngine("footprint", { config: { readers: { footprint: "pion" } }, env: {}, hasPionBinary: true }),
    { mode: "footprint", engine: "pion", requested: "pion", rawRequested: "pion", source: "config", fallback: false },
  );
  assert.deepEqual(
    resolveReaderEngine("footprint", { config: { readers: { footprint: "shadow" } }, env: {}, hasPionBinary: true }),
    { mode: "footprint", engine: "shadow", requested: "shadow", rawRequested: "shadow", source: "config", fallback: false },
  );

  // Implemented non-footprint modes can select pion directly when binary is available.
  assert.deepEqual(
    resolveReaderEngine("packed", { config: { readers: { packed: "pion" } }, env: {}, hasPionBinary: true }),
    { mode: "packed", engine: "pion", requested: "pion", rawRequested: "pion", source: "config", fallback: false },
  );
  assert.deepEqual(
    resolveReaderEngine("memory", { config: { readers: { memory: "pion" } }, env: {}, hasPionBinary: true }),
    { mode: "memory", engine: "pion", requested: "pion", rawRequested: "pion", source: "config", fallback: false },
  );

  // Unimplemented modes safely fall back to mb with reason "pion-mode-unimplemented".
  const unimpl = resolveReaderEngine("data", { config: { readers: { data: "pion" } }, env: {}, hasPionBinary: true });
  assert.equal(unimpl.engine, "mb");
  assert.equal(unimpl.requested, "pion");
  assert.equal(unimpl.source, "config");
  assert.equal(unimpl.fallback, true);
  assert.equal(unimpl.reason, "pion-mode-unimplemented");

  // Empty or null config values fall back to default cleanly.
  assert.equal(
    resolveReaderEngine("footprint", { config: { readers: { footprint: "   " } }, env: {}, hasPionBinary: true }).source,
    "default",
  );
  assert.equal(
    resolveReaderEngine("footprint", { config: { readers: { footprint: null } }, env: {}, hasPionBinary: true }).source,
    "default",
  );
});

test("environment variable STILLFAIL_READER_<UPPER_SNAKE_MODE> overrides config", () => {
  const rollback = resolveReaderEngine("footprint", {
    config: { readers: { footprint: "pion" } },
    env: { STILLFAIL_READER_FOOTPRINT: "mb" },
    hasPionBinary: true,
  });
  assert.deepEqual(rollback, {
    mode: "footprint",
    engine: "mb",
    requested: "mb",
    rawRequested: "mb",
    source: "env",
    fallback: false,
  });

  const upgrade = resolveReaderEngine("packed", {
    config: { readers: { packed: "mb" } },
    env: { STILLFAIL_READER_PACKED: "pion" },
    hasPionBinary: true,
  });
  assert.deepEqual(upgrade, {
    mode: "packed",
    engine: "pion",
    requested: "pion",
    rawRequested: "pion",
    source: "env",
    fallback: false,
  });

  const unimplEnv = resolveReaderEngine("replica-export", {
    config: { readers: { "replica-export": "mb" } },
    env: { STILLFAIL_READER_REPLICA_EXPORT: "pion" },
    hasPionBinary: true,
  });
  assert.equal(unimplEnv.engine, "mb");
  assert.equal(unimplEnv.requested, "pion");
  assert.equal(unimplEnv.source, "env");
  assert.equal(unimplEnv.fallback, true);
  assert.equal(unimplEnv.reason, "pion-mode-unimplemented");

  const blankEnv = resolveReaderEngine("footprint", {
    config: { readers: { footprint: "shadow" } },
    env: { STILLFAIL_READER_FOOTPRINT: "  \t  " },
    hasPionBinary: true,
  });
  assert.equal(blankEnv.engine, "shadow");
  assert.equal(blankEnv.source, "config");
});

test("case-insensitivity and whitespace trimming", () => {
  const fromEnv = resolveReaderEngine("footprint", {
    env: { STILLFAIL_READER_FOOTPRINT: "  ShAdOw \n" },
    hasPionBinary: true,
  });
  assert.equal(fromEnv.engine, "shadow");
  assert.equal(fromEnv.requested, "shadow");
  assert.equal(fromEnv.fallback, false);

  const fromConfig = resolveReaderEngine("footprint", {
    config: { readers: { footprint: " PION " } },
    env: {},
    hasPionBinary: true,
  });
  assert.equal(fromConfig.engine, "pion");
  assert.equal(fromConfig.requested, "pion");
  assert.equal(fromConfig.fallback, false);
});

test("invalid values (including untrusted objects with null toString or circular refs) fall back safely without throwing", () => {
  const circular: Record<string, unknown> = {};
  circular.self = circular;
  const nullProto = Object.create(null) as Record<string, unknown>;
  nullProto.engine = "pion";

  for (const bad of [
    "rust",
    "moonbit",
    "dual",
    42,
    true,
    { engine: "pion" },
    { toString: null },
    nullProto,
    circular,
  ]) {
    const sel = resolveReaderEngine("footprint", {
      config: { readers: { footprint: bad } },
      env: {},
      hasPionBinary: true,
    });
    assert.equal(sel.engine, "mb");
    assert.equal(sel.requested, null);
    assert.equal(sel.source, "config");
    assert.equal(sel.fallback, true);
    assert.equal(sel.reason, "invalid-value");
    assert.equal(typeof sel.rawRequested, "string");
    assert.ok(sel.detail && sel.detail.includes("footprint"));
  }

  // Invalid env must NOT silently fall through to config=pion; it must fail safe to mb.
  const badEnv = resolveReaderEngine("footprint", {
    config: { readers: { footprint: "pion" } },
    env: { STILLFAIL_READER_FOOTPRINT: "typo" },
    hasPionBinary: true,
  });
  assert.equal(badEnv.engine, "mb");
  assert.equal(badEnv.source, "env");
  assert.equal(badEnv.fallback, true);
  assert.equal(badEnv.reason, "invalid-value");
  assert.equal(badEnv.rawRequested, "typo");
});

test("every non-footprint mode strictly forbids shadow and falls back to mb", () => {
  const nonFootprint = (Object.keys(READER_MODES) as ReaderMode[]).filter((m) => m !== "footprint");
  assert.ok(nonFootprint.length >= 30);

  for (const mode of nonFootprint) {
    assert.equal(READER_MODES[mode].allowShadow, false, `${mode} must forbid shadow`);
    for (const hasPionBinary of [true, false]) {
      const viaConfig = resolveReaderEngine(mode, {
        config: { readers: { [mode]: "shadow" } },
        env: {},
        hasPionBinary,
      });
      assert.equal(viaConfig.engine, "mb");
      assert.equal(viaConfig.requested, "shadow");
      assert.equal(viaConfig.source, "config");
      assert.equal(viaConfig.fallback, true);
      assert.equal(viaConfig.reason, "shadow-forbidden");
      assert.ok(viaConfig.detail && viaConfig.detail.includes(mode));

      const viaEnv = resolveReaderEngine(mode, {
        config: { readers: { [mode]: "pion" } },
        env: { [readerModeEnvKey(mode)]: "SHADOW" },
        hasPionBinary,
      });
      assert.equal(viaEnv.engine, "mb");
      assert.equal(viaEnv.requested, "shadow");
      assert.equal(viaEnv.source, "env");
      assert.equal(viaEnv.fallback, true);
      assert.equal(viaEnv.reason, "shadow-forbidden");
    }
  }
});

test("missing Pion binary safely falls back to mb for pion and allowed shadow requests", () => {
  const pionReq = resolveReaderEngine("footprint", {
    config: { readers: { footprint: "pion" } },
    env: {},
    hasPionBinary: false,
  });
  assert.equal(pionReq.engine, "mb");
  assert.equal(pionReq.requested, "pion");
  assert.equal(pionReq.source, "config");
  assert.equal(pionReq.fallback, true);
  assert.equal(pionReq.reason, "pion-binary-missing");
  assert.ok(pionReq.detail && pionReq.detail.includes("Pion binary is unavailable"));

  const shadowReq = resolveReaderEngine("footprint", {
    env: { STILLFAIL_READER_FOOTPRINT: "shadow" },
    hasPionBinary: false,
  });
  assert.equal(shadowReq.engine, "mb");
  assert.equal(shadowReq.requested, "shadow");
  assert.equal(shadowReq.source, "env");
  assert.equal(shadowReq.fallback, true);
  assert.equal(shadowReq.reason, "pion-binary-missing");

  const mbReq = resolveReaderEngine("footprint", {
    config: { readers: { footprint: "mb" } },
    env: {},
    hasPionBinary: false,
  });
  assert.equal(mbReq.engine, "mb");
  assert.equal(mbReq.fallback, false);
  assert.equal(mbReq.reason, undefined);
});

test("STILLFAIL_READER_ENGINE acts as global env fallback below config.readers and above default mb", () => {
  const globalPion = resolveReaderEngine("footprint", {
    config: undefined,
    env: { STILLFAIL_READER_ENGINE: "pion" },
    hasPionBinary: true,
  });
  assert.equal(globalPion.engine, "pion");
  assert.equal(globalPion.source, "env");
  assert.equal(globalPion.fallback, false);

  // Per-mode config pins override global STILLFAIL_READER_ENGINE.
  const configWinsOverGlobal = resolveReaderEngine("footprint", {
    config: { readers: { footprint: "mb" } },
    env: { STILLFAIL_READER_ENGINE: "pion" },
    hasPionBinary: true,
  });
  assert.equal(configWinsOverGlobal.engine, "mb");
  assert.equal(configWinsOverGlobal.source, "config");
  assert.equal(configWinsOverGlobal.fallback, false);

  // Per-mode env STILLFAIL_READER_<MODE> still overrides both config and global env.
  const perModeWins = resolveReaderEngine("footprint", {
    config: { readers: { footprint: "pion" } },
    env: { STILLFAIL_READER_ENGINE: "pion", STILLFAIL_READER_FOOTPRINT: "mb" },
    hasPionBinary: true,
  });
  assert.equal(perModeWins.engine, "mb");
  assert.equal(perModeWins.source, "env");
  assert.equal(perModeWins.fallback, false);

  // Global shadow is still blocked on non-footprint modes.
  const blockedShadow = resolveReaderEngine("data", {
    env: { STILLFAIL_READER_ENGINE: "shadow" },
    hasPionBinary: true,
  });
  assert.equal(blockedShadow.engine, "mb");
  assert.equal(blockedShadow.fallback, true);
  assert.equal(blockedShadow.reason, "shadow-forbidden");
});

test("every mode with pionImplemented: true is explicitly wired to resolveReaderSelection (exact allowlist guard)", () => {
  // Modes whose spawn sites are wired through resolveReaderSelection AND backed by Pion implementations.
  // Adding a mode here requires wiring its actual spawn site and updating the capability gate.
  const WIRED_PION_MODES = new Set<ReaderMode>([
    "archive-last",
    "archive-marks",
    "card-posts",
    "closed-cards",
    "footprint",
    "memory",
    "outflow-chats",
    "packed",
    "page-letters",
    "people-since",
    "post-blocks",
    "search-scope",
    "session-bindings",
    "session-counts",
    "session-list",
    "session-up-jobs",
    "signin-save",
    "usage-retire",
    "widget-sources",
    "workspace-up-jobs",
  ]);
  const enabled = (Object.entries(READER_MODES) as [ReaderMode, (typeof READER_MODES)[ReaderMode]][])
    .filter(([, meta]) => meta.pionImplemented)
    .map(([mode]) => mode)
    .sort();
  for (const mode of enabled) {
    assert.ok(
      WIRED_PION_MODES.has(mode),
      `mode "${mode}" has pionImplemented: true in READER_MODES but is not in WIRED_PION_MODES`,
    );
  }
  assert.deepEqual(enabled, [...WIRED_PION_MODES].sort());
});
