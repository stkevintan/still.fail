// Where the export's work runs: a process of its own as the station runs (the MoonBit program, station/mb's
// src/replica), so none of its reads, hashing, compressing or writing is on the main thread; the TypeScript it is held
// to line by line in the test's thread in tests (test/reference/replica-work.ts `InlineRunner`).
import { sep } from "node:path";
import { wall } from "../ops/fibers.ts";
import { MbProcess, resolveReaderSelection, resolveReaderSelectionAsync, resolveReaderSelectionOrPending } from "../read/mb-reader.ts";
import type { ReaderSelectConfig } from "../read/reader-select.ts";
import type { Passed, Places, Told } from "./export.ts";

/// A pass, and whether the station has no chat of its own (a copy is taken back only into such a one).
export type WorkPassed = Passed & { empty: boolean };

export type Asked =
  | { type: "places"; places: Places }
  | { type: "pass"; told: Told }
  | { type: "newGenerations"; after: number }
  | { type: "sources"; hashes: string[] }
  | { type: "close" };

export interface Runner {
  places(places: Places): Promise<void>;
  pass(told: Told): Promise<WorkPassed>;
  newGenerations(after: number): Promise<void>;
  sources(hashes: string[]): Promise<Record<string, string>>;
  close(): Promise<void>;
}

export type RunnerOptions = {
  db: string;
  replica: string;
  dataDir: string;
  origin: string;
  chunkBytes?: number;
  transcriptPassFiles?: number;
  transcriptPassBytes?: number;
  transcriptPassDeletes?: number;
  chunkGcGraceMs?: number;
  readers?: ReaderSelectConfig | (() => ReaderSelectConfig);
};

/// What the work runs in: the MoonBit program's process, or a test's own, asked and answering a message each,
/// `{id, answer}` or `{id, error}`.
type Thread = {
  on(event: "message", f: (m: { id: number; answer?: unknown; error?: string }) => void): unknown;
  on(event: "error", f: (e: Error) => void): unknown;
  on(event: "exit", f: (code: number) => void): unknown;
  postMessage(m: unknown): void;
  kill?(): void;
  terminate?(): Promise<number>;
};

/// The work in the MoonBit/Pion program (`--builder replica-export`).
export function exportThread(o: RunnerOptions, binary?: string): Thread {
  const args = ["--builder", "replica-export", "--db", o.db, "--replica", o.replica, "--data-dir", o.dataDir, "--origin", o.origin, "--sep", sep, "--compact-heads"];
  if (o.chunkBytes !== undefined) args.push("--chunk-bytes", String(o.chunkBytes));
  if (o.transcriptPassFiles !== undefined) args.push("--transcript-pass-files", String(o.transcriptPassFiles));
  if (o.transcriptPassBytes !== undefined) args.push("--transcript-pass-bytes", String(o.transcriptPassBytes));
  if (o.transcriptPassDeletes !== undefined) args.push("--transcript-pass-deletes", String(o.transcriptPassDeletes));
  if (o.chunkGcGraceMs !== undefined) args.push("--chunk-gc-grace-ms", String(o.chunkGcGraceMs));
  const bin = binary ?? resolveReaderSelection("replica-export", { config: o.readers, logAt: "replica" }).primaryBinary;
  return new MbProcess(bin, args);
}

/// The work in a process of its own, started again (told the workspaces again) at the next thing asked once
/// it ended: what asked meanwhile failed, and its caller tries again with a backoff (copies.ts `#pass`). Each ask says
/// the time (`now`): the program's clock is the station's.
export class ProgramRunner implements Runner {
  readonly #o: RunnerOptions;
  readonly #start: (o: RunnerOptions, binary?: string) => Thread;
  readonly #isDefaultStart: boolean;
  readonly #closeGraceMs: number;
  #worker: Thread | null = null;
  #starting: Promise<Thread> | null = null;
  #closing: Thread | null = null;
  readonly #waiting = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void }>();
  #next = 0;
  #places: Places | null = null;
  #closed = false;

  constructor(o: RunnerOptions, start: (o: RunnerOptions) => Thread = exportThread, closeGraceMs = 2_000) {
    this.#o = o;
    this.#start = start;
    this.#isDefaultStart = start === exportThread;
    this.#closeGraceMs = closeGraceMs;
  }

