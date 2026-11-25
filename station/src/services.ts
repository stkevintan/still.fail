// The station's services: what its parts are given, each a Context key with the layer that makes it. Async and
// long-lived work is Effect (fibers in scopes: a part stopped stops all it started); computing what to answer is plain
// functions (src/read). 「模块划分」.
import { cloudEntry } from "./cloud/transport.ts";
import { Clock, Context, Effect, Layer, Queue, Stream, SubscriptionRef } from "effect";
import { homedir } from "node:os";
import { join } from "node:path";
import { Admin } from "./api/admin.ts";
import { Events as EventStreams, eventsHandoverFile } from "./api/events.ts";
import { Host } from "./api/host.ts";
import { EgressLook } from "./api/egress.ts";
import { jobSeen, seerOf, sessionSeen, threadSeen } from "./api/seen.ts";
import { Store as StationStore } from "./store/store.ts";
import { sees } from "./store/rows.ts";
import { buildLegacyEntryLookups } from "./store/legacy-said-builder.ts";
import { type StationKey, loadKey } from "./cloud/key.ts";
import { Cloud as CloudState } from "./cloud/state.ts";
import { type ControlPlaneShape, makeControlPlane } from "./cloud/plane.ts";
import type { Provider } from "./cloud/provider.ts";
import { type Mesh, loadMesh, withRelays } from "./mesh/native.ts";
import { withFront } from "./mesh/front.ts";
import { verifyWith } from "../../shared/lock.ts";
import { Readers as ReaderPool } from "./read/pool.ts";
import { warmPionProbeForConfig } from "./read/mb-reader.ts";
import type { ReaderSelectConfig } from "./read/reader-select.ts";
import { repairMergedEditLookup } from "./store/schema.ts";
import { makeStore } from "./read/store.ts";
import { apiOf, entryViews, spokenIn } from "./read/views.ts";
import { KnownNames } from "./read/slack-known.ts";
import type { AgentsParts } from "./sessions/agents.ts";
import { PackedProgram } from "./sessions/packed-mb.ts";
import type { Rig } from "./rig/module.ts";
import { platform } from "./platform/index.ts";
import { ScreenHub } from "./screens/hub.ts";
import { Desktop } from "./screens/desktop.ts";
import { Simulators } from "./screens/simulator.ts";
import { WindowsDesktop, screenBinary } from "./screens/win-desktop.ts";
import { LinuxDesktop } from "./screens/linux-desktop.ts";
import { linuxScreenBinary } from "./screens/linux-native.ts";
import { uiBinary } from "./screens/ui.ts";
import { type Drive, droppedInto, stationDrive } from "./drive/drive.ts";
import { stationVersion } from "./ops/version.ts";
import { channelOf } from "./updates/versions.ts";
import { HelperApp, helperApp } from "./helper/app.ts";
import { HelperGrants } from "./helper/grants.ts";
import { HelperFiles } from "./helper/files.ts";
import { ConfigFile } from "./ops/config.ts";
import { Own as OwnPaths } from "./ops/own.ts";
import { previousExited, previousProcess } from "./ops/previous.ts";
import { PeerBus } from "./mesh/bus.ts";
import type { Outside } from "./mesh/peer.ts";
import { Net } from "./jobs/load.ts";
import type { PeerRoute } from "./tools/http.ts";
import type { HereLocal } from "./mesh/peer-http.ts";
import type { Traces } from "./mesh/traces.ts";
import type { Json } from "./store/store.ts";
import { StationParts } from "./parts.ts";
import { wall } from "./ops/fibers.ts";


/// Where the station keeps its data, and the release it runs from.
/// `beforeStore`: what is done before the store first opens (a lost station's chats taken back: replica/restore.ts,
/// given by main.ts).
/// The station's directories, and what of its launcher the parts ask (ops/launcher.ts): `restartFront` where it keeps a
/// front it can start anew.
export class Paths extends Context.Service<Paths, { readonly data: string; readonly app: string; readonly beforeStore?: () => Promise<void>; readonly restartFront?: () => void }>()("stillfail/Paths") {}

