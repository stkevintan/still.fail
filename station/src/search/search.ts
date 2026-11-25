// What the station finds for a search: looked for by the MoonBit program (station/mb, src/search; `--builder search`),
// built for every system the station runs on, in the station's data as it is then. A prepared candidate scope avoids
// unrelated chats; their contents are read as asked. The program is started by the first search and let go once none
// has been asked for IDLE_MS (or at once when the station is short of memory: `trimIdle`): kept from the station's
// start, it held 234 MB for hours nobody searched (2026-11-15). It keeps nothing a search needs between searches (each
// reads the database as it is then), so the next is answered by one started again; one that dies is started again
// too. The machine's files are asked beside it (search/files.ts). There is no search in TypeScript to fall back to: a
// test may give a reference to look instead (`reference`: the search as the station's thread looked before,
// test/reference/search-worker.ts).
import { rm } from "node:fs/promises";
import { join, sep } from "node:path";
import { log } from "../ops/log.ts";
import { wall } from "../ops/fibers.ts";
import { type Asker, type Group, terms } from "./match.ts";
import type { FileSearch } from "./files.ts";
/// What a looker is told, and what it answers.
export type Told = { type: "query"; id: number; query: string; asker: Asker; kinds?: string[]; limit?: number; offset?: number; archived?: boolean; cancel?: SharedArrayBuffer };
export type Answered = { id: number; groups?: Group[]; error?: string } | { scopePending: true } | { sessionListPending: true };
import { SearchScopeBuilder } from "./scope-builder.ts";
import { SessionListBuilder } from "../read/session-list-builder.ts";
import { type BackfillOptions, MbProcess, resolveReaderSelectionAsync, resolveReaderSelectionOrPending } from "../read/mb-reader.ts";
import type { ReaderSelectConfig } from "../read/reader-select.ts";

/// How long a search may take before it is answered with nothing.
const QUERY_MS = 30_000;
/// How long the program is kept with no search asked of it.
const IDLE_MS = 60_000;

/// `building`: always false (said to the clients that showed an index still being built).
export type Found = { groups: Group[]; building: boolean };

/// What looks: the program's process, or a test's reference (a thread, cancelled by the buffer it is given).
export interface Looker {
  on(event: "message", f: (answer: Answered) => void): this;
  on(event: "error", f: (error: Error) => void): this;
  on(event: "exit", f: (code: number) => void): this;
  postMessage(told: Told | { type: "cancel"; id: number }): void;
  terminate(): Promise<number>;
}

export class Search {
  #data: string;
  /// Test reference looker if provided; otherwise spawns `--builder search` via `resolveReaderSelection`.
  readonly #reference: ((data: string) => Looker) | undefined;
  readonly #readers: ReaderSelectConfig | (() => ReaderSelectConfig) | undefined;
  #looker: Looker | null = null;
  #spawning: Promise<Looker | null> | null = null;
  #next = 0;
  #waiting = new Map<number, { resolve: (found: Found) => void; reject: (error: Error) => void; timer: () => void }>();
  #closed = false;
  readonly #scope: SearchScopeBuilder;
  #preparingScope: Promise<void> | null = null;
  readonly #sessionList: SessionListBuilder;
  #preparingSessions: Promise<void> | null = null;
  /// The machine's files (none: not searched here).
  #files: FileSearch | null;
  /// The idle looker's going armed (IDLE_MS), called off by a search.
  #idle: (() => void) | null = null;
  readonly #after: (ms: number, f: () => void) => () => void;

  /// `after`: the timer of IDLE_MS (a test's own; else the wall's); `reference`: what looks in the program's place (a
  /// test's).
  constructor(options: { data: string; files?: FileSearch | null; backfill?: BackfillOptions; reference?: (data: string) => Looker; after?: (ms: number, f: () => void) => () => void }) {
    this.#data = options.data;
    this.#after = options.after ?? wall.after;
    this.#reference = options.reference;
    this.#readers = options.backfill?.readers;
    this.#files = options.files ?? null;
    this.#scope = new SearchScopeBuilder(join(options.data, "stillfail.db"), options.backfill);
    this.#sessionList = new SessionListBuilder(join(options.data, "stillfail.db"), options.backfill);
  }

