// The station's `beta` features (src/features.ts): on as the station is updated on the test channel (config.json's
// `updateChannel`, else the CHANNEL its installer wrote), off on stable, nothing said over it; the overview's `features`
// says those on.
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { GRADUATED_SAID, stationFeature, stationFeatures } from "../src/features.ts";

/// An app directory whose installer wrote `channel` (none: an install from before channels).
function app(channel: string | null): string {
  const dir = mkdtempSync(join(tmpdir(), "features-"));
  if (channel !== null) writeFileSync(join(dir, "CHANNEL"), channel);
  return dir;
}

test("a_beta_feature_follows_the_station_s_channel", () => {
  const beta = app("beta");
  const stable = app("stable");
  const before = app(null);
  assert.equal(stationFeature("terminal", {}, beta), true);
  assert.equal(stationFeature("terminal", {}, stable), false);
  // an install from before channels is stable
  assert.equal(stationFeature("terminal", {}, before), false);
  // config.json's updateChannel said over what the installer wrote
  assert.equal(stationFeature("terminal", { updateChannel: "beta" }, stable), true);
  assert.equal(stationFeature("terminal", { updateChannel: "stable" }, beta), false);
  // what is no station's beta feature is never one here
  assert.equal(stationFeature("board", {}, beta), false);
  assert.equal(stationFeature("selectionIntent", { updateChannel: "beta" }, beta), false);
});

test("the_overview_says_what_is_on_and_moving_graduated_on_every_channel_for_apps_from_before", () => {
  const beta = app("beta");
  const stable = app("stable");
  assert.deepEqual(GRADUATED_SAID, ["stationMove"]);
  assert.deepEqual(stationFeatures({}, beta), ["terminal", "stationMove"]);
  assert.deepEqual(stationFeatures({}, stable), ["stationMove"]);
  assert.deepEqual(stationFeatures({ updateChannel: "beta" }, stable), ["terminal", "stationMove"]);
});
