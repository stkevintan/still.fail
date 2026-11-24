// P5-5's live parts of the station as the MoonBit program runs them itself, with no Node (station/mb
// src/station_main/live_p5_5*.mbt): the connects, the copies and a retirement, the moves, the updates and the station's
// `beta` features. `run` under a launcher of the test's, against a Slack and a still.fail feed of the test's on
// 127.0.0.1: a Slack connect connected on its socket and slack_api called through the agents' door as the session's
// bot; the station's latest release read from the channel it is on, and that channel switched as `stillfail update
// --beta` asks it, station_move offered to the agents on either channel; a stop that leaves nothing. Then the same parts made
// in the harness (`--builder harness-station-main`'s "p5_5"), as the admin API (P5-1's, not made yet) would ask them:
// the overview's `features`, `updates`, `move` and `copies`, the routes of the updates, the moves and the copies, and
// the mesh's methods of the copies, a retirement, a hand-over and a move answered. Every program is run with a PATH
// that names no directory with a Node in it.
import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { createHash, createPublicKey, generateKeyPairSync, sign } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { type AddressInfo, createServer as netServer, type Server } from "node:net";
import { createServer, request } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { after, test } from "node:test";
import { type WebSocket, WebSocketServer } from "ws";
import { mbHarnessBinary, mbStationBinary } from "./mb-harness.ts";
import { Store } from "../src/store/store.ts";
import { FakeFeishu } from "./feishu-fake.ts";

const binary = mbStationBinary();
/// (the tests' program, its harness: the station's own commands are the reader's)
const harnessProgram = mbHarnessBinary();
const skip = binary === null ? "the MoonBit program (stillfail-reader) is not built here" : harnessProgram === null ? "the tests' MoonBit program (stillfail-reader-harness) is not built here" : process.platform === "win32" ? "the launcher's descriptors are Unix's" : false;

const dirs: string[] = [];
const fresh = (what: string) => {
  const dir = mkdtempSync(join(tmpdir(), `sf55-${what}-`));
  dirs.push(dir);
  return dir;
};
const children: ChildProcess[] = [];
const closers: (() => void)[] = [];
after(async () => {
  for (const c of closers) c();
  const left = children.filter((c) => c.exitCode === null && c.signalCode === null);
  for (const c of left) c.kill("SIGKILL");
  await Promise.all(left.map((c) => new Promise<void>((r) => c.once("exit", () => r()))));
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

/// An environment with no Node: an empty PATH of its own, HOME and TMPDIR as given.
const noNode = (more: Record<string, string> = {}) => ({ PATH: fresh("path"), HOME: process.env.HOME ?? tmpdir(), TMPDIR: tmpdir(), ...more });

/// What may never come, waited for as it is told (each change calls `poke`), failing with what it waited for.
const pokes: (() => void)[] = [];
const poke = () => {
  for (const p of pokes.splice(0)) p();
};
function until(what: string, ok: () => boolean, ms = 20_000, standing: () => string = () => ""): Promise<void> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`never came: ${what} ${standing()}`)), ms);
    const look = () => {
      if (ok()) {
        clearTimeout(timer);
        resolve();
      } else pokes.push(look);
    };
    look();
  });
}

// ── the stand-ins: Slack (its Web API and Socket Mode) and still.fail's release feed ──

