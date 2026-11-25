// The search (views/search.ts): what the device holds and what each station finds, one list.
import assert from "node:assert/strict";
import { test } from "node:test";
import { HostError } from "../src/error.ts";
import { SEARCH_SETTLE_MS, SEARCH_STALE_MS } from "../src/station/sync.ts";
import { openOf } from "../src/views/search.ts";
import { apply, subscribe, v } from "./helpers.ts";
import { base, chatsOf, started, stationReplies } from "./station-fixture.ts";

// deno-lint-ignore no-explicit-any
type J = any;

const row = (id: string, thread: number, title: string) => ({ id, session: id, thread, title, agents: [], last: null, unread: false, mine: true, lastActiveAt: thread, connect: null, origin: null });
const said = (thread: number, n: number, text: string, at: number) => ({ thread, n, kind: "message", ts: `${n}.0`, authorKind: "person", author: "a@x", authorName: "阿甲", text, at });

const found = {
  building: false,
  groups: [
    { kind: "chat", more: false, hits: [
      { kind: "chat", key: "c:9", title: "旧的部署", text: "", at: 50, thread: 9, chat: "old", archived: true },
      // Its words late in its title: said where they are.
      { kind: "chat", key: "c:11", title: "动效测试（请照做）：先用命令运行 sleep 3，然后部署", text: "动效测试（请照做）：先用命令运行 sleep 3，然后部署", at: 40, thread: 11, chat: "motion", archived: true },
    ] },
    {
      kind: "message",
      more: false,
      hits: [
        // One the device holds too: listed once.
        { kind: "message", key: "m:7:1", title: "", text: "部署 studio", at: 1000, thread: 7, seq: 1, chat: "a", authorKind: "person", author: "a@x" },
        { kind: "message", key: "m:9:3", title: "", text: "部署完了", at: 3000, thread: 9, seq: 3, chat: "old", chatTitle: "旧的部署", authorKind: "agent", author: "old", archived: true },
      ],
    },
    { kind: "job", more: true, hits: [{ kind: "job", key: "j:j1", title: "部署预览", text: "pnpm dev --filter 部署", at: 10, job: "j1", port: 5173, session: "a", chat: "a", thread: 7 }] },
  ],
};

test("a_search_lists_what_the_device_holds_and_what_its_stations_find_each_once", async () => {
  const { host, core } = await started({
    ...base(),
    ...chatsOf([{ ...row("a", 7, "部署页"), last: { seq: 1 } }, { ...row("b", 8, "别的"), last: { seq: 1 } }]),
    "GET /threads/7/entries?limit=50": { first: 1, last: 1, entries: [said(7, 1, "部署 studio", 1000)] },
    "GET /threads/8/entries?limit=50": { first: 1, last: 1, entries: [said(8, 1, "无关", 500)] },
    "GET /search?q=%E9%83%A8%E7%BD%B2&limit=6": found,
  });
  const ui = core.connect();
  subscribe(core, ui, 1, { topic: "search", scope: "ws", query: "部署" });
  await host.settle();
  // The chats the device holds go out first, before its messages are looked through (a scan of all it keeps).
  const sent = host.emitted.filter(([, m]: J) => m.id === 1).map(([, m]: J) => m);
  const firstValue = sent.find((m: J) => "value" in m);
  assert.deepEqual(firstValue.value.items.map((i: J) => i.id), ["a"]);
  assert.deepEqual(firstValue.value.messages, []);
  const values = new Map();
  apply(host, values);
  // Before the stations answer: what the device holds.
  assert.deepEqual(v(values, 1).items.map((i: J) => i.id), ["a"]);
  assert.deepEqual(v(values, 1).messages.map((m: J) => [m.thread, m.seq]), [[7, 1]]);
  assert.equal(v(values, 1).wait.reading, true);
  await host.time.pass(SEARCH_SETTLE_MS + 10);
  await host.settle();
  apply(host, values);
  const view = v(values, 1);
  // The archived chat a station found, after the device's.
  assert.deepEqual(view.items.map((i: J) => [i.id, i.archived ?? false]), [["a", false], ["old", true], ["motion", true]]);
  // A title with the words first says nothing more; one with them late, where they are.
  assert.equal(view.items[1].foundText, undefined);
  assert.match(view.items[2].foundText, /部署$/);
  assert.ok(view.items[2].foundMarks.length > 0);
  assert.equal(view.items[2].stateText, "已归档");
  // Newest first, the one both have once.
  assert.deepEqual(view.messages.map((m: J) => [m.thread, m.seq]), [[9, 3], [7, 1]]);
  assert.equal(view.messages[0].chat.title, "旧的部署");
  assert.deepEqual(view.groups.map((g: J) => [g.kind, g.items.length, g.more]), [["job", 1, true]]);
  const job = view.groups[0].items[0];
  assert.deepEqual([job.title, job.job, job.port, job.chat, job.station], ["部署预览", "j1", 5173, "a", "ws/st"]);
  // Where it opens: its chat, its page over it.
  assert.deepEqual(job.open, { to: "service", station: "ws/st", chat: "a", job: "j1" });
  assert.deepEqual(job.marks.length > 0, true);
  assert.equal(view.wait.reading, false);
  core.close();
});

