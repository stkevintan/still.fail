// The station's reader in MoonBit (station/mb, src/reader): a process of its own, asked and answering a line of JSON
// each way on its stdin and stdout. The pool (read/pool.ts) gives it every read and the store's checkpoints (`--data`);
// with `--builder` it is a builder of old state, asked by read/requested-builder.ts or, for a backfill the station
// drives itself, through `MbBackfill`. It is built for every system a station runs on, so there is no reader or builder
// in TypeScript to fall back to: those it replaced are the tests' only (test/reference-worker.ts, test/workers/).
import { type ChildProcess, execFile, spawn } from "node:child_process";
import { EventEmitter } from "node:events";
import { accessSync, constants, existsSync, statSync } from "node:fs";
import { resolve, sep } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { wall } from "../ops/fibers.ts";
import type { Lang } from "../ops/i18n.ts";
import { log } from "../ops/log.ts";
import { platform } from "../platform/index.ts";
import { giveBackfill, takeBackfill } from "../store/backfill.ts";
import {
  type ReaderEngine,
  type ReaderMode,
  type ReaderSelectConfig,
  type ReaderSelection,
  resolveReaderEngine,
} from "./reader-select.ts";

/// A read asked of a reader (main.mbt `answer`).
export type Ask = { id: number; op: string; args: any; lang: Lang; names: [string, string][]; processes: [string, string][]; clientKeys: [string, string][]; catalog?: Record<string, unknown> };
/// A read's answer. `body`: the text as its bytes, as the program gives it (`Said`).
export type Answer = { id: number; text?: string; body?: Buffer; status?: number; error?: string; prepareUpJobs?: string; prepareWorkspaceUpJobs?: boolean };
/// Said once, as a reader is ready: how long it took from its first line (its code read in) to its store opened.
export type Ready = { ready: { loadedMs: number; openedMs: number } };

/// The program: STILLFAIL_MB_READER, else beside the station's code in a release, else where `moon build` puts it in
/// a checkout (station/mb/build.sh, for the Mac). None: not built here. Found once for each STILLFAIL_MB_READER (a
/// test may set its own): a builder, a measure and the agents' program each started asking it, every time a look at
/// the disk on the main thread. Not found is looked for again, as a checkout may build it while the station runs.
const foundBinary = new Map<string, string>();
export function mbReaderBinary(): string | null {
  const envKey = process.env.STILLFAIL_MB_READER ?? "";
  const had = foundBinary.get(envKey);
  if (had !== undefined) return had;
  const candidates = [
    process.env.STILLFAIL_MB_READER,
    fileURLToPath(new URL(`./${platform.exe("stillfail-reader")}`, import.meta.url)),
    // (from the source only: bundled, this is main.js, beside which the release puts the program)
    import.meta.url.endsWith(".ts") ? fileURLToPath(new URL("../../mb/_build/stillfail-reader-darwin-arm64", import.meta.url)) : undefined,
  ];
  const found = candidates.find((p) => p !== undefined && p !== "" && existsSync(p)) ?? null; // sync: once, as the station opens its readers before it serves
  if (found !== null) foundBinary.set(envKey, found);
  return found;
}

/// The program, which every station has (`mbReaderBinary`); where it is not built (a checkout that has not), what needs
/// it fails saying so.
export function readerBinary(): string {
  const binary = mbReaderBinary();
  if (binary === null) throw new Error("the station's MoonBit program (stillfail-reader) is not built here (station/mb/build.sh, or STILLFAIL_MB_READER)");
  return binary;
}

function isExecutableFile(path: string): boolean {
  try {
    if (!statSync(path).isFile()) return false; // sync: startup/explicit binary resolution, cached on success
    if (platform.os !== "windows") accessSync(path, constants.X_OK); // sync: startup/explicit binary resolution, cached on success
    return true;
  } catch {
    return false;
  }
}

