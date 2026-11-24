// The station's watch over its own memory: this Node process and the MoonBit programs it runs (read/mb-reader.ts
// MbProcess.live: the readers, the serving programs, the builders), which the watch over the agents' processes leaves
// out (jobs/memory.ts: the station and the runners are never units). Sampled every SAMPLE_MS (a sample of this machine).
//
// - Soft: the machine under pressure (high, critical), or the station's whole (Node's resident memory and its programs')
//   past softLimitOf: what answers nothing is let go at once (Readers.trimIdle), at most once a RELIEF_MS. Nothing that
//   answers is stopped. Under the machine's pressure alone, every idle session's process goes too (`evictWarm`, hub.ts
//   `evictAllIdle`): gigabytes where the readers are megabytes (2026-11-15: nine idle ones held 5.3 GiB of a station
//   whose machine had 2 GiB left). The station past its own soft limit leaves them: they are not its memory, and a
//   machine with room to spare keeps its warm sessions.
// - Hard: the station's whole past hardRssOf, or Node's heap past HEAP_MOST, in SUSTAINED samples in a row (a leak, not
//   a transfer's or a pack's moment), STARTUP_MS after it started: its launcher asked to hand over (ops/restart.ts
//   `restarter`), as an update does, once, the next process taking the sessions up. The whole, not Node's own: Node
//   keeps some 200 MB since the sessions, the serving and the readers went to the programs (`--sessions`, `--serve`,
//   the readers, the builders), and a handover ends every program of the Node that hands over, the next starting its
//   own, so what one of them leaked is given back too. What is only idle never gets there: its first sample past the
//   hard limit is past the soft one too (softLimitOf is under hardRssOf), which lets it go, and the next is under.
//   Never an exit: where there is no launcher (a checkout, a test) it is only said, and what is idle let go.
// - The front (the MoonBit program the launcher keeps the station's iroh endpoint in, native/launcher/src/front.rs) is
//   counted apart: a Node's handover leaves it running, so it is never in the whole a handover is asked for (one that
//   leaked would have Node handed over every STARTUP_MS for nothing). It counts towards the soft limit (the machine's
//   room is one), and held past hardFrontOf for SUSTAINED samples it is said, and `restartFront` asked where given.
import type { Clock } from "effect";
import type { Pressure } from "../jobs/admit.ts";
import { Fibers } from "./fibers.ts";
import { log } from "./log.ts";

const MiB = 1024 ** 2;
const GiB = 1024 ** 3;
export const SAMPLE_MS = 30_000;
export const RELIEF_MS = 60_000;
export const SUSTAINED = 3;
export const STARTUP_MS = 10 * 60_000;
export const HEAP_MOST = 2.5 * GiB;

const clamp = (n: number, low: number, high: number) => Math.min(high, Math.max(low, n));
/// The station's whole past which what is idle is let go: a fifth of the machine's memory, 2 to 6 GiB.
export const softLimitOf = (totalBytes: number): number => clamp(Math.floor(totalBytes * 0.2), 2 * GiB, 6 * GiB);
/// The station's whole (Node's resident memory and its programs') past which, held, it is handed over: 30% of the machine's, 3 to 8 GiB.
export const hardRssOf = (totalBytes: number): number => clamp(Math.floor(totalBytes * 0.3), 3 * GiB, 8 * GiB);
/// The front's resident memory past which, held, it is said (and started again where that is given): a tenth of the
/// machine's, 1 to 3 GiB.
export const hardFrontOf = (totalBytes: number): number => clamp(Math.floor(totalBytes * 0.1), 1 * GiB, 3 * GiB);

export type NodeMemory = { rss: number; heapUsed: number; external: number; arrayBuffers: number };

export type SelfMemoryOptions = {
  clock?: Clock.Clock;
  /// The machine's memory; read at every sample where given as a function, as a VM's grows when memory is plugged in
  /// (a station VM sharing its pool with apps boots with part of it: limits made from that alone stay too low).
  totalBytes: number | (() => number);
  /// When this process started, on the clock.
  startedAt: number;
  /// Node's own (process.memoryUsage).
  memory(): NodeMemory;
  /// The resident bytes of the programs it runs, and how many there are.
  children(): Promise<{ bytes: number; count: number }>;
  /// The front's resident bytes (asked after `children`, each sample); null where none runs or it is not known.
  front?(): Promise<number | null>;
  /// Asks for the front to be started again; where not given, a front held past its limit is only said.
  restartFront?(): Promise<void>;
  pressure(): Promise<Pressure | null>;
  /// Lets go what answers nothing; how many were.
  trimIdle(): number | Promise<number>;
  /// Lets every idle session's process go, the machine under pressure (high, critical); how many were asked to end.
  evictWarm?(): number | Promise<number>;
  /// How to ask the launcher to hand over (ops/restart.ts `restarter`); null where there is none.
  handover(): Promise<(() => Promise<void>) | null>;
  sampleMs?: number;
  softBytes?: number;
  hardRssBytes?: number;
  hardHeapBytes?: number;
  hardFrontBytes?: number;
  sustained?: number;
  startupMs?: number;
  reliefMs?: number;
};

/// What a sample did: how many were let go (null: nothing was asked), how many idle sessions' processes were asked to end
/// (`evictedWarm`, null: none was asked), and whether the launcher was asked to hand over (`asked`), there was none to
/// ask (`none`), or neither; and whether the front, held past its limit, was asked to start again (`asked`), only said
/// (`said`), or neither.
export type SelfVerdict = {
  trimmed: number | null;
  evictedWarm: number | null;
  handover: "asked" | "none" | null;
  front: "asked" | "said" | null;
};

