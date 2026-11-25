// The test station's claude for the app's flows: still.fail's fake claude (station/test/fake/claude.mjs, the next one on
// PATH) for everything it knows, and beside it what the decisions and the execution history need, which it does not
// do. A message the station hands it with one of these in it is answered here (the rest go to still.fail's fake as they
// come):
//   card:<question>|<label>|<label>*|<label>!   chat_post with an options card ending the turn need_human: the
//                                               question, then the options (`*` recommended, `!` action close)
//   text-card:<question>|<placeholder>          the same with a text card
//   md:<words>                                  chat_post all done: <words>, then a table, a TypeScript block with a long
//                                               line and a bare address (…/e2e/<the words' last word>)
//   steps:<words>                               a turn with tool calls in its transcript (a command and its output, an
//                                               edit), then chat_post <words> ending it all_done
//   serve:<name>|<port>|<words>                 job_start a web service <name> on <port> (a page of two, served by
//                                               python's http.server from the session's workspace), then chat_post
//                                               <words> all_done
//   secret:<item>|<command>                     secret_use the vault's <item> for <command> (a card for alice to approve
//                                               in the app); its decision, told in the session, answered here: granted,
//                                               secret_run <command> with the grant and chat_post what it printed all
//                                               done; refused, chat_post so
//   rig:<name>|<reason>                         station_use the rig <name> (a card for its owner in the app), then chat_post
//                                               what the station answered
//   rigtask:<name>|<command>                    station_task <command> on the rig <name> (prepare, then start), then
//                                               chat_post `rigtask <key>:` and what each answered: a task taken, or
//                                               the rig's refusal
//   devtalk:<device>|<reason>|<line>            device_use the device (or asks for it, a card for its owner); where it
//                                               is put on a port here, sends <line> there and chat_posts `devtalk:`
//                                               and what came back, else what device_use answered
// The move drill's (e2e/move.ts), each a turn ending all done with one chat_post:
//   drill-remember:<word>                       `drill-remembered <word>` (the word is in its transcript, as it was said)
//   drill-recall:<nonce>                        what it finds of its own past in its transcript (the file the real one
//                                               would resume from): `drill-recall <nonce> secret=<the last remembered word, or
//                                               none> lines=<its lines> resumed=<--resume given> session=<id> cwd=<its
//                                               working directory> pid=<its pid>`
//   drill-job:<tag>                             job_start a job that only waits (a shell's loop), `drill-job-<tag>` at its command line's end
//   drill-move:<json>                           station_move with those arguments: `drill-move: <what it answered>`
//   drill-note:<n>                              `drill-noted <n> cwd=<cwd>`
//   drill-seed:<n>                              `drill-seeded <n>`
//   drill-gate:<name>                           waits until $FAKE_DUMP.gate-<name> is there, then `drill-gated <name> pid=<pid>`
// Every message a station hands it is noted, as it comes, in $FAKE_DUMP.turns (its time, pid, session, working
// directory and first words): what the drill reads of which agent was woken, where, and by what.
// What it writes of a turn goes to its transcript as the real claude's does (<config>/projects/<dir>/<session>.jsonl),
// which is what the station reads an agent's execution history from.
import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import readline from "node:readline";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const flag = (name) => (args.includes(name) ? args[args.indexOf(name) + 1] : undefined);
const sessionId = flag("--session-id") || flag("--resume") || "none";
const say = (frame) => fs.writeSync(1, JSON.stringify(frame) + "\n");

// still.fail's fake: the first claude.mjs on PATH that is not this one
const theirs = (process.env.PATH || "")
  .split(path.delimiter)
  .map((d) => path.join(d, "claude.mjs"))
  .find((f) => path.dirname(f) !== here && fs.existsSync(f));
