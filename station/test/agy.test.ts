import assert from "node:assert/strict";
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import { delimiter, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { tmpdir } from "node:os";
import { after, test } from "node:test";
import { AGY_CATALOG_RETRY_MS, AGY_FILE_TOKENS, AGY_TOOL_BUDGET, AGY_TOOL_CEILING, AGY_TOOL_WRAP, AgyDriver, AgyNoCatalog, SESSIONS, agyAccountFile, agyBringIn, agyLentFile, agyPlan, agyPlanIn, agyRenew, agySessionPlan, agyTakeBack, agyTokenReady, agyKeychain, goKeyringValue, readLinuxAgyKeyring, agyBaseModel, agyCatalog, agyConversations, agyEnv, agyHome, agyToken, agyVariant, classifyFailure, geminiDir, noticeFailure } from "../src/agents/agy.ts";
import { REPO_RULES_HOOK } from "../src/agents/repo-rules.ts";
import type { OpenOptions, RuntimeEvent } from "../src/agents/runtime.ts";
import { allLeft } from "../src/agents/runner.ts";
import { billedPerUse, profileRuntimes, vertexKeyFile } from "../src/agents/profiles.ts";
import { Accounts, accountEmailSoon } from "../src/accounts/index.ts";
import { uncheckOutdated } from "../src/accounts/models.ts";
import { accessKinds, checkProfile, loginCommand } from "../src/accounts/profiles.ts";
import { LoginManager, type LoginState, agyCallbackCode } from "../src/accounts/login.ts";
import { fakeBrowser } from "./accounts-fakes.ts";
import { checkQuota } from "../src/accounts/quota.ts";
import { ConfigFile } from "../src/ops/config.ts";
import { Accounts as SessionAccounts } from "../src/sessions/accounts.ts";
import { urgency } from "../src/sessions/pool.ts";
import { hubConfig } from "../src/sessions/config.ts";
import { Store } from "../src/store/store.ts";
import { tr } from "../src/ops/i18n.ts";
import { platform } from "../src/platform/index.ts";
import { transcriptPath, readTimeline, isPosting } from "./reference/transcript.ts";
import { callsOf } from "./usage-counter-reference.ts";
import { CHAT_CREATE } from "../src/tools/chat.ts";
import { failureOf } from "../src/agents/runtime.ts";
import { cannotStartWords } from "../src/sessions/actor.ts";
import { testClock } from "./hub-fakes.ts";
import { CORE, HIDDEN, INDIRECT, McpEndpoint } from "../src/tools/mcp.ts";
import { stationTools } from "./station-tools.ts";

const data = mkdtempSync(process.platform === "win32" ? join(tmpdir(), "agy-") : "/tmp/agy-");
const drivers: AgyDriver[] = [];
after(async () => {
  await Promise.all(drivers.map((d) => d.shutdown()));
  rmSync(data, { recursive: true, force: true });
});
const fake = `${fileURLToPath(new URL("./fake", import.meta.url))}${delimiter}${process.env.PATH}`;
let n = 0;
function setup(env: Record<string, string> = {}) {
  const id = ++n;
  const dump = join(data, `dump-${id}`);
  const options: OpenOptions = {
    key: `agy-test-${id}`,
    profile: { id: "ag", runtime: "agy", home: join(data, `home-${id}`), access: { kind: "api-provider", provider: "google", key: "gemini-key" }, env: { PATH: fake, FAKE_DUMP: dump, ...env } },
    cwd: data, instructions: "Use chat_post to answer.", mcpToken: "test-token", mcpUrl: "http://127.0.0.1:12345/mcp", route: "test",
  };
  const events: RuntimeEvent[] = [];
  const driver = new AgyDriver({ data });
  drivers.push(driver);
  return { options, events, driver, dump };
}
async function until(f: () => boolean | Promise<boolean>) {
  const end = Date.now() + 10_000;
  while (!(await f())) {
    if (Date.now() > end) throw new Error("timed out");
    await new Promise((r) => setTimeout(r, 20));
  }
}
const ended = (events: RuntimeEvent[]) => events.filter((e) => e.type === "turnEnded");
// (only complete newline-terminated lines: until() reads .rpc while fake/agy.mjs appends to it)
const rpc = (dump: string) => {
  const raw = readFileSync(dump + ".rpc", "utf8");
  const nl = raw.lastIndexOf("\n");
  if (nl < 0) return [];
  return raw.slice(0, nl).split("\n").filter(Boolean).map((s) => JSON.parse(s));
};

test("a Gemini key runs the Antigravity CLI in its profile's files, with the station's tools and instructions", async () => {
  const { options, events, driver, dump } = setup();
  const session = await driver.open({ ...options, model: "gemini-3.1-pro" }, (e) => events.push(e));
  const started = JSON.parse(readFileSync(dump, "utf8").trim().split("\n")[0]!);
  assert.deepEqual(started.args, ["acp", "--gemini-dir", geminiDir(options.profile.home), "--dangerously-skip-permissions", "--disable-telemetry"]);
  assert.equal(started.key, "gemini-key");
  assert.equal(started.updates, "1");
  const opened = rpc(dump).find((m) => m.method === "session/new").params;
  assert.equal(opened.mcpServers[0].headers[0].value, "Bearer test-token");
  assert.equal(opened._meta.antigravity.systemPrompt.append, "Use chat_post to answer.");
  assert.equal(rpc(dump).find((m) => m.method === "session/set_model").params.modelId, "gemini-3.1-pro");
  await session.prompt("hello");
  await until(() => ended(events).length === 1);
  assert.deepEqual(ended(events)[0], { type: "turnEnded", outcome: { kind: "completed" } });
  // What the person said goes as it is: the instructions are the system prompt's.
  assert.equal(rpc(dump).find((m) => m.method === "session/prompt").params.prompt[0].text, "hello");
  const path = transcriptPath("agy", options.profile.home, session.id());
  assert.ok(path);
  const lines = readFileSync(path, "utf8").trim().split("\n").map((s) => JSON.parse(s));
  assert.equal(lines.find((m) => m.type === "assistant").text, "first hello");
  assert.equal(lines.find((m) => m.type === "tool").result, "file contents");
  // The station's tool named as the others name it, from the title the CLI gives an MCP tool's call.
  assert.ok(isPosting(lines.filter((m) => m.type === "tool").at(-1).name));
  assert.ok(readTimeline("agy", path).length > 0);
  // The turn's counts, input apart from the cache's, thoughts with the output; the context it ended with.
  const calls = callsOf("agy", readFileSync(path, "utf8"), false, { model: null, codexId: null });
  assert.equal(calls.length, 1);
  assert.deepEqual([calls[0]!.input, calls[0]!.cacheRead, calls[0]!.output, calls[0]!.model, calls[0]!.context, calls[0]!.window], [1200, 200, 300, "gemini-3.1-pro", 5000, 1048576]);
  const id = session.id();
  await session.dispose();
  events.length = 0;
  const resumed = await driver.open({ ...options, resume: id }, (e) => events.push(e));
  assert.equal(resumed.id(), id);
  assert.equal(events.length, 0);
  assert.equal(rpc(dump).filter((m) => m.method === "session/load").at(-1).params._meta.antigravity.systemPrompt.append, "Use chat_post to answer.");
  await resumed.prompt("again");
  await until(() => ended(events).length === 1);
  assert.doesNotMatch(readFileSync(path, "utf8"), /past replay/);
  await resumed.dispose();
});

test("a conversation the station kept but its CLI does not is not taken up: failed before anything starts, so the session goes on afresh; one another home of the station keeps is brought in and taken up", async () => {
  const { options, events, driver, dump } = setup();
  const session = await driver.open(options, (e) => events.push(e));
  await session.prompt("hello");
  await until(() => ended(events).length === 1);
  const id = session.id();
  await session.dispose();
  // A chat moved here with the station's transcript alone (2026-11-16): its CLI's conversation is under the id of the
  // profile it ran on there, a home beside this one; this profile's own store has none of it.
  const cli = (home: string) => join(geminiDir(home), "antigravity-cli");
  const own = join(agyConversations(options.profile.home), `${id}.db`);
  const db = readFileSync(own, "utf8");
  rmSync(own);
  const started = () => readFileSync(dump, "utf8").trim().split("\n").length;
  const before = started();
  await assert.rejects(driver.open({ ...options, resume: id }, (e) => events.push(e)), /no Antigravity conversation .* in its CLI's store/);
  assert.equal(started(), before, "no process started for it");
  const other = join(data, `moved-from-${id}`);
  mkdirSync(agyConversations(other), { recursive: true });
  mkdirSync(join(cli(other), "brain", id, "notes"), { recursive: true });
  mkdirSync(join(cli(other), "annotations"), { recursive: true });
  writeFileSync(join(agyConversations(other), `${id}.db`), db);
  writeFileSync(join(agyConversations(other), `${id}.db-wal`), "wal");
  writeFileSync(join(cli(other), "brain", id, "notes", "plan.md"), "plan");
  writeFileSync(join(cli(other), "annotations", `${id}.pbtxt`), "seen");
  events.length = 0;
  const resumed = await driver.open({ ...options, resume: id }, (e) => events.push(e));
  assert.equal(resumed.id(), id);
  assert.equal(readFileSync(own, "utf8"), db);
  assert.equal(readFileSync(`${own}-wal`, "utf8"), "wal");
  assert.equal(readFileSync(join(cli(options.profile.home), "brain", id, "notes", "plan.md"), "utf8"), "plan");
  assert.equal(readFileSync(join(cli(options.profile.home), "annotations", `${id}.pbtxt`), "utf8"), "seen");
  assert.ok(existsSync(join(agyConversations(other), `${id}.db`)), "copied: the home it came from keeps its own");
  await resumed.prompt("again");
  await until(() => ended(events).length === 1);
  await resumed.dispose();
});

test("a conversation that went from one profile to another and back (P1, P2, P1): the home that wrote it last is brought in whole, what P1 kept of it before gone, its old -wal and -shm too; one P1 wrote last stays as it is", async () => {
  const homes = mkdtempSync(join(data, "bring-"));
  const id = "conv-1";
  const cli = (name: string) => join(geminiDir(join(homes, name)), "antigravity-cli");
  const put = (name: string, rel: string, text: string, at: number) => {
    const path = join(cli(name), rel);
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, text);
    utimesSync(path, at, at);
  };
  // P1 ran it first and kept its database with a -wal and -shm of its own, then P2 took it on and wrote it later (its
  // CLI ended: its -wal checkpointed into the database and gone).
  put("P1", `conversations/${id}.db`, "old db", 1_700_000_000);
  put("P1", `conversations/${id}.db-wal`, "old wal", 1_700_000_000);
  put("P1", `conversations/${id}.db-shm`, "old shm", 1_700_000_000);
  put("P1", `brain/${id}/stale.md`, "deleted since", 1_700_000_000);
  put("P1", `annotations/${id}.pbtxt`, "old seen", 1_700_000_000);
  put("P2", `conversations/${id}.db`, "new db", 1_700_000_100);
  put("P2", `brain/${id}/plan.md`, "plan", 1_700_000_100);
  // (another conversation of P1's is not touched)
  put("P1", "conversations/other.db-wal", "other wal", 1_700_000_000);
  assert.equal(await agyBringIn(join(homes, "P1"), id), "P2");
  const conv = join(cli("P1"), "conversations");
  assert.equal(readFileSync(join(conv, `${id}.db`), "utf8"), "new db");
  assert.ok(!existsSync(join(conv, `${id}.db-wal`)), "P1's old -wal is not left beside P2's database");
  assert.ok(!existsSync(join(conv, `${id}.db-shm`)), "nor its -shm");
  assert.deepEqual(readdirSync(conv).sort(), [`${id}.db`, "other.db-wal"], "nothing of the copy left beside it");
  assert.deepEqual(readdirSync(join(cli("P1"), "brain", id)), ["plan.md"], "its brain as P2's, nothing P2 no longer has");
  assert.ok(!existsSync(join(cli("P1"), "annotations", `${id}.pbtxt`)), "nor an annotation P2 has none of");
  assert.equal(readFileSync(join(conv, "other.db-wal"), "utf8"), "other wal");
  assert.equal(await agyBringIn(join(homes, "P1"), id), null, "brought: P1's is as late as P2's, nothing brought again");
  // P2 writes on with its -wal: brought with it.
  put("P2", `conversations/${id}.db-wal`, "new wal", 1_700_000_200);
  assert.equal(await agyBringIn(join(homes, "P1"), id), "P2");
  assert.equal(readFileSync(join(conv, `${id}.db-wal`), "utf8"), "new wal");
  // P1 writes it last: it stays as it is.
  put("P1", `conversations/${id}.db-wal`, "P1 wal", 1_700_000_300);
  assert.equal(await agyBringIn(join(homes, "P1"), id), null);
  assert.equal(readFileSync(join(conv, `${id}.db-wal`), "utf8"), "P1 wal");
});

test("a process that could not reach its backend as the machine came up (no models) is opened again after a wait on the clock; the conversation resumed with its model, never refused as an unknown model", async () => {
  const { options, events, driver: first, dump } = setup();
  const session = await first.open(options, (e) => events.push(e));
  const id = session.id();
  await session.dispose();
  const time = testClock();
  const driver = new AgyDriver({ data, clock: time.clock });
  drivers.push(driver);
  // Its first two openings answer with no models (tokyo-mac-studio-0, 2026-11-16: `models: null`), the third with them.
  const offline = { ...options, profile: { ...options.profile, env: { ...(options.profile.env as Record<string, string>), FAKE_AGY_OFFLINE: "2" } } };
  let opened: Awaited<ReturnType<AgyDriver["open"]>> | null = null;
  let failed: unknown = null;
  const opening = driver.open({ ...offline, resume: id, model: "gemini-3.1-pro" }, (e) => events.push(e)).then((s) => (opened = s), (e) => (failed = e));
  // A wait begun, or the opening over (as it was before: refused at once, "Unknown model ID").
  const waits = async (n: number) => {
    await Promise.race([time.begun(n), opening]);
    assert.equal(failed, null, String(failed));
    assert.equal(opened, null, "not opened before its wait");
    assert.equal(time.asked(), n);
  };
  await waits(1);
  await time.adjust(AGY_CATALOG_RETRY_MS[0]!);
  await waits(2);
  await time.adjust(AGY_CATALOG_RETRY_MS[1]!);
  await opening;
  assert.equal(failed, null, String(failed));
  assert.equal(opened!.id(), id, "the conversation it was resuming");
  assert.equal(readFileSync(dump + ".offline", "utf8"), "3");
  const set = rpc(dump).filter((m) => m.method === "session/set_model");
  assert.deepEqual(set.map((m) => m.params.modelId), ["gemini-3.1-pro"], "the model set only once there were models");
  assert.equal(time.asked(), 2);
  await opened!.dispose();
});

test("the processes of openings that offered no models, ended as it opens again, tell nothing of their end: the session's process opened after them is not taken for closed", async () => {
  const { options } = setup({ FAKE_AGY_OFFLINE: "2" });
  const time = testClock();
  const driver = new AgyDriver({ data, clock: time.clock });
  drivers.push(driver);
  const told: RuntimeEvent[] = [];
  const opening = driver.open({ ...options, model: "gemini-3.1-pro" }, (e) => told.push(e));
  await Promise.race([time.begun(1), opening]);
  await time.adjust(AGY_CATALOG_RETRY_MS[0]!);
  await Promise.race([time.begun(2), opening]);
  await time.adjust(AGY_CATALOG_RETRY_MS[1]!);
  const session = await opening;
  // (each ended before the next opened, its end handled: `dispose` waits on it)
  assert.deepEqual(told.filter((e) => e.type === "closed"), [], "no `closed` of the two ended (ccvm 2026-11-22: the actor closed the live one)");
  await session.dispose();
});

test("a process that never reaches its backend fails as the network after its waits, not as an unknown model", async () => {
  const { options, events, dump } = setup({ FAKE_AGY_OFFLINE: "100" });
  const time = testClock();
  const driver = new AgyDriver({ data, clock: time.clock });
  drivers.push(driver);
  let failed: unknown = null;
  const opening = driver.open({ ...options, model: "gemini-3.1-pro" }, (e) => events.push(e)).then(() => assert.fail("opened"), (e) => (failed = e));
  for (const [i, wait] of AGY_CATALOG_RETRY_MS.entries()) {
    // A wait begun, or the opening over (as it was before: refused at once, "Unknown model ID").
    await Promise.race([time.begun(i + 1), opening]);
    assert.equal(time.asked(), i + 1, `waited before opening again: ${String(failed)}`);
    await time.adjust(wait);
  }
  await opening;
  assert.ok(failed instanceof AgyNoCatalog, String(failed));
  assert.equal(readFileSync(dump + ".offline", "utf8"), String(AGY_CATALOG_RETRY_MS.length + 1), "opened once and once again after each wait");
  assert.equal(rpc(dump).filter((m) => m.method === "session/set_model").length, 0, "no model asked of a process that offers none");
  assert.equal(failureOf((failed as Error).message), "network");
  const words = cannotStartWords(failed);
  assert.doesNotMatch(words, /Unknown model ID/);
  // As any failure of the network is said ("connection failed"): the station's words for it, then what was said.
  assert.equal(words.split("\n")[0], cannotStartWords(new Error("connection failed")).split("\n")[0]);
  assert.notEqual(words.split("\n")[0], cannotStartWords(new Error("Unknown model ID: gemini-3.1-pro")).split("\n")[0]);
});

test("an opening given up (node.cancelOpen: timed out, stopped, closed) during its wait to open again ends there at once: no clock moved, no process started again", async () => {
  const { options, events, dump } = setup({ FAKE_AGY_OFFLINE: "100" });
  const time = testClock();
  const driver = new AgyDriver({ data, clock: time.clock });
  drivers.push(driver);
  const ac = new AbortController();
  let failed: unknown = null;
  const opening = driver.open({ ...options, model: "gemini-3.1-pro", signal: ac.signal }, (e) => events.push(e)).then(() => assert.fail("opened"), (e) => (failed = e));
  await Promise.race([time.begun(1), opening]);
  assert.equal(failed, null, String(failed));
  assert.equal(time.asked(), 1);
  ac.abort("cancelled");
  await opening;
  assert.match(String(failed), /open aborted/);
  assert.equal(readFileSync(dump + ".offline", "utf8"), "1", "no process opened again");
  assert.equal(time.asked(), 1, "no wait begun again");
  // (its clock moved past every wait after: still nothing started)
  await time.adjust(AGY_CATALOG_RETRY_MS.reduce((a, b) => a + b, 0));
  assert.equal(readFileSync(dump + ".offline", "utf8"), "1");
  assert.equal((driver as unknown as { live: Set<unknown> }).live.size, 0, "nothing of it kept");
});

test("an opening given up while its process starts fails at once, its process ended, and never waits to open again", async () => {
  const { options, dump } = setup({ FAKE_AGY_SILENT: "1" });
  const time = testClock();
  const driver = new AgyDriver({ data, clock: time.clock });
  drivers.push(driver);
  const ac = new AbortController();
  const opening = driver.open({ ...options, signal: ac.signal }, () => {});
  opening.catch(() => {});
  await until(() => existsSync(dump + ".rpc") && rpc(dump).some((m) => m.method === "initialize"));
  const [stuck] = [...(driver as unknown as { live: Set<unknown> }).live] as { runner(): string | undefined }[];
  const runner = stuck!.runner()!;
  ac.abort("cancelled");
  await assert.rejects(opening, /open aborted/);
  assert.equal(time.asked(), 0, "no wait to open again");
  assert.equal((driver as unknown as { live: Set<unknown> }).live.size, 0, "nothing of it kept");
  const { findRunner } = await import("../src/agents/process.ts");
  await until(async () => (await findRunner(data, runner)) === undefined);
  // Given up before it was asked: nothing started at all.
  const { options: before, dump: none } = setup();
  const gone = new AbortController();
  gone.abort("closed");
  await assert.rejects(driver.open({ ...before, signal: gone.signal }, () => {}), /open aborted/);
  assert.equal(existsSync(none), false, "no process started");
});

test("another model between turns is set in the running process; one it does not offer starts it again", async () => {
  const { options, events, driver, dump } = setup();
  const session = await driver.open(options, (e) => events.push(e));
  assert.equal(session.model, "gemini-3.5-flash");
  assert.equal(session.retune!({ ...options, model: "gemini-3.1-pro" }), true);
  assert.equal(session.retune!({ ...options, model: "not-offered" }), false);
  await session.prompt("hi");
  await until(() => ended(events).length === 1);
  assert.deepEqual(rpc(dump).filter((m) => m.method === "session/set_model").map((m) => m.params.modelId), ["gemini-3.1-pro"]);
  await session.dispose();
});

test("cancel, a signed-out account, an expired sign-in and a spent quota", async () => {
  const { options, events, driver } = setup();
  const s = await driver.open(options, (e) => events.push(e));
  assert.equal(await s.steer("idle"), false);
  await s.prompt("hold");
  assert.equal(await s.steer("hold-steer"), true);
  await s.abort();
  await until(() => ended(events).length === 1);
  assert.deepEqual(ended(events)[0], { type: "turnEnded", outcome: { kind: "aborted" } });
  assert.equal(await s.steer("idle"), false);
  await s.prompt("expired");
  await until(() => ended(events).length === 2);
  assert.equal((ended(events)[1] as any).outcome.reason, "auth");
  await s.prompt("quota");
  await until(() => ended(events).length === 3);
  assert.equal((ended(events)[2] as any).outcome.reason, "rate_limit");
  // 1.5.9 says a spent quota only in words, its turn ended well (2026-11-15): still a limit, so the session moves on.
  await s.prompt("quota-said");
  await until(() => ended(events).length === 4);
  assert.deepEqual(ended(events)[3], { type: "turnEnded", outcome: { kind: "failed", reason: "rate_limit", message: "⚠ Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 56m33s." } });
  // It says so after the turn's calls too, its last words (2026-11-15): still a limit.
  await s.prompt("quota-after-calls");
  await until(() => ended(events).length === 5);
  assert.deepEqual(ended(events)[4], { type: "turnEnded", outcome: { kind: "failed", reason: "rate_limit", message: "⚠ Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 22m58s." } });
  await s.prompt("the quota");
  await until(() => ended(events).length === 6);
  assert.deepEqual(ended(events)[5], { type: "turnEnded", outcome: { kind: "completed" } });
  await s.dispose();
  const signedOut = setup({ FAKE_AGY_SIGNED_OUT: "1" });
  await assert.rejects(signedOut.driver.open(signedOut.options, () => {}), /Authentication required/);
  assert.equal(classifyFailure("Authentication required"), "auth");
  // What the model says of a quota is no notice: not the whole turn, not one line of the CLI's own.
  assert.equal(noticeFailure("Your quota resets in an hour."), null);
  assert.equal(noticeFailure("⚠ Check the quota:\nit is low."), null);
  assert.equal(noticeFailure("Summary:\n⚠ Your quota resets in an hour."), null);
  assert.equal(noticeFailure("⚠ Something else went wrong."), null);
  // Its words for a failure it does not name (a borrowed token run out under it, 2026-11-16): a failed turn, not last words,
  // even when streamed after partial text or a steered prompt.
  assert.equal(noticeFailure("⚠ Agent execution terminated due to error."), "other");
  assert.equal(noticeFailure("partial\n⚠ Agent execution terminated due to error.\n"), "other");
  assert.equal(noticeFailure("⚠ Authentication expired. Please log back in."), "auth");
  // A sign-in lent by another station run out under the process (1.5.9's words): a sign-in's failure, which reopens it.
  assert.equal(noticeFailure('⚠ agent executor error: generating and executing: request failed: Post "https://daily-cloudcode-pa.googleapis.com/v1internal:streamGenerateContent?alt=sse": oauth2: token expired and refresh token is not set'), "auth");
  assert.equal(noticeFailure('partial\n⚠ agent executor error: generating and executing: request failed: Post "https://daily-cloudcode-pa.googleapis.com/v1internal:streamGenerateContent?alt=sse": oauth2: token expired and refresh token is not set\n'), "auth");
  assert.equal(noticeFailure("⚠ UNAUTHENTICATED (code 401): Request had invalid authentication credentials."), "auth");
  assert.equal(noticeFailure("partial\n⚠ UNAUTHENTICATED (code 401): Request had invalid authentication credentials.\n"), "auth");
  assert.equal(noticeFailure("⚠ agent executor error: unexpected EOF"), "other");
});

test("a borrowed Google account: a process opens on a sign-in lent anew once the one it has runs out soon, and goes on with one that lasts", async () => {
  const { options } = setup();
  const profile = { ...options.profile, access: { kind: "subscription" }, share: { borrowed: true, host: "h", id: "sh" } };
  const signIn = (minutes: number) => JSON.stringify({ token: { access_token: `a${minutes}`, expiry: new Date(Date.now() + minutes * 60_000).toISOString() }, auth_method: "consumer" });
  const writes: number[] = [];
  let lend = 55;
  const driver = new AgyDriver({ data, lent: { borrowed: () => true, write: async (p) => { writes.push(lend); writeFileSync(agyToken(p.home), signIn(lend)); return Date.now() + lend * 60_000; } } });
  drivers.push(driver);
  mkdirSync(join(geminiDir(profile.home), "antigravity-cli"), { recursive: true });
  // 50 minutes left: opened on it, its host not asked.
  writeFileSync(agyToken(profile.home), signIn(50));
  let session = await driver.open({ ...options, profile }, () => {});
  await session.dispose();
  assert.deepEqual(writes, []);
  // 20 left: lent anew first.
  writeFileSync(agyToken(profile.home), signIn(20));
  session = await driver.open({ ...options, profile }, () => {});
  await session.dispose();
  assert.deepEqual(writes, [55]);
  assert.equal(JSON.parse(readFileSync(agyToken(profile.home), "utf8")).token.access_token, "a55");
  // Its host away: 20 left is still enough to start on; 3 is not.
  const away = new AgyDriver({ data, lent: { borrowed: () => true, write: async () => { throw new Error("未能借出"); } } });
  drivers.push(away);
  writeFileSync(agyToken(profile.home), signIn(20));
  session = await away.open({ ...options, profile }, () => {});
  await session.dispose();
  writeFileSync(agyToken(profile.home), signIn(3));
  await assert.rejects(away.open({ ...options, profile }, () => {}), /未能借出/);
});

test("steering mid-turn injects a prompt, completes once on the steered prompt, and keeps both prompts' usage", async () => {
  const { options, events, driver } = setup();
  const s = await driver.open({ ...options, model: "gemini-3.1-pro" }, (e) => events.push(e));
  await s.prompt("hold");
  await until(() => events.some((e) => e.type === "live" && e.event.kind === "delta" && e.event.text === "first "));
  assert.equal(await s.steer("follow up"), true);
  await until(() => ended(events).length === 1);
  assert.deepEqual(ended(events)[0], { type: "turnEnded", outcome: { kind: "completed" } });
  const path = transcriptPath("agy", options.profile.home, s.id())!;
  const entries = readFileSync(path, "utf8").trim().split("\n").map((line) => JSON.parse(line));
  assert.equal(entries.filter((e) => e.type === "assistant").at(-1)?.text, "first follow up");
  assert.equal(entries.some((e) => e.type === "user" && e.text === "follow up"), true);
  const calls = callsOf("agy", readFileSync(path, "utf8"), false, { model: null, codexId: null });
  assert.equal(calls.length, 2);
  assert.deepEqual([calls[0]!.input, calls[0]!.output, calls[0]!.model], [500, 10, "gemini-3.1-pro"]);
  assert.deepEqual([calls[1]!.input, calls[1]!.cacheRead, calls[1]!.output, calls[1]!.model], [1200, 200, 300, "gemini-3.1-pro"]);
  await s.dispose();
});

test("models are read without a turn, the station's tools or a transcript", async () => {
  const { options, driver, dump } = setup();
  assert.deepEqual(await driver.models(options.profile), ["gemini-3.5-flash", "gemini-3.1-pro"]);
  const calls = rpc(dump);
  assert.deepEqual(calls.find((c) => c.method === "session/new").params.mcpServers, []);
  assert.equal(calls.some((c) => c.method === "session/prompt" || c.method === "session/set_model"), false);
  assert.equal(readFileSync(dump, "utf8").includes(options.mcpToken), false);
});

test("the Antigravity catalog reports the plan and groups thinking levels by model", async () => {
  const { options, events, driver, dump } = setup({ FAKE_AGY_SUBSCRIPTION: "1", FAKE_AGY_TIER: "g1-ultra-lite-tier" });
  const cat = await driver.catalog(options.profile);
  assert.deepEqual(cat, {
    models: ["gemini-4-carbon", "claude-opus-5-5", "gpt-oss-120b", "gemini-pro-orchestrator"],
    efforts: {
      "gemini-4-carbon": ["low", "medium", "high"],
      "claude-opus-5-5": ["low", "medium", "high"],
      "gpt-oss-120b": [],
      "gemini-pro-orchestrator": [],
    },
    defaults: { "gemini-4-carbon": "high", "claude-opus-5-5": "medium" },
    plan: "Ultra 5x",
  });
  const medCat = agyCatalog(
    ["gemini-4-carbon-low", "gemini-4-carbon-medium", "gemini-4-carbon-high", "claude-opus-5-5-low", "claude-opus-5-5-high"],
    "gemini-4-carbon-medium",
  );
  assert.deepEqual(medCat.defaults, { "gemini-4-carbon": "medium", "claude-opus-5-5": "high" });
  assert.equal(agyVariant("gemini-4-carbon", undefined, ["gemini-4-carbon-low", "gemini-4-carbon-medium", "gemini-4-carbon-high"], "gemini-4-carbon-medium"), "gemini-4-carbon-medium");
  assert.equal(agyVariant("claude-opus-5-5", undefined, ["claude-opus-5-5-low", "claude-opus-5-5-medium", "claude-opus-5-5-high"], "gemini-4-carbon-medium"), "claude-opus-5-5-medium");
  assert.equal(agyVariant("claude-opus-5-5", undefined, ["claude-opus-5-5-low", "claude-opus-5-5-high"], "gemini-4-carbon-medium"), "claude-opus-5-5-high");
  assert.deepEqual(agyBaseModel("claude-opus-5-5-medium"), { model: "claude-opus-5-5", effort: "medium" });
  assert.equal(agyVariant("gpt-oss-120b", undefined, ["gpt-oss-120b-medium"]), "gpt-oss-120b-medium");

  const session = await driver.open({ ...options, model: "gemini-4-carbon", effort: "medium" }, (e) => events.push(e));
  assert.equal(session.model, "gemini-4-carbon");
  assert.equal(session.currentModelId, "gemini-4-carbon-medium");
  assert.equal(session.retune!({ ...options, model: "gemini-4-carbon" }), true, "default effort returns to the CLI's defaultModelId");
  assert.equal(session.currentModelId, "gemini-4-carbon-high");
  assert.equal(session.retune!({ ...options, model: "gpt-oss-120b" }), true);
  await session.prompt("hi");
  await until(() => ended(events).length === 1);
  assert.deepEqual(
    rpc(dump).filter((m) => m.method === "session/set_model").map((m) => m.params.modelId),
    ["gemini-4-carbon-medium", "gemini-4-carbon-high", "gpt-oss-120b-medium"],
  );
  await session.dispose();

  const cfg = hubConfig(
    { profiles: [{ id: "ag", name: "AGY", runtime: "agy", home: "/h", access: { kind: "subscription" } }] },
    "/x",
    () => cat.models,
  );
  const p = cfg.profiles[0]!;
  assert.equal(p.models.includes("gemini-4-carbon"), true);
  const { spelling } = await import("../src/sessions/config.ts");
  assert.equal(spelling(p, "gemini-4-carbon-high"), "gemini-4-carbon");
  const { availableEfforts } = await import("../src/sessions/pool.ts");
  assert.deepEqual(availableEfforts("agy", "gemini-4-carbon-high", { agy: cat.efforts }), ["low", "medium", "high"]);
  const legacySessions = new Map<string, any>([
    ["s-legacy", { key: "s-legacy", runtime: "agy", profile: "ag", profilePinned: false, model: "gemini-4-carbon-high", effort: null }],
  ]);
  const legacyPool = new SessionAccounts({
    config: () => cfg,
    store: {
      getSession: (k: string) => legacySessions.get(k),
      setSessionProfile: () => {},
      lastTurn: () => ({ endedAt: 1000 }),
      recentlyCompacted: () => false,
      compactionsReady: () => false,
      lastContexts: () => [],
      compactionPoints: () => new Map(),
    } as never,
    running: () => [],
    clock: { currentTimeMillisUnsafe: () => 2000 } as never,
  });
  legacyPool.setHealth(() => ({
    check: { state: "ok", detail: "ok", models: cat.models, modelEfforts: { agy: cat.efforts }, checkedAt: 1500 },
  }));
  const patched = legacyPool.change("s-legacy", { effort: "low" }, "en");
  assert.equal(patched.effort, "low");
});

for (const crashed of [false, true]) {
  test(`taking up a running session ${crashed ? "after a crash" : "from a handover"} keeps its turn, configured model and catalog`, async () => {
    const { options, events, driver } = setup();
    const configured = { ...options, model: "gemini-3.1-pro" };
    const s = await driver.open(configured, (e) => events.push(e));
    await s.prompt("hold");
    await until(() => events.some((e) => e.type === "live" && e.event.kind === "delta" && e.event.text === "first "));
    if (!crashed) await driver.freeze();
    const snapshot = crashed ? null : s.snapshot();
    s.detach();
    await allLeft();
    const next = new AgyDriver({ data });
    drivers.push(next);
    const later: RuntimeEvent[] = [];
    // (after a crash, taken up before the station's door opened: no address of its tools known)
    const adopted = await next.adopt(crashed ? { ...configured, mcpUrl: "" } : configured, snapshot, (e) => later.push(e));
    assert.equal(adopted.mcpUrl(), crashed ? null : configured.mcpUrl);
    assert.equal(adopted.model, "gemini-3.1-pro");
    await adopted.abort();
    await until(() => ended(later).length === 1);
    assert.equal(ended(events).length, 0);
    await adopted.prompt("after");
    await until(() => ended(later).length === 2);
    const path = transcriptPath("agy", options.profile.home, adopted.id())!;
    const calls = callsOf("agy", readFileSync(path, "utf8"), false, { model: null, codexId: null });
    assert.equal(calls.at(-1)?.model, "gemini-3.1-pro");
    assert.equal(adopted.retune!({ ...options, model: "not-offered" }), false);
    assert.equal(adopted.retune!({ ...options, model: "gemini-3.5-flash" }), true);
    await adopted.dispose();
  });

  test(`taking up an idle process ${crashed ? "after a crash" : "from a handover"} refuses one whose CLI database is gone, and brings one another home keeps`, async () => {
    const { options, events, driver } = setup();
    const s = await driver.open(options, (e) => events.push(e));
    await s.prompt("hello");
    await until(() => ended(events).length === 1);
    const id = s.id();
    const runner = s.runner()!;
    const own = join(agyConversations(options.profile.home), `${id}.db`);
    const db = readFileSync(own, "utf8");
    rmSync(own);
    if (!crashed) await driver.freeze();
    const snapshot = crashed ? null : s.snapshot();
    s.detach();
    await allLeft();
    const next = new AgyDriver({ data });
    drivers.push(next);
    if (!crashed) {
      // Handover: refused before attaching, leaving the runner unowned for hub `endOrphans`, or brought in when another home has it.
      await assert.rejects(next.adopt({ ...options, resume: id }, snapshot, () => {}), /no Antigravity conversation .* in its CLI's store/);
      assert.equal(next.ownedRunners().size, 0);
      const other = join(dirname(options.profile.home), `other-home-${id}`);
      mkdirSync(agyConversations(other), { recursive: true });
      writeFileSync(join(agyConversations(other), `${id}.db`), db);
      const later: RuntimeEvent[] = [];
      const adopted = await next.adopt({ ...options, resume: id }, snapshot, (e) => later.push(e));
      assert.equal(readFileSync(own, "utf8"), db);
      await adopted.prompt("again");
      await until(() => ended(later).length === 1);
      assert.deepEqual(ended(later)[0], { type: "turnEnded", outcome: { kind: "completed" } });
      await adopted.dispose();
    } else {
      // Crash with no resume id: replay learns the conversation id, then disposes the broken runner when its `.db` is gone.
      const { findRunner } = await import("../src/agents/process.ts");
      await assert.rejects(next.adopt(options, null, () => {}), /no Antigravity conversation .* in its CLI's store/);
      assert.equal(next.ownedRunners().size, 0);
      assert.equal(await findRunner(data, runner), undefined, "broken runner disposed on crash replay");
    }
  });
}

test("a process whose station went before it was open (initialize never answered) is not taken up after a crash", async () => {
  const { options, driver, dump } = setup({ FAKE_AGY_SILENT: "1" });
  const opening = driver.open(options, () => {});
  opening.catch(() => {});
  await until(() => existsSync(dump + ".rpc") && rpc(dump).some((m) => m.method === "initialize"));
  const [stuck] = [...(driver as unknown as { live: Set<unknown> }).live] as { runner(): string | undefined }[];
  const runner = stuck!.runner()!;
  driver.detach();
  await allLeft();
  const next = new AgyDriver({ data });
  drivers.push(next);
  // (refused before it is held: the hub's `endOrphans` ends its runner, and the session opens again the usual way)
  await assert.rejects(next.adopt(options, null, () => {}), new RegExp(`agy process for ${options.key} had not opened a session`));
  assert.equal(next.ownedRunners().size, 0);
  const { endRunner, findRunner } = await import("../src/agents/process.ts");
  assert.notEqual(await findRunner(data, runner), undefined);
  await endRunner(data, runner, "test");
  (stuck as unknown as { waiting: { failAll(e: Error): void } }).waiting.failAll(new Error("ended"));
  await assert.rejects(opening, /ended/);
});

test("a warm Antigravity session whose CLI lacks its trajectory recovers across handover and on a live prompt without an error notice", async () => {
  const { Hub } = await import("../src/sessions/hub.ts");
  const { InternalChat } = await import("../src/sessions/internal.ts");
  const { FakeChat, message, reply, settle } = await import("./hub-fakes.ts");
  const { findRunner } = await import("../src/agents/process.ts");
  const hubDir = mkdtempSync(join(data, "hub-agy-"));
  const dump = join(hubDir, "dump");
  const home = join(hubDir, "homes", "ag");
  const raw = {
    askToName: false,
    profiles: [{ id: "ag", runtime: "agy", home, access: { kind: "api-provider", provider: "google", key: "gemini-key" }, env: { PATH: fake, FAKE_DUMP: dump } }],
    connects: [{ id: "cl", bind: { runtime: "agy" } }],
  };
  const cfg = hubConfig(raw, hubDir);
  const store = Store.open(join(hubDir, "stillfail.db"));
  const chat = new FakeChat("UBOT");
  const makeHub = (drv: AgyDriver) => {
    const h = new Hub({ config: () => cfg, store, chats: (id) => (id === "cl" ? chat : undefined), drivers: [drv], mcpUrl: "http://127.0.0.1:1/mcp", internal: new InternalChat() });
    h.skillsLinker = async () => "";
    return h;
  };
  const d1 = new AgyDriver({ data: hubDir });
  let completed = 0;
  const open = d1.open.bind(d1);
  d1.open = (options, events) => open(options, (event) => {
    if (event.type === "turnEnded") completed++;
    events(event);
  });
  let hub = makeHub(d1);
  let d2: AgyDriver | null = null;
  try {
    // 1. Turn 1 opens a warm agy process and ends; fake/agy does not call chat_state, so maxNudges=0 lets it settle idle.
    cfg.maxNudges = 0;
    const m1 = message({ text: "first ask" });
    await hub.accept("cl", m1);
    // The runtime id is saved before begin_turn sets running. Wait for the first turn's end before deleting its DB.
    // settle() drains actor work, but the fake process can still be waiting to read its prompt.
    await until(() => completed >= 1 && store.listSessions().length === 1 && !store.listSessions()[0]!.running && store.listSessions()[0]!.runtimeSessionId !== null);
    await settle();
    const key = store.listSessions()[0]!.key;
    const id1 = store.getSession(key)!.runtimeSessionId!;
    const runner1 = [...d1.ownedRunners()][0]!;
    assert.ok(await findRunner(hubDir, runner1));

    // 2. Its CLI `.db` is absent (as for a chat moved before #6608 whose warm process answered `session/load` on 0.1.9512).
    //    Across a station handover, `takeUp` refuses the warm process, `endOrphans` ends its runner, and the next turn
    //    starts a new conversation that reads back instead of failing with `trajectory not found`.
    rmSync(join(agyConversations(home), `${id1}.db`));
    await hub.handOver();
    await d1.shutdown();
    d2 = new AgyDriver({ data: hubDir });
    hub = makeHub(d2);
    await hub.takeUp();
    await until(async () => (await findRunner(hubDir, runner1)) === undefined);
    assert.equal(d2.ownedRunners().size, 0);

    await hub.accept("cl", reply(m1, "2000.2", "<@UBOT> make it simpler", { addressed: true }));
    // (the turn's prompt as the CLI took it, and the turn over: a session not running with no runtime id yet, as takeUp
    // left it, is so before the turn begins, and the dump read then held only the first ask: main 6a896dd6's
    // check-station (1), 43815915481)
    // (a line the fake is still writing is not one yet)
    // (its prompt in the new conversation, as it reopened: until then the one the warm process failed on is the last,
    // and the session can be seen with its new id between the two: PR #6679's check-station (5), 43859167177)
    const prompted = (words: string) => {
      try {
        return rpc(dump).some((m) => m.method === "session/prompt" && /Your earlier conversation could not be restored: this is a new one\./.test(String(m.params.prompt[0].text)) && String(m.params.prompt[0].text).includes(words));
      } catch {
        return false;
      }
    };
    await until(() => {
      const s = store.getSession(key)!;
      return prompted("make it simpler") && !s.running && s.runtimeSessionId !== null && s.runtimeSessionId !== id1;
    });
    await settle();
    const id2 = store.getSession(key)!.runtimeSessionId!;
    assert.notEqual(id2, id1);
    assert.equal(chat.texts().some((t) => t.includes("trajectory not found")), false, `unexpected error notice: ${chat.texts().join("\n")}`);
    const promptsAfterHandover = rpc(dump).filter((m) => m.method === "session/prompt").map((m) => m.params.prompt[0].text as string);
    assert.match(promptsAfterHandover.at(-1)!, /Your earlier conversation could not be restored: this is a new one\..*make it simpler/s);

    // 3. Even without a station restart, if a warm `agy` process loses its trajectory (including a corrupt `.db` file still
    //    on disk that fails `session/prompt` with `trajectory not found`), the actor ends the broken process, marks that id
    //    lost in the driver, and reopens once in a new conversation with the person's message and zero error notice.
    writeFileSync(join(agyConversations(home), `${id2}.db`), "corrupt");
    await hub.accept("cl", reply(m1, "2000.3", "<@UBOT> and shorter", { addressed: true }));
    await until(() => {
      const s = store.getSession(key)!;
      return prompted("and shorter") && !s.running && s.runtimeSessionId !== null && s.runtimeSessionId !== id2;
    });
    await settle();
    const id3 = store.getSession(key)!.runtimeSessionId!;
    assert.notEqual(id3, id2);
    assert.equal(chat.texts().some((t) => t.includes("trajectory not found")), false, `unexpected error notice: ${chat.texts().join("\n")}`);
    const promptsAfterLiveLoss = rpc(dump).filter((m) => m.method === "session/prompt").map((m) => m.params.prompt[0].text as string);
    assert.match(promptsAfterLiveLoss.at(-1)!, /Your earlier conversation could not be restored: this is a new one\..*and shorter/s);
  } finally {
    await hub.shutdown();
    await d1.shutdown();
    if (d2) await d2.shutdown();
    store.close();
  }
});

test("a warm process on a borrowed sign-in that runs out too soon for a turn is opened again on one lent anew before the turn", async () => {
  const { Hub } = await import("../src/sessions/hub.ts");
  const { InternalChat } = await import("../src/sessions/internal.ts");
  const { FakeChat, message, reply, settle } = await import("./hub-fakes.ts");
  const hubDir = mkdtempSync(join(data, "hub-agy-lent-"));
  const dump = join(hubDir, "dump");
  const home = join(hubDir, "homes", "ag");
  const raw = {
    askToName: false,
    profiles: [{ id: "ag", runtime: "agy", home, access: { kind: "api-provider", provider: "google", key: "gemini-key" }, env: { PATH: fake, FAKE_DUMP: dump } }],
    connects: [{ id: "cl", bind: { runtime: "agy" } }],
  };
  const cfg = hubConfig(raw, hubDir);
  const store = Store.open(join(hubDir, "stillfail.db"));
  const chat = new FakeChat("UBOT");
  const signIn = (minutes: number) => JSON.stringify({ token: { access_token: `a${minutes}`, expiry: new Date(Date.now() + minutes * 60_000).toISOString() }, auth_method: "consumer" });
  // Its host away at first: the process opens on the 20 minutes the sign-in has left, enough to start on.
  let hostAway = true;
  const lends: number[] = [];
  const driver = new AgyDriver({
    data: hubDir,
    lent: {
      borrowed: () => true,
      write: async (p) => {
        if (hostAway) throw new Error("host away");
        lends.push(55);
        writeFileSync(agyToken(p.home), signIn(55));
        return Date.now() + 55 * 60_000;
      },
    },
  });
  let completed = 0;
  const open = driver.open.bind(driver);
  driver.open = (options, events) => open(options, (event) => {
    if (event.type === "turnEnded") completed++;
    events(event);
  });
  mkdirSync(join(geminiDir(home), "antigravity-cli"), { recursive: true });
  writeFileSync(agyToken(home), signIn(20));
  const hub = new Hub({ config: () => cfg, store, chats: (id) => (id === "cl" ? chat : undefined), drivers: [driver], mcpUrl: "http://127.0.0.1:1/mcp", internal: new InternalChat() });
  hub.skillsLinker = async () => "";
  try {
    cfg.maxNudges = 0;
    const m1 = message({ text: "first ask" });
    await hub.accept("cl", m1);
    await until(() => completed >= 1 && store.listSessions().length === 1 && !store.listSessions()[0]!.running && store.listSessions()[0]!.runtimeSessionId !== null);
    await settle();
    const key = store.listSessions()[0]!.key;
    const id = store.getSession(key)!.runtimeSessionId!;
    const safeRpc = () => {
      try {
        return rpc(dump);
      } catch {
        return [];
      }
    };
    const opens = () => safeRpc().filter((m) => m.method === "initialize").length;
    const prompts = () => safeRpc().filter((m) => m.method === "session/prompt").map((m) => m.params.prompt[0].text as string);
    assert.equal(opens(), 1);
    assert.deepEqual(lends, []);

    // The next turn: the process's token has under AGY_LENT_RENEW_MS left, so it is ended and the conversation opened
    // again in a new process, on a sign-in lent anew, the person's words its prompt.
    hostAway = false;
    await hub.accept("cl", reply(m1, "2000.2", "<@UBOT> make it simpler", { addressed: true }));
    await until(() => completed >= 2 && !store.getSession(key)!.running && prompts().some((p) => /make it simpler/.test(p)));
    await settle();
    assert.deepEqual(lends, [55]);
    assert.equal(opens(), 2);
    assert.equal(store.getSession(key)!.runtimeSessionId, id);
    assert.equal(rpc(dump).filter((m) => m.method === "session/load").length, 1);

    // One that lasts: the same process takes the turn after.
    await hub.accept("cl", reply(m1, "2000.3", "<@UBOT> and shorter", { addressed: true }));
    await until(() => completed >= 3 && !store.getSession(key)!.running && prompts().some((p) => /and shorter/.test(p)));
    await settle();
    assert.equal(opens(), 2);
    assert.deepEqual(lends, [55]);

    // A borrowed sign-in that runs out under an in-flight turn on 1.5.8 (partial text followed by AGY_TERMINATED):
    // answered as `auth`, so `auth_retry` ends the expired process, lends anew, resumes via `session/load`, and
    // continues once with `GO_ON_AFTER_AUTH` without posting a failure notice.
    const { GO_ON_AFTER_AUTH } = await import("../src/agents/instructions.ts");
    const live = [...(driver as any).live][0];
    const postsBefore = chat.texts().length;
    const completedBefore = completed;
    await hub.accept("cl", reply(m1, "2000.4", "<@UBOT> hold-turn", { addressed: true }));
    await until(() => live.busy());
    live.signInUntil = Date.now() - 60_000;
    writeFileSync(agyToken(home), signIn(-1));
    await hub.accept("cl", reply(m1, "2000.5", "<@UBOT> expire-mid-turn", { addressed: true }));
    await until(() => completed >= completedBefore + 2 && !store.getSession(key)!.running && opens() === 3 && prompts().some((p) => p.includes(GO_ON_AFTER_AUTH)));
    await settle();
    assert.deepEqual(lends, [55, 55]);
    assert.equal(store.getSession(key)!.runtimeSessionId, id);
    assert.equal(rpc(dump).filter((m) => m.method === "session/load").length, 2);
    assert.equal(chat.texts().some((t) => t.includes("terminated due to error") || t.includes("模型服务出错") || t.includes("认证失败")), false);
    assert.equal(chat.texts().length, postsBefore + 1);

    // A long-running task crossing a SECOND hourly borrowed-token expiry inside an `auth_retry` turn:
    // Turn 1 expires -> `auth_retry` opens process #4 -> after running past AGY_LENT_MIN_RUN_MS its borrowed token
    // also expires (`⚠ UNAUTHENTICATED (code 401):`) -> reopens process #5 on a newly lent token instead of failing.
    const live2 = [...(driver as any).live][0];
    const postsBeforeLong = chat.texts().length;
    const completedBeforeLong = completed;
    writeFileSync(dump + ".hold-auth-retry", "1");
    await hub.accept("cl", reply(m1, "2000.6", "<@UBOT> hold-turn", { addressed: true }));
    await until(() => live2.busy());
    live2.signInOpenedAt = Date.now() - 55 * 60_000;
    live2.signInUntil = Date.now() - 60_000;
    writeFileSync(agyToken(home), signIn(-1));
    await hub.accept("cl", reply(m1, "2000.7", "<@UBOT> unauth-mid-turn", { addressed: true }));
    // The fake consumes the marker once it holds the `auth_retry` prompt; `busy()` alone is set before it reads it.
    await until(() => opens() === 4 && !existsSync(dump + ".hold-auth-retry") && [...(driver as any).live].some((s) => s !== live2 && s.busy()));
    const live3 = [...(driver as any).live].find((s) => s !== live2)!;
    // Simulate the `auth_retry` turn running for 55 min until its newly lent token also expires.
    live3.signInOpenedAt = Date.now() - 55 * 60_000;
    live3.signInUntil = Date.now() - 60_000;
    writeFileSync(agyToken(home), signIn(-1));
    await hub.accept("cl", reply(m1, "2000.8", "<@UBOT> unauth-mid-turn", { addressed: true }));
    // (`running` is false between process #4's end and process #5's `begin_turn`, `opens()` 5 already: the turns
    // ended are what says process #5's has run)
    await until(() => completed >= completedBeforeLong + 3 && !store.getSession(key)!.running && opens() === 5);
    await settle();
    assert.deepEqual(lends, [55, 55, 55, 55]);
    assert.equal(store.getSession(key)!.runtimeSessionId, id);
    assert.equal(rpc(dump).filter((m) => m.method === "session/load").length, 4);
    assert.equal(chat.texts().some((t) => t.includes("UNAUTHENTICATED") || t.includes("认证失败") || t.includes("Sign-in failed")), false);
    assert.equal(chat.texts().length, postsBeforeLong + 1);

    // Negative guard: if an `auth_retry` turn fails with 401 right after reopening (before its fresh borrowed token
    // expires / before AGY_LENT_MIN_RUN_MS), it does NOT loop — it stops and posts the auth failure notice.
    const live4 = [...(driver as any).live][0];
    writeFileSync(dump + ".hold-auth-retry", "1");
    await hub.accept("cl", reply(m1, "2000.9", "<@UBOT> hold-turn", { addressed: true }));
    await until(() => live4.busy());
    live4.signInOpenedAt = Date.now() - 55 * 60_000;
    live4.signInUntil = Date.now() - 60_000;
    writeFileSync(agyToken(home), signIn(-1));
    await hub.accept("cl", reply(m1, "2000.10", "<@UBOT> unauth-mid-turn", { addressed: true }));
    await until(() => opens() === 6 && !existsSync(dump + ".hold-auth-retry") && [...(driver as any).live].some((s) => s !== live4 && s.busy()));
    // Do NOT expire live5's fresh token: an immediate 401 must stop instead of retrying again.
    await hub.accept("cl", reply(m1, "2000.11", "<@UBOT> unauth-mid-turn", { addressed: true }));
    await until(() => !store.getSession(key)!.running && chat.texts().some((t) => t.includes("UNAUTHENTICATED")));
    await settle();
    assert.equal(opens(), 6);
    assert.deepEqual(lends, [55, 55, 55, 55, 55]);
  } finally {
    await hub.shutdown();
    await driver.shutdown();
    store.close();
  }
});

test("which profiles run it, and none of the machine's Google accounts", (t) => {
  const { options } = setup();
  assert.deepEqual(accessKinds("agy"), ["subscription", "api-provider", "env"]);
  assert.ok(profileRuntimes({ id: "g", runtime: "dsh", home: "", access: { kind: "api-provider", provider: "google", key: "k" } }).includes("agy"));
  assert.ok(!profileRuntimes({ id: "x", runtime: "dsh", home: "", access: { kind: "api-provider", provider: "xai", key: "k" } }).includes("agy"));
  assert.ok(CHAT_CREATE.inputSchema.properties.runtime.enum.includes("agy"));
  const saved = { GEMINI_API_KEY: process.env.GEMINI_API_KEY, GOOGLE_APPLICATION_CREDENTIALS: process.env.GOOGLE_APPLICATION_CREDENTIALS };
  process.env.GEMINI_API_KEY = "machine-key";
  process.env.GOOGLE_APPLICATION_CREDENTIALS = "/machine/adc.json";
  t.after(() => {
    for (const [k, v] of Object.entries(saved)) if (v === undefined) delete process.env[k]; else process.env[k] = v;
  });
  const env = agyEnv(options);
  assert.equal(env.GEMINI_API_KEY, "gemini-key");
  assert.equal(env.ANTIGRAVITY_GEMINI_DIR, geminiDir(options.profile.home));
  assert.equal(env.GOOGLE_APPLICATION_CREDENTIALS, undefined);
  const own = agyEnv({ ...options, profile: { ...options.profile, access: { kind: "env" }, env: {} } });
  assert.equal(own.GEMINI_API_KEY, undefined);
});

test("a Google account: signed in in its terminal interface (the way chosen, Google's page relayed, the code pasted back), in the profile's files; then checked, and its sessions run on it", { skip: process.platform === "win32" && "no terminal to sign in in" }, async () => {
  const home = join(data, "google");
  const dump = join(data, "google-dump");
  const env = { ...process.env, PATH: fake, FAKE_DUMP: dump, GEMINI_API_KEY: "machine-key", SSH_CONNECTION: "10.0.0.1 22 10.0.0.2 22" } as Record<string, string>;
  const logins = new LoginManager(data, { claude: "claude", codex: "codex", agy: "agy" }, () => env);
  const wait = async (state: LoginState) => until(() => logins.get("g")?.state === state);
  const check = () => checkProfile({ runtime: "agy", kind: "subscription", key: "", via: {}, home, env, machine: false, lang: "en" });
  try {
    assert.equal((await check()).state, "login");
    await logins.start({ id: "g", runtime: "agy", home }, "en");
    await wait("needs_code");
    assert.match(logins.get("g")!.url ?? "", /^https:\/\/accounts\.google\.com\/o\/oauth2\/auth\?.*redirect_uri=https%3A%2F%2Fantigravity\.google%2Foauth-callback/);
    const run = JSON.parse(readFileSync(dump, "utf8").trim().split("\n").at(-1)!);
    // Its HOME an empty directory of its own (its sign-in copied into the profile's agy/ once done), its sign-in kept in a
    // file there (AGY_FILE_TOKENS), its question to the terminal answered; none of the machine's keys.
    assert.deepEqual([run.args, run.home, run.remote, run.key, run.fileTokens], [[], join(data, "run", "agy-login", "g-1"), null, null, AGY_FILE_TOKENS.SSH_CLIENT]);
    assert.match(readFileSync(dump + ".terminal", "utf8"), /\\u001b\[\?1;2c/);
    await logins.submitCode("g", " 4/0Ab-code ", "en");
    await wait("done");
    assert.equal(JSON.parse(readFileSync(agyToken(home), "utf8")).token.access_token, "ya29.4/0Ab-code");
    assert.equal(JSON.parse(readFileSync(agyAccountFile(home), "utf8")).email, "someone@gmail.com");
    assert.equal(agyToken(home), join(geminiDir(home), "antigravity-cli", "antigravity-oauth-token"));
    const signedIn = await check();
    assert.equal(signedIn.state, "ok");
    assert.match(signedIn.detail ?? "", /someone@gmail\.com/);
  } finally {
    await logins.close();
  }
  // A subscription profile's sessions are given no key: the sign-in in its files is what they run on.
  const { options, driver } = setup();
  const signed = { ...options, profile: { ...options.profile, home, access: { kind: "subscription" } } };
  assert.equal(agyEnv(signed).GEMINI_API_KEY, undefined);
  const s = await driver.open(signed, () => {});
  await s.dispose();
});

test("a company's Google account: signed in by Google Cloud's way, its licence chosen, not done on its first file with only a token", { skip: process.platform === "win32" && "no terminal to sign in in" }, async () => {
  const home = join(data, "company");
  const dump = join(data, "company-dump");
  const env = { ...process.env, PATH: fake, FAKE_DUMP: dump, FAKE_AGY_LICENSES: "1" } as Record<string, string>;
  const logins = new LoginManager(data, { claude: "claude", codex: "codex", agy: "agy" }, () => env);
  const wait = async (state: LoginState) => until(() => logins.get("c")?.state === state);
  try {
    await logins.start({ id: "c", runtime: "agy", home, enterprise: true }, "en");
    await wait("needs_code");
    assert.match(logins.get("c")!.url ?? "", /^https:\/\/accounts\.google\.com\/o\/oauth2\/auth\?/);
    await logins.submitCode("c", "4/0Ab-company", "en");
    await wait("done");
    // Its second way (the arrow down, then Enter), Continue with Google Cloud, the code, then its licence.
    const keys = readFileSync(dump + ".keys", "utf8").trim().split("\n").map((l) => JSON.parse(l));
    assert.deepEqual(keys.map((k) => [k.step, k.down]), [["menu", true], ["cloud", false], ["gcp-code", false], ["license", false]]);
    // Done only once the licence was written: the sign-in stopped on the file with only its token would be signed out.
    const file = JSON.parse(readFileSync(agyToken(home), "utf8"));
    assert.deepEqual([file.project_id, file.user_tier, file.auth_method], ["company-project", "gcp-ge-ultra-tier", "gcp"]);
    assert.equal(JSON.parse(readFileSync(agyAccountFile(home), "utf8")).email, "someone@company.com");
    const checked = await checkProfile({ runtime: "agy", kind: "subscription", key: "", via: {}, home, env, machine: false, lang: "en" });
    assert.deepEqual([checked.state, checked.plan], ["ok", "Enterprise Ultra"]);
    // A file with only its token (the licence never chosen) is signed out, as `agy` takes it.
    writeFileSync(agyToken(home), JSON.stringify({ token: { access_token: "ya29.x" }, auth_method: "gcp", id_token_email: "someone@company.com" }));
    assert.equal((await checkProfile({ runtime: "agy", kind: "subscription", key: "", via: {}, home, env, machine: false, lang: "en" })).state, "login");
  } finally {
    await logins.close();
  }
});

test("a company's Google account with no licence: Pay As You Go chosen, its Google Cloud project asked of the person; one refused ends the sign-in saying why", { skip: process.platform === "win32" && "no terminal to sign in in" }, async () => {
  const home = join(data, "paygo");
  const dump = join(data, "paygo-dump");
  const env = { ...process.env, PATH: fake, FAKE_DUMP: dump } as Record<string, string>;
  const logins = new LoginManager(data, { claude: "claude", codex: "codex", agy: "agy" }, () => env);
  const wait = async (state: LoginState) => until(() => logins.get("p")?.state === state);
  try {
    await logins.start({ id: "p", runtime: "agy", home, enterprise: true }, "en");
    await wait("needs_code");
    await logins.submitCode("p", "4/0Ab-paygo", "en");
    await wait("needs_project");
    await assert.rejects(logins.submitCode("p", "  ", "en"), new RegExp(tr("en", "station.login.emptyCode")));
    await logins.submitCode("p", "bad-project", "en");
    await wait("failed");
    assert.match(logins.get("p")!.error ?? "", /Permission denied on project bad-project/);

    await logins.start({ id: "p", runtime: "agy", home, enterprise: true }, "en");
    await wait("needs_code");
    await logins.submitCode("p", "4/0Ab-paygo", "en");
    await wait("needs_project");
    await logins.submitCode("p", " my-project ", "en");
    await wait("done");
    const file = JSON.parse(readFileSync(agyToken(home), "utf8"));
    assert.deepEqual([file.project_id, file.auth_method, file.token.access_token], ["my-project", "gcp", "ya29.4/0Ab-paygo"]);
    const keys = readFileSync(dump + ".keys", "utf8").trim().split("\n").map((l) => JSON.parse(l));
    assert.deepEqual(keys.slice(-4).map((k) => [k.step, k.down]), [["cloud", false], ["gcp-code", false], ["billing", true], ["project", false]]);
    // A company's account on no tier is Enterprise.
    const checked = await checkProfile({ runtime: "agy", kind: "subscription", key: "", via: {}, home, env, machine: false, lang: "en" });
    assert.deepEqual([checked.state, checked.plan], ["ok", "Enterprise"]);
  } finally {
    await logins.close();
  }
});

test("a company's Google account through the accounts: made a profile that remembers it, signed in again the same way; its plan as `agy` says it", { skip: process.platform === "win32" && "no terminal to sign in in" }, async (t) => {
  const dir = join(data, "company-accounts");
  mkdirSync(dir, { recursive: true });
  const dump = join(dir, "dump");
  const saved = { PATH: process.env.PATH, FAKE_DUMP: process.env.FAKE_DUMP, FAKE_AGY_LICENSES: process.env.FAKE_AGY_LICENSES };
  Object.assign(process.env, { PATH: fake, FAKE_DUMP: dump, FAKE_AGY_LICENSES: "1" });
  t.after(() => {
    for (const [k, v] of Object.entries(saved)) if (v === undefined) delete process.env[k]; else process.env[k] = v;
  });
  const store = Store.open(":memory:", null);
  const config = new ConfigFile(dir);
  let plan: string | undefined = "Enterprise Plus";
  const accounts = new Accounts({
    data: dir,
    store,
    config,
    machine: null,
    checkOnStart: false,
    loginCommands: { claude: "claude", codex: "codex", agy: "agy" },
    check: (req, lang) => checkProfile({ ...req, env: {}, machine: false, lang }),
    quota: async () => ({ state: "ok", windows: [], detail: null, checkedAt: 0 }),
    agy: () => ({ models: async () => ["gemini-3.5-flash"], catalog: async () => ({ models: ["gemini-3.5-flash"], efforts: {}, defaults: {}, ...(plan !== undefined ? { plan } : {}) }) }),
  });
  const viewer = { email: "owner@company.com" } as never;
  accounts.start();
  try {
    const { id } = await accounts.newLogin({ access: "agy-enterprise" }, viewer, "en");
    await until(() => accounts.logins.get(id)?.state === "needs_code");
    await accounts.logins.submitCode(id, "4/0Ab-made", "en");
    await until(() => (config.raw().profiles ?? []).length === 1);
    const made = config.raw().profiles[0];
    assert.deepEqual([made.runtime, made.access, made.name], ["agy", { kind: "subscription", enterprise: true }, "someone@company.com"]);
    // Its plan: as `agy` said it; where it says none, its sign-in's.
    assert.equal((await accounts.check(made.id, "en")).plan, "Enterprise Plus");
    plan = undefined;
    assert.equal((await accounts.check(made.id, "en")).plan, "Enterprise Ultra");
    // Signed in again: Google Cloud's way, without being told.
    await accounts.startLogin(made.id, viewer, "en");
    await until(() => accounts.logins.get(made.id)?.state === "needs_code");
    const keys = readFileSync(dump + ".keys", "utf8").trim().split("\n").map((l) => JSON.parse(l));
    assert.deepEqual(keys.slice(-2).map((k) => [k.step, k.down]), [["menu", true], ["cloud", false]]);
    accounts.logins.cancel(made.id);
  } finally {
    await accounts.close();
    store.close();
  }
});

/// A sign-in as `agy` keeps it, in a profile's agy/ (as a sign-in before left it).
const signedInBefore = (home: string, fields: Record<string, unknown>) => {
  mkdirSync(join(geminiDir(home), "antigravity-cli"), { recursive: true });
  writeFileSync(agyToken(home), JSON.stringify(fields));
};

test("signed in again over a sign-in there is (a person's and a company's): `agy` runs in an empty HOME of its own, so it asks how to sign in; the new sign-in replaces the old once done, and the empty HOME goes", { skip: process.platform === "win32" && "no terminal to sign in in" }, async () => {
  for (const enterprise of [false, true]) {
    const home = join(data, `again-${enterprise}`);
    const dump = join(data, `again-${enterprise}-dump`);
    const env = { ...process.env, PATH: fake, FAKE_DUMP: dump, ...(enterprise ? { FAKE_AGY_LICENSES: "1" } : {}) } as Record<string, string>;
    signedInBefore(home, { token: { access_token: "ya29.old", token_type: "Bearer" }, auth_method: enterprise ? "gcp" : "oauth", id_token_email: "before@x.test", ...(enterprise ? { project_id: "old-project" } : {}) });
    const logins = new LoginManager(data, { claude: "claude", codex: "codex", agy: "agy" }, () => env);
    const wait = async (state: LoginState) => until(() => logins.get("a")?.state === state);
    try {
      await logins.start({ id: "a", runtime: "agy", home, ...(enterprise ? { enterprise } : {}) }, "en");
      await wait("needs_code");
      const run = JSON.parse(readFileSync(dump, "utf8").trim().split("\n").at(-1)!);
      assert.equal(run.fileTokens, AGY_FILE_TOKENS.SSH_CLIENT);
      assert.ok(run.home.startsWith(join(data, "run", "agy-login")), run.home);
      // The old one untouched while the new is under way.
      assert.equal(JSON.parse(readFileSync(agyToken(home), "utf8")).token.access_token, "ya29.old");
      await logins.submitCode("a", "4/0Ab-again", "en");
      await wait("done");
      const file = JSON.parse(readFileSync(agyToken(home), "utf8"));
      assert.equal(file.token.access_token, "ya29.4/0Ab-again");
      if (enterprise) assert.deepEqual([file.project_id, file.user_tier], ["company-project", "gcp-ge-ultra-tier"]);
      assert.equal(JSON.parse(readFileSync(agyAccountFile(home), "utf8")).email, enterprise ? "someone@company.com" : "someone@gmail.com");
      await until(() => !existsSync(run.home));
    } finally {
      await logins.close();
    }
  }
});

test("a sign-in again given up or failed leaves the sign-in there as it was", { skip: process.platform === "win32" && "no terminal to sign in in" }, async () => {
  const home = join(data, "kept");
  const env = { ...process.env, PATH: fake, FAKE_DUMP: join(data, "kept-dump") } as Record<string, string>;
  const before = { token: { access_token: "ya29.kept", token_type: "Bearer", refresh_token: "r" }, auth_method: "gcp", id_token_email: "before@company.test", project_id: "kept-project", region: "global" };
  signedInBefore(home, before);
  const logins = new LoginManager(data, { claude: "claude", codex: "codex", agy: "agy" }, () => env);
  const wait = async (state: LoginState) => until(() => logins.get("k")?.state === state);
  try {
    // Given up once its code went in (its file in its HOME written with only its token).
    await logins.start({ id: "k", runtime: "agy", home, enterprise: true }, "en");
    await wait("needs_code");
    await logins.submitCode("k", "4/0Ab-dropped", "en");
    await wait("needs_project");
    logins.cancel("k");
    assert.deepEqual(JSON.parse(readFileSync(agyToken(home), "utf8")), before);
    // Failed: its project refused.
    await logins.start({ id: "k", runtime: "agy", home, enterprise: true }, "en");
    await wait("needs_code");
    await logins.submitCode("k", "4/0Ab-refused", "en");
    await wait("needs_project");
    await logins.submitCode("k", "bad-project", "en");
    await wait("failed");
    assert.deepEqual(JSON.parse(readFileSync(agyToken(home), "utf8")), before);
    await until(() => !existsSync(join(data, "run", "agy-login", "k-1")) && !existsSync(join(data, "run", "agy-login", "k-2")));
  } finally {
    await logins.close();
  }
});

test("an Antigravity CLI account signed in again: its sessions' processes start again and its copies are told; a borrowed one's, once its host's new sign-in is lent", { skip: process.platform === "win32" && "no terminal to sign in in" }, async (t) => {
  const dir = join(data, "again-accounts");
  mkdirSync(dir, { recursive: true });
  const saved = { PATH: process.env.PATH, FAKE_DUMP: process.env.FAKE_DUMP };
  Object.assign(process.env, { PATH: fake, FAKE_DUMP: join(dir, "dump") });
  t.after(() => {
    for (const [k, v] of Object.entries(saved)) if (v === undefined) delete process.env[k]; else process.env[k] = v;
  });
  const borrowedCopy = { id: "sh-0123456789abcdef0123", name: "Google AI Pro", runtime: "agy", access: { kind: "subscription" }, home: "homes/sh-0123456789abcdef0123", env: {}, share: { id: "sh-0123456789abcdef0123", borrowed: true, host: "host-station" } };
  writeFileSync(join(dir, "config.json"), JSON.stringify({ profiles: [{ id: "gem", name: "Google AI Pro", runtime: "agy", access: { kind: "subscription" }, home: "homes/gem", env: {} }, borrowedCopy] }));
  signedInBefore(join(dir, "homes", "gem"), { token: { access_token: "ya29.old", token_type: "Bearer" }, auth_method: "oauth", id_token_email: "someone@gmail.com" });
  const store = Store.open(":memory:", null);
  const config = new ConfigFile(dir);
  const steps: string[] = [];
  const accounts = new Accounts({
    data: dir,
    store,
    config,
    machine: null,
    checkOnStart: false,
    loginCommands: { claude: "claude", codex: "codex", agy: "agy" },
    check: async () => ({ state: "ok", detail: "", models: ["gemini-3.5-flash"], checkedAt: 1 }),
    quota: async () => ({ state: "ok", windows: [], detail: null, checkedAt: 0 }),
    hub: { accounts: { setHealth() {}, healthOf: () => ({}) as never }, profileLoginChanged: (id) => void steps.push(`restart ${id}`) },
    shared: {
      status: async () => ({ check: { state: "ok", detail: "", models: null, checkedAt: 1 }, quota: null }),
      view: () => null,
      loginUpdated: (id) => void steps.push(`told ${id ?? ""}`),
      lendAgy: async (p) => (steps.push(`lent ${p.id}`), Date.now() + 3600_000),
    },
  });
  const viewer = { email: "owner@x.test" } as never;
  accounts.start();
  try {
    await accounts.startLogin("gem", viewer, "en");
    await until(() => accounts.logins.get("gem")?.state === "needs_code");
    await accounts.logins.submitCode("gem", "4/0Ab-new", "en");
    await until(() => steps.includes("restart gem"));
    assert.deepEqual(steps, ["told gem", "restart gem"]);
    assert.equal(JSON.parse(readFileSync(agyToken(join(dir, "homes", "gem")), "utf8")).token.access_token, "ya29.4/0Ab-new");
    // A copy whose host signed in again: what it lends now written first, then its sessions' processes start again.
    steps.length = 0;
    await accounts.sharedChanged(borrowedCopy.id, false);
    assert.deepEqual(steps, [`lent ${borrowedCopy.id}`, `restart ${borrowedCopy.id}`]);
  } finally {
    await accounts.close();
    store.close();
  }
});

test("a Google sign-in done in the station's browser: its code read off the page Google comes back to, its tab closed, nothing to paste; another sign-in's page left alone", { skip: process.platform === "win32" && "no terminal to sign in in" }, async () => {
  const home = join(data, "in-station");
  const env = { ...process.env, PATH: fake, FAKE_AGY_LICENSES: "1" } as Record<string, string>;
  const logins = new LoginManager(data, { claude: "claude", codex: "codex", agy: "agy" }, () => env);
  const b = fakeBrowser();
  logins.attach(b.pages);
  const wait = async (state: LoginState) => until(() => logins.get("s")?.state === state);
  try {
    await logins.start({ id: "s", runtime: "agy", home, enterprise: true }, "en");
    await wait("needs_code");
    assert.equal(logins.get("s")!.browser, true);
    await logins.openPage("s", "en");
    const [tab] = [...b.tabs.keys()];
    const state = new URL(logins.get("s")!.url!).searchParams.get("state");
    // Another sign-in's page (its state not this one's): nothing taken.
    b.went(tab!, "https://antigravity.google/oauth-callback?code=4%2F0Ab-other&state=someone-else");
    assert.equal(logins.get("s")!.state, "needs_code");
    assert.ok(b.tabs.has(tab!));
    // This one's: its code sent, its tab closed, and on through its licence to done.
    b.went(tab!, `https://antigravity.google/oauth-callback?code=4%2F0Ab-station&state=${state}`);
    assert.equal(logins.get("s")!.state, "verifying");
    assert.ok(!b.tabs.has(tab!), "its tab closed");
    await wait("done");
    const file = JSON.parse(readFileSync(agyToken(home), "utf8"));
    assert.deepEqual([file.token.access_token, file.project_id], ["ya29.4/0Ab-station", "company-project"]);
  } finally {
    await logins.close();
  }
  assert.equal(agyCallbackCode("https://antigravity.google/oauth-callback/?code=c&state=s", "https://accounts.google.com/o/oauth2/auth?state=s"), "c");
  assert.equal(agyCallbackCode("https://antigravity.google/oauth-callback?state=s", "https://accounts.google.com/o/oauth2/auth?state=s"), null);
  assert.equal(agyCallbackCode("https://evil.example/oauth-callback?code=c&state=s", "https://accounts.google.com/o/oauth2/auth?state=s"), null);
  assert.equal(agyCallbackCode("https://antigravity.google/oauth-callback?code=c&state=t", "https://accounts.google.com/o/oauth2/auth?state=s"), null);
  assert.equal(agyCallbackCode(null, null), null);
});

test("a company's sign-in that `agy` refuses after its code ends at once saying why, without its `[Auth Error]`", { skip: process.platform === "win32" && "no terminal to sign in in" }, async () => {
  const home = join(data, "auth-error");
  const env = { ...process.env, PATH: fake, FAKE_AGY_LICENSES: "1", FAKE_AGY_AUTH_ERROR: "1" } as Record<string, string>;
  const logins = new LoginManager(data, { claude: "claude", codex: "codex", agy: "agy" }, () => env);
  try {
    await logins.start({ id: "e", runtime: "agy", home, enterprise: true }, "en");
    await until(() => logins.get("e")?.state === "needs_code");
    await logins.submitCode("e", "4/0Ab-x", "en");
    await until(() => logins.get("e")?.state === "failed");
    assert.equal(logins.get("e")!.error, tr("en", "station.login.agyFailed", { error: "Failed to select license: 403 PERMISSION_DENIED" }));
  } finally {
    await logins.close();
  }
});

test("a Google account's tier, as people know its plan; a sign-in's file whole only with a company's licence or project; renewed and lent with what it holds", async () => {
  const plans = [
    ["free-tier", "Free"],
    ["g1-plus-tier", "Plus"],
    ["g1-pro-tier", "Pro"],
    ["g1-ultra-lite-tier", "Ultra 5x"],
    ["g1-ultra-tier", "Ultra 20x"],
    ["gcp-ge-standard-tier", "Enterprise"],
    ["gcp-ge-plus-tier", "Enterprise Plus"],
    ["gcp-ge-ultra-tier", "Enterprise Ultra"],
    ["gcp-standard-tier", "Enterprise"],
    ["gcp-other-tier", "Enterprise"],
    ["", null],
    ["unknown", null],
  ] as const;
  for (const [id, plan] of plans) assert.equal(agyPlan({ id }), plan, id);
  assert.equal(agyPlan(null, true), "Enterprise");
  const sessionPlan = (tier: { id?: string; name?: string }) => agySessionPlan({ _meta: { antigravity: { tier } } });
  assert.equal(sessionPlan({ id: " G1-ULTRA-LITE-TIER ", name: "Google AI Ultra" }), "Ultra 5x");
  assert.equal(sessionPlan({ id: "g1-ultra-tier", name: "Google AI Ultra" }), "Ultra 20x");
  assert.equal(sessionPlan({ id: "future-tier", name: " Google AI Future " }), "Google AI Future");
  assert.equal(sessionPlan({ name: "Google AI Pro Trial" }), "Google AI Pro Trial");
  assert.equal(sessionPlan({ id: "constructor", name: "Unknown" }), null);
  assert.equal(agySessionPlan({ sessionId: "s" }), null);
  assert.equal(agyPlanIn('{"auth_method":"consumer","tier_display_name":"Google AI Pro Trial"}'), "Google AI Pro Trial");
  assert.equal(agyPlanIn('{"auth_method":"gcp","user_tier":"gcp-future-tier","tier_display_name":"Pay As You Go"}'), "Pay As You Go");
  const token = { access_token: "ya29.x" };
  assert.equal(agyTokenReady(JSON.stringify({ token, auth_method: "consumer" }), false), true);
  assert.equal(agyTokenReady(JSON.stringify({ token, auth_method: "oauth" }), false), true);
  assert.equal(agyTokenReady(JSON.stringify({ token, auth_method: "gcp" }), false), false);
  assert.equal(agyTokenReady(JSON.stringify({ token, auth_method: "gcp", project_id: "p" }), false), true);
  assert.equal(agyTokenReady(JSON.stringify({ token, auth_method: "gcp", user_tier: "gcp-ge-ultra-tier" }), true), true);
  assert.equal(agyTokenReady(JSON.stringify({ token }), true), false);
  assert.equal(agyTokenReady(JSON.stringify({ token: { access_token: "" }, project_id: "p" }), false), false);
  assert.equal(agyTokenReady("not json", false), false);
  // Lent: the rest of the host's file kept, never its refresh token; a host from before lends none of it.
  const stored = { auth_method: "gcp", id_token_email: "a@company.com", project_id: "p", region: "us-central1", user_tier: "gcp-ge-ultra-tier", tier_display_name: "Gemini Enterprise Ultra", wif_provider: "w" };
  const lent = JSON.parse(agyLentFile({ token: { access_token: "a", refresh_token: "r" }, email: "a@company.com", auth_method: "gcp", stored }));
  assert.deepEqual(lent, { ...stored, token: { access_token: "a" } });
  assert.deepEqual(JSON.parse(agyLentFile({ token: { access_token: "a", refresh_token: "r" }, email: null, auth_method: null })), { token: { access_token: "a" }, auth_method: "consumer" });
  // Renewed by `agy models`, which writes back its token alone: the company's project and tier kept.
  const home = join(data, "renew-company");
  mkdirSync(join(geminiDir(home), "antigravity-cli"), { recursive: true });
  writeFileSync(agyToken(home), JSON.stringify({ ...stored, token: { access_token: "old", refresh_token: "r", expiry: "2020-01-01T00:00:00Z" } }));
  await agyRenew(home, join(fileURLToPath(new URL("./fake", import.meta.url)), "agy"));
  const renewed = JSON.parse(readFileSync(agyToken(home), "utf8"));
  assert.deepEqual([renewed.token.access_token, renewed.token.refresh_token, renewed.project_id, renewed.region, renewed.user_tier, renewed.tier_display_name], ["renewed", "r", "p", "us-central1", "gcp-ge-ultra-tier", "Gemini Enterprise Ultra"]);
});

test("a Google account's sign-in: refused at once where there is no terminal; without a sign-in its allowance says signed out; its login command", async () => {
  const terminal = platform.terminalSoon;
  platform.terminalSoon = async () => null;
  const logins = new LoginManager(data, { claude: "claude", codex: "codex", agy: "agy" });
  try {
    const job = await logins.start({ id: "nt", runtime: "agy", home: join(data, "no-terminal") }, "en");
    assert.deepEqual([job.state, job.error], ["failed", tr("en", "station.login.agyNoTerminal")]);
  } finally {
    platform.terminalSoon = terminal;
    await logins.close();
  }
  const q = await checkQuota({ id: "p", runtime: "agy", home: join(data, "no-signin"), access: { kind: "subscription" } } as never, {}, undefined, undefined, "en");
  assert.deepEqual([q.state, q.detail], ["unavailable", tr("en", "station.quota.signInExpired")]);
  assert.equal(loginCommand("agy", "/h"), `SSH_CLIENT='${AGY_FILE_TOKENS.SSH_CLIENT}' HOME=/h/agy agy`);
});

test("an Antigravity CLI account's Gemini and Claude / GPT windows weigh only on their own models in the pool", () => {
  const cfg = hubConfig(
    {
      profiles: [
        { id: "ag1", name: "AG1", runtime: "agy", home: "/h1", access: { kind: "subscription" }, model: "gemini-4-carbon-medium", models: ["gemini-4-carbon-medium", "claude-opus-5-5-medium"] },
        { id: "ag2", name: "AG2", runtime: "agy", home: "/h2", access: { kind: "subscription" }, model: "gemini-4-carbon-medium", models: ["gemini-4-carbon-medium", "claude-opus-5-5-medium"] },
      ],
    },
    "/x",
  );
  const sessions = new Map<string, any>([
    ["s-gemini", { key: "s-gemini", runtime: "agy", profile: "ag1", profilePinned: false, model: "gemini-4-carbon-medium", effort: null }],
    ["s-claude", { key: "s-claude", runtime: "agy", profile: "ag1", profilePinned: false, model: "claude-opus-5-5-medium", effort: null }],
  ]);
  const pool = new SessionAccounts({
    config: () => cfg,
    store: {
      getSession: (k: string) => sessions.get(k),
      setSessionProfile: (k: string, id: string, pinned: boolean) => {
        const s = sessions.get(k);
        if (s) {
          s.profile = id;
          s.profilePinned = pinned;
        }
      },
      lastTurn: () => ({ endedAt: 1000 }),
      recentlyCompacted: () => false,
      compactionsReady: () => false,
      lastContexts: () => [],
      compactionPoints: () => new Map(),
    } as never,
    running: () => [],
    clock: { currentTimeMillisUnsafe: () => 2000 } as never,
  });
  const ag1Quota = {
    state: "ok",
    checkedAt: 1500,
    windows: [
      { label: "5 小时 · Gemini", usedPercent: 15, resetsAt: 5000, scope: "gemini" },
      { label: "每周 · Gemini", usedPercent: 25, resetsAt: 9000, scope: "gemini" },
      { label: "5 小时 · Claude / GPT", usedPercent: 100, resetsAt: 6000, scope: "3p" },
      { label: "每周 · Claude / GPT", usedPercent: 40, resetsAt: 9000, scope: "3p" },
    ],
  };
  const ag2Quota = {
    state: "ok",
    checkedAt: 1500,
    windows: [
      { label: "5 小时 · Gemini", usedPercent: 100, resetsAt: 7000, scope: "gemini" },
      { label: "每周 · Gemini", usedPercent: 100, resetsAt: 8000, scope: "gemini" },
      { label: "5 小时 · Claude / GPT", usedPercent: 100, resetsAt: 8500, scope: "3p" },
      { label: "每周 · Claude / GPT", usedPercent: 50, resetsAt: 9000, scope: "3p" },
    ],
  };
  pool.setHealth((id) => ({
    check: { state: "ok", detail: "ok", models: ["gemini-4-carbon-medium", "claude-opus-5-5-medium"], checkedAt: 1500 },
    quota: id === "ag1" ? ag1Quota : ag2Quota,
  }));
  // Gemini on ag1 is still healthy even though ag1's Claude / GPT 5h window is at 100%.
  assert.equal(pool.runOn("s-gemini").id, "ag1");
  // Claude on ag1 sees only the 3P window (refills at 6000), while ag2's 3P window is also full (8500): stays on ag1 and refills at 6000.
  assert.equal(pool.refillsAt("s-claude"), 6000);

  // On a Pro account whose separate Argon weekly cap (`scoped`) is used up, Argon sessions move off it while Hydrogen
  // and Flash sessions on the same account remain healthy under the main Gemini pool.
  sessions.set("s-argon", { key: "s-argon", runtime: "agy", profile: "ag1", profilePinned: false, model: "gemini-4-argon-medium", effort: null });
  sessions.set("s-hydrogen", { key: "s-hydrogen", runtime: "agy", profile: "ag1", profilePinned: false, model: "gemini-4-hydrogen-medium", effort: null });
  pool.setHealth((id) => ({
    check: { state: "ok", detail: "ok", models: ["gemini-4-argon-medium", "gemini-4-hydrogen-medium", "claude-opus-5-5-medium"], checkedAt: 1500 },
    quota:
      id === "ag1"
        ? { ...ag1Quota, scoped: [{ label: "每周 · Argon", usedPercent: 100, resetsAt: 9500, scope: "Argon" }] }
        : {
            state: "ok",
            checkedAt: 1500,
            windows: [
              { label: "5 小时 · Gemini", usedPercent: 10, resetsAt: 7000, scope: "gemini" },
              { label: "每周 · Gemini", usedPercent: 20, resetsAt: 8000, scope: "gemini" },
              { label: "5 小时 · Claude / GPT", usedPercent: 10, resetsAt: 8500, scope: "3p" },
              { label: "每周 · Claude / GPT", usedPercent: 10, resetsAt: 9000, scope: "3p" },
            ],
          },
  }));
  assert.equal(pool.runOn("s-argon").id, "ag2");
  assert.equal(pool.runOn("s-hydrogen").id, "ag1");
});

/// An Antigravity CLI pool of two accounts over sessions kept in memory, on a clock the test moves.
function agyPool(models: string[]) {
  const cfg = hubConfig(
    {
      profiles: ["ag1", "ag2"].map((id) => ({ id, name: id.toUpperCase(), runtime: "agy", home: `/${id}`, access: { kind: "subscription" }, model: models[0], models })),
    },
    "/x",
  );
  const sessions = new Map<string, any>();
  const t = { now: 2000, compacted: false };
  const pool = new SessionAccounts({
    config: () => cfg,
    store: {
      getSession: (k: string) => sessions.get(k),
      setSessionProfile: (k: string, id: string, pinned: boolean) => {
        const s = sessions.get(k);
        if (s) {
          s.profile = id;
          s.profilePinned = pinned;
        }
      },
      lastTurn: () => ({ endedAt: 1000 }),
      recentlyCompacted: () => t.compacted,
      compactionsReady: () => false,
      lastContexts: () => [],
      compactionPoints: () => new Map(),
    } as never,
    running: () => [],
    clock: { currentTimeMillisUnsafe: () => t.now } as never,
  });
  const session = (key: string, model: string, profile = "ag1") => sessions.set(key, { key, runtime: "agy", profile, profilePinned: false, model, effort: null });
  return { pool, sessions, t, session, at: (key: string) => sessions.get(key).profile as string };
}

test("an Antigravity CLI limit that names no model passes over its model's group on the account, a Pro account's own Argon week only Argon; a reset or a newer read lets them run again", () => {
  const models = ["gemini-4-carbon-medium", "gemini-4-argon-medium", "gemini-4-hydrogen-medium", "gemini-4-flash-medium", "claude-opus-5-5-medium", "claude-sonnet-5-5-medium"];
  const { pool, t, session, at } = agyPool(models);
  const quota = (checkedAt: number, scoped?: unknown[]) => ({
    state: "ok",
    checkedAt,
    windows: [
      { label: "5 小时 · Gemini", usedPercent: 10, resetsAt: 50_000, minutes: 300, scope: "gemini" },
      { label: "每周 · Gemini", usedPercent: 16, resetsAt: 900_000, minutes: 10080, scope: "gemini" },
      { label: "5 小时 · Claude / GPT", usedPercent: 60, resetsAt: 60_000, minutes: 300, scope: "3p" },
      { label: "每周 · Claude / GPT", usedPercent: 40, resetsAt: 900_000, minutes: 10080, scope: "3p" },
    ],
    ...(scoped ? { scoped } : {}),
  });
  let ag1 = quota(1500);
  pool.setHealth((id) => ({ check: { state: "ok", models }, quota: id === "ag1" ? ag1 : quota(1500) }));
  session("s-claude", "claude-opus-5-5-medium");
  session("s-gemini", "gemini-4-carbon-medium");
  session("s-sonnet", "claude-sonnet-5-5-medium");
  // Its Claude turn ran into "Individual quota reached", its allowance not read again since (checkedAt before then):
  // its Claude / GPT group is passed over there, its Gemini runs on (2026-11-16: the whole account was).
  assert.deepEqual(pool.spend("s-claude", "ag1"), ["AG1", "AG2"]);
  assert.equal(pool.runOn("s-gemini").id, "ag1");
  assert.equal(at("s-gemini"), "ag1");
  assert.equal(pool.runOn("s-sonnet").id, "ag2");
  // Reset by hand, the group runs there again at once.
  pool.resetAllowance("ag1");
  session("s-sonnet", "claude-sonnet-5-5-medium");
  assert.equal(pool.runOn("s-sonnet").id, "ag1");
  // Spent again, then its allowance read again after it: what that says counts.
  t.now = 3000;
  session("s-claude", "claude-opus-5-5-medium");
  pool.spend("s-claude", "ag1");
  session("s-sonnet", "claude-sonnet-5-5-medium");
  assert.equal(pool.runOn("s-sonnet").id, "ag2");
  ag1 = quota(3500);
  t.now = 4000;
  session("s-sonnet", "claude-sonnet-5-5-medium");
  assert.equal(pool.runOn("s-sonnet").id, "ag1");

  // A Pro account's own Argon week used up: an Argon turn's limit passes over Argon alone there, its Hydrogen and Flash
  // run on under the Gemini group.
  ag1 = quota(3500, [{ label: "每周 · Argon", usedPercent: 100, resetsAt: 900_000, minutes: 10080, scope: "Argon" }]);
  session("s-argon", "gemini-4-argon-medium");
  session("s-hydrogen", "gemini-4-hydrogen-medium");
  session("s-flash", "gemini-4-flash-medium");
  pool.spend("s-argon", "ag1");
  assert.equal(at("s-argon"), "ag2");
  assert.equal(pool.runOn("s-hydrogen").id, "ag1");
  assert.equal(pool.runOn("s-flash").id, "ag1");
  assert.equal(pool.runOn("s-gemini").id, "ag1");
  // Its Argon week read not yet full (95%, the Gemini group's at 16%): still Argon's own, Argon alone passed over until
  // a newer read or a reset.
  t.now = 5000;
  ag1 = quota(4500, [{ label: "每周 · Argon", usedPercent: 95, resetsAt: 900_000, minutes: 10080, scope: "Argon" }]);
  session("s-argon", "gemini-4-argon-medium");
  pool.spend("s-argon", "ag1");
  assert.equal(at("s-argon"), "ag2");
  assert.equal(pool.runOn("s-hydrogen").id, "ag1");
  session("s-argon", "gemini-4-argon-medium");
  assert.equal(pool.runOn("s-argon").id, "ag2");
  pool.resetAllowance("ag1");
  session("s-argon", "gemini-4-argon-medium");
  assert.equal(pool.runOn("s-argon").id, "ag1");
  // And a read after its limit that says its Argon week has room lets it run there too.
  t.now = 6000;
  pool.spend("s-argon", "ag1");
  session("s-argon", "gemini-4-argon-medium");
  assert.equal(pool.runOn("s-argon").id, "ag2");
  ag1 = quota(6500, [{ label: "每周 · Argon", usedPercent: 30, resetsAt: 900_000, minutes: 10080, scope: "Argon" }]);
  t.now = 7000;
  session("s-argon", "gemini-4-argon-medium");
  assert.equal(pool.runOn("s-argon").id, "ag1");
});

test("an Antigravity CLI account's nearly full Claude / GPT five hours does not move its Gemini sessions off it; a window due to refill counts as refilled", () => {
  const models = ["gemini-4-carbon-medium", "claude-opus-5-5-medium"];
  const { pool, t, session } = agyPool(models);
  const hour = 60 * 60 * 1000;
  const quota = (gemini5h: number, p5h: number) => ({
    state: "ok",
    checkedAt: 1500,
    windows: [
      { label: "5 小时 · Gemini", usedPercent: gemini5h, resetsAt: 2 * hour, minutes: 300, scope: "gemini" },
      { label: "每周 · Gemini", usedPercent: 30, resetsAt: 100 * hour, minutes: 10080, scope: "gemini" },
      { label: "5 小时 · Claude / GPT", usedPercent: p5h, resetsAt: 2 * hour, minutes: 300, scope: "3p" },
      { label: "每周 · Claude / GPT", usedPercent: 40, resetsAt: 100 * hour, minutes: 10080, scope: "3p" },
    ],
  });
  pool.setHealth((id) => ({ check: { state: "ok", models }, quota: id === "ag1" ? quota(20, 95) : quota(20, 10) }));
  t.compacted = true;
  session("s-gemini", "gemini-4-carbon-medium");
  session("s-claude", "claude-opus-5-5-medium");
  assert.equal(pool.runOn("s-gemini").id, "ag1");
  // Its Claude session, where that five hours does weigh, moves as before (it loses little: just compacted).
  assert.equal(pool.runOn("s-claude").id, "ag2");

  // Read before its five hours refilled: due by now, it is not crowded and weighs as a whole window again.
  const now = 10 * hour;
  const week = { label: "每周", usedPercent: 20, resetsAt: now + 72 * hour, minutes: 10080 };
  const stale = { state: "ok", windows: [{ label: "5 小时", usedPercent: 90, resetsAt: now - 1, minutes: 300 }, week] };
  const refilled = { state: "ok", windows: [{ label: "5 小时", usedPercent: 0, resetsAt: now - 1, minutes: 300 }, week] };
  assert.equal(urgency(stale, now).crowded, false);
  assert.deepEqual(urgency(stale, now), urgency(refilled, now));
  const shortOnly = (used: number) => ({ state: "ok", windows: [{ label: "5 小时", usedPercent: used, resetsAt: now - 1, minutes: 300 }] });
  assert.deepEqual(urgency(shortOnly(90), now), urgency(shortOnly(0), now));
});

test("macOS keychain: `agy` is kept to the profile's file, and a sign-in it had moved into the machine's one keychain item is taken back only by the profile whose account it is", async () => {
  const dir = join(data, "keychain-accounts");
  mkdirSync(dir, { recursive: true });
  const unsignedHome = join(dir, "homes", "unsigned");
  const preExistingHome = join(dir, "homes", "preexisting");
  const notedHome = join(dir, "homes", "noted");
  const otherHome = join(dir, "homes", "other");
  const envHome = join(dir, "homes", "env");
  const apiHome = join(dir, "homes", "api");
  // `linkTranscripts` creates `agy/sessions` even before a profile has ever signed in.
  mkdirSync(join(agyHome(unsignedHome), SESSIONS), { recursive: true });
  mkdirSync(join(geminiDir(unsignedHome), "antigravity-cli"), { recursive: true });
  // A profile signed in before `account.json` existed, whose token file `agy acp` moved into the keychain: whose
  // account the item is cannot be told, so it signs in again.
  mkdirSync(agyConversations(preExistingHome), { recursive: true });
  writeFileSync(join(agyConversations(preExistingHome), "c1.db"), "db");
  // A profile signed in via station (noted email), then its token file moved into the keychain by `agy`.
  const token = JSON.stringify({ token: { access_token: "ya29.x" }, auth_method: "consumer", id_token_email: "someone@gmail.com" });
  mkdirSync(join(geminiDir(notedHome), "antigravity-cli"), { recursive: true });
  writeFileSync(agyToken(notedHome), token);
  // Another account's profile, its file moved too: the one item holds the account signed in last, not this one.
  mkdirSync(agyHome(otherHome), { recursive: true });
  writeFileSync(agyAccountFile(otherHome), JSON.stringify({ email: "other@gmail.com" }));

  const hadKeychain = platform.hasKeychain;
  const read = agyKeychain.read;
  platform.hasKeychain = true;
  let item: string | null = null;
  let reads = 0;
  agyKeychain.read = async () => {
    reads++;
    return item;
  };
  const store = Store.open(":memory:", null);
  const config = new ConfigFile(dir);
  config.update((raw) => {
    raw.profiles = [
      { id: "ag-u", name: "Unsigned", runtime: "agy", home: unsignedHome, access: { kind: "subscription" } },
      { id: "ag-p", name: "PreExisting", runtime: "agy", home: preExistingHome, access: { kind: "subscription" } },
      { id: "ag-n", name: "Noted", runtime: "agy", home: notedHome, access: { kind: "subscription" } },
      { id: "ag-o", name: "Other", runtime: "agy", home: otherHome, access: { kind: "subscription" } },
      { id: "ag-env", name: "Env", runtime: "agy", home: envHome, access: { kind: "env" } },
      { id: "ag-api", name: "Api", runtime: "agy", home: apiHome, access: { kind: "api-provider", provider: "google", key: "bad-key" } },
    ];
  });
  let driverMode: "ok" | "auth" | "crash" = "ok";
  let driverCalls = 0;
  const accounts = new Accounts({
    data: dir,
    store,
    config,
    machine: null,
    checkOnStart: false,
    check: (req, lang) =>
      req.kind === "api-provider"
        ? Promise.resolve({ state: "failed", detail: "Google refused the key (401)", models: null, checkedAt: 0 })
        : checkProfile({ ...req, env: {}, machine: false, lang }),
    quota: async () => ({ state: "ok", windows: [], detail: null, checkedAt: 0 }),
    agy: () =>
      ({
        models: async () => {
          driverCalls++;
          if (driverMode === "auth") throw new Error("Authentication required");
          if (driverMode === "crash") throw new Error("spawn agy ENOENT");
          return ["gemini-3.5-flash", "gemini-3.1-pro"];
        },
      }) as never,
  });
  try {
    // Its processes keep the sign-in in the file alone: never the keychain's one item for every profile.
    const { options } = setup();
    assert.equal(agyEnv(options).SSH_CLIENT, AGY_FILE_TOKENS.SSH_CLIENT);

    // 1. The first check notes the email; then `agy` (before) moved the file into the keychain, as go-keyring writes it.
    const first = await checkProfile({ runtime: "agy", kind: "subscription", key: "", via: {}, home: notedHome, env: {}, machine: false, lang: "en" });
    assert.equal(first.state, "ok");
    assert.match(first.detail, /someone@gmail\.com/);
    assert.equal(reads, 0, "a profile with its file reads no keychain");
    rmSync(agyToken(notedHome));
    item = `go-keyring-base64:${Buffer.from(token).toString("base64")}`;
    assert.equal(await accountEmailSoon("agy", notedHome), "someone@gmail.com");

    // 2. The item is this profile's account: taken back into its file, and it is signed in on it.
    const back = await checkProfile({ runtime: "agy", kind: "subscription", key: "", via: {}, home: notedHome, env: {}, machine: false, lang: "en" });
    assert.equal(back.state, "ok");
    assert.match(back.detail, /someone@gmail\.com/);
    assert.equal(readFileSync(agyToken(notedHome), "utf8"), token);

    // 3. The item is another account's: not taken, signed out (it ran on someone@'s quota before).
    const other = await checkProfile({ runtime: "agy", kind: "subscription", key: "", via: {}, home: otherHome, env: {}, machine: false, lang: "en" });
    assert.equal(other.state, "login");
    assert.equal(existsSync(agyToken(otherHome)), false);

    // 4. Unsigned and pre-existing profiles (no noted account) stay `login` without probing `agy acp`.
    assert.equal((await accounts.check("ag-u", "en")).state, "login");
    assert.equal((await accounts.check("ag-p", "en")).state, "login");
    assert.equal(driverCalls, 0);

    // 5. The taken-back profile probes `agy acp` and reports `ok` with models.
    const nCheck = await accounts.check("ag-n", "en");
    assert.equal(nCheck.state, "ok");
    assert.deepEqual(nCheck.models, ["gemini-3.5-flash", "gemini-3.1-pro"]);

    // 6. A revoked sign-in (`Authentication required`) flips a subscription check back to `login` while preserving known models.
    driverMode = "auth";
    const revoked = await accounts.check("ag-n", "en");
    assert.equal(revoked.state, "login");
    assert.equal(revoked.detail, tr("en", "station.profile.signedOut"));
    assert.deepEqual(revoked.models, ["gemini-3.5-flash", "gemini-3.1-pro"]);

    // 7. Non-subscription `agy` profiles (`env` and `api-provider`) never get mapped to `login`:
    //    `env` reports `failed` (`agyFailed`), and an already-failed `api-provider` key check preserves its `keyRefused` error without spawning `agy acp`.
    const callsBeforeEnv = driverCalls;
    const envFailed = await accounts.check("ag-env", "en");
    assert.equal(envFailed.state, "failed");
    assert.match(envFailed.detail, /Authentication required/);
    assert.equal(driverCalls, callsBeforeEnv + 1);

    const apiFailed = await accounts.check("ag-api", "en");
    assert.equal(apiFailed.state, "failed");
    assert.equal(apiFailed.detail, "Google refused the key (401)");
    assert.equal(driverCalls, callsBeforeEnv + 1, "already-failed api-provider check does not spawn agy acp");

    // 8. Non-auth launch error still reports `failed`.
    driverMode = "crash";
    const crashed = await accounts.check("ag-n", "en");
    assert.equal(crashed.state, "failed");
    assert.match(crashed.detail, /ENOENT/);
  } finally {
    platform.hasKeychain = hadKeychain;
    agyKeychain.read = read;
    await accounts.close();
    store.close();
  }
});

test("go-keyring's stored values, as `agy` left them in the keychain", () => {
  const text = JSON.stringify({ id_token_email: "a@b.c" });
  assert.equal(goKeyringValue(`go-keyring-base64:${Buffer.from(text).toString("base64")}`), text);
  assert.equal(goKeyringValue(`go-keyring-encoded:${Buffer.from(text).toString("hex")}`), text);
  assert.equal(goKeyringValue(text), text);
});

test("Linux and Windows keep `agy` on file tokens, and Linux takes back a matching Secret Service item", async () => {
  const dir = join(data, "linux-keyring");
  const notedHome = join(dir, "noted");
  const otherHome = join(dir, "other");
  const unsignedHome = join(dir, "unsigned");
  const windowsHome = join(dir, "windows");
  mkdirSync(agyHome(notedHome), { recursive: true });
  mkdirSync(agyHome(otherHome), { recursive: true });
  mkdirSync(agyHome(unsignedHome), { recursive: true });
  mkdirSync(agyHome(windowsHome), { recursive: true });
  const token = JSON.stringify({ token: { access_token: "ya29.linux" }, auth_method: "consumer", id_token_email: "linux@gmail.com" });
  writeFileSync(agyAccountFile(notedHome), JSON.stringify({ email: "linux@gmail.com" }));
  writeFileSync(agyAccountFile(otherHome), JSON.stringify({ email: "other@gmail.com" }));
  writeFileSync(agyAccountFile(windowsHome), JSON.stringify({ email: "linux@gmail.com" }));

  const hadKeychain = platform.hasKeychain;
  const hadOs = platform.os;
  const read = agyKeychain.read;
  let reads = 0;
  agyKeychain.read = async () => {
    reads++;
    return token;
  };
  try {
    // Non-keychain platforms (Linux and Windows) always pass AGY_FILE_TOKENS so `agy` stays on file storage.
    const { options } = setup();
    platform.hasKeychain = false;
    platform.os = "linux";
    assert.equal(agyEnv(options).SSH_CLIENT, AGY_FILE_TOKENS.SSH_CLIENT);

    // Matching Linux Secret Service item is taken back into the profile's token file.
    const back = await checkProfile({ runtime: "agy", kind: "subscription", key: "", via: {}, home: notedHome, env: {}, machine: false, lang: "en" });
    assert.equal(back.state, "ok");
    assert.match(back.detail, /linux@gmail\.com/);
    assert.equal(readFileSync(agyToken(notedHome), "utf8"), token);
    assert.equal(reads, 1);

    // Another account's profile and an unsigned profile do not claim the shared keyring item.
    const other = await checkProfile({ runtime: "agy", kind: "subscription", key: "", via: {}, home: otherHome, env: {}, machine: false, lang: "en" });
    assert.equal(other.state, "login");
    assert.equal(existsSync(agyToken(otherHome)), false);
    assert.equal(reads, 2);

    const unsigned = await checkProfile({ runtime: "agy", kind: "subscription", key: "", via: {}, home: unsignedHome, env: {}, machine: false, lang: "en" });
    assert.equal(unsigned.state, "login");
    assert.equal(reads, 2, "unsigned profile skips keyring lookup");

    // Windows also passes AGY_FILE_TOKENS, while agyTakeBack skips macOS/Linux keyring lookup.
    platform.os = "windows";
    assert.equal(agyEnv(options).SSH_CLIENT, AGY_FILE_TOKENS.SSH_CLIENT);
    assert.equal(await agyTakeBack(windowsHome), false);
    assert.equal(reads, 2);
  } finally {
    platform.hasKeychain = hadKeychain;
    platform.os = hadOs;
    agyKeychain.read = read;
  }
});

test("readLinuxAgyKeyring skips headless environments, reads unlocked items via Gio, and falls back to secret-tool only when python3 or gi is missing", async () => {
  const calls: Array<{ file: string; args: readonly string[] }> = [];
  const token = JSON.stringify({ id_token_email: "linux@gmail.com" });

  // No session D-Bus address and no XDG_RUNTIME_DIR/bus socket -> skips spawning any helper.
  assert.equal(
    await readLinuxAgyKeyring({}, async (file, args) => {
      calls.push({ file, args });
      return { error: null, stdout: token };
    }),
    null,
  );
  assert.equal(calls.length, 0);

  // With DBUS_SESSION_BUS_ADDRESS, queries python3 Gio helper first.
  const busEnv = { DBUS_SESSION_BUS_ADDRESS: "unix:path=/run/user/1000/bus" };
  assert.equal(
    await readLinuxAgyKeyring(busEnv, async (file, args) => {
      calls.push({ file, args });
      return { error: null, stdout: `${token}\n` };
    }),
    token,
  );
  assert.deepEqual(calls.map((c) => c.file), ["python3"]);

  // Item absent or keyring locked (python3 exits 1): returns null without falling back to secret-tool.
  calls.length = 0;
  assert.equal(
    await readLinuxAgyKeyring(busEnv, async (file, args) => {
      calls.push({ file, args });
      return { error: Object.assign(new Error("not found"), { code: 1 }), stdout: "" };
    }),
    null,
  );
  assert.deepEqual(calls.map((c) => c.file), ["python3"]);

  // Missing python3 (ENOENT) or missing gi (exit code 3): falls back to secret-tool.
  for (const code of ["ENOENT", 3] as const) {
    calls.length = 0;
    assert.equal(
      await readLinuxAgyKeyring(busEnv, async (file, args) => {
        calls.push({ file, args });
        if (file === "python3") return { error: Object.assign(new Error("missing"), { code }), stdout: "" };
        return { error: null, stdout: `  ${token}\n` };
      }),
      token,
    );
    assert.deepEqual(calls.map((c) => c.file), ["python3", "secret-tool"]);
    assert.deepEqual(calls[1]!.args, ["lookup", "service", "gemini", "username", "antigravity"]);
  }

  // Blank output or failed secret-tool returns null.
  assert.equal(
    await readLinuxAgyKeyring(busEnv, async (file) => {
      if (file === "python3") return { error: Object.assign(new Error("no gi"), { code: 3 }), stdout: "" };
      return { error: null, stdout: "   \n" };
    }),
    null,
  );
});

test("uncheckOutdated migrates legacy tiered agy model IDs in config.json to base models", () => {
  const raw: any = {
    profiles: [
      {
        id: "ag",
        runtime: "agy",
        access: { kind: "subscription" },
        model: "gemini-4-carbon-high",
        models: ["gemini-4-carbon-high", "claude-opus-5-5-medium"],
      },
    ],
    connects: [{ id: "sl", bind: { runtime: "agy", model: "gemini-4-carbon-high" } }],
  };
  const { changes } = uncheckOutdated(raw, () => ["gemini-4-carbon", "claude-opus-5-5", "gpt-oss-120b"], new Set());
  assert.equal(changes.length, 1);
  assert.deepEqual(raw.profiles[0].models, ["gemini-4-carbon", "claude-opus-5-5"]);
  assert.equal(raw.profiles[0].model, "gemini-4-carbon");
  assert.equal(raw.connects[0].bind.model, "gemini-4-carbon");
});

test("a Claude session at max effort crossing runtimes to Antigravity CLI lands on medium", async () => {
  const cfg = hubConfig(
    {
      profiles: [
        { id: "cc", name: "CC", runtime: "claude", home: "/cc", access: { kind: "subscription" }, model: "claude-opus-5-5", models: ["claude-opus-5-5"] },
        { id: "ag", name: "AG", runtime: "agy", home: "/ag", access: { kind: "subscription" }, model: "gemini-4-carbon", models: ["gemini-4-carbon", "claude-opus-5-5"] },
      ],
    },
    "/x",
  );
  const sessions = new Map<string, any>([
    ["s-opus", { key: "s-opus", runtime: "claude", profile: "cc", profilePinned: false, model: "claude-opus-5-5", effort: "max", runtimeSessionId: "cc-1" }],
  ]);
  const pool = new SessionAccounts({
    config: () => cfg,
    store: {
      getSession: (k: string) => sessions.get(k),
      setSessionProfile: (k: string, id: string, pinned: boolean) => Object.assign(sessions.get(k), { profile: id, profilePinned: pinned }),
      setSessionRuntime: (k: string, runtime: string, profile: string, profilePinned: boolean, model: string | null, effort: string | null) =>
        Object.assign(sessions.get(k), { runtime, profile, profilePinned, model, effort, runtimeSessionId: null }),
      setSessionContextBefore: () => {},
      ranIn: () => {},
      lastTurn: () => ({ endedAt: 1000 }),
      recentlyCompacted: () => false,
      compactionsReady: () => false,
      lastContexts: () => [],
      compactionPoints: () => new Map(),
    } as never,
    running: () => [],
    clock: { currentTimeMillisUnsafe: () => 2000 } as never,
  });
  pool.setHealth((id) => ({
    check: {
      state: "ok",
      models: id === "cc" ? ["claude-opus-5-5"] : ["gemini-4-carbon", "claude-opus-5-5"],
      modelEfforts: id === "ag" ? { agy: { "gemini-4-carbon": ["low", "medium", "high"], "claude-opus-5-5": ["low", "medium", "high"] } } : undefined,
    },
    quota: { state: "ok", windows: [] },
  }));

  assert.deepEqual(pool.spend("s-opus", "cc"), ["CC", "AG"]);
  const moved = sessions.get("s-opus")!;
  assert.equal(moved.runtime, "agy");
  assert.equal(moved.effort, null);

  const { options, driver, dump } = setup({ FAKE_AGY_SUBSCRIPTION: "1" });
  const session = await driver.open({ ...options, model: moved.model, effort: moved.effort ?? undefined }, () => {});
  assert.equal(session.currentModelId, "claude-opus-5-5-medium");
  assert.equal(rpc(dump).find((m) => m.method === "session/set_model").params.modelId, "claude-opus-5-5-medium");
  await session.dispose();
});

test("opening Antigravity sessions keeps --gemini-dir/config/hooks.json enabled across concurrent sessions and silences instructions-less ones via STILLFAIL_REPO_RULES", async () => {
  const { options, driver } = setup();
  const ws = mkdtempSync(join(data, "agy-hooks-ws-"));
  const hooksFile = join(geminiDir(options.profile.home), "config", "hooks.json");
  mkdirSync(dirname(hooksFile), { recursive: true });
  writeFileSync(hooksFile, JSON.stringify({ custom: { PostInvocation: [{ command: "echo {}" }] }, stillfail: { enabled: false } }));

  const s = await driver.open({ ...options, cwd: ws }, () => {});
  const hooks = JSON.parse(readFileSync(hooksFile, "utf8"));
  assert.deepEqual(hooks.custom, { PostInvocation: [{ command: "echo {}" }] });
  assert.equal(Array.isArray(hooks.stillfail?.PostToolUse), true);
  assert.equal(hooks.stillfail?.enabled, undefined);
  const matcher = new RegExp(`^(?:${hooks.stillfail.PostToolUse[0].matcher})$`);
  for (const tool of ["run_command", "read_file", "write_file", "edit_file", "view_file", "grep_search", "find_by_name", "list_dir"]) {
    assert.equal(matcher.test(tool), true, tool);
  }
  const cmd: string = hooks.stillfail.PostToolUse[0].hooks[0].command;
  assert.equal(cmd.includes(REPO_RULES_HOOK), true);
  assert.match(cmd, platform.os === "windows" ? /^call ".*" ".*" 2>nul \|\| echo \{\}$/ : /\|\| printf '\{\}'$/);
  assert.equal(hooks.stillfail.PostInvocation[0].command, cmd);

  // Opening a terminal-continued session (`instructions: ""`) on the same profile home while `s` is alive leaves
  // shared `hooks.json` enabled and silences only that process's hook via `STILLFAIL_REPO_RULES=0` (scrubbed otherwise).
  const userRepo = mkdtempSync(join(data, "agy-user-repo-"));
  const s2 = await driver.open({ ...options, key: `${options.key}-term`, cwd: userRepo, instructions: "", skills: undefined }, () => {});
  try {
    const afterTerm = JSON.parse(readFileSync(hooksFile, "utf8"));
    assert.equal(Array.isArray(afterTerm.stillfail?.PostToolUse), true);
    assert.equal(afterTerm.stillfail?.enabled, undefined);
  } finally {
    await s2.dispose();
    await s.dispose();
  }

  assert.equal(agyEnv({ ...options, instructions: "" }).STILLFAIL_REPO_RULES, "0");
  const prev = process.env.STILLFAIL_REPO_RULES;
  process.env.STILLFAIL_REPO_RULES = "0";
  try {
    assert.equal(agyEnv(options).STILLFAIL_REPO_RULES, undefined);
  } finally {
    if (prev === undefined) delete process.env.STILLFAIL_REPO_RULES;
    else process.env.STILLFAIL_REPO_RULES = prev;
  }
});

test("Antigravity sessions materialize shared and symlinked preset skills into .agent/skills with non-symlink SKILL.md", async () => {
  const { options, driver } = setup();
  const ws = mkdtempSync(join(data, "agy-ws-"));
  const shared = mkdtempSync(join(data, "agy-shared-skills-"));
  const preset = mkdtempSync(join(data, "agy-preset-skills-"));
  mkdirSync(join(shared, "team-skill", "scripts"), { recursive: true });
  mkdirSync(join(shared, "team-skill", ".venv"), { recursive: true });
  writeFileSync(join(shared, "team-skill", "SKILL.md"), "---\nname: team-skill\ndescription: v1\n---\n");
  writeFileSync(join(shared, "team-skill", "scripts", "run.sh"), "#!/bin/sh\n");
  writeFileSync(join(shared, "team-skill", ".venv", "huge"), "skip");
  mkdirSync(join(preset, "deploy"), { recursive: true });
  writeFileSync(join(preset, "deploy", "SKILL.md"), "---\nname: deploy\ndescription: preset\n---\n");

  mkdirSync(join(ws, ".agents", "skills"), { recursive: true });
  symlinkSync(join(preset, "deploy"), join(ws, ".agents", "skills", "deploy"), "dir");

  const s = await driver.open({ ...options, cwd: ws, skills: shared }, () => {});
  await s.dispose();

  const teamDir = join(ws, ".agent", "skills", "team-skill");
  const deployDir = join(ws, ".agent", "skills", "deploy");
  assert.equal(existsSync(join(teamDir, "SKILL.md")), true);
  assert.equal(lstatSync(teamDir).isSymbolicLink(), false);
  assert.equal(lstatSync(join(teamDir, "SKILL.md")).isSymbolicLink(), false);
  assert.equal(readFileSync(join(teamDir, "SKILL.md"), "utf8"), "---\nname: team-skill\ndescription: v1\n---\n");
  assert.equal(existsSync(join(teamDir, "scripts", "run.sh")), true);
  assert.equal(existsSync(join(teamDir, ".venv")), false);
  assert.equal(existsSync(join(deployDir, "SKILL.md")), true);
  assert.equal(lstatSync(join(deployDir, "SKILL.md")).isSymbolicLink(), false);

  // Atomic replacement of SKILL.md and removal of a preset skill update .agent/skills on the next session open.
  writeFileSync(join(shared, "team-skill", "SKILL.md.next"), "---\nname: team-skill\ndescription: v2\n---\n");
  rmSync(join(shared, "team-skill", "SKILL.md"));
  writeFileSync(join(shared, "team-skill", "SKILL.md"), readFileSync(join(shared, "team-skill", "SKILL.md.next")));
  rmSync(join(shared, "team-skill", "SKILL.md.next"));
  rmSync(join(ws, ".agents", "skills", "deploy"), { force: true });
  const sNext = await driver.open({ ...options, cwd: ws, skills: shared }, () => {});
  await sNext.dispose();
  assert.equal(readFileSync(join(teamDir, "SKILL.md"), "utf8"), "---\nname: team-skill\ndescription: v2\n---\n");
  assert.equal(existsSync(deployDir), false);

  // A session continued from a terminal (skills: undefined) writes no .agent/skills.
  const userRepo = mkdtempSync(join(data, "agy-user-skills-"));
  const sTerm = await driver.open({ ...options, cwd: userRepo, instructions: "", skills: undefined }, () => {});
  await sTerm.dispose();
  assert.equal(existsSync(join(userRepo, ".agent")), false);
});

test("Antigravity CLI is declared the station's tools within what it keeps, chat_post among them, once it wraps each", async () => {
  // As the station lists them to an `agy` session (sessions/agents.ts LISTINGS): fitted to AGY_TOOL_BUDGET.
  const all = stationTools();
  const listed = async (budget: number): Promise<any[]> => {
    const e = new McpEndpoint(() => "s", all, undefined, () => ({ budget }));
    const reply: any = await e.handle("POST", "Bearer t", JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list" }));
    return reply.body.result.tools;
  };
  const weighed = (list: any[]) => list.reduce((n, t) => n + Buffer.byteLength(JSON.stringify(t)), 0);
  const list = await listed(AGY_TOOL_BUDGET);
  const names = list.map((t) => t.name);
  const bytes = weighed(list);
  assert.ok(bytes <= AGY_TOOL_BUDGET, `listed ${bytes} B`);
  // What `agy` makes of them (agents/agy.ts AGY_TOOL_BUDGET): each given its description's prefix and `toolSummary`.
  const wrapped = bytes + list.length * AGY_TOOL_WRAP;
  assert.ok(wrapped <= AGY_TOOL_CEILING, `${list.length} tools, ${bytes} B listed, come to ${wrapped} B in agy, over ${AGY_TOOL_CEILING}`);
  // The tools every turn needs are declared whatever the rest weigh, chat_post (the heaviest) first of all.
  for (const name of ["chat_post", "chat_state", ...CORE]) assert.ok(names.includes(name), `${name} is not declared`);
  // And the rest are still reached, through station_tool.
  assert.equal(names.at(-1), INDIRECT);
  const indirect: string[] = list.at(-1).inputSchema.properties.name.enum;
  assert.deepEqual([...names.slice(0, -1), ...indirect].sort(), all.filter((t) => !HIDDEN.includes(t.name)).map((t) => t.name).sort());
  // Earlier budgets (45,000 on 1.5.8; 26,000 on 1.5.9 with Windows skill paths) pushed agy's pool past its ceiling and dropped chat_post.
  for (const oldBudget of [45_000, 26_000]) {
    const before = await listed(oldBudget);
    assert.ok(weighed(before) + before.length * AGY_TOOL_WRAP > AGY_TOOL_CEILING);
  }
});

test("agy Verification Required notice is classified as auth failure (single-line and trailing after partial text)", async () => {
  assert.equal(classifyFailure("Verification Required"), "auth");
  assert.equal(noticeFailure("⚠ Verification Required"), "auth");
  assert.equal(noticeFailure("  ⚠ Verification Required  "), "auth");
  assert.equal(noticeFailure("partial output\n⚠ Verification Required\n"), "auth");
  const { options, events, driver } = setup();
  const s = await driver.open(options, (e) => events.push(e));
  await s.prompt("verification-required");
  await until(() => ended(events).length === 1);
  assert.deepEqual(ended(events)[0], { type: "turnEnded", outcome: { kind: "failed", reason: "auth", message: "⚠ Verification Required" } });
  await s.prompt("verification-required-mid-turn");
  await until(() => ended(events).length === 2);
  assert.deepEqual(ended(events)[1], { type: "turnEnded", outcome: { kind: "failed", reason: "auth", message: "⚠ Verification Required" } });
  await s.dispose();
});

test("agy session/load ghost history replay on first prompt is discarded and original prompt is transparently resent once", async () => {
  const { options, events, driver, dump } = setup();
  const s = await driver.open({ ...options, model: "gemini-3.1-pro" }, (e) => events.push(e));
  await s.prompt("initial turn");
  await until(() => ended(events).length === 1);
  const id = s.id();
  await s.dispose();

  // Reopen via session/load with FAKE_AGY_LOAD_REPLAY=1: first prompt replays ghost history and ends without usage;
  // driver must discard ghost history, not emit turnEnded, not duplicate the user line, and resend once with a new prompt id.
  const dump2 = join(data, `dump-replay-${++n}`);
  const opts2: OpenOptions = {
    ...options,
    key: `agy-replay-${n}`,
    resume: id,
    profile: { ...options.profile, env: { ...(options.profile.env as Record<string, string>), FAKE_DUMP: dump2, FAKE_AGY_LOAD_REPLAY: "1" } },
  };
  const events2: RuntimeEvent[] = [];
  const resumed = await driver.open(opts2, (e) => events2.push(e));
  await resumed.prompt("real question after load");
  await until(() => ended(events2).length === 1);
  assert.deepEqual(ended(events2), [{ type: "turnEnded", outcome: { kind: "completed" } }]);
  const prompts = rpc(dump2).filter((m) => m.method === "session/prompt");
  assert.equal(prompts.length, 2, "driver resent the prompt once after ghost replay");
  assert.notEqual(prompts[0].id, prompts[1].id, "resent prompt uses a fresh prompt:<uuid> id");
  assert.ok(String(prompts[1].id).startsWith("prompt:"));
  assert.equal(prompts[0].params.prompt[0].text, "real question after load");
  assert.equal(prompts[1].params.prompt[0].text, "real question after load");

  const path = transcriptPath("agy", options.profile.home, id)!;
  const entries = readFileSync(path, "utf8").trim().split("\n").map((line) => JSON.parse(line));
  assert.equal(entries.filter((e) => e.type === "user" && e.text === "real question after load").length, 1, "user prompt written only once");
  assert.equal(entries.some((e) => e.text === "ghost history replay text" || e.result === "ghost history output"), false, "ghost replay history not written to transcript");
  assert.equal(entries.filter((e) => e.type === "assistant").at(-1)?.text, "first real question after load");
  assert.equal(entries.filter((e) => e.type === "end").length, 2, "only initial turn and real resumed turn wrote end lines");
  await resumed.dispose();

  // At most 1 resend: if the resent prompt also ends without usage, it completes normally instead of looping.
  const dump3 = join(data, `dump-replay-once-${++n}`);
  const opts3: OpenOptions = {
    ...options,
    key: `agy-replay-once-${n}`,
    resume: id,
    profile: { ...options.profile, env: { ...(options.profile.env as Record<string, string>), FAKE_DUMP: dump3, FAKE_AGY_LOAD_REPLAY: "2" } },
  };
  const events3: RuntimeEvent[] = [];
  const resumed2 = await driver.open(opts3, (e) => events3.push(e));
  await resumed2.prompt("double empty");
  await until(() => ended(events3).length === 1);
  assert.deepEqual(ended(events3), [{ type: "turnEnded", outcome: { kind: "completed" } }]);
  assert.equal(rpc(dump3).filter((m) => m.method === "session/prompt").length, 2, "never resends more than once");
  await resumed2.dispose();

  // session/new (not session/load) never triggers load_replay_guard even when end_turn has no usage.
  const { options: newOpts, events: newEvents, driver: newDriver, dump: newDump } = setup();
  const fresh = await newDriver.open(newOpts, (e) => newEvents.push(e));
  await fresh.prompt("no-usage-end");
  await until(() => ended(newEvents).length === 1);
  assert.deepEqual(ended(newEvents), [{ type: "turnEnded", outcome: { kind: "completed" } }]);
  assert.equal(rpc(newDump).filter((m) => m.method === "session/prompt").length, 1, "session/new never resends");
  await fresh.dispose();
});

test("google-vertex writes and updates its key file before start, authenticates agent-platform (and gemini-api-key only for google), and fails IAM denied notices as auth", async () => {
  const sa1 = JSON.stringify({
    type: "service_account",
    project_id: "proj-one",
    client_email: "bot@proj-one.iam.gserviceaccount.com",
    private_key: "-----BEGIN PRIVATE KEY-----\nkey1\n-----END PRIVATE KEY-----\n",
  });
  const sa2 = JSON.stringify({
    type: "service_account",
    project_id: "proj-two",
    client_email: "bot@proj-two.iam.gserviceaccount.com",
    private_key: "-----BEGIN PRIVATE KEY-----\nkey2\n-----END PRIVATE KEY-----\n",
  });

  // 1. google-vertex profile: writes key file, sets ADC env (no GEMINI_API_KEY), authenticates agent-platform.
  const id1 = ++n;
  const dump1 = join(data, `dump-vertex-${id1}`);
  const home = join(data, `home-vertex-${id1}`);
  const driver = new AgyDriver({ data });
  drivers.push(driver);
  const events1: RuntimeEvent[] = [];
  const baseOpts = (key: string, dump: string): OpenOptions => ({
    key: `agy-vertex-${++n}`,
    profile: { id: "vx", runtime: "agy", home, access: { kind: "api-provider", provider: "google-vertex", key }, env: { PATH: fake, FAKE_DUMP: dump } },
    cwd: data,
    instructions: "",
    mcpToken: "t",
    mcpUrl: "http://127.0.0.1:12345/mcp",
    route: "vertex-test",
  });
  const s1 = await driver.open(baseOpts(sa1, dump1), (e) => events1.push(e));
  assert.equal(readFileSync(vertexKeyFile(home), "utf8"), sa1);
  const started1 = JSON.parse(readFileSync(dump1, "utf8").trim().split("\n")[0]!);
  assert.deepEqual(
    [started1.key, started1.adcAuth, started1.project, started1.location, started1.credentials],
    [null, "1", "proj-one", "global", vertexKeyFile(home)],
  );
  assert.deepEqual(
    rpc(dump1).filter((m) => m.method === "authenticate").map((m) => m.params.methodId),
    ["agent-platform"],
  );
  // IAM permission denied notice fails the turn as auth.
  assert.equal(
    noticeFailure("⚠ Permission 'aiplatform.endpoints.predict' denied on resource '//aiplatform.googleapis.com/projects/demo-project/locations/global/publishers/google/models/gemini-4-carbon' (or it may not exist)."),
    "auth",
  );
  assert.equal(
    noticeFailure("partial\n⚠ Permission 'aiplatform.endpoints.predict' denied on resource '//aiplatform.googleapis.com/projects/demo-project'."),
    null,
  );
  // Vertex request refusal notice fails the turn as other (one-line only).
  assert.equal(
    noticeFailure("⚠ Unable to submit request because mcp_stillfail_station_task functionDeclaration parameters.action schema didn't specify the schema type field."),
    "other",
  );
  assert.equal(
    noticeFailure("partial\n⚠ Unable to submit request because bad schema."),
    null,
  );
  await s1.prompt("vertex-iam-denied");
  await until(() => ended(events1).length === 1);
  assert.equal(ended(events1)[0]!.outcome.kind, "failed");
  assert.equal((ended(events1)[0]!.outcome as any).reason, "auth");
  await s1.dispose();

  // Key changed in config -> rewritten before next start with updated project.
  const dump2 = join(data, `dump-vertex-${++n}`);
  const s2 = await driver.open(baseOpts(sa2, dump2), () => {});
  assert.equal(readFileSync(vertexKeyFile(home), "utf8"), sa2);
  const started2 = JSON.parse(readFileSync(dump2, "utf8").trim().split("\n")[0]!);
  assert.equal(started2.project, "proj-two");
  await s2.dispose();

  // 2. google (Gemini API key) authenticates gemini-api-key, not agent-platform.
  const { options: gOpts, driver: gDriver, dump: gDump } = setup();
  const gs = await gDriver.open(gOpts, () => {});
  assert.deepEqual(
    rpc(gDump).filter((m) => m.method === "authenticate").map((m) => m.params.methodId),
    ["gemini-api-key"],
  );
  await gs.dispose();
});

test("Accounts.newKeyedProfile adds a google-vertex profile with runtimes ['agy'], lists it in apiProviders, and probes agy catalog", async () => {
  const dir = mkdtempSync(join(data, "acc-vertex-"));
  const store = Store.open(":memory:", null);
  const config = new ConfigFile(dir);
  const viewer = { sub: "sub-owner", email: "a@b.c", name: "A", role: "owner" as const, workspace: "ws", device: "d" };
  const accounts = new Accounts({
    data: dir,
    store,
    config,
    machine: null,
    checkOnStart: false,
    agy: () => ({
      models: async () => ["gemini-4-neon"],
      catalog: async () => ({ models: ["gemini-4-neon"], efforts: { "gemini-4-neon": ["low", "medium", "high"] }, defaults: { "gemini-4-neon": "medium" } }),
    }),
  });
  try {
    assert.ok(accounts.apiProviders().some((p) => p.id === "google-vertex" && p.group === "labs"));
    await assert.rejects(
      accounts.newKeyedProfile({ access: { kind: "api-provider", provider: "google-vertex", key: "not-a-service-account" } }, viewer, "zh"),
      /服务账号 JSON/,
    );
    const sa = JSON.stringify({
      type: "service_account",
      project_id: "proj-acc",
      client_email: "bot@proj-acc.iam.gserviceaccount.com",
      private_key: "-----BEGIN PRIVATE KEY-----\nk\n-----END PRIVATE KEY-----\n",
    });
    const id = await accounts.newKeyedProfile({ access: { kind: "api-provider", provider: "google-vertex", key: sa } }, viewer, "zh");
    const profile = accounts.profiles().find((p) => p.id === id)!;
    assert.ok(profile);
    assert.deepEqual(profile.runtimes, ["agy"]);
    assert.equal(profile.runtime, "agy");
    assert.equal(billedPerUse(profile), true);
    const checked = await accounts.check(id, "zh");
    assert.equal(checked.state, "ok");
    assert.deepEqual(checked.models, ["gemini-4-neon"]);
  } finally {
    await accounts.close();
    store.close();
  }
});

test("agy subscription falls back to google-vertex when spent (notifying billedFallback) and returns when usable again", async () => {
  const sa = JSON.stringify({
    type: "service_account",
    project_id: "proj-fb",
    client_email: "bot@proj-fb.iam.gserviceaccount.com",
    private_key: "-----BEGIN PRIVATE KEY-----\nk\n-----END PRIVATE KEY-----\n",
  });
  const cfg = hubConfig(
    {
      profiles: [
        { id: "ag-sub", name: "Google AI", runtime: "agy", home: "/h/sub", access: { kind: "subscription" }, models: ["gemini-4-neon"] },
        { id: "ag-vertex", name: "Google Vertex AI", home: "/h/vx", access: { kind: "api-provider", provider: "google-vertex", key: sa }, models: ["gemini-4-neon"] },
      ],
    },
    "/x",
  );
  const sessions = new Map<string, any>([
    ["s-fb", { key: "s-fb", runtime: "agy", profile: "ag-sub", profilePinned: false, model: "gemini-4-neon", effort: "medium" }],
  ]);
  const fallbacks: Array<{ session: string; profile: string }> = [];
  let now = 2000;
  const pool = new SessionAccounts({
    config: () => cfg,
    store: {
      getSession: (k: string) => sessions.get(k),
      setSessionProfile: (k: string, p: string, pinned: boolean) => {
        const row = sessions.get(k);
        if (row) {
          row.profile = p;
          row.profilePinned = pinned;
        }
      },
      lastTurn: () => ({ endedAt: 1000 }),
      recentlyCompacted: () => false,
      compactionsReady: () => false,
      lastContexts: () => [],
      compactionPoints: () => new Map(),
    } as never,
    running: () => [],
    clock: { currentTimeMillisUnsafe: () => now } as never,
    billedFallback: (info) => fallbacks.push({ session: info.session, profile: info.profile.id }),
  });
  pool.setHealth(() => ({ check: { state: "ok", detail: "ok", models: ["gemini-4-neon"], checkedAt: 1500 } }));

  // Subscription hits its allowance -> spend moves to google-vertex and notifies billedFallback.
  const moved = pool.spend("s-fb", "ag-sub");
  assert.deepEqual(moved, ["Google AI", "Google Vertex AI"]);
  assert.equal(sessions.get("s-fb").profile, "ag-vertex");
  assert.deepEqual(fallbacks, [{ session: "s-fb", profile: "ag-vertex" }]);

  // Once the subscription is usable again, runOn moves the session back before the next turn.
  pool.resetAllowance("ag-sub");
  now += 1000;
  const back = pool.runOn("s-fb");
  assert.equal(back.id, "ag-sub");
  assert.equal(sessions.get("s-fb").profile, "ag-sub");
});
