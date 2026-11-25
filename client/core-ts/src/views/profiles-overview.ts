// The Profile overview's pools (the `profilesOverview` view): the workspace's subscriptions put together by the models
// they serve (Claude, Fable, Codex, Gemini and each other vendor's), each pool's allowance left as a share of what all
// its accounts hold, hour by hour from two days back to a week on, and how fast it goes, an hour at a time.
//
// The past is each account's own hours as its stations kept them (GET /profiles/pace, station accounts/pace.ts): what
// its allowance said at each hour, and between those what its calls spent hour by hour, so an hour nobody worked is
// flat and one an agent ran in falls; before a station kept hours, the window's percent used so far spread over its
// hours by what they spent (evenly where nothing was counted). The future is an hourly simulation: each hour's demand
// leans from the last hours' pace (an exponential weighting) to the week's, shaped by the hour of the day people work
// at, and is spread over the accounts with room in both their week and their five hours, each by its week's pace, as
// the station's pool spreads sessions; a week refills at its reset, five hours at theirs, and what no account can take
// is the pool going without. What a pool has left is its weeks' alone (station sessions/pool.ts: the week is what is spent and refilled, five hours only how
// fast it may be taken): five hours spent hold an account back from being used now (`ready`) and from what the
// simulation can take of it, never take its week out of the pool's line to put it back as they come back.
const HOUR_MS = 3_600_000;

// deno-lint-ignore no-explicit-any
type J = any;

/// The hours drawn back from now, and on.
export const PAST_HOURS = 48;
export const FUTURE_HOURS = 168;
/// How far back a pool's pace is read (the station keeps 192 hours).
const HISTORY_HOURS = 168;
/// The hours a pace is weighed over, and the decay of their weights (an hour `a` back weighs e^(-a/τ)).
const RECENT_HOURS = 12;
const RECENT_TAU = 6;
/// How fast the demand leans from the last hours' pace to the week's (`w = e^(-h/LEAN_HOURS)`).
const LEAN_HOURS = 12;
/// The day's shape: each hour's share of the day against an even prior of so many hours of each (two days), held
/// between these.
const DIURNAL_PRIOR = 2;
const DIURNAL_MIN = 0.25;
const DIURNAL_MAX = 2.4;
/// What a full five hours is of its week, in percent, where an account's hours do not tell (about eight a week).
const SHORT_OF_LONG = 12;
/// The most accounts said to be needed.
const NEEDED_MOST = 999;
/// What a pool with so many more accounts may still go without over the week foreseen, in percent of the pool as it
/// is: a few hours' tenths of a percent, where accounts with their week left have spent their five hours, are no
/// account more (the owner, 2026-11-17: 5 said where the week went without two days and three would do).
const NEEDED_SLACK = 1;

export type OverviewPool = {
  title: string;
  ready: number;
  total: number;
  nowPct: number;
  exhaustHours: number | null;
  currentBurnPerHour: number;
  sustainablePerHour: number;
  /// What it spends an hour now against what it could (sustainablePerHour − currentBurnPerHour, %/h): over it, or going
  /// without within the week, negative.
  netPerHour: number;
  overPace: boolean;
  /// The pool's percent left (whole), an hour apart: PAST_HOURS back (0) to now (PAST_HOURS) to FUTURE_HOURS on.
  traj: number[];
  /// The hours on it goes without, as spans: each pair the first hour (0: the next) and the one after the last.
  starveSpans: number[];
  /// Each hour's pace against what it could keep up (sustainablePerHour − what it spent, %/h, to a tenth): the last 24
  /// (0..23), then the next 24 as foreseen (24..47), what it would ask of them (an hour going without, negative).
  hourlyNet: number[];
  /// How many more accounts of its usual plan, full, it would take not to go without, the week foreseen and the weeks
  /// after it (`neededFor`); none where it does not go without.
  neededAccounts: number | null;
  /// How fast its models wrote (tokens a second, to a tenth; -1 where none of their calls was timed then): Claude's, Fable's,
  /// Codex's and Gemini's alone, by the models their calls named (`speedPool`), none where nothing was timed at all.
  speed?: PoolSpeed;
};

/// A pool's models' speed over three spans, each point what their calls timed in the window that ends there wrote over the
/// time they took (sliding): `quarters` the last 6 hours a quarter apart, each of the hour before it; `hours` the last
/// 24 an hour apart, each of the 3 before; `days` the last week 6 hours apart, each of the day before. The last of each
/// is now's.
export type PoolSpeed = { quarters: number[]; hours: number[]; days: number[] };

const QUARTER_MS = 900_000;

/// The pool a model's speed counts in, by its name (no provider path, variant or version): a model's own later.
export function speedPool(model: string): string | null {
  const raw = model.trim().toLowerCase();
  const bare = (raw.split("[")[0]?.split("/").pop() ?? "").split("@")[0]!;
  if (bare.includes("fable") || bare.includes("mythos")) return "Fable";
  if (bare.includes("claude") || /^(opus|sonnet|haiku)/.test(bare)) return "Claude";
  if (bare.includes("gemini") || bare.includes("gemma")) return "Gemini";
  if (bare.startsWith("gpt") || /^o\d/.test(bare) || bare.includes("codex")) return "Codex";
  return null;
}

/// What each pool's models wrote and took (ms) by quarter and by hour, of the stations the accounts are on (each said
/// its own calls: GET /profiles/pace's speedQuarters and speedHours).
type Took = Map<number, [number, number]>;
function speedsOf(items: J[], pace: (station: string) => J): Map<string, { quarters: Took; hours: Took }> {
  const stations = new Set<string>();
  for (const i of items) for (const m of Array.isArray(i?.members) ? i.members : []) stations.add(str(m?.station));
  const out = new Map<string, { quarters: Took; hours: Took }>();
  const add = (list: unknown, which: "quarters" | "hours") => {
    for (const r of Array.isArray(list) ? list : []) {
      const at = num(r?.at);
      const output = num(r?.output);
      const ms = num(r?.ms);
      const pool = speedPool(str(r?.model));
      if (at === null || output === null || ms === null || !(ms > 0) || pool === null) continue;
      const of = out.get(pool) ?? { quarters: new Map(), hours: new Map() };
      out.set(pool, of);
      const was = of[which].get(at) ?? [0, 0];
      of[which].set(at, [was[0] + output, was[1] + ms]);
    }
  };
  for (const station of stations) {
    const said = pace(station);
    add(said?.speedQuarters, "quarters");
    add(said?.speedHours, "hours");
  }
  return out;
}

/// Each window's tokens a second (to a tenth), the windows `width` long ending at each of `ends`; -1 where none was timed.
function sliding(took: Took, ends: number[], width: number): number[] {
  return ends.map((end) => {
    let output = 0;
    let ms = 0;
    for (let at = end - width + 1; at <= end; at++) {
      const t = took.get(at);
      if (t !== undefined) { output += t[0]; ms += t[1]; }
    }
    return ms > 0 ? round((output / ms) * 1000, 1) : -1;
  });
}

