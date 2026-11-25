// An Antigravity CLI subscription's allowance (what `agy -p /usage --output-format json` reports: Gemini Models and
// Claude and GPT models, 5-hour and weekly windows), asked of `agy` in the profile's own files
// (ANTIGRAVITY_GEMINI_DIR=<home>/agy/.gemini; HOME=<home>/agy with AGY_FILE_TOKENS so `agy` keeps its sign-in in the
// profile's file rather than an OS keyring) without reading or embedding OAuth client credentials in the station.
import { spawn } from "node:child_process";
import { mkdir, readFile } from "node:fs/promises";
import { devNull } from "node:os";
import { AGY_FILE_TOKENS, agyCompany, agyHome, agyPlan, agyTakeBack, agyToken, geminiDir } from "../agents/agy.ts";
import { type Env, platform } from "../platform/index.ts";
import { profileFetch } from "../ops/agent-env.ts";
import { type Lang, Said, stationLang, tr } from "../ops/i18n.ts";
import { withShellCommand } from "../ops/shell-path.ts";
import { RenewRefused } from "./console.ts";
import type { ProfileQuota, QuotaWindow, Urls } from "./profiles.ts";
import { at, okOrUnavailable, percent, windowLabel } from "./quota.ts";

type Json = any;

const TIMEOUT_MS = 30_000;
const AGY_CLOUD_CODE_URL = "https://daily-cloudcode-pa.googleapis.com";
const AGY_PRODUCTION_URL = "https://cloudcode-pa.googleapis.com";
const AGY_QUOTA_SUMMARY = "/v1internal:retrieveUserQuotaSummary";
// Google's retrieveUserQuotaSummary omits the Gemini Models group unless User-Agent has the CLI product segment.
const AGY_USER_AGENT = "antigravity/cli/1.5.15";
const DAY_MINUTES = 24 * 60;
const WEEK_MINUTES = 7 * DAY_MINUTES;
const SCRUBBED = [
  "GEMINI_API_KEY",
  "GOOGLE_API_KEY",
  "GOOGLE_GENAI_USE_VERTEXAI",
  "GOOGLE_APPLICATION_CREDENTIALS",
  "GOOGLE_CLOUD_PROJECT",
  "GOOGLE_CLOUD_LOCATION",
  "AGY_ADC_AUTH",
  "AGY_ACCOUNT",
  "SSH_CONNECTION",
];

const isObject = (v: unknown): v is Record<string, any> => v !== null && typeof v === "object" && !Array.isArray(v);

function modelScopeName(groupName: string, bucketId: string): string {
  const g = groupName.trim();
  const geminiTier = /^gemini\s+(?:\d+(?:\.\d+)?\s+)?(.+)$/i.exec(g);
  if (geminiTier && geminiTier[1]!.trim().toLowerCase() !== "models") return geminiTier[1]!.trim();
  const claudeTier = /^claude\s+([A-Za-z]+)(?:\s+\d+(?:\.\d+)?)?$/i.exec(g);
  if (claudeTier) return claudeTier[1]!;
  if (g !== "") return g;
  const fromId = /^(?:gemini|3p)-([a-z0-9]+)-/i.exec(bucketId.trim());
  if (fromId) {
    const s = fromId[1]!;
    return s.charAt(0).toUpperCase() + s.slice(1).toLowerCase();
  }
  return "";
}

function groupMeta(groupName: string, bucketId: string): { suffix: string; scope?: string; modelScoped?: boolean } {
  const id = bucketId.trim().toLowerCase();
  const g = groupName.trim().toLowerCase();
  if (/^gemini-(?:\d+h|weekly|daily|monthly)$/.test(id) || g === "gemini models" || g === "gemini") {
    return { suffix: "Gemini", scope: "gemini" };
  }
  if (/^3p-(?:\d+h|weekly|daily|monthly)$/.test(id) || (g.includes("claude") && g.includes("gpt")) || g === "claude / gpt") {
    return { suffix: "Claude / GPT", scope: "3p" };
  }
  const own = modelScopeName(groupName, bucketId);
  return own !== "" ? { suffix: own, scope: own, modelScoped: true } : { suffix: groupName.trim() };
}

