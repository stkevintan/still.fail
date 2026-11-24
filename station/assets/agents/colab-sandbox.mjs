// A Colab sandbox's task (station/src/agents/sandbox.ts, kind "colab"): what a job runs in place of its command. It
// takes a Google Colab VM of the sandbox's GPU from the station's pool, runs the task there through sandbox-bridge.mjs
// (its ssh carried by the Colab CLI's ProxyCommand, one connection per task shared by all its ssh: `ensureControlMaster`)
// and hands the VM back, kept warm a while for the chat's next task.
// The pool is a bounded-ephemeral directory of the station's (`pool`, <data>/colab) — authoritative OAuth credentials
// live exclusively in Profiles (`homes/<id>/colab-auth.json`) and are synced into `cli-homes/<id>/` via
// PlaintextKeyring before each CLI invocation:
//
//   venv/                     the Colab CLI (google-colab-cli) + keyrings.alt, installed there the first time needed
//   cli-homes/<profile-id>/   per-profile CLI HOME with PlaintextKeyring seeded from `homes/<id>/colab-auth.json`
//   vms/<vm>.json             the CLI's record of one VM (its endpoint and proxy token)
//   state.json, lock/         the VMs: whose account, which GPU, which chat had it last, who holds it now
//   id_ed25519                the key the station's ssh uses there
//
// Colab never takes a VM back while it runs (its kernel is kept alive), and bills it by the hour: a VM no task holds
// is stopped `KEEP_WARM_MS` after its last one (`reap`, which the station runs: sessions/agents.ts). Measured
// 2026-11-21: an account gets at most 3 VMs of one GPU at a time (a 4th is refused, 412), each GPU counted apart; one
// starts in about 5 s; starting and stopping often is not limited; H100 and A100 answer 503 (Google has none free).
//
//   node colab-sandbox.mjs run '<json>'   {pool, gpu, chat, command, cwd, ports, lostFile, back, bridge, accounts}
//   node colab-sandbox.mjs reap '<json>'  {pool, accounts}
import { spawn, spawnSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { chmodSync, existsSync, lstatSync, mkdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";

/// The GPUs Colab names, and how many of one an account may hold at once.
export const GPUS = ["T4", "L4", "G4", "A100", "H100"];
export const PER_ACCOUNT = 3;
/// How long a VM no task holds is kept for the next (starting one again and setting it up costs more than this does).
export const KEEP_WARM_MS = 3 * 60_000;
/// An account that refused a VM of a GPU (its limit, or Google has none) is not asked for another this long.
export const REFUSED_MS = 60_000;
/// A task that cannot get a VM waits this long at most, then fails saying so.
export const WAIT_MS = 30 * 60_000;
/// The CLI's version the pool installs.
export const CLI = "google-colab-cli==0.8.0";
const CLI_ENV = { PYTHON_KEYRING_BACKEND: "keyrings.alt.file.PlaintextKeyring", COLAB_CLI_ASSIGN_RETRIES: "0", NO_COLOR: "1" };

const KEYRING_SEED_PY = [
  "import keyring, pathlib, sys",
  'keyring.set_password("google-colab-cli", "oauth_token", pathlib.Path(sys.argv[1]).read_text())',
].join("\n");

const say = (s) => process.stderr.write(`[colab] ${s}\n`);
const sleepSync = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

// ── the pool's state ──

export const cliHomeOf = (pool, accountId) => join(pool, "cli-homes", accountId);

/// Ensures `<pool>/cli-homes/<id>` has a PlaintextKeyring entry matching `account.authFile` (checked by mtimeMs + size).
/// Returns `true` if the keyring was written, `false` if already up to date.
export function syncKeyring(pool, account, opts = {}) {
  const st = statSync(account.authFile);
  const stamp = `${st.mtimeMs}:${st.size}`;
  const home = cliHomeOf(pool, account.id);
  const metaFile = join(home, ".seeded-meta");
  if (existsSync(metaFile)) {
    try {
      if (readFileSync(metaFile, "utf8").trim() === stamp) return false;
    } catch {}
  }
  mkdirSync(home, { recursive: true, mode: 0o700 });
  try { chmodSync(home, 0o700); } catch {}
  const python = opts.python ?? join(pool, "venv", "bin", "python");
  const r = (opts.run ?? spawnSync)(python, ["-c", KEYRING_SEED_PY, account.authFile], {
    env: { ...process.env, ...CLI_ENV, HOME: home },
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    timeout: 60_000,
  });
  if ((r.status ?? 1) !== 0) {
    throw new Error(`failed to sync Colab keyring for ${account.id}: ${`${r.stdout ?? ""}${r.stderr ?? ""}`.trim().slice(-400)}`);
  }
  writeFileSync(metaFile, `${stamp}\n`, { mode: 0o600 });
  return true;
}

/// Runs `f` on the pool's state under its lock (a directory: made atomically; one left by a process gone is taken).
export function locked(pool, io, f) {
  mkdirSync(pool, { recursive: true });
  const lock = join(pool, "lock");
  for (;;) {
    try {
      mkdirSync(lock);
      writeFileSync(join(lock, "pid"), String(process.pid));
      break;
    } catch (e) {
      if (e.code !== "EEXIST") throw e;
      let holder = 0;
      try { holder = Number(readFileSync(join(lock, "pid"), "utf8")); } catch {}
      let age = 0;
      try { age = io.now() - statSync(lock).mtimeMs; } catch {}
      if ((holder > 0 && !io.alive(holder)) || age > 60_000) rmSync(lock, { recursive: true, force: true });
      else io.sleep(50);
    }
  }
  try {
    const file = join(pool, "state.json");
    let st = {};
    try { st = JSON.parse(readFileSync(file, "utf8")); } catch {}
    st.vms ??= {};
    st.queue ??= [];
    st.refused ??= {};
    const out = f(st);
    writeFileSync(file + ".tmp", JSON.stringify(st, null, 1));
    renameSync(file + ".tmp", file);
    return out;
  } finally {
    rmSync(lock, { recursive: true, force: true });
  }
}

const vmFile = (pool, vm) => join(pool, "vms", `${vm}.json`);
const holderLive = (v, io) => v.holder != null && io.alive(v.holder);

/// The pool's io: the CLI, other commands (`run`, spawnSync's), the clock, sleeping, whether a process lives. Tests
/// give their own.
export function realIo(pool) {
  return {
    now: () => Date.now(),
    sleep: sleepSync,
    run: (cmd, args, opts) => spawnSync(cmd, args, opts),
    alive: (pid) => {
      try { process.kill(pid, 0); return true; } catch (e) { return e.code === "EPERM"; }
    },
    colab: (account, vm, args) => {
      syncKeyring(pool, account);
      mkdirSync(join(pool, "vms"), { recursive: true });
      const home = cliHomeOf(pool, account.id);
      const r = spawnSync(join(pool, "venv", "bin", "colab"), ["--config", vm === null ? join(home, "probe.json") : vmFile(pool, vm), ...args], {
        env: { ...process.env, ...CLI_ENV, HOME: home }, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], timeout: 300_000,
      });
      return { code: r.status ?? 1, out: `${r.stdout ?? ""}${r.stderr ?? ""}` };
    },
  };
}

function normalizeAccounts(accounts) {
  if (!Array.isArray(accounts)) return [];
  return accounts
    .filter((a) => a && typeof a.id === "string" && a.id !== "" && typeof a.authFile === "string" && a.authFile !== "")
    .map((a) => ({ id: a.id, authFile: a.authFile }))
    .sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
}

/// A VM of `gpu` for `chat`, held by this process: the chat's own when it has one free (what its tasks left there is
/// still there), else any free one of the GPU, else a new one on the account holding fewest, else it waits its turn
/// (first come, first served, for each GPU). Returns the VM's name and account.
export function acquire(pool, gpu, chat, accounts, io, waitMs = WAIT_MS) {
  const list = normalizeAccounts(accounts);
  if (list.length === 0) {
    throw new Error("no Google Colab account is available for this workspace: add one in Settings → Profiles → Add Account → Google → Google Colab (设置 → Profiles → 添加账号 → Google → Google Colab), then start the task again");
  }
  const byId = new Map(list.map((a) => [a.id, a]));
  const ticket = `${process.pid}-${io.now()}`;
  const deadline = io.now() + waitMs;
  locked(pool, io, (st) => void st.queue.push({ ticket, gpu, pid: process.pid }));
  let told = 0;
  try {
    for (;;) {
      const now = io.now();
      const step = locked(pool, io, (st) => {
        st.queue = st.queue.filter((q) => io.alive(q.pid));
        for (const [k, until] of Object.entries(st.refused)) if (until <= now) delete st.refused[k];
        const waiting = st.queue.filter((q) => q.gpu === gpu);
        const position = waiting.findIndex((q) => q.ticket === ticket);
        if (position > 0) return { wait: position };
        const free = Object.entries(st.vms).filter(([, v]) => v.gpu === gpu && v.state === "ready" && !holderLive(v, io) && byId.has(v.account));
        free.sort(([, a], [, b]) => (b.chat === chat) - (a.chat === chat) || b.used - a.used);
        const leave = () => { st.queue = st.queue.filter((q) => q.ticket !== ticket); };
        if (free.length > 0) {
          const [vm, v] = free[0];
          Object.assign(v, { holder: process.pid, chat, used: now });
          leave();
          return { vm, account: v.account, reused: true, nodeReady: v.nodeReady === true };
        }
        const held = (id) => Object.values(st.vms).filter((v) => v.gpu === gpu && v.account === id).length;
        const open = list.filter((a) => held(a.id) < PER_ACCOUNT && !st.refused[`${a.id}:${gpu}`]);
        if (open.length === 0) return { wait: 0 };
        const chosen = open.reduce((a, b) => (held(b.id) < held(a.id) ? b : a));
        const vm = `${gpu.toLowerCase()}-${randomBytes(4).toString("hex")}`;
        st.vms[vm] = { account: chosen.id, gpu, state: "starting", holder: process.pid, chat, used: now, started: now };
        leave();
        return { vm, account: chosen.id, start: true };
      });
      if (step.vm !== undefined && !step.start) {
        say(`reusing VM ${step.vm} (${gpu}, account ${step.account})`);
        return { ...step, authFile: byId.get(step.account).authFile };
      }
      if (step.start) {
        const acct = byId.get(step.account);
        say(`starting a ${gpu} VM on account ${step.account}`);
        const r = io.colab(acct, step.vm, ["new", "-s", step.vm, "--gpu", gpu]);
        const ok = r.code === 0 && /READY/.test(r.out);
        const refused = /precondition|\b412\b/i.test(r.out) ? "its limit of VMs" : /Service Unavailable|\b503\b/.test(r.out) ? "no free machine at Google" : null;
        locked(pool, io, (st) => {
          if (ok) st.vms[step.vm].state = "ready";
          else {
            delete st.vms[step.vm];
            st.refused[`${step.account}:${gpu}`] = io.now() + (refused ? REFUSED_MS : 15_000);
            st.queue.unshift({ ticket, gpu, pid: process.pid });
          }
        });
        if (ok) return { ...step, authFile: acct.authFile };
        say(refused ? `account ${step.account} gave no ${gpu} (${refused})` : `starting a VM failed: ${r.out.trim().slice(-400)}`);
        continue;
      }
      if (io.now() > deadline) throw new Error(`no ${gpu} VM came free in ${Math.round(waitMs / 60_000)} minutes: every account is at its limit or Google has none; start the task again later, or add another Google Colab profile in Settings → Profiles`);
      if (io.now() - told > 60_000) {
        say(step.wait > 0 ? `waiting for a ${gpu}: ${step.wait} task(s) ahead` : `waiting for a ${gpu}: every account holds ${PER_ACCOUNT} or was refused one`);
        told = io.now();
      }
      io.sleep(3000);
    }
  } finally {
    locked(pool, io, (st) => { st.queue = st.queue.filter((q) => q.ticket !== ticket); });
  }
}

/// Hands `vm` back: kept warm for KEEP_WARM_MS (reap stops it after).
export function release(pool, vm, io) {
  locked(pool, io, (st) => {
    const v = st.vms[vm];
    if (v && v.holder === process.pid) Object.assign(v, { holder: null, used: io.now() });
  });
}

/// Notes that `vm` has Node (`ensureNode`), so the next task there need not ask.
export function markNodeReady(pool, vm, io) {
  locked(pool, io, (st) => { if (st.vms[vm]) st.vms[vm].nodeReady = true; });
}

/// Stops the VMs no live task holds whose last use is KEEP_WARM_MS past (none while a task waits for their GPU), and
/// those whose task died while starting them (Colab made the VM once `vms/<vm>.json` is written, and bills it), and
/// forgets those Colab no longer has. Returns the names stopped.
export function reap(pool, accounts, io) {
  const list = normalizeAccounts(accounts);
  const byId = new Map(list.map((a) => [a.id, a]));
  const now = io.now();
  const stop = locked(pool, io, (st) => {
    st.queue = st.queue.filter((q) => io.alive(q.pid));
    const out = [];
    for (const [vm, v] of Object.entries(st.vms)) {
      if (v.state === "starting" && !holderLive(v, io)) {
        if (existsSync(vmFile(pool, vm))) {
          v.state = "stopping";
          out.push([vm, v.account]);
        } else {
          delete st.vms[vm];
          closeControlMaster(pool, vm, io);
        }
        continue;
      }
      if (v.state !== "ready" || holderLive(v, io)) continue;
      if (now - v.used < KEEP_WARM_MS || st.queue.some((q) => q.gpu === v.gpu)) continue;
      v.state = "stopping";
      out.push([vm, v.account]);
    }
    return out;
  });
  for (const [vm, accountId] of stop) {
    const acct = byId.get(accountId);
    if (acct !== undefined) io.colab(acct, vm, ["stop", "-s", vm]);
    rmSync(vmFile(pool, vm), { force: true });
    closeControlMaster(pool, vm, io);
    locked(pool, io, (st) => void delete st.vms[vm]);
    say(`stopped VM ${vm} (idle)`);
  }
  // Those Colab took back or a person stopped: its list of the account's VMs no longer names their endpoint.
  const activeAccounts = locked(pool, io, (st) => new Set(Object.values(st.vms).map((v) => v.account)));
  for (const acct of list) {
    if (!activeAccounts.has(acct.id)) continue;
    const r = io.colab(acct, null, ["sessions"]);
    if (r.code !== 0) continue;
    const listed = new Set([...r.out.matchAll(/\]\s+(\S+)\s+\|/g)].map((m) => m[1]));
    locked(pool, io, (st) => {
      for (const [vm, v] of Object.entries(st.vms)) {
        if (v.account !== acct.id || v.state !== "ready" || holderLive(v, io)) continue;
        let endpoint = null;
        try { endpoint = JSON.parse(readFileSync(vmFile(pool, vm), "utf8"))[vm]?.endpoint ?? null; } catch {}
        if (endpoint !== null && !listed.has(endpoint)) {
          delete st.vms[vm];
          rmSync(vmFile(pool, vm), { force: true });
          closeControlMaster(pool, vm, io);
        }
      }
    });
  }
  return stop.map(([vm]) => vm);
}