function speedOf(took: { quarters: Took; hours: Took } | undefined, now: number): PoolSpeed | undefined {
  if (took === undefined) return undefined;
  const q = Math.floor(now / QUARTER_MS);
  const h = Math.floor(now / HOUR_MS);
  const span = (n: number, last: number, step: number) => Array.from({ length: n }, (_, i) => last - step * (n - 1 - i));
  const speed = {
    quarters: sliding(took.quarters, span(24, q, 1), 4),
    hours: sliding(took.hours, span(24, h, 1), 3),
    days: sliding(took.hours, span(28, h, 6), 24),
  };
  return [...speed.quarters, ...speed.hours, ...speed.days].some((v) => v >= 0) ? speed : undefined;
}

/// One window of an account's allowance, as its station or an hour of it says it.
type Win = { label: string; scope: string; used: number; resetsAt: number | null; minutes: number | null; mark: string };
type Kind = "long" | "short";
/// An hour an account's allowance was read in: when, and its windows.
type Snap = { at: number; windows: Win[] };
/// An account's hours as its stations said them (members' together: a borrowed account's calls spend the same).
type Hours = { snaps: Snap[]; spend: Map<string, Map<number, number>> };

/// An account as a pool takes it.
type Slot = {
  weight: number;
  broken: boolean;
  ready: boolean;
  long: Win | null;
  short: Win | null;
  /// Not to be used before this many hours on (Fable's while its account's week, reset apart from it, is spent).
  lockedHours: number;
  /// A long window every call of it counts against too (Fable's: its account's week), or null.
  gate: Win | null;
  /// What its calls count against (a window's `scope`; "" the account's own).
  scope: string;
  hours: Hours;
};

const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);
const str = (v: unknown): string => (typeof v === "string" ? v : "");
const isObject = (v: unknown): v is Record<string, J> => v !== null && typeof v === "object" && !Array.isArray(v);
const round = (v: number, places: number) => {
  const f = 10 ** places;
  const r = Math.round(v * f) / f;
  // (never -0: it goes out as 0 and comes back 0, a value that would not be the one it was)
  return r === 0 ? 0 : r;
};
const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));

function normScopeOf(name: string): string | null {
  const l = name.trim().toLowerCase();
  if (l === "gemini") return "gemini";
  if (l === "3p" || l === "claude / gpt") return "3p";
  if (l === "fable") return "Fable";
  return null;
}

/// A window's scope as one name whoever said it: an Antigravity account's "gemini" and "3p" as its allowance gives
/// them (stations from before spent against "Gemini" and "Claude / GPT"), Fable's "Fable"; with none said, of a
/// label that names one of these after its " · ".
export function normScope(scope: string, label = ""): string {
  if (scope === "" && label === "") return "";
  const s = scope.trim();
  if (s !== "") return normScopeOf(s) ?? s;
  const at = label.lastIndexOf(" · ");
  return at < 0 ? "" : normScopeOf(label.slice(at + 3)) ?? "";
}

function winOf(w: J): Win | null {
  if (!isObject(w)) return null;
  // (as a station said it, or as the list's rows keep it: what is left, whole percent)
  const left = num(w.left);
  const used = num(w.usedPercent) ?? (left === null ? null : 100 - left);
  if (used === null) return null;
  const label = str(w.label);
  return { label, scope: normScope(str(w.scope), label), used: clamp(used, 0, 100), resetsAt: num(w.resetsAt), minutes: num(w.minutes), mark: str(w.mark) };
}

/// Whether a window is a week's (or a month's) or a few hours'.
function kindOf(w: Win): Kind {
  if (w.minutes !== null) return w.minutes >= 1440 ? "long" : "short";
  if (w.mark === "W" || w.mark === "M") return "long";
  if (w.mark === "5H" || w.mark === "2H" || w.mark === "3D") return "short";
  const l = w.label.toLowerCase();
  if (l.includes("小时") || l.includes("hour") || /\b\d+h\b/.test(l)) return "short";
  return "long";
}

/// A long window's cycle in hours.
function cycleOf(w: Win): number {
  if (w.minutes !== null && w.minutes >= 1440) return w.minutes / 60;
  const l = w.label.toLowerCase();
  return w.mark === "M" || l.includes("每月") || l.includes("month") ? 720 : 168;
}
const shortHoursOf = (w: Win) => (w.minutes !== null && w.minutes > 0 && w.minutes < 1440 ? w.minutes / 60 : 5);

const find = (ws: Win[], scope: string, kind: Kind) => ws.find((w) => w.scope === scope && kindOf(w) === kind) ?? null;

function windowsOf(item: J): Win[] {
  const q = item?.profile?.quota;
  if (!isObject(q) || q.state !== "ok") return [];
  return [...(Array.isArray(q.windows) ? q.windows : []), ...(Array.isArray(q.scoped) ? q.scoped : [])].flatMap((w) => winOf(w) ?? []);
}

const needsFix = (item: J) => item?.look === true || item?.state?.tone === "red" || item?.profile?.checkTone === "red";

/// How much of a pool an account is, by its plan (a Max 20x Claude twenty of a Pro's).
function planWeight(item: J): number {
  const g = str(item?.group);
  const plan = str(item?.profile?.planText);
  if (g === "claude") return plan.includes("20x") ? 20 : plan.includes("5x") ? 5 : 1;
  if (g === "chatgpt") return plan.includes("200") || plan.includes("Pro") ? 10 : plan.includes("Team") ? 2 : 1;
  if (g === "agy") return plan.includes("Ultra") ? 5 : 1;
  return 1;
}

/// An account's hours read as a station said them, kept by what it said (the same object until it is read again: the
/// pools made again as an account's row changes read none of them anew).
const snapsRead = new WeakMap<object, Snap[]>();
function snapsOf(quotas: J[]): Snap[] {
  const kept = snapsRead.get(quotas);
  if (kept !== undefined) return kept;
  const snaps: Snap[] = [];
  for (let i = 0; i < quotas.length; i++) {
    const q = quotas[i];
    const at = num(q?.at);
    if (at === null) continue;
    const raw = q.windows;
    const windows: Win[] = [];
    if (Array.isArray(raw)) {
      for (let j = 0; j < raw.length; j++) {
        const w = winOf(raw[j]);
        if (w !== null) windows.push(w);
      }
    }
    snaps.push({ at, windows });
  }
  snaps.sort((a, b) => a.at - b.at);
  snapsRead.set(quotas, snaps);
  return snaps;
}

const spendRead = new WeakMap<object, Map<string, Map<number, number>>>();
function spendOf(raw: J[]): Map<string, Map<number, number>> {
  const kept = spendRead.get(raw);
  if (kept !== undefined) return kept;
  const spend = new Map<string, Map<number, number>>();
  for (let i = 0; i < raw.length; i++) {
    const s = raw[i];
    const hour = num(s?.hour);
    const weight = num(s?.weight);
    if (hour === null || weight === null || weight <= 0) continue;
    const scope = normScope(str(s.scope));
    let byHour = spend.get(scope);
    if (byHour === undefined) {
      byHour = new Map<number, number>();
      spend.set(scope, byHour);
    }
    byHour.set(hour, (byHour.get(hour) ?? 0) + weight);
  }
  spendRead.set(raw, spend);
  return spend;
}

