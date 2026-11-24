// The workspace's profiles in one list (src/views/profiles.ts): a shared one once, from its host while that one is read;
// one on a station only with that station; a shared subscription whose host is away, unusable and first.
import assert from "node:assert/strict";
import { test } from "node:test";
import { holdLanguage } from "../src/i18n.ts";
import { profile as shownProfile } from "../src/present.ts";
import { choices, models, runtimes, runnableOn, servingIn } from "../src/views/models.ts";
import { stationProfileSummary, workspaceProfiles } from "../src/views/profiles.ts";
import { profilesOverview } from "../src/views/profiles-overview.ts";

holdLanguage();

const A = "a".repeat(64);
const B = "b".repeat(64);
const profile = (id: string, extra: Record<string, unknown> = {}) => ({ id, name: id, access: { kind: "subscription" }, checkTone: "green", ...extra });
const station = (id: string, name: string, online: boolean, profiles: unknown[] | null) => ({ id, station: `w/${id}`, name, online, overview: profiles === null ? undefined : { sharing: true, profiles } });

test("a disabled key remains in the account list but is absent from model and account choices", () => {
  const off = shownProfile(profile("off", { access: { kind: "anthropic-api", key: "sk-1…2345" }, enabled: false, runtimes: ["claude"], models: ["opus", "sonnet"], check: { state: "ok", detail: "Works" } }));
  const on = shownProfile(profile("on", { runtimes: ["claude"], models: ["sonnet"], check: { state: "ok", detail: "Works" } }));
  const overview = { profiles: [off, on] };
  const row = workspaceProfiles([station(A, "office", true, [off])]).items[0];
  assert.deepEqual([row.state.text, row.look, row.where, row.usable], ["已停用", false, "", false]);
  assert.deepEqual(runtimes(overview), [{ runtime: "claude", models: ["sonnet"] }]);
  assert.deepEqual(models(overview, 0).map((m: any) => m.model), ["sonnet"]);
  assert.deepEqual(choices(overview, { runtime: "claude" }, 0).map((m: any) => m.model), ["sonnet"]);
  assert.deepEqual(runnableOn(overview, { runtime: "claude", model: "sonnet" }, 0).map((p: any) => p.id), ["on"]);
  assert.deepEqual(servingIn(overview, "w", false).profiles.map((p: any) => p.id), ["on"]);
  assert.equal(off.trouble, null);
  assert.equal(off.checkLine, "");
});

test("a station's profile count uses the profile list's needs-a-look rule", () => {
  const shown = (id: string, extra: Record<string, unknown>) => shownProfile(profile(id, { runtime: "claude", ...extra }));
  const profiles = [
    shown("ok", { check: { state: "ok" }, quota: { state: "ok", windows: [] } }),
    shown("new", {}),
    shown("quota", { check: { state: "ok" }, quota: { state: "unavailable", detail: "No quota returned" } }),
    shown("login", { check: { state: "login" } }),
  ];
  const current = station(A, "office", true, profiles);
  const byId = new Map([[A, current]]);
  const summary = stationProfileSummary(current.overview, current, byId);
  assert.deepEqual(summary.profileGroups, [{ group: "claude", title: "Claude 订阅", profiles: ["quota", "login", "ok", "new"], attention: 2 }]);
  assert.deepEqual(summary.profileStates.quota, { text: "额度查询失败", tone: "amber" });
  assert.deepEqual(summary.profileStates.login, { text: "需要登录", tone: "amber" });
  assert.deepEqual(stationProfileSummary(null, current, byId), { profileGroups: [], profileStates: {} });
  assert.equal(workspaceProfiles([current]).attention, 2);
});

test("a station's borrowed subscription needs a look when its host is away or unreachable", () => {
  const shared = { id: "sh-1", host: A, role: "user", reachable: true };
  const borrowed = profile("borrowed", { checkText: "", share: shared });
  const key = profile("key", { access: { kind: "env" }, share: { id: "sh-2", host: A, role: "user", reachable: true } });
  const host = station(A, "office", false, null);
  const current = station(B, "mini", true, [borrowed, key]);
  const byId = new Map([[A, host], [B, current]]);
  assert.deepEqual(stationProfileSummary(current.overview, current, byId), {
    profileGroups: [
      { group: "claude", title: "Claude 订阅", profiles: ["borrowed"], attention: 1 },
      { group: "key", title: "API Key", profiles: ["key"], attention: 0 },
    ],
    profileStates: { borrowed: { text: "office 离线", tone: "red" } },
  });
  host.online = true;
  shared.reachable = false;
  assert.deepEqual(stationProfileSummary(current.overview, current, byId).profileStates.borrowed, { text: "office 离线", tone: "red" });
  shared.reachable = true;
  assert.deepEqual(stationProfileSummary(current.overview, current, byId).profileGroups.map((g) => g.attention), [0, 0]);
  current.online = false;
  assert.deepEqual(stationProfileSummary(current.overview, current, byId).profileStates, {
    borrowed: { text: "mini 离线", tone: "red" }, key: { text: "mini 离线", tone: "red" },
  });
  assert.deepEqual(stationProfileSummary(current.overview, current, byId).profileGroups.map((g) => g.attention), [1, 1]);
});

