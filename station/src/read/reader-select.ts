// Per-mode reader engine selector and shadow-mode safety gate for migrating `stillfail-reader`
// from MoonBit (`mb`) to Pion (`pion`) one slice at a time.
//
// Invariants:
// - Default engine is always `"mb"`.
// - Environment variable `STILLFAIL_READER_<UPPER_SNAKE_MODE>` overrides `config.json`'s `readers[mode]`.
// - Only strictly read-only, side-effect-free modes (currently only `footprint`) may run in `"shadow"` mode.
//   Stateful, database-writing, cache-writing, filesystem-mutating, or socket-binding modes MUST reject
//   `"shadow"` and fall back safely to `"mb"` so two engines never mutate the same store or state concurrently.
// - Requesting `"pion"` (or an allowed `"shadow"`) when no Pion binary is available falls back safely
//   to `"mb"` with a structured reason for logging.

export type ReaderEngine = "mb" | "pion" | "shadow";

export type ReaderSideEffect = "read-only" | "read-with-side-effects" | "write-db" | "write-fs" | "network";

export type ReaderModeMeta = {
  readonly allowShadow: boolean;
  readonly pionImplemented: boolean;
  readonly sideEffect: ReaderSideEffect;
  readonly note: string;
};

/**
 * Explicit registry of every `stillfail-reader` execution mode (`--data`, `--serve`, `--sessions`,
 * and `--builder <kind>`), declaring whether dual-run `shadow` mode is permitted and whether the
 * Pion implementation is ready to serve it (`pionImplemented`).
 *
 * Only `footprint` is currently certified pure read-only / side-effect-free (`allowShadow: true`).
 * All other modes (`data` runs WAL checkpoints & writes timeline marks cache; `search`, `live-locator`,
 * `usage-check` attach SQLite / shell state; builders & servers mutate DB/FS/sockets) forbid `shadow`
 * until individually proven read-only and isolated.
 */
