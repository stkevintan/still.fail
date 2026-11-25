// The export's work as one thing (replica/AGENTS.md): a pass of the exporter, and where the files its batches name are,
// in the TypeScript the MoonBit program is held to (replica-export.ts), run in a test's own thread, its clock the
// test's (`InlineRunner`, the tests' own stations' runner; the station's is src/replica/runner.ts `ProgramRunner`).
import type { Places, Told } from "../../src/replica/export.ts";
import type { Runner, RunnerOptions, WorkPassed } from "../../src/replica/runner.ts";
import { type ExporterOptions, Exporter } from "./replica-export.ts";

export class ExportWork {
  readonly exporter: Exporter;

  constructor(o: ExporterOptions) {
    this.exporter = new Exporter(o);
  }

  close(): void {
    this.exporter.close();
  }

  setPlaces(places: Places): void {
    this.exporter.setPlaces(places);
  }

  newGenerations(after: number): void {
    this.exporter.newGenerations(after);
  }

  pass(told: Told): WorkPassed {
    return { ...this.exporter.pass(told), empty: this.exporter.empty() };
  }

  sources(hashes: string[]): Record<string, string> {
    const out: Record<string, string> = {};
    for (const h of hashes) {
      const s = this.exporter.sourceOf(h);
      if (s !== null) out[h] = s;
    }
    return out;
  }
}

/// The work in this thread, one thing at a time as in the program (a test's: its clock).
export class InlineRunner implements Runner {
  readonly work: ExportWork;
  #queue: Promise<unknown> = Promise.resolve();

  constructor(o: RunnerOptions & { now: () => number; chunkBytes?: number }) {
    this.work = new ExportWork({ ...o, compactHeads: true });
  }

  #one<T>(f: () => T | Promise<T>): Promise<T> {
    const p = this.#queue.then(f);
    this.#queue = p.catch(() => {});
    return p;
  }

  places(places: Places) {
    return this.#one(() => this.work.setPlaces(places));
  }
  pass(told: Told) {
    return this.#one(() => this.work.pass(told));
  }
  newGenerations(after: number) {
    return this.#one(() => this.work.newGenerations(after));
  }
  sources(hashes: string[]) {
    return this.#one(() => this.work.sources(hashes));
  }
  close() {
    return this.#one(() => this.work.close());
  }
}