test("a shared profile is listed once, from its host, with where it is signed in and who borrows it", () => {
  const share = { id: "sh-1", host: A, allow: [A, B] };
  const view = workspaceProfiles([
    station(A, "office", true, [profile("max", { share: { ...share, role: "host" } }), profile("local", { access: { kind: "env" } })]),
    station(B, "mini", true, [profile("sh-1", { share: { ...share, role: "user", reachable: true } })]),
  ]);
  assert.equal(view.items.length, 2);
  const shared = view.items.find((e: any) => e.shared);
  assert.equal(shared.key, "share:sh-1");
  assert.deepEqual(shared.members.map((m: any) => [m.stationName, m.role]), [["office", "host"], ["mini", "user"]]);
  assert.equal(shared.station, `w/${A}`, "its page is on its host");
  assert.equal(shared.profile.id, "max");
  assert.equal(shared.where, "office、mini 可用");
  assert.equal(shared.usable, true);
  assert.deepEqual(shared.stations.map((s: any) => [s.name, s.allowed]), [["office", true], ["mini", true]]);
  const local = view.items.find((e: any) => !e.shared);
  assert.equal(local.where, "office 可用");
  assert.equal(local.canShare, true);
});

test("a shared subscription stays one row when older copies have no account identity", () => {
  const C = "c".repeat(64);
  const share = { id: "sh-1", host: A, allow: [A, B, C] };
  const host = station(A, "host", true, [profile("max", { name: "same name", runtime: "claude", email: "a@x.test", share: { ...share, role: "host" } })]);
  const copy = (id: string) => profile(id, { name: "same name", runtime: "claude", share: { ...share, role: "user", reachable: true } });
  const b = station(B, "mini", true, [copy("b")]);
  const c = station(C, "laptop", true, [copy("c")]);
  for (const stations of [[b, c, host], [host, b, c]]) {
    const view = workspaceProfiles(stations);
    assert.equal(view.items.length, 1);
    assert.equal(view.items[0].profile.id, "max");
    assert.equal(view.items[0].members.length, 3);
    assert.deepEqual(new Set(view.items[0].places.map((p: any) => p.stationName)), new Set(["host", "mini", "laptop"]));
  }
  const offline = workspaceProfiles([station(A, "host", false, null), b, c]);
  assert.equal(offline.items.length, 1, "copies still group by share while their host is offline");
  assert.equal(offline.items[0].usable, false);
});

test("a shared account uses its host's identity when a copy has an old email", () => {
  const C = "c".repeat(64);
  const share = { id: "sh-1", host: A, allow: null };
  const view = workspaceProfiles([
    station(B, "mini", true, [profile("copy", { name: "same name", runtime: "claude", email: "old@x.test", share: { ...share, role: "user" } })]),
    station(A, "host", true, [profile("max", { runtime: "claude", email: "new@x.test", share: { ...share, role: "host" } })]),
    station(C, "other", true, [profile("other", { name: "same name", runtime: "claude", email: "old@x.test" })]),
  ]);
  assert.equal(view.items.length, 2);
  assert.deepEqual(view.items.find((e: any) => e.key === "sub:claude:new@x.test").members.map((m: any) => m.stationName), ["mini", "host"]);
  assert.deepEqual(view.items.find((e: any) => e.key === "sub:claude:old@x.test").members.map((m: any) => m.stationName), ["other"]);
});