type Asked = { m: string; auth: string | null; form: Record<string, string> };
async function slackStandIn() {
  const asked: Asked[] = [];
  const sockets: WebSocket[] = [];
  const server = createServer(async (req, res) => {
    const chunks: Buffer[] = [];
    for await (const c of req) chunks.push(c as Buffer);
    const form = Object.fromEntries(new URLSearchParams(Buffer.concat(chunks).toString()));
    const m = (req.url ?? "").split("?")[0]!.replace(/^\/api\//, "");
    asked.push({ m, auth: (req.headers.authorization as string | undefined) ?? null, form });
    poke();
    const ok = (body: object) => {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ ok: true, ...body }));
    };
    switch (m) {
      case "auth.test":
        return ok({ team: "Acme", team_id: "T1", url: "https://acme.slack.com/", user_id: "UB", user: "bot", bot_id: "BB" });
      case "users.info":
        return ok({ user: { profile: { display_name: "Agent", image_72: "https://bot" } } });
      case "apps.connections.open":
        return ok({ url: `ws://127.0.0.1:${(server.address() as AddressInfo).port}/socket` });
      case "conversations.info":
        return ok({ channel: { id: form.channel, name: `name-${form.channel}` } });
      default:
        return ok({});
    }
  });
  const wss = new WebSocketServer({ server, path: "/socket" });
  wss.on("connection", (ws) => {
    sockets.push(ws);
    ws.send(JSON.stringify({ type: "hello" }));
    poke();
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  closers.push(() => {
    for (const c of wss.clients) c.terminate();
    wss.close();
    server.closeAllConnections();
    server.close();
  });
  return { base: `http://127.0.0.1:${(server.address() as AddressInfo).port}/api`, asked, sockets };
}

// The tests' release key and a feed it signed (scripts/release-sign.ts's shape).
const { privateKey } = generateKeyPairSync("ed25519");
const RAW = Buffer.from(createPublicKey(privateKey).export({ format: "jwk" }).x as string, "base64url").toString("base64");
const keyId = createHash("sha256").update(Buffer.from(RAW, "base64")).digest("hex").slice(0, 16);
const feedOf = (build: number) => {
  const words = Buffer.from(JSON.stringify({
    kind: "stillfail-station-release", version: `0.1.${build}`, build, commit: "0".repeat(40), node: "24.21.0",
    builds: { "darwin-arm64": { sha256: "a".repeat(64), size: 1000, nodeSha256: "b".repeat(64) }, "linux-x64": { sha256: "a".repeat(64), size: 1000, nodeSha256: "b".repeat(64) } },
  }));
  return { version: `0.1.${build}`, build, commit: "0".repeat(40), release: words.toString("base64"), signature: sign(null, words, privateKey).toString("base64"), key: keyId };
};
async function feedStandIn() {
  const asked: string[] = [];
  const server = createServer((req, res) => {
    asked.push(req.url ?? "");
    poke();
    const body = req.url === "/releases/station.json" ? feedOf(9500) : req.url === "/releases/station-beta.json" ? feedOf(9600) : null;
    // (the control plane's own calls, its presence too, answered unavailable: a 404 there says the station was taken
    // out of its workspace, which stops its work)
    const release = (req.url ?? "").startsWith("/releases/");
    res.writeHead(body !== null ? 200 : release ? 404 : 503, { "content-type": "application/json" });
    res.end(JSON.stringify(body ?? { error: "no" }));
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  closers.push(() => {
    server.closeAllConnections();
    server.close();
  });
  return { origin: `http://127.0.0.1:${(server.address() as AddressInfo).port}`, asked };
}

/// A data directory in a workspace (cloud.json as the control plane wrote it), its release its own `app` (an installer's,
/// whose updates may be taken), config.json as given.
function station(config: object): { data: string; app: string; id: string } {
  const data = fresh("data");
  const made = spawnSync(binary!, ["id", "--data", data], { env: noNode(), encoding: "utf8" });
  assert.equal(made.status, 0, made.stderr);
  const id = made.stdout.trim();
  const app = join(data, "app");
  mkdirSync(app, { recursive: true });
  writeFileSync(join(app, "BUILD"), "9400\n");
  writeFileSync(join(data, "config.json"), JSON.stringify(config));
  return { data, app, id };
}
const cloudOf = (id: string, origin: string) => ({
  origin, station: id, workspace: "w1", workspace_name: "团队", name: "mac", relay_url: "", relay_urls: [], grant_keys: null,
  peers: [{ id, name: "mac" }, { id: "b".repeat(64), name: "other" }], revocations: [],
});

// ── run, under a launcher of the test's ──

type Launched = { child: ChildProcess; said: any[]; next: (what: string, ok: (m: any) => boolean) => Promise<any>; tell: (m: unknown) => void; ended: Promise<number | null>; err: () => string };

async function launch(data: string, app: string, env: Record<string, string>): Promise<Launched> {
  const listener = () => new Promise<Server>((resolve) => {
    const s = netServer();
    s.listen(0, "127.0.0.1", () => resolve(s));
  });
  const [mcp, loop] = [await listener(), await listener()];
  const fd = (s: Server) => (s as any)._handle.fd as number;
  const child = spawn(binary!, ["run", "--app", app, "--data", data, "--launcher-fds", "3,4,5", "--launcher-carries", "--launcher-heartbeat"], {
    stdio: ["ignore", "pipe", "pipe", fd(mcp), fd(loop), "pipe"],
    env: noNode({ STILLFAIL_HELD_EVERY_MS: "300", ...env }),
  });
  children.push(child);
  mcp.close();
  loop.close();
  const said: any[] = [];
  const channel = (child.stdio as readonly unknown[])[5] as import("node:net").Socket;
  createInterface({ input: channel }).on("line", (line) => {
    said.push(JSON.parse(line));
    poke();
  });
  let err = "";
  child.stderr!.on("data", (d) => (err += d));
  const next = async (what: string, ok: (m: any) => boolean) => {
    await until(what, () => said.some(ok), 20_000, () => `said ${JSON.stringify(said)}; stderr ${err}`);
    return said.find(ok);
  };
  const ended = new Promise<number | null>((resolve) => child.on("exit", (code) => resolve(code)));
  return { child, said, next, tell: (m) => channel.write(`${JSON.stringify(m)}\n`), ended, err: () => err };
}

function post(port: number, path: string, body: unknown, token?: string): Promise<any> {
  return new Promise((resolve, reject) => {
    const req = request({ host: "127.0.0.1", port, path, method: "POST", headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) } }, (res) => {
      let text = "";
      res.on("data", (d) => (text += d));
      res.on("end", () => resolve(JSON.parse(text)));
    });
    req.on("error", reject);
    req.end(JSON.stringify(body));
  });
}
function getJson(port: number, path: string): Promise<any> {
  return new Promise((resolve, reject) => {
    const req = request({ host: "127.0.0.1", port, path, method: "GET" }, (res) => {
      let text = "";
      res.on("data", (d) => (text += d));
      res.on("end", () => resolve(JSON.parse(text)));
    });
    req.on("error", reject);
    req.end();
  });
}
function watchOverviews(port: number, path: string): { opened: Promise<number>; close: () => void; latest: () => any } {
  let buf = "";
  let event = "";
  let latest: any = null;
  let close = () => {};
  const opened = new Promise<number>((resolve, reject) => {
    const req = request({ host: "127.0.0.1", port, path }, (res) => {
      res.setEncoding("utf8");
      res.on("data", (chunk: string) => {
        buf += chunk;
        for (let at = buf.indexOf("\n"); at !== -1; at = buf.indexOf("\n")) {
          const line = buf.slice(0, at).replace(/\r$/, "");
          buf = buf.slice(at + 1);
          if (line.startsWith("event:")) event = line.slice(6).trim();
          else if (line.startsWith("data:") && event === "overview") {
            try { latest = JSON.parse(line.slice(5)); } catch {}
            poke();
          } else if (line === "") event = "";
        }
      });
      resolve(res.statusCode!);
    });
    req.on("error", reject);
    close = () => req.destroy();
    req.end();
  });
  closers.push(() => close());
  return { opened, close: () => close(), latest: () => latest };
}
// (the whole station's tools, as a session's bearer lists them: those of the connects' and the updates' parts)
const PARTS_TOOLS = new Set(["feishu_api", "slack_api", "station_move", "station_retire", "station_version"]);
const toolNames = async (port: number, token: string) => {
  const listed = await post(port, "/mcp", { jsonrpc: "2.0", id: 1, method: "tools/list" }, token);
  assert.ok(listed.result, JSON.stringify(listed));
  return listed.result.tools.map((t: any) => t.name).filter((n: string) => PARTS_TOOLS.has(n)).sort();
};

test("run: a Slack connect and a Feishu one connected, slack_api and feishu_api called as their bots, the release read from the channel it is on and that channel switched, station_move offered on either channel, a stop that leaves nothing", { skip }, async () => {
  const slack = await slackStandIn();
  const feed = await feedStandIn();
  const feishu = await FakeFeishu.start();
  closers.push(() => void feishu.close());
  const { data, app, id } = station({
    updateChannel: "stable",
    connects: [
      { id: "c1", kind: "slack", enabled: true, bind: { runtime: "claude" }, slack: { appToken: "xapp-1", botToken: "xoxb-1" } },
      { id: "f1", kind: "feishu", enabled: true, bind: { runtime: "claude" }, feishu: { appId: "cli_test", appSecret: "sec-1", domain: "feishu" } },
      { id: "c-off", kind: "slack", enabled: false, bind: { runtime: "claude" }, slack: { appToken: "xapp-off", botToken: "xoxb-off" } },
    ],
  });
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify(cloudOf(id, feed.origin)));
  const a = await launch(data, app, { STILLFAIL_SLACK_API: slack.base, STILLFAIL_FEISHU_API: feishu.base, STILLFAIL_RELEASE_KEYS: RAW, STILLFAIL_LOCAL_ADMIN: "1" });
  await a.next("ready", (m) => m.ready === true);
  const mcp = await a.next("the agents' door", (m) => m.serving === "mcp");
  const stream = watchOverviews(mcp.port, "/admin-api/events");
  assert.equal(await stream.opened, 200);
  // the Slack connect: who the bot is asked, its socket opened (once the sessions are taken up: the door open)
  await until("the Slack socket open", () => slack.sockets.length >= 1, 20_000, () => `asked ${JSON.stringify(slack.asked.map((x) => x.m))}; stderr ${a.err()}`);
  assert.ok(slack.asked.some((x) => x.m === "auth.test" && x.auth === "Bearer xoxb-1"), "who the bot is, asked with its token");
  assert.ok(slack.asked.some((x) => x.m === "apps.connections.open" && x.auth === "Bearer xapp-1"), "its socket's address, asked with the app's token");
  // the Feishu connect: its app's token, its long connection opened on the shell's socket, its frames binary both ways
  // (an event Feishu sends down it taken, its acknowledgement sent back up)
  await until("the Feishu socket open", () => feishu.sockets.length >= 1, 20_000, () => `seen ${JSON.stringify(feishu.seen.map((x) => x.path))}; stderr ${a.err()}`);
  assert.ok(feishu.calls("POST", "/open-apis/auth/v3/tenant_access_token/internal").some((x) => x.body?.app_id === "cli_test" && x.body?.app_secret === "sec-1"));
  assert.equal(feishu.calls("POST", "/callback/ws/endpoint").length >= 1, true);
  const frame = feishu.message({ id: "om_1", text: "hi", at: true });
  await until("the Feishu event acknowledged", () => feishu.acks.length >= 1, 20_000, () => a.err());
  assert.ok(feishu.ack(frame) !== undefined, "the acknowledgement names the frame it took");
  // the overview reports each enabled connect's live connection state (connected, not disabled) and keeps disabled ones disabled
  const stateOf = (cs: any[], cid: string) => cs.find((x: any) => x.id === cid)?.connection?.state;
  await until(
    "overview reports c1 and f1 connected",
    () => {
      const cs = stream.latest()?.connects ?? [];
      return stateOf(cs, "c1") === "connected" && stateOf(cs, "f1") === "connected";
    },
    20_000,
    () => `${JSON.stringify(stream.latest()?.connects)}; stderr ${a.err()}`,
  );
  const ov = await getJson(mcp.port, "/admin-api/overview");
  assert.equal(stateOf(ov.connects, "c1"), "connected", JSON.stringify(ov.connects));
  assert.equal(stateOf(ov.connects, "f1"), "connected", JSON.stringify(ov.connects));
  assert.equal(stateOf(ov.connects, "c-off"), "disabled", JSON.stringify(ov.connects));
  stream.close();
  // the station's latest release, read from the stable channel's feed, verified by the test's key
  await until("the stable feed read", () => feed.asked.includes("/releases/station.json"), 20_000, () => a.err());
  assert.equal(feed.asked.includes("/releases/station-beta.json"), false);
  // slack_api through the agents' door, as the session the bearer names (its connect's bot)
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);
  store.insertSession({ key: "s1", connect: "c1", runtime: "claude", profile: "cc", workspace: data, token: "t1", createdAt: Date.now(), lastActiveAt: Date.now() });
  store.insertSession({ key: "s2", connect: "f1", runtime: "claude", profile: "cc", workspace: data, token: "t2", createdAt: Date.now(), lastActiveAt: Date.now() });
  store.close();
  // the agents' tools on a stable station: the parts', station_move among them since moving graduated (station_retire is
  // hidden from tools/list)
  assert.deepEqual(await toolNames(mcp.port, "t1"), ["feishu_api", "slack_api", "station_move", "station_version"]);
  // station_version: the release as the agents see it; an action it does not know refused as the TypeScript's
  const version = await post(mcp.port, "/mcp", { jsonrpc: "2.0", id: 6, method: "tools/call", params: { name: "station_version", arguments: { action: "list" } } }, "t1");
  assert.equal(version.result.isError, undefined, JSON.stringify(version));
  assert.deepEqual(Object.keys(JSON.parse(version.result.content[0].text)).slice(0, 8), ["version", "latest", "newer", "channel", "auto", "autoAfter", "earlier", "state"]);
  const unknown = await post(mcp.port, "/mcp", { jsonrpc: "2.0", id: 7, method: "tools/call", params: { name: "station_version", arguments: { action: "other" } } }, "t1");
  assert.equal(unknown.result.isError, true);
  assert.equal(unknown.result.content[0].text, "action: list, update, back or wait");
  const called = await post(mcp.port, "/mcp", { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "slack_api", arguments: { method: "conversations.info", params: { channel: "C9" } } } }, "t1");
  assert.equal(called.result.isError, undefined, JSON.stringify(called));
  assert.deepEqual(JSON.parse(called.result.content[0].text), { ok: true, channel: { id: "C9", name: "name-C9" } });
  const info = slack.asked.find((x) => x.m === "conversations.info");
  assert.deepEqual([info?.auth, info?.form.channel], ["Bearer xoxb-1", "C9"]);
  const refused = await post(mcp.port, "/mcp", { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "slack_api", arguments: { method: "apps.manifest.export" } } }, "t1");
  assert.equal(refused.result.isError, true);
  assert.match(refused.result.content[0].text, /not for agents/);
  // feishu_api the same, as the Feishu connect's app
  const read = await post(mcp.port, "/mcp", { jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "feishu_api", arguments: { method: "GET /open-apis/im/v1/chats/oc_g", params: {} } } }, "t2");
  assert.equal(read.result.isError, undefined, JSON.stringify(read));
  assert.deepEqual(JSON.parse(read.result.content[0].text), { code: 0, data: { name: "项目群", chat_mode: "group", group_message_type: "chat" } });
  assert.equal(feishu.calls("GET", "/open-apis/im/v1/chats/oc_g").at(-1)?.auth, "t-cli_test");
  const sending = await post(mcp.port, "/mcp", { jsonrpc: "2.0", id: 5, method: "tools/call", params: { name: "feishu_api", arguments: { method: "POST /open-apis/im/v1/messages", params: {} } } }, "t2");
  assert.equal(sending.result.isError, true);
  assert.match(sending.result.content[0].text, /chat_post/);
  // chat_post to a Feishu chat with no conversation yet (FB-43): its first message there, its file uploaded before it and
  // posted after it, its card's buttons changed to answer in the thread it began; the thread one of s2's conversations
  const report = join(data, "report.pdf");
  writeFileSync(report, "pdf");
  const begun = await post(mcp.port, "/mcp", { jsonrpc: "2.0", id: 8, method: "tools/call", params: { name: "chat_post", arguments: { to: "oc_new/", text: "选哪个", files: [report], card: { type: "options", options: [{ label: "A" }, { label: "B" }] } } } }, "t2");
  assert.equal(begun.result.isError, undefined, JSON.stringify(begun));
  const begunTs = /^Posted to oc_new\/(om_bot\d+) \(now one of your conversations\)\./.exec(begun.result.content[0].text)?.[1];
  assert.ok(begunTs, begun.result.content[0].text);
  assert.deepEqual(feishu.calls("POST", /^\/open-apis\/im\/v1\/(files|messages)$/).filter((c) => c.path.endsWith("/files") || c.body?.receive_id === "oc_new").map((c) => [c.path, c.body.msg_type ?? c.body.file_type]), [
    ["/open-apis/im/v1/files", "pdf"],
    ["/open-apis/im/v1/messages", "interactive"],
    ["/open-apis/im/v1/messages", "file"],
  ]);
  assert.equal(JSON.parse(feishu.calls("PATCH", `/open-apis/im/v1/messages/${begunTs}`)[0]!.body.content).body.elements.find((e: any) => e.tag === "button").behaviors[0].value.t, begunTs);
  const kept = Store.open(join(data, "stillfail.db"), join(data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);
  assert.equal(kept.sessionThread("s2", "oc_new", begunTs!)?.connect, "f1");
  kept.close();
  const noAbout = await post(mcp.port, "/mcp", { jsonrpc: "2.0", id: 9, method: "tools/call", params: { name: "chat_post", arguments: { to: "oc_x", text: "hi", kind: "all_done", done: "已在新建群发出首条消息，群里已有人回复", about: "om_1" } } }, "t2");
  assert.equal(noAbout.result.isError, true);
  assert.equal(noAbout.result.content[0].text, "about must be the ts of a message in an existing conversation (leave about out when starting a new Feishu chat)");
  // `stillfail update --beta` asks the running station (run/channel-ask, a SIGHUP the launcher passes on as `hup`)
  writeFileSync(join(data, "run", "channel-ask"), "beta\n");
  a.tell({ op: "hup" });
  await until("the channel answered", () => existsSync(join(data, "run", "channel-answer")), 20_000, () => a.err());
  assert.equal(readFileSync(join(data, "run", "channel-answer"), "utf8"), "ok beta\n");
  assert.equal(JSON.parse(readFileSync(join(data, "config.json"), "utf8")).updateChannel, "beta");
  await until("the beta feed read", () => feed.asked.includes("/releases/station-beta.json"), 20_000, () => a.err());
  // on the test channel: station_move an agent's tool as on stable
  assert.deepEqual(await toolNames(mcp.port, "t1"), ["feishu_api", "slack_api", "station_move", "station_version"]);
  // back to stable: the same
  writeFileSync(join(data, "run", "channel-ask"), "stable\n");
  rmSync(join(data, "run", "channel-answer"));
  a.tell({ op: "hup" });
  await until("the channel answered again", () => existsSync(join(data, "run", "channel-answer")), 20_000, () => a.err());
  assert.deepEqual(await toolNames(mcp.port, "t1"), ["feishu_api", "slack_api", "station_move", "station_version"]);
  // the copies' export: a process of its own (`--builder replica-export`), not in the station's, started as background
  // work: on macOS under `taskpolicy -b` (which execs it), its priority the background band's, under the station's
  if (process.platform !== "win32") {
    const rows = spawnSync("ps", ["-A", "-o", "pid=,ppid=,pri=,command="], { encoding: "utf8" }).stdout.split("\n").map((l) => l.trim().split(/\s+/));
    const own = rows.find((r) => r[0] === String(a.child.pid));
    const exported = rows.find((r) => r[1] === String(a.child.pid) && r.slice(3).join(" ").includes("--builder replica-export"));
    assert.ok(own !== undefined && exported !== undefined, `the export's process: ${JSON.stringify(rows.filter((r) => r[1] === String(a.child.pid)))}`);
    if (process.platform === "darwin") assert.ok(Number(exported![2]) < Number(own![2]), `backgrounded: ${exported![2]} under ${own![2]}`);
  }
  // a stop: its socket closed, nothing left
  a.tell({ op: "stop" });
  assert.equal(await a.ended, 0);
  assert.throws(() => process.kill(a.child.pid!, 0), "no process left");
  assert.equal(existsSync(join(data, "run", "hub.json")), false);
});

