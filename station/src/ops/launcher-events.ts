// What the launcher did to recover while no station could say it (a Node or the front killed as hung, a crash, a
// handover given up): station/native/launcher/src/lifecycle.rs `record` keeps each as a JSON line in
// <data>/run/launcher-events.jsonl, and the station that comes up next says each in its log (so the log upload carries
// it, src/ops/log-export.ts), once: it takes the file for itself first (a rename), so another process does not say them
// again. MoonBit's station does the same (station/mb/src/station_main/launcher_events.mbt).
//
// So is what ended a Node station by a fatal error (an exception nobody caught, a rejection nobody handled, the
// station's fiber ending by itself): the launcher sees only that it exited with 1, and the log's upload (every 5 s) has
// no time to send the error's line before the process ends. `recordNodeCrash` keeps the first in
// <data>/run/node-crash.json as the process ends, and the next station says it once (`reportNodeCrash`).
import { mkdirSync, writeFileSync } from "node:fs";
import { readFile, rename, unlink } from "node:fs/promises";
import { join } from "node:path";
import { wall } from "./fibers.ts";
import { log } from "./log.ts";

export type LauncherEventLevel = "error" | "warn";
export type LauncherEventEmit = (level: LauncherEventLevel, message: string, fields: Record<string, unknown>) => void;

/// The fields said of an event: the launcher's numbers and words of its own (no path, nothing a person wrote).
const FIELDS = ["kind", "at", "pid", "version", "how", "uptimeMs", "taken", "failures", "heartbeatTimeoutMs", "misses", "probeMs", "retries", "reason", "exitTimeoutMs", "healthAgeMs", "rssBytes", "openFds", "heldMaxMs", "front", "presenceOnline", "relayConflict", "procState", "wchan", "pcpu", "threads", "kernelStack", "mainStack"];
const ERRORS = new Set(["node_hung_killed", "node_crashed", "front_hung_killed"]);

/// One line of the file: its level, kind and fields; null for one that is not an event.
export function launcherEventOf(line: string): { level: LauncherEventLevel; kind: string; fields: Record<string, unknown> } | null {
  let event: unknown;
  try {
    event = JSON.parse(line);
  } catch {
    return null;
  }
  if (event === null || typeof event !== "object" || Array.isArray(event)) return null;
  const e = event as Record<string, unknown>;
  if (typeof e.kind !== "string" || e.kind === "") return null;
  const fields: Record<string, unknown> = {};
  for (const name of FIELDS) if (e[name] !== undefined) fields[name] = e[name];
  const level = e.level === "error" || e.level === "warn" ? e.level : ERRORS.has(e.kind) ? "error" : "warn";
  return { level, kind: e.kind, fields };
}

const said: LauncherEventEmit = (level, message, fields) => (level === "error" ? log.error("launcher", message, fields) : log.warn("launcher", message, fields));

/// Says each event the launcher kept (`emit`, the log by default) and removes them: how many.
export async function reportLauncherEvents(data: string, emit: LauncherEventEmit = said): Promise<number> {
  const run = join(data, "run");
  const claimed = join(run, `launcher-events.${process.pid}.jsonl`);
  try {
    await rename(join(run, "launcher-events.jsonl"), claimed);
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === "ENOENT") return 0;
    throw e;
  }
  try {
    let n = 0;
    for (const line of (await readFile(claimed, "utf8")).split("\n")) {
      const event = line.trim() === "" ? null : launcherEventOf(line);
      if (event === null) continue;
      emit(event.level, event.kind, event.fields);
      n++;
    }
    return n;
  } finally {
    await unlink(claimed).catch((e: NodeJS.ErrnoException) => {
      if (e.code !== "ENOENT") throw e;
    });
  }
}

const CRASH_FILE = "node-crash.json";
/// The fields said of a crash: when, which process and version, how it ended (`uncaughtException`,
/// `unhandledRejection`, `fiberExit`) and the error's own words (its stack).
const CRASH_FIELDS = ["at", "pid", "version", "origin", "error"] as const;
/// The most of an error kept, in characters.
const CRASH_ERROR_MAX = 4_000;

export type NodeCrash = { origin: string; error: string; version: string; pid?: number; at?: number };
export type NodeCrashEmit = (fields: Record<string, unknown>) => void;

/// Keeps what ends this process for the next station to say. On the way out, so synchronous, and never throws.
export function recordNodeCrash(data: string, crash: NodeCrash): void {
  try {
    const payload = { at: crash.at ?? wall.now(), pid: crash.pid ?? process.pid, version: crash.version, origin: crash.origin, error: crash.error.slice(0, CRASH_ERROR_MAX) };
    mkdirSync(join(data, "run"), { recursive: true }); // sync: process is exiting on fatal error
    writeFileSync(join(data, "run", CRASH_FILE), `${JSON.stringify(payload)}\n`, { mode: 0o600 }); // sync: process is exiting on fatal error
  } catch {
    // nothing more can be done on the way out
  }
}

/// The file's crash: its own fields; null for one that is not a crash.
export function nodeCrashOf(text: string): Record<string, unknown> | null {
  let crash: unknown;
  try {
    crash = JSON.parse(text);
  } catch {
    return null;
  }
  if (crash === null || typeof crash !== "object" || Array.isArray(crash)) return null;
  const e = crash as Record<string, unknown>;
  if (typeof e.origin !== "string" || e.origin === "" || typeof e.error !== "string" || e.error === "") return null;
  const fields: Record<string, unknown> = {};
  for (const name of CRASH_FIELDS) if (e[name] !== undefined) fields[name] = e[name];
  return fields;
}

/// Says the crash the station before kept (`emit`, the log by default) and removes it: whether there was one.
export async function reportNodeCrash(data: string, emit: NodeCrashEmit = (fields) => log.error("station", "previous process ended with fatal error", fields)): Promise<boolean> {
  const run = join(data, "run");
  const claimed = join(run, `node-crash.${process.pid}.json`);
  try {
    await rename(join(run, CRASH_FILE), claimed);
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === "ENOENT") return false;
    throw e;
  }
  try {
    const fields = nodeCrashOf(await readFile(claimed, "utf8"));
    if (fields === null) return false;
    emit(fields);
    return true;
  } finally {
    await unlink(claimed).catch((e: NodeJS.ErrnoException) => {
      if (e.code !== "ENOENT") throw e;
    });
  }
}