test("a shared subscription whose host is away comes from a copy, unusable, first", () => {
  const share = { id: "sh-1", host: A, allow: null };
  const view = workspaceProfiles([
    station(A, "office", false, null),
    station(B, "mini", true, [profile("b-own", { access: { kind: "env" } }), profile("sh-1", { name: "Max", share: { ...share, role: "user", reachable: true } })]),
  ]);
  assert.equal(view.items[0].key, "share:sh-1");
  assert.equal(view.items[0].usable, false);
  assert.deepEqual([view.items[0].look, view.items[0].state], [true, { text: "office 离线", tone: "red" }]);
  assert.equal(view.attention, 1);
  assert.equal(view.items[0].editable, false);
  assert.deepEqual(view.items[0].places.map((p: any) => [p.stationName, p.usable, p.sourceName]), [["office", false, ""], ["mini", false, "office"]]);
  // Still listed as up by the cloud, but not answering the station borrowing it: away all the same.
  const late = workspaceProfiles([
    station(A, "office", true, null),
    station(B, "mini", true, [profile("sh-1", { share: { ...share, role: "user", reachable: false } })]),
  ]);
  assert.equal(late.items[0].usable, false);
  assert.equal(late.wait.reading, true, "office is up and not read yet");
});

test("what needs a look says so in its row, is counted and comes first in its kind: its allowance not read as much as a sign-in wanted", () => {
  const shown = (id: string, extra: Record<string, unknown>) => shownProfile(profile(id, { email: `${id}@x.test`, runtime: "claude", ...extra }));
  const view = workspaceProfiles([
    station(A, "office", true, [
      shown("a-fine", { check: { state: "ok" }, quota: { state: "ok", windows: [] } }),
      shown("b-new", {}),
      shown("c-quota", { check: { state: "ok" }, quota: { state: "unavailable", detail: "Kimi Code 没有返回额度信息" } }),
      shown("d-login", { check: { state: "login" } }),
    ]),
  ]);
  assert.deepEqual(view.items.map((e: any) => [e.profile.id, e.look, e.state]), [
    ["c-quota", true, { text: "额度查询失败", tone: "amber" }],
    ["d-login", true, { text: "需要登录", tone: "amber" }],
    ["a-fine", false, null],
    // (not checked yet: said, but nothing to look at)
    ["b-new", false, { text: "未检查", tone: "neutral" }],
  ]);
  assert.equal(view.attention, 2);
});

test("the same account signed in on two stations each is one row, each station a member", () => {
  const view = workspaceProfiles([
    station(A, "office", true, [profile("max", { email: "Z@x.test", runtime: "claude" })]),
    station(B, "mini", true, [profile("max-2", { email: "z@x.test", runtime: "claude", checkTone: "red" })]),
  ]);
  assert.equal(view.items.length, 1);
  const row = view.items[0];
  assert.equal(row.where, "office、mini 可用");
  assert.equal(row.title, "Z@x.test", "a subscription called by its account");
  assert.equal(row.profile.id, "max", "the row shows the first one that is up and has its login");
  assert.deepEqual(row.members.map((m: any) => [m.stationName, m.role, m.about]), [["office", "own", "在此 station 单独登录"], ["mini", "own", "在此 station 单独登录"]]);
  // Two different accounts stay two rows.
  const two = workspaceProfiles([
    station(A, "office", true, [profile("a", { email: "a@x.test", runtime: "claude" })]),
    station(B, "mini", true, [profile("b", { email: "b@x.test", runtime: "claude" })]),
  ]);
  assert.equal(two.items.length, 2);
});

test("the same OpenCode Go account signed in on two stations is one row, though each sign-in has its own token", () => {
  const go = (id: string, email: string, key: string) => profile(id, { name: email, email, runtime: "claude", access: { kind: "opencode-go", key, login: true } });
  const view = workspaceProfiles([
    station(A, "office", true, [go("opencode-go", "Z@x.test", "eyJhb…1111")]),
    station(B, "mini", true, [go("opencode-go", "z@x.test", "eyJhb…2222")]),
  ]);
  assert.equal(view.items.length, 1);
  const row = view.items[0];
  assert.equal(row.group, "opencode");
  assert.equal(row.title, "Z@x.test");
  assert.equal(row.where, "office、mini 可用");
  assert.deepEqual(row.members.map((m: any) => [m.stationName, m.about]), [["office", "在此 station 单独登录"], ["mini", "在此 station 单独登录"]]);
  // Two accounts, or the same key given by hand (not signed in), stay apart by what tells them apart.
  const two = workspaceProfiles([
    station(A, "office", true, [go("opencode-go", "a@x.test", "eyJhb…1111")]),
    station(B, "mini", true, [go("opencode-go", "b@x.test", "eyJhb…1111"), profile("go-key", { access: { kind: "opencode-go", key: "sk-1…2345" } })]),
  ]);
  assert.equal(two.items.length, 3);
});