export const READER_MODES = {
  // Pure read-only / no-side-effect modes (shadow allowed)
  footprint: {
    allowShadow: true,
    pionImplemented: true,
    sideEffect: "read-only",
    note: "Read-only disk footprint walk (--builder footprint)",
  },

  // Stateful / DB-attaching / cache-writing / FS-mutating / network-binding modes (shadow strictly forbidden)
  data: {
    allowShadow: false,
    pionImplemented: false,
    sideEffect: "write-db",
    note: "Query pool process with WAL checkpoints and timeline marks cache writes (--data)",
  },
  search: {
    allowShadow: false,
    pionImplemented: false,
    sideEffect: "read-with-side-effects",
    note: "Transcript and history search: attaches SQLite/shell_dir and shares transcript hints (--builder search)",
  },
  "live-locator": {
    allowShadow: false,
    pionImplemented: false,
    sideEffect: "read-with-side-effects",
    note: "Live transcript locator: attaches SQLite/shell_dir (--builder live-locator)",
  },
  "usage-check": {
    allowShadow: false,
    pionImplemented: false,
    sideEffect: "read-with-side-effects",
    note: "Historical usage coverage checker: attaches SQLite/shell_dir (--builder usage-check)",
  },
  serve: {
    allowShadow: false,
    pionImplemented: false,
    sideEffect: "network",
    note: "Device request server over Unix socket (--serve)",
  },
  sessions: {
    allowShadow: false,
    pionImplemented: false,
    sideEffect: "write-db",
    note: "Session actors, #jobs, #remote, #live with SQLite writes (--sessions)",
  },
  memory: {
    allowShadow: false,
    pionImplemented: true,
    sideEffect: "write-fs",
    note: "Agent memory file 3-way merges and writes (--builder memory)",
  },
  packed: {
    allowShadow: false,
    pionImplemented: true,
    sideEffect: "write-fs",
    note: "Cold-storage zstd/tar packing and unpacking (--builder packed)",
  },
  "replica-export": {
    allowShadow: false,
    pionImplemented: false,
    sideEffect: "write-fs",
    note: "Replica chunk export and state mutation (--builder replica-export)",
  },
  "replica-restore": {
    allowShadow: false,
    pionImplemented: false,
    sideEffect: "write-db",
    note: "Replica restore into SQLite and data dir (--builder replica-restore)",
  },
  "replica-carry": {
    allowShadow: false,
    pionImplemented: false,
    sideEffect: "write-fs",
    note: "Migration file gather/place operations (--builder replica-carry)",
  },
  "vault-uses": {
    allowShadow: false,
    pionImplemented: false,
    sideEffect: "write-db",
    note: "Vault use-index writes (--builder vault-uses)",
  },
  "usage-counter": {
    allowShadow: false,
    pionImplemented: false,
    sideEffect: "write-db",
    note: "Usage transcript scan and SQLite writes (--builder usage-counter)",
  },
  "usage-retire": {
    allowShadow: false,
    pionImplemented: true,
    sideEffect: "write-db",
    note: "Legacy usage table fill and drop (--builder usage-retire)",
  },
  "archive-marks": {
    allowShadow: false,
    pionImplemented: true,
    sideEffect: "write-db",
    note: "Archive mark index builder (--builder archive-marks)",
  },
  "archive-last": {
    allowShadow: false,
    pionImplemented: true,
    sideEffect: "write-db",
    note: "Archive last-message index builder (--builder archive-last)",
  },
  "session-bindings": {
    allowShadow: false,
    pionImplemented: true,
    sideEffect: "write-db",
    note: "Session bindings index builder (--builder session-bindings)",
  },
  "session-up-jobs": {
    allowShadow: false,
    pionImplemented: true,
    sideEffect: "write-db",
    note: "Session up-jobs index builder (--builder session-up-jobs)",
  },
  "workspace-up-jobs": {
    allowShadow: false,
    pionImplemented: true,
    sideEffect: "write-db",
    note: "Workspace up-jobs index builder (--builder workspace-up-jobs)",
  },
  "widget-sources": {
    allowShadow: false,
    pionImplemented: true,
    sideEffect: "write-db",
    note: "Widget sources index builder (--builder widget-sources)",
  },
  "card-posts": {
    allowShadow: false,
    pionImplemented: true,
    sideEffect: "write-db",
    note: "Card posts index builder (--builder card-posts)",
  },
  "closed-cards": {
    allowShadow: false,
    pionImplemented: true,
    sideEffect: "write-db",
    note: "Closed cards index builder (--builder closed-cards)",
  },
  "people-since": {
    allowShadow: false,
    pionImplemented: true,
    sideEffect: "write-db",
    note: "People-since index builder (--builder people-since)",
  },
  "legacy-edits": {
    allowShadow: false,
    pionImplemented: false,
    sideEffect: "write-db",
    note: "Legacy edits migration builder (--builder legacy-edits)",
  },
  "legacy-said": {
    allowShadow: false,
    pionImplemented: false,
    sideEffect: "write-db",
    note: "Legacy said migration builder (--builder legacy-said)",
  },
  "session-counts": {
    allowShadow: false,
    pionImplemented: true,
    sideEffect: "write-db",
    note: "Session counts backfill builder (--builder session-counts)",
  },
  "session-backfill": {
    allowShadow: false,
    pionImplemented: false,
    sideEffect: "write-db",
    note: "Session activity/recovery backfill builder (--builder session-backfill)",
  },
  "post-blocks": {
    allowShadow: false,
    pionImplemented: true,
    sideEffect: "write-db",
    note: "Post blocks index builder (--builder post-blocks)",
  },
  "signin-save": {
    allowShadow: false,
    pionImplemented: true,
    sideEffect: "write-db",
    note: "Sign-in index builder (--builder signin-save)",
  },
  "search-scope": {
    allowShadow: false,
    pionImplemented: true,
    sideEffect: "write-db",
    note: "Search scope preparation builder (--builder search-scope)",
  },
  "outflow-chats": {
    allowShadow: false,
    pionImplemented: true,
    sideEffect: "write-db",
    note: "Outflow chats index builder (--builder outflow-chats)",
  },
  said: {
    allowShadow: false,
    pionImplemented: false,
    sideEffect: "write-db",
    note: "Sidebar said-state builder (--builder said)",
  },
  "page-letters": {
    allowShadow: false,
    pionImplemented: true,
    sideEffect: "write-db",
    note: "Old page letters builder (--builder page-letters)",
  },
  "recent-chat": {
    allowShadow: false,
    pionImplemented: false,
    sideEffect: "write-db",
    note: "Recent chat preparation builder (--builder recent-chat)",
  },
  "cc-index": {
    allowShadow: false,
    pionImplemented: false,
    sideEffect: "write-db",
    note: "Copy destinations and chat order builder (--builder cc-index)",
  },
  "turn-counts": {
    allowShadow: false,
    pionImplemented: false,
    sideEffect: "write-db",
    note: "Session turn-counts builder (--builder turn-counts)",
  },
  "session-list": {
    allowShadow: false,
    pionImplemented: true,
    sideEffect: "write-db",
    note: "Session list index builder (--builder session-list)",
  },
  forward: {
    allowShadow: false,
    pionImplemented: false,
    sideEffect: "network",
    note: "Local TCP port forwarder (--builder forward)",
  },
  mesh: {
    allowShadow: false,
    pionImplemented: false,
    sideEffect: "network",
    note: "Iroh mesh front endpoint (--builder mesh)",
  },
} as const satisfies Record<string, ReaderModeMeta>;