// ── the same parts in the harness, asked as the admin API would ──

function harness() {
  const child = spawn(harnessProgram!, ["--builder", "harness-station-main", "--shell-dir", fresh("shell")], { stdio: ["pipe", "pipe", "pipe"], env: noNode({ STILLFAIL_RELEASE_KEYS: RAW }) });
  children.push(child);
  let seq = 0;
  const waiting = new Map<number, (v: any) => void>();
  let stderr = "";
  child.stderr!.on("data", (d) => (stderr += d));
  createInterface({ input: child.stdout! }).on("line", (line) => {
    const m = JSON.parse(line);
    waiting.get(m.id)?.(m);
    waiting.delete(m.id);
  });
  child.on("exit", (code) => {
    for (const w of waiting.values()) w({ error: `the harness ended (${code}): ${stderr}` });
  });
  const send = (a: Record<string, unknown>) =>
    new Promise<any>((resolve) => {
      seq += 1;
      waiting.set(seq, resolve);
      child.stdin!.write(`${JSON.stringify({ id: seq, op: "p5_5", ...a })}\n`);
    });
  const ok = async (a: Record<string, unknown>) => {
    const said = await send(a);
    assert.equal(said.error, undefined, `${JSON.stringify(a)}: ${said.error} ${stderr}`);
    return said.ok;
  };
  return { child, send, ok, stderr: () => stderr };
}

