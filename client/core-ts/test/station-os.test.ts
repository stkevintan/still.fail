// A station its workspace gave no mark is shown by the system it runs on (src/station-os.ts): learned of its host
// readings, kept on the device, and given as its `icon` with `osIcon`; one given a mark keeps its own.
import assert from "node:assert/strict";
import { test } from "node:test";
import { keepOs, keptOs, osIcon, osKindOf } from "../src/station-os.ts";
import { base, started } from "./station-fixture.ts";
import { subscribe } from "./helpers.ts";

// deno-lint-ignore no-explicit-any
type J = any;

test("a host reading's system named as still.fail draws it", () => {
  assert.equal(osKindOf("macOS 26.1"), "macos");
  assert.equal(osKindOf("macOS (Darwin 25.0.0)"), "macos");
  assert.equal(osKindOf("Windows 11 Pro 10.0.26100"), "windows");
  assert.equal(osKindOf("Linux 6.12.118+deb13-amd64"), "linux");
  assert.equal(osKindOf("FreeBSD 14.1"), null);
  assert.equal(osKindOf("Test OS"), null);
  assert.equal(osKindOf(undefined), null);
  assert.equal(osIcon("linux"), "glyph:linux");
  assert.equal(osIcon("plan9"), null);
});

test("a station's system kept once, again only as it changes", () => {
  const records = new Map<string, unknown>();
  let puts = 0;
  const data = { record: (t: string, k: string) => records.get(`${t}:${k}`), put: (t: string, k: string, v: unknown) => void (puts++, records.set(`${t}:${k}`, v)) };
  keepOs(data, "ws", "a", "Linux 6.8.0");
  keepOs(data, "ws", "a", "Linux 6.9.1");
  keepOs(data, "ws", "b", "Test OS");
  keepOs(data, "ws", "b", "macOS 15.2");
  assert.deepEqual(keptOs(data, "ws"), { a: "linux", b: "macos" });
  assert.equal(puts, 2, "a reading of the same system writes nothing");
});

test("a_station_with_no_mark_is_shown_by_its_system_one_given_a_mark_by_its_own", async () => {
  const cloud = { stations: [{ id: "st", name: "studio", last_seen: null }] };
  const { host, core, push } = await started(base());
  const ui = core.connect();
  subscribe(core, ui, 1, { topic: "stations", scope: "ws" });
  subscribe(core, ui, 2, { topic: "station", scope: "ws", station: "ws/st" });
  await host.settle();
  const row = () => (core.inner.store.get({ topic: "stations", scope: "ws" }) as J[]).find((s) => s.station === "ws/st");
  const page = () => (core.inner.store.get({ topic: "station", scope: "ws", station: "ws/st" }) as J[])?.[0] ?? core.inner.store.get({ topic: "station", scope: "ws", station: "ws/st" });
  assert.equal(row().icon, undefined, "its system not known yet: none");
  push("host", { hostname: "studio", os: "Linux 6.8.0", arch: "x86_64", cpus: 8, cpuModel: "EPYC", load: 0.1, uptimeSec: 100, memory: { totalBytes: 2, usedBytes: 1, swapUsedBytes: null }, disk: { path: "/", totalBytes: 2, freeBytes: 1 }, stationRssBytes: 1, checkedAt: 1 });
  await host.settle();
  assert.deepEqual([row().icon, row().osIcon], ["glyph:linux", true]);
  assert.deepEqual([page().icon, page().osIcon], ["glyph:linux", true]);
  assert.deepEqual(keptOs(core.inner.data, "ws"), { st: "linux" }, "kept on the device");
  // Given a mark: its own, not its system's.
  core.inner.data.update({ topic: "workspace", workspace: "ws" }, (w) => ({ ...(w as object), stations: [{ ...cloud.stations[0], emoji: "🦊" }] }));
  await host.settle();
  assert.deepEqual([row().emoji, row().icon, row().osIcon], ["🦊", undefined, undefined]);
  core.close();
});