export type ReaderMode = keyof typeof READER_MODES;

export type ReaderSelectConfig = {
  readonly readers?: Readonly<Record<string, unknown>> | null;
} | null | undefined;

export type ReaderSelectOptions = {
  readonly config?: ReaderSelectConfig;
  readonly env?: Readonly<Record<string, string | undefined>>;
  readonly hasPionBinary: boolean;
  /** Optional override for `READER_MODES[mode].pionImplemented` (used by tests verifying binary capability probes). */
  readonly pionImplemented?: boolean;
  /** Whether the discovered Pion binary supports `mode` (defaults to `true`). */
  readonly pionModeSupported?: boolean;
};

export type ReaderSelectSource = "default" | "config" | "env" | "explicit";

export type ReaderFallbackReason =
  | "invalid-value"
  | "shadow-forbidden"
  | "pion-mode-unimplemented"
  | "pion-binary-missing"
  | "pion-binary-unsupported-mode";

export type ReaderSelection = {
  readonly mode: ReaderMode;
  readonly engine: ReaderEngine;
  readonly requested: ReaderEngine | null;
  readonly rawRequested: string | null;
  readonly source: ReaderSelectSource;
  readonly fallback: boolean;
  readonly reason?: ReaderFallbackReason;
  readonly detail?: string;
};

export const READER_ENV_PREFIX = "STILLFAIL_READER_";
export const READER_ENGINE_ENV = "STILLFAIL_READER_ENGINE";

/** Compute the canonical environment variable name for a reader mode. */
export function readerModeEnvKey(mode: ReaderMode): `STILLFAIL_READER_${string}` {
  return `${READER_ENV_PREFIX}${mode.replaceAll("-", "_").toUpperCase()}`;
}

/** Type guard for known reader modes. */
export function isReaderMode(value: string): value is ReaderMode {
  return Object.hasOwn(READER_MODES, value);
}

/** Safely format an arbitrary config/env value for diagnostics without calling `toString()` on untrusted objects. */
function formatRawValue(raw: unknown): string {
  if (typeof raw === "string") return raw;
  if (
    typeof raw === "number" ||
    typeof raw === "boolean" ||
    typeof raw === "bigint" ||
    raw === null ||
    raw === undefined
  ) {
    return `${raw}`;
  }
  if (typeof raw === "symbol") {
    return raw.description !== undefined ? `Symbol(${raw.description})` : "Symbol()";
  }
  try {
    const json = JSON.stringify(raw);
    return json !== undefined ? json : "[unserializable]";
  } catch {
    return "[unserializable]";
  }
}

function parseEngineValue(raw: unknown): { engine: ReaderEngine | null; rawText: string } {
  if (typeof raw !== "string") {
    return { engine: null, rawText: formatRawValue(raw) };
  }
  const normalized = raw.trim().toLowerCase();
  if (normalized === "mb" || normalized === "pion" || normalized === "shadow") {
    return { engine: normalized, rawText: raw };
  }
  return { engine: null, rawText: raw };
}

