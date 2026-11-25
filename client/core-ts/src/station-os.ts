// Which system each of a workspace's stations runs on, as its host readings said it (`os`, station/src/api/host.ts:
// "macOS 15.2", "Linux 6.8.0", "Windows 11 Pro 10.0.26100"), kept on the device by the workspace's id (`stationOs`) so a
// station not reached this run, or offline, is still known by it. A station whose workspace gave it no mark (no emoji,
// no icon) is shown by its system's glyph (design/station-icons macos, windows, linux) in its place
// (views/views.ts `stations`); a mark it is given is shown instead, and the picker shows none chosen (`osIcon`).
import { isObject } from "./util.ts";

export type OsKind = "macos" | "windows" | "linux";

/// The system a host reading's `os` names; null for one still.fail draws no glyph of.
export function osKindOf(os: unknown): OsKind | null {
  if (typeof os !== "string") return null;
  const s = os.toLowerCase();
  if (s.startsWith("macos") || s.startsWith("mac os") || s.startsWith("darwin")) return "macos";
  if (s.startsWith("windows")) return "windows";
  if (s.startsWith("linux")) return "linux";
  return null;
}

/// The icon a station of system `kind` is shown by where it has no mark of its own.
export function osIcon(kind: unknown): string | null {
  return kind === "macos" || kind === "windows" || kind === "linux" ? `glyph:${kind}` : null;
}

/// The systems kept for `ws`'s stations, by station id.
export function keptOs(data: { record(table: string, key: string): unknown }, ws: string): Record<string, OsKind> {
  const raw = data.record("stationOs", ws);
  const out: Record<string, OsKind> = {};
  if (isObject(raw)) for (const [id, k] of Object.entries(raw)) if (osIcon(k) !== null) out[id] = k as OsKind;
  return out;
}

/// Station `id` of `ws` said to run on `os`: kept where that is another system than the one kept (a host reading comes
/// every few seconds; this writes once a station).
export function keepOs(data: { record(table: string, key: string): unknown; put(table: string, key: string, value: unknown): void }, ws: string, id: string, os: unknown): void {
  const kind = osKindOf(os);
  if (kind === null) return;
  const was = keptOs(data, ws);
  if (was[id] === kind) return;
  data.put("stationOs", ws, { ...was, [id]: kind });
}