test("a_station_from_before_search_is_said_to_need_an_update", async () => {
  const { host, core } = await started({ ...base(), ...chatsOf([row("a", 7, "部署页")]) });
  const ui = core.connect();
  subscribe(core, ui, 1, { topic: "search", scope: "ws", query: "部署" });
  await host.settle();
  await host.time.pass(SEARCH_SETTLE_MS + 10);
  await host.settle();
  const values = new Map();
  apply(host, values);
  assert.match(v(values, 1).note ?? "", /更新/);
  assert.deepEqual(v(values, 1).items.map((i: J) => i.id), ["a"]);
  core.close();
});

test("a_search_shown_again_asks_its_stations_again", async () => {
  const replies: Record<string, unknown> = { ...base(), ...chatsOf([row("a", 7, "部署页")]), "GET /search?q=%E9%83%A8%E7%BD%B2&limit=6": found };
  const { host, core } = await started(replies);
  const ui = core.connect();
  subscribe(core, ui, 1, { topic: "search", scope: "ws", query: "部署" });
  await host.settle();
  await host.time.pass(SEARCH_SETTLE_MS + 10);
  await host.settle();
  core.receive(ui, { kind: "unsubscribe", id: 1, unsubscribe: true });
  await host.settle();
  // Archived meanwhile: the station says so now.
  replies["GET /search?q=%E9%83%A8%E7%BD%B2&limit=6"] = { building: false, groups: [{ kind: "chat", more: false, hits: [{ kind: "chat", key: "c:7", title: "部署页", text: "", at: 9, thread: 7, chat: "a", archived: true }] }] };
  Object.assign(replies, chatsOf([]));
  subscribe(core, ui, 2, { topic: "search", scope: "ws", query: "部署" });
  await host.settle();
  await host.time.pass(SEARCH_SETTLE_MS + 10);
  await host.settle();
  const values = new Map();
  apply(host, values);
  assert.deepEqual(v(values, 2).groups, []);
  assert.equal(v(values, 2).messages.length, 0);
  core.close();
});

test("a_search_shown_is_asked_again_when_its_station_says_a_chat_changed", async () => {
  const replies: Record<string, unknown> = { ...base(), ...chatsOf([row("a", 7, "部署页")]), "GET /search?q=%E9%83%A8%E7%BD%B2&limit=6": found };
  const { host, core, push } = await started(replies);
  const ui = core.connect();
  subscribe(core, ui, 1, { topic: "search", scope: "ws", query: "部署" });
  await host.settle();
  await host.time.pass(SEARCH_SETTLE_MS + 10);
  await host.settle();
  // Archived on the station: it says so, and finds it so (asked again: `again=1`).
  replies["GET /search?q=%E9%83%A8%E7%BD%B2&limit=6&again=1"] = { building: false, groups: [{ kind: "chat", more: false, hits: [{ kind: "chat", key: "c:7", title: "部署页", text: "", at: 9, thread: 7, chat: "a", archived: true }] }] };
  push("thread", { id: 7, entries: [] });
  // Told again and again meanwhile (a busy station): asked again once.
  push("thread", { id: 7, entries: [] });
  await host.settle();
  await host.time.pass(SEARCH_STALE_MS + SEARCH_SETTLE_MS + 10);
  await host.settle();
  const values = new Map();
  apply(host, values);
  assert.deepEqual(v(values, 1).items.map((i: J) => [i.id, i.archived ?? false]), [["a", true]]);
  assert.equal(v(values, 1).messages.length, 0);
  core.close();
});