/// The control plane this station is enrolled in (cloud/plane.ts): cloud.json and its changes, the presence socket,
/// notices, traces, releases and which credentials it takes. `layer` follows cloud.json's provider (still.fail cloud
/// when it names none); `layerFor` keeps to one (tests).
export class ControlPlane extends Context.Service<ControlPlane, ControlPlaneShape>()("stillfail/ControlPlane") {
  static readonly layer = ControlPlane.make();
  static layerFor(provider: Provider) {
    return ControlPlane.make(provider);
  }

  private static make(provider?: Provider) {
    return Layer.effect(
      ControlPlane,
      Effect.gen(function* () {
        const { data, app } = yield* Paths;
        const key = yield* Key;
        const up = yield* Up;
        const clock = yield* Clock.clockWith(Effect.succeed);
        const config = yield* StationConfig;
        const state = yield* Effect.acquireRelease(Effect.sync(() => new CloudState(data, true, clock, () => cloudEntry(config.raw()))), (s) => Effect.promise(async () => { await s.close(); }));
        const changes = Stream.callback<void>((queue) =>
          Effect.acquireRelease(
            Effect.sync(() => state.listen(() => void Queue.offerUnsafe(queue, undefined))),
            (unlisten) => Effect.sync(unlisten),
          ),
        );
        // (the platform's, not process.platform: test/platform.test.ts)
        const traceResource: [string, string][] = [["service.version", stationVersion(app) ?? ""], ["os.type", platform.buildOs ?? platform.os], ["host.arch", process.arch], ["process.runtime.name", "nodejs"]];
        return ControlPlane.of(makeControlPlane({ state, changes, key, up, provider, traceResource }));
      }),
    );
  }
}

/// The station's key.
export class Key extends Context.Service<Key, StationKey>()("stillfail/Key") {
  static readonly layer = Layer.effect(
    Key,
    Effect.gen(function* () {
      return loadKey((yield* Paths).data);
    }),
  );
}

/// Whether the station answers now: its parts started, not stopping or handing over.
export class Up extends Context.Service<Up, SubscriptionRef.SubscriptionRef<boolean>>()("stillfail/Up") {
  static readonly layer = Layer.effect(Up, SubscriptionRef.make(false));
}

/// The readers (the MoonBit program's processes) answering the admin API's reads.
export class Readers extends Context.Service<Readers, ReaderPool>()("stillfail/Readers") {
  static readonly layer = Layer.effect(
    Readers,
    Effect.gen(function* () {
      const { data } = yield* Paths;
      const store = yield* Store;
      const previous = yield* Previous;
      const readerConfig = yield* ReaderConfig;
      yield* Effect.acquireRelease(
        Effect.sync(() => {
          const builder = buildLegacyEntryLookups(store, previous.exited, undefined, undefined, readerConfig);
          const wait = () => builder.waitForDecisionSessions();
          store.waitForDecisionSessions = wait;
          return { builder, wait };
        }),
        ({ builder, wait }) => Effect.promise(async () => {
          if (store.waitForDecisionSessions === wait) store.waitForDecisionSessions = null;
          await builder.close();
        }),
      );
      return yield* Effect.acquireRelease(Effect.sync(() => {
        // The usage checker (`startUsageIndex`, reader `--builder usage-check`) only says whether the statistics are
        // complete, filling nothing: it is started by the read that finds them not yet (pool.ts `usageRead`), not here.
        const pool = new ReaderPool(data, undefined, undefined, undefined, { previousGone: previous.exited, priority: store.backfillPriority, readers: readerConfig });
        // (the merged view a builder leaves to the writer, repaired on the station's one write connection, which waits
        // for no lock meanwhile: one held elsewhere is SQLITE_BUSY, and the builder asks again after a pause)
        pool.repairEdits = () => {
          const timeout = Number((store.db.prepare("PRAGMA busy_timeout").get() as { timeout: number }).timeout);
          store.db.exec("PRAGMA busy_timeout = 0");
          try { repairMergedEditLookup(store.db); } finally { store.db.exec(`PRAGMA busy_timeout = ${timeout}`); }
        };
        pool.warm();
        return pool;
      }), (pool) => Effect.sync(() => pool.close()));
    }),
  );
}