const foundPionBinary = new Map<string, string | null>();
/// Cooldown before re-checking disk when non-explicit `pionBinary()` lookup missed (avoids repeated `statSync`
/// on hot paths while still discovering binaries installed or built while the station is running).
const PION_BINARY_MISS_COOLDOWN_MS = 30_000;
let pionBinaryMissUntil = 0;

/// The Pion reader/builder binary (`stillfail-pion`):
/// 1. Explicit `STILLFAIL_PION_READER` env override (resolved via `path.resolve`; if set and non-empty,
///    only that path is accepted and its lookup result — found or missing — is cached by resolved path)
/// 2. Bundled beside `stillfail-reader` (`stillfail-pion` / `stillfail-pion.exe`)
/// 3. Checkout dev build (`pion/station/_build/stillfail-pion-<host>`)
export function pionBinary(): string | null {
  const explicitRaw = process.env.STILLFAIL_PION_READER?.trim();
  if (explicitRaw !== undefined && explicitRaw !== "") {
    const resolved = resolve(explicitRaw);
    const cacheKey = `explicit:${resolved}`;
    if (foundPionBinary.has(cacheKey)) return foundPionBinary.get(cacheKey)!;
    const ok = isExecutableFile(resolved) ? resolved : null;
    foundPionBinary.set(cacheKey, ok);
    return ok;
  }
  const had = foundPionBinary.get("");
  if (had !== undefined && had !== null) return had;
  if (had === null && wall.now() < pionBinaryMissUntil) return null;
  const hostBuild = import.meta.url.endsWith(".ts") && platform.buildOs !== null
    ? fileURLToPath(new URL(`../../../pion/station/_build/${platform.exe(`stillfail-pion-${platform.buildOs}-${process.arch}`)}`, import.meta.url))
    : undefined;
  const candidates = [
    fileURLToPath(new URL(`./${platform.exe("stillfail-pion")}`, import.meta.url)),
    hostBuild,
  ];
  const found = candidates.find((p) => p !== undefined && p !== "" && isExecutableFile(p)) ?? null;
  foundPionBinary.set("", found);
  pionBinaryMissUntil = found === null ? wall.now() + PION_BINARY_MISS_COOLDOWN_MS : 0;
  return found;
}

/// The three baseline modes supported without a `--version` probe.
/// This assumes any `stillfail-pion` binary on disk is no older than the three-baseline-complete release baseline
/// (commit `ab0bba7835` and later, predating Wave 5 first bundling `stillfail-pion` with stations).
export const PION_BASELINE_MODES: ReadonlySet<ReaderMode> = new Set<ReaderMode>(["footprint", "packed", "memory"]);

/// Cooldown before retrying a failed or timed-out `--version` probe (transient load should not lock out Pion forever).
const PION_PROBE_RETRY_COOLDOWN_MS = 30_000;

const probedPionModes = new Map<string, ReadonlySet<string>>();
const probingPionModes = new Map<string, Promise<ReadonlySet<string> | null>>();
const failedPionProbeUntil = new Map<string, number>();
const warnedReaderFallbacks = new Set<string>();

/// Parse supported modes from `stillfail-pion --version` output (`modes:a,b,c`).
/// Older binaries that omit `modes:` are treated as supporting only the 3 baseline modes.
export function parsePionVersionModes(stdout: string): ReadonlySet<string> {
  const modes = new Set<string>(PION_BASELINE_MODES);
  const match = /(?:^|\s)modes:([a-z0-9_,-]+)/i.exec(stdout);
  if (match?.[1]) {
    for (const part of match[1].split(",")) {
      const m = part.trim().toLowerCase();
      if (m !== "") modes.add(m);
    }
  }
  return modes;
}

