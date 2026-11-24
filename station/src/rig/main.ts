// A rig's process (a station that only runs tasks, 2026-11-10): the composition root of a machine that joined its workspace as a rig
// (`enroll --rig`, cloud.json's `rig`), in the place of the station's (main.ts). The same release, launcher and
// updates; of a station's parts only those that are asked by another station: the mesh's station transport (no
// members' links, no gateway's tools), the jobs, the tasks other stations send (jobs/remote.ts), a command run with
// a secret a station sends along (vault/incoming.ts), and the rig's own say over who may use it (rig/module.ts). No
// agents, sessions, chats, connects, accounts, vault or drive are made here: there is nothing in this process that
// could run one.
import { closePeerRelays } from "../mesh/peer-relays.ts";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Effect, Layer, Option, Stream, SubscriptionRef } from "effect";
import { Jobs, notifyEndpoint, screenEndpoint } from "../jobs/jobs.ts";
import { measure } from "../jobs/load.ts";
import { liveMemory } from "../jobs/memory.ts";
import { Remote, followRoster } from "../jobs/remote.ts";
import { accept } from "../mesh/accept.ts";
import { lanAddrs } from "../mesh/lan.ts";
import { applyNetwork, keptRunning } from "../mesh/mesh.ts";
import { bindStation } from "../mesh/native.ts";
import { PEER_ALPN, PEER_BYTES_ALPN, peerCall, servePeer } from "../mesh/peer.ts";
import { DeviceRefused, PEER_HTTP_ALPN, rigAllowed, serveHttp } from "../mesh/peer-http.ts";
import { keepRelays, wantedRelays } from "../mesh/relays.ts";
import { congestionOf } from "../mesh/settings.ts";
import { Fibers } from "../ops/fibers.ts";
import { DISK_EVERY_MS, diskEvery, diskSoft, diskTier } from "../ops/disk.ts";
import { Upkeep, diskOf } from "../ops/storage.ts";
import { sweepRunners } from "../agents/runner.ts";
import { mcpPortFile, ownData, portsToTry, rememberedMcpPort } from "../ops/files.ts";
import type { Control } from "../ops/launcher.ts";
import { log } from "../ops/log.ts";
import { becomeOther } from "../ops/restart.ts";
import { stationLog } from "../ops/log-export.ts";
import { AdminHost, AgentsSide, ControlPlane, Key, MeshNative, MeshSide, Paths, Peers, Previous, ReaderConfig, RigSide, StationConfig, Store, Up } from "../services.ts";
import { type AgentsDoor, openAgentsDoor } from "../tools/http.ts";
import { McpEndpoint } from "../tools/mcp.ts";
import { makeUpdates } from "../updates/updates.ts";
import { Incoming } from "../vault/incoming.ts";
import { Proxy } from "../vault/proxy.ts";
import { Rig } from "./module.ts";

/// `remote:<workspace>:<station>:<session>`: whose a task's job is (jobs/remote.ts `owner`). A session's key has
/// colons of its own; a workspace's id and a station's have none.
const ownerOf = (workspace: string, station: string, session: string) => `remote:${workspace}:${station}:${session}`;
function owned(sessionKey: string): { workspace: string; station: string; session: string } | null {
  const m = /^remote:([^:]*):([^:]*):(.*)$/s.exec(sessionKey);
  return m === null ? null : { workspace: m[1]!, station: m[2]!, session: m[3]! };
}

/// Rig-side part for a mixed-mode station (at least one full workspace, plus zero or more rig-mode workspaces).
/// Mounted as a station part after `AgentsLive` so platform and agents layers do not import `rig/` at runtime.
export const MixedRigLive = Layer.effectDiscard(
  Effect.gen(function* () {
    const { data } = yield* Paths;
    const store = yield* Store;
    const plane = yield* ControlPlane;
    const bus = yield* Peers;
    const side = yield* RigSide;
    const agents = (yield* AgentsSide).current;
    const rig = new Rig({
      data,
      cloud: plane.state,
      bus,
      fibers: new Fibers("rig", agents?.hub.clock),
      busy: (workspace, station, session) => store.runningJobsAtLeast(ownerOf(workspace, station, session), 1),
      stop: async (workspace, station, session) => {
        for (const id of store.upJobIds(ownerOf(workspace, station, session))) {
          await agents?.jobs.stop(id).catch((error) => log.warn("rig", "a task of a chat that lost this rig was not stopped", { job: id, error: (error as Error).message }));
        }
      },
      running: () => store.jobsRunning().flatMap((j) => owned(j.sessionKey) ?? []),
    });
    side.current = rig;
    agents?.remote.setDescribed((_peer, ws) => rig.described(ws));
    yield* Effect.addFinalizer(() =>
      Effect.promise(async () => {
        if (side.current === rig) side.current = null;
        await rig.close();
      }),
    );
  }),
);