/// The store's log written into the database by the readers as the store changes (read/pool.ts `checkpointSoon`), not
/// by the main thread (store.ts).
export const CheckpointsLive = Layer.effectDiscard(
  Effect.gen(function* () {
    const store = yield* Store;
    const readers = yield* Readers;
    yield* Effect.acquireRelease(
      Effect.sync(() => store.subscribe(() => readers.checkpointSoon())),
      (off) => Effect.sync(off),
    );
  }),
);

/// The station's store (stillfail.db, archive/): what is written, on this thread; the readers read the same file.
export class Store extends Context.Service<Store, StationStore>()("stillfail/Store") {
  static readonly layer = Layer.effect(
    Store,
    Effect.gen(function* () {
      const { data, beforeStore } = yield* Paths;
      if (beforeStore !== undefined) yield* Effect.promise(beforeStore);
      return yield* Effect.acquireRelease(
        Effect.sync(() => {
          return StationStore.open(join(data, "stillfail.db"), join(data, "archive"));
        }),
        (store) => Effect.sync(() => store.close()),
      );
    }),
  );
}

/// Start the store before the readers, and keep the same store available to the station's other parts.
export const ReadersAndStore = Readers.layer.pipe(Layer.provideMerge(Store.layer));

/// still.fail Helper (macOS §4), installed and talked to under <data>/helper: this Mac's
/// screen (the desktop's) and the drive's protected folders (helper/files.ts); null where there is none.
export class Helper extends Context.Service<Helper, HelperApp | null>()("stillfail/Helper") {
  static readonly layer = Layer.effect(
    Helper,
    Effect.gen(function* () {
      const { data } = yield* Paths;
      const app = platform.desktopScreen === "helper" ? helperApp() : null;
      return app === null ? null : new HelperApp({ app, dir: join(data, "helper") });
    }),
  );
}

/// What macOS lets still.fail Helper do here (helper/grants.ts): one look at its grants and one window asking for them,
/// for the desktop's screen, the drive, the station's page and the agents; null where there is no helper.
export class Grants extends Context.Service<Grants, HelperGrants | null>()("stillfail/Grants") {
  static readonly layer = Layer.effect(
    Grants,
    Effect.gen(function* () {
      const helper = yield* Helper;
      return helper === null ? null : new HelperGrants({ helper, folders: platform.hasFolderPermissions });
    }),
  );
}

/// The screens members see and drive: the registry the station's parts add their sources to
/// (`add`), with this machine's display among them from the start; views of them end as the station stops.
export class ScreenRegistry extends Context.Service<ScreenRegistry, ScreenHub>()("stillfail/Screens") {
  static readonly layer = Layer.effect(
    ScreenRegistry,
    Effect.gen(function* () {
      // (the Downloads looked at off the thread, before the screens are listed)
      const drop = yield* Effect.promise(() => droppedInto(homedir()));
      const hub = yield* Effect.acquireRelease(Effect.sync(() => new ScreenHub({ drop })), (hub) => Effect.sync(() => hub.close()));
      const helper = yield* Helper;
      const { data } = yield* Paths;
      const title = process.env.STILLFAIL_TEST_HOST === "1" ? () => "test-station" : undefined;
      // Windows': stillfail-screen; macOS's: still.fail Helper; Linux's: the station user's desktop session.
      const desktop: Desktop | WindowsDesktop | LinuxDesktop =
        platform.desktopScreen === "screen"
          ? new WindowsDesktop({ binary: screenBinary(), ui: uiBinary(), changed: () => hub.changed(), title })
          : platform.desktopScreen === "x11"
          ? new LinuxDesktop({ data, changed: () => hub.changed(), title, nativeBinary: linuxScreenBinary() })
          : new Desktop({ supported: platform.desktopScreen === "helper", helper, grants: yield* Grants, changed: () => hub.changed(), title });
      // Back after it ended by itself: the desktop asks again for a grant still missing.
      if (desktop instanceof Desktop) helper?.onBack(() => void desktop.helperBack());
      yield* Effect.acquireRelease(
        Effect.sync(() => {
          const remove = hub.add(desktop);
          // Its size and grants are looked at as the screens are asked for (the helper started then, not before).
          const unrefresh = hub.refresher(() => desktop.refresh());
          return () => (unrefresh(), remove(), void desktop.close());
        }),
        (stop) => Effect.sync(stop),
      );
      // The iOS Simulators booted on this Mac, each a screen while it is (still.fail Helper's, as the desktop is).
      yield* Effect.acquireRelease(
        Effect.sync(() => {
          const simulators = new Simulators({ screens: hub, helper });
          void simulators.start();
          const unrefresh = hub.refresher(() => simulators.refresh());
          return () => (unrefresh(), simulators.close());
        }),
        (stop) => Effect.sync(stop),
      );
      return hub;
    }),
  );
}