  /// The removal of the index of before under way (`start`): waited for by `stop`.
  #starting: Promise<void> = Promise.resolve();

  /// The index an earlier station kept removed, off the main thread (nothing reads it: there is none now); done once
  /// the promise is. Nothing is started until a search is asked.
  start(): Promise<void> {
    return (this.#starting = Promise.all(["search.db", "search.db-wal", "search.db-shm"].map((f) => rm(join(this.#data, f), { force: true })))
      .then(() => {}, (error) => log.warn("search", "the index of before was not removed", { error: (error as Error).message })));
  }

  /// Whether a looker runs now (the program, or the test's reference).
  get running(): boolean { return this.#looker !== null; }

  /// The looker let go at once if no search is under way: 1, else 0 (the station short of memory: read/pool.ts
  /// `trimIdle`). The next search starts it again.
  trimIdle(): number {
    if (this.#closed || this.#waiting.size > 0 || this.#spawning !== null || !this.running) return 0;
    this.#letGo();
    return 1;
  }

  #letGo(): void {
    this.#idle?.();
    this.#idle = null;
    const looker = this.#looker;
    this.#looker = null;
    void looker?.terminate();
  }

  /// No search under way: the looker goes after IDLE_MS unless one is asked meanwhile.
  #idleLater(): void {
    if (this.#closed || this.#waiting.size > 0 || this.#idle !== null || !this.running) return;
    // timer: a deadline (an idle program's process let go)
    this.#idle = this.#after(IDLE_MS, () => {
      this.#idle = null;
      if (this.#waiting.size === 0) this.#letGo();
    });
  }