const child = theirs ? spawn(process.execPath, [theirs, ...args], { stdio: ["pipe", "pipe", "inherit"], env: process.env }) : null;
if (child) {
  // its frames passed on whole, a line at a time (ours are written between its lines, never inside one)
  readline.createInterface({ input: child.stdout }).on("line", (line) => fs.writeSync(1, line + "\n"));
  child.on("exit", (code) => process.exit(code ?? 0));
}

// the transcript, as the real claude keeps it
const config = process.env.CLAUDE_CONFIG_DIR || path.join(process.env.HOME || ".", ".claude");
// (in the directory the real one names by the working directory, every character but an ASCII letter or digit a dash:
// the station looks for a session's transcript there alone, station/src/read/transcript.ts claudeProject)
const transcript = path.join(config, "projects", process.cwd().replace(/[^a-zA-Z0-9]/g, "-"), `${sessionId}.jsonl`);
let entry = 0;
function record(type, content) {
  fs.mkdirSync(path.dirname(transcript), { recursive: true });
  const line = { type, uuid: `e2e-${process.pid}-${++entry}`, sessionId, timestamp: new Date().toISOString(), message: { role: type, content } };
  fs.appendFileSync(transcript, JSON.stringify(line) + "\n");
}

let n = 0;
function message(text) {
  const id = `msg_e2e_${++n}`;
  const event = (e) => say({ type: "stream_event", event: e, parent_tool_use_id: null, session_id: sessionId, uuid: `e${n}-${Math.random()}` });
  event({ type: "message_start", message: { id, role: "assistant", content: [] } });
  event({ type: "content_block_start", index: 0, content_block: { type: "text", text: "" } });
  event({ type: "content_block_delta", index: 0, delta: { type: "text_delta", text } });
  event({ type: "content_block_stop", index: 0 });
  event({ type: "message_stop" });
  say({ type: "assistant", message: { id, role: "assistant", content: [{ type: "text", text }] }, session_id: sessionId });
}