test("what_a_search_finds_says_where_it_opens_as_every_client_has_a_page_for_it", () => {
  const at = { station: "ws/st" };
  // A service its chat and its page over it, a task its chat with it picked, one with no id its chat; none without a chat.
  assert.deepEqual(openOf({ ...at, kind: "job", chat: "a", job: "j1", port: 5173 }), { to: "service", station: "ws/st", chat: "a", job: "j1" });
  assert.deepEqual(openOf({ ...at, kind: "job", chat: "a", job: "j2" }), { to: "task", station: "ws/st", chat: "a", job: "j2" });
  assert.deepEqual(openOf({ ...at, kind: "job", chat: "a" }), { to: "chat", station: "ws/st", chat: "a" });
  assert.equal(openOf({ ...at, kind: "job", job: "j1" }), null);
  // A station its page, a member the workspace's members, anything else in a chat that chat.
  assert.deepEqual(openOf({ ...at, kind: "station" }), { to: "station", station: "ws/st" });
  assert.deepEqual(openOf({ kind: "member", station: "" }), { to: "members", station: "" });
  assert.deepEqual(openOf({ ...at, kind: "skill", chat: "b" }), { to: "chat", station: "ws/st", chat: "b" });
  assert.equal(openOf({ ...at, kind: "skill" }), null);
  // A folder entered; a text read, a video played, in their folder; anything else its folder shown.
  const file = (path: string, fileKind: string, more: J = {}) => openOf({ ...at, kind: "file", path, fileKind, dir: fileKind === "folder", ...more });
  assert.deepEqual(file("/home/a/docs", "folder"), { to: "files", station: "ws/st", root: "/home/a/docs", path: "" });
  assert.deepEqual(file("/home/a/docs/README.md", "markdown"), { to: "files", station: "ws/st", root: "/home/a/docs", path: "README.md", how: "read" });
  assert.deepEqual(file("C:\\Users\\a\\clip.mp4", "video"), { to: "files", station: "ws/st", root: "C:\\Users\\a", path: "clip.mp4", how: "play" });
  assert.deepEqual(file("/home/a/docs/a.png", "image"), { to: "files", station: "ws/st", root: "/home/a/docs", path: "" });
  // Found under a folder a read-only member's workspace pinned: from there.
  const pinned = { root: "/srv/share", rel: "photos/2026/a.png" };
  assert.deepEqual(file("/srv/share/photos/2026/a.png", "image", pinned), { to: "files", station: "ws/st", root: "/srv/share", path: "photos/2026" });
  assert.deepEqual(file("/srv/share/notes/b.txt", "text", { root: "/srv/share", rel: "notes/b.txt" }), { to: "files", station: "ws/st", root: "/srv/share", path: "notes/b.txt", how: "read" });
  assert.deepEqual(file("/srv/share/notes", "folder", { root: "/srv/share", rel: "notes" }), { to: "files", station: "ws/st", root: "/srv/share", path: "notes" });
  // A file with no path opens nowhere.
  assert.equal(openOf({ ...at, kind: "file", chat: "a" }), null);
});

test("files_found_at_the_top_of_a_disk_keep_the_root_and_the_file_to_open", () => {
  const station = "ws/st";
  for (const root of ["/", "C:\\", "D:/"]) {
    const file = (name: string, fileKind: string, more: J = {}) => openOf({ kind: "file", station, path: `${root}${name}`, fileKind, ...more });
    assert.deepEqual([
      file("notes.md", "markdown"),
      file("clip.mp4", "video"),
      file("photo.png", "image"),
      file("", "folder", { dir: true }),
    ], [
      { to: "files", station, root, path: "notes.md", how: "read" },
      { to: "files", station, root, path: "clip.mp4", how: "play" },
      { to: "files", station, root, path: "" },
      { to: "files", station, root, path: "" },
    ], root);
  }
});

