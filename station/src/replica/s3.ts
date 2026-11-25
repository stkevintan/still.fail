// Zero-dependency AWS SigV4 S3/R2 client and end-to-end encrypted `S3Place` implementing `Place` + restore.
// Compatible with Cloudflare R2, AWS S3, MinIO, Backblaze B2 (path-style and virtual-hosted URLs).
import { createHash, createHmac } from "node:crypto";
import { open } from "node:fs/promises";
import { wall } from "../ops/fibers.ts";
import type { NormalizedS3Target } from "./backup-config.ts";
import {
  FRAME_PLAIN_MAX,
  SFB1_FRAME_HEADER_LEN,
  SFB1_HEADER_LEN,
  SFB1_TAG_LEN,
  parseEncryptionKey,
  sfb1Open,
  sfb1OpenStream,
  sfb1Seal,
  sfb1SealStream,
} from "./crypto.ts";
import { BATCH, GEN, HASH, STATION, WORKSPACE, type Head, asHead, genMade } from "./format.ts";
import { MANIFEST_MAX_BYTES, loadTranscriptManifest, manifestAllRefs } from "./manifest.ts";
import type { Held, Holding, Place } from "./places.ts";

export const MULTIPART_THRESHOLD = 16 * 1024 * 1024;
export const MULTIPART_PART_SIZE = 8 * 1024 * 1024;
export const DELETE_OBJECTS_BATCH = 1000;
const FILE_READ_PIECE = 1 << 20;

const sha256Hex = (data: Buffer | string): string => createHash("sha256").update(data).digest("hex");
const hmacBuf = (key: Buffer | string, data: Buffer | string): Buffer => createHmac("sha256", key).update(data).digest();
const hmacHex = (key: Buffer | string, data: Buffer | string): string => createHmac("sha256", key).update(data).digest("hex");