async function tool(name, args) {
  const server = JSON.parse(flag("--mcp-config")).mcpServers.stillfail;
  const call = (id, method, params) =>
    fetch(server.url, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${process.env.STILLFAIL_MCP_TOKEN}` },
      body: JSON.stringify({ jsonrpc: "2.0", id, method, params }),
    }).then((r) => r.json());
  await call(1, "initialize", { protocolVersion: "2025-06-18" });
  const answer = await call(2, "tools/call", { name, arguments: args });
  return answer.result?.content?.[0]?.text ?? JSON.stringify(answer.error ?? answer);
}

// The model asking again, having read what it was written (a steer included): the one frame that clears what the station
// counts as unread and takes back the state the step before declared (station/mb/src/reader/actor_run.mbt `requesting`),
// as still.fail's fake says it as each turn begins. A message of its own clears nothing.
const requesting = () => say({ type: "system", subtype: "status", status: "requesting", session_id: sessionId });

// A post the station holds back because a message steered into the turn came first ("Held as held-N", station/src/sessions/
// conversations.ts): as the real one does, it reads them (`requesting`, which clears what it had not read) and sends the
// held post as written by its id, with the state it ended with.
async function post(to, args) {
  let answer = await tool("chat_post", { to, ...args });
  for (let tries = 0; tries < 5; tries++) {
    const held = /Held as (held-\d+)/.exec(answer);
    if (!held) return answer;
    requesting();
    await new Promise((r) => setTimeout(r, 50));
    const state = Object.fromEntries(["kind", "done", "need", "about"].filter((k) => args[k] !== undefined).map((k) => [k, args[k]]));
    answer = await tool("chat_post", { to, send: held[1], ...state });
  }
  return answer;
}

// the service's two pages, written where it runs (every word made up)
const PAGE_A = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>端到端测试服务</title><link rel="stylesheet" href="style.css"></head><body><h1>端到端测试服务</h1>
<p id="n">脚本还没有运行</p><p><a href="b.html">去第二页</a></p>
<script>fetch('data.json').then(r=>r.json()).then(d=>{document.getElementById('n').textContent='脚本已运行：'+d.n})</script></body></html>`;
const PAGE_B = `<!doctype html><html><head><meta charset="utf-8"><title>第二页</title><link rel="stylesheet" href="style.css"></head>
<body><h1>这是第二页</h1></body></html>`;
const STYLE = "body{margin:0;padding:24px;font-family:system-ui,sans-serif;background:#fbe6dc;color:#24272b}h1{color:#b9471f}";

// One turn at a time: a message the station steers into a turn under way (a remote task's notice, the next word) waits
// in `steered` and is answered in that turn, before its one result. Two turns at once ended the station's turn with the
// first's result, and the second's chat_state and result then fell outside it.
let busy = false;
const steered = [];
async function turn(first) {
  busy = true;
  try {
    say({ type: "system", subtype: "init", session_id: sessionId, model: flag("--model") || "default", tools: [], mcp_servers: [] });
    let last = "";
    for (let cur = first; cur !== undefined; cur = steered.shift()) {
      if (!ours(cur)) continue;
      // (each message read, the first and each steered in after it, as the real one asks again having read it: a steer
      // that came during the step before is no longer unread, and that step's state is taken back)
      requesting();
      last = await handle(cur);
      message(last);
    }
    say({ type: "result", subtype: "success", is_error: false, duration_ms: 1, num_turns: 1, session_id: sessionId, result: last });
  } finally {
    busy = false;
  }
}

// One message of a turn: what it posted.
async function handle(text) {
  record("user", text);
  const to = /thread="([^"]+)"/.exec(text)?.[1] ?? "";
  const line = (key) => text.slice(text.indexOf(key) + key.length).split("\n")[0];
  let said;
  // The station's ask for a title once a turn ended and its chat has none (station/src/agents/instructions.ts
  // nameUntitled): as the real one does, its title alone, then the state it ended with again. Left to still.fail's fake,
  // it ended with no state, was nudged seven times, and its "stopped with no result" notice went into a Slack thread the
  // move drill reads (part 4s, c4s-dda7).
  const untitled = /The chat (\S+) still has no title, and nobody is at work in it now/.exec(text);
  if (untitled) {
    said = await post(untitled[1], { title: `drill ${sessionId.slice(0, 8)}` });
    await tool("chat_state", { kind: "all_done", done: "did what the drill asked" });
    return said;
  }
  if (/(^|\s)drill-[a-z]+:/.test(text)) return drill(text, to, line);
  if (text.includes("text-card:")) {
    const [question, placeholder] = line("text-card:").split("|");
    said = await post(to, { text: question, kind: "need_human", need: question, card: { type: "text", placeholder: placeholder ?? "" } });
  } else if (text.includes("card:")) {
    const [question, ...labels] = line("card:").split("|");
    const options = labels.map((l) => {
      const o = { label: l.replace(/[*!]+$/, "") };
      if (/\*/.test(l.slice(o.label.length))) o.recommended = true;
      if (/!/.test(l.slice(o.label.length))) o.action = "close";
      return o;
    });
    said = await post(to, { text: question, kind: "need_human", need: question, card: { type: "options", options } });
  } else if (/(^|\s)md:/.test(text)) {
    // Markdown as an agent writes it: a table, code with a line too long for the message, a bare address
    const words = line("md:");
    const md = [
      words, "",
      "| 页面 | 状态 | 耗时 |", "|:--|:-:|--:|", "| 首页 | 完成 | 1.2 s |", "| 聊天页的列表和输入框 | 进行中 | 3.4 s |", "",
      "```ts",
      "export function placeRows(rows: Row[], from: number): number {",
      "  const visible = rows.filter((r) => r.top >= from && r.top < from + window.innerHeight * 2) // only the rows near the screen",
      "  return visible.length",
      "}",
      "```", "",
      `详见 https://example.com/e2e/${encodeURIComponent(words.split(" ").pop() ?? "x")}`,
    ].join("\n");
    said = await post(to, { text: md, kind: "all_done", done: "answered the question that was asked" });
  } else if (/(^|\s)secret:/.test(text)) {
    const [item, command] = line("secret:").split("|");
    // (its chat and command kept for the decision, which comes as a station notice in no chat)
    fs.writeFileSync(path.join(process.cwd(), `.e2e-secret-${sessionId}`), JSON.stringify({ to, command: command ?? "true" }));
    const asked = await tool("secret_use", { item, reason: `端到端测试：用「${item}」跑一条命令`, command });
    record("assistant", [{ type: "text", text: asked }]);
    // (asked: the card is the station's, in the chat; the turn ends waiting for alice's decision)
    said = asked.startsWith("Asked for")
      ? await post(to, { text: `等你批准使用「${item}」`, kind: "need_human", need: `批准使用「${item}」` })
      : await post(to, { text: `没能申请「${item}」：${asked}`, kind: "all_done", done: "the request could not be made" });
  } else if (/Granted: 「[^」]*」, grant (r_[\w-]+)/.test(text) || /\(r_[\w-]+\) was (refused|let go)/.test(text)) {
    const grant = /Granted: 「[^」]*」, grant (r_[\w-]+)/.exec(text)?.[1];
    const kept = JSON.parse(fs.readFileSync(path.join(process.cwd(), `.e2e-secret-${sessionId}`), "utf8"));
    if (grant) {
      const command = kept.command;
      const ran = await tool("secret_run", { grant, command, env: "E2E_SECRET" });
      record("assistant", [{ type: "text", text: ran }]);
      said = await post(kept.to, { text: `用密钥跑完了：${ran}`, kind: "all_done", done: "ran the command with the granted secret" });
    } else {
      said = await post(kept.to, { text: "密钥申请被拒绝了", kind: "all_done", done: "the request was refused" });
    }
  } else if (/(^|\s)rig:/.test(text)) {
    const [rig, reason] = line("rig:").split("|");
    const asked = await tool("station_use", { station: rig, reason: reason ?? "端到端测试" });
    record("assistant", [{ type: "text", text: asked }]);
    said = /waits for its owner/.test(asked)
      ? await post(to, { text: `rig: ${asked}`, kind: "need_human", need: `批准使用 station「${rig}」` })
      : await post(to, { text: `rig: ${asked}`, kind: "all_done", done: "asked for the rig" });
  } else if (/(^|\s)devtalk:/.test(text)) {
    const [device, reason, sent] = line("devtalk:").split("|");
    const asked = await tool("device_use", { device, reason: reason ?? "端到端测试" });
    record("assistant", [{ type: "text", text: asked }]);
    const port = /127\.0\.0\.1:(\d+)/.exec(asked)?.[1];
    let heard = "";
    if (port !== undefined) {
      heard = await new Promise((done) => {
        let got = "";
        const socket = net.connect({ host: "127.0.0.1", port: Number(port) });
        const stop = setTimeout(() => (socket.destroy(), done(got === "" ? "(nothing came back)" : got)), 5000);
        socket.on("data", (c) => {
          got += c.toString();
          if (got.length >= (sent ?? "").length) (clearTimeout(stop), socket.end(), done(got));
        });
        socket.on("error", (e) => (clearTimeout(stop), done(`(cut off: ${e.message})`)));
        socket.on("close", () => (clearTimeout(stop), done(got === "" ? "(closed)" : got)));
        socket.once("connect", () => socket.write(sent ?? "ping"));
      });
    }
    said = await post(to, { text: port === undefined ? `devtalk: ${asked}` : `devtalk heard: ${heard}`, kind: /waits for its owner/.test(asked) ? "need_human" : "all_done", ...(/waits for its owner/.test(asked) ? { need: `批准使用设备「${device}」` } : { done: "used the device, or was told why not" }) });
  } else if (/(^|\s)rigtask:/.test(text)) {
    const [rig, command] = line("rigtask:").split("|");
    const key = `e2e-${Date.now().toString(36)}`;
    // (a rig whose mode was just switched hands its process over: a prepare or start its old process dropped is asked
    // again with the same key, station/src/mesh/peer.ts PeerStopped; a refusal is not)
    const askRig = async (args) => {
      let out = await tool("station_task", args);
      for (let tries = 0; tries < 5 && /stopped or handed over as it was asked/.test(out); tries++) {
        await new Promise((r) => setTimeout(r, 300));
        out = await tool("station_task", args);
      }
      return out;
    };
    const prepared = await askRig({ station: rig, action: "prepare", key, name: key, command, small: true });
    const started = await askRig({ station: rig, action: "start", key });
    record("assistant", [{ type: "text", text: `${prepared}\n${started}` }]);
    said = await post(to, { text: `rigtask ${key}: ${prepared} // ${started}`, kind: "all_done", done: "ran the task on the rig, or was refused" });
  } else if (text.includes("serve:")) {
    const [name, port, words] = line("serve:").split("|");
    // a port another process holds (another run's service on the same machine) is said, not served over: the page
    // would be that other server's
    const taken = await new Promise((done) => {
      const probe = net.createServer().once("error", () => done(true));
      probe.listen(Number(port), "127.0.0.1", () => probe.close(() => done(false)));
    });
    if (taken) {
      process.stderr.write(`fake claude: serve: port ${port} is taken by another process\n`);
      return post(to, { text: `serve: port ${port} is taken by another process`, kind: "all_done", done: "the port was taken" });
    }
    const dir = path.join(process.cwd(), `e2e-site-${port}`);
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, "index.html"), PAGE_A);
    fs.writeFileSync(path.join(dir, "b.html"), PAGE_B);
    fs.writeFileSync(path.join(dir, "style.css"), STYLE);
    fs.writeFileSync(path.join(dir, "data.json"), JSON.stringify({ n: 42 }));
    const started = await tool("job_start", { name, port: Number(port), command: `cd '${dir}' && exec python3 -m http.server ${port} --bind 127.0.0.1` });
    record("assistant", [{ type: "text", text: started }]);
    said = await post(to, { text: words ?? name, kind: "all_done", done: "started the service that was asked for" });
  } else if (/Your (?:request|grant) r_[\w-]+ (?:for|of) |Remote task \S+ on /.test(text)) {
    // A rig or device grant, refusal or end (station/src/rigs/requests.ts), or how a remote task went
    // (station/mb/src/reader/remote_source.mbt), as the station tells the chat: ended here with chat_state, since
    // still.fail's fake answers it with no MCP call, which the station takes for its tools lost and restarts it
    // mid-session.
    said = await tool("chat_state", { kind: "all_done", done: "noted the station notice" });
  } else {
    // steps: a command and what it printed, an edit, then the answer
    const words = line("steps:");
    const call = (id, name, input) => record("assistant", [{ type: "tool_use", id, name, input }]);
    const result = (id, content) => record("user", [{ type: "tool_result", tool_use_id: id, content }]);
    call("toolu_e2e_1", "Bash", { command: "ls docs", description: "列出 docs 目录" });
    result("toolu_e2e_1", "stillfail-port.md\nstillfail-android-map.md");
    call("toolu_e2e_2", "Edit", { file_path: "/tmp/e2e/notes.md", old_string: "旧的一行", new_string: "新的一行" });
    result("toolu_e2e_2", "The file /tmp/e2e/notes.md has been updated.");
    record("assistant", [{ type: "text", text: "看过了，改好了。" }]);
    said = await post(to, { text: words, kind: "all_done", done: "answered the question that was asked" });
  }
  return said;
}

