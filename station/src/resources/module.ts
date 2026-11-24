// What of this machine still.fail uses (resources/watch.ts), as a part of the station (parts.ts): looked at while a
// page asks; GET /resources. And the station's watch over its own memory (ops/self-memory.ts).
import { execFile } from "node:child_process";
import { readFile, rm } from "node:fs/promises";
import { homedir, totalmem } from "node:os";
import { basename, join } from "node:path";
import { promisify } from "node:util";
import { Effect, Layer } from "effect";
import { resourceRoutes } from "../api/routes/usage.ts";
import { runnerSessions, runnersWithSessions, watchedJobs } from "../jobs/memory.ts";
import { loadMesh } from "../mesh/native.ts";
import { type ProcessInfo, platform, treeOf } from "../platform/index.ts";
import { Agents } from "../sessions/agents.ts";
import { restarter } from "../ops/restart.ts";
import { SelfMemoryGovernor } from "../ops/self-memory.ts";
import { MbProcess } from "../read/mb-reader.ts";
import { Parts, Paths, Readers, Store } from "../services.ts";
import { linuxUsage } from "./linux.ts";
import { PRODUCTS, STILLFAIL } from "../../../client/i18n/brand.ts";
import { ResourceWatch } from "./watch.ts";

/// The desktop app's bundle ids begin so, each product's (fail.still.desktop, fail.still.desktop.beta,
/// build.monoid.desktop, …: apps/mbui's, in the Electron app's place, as that app's were).
const APP_IDS = [STILLFAIL, ...PRODUCTS.map((p) => p.product)].map((p) => `${p.reverse}.desktop`);

/// Whether `command` runs from a bundle of the desktop app's: its Info.plist names the id (as text in an XML plist or a
/// binary one alike). Each bundle read once, off the station's thread: one not read yet is none until it is (the next
/// look). Read as each was asked, the first look after the station started read every app's running (53 on a station,
/// 2026-11-03) from a disk short of memory, and held the station 7.8 s, a message sent waiting on it.
export function appBundles(read: (path: string) => Promise<Buffer> = (path) => readFile(path)): (command: string) => boolean {
  const known = new Map<string, boolean>();
  return (command) => {
    const at = command.indexOf(".app/Contents/");
    if (at < 0) return false;
    const bundle = command.slice(0, at + 4);
    const is = known.get(bundle);
    if (is !== undefined) return is;
    known.set(bundle, false);
    read(`${bundle}/Contents/Info.plist`).then((plist) => known.set(bundle, APP_IDS.some((id) => plist.includes(id))), () => {});
    return false;
  };
}

const run = promisify(execFile);

/// `ps -o pid=,args=`: each pid's command line.
function parseArgs(text: string): Map<number, string> {
  const out = new Map<number, string>();
  for (const line of text.split("\n")) {
    const m = line.match(/^\s*(\d+)\s(.*)$/);
    if (m) out.set(Number(m[1]), m[2]!);
  }
  return out;
}

/// `nettop -P -L 1 -x -J bytes_in,bytes_out -n`: each process's bytes in and out so far, as `name.pid,in,out,` (its
/// name may have dots of its own).
export function parseNettop(text: string): Map<number, { in: number; out: number }> {
  const out = new Map<number, { in: number; out: number }>();
  for (const line of text.split("\n")) {
    const m = line.match(/\.(\d+),(\d+),(\d+),?$/);
    if (m) out.set(Number(m[1]), { in: Number(m[2]), out: Number(m[3]) });
  }
  return out;
}

/// The resident bytes of the MoonBit programs this process runs (MbProcess.live) and all under them, in `table`.
export function programsIn(table: readonly ProcessInfo[] | null, pids: readonly number[]): { bytes: number; count: number } {
  if (table === null) return { bytes: 0, count: pids.length };
  const { byPid, children } = treeOf(table);
  const seen = new Set<number>();
  let bytes = 0;
  for (const queue = [...pids]; queue.length > 0; ) {
    const pid = queue.pop()!;
    if (seen.has(pid)) continue;
    seen.add(pid);
    bytes += byPid.get(pid)?.bytes ?? 0;
    queue.push(...(children.get(pid) ?? []));
  }
  return { bytes, count: pids.length };
}