test("an account is called by what it is signed in to, and said usable where any station has it: no one copy's share limit or name", () => {
  const C = "c".repeat(64);
  const share = { id: "sh-1", host: A, allow: [C] };
  const view = workspaceProfiles([
    station(A, "Office", true, [profile("codex-example", { email: "z@x.test", runtime: "codex", share: { ...share, role: "host", users: [C] } })]),
    station(B, "TestStation", true, [profile("codex", { email: "z@x.test", runtime: "codex" })]),
    station(C, "lab-node", true, [profile("sh-1", { email: "z@x.test", runtime: "codex", share: { ...share, role: "user", reachable: true } })]),
  ]);
  assert.equal(view.items.length, 1);
  assert.deepEqual([view.items[0].title, view.items[0].where], ["z@x.test", "Office、TestStation、lab-node 可用"]);
  assert.deepEqual(view.items[0].places.map((p: any) => p.stationName), ["Office", "TestStation", "lab-node"], "a separate login is available even outside the host's share limit");
  // A key: by its profile's name.
  const key = workspaceProfiles([station(A, "Office", true, [profile("备用 key", { access: { kind: "anthropic-api", key: "sk-1…2345" } })])]);
  assert.deepEqual([key.items[0].title, key.items[0].where], ["备用 key", "Office 可用"]);
});

test("each station appears once for an account it can use, even when it has its own login and a borrowed one", () => {
  const C = "c".repeat(64);
  const D = "d".repeat(64);
  const share = { id: "sh-1", host: A, allow: null };
  const sub = { email: "z@x.test", runtime: "codex" };
  const row = workspaceProfiles([
    station(A, "Office", true, [profile("codex-example", { ...sub, share: { ...share, role: "host", users: [B, C, D] } })]),
    station(B, "Laptop", true, [profile("sh-1", { ...sub, share: { ...share, role: "user" } })]),
    station(C, "TestStation", true, [profile("local", sub), profile("sh-1", { ...sub, share: { ...share, role: "user" } })]),
    station(D, "lab-node", true, [profile("local", sub), profile("sh-1", { ...sub, share: { ...share, role: "user" } })]),
  ]).items[0];
  // Fall back to the old presentation to make the repeated stations visible in the failure on main.
  const places = row.places ?? row.members;
  assert.deepEqual(places.map((p: any) => p.stationName), ["Office", "Laptop", "TestStation", "lab-node"]);
  assert.equal(row.members.length, 6, "the underlying profiles remain available individually");
});

test("a station with several copies uses one that works, and retains offline places", () => {
  const C = "c".repeat(64);
  const D = "d".repeat(64);
  const sub = { email: "z@x.test", runtime: "codex" };
  const share = { id: "sh-1", host: A, allow: null };
  const row = workspaceProfiles([
    station(A, "Office", true, [profile("host", { ...sub, share: { ...share, role: "host" } })]),
    station(B, "Laptop", true, [
      profile("needs-login", { ...sub, checkText: "需要登录", checkTone: "red", trouble: { title: "需要登录" } }),
      profile("borrowed", { ...sub, share: { ...share, role: "user", reachable: true } }),
    ]),
    station(C, "TestStation", true, [
      profile("unreachable", { ...sub, share: { id: "other", host: D, role: "user", reachable: false } }),
      profile("available", { ...sub, share: { ...share, role: "user", reachable: true } }),
    ]),
    station(D, "lab-node", false, [profile("offline", sub)]),
  ]).items[0];
  const places = row.places ?? row.members;
  assert.deepEqual(places.map((p: any) => [p.stationName, p.profileId, p.online, p.usable]), [
    ["Office", "host", true, true], ["Laptop", "borrowed", true, true],
    ["TestStation", "available", true, true], ["lab-node", "offline", false, false],
  ]);
  const broken = workspaceProfiles([station(A, "Office", true, [profile("blocked", { ...sub, trouble: { title: "额度查询失败" } })])]).items[0].places[0];
  assert.deepEqual(broken.state, { text: "额度查询失败", tone: "amber" }, "trouble remains visible even when the last login check passed");
});

