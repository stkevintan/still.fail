// Two-level 256-bucket canonical pure JSON manifest for replica transcript chunks.
//
// Root manifest (`<rootHash>` = SHA-256 of canonical UTF-8 bytes, no whitespace):
//   {"v":1,"buckets":{"00":"<leafHash>",...}}
//   - "buckets" keys are 2-char lowercase hex ("00".."ff") in ascending order; empty buckets omitted.
//   - Values are 64-char lowercase hex SHA-256 of each bucket leaf's canonical UTF-8 bytes.
//
// Bucket leaf (`<leafHash>`):
//   {"v":1,"files":{"<chunkHash>":<compSize>,...}}
//   - "files" keys are 64-char lowercase hex in ascending order, each starting with its bucket prefix.
//   - Values are non-negative safe integers (`compSize`).
import { createHash } from "node:crypto";
import { open, readFile, stat } from "node:fs/promises";
import { join } from "node:path";
import { type Head, asHead, isHex64 } from "./format.ts";

export const MANIFEST_VERSION = 1;
export const MANIFEST_MAX_BYTES = 64 * 1024 * 1024;
export const MANIFEST_MAX_ENTRIES = 500_000;
export const MANIFEST_MAX_BUCKETS = 256;
export const MANIFEST_GC_GRACE_MS = 10 * 60 * 1000;

const MAX_SAFE_BIGINT = BigInt(Number.MAX_SAFE_INTEGER);
const BOUNDED_READ_CHUNK = 64 * 1024;

export type EncodedManifest = {
  rootHash: string;
  rootBytes: Buffer;
  buckets: Record<string, string>;
  leaves: Map<string, { bucket: string; bytes: Buffer }>;
};

export type ParsedRootManifest = {
  v: 1;
  buckets: Record<string, string>;
};

export type ParsedLeafManifest = {
  v: 1;
  files: Record<string, number>;
};

export type ManifestBudget = {
  bytes: number;
  entries: number;
};

export type ResolvedManifest = {
  rootHash: string;
  buckets: Record<string, string>;
  leafHashes: string[];
  files: Record<string, number>;
  totalBytes: number;
  totalEntries: number;
};

export function isHex2(s: string): boolean {
  if (s.length !== 2) return false;
  for (let i = 0; i < 2; i++) {
    const c = s.charCodeAt(i);
    if (!((c >= 48 && c <= 57) || (c >= 97 && c <= 102))) return false;
  }
  return true;
}

function sha256Hex(bytes: Uint8Array): string {
  return createHash("sha256").update(bytes).digest("hex");
}

function isNonNegSafeInt(v: unknown): v is number {
  return typeof v === "number" && Number.isSafeInteger(v) && v >= 0 && !Object.is(v, -0);
}

const utf8Fatal = new TextDecoder("utf-8", { fatal: true });

/// Strict RFC 8259 JSON parser for manifests that rejects duplicate object keys (even via `\uXXXX` escapes),
/// non-integer / negative / `-0` / scientific / out-of-safe-range numbers, trailing tokens, excessive nesting,
/// and enforces entry count caps during parsing before materializing oversized objects.
class StrictJsonParser {
  readonly #s: string;
  readonly #maxDepth1Entries: number;
  readonly #depth1LimitError: string;
  #at = 0;
  #depth1Entries = 0;

  constructor(s: string, maxDepth1Entries: number, depth1LimitError: string) {
    this.#s = s;
    this.#maxDepth1Entries = maxDepth1Entries;
    this.#depth1LimitError = depth1LimitError;
  }

