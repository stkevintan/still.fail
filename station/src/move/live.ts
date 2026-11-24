// Migrations as a part of the station (move/AGENTS.md): made of what the composition root gives (parts.ts), the
// workspace's connects once they are made, `handover.*` and `move.*` answered, station_move given, its card chosen.
import { Effect, Layer } from "effect";
import { Fibers, wall } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { AdminApi, ControlPlane, Events, Key, Parts, Paths, Peers, Previous, Store } from "../services.ts";
import { Agents } from "../sessions/agents.ts";
import { chatCards } from "../replica/retire-asks.ts";
import { gitHere, gitRun } from "../replica/retire.ts";
import { ANSWER_SOON_MS, MoveAsks, moveTools } from "../tools/move.ts";
import { Moves } from "./station.ts";
import { moveRoutes } from "./routes.ts";
import { plainStore } from "../vault/plain.ts";
import { vaultStore } from "../vault/store.ts";

type Json = any;

export const MovesLive = Layer.effectDiscard(
  Effect.gen(function* () {
    const { data } = yield* Paths;
    const store = yield* Store;
    const bus = yield* Peers;
    const cloud = (yield* ControlPlane).state;
    const events = yield* Events;
    const parts = yield* Parts;
    const key = yield* Key;
    const agents = yield* Agents;
    const admin = yield* AdminApi;
    // (the station process handing over to this one: its move turns and hand-overs its own until it is gone)
    const previous = yield* Previous;
    const fibers = yield* Effect.acquireRelease(Effect.sync(() => new Fibers("move")), (f) => Effect.promise(() => f.close()));
    const roster = (ws: string) => {
      const m = cloud.membership(ws);
      if (m === null || !cloud.peersCurrent) return null;
      return m.peers.flatMap((p: Json) => (typeof p?.id === "string" ? [{ id: p.id as string, name: typeof p.name === "string" ? p.name : "", tasks: p.mode === "tasks" }] : []));
    };
    const hub = agents.hub;
    const wc = () => agents.workspaceConnects;
    // (a burst of changes, a file's progress among them, told once: what the app's page reads again, GET /move)
    let telling: (() => void) | null = null;
    const changed = () => {
      if (telling !== null) return;
      telling = fibers.after(500, () => { // timer: a debounce of a burst (each file's progress)
        telling = null;
        events.tell("move", { changed: true }, "move", {});
        events.overviewChanged();
      });
    };
    const moves = new Moves({
      data, store, fibers, roster, previous: previous.exited, previousPid: previous.pid,
      here: () => key.id,
      home: () => cloud.home(),
      ask: (station, request) => bus.ask(station, request),
      hub: {
        holdChat: (k, why, notice) => hub.holdChat(k, why, notice),
        releaseChat: (k) => hub.releaseChat(k),
        wakeChat: (k) => hub.wakeChat(k),
        busy: (k) => hub.busy(k),
        turnEnded: (k) => hub.turnEnded(k),
        drained: (c, ch, ts) => hub.drained(c, ch, ts),
        wsOf: (k) => hub.wsOf(k),
      },
      connects: {
        route: (id, ch, ts, to) => wc()!.route(id, ch, ts, to),
        describedFor: (id) => wc()?.describedFor(id) ?? null,
        learnOf: (known, station, d) => wc()?.learnOf(known, station, d),
        kindOf: (id) => wc()?.kindOf(id) ?? null,
        own: () => wc()?.ownIds() ?? [],
        ownIn: (ws) => wc()?.ownKinds(ws) ?? [],
        runsOn: (id) => wc()?.runsOn(id) ?? null,
        movedAway: (ws) => wc()?.movedAway(ws) ?? [],
        move: (id, to, awaiting) => wc()!.move(id, to, null, undefined, undefined, awaiting ?? []),
        arrived: async (keys) => wc()?.arrived(keys),
      },
      jobs: {
        // (of sessions `keys`, a chat's: by their index; of a workspace, a plan's: every job up, once a plan)
        up: (keys, ws) => (keys !== null ? store.jobsUpOf(keys) : store.jobsUp())
          .filter((j) => !j.sessionKey.startsWith("remote:") && (keys !== null || ws === undefined || hub.ofWorkspace(j.sessionKey, ws)))
          .map((j) => ({ id: j.id, session: j.sessionKey, name: j.name, command: j.command, cwd: j.cwd, port: j.port, watch: j.watch })),
        stop: async (id) => void (await agents.jobs.stop(id)),
        // (the jobs run in the MoonBit program, #6387: a start answers once it went, or with why not)
        start: async (j) => void (await agents.jobs.start(j.session, j.name, j.command, j.cwd ?? store.getSession(j.session)?.workspace ?? data, j.port ?? null, j.watch === true)),
        stopNamed: async (session, name) => {
          for (const j of store.jobsUpOf([session]).filter((x) => x.name === name)) await agents.jobs.stop(j.id);
        },
      },
      profiles: () => (Array.isArray(agents.config.raw()?.profiles) ? agents.config.raw().profiles : []),
      moveProfile: (id, to) => agents.sharing.moveProfile(id, to),
      shareMoves: {
        move: (id, to, made) => agents.sharing.moveProfile(id, to, undefined, made), unshare: (share, stations) => agents.sharing.unshareMoved(share, stations),
        lend: (id, to) => agents.sharing.lendTo(id, to), unlend: (share, to, made, widened) => agents.sharing.unlend(share, to, made, widened),
      },
      sessionsIn: (ws, after, limit) => store.sessionPageOfWs(cloud.home() === ws ? null : ws, cloud.home(), after, limit),
      reposDir: hub.reposDir(),
      clonesElsewhere: async () => (await hub.repoIndex.repos()).map((c) => c.path),
      git: gitRun,
      hasGit: gitHere,
      changed: () => changed(),
      config: agents.config,
      keptSends: (threads) => admin.keptSends(threads),
      keepSends: (sends) => admin.keepSends(sends),
      vault: {
        owners: (ws) => [...new Set([
          ...(store.db.prepare("SELECT DISTINCT owner FROM vault_plain WHERE ws = ? LIMIT 500").all(ws) as { owner: string }[]).map((r) => r.owner),
          ...vaultStore(store.db).vaults(ws).map((x) => x.owner),
        ])],
        // (each session's owners, of the grants it holds: one read for a page of chats)
        grantOwners: (keys) => {
          const out = new Map<string, string[]>();
          for (const r of store.db.prepare("SELECT session, body FROM vault_grants WHERE session IN (SELECT value FROM json_each(?)) ORDER BY session, rowid LIMIT ?").all(JSON.stringify(keys), keys.length * 50) as { session: string; body: string }[]) {
            let o: unknown;
            try {
              o = JSON.parse(r.body)?.request?.owner;
            } catch {}
            if (typeof o !== "string") continue;
            const list = out.get(r.session) ?? [];
            if (!list.includes(o)) list.push(o);
            out.set(r.session, list);
          }
          return out;
        },
        plain: plainStore(store.db),
        vaults: vaultStore(store.db) as Json,
      },
    });
    yield* Effect.addFinalizer(() => Effect.promise(() => moves.close()));
    const inWorkspace = (peer: string) => cloud.fullMemberships().some((m) => m.peers.some((p: Json) => p?.id === peer));
    const answers = moves.answers(inWorkspace);
    bus.on("handover.", answers);
    // (a station heard from again: what is owed to it of a hand-over is told now)
    bus.heard((peer) => {
      moves.handover.reached(peer);
      moves.heard(peer);
    });
    bus.on("move.", answers);
    // (a login home again, by any route: the share a trip made for it undone)
    agents.sharing.onHosted = (share, from) => void moves.shareCameHome(share, from).catch(() => {});
    // (the logins changed: what is stopped here for one looked at again, one that came by no move among them)
    const offLogins = agents.config.listen(() => moves.loginsChanged());
    yield* Effect.addFinalizer(() => Effect.sync(offLogins));
    const asks = new MoveAsks({
      data, scheduler: moves.scheduler,
      here: () => key.id,
      wsOf: (session) => hub.wsOf(session),
      roster,
      cards: chatCards(hub as Json),
      notify: (session, text) => hub.notify(session, text),
      ask: (station, request) => bus.ask(station, request),
      setWait: (w) => void (moves.wait = w),
      refusal: (ws, station) => moves.refusal(ws, station),
      room: (ws, station, ids) => moves.room(ws, station, ids),
      told: moves.told,
      soon: (what) => new Promise((resolve, reject) => {
        const off = wall.after(ANSWER_SOON_MS, () => resolve(null)); // timer: a deadline (a chat's station_move answers it is under way)
        what.then((value) => (off(), resolve({ value })), (e) => (off(), reject(e)));
      }),
    });
    bus.on("move.tool", async (peer, request, workspace) => {
      if (!inWorkspace(peer) || typeof workspace !== "string") throw new Error("not a station of this workspace");
      return asks.answer(peer, workspace, request);
    });
    parts.routes(moveRoutes({
      scheduler: moves.scheduler,
      order: () => moves.modules.map((m) => m.id),
      home: () => cloud.home(),
      name: (ws, id) => roster(ws)?.find((x) => x.id === id)?.name || null,
      station: (ws, v) => {
        const r = roster(ws)?.find((x) => x.id === v || x.name.toLowerCase() === v.toLowerCase() || (v.length >= 8 && x.id.startsWith(v)));
        return r === undefined ? null : { id: r.id, tasks: r.tasks || cloud.rigOf(r.id, ws) !== null };
      },
      here: () => key.id,
      rig: () => cloud.state?.rig !== undefined,
      refusal: (ws, station, lang) => moves.refusal(ws, station, lang),
      chatOf: (k) => moves.handover.chatOf(k),
    }));
    // (whether the app offers moving here: the switch; GET /move answers either way)
    // (whether it takes moves; the chats going from here now, each a device's chat page says so over its composer, shut)
    parts.overview("move", (viewer) => {
      const ws = viewer.workspace ?? cloud.home();
      return { offered: moves.on(), chats: moves.handover.moving().filter((c) => c.ws === ws).map(({ ws: _, ...c }) => c) };
    });
    parts.cardChoice("move", { may: (viewer, card, at) => asks.may(viewer, card, at), chosen: (viewer, card, option, at) => asks.chosen(viewer, card, option, at) });
    // (station_move is an agent's only where moving is on here)
    parts.tools(moveTools(asks), () => moves.on());
    bus.whenAttached(() => void moves.start().catch((e) => log.warn("move", "the migrations did not go on", { error: (e as Error).message })));
  }),
);