test("a shared account lists all allowed stations while their copies or overviews are still pending", () => {
  const C = "c".repeat(64);
  const D = "d".repeat(64);
  const sub = { email: "z@x.test", runtime: "codex" };
  const row = workspaceProfiles([
    station(A, "Office", true, [profile("host", { ...sub, share: { id: "sh-1", role: "host", host: A, allow: [B, C] } })]),
    station(B, "Laptop", true, []),
    station(C, "TestStation", false, null),
    // The host has revoked lab-node; its old copy has not heard that yet.
    station(D, "lab-node", true, [profile("stale", { ...sub, share: { id: "sh-1", role: "user", host: A, allow: null } })]),
  ]).items[0];
  const places = row.places ?? row.members;
  assert.deepEqual(places.map((p: any) => [p.stationName, p.profileId, p.online, p.state?.text ?? null]), [
    ["Office", "host", true, null], ["Laptop", "", true, "等待同步"], ["TestStation", "", false, null],
  ]);
  const reading = workspaceProfiles([
    station(A, "Office", true, [profile("host", { ...sub, share: { id: "sh-1", role: "host", host: A, allow: [B] } })]),
    station(B, "Laptop", true, null),
  ]).items[0].places[1];
  assert.equal(reading.state.text, "正在读取");
});

test("a share following the workspace's whitelist reaches the stations on it as the viewer knows them, and its page's stations say who is", () => {
  const C = "c".repeat(64);
  const sub = { email: "z@x.test", runtime: "codex" };
  const on = (s: any, accept: boolean) => ({ ...s, overview: { ...s.overview, autoChats: { enabled: accept, canEdit: false } } });
  const host = station(A, "Office", true, [profile("host", { ...sub, share: { id: "sh-1", role: "host", host: A, allow: [A], allowAuto: true } })]);
  const row = workspaceProfiles([on(host, false), on(station(B, "Laptop", true, []), true), on(station(C, "Lab", true, []), false)]).items[0];
  // (Laptop is on the whitelist though its host has not heard yet: a copy on its way; Lab is not)
  assert.deepEqual(row.places.map((p: any) => [p.stationName, p.state?.text ?? null]), [["Office", null], ["Laptop", "等待同步"]]);
  assert.deepEqual(row.stations.map((x: any) => [x.name, x.allowed, x.acceptAutoChats, x.tasksOnly]), [
    ["Office", true, false, false], ["Laptop", true, true, false], ["Lab", false, false, false],
  ]);
  assert.equal(row.shareAuto, true);
});

test("the list's 多选 takes an account its station has alone and is up, sharing, else says why not", () => {
  const C = "c".repeat(64);
  const sub = (id: string, email: string, extra: Record<string, unknown> = {}) => profile(id, { email, runtime: "claude", ...extra });
  const rows = workspaceProfiles([
    { ...station(A, "Office", true, [
      sub("mine", "a@x.test"),
      sub("lent", "b@x.test", { share: { id: "sh-1", role: "host", host: A, allow: null } }),
      sub("both", "c@x.test"),
      profile("grok", { email: "d@x.test", runtime: "grok", shareable: false }),
    ]), overview: { sharing: true, shareAllowAuto: true, profiles: [
      sub("mine", "a@x.test"),
      sub("lent", "b@x.test", { share: { id: "sh-1", role: "host", host: A, allow: null } }),
      sub("both", "c@x.test"),
      profile("grok", { email: "d@x.test", runtime: "grok", shareable: false }),
    ] } },
    station(B, "Laptop", true, [sub("both", "c@x.test"), sub("theirs", "e@x.test", { share: { id: "sh-2", role: "user", host: C, allow: null } })]),
    station(C, "Lab", false, [sub("away", "f@x.test")]),
  ]).items;
  const of = (title: string) => rows.find((r: any) => r.title === title);
  const said = (r: any) => [r.canBatchShare, r.batchShareWhy ?? null, r.batchShareAllowAuto, r.shared];
  assert.deepEqual(said(of("a@x.test")), [true, null, true, false]);
  assert.deepEqual(said(of("b@x.test")), [true, null, true, true]);
  assert.deepEqual(said(of("c@x.test")).slice(0, 2), [false, "several"]);
  assert.deepEqual(said(of("d@x.test")).slice(0, 2), [false, "unshareable"]);
  assert.deepEqual(said(of("f@x.test")).slice(0, 2), [false, "offline"]);
  // (a copy of Lab's, Lab away: the row is the copy's, not this station's to share)
  assert.deepEqual(said(of("e@x.test")).slice(0, 2), [false, "borrowed"]);
});