/// The event streams (GET /events): the store's changes, pushed. What they told goes on in the next process (a
/// handover, or the next start), taken up once this one is gone.
export class Events extends Context.Service<Events, EventStreams>()("stillfail/Events") {
  static readonly layer = Layer.effect(
    Events,
    Effect.gen(function* () {
      const store = yield* Store;
      const readers = yield* Readers;
      const admin = yield* AdminHost;
      const screens = yield* ScreenRegistry;
      const { data } = yield* Paths;
      const previous = yield* Previous;
      // What was just said, made as the pages show it on this thread: over the store's own connection (what it just
      // wrote is in its memory), with the names the readers are given.
      const view = Object.assign(makeStore(store.db, data), { names: readers.names });
      // and the config and names books as the station holds them, so a message said looks at no file
      const config = yield* StationConfig;
      const known = yield* Effect.acquireRelease(Effect.sync(() => new KnownNames(data, () => config.raw())), (known) => Effect.sync(() => known.close()));
      const events = new EventStreams({
        readers,
        said: (thread, entries, lang) => spokenIn(lang, () => entryViews(apiOf(view, config.raw(), known), thread, entries)),
        subscribe: (listener) => store.subscribe(listener),
        host: () => admin.sample(),
        jobLog: (id) => store.getJob(id)?.log ?? null,
        logNow: async (id, lines) => {
          try {
            const read = JSON.parse(await readers.read("jobLog", { id, lines: String(lines) }, "zh", { told: true }));
            return { text: read.text, outputAt: read.outputAt ?? null };
          } catch {
            return null;
          }
        },
        sessionExists: (key) => store.getSession(key) !== null,
        liveSeen: (viewer, key) => { const ws = store.sessionWs(key); return ws !== undefined && sees(viewer, ws); },
        seen: (viewer, of) => ("session" in of ? sessionSeen(store, viewer, of.session) : "thread" in of ? threadSeen(store, viewer, of.thread) : jobSeen(store, viewer, of.job)),
        seer: (of) => seerOf(store, of),
        handover: { file: eventsHandoverFile(data), previous },
      });
      // Handed over as the station stops, after the parts made on it (the agents' side has handed over its sessions,
      // the mesh let go of every stream): the last it tells is told by then.
      yield* Effect.addFinalizer(() => Effect.promise(() => events.handOver()));
      // The screens as they change, and who is on them (`screens`).
      yield* Effect.acquireRelease(
        Effect.sync(() => screens.onChange(() => events.screens((lang) => screens.listed(lang)))),
        (off) => Effect.sync(off),
      );
      return events;
    }),
  );
}

/// The machine's state, shared by GET /host, the events and what other stations are told of this one's load; its
/// CPUs noted every few seconds for their recent average (Host.follow) while the station runs.
export class AdminHost extends Context.Service<AdminHost, Host>()("stillfail/AdminHost") {
  static readonly layer = Layer.effect(
    AdminHost,
    Effect.gen(function* () {
      const host = new Host((yield* Readers).data, undefined, undefined, new EgressLook());
      yield* Effect.acquireRelease(Effect.sync(() => host.follow()), (stop) => Effect.sync(stop));
      return host;
    }),
  );
}

