// What the agents spent, counted (the Rust station's usage.rs `Usage`): every model call their runtimes write to a transcript
// (Claude Code's message usage, Codex's token counts) is recorded once in the store (store/usage.ts), with the turn it
// was in and whom that turn worked for, and how long it took where the transcript tells it (mb/src/usagecount speed.mbt).
// The transcripts are read as they grow, from where the last read stopped: all of them as sessions run, from the
// counter's installation onward; older transcripts are not backfilled, but for the time the calls of the last
// TIMED_BACK_MS read before it was kept took, read once as the counter starts.
//
// Pushed rather than polled (the Rust reads every minute): a read when the counter starts, one shortly after a turn
// ends (the store's session changes say so), one of a session alone shortly after its transcript grew while it works
// (the live view says so: what a chat shows it spent goes on with each call), and a slow safety read for anything
// missed. Reads never overlap. The reading itself is the MoonBit program's (counter-mb.ts, reader `--builder
// usage-counter`, mb/src/usagecount): the transcripts read, their lines parsed and their calls written to the database
// there, none of it on the station's thread; here only when to read and what it told. The program is built for every
// system a station runs on, so there is no counter in TypeScript to fall back to (test/usage-counter-reference.ts is
// the one it is compared with). What is recorded is the one count of what was spent: a chat's usage and the usage page
// are both added up from it. The prices (what a call costs) are the usage page's: src/read/usage.ts.
import { Clock, Effect, Fiber, Queue } from "effect";
import { liveClock } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { allTranscriptHints, takeTranscriptHints } from "../read/transcript.ts";
import { mbReaderBinary, pionBinary } from "../read/mb-reader.ts";
import { type ReaderSelectConfig, resolveReaderEngine } from "../read/reader-select.ts";
import { MbCounterStopped, MbUsageCounter } from "./counter-mb.ts";
import type { Store } from "../store/store.ts";

/// How long after a turn ends, or a session at work wrote more, its transcript is read (its last lines written, other
/// turns ending with it, a burst of writes gathered).
export const SETTLE_MS = 2_000;
/// How often everything that ran is read anyway, for what no turn's end told.
export const SAFETY_MS = 10 * 60_000;
/// How far back the calls read before their time was kept are timed as the counter starts (mb/src/usagecount
/// speed.mbt): Profile overview's 输出速度 a week back, each point the day before it.
export const TIMED_BACK_MS = 8 * 24 * 3_600_000;

/// What the counter reads of the station's config: where its data is, and each profile's home (absolute).
export type UsageConfig = { dataDir: string; profiles: readonly { home: string }[] };

export type UsageCounterOptions = {
  store: Store;
  /// Read at every read, so profiles added since are read too.
  config: () => UsageConfig;
  settleMs?: number;
  safetyMs?: number;
  /// Its time (a TestClock in tests).
  clock?: Clock.Clock;
  /// The MoonBit program that reads (counter-mb.ts): by default the station's (mbReaderBinary), on the store's file
  /// (`dbPath`).
  mb?: string | null;
  dbPath?: string | null;
  /// Live `config.json` `readers` snapshot or getter for `usage-counter` engine selection.
  readers?: ReaderSelectConfig | (() => ReaderSelectConfig);
  /// The program's idle timer (a test's own; else the wall's).
  after?: (ms: number, f: () => void) => () => void;
};

export class UsageCounter {
  readonly #store: Store;
  readonly #config: () => UsageConfig;
  readonly #settleMs: number;
  readonly #safetyMs: number;
  /// When the last read started; 0 before the first.
  #last = 0;
  /// The first sweep is under way.
  #first = false;
  /// The read under way (reads queue behind it).
  #reading: Promise<unknown> = Promise.resolve();
  /// Sessions that changed since the loop last looked, and when each one's latest turn had ended when it last did.
  #changed = new Set<string>();
  #ended = new Map<string, number>();
  #startedAt = 0;
  #wake = Effect.runSync(Queue.dropping<void>(1));
  /// Sessions at work whose transcripts grew, to be read alone though no turn ended (`soon`).
  #asked = new Set<string>();
  #fiber: Fiber.Fiber<void> | null = null;
  #unsubscribe: (() => void) | null = null;
  #clock: Clock.Clock;
  /// Explicit binary override if provided (`null` explicitly disables; `undefined` uses `resolveReaderSelection`).
  readonly #explicit: string | null | undefined;
  /// The program that reads.
  readonly #mb: MbUsageCounter;