function windowDuration(rawWindow: string, bucketId: string): [number | null, string] {
  const w = rawWindow.trim().toLowerCase();
  const id = bucketId.trim().toLowerCase();
  const hours = /^(\d+)\s*h$/.exec(w) ?? /-(\d+)h$/.exec(id);
  if (hours) {
    const mins = Number(hours[1]) * 60;
    return [mins, windowLabel(mins, `${hours[1]} 小时`)];
  }
  if (w === "weekly" || id.endsWith("-weekly")) return [WEEK_MINUTES, "每周"];
  if (w === "monthly" || id.endsWith("-monthly")) return [30 * DAY_MINUTES, "每月"];
  if (w === "daily" || id.endsWith("-daily")) return [DAY_MINUTES, "1 天"];
  return [null, rawWindow.trim() || "限额"];
}

export function agyAllowance(body: Json): { windows: QuotaWindow[]; scoped: QuotaWindow[] } {
  const groups = Array.isArray(body?.command?.data?.groups)
    ? body.command.data.groups
    : Array.isArray(body?.quotaSummary?.groups)
      ? body.quotaSummary.groups
      : Array.isArray(body?.groups)
        ? body.groups
        : [];
  const multiGroup = groups.length > 1;
  const windows: QuotaWindow[] = [];
  const scoped: QuotaWindow[] = [];
  for (const group of groups) {
    const groupName = typeof group?.displayName === "string" ? group.displayName : typeof group?.name === "string" ? group.name : "";
    const buckets = Array.isArray(group?.buckets) ? group.buckets : [];
    for (const b of buckets) {
      if (!isObject(b)) continue;
      const frac = typeof b.remainingFraction === "number" ? b.remainingFraction : typeof b.remaining_fraction === "number" ? b.remaining_fraction : null;
      if (frac === null && b.disabled !== true) continue;
      const used = b.disabled === true ? 100 : percent((1 - frac!) * 100);
      const bucketId = typeof b.bucketId === "string" ? b.bucketId : typeof b.id === "string" ? b.id : "";
      const rawWin = typeof b.refreshWindowLabel === "string" ? b.refreshWindowLabel : typeof b.window === "string" ? b.window : "";
      const [minutes, base] = windowDuration(rawWin, bucketId);
      const { suffix, scope, modelScoped } = groupMeta(groupName, bucketId);
      const label = (multiGroup || scope !== undefined) && suffix !== "" ? `${base} · ${suffix}` : base;
      const resetsAt = at(b.resetTime ?? b.reset_time);
      const win: QuotaWindow = { label, usedPercent: used, resetsAt, minutes, ...(scope !== undefined ? { scope } : {}) };
      if (modelScoped) scoped.push(win);
      else windows.push(win);
    }
  }
  return { windows, scoped };
}

export function agyWindows(body: Json): QuotaWindow[] {
  return agyAllowance(body).windows;
}

export function agyScopeForModel(model: string | null | undefined): "gemini" | "3p" {
  if (typeof model !== "string" || model.trim() === "") return "gemini";
  const bare = (model.trim().toLowerCase().split("[")[0]?.split("/").pop() ?? "").split("@")[0]!;
  const m = bare.replace(/^(?:[a-z]+\.)+/, "");
  if (m.startsWith("gemini") || m.startsWith("gemma")) return "gemini";
  return "3p";
}

function networkFailure(text: string): boolean {
  const lower = text.toLowerCase();
  if (/\beof\b/.test(lower)) return true;
  return [
    "connection refused",
    "connection reset",
    "no such host",
    "i/o timeout",
    "context deadline exceeded",
    "tls handshake timeout",
    "network is unreachable",
    "no route to host",
    "temporary failure in name resolution",
  ].some((w) => lower.includes(w));
}

function authFailure(text: string): boolean {
  const lower = text.toLowerCase();
  return ["authentication required", "not logged into antigravity", "authentication expired", "couldn't sign in", "invalid_grant", "unauthenticated"].some((w) =>
    lower.includes(w),
  );
}

/// Google holding an account until a person verifies it (`agy` says "Eligibility check failed: Your current account is
/// not eligible for Antigravity. Verify your account to continue." and the page to do it on; its backend
/// `VALIDATION_REQUIRED`): that page, "" when it gives none, null when it is not that.
export function agyVerify(text: string): string | null {
  const lower = text.toLowerCase();
  if (!["verify your account", "validation_required"].some((w) => lower.includes(w))) return null;
  return /https:\/\/accounts\.google\.com\/\S+/.exec(text)?.[0] ?? "";
}

function agyLocationIneligible(text: string): boolean {
  const lower = text.toLowerCase();
  return (
    lower.includes("not currently available in your location") ||
    lower.includes("unsupported_location") ||
    lower.includes("not eligible for antigravity")
  );
}