/// config.json (ops/config.ts): one for the whole station. What an edit must pass is said by the parts that read it
/// (the agents' side: accounts/check.ts).
export class StationConfig extends Context.Service<StationConfig, ConfigFile>()("stillfail/Config") {
  static readonly layer = Layer.effect(
    StationConfig,
    Effect.gen(function* () {
      const { data } = yield* Paths;
      return yield* Effect.acquireRelease(Effect.sync(() => {
        const config = new ConfigFile(data);
        config.watch();
        return config;
      }), (config) => Effect.promise(async () => {
        config.unwatch();
        // What was taken is on disk before the next process reads it.
        await config.written();
      }));
    }),
  );
}

/// Live in-memory snapshot of `config.json`'s `readers` map, initialized once from the watched `ConfigFile`
/// and updated via `config.listen(...)` (zero per-request `readFileSync`/`config.raw()`, zero module globals).
export function makeReaderConfigSnapshot(config: ConfigFile): { get: () => ReaderSelectConfig; stop: () => void } {
  const extract = (raw: any): ReaderSelectConfig => {
    const readers = raw?.readers;
    if (readers !== null && readers !== undefined && typeof readers === "object" && !Array.isArray(readers)) {
      return { readers: { ...readers } };
    }
    return undefined;
  };
  let snapshot: ReaderSelectConfig = extract(config.raw());
  const stop = config.listen((raw) => {
    snapshot = extract(raw);
  });
  return { get: () => snapshot, stop };
}

/// Extract the `ReaderSelectConfig` shape passed to cold `takeBackSoon` from `settings.raw()` (`main.ts:236`).
export function restoreReaderConfig(raw: { readonly readers?: Readonly<Record<string, unknown>> | null } | null | undefined): ReaderSelectConfig {
  return raw?.readers ? { readers: raw.readers } : undefined;
}

/// Live in-memory getter of `config.json`'s `readers` engine overrides for every reader/builder spawn.
export class ReaderConfig extends Context.Service<ReaderConfig, () => ReaderSelectConfig>()("stillfail/ReaderConfig") {
  static readonly layer = Layer.effect(
    ReaderConfig,
    Effect.gen(function* () {
      const config = yield* StationConfig;
      const snap = yield* Effect.acquireRelease(
        Effect.sync(() => makeReaderConfigSnapshot(config)),
        (s) => Effect.sync(() => s.stop()),
      );
      yield* Effect.promise(() => warmPionProbeForConfig(snap.get()));
      return snap.get;
    }),
  );
}

/// Station-scoped `--builder packed` program bound to this station's `ReaderConfig` snapshot (isolated per station,
/// never overwriting the config-free module singleton `packedProgram()`).
export class StationPacked extends Context.Service<StationPacked, PackedProgram>()("stillfail/Packed") {
  static readonly layer = Layer.effect(
    StationPacked,
    Effect.gen(function* () {
      const readerConfig = yield* ReaderConfig;
      return yield* Effect.acquireRelease(
        Effect.sync(() => new PackedProgram({ readers: readerConfig })),
        (program) => Effect.promise(() => program.close()),
      );
    }),
  );
}

/// What is the station's own on this machine (ops/own.ts): its data and config, and what its parts add as they are made.
export class Own extends Context.Service<Own, OwnPaths>()("stillfail/Own") {
  static readonly layer = Layer.effect(
    Own,
    Effect.gen(function* () {
      return new OwnPaths((yield* Paths).data, (yield* StationConfig).path);
    }),
  );
}

/// The station process before this one (ops/previous.ts), and its end: what only one process may have waits on it, and
/// what its event streams told is taken up from it alone (api/events.ts). Looked for as this process starts, before it
/// writes its own run/hub.json.
export class Previous extends Context.Service<Previous, { readonly pid: number | null; readonly gone: Promise<void>; readonly exited: Promise<void> }>()("stillfail/Previous") {
  static readonly layer = Layer.effect(
    Previous,
    Effect.gen(function* () {
      const previous = previousProcess(join((yield* Paths).data, "run"));
      return { ...previous, exited: previousExited(previous) };
    }),
  );
}