/// RFC 3986 percent-encoding (preserves unreserved chars `A-Z a-z 0-9 - _ . ~`).
export function rfc3986Encode(s: string): string {
  return encodeURIComponent(s).replace(/[!'()*]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`);
}

export function encodeS3Path(key: string): string {
  return key.split("/").map(rfc3986Encode).join("/");
}

/// Converts epoch ms to AWS SigV4 `{ amzDate: YYYYMMDDTHHMMSSZ, dateStamp: YYYYMMDD }` using pure UTC calendar math.
export function formatAmzDate(ms: number): { amzDate: string; dateStamp: string } {
  const totalSec = Math.floor(ms / 1000);
  const secOfDay = ((totalSec % 86400) + 86400) % 86400;
  const z = Math.floor(totalSec / 86400) + 719468;
  const era = Math.floor((z >= 0 ? z : z - 146096) / 146097);
  const doe = z - era * 146097;
  const yoe = Math.floor((doe - Math.floor(doe / 1460) + Math.floor(doe / 36524) - Math.floor(doe / 146096)) / 365);
  const y = yoe + era * 400;
  const doy = doe - (365 * yoe + Math.floor(yoe / 4) - Math.floor(yoe / 100));
  const mp = Math.floor((5 * doy + 2) / 153);
  const d = doy - Math.floor((153 * mp + 2) / 5) + 1;
  const m = mp + (mp < 10 ? 3 : -9);
  const year = y + (m <= 2 ? 1 : 0);
  const hh = Math.floor(secOfDay / 3600);
  const mm = Math.floor((secOfDay % 3600) / 60);
  const ss = secOfDay % 60;
  const p2 = (n: number) => String(n).padStart(2, "0");
  const p4 = (n: number) => String(n).padStart(4, "0");
  const dateStamp = `${p4(year)}${p2(m)}${p2(d)}`;
  return { dateStamp, amzDate: `${dateStamp}T${p2(hh)}${p2(mm)}${p2(ss)}Z` };
}

export function escapeXml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;")
    .replace(/\r/g, "&#13;");
}

export function unescapeXml(s: string): string {
  return s.replace(/&(#x[0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos);/g, (_, ent: string) => {
    if (ent === "amp") return "&";
    if (ent === "lt") return "<";
    if (ent === "gt") return ">";
    if (ent === "quot") return '"';
    if (ent === "apos") return "'";
    if (ent.startsWith("#x")) return String.fromCodePoint(parseInt(ent.slice(2), 16));
    if (ent.startsWith("#")) return String.fromCodePoint(parseInt(ent.slice(1), 10));
    return `&${ent};`;
  });
}

export function extractXmlTag(xml: string, tag: string): string | null {
  const re = new RegExp(`<(?:[A-Za-z0-9_.-]+:)?${tag}(?:\\s[^>]*)?>([\\s\\S]*?)</(?:[A-Za-z0-9_.-]+:)?${tag}>`);
  const m = re.exec(xml);
  return m === null ? null : unescapeXml(m[1]!);
}

export function extractAllXmlTags(xml: string, tag: string): string[] {
  const re = new RegExp(`<(?:[A-Za-z0-9_.-]+:)?${tag}(?:\\s[^>]*)?>([\\s\\S]*?)</(?:[A-Za-z0-9_.-]+:)?${tag}>`, "g");
  const out: string[] = [];
  let m: RegExpExecArray | null;
  while ((m = re.exec(xml)) !== null) out.push(unescapeXml(m[1]!));
  return out;
}

export type S3ClientOptions = {
  now?: () => number;
  multipartThreshold?: number;
  multipartPartSize?: number;
};

export type SignedS3Request = {
  url: string;
  headers: Record<string, string>;
};

export class S3HttpError extends Error {
  readonly status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

export class S3Client {
  readonly target: NormalizedS3Target;
  readonly #now: () => number;
  readonly #multipartThreshold: number;
  readonly #multipartPartSize: number;

  constructor(target: NormalizedS3Target, opts: S3ClientOptions = {}) {
    this.target = target;
    this.#now = opts.now ?? (() => wall.now());
    this.#multipartThreshold = opts.multipartThreshold ?? MULTIPART_THRESHOLD;
    this.#multipartPartSize = opts.multipartPartSize ?? MULTIPART_PART_SIZE;
  }

  /// Computes URL and SigV4 headers for an S3 request.
  signRequest(
    method: string,
    key: string,
    query: Record<string, string>,
    body: Buffer,
    extraHeaders: Record<string, string> = {},
  ): SignedS3Request {
    const base = new URL(this.target.endpoint);
    const basePath = base.pathname.replace(/\/+$/, "");
    let hostHeader: string;
    let urlOrigin: string;
    let canonicalPath: string;
    const cleanKey = key.replace(/^\/+/, "");

    if (this.target.forcePathStyle) {
      hostHeader = base.host;
      urlOrigin = `${base.protocol}//${base.host}`;
      canonicalPath = cleanKey === ""
        ? `${basePath}/${rfc3986Encode(this.target.bucket)}`
        : `${basePath}/${rfc3986Encode(this.target.bucket)}/${encodeS3Path(cleanKey)}`;
    } else {
      const vhost = `${this.target.bucket}.${base.hostname}`;
      hostHeader = base.port !== "" ? `${vhost}:${base.port}` : vhost;
      urlOrigin = `${base.protocol}//${hostHeader}`;
      canonicalPath = cleanKey === "" ? `${basePath}/` : `${basePath}/${encodeS3Path(cleanKey)}`;
    }
    if (!canonicalPath.startsWith("/")) canonicalPath = `/${canonicalPath}`;

    const queryPairs = Object.entries(query)
      .map(([k, v]) => [rfc3986Encode(k), rfc3986Encode(v)] as const)
      .sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : 0));
    const canonicalQuery = queryPairs.map(([k, v]) => `${k}=${v}`).join("&");

    const { amzDate, dateStamp } = formatAmzDate(this.#now());
    const payloadHash = sha256Hex(body);

    const lowerHeaders: Record<string, string> = {
      host: hostHeader,
      "x-amz-content-sha256": payloadHash,
      "x-amz-date": amzDate,
    };
    for (const [k, v] of Object.entries(extraHeaders)) {
      lowerHeaders[k.toLowerCase()] = v.trim();
    }

    const headerKeys = Object.keys(lowerHeaders).sort();
    const canonicalHeaders = headerKeys.map((k) => `${k}:${lowerHeaders[k]}\n`).join("");
    const signedHeaders = headerKeys.join(";");
    const canonicalRequest = `${method}\n${canonicalPath}\n${canonicalQuery}\n${canonicalHeaders}\n${signedHeaders}\n${payloadHash}`;

    const scope = `${dateStamp}/${this.target.region}/s3/aws4_request`;
    const stringToSign = `AWS4-HMAC-SHA256\n${amzDate}\n${scope}\n${sha256Hex(canonicalRequest)}`;
    const kDate = hmacBuf(`AWS4${this.target.secretAccessKey}`, dateStamp);
    const kRegion = hmacBuf(kDate, this.target.region);
    const kService = hmacBuf(kRegion, "s3");
    const kSigning = hmacBuf(kService, "aws4_request");
    const signature = hmacHex(kSigning, stringToSign);

    const headers: Record<string, string> = {
      ...extraHeaders,
      "x-amz-content-sha256": payloadHash,
      "x-amz-date": amzDate,
      authorization: `AWS4-HMAC-SHA256 Credential=${this.target.accessKeyId}/${scope}, SignedHeaders=${signedHeaders}, Signature=${signature}`,
    };
    const url = canonicalQuery === "" ? `${urlOrigin}${canonicalPath}` : `${urlOrigin}${canonicalPath}?${canonicalQuery}`;
    return { url, headers };
  }

  async #fetch(
    method: string,
    key: string,
    query: Record<string, string>,
    body: Buffer,
    extraHeaders: Record<string, string> = {},
  ): Promise<Response> {
    const { url, headers } = this.signRequest(method, key, query, body, extraHeaders);
    const res = await fetch(url, {
      method,
      headers,
      body: method === "GET" || method === "HEAD" || method === "DELETE" ? undefined : new Uint8Array(body),
    });
    return res;
  }

  async testConnection(): Promise<void> {
    const prefix = this.target.prefix === "" ? "" : `${this.target.prefix}/`;
    const query: Record<string, string> = { "list-type": "2", "max-keys": "1" };
    if (prefix !== "") query.prefix = prefix;
    const res = await this.#fetch("GET", "", query, Buffer.alloc(0));
    const text = await res.text();
    if (!res.ok) {
      const code = extractXmlTag(text, "Code");
      const msg = extractXmlTag(text, "Message");
      throw new S3HttpError(res.status, code || msg ? `S3 ${res.status}: ${code ?? ""} ${msg ?? ""}`.trim() : `S3 ${res.status}`);
    }
  }

  async listPrefix(prefix: string): Promise<string[]> {
    const keys: string[] = [];
    let token: string | null = null;
    for (;;) {
      const query: Record<string, string> = { "list-type": "2", prefix };
      if (token !== null) query["continuation-token"] = token;
      const res = await this.#fetch("GET", "", query, Buffer.alloc(0));
      const xml = await res.text();
      if (!res.ok) throw new S3HttpError(res.status, `S3 ListObjectsV2 failed (${res.status}): ${extractXmlTag(xml, "Message") ?? xml.slice(0, 200)}`);
      for (const k of extractAllXmlTags(xml, "Key")) keys.push(k);
      const truncated = extractXmlTag(xml, "IsTruncated");
      const next = extractXmlTag(xml, "NextContinuationToken");
      if (truncated === "true" && next !== null && next !== "") token = next;
      else break;
    }
    return keys;
  }

  async getObject(key: string, maxBytes?: number): Promise<Buffer> {
    const res = await this.#fetch("GET", key, {}, Buffer.alloc(0));
    if (!res.ok) {
      const text = await res.text().catch(() => "");
      throw new S3HttpError(res.status, `S3 GET ${key} failed (${res.status}): ${extractXmlTag(text, "Message") ?? text.slice(0, 200)}`);
    }
    if (maxBytes === undefined) {
      return Buffer.from(await res.arrayBuffer());
    }
    const cl = res.headers.get("content-length");
    if (cl !== null && cl !== "") {
      const n = Number(cl);
      if (Number.isFinite(n) && n > maxBytes) {
        await res.body?.cancel().catch(() => {});
        throw new Error(`transcript manifest exceeds max bytes (${MANIFEST_MAX_BYTES})`);
      }
    }
    if (res.body !== null) {
      const reader = res.body.getReader();
      const chunks: Buffer[] = [];
      let total = 0;
      try {
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          if (value === undefined || value.byteLength === 0) continue;
          total += value.byteLength;
          if (total > maxBytes) {
            await reader.cancel().catch(() => {});
            throw new Error(`transcript manifest exceeds max bytes (${MANIFEST_MAX_BYTES})`);
          }
          chunks.push(Buffer.from(value.buffer, value.byteOffset, value.byteLength));
        }
      } finally {
        reader.releaseLock();
      }
      return chunks.length === 0 ? Buffer.alloc(0) : chunks.length === 1 ? chunks[0]! : Buffer.concat(chunks, total);
    }
    const buf = Buffer.from(await res.arrayBuffer());
    if (buf.length > maxBytes) {
      throw new Error(`transcript manifest exceeds max bytes (${MANIFEST_MAX_BYTES})`);
    }
    return buf;
  }

  async getObjectStream(key: string): Promise<AsyncIterable<Buffer>> {
    const res = await this.#fetch("GET", key, {}, Buffer.alloc(0));
    if (!res.ok) {
      const text = await res.text().catch(() => "");
      throw new S3HttpError(res.status, `S3 GET ${key} failed (${res.status}): ${extractXmlTag(text, "Message") ?? text.slice(0, 200)}`);
    }
    if (res.body === null) {
      return (async function* () {})();
    }
    const reader = res.body.getReader();
    return (async function* () {
      try {
        for (;;) {
          const { done, value } = await reader.read();
          if (done) return;
          if (value !== undefined && value.byteLength > 0) yield Buffer.from(value.buffer, value.byteOffset, value.byteLength);
        }
      } finally {
        reader.releaseLock();
      }
    })();
  }

  async putObject(key: string, bytes: Buffer): Promise<void> {
    const res = await this.#fetch("PUT", key, {}, bytes, { "content-type": "application/octet-stream" });
    if (!res.ok) {
      const text = await res.text().catch(() => "");
      throw new S3HttpError(res.status, `S3 PUT ${key} failed (${res.status}): ${extractXmlTag(text, "Message") ?? text.slice(0, 200)}`);
    }
  }

  /// Streams an async iterable to S3: buffers up to `multipartThreshold` for a single PUT, and switches automatically to
  /// S3 Multipart Upload (uploading `multipartPartSize` chunks, aborting on any failure) when larger.
  async putStream(key: string, stream: AsyncIterable<Buffer>): Promise<void> {
    const threshold = this.#multipartThreshold;
    const partSize = this.#multipartPartSize;

    let buf: Buffer[] = [];
    let bufLen = 0;
    let uploadId: string | null = null;
    const parts: { partNumber: number; etag: string }[] = [];

    const flushPart = async (data: Buffer): Promise<void> => {
      const partNumber = parts.length + 1;
      const res = await this.#fetch("PUT", key, { partNumber: String(partNumber), uploadId: uploadId! }, data);
      if (!res.ok) {
        const text = await res.text().catch(() => "");
        throw new S3HttpError(res.status, `S3 UploadPart ${partNumber} failed (${res.status}): ${extractXmlTag(text, "Message") ?? text.slice(0, 200)}`);
      }
      const etag = res.headers.get("etag") ?? "";
      parts.push({ partNumber, etag });
    };

    const startMultipart = async (): Promise<void> => {
      const res = await this.#fetch("POST", key, { uploads: "" }, Buffer.alloc(0), { "content-type": "application/octet-stream" });
      const xml = await res.text();
      if (!res.ok) throw new S3HttpError(res.status, `S3 CreateMultipartUpload failed (${res.status}): ${extractXmlTag(xml, "Message") ?? xml.slice(0, 200)}`);
      const id = extractXmlTag(xml, "UploadId");
      if (id === null || id === "") throw new Error("S3 CreateMultipartUpload returned no UploadId");
      uploadId = id;
    };

    const takeChunk = (n: number): Buffer => {
      const all = Buffer.concat(buf, bufLen);
      const head = all.subarray(0, n);
      const rest = all.subarray(n);
      buf = rest.length > 0 ? [rest] : [];
      bufLen = rest.length;
      return head;
    };

    try {
      for await (const piece of stream) {
        if (piece.length === 0) continue;
        buf.push(piece);
        bufLen += piece.length;
        if (uploadId === null && bufLen > threshold) {
          await startMultipart();
        }
        if (uploadId !== null) {
          while (bufLen >= partSize) {
            await flushPart(takeChunk(partSize));
          }
        }
      }
      if (uploadId === null) {
        await this.putObject(key, bufLen === 0 ? Buffer.alloc(0) : Buffer.concat(buf, bufLen));
        return;
      }
      if (bufLen > 0) {
        await flushPart(Buffer.concat(buf, bufLen));
      }
      const completeXml = `<CompleteMultipartUpload>${parts.map((p) => `<Part><PartNumber>${p.partNumber}</PartNumber><ETag>${p.etag}</ETag></Part>`).join("")}</CompleteMultipartUpload>`;
      const res = await this.#fetch("POST", key, { uploadId }, Buffer.from(completeXml, "utf8"), { "content-type": "application/xml" });
      if (!res.ok) {
        const text = await res.text().catch(() => "");
        throw new S3HttpError(res.status, `S3 CompleteMultipartUpload failed (${res.status}): ${extractXmlTag(text, "Message") ?? text.slice(0, 200)}`);
      }
    } catch (e) {
      if (uploadId !== null) {
        await this.#fetch("DELETE", key, { uploadId }, Buffer.alloc(0)).catch(() => {});
      }
      throw e;
    }
  }

  async deleteObject(key: string): Promise<void> {
    const res = await this.#fetch("DELETE", key, {}, Buffer.alloc(0));
    if (!res.ok && res.status !== 404) {
      const text = await res.text().catch(() => "");
      throw new S3HttpError(res.status, `S3 DELETE ${key} failed (${res.status}): ${extractXmlTag(text, "Message") ?? text.slice(0, 200)}`);
    }
  }

  async deleteObjects(keys: string[]): Promise<{ deleted: string[]; errors: { key: string; code: string; message: string }[] }> {
    const deleted: string[] = [];
    const errors: { key: string; code: string; message: string }[] = [];
    if (keys.length === 0) return { deleted, errors };
    for (let i = 0; i < keys.length; i += DELETE_OBJECTS_BATCH) {
      const batch = keys.slice(i, i + DELETE_OBJECTS_BATCH);
      const xml = `<Delete><Quiet>false</Quiet>${batch.map((k) => `<Object><Key>${escapeXml(k)}</Key></Object>`).join("")}</Delete>`;
      const body = Buffer.from(xml, "utf8");
      const contentMd5 = createHash("md5").update(body).digest("base64");
      const res = await this.#fetch("POST", "", { delete: "" }, body, {
        "content-md5": contentMd5,
        "content-type": "application/xml",
      });
      const text = await res.text();
      if (!res.ok) {
        throw new S3HttpError(res.status, `S3 DeleteObjects failed (${res.status}): ${extractXmlTag(text, "Message") ?? text.slice(0, 200)}`);
      }
      const batchAccounted = new Set<string>();
      const deletedRe = /<(?:[A-Za-z0-9_.-]+:)?Deleted(?:\s[^>]*)?>([\s\S]*?)<\/(?:[A-Za-z0-9_.-]+:)?Deleted>/g;
      let m: RegExpExecArray | null;
      while ((m = deletedRe.exec(text)) !== null) {
        const k = extractXmlTag(m[1]!, "Key");
        if (k !== null) {
          deleted.push(k);
          batchAccounted.add(k);
        }
      }
      const errorRe = /<(?:[A-Za-z0-9_.-]+:)?Error(?:\s[^>]*)?>([\s\S]*?)<\/(?:[A-Za-z0-9_.-]+:)?Error>/g;
      while ((m = errorRe.exec(text)) !== null) {
        const block = m[1]!;
        const k = extractXmlTag(block, "Key") ?? "";
        errors.push({
          key: k,
          code: extractXmlTag(block, "Code") ?? "UnknownError",
          message: extractXmlTag(block, "Message") ?? "",
        });
        if (k !== "") batchAccounted.add(k);
      }
      for (const k of batch) {
        if (!batchAccounted.has(k)) {
          errors.push({ key: k, code: "MissingFromResponse", message: "key omitted from S3 DeleteObjects response" });
        }
      }
    }
    return { deleted, errors };
  }
}

