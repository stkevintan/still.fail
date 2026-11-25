// A lost station's conversations taken back (replica/AGENTS.md): a copy of them (a generation of batches and its files,
// brought into <data>/restore/ from a station that holds it) folded into what it says
// now, and put into this station's database before its store opens: the same thread ids, entry numbers and session
// keys, the paths in its rows moved from the lost station's data directory to this one's, its files put where the rows
// say. Only into a station that has no chats of its own yet; the station then says it was that one (`formerly`).
import { claudeProject } from "../read/transcript.ts";
import type { ReaderSelectConfig } from "../read/reader-select.ts";
import { existsSync } from "node:fs";
import { join, sep } from "node:path";

/// Where a restore brings a copy before it is put in: `<data>/restore/`, its generation's batches and files as a
/// place keeps them, and `ready.json` once all of it is there.
export const restoreDir = (data: string) => join(data, "restore");
export const readyFile = (data: string) => join(restoreDir(data), "ready.json");
/// What a restore brought, once all of it is there: whose copy (`origin`, in `workspace`), which generation, and where it
/// was taken from (said to whoever looks at the station meanwhile).
/// `merge`: the copy of a station retired into this one (retire.ts), put in beside this station's own chats;
/// `connects`: how the ids of that station's connects go here (retire.ts `connectsThere`); `ws`: what its sessions'
/// `ws` is here (null: this station's home workspace), whatever it was there.
export type Ready = { origin: string; workspace: string; gen: string; name: string; from: string; merge?: boolean; connects?: Record<string, string>; ws?: string | null };

/// The generation brought, as `<restore>/copy/` holds it: `head.json`, `log/`, `files/`.
export const copyDir = (data: string) => join(restoreDir(data), "copy");

/// Where a file of a chat carried from the station whose data directory is `from` lies here, the one answer for its
/// placing, for whether it is in place already and for its pruning: as `moved`, and a Claude transcript
/// (`transcripts*/claude/<project>/…`, its project named by the runtime after the real path of the directory it ran
/// in, read/transcript.ts `claudeProject`) under the project of `room`, its room here as the runtime will see it (its
/// real path, `/private/tmp/…` where the data directory is behind a symlink), whatever name it had there; none given:
/// as `moved`. Kept under the other's name, it was not the one resumed: this station's own older copy of the same
/// session, in place under this room's project, was (a chat moved there and back recalled nothing of its time there;
/// 2026-11-14).
export function carriedTo(path: string, from: string, to: string, room: string | null): string {
  const at = moved(path, from, to);
  const project = room === null ? null : claudeProject(room);
  if (project === null || from === "" || at === path) return at;
  const t = to.endsWith(sep) ? to.slice(0, -1) : to;
  const parts = at.slice(t.length + 1).split(/[\\/]/);
  if (parts.length < 4 || !parts[0]!.startsWith("transcripts") || parts[1] !== "claude") return at;
  parts[2] = project;
  return join(t, ...parts);
}

/// `path` as it is on this station: under `to` where it was under `from`.
export function moved(path: string, from: string, to: string): string {
  if (from === "" || from === to) return path;
  const f = from.endsWith(sep) ? from.slice(0, -1) : from;
  if (path === f) return to;
  return path.startsWith(f + sep) || path.startsWith(`${f}/`) ? join(to, path.slice(f.length + 1)) : path;
}

/// What came of a restore, as the settings say it after the restart (copies.ts `overview`): `error` its words for the
/// log, `reason` the settings' (the station got a chat of its own first, the disk full, or something else); `pending`:
/// its chats are in and their files not all placed yet (`left` of them), the next start placing them.
export type Outcome = { origin: string; name: string; from: string; at: number; rows: Record<string, number>; files: number; missing: number; error: string | null; reason: "notEmpty" | "full" | "error" | null; pending: boolean; left: number };

/// A copy is taken back only into a station with no chat of its own.
export class NotEmpty extends Error {
  constructor() {
    super("this station has chats of its own: a copy is taken back only into a new one");
  }
}
export const outcomeFile = (data: string) => join(data, "replica", "restored.json");

/// The restore put in off the main thread, where one waits (null: none did), by the MoonBit program (station/mb's
/// src/replica, `--builder replica-restore`; `given`: a test's own), which does what `takeBack` did
/// (test/reference/replica-restore.ts, which the tests hold it to).
export async function takeBackSoon(
  data: string,
  db: string,
  now: number,
  given?: string,
  options?: { readers?: ReaderSelectConfig | (() => ReaderSelectConfig) },
): Promise<Ready | null> {
  if (!existsSync(readyFile(data))) return null; // sync: before the station serves (its store not open yet)
  const { MbProcess, resolveReaderSelectionAsync } = await import("../read/mb-reader.ts");
  const binary = (await resolveReaderSelectionAsync("replica-restore", { binary: given, config: options?.readers, logAt: "replica" })).primaryBinary;
  return new Promise((resolve, reject) => {
    const p = new MbProcess(binary, ["--builder", "replica-restore", "--db", db, "--data", data, "--now", String(now), "--sep", sep]);
    let said = false;
    p.once("message", (m: { ready?: Ready | null; error?: string }) => {
      said = true;
      if (m.error !== undefined) reject(new Error(m.error));
      else resolve(m.ready ?? null);
    });
    p.once("error", reject);
    p.once("exit", (code: number) => { if (!said) reject(new Error(`the restore ended saying nothing (${code})`)); });
  });
}