test("a_search_typed_on_asks_its_stations_for_the_last_words_alone_and_again_only_for_them", async () => {
  const replies: Record<string, unknown> = { ...base(), ...chatsOf([row("a", 7, "部署页")]) };
  for (const q of ["u", "up", "upd"]) for (const tail of ["", "&again=1"]) replies[`GET /search?q=${q}&limit=6${tail}`] = { building: false, groups: [] };
  const { host, core, push } = await started(replies);
  const ui = core.connect();
  // Typed: each words shown in place of the last (the ones let go are kept a while, not shown).
  let id = 0;
  for (const q of ["u", "up", "upd"]) {
    if (id > 0) core.receive(ui, { kind: "unsubscribe", id, unsubscribe: true });
    subscribe(core, ui, ++id, { topic: "search", scope: "ws", query: q });
    await host.settle();
    await host.time.pass(50);
  }
  await host.time.pass(SEARCH_SETTLE_MS + 10);
  await host.settle();
  const asked = (from: number) => host.requests.slice(from).map((r: J) => r.url as string).filter((u) => u.includes("/search?")).map((u) => u.split("q=")[1]);
  assert.deepEqual(asked(0), ["upd&limit=6"]);
  const before = host.requests.length;
  push("thread", { id: 7, entries: [] });
  await host.settle();
  await host.time.pass(SEARCH_STALE_MS + SEARCH_SETTLE_MS + 10);
  await host.settle();
  assert.deepEqual(asked(before), ["upd&limit=6&again=1"]);
  core.close();
});

test("stale_in_flight_searches_are_cancelled_when_query_changes_so_the_latest_query_is_not_blocked", async () => {
  const replies: Record<string, unknown> = {
    ...base(),
    ...chatsOf([row("a", 7, "部署页")]),
    "GET /search?q=a&limit=6": { building: false, groups: [] },
    "GET /search?q=admin&limit=6": { building: false, groups: [] },
    "GET /search?q=admin%20cli&limit=6": {
      building: false,
      groups: [{ kind: "chat", more: false, hits: [{ kind: "chat", key: "c:21", title: "Admin CLI", text: "", at: 99, thread: 21, chat: "adm", archived: true }] }],
    },
  };
  const { host, core } = await started(replies);
  const ui = core.connect();
  // Hold the first two search requests so both slots of the station lane (width 2) are occupied.
  const releaseA = host.hold("/search?q=a&limit=6");
  const releaseAdmin = host.hold("/search?q=admin&limit=6");
  subscribe(core, ui, 1, { topic: "search", scope: "ws", query: "a" });
  await host.settle();
  await host.time.pass(SEARCH_SETTLE_MS + 10);
  await host.settle();
  core.receive(ui, { kind: "unsubscribe", id: 1, unsubscribe: true });
  subscribe(core, ui, 2, { topic: "search", scope: "ws", query: "admin" });
  await host.settle();
  await host.time.pass(SEARCH_SETTLE_MS + 10);
  await host.settle();
  // Now switch to the latest query while the previous two requests are still held in flight.
  core.receive(ui, { kind: "unsubscribe", id: 2, unsubscribe: true });
  subscribe(core, ui, 3, { topic: "search", scope: "ws", query: "admin cli" });
  await host.settle();
  await host.time.pass(SEARCH_SETTLE_MS + 10);
  await host.settle();
  const values = new Map();
  apply(host, values);
  const view = v(values, 3);
  assert.equal(view.wait.reading, false, "latest search should not be blocked behind cancelled in-flight searches");
  assert.deepEqual(view.items.map((i: J) => i.id), ["adm"]);
  releaseA();
  releaseAdmin();
  core.close();
});