async function* fileChunks(path: string): AsyncIterable<Buffer> {
  const f = await open(path, "r");
  try {
    for (;;) {
      const piece = Buffer.allocUnsafe(FILE_READ_PIECE);
      const { bytesRead } = await f.read(piece, 0, FILE_READ_PIECE, null);
      if (bytesRead === 0) return;
      yield piece.subarray(0, bytesRead);
    }
  } finally {
    await f.close();
  }
}

async function* oneChunk(bytes: Buffer): AsyncIterable<Buffer> {
  yield bytes;
}

/// End-to-end encrypted S3/R2 place implementing `Place` + discovery (`origins`) and streaming restore (`read`).
export class S3Place implements Place {
  readonly target: NormalizedS3Target;
  readonly client: S3Client;
  readonly #key: Buffer;
  /// Cached present `fileTag`s per `${ws}\n${origin}` from the last `held()` listing.
  readonly #presentFileTags = new Map<string, Set<string>>();
  /// Orphan `fileTag`s (`fileTags \ referencedTags`) discovered by `held()` ONLY when every listed head was verified.
  readonly #orphanFileTags = new Map<string, Set<string>>();
  /// Per `${ws}\n${origin}` set of `gen`s whose `head/<gen>.enc` failed verification in `held()`.
  readonly #unverifiedGens = new Map<string, Set<string>>();
  /// Per `${ws}\n${origin}` -> `gen` -> referenced `files`, (for older gens) `transcriptFiles`, verified `manifestRefs` (root + leaves + chunks), and `manifestMeta` (root + leaves).
  readonly #genRefHashes = new Map<
    string,
    Map<string, { files: Record<string, number>; transcriptFiles?: Record<string, number>; manifestRefs?: Set<string>; manifestMeta?: Set<string> }>
  >();
  /// Last head reconciled against `#orphanFileTags` per `${ws}\n${origin}` (present ONLY while orphans are non-empty, for O(delta) incremental checks).
  readonly #lastOrphanHead = new Map<string, Head>();