// The move drill's words (above): what each posts.
async function drill(text, to, line) {
  const done = (words) => post(to, { text: words, kind: "all_done", done: "did what the drill asked" });
  if (/(^|\s)drill-remember:/.test(text)) return done(`drill-remembered ${line("drill-remember:").trim()}`);
  if (/(^|\s)drill-recall:/.test(text)) {
    // (its own transcript, as the real one resumes from it: the words remembered, as they were said to it)
    const lines = fs.existsSync(transcript) ? fs.readFileSync(transcript, "utf8").split("\n").filter((l) => l !== "") : [];
    let secret = "none";
    for (const l of lines) {
      try {
        const e = JSON.parse(l);
        const c = typeof e.message?.content === "string" ? e.message.content : "";
        const m = e.type === "user" ? /drill-remember:(\S+)/.exec(c) : null;
        if (m) secret = m[1];
      } catch {}
    }
    return done(`drill-recall ${line("drill-recall:").trim()} secret=${secret} lines=${lines.length} resumed=${args.includes("--resume")} session=${sessionId} cwd=${process.cwd()} pid=${process.pid}`);
  }
  if (/(^|\s)drill-job:/.test(text)) {
    const tag = line("drill-job:").trim();
    const started = await tool("job_start", { name: `drill-${tag}`, command: `while :; do sleep 3600; done; : drill-job-${tag}` });
    record("assistant", [{ type: "text", text: started }]);
    return done(`drill-job ${tag}: ${started}`);
  }
  if (/(^|\s)drill-move:/.test(text)) {
    const answer = await tool("station_move", JSON.parse(line("drill-move:")));
    record("assistant", [{ type: "text", text: answer }]);
    return done(`drill-move: ${answer.slice(0, 6000)}`);
  }
  if (/(^|\s)drill-note:/.test(text)) return done(`drill-noted ${line("drill-note:").trim()} cwd=${process.cwd()}`);
  if (/(^|\s)drill-seed:/.test(text)) return done(`drill-seeded ${line("drill-seed:").trim()}`);
  if (/(^|\s)drill-gate:/.test(text)) {
    const name = line("drill-gate:").trim();
    const gate = `${process.env.FAKE_DUMP}.gate-${name}`;
    // (until the drill makes the file: its directory's events, and a look as the watch begins)
    await new Promise((resolve) => {
      const w = fs.watch(path.dirname(gate), () => fs.existsSync(gate) && (w.close(), resolve()));
      if (fs.existsSync(gate)) (w.close(), resolve());
    });
    return done(`drill-gated ${name} pid=${process.pid}`);
  }
  return done(`drill: no such word in ${text.slice(0, 200)}`);
}