  parse(): unknown {
    this.#skip();
    const val = this.#value(0);
    this.#skip();
    if (this.#at !== this.#s.length) throw new Error(`unexpected trailing token at ${this.#at}`);
    return val;
  }

  #skip(): void {
    const s = this.#s;
    const n = s.length;
    while (this.#at < n) {
      const c = s.charCodeAt(this.#at);
      if (c === 0x20 || c === 0x09 || c === 0x0a || c === 0x0d) this.#at++;
      else break;
    }
  }

  #value(depth: number): unknown {
    if (depth > 2) throw new Error("manifest JSON nesting too deep");
    this.#skip();
    if (this.#at >= this.#s.length) throw new Error("unexpected end of JSON");
    const c = this.#s.charCodeAt(this.#at);
    if (c === 0x7b) {
      if (depth >= 2) throw new Error("manifest JSON nesting too deep");
      return this.#object(depth);
    }
    if (c === 0x22) return this.#string();
    if (c >= 0x30 && c <= 0x39) return this.#number();
    throw new Error(`unexpected token in manifest JSON at ${this.#at}`);
  }

  #object(depth: number): Record<string, unknown> {
    this.#at++; // '{'
    const out: Record<string, unknown> = Object.create(null);
    this.#skip();
    if (this.#at < this.#s.length && this.#s.charCodeAt(this.#at) === 0x7d) {
      this.#at++;
      return out;
    }
    let count = 0;
    for (;;) {
      this.#skip();
      if (this.#at >= this.#s.length || this.#s.charCodeAt(this.#at) !== 0x22) {
        throw new Error(`expected string key at ${this.#at}`);
      }
      const key = this.#string();
      if (Object.hasOwn(out, key)) throw new Error(`duplicate JSON key: ${key}`);
      count++;
      if (depth === 0 && count > 2) {
        throw new Error("manifest JSON top-level object has too many keys");
      }
      if (depth === 1 && ++this.#depth1Entries > this.#maxDepth1Entries) {
        throw new Error(this.#depth1LimitError);
      }
      this.#skip();
      if (this.#at >= this.#s.length || this.#s.charCodeAt(this.#at) !== 0x3a) {
        throw new Error(`expected ':' at ${this.#at}`);
      }
      this.#at++;
      out[key] = this.#value(depth + 1);
      this.#skip();
      if (this.#at >= this.#s.length) throw new Error("unterminated JSON object");
      const next = this.#s.charCodeAt(this.#at);
      if (next === 0x2c) {
        this.#at++;
        continue;
      }
      if (next === 0x7d) {
        this.#at++;
        return out;
      }
      throw new Error(`expected ',' or '}' at ${this.#at}`);
    }
  }

  #string(): string {
    const s = this.#s;
    const n = s.length;
    this.#at++; // '"'
    const start = this.#at;
    let hasEscape = false;
    while (this.#at < n) {
      const c = s.charCodeAt(this.#at);
      if (c === 0x22) {
        const res = hasEscape ? JSON.parse(s.slice(start - 1, this.#at + 1)) as string : s.slice(start, this.#at);
        this.#at++;
        return res;
      }
      if (c < 0x20) throw new Error(`unescaped control char in string at ${this.#at}`);
      if (c === 0x5c) {
        hasEscape = true;
        this.#at += 2;
      } else {
        this.#at++;
      }
    }
    throw new Error("unterminated JSON string");
  }

  /// Accepts only strict non-negative decimal integers (`0` or `[1-9][0-9]*`) within `[0, Number.MAX_SAFE_INTEGER]`.
  #number(): number {
    const s = this.#s;
    const n = s.length;
    const start = this.#at;
    const first = s.charCodeAt(this.#at);
    if (first === 0x30) {
      this.#at++;
      if (this.#at < n) {
        const next = s.charCodeAt(this.#at);
        if ((next >= 0x30 && next <= 0x39) || next === 0x2e || next === 0x65 || next === 0x45) {
          throw new Error(`invalid integer in manifest at ${start}`);
        }
      }
      return 0;
    }
    if (first >= 0x31 && first <= 0x39) {
      while (this.#at < n && s.charCodeAt(this.#at) >= 0x30 && s.charCodeAt(this.#at) <= 0x39) this.#at++;
      if (this.#at < n) {
        const next = s.charCodeAt(this.#at);
        if (next === 0x2e || next === 0x65 || next === 0x45) {
          throw new Error(`invalid integer in manifest at ${start}`);
        }
      }
      const raw = s.slice(start, this.#at);
      if (raw.length > 16) throw new Error(`integer out of safe range: ${raw}`);
      const bi = BigInt(raw);
      if (bi > MAX_SAFE_BIGINT) throw new Error(`integer out of safe range: ${raw}`);
      return Number(bi);
    }
    throw new Error(`invalid integer in manifest at ${start}`);
  }
}

function parseStrictJsonObject(
  bytes: Uint8Array,
  maxDepth1Entries: number,
  depth1LimitError: string,
): Record<string, unknown> {
  const text = utf8Fatal.decode(bytes);
  const parsed = new StrictJsonParser(text, maxDepth1Entries, depth1LimitError).parse();
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("manifest JSON must be an object");
  }
  return parsed as Record<string, unknown>;
}

/// Encodes `files` (`chunkHash -> compSize`) into a canonical 2-level 256-bucket manifest.
export function encodeTranscriptManifest(files: Record<string, number>): EncodedManifest {
  const grouped = new Map<string, [string, number][]>();
  let totalEntries = 0;
  for (const hash in files) {
    if (!Object.hasOwn(files, hash)) continue;
    if (!isHex64(hash)) throw new Error(`invalid transcript chunk hash: ${hash}`);
    const size = files[hash]!;
    if (!isNonNegSafeInt(size)) throw new Error(`invalid transcript chunk size for ${hash}: ${size}`);
    totalEntries++;
    if (totalEntries > MANIFEST_MAX_ENTRIES) {
      throw new Error(`transcript manifest exceeds max entries (${MANIFEST_MAX_ENTRIES})`);
    }
    const bucket = hash.slice(0, 2);
    let list = grouped.get(bucket);
    if (list === undefined) grouped.set(bucket, (list = []));
    list.push([hash, size]);
  }

  const bucketKeys = [...grouped.keys()].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  const buckets: Record<string, string> = {};
  const leaves = new Map<string, { bucket: string; bytes: Buffer }>();
  let totalBytes = 0;

  for (const bucket of bucketKeys) {
    const list = grouped.get(bucket)!;
    list.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
    const parts = new Array<string>(list.length);
    for (let i = 0; i < list.length; i++) {
      const [h, sz] = list[i]!;
      parts[i] = `"${h}":${sz}`;
    }
    const leafJson = `{"v":1,"files":{${parts.join(",")}}}`;
    const leafBytes = Buffer.from(leafJson, "utf8");
    totalBytes += leafBytes.length;
    if (totalBytes > MANIFEST_MAX_BYTES) {
      throw new Error(`transcript manifest exceeds max bytes (${MANIFEST_MAX_BYTES})`);
    }
    const leafHash = sha256Hex(leafBytes);
    buckets[bucket] = leafHash;
    leaves.set(leafHash, { bucket, bytes: leafBytes });
  }

  const rootParts = bucketKeys.map((b) => `"${b}":"${buckets[b]}"`);
  const rootJson = `{"v":1,"buckets":{${rootParts.join(",")}}}`;
  const rootBytes = Buffer.from(rootJson, "utf8");
  totalBytes += rootBytes.length;
  if (totalBytes > MANIFEST_MAX_BYTES) {
    throw new Error(`transcript manifest exceeds max bytes (${MANIFEST_MAX_BYTES})`);
  }
  const rootHash = sha256Hex(rootBytes);
  return { rootHash, rootBytes, buckets, leaves };
}

/// Validates and parses a root manifest object against `expectedHash` and anti-bomb limits.
export function parseRootManifest(bytes: Uint8Array, expectedHash: string, budget?: ManifestBudget): ParsedRootManifest {
  if (!isHex64(expectedHash)) throw new Error(`invalid manifest root hash: ${expectedHash}`);
  const nextBytes = (budget?.bytes ?? 0) + bytes.byteLength;
  if (nextBytes > MANIFEST_MAX_BYTES) {
    throw new Error(`transcript manifest exceeds max bytes (${MANIFEST_MAX_BYTES})`);
  }
  if (budget !== undefined) budget.bytes = nextBytes;
  const actual = sha256Hex(bytes);
  if (actual !== expectedHash) {
    throw new Error(`manifest root hash mismatch: expected ${expectedHash}, got ${actual}`);
  }
  const obj = parseStrictJsonObject(bytes, MANIFEST_MAX_BUCKETS, `manifest root exceeds max buckets (${MANIFEST_MAX_BUCKETS})`);
  const topKeys = Object.keys(obj);
  if (topKeys.length !== 2 || !Object.hasOwn(obj, "v") || !Object.hasOwn(obj, "buckets")) {
    throw new Error("manifest root must have only keys 'v' and 'buckets'");
  }
  if (obj.v !== MANIFEST_VERSION) {
    throw new Error(`unsupported manifest root version: ${String(obj.v)}`);
  }
  const rawBuckets = obj.buckets;
  if (rawBuckets === null || typeof rawBuckets !== "object" || Array.isArray(rawBuckets)) {
    throw new Error("manifest root 'buckets' must be an object");
  }
  const buckets: Record<string, string> = {};
  let bucketCount = 0;
  for (const [b, leafHash] of Object.entries(rawBuckets as Record<string, unknown>)) {
    bucketCount++;
    if (bucketCount > MANIFEST_MAX_BUCKETS) {
      throw new Error(`manifest root exceeds max buckets (${MANIFEST_MAX_BUCKETS})`);
    }
    if (!isHex2(b)) throw new Error(`invalid manifest bucket key: ${b}`);
    if (typeof leafHash !== "string" || !isHex64(leafHash)) {
      throw new Error(`invalid manifest leaf hash for bucket ${b}`);
    }
    buckets[b] = leafHash;
  }
  return { v: 1, buckets };
}

/// Validates and parses a bucket leaf manifest object against `expectedHash`, `expectedBucket`, and anti-bomb limits.
export function parseLeafManifest(
  bytes: Uint8Array,
  expectedHash: string,
  expectedBucket: string,
  budget?: ManifestBudget,
): ParsedLeafManifest {
  if (!isHex64(expectedHash)) throw new Error(`invalid manifest leaf hash: ${expectedHash}`);
  if (!isHex2(expectedBucket)) throw new Error(`invalid manifest bucket: ${expectedBucket}`);
  const nextBytes = (budget?.bytes ?? 0) + bytes.byteLength;
  if (nextBytes > MANIFEST_MAX_BYTES) {
    throw new Error(`transcript manifest exceeds max bytes (${MANIFEST_MAX_BYTES})`);
  }
  if (budget !== undefined) budget.bytes = nextBytes;
  const actual = sha256Hex(bytes);
  if (actual !== expectedHash) {
    throw new Error(`manifest leaf hash mismatch: expected ${expectedHash}, got ${actual}`);
  }
  const remainingEntries = Math.max(0, MANIFEST_MAX_ENTRIES - (budget?.entries ?? 0));
  const obj = parseStrictJsonObject(
    bytes,
    remainingEntries,
    `transcript manifest exceeds max entries (${MANIFEST_MAX_ENTRIES})`,
  );
  const topKeys = Object.keys(obj);
  if (topKeys.length !== 2 || !Object.hasOwn(obj, "v") || !Object.hasOwn(obj, "files")) {
    throw new Error("manifest leaf must have only keys 'v' and 'files'");
  }
  if (obj.v !== MANIFEST_VERSION) {
    throw new Error(`unsupported manifest leaf version: ${String(obj.v)}`);
  }
  const rawFiles = obj.files;
  if (rawFiles === null || typeof rawFiles !== "object" || Array.isArray(rawFiles)) {
    throw new Error("manifest leaf 'files' must be an object");
  }
  const files: Record<string, number> = {};
  let entries = budget?.entries ?? 0;
  for (const [chunkHash, size] of Object.entries(rawFiles as Record<string, unknown>)) {
    entries++;
    if (entries > MANIFEST_MAX_ENTRIES) {
      throw new Error(`transcript manifest exceeds max entries (${MANIFEST_MAX_ENTRIES})`);
    }
    if (!isHex64(chunkHash)) throw new Error(`invalid chunk hash in manifest leaf: ${chunkHash}`);
    if (chunkHash.slice(0, 2) !== expectedBucket) {
      throw new Error(`chunk hash ${chunkHash} does not match bucket ${expectedBucket}`);
    }
    if (!isNonNegSafeInt(size)) {
      throw new Error(`invalid chunk size in manifest leaf for ${chunkHash}: ${String(size)}`);
    }
    files[chunkHash] = size;
  }
  if (budget !== undefined) budget.entries = entries;
  return { v: 1, files };
}

/// Reads a local file strictly up to `maxBytes` (checking `stat.size` first, then reading at most `maxBytes + 1` bytes).
/// Returns `null` on `ENOENT`/`ENOTDIR`; throws immediately if the file exceeds `maxBytes`.
export async function readFileBounded(path: string, maxBytes: number): Promise<Buffer | null> {
  let st;
  try {
    st = await stat(path);
  } catch (e) {
    if (isMissingErr(e)) return null;
    throw e;
  }
  if (st.size > maxBytes) {
    throw new Error(`transcript manifest exceeds max bytes (${MANIFEST_MAX_BYTES})`);
  }
  let fh;
  try {
    fh = await open(path, "r");
  } catch (e) {
    if (isMissingErr(e)) return null;
    throw e;
  }
  try {
    const chunks: Buffer[] = [];
    let total = 0;
    const limit = maxBytes + 1;
    while (total < limit) {
      const want = Math.min(BOUNDED_READ_CHUNK, limit - total);
      const buf = Buffer.allocUnsafe(want);
      const { bytesRead } = await fh.read(buf, 0, want, null);
      if (bytesRead === 0) break;
      total += bytesRead;
      if (total > maxBytes) {
        throw new Error(`transcript manifest exceeds max bytes (${MANIFEST_MAX_BYTES})`);
      }
      chunks.push(bytesRead === want ? buf : buf.subarray(0, bytesRead));
    }
    return chunks.length === 0 ? Buffer.alloc(0) : chunks.length === 1 ? chunks[0]! : Buffer.concat(chunks, total);
  } finally {
    await fh.close();
  }
}

/// Reads an async byte stream up to `maxBytes`, aborting the stream and throwing immediately if exceeded.
export async function readStreamBounded(stream: AsyncIterable<Buffer>, maxBytes: number): Promise<Buffer> {
  const chunks: Buffer[] = [];
  let total = 0;
  for await (const chunk of stream) {
    total += chunk.length;
    if (total > maxBytes) {
      throw new Error(`transcript manifest exceeds max bytes (${MANIFEST_MAX_BYTES})`);
    }
    chunks.push(chunk);
  }
  return chunks.length === 0 ? Buffer.alloc(0) : chunks.length === 1 ? chunks[0]! : Buffer.concat(chunks, total);
}

/// Loads and strictly verifies a full 2-level manifest (root + all bucket leaves).
/// Passes the remaining byte budget `maxBytes` to `readObject` so callers enforce hard byte limits before buffering.
export async function loadTranscriptManifest(
  rootHash: string,
  readObject: (hash: string, maxBytes: number) => Promise<Uint8Array | null>,
): Promise<ResolvedManifest> {
  const budget: ManifestBudget = { bytes: 0, entries: 0 };
  const rootBytes = await readObject(rootHash, MANIFEST_MAX_BYTES);
  if (rootBytes === null) throw new Error(`transcript manifest root ${rootHash} is missing`);
  const root = parseRootManifest(rootBytes, rootHash, budget);
  const files: Record<string, number> = {};
  const leafHashes: string[] = [];
  const bucketKeys = Object.keys(root.buckets).sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  for (const bucket of bucketKeys) {
    const leafHash = root.buckets[bucket]!;
    leafHashes.push(leafHash);
    const remaining = MANIFEST_MAX_BYTES - budget.bytes;
    if (remaining <= 0) {
      throw new Error(`transcript manifest exceeds max bytes (${MANIFEST_MAX_BYTES})`);
    }
    const leafBytes = await readObject(leafHash, remaining);
    if (leafBytes === null) throw new Error(`transcript manifest leaf ${leafHash} (bucket ${bucket}) is missing`);
    const leaf = parseLeafManifest(leafBytes, leafHash, bucket, budget);
    for (const [h, sz] of Object.entries(leaf.files)) {
      files[h] = sz;
    }
  }
  return {
    rootHash,
    buckets: root.buckets,
    leafHashes,
    files,
    totalBytes: budget.bytes,
    totalEntries: budget.entries,
  };
}

function isMissingErr(e: unknown): boolean {
  const code = (e as { code?: unknown } | null)?.code;
  return code === "ENOENT" || code === "ENOTDIR";
}

/// Loads local compact `WorkPassed.heads` transcript files from `<replica>/manifests/`.
/// If a local manifest file is missing, falls back to `<replica>/own/<ws>/<gen>/head.json` ONLY if the
/// recomputed canonical root hash strictly matches `head.transcriptManifest`; otherwise throws.
export async function loadLocalTranscriptFiles(replicaDir: string, head: Head): Promise<Record<string, number>> {
  if (head.transcriptManifest === undefined) {
    return head.transcriptFiles ?? {};
  }
  const manifestsDir = join(replicaDir, "manifests");
  let missingLocal = false;
  try {
    const resolved = await loadTranscriptManifest(head.transcriptManifest, async (hash, maxBytes) => {
      const buf = await readFileBounded(join(manifestsDir, hash), maxBytes);
      if (buf === null) {
        missingLocal = true;
        return null;
      }
      return buf;
    });
    return resolved.files;
  } catch (err) {
    if (!missingLocal) throw err;
  }
  // Fallback: rebuild from own/<ws>/<gen>/head.json ONLY if canonical root hash strictly matches.
  const headPath = join(replicaDir, "own", head.workspace, head.gen, "head.json");
  let diskHead: Head | null = null;
  try {
    diskHead = asHead(JSON.parse(await readFile(headPath, "utf8")));
  } catch {
    diskHead = null;
  }
  if (diskHead === null || diskHead.gen !== head.gen || diskHead.workspace !== head.workspace || diskHead.origin !== head.origin) {
    throw new Error(`local transcript manifest ${head.transcriptManifest} missing and own head.json unreadable`);
  }
  const diskTf = diskHead.transcriptFiles ?? {};
  const recomputed = encodeTranscriptManifest(diskTf);
  if (recomputed.rootHash !== head.transcriptManifest) {
    throw new Error(
      `local transcript manifest ${head.transcriptManifest} missing and own head.json recomputed hash ${recomputed.rootHash} does not match`,
    );
  }
  return diskTf;
}

/// Collects every object hash referenced by `resolved` (root + leaves + chunks).
export function manifestAllRefs(resolved: ResolvedManifest): Set<string> {
  const refs = new Set<string>();
  refs.add(resolved.rootHash);
  for (const h of resolved.leafHashes) refs.add(h);
  for (const h in resolved.files) {
    if (Object.hasOwn(resolved.files, h)) refs.add(h);
  }
  return refs;
}