// ── the CLI and the VM ──

/// The Colab CLI installed in the pool, where it is not yet (Python 3.10 or newer is needed).
function ensureCli(pool) {
  if (existsSync(join(pool, "venv", "bin", "colab"))) return;
  say("installing the Colab CLI (once)");
  mkdirSync(pool, { recursive: true });
  const python = ["python3.13", "python3.12", "python3.11", "python3.10", "python3"].find((p) => spawnSync(p, ["-c", "import sys; sys.exit(sys.version_info < (3, 10))"]).status === 0);
  if (python === undefined) throw new Error("the Colab CLI needs Python 3.10 or newer on this station: install it, then start the task again");
  const run = (cmd, args) => {
    const r = spawnSync(cmd, args, { stdio: ["ignore", "inherit", "inherit"] });
    if (r.status !== 0) throw new Error(`${cmd} ${args.join(" ")} failed`);
  };
  rmSync(join(pool, "venv"), { recursive: true, force: true });
  run(python, ["-m", "venv", join(pool, "venv")]);
  run(join(pool, "venv", "bin", "pip"), ["install", "-q", CLI, "keyrings.alt"]);
}

function ensureKey(pool) {
  const key = join(pool, "id_ed25519");
  if (!existsSync(key)) spawnSync("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "stillfail-colab", "-f", key]);
  return key;
}

const HOST = "root@colab-runtime";
const quoted = (w) => `'${w.replace(/'/g, `'\\''`)}'`;

/// ssh's options to `vm`: its connection carried by `colab ssh --proxy-mode` (`proxyTail` added to that command).
function sshOptions(pool, vm, accountId, proxyTail = "") {
  const key = join(pool, "id_ed25519");
  const env = Object.entries({ ...CLI_ENV, HOME: cliHomeOf(pool, accountId) }).map(([k, v]) => `${k}=${v}`);
  const proxy = ["env", ...env, join(pool, "venv", "bin", "colab"), "--config", vmFile(pool, vm), "ssh", "--proxy-mode", "-s", vm, "--identity", key]
    .map(quoted).join(" ") + proxyTail;
  return ["-T", "-o", "BatchMode=yes", "-o", `ProxyCommand=${proxy}`, "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
    "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4", "-i", key, "-o", "IdentitiesOnly=yes"];
}

/// ssh's command line to `vm`, up to the remote command: through the task's shared connection at `sock`
/// (`ensureControlMaster`) when given, else (or should that connection be gone) its own `colab ssh --proxy-mode`.
export function sshTo(pool, vm, accountId, sock = null) {
  const mux = sock ? ["-o", "ControlMaster=no", "-o", `ControlPath=${sock}`] : [];
  return ["ssh", ...mux, ...sshOptions(pool, vm, accountId), HOST];
}

// ── one connection to a VM, shared ──
//
// Each `colab ssh --proxy-mode` asks Colab's API for the VM's tunnel, and a few within seconds are refused (429): a
// task's ssh (Node's check, the task, the results brought back) all go through one master connection instead, kept
// MUX_PERSIST_S after its last use for the chat's next task on the warm VM and closed when reap stops the VM. Not on
// Windows (its OpenSSH has no ControlMaster). The master is started with nothing of this process's open (stdio
// ignored, ssh's log and the proxy's stderr to a file): this process's stdout and stderr are the job's pipes, which
// would never close while a master outliving the task held them.

/// How long a master connection stays after its last ssh (more than KEEP_WARM_MS: reap closes it with the VM).
export const MUX_PERSIST_S = 240;
/// Waits before starting a master again after Colab refused (429) or the connection broke (a VM just started).
export const MUX_RETRY_MS = [2000, 5000];
const TRANSIENT = /\b429\b|too many requests|rate.?limit|kex_exchange_identification|connection (?:closed|reset|refused|timed out)|timed out|UNKNOWN port/i;
const IGNORED = ["ignore", "ignore", "ignore"];

/// The master connection's socket for `vm`: short, as a Unix socket's path is at most 104 bytes on macOS (ssh adds
/// 17 while making it), in a directory of this user's; the pool's hash keeps stations of one user apart.
export function controlPathOf(pool, vm) {
  const uid = typeof process.getuid === "function" ? process.getuid() : "";
  const name = `${createHash("sha256").update(pool).digest("hex").slice(0, 8)}-${vm}.sock`;
  const path = join(tmpdir(), `sfc${uid}`, name);
  return Buffer.byteLength(path) <= 84 ? path : join("/tmp", `sfc${uid}`, name);
}

/// The socket's directory, made only this user's: false when it is someone else's (their socket would get the task).
function ownDir(dir) {
  try {
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    const s = lstatSync(dir);
    if (!s.isDirectory() || (typeof process.getuid === "function" && s.uid !== process.getuid())) return false;
    if ((s.mode & 0o077) !== 0) chmodSync(dir, 0o700);
    return true;
  } catch {
    return false;
  }
}

const muxAlive = (sock, io) => (io.run("ssh", ["-O", "check", "-S", sock, "-o", "BatchMode=yes", HOST], { stdio: IGNORED, timeout: 15_000 }).status ?? 1) === 0;

/// The master connection to `vm`, started when there is none alive: its socket, for `sshTo`, or null where there is
/// none to share (Windows, a socket directory not this user's). Throws when Colab keeps refusing or the VM is
/// unreachable.
export function ensureControlMaster(pool, vm, accountId, io, { platform = process.platform } = {}) {
  if (platform === "win32") return null;
  const sock = controlPathOf(pool, vm);
  if (!ownDir(dirname(sock))) {
    say(`${dirname(sock)} is not this user's: each ssh to the VM connects on its own`);
    return null;
  }
  if (existsSync(sock) && muxAlive(sock, io)) return sock;
  const errFile = `${sock}.err`;
  for (let attempt = 0; ; attempt++) {
    rmSync(sock, { force: true });
    rmSync(errFile, { force: true });
    const r = io.run("ssh", ["-M", "-N", "-f", "-E", errFile, "-o", "ControlMaster=yes", "-o", `ControlPath=${sock}`, "-o", `ControlPersist=${MUX_PERSIST_S}`,
      ...sshOptions(pool, vm, accountId, ` 2>>${quoted(errFile)}`), HOST], { stdio: IGNORED, timeout: 120_000 });
    if ((r.status ?? 1) === 0 && muxAlive(sock, io)) {
      rmSync(errFile, { force: true });
      return sock;
    }
    let err = "";
    try { err = readFileSync(errFile, "utf8").trim(); } catch {}
    rmSync(errFile, { force: true });
    const why = err.slice(-400) || (r.error ? r.error.message : `ssh exited ${r.status ?? r.signal}`);
    if (attempt >= MUX_RETRY_MS.length || !(TRANSIENT.test(err) || r.error?.code === "ETIMEDOUT")) {
      throw new Error(`could not connect to the Colab VM ${vm} (tried ${attempt + 1} times): ${why}; start the task again in a few minutes`);
    }
    say(`connecting to VM ${vm} failed (${why.split("\n").pop()}); again in ${MUX_RETRY_MS[attempt] / 1000} s`);
    io.sleep(MUX_RETRY_MS[attempt]);
  }
}