export class SelfMemoryGovernor {
  readonly #o: SelfMemoryOptions;
  readonly #fibers: Fibers;
  #soft = 0;
  #hardRss = 0;
  readonly #hardHeap: number;
  #hardFront = 0;
  /// The machine's memory the limits above were made from.
  #total = -1;
  #lastRelief: number | null = null;
  /// Samples in a row with the station's whole or Node's heap past its hard limit.
  #over = 0;
  /// Samples in a row with the front past its own.
  #frontOver = 0;
  #handedOver = false;
  #stop: (() => void) | null = null;

  constructor(o: SelfMemoryOptions) {
    this.#o = o;
    this.#fibers = new Fibers("memory", o.clock);
    this.#hardHeap = o.hardHeapBytes ?? HEAP_MOST;
    this.#limits();
  }

  /// The limits from the machine's memory as it is now (those given stay as given).
  #limits() {
    const total = typeof this.#o.totalBytes === "function" ? this.#o.totalBytes() : this.#o.totalBytes;
    if (total === this.#total) return;
    this.#total = total;
    this.#soft = this.#o.softBytes ?? softLimitOf(total);
    this.#hardRss = this.#o.hardRssBytes ?? hardRssOf(total);
    this.#hardFront = this.#o.hardFrontBytes ?? hardFrontOf(total);
  }

  start(): void {
    this.#stop ??= this.#fibers.every(this.#o.sampleMs ?? SAMPLE_MS, () => this.sample()); // timer: a sample of this machine (the station's own memory)
  }

  async sample(): Promise<SelfVerdict> {
    this.#limits();
    const now = this.#fibers.now();
    const node = this.#o.memory();
    const children = await this.#o.children();
    const front = this.#o.front ? await this.#o.front() : null;
    const pressure = await this.#o.pressure();
    // (what a handover gives back: Node and its programs; the front is not)
    const whole = node.rss + children.bytes;
    const fields = {
      nodeRssMb: Math.round(node.rss / MiB), heapUsedMb: Math.round(node.heapUsed / MiB), externalMb: Math.round(node.external / MiB),
      arrayBuffersMb: Math.round(node.arrayBuffers / MiB), mbChildrenRssMb: Math.round(children.bytes / MiB), mbCount: children.count,
      wholeRssMb: Math.round(whole / MiB), ...(front !== null ? { frontRssMb: Math.round(front / MiB) } : {}), pressure,
    };
    const verdict: SelfVerdict = { trimmed: null, evictedWarm: null, handover: null, front: null };
    const pressed = pressure === "high" || pressure === "critical";
    if ((pressed || whole + (front ?? 0) > this.#soft) && (this.#lastRelief === null || now - this.#lastRelief >= (this.#o.reliefMs ?? RELIEF_MS))) {
      this.#lastRelief = now;
      verdict.trimmed = await this.#o.trimIdle();
      if (pressed && this.#o.evictWarm) verdict.evictedWarm = await this.#o.evictWarm();
      log.info("memory", "station trimmed idle helpers under memory pressure", { ...fields, softMb: Math.round(this.#soft / MiB), trimmed: verdict.trimmed, evictedWarm: verdict.evictedWarm });
    }
    const sustained = this.#o.sustained ?? SUSTAINED;
    const started = now - this.#o.startedAt >= (this.#o.startupMs ?? STARTUP_MS);
    this.#frontOver = front !== null && front > this.#hardFront ? this.#frontOver + 1 : 0;
    if (this.#frontOver >= sustained && started) {
      // (counted again from here: said, and asked again, once a SUSTAINED samples while it lasts)
      this.#frontOver = 0;
      log.warn("memory", "mesh front exceeded sustained memory limit", { ...fields, hardFrontMb: Math.round(this.#hardFront / MiB) });
      verdict.front = "said";
      if (this.#o.restartFront) {
        await this.#o.restartFront().catch((e) => log.warn("memory", "asking for the front to start again failed", { error: (e as Error).message }));
        verdict.front = "asked";
      }
    }
    this.#over = whole > this.#hardRss || node.heapUsed > this.#hardHeap ? this.#over + 1 : 0;
    if (this.#handedOver || this.#over < sustained || !started) return verdict;
    // (counted again from here: where there is no launcher, said once a SUSTAINED samples while it lasts)
    this.#over = 0;
    const limits = { hardRssMb: Math.round(this.#hardRss / MiB), hardHeapMb: Math.round(this.#hardHeap / MiB) };
    const ask = await this.#o.handover().catch(() => null);
    if (ask === null) {
      log.warn("memory", "station process exceeded sustained memory limit; no launcher to hand over to, trimming idle helpers", { ...fields, ...limits });
      verdict.trimmed = await this.#o.trimIdle();
      verdict.handover = "none";
      return verdict;
    }
    this.#handedOver = true;
    log.warn("memory", "station process exceeded sustained memory limit; asking launcher to hand over", { ...fields, ...limits });
    await ask().catch((e) => {
      // (asked again once it is held SUSTAINED samples more)
      this.#handedOver = false;
      log.warn("memory", "asking the launcher to hand over failed", { error: (e as Error).message });
    });
    verdict.handover = "asked";
    return verdict;
  }

  async close(): Promise<void> {
    this.#stop = null;
    await this.#fibers.close();
  }
}