test("a_non_http_search_failure_ends_waiting_surfaces_the_error_and_retries_when_shown_again", async () => {
  const replies: Record<string, unknown> = {
    ...base(),
    ...chatsOf([row("a", 7, "部署页")]),
    "GET /search?q=timeout&limit=6": {
      building: false,
      groups: [{ kind: "chat", more: false, hits: [{ kind: "chat", key: "c:30", title: "Timeout 排查", text: "", at: 88, thread: 30, chat: "to1", archived: true }] }],
    },
  };
  let fail = true;
  const { host, core } = await started(replies);
  stationReplies(host, (req) => {
    if (req.url.includes("/search?q=timeout&limit=6") && fail) throw new HostError("connection reset");
    return undefined;
  });
  const ui = core.connect();
  subscribe(core, ui, 1, { topic: "search", scope: "ws", query: "timeout" });
  await host.settle();
  await host.time.pass(SEARCH_SETTLE_MS + 10);
  await host.settle();
  const values = new Map();
  apply(host, values);
  const failed = v(values, 1);
  assert.equal(failed.wait.reading, false, "non-HTTP failure must stop the waiting indicator");
  assert.equal(failed.wait.failing.length, 1);
  assert.equal(failed.wait.failing[0].station, "ws/st");
  // Re-opening the search retries after a transient non-HTTP failure.
  core.receive(ui, { kind: "unsubscribe", id: 1, unsubscribe: true });
  await host.settle();
  fail = false;
  subscribe(core, ui, 2, { topic: "search", scope: "ws", query: "timeout" });
  await host.settle();
  await host.time.pass(SEARCH_SETTLE_MS + 10);
  await host.settle();
  apply(host, values);
  const retried = v(values, 2);
  assert.equal(retried.wait.reading, false);
  assert.deepEqual(retried.wait.failing, []);
  assert.deepEqual(retried.items.map((i: J) => i.id), ["to1"]);
  core.close();
});

for (const topic of ["chatSearch", "search"] as const) {
  test(`a_${topic}_let_go_before_its_messages_were_looked_for_shows_them_when_shown_again`, async () => {
    const { host, core } = await started({
      ...base(),
      ...chatsOf([{ ...row("a", 7, "部署页"), last: { seq: 1 } }]),
      "GET /threads/7/entries?limit=50": { first: 1, last: 1, entries: [said(7, 1, "部署 studio", 1000)] },
    });
    const ui = core.connect();
    subscribe(core, ui, 9, { topic: "chats", scope: "ws" });
    await host.settle();
    await host.time.pass(5000);
    await host.settle();
    const asked = topic === "chatSearch" ? { topic, scope: "ws", query: "部署", messages: 10 } : { topic, scope: "ws", query: "部署" };
    subscribe(core, ui, 1, asked);
    // Let go (kept a while) before its turn came, as a word typed on; then the word taken back.
    core.receive(ui, { kind: "unsubscribe", id: 1, keep: true } as J);
    await host.settle();
    subscribe(core, ui, 2, asked);
    await host.settle();
    await host.time.pass(SEARCH_SETTLE_MS + 10);
    await host.settle();
    const values = new Map();
    apply(host, values);
    assert.deepEqual(v(values, 2).messages.map((m: J) => [m.thread, m.seq]), [[7, 1]]);
    core.close();
  });
}

test("a_message_said_while_a_search_shows_keeps_what_it_found_shown_until_it_is_looked_through_again", async () => {
  const { host, core } = await started({
    ...base(),
    ...chatsOf([{ ...row("a", 7, "部署页"), last: { seq: 1 } }]),
    "GET /threads/7/entries?limit=50": { first: 1, last: 1, entries: [said(7, 1, "部署 studio", 1000)] },
  });
  const ui = core.connect();
  subscribe(core, ui, 9, { topic: "chats", scope: "ws" });
  await host.settle();
  await host.time.pass(5000);
  await host.settle();
  subscribe(core, ui, 1, { topic: "chatSearch", scope: "ws", query: "部署", messages: 10 });
  await host.settle();
  const values = new Map();
  apply(host, values);
  assert.equal(v(values, 1).messages.length, 1);
  core.inner.data.putItems("entry", "ws/st", "7", [[2, said(7, 2, "部署 again", 2000)]]);
  for (const t of core.inner.store.liveTopics().filter((t: J) => t.topic === "chatSearch")) core.inner.store.invalidate(t);
  let fewest = Infinity;
  for (let i = 0; i < 10; i++) {
    await host.time.pass(50);
    await host.settle();
    // (each value sent taken alone: one sent without its messages and made whole again in the same step is seen)
    for (const one of host.takeEmitted()) {
      apply({ takeEmitted: () => [one] } as J, values);
      fewest = Math.min(fewest, v(values, 1).messages.length);
    }
  }
  assert.ok(fewest >= 1, "what it found stays shown while it is looked through again");
  assert.deepEqual(v(values, 1).messages.map((m: J) => m.seq), [2, 1]);
  core.close();
});