/// Non-blocking asynchronous capability probe for `binaryPath` (`execFile(binaryPath, ["--version"], { timeout: 3000, killSignal: "SIGKILL" })`).
/// Returns the cached set of supported mode names once a clean exit-0 probe succeeds, or `null` while probing or during
/// a transient-failure retry cooldown. Never called on default `mb` or for the 3 baseline modes (`footprint`, `packed`, `memory`).
export function pionSupportedModes(binaryPath: string): ReadonlySet<string> | null {
  const key = resolve(binaryPath);
  const cached = probedPionModes.get(key);
  if (cached !== undefined) return cached;
  const retryAfter = failedPionProbeUntil.get(key);
  if (retryAfter !== undefined && wall.now() < retryAfter) return null;
  if (!probingPionModes.has(key)) {
    let settled = false;
    const pending = new Promise<ReadonlySet<string> | null>((resolveProbe) => {
      const finish = (supported: ReadonlySet<string> | null) => {
        if (settled) return;
        settled = true;
        probingPionModes.delete(key);
        if (supported !== null) {
          failedPionProbeUntil.delete(key);
          probedPionModes.set(key, supported);
        } else {
          failedPionProbeUntil.set(key, wall.now() + PION_PROBE_RETRY_COOLDOWN_MS);
        }
        resolveProbe(supported);
      };
      try {
        execFile(key, ["--version"], { timeout: 3_000, killSignal: "SIGKILL", windowsHide: true }, (err, stdout) => {
          finish(err ? null : parsePionVersionModes(String(stdout ?? "")));
        });
      } catch {
        finish(null);
      }
    });
    if (!settled) probingPionModes.set(key, pending);
  }
  return null;
}

/// Await the non-blocking `--version` capability probe for `binaryPath` (starts one if not yet cached).
/// Returns the probed supported mode set, or `null` if the probe failed or timed out.
export function probePionSupportedModes(binaryPath: string): Promise<ReadonlySet<string> | null> {
  const cached = pionSupportedModes(binaryPath);
  if (cached !== null) return Promise.resolve(cached);
  return probingPionModes.get(resolve(binaryPath)) ?? Promise.resolve(null);
}

/// Clear cached binary lookups, `--version` capability probes, retry cooldowns, and deduped fallback warnings (tests only).
export function resetReaderSelectionStateForTest(): void {
  foundPionBinary.clear();
  pionBinaryMissUntil = 0;
  probedPionModes.clear();
  probingPionModes.clear();
  failedPionProbeUntil.clear();
  warnedReaderFallbacks.clear();
}

export type ResolveReaderSelectionOptions = {
  /// Explicit binary override; always wins and skips engine selection and `pionBinary()` probing.
  readonly binary?: string | null;
  /// Live `config.json` `readers` snapshot or getter.
  readonly config?: ReaderSelectConfig | (() => ReaderSelectConfig);
  /// Environment variables (defaults to `process.env`).
  readonly env?: Readonly<Record<string, string | undefined>>;
  /// Log component tag for deduplicated fallback warnings (defaults to `"readers"`).
  readonly logAt?: string;
  /// Optional override for `READER_MODES[mode].pionImplemented` (tests verifying binary capability probes).
  readonly pionImplemented?: boolean;
};

export type ResolvedReaderSelection = {
  readonly engine: ReaderEngine;
  readonly primaryBinary: string;
  readonly pionBinary: string | null;
  readonly selection: ReaderSelection;
};

function warnReaderFallbackOnce(logAt: string, selection: ReaderSelection): void {
  if (!selection.fallback) return;
  const dedupKey = `${selection.mode}:${selection.source}:${selection.reason ?? "unknown"}`;
  if (warnedReaderFallbacks.has(dedupKey)) return;
  warnedReaderFallbacks.add(dedupKey);
  log.warn(logAt, "reader engine fallback", {
    mode: selection.mode,
    engine: selection.engine,
    requested: selection.requested,
    source: selection.source,
    reason: selection.reason,
    detail: selection.detail,
  });
}

