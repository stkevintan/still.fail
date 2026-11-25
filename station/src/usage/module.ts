// What the agents spent (docs: the usage page), as a part of the station (parts.ts): read from their transcripts now,
// after each turn ends and as a session at work writes more (usage/counter.ts), recorded once (store/usage.ts). Every
// way it is shown is added up from that record: a chat's execution details and agent card (told as more is recorded,
// on its live stream and in its session's summary, `usage`) and the usage page (GET /usage).
import { Clock, Effect, Layer } from "effect";
import { MbBackfill, resolveReaderSelection } from "../read/mb-reader.ts";
import type { ReaderSelectConfig } from "../read/reader-select.ts";
import { wall } from "../ops/fibers.ts";
import { usageRoutes } from "../api/routes/usage.ts";
import { usageNow } from "../read/usage.ts";
import { Agents } from "../sessions/agents.ts";
import { hubConfig } from "../sessions/config.ts";
import type { LiveHub } from "../sessions/live.ts";
import { Parts, Paths, Previous, ReaderConfig, Readers, StationConfig, Store } from "../services.ts";
import { log } from "../ops/log.ts";
import type { Store as StationStore } from "../store/store.ts";
import { giveBackfill, takeBackfill } from "../store/backfill.ts";
import { stopUsageIndexes, usageIndexesLeft } from "../store/usage-retire.ts";
import { installCompactUsage } from "../store/usage-compact.ts";
import { usage15mSince } from "../store/usage-15m.ts";
import { drainUsageChatDirty } from "../store/usage-chat-stats.ts";
import { UsageCounter } from "./counter.ts";

/// A session's usage as its summary says it (store.ts `setSessionUsage`): as recorded now (read/usage.ts `usageNow`).
/// None before a call. `quiet`: not told as a change of the session.
export function keepUsage(store: StationStore, key: string, quiet = false): void {
  const usage = usageNow(store, key);
  if (usage !== null) store.setSessionUsage(key, usage, quiet);
}

/// Recomputes kept usage summaries that still had unpriced calls once the model catalog loads or changes.
export function repriceUsage(store: StationStore, live: LiveHub): void {
  const keys = store.unpricedUsageSessions();
  if (keys.length === 0) return;
  for (const key of keys) keepUsage(store, key);
  live.usageCounted();
}

/// The live view reads each saved summary. Only sessions whose recorded usage changes are updated and told.
export function keepCounted(store: StationStore, live: LiveHub, counter: UsageCounter): () => void {
  live.countWith({
    of: (key) => store.sessionUsage(key),
    ask: (key) => counter.soon(key),
    flush: async (key) => {
      await counter.read(new Set([key]));
    },
  });
  return store.subscribe((change) => {
    if (change.type === "usage" && change.statisticsOnly) return;
    // A session gone on in another conversation (its context cleared, as 换新上下文 does): its context is that one's.
    const sessions = change.type === "usage" ? change.sessions : change.type === "conversation" ? [change.key] : null;
    if (sessions === null) return;
    for (const key of sessions) keepUsage(store, key);
    live.usageCounted();
  });
}

/// Keep the contexts with the station's own writers and stop the old statistics' writers, without waiting behind another
/// connection on the station thread.
function tryStopUsageIndexes(store: StationStore): boolean {
  const priority = new Int32Array(store.backfillPriority);
  const owner = -1; // Background workers use positive thread ids.
  if (!takeBackfill(priority, owner)) return false;
  try {
    const timeout = (store.db.prepare("PRAGMA busy_timeout").get() as { timeout: number }).timeout;
    store.db.exec("PRAGMA busy_timeout = 0");
    try {
      try { installCompactUsage(store.db); }
      catch (error) {
        const code = (error as { errcode?: number }).errcode;
        if (code !== undefined && [5, 6].includes(code & 255)) throw error;
        // Even if the contexts cannot be kept, do not leave the old per-call writers running.
        log.warn("usage", "the usage contexts could not be installed", { error: (error as Error).message });
      }
      stopUsageIndexes(store.db);
      return true;
    } catch (error) {
      const code = (error as { errcode?: number }).errcode;
      if (code !== undefined && [5, 6].includes(code & 255)) return false;
      throw error;
    } finally {
      store.db.exec(`PRAGMA busy_timeout = ${timeout}`);
    }
  } finally { giveBackfill(priority, owner); }
}

/// An older station reads and writes the old statistics during handover. Stop their writers only after it actually
/// exits, then free them and take in the calls from before the quarters (store/usage-15m.ts). `binary`: the MoonBit
/// program, a test's own where it gives one. True once all of it is done.
export function retireAfterPrevious(store: StationStore, exited: Promise<void>, binary?: string, readers?: () => ReaderSelectConfig) {
  let stopped = false;
  return Effect.gen(function* () {
    yield* Effect.tryPromise({ try: () => exited, catch: (error) => error });
    while (!(yield* Effect.try({ try: () => tryStopUsageIndexes(store), catch: (error) => error }))) {
      yield* Effect.sleep(50);
    }
    stopped = true;
    const path = store.db.location();
    if (path === null) {
      // (no builder opens a database in memory: what it would free and take in stays, its writers stopped)
      if (usageIndexesLeft(store.db) || usage15mSince(store.db) !== null) log.warn("usage", "the usage retirement requires a file-backed store");
      return true;
    }
    // (by the MoonBit builder, station/mb's src/usagefill: a step at a time, the permit taken for each)
    yield* Effect.tryPromise({
      try: () => {
        const mb = resolveReaderSelection("usage-retire", { binary, config: readers, logAt: "readers" }).primaryBinary;
        return retireByProgram(store, mb, path);
      },
      catch: (error) => error,
    });
    return true;
  }).pipe(Effect.catch((error) => Effect.sync(() => {
    log.warn("usage", stopped ? "the old usage statistics could not be removed" : "the old usage statistics' writers could not be stopped", { error: (error as Error).message });
    return false;
  })));
}