test("a pending copy names the station cut off from still.fail cloud instead of waiting on", () => {
  const sub = { email: "z@x.test", runtime: "codex" };
  const host = station(A, "Studio", true, [profile("host", { ...sub, share: { id: "sh-1", role: "host", host: A, allow: [B] } })]);
  const mba = station(B, "MBA", true, []);
  const cut = (s: any) => ({ ...s, overview: { ...s.overview, mesh: { state: "running", reached: false } } });
  const placeOf = (stations: any[]) => workspaceProfiles(stations).items[0].places[1].state;
  assert.deepEqual(placeOf([host, cut(mba)]), { text: "无法连接 still.fail cloud", tone: "amber" });
  assert.deepEqual(placeOf([cut(host), mba]), { text: "Studio 无法连接 still.fail cloud", tone: "amber" });
  assert.deepEqual(placeOf([host, mba]), { text: "等待同步", tone: "neutral" });
});

test("an older station's copy of an account lent to another workspace is not listed here", () => {
  const C = "c".repeat(64);
  const own = profile("own", { runtime: "claude" });
  const lent = profile("sh-cue", { runtime: "claude", email: "cue@example.com", serves: false, share: { id: "sh-cue", host: C, role: "user", reachable: true } });
  const current = { ...station(A, "mine", true, [own, lent]), joined: true };
  const listed = workspaceProfiles([current]);
  assert.deepEqual(listed.items.flatMap((e: any) => e.members.map((m: any) => m.profileId)), ["own"]);
  assert.equal(listed.attention, 0);
  // The station page names its station by `address`.
  const page = { id: A, address: current.station, name: "mine", online: true, joined: true };
  const summary = stationProfileSummary(current.overview, page, new Map([[A, page]]));
  assert.deepEqual(summary.profileGroups, [{ group: "claude", title: "Claude 订阅", profiles: ["own"], attention: 0 }]);
  assert.deepEqual(summary.profileStates, {});
});

test("a share withheld from this workspace does not make its stations usable here", () => {
  const C = "c".repeat(64);
  const D = "d".repeat(64);
  const sub = { email: "z@x.test", runtime: "codex" };
  const share = { id: "sh-1", host: A, allow: null };
  const row = workspaceProfiles([
    // The host's newer overview says the share is withheld here; an old copy has not heard it yet.
    station(A, "Office", true, [profile("host", { ...sub, serves: false, share: { ...share, role: "host" } })]),
    station(B, "Laptop", true, [profile("stale", { ...sub, serves: true, share: { ...share, role: "user" } })]),
    station(C, "TestStation", true, [profile("local", { ...sub, serves: true })]),
    station(D, "lab-node", true, []),
  ]).items[0];
  assert.deepEqual((row.places ?? row.members).map((p: any) => p.stationName), ["TestStation"]);
  assert.equal(row.members.length, 3, "the page can still find the profiles for managing them");

  // An older joined station says the same thing in workspaces instead of serves.
  const older = workspaceProfiles([
    { ...station(A, "Office", true, [profile("host", { ...sub, workspaces: ["other"], share: { ...share, role: "host" } })]), joined: true },
    station(B, "Laptop", true, [profile("local", { ...sub, serves: true })]),
  ]).items[0];
  assert.deepEqual((older.places ?? older.members).map((p: any) => p.stationName), ["Laptop"]);

  const open = workspaceProfiles([
    { ...station(A, "Office", true, [profile("host", { ...sub, serves: true, share: { ...share, role: "host" } })]), joined: true },
    station(B, "Laptop", true, []),
  ]).items[0];
  assert.deepEqual(open.places.map((p: any) => p.stationName), ["Office", "Laptop"], "a joined station may share when this workspace is allowed");
});

test("a station with two profiles signed in to the same account: its rows named by their profiles too", () => {
  const view = workspaceProfiles([
    station(A, "default", true, [profile("工作", { email: "z@x.test", runtime: "codex" }), profile("备用", { email: "z@x.test", runtime: "codex" })]),
    station(B, "mini", true, [profile("max", { email: "z@x.test", runtime: "codex" })]),
  ]);
  assert.equal(view.items.length, 1);
  assert.deepEqual(view.items[0].members.map((m: any) => m.title), ["default · 工作", "default · 备用", "mini"]);
});

