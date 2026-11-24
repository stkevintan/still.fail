import { MbBackfill, resolveReaderSelection } from "../read/mb-reader.ts";
import type { ReaderSelectConfig } from "../read/reader-select.ts";
import { log } from "../ops/log.ts";
import { releaseStoppedBackfill } from "../store/backfill.ts";
import { chatShareIndexReady, hasChatShareIndex, refreshChatShareIndex, SHARE_MANY } from "../store/chat-share-index.ts";
import type { Store } from "../store/store.ts";

/// Sharing continues to answer the old way while the preceding station is up or a worker prepares its old grants.
export class ChatShareIndexBuilder {
  private pending: Promise<boolean> | null = null;
  private worker: MbBackfill | null = null;
  private stopped = false;
  private readonly cancelled = Promise.withResolvers<boolean>();
  private readonly previous: Promise<boolean>;
  private readonly store: Store;
  private readonly binary: string | undefined;
  private readonly readers: (() => ReaderSelectConfig) | undefined;

  constructor(store: Store, previous: Promise<void>, binary?: string, readers?: () => ReaderSelectConfig) {
    this.store = store;
    this.binary = binary;
    this.readers = readers;
    this.previous = previous.then(() => true, (error) => {
      log.warn("xshare", "could not wait for the previous station before preparing shares", { error: (error as Error).message });
      return false;
    });
  }

  request(): void {
    if (this.stopped || this.pending !== null) return;
    try {
      if (chatShareIndexReady(this.store.db)) return;
      // A few shares are cheaper to read directly. Do not install anything until the table grows past this probe.
      if (!hasChatShareIndex(this.store.db) && this.store.db.prepare(SHARE_MANY).get() === undefined) return;
    } catch (error) {
      log.warn("xshare", "the share lookup could not be checked", { error: (error as Error).message });
      return;
    }
    const work = (async () => {
      if (!await Promise.race([this.previous, this.cancelled.promise]) || this.stopped) return false;
      return this.runWorker();
    })().catch((error) => {
      log.warn("xshare", "the share lookup could not be prepared", { error: (error as Error).message });
      return false;
    }).finally(() => { if (this.pending === work) this.pending = null; });
    this.pending = work;
  }

  async settled(): Promise<void> { await this.pending; }

  private runWorker(): Promise<boolean> {
    const path = this.store.db.location();
    if (path === null) {
      log.warn("xshare", "the share lookup's backfill requires a file-backed store");
      return Promise.resolve(false);
    }
    return new Promise<boolean>((resolve) => {
      // (by the MoonBit builder, station/mb's src/activity, share.mbt: `MbBackfill`)
      let worker: MbBackfill;
      try {
        const bin = resolveReaderSelection("session-backfill", { binary: this.binary, config: this.readers, logAt: "readers" }).primaryBinary;
        worker = new MbBackfill(bin, ["--builder", "session-backfill", "--db", path], this.store.backfillPriority, 20);
      }
      catch (error) { log.warn("xshare", "the share worker could not start", { error: (error as Error).message }); resolve(false); return; }
      const owner = worker.threadId;
      let done = false;
      this.worker = worker;
      worker.unref();
      worker.on("message", (result: { done: boolean; error?: string }) => {
        if (result.error) {
          log.warn("xshare", "a share batch stopped", { error: result.error });
          void worker.terminate();
        } else if (result.done || this.stopped) {
          done = result.done && !this.stopped;
          void worker.terminate();
        } else worker.postMessage({ kind: "chat-share" });
      });
      worker.once("error", (error) => log.warn("xshare", "the share worker failed", { error: error.message }));
      worker.once("exit", (code) => {
        releaseStoppedBackfill(this.store.backfillPriority, owner);
        if (this.worker === worker) this.worker = null;
        if (done) {
          try { done = refreshChatShareIndex(this.store.db); }
          catch (error) { done = false; log.warn("xshare", "the prepared share lookup could not be found", { error: (error as Error).message }); }
        }
        if (!done && !this.stopped) log.warn("xshare", "the share worker stopped before finishing", { code });
        resolve(done);
      });
      worker.postMessage({ kind: "chat-share" });
    });
  }

  async close(): Promise<void> {
    if (this.stopped) return;
    this.stopped = true;
    this.cancelled.resolve(false);
    if (this.worker !== null) await this.worker.terminate();
    await this.pending;
  }
}