const ours = (text) => /still has no title, and nobody is at work in it now/.test(text) || /(^|\s)(card:|text-card:|steps:|serve:|md:|secret:|rig:|rigtask:|devtalk:|drill-[a-z]+:)/.test(text) ||/Granted: 「[^」]*」, grant r_|\(r_[\w-]+\) was (refused|let go)/.test(text) || /Your (?:request|grant) r_[\w-]+ (?:for|of) |Remote task \S+ on /.test(text);
readline.createInterface({ input: process.stdin }).on("line", (line) => {
  let msg = null;
  try {
    msg = JSON.parse(line);
  } catch {}
  const text = msg?.type === "user" ? (msg.message?.content ?? []).map((c) => c.text ?? "").join("") : "";
  if (msg?.type === "user" && process.env.FAKE_DUMP) {
    fs.appendFileSync(`${process.env.FAKE_DUMP}.turns`, JSON.stringify({ at: Date.now(), pid: process.pid, session: sessionId, resumed: args.includes("--resume"), cwd: process.cwd(), text: text.slice(0, 8000) }) + "\n");
  }
  if (msg?.type === "user" && busy) {
    steered.push(text);
    return;
  }
  if (msg?.type === "user" && ours(text)) {
    turn(text).catch((e) => {
      fs.writeSync(2, `e2e fake claude: ${e?.stack ?? e}\n`);
      say({ type: "result", subtype: "error_during_execution", is_error: true, session_id: sessionId, result: String(e) });
    });
    return;
  }
  if (child) child.stdin.write(line + "\n");
});
process.stdin.on("end", () => (child ? child.stdin.end() : process.exit(0)));