  #begin(binary?: string): Thread {
    if (this.#worker !== null) return this.#worker;
    const worker = this.#isDefaultStart ? exportThread(this.#o, binary) : this.#start(this.#o);
    worker.on("message", (m: { id: number; answer?: unknown; error?: string }) => {
      const w = this.#waiting.get(m.id);
      this.#waiting.delete(m.id);
      if (m.error !== undefined) w?.reject(new Error(m.error));
      else w?.resolve(m.answer);
    });
    const fail = (e: Error) => {
      if (this.#worker !== worker && this.#closing !== worker) return;
      if (this.#worker === worker) this.#worker = null;
      if (this.#closing === worker) this.#closing = null;
      for (const w of this.#waiting.values()) w.reject(e);
      this.#waiting.clear();
    };
    worker.on("error", (e) => fail(new Error(`the copies' thread failed: ${e.message}`)));
    worker.on("exit", (code) => fail(new Error(`the copies' thread ended (${code})`)));
    this.#worker = worker;
    if (this.#places !== null) worker.postMessage({ type: "places", places: this.#places, id: ++this.#next, now: wall.now() });
    return worker;
  }

  #sendAsk<T>(worker: Thread, m: Asked): Promise<T> {
    if (this.#closed) return Promise.reject(new Error("the copies' thread is closed"));
    const id = ++this.#next;
    return new Promise<T>((resolve, reject) => {
      this.#waiting.set(id, { resolve, reject });
      worker.postMessage({ ...m, id, now: wall.now() });
    });
  }

  #ask<T>(m: Asked): Promise<T> {
    if (this.#closed) return Promise.reject(new Error("the copies' thread is closed"));
    if (this.#worker !== null) return this.#sendAsk(this.#worker, m);
    if (!this.#isDefaultStart) return this.#sendAsk(this.#begin(), m);
    if (this.#starting === null) {
      let sync;
      try {
        sync = resolveReaderSelectionOrPending("replica-export", { config: this.#o.readers, logAt: "replica" });
      } catch (e) {
        return Promise.reject(e);
      }
      if (!sync.pending) {
        return this.#sendAsk(this.#begin(sync.primaryBinary), m);
      }
      const pending = resolveReaderSelectionAsync("replica-export", { config: this.#o.readers, logAt: "replica" }).then(
        (resolved) => {
          if (this.#closed) throw new Error("the copies' thread is closed");
          return this.#begin(resolved.primaryBinary);
        },
      ).finally(() => {
        if (this.#starting === pending) this.#starting = null;
      });
      this.#starting = pending;
    }
    return this.#starting.then((worker) => this.#sendAsk(worker, m));
  }

  places(places: Places) {
    this.#places = places;
    return this.#ask<void>({ type: "places", places });
  }
  pass(told: Told) {
    return this.#ask<WorkPassed>({ type: "pass", told });
  }
  newGenerations(after: number) {
    return this.#ask<void>({ type: "newGenerations", after });
  }
  sources(hashes: string[]) {
    return this.#ask<Record<string, string>>({ type: "sources", hashes });
  }
  async close() {
    this.#closed = true;
    const worker = this.#worker;
    this.#worker = null;
    if (worker === null) return;
    this.#closing = worker;
    const id = ++this.#next;
    const ack = new Promise<void>((resolve, reject) => {
      this.#waiting.set(id, { resolve, reject });
      try {
        worker.postMessage({ type: "close", id, now: wall.now() });
      } catch (e) {
        this.#waiting.delete(id);
        reject(e as Error);
      }
    });
    let stop = () => {};
    const timedOut = Symbol("timeout");
    const timer = new Promise<typeof timedOut>((resolve) => {
      stop = wall.after(this.#closeGraceMs, () => resolve(timedOut)); // timer: a timeout waiting for the export process to close
    });
    try {
      const res = await Promise.race([ack.catch(() => timedOut), timer]);
      if (res === timedOut && this.#closing === worker) {
        worker.kill?.();
      }
    } finally {
      stop();
      if (this.#closing === worker) this.#closing = null;
      const err = new Error("the copies' thread is closed");
      for (const w of this.#waiting.values()) w.reject(err);
      this.#waiting.clear();
    }
  }
}