/// An account's hours, its members' together (each station's of its profile there).
function hoursOf(item: J, pace: (station: string) => J): Hours {
  let snaps: Snap[] = [];
  let spendSingle: Map<string, Map<number, number>> | null = null;
  let spendMerged: Map<string, Map<number, number>> | null = null;
  let most = -1;
  for (const m of Array.isArray(item?.members) ? item.members : []) {
    const said = pace(str(m?.station))?.profiles?.[str(m?.profileId)];
    if (!isObject(said)) continue;
    // (the allowance as the member that read it most often kept it: each reads the same account)
    const quotas = Array.isArray(said.quotas) ? said.quotas : [];
    if (quotas.length > most) {
      most = quotas.length;
      snaps = snapsOf(quotas);
    }
    const rawSpend = said.spend;
    if (Array.isArray(rawSpend) && rawSpend.length > 0) {
      const part = spendOf(rawSpend);
      if (part.size > 0) {
        if (spendSingle === null && spendMerged === null) {
          spendSingle = part;
        } else {
          if (spendMerged === null) {
            spendMerged = new Map<string, Map<number, number>>();
            for (const [scope, byHour] of spendSingle!) spendMerged.set(scope, new Map(byHour));
            spendSingle = null;
          }
          for (const [scope, byHour] of part) {
            let dst = spendMerged.get(scope);
            if (dst === undefined) {
              dst = new Map<number, number>();
              spendMerged.set(scope, dst);
            }
            for (const [hour, weight] of byHour) dst.set(hour, (dst.get(hour) ?? 0) + weight);
          }
        }
      }
    }
  }
  return { snaps, spend: spendMerged ?? spendSingle ?? new Map() };
}

type PoolSpec = { title: string; slots: Slot[] };
/// A pool's rows (what `pooled` keeps its pool by) and its slots made of them with their hours as asked (`poolOf`'s).
type PoolRows = { title: string; items: J[]; slots: (h: (i: J) => Hours) => Slot[] };

/// A window as the list's rows keep it (what is left, whole; no length) made exact by its account's hour kept within
/// the last two (the same window, the same left): its length and its percent as read. None kept: as the row has it.
function exact(w: Win | null, hours: Hours, now: number): Win | null {
  if (w === null || w.minutes !== null) return w;
  for (let i = hours.snaps.length - 1; i >= 0; i--) {
    const snap = hours.snaps[i]!;
    if (snap.at < now - 2 * HOUR_MS) break;
    const sw = snap.windows.find((x) => x.scope === w.scope && kindOf(x) === kindOf(w) && Math.round(100 - x.used) === Math.round(100 - w.used));
    if (sw !== undefined) return { ...w, minutes: sw.minutes, used: sw.used };
  }
  return w;
}

function slot(item: J, hours: Hours, now: number, scope: string, long: Win | null, short: Win | null, o: { weight?: number; lockedHours?: number; usable?: boolean; gate?: Win | null } = {}): Slot {
  const broken = needsFix(item) || item?.profile?.quota?.state === "blocked";
  const usable = o.usable ?? item?.usable === true;
  const lockedHours = o.lockedHours ?? 0;
  const gate = o.gate ?? null;
  const ready = !broken && usable && (long === null || long.used < 100) && (short === null || short.used < 100) && (gate === null || gate.used < 100) && lockedHours <= 0;
  return { weight: o.weight ?? planWeight(item), broken, ready, long: exact(long, hours, now), short: exact(short, hours, now), lockedHours, gate: exact(gate, hours, now), scope, hours };
}

/// Whether a gate resets with its window (Claude's week and its Fable week: the same moment, a millisecond apart):
/// then what is left of both is the less of the two, refilled together.
const gatedTogether = (long: Win | null, gate: Win | null): boolean =>
  long !== null && gate !== null && gate.resetsAt !== null && long.resetsAt !== null && Math.abs(gate.resetsAt - long.resetsAt) < 3 * HOUR_MS;

/// Each pool's accounts (`items`), and its slots made of them as asked, with their hours (`h`): a pool kept
/// (`poolKept`) reads none of its accounts' hours.
function poolSpecs(items: J[], now: number): PoolRows[] {
  const main = (i: J): [Win | null, Win | null] => {
    const ws = windowsOf(i);
    return [find(ws, "", "long"), find(ws, "", "short")];
  };
  const groupOf = (i: J) => str(i?.group);
  const specs: PoolRows[] = [];
  // (an Antigravity account's Claude / GPT serve no Claude Code or Codex session: the station's pool never runs one
  // of those on it, sessions/pool.ts, so it is none of their pools')
  const own = (group: string, title: string) => {
    const mine = items.filter((i) => groupOf(i) === group);
    specs.push({ title, items: mine, slots: (h) => mine.map((i) => {
      const [long, short] = main(i);
      return slot(i, h(i), now, "", long, short);
    }) });
  };
  own("claude", "Claude");
  // Fable: a model's own week, on accounts whose week of their own must have room too.
  const fableOf = (i: J): Win | null => windowsOf(i).find((w) => w.scope === "Fable") ?? null;
  const fable = items.filter((i) => fableOf(i) !== null || (groupOf(i) === "claude" && needsFix(i)));
  specs.push({ title: "Fable", items: fable, slots: (h) => fable.map((i) => {
    const mine = fableOf(i);
    const [week, short] = main(i);
    // (its account's week reset with it is a gate, the less of the two left; one reset apart and spent holds it till then)
    const locked = !gatedTogether(mine, week) && week !== null && week.used >= 100 ? Math.max(0, ((week.resetsAt ?? now) - now) / HOUR_MS) : 0;
    return slot(i, h(i), now, "Fable", mine, short, { lockedHours: locked, gate: week });
  }) });
  own("chatgpt", "Codex");
  const geminiOf = (i: J): [Win | null, Win | null] => {
    const ws = windowsOf(i);
    return [find(ws, "gemini", "long"), find(ws, "gemini", "short")];
  };
  const gemini = items.filter((i) => {
    if (groupOf(i) !== "agy" || i?.profile?.access?.kind === "service") return false;
    const [long, short] = geminiOf(i);
    // (an allowance read that has no Gemini window: an account of none, not one to wait for)
    return !(long === null && short === null && i?.profile?.quota?.state === "ok" && !needsFix(i));
  });
  specs.push({ title: "Gemini", items: gemini, slots: (h) => gemini.map((i) => {
    const [long, short] = geminiOf(i);
    return slot(i, h(i), now, "gemini", long, short);
  }) });
  for (const [group, title] of [["grok", "SuperGrok"], ["kimi", "Kimi Code"], ["opencode", "OpenCode Go"], ["cursor", "Cursor"], ["devin", "Devin"], ["copilot", "GitHub Copilot"]] as const) {
    const mine = items.filter((i) => groupOf(i) === group);
    specs.push({ title, items: mine, slots: (h) => mine.map((i) => {
      const [long, short] = main(i);
      return slot(i, h(i), now, "", long, short, { weight: 1 });
    }) });
  }
  return specs.filter((s) => s.items.length > 0);
}

/// An account's long window through the hours: its percent used `k` hours back (k = 0..HISTORY_HOURS), and in each hour
/// what it used (a reset's refill not counted).
type Past = { used: number[]; burn: number[]; known: number };