test("an account signed in on two stations, signed out on one: the row shows the one that works and names where the other needs a look", () => {
  const signedOut = shownProfile(profile("machine-claude", { email: "z@x.test", runtime: "claude", machine: true, check: { state: "login" } }));
  const fine = shownProfile(profile("machine-claude", { email: "z@x.test", runtime: "claude", machine: true, check: { state: "ok" },
    quota: { state: "ok", windows: [{ label: "每周", minutes: 10080, usedPercent: 5 }] } }));
  const view = workspaceProfiles([station(A, "macbook", true, [signedOut]), station(B, "mini", true, [fine])]);
  assert.equal(view.items.length, 1);
  const row = view.items[0];
  assert.equal(row.stationName, "mini", "the copy that works");
  assert.deepEqual([row.look, row.state], [true, { text: "macbook：需要登录", tone: "amber" }]);
  const pool = profilesOverview(view.items, () => undefined, 0, 0).pools[0]!;
  assert.deepEqual([pool.ready, pool.total, pool.nowPct], [1, 1, 95]);
  const unavailable = workspaceProfiles([station(A, "macbook", true, [signedOut]), station(B, "mini", true, [signedOut])]);
  assert.equal(profilesOverview(unavailable.items, () => undefined, 0, 0).pools[0]!.ready, 0);
  // Both fine: nothing said.
  const both = workspaceProfiles([station(A, "macbook", true, [fine]), station(B, "mini", true, [fine])]);
  assert.deepEqual([both.items[0].look, both.items[0].state, both.items[0].stationName], [false, null, "macbook"]);
});

test("the list is grouped by kind of account: Claude's subscriptions, ChatGPT's, SuperGrok's, Kimi Code's and OpenCode Go's signed in, Cursor's, Devin's, then keys", () => {
  const view = workspaceProfiles([
    station(A, "office", true, [
      profile("key", { access: { kind: "api-provider" } }),
      profile("go-key", { access: { kind: "opencode-go", key: "sk-1…2345" } }),
      profile("go", { access: { kind: "opencode-go", key: "st_1…2345", login: true } }),
      profile("kimi", { access: { kind: "env", provider: "kimi-code", login: true } }),
      profile("dev", { email: "d@x.test", runtime: "devin" }),
      profile("cur", { email: "c@x.test", runtime: "cursor" }),
      profile("super", { email: "s@x.test", runtime: "grok" }),
      profile("gpt", { email: "g@x.test", runtime: "codex" }),
      profile("b-claude", { email: "b@x.test", runtime: "claude" }),
      profile("a-claude", { email: "a@x.test", runtime: "claude", checkTone: "red" }),
    ]),
  ]);
  assert.deepEqual(view.items.map((e: any) => [e.group, e.groupTitle, e.profile.id]), [
    ["claude", "Claude 订阅", "a-claude"],
    ["claude", "Claude 订阅", "b-claude"],
    ["chatgpt", "ChatGPT 订阅", "gpt"],
    ["grok", "SuperGrok 订阅", "super"],
    ["kimi", "Kimi Code 订阅", "kimi"],
    ["opencode", "OpenCode Go 订阅", "go"],
    ["cursor", "Cursor 订阅", "cur"],
    ["devin", "Devin 订阅", "dev"],
    ["key", "API Key", "go-key"],
    ["key", "API Key", "key"],
  ]);
});

test("two profiles of one station signed in to the same account: the station said once where it is signed in", () => {
  const view = workspaceProfiles([
    station(A, "office", true, [profile("codex", { email: "z@x.test", runtime: "codex" }), profile("codex-2", { email: "z@x.test", runtime: "codex" })]),
    station(B, "mini", true, [profile("codex-3", { email: "z@x.test", runtime: "codex" })]),
  ]);
  assert.equal(view.items.length, 1);
  assert.equal(view.items[0].members.length, 3, "each profile still a member");
  assert.equal(view.items[0].where, "office、mini 可用");
});

test("Hermes profiles can name models and expose a selected model to new chats", () => {
  const base = { id: "hm", name: "Hermes", runtime: "hermes", runtimes: ["hermes"], access: {kind:"env"}, models: [], env: [] };
  assert.equal(shownProfile(base).canAddModel, true);
  const listed = shownProfile({...base, models:["openrouter:model-a"], check: {state:"ok",models:["openrouter:model-a"],detail:""}});
  assert.ok(listed.available.includes("openrouter:model-a"));
  const selected = {...base,models:["openrouter:model-a"]};
  assert.deepEqual(runtimes({profiles:[selected]}),[{runtime:"hermes",models:["openrouter:model-a"]}]);
});

