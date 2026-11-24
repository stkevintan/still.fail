// What the app shows of a migration (move/AGENTS.md): `GET /move?to=<station>` answers, for the asker's workspace and
// that station, the modules in order with their needs, each module's done of total, how many of its items here cannot
// move (`cannot`, of all of them) and a page of its items (label,
// state, what it needs and waits for, why it cannot move, its error, the moving one's progress inside it). `module` and
// `after` page one module's items further; `limit` (at most 200) is a page's. Told changed as `move` on the event
// stream (move/live.ts), which a device reads it again on; it is never asked again on a timer. `last`: the workspace's
// last move or move back and what came of it (scheduler.ts `Last`).
// `POST /move {to, module?, item?, all?, withNeeds?, arriveStopped?}` and `POST /move/back {from, module?, item?, all?}` are the people's
// way to what station_move does, the same turn of the same scheduler: the workspace's owners and admins, answered 202
// at once while it goes on (GET /move and `move` say how far and what came of it); refused in the viewer's words where
// moving is switched off here or there or that station is out of reach (move/AGENTS.md), while another turn is under way, on a station that only runs
// tasks, or with a target that is not a whole station of the workspace. No card: the person pressing is the
// confirmation, `all` too.
import type { Route } from "../api/admin.ts";
import { error, json, ok, param } from "../api/request.ts";
import type { Request } from "../api/request.ts";
import { managesStation } from "../mesh/credential.ts";
import { tr } from "../ops/i18n.ts";
import { named } from "./module.ts";
import type { Held, Last, Plan, Planned, Scheduler, Selection } from "./scheduler.ts";

type Json = any;

export const MOVE_PAGE = 50;
export const MOVE_PAGE_MOST = 200;