/// 5-hour quota windows derived from `v1internal:fetchAvailableModels` (`models[*].quotaInfo`), one per pool
/// (`gemini` and `3p`), taking the lowest remaining fraction in each pool.
export function agyModelWindows(body: Json): QuotaWindow[] {
  const models = isObject(body?.models) ? body.models : null;
  if (models === null) return [];
  const pools: Record<"gemini" | "3p", { frac: number; resetsAt: number | null } | null> = { gemini: null, "3p": null };
  for (const [modelId, entry] of Object.entries(models)) {
    if (modelId.toLowerCase().startsWith("tab_") || !isObject(entry)) continue;
    const qi = isObject(entry.quotaInfo) ? entry.quotaInfo : null;
    if (qi === null) continue;
    const resetsAt = at(qi.resetTime ?? qi.reset_time);
    const camelFrac = qi.remainingFraction;
    const snakeFrac = qi.remaining_fraction;
    let frac = typeof camelFrac === "number" ? camelFrac : snakeFrac;
    // Google omits the zero fraction for an exhausted model pool and still gives its reset time.
    if (typeof frac !== "number") {
      if (camelFrac != null || snakeFrac != null || resetsAt === null) continue;
      frac = 0;
    }
    const scope = agyScopeForModel(modelId);
    const prev = pools[scope];
    if (prev === null) {
      pools[scope] = { frac, resetsAt };
    } else {
      if (frac < prev.frac) prev.frac = frac;
      if (prev.resetsAt === null && resetsAt !== null) prev.resetsAt = resetsAt;
    }
  }
  const out: QuotaWindow[] = [];
  for (const [scope, suffix] of [
    ["gemini", "Gemini"],
    ["3p", "Claude / GPT"],
  ] as const) {
    const p = pools[scope];
    if (p === null) continue;
    out.push({
      label: `${windowLabel(300, "5 小时")} · ${suffix}`,
      usedPercent: percent((1 - p.frac) * 100),
      resetsAt: p.resetsAt,
      minutes: 300,
      scope,
    });
  }
  return out;
}

async function agyPost(base: string, path: string, token: string, body: Json): Promise<Json | null> {
  try {
    const res = await profileFetch(`${base}${path}`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
        accept: "application/json",
        "user-agent": AGY_USER_AGENT,
      },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    if (!res.ok) return null;
    return JSON.parse(await res.text());
  } catch {
    return null;
  }
}

function agyBase(urls: Urls, fallback: string): string {
  return (urls.agyQuota?.trim() || fallback).replace(/\/+$/, "");
}

function agyProductionBase(urls: Urls): string {
  return (urls.agyQuotaProduction?.trim() || urls.agyQuota?.trim() || AGY_PRODUCTION_URL).replace(/\/+$/, "");
}

async function agyQuotaProject(home: string, base: string) {
  let token: string;
  try {
    const parsed = JSON.parse(await readFile(agyToken(home), "utf8"));
    token = typeof parsed?.token?.access_token === "string" ? parsed.token.access_token : "";
  } catch {
    return null;
  }
  if (token === "") return null;
  const loaded = await agyPost(base, "/v1internal:loadCodeAssist", token, { metadata: { ideType: "ANTIGRAVITY" } });
  if (!isObject(loaded)) return null;
  const tier = isObject(loaded.paidTier) ? loaded.paidTier : loaded.currentTier;
  if (!isObject(tier)) return null;
  const project = typeof loaded.cloudaicompanionProject === "string" && loaded.cloudaicompanionProject !== "" ? loaded.cloudaicompanionProject : null;
  const payload = project !== null ? { project } : {};
  return { token, tier, payload };
}

function isGeminiWeekly(window: QuotaWindow): boolean {
  return window.scope === "gemini" && window.minutes === WEEK_MINUTES;
}

// Read the shared Gemini weekly window from `base` (daily first, then production when omitted).
async function agyGeminiWeekly(base: string, token: string, payload: Json): Promise<QuotaWindow | undefined> {
  return agyWindows(await agyPost(base, AGY_QUOTA_SUMMARY, token, payload)).find(isGeminiWeekly);
}