/// Unified reader/builder binary & engine selector for single-engine and `shadow` modes.
///
/// Invariants:
/// - Explicit `options.binary` always takes precedence without probing `pionBinary()`.
/// - Default `"mb"` never calls `pionBinary()` (zero main-thread `statSync`, zero `--version` spawn).
/// - Unimplemented Pion modes (`pionImplemented === false`) fall back to `"mb"` before touching disk.
/// - Non-baseline Pion modes check `pionSupportedModes(pionBin)` asynchronously: while the first
///   `--version` probe is in flight they safely run `"mb"`, and once probed either switch to `"pion"`
///   or permanently fall back to `"mb"` for that binary path with a deduped `pion-binary-unsupported-mode` warn.
export function resolveReaderSelection(
  mode: ReaderMode,
  options: ResolveReaderSelectionOptions = {},
): ResolvedReaderSelection {
  if (options.binary != null) {
    return {
      engine: "mb",
      primaryBinary: options.binary,
      pionBinary: null,
      selection: {
        mode,
        engine: "mb",
        requested: null,
        rawRequested: null,
        source: "explicit",
        fallback: false,
      },
    };
  }
  const logAt = options.logAt ?? "readers";
  const config = typeof options.config === "function" ? options.config() : options.config;
  const probe = resolveReaderEngine(mode, {
    config,
    env: options.env,
    hasPionBinary: true,
    pionImplemented: options.pionImplemented,
  });
  if (probe.engine === "mb") {
    warnReaderFallbackOnce(logAt, probe);
    return { engine: "mb", primaryBinary: readerBinary(), pionBinary: null, selection: probe };
  }
  const pionBin = pionBinary();
  if (pionBin === null) {
    const selection = resolveReaderEngine(mode, {
      config,
      env: options.env,
      hasPionBinary: false,
      pionImplemented: options.pionImplemented,
    });
    warnReaderFallbackOnce(logAt, selection);
    return { engine: "mb", primaryBinary: readerBinary(), pionBinary: null, selection };
  }
  if (!PION_BASELINE_MODES.has(mode)) {
    const supported = pionSupportedModes(pionBin);
    if (supported === null) {
      return {
        engine: "mb",
        primaryBinary: readerBinary(),
        pionBinary: null,
        selection: { ...probe, engine: "mb", fallback: true },
      };
    }
    if (!supported.has(mode)) {
      const selection = resolveReaderEngine(mode, {
        config,
        env: options.env,
        hasPionBinary: true,
        pionImplemented: options.pionImplemented,
        pionModeSupported: false,
      });
      warnReaderFallbackOnce(logAt, selection);
      return { engine: "mb", primaryBinary: readerBinary(), pionBinary: null, selection };
    }
  }
  if (probe.engine === "pion") {
    return { engine: "pion", primaryBinary: pionBin, pionBinary: pionBin, selection: probe };
  }
  return { engine: "shadow", primaryBinary: readerBinary(), pionBinary: pionBin, selection: probe };
}

/// Shared options for background and on-demand reader builders.
export type BackfillOptions = {
  previousGone?: Promise<void>;
  priority?: SharedArrayBuffer;
  readers?: () => ReaderSelectConfig;
};

/// What the pool asks of a reader: the program's process, or what a test gives in its place (test/reference.ts).
export interface ReaderLike {
  on(event: "message", f: (answer: Answer | Ready) => void): this;
  on(event: "error", f: (error: Error) => void): this;
  on(event: "exit", f: (code: number) => void): this;
  postMessage(ask: Ask): void;
  terminate(): Promise<number>;
  getHeapStatistics(): Promise<{ used_heap_size: number }>;
}