/// Ends `vm`'s master connection, when it has one.
export function closeControlMaster(pool, vm, io, { platform = process.platform } = {}) {
  if (platform === "win32") return;
  const sock = controlPathOf(pool, vm);
  if (!existsSync(sock)) return;
  io.run("ssh", ["-O", "exit", "-S", sock, "-o", "BatchMode=yes", HOST], { stdio: IGNORED, timeout: 15_000 });
  rmSync(sock, { force: true });
}

/// Node on the VM (the bridge's far side runs on it; Colab's image has none): this Node's version, from nodejs.org.
function ensureNode(ssh) {
  const v = process.version;
  const script = `command -v node >/dev/null || { curl -fsSL https://nodejs.org/dist/${v}/node-${v}-linux-x64.tar.xz | tar xJ -C /usr/local --strip-components=1; }`;
  const r = spawnSync(ssh[0], [...ssh.slice(1), script], { stdio: ["ignore", "inherit", "inherit"] });
  if (r.status !== 0) throw new Error("could not put Node on the VM");
}

const bridged = (bridge, spec) => new Promise((resolve) => {
  const child = spawn(process.execPath, [bridge, "host", JSON.stringify(spec)], { stdio: "inherit" });
  const handlers = ["SIGTERM", "SIGINT", "SIGHUP"].map((s) => {
    const fn = () => child.kill(s);
    process.on(s, fn);
    return [s, fn];
  });
  child.on("exit", (code, signal) => {
    for (const [s, fn] of handlers) process.off(s, fn);
    resolve(code ?? (signal ? 128 : 1));
  });
});