  #spawnWith(looker: Looker): Looker {
    this.#looker = looker;
    this.#listen(looker, () => { if (this.#looker === looker) this.#looker = null; });
    return looker;
  }

  #spawnLooker(binary: string): Looker | null {
    if (this.#closed) return null;
    if (this.#looker !== null) return this.#looker;
    const looker = new MbProcess(binary, ["--builder", "search", "--db", join(this.#data, "stillfail.db"), "--data", this.#data, "--sep", sep]);
    return this.#spawnWith(looker);
  }

  #looked(query: string, asker: Asker, options: { kinds?: string[]; limit?: number; offset?: number; archived?: boolean }): Promise<Found> {
    if (this.#closed) return Promise.reject(new Error("the search is stopped"));
    if (this.#looker !== null) return this.#ask(this.#looker, query, asker, options);
    if (this.#reference !== undefined) return this.#ask(this.#spawnWith(this.#reference(this.#data)), query, asker, options);
    if (this.#spawning === null) {
      let sync;
      try {
        sync = resolveReaderSelectionOrPending("search", { config: this.#readers, logAt: "search" });
      } catch (e) {
        return Promise.reject(e);
      }
      if (!sync.pending) {
        return this.#ask(this.#spawnLooker(sync.primaryBinary), query, asker, options);
      }
      const pending = resolveReaderSelectionAsync("search", { config: this.#readers, logAt: "search" }).then(
        (resolved) => this.#spawnLooker(resolved.primaryBinary),
      ).finally(() => {
        if (this.#spawning === pending) this.#spawning = null;
      });
      this.#spawning = pending;
    }
    return this.#spawning.then((looker) => this.#ask(looker, query, asker, options));
  }

  /// A looker's answers: each to the search it is for; its end ends the searches waiting on it.
  #listen(looker: Looker, gone: () => void): void {
    const mine = new Set<number>();
    looker.on("message", (answer: Answered) => {
      if ("scopePending" in answer) { if (!this.#closed) this.#prepareScope(); return; }
      if ("sessionListPending" in answer) { if (!this.#closed) this.#prepareSessions(); return; }
      mine.delete(answer.id);
      const waiter = this.#waiting.get(answer.id);
      if (!waiter) return;
      this.#waiting.delete(answer.id);
      waiter.timer();
      if (answer.error !== undefined) waiter.reject(new Error(answer.error));
      else waiter.resolve({ groups: answer.groups ?? [], building: false });
      this.#idleLater();
    });
    looker.on("error", (error: Error) => log.error("search", "the search's looker stopped", { error: error.message }));
    looker.on("exit", () => {
      gone();
      for (const [id, waiter] of this.#waiting) {
        if (!mine.has(id)) continue;
        waiter.timer();
        waiter.reject(new Error("the search stopped"));
        this.#waiting.delete(id);
      }
      this.#idleLater();
    });
    this.#asked.set(looker, mine);
  }

  readonly #asked = new WeakMap<Looker, Set<number>>();

  /// What `query` finds for `asker`: by kind, at most `limit` of each (those of `kinds` only, when given; the execution
  /// history only when asked for by name), the machine's files beside the rest.
  async query(query: string, asker: Asker, options: { kinds?: string[]; limit?: number; offset?: number; archived?: boolean } = {}): Promise<Found> {
    const files = this.#files;
    const wantsFiles = files !== null && (!options.kinds || options.kinds.length === 0 || options.kinds.includes("file")) && (options.offset ?? 0) === 0;
    const rest = options.kinds?.filter((k) => k !== "file");
    const [looked, found] = await Promise.all([
      options.kinds && options.kinds.length > 0 && rest!.length === 0 ? Promise.resolve({ groups: [], building: false }) : this.#looked(query, asker, options),
      wantsFiles ? files.query(terms(query), asker, Math.max(1, Math.min(options.limit ?? 8, 200))).catch(() => null) : Promise.resolve(null),
    ]);
    return found === null ? looked : { ...looked, groups: [...looked.groups, found] };
  }

  // Preparation is shared and never holds up the current search. A later query retries after a failure or change.
  #prepareScope(): void {
    if (this.#preparingScope !== null) return;
    const pending = this.#scope.prepare();
    this.#preparingScope = pending;
    void pending.catch((error: unknown) => {
      if (!this.#closed) log.warn("search", "the candidate scope could not be prepared", { error: (error as Error).message });
    }).finally(() => { if (this.#preparingScope === pending) this.#preparingScope = null; });
  }

  #prepareSessions(): void {
    if (this.#preparingSessions !== null) return;
    const pending = this.#sessionList.readySearch();
    this.#preparingSessions = pending;
    void pending.catch((error: unknown) => {
      if (!this.#closed) log.warn("search", "the session list could not be prepared", { error: (error as Error).message });
    }).finally(() => { if (this.#preparingSessions === pending) this.#preparingSessions = null; });
  }

  #ask(looker: Looker | null, query: string, asker: Asker, options: { kinds?: string[]; limit?: number; offset?: number; archived?: boolean }): Promise<Found> {
    if (!looker) return Promise.reject(new Error("the search is stopped"));
    this.#idle?.();
    this.#idle = null;
    const id = this.#next++;
    const program = looker instanceof MbProcess;
    const cancel = program ? undefined : new SharedArrayBuffer(Int32Array.BYTES_PER_ELEMENT);
    return new Promise<Found>((resolve, reject) => {
      const timer = wall.after(QUERY_MS, () => {
        if (cancel) Atomics.store(new Int32Array(cancel), 0, 1);
        else looker.postMessage({ type: "cancel", id });
        this.#waiting.delete(id);
        reject(new Error("the search took too long"));
        this.#idleLater();
      });
      this.#waiting.set(id, { resolve, reject, timer });
      this.#asked.get(looker)?.add(id);
      looker.postMessage({ type: "query", id, query, asker, ...options, ...(cancel ? { cancel } : {}) } satisfies Told);
    });
  }

  async stop(): Promise<void> {
    this.#closed = true;
    this.#idle?.();
    this.#idle = null;
    await Promise.all([this.#looker?.terminate(), this.#scope.close(), this.#sessionList.close(), this.#starting]);
    this.#looker = null;
  }
}