/// The resident bytes of the front in `table` (the MoonBit program the launcher keeps the station's endpoint in,
/// native/launcher/src/front.rs): the launcher's child that runs the program, which no other is (its others are Nodes);
/// null where there is no launcher, no table or no front. Linux's ps cuts a command's name to 15 bytes.
export function frontIn(table: readonly ProcessInfo[] | null, launcher: number | null, self: number): number | null {
  if (table === null || launcher === null) return null;
  const front = table.find((p) => p.ppid === launcher && p.pid !== self && basename(p.command).startsWith("stillfail-reade"));
  return front?.bytes ?? null;
}

/// Whether this process's parent is its launcher (stillfail-station), not a shell or launchd, whose all under it is not
/// the station's.
async function launcher(): Promise<boolean> {
  // (Windows: no ps of its own, and no front to find)
  if ((platform.os !== "macos" && platform.os !== "linux") || process.ppid <= 1) return false;
  try {
    return basename((await run("ps", ["-o", "comm=", "-p", String(process.ppid)], { encoding: "utf8" })).stdout.trim()).startsWith("stillfail");
  } catch {
    return false;
  }
}

export const ResourcesLive = Layer.effectDiscard(
  Effect.gen(function* () {
    const { data, restartFront } = yield* Paths;
    const store = yield* Store;
    const { hub } = yield* Agents;
    const readers = yield* Readers;
    const underLauncher = yield* Effect.promise(() => launcher());
    // The station's own memory (ops/self-memory.ts), wherever it runs: on Windows only Node's own is read.
    yield* Effect.acquireRelease(
      Effect.sync(() => {
        // One table a sample: the one `children` read, the governor asking `front` after it.
        let table: Promise<ProcessInfo[] | null> | null = null;
        const governor = new SelfMemoryGovernor({
          clock: hub.clock,
          totalBytes: () => totalmem(),
          startedAt: hub.clock.currentTimeMillisUnsafe() - Math.round(process.uptime() * 1000),
          memory: () => process.memoryUsage(),
          children: async () => programsIn(await (table = platform.processTable(false)), MbProcess.live().map((p) => p.pid)),
          front: async () => {
            // (let go once read: the machine's table is not kept between samples)
            const current = table;
            table = null;
            return frontIn(await (current ?? platform.processTable(false)), underLauncher ? process.ppid : null, process.pid);
          },
          pressure: () => platform.memoryPressure(),
          trimIdle: () => readers.trimIdle(),
          evictWarm: () => hub.evictAllIdle(),
          handover: () => restarter(data),
          // (the front held past its limit started anew, the Node handed over to one linked to it: the launcher's)
          ...(restartFront ? { restartFront: async () => restartFront() } : {}),
        });
        governor.start();
        return governor;
      }),
      (g) => Effect.promise(() => g.close()),
    );
    // What processes used is read on macOS and Linux; elsewhere (Windows) there is nothing to look at.
    const linux = platform.os === "linux";
    if (platform.os !== "macos" && !linux) {
      (yield* Parts).routes((tools) => resourceRoutes(tools, null));
      return;
    }
    const mesh = loadMesh();
    const isApp = appBundles();
    const whose = runnerSessions(store, (runners) => hub.runnerNameSessions(runners));
    const watch = yield* Effect.acquireRelease(
      Effect.sync(() => new ResourceWatch({
        clock: hub.clock,
        table: () => platform.processTable(false),
        args: async () => parseArgs((await run("ps", ["-axo", "pid=,args="], { maxBuffer: 32 << 20 })).stdout),
        // A chat's own directory, not where it works (a repository people also work in).
        places: () => store.liveSessions().flatMap((s) => (s.workspace && s.workspace !== "/" && s.workspace !== homedir() ? [{ dir: s.workspace, session: s.key }] : [])),
        placesInArguments: (lines) => hub.sessionsInArguments(lines, homedir()),
        usage: (pids) => (linux ? linuxUsage(pids) : typeof mesh.processUsage === "function" ? mesh.processUsage(pids) : pids.map(() => null)),
        // Every process's, once: some 20 ms. Linux has none to read without root.
        ...(linux ? {} : { traffic: async () => parseNettop((await run("nettop", ["-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out", "-n"], { maxBuffer: 16 << 20, timeout: 5000 })).stdout) }),
        runners: () => runnersWithSessions(data, whose),
        jobs: () => watchedJobs(store, hub.processJobLookup()),
        isApp,
        self: [process.pid, ...(underLauncher ? [process.ppid] : [])],
      })),
      (w) => Effect.promise(() => w.close()),
    );
    // What was kept of the hours' energy before (no longer counted).
    void rm(join(data, "resources", "hours.json"), { force: true }).catch(() => {});
    (yield* Parts).routes((tools) => resourceRoutes(tools, watch));
  }),
);