test("the release's installer started as an update asks it, the copy an update before left in run/ replaced", { skip: skip || (process.platform !== "darwin" && process.platform !== "linux" ? "the installer's shell is Unix's" : false) }, async () => {
  const { data, app, id } = station({ updateChannel: "stable" });
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify(cloudOf(id, "http://127.0.0.1:9")));
  const h = harness();
  await h.ok({ step: "start", data, app });
  const run = join(data, "run");
  // (what the update before left: its copy of the installer, its exit)
  writeFileSync(join(run, "install.sh"), "echo the old installer > \"$(dirname \"$0\")/ran.txt\"\n");
  const script = join(fresh("release"), "install.sh");
  writeFileSync(script, "echo the new installer > \"$(dirname \"$0\")/ran.txt\"\n");
  assert.equal(await h.ok({ step: "platform", name: "platform.startInstaller", args: [script, run, { PATH: "/usr/bin:/bin" }, app] }), true);
  assert.equal(readFileSync(join(run, "install.sh"), "utf8"), readFileSync(script, "utf8"), "the copy is the release's installer");
  // (it runs in the background, nobody's child: its exit written beside it)
  const until = Date.now() + 20_000;
  const exitFile = join(run, "update.exit");
  while ((!existsSync(exitFile) || readFileSync(exitFile, "utf8").trim() === "") && Date.now() < until) await new Promise((r) => setTimeout(r, 50));
  assert.equal(readFileSync(exitFile, "utf8").trim(), "0");
  assert.equal(readFileSync(join(run, "ran.txt"), "utf8"), "the new installer\n");
  await h.ok({ step: "stop" });
  h.child.stdin!.end();
  assert.equal(await new Promise((r) => h.child.on("exit", r)), 0);
});

