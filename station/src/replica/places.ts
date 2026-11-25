// The places that keep a station's copies (replica/AGENTS.md), and how a copy is brought level with one: the other
// stations of its workspace, each keeping what it is sent under <data>/replicas/, without reading inside it:
//
//   <root>/<workspace>/<origin>/files/<sha256>           the attached files, shared by its generations
//   <root>/<workspace>/<origin>/<gen>/log/<batch>         a generation's batches
//   <root>/<workspace>/<origin>/<gen>/head.json           written after its batches and files, before anything goes
//
// A place keeps every generation it was given: what goes is only a generation's batches its head no longer names
// (folded into another) and files no head it holds names any more (their chat deleted).
import { open } from "node:fs/promises";
import { randomBytes } from "node:crypto";
import { dirname, join } from "node:path";
import { type Fs, type Stat, direct } from "../drive/fs.ts";
import { BATCH, GEN, HASH, STATION, WORKSPACE, type Head, asHead, genMade } from "./format.ts";
import { MANIFEST_MAX_BYTES, type ResolvedManifest, loadTranscriptManifest, manifestAllRefs, readStreamBounded } from "./manifest.ts";

/// What a place holds of one station's copies in a workspace: each generation (its head, its batches) and the files.
export type Holding = { gen: string; head: Head | null; batches: string[] };
export type Held = { gens: Holding[]; files: string[]; hasUnverifiedHead?: boolean; unverifiedGens?: string[] };
export const nothingHeld = (): Held => ({ gens: [], files: [] });

export const DROP_FILES_PAGE = 2000;

export interface Place {
  held(ws: string, origin: string): Promise<Held>;
  /// A batch or the head of a generation (`head` optional parsed object avoids redundant JSON.parse in places like S3Place).
  put(ws: string, origin: string, gen: string, kind: "batch" | "head", name: string, bytes: Buffer, head?: Head): Promise<void>;
  /// A file, by its hash, read from `source` (a path on this station) or given whole.
  putFile(ws: string, origin: string, hash: string, source: string | Buffer): Promise<void>;
  drop(ws: string, origin: string, gen: string, batches: string[], files: string[], opts?: { allowCurrentGenTranscripts?: boolean }): Promise<void>;
  /// Optional post-head orphan file cleanup (e.g. S3Place after crash recovery when all heads are verified).
  pruneOrphans?(ws: string, origin: string, liveHead?: Head): Promise<void>;
}

function check(ws: string, origin: string, gen?: string): void {
  if (!WORKSPACE.test(ws) || !STATION.test(origin) || (gen !== undefined && !GEN.test(gen))) throw new Error("not a copy's name");
}

/// What a file is written in at a time.
const PIECE = 1 << 20;

/// The bytes of a file of this station's, a piece at a time.
async function* fileOf(path: string): AsyncIterable<Buffer> {
  const f = await open(path, "r");
  try {
    for (;;) {
      const piece = Buffer.allocUnsafe(PIECE);
      const { bytesRead } = await f.read(piece, 0, PIECE, null);
      if (bytesRead === 0) return;
      yield piece.subarray(0, bytesRead);
    }
  } finally {
    await f.close();
  }
}

async function* oneOf(bytes: Buffer): AsyncIterable<Buffer> {
  yield bytes;
}

const MAX_META_ENTRIES = 512;
const MAX_FILES_ENTRIES = 8;
const MAX_CACHED_FILE_HASHES = 500_000;

type HeadMeta = { mtimeMs: number; size: number; to: number; partial: boolean; batches: string[]; manifestRoot?: string };
type HeadFilesEntry = {
  mtimeMs: number;
  size: number;
  files: Record<string, number>;
  transcriptFiles?: Record<string, number>;
  manifestRoot?: string;
  manifestRefs?: Set<string>;
  count: number;
};

function countHeadFiles(head: Head, manifestRefs?: Set<string>): number {
  let count = 0;
  for (const h in head.files) if (Object.hasOwn(head.files, h)) count++;
  if (head.transcriptFiles !== undefined) {
    for (const h in head.transcriptFiles) if (Object.hasOwn(head.transcriptFiles, h)) count++;
  }
  if (manifestRefs !== undefined) count += manifestRefs.size;
  return count;
}

function headFilesHas(entry: HeadFilesEntry, hash: string): boolean {
  return (
    Object.hasOwn(entry.files, hash) ||
    (entry.transcriptFiles !== undefined && Object.hasOwn(entry.transcriptFiles, hash)) ||
    (entry.manifestRefs !== undefined && entry.manifestRefs.has(hash))
  );
}

function isMissingFsError(e: unknown): boolean {
  const code = (e as { code?: unknown } | null)?.code;
  return code === "ENOENT" || code === "ENOTDIR";
}

/// Where a station keeps what other stations send it (`<data>/replicas`), on its own disk.
export class FolderPlace implements Place {
  readonly root: string;
  readonly fs: Fs;
  readonly #meta = new Map<string, HeadMeta>();
  readonly #headFiles = new Map<string, HeadFilesEntry>();
  readonly #locks = new Map<string, Promise<void>>();
  #cachedHashes = 0;
  constructor(root: string, fs: Fs = direct) {
    this.root = root;
    this.fs = fs;
  }

  async #withLock<T>(ws: string, origin: string, fn: () => Promise<T>): Promise<T> {
    const key = `${ws}\n${origin}`;
    const prev = this.#locks.get(key) ?? Promise.resolve();
    let release!: () => void;
    const next = new Promise<void>((r) => { release = r; });
    const tail = prev.then(() => next);
    this.#locks.set(key, tail);
    await prev;
    try {
      return await fn();
    } finally {
      release();
      if (this.#locks.get(key) === tail) this.#locks.delete(key);
    }
  }