/// Its spending between two moments (hours from now, `a` < `b`), each hour's taken by how much of it falls between: of
/// running sums over the hours it may be asked of, made once (a reckoning asks it of every hour back, and of spans).
function spending(spend: Map<number, number> | undefined, nowHourF: number): (a: number, b: number) => number {
  if (spend === undefined || spend.size === 0) return () => 0;
  const nowFloor = Math.floor(nowHourF);
  const last = nowFloor + 2;
  let minKey = Infinity;
  for (const k of spend.keys()) if (k < minKey) minKey = k;
  if (minKey >= last) return () => 0;
  const first = Math.max(nowFloor - HISTORY_HOURS - 800, Math.floor(minKey));
  const n = last - first;
  const sums = new Float64Array(n + 1);
  const vals = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    const v = spend.get(first + i) ?? 0;
    vals[i] = v;
    sums[i + 1] = sums[i]! + v;
  }
  const at = (x: number) => {
    const fx = Math.floor(x);
    const i = fx - first;
    if (i < 0) return 0;
    if (i >= n) return sums[n]!;
    return sums[i]! + vals[i]! * (x - fx);
  };
  return (a, b) => (b <= a ? 0 : at(nowHourF + b) - at(nowHourF + a));
}

/// `w` (its long window, or its gate) counted against by what was spent of `scope`.
function pastOf(s: Slot, now: number, w: Win | null = s.long, scope: string = s.scope): Past {
  const used = new Array<number>(HISTORY_HOURS + 1).fill(0);
  const burn = new Array<number>(HISTORY_HOURS).fill(0);
  if (w === null) return { used, burn, known: 0 };
  const nowHourF = now / HOUR_MS;
  const spentBetween = spending(s.hours.spend.get(scope), now / HOUR_MS);
  const spend = s.hours.spend.get(scope);
  const cycle = cycleOf(w);
  const r = w.resetsAt !== null ? (w.resetsAt - now) / HOUR_MS : cycle / 2;
  // The end of the cycle a moment `t` (hours from now) is in.
  const endOf = (t: number) => r - cycle * Math.floor((r - t) / cycle);
  // What is known of it: each hour kept (of this window: its scope, its kind), and now.
  const points: { t: number; used: number; end: number }[] = [];
  const snaps = s.hours.snaps;
  const wScope = w.scope;
  let sorted = true;
  let prevT = -Infinity;
  for (let si = 0; si < snaps.length; si++) {
    const snap = snaps[si]!;
    const t = (snap.at - now) / HOUR_MS;
    if (t >= 0 || t < -HISTORY_HOURS - cycle) continue;
    const wins = snap.windows;
    let sw: Win | undefined;
    for (let wi = 0; wi < wins.length; wi++) {
      const x = wins[wi]!;
      if (x.scope === wScope && kindOf(x) === "long") { sw = x; break; }
    }
    if (sw === undefined) continue;
    const end = sw.resetsAt !== null ? (sw.resetsAt - now) / HOUR_MS : endOf(t);
    if (t < prevT) sorted = false;
    prevT = t;
    points.push({ t, used: sw.used, end });
  }
  if (0 < prevT) sorted = false;
  points.push({ t: 0, used: w.used, end: endOf(0) });
  if (!sorted) points.sort((a, b) => a.t - b.t);
  const sameCycle = (a: number, b: number) => Math.abs(a - b) < 3;
  const ofCycle = new Map<number, { mine: typeof points; cur: number }>();
  // Percent used per dollar spent and per hour, as this cycle went so far (what an hour of an earlier one without
  // points is reckoned by).
  const start0 = endOf(0) - cycle;
  const spentNow = spentBetween(start0, 0);
  const perDollar = spentNow > 0 ? w.used / spentNow : null;
  const perHour = w.used / Math.max(1, -start0);
  const along = (a: number, b: number, t: number) => {
    // How far a moment `t` is from `a` to `b`, by what was spent between (by the time where nothing was).
    const all = spentBetween(a, b);
    return all > 0 ? spentBetween(a, t) / all : b > a ? (t - a) / (b - a) : 1;
  };
  for (let k = 0; k <= HISTORY_HOURS; k++) {
    const t = -k;
    const end = endOf(t);
    const start = end - cycle;
    let entry = ofCycle.get(end);
    if (entry === undefined) {
      const mine: typeof points = [];
      for (let j = 0; j < points.length; j++) {
        const p = points[j]!;
        if (sameCycle(p.end, end)) mine.push({ t: p.t, used: p.used, end: p.end });
      }
      // What a cycle used so far never goes back: a percent read a whole one higher, or two stations' readings a
      // moment apart, taken down to the newest reading after it (now's, the last), so the line rises nowhere but at a
      // refill and meets now where now is.
      for (let j = mine.length - 2; j >= 0; j--) mine[j]!.used = Math.min(mine[j]!.used, mine[j + 1]!.used);
      entry = { mine, cur: mine.length };
      ofCycle.set(end, entry);
    }
    const mine = entry.mine;
    // (points in order of time, t strictly decreasing: move cursor back to the first at or after `t`)
    let cur = entry.cur;
    while (cur > 0 && mine[cur - 1]!.t >= t) cur--;
    entry.cur = cur;
    const newer = cur < mine.length ? mine[cur] : undefined;
    const older = newer !== undefined && newer.t === t ? newer : cur > 0 ? mine[cur - 1] : undefined;
    let u: number;
    if (newer !== undefined && older !== undefined) {
      u = newer.t === older.t ? newer.used : older.used + (newer.used - older.used) * along(older.t, newer.t, t);
    } else if (newer !== undefined) {
      // (before the first hour kept of this cycle: from nothing at its start)
      u = newer.used * along(start, newer.t, t);
    } else if (older !== undefined) {
      const more = perDollar !== null ? perDollar * spentBetween(older.t, t) : perHour * (t - older.t);
      u = older.used + more;
    } else {
      u = perDollar !== null ? perDollar * spentBetween(start, t) : perHour * (t - start);
    }
    used[k] = clamp(u, 0, 100);
  }
  for (let k = 1; k <= HISTORY_HOURS; k++) {
    // The hour from k back to k - 1: what it used, a refill between them not counted.
    const reset = !sameCycle(endOf(-k), endOf(-(k - 1)));
    burn[k - 1] = Math.max(0, reset ? used[k - 1]! : used[k - 1]! - used[k]!);
  }
  // How far back what it says is the account's own, not a reckoning: its first hour kept or counted, or its cycle's start.
  const firstSnap = points.length > 1 ? -points[0]!.t : 0;
  let firstSpend = 0;
  if (spend !== undefined) for (const hour of spend.keys()) firstSpend = Math.max(firstSpend, nowHourF - hour);
  const known = Math.min(HISTORY_HOURS, Math.max(firstSnap, firstSpend, w.used > 0 ? -start0 : 0));
  return { used, burn, known };
}