/**
 * Resolve which engine (`"mb"`, `"pion"`, or `"shadow"`) should execute `mode`.
 *
 * Precedence:
 * 1. Per-mode environment variable `STILLFAIL_READER_<UPPER_SNAKE_MODE>` (non-empty trimmed string)
 * 2. `config.readers[mode]`
 * 3. Global environment variable `STILLFAIL_READER_ENGINE` (non-empty trimmed string)
 * 4. Default `"mb"`
 *
 * Safety gates:
 * - Invalid values fall back to `"mb"` (`reason: "invalid-value"`).
 * - `"shadow"` on any mode with `allowShadow === false` is refused and falls back to `"mb"`
 *   (`reason: "shadow-forbidden"`).
 * - `"pion"` or `"shadow"` when `hasPionBinary === false` falls back to `"mb"`
 *   (`reason: "pion-binary-missing"`).
 */
export function resolveReaderEngine(
  mode: ReaderMode,
  opts: ReaderSelectOptions,
): ReaderSelection {
  const meta: ReaderModeMeta = READER_MODES[mode];
  const env = opts.env ?? process.env;
  const envKey = readerModeEnvKey(mode);
  const rawEnv = env[envKey];
  const rawGlobalEnv = env[READER_ENGINE_ENV];

  let source: ReaderSelectSource = "default";
  let rawInput: unknown = undefined;

  if (typeof rawEnv === "string" && rawEnv.trim() !== "") {
    source = "env";
    rawInput = rawEnv;
  } else {
    const readers = opts.config?.readers;
    if (readers !== null && readers !== undefined && typeof readers === "object" && !Array.isArray(readers) && Object.hasOwn(readers, mode)) {
      const configured = readers[mode];
      if (configured !== undefined && configured !== null && !(typeof configured === "string" && configured.trim() === "")) {
        source = "config";
        rawInput = configured;
      }
    }
    if (source === "default" && typeof rawGlobalEnv === "string" && rawGlobalEnv.trim() !== "") {
      source = "env";
      rawInput = rawGlobalEnv;
    }
  }

  if (source === "default") {
    return {
      mode,
      engine: "mb",
      requested: null,
      rawRequested: null,
      source: "default",
      fallback: false,
    };
  }

  const parsed = parseEngineValue(rawInput);
  if (parsed.engine === null) {
    return {
      mode,
      engine: "mb",
      requested: null,
      rawRequested: parsed.rawText,
      source,
      fallback: true,
      reason: "invalid-value",
      detail: `invalid reader engine ${JSON.stringify(parsed.rawText)} from ${source} for mode "${mode}"; expected "mb" | "pion" | "shadow", falling back to "mb"`,
    };
  }

  const requested = parsed.engine;
  if (requested === "mb") {
    return {
      mode,
      engine: "mb",
      requested,
      rawRequested: parsed.rawText,
      source,
      fallback: false,
    };
  }

  if (requested === "shadow" && !meta.allowShadow) {
    return {
      mode,
      engine: "mb",
      requested,
      rawRequested: parsed.rawText,
      source,
      fallback: true,
      reason: "shadow-forbidden",
      detail: `mode "${mode}" (${meta.sideEffect}) forbids shadow execution; falling back to "mb"`,
    };
  }

  const implemented = opts.pionImplemented ?? meta.pionImplemented;
  if (!implemented) {
    return {
      mode,
      engine: "mb",
      requested,
      rawRequested: parsed.rawText,
      source,
      fallback: true,
      reason: "pion-mode-unimplemented",
      detail: `mode "${mode}" requested "${requested}" from ${source} but Pion implementation is not yet enabled; falling back to "mb"`,
    };
  }

  if (!opts.hasPionBinary) {
    return {
      mode,
      engine: "mb",
      requested,
      rawRequested: parsed.rawText,
      source,
      fallback: true,
      reason: "pion-binary-missing",
      detail: `mode "${mode}" requested "${requested}" from ${source} but Pion binary is unavailable; falling back to "mb"`,
    };
  }

  if (opts.pionModeSupported === false) {
    return {
      mode,
      engine: "mb",
      requested,
      rawRequested: parsed.rawText,
      source,
      fallback: true,
      reason: "pion-binary-unsupported-mode",
      detail: `mode "${mode}" requested "${requested}" from ${source} but the Pion binary on disk does not support "${mode}"; falling back to "mb"`,
    };
  }

  return {
    mode,
    engine: requested,
    requested,
    rawRequested: parsed.rawText,
    source,
    fallback: false,
  };
}