  #setMeta(key: string, meta: HeadMeta): void {
    this.#meta.delete(key);
    this.#meta.set(key, meta);
    while (this.#meta.size > MAX_META_ENTRIES) {
      const oldest = this.#meta.keys().next().value;
      if (oldest === undefined) break;
      this.#meta.delete(oldest);
    }
  }

  #deleteFiles(key: string): void {
    const old = this.#headFiles.get(key);
    if (old !== undefined) {
      this.#cachedHashes -= old.count;
      this.#headFiles.delete(key);
    }
  }

  #setFiles(key: string, entry: HeadFilesEntry): void {
    this.#deleteFiles(key);
    if (entry.count > MAX_CACHED_FILE_HASHES) return;
    while (this.#headFiles.size >= MAX_FILES_ENTRIES || this.#cachedHashes + entry.count > MAX_CACHED_FILE_HASHES) {
      const oldest = this.#headFiles.keys().next().value;
      if (oldest === undefined) break;
      this.#deleteFiles(oldest);
    }
    this.#headFiles.set(key, entry);
    this.#cachedHashes += entry.count;
  }

  #cacheHead(
    key: string,
    st: Stat,
    head: Head,
    manifestRefs?: Set<string>,
    cacheFiles = true,
  ): { meta: HeadMeta; files: HeadFilesEntry | null } {
    const meta: HeadMeta = {
      mtimeMs: st.mtimeMs,
      size: st.size,
      to: head.to,
      partial: head.partial === true,
      batches: [...head.batches],
      ...(head.transcriptManifest !== undefined ? { manifestRoot: head.transcriptManifest } : {}),
    };
    this.#setMeta(key, meta);
    if (!cacheFiles) {
      this.#deleteFiles(key);
      return { meta, files: null };
    }
    const files: HeadFilesEntry = {
      mtimeMs: st.mtimeMs,
      size: st.size,
      files: head.files,
      ...(head.transcriptFiles !== undefined ? { transcriptFiles: head.transcriptFiles } : {}),
      ...(head.transcriptManifest !== undefined ? { manifestRoot: head.transcriptManifest } : {}),
      ...(manifestRefs !== undefined ? { manifestRefs } : {}),
      count: countHeadFiles(head, manifestRefs),
    };
    this.#setFiles(key, files);
    return { meta, files };
  }

  async #readBoundedPath(path: string, maxBytes: number): Promise<Buffer | null> {
    let st: Stat;
    try {
      st = await this.fs.stat(path);
    } catch (e) {
      if (isMissingFsError(e)) return null;
      throw e;
    }
    if (st.size > maxBytes) {
      throw new Error(`transcript manifest exceeds max bytes (${MANIFEST_MAX_BYTES})`);
    }
    const chunks: Buffer[] = [];
    let total = 0;
    const limit = maxBytes + 1;
    while (total < limit) {
      const want = Math.min(PIECE, limit - total);
      let res;
      try {
        res = await this.fs.read(path, total, want);
      } catch (e) {
        if (isMissingFsError(e)) return null;
        throw e;
      }
      if (res.bytes.length === 0) break;
      total += res.bytes.length;
      if (total > maxBytes) {
        throw new Error(`transcript manifest exceeds max bytes (${MANIFEST_MAX_BYTES})`);
      }
      chunks.push(res.bytes);
      if (total >= res.size) break;
    }
    return chunks.length === 0 ? Buffer.alloc(0) : chunks.length === 1 ? chunks[0]! : Buffer.concat(chunks, total);
  }

  async #readManifestObject(ws: string, origin: string, hash: string, maxBytes: number): Promise<Buffer | null> {
    return this.#readBoundedPath(join(this.dir(ws, origin), "files", hash), maxBytes);
  }

  async #resolveHeadManifest(ws: string, origin: string, head: Head): Promise<ResolvedManifest | null> {
    if (head.transcriptManifest === undefined) return null;
    return loadTranscriptManifest(head.transcriptManifest, (h, maxBytes) => this.#readManifestObject(ws, origin, h, maxBytes));
  }

  dir(ws: string, origin: string): string {
    return join(this.root, ws, origin);
  }

  #exists(path: string): Promise<boolean> {
    return this.fs.stat(path).then(() => true, () => false);
  }

  #list(dir: string): Promise<string[]> {
    return this.fs.names(dir).catch(() => [] as string[]);
  }

  async #listStrict(dir: string): Promise<string[]> {
    try {
      return await this.fs.names(dir);
    } catch (e) {
      if (isMissingFsError(e)) return [];
      throw e;
    }
  }

  /// Written beside and renamed into place, synced: whole or not at all.
  async #whole(path: string, bytes: AsyncIterable<Buffer>): Promise<Stat> {
    await this.fs.mkdir(dirname(path), true);
    const tmp = `${path}.${randomBytes(4).toString("hex")}.tmp`;
    let at = 0;
    let st: Stat;
    try {
      for await (const piece of bytes) {
        await this.fs.write(tmp, { create: at === 0, offset: at, data: piece });
        at += piece.length;
      }
      if (at === 0) await this.fs.write(tmp, { create: true, offset: 0, data: Buffer.alloc(0) });
      await this.fs.write(tmp, { create: false, offset: at, data: Buffer.alloc(0), truncate: at, sync: true });
      st = await this.fs.stat(tmp);
      await this.fs.rename(tmp, path);
    } catch (e) {
      await this.fs.unlink(tmp).catch(() => {});
      throw e;
    }
    return st;
  }

  async #head(path: string): Promise<Head | null> {
    try {
      return asHead(JSON.parse((await this.fs.readAll(path)).toString("utf8")));
    } catch {
      return null;
    }
  }

  async #readHeadStrict(path: string, ws: string, origin: string, gen: string): Promise<Head> {
    const raw = await this.fs.readAll(path);
    let parsed: Head | null = null;
    try {
      parsed = asHead(JSON.parse(raw.toString("utf8")));
    } catch {
      parsed = null;
    }
    if (parsed === null || parsed.gen !== gen || parsed.origin !== origin || parsed.workspace !== ws) {
      throw new Error(`corrupted head.json for ${ws}/${origin}/${gen}`);
    }
    return parsed;
  }

  async #headMetaStrict(ws: string, origin: string, gen: string): Promise<{ meta: HeadMeta; head?: Head } | null> {
    const key = `${ws}\n${origin}\n${gen}`;
    const path = join(this.dir(ws, origin), gen, "head.json");
    let st: Stat;
    try {
      st = await this.fs.stat(path);
    } catch (e) {
      if (!isMissingFsError(e)) throw e;
      this.#meta.delete(key);
      this.#deleteFiles(key);
      return null;
    }
    const cached = this.#meta.get(key);
    if (cached !== undefined && cached.mtimeMs === st.mtimeMs && cached.size === st.size && cached.manifestRoot === undefined) {
      this.#meta.delete(key);
      this.#meta.set(key, cached);
      return { meta: cached };
    }
    let head: Head;
    try {
      head = await this.#readHeadStrict(path, ws, origin, gen);
    } catch (e) {
      this.#meta.delete(key);
      this.#deleteFiles(key);
      throw e;
    }
    let manifestRefs: Set<string> | undefined;
    if (head.transcriptManifest !== undefined) {
      try {
        const resolved = await this.#resolveHeadManifest(ws, origin, head);
        if (resolved === null) {
          this.#meta.delete(key);
          this.#deleteFiles(key);
          throw new Error(`transcript manifest root ${head.transcriptManifest} could not be resolved`);
        }
        manifestRefs = manifestAllRefs(resolved);
      } catch (e) {
        this.#meta.delete(key);
        this.#deleteFiles(key);
        throw e;
      }
    }
    return { meta: this.#cacheHead(key, st, head, manifestRefs, true).meta, head };
  }

  async #headMeta(ws: string, origin: string, gen: string, strict = false): Promise<HeadMeta | null> {
    if (strict) return (await this.#headMetaStrict(ws, origin, gen))?.meta ?? null;
    const key = `${ws}\n${origin}\n${gen}`;
    const path = join(this.dir(ws, origin), gen, "head.json");
    let st: Stat;
    try {
      st = await this.fs.stat(path);
    } catch {
      this.#meta.delete(key);
      this.#deleteFiles(key);
      return null;
    }
    const cached = this.#meta.get(key);
    if (cached !== undefined && cached.mtimeMs === st.mtimeMs && cached.size === st.size) {
      this.#meta.delete(key);
      this.#meta.set(key, cached);
      return cached;
    }
    const head = await this.#head(path);
    if (head === null) {
      this.#meta.delete(key);
      this.#deleteFiles(key);
      return null;
    }
    let manifestRefs: Set<string> | undefined;
    let cacheFiles = true;
    if (head.transcriptManifest !== undefined) {
      try {
        const resolved = await this.#resolveHeadManifest(ws, origin, head);
        if (resolved === null) cacheFiles = false;
        else manifestRefs = manifestAllRefs(resolved);
      } catch {
        cacheFiles = false;
      }
    }
    return this.#cacheHead(key, st, head, manifestRefs, cacheFiles).meta;
  }

  async #headFilesOfStrict(ws: string, origin: string, gen: string): Promise<HeadFilesEntry | null> {
    const key = `${ws}\n${origin}\n${gen}`;
    const path = join(this.dir(ws, origin), gen, "head.json");
    let st: Stat;
    try {
      st = await this.fs.stat(path);
    } catch (e) {
      if (!isMissingFsError(e)) throw e;
      this.#meta.delete(key);
      this.#deleteFiles(key);
      return null;
    }
    const cached = this.#headFiles.get(key);
    if (cached !== undefined && cached.mtimeMs === st.mtimeMs && cached.size === st.size && cached.manifestRoot === undefined) {
      this.#headFiles.delete(key);
      this.#headFiles.set(key, cached);
      return cached;
    }
    const head = await this.#head(path);
    if (head === null || head.gen !== gen || head.origin !== origin || head.workspace !== ws) {
      this.#meta.delete(key);
      this.#deleteFiles(key);
      throw new Error(`corrupted head.json for ${ws}/${origin}/${gen}`);
    }
    let manifestRefs: Set<string> | undefined;
    if (head.transcriptManifest !== undefined) {
      try {
        const resolved = await this.#resolveHeadManifest(ws, origin, head);
        if (resolved !== null) manifestRefs = manifestAllRefs(resolved);
      } catch (e) {
        this.#deleteFiles(key);
        throw e;
      }
    }
    return this.#cacheHead(key, st, head, manifestRefs, true).files!;
  }

  async held(ws: string, origin: string): Promise<Held> {
    check(ws, origin);
    const dir = this.dir(ws, origin);
    const gens: Holding[] = [];
    for (const gen of await this.#list(dir)) {
      if (!GEN.test(gen)) continue;
      gens.push({ gen, head: await this.#head(join(dir, gen, "head.json")), batches: (await this.#list(join(dir, gen, "log"))).filter((b) => BATCH.test(b)).sort() });
    }
    gens.sort((a, b) => genMade(a.gen) - genMade(b.gen) || (a.gen < b.gen ? -1 : 1));
    return { gens, files: (await this.#list(join(dir, "files"))).filter((f) => HASH.test(f)) };
  }

  /// Strict inventory for source-side handover: propagates `EACCES`/`EIO` from directory listing instead of returning
  /// empty, and marks `hasUnverifiedHead: true` if any generation's `head.json` exists but fails to read or parse.
  async heldStrict(ws: string, origin: string): Promise<Held> {
    check(ws, origin);
    const dir = this.dir(ws, origin);
    const gens: Holding[] = [];
    const unverifiedGens: string[] = [];
    for (const gen of await this.#listStrict(dir)) {
      if (!GEN.test(gen)) continue;
      const headPath = join(dir, gen, "head.json");
      let head: Head | null = null;
      let raw: Buffer | null = null;
      try {
        raw = await this.fs.readAll(headPath);
      } catch (e) {
        if (!isMissingFsError(e)) {
          unverifiedGens.push(gen);
        }
      }
      if (raw !== null) {
        try {
          const parsed = asHead(JSON.parse(raw.toString("utf8")));
          if (parsed !== null && parsed.gen === gen && parsed.origin === origin && parsed.workspace === ws) {
            head = parsed;
          } else {
            unverifiedGens.push(gen);
          }
        } catch {
          unverifiedGens.push(gen);
        }
      }
      const batches = (await this.#listStrict(join(dir, gen, "log"))).filter((b) => BATCH.test(b)).sort();
      gens.push({ gen, head, batches });
    }
    gens.sort((a, b) => genMade(a.gen) - genMade(b.gen) || (a.gen < b.gen ? -1 : 1));
    const files = (await this.#listStrict(join(dir, "files"))).filter((f) => HASH.test(f));
    return {
      gens,
      files,
      ...(unverifiedGens.length > 0 ? { hasUnverifiedHead: true, unverifiedGens } : {}),
    };
  }

  async put(ws: string, origin: string, gen: string, kind: "batch" | "head", name: string, bytes: Buffer): Promise<void> {
    check(ws, origin, gen);
    const dir = join(this.dir(ws, origin), gen);
    if (kind === "batch") {
      if (!BATCH.test(name)) throw new Error("not a batch's name");
      // (a batch is never written over: what it holds is what its name says)
      if (await this.#exists(join(dir, "log", name))) return;
      await this.#whole(join(dir, "log", name), oneOf(bytes));
    } else {
      const head = asHead(JSON.parse(bytes.toString("utf8")));
      if (head === null || head.gen !== gen || head.origin !== origin || head.workspace !== ws) throw new Error("not a head of this copy");
      if (head.partial === true && head.transcriptManifest !== undefined) {
        throw new Error("partial head must not reference transcriptManifest");
      }
      await this.#withLock(ws, origin, async () => {
        // A head never goes back: one strictly older than what is held is ignored; same-to heads are checked
        // symmetrically below after validating incoming batches/manifest so conflicts throw explicitly.
        // Strict mode: only ENOENT returns null; stat/readAll I/O errors, corrupted JSON, or corrupt manifests abort.
        const wasInfo = await this.#headMetaStrict(ws, origin, gen);
        const was = wasInfo?.meta ?? null;
        if (was !== null && was.to > head.to) return;
        for (const b of head.batches) if (!(await this.#exists(join(dir, "log", b)))) throw new Error(`batch ${b} is not here yet`);
        let resolvedIncoming: ResolvedManifest | undefined;
        let manifestRefs: Set<string> | undefined;
        if (head.transcriptManifest !== undefined) {
          const resolved = await this.#resolveHeadManifest(ws, origin, head);
          if (resolved === null) throw new Error("transcript manifest could not be resolved");
          const filesDir = join(this.dir(ws, origin), "files");
          for (const chunkHash in resolved.files) {
            if (Object.hasOwn(resolved.files, chunkHash) && !(await this.#exists(join(filesDir, chunkHash)))) {
              throw new Error(`transcript chunk ${chunkHash} is not here yet`);
            }
          }
          resolvedIncoming = resolved;
          manifestRefs = manifestAllRefs(resolved);
        }
        if (was !== null && was.to === head.to) {
          // Under #withLock, reuse the head already read on cache miss (avoiding redundant readAll) or read strictly.
          const existing = wasInfo?.head ?? await this.#readHeadStrict(join(dir, "head.json"), ws, origin, gen);
          let existingTf: Record<string, number>;
          if (existing.transcriptManifest !== undefined) {
            let resolvedExisting: ResolvedManifest | null;
            try {
              resolvedExisting = await this.#resolveHeadManifest(ws, origin, existing);
            } catch {
              throw new Error("head conflict: existing same-to head manifest unreadable");
            }
            if (resolvedExisting === null) {
              throw new Error("head conflict: existing same-to head manifest unreadable");
            }
            existingTf = { ...(existing.transcriptFiles ?? {}), ...resolvedExisting.files };
          } else {
            existingTf = existing.transcriptFiles ?? {};
          }
          const incomingTf = resolvedIncoming !== undefined
            ? { ...(head.transcriptFiles ?? {}), ...resolvedIncoming.files }
            : (head.transcriptFiles ?? {});
          const sameCore = sameBatches(head.batches, existing.batches) && sameFileMap(head.files, existing.files);
          if (!was.partial) {
            // Existing full head at same `to`: never overwrite disk. Succeed idempotently ONLY if existing
            // already covers incoming (replay, made-only bump, or subset partial); throw on conflict.
            if (sameCore && isSubsetFileMap(incomingTf, existingTf)) return;
            throw new Error("head conflict: existing same-to full head does not cover incoming head");
          }
          // Existing partial head at same `to`: only allow upgrade/replacement when incoming strictly covers
          // existing (`incomingTf ⊇ existingTf`); throw explicit conflict otherwise.
          if (!sameCore || !isSubsetFileMap(existingTf, incomingTf)) {
            throw new Error("head conflict: incoming head does not cover existing same-to partial head");
          }
        }
        const st = await this.#whole(join(dir, "head.json"), oneOf(bytes));
        this.#cacheHead(`${ws}\n${origin}\n${gen}`, st, head, manifestRefs);
      });
    }
  }

  async putFile(ws: string, origin: string, hash: string, source: string | Buffer): Promise<void> {
    await this.putFileFrom(ws, origin, hash, Buffer.isBuffer(source) ? oneOf(source) : fileOf(source));
  }

  /// Takes a file sent as it comes.
  async putFileFrom(ws: string, origin: string, hash: string, bytes: AsyncIterable<Buffer>): Promise<void> {
    check(ws, origin);
    if (!HASH.test(hash)) throw new Error("not a file's hash");
    const path = join(this.dir(ws, origin), "files", hash);
    if (await this.#exists(path)) {
      for await (const _ of bytes) void _;
      return;
    }
    await this.#whole(path, bytes);
  }

  async drop(ws: string, origin: string, gen: string, batches: string[], files: string[]): Promise<void> {
    check(ws, origin, gen);
    await this.#withLock(ws, origin, async () => {
      const dir = this.dir(ws, origin);
      const meta = await this.#headMeta(ws, origin, gen, true);
      for (const b of batches) if (BATCH.test(b) && !(meta?.batches ?? []).includes(b)) await this.fs.unlink(join(dir, gen, "log", b)).catch(() => {});
      if (files.length === 0) return;
      // (a file stays while any generation held names it; fail-closed if any head or manifest is corrupted)
      const liveGens = new Set<string>();
      const entries: HeadFilesEntry[] = [];
      for (const g of await this.#listStrict(dir)) {
        if (!GEN.test(g)) continue;
        liveGens.add(g);
        const e = await this.#headFilesOfStrict(ws, origin, g);
        if (e !== null) entries.push(e);
      }
      const prefix = `${ws}\n${origin}\n`;
      for (const key of this.#meta.keys()) {
        if (key.startsWith(prefix) && !liveGens.has(key.slice(prefix.length))) this.#meta.delete(key);
      }
      for (const key of this.#headFiles.keys()) {
        if (key.startsWith(prefix) && !liveGens.has(key.slice(prefix.length))) this.#deleteFiles(key);
      }
      for (const f of files) {
        if (!HASH.test(f)) continue;
        let referenced = false;
        for (const e of entries) {
          if (headFilesHas(e, f)) {
            referenced = true;
            break;
          }
        }
        if (!referenced) await this.fs.unlink(join(dir, "files", f)).catch(() => {});
      }
    });
  }

  #resolvePath(ws: string, origin: string, gen: string | null, name: string): string | null {
    check(ws, origin, gen ?? undefined);
    return gen === null
      ? (HASH.test(name) ? join(this.dir(ws, origin), "files", name) : null)
      : name === "head.json"
        ? join(this.dir(ws, origin), gen, "head.json")
        : BATCH.test(name)
          ? join(this.dir(ws, origin), gen, "log", name)
          : null;
  }

  /// Where a batch, a head or a file held here is, by its name; null where it is not (propagates non-ENOENT errors like EACCES/EIO).
  async pathOf(ws: string, origin: string, gen: string | null, name: string): Promise<string | null> {
    const path = this.#resolvePath(ws, origin, gen, name);
    if (path === null) return null;
    try {
      await this.fs.stat(path);
      return path;
    } catch (e) {
      if (isMissingFsError(e)) return null;
      throw e;
    }
  }

  /// A batch, a head or a file held here, whole; null where it is not (propagates non-ENOENT errors like EACCES/EIO).
  async read(ws: string, origin: string, gen: string | null, name: string): Promise<Buffer | null> {
    const path = this.#resolvePath(ws, origin, gen, name);
    if (path === null) return null;
    try {
      return await this.fs.readAll(path);
    } catch (e) {
      if (isMissingFsError(e)) return null;
      throw e;
    }
  }

  /// A batch, a head or a file held here, bounded to `maxBytes`; null where it is not (propagates non-ENOENT errors).
  async readBounded(ws: string, origin: string, gen: string | null, name: string, maxBytes: number): Promise<Buffer | null> {
    const path = this.#resolvePath(ws, origin, gen, name);
    return path === null ? null : this.#readBoundedPath(path, maxBytes);
  }

  /// A batch, a head or a file held here, a piece at a time (preserves original fs error codes like EACCES/EIO).
  async *stream(ws: string, origin: string, gen: string | null, name: string): AsyncIterable<Buffer> {
    const path = this.#resolvePath(ws, origin, gen, name);
    if (path === null) throw Object.assign(new Error(`ENOENT: ${name} is not there`), { code: "ENOENT" });
    for (let at = 0; ; ) {
      const { bytes, size } = await this.fs.read(path, at, PIECE);
      if (bytes.length > 0) yield bytes;
      at += bytes.length;
      if (bytes.length === 0 || at >= size) return;
    }
  }

  /// Every station whose copies are held here in `ws`, with each generation's head.
  async origins(ws: string): Promise<{ origin: string; heads: Head[] }[]> {
    if (!WORKSPACE.test(ws)) return [];
    const out: { origin: string; heads: Head[] }[] = [];
    for (const origin of await this.#list(join(this.root, ws))) {
      if (!STATION.test(origin)) continue;
      const heads = (await this.held(ws, origin)).gens.flatMap((g) => (g.head === null ? [] : [g.head]));
      if (heads.length > 0) out.push({ origin, heads });
    }
    return out;
  }

  /// Drops cached head metadata for a workspace, or for one origin station in it.
  forget(ws: string, origin?: string): void {
    const prefix = origin === undefined ? `${ws}\n` : `${ws}\n${origin}\n`;
    for (const key of this.#meta.keys()) {
      if (key.startsWith(prefix)) this.#meta.delete(key);
    }
    for (const key of this.#headFiles.keys()) {
      if (key.startsWith(prefix)) this.#deleteFiles(key);
    }
  }

  /// All it holds of a workspace (a station that left it), or of one station's copies there, let go.
  async remove(ws: string, origin?: string): Promise<void> {
    await this.fs.remove(origin === undefined ? join(this.root, ws) : this.dir(ws, origin)).catch(() => {});
    this.forget(ws, origin);
  }
}

/// The generation of this station's own copy being brought to a place: its head, its batches' bytes, where its files
/// are now.
export type Own = {
  head: Head;
  batch(name: string): Promise<Buffer>;
  sources(hashes: string[]): Promise<Map<string, string>>;
  /// Resolves a local compact `head.transcriptManifest` into its validated `chunkHash -> compSize` map.
  loadTranscriptFiles?(): Promise<Record<string, number>>;
};

/// What a place holds of this station's generation, as this station last left it there (it alone writes that
/// generation there): the batches, the files, the files the place's other generations name, how far its head went. Kept
/// between levellings, so that one after a batch sends that batch and the head alone; the place is asked what it holds
/// only as this station starts, as the place comes back, after a failure and on a handover.
export type Known = {
  gen: string;
  batches: Set<string>;
  files: Set<string>;
  others: Set<string>;
  hasUnverifiedHead?: boolean;
  unverifiedGens?: Set<string>;
  to: number;
  made: number;
  /// All file/manifest hashes referenced by a preserved same-to superset full head on the target, preventing `oldFiles`
  /// drop from reclaiming them on this or subsequent same-to `level()` calls.
  keptTargetFiles?: Set<string>;
  /// The preserved same-to superset full head on the target, passed to `pruneOrphans` so orphan reconciliation matches
  /// the live remote head.
  keptTargetHead?: Head;
  /// Confirmed manifest cache keyed by `(gen, strategy, rootHash)` to avoid re-expanding unchanged manifests.
  manifest?: {
    gen: string;
    strategy: "with-transcripts" | "no-transcripts";
    rootHash: string;
    transcriptFiles: Record<string, number>;
    tfCount: number;
    complete: boolean;
  };
};

/// What bringing a place level found: `behind` where the place holds what this station's own copy does not (this
/// station's data was rolled back: a new generation is begun, and the place keeps both), else how far the place goes
/// now, the files that could not be sent (not on this station any more), and what it holds now.
export type Levelled = { behind: true } | { behind: false; to: number; missing: number; known: Known };

/// Whether what `place` holds of a generation was written by runs this station's own head does not account for.
export function behind(own: Head, held: Held): boolean {
  for (const g of held.gens) {
    const h = g.head;
    if (h === null || h.origin !== own.origin) continue;
    if (g.gen !== own.gen) {
      // (a generation begun after this station's own: written by this station before it was rolled back)
      if (genMade(g.gen) > genMade(own.gen)) return true;
      continue;
    }
    const last = h.runs[h.runs.length - 1];
    if (last === undefined) continue;
    const i = own.runs.findIndex((r) => r.run === last.run);
    if (i < 0) {
      // (a run this station does not know: one rolled back, unless it is one so far back that its head let it go)
      if (h.to > 0 && !(own.runs.length > 0 && h.to < own.runs[0]!.from)) return true;
      continue;
    }
    const end = i + 1 < own.runs.length ? own.runs[i + 1]!.from - 1 : own.to;
    if (h.to > end) return true;
  }
  return false;
}

/// `head` naming only the transcripts `held` (`partial`): what a place holds once the chats are sent and before the
/// transcripts are, a whole copy for a restorer as far as it goes. Always inline (never points at an unverified manifest).
function partialHead(head: Head, held: Set<string>, resolvedTf?: Record<string, number>): Head {
  const transcriptFiles: Record<string, number> = {};
  const tf = resolvedTf ?? head.transcriptFiles;
  if (tf !== undefined) {
    for (const h in tf) {
      if (Object.hasOwn(tf, h) && (held.has(h) || Object.hasOwn(head.files, h))) transcriptFiles[h] = tf[h]!;
    }
  }
  const { transcriptManifest: _, ...rest } = head;
  return { ...rest, transcriptFiles, partial: true };
}

/// Brings `place` level with this station's own copy of `ws`: its batches and the chats' files first, a partial head
/// while transcripts are lacking (`partialHead`), the transcripts, its head, then what is not named any more goes.
/// `known`: what the place held after it was levelled last (null: asked of it now). `onPartial`: told as the partial
/// head is put, how far it goes and how many transcripts are still to send.
export async function level(
  place: Place,
  ws: string,
  own: Own,
  known: Known | null = null,
  opts: { includeTranscripts?: boolean; onPartial?: (to: number, lacking: number) => void; dropFilesPage?: number; onPruneError?: (err: unknown) => void } = {},
): Promise<Levelled> {
  const includeTranscripts = opts.includeTranscripts !== false;
  const strategy = includeTranscripts ? "with-transcripts" : "no-transcripts";
  const origin = own.head.origin;
  let k = known;
  let initialHoldingHead: Head | null = null;
  let initialReadPlace: ReadPlaceObject | undefined;
  if (k === null || k.gen !== own.head.gen) {
    const held = await place.held(ws, origin);
    if (behind(own.head, held)) return { behind: true };
    const holding = held.gens.find((g) => g.gen === own.head.gen);
    initialHoldingHead = holding?.head ?? null;
    const others = new Set<string>();
    const unverifiedGens = new Set<string>(held.unverifiedGens ?? []);
    let hasUnverifiedHead = held.hasUnverifiedHead === true || unverifiedGens.size > 0;
    const readPlace = placeObjectReader(place, ws, origin);
    initialReadPlace = readPlace;
    for (const g of held.gens) {
      if (g.gen === own.head.gen) continue;
      if (g.head === null) {
        hasUnverifiedHead = true;
        unverifiedGens.add(g.gen);
        continue;
      }
      for (const h in g.head.files) if (Object.hasOwn(g.head.files, h)) others.add(h);
      if (g.head.transcriptFiles !== undefined) {
        for (const h in g.head.transcriptFiles) if (Object.hasOwn(g.head.transcriptFiles, h)) others.add(h);
      }
      if (g.head.transcriptManifest !== undefined) {
        if (readPlace !== undefined) {
          try {
            const resolved = await loadTranscriptManifest(g.head.transcriptManifest, readPlace);
            for (const h of manifestAllRefs(resolved)) others.add(h);
          } catch {
            others.add(g.head.transcriptManifest);
            hasUnverifiedHead = true;
            unverifiedGens.add(g.gen);
          }
        } else {
          others.add(g.head.transcriptManifest);
          hasUnverifiedHead = true;
          unverifiedGens.add(g.gen);
        }
      }
    }
    k = {
      gen: own.head.gen,
      batches: new Set(holding?.batches ?? []),
      files: new Set(held.files),
      others,
      ...(hasUnverifiedHead ? { hasUnverifiedHead: true } : {}),
      ...(unverifiedGens.size > 0 ? { unverifiedGens } : {}),
      to: holding?.head?.to ?? -1,
      made: holding?.head?.partial === true ? -1 : (holding?.head?.made ?? -1),
    };
  }
  for (const b of own.head.batches) {
    if (k.batches.has(b)) continue;
    await place.put(ws, origin, own.head.gen, "batch", b, await own.batch(b));
    k.batches.add(b);
  }
  const ownFiles = own.head.files;
  let resolvedTf: Record<string, number> | undefined;
  let tfCount = 0;
  let manifestCacheHit = false;
  if (own.head.transcriptManifest !== undefined) {
    const cached = k.manifest;
    if (
      cached !== undefined &&
      cached.gen === own.head.gen &&
      cached.strategy === strategy &&
      cached.rootHash === own.head.transcriptManifest
    ) {
      resolvedTf = cached.transcriptFiles;
      tfCount = cached.tfCount;
      manifestCacheHit = cached.complete;
    } else {
      if (own.loadTranscriptFiles !== undefined) {
        resolvedTf = await own.loadTranscriptFiles();
      } else if (own.head.transcriptFiles !== undefined) {
        resolvedTf = own.head.transcriptFiles;
      } else {
        throw new Error("own.loadTranscriptFiles is required to resolve compact transcriptManifest");
      }
      for (const h in resolvedTf) if (Object.hasOwn(resolvedTf, h)) tfCount++;
    }
  } else {
    resolvedTf = own.head.transcriptFiles;
    if (resolvedTf !== undefined) {
      for (const h in resolvedTf) if (Object.hasOwn(resolvedTf, h)) tfCount++;
    }
  }
  const ownTf = includeTranscripts ? resolvedTf : undefined;
  // (the chats' own files first, then the transcripts: a transcript a file also names is the chat's)
  const lackingChat: string[] = [];
  const lackingTranscripts: string[] = [];
  let wantedCount = 0;
  let chatOverlapWithTf = 0;
  for (const h in ownFiles) {
    if (!Object.hasOwn(ownFiles, h)) continue;
    wantedCount++;
    if (ownTf !== undefined && Object.hasOwn(ownTf, h)) chatOverlapWithTf++;
    if (!k.files.has(h)) lackingChat.push(h);
  }
  if (ownTf !== undefined) {
    if (manifestCacheHit) {
      wantedCount += tfCount - chatOverlapWithTf;
    } else {
      for (const h in ownTf) {
        if (!Object.hasOwn(ownTf, h) || Object.hasOwn(ownFiles, h)) continue;
        wantedCount++;
        if (!k.files.has(h)) lackingTranscripts.push(h);
      }
    }
  }
  const lackingCount = lackingChat.length + lackingTranscripts.length;
  const sources = lackingCount === 0
    ? new Map<string, string>()
    : await own.sources(lackingTranscripts.length === 0 ? lackingChat : lackingChat.length === 0 ? lackingTranscripts : [...lackingChat, ...lackingTranscripts]);
  let sendableTranscripts = 0;
  for (const h of lackingTranscripts) if (sources.has(h)) sendableTranscripts++;
  let missing = 0;
  let missingTranscripts = 0;
  const send = async (hash: string, isTranscript: boolean): Promise<void> => {
    const source = sources.get(hash);
    if (source === undefined) {
      missing++;
      if (isTranscript) missingTranscripts++;
      return;
    }
    try {
      await place.putFile(ws, origin, hash, source);
    } catch (e) {
      const enoent = (e as { code?: unknown } | null)?.code === "ENOENT" || (e instanceof Error && e.message.startsWith("ENOENT:"));
      if (enoent && !isTranscript) {
        missing++;
        return;
      }
      throw e;
    }
    k.files.add(hash);
  };
  for (const hash of lackingChat) await send(hash, ownTf !== undefined && Object.hasOwn(ownTf, hash));
  // The chats as far as they go now, before the transcripts still to send: a first copy of a station's transcripts is
  // hundreds of thousands of files, and its chats waited behind them for a day (2026-11-23). This head names only the
  // transcripts the place holds, and says it is partial, so that the whole one is put after them.
  if (sendableTranscripts > 0 && k.to !== own.head.to) {
    const partial = partialHead(own.head, k.files, resolvedTf);
    await place.put(ws, origin, own.head.gen, "head", "head.json", Buffer.from(JSON.stringify(partial, null, 1)), partial);
    k.to = own.head.to;
    k.made = -1;
    k.keptTargetFiles = undefined;
    k.keptTargetHead = undefined;
    opts.onPartial?.(own.head.to, sendableTranscripts);
  }
  for (const hash of lackingTranscripts) await send(hash, true);
  // D72a invariant: outgoing wire `put("head")` continues to carry inline `transcriptFiles` (never switches wire to
  // `transcriptManifest`) so any rollback to an older station never misinterprets the head.
  let wireHead: Head = own.head;
  if (own.head.transcriptManifest !== undefined) {
    const { transcriptManifest: _, ...rest } = own.head;
    wireHead = resolvedTf !== undefined && tfCount > 0 ? { ...rest, transcriptFiles: resolvedTf } : rest;
  }
  const selfUnverified = k.unverifiedGens?.has(own.head.gen) === true;
  let preserveTargetHead = false;
  if (initialHoldingHead !== null && initialHoldingHead.to === own.head.to && !selfUnverified) {
    const sameCore = sameBatches(own.head.batches, initialHoldingHead.batches) && sameFileMap(own.head.files, initialHoldingHead.files);
    const ownAllTf = own.head.transcriptManifest !== undefined
      ? { ...(own.head.transcriptFiles ?? {}), ...(resolvedTf ?? {}) }
      : (resolvedTf ?? {});
    let targetTf: Record<string, number> | null = null;
    let targetManifestMeta: string[] | undefined;
    if (initialHoldingHead.transcriptManifest !== undefined) {
      if (initialReadPlace !== undefined) {
        try {
          const resolvedTarget = await loadTranscriptManifest(initialHoldingHead.transcriptManifest, initialReadPlace);
          targetTf = { ...(initialHoldingHead.transcriptFiles ?? {}), ...resolvedTarget.files };
          targetManifestMeta = [resolvedTarget.rootHash, ...resolvedTarget.leafHashes];
        } catch {
          targetTf = null;
        }
      }
    } else {
      targetTf = initialHoldingHead.transcriptFiles ?? {};
    }
    if (initialHoldingHead.partial !== true) {
      const covered = sameCore && targetTf !== null && isSubsetFileMap(ownAllTf, targetTf);
      if (!covered) {
        throw new Error("head conflict: existing same-to full head does not cover incoming head");
      }
      preserveTargetHead = true;
      k.to = own.head.to;
      k.made = own.head.made;
      const kept = new Set<string>();
      for (const h in initialHoldingHead.files) if (Object.hasOwn(initialHoldingHead.files, h)) kept.add(h);
      if (targetManifestMeta !== undefined) {
        for (const h of targetManifestMeta) kept.add(h);
      }
      for (const h in targetTf) {
        if (Object.hasOwn(targetTf, h) && (includeTranscripts || !Object.hasOwn(ownAllTf, h))) kept.add(h);
      }
      k.keptTargetFiles = kept;
      k.keptTargetHead = initialHoldingHead;
    } else {
      const coversPartial = sameCore && targetTf !== null && isSubsetFileMap(targetTf, ownAllTf);
      if (!coversPartial) {
        throw new Error("head conflict: incoming head does not cover existing same-to partial head");
      }
    }
  }
  if (!preserveTargetHead && (k.to !== own.head.to || k.made !== own.head.made || selfUnverified)) {
    await place.put(ws, origin, own.head.gen, "head", "head.json", Buffer.from(JSON.stringify(wireHead, null, 1)), wireHead);
    k.to = own.head.to;
    k.made = own.head.made;
    k.keptTargetFiles = undefined;
    k.keptTargetHead = undefined;
    if (k.unverifiedGens !== undefined) {
      k.unverifiedGens.delete(own.head.gen);
      if (k.unverifiedGens.size === 0) {
        k.unverifiedGens = undefined;
        k.hasUnverifiedHead = false;
      }
    }
  }
  if (own.head.transcriptManifest !== undefined && resolvedTf !== undefined) {
    k.manifest = {
      gen: own.head.gen,
      strategy,
      rootHash: own.head.transcriptManifest,
      transcriptFiles: resolvedTf,
      tfCount,
      complete: !includeTranscripts || missingTranscripts === 0,
    };
  } else {
    k.manifest = undefined;
  }
  const oldBatches = [...k.batches].filter((b) => !own.head.batches.includes(b));
  const oldFiles: string[] = [];
  if (!k.hasUnverifiedHead && k.files.size > wantedCount - missing) {
    for (const f of k.files) {
      if (
        !Object.hasOwn(ownFiles, f) &&
        !(ownTf !== undefined && Object.hasOwn(ownTf, f)) &&
        !k.others.has(f) &&
        !(k.keptTargetFiles?.has(f) === true)
      ) {
        oldFiles.push(f);
      }
    }
  }
  const dropPage = opts.dropFilesPage !== undefined && opts.dropFilesPage > 0 ? opts.dropFilesPage : DROP_FILES_PAGE;
  const dropOpts = !includeTranscripts ? { allowCurrentGenTranscripts: true } : undefined;
  if (oldBatches.length > 0 || oldFiles.length > 0) {
    if (oldFiles.length === 0) {
      await place.drop(ws, origin, own.head.gen, oldBatches, [], dropOpts);
      for (const b of oldBatches) k.batches.delete(b);
    } else {
      for (let i = 0; i < oldFiles.length; i += dropPage) {
        const page = oldFiles.slice(i, i + dropPage);
        await place.drop(ws, origin, own.head.gen, i === 0 ? oldBatches : [], page, dropOpts);
        if (i === 0) {
          for (const b of oldBatches) k.batches.delete(b);
        }
        for (const f of page) k.files.delete(f);
      }
    }
  }
  if (!k.hasUnverifiedHead) {
    try {
      await place.pruneOrphans?.(ws, origin, k.keptTargetHead ?? wireHead);
    } catch (err) {
      // best-effort: head and drop already succeeded; retain remaining orphans for next sync
      opts.onPruneError?.(err);
    }
  }
  return { behind: false, to: own.head.to, missing, known: k };
}

function sameBatches(a: readonly string[], b: readonly string[]): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

function sameFileMap(a: Record<string, number> | undefined, b: Record<string, number> | undefined): boolean {
  let countA = 0;
  if (a !== undefined) {
    for (const k in a) {
      if (!Object.hasOwn(a, k)) continue;
      countA++;
      if (b === undefined || !Object.hasOwn(b, k) || b[k] !== a[k]) return false;
    }
  }
  let countB = 0;
  if (b !== undefined) {
    for (const k in b) if (Object.hasOwn(b, k)) countB++;
  }
  return countA === countB;
}

function hasAllBatches(present: readonly string[], needed: readonly string[]): boolean {
  if (needed.length === 0) return true;
  const set = new Set(present);
  for (const b of needed) if (!set.has(b)) return false;
  return true;
}

function isSubsetFileMap(sub: Record<string, number> | undefined, sup: Record<string, number> | undefined): boolean {
  if (sub === undefined) return true;
  for (const k in sub) {
    if (!Object.hasOwn(sub, k)) continue;
    if (sup === undefined || !Object.hasOwn(sup, k) || sup[k] !== sub[k]) return false;
  }
  return true;
}

type ReadPlaceObject = (hash: string, maxBytes: number) => Promise<Uint8Array | null>;

function placeObjectReader(place: Place, ws: string, origin: string): ReadPlaceObject | undefined {
  if (place instanceof FolderPlace) {
    return (hash, maxBytes) => place.readBounded(ws, origin, null, hash, maxBytes);
  }
  const maybeRead = (place as { read?: (ws: string, origin: string, gen: string | null, name: string) => Promise<AsyncIterable<Buffer>> }).read;
  if (typeof maybeRead === "function") {
    return async (hash, maxBytes) => {
      let stream: AsyncIterable<Buffer>;
      try {
        stream = await maybeRead.call(place, ws, origin, null, hash);
      } catch (e) {
        const status = (e as { status?: unknown } | null)?.status;
        if (isMissingFsError(e) || status === 404 || (e instanceof Error && /not kept here|not found|enoent/i.test(e.message))) {
          return null;
        }
        throw e;
      }
      return readStreamBounded(stream, maxBytes);
    };
  }
  return undefined;
}

/// Checks whether two heads are logically equivalent (same `gen`, `to`, `partial`, `batches`, `files`, and expanded
/// transcript file map — even when one carries inline `transcriptFiles` and the other carries `transcriptManifest`).
export async function headsLogicallyEqual(
  a: Head,
  b: Head,
  readA?: ReadPlaceObject,
  readB?: ReadPlaceObject,
): Promise<boolean> {
  if (a.gen !== b.gen || a.to !== b.to || (a.partial === true) !== (b.partial === true)) return false;
  if (!sameBatches(a.batches, b.batches) || !sameFileMap(a.files, b.files)) return false;
  const tfA = a.transcriptManifest !== undefined
    ? (readA !== undefined ? (await loadTranscriptManifest(a.transcriptManifest, readA)).files : null)
    : (a.transcriptFiles ?? {});
  const tfB = b.transcriptManifest !== undefined
    ? (readB !== undefined ? (await loadTranscriptManifest(b.transcriptManifest, readB)).files : null)
    : (b.transcriptFiles ?? {});
  if (tfA === null || tfB === null) return a.transcriptManifest !== undefined && a.transcriptManifest === b.transcriptManifest;
  return sameFileMap(tfA, tfB);
}

/// Brings `to` level with what `from` holds of another station's copies (a station that holds them and is not one of
/// those that should, handing them over): every generation, nothing dropped. Whether `to` holds all of it now.
export async function handOver(from: FolderPlace, to: Place, ws: string, origin: string): Promise<boolean> {
  let mine: Held;
  try {
    mine = await from.heldStrict(ws, origin);
  } catch {
    return false;
  }
  if (mine.hasUnverifiedHead === true) return false;
  const theirs = await to.held(ws, origin);
  const readMine: ReadPlaceObject = (hash, maxBytes) => from.readBounded(ws, origin, null, hash, maxBytes);
  const readTheirs = placeObjectReader(to, ws, origin);
  const files = new Set(theirs.files);
  for (const hash of mine.files) {
    if (files.has(hash)) continue;
    const path = await from.pathOf(ws, origin, null, hash);
    if (path !== null) await to.putFile(ws, origin, hash, path);
  }
  for (const g of mine.gens) {
    if (g.head === null) {
      // Unfinished generation with on-disk batches but no published head.json: never approve source deletion.
      if (g.batches.length > 0) return false;
      continue;
    }
    const t = theirs.gens.find((x) => x.gen === g.gen);
    // 1. Always upload any batch files from `g.head.batches` missing on disk at `to`.
    const has = new Set(t?.batches ?? []);
    for (const b of g.head.batches) {
      if (has.has(b)) continue;
      const bytes = await from.read(ws, origin, g.gen, b);
      if (bytes !== null) await to.put(ws, origin, g.gen, "batch", b, bytes);
    }
    // 2. Decide whether to put head independently from batch upload:
    //    NEVER call `to.put("head")` when `to` already holds a full head at `t.head.to >= g.head.to`
    //    (prevents overwriting a conflicting same-to full head on older peers); and when upgrading a
    //    same-to partial head to full, only overwrite when `g.head` strictly covers `t.head` (`mineTf ⊇ theirsTf`).
    const theirsFull = t?.head != null && t.head.partial !== true;
    const mineFull = g.head.partial !== true;
    let resolvedMineTf: Record<string, number> | undefined;
    const getMineTf = async (): Promise<Record<string, number>> => {
      if (resolvedMineTf !== undefined) return resolvedMineTf;
      if (g.head!.transcriptManifest !== undefined) {
        const resolved = await loadTranscriptManifest(g.head!.transcriptManifest, readMine);
        resolvedMineTf = { ...(g.head!.transcriptFiles ?? {}), ...resolved.files };
      } else {
        resolvedMineTf = g.head!.transcriptFiles ?? {};
      }
      return resolvedMineTf;
    };
    let shouldPutHead = t?.head == null || t.head.to < g.head.to;
    if (!shouldPutHead && t?.head != null && t.head.to === g.head.to && !theirsFull && mineFull) {
      if (sameBatches(g.head.batches, t.head.batches) && sameFileMap(g.head.files, t.head.files)) {
        shouldPutHead = await (async () => {
          const mineTf = await getMineTf();
          let theirsTf: Record<string, number>;
          if (t.head!.transcriptManifest !== undefined) {
            if (readTheirs === undefined) return false;
            const resolvedTheirs = await loadTranscriptManifest(t.head!.transcriptManifest, readTheirs);
            theirsTf = { ...(t.head!.transcriptFiles ?? {}), ...resolvedTheirs.files };
          } else {
            theirsTf = t.head!.transcriptFiles ?? {};
          }
          return isSubsetFileMap(theirsTf, mineTf);
        })().catch(() => false);
      }
    }
    if (!shouldPutHead) continue;
    // D72a invariant: outgoing wire `put("head")` always sends inline `transcriptFiles` (never `transcriptManifest`),
    // taking the union of inline `transcriptFiles` and `transcriptManifest` for dual-field source heads.
    let wireHead: Head = g.head;
    if (g.head.transcriptManifest !== undefined) {
      const tf = await getMineTf();
      const { transcriptManifest: _, ...rest } = g.head;
      let hasTf = false;
      for (const _ in tf) {
        hasTf = true;
        break;
      }
      wireHead = hasTf ? { ...rest, transcriptFiles: tf } : rest;
    }
    try {
      await to.put(ws, origin, g.gen, "head", "head.json", Buffer.from(JSON.stringify(wireHead, null, 1)), wireHead);
    } catch (e) {
      if (e instanceof Error && e.message.includes("head conflict:")) return false;
      throw e;
    }
  }
  return holdsAllLogical(mine, await to.held(ws, origin), { readMine, readTheirs });
}

/// Synchronous check whether `theirs` holds as much as `mine` for inline heads (strictly refuses `partial` for full).
export function holdsAll(mine: Held, theirs: Held): boolean {
  const files = new Set(theirs.files);
  if (mine.files.some((f) => !files.has(f))) return false;
  return mine.gens.every((g) => {
    if (g.head === null) return g.batches.length === 0;
    const t = theirs.gens.find((x) => x.gen === g.gen);
    if (t?.head == null) return false;
    if (!hasAllBatches(t.batches, g.head.batches) || !hasAllBatches(t.batches, t.head.batches)) return false;
    if (g.head.partial !== true && t.head.partial === true) return false;
    if (t.head.to < g.head.to) return false;
    if (t.head.to > g.head.to) return true;
    if (!sameBatches(g.head.batches, t.head.batches) || !sameFileMap(g.head.files, t.head.files)) return false;
    if (g.head.transcriptManifest !== undefined || t.head.transcriptManifest !== undefined) {
      return (
        g.head.transcriptManifest !== undefined &&
        g.head.transcriptManifest === t.head.transcriptManifest &&
        isSubsetFileMap(g.head.transcriptFiles, t.head.transcriptFiles)
      );
    }
    if (!isSubsetFileMap(g.head.transcriptFiles, t.head.transcriptFiles)) return false;
    return true;
  });
}

/// Async logical check whether `theirs` holds as much as `mine`: strictly distinguishes `partial` vs full heads,
/// verifies actual on-disk batch files in `Holding.batches`, and compares expanded transcript maps so inline
/// `transcriptFiles` and `transcriptManifest` representations are equivalent.
export async function holdsAllLogical(
  mine: Held,
  theirs: Held,
  opts: { readMine?: ReadPlaceObject; readTheirs?: ReadPlaceObject } = {},
): Promise<boolean> {
  if (mine.hasUnverifiedHead === true) return false;
  const theirsFiles = new Set(theirs.files);
  const mineManifestMeta = new Set<string>();
  for (const g of mine.gens) {
    if (g.head === null) {
      if (g.batches.length > 0) return false;
      continue;
    }
    const t = theirs.gens.find((x) => x.gen === g.gen);
    if (t?.head == null) return false;
    if (!hasAllBatches(t.batches, g.head.batches) || !hasAllBatches(t.batches, t.head.batches)) return false;
    if (g.head.partial !== true && t.head.partial === true) return false;
    if (t.head.to < g.head.to) return false;
    let mineTf: Record<string, number>;
    if (g.head.transcriptManifest !== undefined) {
      if (opts.readMine === undefined) return false;
      let resolved: ResolvedManifest;
      try {
        resolved = await loadTranscriptManifest(g.head.transcriptManifest, opts.readMine);
      } catch {
        return false;
      }
      mineManifestMeta.add(resolved.rootHash);
      for (const lh of resolved.leafHashes) mineManifestMeta.add(lh);
      mineTf = { ...(g.head.transcriptFiles ?? {}), ...resolved.files };
    } else {
      mineTf = g.head.transcriptFiles ?? {};
    }
    if (t.head.to > g.head.to) {
      if (t.head.transcriptManifest !== undefined && opts.readTheirs !== undefined) {
        try {
          await loadTranscriptManifest(t.head.transcriptManifest, opts.readTheirs);
        } catch {
          return false;
        }
      }
      continue;
    }
    if (t.head.to === g.head.to) {
      if (!sameBatches(g.head.batches, t.head.batches) || !sameFileMap(g.head.files, t.head.files)) return false;
      let theirsTf: Record<string, number>;
      if (t.head.transcriptManifest !== undefined) {
        if (opts.readTheirs === undefined) return false;
        try {
          const resolvedTheirs = await loadTranscriptManifest(t.head.transcriptManifest, opts.readTheirs);
          theirsTf = { ...(t.head.transcriptFiles ?? {}), ...resolvedTheirs.files };
        } catch {
          return false;
        }
      } else {
        theirsTf = t.head.transcriptFiles ?? {};
      }
      if (!isSubsetFileMap(mineTf, theirsTf)) return false;
    }
  }
  for (const f of mine.files) {
    if (mineManifestMeta.has(f)) continue;
    if (!theirsFiles.has(f)) return false;
  }
  return true;
}
