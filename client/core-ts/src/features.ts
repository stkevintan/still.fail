// Features not yet rolled out to everyone, one registry for the core, the app and the station:
//
// - `beta`: on on the test channel, gone on stable, never a switch. Whose channel decides is where its code runs: one
//   the station runs (`station: true`) is the station's, by the channel it is updated on (station/src/features.ts
//   `stationFeature`), said in its overview (`features`) and read there by the app; the device's own, by
//   host.testChannel().
// - `experimental`: off by default on both channels, a per-device switch in 设置 › 实验性功能. `betaOnly` shows its
//   switch on the test channel alone: what still replaces a working path step by step is not offered to people on
//   stable (the owner's reason for 实验性功能, 2026-11-16: 「别把用户搞得没法用」).
//
// What the app shows is what the core says of this registry (the prefs' `features` and `experimentalItems`): the app
// keeps no copy of it. Once a feature graduates (or is dropped), delete its entry here and its branches in the code;
// scripts/features-check.ts refuses any stray reference.

export type FeatureStage = "beta" | "experimental";

export interface FeatureSpec {
  readonly stage: FeatureStage;
  readonly betaOnly?: boolean;
  /// A `beta` feature whose code runs on the station: the station's channel decides it, never the device's.
  readonly station?: boolean;
}

export const FEATURES = {
  board: { stage: "experimental" },
  selectionIntent: { stage: "experimental" },
  cmdQuote: { stage: "experimental" },
  terminal: { stage: "beta", station: true },
} as const satisfies Record<string, FeatureSpec>;

export type FeatureId = keyof typeof FEATURES;

export const FEATURE_IDS = Object.keys(FEATURES) as FeatureId[];

function isObj(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

const has = (registry: Record<string, FeatureSpec>, id: string) => Object.prototype.hasOwnProperty.call(registry, id);

export function isExperimentalFeature(id: string): id is FeatureId {
  return has(FEATURES, id) && FEATURES[id as FeatureId].stage === "experimental";
}

/// Experimental switches turned on on this device (`prefs.experimental`), ignoring unknown or graduated ids.
export function experimentalOf(prefs: unknown, registry: Record<string, FeatureSpec> = FEATURES): Record<string, boolean> {
  const out: Record<string, boolean> = {};
  const raw = isObj(prefs) && isObj(prefs.experimental) ? prefs.experimental : null;
  if (raw !== null) {
    for (const key of Object.keys(raw)) {
      if (has(registry, key) && registry[key]!.stage === "experimental" && raw[key] === true) out[key] = true;
    }
  }
  return out;
}

/// The device's own feature `id` on this device (`testChannel`: host.testChannel()): false for one the station decides.
export function featureEnabled(id: FeatureId, prefs: unknown, testChannel: boolean, registry: Record<string, FeatureSpec> = FEATURES): boolean {
  const spec = registry[id];
  if (spec === undefined || spec.station === true) return false;
  if (spec.stage === "beta") return testChannel;
  if (spec.betaOnly === true && !testChannel) return false;
  return experimentalOf(prefs, registry)[id] === true;
}

/// Every one of the device's own features (not those a station decides) on this device: the prefs' `features`, all the
/// app reads of them.
export function featuresOf(prefs: unknown, testChannel: boolean, registry: Record<string, FeatureSpec> = FEATURES): Record<string, boolean> {
  const out: Record<string, boolean> = {};
  for (const id of Object.keys(registry)) {
    if (registry[id]!.station !== true) out[id] = featureEnabled(id as FeatureId, prefs, testChannel, registry);
  }
  return out;
}

/// Items visible in 设置 › 实验性功能 on this channel, in registry order (empty when none: the settings row hides).
export function experimentalItemsOf(prefs: unknown, testChannel: boolean, registry: Record<string, FeatureSpec> = FEATURES): { id: string; enabled: boolean }[] {
  const exp = experimentalOf(prefs, registry);
  const out: { id: string; enabled: boolean }[] = [];
  for (const id of Object.keys(registry)) {
    const spec = registry[id]!;
    if (spec.stage === "experimental" && (spec.betaOnly !== true || testChannel)) out.push({ id, enabled: exp[id] === true });
  }
  return out;
}

/// Whether a station's `overview` says it runs its `beta` feature `id`.
export function stationFeature(overview: unknown, id: FeatureId): boolean {
  const ids = isObj(overview) ? overview.features : undefined;
  return Array.isArray(ids) && ids.includes(id);
}

/// The `beta` features a station decides (`station: true`), as its overview's `features` lists those on.
export function stationFeatureIds(registry: Record<string, FeatureSpec> = FEATURES): string[] {
  return Object.keys(registry).filter((id) => registry[id]!.stage === "beta" && registry[id]!.station === true);
}