/// Percent of its week a full five hours of an account is, as its kept hours tell (what both rose by, hour to hour
/// within one of each), or SHORT_OF_LONG.
function shortOfLong(s: Slot): number {
  if (s.short === null || s.long === null) return SHORT_OF_LONG;
  const snaps = s.hours.snaps;
  if (snaps.length < 2) return SHORT_OF_LONG;
  const lScope = s.long.scope;
  const sScope = s.short.scope;
  let la: Win | undefined;
  let sa: Win | undefined;
  const w0 = snaps[0]!.windows;
  for (let wi = 0; wi < w0.length; wi++) {
    const x = w0[wi]!;
    if (la === undefined && x.scope === lScope && kindOf(x) === "long") la = x;
    if (sa === undefined && x.scope === sScope && kindOf(x) === "short") sa = x;
  }
  let dl = 0;
  let ds = 0;
  for (let i = 1; i < snaps.length; i++) {
    const wb = snaps[i]!.windows;
    let lb: Win | undefined;
    let sb: Win | undefined;
    for (let wi = 0; wi < wb.length; wi++) {
      const x = wb[wi]!;
      if (lb === undefined && x.scope === lScope && kindOf(x) === "long") lb = x;
      if (sb === undefined && x.scope === sScope && kindOf(x) === "short") sb = x;
    }
    if (la !== undefined && lb !== undefined && sa !== undefined && sb !== undefined && lb.used >= la.used && sb.used >= sa.used && sa.resetsAt === sb.resetsAt) {
      dl += lb.used - la.used;
      ds += sb.used - sa.used;
    }
    la = lb;
    sa = sb;
  }
  // (whole percents read: a five hours' 20 against a week's 1 is a rounding's, not a five hours of 2% of its week)
  return ds >= 40 && dl >= 4 ? clamp((dl / ds) * 100, 8, 100) : SHORT_OF_LONG;
}

/// An account in the simulation.
type Tank = {
  share: number;
  left: number;
  resetIn: number;
  cycle: number;
  lockedTill: number;
  short: { used: number; resetIn: number | null; hours: number; ofLong: number } | null;
};

function tanksOf(slots: Slot[], shares: number[], now: number): Tank[] {
  return slots.map((s, i) => {
    const share = shares[i]!;
    const cycle = s.long !== null ? cycleOf(s.long) : 168;
    let resetIn = s.long?.resetsAt != null ? (s.long.resetsAt - now) / HOUR_MS : cycle / 2;
    while (resetIn <= 0) resetIn += cycle;
    // (a gate reset with it: the less of the two left; one reset apart holds it by `lockedHours`)
    const used = s.long === null ? 0 : gatedTogether(s.long, s.gate) ? Math.max(s.long.used, s.gate!.used) : s.long.used;
    const left = (share * (100 - used)) / 100;
    const short = s.short === null ? null : {
      used: s.short.used,
      resetIn: s.short.used > 0 && s.short.resetsAt !== null ? Math.max(0, (s.short.resetsAt - now) / HOUR_MS) : null,
      hours: shortHoursOf(s.short),
      ofLong: shortOfLong(s),
    };
    return { share, left, resetIn, cycle, lockedTill: s.lockedHours, short };
  });
}

type SimBuf = {
  cap: number;
  share: Float64Array;
  left: Float64Array;
  resetIn: Float64Array;
  cycle: Float64Array;
  lockedTill: Float64Array;
  hasShort: Uint8Array;
  shortUsed: Float64Array;
  shortResetIn: Float64Array;
  shortHours: Float64Array;
  shortOfLong: Float64Array;
  openIdx: Int32Array;
  openRoom: Float64Array;
  openPace: Float64Array;
};

let simBuf: SimBuf = makeSimBuf(32);

function makeSimBuf(cap: number): SimBuf {
  return {
    cap,
    share: new Float64Array(cap),
    left: new Float64Array(cap),
    resetIn: new Float64Array(cap),
    cycle: new Float64Array(cap),
    lockedTill: new Float64Array(cap),
    hasShort: new Uint8Array(cap),
    shortUsed: new Float64Array(cap),
    shortResetIn: new Float64Array(cap),
    shortHours: new Float64Array(cap),
    shortOfLong: new Float64Array(cap),
    openIdx: new Int32Array(cap),
    openRoom: new Float64Array(cap),
    openPace: new Float64Array(cap),
  };
}

function ensureSimBuf(need: number): SimBuf {
  if (simBuf.cap < need) {
    let cap = simBuf.cap;
    while (cap < need) cap *= 2;
    simBuf = makeSimBuf(cap);
  }
  return simBuf;
}

function loadTanks(start: Tank[], scale: number): void {
  const n = start.length;
  const { share, left, resetIn, cycle, lockedTill, hasShort, shortUsed, shortResetIn, shortHours, shortOfLong } = simBuf;
  for (let i = 0; i < n; i++) {
    const t = start[i]!;
    share[i] = t.share * scale;
    left[i] = t.left * scale;
    resetIn[i] = t.resetIn;
    cycle[i] = t.cycle;
    lockedTill[i] = t.lockedTill;
    const sh = t.short;
    if (sh === null) {
      hasShort[i] = 0;
      shortUsed[i] = 0;
      shortResetIn[i] = -1;
      shortHours[i] = 0;
      shortOfLong[i] = 0;
    } else {
      hasShort[i] = 1;
      shortUsed[i] = sh.used;
      shortResetIn[i] = sh.resetIn === null ? -1 : sh.resetIn;
      shortHours[i] = sh.hours;
      shortOfLong[i] = sh.ofLong;
    }
  }
}