/// The station's requests to and from the other stations of its workspace (mesh/bus.ts): the mesh attaches the
/// transport, the parts say what they answer.
export class Peers extends Context.Service<Peers, PeerBus>()("stillfail/Peers") {
  static readonly layer = Layer.sync(Peers, () => new PeerBus({ sleep: (ms) => wall.sleep(ms) }));
}

/// What the mesh (mesh/mesh.ts) shares with the agents' side, each filled by the one that has it: the relay link as the
/// mesh sees it (`net`, told to other stations with this one's load), the mesh's way to other stations' web services
/// (`peers`, the agents' door's /peer requests), and what the agents say: the stations of other workspaces this one
/// shares chats with (`outside`), a port of another station forwarded here (`forwarded`), the runtimes its device tools
/// see (`runtimes`). The mesh no longer reaches into the agents' side.
export type MeshSideShape = {
  relayControl?: { list(workspace: string): unknown[]; revoke(workspace: string, node: string): Promise<unknown> };
  readonly net: Net;
  readonly peers: { route: PeerRoute | null };
  outside: Outside | null;
  forwarded: (port: number) => boolean;
  runtimes: () => string[];
  /// A connection to a device attached here, for a chat of another station (devices/module.ts): what peer-http.ts's
  /// `HereLocal.device` is; none until the devices' part is up.
  device: HereLocal["device"] | null;
  /// Active OTLP trace batcher (mesh/mesh.ts), null when mesh is not up or telemetry.traces is false.
  traces?: Traces | null;
};
export class MeshSide extends Context.Service<MeshSide, MeshSideShape>()("stillfail/MeshSide") {
  static readonly layer = Layer.sync(MeshSide, (): MeshSideShape => ({ net: new Net(), peers: { route: null }, outside: null, forwarded: () => false, runtimes: () => [], device: null, traces: null }));
}

/// A device as an agent is shown it (devices/, 2026-11-10): what it is, where it is attached, whose it is, and whether
/// this chat may use it now and who may.
export type DeviceEntry = {
  id: string; name: string; kind: string; target: string; baud?: number;
  /// Where it is attached: a station's id and name (`via: station`), a tasks-only station's (`rig`), or its person's
  /// phone itself (`phone`, its app lending it).
  via: "station" | "rig" | "phone"; station: string; stationName: string;
  owner: string; ownerEmail: string; ownerName: string;
  online?: boolean; thisChat: string; hasAccess: string | string[];
};
/// Where devices come from besides this station's own whole ones (devices/module.ts): the tasks-only stations'
/// (rigs/module.ts) and the members' phones (adb/module.ts), each filled by its part.
export type DeviceSource = {
  list(workspace: string, session: string): Promise<DeviceEntry[]>;
  /// What the agent is told of asking for `device` (its id or name, as found by `list`).
  use(workspace: string, session: string, device: DeviceEntry, reason: string, timeout: unknown, signal?: AbortSignal): Promise<string>;
  /// The chat's grants (or requests) of devices of this source handed back (one, or every one: none named): their names.
  done(workspace: string, session: string, device: DeviceEntry | null): string[];
  /// What the members' apps are shown of them (the phones lent here, with the chats that hold each); none: nothing.
  shown?(workspace: string): Json[];
};
/// `forward`: the devices' part's, a device a chat may use put on a port here for it (what the agent is told of it).
export type DeviceSourcesShape = {
  rigs: DeviceSource | null; phones: DeviceSource | null;
  forward: ((session: string, device: DeviceEntry) => Promise<string>) | null;
  /// What the members' apps are shown changed (a phone lent or gone, a grant of it): told again.
  changed: ((workspace: string | null) => void) | null;
};
export class DeviceSources extends Context.Service<DeviceSources, DeviceSourcesShape>()("stillfail/DeviceSources") {
  static readonly layer = Layer.sync(DeviceSources, (): DeviceSourcesShape => ({ rigs: null, phones: null, forward: null, changed: null }));
}

