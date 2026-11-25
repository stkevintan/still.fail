// What a copy of a station's conversations is made of (replica/AGENTS.md): batches, each the rows that changed since the
// one before it, numbered on in a generation of them, and the head that says which batches and files make the copy now.
// Only a restorer reads inside them; the stations that keep a copy keep them as files.
//
//   <gen>/log/<from>-<to>-<sum>.ndjson.zst   a batch: zstd of JSON lines, the first its header, written whole or not at
//                                      all; `sum` the start of its bytes' hash, so two batches of the same numbers (one a
//                                      station rolled back wrote again) are never taken for each other
//   <gen>/files/<sha256>               an attached file, by the hash of what it holds
//   <gen>/head.json                    written last: the batches and files of the copy, and what it is of
//
// A record says a row as it is now (`r`: its table, `row`: its columns by name, as the origin's schema has them), a row
// that is gone (`del`: its table and key), a session or thread deleted with everything of it (`gone`), or an attached
// file (`file`: its hash, size and where it was). A later record of a key stands for an earlier one; folding them
// (`Folded`) is what both a restore and the folding of small batches into one do. The coding and folding are the
// MoonBit program's (station/mb src/replica); the TypeScript it is held to is the tests' (test/reference/replica-format.ts).
/// The batches' format: a restorer takes those of its own version or before.
export const VERSION = 1;

export type Row = Record<string, unknown>;

/// The head of a generation of batches (`head.json`): which batches and files the copy is now, whose it is (`origin`,
/// in `workspace`; what it was called, `name`; where its data was, `dataDir`, which the paths in its rows begin with),
/// how far it goes (`to`), when that was (`made`), how much it holds (`chats`, `messages`; `bytes` of batches and
/// files), and the runs of its exporter that wrote it, each from the batch it began at (`runs`, the last RUNS_KEPT): a
/// place that holds a run this station's own head does not know holds what this station lost (it was rolled back).
export type Head = {
  v: number;
  origin: string;
  workspace: string;
  gen: string;
  name: string;
  dataDir: string;
  made: number;
  to: number;
  batches: string[];
  files: Record<string, number>;
  transcriptFiles?: Record<string, number>;
  /// Content-addressed 2-level 256-bucket transcript manifest root hash (64-char lowercase hex SHA-256).
  transcriptManifest?: string;
  /// Put before the transcripts it lacks were sent (places.ts `partialHead`): naming only those the place held then.
  partial?: true;
  chats: number;
  messages: number;
  bytes: number;
  runs: { run: string; from: number }[];
};

export const WORKSPACE = /^[0-9A-Za-z_-]{1,64}$/;
export const STATION = /^[0-9a-f]{64}$/;
export const GEN = /^[0-9a-z]{1,16}-[0-9a-f]{8}$/;
export const HASH = /^[0-9a-f]{64}$/;
export const BATCH = /^(\d{10})-(\d{10})-[0-9a-f]{8}\.ndjson\.zst$/;

/// When a generation began, from its name (base 36, then a random part).
export const genMade = (gen: string) => parseInt(gen.split("-")[0]!, 36);

/// Zero-allocation check for a 64-character lowercase hex SHA-256 hash.
export function isHex64(s: string): boolean {
  if (s.length !== 64) return false;
  for (let i = 0; i < 64; i++) {
    const c = s.charCodeAt(i);
    if (!((c >= 48 && c <= 57) || (c >= 97 && c <= 102))) return false;
  }
  return true;
}

function allHex64Keys(obj: Record<string, unknown>): boolean {
  for (const k in obj) {
    if (Object.hasOwn(obj, k) && !isHex64(k)) return false;
  }
  return true;
}

/// A head read back, or null where it is none (or of a format newer than this).
export function asHead(v: unknown): Head | null {
  const h = v as Head;
  if (h === null || typeof h !== "object" || typeof h.v !== "number" || h.v > VERSION) return null;
  if (typeof h.origin !== "string" || typeof h.workspace !== "string" || typeof h.gen !== "string" || !GEN.test(h.gen)) return null;
  if (!Number.isSafeInteger(h.to) || !Array.isArray(h.batches) || h.batches.some((b) => typeof b !== "string" || !BATCH.test(b))) return null;
  if (h.files === null || typeof h.files !== "object" || Array.isArray(h.files) || !allHex64Keys(h.files)) return null;
  if (h.transcriptFiles !== undefined && (h.transcriptFiles === null || typeof h.transcriptFiles !== "object" || Array.isArray(h.transcriptFiles) || !allHex64Keys(h.transcriptFiles))) return null;
  if (h.transcriptManifest !== undefined && (typeof h.transcriptManifest !== "string" || !isHex64(h.transcriptManifest))) return null;
  if (!Array.isArray(h.runs)) return null;
  return h;
}