test("the parts as the admin API asks them: the overview's features, updates, move and copies; the routes of the updates, the moves and the copies; what the admin API's own routes ask of Slack, Feishu, Comma and the updates; the mesh's methods answered", { skip }, async () => {
  const feed = await feedStandIn();
  const { data, app, id } = station({ updateChannel: "stable" });
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify(cloudOf(id, feed.origin)));
  const h = harness();
  assert.deepEqual(await h.ok({ step: "start", data, app }), { station: id });
  const owner = { role: "owner", workspace: "w1", email: "o@x.y" };
  const member = { role: "member", workspace: "w1", email: "m@x.y" };
  // the overview on a stable station
  const first = await h.ok({ step: "overview", viewer: owner, lang: "en" });
  // (moving graduated: offered on stable too, and said in `features` for apps from before)
  assert.deepEqual(first.features, ["stationMove"]);
  assert.deepEqual(first.move, { offered: true });
  assert.equal(first.updates[0].id, "station");
  assert.equal(typeof first.copies, "object");
  assert.deepEqual([first.slackTeams, first.slackApps], [[], []]);
  assert.deepEqual(await h.ok({ step: "coord", name: "connects.states", arg: [] }), []);
  assert.deepEqual((await h.ok({ step: "tools" })).sort(), ["feishu_api", "slack_api", "station_move", "station_retire", "station_version"]);
  assert.deepEqual([first.comma, first.group, first.feishuRegistrations], [true, true, []]);
  // what the admin API's own routes (api_routes) ask of the connect kinds and Slack's, Feishu's and Comma's parts
  for (const kind of ["slack", "feishu", "comma", "group"]) assert.deepEqual(await h.ok({ step: "coord", name: "connectKinds.get", arg: [kind] }), { $ref: kind });
  assert.equal(await h.ok({ step: "coord", name: "connectKinds.get", arg: ["fax"] }), null);
  const entry = await h.ok({ step: "coord", name: "feishu.entry", arg: [{ appId: "cli_x", appSecret: "s", domain: "lark" }, null] });
  assert.deepEqual([entry.appId, entry.appSecret, entry.domain], ["cli_x", "s", "lark"]);
  assert.ok((await h.ok({ step: "coord", name: "slack/index.createAppUrl", arg: ["Agent"] })).startsWith("https://api.slack.com/apps?new_app=1&manifest_json="));
  const manifest = await h.ok({ step: "coord", name: "slack/index.slackManifest", arg: ["Agent", null, null] });
  assert.equal(manifest.display_information.name, "Agent");
  assert.equal((await h.ok({ step: "coord", name: "slack/index.withSocketMode", arg: [manifest, true] })).settings.socket_mode_enabled, true);
  assert.deepEqual(await h.ok({ step: "coord", name: "slack/index.configTokens", arg: [{ slackConfigTokens: [] }] }), []);
  assert.deepEqual(await h.ok({ step: "coord", name: "slack.connects", arg: [] }), []);
  assert.equal(await h.ok({ step: "coord", name: "slack.apps.configured", arg: ["o@x.y"] }), false);
  const slackError = await h.send({ step: "coord", name: "slack/index.nothing", arg: [] });
  assert.match(slackError.error, /no such Slack function/);
  assert.deepEqual(await h.ok({ step: "coord", name: "comma/index.commaLine", arg: ["comma wss://comma.example/ws tok-12345678"] }), { server: "https://comma.example", token: "tok-12345678" });
  assert.equal(await h.ok({ step: "coord", name: "comma/index.commaLine", arg: ["not a line"] }), null);
  assert.equal(await h.ok({ step: "coord", name: "feishu/web.domainOf", arg: ["lark"] }), "lark");
  assert.equal(await h.ok({ step: "coord", name: "feishu.registrations.cancel", arg: ["r-none", "o@x.y", "w1"] }), false);
  // the updates' routes: read again (the stable feed), refused to a member, the channel set
  const checked = await h.ok({ step: "route", method: "POST", path: "/updates/check", body: null, viewer: owner, lang: "en" });
  assert.equal(checked.status, 200);
  assert.ok(feed.asked.includes("/releases/station.json"));
  const read = checked.body.find((x: any) => x.id === "station");
  assert.deepEqual([read.version, read.latest, read.channel], ["0.1.9400", "0.1.9500", "stable"]);
  assert.equal((await h.ok({ step: "route", method: "POST", path: "/updates/check", body: null, viewer: member, lang: "en" })).status, 403);
  assert.equal((await h.ok({ step: "route", method: "POST", path: "/updates/channel", body: { channel: "nightly" }, viewer: owner, lang: "en" })).status, 400);
  const beta = await h.ok({ step: "route", method: "POST", path: "/updates/channel", body: { channel: "beta" }, viewer: owner, lang: "en" });
  assert.equal(beta.status, 200);
  assert.ok(feed.asked.includes("/releases/station-beta.json"), "read again from the channel it is on now");
  assert.deepEqual([beta.body.find((x: any) => x.id === "station").latest, beta.body.find((x: any) => x.id === "station").channel], ["0.1.9600", "beta"]);
  assert.equal(JSON.parse(readFileSync(join(data, "config.json"), "utf8")).updateChannel, "beta");
  assert.equal(await h.ok({ step: "coord", name: "agents.updates.channel", arg: [] }), "beta");
  // on the test channel: the features, moving offered, station_move an agent's
  const second = await h.ok({ step: "overview", viewer: owner, lang: "en" });
  assert.deepEqual(second.features, ["terminal", "stationMove"]);
  assert.deepEqual(second.move, { offered: true });
  assert.deepEqual((await h.ok({ step: "tools" })).sort(), ["feishu_api", "slack_api", "station_move", "station_retire", "station_version"]);
  // station_move all (tools/move.ts `MoveAsks`): a card in the asking chat, kept in move/asks.json; nothing moves until
  // an owner or admin of its workspace confirms it in the app, a member refused (the other station and the hub's
  // cards and notices the test's)
  const other = "b".repeat(64);
  const sessions = Store.open(join(data, "stillfail.db"), join(data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);
  sessions.insertSession({ key: "s1", connect: "ember", ws: "w1", runtime: "claude", profile: "cc", workspace: data, token: "t1", createdAt: Date.now(), lastActiveAt: Date.now() });
  sessions.close();
  await h.ok({ step: "standIn", hub: { "cards.post": { thread: 7, ts: "1.5" }, "hub.notify": null }, peers: { "move.open": { on: true } } });
  const all = await h.ok({ step: "call", name: "station_move", args: { action: "move", to: other, all: true }, context: { session: "s1" } });
  assert.equal(all.isError, undefined, JSON.stringify(all));
  const asked = JSON.parse(all.content[0].text);
  assert.equal(asked.card, "posted");
  assert.match(asked.ask, /^m_[0-9a-f]{12}$/);
  const posted = (await h.ok({ step: "asked" })).filter((x: any) => x.hub === "cards.post");
  assert.equal(posted.length, 1);
  const [cardSession, , card] = posted[0].args;
  assert.equal(cardSession, "s1");
  assert.deepEqual(card.move, { ask: asked.ask, to: other, toName: "other" });
  const asksFile = join(data, "move", "asks.json");
  const kept = () => JSON.parse(readFileSync(asksFile, "utf8"));
  assert.deepEqual(kept(), [{ id: asked.ask, session: "s1", ws: "w1", to: other, toName: "other", state: "asked", thread: 7, ts: "1.5", by: null }]);
  const at = { thread: 7, ts: "1.5" };
  assert.match(await h.ok({ step: "card", key: "move", call: "may", viewer: member, card, at }), /所有者或管理员|owner or admin/);
  assert.match(await h.ok({ step: "card", key: "move", call: "may", viewer: owner, card, at: { thread: 7, ts: "2.5" } }), /失效|no longer asks/);
  assert.equal(await h.ok({ step: "card", key: "move", call: "may", viewer: owner, card, at }), null);
  await h.ok({ step: "card", key: "move", call: "chosen", viewer: owner, card, option: card.options[0].label, at });
  // (what the choice set going comes to: the chat told what came of it)
  await Promise.race([h.ok({ step: "heard", hub: "hub.notify" }), new Promise((_, no) => setTimeout(() => no(new Error(`the chat was never told: ${h.stderr()}`)), 20_000).unref())]);
  assert.deepEqual([kept()[0].state, kept()[0].by], ["confirmed", "o@x.y"]);
  const notices = (await h.ok({ step: "asked" })).filter((x: any) => x.hub === "hub.notify");
  assert.equal(notices.length, 1, JSON.stringify(notices));
  assert.equal(notices[0].args[0], "s1");
  assert.match(notices[0].args[1], /^o@x\.y confirmed moving everything to other/);
  // station_move asked by another station of the workspace (`move.tool`): as a told step where it asks so, answered at
  // once; else answered with what it comes to; a station not of the workspace refused
  assert.deepEqual(await h.ok({ step: "peer", from: other, workspace: "w1", method: "move.tool", params: { args: { action: "stop" }, told: "tool:stop:1" } }), { under: true, told: "tool:stop:1" });
  assert.match((await h.send({ step: "peer", from: other, workspace: "w1", method: "move.tool", params: { args: { action: "go" } } })).error, /action is one of plan, move, back, status, stop/);
  assert.match((await h.send({ step: "peer", from: "c".repeat(64), workspace: "w1", method: "move.tool", params: { args: { action: "stop" } } })).error, /not a station of this workspace/);
  // the moves' routes: the page of a move to the other station, a move refused to a member, one to a station not of it
  const page = await h.ok({ step: "route", method: "GET", path: "/move", query: { to: "b".repeat(64) }, body: null, viewer: owner, lang: "en" });
  assert.equal(page.status, 200, JSON.stringify(page));
  assert.ok(Array.isArray(page.body.modules), JSON.stringify(page.body));
  assert.equal((await h.ok({ step: "route", method: "POST", path: "/move", body: { to: "b".repeat(64), module: "chats", item: "s1" }, viewer: member, lang: "en" })).status, 403);
  assert.equal(await h.ok({ step: "coord", name: "move.here", arg: [] }), id);
  // a folder a move made let go as it goes back (repos.ts `remove`): all it holds, the shell's `fs.remove`; nothing
  // there no failure
  const made = join(data, "repos", "made-by-move");
  mkdirSync(join(made, "a", "b"), { recursive: true });
  writeFileSync(join(made, "a", "b", "f"), "x");
  assert.equal(await h.ok({ step: "coord", name: "move.remove", arg: [made] }), null);
  assert.equal(existsSync(made), false);
  assert.equal(await h.ok({ step: "coord", name: "move.remove", arg: [made] }), null);
  // the copies' routes: a retirement's start refused (switched off), a restore asked without what it needs
  const retire = await h.ok({ step: "route", method: "POST", path: "/retire", body: { to: "b".repeat(64) }, viewer: owner, lang: "en" });
  assert.equal(retire.status, 409);
  assert.equal((await h.ok({ step: "route", method: "POST", path: "/copies/restore", body: {}, viewer: owner, lang: "en" })).status, 400);
  assert.equal((await h.ok({ step: "route", method: "GET", path: "/retire/preview", body: null, viewer: member, lang: "en" })).status, 403);
  // the mesh's methods: the copies', a retirement's, a hand-over's and a move's, each answered by its part
  const peers = await h.ok({ step: "peers" });
  for (const p of ["retire.", "replica.", "handover.", "move."]) assert.ok(peers.prefixes.includes(p), JSON.stringify(peers.prefixes));
  // (a station not of the workspace is refused by the part itself, not as a method nobody answers)
  const stranger = await h.send({ step: "peer", from: "c".repeat(64), workspace: "w1", method: "replica.list", params: {} });
  assert.ok(stranger.error !== undefined && !/unknown peer method/.test(stranger.error), JSON.stringify(stranger));
  assert.ok(peers.prefixes.includes("comma."), "another station's reads of the Comma statistics answered");
  // back to stable as the admin API's own route asks it (`updates.setChannel` on coord_ask): the features off
  assert.equal(await h.ok({ step: "coord", name: "updates/versions.channelOfId", arg: ["stable"] }), "stable");
  assert.equal(await h.ok({ step: "coord", name: "updates.setChannel", arg: ["stable", "en"] }), null);
  assert.equal(await h.ok({ step: "coord", name: "agents.updates.channel", arg: [] }), "stable");
  assert.equal(JSON.parse(readFileSync(join(data, "config.json"), "utf8")).updateChannel, "stable");
  assert.deepEqual((await h.ok({ step: "overview", viewer: owner, lang: "en" })).features, ["stationMove"]);
  assert.deepEqual((await h.ok({ step: "tools" })).sort(), ["feishu_api", "slack_api", "station_move", "station_retire", "station_version"]);
  // the copies' and a retirement's on coord_ask: a refusal thrown as the routes take it, its words kept
  const retireCoord = await h.send({ step: "coord", name: "retire.retire", arg: ["w1", "b".repeat(64), "o@x.y"] });
  assert.ok(retireCoord.error !== undefined, JSON.stringify(retireCoord));
  // connects.overview and connects.states look up each connect by id rather than passing a bare {id} object
  await h.ok({
    step: "config",
    config: {
      updateChannel: "stable",
      connects: [
        { id: "s-on", kind: "slack", enabled: true, bind: { runtime: "claude" }, slack: {} },
        { id: "s-off", kind: "slack", enabled: false, bind: { runtime: "claude" }, slack: {} },
      ],
    },
  });
  const ovConnects = (await h.ok({ step: "coord", name: "connects.overview", arg: [] })).connects;
  assert.equal(ovConnects.find((x: any) => x.id === "s-on")?.connection?.state, "no_tokens", JSON.stringify(ovConnects));
  assert.equal(ovConnects.find((x: any) => x.id === "s-off")?.connection?.state, "disabled", JSON.stringify(ovConnects));
  const stConnects = await h.ok({ step: "coord", name: "connects.states", arg: [] });
  assert.equal(stConnects.find((x: any) => x.id === "s-on")?.connection?.state, "no_tokens", JSON.stringify(stConnects));
  assert.equal(stConnects.find((x: any) => x.id === "s-off")?.connection?.state, "disabled", JSON.stringify(stConnects));
  await h.ok({ step: "stop" });
  h.child.stdin!.end();
  assert.equal(await new Promise((r) => h.child.on("exit", r)), 0);
});