/// What a program says on its stdout: a line of JSON at a time, each told whole as it ends; a line that says `bytes` has
/// that many bytes after it, its body, told with it as `body` as they are (the reader's answer: main.mbt `say_answer`),
/// never decoded or unescaped here. A line is ended by its `\n` alone (readline also took U+2028 and U+2029 for ends).
export class Said {
  #carry: Buffer[] = [];
  #size = 0;
  /// The head waiting for its body, and how many bytes of it are still to come.
  #head: Record<string, unknown> | null = null;
  #wanted = 0;
  readonly #tell: (said: unknown) => void;
  constructor(tell: (said: unknown) => void) { this.#tell = tell; }

  push(bytes: Buffer) {
    let at = 0;
    while (at < bytes.length) {
      if (this.#head !== null) {
        const take = Math.min(this.#wanted - this.#size, bytes.length - at);
        this.#carry.push(bytes.subarray(at, at + take));
        this.#size += take;
        at += take;
        if (this.#size < this.#wanted) return;
        const head = this.#head;
        const body = this.#carry.length === 1 ? this.#carry[0]! : Buffer.concat(this.#carry, this.#size);
        this.#head = null;
        this.#carry = [];
        this.#size = 0;
        this.#tell({ ...head, body });
        continue;
      }
      const end = bytes.indexOf(10, at);
      if (end < 0) {
        this.#carry.push(bytes.subarray(at));
        this.#size += bytes.length - at;
        return;
      }
      this.#carry.push(bytes.subarray(at, end));
      const line = (this.#carry.length === 1 ? this.#carry[0]! : Buffer.concat(this.#carry)).toString();
      this.#carry = [];
      this.#size = 0;
      at = end + 1;
      if (line === "") continue;
      let head: unknown;
      try { head = JSON.parse(line); }
      catch {
        log.warn("readers", "a MoonBit program said what is not JSON", { line: line.slice(0, 200) });
        continue;
      }
      const wanted = (head as { bytes?: unknown } | null)?.bytes;
      if (typeof wanted === "number" && Number.isInteger(wanted) && wanted >= 0) {
        const { bytes: _, ...rest } = head as Record<string, unknown>;
        this.#head = rest;
        this.#wanted = wanted;
        if (wanted === 0) {
          this.#head = null;
          this.#tell({ ...rest, body: Buffer.alloc(0) });
        }
        continue;
      }
      this.#tell(head);
    }
  }
}

/// The builders nobody waits on: what the station drives itself, a batch at a time (MbBackfill's kinds), the export
/// of the chats' copies, and a directory's size measured on disk (sessions/footprint.ts). Every other builder answers a request as it is asked (a search, the vault's uses, the usage
/// page, a live session found, the outflow's chats), or holds the backfill permit for its batch as a read waits on it
/// (read/requested-builder.ts), or is waited on by a person (a restore, the mesh's): under PRIO_DARWIN_BG's throttled IO
/// on a busy Mac each would take many times as long, holding up the person or the permit.
const BACKGROUND_BUILDERS = new Set(["replica-export", "footprint", "session-backfill", "post-blocks", "session-counts", "usage-counter", "usage-retire", "signin-save"]);

/// Whether the program with `args` is the station's background work by default: a builder of BACKGROUND_BUILDERS
/// (`--builder <kind>`). The readers that answer devices as they ask (`--data`, `--serve`, `--sessions`) are not.
export function backgroundByDefault(args: readonly string[]): boolean {
  const at = args.indexOf("--builder");
  return at >= 0 && BACKGROUND_BUILDERS.has(args[at + 1] ?? "");
}

/// What is spawned for the program `binary` with `args`: under platform.backgrounded when it is background work
/// (`background`, else backgroundByDefault), so the builders scanning the database and the disk on their own yield the
/// CPU and the disk to the station's foreground and the agents'; as it is otherwise.
export function mbSpawned(binary: string, args: string[], options: { background?: boolean } = {}): [string, string[]] {
  return (options.background ?? backgroundByDefault(args)) ? platform.backgrounded(binary, args) : [binary, args];
}

/// The most of what is written to a program's stdin that it has not read yet, which Node keeps: a program that stopped
/// reading (stuck in a query, hung) past it is ended, its users told by its exit (a reader started again, a read
/// failed), not let grow the station's memory with every ask given it meanwhile. The program's own queue of stdin is
/// bounded too (mb/src/host/host.c STDIN_MOST): past it the rest waits in the pipe, then here.
export const STDIN_MOST = 64 * 1024 * 1024;
/// Unread past this, it is said once (and not ended): from then to STDIN_MOST, what it read of what it was given tells
/// whether it stopped reading (next to nothing) or is given more than it reads.
export const STDIN_BEHIND = 8 * 1024 * 1024;

/// A program's process that runs, as the station's watch over its own memory counts them (ops/self-memory.ts).
export type LiveProgram = { pid: number; args: readonly string[]; background: boolean; startedAt: number };

/// The program's process, a line of JSON each way: told its lines as "message"s, its end as "exit".
export class MbProcess extends EventEmitter {
  /// Every program's process this station runs, until its end.
  static readonly #live = new Map<MbProcess, LiveProgram>();
  /// Those running now, by their pids, arguments and since when.
  static live(): ReadonlyArray<LiveProgram> { return [...MbProcess.#live.values()]; }

  readonly #child: ChildProcess;
  readonly #args: readonly string[];
  readonly #stdinMost: number;
  #exited = false;
  #stalled = false;
  /// All written to its stdin, and where it stood when it was last found behind (STDIN_BEHIND, `postLine`).
  #written = 0;
  #behind: { at: number; written: number; unread: number } | null = null;

  /// `options.background`: whether it runs as the system's background work (mbSpawned), else as its args say;
  /// `stdinMost`: STDIN_MOST but in tests.
  constructor(binary: string, args: string[], options: { background?: boolean; stdinMost?: number } = {}) {
    super();
    const background = options.background ?? backgroundByDefault(args);
    const [command, given] = mbSpawned(binary, args, { background });
    this.#args = args;
    this.#stdinMost = options.stdinMost ?? STDIN_MOST;
    this.#child = spawn(command, given, { stdio: ["pipe", "pipe", "pipe"], windowsHide: true });
    if (this.#child.pid !== undefined) MbProcess.#live.set(this, { pid: this.#child.pid, args, background, startedAt: wall.now() });
    const said = new Said((answer) => this.emit("message", answer));
    this.#child.stdout!.on("data", (bytes: Buffer) => said.push(bytes));
    createInterface({ input: this.#child.stderr! }).on("line", (line) => log.warn("readers", "a MoonBit reader said", { line }));
    // (a failed write is the process gone, told by its exit)
    this.#child.stdin!.on("error", () => {});
    // All it was given read, with nothing written meanwhile: no longer behind (else the next time it is would be told
    // from where it stood before).
    this.#child.stdin!.on("drain", () => void (this.#behind = null));
    this.#child.on("error", (error) => {
      if (this.#child.pid === undefined) MbProcess.#live.delete(this);
      this.emit("error", error);
    });
    // Its end once its output is read whole (`close`: after `exit` and its streams' ends): what it said last, then that it
    // ended. On `exit` a line it wrote just before could still be on its way, its answer taken for none.
    this.#child.on("close", (code, signal) => {
      this.#exited = true;
      MbProcess.#live.delete(this);
      this.emit("exit", code ?? (signal !== null ? 1 : 0));
    });
  }

  /// (a bigint said as its digits)
  /// One that has left more than its `stdinMost` unread is ended (STDIN_MOST), what is posted after dropped.
  postMessage(message: unknown) {
    if (this.#stalled || this.#exited) return;
    this.postLine(JSON.stringify(message, (_, v) => typeof v === "bigint" ? v.toString() : v));
  }

  /// Write an already-serialized JSON line to stdin, sharing `postMessage`'s backpressure and `SIGKILL` guard.
  postLine(line: string) {
    if (this.#stalled || this.#exited) return;
    const stdin = this.#child.stdin!;
    stdin.write(`${line}\n`);
    this.#written += line.length + 1;
    const unread = stdin.writableLength;
    if (unread > STDIN_BEHIND && this.#behind === null) {
      this.#behind = { at: wall.now(), written: this.#written, unread };
      log.warn("readers", "a MoonBit program is behind what it is asked", { args: this.#args.slice(0, 6), pid: this.#child.pid ?? null, unreadBytes: unread });
    } else if (unread <= STDIN_BEHIND / 2) this.#behind = null;
    if (unread <= this.#stdinMost) return;
    this.#stalled = true;
    // Since it was found behind: how long, and what it read of what it was given (next to nothing, it stopped reading).
    const behind = this.#behind;
    const since = behind === null ? {} : { behindMs: wall.now() - behind.at, readBytes: this.#written - behind.written - (unread - behind.unread) };
    log.error("readers", "a MoonBit program stopped reading what it is asked; ending it", { args: this.#args.slice(0, 6), pid: this.#child.pid ?? null, unreadBytes: unread, ...since });
    this.#child.kill("SIGKILL");
  }

  /// Whether the station's process waits on it to end: not for one that lives as long as what uses it, while that has
  /// nothing asked of it.
  ref(on: boolean) {
    if (on) this.#child.ref();
    else this.#child.unref();
    for (const stream of [this.#child.stdin, this.#child.stdout, this.#child.stderr]) {
      const s = stream as unknown as { ref?(): void; unref?(): void } | null;
      if (on) s?.ref?.();
      else s?.unref?.();
    }
  }

  /// Ends it now, not waiting for its end (the station's process is ending).
  kill() {
    if (!this.#exited) this.#child.kill("SIGKILL");
  }

  terminate(): Promise<number> {
    if (this.#exited) return Promise.resolve(this.#child.exitCode ?? 1);
    this.ref(true);
    return new Promise((resolve) => {
      this.#child.once("close", (code) => {
        this.ref(false);
        resolve(code ?? 1);
      });
      this.#child.kill();
    });
  }

  /// No JS heap: the memory log counts V8's; its resident memory is counted from MbProcess.live (ops/self-memory.ts).
  getHeapStatistics(): Promise<{ used_heap_size: number }> {
    return Promise.resolve({ used_heap_size: 0 });
  }
}

/// The reader, started on the station's data directory `data`.
export class MbReader extends MbProcess implements ReaderLike {
  constructor(binary: string, data: string) { super(binary, ["--data", data, "--sep", sep]); }
  override postMessage(ask: Ask) { super.postMessage(ask); }
}

/// What stands for a MoonBit backfill in the permit: never a thread's.
let nextOwner = 0x60000000;

/// A backfill the station drives itself, by the MoonBit builder `args`: each message asks for a batch, answered
/// `{done, error?}` (`threadId`: its owner in the permit, which its user releases on its exit). It knows nothing of the backfill permit,
/// which this takes for each batch and gives back when it is answered; a batch the permit is not had for, and one that
/// did not finish everything, are answered after a pause (`pauseMs`).
export class MbBackfill extends EventEmitter {
  readonly threadId = nextOwner++;
  readonly #process: MbProcess;
  readonly #priority: Int32Array | null;
  readonly #pauseMs: number;
  #holding = false;
  #exited = false;

  constructor(binary: string, args: string[], priority: SharedArrayBuffer | undefined, pauseMs: number) {
    super();
    this.#priority = priority instanceof SharedArrayBuffer ? new Int32Array(priority) : null;
    this.#pauseMs = pauseMs;
    // (a backfill is the station's own, nobody waiting on it: the system's background work, whatever its kind)
    this.#process = new MbProcess(binary, args, { background: true });
    this.#process.on("message", (result: { done: boolean; error?: string }) => {
      this.#give();
      if (!result.done && !result.error) this.#later(result);
      else this.emit("message", result);
    });
    this.#process.on("error", (error) => this.emit("error", error));
    this.#process.on("exit", (code) => {
      this.#give();
      this.#exited = true;
      this.emit("exit", code);
    });
  }

  #give() {
    if (this.#holding) { this.#holding = false; giveBackfill(this.#priority, this.threadId); }
  }

  #later(result: { done: boolean }) {
    wall.after(this.#pauseMs, () => { if (!this.#exited) this.emit("message", result); });
  }

  postMessage(message: unknown) {
    if (!takeBackfill(this.#priority, this.threadId)) return void this.#later({ done: false });
    this.#holding = true;
    this.#process.postMessage(message);
  }

  /// (a process keeps the station's event loop no more than the backfill it is)
  unref() {}

  terminate(): Promise<number> { return this.#process.terminate(); }
}
