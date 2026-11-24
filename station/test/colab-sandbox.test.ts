// The Colab sandboxes' pool (assets/agents/colab-sandbox.mjs): PlaintextKeyring sync from native Profiles
// (`homes/<id>/colab-auth.json`), which VM a task gets, which account starts a new one, waiting when none can,
// stopping idle ones, and the one ssh connection a task's ssh share (no `colab ssh --proxy-mode` each, which Colab
// refuses with 429 when asked a few times in seconds). Colab itself is a stand-in here (its CLI's answers: READY, 412 past 3 VMs/GPU, 503 when
// Google has none); the clock is the test's.
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterEach, beforeEach, describe, test } from "node:test";
// @ts-expect-error: a plain .mjs of the station's assets
import { KEEP_WARM_MS, MUX_PERSIST_S, MUX_RETRY_MS, PER_ACCOUNT, REFUSED_MS, acquire, cliHomeOf, controlPathOf, ensureControlMaster, markNodeReady, reap, release, sshTo, syncKeyring } from "../assets/agents/colab-sandbox.mjs";

type Account = { id: string; authFile: string };
type Call = { account: string; vm: string | null; args: string[] };
type Run = { cmd: string; args: string[]; opts: { stdio?: unknown } };

/// A stand-in Colab: each account holds VMs up to its limit (`limits`, else PER_ACCOUNT); `unavailable`: Google has
/// none of a GPU free; `masters`: what each start of a master ssh connection gets ("ok", or what ssh's log then says).
/// The clock moves only as the pool sleeps (or the test says).
function fakeColab(o: { limits?: Record<string, number>; unavailable?: string[]; serverEndpoints?: Record<string, string[]>; masters?: string[] } = {}) {
  let clock = 1_000_000;
  const held = new Map<string, { account: string; gpu: string }>();
  const calls: Call[] = [];
  const runs: Run[] = [];
  const sleeps: number[] = [];
  const masters = [...(o.masters ?? [])];
  let masterAlive = false;
  const io = {
    now: () => clock,
    sleep: (ms: number) => { sleeps.push(ms); clock += ms; },
    // ssh: `-O check` / `-O exit` on the master's socket, `-M` starting one.
    run: (cmd: string, args: string[], opts: { stdio?: unknown }) => {
      runs.push({ cmd, args, opts });
      const sock = args[args.indexOf("-S") + 1] ?? "";
      if (args[0] === "-O" && args[1] === "check") return { status: masterAlive ? 0 : 255 };
      if (args[0] === "-O" && args[1] === "exit") { masterAlive = false; return { status: 0 }; }
      if (args[0] === "-M") {
        const outcome = masters.shift() ?? "ok";
        if (outcome === "ok") {
          masterAlive = true;
          writeFileSync(args.find((a) => a.startsWith("ControlPath="))!.slice("ControlPath=".length), "");
          return { status: 0 };
        }
        writeFileSync(args[args.indexOf("-E") + 1]!, outcome);
        return { status: 255 };
      }
      return { status: sock === "" ? 1 : 255 };
    },
    alive: (pid: number) => pid === process.pid,
    colab: (account: Account, vm: string | null, args: string[]) => {
      calls.push({ account: account.id, vm, args });
      if (args[0] === "new") {
        const gpu = args[args.indexOf("--gpu") + 1]!;
        if (o.unavailable?.includes(gpu)) return { code: 1, out: "503 Server Error: Service Unavailable" };
        const mine = [...held.values()].filter((h) => h.account === account.id && h.gpu === gpu).length;
        if (mine >= (o.limits?.[account.id] ?? PER_ACCOUNT)) return { code: 1, out: "[colab] Allocation refused (precondition failed)." };
        held.set(vm!, { account: account.id, gpu });
        return { code: 0, out: `[colab] Creating session '${vm}'...\n[colab] Session READY.\n` };
      }
      if (args[0] === "stop") {
        held.delete(vm!);
        return { code: 0, out: "[colab] Session terminated.\n" };
      }
      if (args[0] === "sessions") {
        const eps = o.serverEndpoints?.[account.id] ?? [];
        if (eps.length === 0) return { code: 0, out: "[colab] No active sessions found on server.\n" };
        return { code: 0, out: eps.map((ep, i) => `[${i}] ${ep} | READY`).join("\n") + "\n" };
      }
      return { code: 1, out: "unknown" };
    },
  };
  return { io, held, calls, runs, sleeps, setMasterAlive: (alive: boolean) => { masterAlive = alive; }, advance: (ms: number) => { clock += ms; } };
}

