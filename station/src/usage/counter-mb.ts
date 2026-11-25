// The usage counter's reads in the MoonBit program (station/mb src/usagecount, reader `--builder usage-counter`), in
// place of counter.ts's own where the program is there and the store is a file: the transcripts read, their lines
// parsed and their calls written to the database there, none of it on the station's thread. Started at its first read,
// it goes after IDLE_MS with nothing asked of it (or at once: `trimIdle`) and is started again by the next: what it keeps
// between reads (where each transcript was read to) the database keeps too.
import { sep } from "node:path";
import { wall } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { MbProcess, resolveReaderSelectionAsync, resolveReaderSelectionOrPending } from "../read/mb-reader.ts";
import type { ReaderSelectConfig } from "../read/reader-select.ts";
import type { TranscriptLocationHints } from "../read/transcript.ts";

/// How long a program with nothing asked of it is kept.
export const IDLE_MS = 60_000;

/// A read asked of the program (mb/src/usagecount `Counter::read`): of `only`'s sessions, or (null) of those that ran
/// since the last sweep (`last`, 0 before the first), begun at `started`.
export type MbRead = {
  only: string[] | null; started: number; last: number; dataDir: string; homes: string[]; hints: TranscriptLocationHints;
  /// What a transcript had been read of before its calls were timed is read again, its calls from then on timed
  /// (counter.ts TIMED_BACK_MS, as it starts).
  timeFrom?: number;
};
/// What it answers: how many calls were new, of which sessions, the earliest made when, and the hints as it left them.
export type MbReadAnswer = { added: number; sessions: string[]; from: number | null; hints: TranscriptLocationHints };

type Waiting = { resolve: (answer: MbReadAnswer) => void; reject: (error: Error) => void };

/// The stop of a read under way: the program ended (`close`, a trim cannot end one under way).
export class MbCounterStopped extends Error {}

export class MbUsageCounter {
  readonly #binary: string | undefined;
  readonly #db: string;
  readonly #after: (ms: number, f: () => void) => () => void;
  readonly #readers: ReaderSelectConfig | (() => ReaderSelectConfig) | undefined;
  #process: MbProcess | null = null;
  #starting: Promise<MbProcess> | null = null;
  #termination: Promise<number> | null = null;
  #next = 0;
  #waiting = new Map<number, Waiting>();
  #idle: (() => void) | null = null;
  #closed = false;
  /// How many processes it started (tests: one started again after a trim).
  started = 0;

  /// `after`: the timer of IDLE_MS (a test's own; else the wall's).
  constructor(
    binary: string | undefined,
    db: string,
    options: { after?: (ms: number, f: () => void) => () => void; readers?: ReaderSelectConfig | (() => ReaderSelectConfig) } = {},
  ) {
    this.#binary = binary;
    this.#db = db;
    this.#after = options.after ?? wall.after;
    this.#readers = options.readers;
  }

  /// Whether a program runs now.
  get running(): boolean { return this.#process !== null; }

  read(ask: MbRead): Promise<MbReadAnswer> {
    if (this.#closed) return Promise.reject(new MbCounterStopped("station stopping"));
    return new Promise((resolve, reject) => {
      const id = ++this.#next;
      this.#waiting.set(id, { resolve, reject });
      this.#idle?.();
      this.#idle = null;
      const send = (proc: MbProcess) => {
        if (this.#closed) {
          this.#waiting.delete(id);
          reject(new MbCounterStopped("station stopping"));
          return;
        }
        try {
          proc.postMessage({ id, op: "read", ...ask });
        } catch (error) {
          this.#waiting.delete(id);
          reject(error as Error);
        }
      };
      if (this.#process !== null) {
        send(this.#process);
        return;
      }
      if (this.#starting !== null) {
        this.#starting.then(send, (error) => {
          this.#waiting.delete(id);
          reject(error as Error);
        });
        return;
      }
      if (this.#binary !== undefined) {
        try {
          send(this.#startWith(this.#binary));
        } catch (error) {
          this.#waiting.delete(id);
          reject(error as Error);
        }
        return;
      }
      let syncSel;
      try {
        syncSel = resolveReaderSelectionOrPending("usage-counter", { config: this.#readers, logAt: "usage" });
      } catch (error) {
        this.#waiting.delete(id);
        reject(error as Error);
        return;
      }
      if (!syncSel.pending) {
        try {
          send(this.#startWith(syncSel.primaryBinary));
        } catch (error) {
          this.#waiting.delete(id);
          reject(error as Error);
        }
        return;
      }
      const pending = resolveReaderSelectionAsync("usage-counter", { config: this.#readers, logAt: "usage" }).then(
        (resolved) => {
          if (this.#closed) throw new MbCounterStopped("station stopping");
          return this.#startWith(resolved.primaryBinary);
        },
      ).finally(() => {
        if (this.#starting === pending) this.#starting = null;
      });
      this.#starting = pending;
      pending.then(send, (error) => {
        this.#waiting.delete(id);
        reject(error as Error);
      });
    });
  }

  #startWith(binary: string): MbProcess {
    if (this.#process !== null) return this.#process;
    const child = new MbProcess(binary, ["--builder", "usage-counter", "--db", this.#db, "--sep", sep]);
    this.started++;
    this.#process = child;
    child.on("message", (answer: MbReadAnswer & { id?: number; error?: string }) => {
      if (answer.id === undefined) return;
      const waiting = this.#waiting.get(answer.id);
      if (!waiting) return;
      this.#waiting.delete(answer.id);
      if (answer.error !== undefined) waiting.reject(new Error(answer.error));
      else waiting.resolve(answer);
      this.#idleLater();
    });
    let failure: Error | null = null;
    child.on("error", (error: Error) => {
      failure = error;
      log.error("usage", "the usage counter's program stopped", { error: error.message });
    });
    child.on("exit", (code: number) => {
      if (this.#process !== child) return;
      this.#process = null;
      this.#idle?.();
      this.#idle = null;
      const error = this.#closed ? new MbCounterStopped("station stopping") : (failure ?? new Error(`the usage counter's program stopped (exit ${code})`));
      for (const waiting of this.#waiting.values()) waiting.reject(error);
      this.#waiting.clear();
    });
    return child;
  }

  /// Nothing asked of it: it goes after IDLE_MS unless asked again.
  #idleLater(): void {
    if (this.#closed || this.#process === null || this.#waiting.size > 0 || this.#idle !== null) return;
    // timer: a deadline (an idle program's process let go)
    this.#idle = this.#after(IDLE_MS, () => {
      this.#idle = null;
      if (this.#waiting.size === 0) this.#letGo();
    });
  }

  #letGo(): void {
    this.#idle?.();
    this.#idle = null;
    const child = this.#process;
    if (child === null) return;
    this.#process = null;
    this.#termination = child.terminate();
  }

  /// The program let go at once if nothing is asked of it: 1, else 0 (one under way goes IDLE_MS after it).
  trimIdle(): number {
    if (this.#closed || this.#process === null || this.#waiting.size > 0) return 0;
    this.#letGo();
    return 1;
  }

  /// Its end: a read under way is stopped there (what it recorded stays).
  async close(): Promise<void> {
    this.#closed = true;
    this.#idle?.();
    this.#idle = null;
    const child = this.#process;
    this.#process = null;
    for (const waiting of this.#waiting.values()) waiting.reject(new MbCounterStopped("station stopping"));
    this.#waiting.clear();
    if (child !== null) this.#termination = child.terminate();
    if (this.#termination !== null) await this.#termination;
  }
}