/// The answer of GET /move for `plan`: `module`/`after` the page of one module that goes on from `after`.
/// `name`: what the roster calls a station (`at`, `waitsAt`), its id's start where it names none.
export function moveView(plan: Plan, order: string[], stopped: { item: { module: string; id: string }; waitsFor: { module: string; id: string } }[], o: { module?: string; after?: string; limit?: number } = {}, last: Last | null = null, stopping = false, name: (id: string) => string = (id) => id.slice(0, 12), current: { module: string; id: string } | null = null, held: Held | null = null): Json {
  const limit = Math.min(Math.max(o.limit ?? MOVE_PAGE, 1), MOVE_PAGE_MOST);
  // (a turn under way: its own plan, held by module with each item's place and the counts it keeps; only the page's rows
  // and the item it is at asked where they stand now: nothing gone through whole)
  const heldAt = (n: { module: string; id: string }) => {
    const i = held?.at.get(named(n));
    return i === undefined ? undefined : held!.byModule.get(n.module)?.[i];
  };
  // (each row asked where it stands once a read, the item the turn is at among them or not)
  const asked = new Map<Planned, Planned>();
  const now = (x: Planned) => asked.get(x) ?? (asked.set(x, held!.now(x)), asked.get(x)!);
  // (the turn under way is at an item till its end is told, whether that item reads moving yet or not)
  const moving = held !== null
    ? (current === null ? null : ((x) => (x === undefined ? null : now(x)))(heldAt(current)))
    : plan.items.find((x) => x.state === "moving") ?? (current === null ? null : plan.items.find((x) => x.module === current.module && x.id === current.id) ?? null);
  // (each module's items, gone through once; held, as the turn keeps them)
  const of = new Map<string, readonly Planned[]>(order.map((id) => [id, held?.byModule.get(id) ?? []]));
  if (held === null) for (const x of plan.items) (of.get(x.module) as Planned[] | undefined)?.push(x);
  const needsOf = new Map(plan.modules.map((m) => [m.id, m.needs]));
  return {
    ws: plan.ws,
    to: plan.to,
    modules: order.map((id) => {
      const mine = of.get(id)!;
      const from = o.module === id && o.after !== undefined ? (held !== null ? (held.at.get(named({ module: id, id: o.after })) ?? -1) : mine.findIndex((x) => x.id === o.after)) + 1 : 0;
      const page = held !== null ? mine.slice(from, from + limit).map(now) : mine.slice(from, from + limit);
      let done = 0;
      let cannot = 0;
      const kept = held?.counts.get(id);
      if (kept !== undefined) (done = kept.done), (cannot = kept.cannot);
      else if (held === null) {
        for (const x of mine) {
          if (x.state === "there") done++;
          else if (x.state === "here" && x.cannot !== undefined) cannot++;
        }
      }
      return {
        id,
        needs: needsOf.get(id) ?? [],
        done,
        total: mine.length,
        // (those here that cannot move, of all its items, not of the page: what a whole move would leave here)
        cannot,
        items: page.map((x) => ({
          id: x.id, label: x.label, state: x.state, needs: x.needs.map(named),
          ...(x.waitsFor ? { waitsFor: named(x.waitsFor) } : {}),
          // (where it is, a station neither this one nor the one the page is toward; where what it waits for is)
          ...(x.at !== undefined ? { at: name(x.at) } : {}),
          ...(x.waitsFor?.at !== undefined ? { waitsAt: name(x.waitsFor.at) } : x.waits === "station" && x.from !== undefined ? { waitsAt: name(x.from) } : {}),
          ...(x.cannot !== undefined ? { cannot: x.cannot } : {}),
          ...(x.leaves !== undefined ? { leaves: x.leaves } : {}),
          ...(x.error ? { error: x.error } : {}),
          ...(x.progress ? { progress: x.progress } : {}),
          // (here, its host, and usable there too: lent for what moved there)
          ...(x.lentTo !== undefined ? { lentTo: name(x.lentTo) } : {}),
          // (moving, waiting for what is not its own progress: its chat's turn to end)
          ...(x.waits !== undefined ? { waits: x.waits } : {}),
          ...(x.wouldStop.length > 0 ? { wouldStop: x.wouldStop.map(named) } : {}),
        })),
        more: from + limit < mine.length ? page.at(-1)?.id ?? null : null,
      };
    }),
    moving: moving === null ? null : { module: moving.module, id: moving.id, label: moving.label, progress: moving.progress ?? null, ...(moving.waits !== undefined ? { waits: moving.waits } : {}), ...(stopping ? { stopping: true } : {}) },
    stopped: stopped.map((s) => ({ item: named(s.item), waitsFor: named(s.waitsFor) })),
    last: last === null ? null : {
      at: last.at, by: last.by, how: last.how, station: last.station, ...(last.stoppedBy !== undefined ? { stoppedBy: last.stoppedBy } : {}),
      done: last.done.map(named), refused: last.refused.map((x) => ({ item: named(x.item), why: x.why })),
      stopped: last.stopped.map((x) => ({ item: named(x.item), waitsFor: named(x.waitsFor) })), resumed: last.resumed.map(named),
      failed: last.failed === null ? null : { item: last.failed.item === null ? null : named(last.failed.item), error: last.failed.error },
      ...((last.failures ?? []).length > 0 ? { failures: last.failures!.map((f) => ({ item: named(f.item), error: f.error })) } : {}),
      ...((last.returned ?? []).length > 0 ? { returned: last.returned!.map(named) } : {}),
      ...((last.lent ?? []).length > 0 ? { lent: last.lent!.map(named) } : {}),
    },
  };
}

const bodyOf = (r: Request): Json => {
  try {
    return r.body.length === 0 ? {} : JSON.parse(r.body.toString("utf8"));
  } catch {
    return null;
  }
};

export type MoveRoutesDeps = {
  scheduler: Scheduler;
  order: () => string[];
  home: () => string | null;
  /// A station of `ws` by its id or name: its id, and whether it only runs tasks.
  station: (ws: string, v: string) => { id: string; tasks: boolean } | null;
  here: () => string | null;
  /// Whether this machine only runs tasks (a rig) now.
  rig: () => boolean;
  /// What the roster of `ws` calls station `id` (none: its id's start).
  name?: (ws: string, id: string) => string | null;
  /// The chat session `key` goes with, as the chats' plan names it (handover.ts `chatOf`).
  chatOf?: (key: string) => string;
  /// move/station.ts `refusal`: switched off here or there.
  refusal: (ws: string, station: string, lang: Request["lang"]) => Promise<string | null>;
};