/// The station's parts in its own process (parts.ts): what each adds to the admin API, the overview and the agents'
/// tools, said as it is made.
export class Parts extends Context.Service<Parts, StationParts>()("stillfail/Parts") {
  static readonly layer = Layer.sync(Parts, () => new StationParts());
}

/// The folders macOS protects (Documents, Desktop, Downloads, disks) through still.fail Helper (helper/files.ts): the
/// drive's, a search's and the directories people and agents name; none where there is no helper for them. Their
/// grants' changes are the overview's.
export class HelperFolders extends Context.Service<HelperFolders, HelperFiles | null>()("stillfail/HelperFolders") {
  static readonly layer = Layer.effect(
    HelperFolders,
    Effect.gen(function* () {
      const grants = yield* Grants;
      const events = yield* Events;
      return grants && platform.hasFolderPermissions ? new HelperFiles({ helper: grants.helper, grants, changed: () => events.overviewChanged() }) : null;
    }),
  );
}

/// The station's drive (drive/drive.ts): one, for the admin API's routes and the modules' local API.
/// config.json's roots; what is the station's own never reached; the folders macOS protects through still.fail Helper.
export class StationDrive extends Context.Service<StationDrive, Drive>()("stillfail/Drive") {
  static readonly layer = Layer.effect(
    StationDrive,
    Effect.gen(function* () {
      const own = yield* Own;
      return stationDrive(yield* StationConfig, () => own.more(), yield* HelperFolders);
    }),
  );
}

/// The agents' side once it is made (sessions/agents.ts sets it): the admin API is made before it and asks for it as a
/// request comes; nothing of the platform waits on it.
export class AgentsSide extends Context.Service<AgentsSide, { current: AgentsParts | null }>()("stillfail/AgentsSide") {
  static readonly layer = Layer.sync(AgentsSide, () => ({ current: null }));
}

/// The rig, once made: what the mesh asks of it (pure rig or mixed-mode station).
export class RigSide extends Context.Service<RigSide, { current: Rig | null }>()("stillfail/RigSide") {
  static readonly layer = Layer.sync(RigSide, () => ({ current: null }));
}

/// The admin API: the platform's routes, the agents' side's as a request comes (AgentsSide), the parts' (parts.ts).
export class AdminApi extends Context.Service<AdminApi, Admin>()("stillfail/AdminApi") {
  static readonly layer = Layer.effect(
    AdminApi,
    Effect.gen(function* () {
      const side = yield* AgentsSide;
      const config = yield* StationConfig;
      const readerConfig = yield* ReaderConfig;
      const packed = yield* StationPacked;
      const paths = yield* Paths;
      return new Admin(yield* Readers, {
        store: yield* Store, events: yield* Events, host: yield* AdminHost, agents: () => side.current ?? undefined, screens: yield* ScreenRegistry, helper: yield* Helper, grants: yield* Grants,
        drive: yield* StationDrive, parts: yield* Parts, config, readerConfig, packed, data: paths.data, cloud: (yield* ControlPlane).state,
        ...(paths.restartFront ? { restartFront: paths.restartFront } : {}),
      });
    }),
  );
}

/// The native mesh addon.
export class MeshNative extends Context.Service<MeshNative, Mesh>()("stillfail/MeshNative") {
  // (and the lock's and the vault's signatures checked by its libcrux from now on, where it has it: cloud/lock.ts)
  static readonly layer = Layer.effect(MeshNative, Effect.sync(() => {
    const mesh = loadMesh();
    if (mesh.verify) verifyWith((alg, key, signature, message) => mesh.verify!(alg, key, signature, message));
    // The endpoint kept by the MoonBit front where the launcher started one (mesh/front.ts), across handovers.
    const front = process.env.STILLFAIL_MESH_FRONT;
    return front ? withFront(mesh, front) : withRelays(mesh);
  }));
}