/// Run one hour `h` on `simBuf`'s first `n` tanks with demand `wantIn`; returns unmet demand.
// The hour's demand spread as the station's pool spreads sessions (station sessions/pool.ts `urgency`): over the
// accounts that can take some, each by its week's pace (what it has left over the hours to its refill, a day at
// least), what one cannot take of its part going to the others. Never one drained after another: the last weeks
// left would be a few accounts' alone, held to their five hours, an hour going without where the pool's weeks
// still had plenty (the owner, 2026-11-17: an account more said for tenths of a percent).
function stepHour(n: number, h: number, wantIn: number): number {
  const buf = simBuf;
  const share = buf.share;
  const left = buf.left;
  const resetIn = buf.resetIn;
  const cycle = buf.cycle;
  const lockedTill = buf.lockedTill;
  const hasShort = buf.hasShort;
  const shortUsed = buf.shortUsed;
  const shortResetIn = buf.shortResetIn;
  const shortHours = buf.shortHours;
  const shortOfLong = buf.shortOfLong;
  const openIdx = buf.openIdx;
  const openRoom = buf.openRoom;
  const openPace = buf.openPace;
  let openLen = 0;
  for (let i = 0; i < n; i++) {
    if (resetIn[i]! <= h) {
      left[i] = share[i]!;
      resetIn[i] = resetIn[i]! + cycle[i]!;
    }
    const hs = hasShort[i]!;
    if (hs !== 0) {
      const sr = shortResetIn[i]!;
      if (sr >= 0 && sr <= h) {
        shortUsed[i] = 0;
        shortResetIn[i] = -1;
      }
    }
    const li = left[i]!;
    const si = share[i]!;
    if (li > 1e-9 && h > lockedTill[i]! && si > 0) {
      let room = li;
      if (hs !== 0) {
        const srCap = ((100 - shortUsed[i]!) * si * shortOfLong[i]!) / 1e4;
        if (srCap < room) room = srCap;
      }
      if (room > 1e-9) {
        openIdx[openLen] = i;
        openRoom[openLen] = room;
        openLen++;
      }
    }
  }
  let want = wantIn > 0 ? wantIn : 0;
  while (want > 1e-9 && openLen > 0) {
    let whole = 0;
    for (let oi = 0; oi < openLen; oi++) {
      const i = openIdx[oi]!;
      const rd = resetIn[i]! - h + 1;
      const pace = left[i]! / (rd > 24 ? rd : 24);
      openPace[oi] = pace;
      whole += pace;
    }
    let given = 0;
    let nextOpenLen = 0;
    let anyFull = false;
    for (let oi = 0; oi < openLen; oi++) {
      const i = openIdx[oi]!;
      const room = openRoom[oi]!;
      const part = (want * openPace[oi]!) / whole;
      const take = room < part ? room : part;
      const isFull = take >= room - 1e-9;
      if (isFull) anyFull = true;
      if (take > 0) {
        const nl = left[i]! - take;
        left[i] = nl;
        if (hasShort[i] !== 0) {
          const nu = shortUsed[i]! + (take * 1e4) / (share[i]! * shortOfLong[i]!);
          shortUsed[i] = nu < 100 ? nu : 100;
          if (shortResetIn[i]! < 0) shortResetIn[i] = h - 1 + shortHours[i]!;
        }
        given += take;
      }
      if (!isFull) {
        const nl = left[i]!;
        if (nl > 1e-9) {
          let remRoom = nl;
          if (hasShort[i] !== 0) {
            const srCap = ((100 - shortUsed[i]!) * share[i]! * shortOfLong[i]!) / 1e4;
            if (srCap < remRoom) remRoom = srCap;
          }
          if (remRoom > 1e-9) {
            openIdx[nextOpenLen] = i;
            openRoom[nextOpenLen] = remRoom;
            nextOpenLen++;
          }
        }
      }
    }
    want -= given;
    if (!anyFull) break;
    openLen = nextOpenLen;
  }
  return want;
}

/// Each hour on (1..FUTURE_HOURS) given `demandArr[h]`: what is left to use at its end, what was taken, what went
/// without.
function simulate(start: Tank[], demandArr: Float64Array): { avail: number[]; taken: number[]; unmet: number[] } {
  const n = start.length;
  ensureSimBuf(n);
  loadTanks(start, 1);
  const { left, lockedTill } = simBuf;
  const avail = new Array<number>(FUTURE_HOURS);
  const taken = new Array<number>(FUTURE_HOURS);
  const unmet = new Array<number>(FUTURE_HOURS);
  for (let h = 1; h <= FUTURE_HOURS; h++) {
    const want0 = demandArr[h]! > 0 ? demandArr[h]! : 0;
    const want = stepHour(n, h, want0);
    // (what is left of the weeks: five hours spent only hold back what is taken, as `unmet` says)
    let a = 0;
    for (let i = 0; i < n; i++) if (h > lockedTill[i]!) a += left[i]!;
    avail[h - 1] = a;
    taken[h - 1] = want0 - want;
    unmet[h - 1] = want;
  }
  return { avail, taken, unmet };
}

/// True if any hour in 1..FUTURE_HOURS goes without by more than `maxUnmet` under a constant hourly demand.
function simulateAnyUnmet(start: Tank[], constDemand: number, maxUnmet: number): boolean {
  const n = start.length;
  ensureSimBuf(n);
  loadTanks(start, 1);
  for (let h = 1; h <= FUTURE_HOURS; h++) {
    if (stepHour(n, h, constDemand) > maxUnmet) return true;
  }
  return false;
}

/// True if `start` plus `k` full unit accounts (all scaled by `scale`) keep total unmet demand over the week within
/// `maxUnmet` (in original unscaled percent of the pool).
function simulateTotalUnmet(
  start: Tank[],
  k: number,
  unitShare: number,
  unitCycle: number,
  unitShort: { hours: number; ofLong: number } | null,
  demandArr: Float64Array,
  scale: number,
  maxUnmet: number,
): boolean {
  const n = start.length;
  const total = n + k;
  ensureSimBuf(total);
  loadTanks(start, scale);
  const scaledUnitShare = unitShare * scale;
  const hasUnitShort = unitShort !== null ? 1 : 0;
  const uHours = unitShort !== null ? unitShort.hours : 0;
  const uOfLong = unitShort !== null ? unitShort.ofLong : 0;
  const { share, left, resetIn, cycle, lockedTill, hasShort, shortUsed, shortResetIn, shortHours, shortOfLong } = simBuf;
  for (let j = 0; j < k; j++) {
    const idx = n + j;
    share[idx] = scaledUnitShare;
    left[idx] = scaledUnitShare;
    resetIn[idx] = unitCycle;
    cycle[idx] = unitCycle;
    lockedTill[idx] = 0;
    hasShort[idx] = hasUnitShort;
    shortUsed[idx] = 0;
    shortResetIn[idx] = -1;
    shortHours[idx] = uHours;
    shortOfLong[idx] = uOfLong;
  }
  let unmetSum = 0;
  for (let h = 1; h <= FUTURE_HOURS; h++) {
    unmetSum += stepHour(total, h, demandArr[h]! * scale);
    if (unmetSum / scale > maxUnmet + 1e-9) return false;
  }
  return unmetSum / scale <= maxUnmet;
}

const starves = (s: { avail: number[]; unmet: number[] }, h: number) => s.unmet[h]! > 0.05 || s.avail[h]! <= 0.3;