  constructor(target: NormalizedS3Target, opts: S3ClientOptions = {}) {
    this.target = target;
    this.client = new S3Client(target, opts);
    this.#key = parseEncryptionKey(target.encryptionKey);
  }

  wsTag(ws: string): string {
    return hmacHex(this.#key, `ws:${ws}`).slice(0, 32);
  }

  originTag(origin: string): string {
    return hmacHex(this.#key, `origin:${origin}`).slice(0, 32);
  }

  fileTag(hash: string): string {
    return hmacHex(this.#key, `file:${hash}`);
  }

  #prefixed(rel: string): string {
    return this.target.prefix === "" ? rel : `${this.target.prefix}/${rel}`;
  }

  #headKey(ws: string, origin: string, gen: string): string {
    return this.#prefixed(`${this.wsTag(ws)}/${this.originTag(origin)}/head/${gen}.enc`);
  }

  #batchKey(ws: string, origin: string, gen: string, name: string): string {
    return this.#prefixed(`${this.wsTag(ws)}/${this.originTag(origin)}/log/${gen}/${name}.enc`);
  }

  #fileKey(ws: string, origin: string, hash: string): string {
    return this.#prefixed(`${this.wsTag(ws)}/${this.originTag(origin)}/files/${this.fileTag(hash)}.enc`);
  }

  async #readManifestObject(ws: string, origin: string, hash: string, maxBytes: number): Promise<Buffer | null> {
    const frames = Math.max(1, Math.ceil(maxBytes / FRAME_PLAIN_MAX) + 1);
    const maxEncoded = maxBytes + SFB1_HEADER_LEN + frames * (SFB1_FRAME_HEADER_LEN + SFB1_TAG_LEN);
    try {
      const enc = await this.client.getObject(this.#fileKey(ws, origin, hash), maxEncoded);
      const plain = sfb1Open(this.#key, { ws, origin, logicalPath: `files/${hash}` }, enc);
      if (plain.length > maxBytes) {
        throw new Error(`transcript manifest exceeds max bytes (${MANIFEST_MAX_BYTES})`);
      }
      return plain;
    } catch (e) {
      if (e instanceof S3HttpError && e.status === 404) return null;
      throw e;
    }
  }

  async held(ws: string, origin: string): Promise<Held> {
    if (!WORKSPACE.test(ws) || !STATION.test(origin)) throw new Error("not a copy's name");
    const wt = this.wsTag(ws);
    const ot = this.originTag(origin);
    const base = this.#prefixed(`${wt}/${ot}/`);
    const keys = await this.client.listPrefix(base);

    const headGens: string[] = [];
    const batchesByGen = new Map<string, string[]>();
    const fileTags = new Set<string>();

    for (const fullKey of keys) {
      if (!fullKey.startsWith(base)) continue;
      const rel = fullKey.slice(base.length);
      if (rel.startsWith("head/") && rel.endsWith(".enc")) {
        const gen = rel.slice("head/".length, -".enc".length);
        if (GEN.test(gen)) headGens.push(gen);
      } else if (rel.startsWith("log/") && rel.endsWith(".enc")) {
        const rest = rel.slice("log/".length, -".enc".length);
        const slash = rest.indexOf("/");
        if (slash > 0) {
          const gen = rest.slice(0, slash);
          const batch = rest.slice(slash + 1);
          if (GEN.test(gen) && BATCH.test(batch)) {
            let list = batchesByGen.get(gen);
            if (list === undefined) batchesByGen.set(gen, (list = []));
            list.push(batch);
          }
        }
      } else if (rel.startsWith("files/") && rel.endsWith(".enc")) {
        const tag = rel.slice("files/".length, -".enc".length);
        if (HASH.test(tag)) fileTags.add(tag);
      }
    }

    this.#presentFileTags.set(`${ws}\n${origin}`, fileTags);

    const allGens = new Set<string>([...headGens, ...batchesByGen.keys()]);
    const headMap = new Map<string, Head | null>();
    await Promise.all(
      headGens.map(async (gen) => {
        try {
          const enc = await this.client.getObject(this.#headKey(ws, origin, gen));
          const plain = sfb1Open(this.#key, { ws, origin: ot, logicalPath: `head/${gen}` }, enc);
          const parsed = asHead(JSON.parse(plain.toString("utf8")));
          if (parsed !== null && parsed.origin === origin && parsed.workspace === ws && parsed.gen === gen) {
            headMap.set(gen, parsed);
          } else {
            headMap.set(gen, null);
          }
        } catch {
          headMap.set(gen, null);
        }
      }),
    );

    const gens: Holding[] = [];
    const presentHashes = new Set<string>();
    const referencedTags = new Set<string>();
    const unverified = new Set<string>();
    const manifestRefsByGen = new Map<string, Set<string>>();
    const manifestMetaByGen = new Map<string, Set<string>>();
    await Promise.all(
      headGens.map(async (gen) => {
        const head = headMap.get(gen) ?? null;
        if (head === null) {
          unverified.add(gen);
          return;
        }
        if (head.transcriptManifest !== undefined) {
          try {
            const resolved = await loadTranscriptManifest(head.transcriptManifest, (h, maxBytes) => this.#readManifestObject(ws, origin, h, maxBytes));
            const refs = manifestAllRefs(resolved);
            if (head.transcriptFiles !== undefined) {
              for (const h in head.transcriptFiles) {
                if (Object.hasOwn(head.transcriptFiles, h)) refs.add(h);
              }
            }
            manifestRefsByGen.set(gen, refs);
            manifestMetaByGen.set(gen, new Set([resolved.rootHash, ...resolved.leafHashes]));
          } catch {
            unverified.add(gen);
          }
        }
      }),
    );
    const allHeadsVerified = unverified.size === 0;
    const byGen = new Map<string, { files: Record<string, number>; transcriptFiles?: Record<string, number>; manifestRefs?: Set<string>; manifestMeta?: Set<string> }>();
    for (const gen of allGens) {
      const head = headMap.get(gen) ?? null;
      const batches = (batchesByGen.get(gen) ?? []).sort();
      gens.push({ gen, head, batches });
      if (head !== null) {
        const manifestRefs = manifestRefsByGen.get(gen);
        const manifestMeta = manifestMetaByGen.get(gen);
        for (const h of Object.keys(head.files)) {
          const tag = this.fileTag(h);
          referencedTags.add(tag);
          if (fileTags.has(tag)) presentHashes.add(h);
        }
        for (const h of Object.keys(head.transcriptFiles ?? {})) {
          const tag = this.fileTag(h);
          referencedTags.add(tag);
          if (fileTags.has(tag)) presentHashes.add(h);
        }
        if (manifestRefs !== undefined) {
          for (const h of manifestRefs) {
            const tag = this.fileTag(h);
            referencedTags.add(tag);
            if (fileTags.has(tag)) presentHashes.add(h);
          }
        }
        byGen.set(gen, {
          files: head.files,
          transcriptFiles: head.transcriptFiles,
          ...(manifestRefs !== undefined ? { manifestRefs } : {}),
          ...(manifestMeta !== undefined ? { manifestMeta } : {}),
        });
      }
    }
    const scopeKey = `${ws}\n${origin}`;
    if (unverified.size > 0) this.#unverifiedGens.set(scopeKey, unverified);
    else this.#unverifiedGens.delete(scopeKey);
    this.#genRefHashes.set(scopeKey, byGen);
    if (allHeadsVerified) {
      const orphans = new Set<string>();
      for (const tag of fileTags) {
        if (!referencedTags.has(tag)) orphans.add(tag);
      }
      if (orphans.size > 0) {
        this.#orphanFileTags.set(scopeKey, orphans);
        const single = headMap.size === 1 ? ([...headMap.values()][0] ?? null) : null;
        if (single !== null) this.#lastOrphanHead.set(scopeKey, single);
        else this.#lastOrphanHead.delete(scopeKey);
      } else {
        this.#orphanFileTags.delete(scopeKey);
        this.#lastOrphanHead.delete(scopeKey);
      }
    } else {
      this.#orphanFileTags.delete(scopeKey);
      this.#lastOrphanHead.delete(scopeKey);
    }
    gens.sort((a, b) => genMade(a.gen) - genMade(b.gen) || (a.gen < b.gen ? -1 : 1));
    return {
      gens,
      files: [...presentHashes],
      ...(unverified.size > 0 ? { hasUnverifiedHead: true, unverifiedGens: [...unverified] } : {}),
    };
  }

  #reconcileOrphans(scopeKey: string, head: Head, manifestRefs?: Set<string>): void {
    const orphans = this.#orphanFileTags.get(scopeKey);
    if (orphans === undefined || orphans.size === 0) {
      this.#lastOrphanHead.delete(scopeKey);
      return;
    }
    const prev = this.#lastOrphanHead.get(scopeKey);
    const incremental = prev !== undefined && prev.gen === head.gen && prev.transcriptManifest === head.transcriptManifest;
    for (const h in head.files) {
      if (!Object.hasOwn(head.files, h)) continue;
      if (incremental && Object.hasOwn(prev.files, h)) continue;
      orphans.delete(this.fileTag(h));
      if (orphans.size === 0) break;
    }
    if (orphans.size > 0 && head.transcriptFiles !== undefined) {
      const prevTf = incremental ? prev.transcriptFiles : undefined;
      for (const h in head.transcriptFiles) {
        if (!Object.hasOwn(head.transcriptFiles, h)) continue;
        if (prevTf !== undefined && Object.hasOwn(prevTf, h)) continue;
        orphans.delete(this.fileTag(h));
        if (orphans.size === 0) break;
      }
    }
    if (orphans.size > 0 && manifestRefs !== undefined) {
      for (const h of manifestRefs) {
        orphans.delete(this.fileTag(h));
        if (orphans.size === 0) break;
      }
    } else if (orphans.size > 0 && head.transcriptManifest !== undefined) {
      orphans.delete(this.fileTag(head.transcriptManifest));
    }
    if (orphans.size === 0) {
      this.#orphanFileTags.delete(scopeKey);
      this.#lastOrphanHead.delete(scopeKey);
    } else {
      this.#lastOrphanHead.set(scopeKey, head);
    }
  }

  async put(ws: string, origin: string, gen: string, kind: "batch" | "head", name: string, bytes: Buffer, head?: Head): Promise<void> {
    if (!WORKSPACE.test(ws) || !STATION.test(origin) || !GEN.test(gen)) throw new Error("not a copy's name");
    if (kind === "batch") {
      if (!BATCH.test(name)) throw new Error("not a batch's name");
      const enc = sfb1Seal(this.#key, { ws, origin, logicalPath: `log/${gen}/${name}` }, bytes);
      await this.client.putObject(this.#batchKey(ws, origin, gen, name), enc);
    } else {
      let parsed: Head | null = head ?? null;
      if (parsed === null) {
        try {
          parsed = asHead(JSON.parse(bytes.toString("utf8")));
        } catch {
          parsed = null;
        }
      }
      let manifestRefs: Set<string> | undefined;
      let manifestMeta: Set<string> | undefined;
      if (parsed !== null && parsed.transcriptManifest !== undefined) {
        // Verify the full 2-level manifest BEFORE overwriting the remote head object so a broken manifest
        // can never clobber a previously valid head/<gen>.enc.
        const resolved = await loadTranscriptManifest(parsed.transcriptManifest, (h, maxBytes) => this.#readManifestObject(ws, origin, h, maxBytes));
        manifestRefs = manifestAllRefs(resolved);
        manifestMeta = new Set([resolved.rootHash, ...resolved.leafHashes]);
        // Dual-field head (transcriptManifest + inline transcriptFiles): union inline keys into manifestRefs
        // so current-gen inline-only chunks are never deleted by drop().
        if (parsed.transcriptFiles !== undefined) {
          for (const h in parsed.transcriptFiles) {
            if (Object.hasOwn(parsed.transcriptFiles, h)) manifestRefs.add(h);
          }
        }
      }
      const ot = this.originTag(origin);
      const enc = sfb1Seal(this.#key, { ws, origin: ot, logicalPath: `head/${gen}` }, bytes);
      await this.client.putObject(this.#headKey(ws, origin, gen), enc);
      const scopeKey = `${ws}\n${origin}`;
      const unverified = this.#unverifiedGens.get(scopeKey);
      const wasUnverified = unverified !== undefined && unverified.size > 0;
      if (unverified !== undefined) {
        unverified.delete(gen);
        if (unverified.size === 0) this.#unverifiedGens.delete(scopeKey);
      }
      if (parsed !== null) {
        let byGen = this.#genRefHashes.get(scopeKey);
        if (byGen === undefined) this.#genRefHashes.set(scopeKey, (byGen = new Map()));
        // Current gen only needs `files` (and verified `manifestRefs`/`manifestMeta`, which already unions any dual-field `transcriptFiles`)
        // protected in `drop()` (never retains 246k inline `transcriptFiles` on inline-only heads).
        byGen.set(gen, {
          files: parsed.files,
          ...(manifestRefs !== undefined ? { manifestRefs } : {}),
          ...(manifestMeta !== undefined ? { manifestMeta } : {}),
        });
        if (wasUnverified && !this.#unverifiedGens.has(scopeKey)) {
          // Last unverified gen just self-healed: rebuild orphan set from presentFileTags minus all verified gen refs
          // so pruneOrphans() can resume reclamation immediately without waiting for another held() roundtrip.
          const present = this.#presentFileTags.get(scopeKey);
          if (present !== undefined && present.size > 0) {
            const referenced = new Set<string>();
            for (const refs of byGen.values()) {
              for (const h in refs.files) if (Object.hasOwn(refs.files, h)) referenced.add(this.fileTag(h));
              if (refs.transcriptFiles !== undefined) {
                for (const h in refs.transcriptFiles) if (Object.hasOwn(refs.transcriptFiles, h)) referenced.add(this.fileTag(h));
              }
              if (refs.manifestRefs !== undefined) {
                for (const h of refs.manifestRefs) referenced.add(this.fileTag(h));
              }
            }
            if (parsed.transcriptFiles !== undefined) {
              for (const h in parsed.transcriptFiles) if (Object.hasOwn(parsed.transcriptFiles, h)) referenced.add(this.fileTag(h));
            }
            const orphans = new Set<string>();
            for (const tag of present) if (!referenced.has(tag)) orphans.add(tag);
            if (orphans.size > 0) {
              this.#orphanFileTags.set(scopeKey, orphans);
              this.#lastOrphanHead.set(scopeKey, parsed);
            } else {
              this.#orphanFileTags.delete(scopeKey);
              this.#lastOrphanHead.delete(scopeKey);
            }
          }
        } else {
          this.#reconcileOrphans(scopeKey, parsed, manifestRefs);
        }
      }
    }
  }

  async putFile(ws: string, origin: string, hash: string, source: string | Buffer): Promise<void> {
    if (!WORKSPACE.test(ws) || !STATION.test(origin) || !HASH.test(hash)) throw new Error("not a file's hash");
    const chunks = Buffer.isBuffer(source) ? oneChunk(source) : fileChunks(source);
    const encStream = sfb1SealStream(this.#key, { ws, origin, logicalPath: `files/${hash}` }, chunks);
    await this.client.putStream(this.#fileKey(ws, origin, hash), encStream);
    const tag = this.fileTag(hash);
    const scopeKey = `${ws}\n${origin}`;
    this.#presentFileTags.get(scopeKey)?.add(tag);
    this.#orphanFileTags.get(scopeKey)?.delete(tag);
  }

  async drop(
    ws: string,
    origin: string,
    gen: string,
    batches: string[],
    files: string[],
    opts?: { allowCurrentGenTranscripts?: boolean },
  ): Promise<void> {
    if (!WORKSPACE.test(ws) || !STATION.test(origin) || !GEN.test(gen)) throw new Error("not a copy's name");
    const scopeKey = `${ws}\n${origin}`;
    const unverified = this.#unverifiedGens.get(scopeKey);
    const allVerified = unverified === undefined || unverified.size === 0;
    const byGen = this.#genRefHashes.get(scopeKey);
    const allowCurrentGenTranscripts = opts?.allowCurrentGenTranscripts === true;
    const isProtectedHash = (hash: string): boolean => {
      if (byGen === undefined) return false;
      for (const [otherGen, refs] of byGen) {
        if (Object.hasOwn(refs.files, hash)) return true;
        if (otherGen !== gen) {
          if (refs.transcriptFiles !== undefined && Object.hasOwn(refs.transcriptFiles, hash)) return true;
          if (refs.manifestRefs !== undefined && refs.manifestRefs.has(hash)) return true;
        } else {
          if (refs.manifestMeta !== undefined && refs.manifestMeta.has(hash)) return true;
          if (!allowCurrentGenTranscripts && refs.manifestRefs !== undefined && refs.manifestRefs.has(hash)) return true;
        }
      }
      return false;
    };
    const keys: string[] = [];
    const fileKeyToTag = new Map<string, string>();
    for (const b of batches) {
      if (BATCH.test(b)) keys.push(this.#batchKey(ws, origin, gen, b));
    }
    if (allVerified) {
      for (const f of files) {
        if (!HASH.test(f)) continue;
        if (isProtectedHash(f)) continue;
        const tag = this.fileTag(f);
        const k = this.#fileKey(ws, origin, f);
        keys.push(k);
        fileKeyToTag.set(k, tag);
      }
    }
    if (keys.length === 0) return;
    const { deleted, errors } = await this.client.deleteObjects(keys);
    const tags = this.#presentFileTags.get(scopeKey);
    const orphans = this.#orphanFileTags.get(scopeKey);
    for (const k of deleted) {
      const tag = fileKeyToTag.get(k);
      if (tag !== undefined) {
        tags?.delete(tag);
        orphans?.delete(tag);
      }
    }
    const realErrors: { key: string; code: string; message: string }[] = [];
    for (const err of errors) {
      if (err.code === "NoSuchKey") {
        const tag = fileKeyToTag.get(err.key);
        if (tag !== undefined) {
          tags?.delete(tag);
          orphans?.delete(tag);
        }
      } else {
        realErrors.push(err);
      }
    }
    if (realErrors.length > 0) {
      const sample = realErrors[0]!;
      throw new Error(`S3 DeleteObjects failed for ${realErrors.length} key(s): ${sample.key} (${sample.code}: ${sample.message})`);
    }
  }

  async pruneOrphans(ws: string, origin: string, liveHead?: Head): Promise<void> {
    if (!WORKSPACE.test(ws) || !STATION.test(origin)) throw new Error("not a copy's name");
    const scopeKey = `${ws}\n${origin}`;
    const unverified = this.#unverifiedGens.get(scopeKey);
    if (unverified !== undefined && unverified.size > 0) return;
    if (liveHead !== undefined) {
      let manifestRefs: Set<string> | undefined;
      if (liveHead.transcriptManifest !== undefined) {
        try {
          const resolved = await loadTranscriptManifest(liveHead.transcriptManifest, (h, maxBytes) => this.#readManifestObject(ws, origin, h, maxBytes));
          manifestRefs = manifestAllRefs(resolved);
        } catch {
          let u = this.#unverifiedGens.get(scopeKey);
          if (u === undefined) this.#unverifiedGens.set(scopeKey, (u = new Set()));
          u.add(liveHead.gen);
          this.#orphanFileTags.delete(scopeKey);
          this.#lastOrphanHead.delete(scopeKey);
          return;
        }
      }
      this.#reconcileOrphans(scopeKey, liveHead, manifestRefs);
    }
    const orphans = this.#orphanFileTags.get(scopeKey);
    if (orphans === undefined || orphans.size === 0) {
      this.#lastOrphanHead.delete(scopeKey);
      return;
    }
    const wt = this.wsTag(ws);
    const ot = this.originTag(origin);
    const keys: string[] = [];
    const keyToTag = new Map<string, string>();
    for (const tag of orphans) {
      const k = this.#prefixed(`${wt}/${ot}/files/${tag}.enc`);
      keys.push(k);
      keyToTag.set(k, tag);
    }
    const { deleted, errors } = await this.client.deleteObjects(keys);
    const tags = this.#presentFileTags.get(scopeKey);
    for (const k of deleted) {
      const tag = keyToTag.get(k);
      if (tag !== undefined) {
        orphans.delete(tag);
        tags?.delete(tag);
      }
    }
    const realErrors: { key: string; code: string; message: string }[] = [];
    for (const err of errors) {
      if (err.code === "NoSuchKey") {
        const tag = keyToTag.get(err.key);
        if (tag !== undefined) {
          orphans.delete(tag);
          tags?.delete(tag);
        }
      } else {
        realErrors.push(err);
      }
    }
    if (orphans.size === 0) {
      this.#orphanFileTags.delete(scopeKey);
      this.#lastOrphanHead.delete(scopeKey);
    }
    if (realErrors.length > 0) {
      const sample = realErrors[0]!;
      throw new Error(`S3 pruneOrphans failed for ${realErrors.length} key(s): ${sample.key} (${sample.code}: ${sample.message})`);
    }
  }

  /// Discovers all backed-up stations for `ws` in this S3 bucket using only `ws` and `encryptionKey`.
  async origins(ws: string): Promise<{ origin: string; heads: Head[] }[]> {
    if (!WORKSPACE.test(ws)) return [];
    const base = this.#prefixed(`${this.wsTag(ws)}/`);
    const keys = await this.client.listPrefix(base);
    const headEntries: { originTag: string; gen: string; key: string }[] = [];
    for (const fullKey of keys) {
      if (!fullKey.startsWith(base)) continue;
      const rel = fullKey.slice(base.length);
      const parts = rel.split("/");
      if (parts.length === 3 && parts[1] === "head" && parts[2]!.endsWith(".enc")) {
        const originTag = parts[0]!;
        const gen = parts[2]!.slice(0, -".enc".length);
        if (/^[0-9a-f]{32}$/.test(originTag) && GEN.test(gen)) {
          headEntries.push({ originTag, gen, key: fullKey });
        }
      }
    }

    const byOrigin = new Map<string, Head[]>();
    await Promise.all(
      headEntries.map(async ({ originTag, gen, key }) => {
        try {
          const enc = await this.client.getObject(key);
          const plain = sfb1Open(this.#key, { ws, origin: originTag, logicalPath: `head/${gen}` }, enc);
          const head = asHead(JSON.parse(plain.toString("utf8")));
          if (head === null || head.workspace !== ws || head.gen !== gen) return;
          if (this.originTag(head.origin) !== originTag) return;
          let list = byOrigin.get(head.origin);
          if (list === undefined) byOrigin.set(head.origin, (list = []));
          list.push(head);
        } catch {
          // skip unreadable or foreign-keyed heads
        }
      }),
    );

    return [...byOrigin.entries()].map(([origin, heads]) => ({
      origin,
      heads: heads.sort((a, b) => genMade(a.gen) - genMade(b.gen) || (a.gen < b.gen ? -1 : 1)),
    }));
  }

  /// Streaming read and decrypt of a `head`, `batch`, or `file` for restore.
  async read(ws: string, origin: string, gen: string | null, name: string): Promise<AsyncIterable<Buffer>> {
    if (!WORKSPACE.test(ws) || !STATION.test(origin) || (gen !== null && !GEN.test(gen))) {
      throw new Error("not a copy's name");
    }
    if (gen === null) {
      if (!HASH.test(name)) throw new Error("not a file's hash");
      const encStream = await this.client.getObjectStream(this.#fileKey(ws, origin, name));
      return sfb1OpenStream(this.#key, { ws, origin, logicalPath: `files/${name}` }, encStream);
    }
    if (name === "head.json") {
      const encStream = await this.client.getObjectStream(this.#headKey(ws, origin, gen));
      return sfb1OpenStream(this.#key, { ws, origin: this.originTag(origin), logicalPath: `head/${gen}` }, encStream);
    }
    if (!BATCH.test(name)) throw new Error("not a batch's name");
    const encStream = await this.client.getObjectStream(this.#batchKey(ws, origin, gen, name));
    return sfb1OpenStream(this.#key, { ws, origin, logicalPath: `log/${gen}/${name}` }, encStream);
  }
}