let pool = "";
let homesDir = "";

function makeAccounts(...ids: string[]): Account[] {
  return ids.map((id) => {
    const dir = join(homesDir, id);
    mkdirSync(dir, { recursive: true });
    const authFile = join(dir, "colab-auth.json");
    writeFileSync(authFile, JSON.stringify({ token: `tok-${id}`, refresh_token: `ref-${id}` }));
    return { id, authFile };
  });
}

const state = () => JSON.parse(readFileSync(join(pool, "state.json"), "utf8"));

describe("Colab sandboxes' pool", () => {
  beforeEach(() => {
    pool = mkdtempSync(join(tmpdir(), "colab-pool-"));
    homesDir = mkdtempSync(join(tmpdir(), "colab-homes-"));
  });
  afterEach(() => {
    // Master sockets live outside the pool (controlPathOf): those the tests made.
    let vms: string[] = [];
    try { vms = Object.keys(state().vms); } catch {}
    for (const vm of [...vms, "g4-11111111"]) rmSync(controlPathOf(pool, vm), { force: true });
    rmSync(pool, { recursive: true, force: true });
    rmSync(homesDir, { recursive: true, force: true });
  });

  test("syncKeyring seeds PlaintextKeyring from homes/<id>/colab-auth.json, skips when unchanged, and re-syncs on mtime or size change", () => {
    const [acct] = makeAccounts("p1");
    const runs: { cmd: string; args: string[]; home: string; backend: string }[] = [];
    const fakeRun = (cmd: string, args: string[], opts: { env: Record<string, string> }) => {
      runs.push({ cmd, args, home: opts.env.HOME ?? "", backend: opts.env.PYTHON_KEYRING_BACKEND ?? "" });
      return { status: 0, stdout: "", stderr: "" };
    };
    assert.equal(syncKeyring(pool, acct, { python: "/fake/python", run: fakeRun }), true);
    assert.equal(runs.length, 1);
    assert.equal(runs[0]!.cmd, "/fake/python");
    assert.equal(runs[0]!.args[2], acct.authFile);
    assert.equal(runs[0]!.home, cliHomeOf(pool, "p1"));
    assert.equal(runs[0]!.backend, "keyrings.alt.file.PlaintextKeyring");

    // Unchanged mtimeMs and size: no re-seed.
    assert.equal(syncKeyring(pool, acct, { python: "/fake/python", run: fakeRun }), false);
    assert.equal(runs.length, 1);

    // Size changes: re-seeds.
    writeFileSync(acct.authFile, JSON.stringify({ token: "tok-p1-longer", refresh_token: "ref-p1" }));
    assert.equal(syncKeyring(pool, acct, { python: "/fake/python", run: fakeRun }), true);
    assert.equal(runs.length, 2);

    // Same size, mtime changes: re-seeds.
    const future = new Date(Date.now() + 60_000);
    utimesSync(acct.authFile, future, future);
    assert.equal(syncKeyring(pool, acct, { python: "/fake/python", run: fakeRun }), true);
    assert.equal(runs.length, 3);
  });

  test("no account available: the task fails telling the user to add one in Settings → Profiles → Google Colab", () => {
    const { io } = fakeColab();
    assert.throws(() => acquire(pool, "G4", "s1", [], io), /Settings → Profiles.*Google Colab/);
  });

  test("a chat's next task gets the VM its last one left; another chat's task gets a VM of its own while that one is held", () => {
    const accts = makeAccounts("a");
    const { io, calls } = fakeColab();
    const first = acquire(pool, "G4", "s1", accts, io);
    assert.equal(first.account, "a");
    release(pool, first.vm, io);
    const again = acquire(pool, "G4", "s1", accts, io);
    assert.equal(again.vm, first.vm);
    const other = acquire(pool, "G4", "s2", accts, io);
    assert.notEqual(other.vm, first.vm);
    assert.equal(calls.filter((c) => c.args[0] === "new").length, 2);
  });

  test("a new VM goes to the account holding fewest; one at its limit (412) is passed over for REFUSED_MS", () => {
    const accts = makeAccounts("b", "a"); // unsorted input is sorted by id
    const { io, held } = fakeColab({ limits: { a: 1 } });
    const vms = [
      acquire(pool, "G4", "s1", accts, io),
      acquire(pool, "G4", "s2", accts, io),
      acquire(pool, "G4", "s3", accts, io),
    ];
    // a, b, then a again (fewest held): refused there (412), so b.
    assert.deepEqual(vms.map((v) => v.account), ["a", "b", "b"]);
    assert.deepEqual([...held.values()].map((h) => h.account).sort(), ["a", "b", "b"]);
    assert.ok(state().refused["a:G4"] > 0);
  });

  test("per-account 3 VM/GPU cap: 4th concurrent task waits and fails after waitMs, releasing its queue slot", () => {
    const accts = makeAccounts("a");
    const { io } = fakeColab();
    for (let i = 0; i < PER_ACCOUNT; i++) acquire(pool, "G4", `s${i}`, accts, io);
    assert.throws(() => acquire(pool, "G4", "s-wait", accts, io, 10 * 60_000), /no G4 VM came free in 10 minutes/);
    assert.deepEqual(state().queue, []);
  });

  test("Google has none of a GPU (503): the account is tried again after REFUSED_MS, not at once", () => {
    const accts = makeAccounts("a");
    const { io, calls } = fakeColab({ unavailable: ["H100"] });
    assert.throws(() => acquire(pool, "H100", "s1", accts, io, REFUSED_MS * 3), /no H100 VM came free/);
    const tries = calls.filter((c) => c.args[0] === "new").length;
    assert.ok(tries >= 3 && tries <= 4, `tried ${tries} times`);
  });

  test("a VM no task holds is stopped KEEP_WARM_MS after its last task; one held is not; gone VMs are forgotten", () => {
    const accts = makeAccounts("a");
    const fake = fakeColab({ serverEndpoints: { a: [] } });
    const held = acquire(pool, "G4", "s1", accts, fake.io);
    const free = acquire(pool, "G4", "s2", accts, fake.io);
    release(pool, free.vm, fake.io);
    // Write a vm record for another idle VM whose endpoint is gone from Colab server.
    const gone = acquire(pool, "L4", "s3", accts, fake.io);
    mkdirSync(join(pool, "vms"), { recursive: true });
    writeFileSync(join(pool, "vms", `${gone.vm}.json`), JSON.stringify({ [gone.vm]: { endpoint: "m-gone" } }));
    release(pool, gone.vm, fake.io);

    fake.advance(KEEP_WARM_MS - 1);
    assert.deepEqual(reap(pool, accts, fake.io), []);
    // `gone` was not idle past KEEP_WARM_MS yet, but server `sessions` didn't list `m-gone`, so it was forgotten.
    assert.equal(state().vms[gone.vm], undefined);

    fake.advance(2);
    assert.deepEqual(reap(pool, accts, fake.io), [free.vm]);
    assert.deepEqual([...fake.held.keys()].sort(), [gone.vm, held.vm].sort());
    assert.deepEqual(Object.keys(state().vms), [held.vm]);
  });
  test("a master connection's socket path stays short however long the pool's path, and differs by pool", () => {
    const longPool = join(pool, "x".repeat(160));
    const sock = controlPathOf(longPool, "a100-12345678");
    assert.ok(Buffer.byteLength(sock) < 90, `${sock}: ${Buffer.byteLength(sock)} bytes`);
    assert.ok(sock.endsWith("-a100-12345678.sock"));
    assert.notEqual(controlPathOf(join(pool, "other"), "a100-12345678"), sock);
    assert.equal(dirname(controlPathOf(join(pool, "other"), "a100-12345678")), dirname(sock));
  });

  test("ssh goes through the master connection when there is one, else on its own through `colab ssh --proxy-mode`", () => {
    const sock = controlPathOf(pool, "g4-11111111");
    const shared = sshTo(pool, "g4-11111111", "a", sock);
    assert.ok(shared.includes("ControlMaster=no"));
    assert.ok(shared.includes(`ControlPath=${sock}`));
    // Should the master be gone, ssh connects by itself: the proxy stays.
    assert.ok(shared.some((a: string) => a.startsWith("ProxyCommand=") && a.includes("'--proxy-mode'")));
    const alone = sshTo(pool, "g4-11111111", "a");
    assert.ok(!alone.some((a: string) => a.startsWith("Control")));
    assert.ok(alone.some((a: string) => a.startsWith("ProxyCommand=")));
    assert.equal(alone.at(-1), "root@colab-runtime");

    // Windows: no master (its OpenSSH has none), nothing run.
    const fake = fakeColab();
    assert.equal(ensureControlMaster(pool, "g4-11111111", "a", fake.io, { platform: "win32" }), null);
    assert.deepEqual(fake.runs, []);
  });

  test("a task's master connection is started once with none of the job's pipes, and reused while alive", () => {
    const fake = fakeColab();
    const sock = ensureControlMaster(pool, "g4-11111111", "a", fake.io, { platform: "linux" });
    assert.equal(sock, controlPathOf(pool, "g4-11111111"));
    const starts = fake.runs.filter((r) => r.args[0] === "-M");
    assert.equal(starts.length, 1);
    const start = starts[0]!;
    // stdout and stderr here are the job's pipes: a master outliving the task must not hold them.
    assert.deepEqual(start.opts.stdio, ["ignore", "ignore", "ignore"]);
    const errFile = start.args[start.args.indexOf("-E") + 1]!;
    for (const o of ["ControlMaster=yes", `ControlPath=${sock}`, `ControlPersist=${MUX_PERSIST_S}`]) assert.ok(start.args.includes(o), o);
    assert.ok(start.args.includes("-N") && start.args.includes("-f"));
    // The proxy's own errors (Colab's 429) go to the same file, not to the job.
    const proxy = start.args.find((a) => a.startsWith("ProxyCommand="))!;
    assert.ok(proxy.endsWith(` 2>>'${errFile}'`), proxy);
    assert.ok(fake.runs.every((r) => JSON.stringify(r.opts.stdio) === JSON.stringify(["ignore", "ignore", "ignore"])));
    assert.equal(existsSync(errFile), false);

    // Alive: the next ssh (the results brought back, the chat's next task) start no other.
    fake.runs.length = 0;
    assert.equal(ensureControlMaster(pool, "g4-11111111", "a", fake.io, { platform: "linux" }), sock);
    assert.deepEqual(fake.runs.map((r) => r.args.slice(0, 2)), [["-O", "check"]]);

    // Gone (ControlPersist past, the VM's connection broken): started again, its stale socket removed first.
    fake.setMasterAlive(false);
    fake.runs.length = 0;
    assert.equal(ensureControlMaster(pool, "g4-11111111", "a", fake.io, { platform: "linux" }), sock);
    assert.equal(fake.runs.filter((r) => r.args[0] === "-M").length, 1);
  });

  test("Colab refusing the connection (429) is waited out MUX_RETRY_MS, then the task fails saying so; other errors fail at once", () => {
    const vm = "g4-11111111";
    const fine = fakeColab({ masters: ["[colab] 429 Too Many Requests", "kex_exchange_identification: Connection closed by remote host", "ok"] });
    assert.equal(ensureControlMaster(pool, vm, "a", fine.io, { platform: "linux" }), controlPathOf(pool, vm));
    assert.deepEqual(fine.sleeps, MUX_RETRY_MS);
    assert.equal(fine.runs.filter((r) => r.args[0] === "-M").length, 3);
    rmSync(controlPathOf(pool, vm), { force: true });

    const limited = fakeColab({ masters: ["429 Too Many Requests", "429 Too Many Requests", "429 Too Many Requests", "ok"] });
    assert.throws(() => ensureControlMaster(pool, vm, "a", limited.io, { platform: "linux" }), /Colab VM g4-11111111 \(tried 3 times\): 429 Too Many Requests; start the task again/);
    assert.deepEqual(limited.sleeps, MUX_RETRY_MS);
    assert.equal(existsSync(`${controlPathOf(pool, vm)}.err`), false);

    const denied = fakeColab({ masters: ["root@colab-runtime: Permission denied (publickey)."] });
    assert.throws(() => ensureControlMaster(pool, vm, "a", denied.io, { platform: "linux" }), /tried 1 times\): root@colab-runtime: Permission denied/);
    assert.deepEqual(denied.sleeps, []);
  });

  test("a VM whose task died while starting it is stopped when Colab made it, forgotten when not", () => {
    const accts = makeAccounts("a");
    const fake = fakeColab({ serverEndpoints: { a: [] } });
    const dead = 2 ** 30;
    mkdirSync(pool, { recursive: true });
    const starting = { account: "a", gpu: "G4", state: "starting", holder: dead, chat: "s1", used: 1, started: 1 };
    writeFileSync(join(pool, "state.json"), JSON.stringify({ vms: { "g4-dead0001": starting, "g4-dead0002": starting }, queue: [], refused: {} }));
    mkdirSync(join(pool, "vms"), { recursive: true });
    writeFileSync(join(pool, "vms", "g4-dead0001.json"), JSON.stringify({ "g4-dead0001": { endpoint: "m-1" } }));

    assert.deepEqual(reap(pool, accts, fake.io), ["g4-dead0001"]);
    assert.deepEqual(fake.calls.filter((c) => c.args[0] === "stop"), [{ account: "a", vm: "g4-dead0001", args: ["stop", "-s", "g4-dead0001"] }]);
    assert.equal(existsSync(join(pool, "vms", "g4-dead0001.json")), false);
    assert.deepEqual(state().vms, {});
  });

  test("stopping an idle VM closes its master connection", () => {
    const accts = makeAccounts("a");
    const fake = fakeColab({ serverEndpoints: { a: [] } });
    const { vm } = acquire(pool, "G4", "s1", accts, fake.io);
    const sock = ensureControlMaster(pool, vm, "a", fake.io, { platform: "linux" });
    assert.ok(existsSync(sock));
    release(pool, vm, fake.io);
    fake.advance(KEEP_WARM_MS + 1);
    fake.runs.length = 0;
    assert.deepEqual(reap(pool, accts, fake.io), [vm]);
    assert.deepEqual(fake.runs.map((r) => r.args.slice(0, 3)), [["-O", "exit", "-S"]]);
    assert.equal(fake.runs[0]!.args[3], sock);
    assert.equal(existsSync(sock), false);
  });

  test("a warm VM that has Node is not asked again", () => {
    const accts = makeAccounts("a");
    const { io } = fakeColab();
    const first = acquire(pool, "G4", "s1", accts, io);
    assert.equal(first.nodeReady, undefined);
    markNodeReady(pool, first.vm, io);
    release(pool, first.vm, io);
    const again = acquire(pool, "G4", "s1", accts, io);
    assert.equal(again.vm, first.vm);
    assert.equal(again.nodeReady, true);
  });
});