function poolOf(spec: PoolSpec, now: number, offsetMin: number): OverviewPool {
  const total = spec.slots.length;
  const ready = spec.slots.filter((s) => s.ready).length;
  const active = spec.slots.filter((s) => !s.broken && s.weight > 0);
  const weight = active.reduce((a, s) => a + s.weight, 0);
  if (active.length === 0 || weight <= 0) {
    return {
      title: spec.title, ready: 0, total, nowPct: 0, exhaustHours: 0, currentBurnPerHour: 0, sustainablePerHour: 0, netPerHour: 0, overPace: true,
      traj: new Array(PAST_HOURS + 1 + FUTURE_HOURS).fill(0), starveSpans: [0, FUTURE_HOURS], hourlyNet: new Array(48).fill(0),
      // (none of its accounts usable: nothing to say how much one more would be of it)
      neededAccounts: null,
    };
  }
  const shares = active.map((s) => (s.weight / weight) * 100);
  const pasts = active.map((s) => pastOf(s, now));
  // (a gate reset with the window: its own past, of the account's own spending, what it left the less of the two)
  const gates = active.map((s) => (gatedTogether(s.long, s.gate) ? pastOf(s, now, s.gate, "") : null));
  // The past: what each account's week had left.
  const activeLen = active.length;
  const traj: number[] = [];
  for (let k = PAST_HOURS; k >= 1; k--) {
    let v = 0;
    for (let i = 0; i < activeLen; i++) {
      const pu = pasts[i]!.used[k]!;
      const g = gates[i];
      const gu = g !== null ? g!.used[k]! : 0;
      const used = pu > gu ? pu : gu;
      v += (shares[i]! * (100 - used)) / 100;
    }
    traj.push(clamp(v, 0, 100));
  }
  const tanks = tanksOf(active, shares, now);
  let nowAvail = 0;
  for (const t of tanks) if (t.lockedTill <= 0) nowAvail += t.left;
  // (none of it to be taken now: every account with some left has spent its five hours, or is held)
  const nowStarved = !tanks.some((t) => t.lockedTill <= 0 && t.left > 0.3 && (t.short === null || t.short.used < 100));
  traj.push(clamp(nowAvail, 0, 100));
  // What the pool spent each hour back (0: the last).
  const pastBurn: number[] = [];
  for (let j = 0; j < HISTORY_HOURS; j++) {
    let b = 0;
    for (let i = 0; i < activeLen; i++) b += (shares[i]! * pasts[i]!.burn[j]!) / 100;
    pastBurn.push(b);
  }
  // The last hours' pace, and the week's.
  let wsum = 0;
  let recent = 0;
  for (let j = 0; j < RECENT_HOURS; j++) {
    const wj = Math.exp(-j / RECENT_TAU);
    wsum += wj;
    recent += wj * pastBurn[j]!;
  }
  recent /= wsum;
  const known = Math.max(1, Math.round(Math.max(...pasts.map((p) => p.known))));
  const meanKnown = pastBurn.slice(0, known).reduce((a, b) => a + b, 0) / known;
  let cycleAvg = 0;
  active.forEach((s, i) => {
    if (s.long === null) return;
    const cycle = cycleOf(s.long);
    const r = s.long.resetsAt !== null ? (s.long.resetsAt - now) / HOUR_MS : cycle / 2;
    let left = r;
    while (left <= 0) left += cycle;
    while (left > cycle) left -= cycle;
    const elapsed = Math.max(1, cycle - left);
    cycleAvg += (shares[i]! * s.long.used) / 100 / elapsed;
  });
  const base = known >= 24 ? meanKnown : (known * meanKnown + (24 - known) * cycleAvg) / 24;
  // The day's shape, by the viewer's hours.
  const localHour = (ms: number) => (((Math.floor((ms + offsetMin * 60_000) / HOUR_MS) % 24) + 24) % 24);
  const sums = new Array<number>(24).fill(0);
  const counts = new Array<number>(24).fill(0);
  for (let j = 0; j < known; j++) {
    const lh = localHour(now - (j + 0.5) * HOUR_MS);
    sums[lh]! += pastBurn[j]!;
    counts[lh]! += 1;
  }
  const mean = known > 0 ? pastBurn.slice(0, known).reduce((a, b) => a + b, 0) / known : 0;
  let diurnal = sums.map((s, lh) => (mean > 0 ? clamp((s + DIURNAL_PRIOR * mean) / (counts[lh]! + DIURNAL_PRIOR) / mean, DIURNAL_MIN, DIURNAL_MAX) : 1));
  const dm = diurnal.reduce((a, b) => a + b, 0) / 24;
  diurnal = diurnal.map((d) => d / dm);
  const demandArr = new Float64Array(FUTURE_HOURS + 1);
  for (let h = 1; h <= FUTURE_HOURS; h++) {
    const w = Math.exp(-h / LEAN_HOURS);
    demandArr[h] = w * recent + (1 - w) * base * diurnal[localHour(now + (h - 0.5) * HOUR_MS)]!;
  }
  const sim = simulate(tanks, demandArr);
  for (let h = 0; h < FUTURE_HOURS; h++) traj.push(clamp(sim.avail[h]!, 0, 100));
  const willStarve = sim.avail.map((_, h) => starves(sim, h));
  const first = willStarve.findIndex((x) => x);
  const exhaustHours = nowAvail <= 0.3 || (nowStarved && (recent > 0.05 || base > 0.05)) ? 0 : first >= 0 ? first + 1 : null;
  // The most it could spend an hour, evenly, and never go without for the week.
  // (no more than all it holds and gets back in the week spread over it: searched to a hundredth of a percent an hour)
  let held = 0;
  for (const t of tanks) held += t.left + t.share * Math.max(0, Math.floor((FUTURE_HOURS - t.resetIn) / t.cycle) + (t.resetIn <= FUTURE_HOURS ? 1 : 0));
  let lo = 0;
  let hi = held / FUTURE_HOURS + 0.01;
  while (hi - lo > 0.005) {
    const mid = (lo + hi) / 2;
    if (simulateAnyUnmet(tanks, mid, 0.05)) hi = mid;
    else lo = mid;
  }
  const sustainable = Math.max(0.01, lo);
  // Each hour against the pace it could keep up: the last 24 what was spent, the next 24 what they ask (taken or not:
  // an hour going without asks what it cannot have), one going without never at or over it.
  const hourlyNet: number[] = [];
  for (let j = 23; j >= 0; j--) hourlyNet.push(round(sustainable - pastBurn[j]!, 1));
  for (let h = 0; h < 24; h++) {
    const asked = sim.taken[h]! + sim.unmet[h]!;
    const net = sustainable - asked;
    hourlyNet.push(round(willStarve[h] && net >= -0.05 ? -Math.max(0.1, asked) : net, 1));
  }
  const starveSpans: number[] = [];
  for (let h = 0; h < FUTURE_HOURS; h++) {
    if (!willStarve[h] || (h > 0 && willStarve[h - 1])) continue;
    let end = h;
    while (end < FUTURE_HOURS && willStarve[end]) end++;
    starveSpans.push(h, end);
  }
  const overPace = recent > sustainable || exhaustHours !== null;
  // (what the weeks after ask an hour: the week's pace as it was spent (`base`), never now's leaning to it, as if the
  // last hours' run went on in every week after (the owner, 2026-11-17: 4 said for the weeks after where its week's
  // pace asks 3); where nothing is left now, the cycles' so far if faster: an hour it could not spend in is no pace
  // of its)
  const pace = Math.max(base, nowAvail <= 0.3 ? cycleAvg : 0);
  const neededAccounts = overPace ? neededFor(active, shares, weight, tanks, demandArr, pace) : null;
  // (over it, or going without within the week: said against the faster of now's pace and the week's, never above
  // -0.1, so it falls as either rises)
  const net = sustainable - recent;
  return {
    title: spec.title,
    ready,
    total,
    nowPct: Math.round(clamp(nowAvail, 0, 100)),
    exhaustHours,
    currentBurnPerHour: round(Math.max(0, recent), 2),
    sustainablePerHour: round(sustainable, 2),
    netPerHour: round(overPace ? Math.min(-0.1, sustainable - Math.max(recent, base)) : net, 1),
    overPace,
    traj: traj.map((v) => Math.round(v)),
    starveSpans,
    hourlyNet,
    neededAccounts,
  };
}

/// The most often of `xs`, ties to the larger; null where there is none.
function mode(xs: number[]): number | null {
  const counts = new Map<number, number>();
  for (const x of xs) counts.set(x, (counts.get(x) ?? 0) + 1);
  let best: number | null = null;
  let most = 0;
  for (const [x, c] of counts) if (c > most || (c === most && best !== null && x > best)) [best, most] = [x, c];
  return best;
}