test("a move's plan reads each page of chats in one statement (store.ts sessionPageOfWs as move/live.ts gives it): a home chat's sessions together, the accounts they ran on, those handed over and those of no workspace, the hub's wsOf given each row", { skip }, async () => {
  const feed = await feedStandIn();
  const { data, app, id } = station({ updateChannel: "beta" });
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify(cloudOf(id, feed.origin)));
  const h = harness();
  assert.deepEqual(await h.ok({ step: "start", data, app }), { station: id });
  const owner = { role: "owner", workspace: "w1", email: "o@x.y" };
  const other = "b".repeat(64);
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);
  const now = Date.now();
  const add = (key: string, ws: string | null, profile = "cc") =>
    store.insertSession({ key, connect: "ember", ...(ws === null ? {} : { ws }), runtime: "claude", profile, workspace: join(data, "sessions", key), token: `t-${key}`, createdAt: now, lastActiveAt: now } as never);
  // a1 and a2 share a1's still.fail home chat; r1 ran on an account it runs on no more; n1 is of no workspace (the
  // home one's, from before workspaces); h1 was handed to the other station; x1 is another workspace's
  for (const k of ["a1", "a2", "r1", "h1"]) add(k, "w1");
  add("n1", null);
  add("x1", "w2");
  const home = store.openThread("chat", "CHAT", "1790000000.000001", "a1", "o@x.y");
  store.joinThread(home.id, "a1", "ember");
  store.joinThread(home.id, "a2", "ember");
  (store as any).db.prepare("UPDATE threads SET home = ? WHERE id = ?").run("a1", home.id);
  store.ranIn("r1", "rt-old", "gone-profile");
  store.ranIn("r1", "rt-now", "cc");
  store.handOff(["h1"], other, "w1", {});
  store.close();
  await h.ok({ step: "standIn", hub: { "hub.wsOf": "w1" }, peers: { "move.open": { on: true }, "move.chats.live": { live: [], name: "other" }, "move.accounts": {} } });
  const page = await h.ok({ step: "route", method: "GET", path: "/move", query: { to: other }, body: null, viewer: owner, lang: "en" });
  assert.equal(page.status, 200, JSON.stringify(page));
  const chats = page.body.modules.find((m: any) => m.id === "chats");
  const item = (k: string) => chats.items.find((x: any) => x.id === k);
  // a2 goes with a1 (their home chat's), x1 is another workspace's; n1 is the home one's
  assert.deepEqual(chats.items.map((x: any) => x.id), ["a1", "h1", "n1", "r1"]);
  for (const k of ["a1", "n1", "r1"]) assert.equal(item(k).cannot, undefined, JSON.stringify(item(k)));
  assert.deepEqual(item("a1").needs, ["accounts machine:cc"]);
  assert.match(item("r1").leaves, /gone-profile/);
  // handed over: in the page, and not to be moved again from here
  assert.ok(item("h1").cannot !== undefined, JSON.stringify(item("h1")));
  // each chat's row, home chat and accounts read from the page, not asked of the store one by one (11-12 statements a
  // chat: 79.7 s for 3,643 chats on the station's thread)
  const asked = await h.ok({ step: "asked" });
  const oneByOne = asked.filter((x: any) => ["store.getSession", "store.homeChat", "store.threadSessions", "store.chatPage"].includes(x.hub));
  assert.deepEqual(oneByOne, []);
  // the hub's wsOf given each session's row, as handover.ts `check` gives it
  const wsOf = asked.filter((x: any) => x.hub === "hub.wsOf");
  assert.ok(wsOf.length > 0);
  for (const x of wsOf) assert.equal(typeof x.args[0]?.key, "string", JSON.stringify(x));
  await h.ok({ step: "stop" });
  h.child.stdin!.end();
  assert.equal(await new Promise((r) => h.child.on("exit", r)), 0);
});