/// What a rig runs and answers: the jobs, other stations' tasks, its grants, its own updates, and the door its jobs
/// reach it by (`stillfail-job`).
export const RigLive = (control: Control) =>
  Layer.effectDiscard(
    Effect.gen(function* () {
      const { data, app } = yield* Paths;
      const store = yield* Store;
      const plane = yield* ControlPlane;
      const cloud = plane.state;
      const config = yield* StationConfig;
      const readerConfig = yield* ReaderConfig;
      const host = yield* AdminHost;
      const up = yield* Up;
      const bus = yield* Peers;
      const previous = (yield* Previous).gone;
      const side = yield* RigSide;
      const net = (yield* MeshSide).net;
      const time = new Fibers("rig");
      const run = join(data, "run");

      const jobs = new Jobs({
        store, data,
        // No agent here to tell: what a task says is its record's, read by the station that sent it.
        notify: () => {},
        link: () => null,
      });
      const remote = new Remote({ data, store, jobs, notify: () => {}, bus, readers: readerConfig });
      const rig = new Rig({
        data, cloud, bus, fibers: time,
        busy: (workspace, station, session) => store.runningJobsAtLeast(ownerOf(workspace, station, session), 1),
        stop: async (workspace, station, session) => {
          for (const id of store.upJobIds(ownerOf(workspace, station, session))) {
            await jobs.stop(id).catch((error) => log.warn("rig", "a task of a chat that lost this rig was not stopped", { job: id, error: (error as Error).message }));
          }
        },
        running: () => store.jobsRunning().flatMap((j) => owned(j.sessionKey) ?? []),
      });
      side.current = rig;
      remote.setDescribed((_peer, ws) => rig.described(ws));
      const gpus = host.gpus;
      void gpus.read().catch(() => null);
      remote.setLoad(() =>
        measure({
          host, gpus,
          running: () => {
            const j = store.runningJobs();
            return { remoteTasks: j.remote, jobs: j.jobs, services: j.services, turns: 0 };
          },
          relay: () => net.seen(),
        }),
      );
      // A command a station sends to run with a secret one of its chats was granted: run here, the secret in no file.
      const runs = new Incoming({ proxy: new Proxy(join(data, "vault"), () => time.now()), now: () => time.now(), ask: (station, request) => bus.ask(station, request), workOf: (ws, peer, session) => remote.work(ws, peer, session) });
      bus.on("vault.", (peer, request, workspace) => runs.heard(peer, workspace ?? cloud.home() ?? "", request));
      // Tasks of stations no longer in the workspace stop, as on a station.
      let roster: (() => void) | null = null;
      bus.whenAttached(() => void (roster = followRoster(cloud, remote, config)));

      const memory = liveMemory({ data, store, jobs, notify: () => {}, clock: time.clock });
      memory.start();

      // Its own files held to their bounds, and room made as its disk fills (ops/storage.ts, ops/disk.ts): a machine
      // that only runs tasks keeps the mirrors and rooms of every chat that sends it one.
      const upkeep = new Upkeep({ data, clock: time.clock, runners: (now) => sweepRunners(data, now), jobs: (now) => jobs.upkeep(now), remote: (now, disk) => remote.upkeep(now, disk) });
      upkeep.start();
      // Room made as its disk fills: what is made again when asked for, then other stations' mirrors unused the longest
      // (jobs/remote.ts).
      const relieving = async () => {
        let tier: "ok" | "soft" | "low" = "ok";
        try {
          const disk = await diskOf(data);
          tier = diskTier(disk.free, disk.total);
          if (tier !== "ok") {
            await upkeep.renewables(time.now());
            await remote.relieve(time.now(), diskSoft(disk.total));
          }
        } catch (error) {
          log.warn("rig", "making room on the disk failed", { error: (error as Error).message });
        }
        time.after(diskEvery(tier), relieving); // timer: a sample of this machine (its disk)
      };
      time.after(DISK_EVERY_MS, relieving); // timer: a sample of this machine (its disk)

      // Its own release, read at start and as the cloud says one is out; updated by itself while nothing runs.
      const updates = makeUpdates({
        app, data, config, origin: () => plane.releaseBase(), running: () => 0, stationOnly: true,
        ...(control.runInstaller ? { launcherInstaller: control.runInstaller } : {}),
      });
      updates.start();
      plane.told("release", () => void updates.check().catch((error) => log.warn("updates", "the release not read", { error: String(error) })));
      control.on("hup", () => void updates.answerChannelAsk());

      // In its workspace or out of it, as cloud.json says: out of it, what it runs for the stations stops.
      const bound = () => cloud.rigMemberships().length > 0;
      let inWorkspace = bound();
      let giving = false;
      const follow = async () => {
        // No longer rig-only (has at least one full workspace now): hand over to StationLive.
        if (cloud.fullMemberships().length > 0) {
          log.warn("rig", "this machine has a full workspace now: the rig's process gives way to the station's");
          if (!giving) becomeOther(data);
          giving = true;
          return;
        }
        const now = bound();
        if (now === inWorkspace) return;
        inWorkspace = now;
        if (now) jobs.relaunch();
        else await jobs.stopAll(cloud.removed() ? "the rig was removed from its workspace" : "the rig is in no workspace");
      };
      yield* plane.changes.pipe(Stream.runForEach(() => Effect.promise(follow)), Effect.forkScoped);

      // The door its jobs reach it by (`stillfail-job notify`, `screen`): this machine's own, with no tool behind it.
      let door: AgentsDoor | null = null;
      const start = async () => {
        await Effect.runPromise(Effect.gen(function* () {
          if (!(yield* SubscriptionRef.get(up))) yield* SubscriptionRef.changes(up).pipe(Stream.filter((now) => now), Stream.runHead);
        }));
        await previous;
        mkdirSync(run, { recursive: true });
        const mcp = new McpEndpoint(() => undefined, []);
        const notified = (authorization: string | undefined, body: Buffer) => notifyEndpoint(jobs, authorization, body);
        const screened = (authorization: string | undefined, body: Buffer) => screenEndpoint(jobs, authorization, body);
        if (control.mcpFd !== undefined) door = await openAgentsDoor({ fd: control.mcpFd }, mcp, notified, () => null, () => [], screened);
        else if (control.ports) door = await openAgentsDoor({ port: 0, shown: control.ports.mcp }, mcp, notified, () => null, () => [], screened);
        else {
          const tries = portsToTry(undefined, rememberedMcpPort(data), 4750, ownData(data));
          for (const [i, port] of tries.entries()) {
            try {
              door = await openAgentsDoor({ port }, mcp, notified, () => null, () => [], screened);
              break;
            } catch (error) {
              if ((error as NodeJS.ErrnoException).code !== "EADDRINUSE" || i === tries.length - 1) throw error;
            }
          }
          writeFileSync(mcpPortFile(data), `{"port":${door!.port}}\n`);
        }
        jobs.setNotifyUrl(door!.url.replace(/\/mcp$/, "/jobs/notify"));
        control.serving("mcp", door!.port);
        if (inWorkspace) jobs.relaunch();
        else if (cloud.removed()) await jobs.stopAll("the rig was removed from its workspace");
      };
      yield* Effect.forkScoped(Effect.promise(() => start().catch((e) => {
        log.error("rig", "the rig did not start", { error: (e as Error).message });
        control.failed(`the rig did not start: ${(e as Error).message}`);
      })));


      // Nothing here to hand over turn by turn: drained at once.
      control.on("drain", () => {
        writeFileSync(join(run, "drained"), "idle\n");
        control.drained("idle");
      });

      yield* Effect.addFinalizer(() =>
        Effect.promise(async () => {
          side.current = null;
          roster?.();
          await door?.close(5_000);
          await memory.close();
          await upkeep.close();
          await rig.close();
          await remote.close();
          await jobs.shutdown();
          await updates.close();
          await time.close();
        }),
      );
    }),
  );