export function moveRoutes(d: MoveRoutesDeps): Route[] {
  /// A turn asked by a person: checked, begun, answered 202 at once.
  const start = async (r: Request, back: boolean): Promise<ReturnType<typeof ok>> => {
    if (!managesStation(r.viewer)) return error(403, tr(r.lang, "station.move.managersOnly"));
    const ws = r.viewer.workspace ?? d.home();
    if (ws === null) return error(404, "this station is in no workspace");
    if (d.rig()) return error(409, tr(r.lang, "station.move.isRig"));
    const b = bodyOf(r);
    if (b === null || typeof b !== "object") return error(400, "the body is JSON: {to, module, item} (POST /move/back: {from, …})");
    const given = typeof (back ? b.from : b.to) === "string" ? String(back ? b.from : b.to).trim() : "";
    const at = given === "" ? null : d.station(ws, given);
    if (at === null) return error(400, tr(r.lang, "station.move.noStation", { station: given }));
    if (at.id === d.here()) return error(400, tr(r.lang, "station.move.self"));
    if (at.tasks) return error(409, tr(r.lang, "station.move.notWhole", { station: given }));
    const module = typeof b.module === "string" && b.module !== "" ? b.module : undefined;
    const item = typeof b.item === "string" && b.item !== "" ? b.item : undefined;
    const sel: Selection = {
      module,
      // (a chat asked by any of its sessions (a chat's menu names its own): as the chats' plan lists it, by its first)
      item: module === "chats" && item !== undefined && d.chatOf !== undefined ? d.chatOf(item) : item,
      all: b.all === true, withNeeds: !back && b.withNeeds === true,
      // (a move back brings an item stopped where what it needs stays there by itself)
      arriveStopped: !back && b.arriveStopped === true,
    };
    if (sel.all !== true && (sel.module === undefined || (sel.item === undefined && !back))) return error(400, tr(r.lang, "station.move.pick"));
    const why = await d.refusal(ws, at.id, r.lang);
    if (why !== null) return error(409, why);
    // (asked meanwhile, while the other station was asked)
    if (d.scheduler.busy()) return error(409, tr(r.lang, "station.move.running"));
    const follow = sel.all === true || sel.module === "chats" ? ["jobs"] : undefined;
    const run = back ? d.scheduler.back(ws, at.id, { ...sel, follow }, r.viewer.email) : d.scheduler.move(ws, at.id, { ...sel, follow }, r.viewer.email);
    // (what came of it is GET /move's `last`, and the `move` event says it changed)
    void run.catch(() => {});
    return json(202, JSON.stringify({ started: true }));
  };
  return [
    { method: "POST", pattern: /^\/move\/?$/, handle: (r) => start(r, false) },
    { method: "POST", pattern: /^\/move\/back\/?$/, handle: (r) => start(r, true) },
    // The turn under way stopped: nothing further of it starts, the item under way gives up where it can.
    {
      method: "POST",
      pattern: /^\/move\/stop\/?$/,
      handle: async (r) => {
        if (!managesStation(r.viewer)) return error(403, tr(r.lang, "station.move.managersOnly"));
        if (!d.scheduler.stopTurn(r.viewer.email)) return error(409, tr(r.lang, "station.move.notRunning"));
        return ok({ ok: true });
      },
    },
    {
      method: "GET",
      pattern: /^\/move\/?$/,
      handle: async (r) => {
        const ws = r.viewer.workspace ?? d.home();
        if (ws === null) return error(404, "this station is in no workspace");
        const given = param(r, "to") ?? "";
        const to = given === "" ? "" : (d.station(ws, given)?.id ?? null);
        if (to === null) return error(400, tr(r.lang, "station.move.noStation", { station: given }));
        try {
          // (a turn under way toward it: its own plan, the page's rows as they stand now; else planned anew)
          const held = d.scheduler.held(ws, to);
          const plan = held?.plan ?? (await d.scheduler.plan(ws, to));
          const limit = Number(param(r, "limit") ?? MOVE_PAGE);
          return ok(moveView(plan, d.order(), d.scheduler.stopped(), { module: param(r, "module") ?? undefined, after: param(r, "after") ?? undefined, limit: Number.isFinite(limit) ? limit : MOVE_PAGE }, d.scheduler.last(ws), d.scheduler.stopping(), (id) => d.name?.(ws, id) ?? id.slice(0, 12), d.scheduler.current(), held?.view ?? null));
        } catch (e) {
          return error(409, (e as Error).message);
        }
      },
    },
  ];
}