test("Feishu's and Comma's sockets kept up as comma/surface.ts and feishu/surface.ts keep them (pinged every 15 s, dead after 45 s quiet); a platform's socket on the shell sends its ping frame and says it is open only from its open until it closed or was cut off; Comma's part given where the session pages are as sessions/agents.ts `pages` says", { skip }, async () => {
  const h = harness();
  assert.deepEqual(await h.ok({ step: "keepalive" }), { feishu: { pingMs: 15_000, staleMs: 45_000 }, comma: { pingMs: 15_000, staleMs: 45_000 } });
  // the socket's ping is a WebSocket ping frame the server hears (and answers with its pong); the server then closes it
  const server = createServer();
  const wss = new WebSocketServer({ server });
  const pinged: number[] = [];
  wss.on("connection", (ws) => {
    ws.on("ping", () => {
      pinged.push(1);
      setImmediate(() => ws.close());
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  closers.push(() => server.close());
  const url = `ws://127.0.0.1:${(server.address() as AddressInfo).port}/`;
  const probe = await h.ok({ step: "socket", url });
  assert.equal(pinged.length, 1, JSON.stringify(probe));
  assert.deepEqual([probe.before, probe.opened, probe.after], [false, true, false], JSON.stringify(probe));
  assert.equal(probe.said.at(-1), "closed", JSON.stringify(probe));
  assert.ok(probe.said.includes("pong"), JSON.stringify(probe));
  assert.deepEqual([probe.cutOpened, probe.cut], [true, false]);
  // where the session pages are: still.fail cloud's alone, in a workspace not left, its test channel's origin on beta
  const state = { provider: "stillfail", origin: "https://app.still.fail", workspace: "w1", station: "s1" };
  assert.deepEqual(await h.ok({ step: "pageBase", state, channel: "stable" }), { origin: "https://app.still.fail", workspace: "w1", station: "s1" });
  assert.deepEqual(await h.ok({ step: "pageBase", state, channel: "beta" }), { origin: "https://app.youdid.wtf", workspace: "w1", station: "s1" });
  assert.deepEqual(await h.ok({ step: "pageBase", state: { ...state, origin: "https://app.monoid.build" }, channel: "beta" }), { origin: "https://app.monoid.zone", workspace: "w1", station: "s1" });
  assert.equal(await h.ok({ step: "pageBase", state: { ...state, provider: "comma" }, channel: "stable" }), null);
  assert.equal(await h.ok({ step: "pageBase", state: { ...state, workspace: "" }, channel: "stable" }), null);
  assert.equal(await h.ok({ step: "pageBase", state: { ...state, removed_at: 1 }, channel: "stable" }), null);
  assert.equal(await h.ok({ step: "pageBase", state: null, channel: "stable" }), null);
  h.child.stdin!.end();
  assert.equal(await new Promise((r) => h.child.on("exit", r)), 0);
});

test("the parts that download follow a 302 as Node's fetch does (Slack's url_private telling it was sent elsewhere, Feishu's, the updates', Farview's release, the accounts' unless `manual`), on the shell against a server of the test's", { skip }, async () => {
  const hits: string[] = [];
  const server = createServer((req, res) => {
    hits.push(req.url ?? "");
    if (req.url === "/moved") {
      res.writeHead(302, { location: "/final" });
      res.end();
    } else if (req.url === "/final") {
      res.writeHead(200, { "content-type": "application/octet-stream" });
      res.end("final");
    } else {
      res.writeHead(404);
      res.end("none");
    }
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  closers.push(() => server.close());
  const at = (path: string) => `http://127.0.0.1:${(server.address() as AddressInfo).port}${path}`;
  const h = harness();
  const via = (part: string, path: string, manual = false) => h.ok({ step: "fetchVia", via: part, url: path.startsWith("gh:") ? path : at(path), manual });
  assert.deepEqual(await via("slack", "/moved"), { status: 200, redirected: true, body: "final" });
  assert.deepEqual(await via("slack", "/final"), { status: 200, redirected: false, body: "final" });
  assert.deepEqual(await via("feishu", "/moved"), { status: 200, body: "final" });
  assert.deepEqual(await via("updates", "/moved"), { status: 200, body: "final" });
  assert.deepEqual(await via("farview", "/moved"), { body: "final" });
  assert.equal(await via("farview", "/gone"), null);
  // (a gh: source with no gh on the PATH: none from there, as fetchBytes says it)
  assert.equal(await via("farview", "gh:AFK-surf/farview-legacy@builds/none.tgz"), null);
  assert.deepEqual(await via("oauth", "/moved"), { status: 200, body: "final" });
  hits.length = 0;
  assert.deepEqual(await via("oauth", "/moved", true), { status: 302, body: "" });
  assert.deepEqual(hits, ["/moved"]);
  h.child.stdin!.end();
  assert.equal(await new Promise((r) => h.child.on("exit", r)), 0);
});
