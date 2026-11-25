// Antigravity CLI driver: one `agy acp` per session, spoken to in ACP (acp.ts) with one ACP session in it. See
//. Beside what ACP says:
// - its files (sign-in, settings, conversations) are in the profile's, `--gemini-dir`: none of the machine's ~/.gemini,
//   and none of the OS keyring's (`AGY_FILE_TOKENS`);
// - the station's instructions are appended to its system prompt (`_meta.antigravity.systemPrompt.append` of
//   session/new and session/load, which initialize says it takes);
// - it runs without approvals (`--dangerously-skip-permissions`), with no telemetry and no updating itself;
// - a message for the running turn steers it (`promptTakeover`); its model is session/set_model;
// - the station keeps the transcript (acp.ts KeptTranscript), with each turn's usage: the prompt's answer says it.
import { execFile } from "node:child_process";
import type { Stats } from "node:fs";
import { access, copyFile, cp, link as hardLink, lstat, mkdir, readdir, realpath, rename, rm, stat, writeFile, readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { Duration, Effect, type Clock } from "effect";
import { liveClock, wall } from "../ops/fibers.ts";
import { writePrivateSoon } from "../ops/files.ts";
import { link as linkPath } from "../ops/links.ts";
import { log } from "../ops/log.ts";
import { platform } from "../platform/index.ts";
import { peerHttpBase } from "../tools/http.ts";
import { AcpDriver, AcpSession, KeptTranscript, errorText, type AcpStart } from "./acp.ts";
import type { Events } from "./own-process.ts";
import { accessKind, expandRoute, profileEnv, profileModel, profileVia, vertexKeyFile } from "./profiles.ts";
import { AGY_REPO_RULES_COMMAND } from "./repo-rules.ts";
import { cleanEnv, failureOf, uuid, type FailureReason, type OpenOptions, type Profile } from "./runtime.ts";
import { keepLocal } from "../ops/agent-env.ts";

type Json = any;

/// Inherited variables that would let a session use another account or project than its profile's, or silence its hooks.
const SCRUBBED = ["GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_GENAI_USE_VERTEXAI", "GOOGLE_APPLICATION_CREDENTIALS", "GOOGLE_CLOUD_PROJECT", "GOOGLE_CLOUD_LOCATION", "AGY_ADC_AUTH", "AGY_ACCOUNT", "STILLFAIL_REPO_RULES"];
/// The CLI's home in a profile's: what `agy` signs in to with this as its HOME, its .gemini/ the ACP server's
/// `--gemini-dir`.
export const agyHome = (home: string) => join(home, "agy");
export const geminiDir = (home: string) => join(agyHome(home), ".gemini");
/// Where its sign-in to a Google account lands in that home (its TUI's, `agy` with the profile's agy/ as its HOME:
/// accounts/login.ts), which the ACP server reads from `--gemini-dir`: a file, `id_token_email` whose account it is.
export const agyToken = (home: string) => agyTokenIn(geminiDir(home));
/// The sign-in's file in a `--gemini-dir`.
export const agyTokenIn = (gemini: string) => join(gemini, "antigravity-cli", "antigravity-oauth-token");
/// Where the station notes the Google account's email when `agyToken` is written or checked: the account's name, and
/// which keychain item is this profile's (`agyTakeBack`).
export const agyAccountFile = (home: string) => join(agyHome(home), "account.json");
/// Where `agy acp` keeps its conversation databases under `--gemini-dir` once a signed-in session opens.
export const agyConversations = (home: string) => join(geminiDir(home), "antigravity-cli", "conversations");

/// How many conversations this process brought in (`agyBringIn`): the names it copies beside under.
let bringSeq = 0;

/// Conversation `id` brought into the CLI's store of profile home `home` from another home beside it (the station's
/// `homes/`) that kept it last: its database (and `-wal`), `annotations/<id>.pbtxt` and `brain/<id>/`
/// (replica/carry.ts `cliKept`). A chat moved from another station comes with what its CLI kept under the id of the
/// profile it ran on there, which may be known here by another (a login lent: `sh-…`); `session/load` finds the
/// conversation only in the profile's own `--gemini-dir`. One that went from this profile to another and back (a
/// quota's switch, a move there and back on another login) finds an older copy here: the home whose database or its
/// `-wal` was written last is the one taken, here kept where none is later. What comes is that home's whole, never
/// joined with what was here: its `-wal` with its database, or none (a `-wal` left beside a database it is not of is
/// replayed into it, which the CLI then finds malformed, 2026-11-16), the `-shm` made again, `annotations` and `brain`
/// as there. In the order that leaves a database here whole at every step: what was here of it out, the database put,
/// then its `-wal`. The name of the home it came from; null where nothing was brought.
export async function agyBringIn(home: string, id: string): Promise<string | null> {
  if (!SESSION_ID.test(id)) return null;
  const cliOf = (h: string) => join(geminiDir(h), "antigravity-cli");
  const here = cliOf(home);
  const homes = dirname(home);
  let best: { name: string; cli: string; at: number } | null = null;
  const mine = await lastWritten(here, id);
  for (const name of (await readdir(homes).catch(() => [] as string[])).sort()) {
    const other = join(homes, name);
    if (other === home) continue;
    const at = await lastWritten(cliOf(other), id);
    if (at !== null && (mine === null || at > mine) && (best === null || at > best.at)) best = { name, cli: cliOf(other), at };
  }
  if (best === null) return null;
  const { name, cli } = best;
  const db = join(here, "conversations", `${id}.db`);
  await mkdir(join(here, "conversations"), { recursive: true });
  const fromWal = (await there(join(cli, "conversations", `${id}.db-wal`))) ? join(cli, "conversations", `${id}.db-wal`) : null;
  // (copied beside first, so that what was here goes only once all of it came; under names of its own, so that two
  // bringing it at once, or one left by a failed one, are not each other's)
  const n = ++bringSeq;
  const dbBringing = `${db}.${process.pid}.${n}.bringing`;
  const walBringing = `${db}-wal.${process.pid}.${n}.bringing`;
  await cp(join(cli, "conversations", `${id}.db`), dbBringing, { preserveTimestamps: true });
  if (fromWal !== null) await cp(fromWal, walBringing, { preserveTimestamps: true });
  for (const [dir, entry] of [["annotations", `${id}.pbtxt`], ["brain", id]] as const) {
    await rm(join(here, dir, entry), { recursive: true, force: true });
    if (!(await there(join(cli, dir, entry)))) continue;
    await mkdir(join(here, dir), { recursive: true });
    await cp(join(cli, dir, entry), join(here, dir, entry), { recursive: true, preserveTimestamps: true });
  }
  await rm(`${db}-wal`, { force: true });
  await rm(`${db}-shm`, { force: true });
  await rename(dbBringing, db);
  if (fromWal !== null) await rename(walBringing, `${db}-wal`);
  log.info("agy", "a conversation brought into the profile's CLI from another home of the station", { id, from: name, to: home });
  return name;
}

/// When the CLI at `cli` last wrote conversation `id` (its database's time, or its `-wal`'s where later); null where it
/// keeps none.
async function lastWritten(cli: string, id: string): Promise<number | null> {
  const db = await stat(join(cli, "conversations", `${id}.db`)).catch(() => null);
  if (db === null) return null;
  const wal = await stat(join(cli, "conversations", `${id}.db-wal`)).catch(() => null);
  return Math.max(db.mtimeMs, wal?.mtimeMs ?? 0);
}

const there = (path: string): Promise<boolean> => stat(path).then(() => true, () => false);
export function agyEmailIn(text: string): string | null {
  try {
    const email = JSON.parse(text)?.id_token_email;
    return typeof email === "string" && email !== "" ? email : null;
  } catch {
    return null;
  }
}

export async function noteAgyEmail(home: string, text: string): Promise<string | null> {
  let parsed: Json;
  try {
    parsed = JSON.parse(text);
  } catch {
    await rm(agyAccountFile(home), { force: true }).catch(() => {});
    return null;
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    await rm(agyAccountFile(home), { force: true }).catch(() => {});
    return null;
  }
  const raw = parsed.id_token_email;
  const email = typeof raw === "string" && raw !== "" ? raw : null;
  try {
    await writeFile(agyAccountFile(home), `${JSON.stringify(email !== null ? { email } : {})}\n`);
  } catch {}
  return email;
}

export async function agyNotedEmail(home: string): Promise<string | null> {
  try {
    const email = JSON.parse(await readFile(agyAccountFile(home), "utf8"))?.email;
    return typeof email === "string" && email !== "" ? email : null;
  } catch {
    return null;
  }
}

/// On desktop OSes, `agy` keeps its sign-in in one OS keyring item for the whole user (service `gemini`, account
/// `antigravity`, through go-keyring: macOS login keychain, Linux Secret Service, Windows Credential Manager), which
/// `--gemini-dir` does not separate: it reads that item before the profile's `agyToken`, and moved the file there, so
/// every profile ran on whichever account was put there last (2026-11-14: a session moved to another account went on
/// with the first one's quota; on Linux the moved file also left the profile appearing signed out). Where it thinks it
/// is in an SSH session it keeps the sign-in in the file alone ("Using file-based token storage because SSH session
/// detected", 1.5.9), so the station's processes are given that (`agyEnv`, agy-quota.ts, `agyRenew`, accounts/login.ts).
export const AGY_FILE_TOKENS = { SSH_CLIENT: "127.0.0.1 0 0" };

type KeyringExecResult = { error: (Error & { code?: string | number | null }) | null; stdout: string };
type KeyringExec = (file: string, args: readonly string[], env: NodeJS.ProcessEnv) => Promise<KeyringExecResult>;

const defaultKeyringExec: KeyringExec = (file, args, env) =>
  new Promise((resolve) => {
    execFile(file, args, { env, timeout: 5000, killSignal: "SIGKILL" }, (error, stdout) =>
      resolve({ error, stdout: String(stdout) }),
    );
  });

const LINUX_KEYRING_NO_GI = 3;
const LINUX_KEYRING_PY = [
  "import sys",
  "try:",
  "    from gi.repository import Gio, GLib",
  "except Exception:",
  `    sys.exit(${LINUX_KEYRING_NO_GI})`,
  "bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)",
  "svc = Gio.DBusProxy.new_sync(bus, Gio.DBusProxyFlags.NONE, None, 'org.freedesktop.secrets', '/org/freedesktop/secrets', 'org.freedesktop.Secret.Service', None)",
  "_, session = svc.call_sync('OpenSession', GLib.Variant('(sv)', ('plain', GLib.Variant('s', ''))), Gio.DBusCallFlags.NONE, 3000, None).unpack()",
  "try:",
  "    unlocked, _ = svc.call_sync('SearchItems', GLib.Variant('(a{ss})', ({'service': 'gemini', 'username': 'antigravity'},)), Gio.DBusCallFlags.NONE, 3000, None).unpack()",
  "    if not unlocked:",
  "        sys.exit(1)",
  "    secrets, = svc.call_sync('GetSecrets', GLib.Variant('(aoo)', ([unlocked[0]], session)), Gio.DBusCallFlags.NONE, 3000, None).unpack()",
  "    secret = secrets.get(unlocked[0])",
  "    if secret is None:",
  "        sys.exit(1)",
  "    sys.stdout.buffer.write(bytes(secret[2]))",
  "finally:",
  "    try:",
  "        Gio.DBusProxy.new_sync(bus, Gio.DBusProxyFlags.NONE, None, 'org.freedesktop.secrets', session, 'org.freedesktop.Secret.Session', None).call_sync('Close', None, Gio.DBusCallFlags.NONE, 1000, None)",
  "    except Exception:",
  "        pass",
].join("\n");

async function hasLinuxSessionBus(env: NodeJS.ProcessEnv): Promise<boolean> {
  if (typeof env.DBUS_SESSION_BUS_ADDRESS === "string" && env.DBUS_SESSION_BUS_ADDRESS.trim() !== "") return true;
  const runtimeDir = typeof env.XDG_RUNTIME_DIR === "string" ? env.XDG_RUNTIME_DIR.trim() : "";
  if (runtimeDir === "") return false;
  return stat(join(runtimeDir, "bus")).then(
    (s) => s.isSocket(),
    () => false,
  );
}

/// Reads the `gemini`/`antigravity` item from Linux Secret Service without prompting to unlock a locked keyring.
/// Queries unlocked items over D-Bus via PyGObject first, falling back to `secret-tool` only when `python3` or
/// `gi.repository` is unavailable.
export async function readLinuxAgyKeyring(env: NodeJS.ProcessEnv = process.env, run: KeyringExec = defaultKeyringExec): Promise<string | null> {
  if (!(await hasLinuxSessionBus(env))) return null;
  const py = await run("python3", ["-c", LINUX_KEYRING_PY], env);
  if (py.error === null) {
    const text = py.stdout.trim();
    return text === "" ? null : text;
  }
  const code = (py.error as { code?: unknown }).code;
  if (code !== "ENOENT" && code !== LINUX_KEYRING_NO_GI) return null;
  const tool = await run("secret-tool", ["lookup", "service", "gemini", "username", "antigravity"], env);
  if (tool.error !== null) return null;
  const text = tool.stdout.trim();
  return text === "" ? null : text;
}

/// The keyring item `agy` kept a sign-in in before `AGY_FILE_TOKENS`, or null. Replaced in tests.
export const agyKeychain = {
  read: (): Promise<string | null> => {
    if (platform.hasKeychain) {
      return new Promise<string | null>((resolve) => {
        execFile("/usr/bin/security", ["find-generic-password", "-s", "gemini", "-a", "antigravity", "-w"], { timeout: 5000, killSignal: "SIGKILL" }, (error, stdout) => {
          if (error) return resolve(null);
          const text = String(stdout).trim();
          resolve(text === "" ? null : text);
        });
      });
    }
    if (platform.os === "linux") return readLinuxAgyKeyring();
    return Promise.resolve(null);
  },
};

/// go-keyring's stored value as `agy` wrote it: base64 or hex behind a prefix, else as it is.
export function goKeyringValue(stored: string): string {
  if (stored.startsWith("go-keyring-base64:")) return Buffer.from(stored.slice("go-keyring-base64:".length), "base64").toString("utf8");
  if (stored.startsWith("go-keyring-encoded:")) return Buffer.from(stored.slice("go-keyring-encoded:".length), "hex").toString("utf8");
  return stored;
}

/// Whether the profile has its sign-in in its `agyToken`, moving it back there from the OS keyring where `agy` moved
/// it before `AGY_FILE_TOKENS`: only when the item is the account the profile noted (`agyAccountFile`), since the item
/// is the last account signed in on the machine, not necessarily this profile's. One whose item is another account's
/// signs in again. The item is left: it may be the user's own `agy`'s.
export async function agyTakeBack(home: string): Promise<boolean> {
  try {
    await lstat(agyToken(home));
    return true;
  } catch {}
  if (!platform.hasKeychain && platform.os !== "linux") return false;
  const noted = await agyNotedEmail(home);
  if (noted === null) return false;
  const stored = await agyKeychain.read();
  if (stored === null) return false;
  const text = goKeyringValue(stored);
  if (agyEmailIn(text) !== noted) return false;
  try {
    await writePrivateSoon(agyToken(home), text);
  } catch (error) {
    log.warn("agents::agy", "could not move a profile's sign-in out of the keyring", { home, error: String(error) });
    return false;
  }
  log.info("agents::agy", "a profile's sign-in moved back from the keyring to its file", { home });
  return true;
}

/// Whether a sign-in's file is one `agy` runs on: a token, and for a company's account (`enterprise`, or a way of signing
/// in other than a person's Google account, `consumer`) its tier or Google Cloud project too. Such an account's file is
/// written first with its token alone, before its licence is chosen or its project given, and `agy` takes a file
/// with neither as signed out ("incomplete GCP onboarding", 1.5.9).
export function agyTokenReady(text: string, enterprise: boolean): boolean {
  let parsed: Json;
  try {
    parsed = JSON.parse(text);
  } catch {
    return false;
  }
  const filled = (v: unknown) => typeof v === "string" && v !== "";
  if (!filled(parsed?.token?.access_token)) return false;
  const company = enterprise || companyMethod(parsed.auth_method);
  return !company || filled(parsed.user_tier) || filled(parsed.project_id);
}

/// A way of signing in that is a company's (Google Cloud's: `gcp`), not a person's Google account (`consumer`; `oauth`
/// before 1.5).
const companyMethod = (method: unknown) => typeof method === "string" && method !== "" && method !== "consumer" && method !== "oauth";

/// Whether a sign-in's file is a company's Google account's.
export function agyCompany(text: string): boolean {
  try {
    return companyMethod(JSON.parse(text)?.auth_method);
  } catch {
    return false;
  }
}

/// Google can return the same display name for both Ultra tiers. Use the ID first, then Google's display name.
export function agyPlan(tier: { id?: unknown; name?: unknown } | null | undefined, company = false): string | null {
  const id = typeof tier?.id === "string" ? tier.id.trim().toLowerCase() : "";
  const known: Record<string, string> = {
    "free-tier": "Free",
    "g1-plus-tier": "Plus",
    "g1-pro-tier": "Pro",
    "g1-ultra-lite-tier": "Ultra 5x",
    "g1-ultra-tier": "Ultra 20x",
    "gcp-ge-standard-tier": "Enterprise",
    "gcp-ge-plus-tier": "Enterprise Plus",
    "gcp-ge-ultra-tier": "Enterprise Ultra",
  };
  if (Object.hasOwn(known, id)) return known[id]!;
  const name = typeof tier?.name === "string" ? tier.name.trim() : "";
  if (name !== "" && name.toLowerCase() !== "unknown") return name;
  if (id.startsWith("gcp-") || company) return "Enterprise";
  return null;
}

/// The plan in a profile's sign-in file.
export function agyPlanIn(text: string, enterprise = false): string | null {
  try {
    const parsed = JSON.parse(text);
    return agyPlan({ id: parsed?.user_tier, name: parsed?.tier_display_name }, enterprise || companyMethod(parsed?.auth_method));
  } catch {
    return enterprise ? "Enterprise" : null;
  }
}

/// When the access token of the profile's sign-in runs out (its `token.expiry`), 0 when it has none or none readable.
export function agyExpiryIn(text: string): number {
  try {
    const at = Date.parse(JSON.parse(text)?.token?.expiry);
    return Number.isFinite(at) ? at : 0;
  } catch {
    return 0;
  }
}

export async function agyExpiry(home: string): Promise<number> {
  try {
    return agyExpiryIn(await readFile(agyToken(home), "utf8"));
  } catch {
    return 0;
  }
}

/// The profile's sign-in renewed by `agy` itself, which holds the OAuth client Google renews it for (the station has
/// none of its own): a copy of it, marked run out, given to `agy models` in a directory of its own, which renews it
/// there (1.5.9: 2-3 s), and the renewed one written over the profile's, whose running sessions read it again as it
/// changes. The profile's own file is never marked run out, so nothing running on it is made to renew it too. A
/// failure leaves the profile's file as it was.
export async function agyRenew(home: string, command = "agy"): Promise<void> {
  const had = await readFile(agyToken(home), "utf8");
  const parsed = JSON.parse(had);
  if (typeof parsed?.token?.refresh_token !== "string" || parsed.token.refresh_token === "") throw new Error("no refresh token");
  const dir = join(agyHome(home), "renewing");
  await rm(dir, { recursive: true, force: true });
  try {
    const gemini = join(dir, ".gemini");
    await mkdir(join(gemini, "antigravity-cli"), { recursive: true });
    const marked = agyTokenIn(gemini);
    await writePrivateSoon(marked, JSON.stringify({ ...parsed, token: { ...parsed.token, expiry: "1970-01-01T00:00:00Z" } }));
    const env: Record<string, string> = { ...cleanEnv(SCRUBBED), HOME: dir, ANTIGRAVITY_GEMINI_DIR: gemini, AGY_CLI_DISABLE_AUTO_UPDATE: "1", ...AGY_FILE_TOKENS };
    await new Promise<void>((resolve, reject) => {
      execFile(command, ["models"], { env, cwd: dir, timeout: 30_000 }, (error) => (error ? reject(error) : resolve()));
    });
    const renewed = await readFile(marked, "utf8");
    if (agyExpiryIn(renewed) <= wall.now()) throw new Error("agy did not renew the sign-in");
    // What else the sign-in held (a company's project, region and tier) kept where the renewed one leaves it out.
    const fresh = JSON.parse(renewed);
    await writePrivateSoon(agyToken(home), JSON.stringify({ ...parsed, ...fresh, token: fresh.token }));
  } finally {
    await rm(dir, { recursive: true, force: true }).catch(() => {});
  }
}

/// A sign-in as a borrower keeps it: the access token its host lent, no refresh token (so `agy` never renews it here,
/// and asks to sign in once it runs out, which the station prevents by asking its host again first); with what else
/// the host's file holds (`stored`: a company's project, region and tier, without which `agy` takes it as signed out),
/// where a host lends it.
export function agyLentFile(lent: { token: Json; email?: string | null; auth_method?: string | null; stored?: Json }): string {
  const { refresh_token: _, ...token } = lent.token ?? {};
  const stored = lent.stored !== null && typeof lent.stored === "object" && !Array.isArray(lent.stored) ? lent.stored : {};
  return JSON.stringify({ ...stored, token, auth_method: lent.auth_method ?? stored.auth_method ?? "consumer", ...(lent.email ? { id_token_email: lent.email } : {}) });
}
/// How many bytes of the station's tools a session's model is declared (tools/mcp.ts `fitted`). `agy` 1.5.6 in ACP
/// declares an MCP server's tools only while all of them together stay within about 57-60 KB, dropping the largest
/// beyond that, and offers no call_mcp_tool for those it dropped: measured 2026-11-12 with the station's 42 tools
/// (73 KB; chat_post, station_task and secret_save were dropped, so its sessions could not post) and with subsets of
/// them (57 KB declared whole). That limit is on the tools as `agy` declares them, not as the station lists them, and is
/// shared: each becomes `mcp_stillfail_<name>`, its description given "This is a tool from the stillfail MCP server.\n"
/// (46 B) and its parameters a required `toolSummary` (275 B), so about AGY_TOOL_WRAP more a tool; and one pool holds
/// them with the workspace's skills, workflows and subagents (`.agent/skills`, which #6685 fills with the workspace's
/// skills: 37 of them, some 16-18 KB), and with 1.5.8/1.5.9's tools of their own (`swarm`, `run_workflow`, `schedule`,
/// `manage_task`, `send_message`). Measured on 1.5.8/1.5.9: 45,000 (40 tools listed, 43,877 B, ~56.7 KB wrapped) and
/// 26,000 on Windows (longer `.agent/skills` paths plus 1.5.9's extra built-ins) pushed the combined pool past ~58 KB
/// and dropped `chat_post` (4,704 B, the largest), every session answered `unknown tool: "mcp_stillfail_chat_post"`.
/// So the list is fitted to this, and what it comes to in `agy` (each tool's AGY_TOOL_WRAP added) is held under
/// AGY_TOOL_CEILING (test/agy.test.ts): with some 20 KB of skills beside it, well within the pool.
/// side/agy-real.test.ts holds it on the real CLI with 37 skills of that size.
export const AGY_TOOL_BUDGET = 22_000;
/// What `agy` adds to each tool it is declared, rounded up (46 B of description and 275 B of `toolSummary`, 2026-11-16).
export const AGY_TOOL_WRAP = 350;
/// The most the station's list may come to as `agy` declares it, its AGY_TOOL_WRAP a tool counted: what leaves room in
/// `agy`'s pool for the workspace's skills (some 20 KB) and its own tools.
export const AGY_TOOL_CEILING = 31_000;

/// Where the station keeps its sessions' transcripts.
export const SESSIONS = "sessions";

/// The conversation ids it gives: a path segment of the transcript's.
const SESSION_ID = /^[a-zA-Z0-9_-]+$/;

/// What failed a turn, from what it said of it.
export const classifyFailure = (text: string): FailureReason =>
  failureOf(text, { auth: ["authentication required", "not logged into antigravity", "authentication expired", "couldn't sign in", "invalid_grant", "unauthenticated", "token expired", "verification required"], limit: ["resource_exhausted", "quota"] });

/// A failure Antigravity CLI tells only in words: a turn whose answer is end_turn, all it said one line of its own
/// notice (⚠). Its spent quota came so on 1.5.9 (2026-11-15: "⚠ Individual quota reached. Please upgrade your
/// subscription to increase your limits. Resets in 56m33s.", where its log says RESOURCE_EXHAUSTED (code 429)), and a
/// session went on asking the spent account instead of moving to another. It comes after the turn's calls too, its
/// last words (2026-11-15: a turn of tool calls and thinking ending on it was taken as finished). What the model says
/// is never one: a notice is all of the turn's last words, one line of its own, and only what tells the account, a
/// limit or the provider counts (not `model`, the rest). What the program reads a process by does this (mb/src/acp
/// `notice_failure`); this is what it is held to.
/// Its own words for any failure it gives no reason for (1.5.8 `AGY_TERMINATED`: a token run out under it, 2026-11-16;
/// 1.5.9 `AGY_EXECUTOR_ERROR`: its executor's error line), even after partial streamed text, fail the turn too, never
/// forwarded as the agent's last words.
export function noticeFailure(said: string): FailureReason | null {
  const text = said.trim();
  const last = text.slice(text.lastIndexOf("\n") + 1).trim();
  const lower = last.toLowerCase();
  if (lower === AGY_TERMINATED) return "other";
  if (lower.startsWith(AGY_EXECUTOR_ERROR)) {
    const reason = classifyFailure(last);
    return reason === "model" ? "other" : reason;
  }
  if (lower.startsWith(AGY_UNAUTHENTICATED)) return "auth";
  if (lower.startsWith(AGY_VERIFICATION_REQUIRED)) return "auth";
  if (!text.startsWith("⚠") || text.includes("\n")) return null;
  if (lower.startsWith(AGY_PERMISSION_DENIED) && lower.includes("denied")) return "auth";
  if (lower.startsWith(AGY_UNABLE_TO_SUBMIT)) return "other";
  const reason = classifyFailure(text);
  return reason === "model" ? null : reason;
}

/// What Antigravity CLI says of a turn its executor ended on an error (1.5.8: unnamed; 1.5.9: named or HTTP 401; 1.5.14: verification gate).
const AGY_TERMINATED = "⚠ agent execution terminated due to error.";
const AGY_EXECUTOR_ERROR = "⚠ agent executor error:";
const AGY_UNAUTHENTICATED = "⚠ unauthenticated (code 401):";
const AGY_VERIFICATION_REQUIRED = "⚠ verification required";
const AGY_PERMISSION_DENIED = "⚠ permission '";
const AGY_UNABLE_TO_SUBMIT = "⚠ unable to submit request";

/// The process's arguments: the profile's files, no approvals, no telemetry.
export const agyArgs = (home: string) => ["acp", "--gemini-dir", geminiDir(home), "--dangerously-skip-permissions", "--disable-telemetry"];

/// Environment of an Antigravity CLI process: the station's scrubbed environment, the profile's own variables (which
/// win), its `--gemini-dir` (`ANTIGRAVITY_GEMINI_DIR`, for sandbox sync too), its sign-in in that file alone
/// (`AGY_FILE_TOKENS`), updates off, and the peer HTTP endpoint.
export function agyEnv(options: OpenOptions): Record<string, string> {
  const env: Record<string, string> = keepLocal({ ...cleanEnv(SCRUBBED), ...expandRoute(profileEnv(options.profile, "agy"), options.route) });
  env.ANTIGRAVITY_GEMINI_DIR = geminiDir(options.profile.home);
  Object.assign(env, AGY_FILE_TOKENS);
  env.AGY_CLI_DISABLE_AUTO_UPDATE = "1";
  env.STILLFAIL_PEER_HTTP = peerHttpBase(options.mcpUrl);
  if (options.instructions === "" || options.textOnly) env.STILLFAIL_REPO_RULES = "0";
  return env;
}

/// What session/new and session/load are given besides the working directory and the station's tools: its instructions,
/// after its own system prompt.
export const agyOpening = (instructions: string): Json => (instructions === "" ? {} : { _meta: { antigravity: { systemPrompt: { append: instructions } } } });

/// Where `agy acp` reads global hooks under `--gemini-dir`, outside the session's workspace.
export const agyHooksFile = (home: string) => join(geminiDir(home), "config", "hooks.json");

/// The tools of Antigravity CLI that touch files or directories in a repository (`repo-rules-hook.mjs`).
export const AGY_REPO_RULES_TOOLS = "run_command|read_file|write_file|edit_file|view_file|grep_search|find_by_name|list_dir";
const AGY_HOOK_SECONDS = 10;

/// Keeps the profile's global `hooks.json` telling repository rules (`AGENTS.md`, `CLAUDE.md`) as `agy`'s tools touch
/// directories below the session's workspace (`PostToolUse` queues, `PostInvocation` injects). Always kept enabled in
/// the shared `--gemini-dir/config/hooks.json` (`agy` re-reads it on each prompt across concurrent sessions on one
/// profile); a session without the station's instructions silences the hook via `STILLFAIL_REPO_RULES=0` in `agyEnv`.
export async function agyHooks(home: string): Promise<void> {
  const file = agyHooksFile(home);
  let current: Record<string, unknown> = {};
  let rawNow: string | null = null;
  try {
    rawNow = await readFile(file, "utf8");
    const parsed = JSON.parse(rawNow);
    if (parsed !== null && typeof parsed === "object" && !Array.isArray(parsed)) current = parsed;
  } catch {}
  const next = {
    ...current,
    stillfail: {
      PostToolUse: [{ matcher: AGY_REPO_RULES_TOOLS, hooks: [{ type: "command", command: AGY_REPO_RULES_COMMAND, timeout: AGY_HOOK_SECONDS }] }],
      PostInvocation: [{ type: "command", command: AGY_REPO_RULES_COMMAND, timeout: AGY_HOOK_SECONDS }],
    },
  };
  const text = `${JSON.stringify(next, null, 2)}\n`;
  if (rawNow === text) return;
  await mkdir(dirname(file), { recursive: true });
  await writeFile(file, text);
}

const NOT_SKILL_ENTRIES = new Set([".git", "node_modules", ".venv"]);

/// Antigravity CLI confines workspace skills to paths inside the workspace (`pinnedEvalSymlinks` skips symbolic links in
/// `.agents/skills/` that resolve outside `cwd`, 1.5.9). Materializes each skill of `<cwd>/.agents/skills/` (the
/// workspace's and any preset's, `sessionSkills` and `keepCopy`) and `skillsDir` into `<cwd>/.agent/skills/<name>/` as a
/// directory of its own with `SKILL.md` hard-linked (or copied across devices) and its sibling scripts and references
/// linked beside it, without adding the shared skills directory to `Active Workspaces`.
export async function agySkills(cwd: string, skillsDir?: string): Promise<void> {
  const sources = new Map<string, string>();
  const dotAgents = join(cwd, ".agents", "skills");
  for (const name of await readdir(dotAgents).catch(() => [] as string[])) {
    if (!name.startsWith(".")) sources.set(name, join(dotAgents, name));
  }
  if (skillsDir !== undefined) {
    for (const name of await readdir(skillsDir).catch(() => [] as string[])) {
      if (!name.startsWith(".") && !sources.has(name)) sources.set(name, join(skillsDir, name));
    }
  }
  const root = join(cwd, ".agent", "skills");
  const valid = new Map<string, { dir: string; skillMd: string; stat: Stats }>();
  for (const [name, src] of sources) {
    try {
      const dir = await realpath(src);
      const skillMd = await realpath(join(dir, "SKILL.md"));
      const st = await stat(skillMd);
      if (st.isFile()) valid.set(name, { dir, skillMd, stat: st });
    } catch {}
  }
  for (const old of await readdir(root).catch(() => [] as string[])) {
    if (!valid.has(old)) await rm(join(root, old), { recursive: true, force: true });
  }
  if (valid.size === 0) return;
  await mkdir(root, { recursive: true });
  for (const [name, { dir, skillMd, stat: srcStat }] of valid) {
    const target = join(root, name);
    const targetMeta = await lstat(target).catch(() => null);
    if (targetMeta !== null && !targetMeta.isDirectory()) await rm(target, { recursive: true, force: true });
    await mkdir(target, { recursive: true });
    const dstMd = join(target, "SKILL.md");
    const dstMeta = await lstat(dstMd).catch(() => null);
    const sameInode = dstMeta !== null && !dstMeta.isSymbolicLink() && dstMeta.dev === srcStat.dev && dstMeta.ino === srcStat.ino;
    const sameCopy = dstMeta !== null && !dstMeta.isSymbolicLink() && dstMeta.dev !== srcStat.dev && dstMeta.size === srcStat.size && Math.abs(dstMeta.mtimeMs - srcStat.mtimeMs) < 1;
    if (!sameInode && !sameCopy) {
      await rm(dstMd, { force: true });
      await hardLink(skillMd, dstMd).catch(async () => {
        await copyFile(skillMd, dstMd);
      });
    }
    const siblings = (await readdir(dir).catch(() => [] as string[])).filter((e) => e !== "SKILL.md" && !NOT_SKILL_ENTRIES.has(e));
    const keep = new Set(["SKILL.md", ...siblings]);
    for (const existing of await readdir(target).catch(() => [] as string[])) {
      if (!keep.has(existing)) await rm(join(target, existing), { recursive: true, force: true });
    }
    for (const entry of siblings) {
      const at = join(target, entry);
      if ((await lstat(at).catch(() => null)) === null) {
        await linkPath(join(dir, entry), at, { junction: true }).catch(() => {});
      }
    }
  }
}

/// The thinking levels Antigravity's ACP models append to a family's name (`gemini-4-carbon-high`, `claude-opus-5-5-medium`).
export const AGY_LEVELS = ["none", "minimal", "low", "medium", "high", "xhigh", "max"];

/// A raw ACP `modelId` split into its base model and thinking level (`gemini-4-carbon-high` → `gemini-4-carbon` at `high`,
/// `gemini-3.5-flash` → `gemini-3.5-flash`).
export function agyBaseModel(id: string): { model: string; effort?: string } {
  const trimmed = id.trim();
  const effort = AGY_LEVELS.find((l) => trimmed.endsWith(`-${l}`) && trimmed.length > l.length + 1);
  return effort === undefined ? { model: trimmed } : { model: trimmed.slice(0, -effort.length - 1), effort };
}

/// `plan`: the subscription label from the Antigravity session, when available.
export type AgyCatalog = { models: string[]; efforts: Record<string, string[]>; defaults: Record<string, string>; plan?: string };

/// The account's plan from session/new or session/load.
export function agySessionPlan(result: Json): string | null {
  return agyPlan(result?._meta?.antigravity?.tier);
}

/// The base models, their thinking levels (`[]` where at most one variant is offered, e.g. `gpt-oss-120b-medium`), and
/// any default level (`currentModelId`'s for its model, else `medium` where offered, else `high`).
export function agyCatalog(availableModels: readonly string[], currentModelId?: string | null): AgyCatalog {
  const models: string[] = [];
  const levels = new Map<string, Set<string>>();
  for (const raw of availableModels) {
    const { model, effort } = agyBaseModel(raw);
    if (model === "") continue;
    if (!models.includes(model)) models.push(model);
    if (effort !== undefined) {
      let set = levels.get(model);
      if (!set) levels.set(model, (set = new Set()));
      set.add(effort);
    }
  }
  const efforts: Record<string, string[]> = {};
  const defaults: Record<string, string> = {};
  const cur = typeof currentModelId === "string" && currentModelId.trim() !== "" ? agyBaseModel(currentModelId) : null;
  for (const model of models) {
    const sorted = AGY_LEVELS.filter((l) => levels.get(model)?.has(l) === true);
    efforts[model] = sorted.length >= 2 ? sorted : [];
    if (sorted.length >= 2) {
      defaults[model] =
        cur !== null && cur.model === model && cur.effort !== undefined && sorted.includes(cur.effort)
          ? cur.effort
          : sorted.includes("medium")
            ? "medium"
            : sorted.includes("high")
              ? "high"
              : sorted[sorted.length - 1]!;
    }
  }
  return { models, efforts, defaults };
}

/// The ACP `modelId` for `(model, effort)` among `availableModels`, or `null` when `availableModels` is non-empty and
/// offers neither `model` nor any level of it.
export function agyVariant(model: string, effort: string | undefined, availableModels: readonly string[], defaultModelId?: string | null): string | null {
  const { model: base, effort: inline } = agyBaseModel(model);
  const wanted = effort !== undefined && AGY_LEVELS.includes(effort) ? effort : inline;
  if (wanted === undefined && typeof defaultModelId === "string" && defaultModelId !== "" && agyBaseModel(defaultModelId).model === base) {
    if (availableModels.length === 0 || availableModels.includes(defaultModelId)) return defaultModelId;
  }
  if (availableModels.length === 0) {
    return wanted !== undefined && inline === undefined ? `${base}-${wanted}` : model;
  }
  if (wanted !== undefined && availableModels.includes(`${base}-${wanted}`)) return `${base}-${wanted}`;
  if (effort === undefined && availableModels.includes(model)) return model;
  if (availableModels.includes(base)) return base;
  const variants = availableModels.filter((m) => agyBaseModel(m).model === base);
  if (variants.length === 0) return null;
  return variants.find((m) => m === `${base}-medium`) ?? variants.find((m) => m === `${base}-high`) ?? variants[0]!;
}

/// The models session/new or session/load lists (ACP's `models`), the current first.
export function agyModels(result: Json): string[] {
  const valid = (v: unknown): v is string => typeof v === "string" && v.trim() !== "";
  const out = new Set<string>();
  if (valid(result?.models?.currentModelId)) out.add(result.models.currentModelId);
  for (const m of Array.isArray(result?.models?.availableModels) ? result.models.availableModels : []) if (valid(m?.modelId)) out.add(m.modelId);
  return [...out];
}

/// A turn's counts as the prompt's answer says them (ACP's `usage`), as the transcript keeps them: Cursor's names, input
/// apart from the cache's. None when it says none.
export function turnUsage(answer: Json): { inputTokens: number; cacheReadTokens: number; cacheWriteTokens: number; outputTokens: number } | null {
  const u = answer?.result?.usage;
  if (u === null || typeof u !== "object") return null;
  const n = (v: unknown) => (typeof v === "number" && Number.isFinite(v) && v > 0 ? v : 0);
  return { inputTokens: n(u.inputTokens), cacheReadTokens: n(u.cachedReadTokens), cacheWriteTokens: n(u.cachedWriteTokens), outputTokens: n(u.outputTokens) };
}

export type AgyDriverOptions = {
  /// The station's data directory: runners live in <data>/run/runners.
  data: string;
  /// The CLI, by name on the agent's PATH or a path.
  command?: string;
  /// Another station's subscription, borrowed (share/index.ts): its sign-in file written with the access token the
  /// station signed in on it lent (`write`, when it runs out).
  lent?: { borrowed(profile: Profile): boolean; write(profile: Profile): Promise<number> };
  /// What it waits on between openings of a process that could not load its models (`AGY_CATALOG_RETRY_MS`).
  clock?: Clock.Clock;
};

/// `agy acp` that cannot reach its backend as it starts (1.5.8, 1.5.9: a machine just restarted, its network not up yet)
/// fails neither session/new nor session/load: it answers them with no models (`models: null`), and offers none for the
/// rest of its life, so its session/set_model is refused ("Unknown model ID", tokyo-mac-studio-0 2026-11-16: five
/// sessions failed as the machine came up, its network four seconds later). Such a process is ended and another opened
/// after these waits; the last failure is the network's (`failureOf`), never the model's.
export const AGY_CATALOG_RETRY_MS = [1000, 2000, 4000];
/// What an opening that offered no models fails with: the network's words (`failureOf`), so its caller keeps the
/// conversation it was resuming and says the network failed.
export class AgyNoCatalog extends Error {
  constructor() {
    super("Antigravity CLI could not load its model catalog: connection failed");
  }
}

/// A borrowed sign-in is asked of its host again as a process opens on it once it has less than this left. A running
/// `agy` never reads its sign-in's file again (1.5.9, measured 2026-11-15: a file renewed under it, its next call still
/// "oauth2: token expired and refresh token is not set"), so one that runs out under a process fails its turn as a
/// sign-in's failure (`classifyFailure`), which the session's actor answers by ending the process and going on once in a
/// new one (actor_run.mbt `auth_retry`), opened here on a sign-in lent anew. Google's access tokens last an hour; `agy`
/// refuses to start on one with under 5 minutes.
export const AGY_LENT_RENEW_MS = 40 * 60_000;
/// What `agy` needs left of a sign-in to start on it (it asks to sign in under 5 minutes, 1.5.9), with a margin.
const AGY_LENT_LEAST_MS = 10 * 60_000;
/// Margin before a borrowed sign-in's recorded expiry within which an auth failure is taken as that token running out
/// (covers host/borrower clock skew and early expiry; well below AGY_LENT_LEAST_MS so a freshly opened process does
/// not match it immediately).
const AGY_LENT_EXPIRE_MARGIN_MS = 5 * 60_000;
/// Minimum time a process must have been open on its borrowed sign-in before another mid-turn expiry reopens it past
/// the one-shot `auth_retried` guard, so even severe clock skew cannot loop retries.
const AGY_LENT_MIN_RUN_MS = 5 * 60_000;

export class AgyDriver extends AcpDriver<AgySession> {
  protected readonly keepsTranscript = true;
  private readonly command: string;
  private readonly lent: AgyDriverOptions["lent"];
  private readonly lost = new Set<string>();
  readonly #clock: Clock.Clock;

  constructor(options: AgyDriverOptions) {
    super(options.data);
    this.command = options.command ?? "agy";
    this.lent = options.lent;
    this.#clock = options.clock ?? liveClock;
  }

  /// Marks conversation `id` as missing its trajectory in the CLI (`trajectory not found` on `session/prompt`), so the
  /// next open starts afresh even if a broken `.db` file is still on disk.
  noteLost(id: string) {
    if (SESSION_ID.test(id)) this.lost.add(id);
  }

  /// A conversation resumed or taken up is one its CLI keeps in `--gemini-dir`, brought in from another home of this
  /// station where needed (`agyBringIn`): `session/load` answers without checking the CLI's store, and every prompt
  /// then fails with "trajectory not found" (2026-11-16).
  private async ensureConversation(home: string, id: string): Promise<void> {
    if (!SESSION_ID.test(id)) return;
    if (this.lost.has(id)) throw new Error(`Antigravity conversation ${id} lost its trajectory in its CLI's store`);
    await agyBringIn(home, id);
    if (!(await there(join(agyConversations(home), `${id}.db`)))) throw new Error(`no Antigravity conversation ${id} in its CLI's store`);
  }

  /// A borrowed sign-in with little left (AGY_LENT_RENEW_MS) lent again before a process opens on it. Where none is lent,
  /// one that still lasts long enough for `agy` to start on is gone on with (said), else the failure is the opening's.
  private async renewLent(profile: Profile): Promise<void> {
    const until = await agyExpiry(profile.home);
    if (until - wall.now() >= AGY_LENT_RENEW_MS) return;
    try {
      await this.lent!.write(profile);
    } catch (error) {
      if (until - wall.now() < AGY_LENT_LEAST_MS) throw error;
      log.warn("agents::agy", "its borrowed sign-in runs out soon and no new one was lent; it goes on with the one it has", { profile: profile.id, error: (error as Error).message });
    }
  }

  runtime(): "agy" {
    return "agy";
  }

  /// The models a profile's CLI offers, normalized into base models and their thinking levels: a session opened only to ask.
  async catalog(profile: Profile): Promise<AgyCatalog> {
    const session = await this.begin({ key: `models-${profile.id}-${uuid()}`, profile, cwd: agyHome(profile.home), instructions: "", mcpToken: "", mcpUrl: "", route: "model-discovery" }, () => {}, true);
    try {
      const catalog = agyCatalog(session.availableModels, session.currentModelId);
      return session.plan !== null ? { ...catalog, plan: session.plan } : catalog;
    } finally {
      await session.dispose();
    }
  }

  /// The models a profile's CLI offers: a session opened only to ask.
  async models(profile: Profile): Promise<string[]> {
    return (await this.catalog(profile)).models;
  }

  protected session(options: OpenOptions, events: Events) {
    return new AgySession(this, events, options);
  }

  /// One opening, opened again after `AGY_CATALOG_RETRY_MS` while its process offers no models (`AgyNoCatalog`); any
  /// other failure is the caller's at once.
  /// Given up (`OpenOptions.signal`: timed out, stopped, suspended, closed), it opens nothing again and starts no process.
  protected async begin(options: OpenOptions, events: Events, probe: boolean): Promise<AgySession> {
    const signal = options.signal;
    for (let attempt = 0; ; attempt++) {
      if (signal?.aborted) throw new Error("open aborted");
      try {
        return await this.beginOnce(options, events, probe);
      } catch (error) {
        if (signal?.aborted) throw error;
        const wait = AGY_CATALOG_RETRY_MS[attempt];
        if (!(error instanceof AgyNoCatalog) || wait === undefined) throw error;
        log.warn("agents::agy", "its process offered no models (its network not up?); opened again after a wait", { key: options.key, attempt: attempt + 1, waitMs: wait });
        // timer: retry after a failure (its wait interrupted as the opening is given up)
        const waited = Effect.runPromise(this.#clock.sleep(Duration.millis(wait)), signal === undefined ? undefined : { signal });
        await waited.catch((error: unknown) => {
          if (!signal?.aborted) throw error;
        });
      }
    }
  }

  private async beginOnce(options: OpenOptions, events: Events, probe: boolean): Promise<AgySession> {
    const borrowed = this.lent?.borrowed(options.profile) === true;
    if (borrowed) await this.renewLent(options.profile);
    else if (accessKind(options.profile) === "subscription") await agyTakeBack(options.profile.home);
    else if (accessKind(options.profile) === "api-provider" && profileVia(options.profile).provider === "google-vertex") {
      const key = typeof (options.profile.access as { key?: unknown } | undefined)?.key === "string" ? (options.profile.access as { key: string }).key.trim() : "";
      if (key !== "") {
        const file = vertexKeyFile(options.profile.home);
        const existing = await readFile(file, "utf8").catch(() => null);
        if (existing !== key) await writePrivateSoon(file, key);
      }
    }
    // Read before the process starts: the token it reads, never read again (AGY_LENT_RENEW_MS).
    const until = borrowed ? await agyExpiry(options.profile.home) : null;
    // Failed here, before anything starts, so the session goes on in a new conversation and reads back.
    if (options.resume !== undefined) await this.ensureConversation(options.profile.home, options.resume);
    if (!probe) {
      await agyHooks(options.profile.home);
      if (options.skills !== undefined) await agySkills(options.cwd, options.skills);
    }
    // (given up while it was made ready: no process started)
    if (options.signal?.aborted) throw new Error("open aborted");
    const session = await super.begin(options, events, probe);
    session.signInUntil = until;
    session.signInOpenedAt = borrowed ? wall.now() : null;
    return session;
  }

  override async adopt(options: OpenOptions, snapshot: unknown | null, events: Events): Promise<AgySession> {
    // A warm process opened before #6608 (or whose CLI database went away) answered `session/load` and would otherwise
    // be taken up across a station update, failing every prompt there too (Office-Host-2 0.1.9517, 2026-11-16): refused
    // here, `endOrphans` ends its runner and the session goes on in a new conversation.
    const id = typeof (snapshot as { id?: unknown } | null)?.id === "string" ? (snapshot as { id: string }).id : options.resume;
    if (id !== undefined) await this.ensureConversation(options.profile.home, id);
    const session = await super.adopt(options, snapshot, events);
    // One handed over says the token it opened on (`kept`); one taken up after a crash, or from a station from before,
    // does not, and is opened again before its next turn: the file may hold a token lent since, for another process.
    if (this.lent?.borrowed(options.profile) !== true) {
      session.signInUntil = null;
      session.signInOpenedAt = null;
    } else if (session.signInUntil === null) {
      session.signInUntil = 0;
      session.signInOpenedAt = null;
    } else if (session.signInOpenedAt === null && session.signInUntil > 0) {
      session.signInOpenedAt = session.signInUntil - 60 * 60_000;
    }
    if (session.id() !== id) {
      try {
        await this.ensureConversation(options.profile.home, session.id());
      } catch (error) {
        await session.dispose();
        throw error;
      }
    }
    await agyHooks(options.profile.home);
    if (options.skills !== undefined) await agySkills(options.cwd, options.skills);
    return session;
  }

  protected async starting(options: OpenOptions): Promise<AcpStart> {
    if (options.resume !== undefined && !SESSION_ID.test(options.resume)) throw new Error("invalid Antigravity conversation id");
    const sessions = join(agyHome(options.profile.home), SESSIONS);
    await mkdir(sessions, { recursive: true });
    await mkdir(geminiDir(options.profile.home), { recursive: true });
    // Not one the station kept.
    if (options.resume !== undefined && !(await access(join(sessions, `${options.resume}.jsonl`)).then(() => true, () => false))) throw new Error(`no Antigravity conversation ${options.resume}`);
    return { command: this.command, args: agyArgs(options.profile.home), env: agyEnv(options), opening: agyOpening(options.instructions) };
  }

  protected override async initialized(session: AgySession, answer: Json, options: OpenOptions): Promise<void> {
    if (accessKind(options.profile) !== "api-provider" || !Array.isArray(answer?.result?.authMethods)) return;
    const provider = profileVia(options.profile).provider;
    const methodId = provider === "google" ? "gemini-api-key" : provider === "google-vertex" ? "agent-platform" : null;
    if (methodId !== null && answer.result.authMethods.some((m: Json) => m?.id === methodId)) {
      await session.request(`auth:${uuid()}`, "authenticate", { methodId });
    }
  }

  protected async ready(session: AgySession, options: OpenOptions, probe: boolean) {
    // Its backend not reached as it started: no model it would take (AGY_CATALOG_RETRY_MS). The opening's catch ends it.
    if (session.availableModels.length === 0) throw new AgyNoCatalog();
    const model = probe ? undefined : (options.model ?? profileModel(options.profile));
    if (model === undefined) return;
    const target = agyVariant(model, options.effort, session.availableModels, session.defaultModelId) ?? model;
    if (target !== session.currentModelId) await session.request(`model:${uuid()}`, "session/set_model", { sessionId: session.id(), modelId: target });
    session.currentModelId = target;
    session.model = agyBaseModel(model).model;
  }
}

export class AgySession extends AcpSession {
  /// What session/new or session/load said it offers.
  availableModels: string[] = [];
  /// The raw ACP `modelId` currently active in the process.
  currentModelId: string | null = null;
  /// The raw ACP `modelId` the process opened on before any `session/set_model`.
  defaultModelId: string | null = null;
  /// The account's plan, as session/new or session/load said it.
  plan: string | null = null;
  /// The context its last call had and the model's window, as usage_update says them.
  private context = { used: 0, size: 0 };
  /// When the borrowed sign-in its process opened on runs out (ms); null on a sign-in of this station's own, which
  /// `agy` renews itself.
  signInUntil: number | null = null;
  /// When the process opened on its borrowed sign-in (ms); null on a sign-in of this station's own or unknown.
  signInOpenedAt: number | null = null;
  private readonly agyDriver: AgyDriver;

  constructor(driver: AgyDriver, events: Events, options: OpenOptions) {
    super(driver, events, new KeptTranscript("agy", join(agyHome(options.profile.home), SESSIONS)));
    this.agyDriver = driver;
  }

  named(id: string) {
    if (!SESSION_ID.test(id)) throw new Error("invalid Antigravity conversation id");
    super.named(id);
  }

  opened(result: Json, resumed = false) {
    super.opened(result, resumed);
    this.availableModels = agyModels(result);
    this.plan = agySessionPlan(result) ?? this.plan;
    const current = result?.models?.currentModelId;
    if (typeof current === "string" && current !== "") {
      this.currentModelId = current;
      this.defaultModelId = current;
      this.model = agyBaseModel(current).model;
    }
  }

  protected kept() {
    return {
      availableModels: this.availableModels,
      currentModelId: this.currentModelId,
      defaultModelId: this.defaultModelId,
      context: this.context,
      signInUntil: this.signInUntil,
      signInOpenedAt: this.signInOpenedAt,
    };
  }

  protected taken(snapshot: Json) {
    this.availableModels = Array.isArray(snapshot.availableModels) ? snapshot.availableModels.filter((m: unknown): m is string => typeof m === "string") : [];
    this.currentModelId = typeof snapshot.currentModelId === "string" ? snapshot.currentModelId : this.model;
    this.defaultModelId = typeof snapshot.defaultModelId === "string" ? snapshot.defaultModelId : null;
    const c = snapshot.context;
    if (c && typeof c === "object") this.context = { used: typeof c.used === "number" ? c.used : 0, size: typeof c.size === "number" ? c.size : 0 };
    this.signInUntil = typeof snapshot.signInUntil === "number" ? snapshot.signInUntil : null;
    this.signInOpenedAt = typeof snapshot.signInOpenedAt === "number" ? snapshot.signInOpenedAt : null;
  }

  /// Its process's borrowed sign-in has less than AGY_LENT_RENEW_MS left: it takes no turn on it, but is ended and
  /// opened again before the next (on a token lent anew, `renewLent`). Without it a process kept warm for an hour ran
  /// out under every turn, which `agy` told only as "⚠ Agent execution terminated due to error." (1.5.9; its log said
  /// "oauth2: token expired and refresh token is not set"), no sign-in failure `auth_retry` answers: Office-Host-2,
  /// 2026-11-16, five chats failing every turn in 0.1 s.
  outlived() {
    return this.signInUntil !== null && this.signInUntil - wall.now() < AGY_LENT_RENEW_MS;
  }

  /// When a turn ends on `AGY_TERMINATED` (1.5.8), whether its process's borrowed sign-in has already run out under the
  /// turn (within AGY_LENT_EXPIRE_MARGIN_MS; 0 when taken up without a known expiry): `actor_run.mbt` then answers it
  /// as `auth`, ending the process and going on in a new one on a sign-in lent anew (`auth_retry`).
  signInExpired() {
    return this.signInUntil !== null && this.signInUntil - wall.now() <= AGY_LENT_EXPIRE_MARGIN_MS;
  }

  /// Whether this process opened on a known borrowed sign-in, ran for at least AGY_LENT_MIN_RUN_MS, and that sign-in
  /// has now reached expiry: lets a long-running turn reopen on a newly lent token across multiple hourly expiries
  /// while stopping immediately on a broken login or severe clock skew.
  lentExpired() {
    if (this.signInUntil === null || this.signInUntil <= 0 || this.signInOpenedAt === null) return false;
    const now = wall.now();
    return this.signInUntil - now <= AGY_LENT_EXPIRE_MARGIN_MS && now - this.signInOpenedAt >= AGY_LENT_MIN_RUN_MS;
  }

  protected updated(update: Json, _owner: string | null) {
    if (update?.sessionUpdate !== "usage_update") return;
    const n = (v: unknown) => (typeof v === "number" && Number.isFinite(v) && v > 0 ? v : 0);
    if (n(update.used) > 0) this.context.used = n(update.used);
    if (n(update.size) > 0) this.context.size = n(update.size);
  }

  /// The turn's usage, into the transcript before its end.
  protected ending(id: string, answer: Json) {
    if (answer?.error !== undefined && /\btrajectory not found\b/i.test(errorText(answer.error))) this.agyDriver.noteLost(this.sessionId);
    const usage = turnUsage(answer);
    if (usage !== null) this.transcript?.keep(this.sessionId, { type: "usage", run: id.slice(id.indexOf(":") + 1), model: this.model, usage, calls: 1, context: this.context.used, window: this.context.size });
  }

  protected ignored(id: string, answer: Json) {
    this.ending(id, answer);
  }

  /// Into the running turn: Antigravity CLI immediately resolves the superseded prompt and finishes on the new one.
  async steer(text: string) {
    return this.promptTakeover(text);
  }

  /// Between turns, another model or thinking level is set in the running process, read from its next turn on.
  retune(options: OpenOptions) {
    if (this.turn.closed || this.turn.busy || this.sessionId === "" || this.outlived()) return false;
    if (options.skills !== undefined) void agySkills(options.cwd, options.skills).catch(() => {});
    const model = options.model ?? profileModel(options.profile);
    if (model === undefined) return false;
    const target = agyVariant(model, options.effort, this.availableModels, this.defaultModelId);
    if (target === null) return false;
    if (target !== this.currentModelId) this.send("session/set_model", { sessionId: this.sessionId, modelId: target });
    this.currentModelId = target;
    this.model = agyBaseModel(model).model;
    return true;
  }
}