test("service profiles decorate without agent runtime, dedup by (service, email), and stay out of model pickers", () => {
  const raw = {
    id: "gpu-1",
    name: "GPU 1",
    email: "alice@example.com",
    runtime: null,
    service: "fake-gpu",
    runtimes: [],
    access: { kind: "service", key: "", service: "fake-gpu" },
    models: [],
    env: [],
  };
  const decorated = shownProfile(raw);
  assert.equal(decorated.group, "service");
  assert.equal(decorated.modelsReading, false);
  assert.equal(decorated.canAddModel, false);
  assert.equal(decorated.signInProvider, "");
  assert.deepEqual(decorated.uses, []);
  assert.deepEqual(runtimes({ profiles: [decorated] }), []);

  // Same service + same email across two stations merge into one account row;
  // an agy subscription with the same email stays separate; service without email never merges.
  const svcA = shownProfile({ ...raw, id: "gpu-a" });
  const svcB = shownProfile({ ...raw, id: "gpu-b" });
  const agySameEmail = shownProfile({
    id: "agy-1",
    name: "AGY",
    email: "alice@example.com",
    runtime: "agy",
    runtimes: ["agy"],
    access: { kind: "subscription", key: "" },
    models: [],
    env: [],
  });
  const anonA = shownProfile({ ...raw, id: "gpu-anon-a", email: null });
  const anonB = shownProfile({ ...raw, id: "gpu-anon-b", email: null });
  const view = workspaceProfiles([
    station(A, "office", true, [svcA, agySameEmail, anonA]),
    station(B, "mini", true, [svcB, anonB]),
  ]);
  assert.equal(view.items.length, 4);
  const merged = view.items.find((i: any) => i.group === "service" && i.members.length === 2);
  assert.ok(merged, "same (service, email) across stations should merge");
  assert.equal(merged.title, "alice@example.com");
  const anon = view.items.find((i: any) => i.group === "service" && i.members.length === 1);
  assert.ok(anon);
  assert.equal(anon.title, "GPU 1");
  assert.ok(view.items.some((i: any) => i.group === "agy" && i.members.length === 1), "agy subscription must not merge with service profile");
});

test("colab service profile groups under Google without merging with Antigravity CLI or entering Gemini overview pool", () => {
  const colab = shownProfile({
    id: "colab-1",
    name: "lin@example.com",
    email: "lin@example.com",
    runtime: null,
    service: "colab",
    runtimes: [],
    access: { kind: "service", key: "", service: "colab" },
    models: [],
    env: [],
    check: { state: "ok", detail: "已登录，lin@example.com", models: null, checkedAt: 1000 },
    quota: {
      state: "ok",
      windows: [],
      credits: { hasCredits: true, unlimited: false, balance: "2500.00 CU" },
      detail: "1 台运行中 · 10.05 CU/h",
      checkedAt: 1000,
    },
  });
  const agy = shownProfile({
    id: "agy-1",
    name: "lin@example.com",
    email: "lin@example.com",
    runtime: "agy",
    runtimes: ["agy"],
    access: { kind: "subscription", key: "" },
    models: [],
    env: [],
    check: { state: "ok", detail: "已登录", models: [], checkedAt: 1000 },
    quota: { state: "ok", windows: [], checkedAt: 1000 },
  });
  assert.equal(colab.group, "agy");
  assert.equal(colab.groupTitle, "Google");
  assert.equal(agy.group, "agy");
  assert.equal(agy.groupTitle, "Google");
  assert.equal(colab.providerName, "Google Colab");
  assert.equal(colab.providerMark, "colab");
  assert.equal(colab.signInProvider, "Google Colab");
  assert.equal(colab.usesText, "Google Colab GPU 算力");

  const expired = shownProfile({
    id: "colab-2",
    name: "expired@example.com",
    email: "expired@example.com",
    runtime: null,
    service: "colab",
    runtimes: [],
    access: { kind: "service", key: "", service: "colab" },
    models: [],
    env: [],
    check: { state: "login", detail: "未登录", models: null, checkedAt: 1000 },
  });
  assert.equal(expired.trouble?.action, "login");

  // Same email for Antigravity CLI and Colab stay separate rows under Google.
  const view = workspaceProfiles([station(A, "office", true, [agy, colab, expired])]);
  const googleRows = view.items.filter((i: any) => i.group === "agy");
  assert.equal(googleRows.length, 3);
  assert.ok(googleRows.every((i: any) => i.groupTitle === "Google"));

  // Neither ok nor expired (needsFix) Colab profiles enter the Gemini overview pool.
  const ov = profilesOverview(view.items, () => null, 1_900_000_000_000, 480);
  assert.equal(ov.pools.find((p) => p.title === "Gemini"), undefined);
});