/// A rig on the mesh: its endpoint with the station transport alone, its presence at the control plane, and the
/// workspace's stations' connections, each request of theirs through the rig's grants.
export const RigMeshLive = Layer.effectDiscard(
  Effect.gen(function* () {
    const plane = yield* ControlPlane;
    const cloud = plane.state;
    const key = yield* Key;
    const native = yield* MeshNative;
    const previous = yield* Previous;
    const peers = yield* Peers;
    const config = yield* StationConfig;
    const side = yield* MeshSide;
    const rig = yield* RigSide;
    const { restartFront } = yield* Paths;
    const run = Effect.gen(function* () {
      if (!cloud.state) yield* plane.changes.pipe(Stream.filter(() => cloud.state !== null), Stream.runHead);
      if (Number(process.env.STILLFAIL_MESH_BIND_ADDR?.split(":").at(-1)) > 0) yield* Effect.promise(() => previous.gone);
      // Kept on the relays its workspace's ways keep on, as a station is (mesh/relays.ts).
      const bound = wantedRelays(cloud);
      const endpoint = yield* Effect.acquireRelease(
        Effect.promise(() => bindStation(native, { secretKey: key.seed, alpns: [PEER_HTTP_ALPN, PEER_BYTES_ALPN, PEER_ALPN], relayUrls: bound, discovery: process.env.STILLFAIL_NO_DISCOVERY !== "1", dht: process.env.STILLFAIL_NO_DHT !== "1", congestion: congestionOf(config.raw()) })),
        (endpoint) => Effect.ignore(Effect.timeoutOption(Effect.promise(() => endpoint.close()), "1 second")),
      );
      log.info("mesh", "rig listening", { rig: endpoint.id(), workspace: cloud.state!.workspace_name, sockets: endpoint.sockets(), lan: lanAddrs(endpoint.sockets()) });
      yield* Effect.acquireRelease(Effect.sync(() => applyNetwork(endpoint, config)), (off) => Effect.sync(off));
      yield* Effect.acquireRelease(Effect.sync(() => side.net.attach(() => endpoint.home())), (off) => Effect.sync(off));
      // An endpoint found stuck by its relays' probes (mesh/relays.ts `PROBE`): the front restarted, or closed and bound anew.
      yield* Effect.forkScoped(keepRelays(endpoint, side.net, bound, { onUnhealthy: restartFront ? () => restartFront() : () => void endpoint.close() }));
      yield* Effect.forkScoped(
        Effect.gen(function* () {
          const online = yield* Effect.timeoutOption(Effect.promise(() => endpoint.online()), "15 seconds");
          if (Option.isNone(online)) log.warn("mesh", `no relay link after 15 s; going online at ${plane.spec().name} anyway`);
          yield* plane.presence;
        }),
      );
      // What it tells the stations (rig/module.ts), and nothing it asks of them.
      const call = peerCall(endpoint, cloud);
      peers.attach(call);
      // (its watch of the ways, which lets go of connections through a relay turned off, ends with the mesh)
      yield* Effect.addFinalizer(() => Effect.sync(() => { call.close?.(); closePeerRelays(endpoint); }));
      stationLog.sendWith((body) => Effect.runPromise(plane.logs(body)));
      yield* accept(endpoint, {
        // (a station: what this one keeps to it, from before it started again, asked whether it is still there)
        arrived: (conn) => call.arrived(conn),
        serve: (conn) =>
          conn.alpn().equals(PEER_HTTP_ALPN)
            ? serveHttp(conn, cloud, {
                allowed: rigAllowed(rig),
                device: (peer, workspace, session, device, probe) => rig.current === null ? Promise.reject(new DeviceRefused(503, "the rig is starting")) : rig.current.device(peer, workspace, session, device, probe),
              })
            : servePeer(conn, cloud, peers),
        closing: "rig stopping",
      });
      // (as the station's does, mesh.ts: an endpoint that gives no more connections while the rig runs is bound again)
      return yield* Effect.fail(new Error("rig mesh endpoint accept ended"));
    });
    yield* Effect.forkScoped(keptRunning(run, "rig mesh"));
  }),
);