/// Fallback when the CLI rejects an account with an active tier and an ineligible free tier.
async function agyDirectQuota(home: string, urls: Urls, lang: Lang): Promise<ProfileQuota | null> {
  const base = agyBase(urls, AGY_CLOUD_CODE_URL);
  const project = await agyQuotaProject(home, base);
  if (project === null) return null;
  const { token, tier, payload } = project;
  const [summary, models] = await Promise.all([
    agyPost(base, AGY_QUOTA_SUMMARY, token, payload),
    agyPost(base, "/v1internal:fetchAvailableModels", token, payload),
  ]);
  const { windows, scoped } = summary !== null ? agyAllowance(summary) : { windows: [], scoped: [] };
  const extra = agyModelWindows(models).filter((w) => !windows.some((reported) => reported.scope === w.scope && reported.minutes === w.minutes));
  const production = agyProductionBase(urls);
  // Only fall back to production when daily answered cleanly and omitted the weekly window.
  if (isObject(summary) && base !== production && !windows.some(isGeminiWeekly)) {
    const weekly = await agyGeminiWeekly(production, token, payload);
    if (weekly !== undefined) windows.unshift(weekly);
  }
  const merged = [...extra.filter((w) => w.scope === "gemini"), ...windows, ...extra.filter((w) => w.scope !== "gemini")];
  if (merged.length === 0 && scoped.length === 0) return null;
  const q = okOrUnavailable(merged.length > 0 ? merged : scoped, tr(lang, "station.quota.agyNoWindows"));
  if (q.state === "ok" && merged.length > 0 && scoped.length > 0) q.scoped = scoped;
  const plan = agyPlan(tier);
  if (plan !== null) q.plan = plan;
  return q;
}

async function runAgyUsage(command: string, env: Env, cwd: string): Promise<{ code: number | null; stdout: string; stderr: string; authPrompted: boolean }> {
  const r = await platform.runnableSoon(command, ["--log-file", devNull, "-p", "/usage", "--output-format", "json"], env as NodeJS.ProcessEnv);
  return new Promise((resolve, reject) => {
    const child = spawn(r.file, r.args, {
      cwd,
      env: env as NodeJS.ProcessEnv,
      stdio: ["ignore", "pipe", "pipe"],
      windowsVerbatimArguments: r.windowsVerbatimArguments,
      windowsHide: true,
    });
    let stdout = "";
    let stderr = "";
    let authPrompted = false;
    let settled = false;
    const done = (err: Error | null, code: number | null = null) => {
      if (settled) return;
      settled = true;
      try {
        child.kill("SIGKILL");
      } catch {}
      if (err) reject(err);
      else resolve({ code, stdout, stderr, authPrompted });
    };
    const abort = AbortSignal.timeout(TIMEOUT_MS);
    const onAbort = () => {
      const e = new Error("agy /usage timed out");
      e.name = "TimeoutError";
      done(e);
    };
    abort.addEventListener("abort", onAbort, { once: true });
    child.once("error", (e) => {
      abort.removeEventListener("abort", onAbort);
      done(e);
    });
    const checkPrompt = (chunk: string) => {
      if (!authPrompted && (chunk.includes("Authentication required.") || chunk.includes("Waiting for authentication"))) {
        authPrompted = true;
        abort.removeEventListener("abort", onAbort);
        done(null, 1);
      }
    };
    child.stdout?.on("data", (d: Buffer) => {
      const s = d.toString("utf8");
      stdout += s;
      checkPrompt(stdout);
    });
    child.stderr?.on("data", (d: Buffer) => {
      const s = d.toString("utf8");
      stderr = (stderr + s).slice(-4000);
      checkPrompt(stderr);
    });
    child.once("close", (code) => {
      abort.removeEventListener("abort", onAbort);
      done(null, code);
    });
  });
}

function parseJsonLine(stdout: string): Json | null {
  for (const line of stdout.trim().split(/\r?\n/).reverse()) {
    const trimmed = line.trim();
    if (!trimmed.startsWith("{")) continue;
    try {
      return JSON.parse(trimmed);
    } catch {}
  }
  return null;
}

/// At most `most` characters of `text`, but a link the cut falls in kept whole: Google's verification link (`Please
/// verify your account in your browser to continue: https://accounts.google.com/v3/signin/continue?plt=…`) cut short
/// opens a 400, and it is what the person is to open.
export function clipKeepingLinks(text: string, most: number): string {
  if (text.length <= most) return text;
  const cut = text.slice(0, most);
  if (!/https?:\/\/\S*$/.test(cut)) return cut;
  return cut + /^\S*/.exec(text.slice(most))![0];
}