async function runTask(o) {
  if (!GPUS.includes(o.gpu)) throw new Error(`no GPU ${o.gpu} at Colab (${GPUS.join(", ")})`);
  ensureCli(o.pool);
  ensureKey(o.pool);
  const io = realIo(o.pool);
  const { vm, account, authFile, nodeReady } = acquire(o.pool, o.gpu, o.chat, o.accounts, io);
  try {
    syncKeyring(o.pool, { id: account, authFile });
    const sock = ensureControlMaster(o.pool, vm, account, io);
    const ssh = sshTo(o.pool, vm, account, sock);
    if (!nodeReady) {
      ensureNode(ssh);
      markNodeReady(o.pool, vm, io);
    }
    const rootPath = o.data ?? dirname(o.pool);
    const base = { root: { path: rootPath }, dirs: [o.cwd] };
    const runSpec = {
      ...base,
      ports: Array.isArray(o.ports) ? o.ports : [],
      sync: [{ path: o.cwd, mode: "whole", back: false, dir: true }],
      program: "/bin/sh",
      args: ["-c", o.command],
      cwd: o.cwd,
      lostFile: o.lostFile,
      own: "all",
    };
    const backPaths = Array.isArray(o.back) ? o.back : [];
    const backSpec = backPaths.length === 0 ? null : {
      ...base,
      sync: backPaths.map((b) => ({ path: join(o.cwd, b), mode: "whole", push: false, dir: false })),
    };
    const code = await bridged(o.bridge, { ...runSpec, ssh });
    // What it brings back, on the master connection started again should it be gone; once more when that failed
    // (seen once on a VM just started: the first connection after the task's own never answered).
    const back = () => {
      if (sock !== null) {
        try { ensureControlMaster(o.pool, vm, account, io); } catch (e) { say(e.message); }
      }
      return bridged(o.bridge, { ...backSpec, ssh });
    };
    if (backSpec && (await back()) !== 0) {
      say("bringing the results back failed; once more");
      await back();
    }
    return code;
  } finally {
    release(o.pool, vm, io);
  }
}

async function main() {
  const [what, json] = process.argv.slice(2);
  const o = JSON.parse(json ?? "{}");
  try {
    if (what === "run") process.exit(await runTask(o));
    if (what === "reap") {
      if (!existsSync(join(o.pool, "venv", "bin", "colab"))) return;
      reap(o.pool, o.accounts ?? [], realIo(o.pool));
      return;
    }
    throw new Error("colab-sandbox.mjs run|reap '<json>'");
  } catch (e) {
    say(e.message);
    process.exit(1);
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) await main();