  /// Throws where there is no program to read with: a store in memory (the program writes the store's file), or a
  /// checkout that did not build it.
  constructor(options: UsageCounterOptions) {
    this.#store = options.store;
    this.#config = options.config;
    this.#settleMs = options.settleMs ?? SETTLE_MS;
    this.#safetyMs = options.safetyMs ?? SAFETY_MS;
    this.#clock = options.clock ?? liveClock;
    this.#explicit = options.mb;
    const location = options.dbPath !== undefined ? options.dbPath : (this.#store.db.location() ?? null);
    if (location === null || location === "" || location === ":memory:") throw new Error("the usage counter reads into a store in a file (its program writes there), not one in memory");
    if (this.#explicit === null) throw new Error("the usage counter needs the MoonBit reader (station/mb/build.sh), which this station was not built with");
    if (this.#explicit === undefined) {
      const cfg = typeof options.readers === "function" ? options.readers() : options.readers;
      const intent = resolveReaderEngine("usage-counter", { config: cfg, hasPionBinary: true });
      const hasPion = intent.engine === "pion" && pionBinary() !== null;
      if (!hasPion && mbReaderBinary() === null) {
        throw new Error("the usage counter needs the MoonBit reader (station/mb/build.sh), which this station was not built with");
      }
    }
    this.#mb = new MbUsageCounter(this.#explicit, location, { after: options.after, readers: options.readers });
  }

  /// The program let go if nothing is asked of it (read/pool.ts `onTrim`): 1, else 0.
  trimIdle(): number { return this.#mb.trimIdle(); }

  /// Reads sessions that ran since the previous sweep, then those whose turn ended (shortly after), and all that ran
  /// every SAFETY_MS. Stopped by `stop`.
  start(): void {
    if (this.#fiber !== null) return;
    this.#startedAt = this.#clock.currentTimeMillisUnsafe();
    this.#unsubscribe = this.#store.subscribe((change) => {
      // (a session deleted: nothing of it kept, so one of its key made again is counted as new)
      if (change.type === "sessionRemoved") {
        this.#ended.delete(change.key);
        this.#changed.delete(change.key);
        this.#asked.delete(change.key);
        return;
      }
      if (change.type !== "session") return;
      this.#changed.add(change.key);
      Queue.offerUnsafe(this.#wake, undefined);
    });
    const me = this;
    const readNow = Effect.promise(() => me.#readLogged());
    // Whether a turn ended since the loop last looked, of the sessions that changed.
    const turnEnded = Effect.sync(() => {
      let ended = false;
      for (const key of me.#changed) {
        const at = me.#store.lastTurn(key)?.endedAt ?? null;
        if (at !== null && at > (me.#ended.get(key) ?? me.#startedAt)) {
          me.#ended.set(key, at);
          ended = true;
        }
      }
      me.#changed.clear();
      return ended;
    });
    // The sessions asked of alone.
    const readAsked = Effect.promise(() => {
      const only = new Set(me.#asked);
      me.#asked.clear();
      return me.#readLogged(only);
    });
    // (as it starts: what was read before calls were timed, of the sessions that ran the last TIMED_BACK_MS, timed too:
    // the counter finds those sessions itself, off the main thread, and reads on each transcript from where it is)
    const timeBack = Effect.promise(async () => {
      const from = me.#clock.currentTimeMillisUnsafe() - TIMED_BACK_MS;
      await me.#readLogged(undefined, from);
    });
    const loop = Effect.gen(function* () {
      yield* timeBack;
      let due = (yield* Clock.currentTimeMillis) + me.#safetyMs;
      while (true) {
        const woken = yield* Effect.raceFirst(
          Queue.take(me.#wake).pipe(Effect.as(true)),
          Clock.currentTimeMillis.pipe(Effect.flatMap((now) => Effect.sleep(Math.max(1, due - now))), Effect.as(false)),
        );
        if (woken) {
          yield* Effect.sleep(me.#settleMs);
          yield* Queue.clear(me.#wake);
          if (!(yield* turnEnded) && (yield* Clock.currentTimeMillis) < due) {
            if (me.#asked.size > 0) yield* readAsked;
            continue;
          }
        }
        // Those at work are among those read.
        me.#asked.clear();
        yield* readNow;
        due = (yield* Clock.currentTimeMillis) + me.#safetyMs;
      }
    });
    this.#fiber = Effect.runFork(loop.pipe(Effect.provideService(Clock.Clock, this.#clock)));
  }

  /// Reads `key`'s transcripts shortly, though no turn ended: a session at work wrote more (live.ts).
  soon(key: string): void {
    this.#asked.add(key);
    Queue.offerUnsafe(this.#wake, undefined);
  }

  /// Stops reading: the program ends, the read under way with it (what it recorded stays).
  async stop(): Promise<void> {
    this.#unsubscribe?.();
    this.#unsubscribe = null;
    if (this.#fiber !== null) await Effect.runPromise(Fiber.interrupt(this.#fiber));
    this.#fiber = null;
    await this.#mb.close();
    await this.#reading.catch(() => {});
  }

  /// reading_all: whether everything is still being read for the first time.
  readingAll(): boolean {
    return this.#first || this.#last === 0;
  }

  async #readLogged(only?: ReadonlySet<string>, timeFrom?: number): Promise<void> {
    try {
      await this.read(only, timeFrom);
    } catch (e) {
      if (!(e instanceof MbCounterStopped)) log.warn("usage", "usage not read", { error: (e as Error).message });
    }
  }

  /// One read: the transcripts of sessions that ran since the last sweep; `only`: of those sessions alone (it says
  /// nothing of when the last sweep was). How many calls were new. Reads queue behind one another. `timeFrom`: what a
  /// transcript had been read of before its calls were timed is read again, its calls from then on (ms) timed.
  read(only?: ReadonlySet<string>, timeFrom?: number): Promise<number> {
    const next = this.#reading.catch(() => {}).then(() => this.#read(only ?? null, timeFrom ?? null));
    this.#reading = next;
    return next;
  }

  /// A read by the program: what it found written there, told here.
  async #read(only: ReadonlySet<string> | null, timeFrom: number | null): Promise<number> {
    const started = this.#clock.currentTimeMillisUnsafe();
    const last = this.#last;
    if (only === null) this.#first = last === 0;
    const config = this.#config();
    const answer = await this.#mb.read({
      only: only === null ? null : [...only], started, last, dataDir: config.dataDir, homes: config.profiles.map((p) => p.home),
      hints: allTranscriptHints(), ...(timeFrom === null ? {} : { timeFrom }),
    });
    takeTranscriptHints(answer.hints);
    if (only === null) {
      this.#last = started;
      this.#first = false;
    }
    if (answer.sessions.length > 0) {
      if (last === 0 && only === null) log.info("usage", "usage read from recent transcripts", { calls: answer.added, ms: this.#clock.currentTimeMillisUnsafe() - started });
      this.#store.usageChanged(answer.sessions, answer.from ?? undefined);
    }
    return answer.added;
  }
}