/// `direct`: whether what `agy -p /usage` leaves out (Gemini's week; an account it refuses for its free tier's location) is
/// asked of Google's Cloud Code API with the profile's token as the CLI would (the profile's `directQuota`, on unless
/// false). Off, only the CLI is asked: nothing goes to Google but what `agy` itself sends.
export async function agyQuota(home: string, sourceEnv: Env, urls: Urls, lang: Lang = stationLang(), command = "agy", direct = true): Promise<ProfileQuota> {
  // Before sign-in (no token file in the profile's, none to take back from the keychain: agents/agy.ts `agyTakeBack`),
  // return signed out immediately without spawning `agy`.
  if (!(await agyTakeBack(home))) {
    throw new Said(tr(lang, "station.quota.signInExpired"));
  }
  const baseEnv: Record<string, string> = {};
  for (const [k, v] of Object.entries(sourceEnv)) {
    if (v !== undefined && !SCRUBBED.includes(k)) baseEnv[k] = v;
  }
  // HOME isolated to `<home>/agy` and the sign-in kept in the file alone (`AGY_FILE_TOKENS`), so `agy` reads only the
  // profile's token file, never the OS keyring item, which is the machine's last account.
  baseEnv.HOME = agyHome(home);
  Object.assign(baseEnv, AGY_FILE_TOKENS);
  baseEnv.ANTIGRAVITY_GEMINI_DIR = geminiDir(home);
  baseEnv.AGY_CLI_DISABLE_AUTO_UPDATE = "1";
  if (urls.agyQuota) baseEnv.CLOUD_CODE_URL = urls.agyQuota;
  const runEnv = await withShellCommand(command, baseEnv, sourceEnv);
  await mkdir(home, { recursive: true });
  const { code, stdout, stderr, authPrompted } = await runAgyUsage(command, runEnv, home);
  if (authPrompted) {
    throw new RenewRefused(401, tr(lang, "station.quota.signInExpired"));
  }
  const parsed = parseJsonLine(stdout);
  if (parsed !== null && parsed.status === "SUCCESS") {
    const { windows, scoped } = agyAllowance(parsed);
    if (direct && windows.length > 0 && !windows.some(isGeminiWeekly)) {
      const daily = agyBase(urls, AGY_CLOUD_CODE_URL);
      const production = agyProductionBase(urls);
      const project = await agyQuotaProject(home, daily);
      if (project !== null) {
        // Only fall back to production when daily answered cleanly and omitted the weekly window.
        const summary = await agyPost(daily, AGY_QUOTA_SUMMARY, project.token, project.payload);
        if (isObject(summary)) {
          const weekly =
            agyWindows(summary).find(isGeminiWeekly) ??
            (daily !== production ? await agyGeminiWeekly(production, project.token, project.payload) : undefined);
          if (weekly !== undefined) windows.unshift(weekly);
        }
      }
    }
    // A company's account paying as it goes (a Google Cloud project with no subscription) has no windows to show.
    if (windows.length === 0 && scoped.length === 0 && agyCompany(await readFile(agyToken(home), "utf8").catch(() => ""))) {
      return { state: "unsupported", windows: [], detail: tr(lang, "station.quota.agyPayAsYouGo"), checkedAt: 0 };
    }
    const q = okOrUnavailable(windows.length > 0 ? windows : scoped, tr(lang, "station.quota.agyNoWindows"));
    if (q.state === "ok" && windows.length > 0 && scoped.length > 0) q.scoped = scoped;
    return q;
  }
  const said = typeof parsed?.error === "string" && parsed.error.trim() !== "" ? parsed.error.trim() : stderr.trim() || stdout.trim();
  // Google refusing the account until a person verifies it: blocked, saying where to verify it. Its page comes after
  // the first 300 characters.
  const verify = agyVerify(said);
  if (verify !== null) {
    const detail = verify !== "" ? tr(lang, "station.quota.agyVerifyAt", { url: verify }) : tr(lang, "station.quota.agyVerify");
    return { state: "blocked", windows: [], detail, checkedAt: 0 };
  }
  if (direct && agyLocationIneligible(said)) {
    const read = await agyDirectQuota(home, urls, lang);
    if (read !== null) return read;
  }
  const detail = clipKeepingLinks(said, 300);
  if (authFailure(detail)) {
    throw new RenewRefused(401, tr(lang, "station.quota.signInExpired"));
  }
  if (networkFailure(detail)) {
    const err: NodeJS.ErrnoException = new Error(detail || "agy /usage network error");
    err.code = "ECONNREFUSED";
    throw err;
  }
  const statusMatch = /\bHTTP\s+(429|5\d\d)\b|\bstatus(?:\s+code)?[:=\s]+(429|5\d\d)\b/i.exec(detail);
  if (statusMatch) {
    const status = Number(statusMatch[1] ?? statusMatch[2]);
    return {
      state: "unavailable",
      windows: [],
      detail: tr(lang, "station.quota.providerStatus", { provider: "Antigravity ", status }),
      checkedAt: 0,
      unanswered: true,
    };
  }
  throw new Error(detail !== "" ? detail : `agy exited (${code})`);
}