/// The fewest accounts of the pool's usual plan (its accounts' most common weight, cycle and five hours, a five hours
/// the share of its week its own are read to be), each full and its week begun now, that put beside its own keep it
/// from going without: the week foreseen (`demand`) goes without by no more than `NEEDED_SLACK` in all, and their
/// cycles give back what it asks an hour on the whole (`pace`), so the weeks after go on so. Each is reckoned at the
/// pool's shares with them in (`scale`), as the pools made again of those accounts would be. None (null) where it
/// goes without by no more than that as it is; most `NEEDED_MOST`.
function neededFor(active: Slot[], shares: number[], weight: number, tanks: Tank[], demandArr: Float64Array, pace: number): number | null {
  const unitWeight = mode(active.map((s) => s.weight))!;
  const unitShare = (unitWeight / weight) * 100;
  const unitCycle = mode(active.flatMap((s) => (s.long !== null ? [cycleOf(s.long)] : []))) ?? 168;
  const shortHours = active.flatMap((s) => (s.short !== null ? [shortHoursOf(s.short)] : []));
  // (a five hours of its own as its accounts' are read to be, the middle of them: not the guess where they tell)
  const ofLongs: number[] = [];
  for (let i = 0; i < tanks.length; i++) {
    const sh = tanks[i]!.short;
    if (sh !== null) ofLongs.push(sh.ofLong);
  }
  ofLongs.sort((a, b) => a - b);
  const unitOfLong = ofLongs.length > 0 ? ofLongs[Math.floor(ofLongs.length / 2)]! : SHORT_OF_LONG;
  const unitShort = shortHours.length * 2 >= active.length ? { hours: mode(shortHours)!, ofLong: unitOfLong } : null;
  // What its own give back an hour, at their cycles.
  const existingSteady = active.reduce((a, s, i) => a + shares[i]! / (s.long !== null ? cycleOf(s.long) : 168), 0);
  const canKeepUp = (k: number): boolean => {
    const scale = 100 / (100 + k * unitShare);
    if ((existingSteady + k * (unitShare / unitCycle)) * scale < pace * scale + 0.005) return false;
    // (what it goes without, back in percent of the pool as it is)
    return simulateTotalUnmet(tanks, k, unitShare, unitCycle, unitShort, demandArr, scale, NEEDED_SLACK);
  };
  if (canKeepUp(0)) return null;
  // (lo: so few do not keep it from going without; hi: so many do)
  let lo = 0;
  let hi = 1;
  while (!canKeepUp(hi)) {
    if (hi >= NEEDED_MOST) return NEEDED_MOST;
    lo = hi;
    hi = Math.min(NEEDED_MOST, hi * 2);
  }
  while (hi - lo > 1) {
    const mid = Math.floor((lo + hi) / 2);
    if (canKeepUp(mid)) hi = mid;
    else lo = mid;
  }
  return hi;
}

/// What a pool made of its rows reads of each (`poolSpecs`, `slot`, `windowsOf`, `needsFix`, `planWeight`: its kind,
/// whether it needs fixing, its plan, whether it can be used, its allowance as read, the profiles it is on), in words.
function rowRead(i: J): string {
  const members = Array.isArray(i?.members) ? i.members : [];
  const qState = i?.profile?.quota?.state;
  const state = qState === "ok" || qState === "blocked" ? qState : "";
  const windows = windowsOf(i).map((w) => [w.scope, w.mark, w.label, w.used, w.resetsAt, w.minutes]);
  return JSON.stringify([str(i?.group), needsFix(i), str(i?.profile?.planText), i?.usable === true, state, windows, members.map((m: J) => [str(m?.station), str(m?.profileId)])]);
}

/// The pools made last (`poolOf`), each by what it was made of: its name, its rows as it reads them (`rowRead`), its
/// accounts' hours as their stations said them (the objects: `hoursOf` reads each member's profile of its station's
/// pace and nothing else of it), the viewer's offset and the minute of `now`. A pool none of whose accounts changed is
/// the one made before within the minute: each station's overview or hours coming made every pool again (6-18 times
/// in a row as stations came back, 154-903 ms each on a phone, 0.1.10103-10130), each a week's simulation searched over
/// a dozen times. The last `POOLS_KEPT` (a few workspaces' pools).
type Pooled = { hours: unknown[]; pool: OverviewPool };
const pooled = new Map<string, Pooled>();
const POOLS_KEPT = 48;

/// Frozen all through (util.ts `deepFreeze`, this file importing nothing).
function deepFreeze(v: unknown): void {
  if (v === null || typeof v !== "object" || Object.isFrozen(v)) return;
  Object.freeze(v);
  for (const k of Object.keys(v)) deepFreeze((v as Record<string, unknown>)[k]);
}

/// A pool kept is frozen all through as it is kept: every call that finds it hands the same object.
function poolKept(rows: PoolRows, pace: (station: string) => J, now: number, offsetMin: number, h: (i: J) => Hours): OverviewPool {
  const hours: unknown[] = [];
  for (const i of rows.items) for (const m of Array.isArray(i?.members) ? i.members : []) hours.push(pace(str(m?.station))?.profiles?.[str(m?.profileId)]);
  const key = JSON.stringify([rows.title, Math.floor(now / 60_000), offsetMin, rows.items.map(rowRead)]);
  const was = pooled.get(key);
  if (was !== undefined && was.hours.length === hours.length && was.hours.every((x, i) => x === hours[i])) {
    pooled.delete(key);
    pooled.set(key, was);
    return was.pool;
  }
  const pool = poolOf({ title: rows.title, slots: rows.slots(h) }, now, offsetMin);
  deepFreeze(pool);
  pooled.delete(key);
  pooled.set(key, { hours, pool });
  if (pooled.size > POOLS_KEPT) pooled.delete(pooled.keys().next().value!);
  return pool;
}

/// The overview's pools of the workspace's accounts (`profilesWhole`'s items), with their stations' hours (`pace`,
/// by a station's address: what it said of GET /profiles/pace; nothing said, none), at `now` in the viewer's offset.
/// `fresh`: every pool made anew, none kept (what the kept ones are held to: profiles-overview-kept.test.ts).
export function profilesOverview(items: J[], pace: (station: string) => J, nowMs: number, offsetMin: number, fresh = false): { pools: OverviewPool[] } {
  // (as of the minute `nowMs` is in: what is made within it is the same whenever in it, so a pool kept is what one
  // made anew would be)
  const now = Math.floor(nowMs / 60_000) * 60_000;
  const speeds = speedsOf(items, pace);
  // (an account's hours read as a pool not kept first needs them: the pools kept read none)
  const hours = new Map<J, Hours>();
  const h = (i: J): Hours => {
    let made = hours.get(i);
    if (made === undefined) hours.set(i, made = hoursOf(i, pace));
    return made;
  };
  return {
    pools: poolSpecs(items.map((item) => item.poolProfile ? { ...item, profile: item.poolProfile, look: false, state: null } : item), now).map((rows) => {
      const pool = fresh ? poolOf({ title: rows.title, slots: rows.slots(h) }, now, offsetMin) : poolKept(rows, pace, now, offsetMin, h);
      const speed = speedOf(speeds.get(rows.title), now);
      return speed === undefined ? pool : Object.freeze({ ...pool, speed });
    }),
  };
}