/// The usage retirement by the MoonBit program (`--builder usage-retire`): the retired statistics freed, then the old
/// calls taken in, newest first, with at most about a tenth of the time going to them; pages open read again once old
/// days came in.
async function retireByProgram(store: StationStore, mb: string, path: string): Promise<void> {
  const program = new MbBackfill(mb, ["--builder", "usage-retire", "--db", path], store.backfillPriority, 20);
  // (one that cannot start says so, then ends: its end fails what was asked)
  program.on("error", (error: Error) => log.warn("usage", "the usage retirement program failed", { error: error.message }));
  const ask = (message: object) => new Promise<{ done: boolean; error?: string }>((resolve, reject) => {
    const exit = (code: number) => reject(new Error(`usage retirement stopped (exit ${code})`));
    program.once("exit", exit);
    program.once("message", (answer: { done: boolean; error?: string }) => {
      program.off("exit", exit);
      if (answer.error) reject(new Error(answer.error)); else resolve(answer);
    });
    program.postMessage(message);
  });
  try {
    while (!(await ask({ drop: true })).done);
    let filled = false;
    for (;;) {
      const started = performance.now();
      if ((await ask({})).done) break;
      filled = true;
      await wall.sleep(Math.max(200, (performance.now() - started) * 9));
    }
    // The days before the quarters began have just come in: pages open now read them again.
    if (filled) store.usageChanged([], undefined, true);
  } finally { await program.terminate(); }
}

/// Retry temporary installation or cleanup failures after stopping the old writers.
export function retireUntilComplete(store: StationStore, exited: Promise<void>, binary?: string, readers?: () => ReaderSelectConfig) {
  return Effect.gen(function* () {
    let retryMs = 250;
    while (!(yield* retireAfterPrevious(store, exited, binary, readers))) {
      yield* Effect.sleep(retryMs);
      retryMs = Math.min(retryMs * 2, 30_000);
    }
  });
}

/// The chats of sessions that moved between workspaces (usage_chat_dirty) given their new workspace, a batch at a
/// time, the station's thread given back between them: once the station before has gone, and again each time
/// sessions move. Pages open are told once none waits (the page's chats are whole again: `chatsIncomplete` no more).
/// The function returned stops it.
export function drainUsageChats(store: StationStore, exited: Promise<void>, batch = 32): { drained: () => Promise<void>; stop: () => void } {
  let stopped = false;
  let ready = false;
  let running: Promise<void> | null = null;
  let again = false;
  const run = async () => {
    do {
      again = false;
      let moved = false;
      for (;;) {
        if (stopped) return;
        let step: { done: boolean; processed: number };
        try { step = drainUsageChatDirty(store.db, batch); }
        catch (error) {
          log.warn("usage", "the chats of moved sessions could not be counted again", { error: (error as Error).message });
          return;
        }
        if (step.processed > 0) moved = true;
        if (step.done) break;
        await new Promise<void>((resolve) => setImmediate(resolve));
      }
      if (moved) store.usageChanged([], undefined, true);
    } while (again && !stopped);
  };
  const wake = () => {
    if (stopped || !ready) return;
    if (running !== null) { again = true; return; }
    running = run().finally(() => { running = null; });
  };
  const unsubscribe = store.onSessionWorkspaceChange(wake);
  void exited.then(() => { ready = true; wake(); }, () => {});
  return {
    drained: async () => { while (running !== null) await running; },
    stop: () => { stopped = true; unsubscribe(); },
  };
}

export const UsageLive = Layer.effectDiscard(
  Effect.gen(function* () {
    const { data } = yield* Paths;
    const store = yield* Store;
    const config = yield* StationConfig;
    const { hub } = yield* Agents;
    const previous = yield* Previous;
    const readerConfig = yield* ReaderConfig;
    const readers = yield* Readers;
    yield* Effect.forkScoped(retireUntilComplete(store, previous.exited, undefined, readerConfig).pipe(Effect.provideService(Clock.Clock, hub.clock)));
    yield* Effect.acquireRelease(
      Effect.sync(() => drainUsageChats(store, previous.exited)),
      (drain) => Effect.sync(() => drain.stop()),
    );
    const usage = yield* Effect.acquireRelease(
      Effect.sync(() => new UsageCounter({
        store, config: () => ({ dataDir: data, profiles: hubConfig(config.raw(), data).profiles }), clock: hub.clock, readers: readerConfig,
      })),
      (u) => Effect.promise(() => u.stop()),
    );
    usage.start();
    // The counter's program, when it reads nothing, is let go when the station is short of memory.
    readers.onTrim(() => usage.trimIdle());
    yield* Effect.acquireRelease(
      Effect.sync(() => keepCounted(store, hub.live, usage)),
      (unsubscribe) => Effect.sync(unsubscribe),
    );
    (yield* Parts).routes((tools) => usageRoutes(tools, () => usage.readingAll()));
  }),
);
