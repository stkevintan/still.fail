// Allowances and renewing a Claude login: against local providers, in temp homes.
import assert from "node:assert/strict";
import { describe, test } from "node:test";
import { existsSync, mkdirSync, readFileSync, realpathSync, rmdirSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { devNull } from "node:os";
import { delimiter, join } from "node:path";
import { fileURLToPath } from "node:url";
import { agyAllowance, agyModelWindows, agyScopeForModel, agyVerify, clipKeepingLinks } from "../src/accounts/agy-quota.ts";
import { claudeOAuthToken, RefreshLock } from "../src/accounts/oauth.ts";
import { readClaudeCredentials } from "../src/agents/machine-logins.ts";
import { URLS } from "../src/accounts/profiles.ts";
import { at, checkQuota, claudeUsage, claudeWithRefresh, codexQuota, codexUsage, codexWindows, machineUsage, windowLabel } from "../src/accounts/quota.ts";
import { AGY_FILE_TOKENS, SESSIONS, agyAccountFile, agyConversations, agyHome, agyKeychain, agyToken, geminiDir } from "../src/agents/agy.ts";
import { platform } from "../src/platform/index.ts";
import { hubConfig } from "../src/sessions/config.ts";
import { machine, provider, script, temp, until } from "./accounts-fakes.ts";

describe("allowances and renewing", { concurrency: true }, () => {
  test("MiniMax Token Plan reports shared text quota and leaves ordinary keys alone", async (t) => {
    const start = 1_800_000_000_000;
    const end = start + 5 * 60 * 60_000;
    const weeklyEnd = start + 7 * 24 * 60 * 60_000;
    const p = await provider(() => ({
      status: 200,
      body: {
        base_resp: { status_code: 0 },
        model_remains: [
          { model_name: "video", current_interval_remaining_percent: 10, start_time: start, end_time: end },
          {
            model_name: "general", start_time: start, end_time: end, current_interval_remaining_percent: 75,
            weekly_start_time: start, weekly_end_time: weeklyEnd, current_weekly_remaining_percent: 95,
          },
        ],
      },
    }));
    t.after(p.close);
    const urls = { ...URLS, minimaxCnQuota: p.base + "/v1/token_plan/remains" };
    const profile = { id: "minimax", runtime: "claude", home: "homes/minimax" } as const;
    const check = (key: string) => {
      const configured = { ...profile, access: { kind: "api-provider", provider: "minimax-cn", key } };
      return checkQuota(hubConfig({ profiles: [configured] }, "/x").profiles[0]!, {}, undefined, urls, "en");
    };

    assert.equal((await check("ordinary-key")).state, "unsupported");
    assert.equal(p.asked.length, 0);
    const result = await check("sk-cp-test");
    assert.equal(result.state, "ok");
    assert.deepEqual(result.windows, [
      { label: "5 小时", minutes: 300, usedPercent: 25, resetsAt: end },
      { label: "每周", minutes: 10080, usedPercent: 5, resetsAt: weeklyEnd },
    ]);
    assert.deepEqual(p.asked.map((r) => [r.method, r.url, r.headers.authorization]), [
      ["GET", "/v1/token_plan/remains", "Bearer sk-cp-test"],
    ]);
  });

  test("GLM Coding Plan reports token windows and treats a failed lookup as unavailable", async (t) => {
    const reset = 1_800_000_000_000;
    let code = 200;
    const p = await provider(() => ({
      status: 200,
      body: {
        code,
        data: { limits: [
          { type: "TOKENS_LIMIT", unit: 6, number: 1, percentage: 11, nextResetTime: reset },
          { type: "TOKENS_LIMIT", unit: 3, number: 5, percentage: 0 },
          { type: "TIME_LIMIT", unit: 5, number: 1, percentage: 37, nextResetTime: reset },
        ] },
      },
    }));
    t.after(p.close);
    const urls = { ...URLS, glmCodingCnQuota: p.base + "/api/monitor/usage/quota/limit" };
    const profile = {
      id: "glm", runtime: "pi", home: "homes/glm",
      access: { kind: "api-provider", provider: "zai-coding-cn", key: "glm-test" },
    } as const;
    const check = () => checkQuota(hubConfig({ profiles: [profile] }, "/x").profiles[0]!, {}, undefined, urls, "en");

    const result = await check();
    assert.equal(result.state, "ok");
    assert.deepEqual(result.windows, [
      { label: "5 小时", minutes: 300, usedPercent: 0, resetsAt: null },
      { label: "每周", minutes: 10080, usedPercent: 11, resetsAt: reset },
    ]);
    assert.deepEqual(p.asked.map((r) => [r.method, r.url, r.headers.authorization]), [
      ["GET", "/api/monitor/usage/quota/limit", "Bearer glm-test"],
    ]);
    code = 401;
    assert.equal((await check()).state, "unavailable");
  });

  test("an account its provider refuses is blocked, a sign-in no longer good is not", async () => {
    let p = await provider(() => ({ status: 403, body: { error: { message: "This organization has been disabled." } } }));
    const blocked = await claudeUsage(p.base, "t", "zh");
    assert.equal(blocked.state, "blocked");
    assert.ok(blocked.detail!.includes("This organization has been disabled"));
    await p.close();
    p = await provider(() => ({ status: 401, body: { error: { message: "OAuth token has expired" } } }));
    const expired = await claudeUsage(p.base, "t", "zh");
    assert.deepEqual([expired.state, expired.detail], ["unavailable", "登录已过期或失效"]);
    await p.close();
    p = await provider(() => ({ status: 401, body: { detail: "Your account has been deactivated" } }));
    assert.equal((await claudeUsage(p.base, "t", "zh")).state, "blocked");
    await p.close();
  });

  test("a Claude subscription's allowance says whether its usage credits (what Fast is billed to) are on", async () => {
    let extra: unknown = { is_enabled: true, monthly_limit: 5000 };
    const p = await provider(() => ({ status: 200, body: { five_hour: { utilization: 5, resets_at: null }, extra_usage: extra } }));
    assert.equal((await claudeUsage(p.base, "t", "zh")).extraUsage, true);
    extra = { is_enabled: false };
    assert.equal((await claudeUsage(p.base, "t", "zh")).extraUsage, false);
    extra = null;
    assert.equal("extraUsage" in (await claudeUsage(p.base, "t", "zh")), false, "not said: not known");
    await p.close();
  });

  test("a model's own week under a Claude subscription's is read apart from the account's windows", async () => {
    // As Anthropic answered on 2026-11-09 (the fields this reads).
    const week = { utilization: 10, resets_at: "2026-11-16T11:59:59.936566+00:00" };
    const limits = [
      { kind: "weekly_all", group: "weekly", percent: 10, resets_at: week.resets_at, scope: null, is_active: true },
      { kind: "weekly_scoped", group: "weekly", percent: 8, resets_at: "2026-11-16T11:59:59.936748+00:00", scope: { model: { id: null, display_name: "Fable" }, surface: null }, is_active: false },
      { kind: "weekly_scoped", group: "weekly", percent: 40, resets_at: null, scope: { model: { id: null, display_name: "Opus" }, surface: null } },
      { kind: "session_scoped", group: "session", percent: 1, resets_at: null, scope: { model: { id: null, display_name: "Fable" }, surface: null } },
    ];
    const p = await provider(() => ({ status: 200, body: { five_hour: null, seven_day: week, seven_day_opus: { utilization: 40, resets_at: null }, limits } }));
    const quota = await claudeUsage(p.base, "t", "zh");
    const resetsAt = Date.parse("2026-11-16T11:59:59.936Z");
    assert.deepEqual(quota.windows, [
      { label: "每周", usedPercent: 10, resetsAt, minutes: 10080 },
      { label: "每周 · Opus", usedPercent: 40, resetsAt: null, minutes: 10080 },
    ]);
    assert.deepEqual(quota.scoped, [{ label: "每周 · Fable", usedPercent: 8, resetsAt, minutes: 10080, scope: "Fable" }], "Opus's said once, by its field; a group not known left out");
    // A login of the machine's that is no profile yet is offered by the account's own windows alone.
    const m = machine(); // (its `security` finds no keychain item: the login is the file's)
    mkdirSync(join(m.home, ".claude"));
    writeFileSync(join(m.home, ".claude", ".credentials.json"), JSON.stringify(credentials(Date.now() + 3_600_000)));
    const offered = await machineUsage("claude", m.env, { ...URLS, anthropic: p.base }, "zh");
    assert.deepEqual([offered!.windows.length, "scoped" in offered!], [2, false]);
    await p.close();
    const none = await provider(() => ({ status: 200, body: { seven_day: week, limits: [limits[0]] } }));
    assert.equal("scoped" in (await claudeUsage(none.base, "t", "zh")), false);
    await none.close();
  });

  test("an Antigravity CLI Google sign-in's allowance is read via `agy -p /usage` in its profile files", async () => {
    const home = temp("agy-quota");
    const dump = join(home, "dump");
    const fakePath = `${fileURLToPath(new URL("./fake", import.meta.url))}${delimiter}${process.env.PATH ?? ""}`;
    const tokenPath = agyToken(home);
    mkdirSync(join(home, "agy", ".gemini", "antigravity-cli"), { recursive: true });
    writeFileSync(
      tokenPath,
      JSON.stringify({
        token: { access_token: "ya29.ok", token_type: "Bearer", refresh_token: "1//refresh" },
        auth_method: "oauth",
        id_token_email: "me@gmail.com",
      }),
    );
    const profile = hubConfig({ profiles: [{ id: "ag", home, runtime: "agy", access: { kind: "subscription" } }] }, "/x").profiles[0]!;
    const env = { PATH: fakePath, FAKE_DUMP: dump, GEMINI_API_KEY: "machine-key" };
    const urls = { ...URLS, agyQuota: "https://aicode.example.test" };
    const q = await checkQuota(profile, env, undefined, urls, "zh");
    assert.equal(q.state, "ok");
    assert.deepEqual(q.windows, [
      { label: "每周 · Gemini", usedPercent: 25, resetsAt: Date.parse("2026-11-19T09:14:38Z"), minutes: 10080, scope: "gemini" },
      { label: "5 小时 · Gemini", usedPercent: 10, resetsAt: Date.parse("2026-11-12T14:14:38Z"), minutes: 300, scope: "gemini" },
      { label: "每周 · Claude / GPT", usedPercent: 60, resetsAt: Date.parse("2026-11-19T09:14:38Z"), minutes: 10080, scope: "3p" },
      { label: "5 小时 · Claude / GPT", usedPercent: 100, resetsAt: Date.parse("2026-11-12T14:14:38Z"), minutes: 300, scope: "3p" },
    ]);
    const ran = JSON.parse(readFileSync(dump, "utf8").trim().split("\n")[0]!);
    assert.deepEqual(ran.args, ["--log-file", devNull, "-p", "/usage", "--output-format", "json"]);
    assert.equal(ran.home, agyHome(home));
    assert.equal(ran.geminiDir, geminiDir(home));
    assert.equal(ran.fileTokens, AGY_FILE_TOKENS.SSH_CLIENT);
    assert.equal(ran.cloudCodeUrl, "https://aicode.example.test");
    assert.equal(ran.key, null, "scrubs inherited GEMINI_API_KEY");
    assert.equal(ran.updates, "1");

    let hasGeminiWeekly = true;
    const weeklyReset = "2030-01-20T08:00:00Z";
    const cliUserAgent = /^antigravity\/cli\/\d+\.\d+\.\d+/;
    const quotaApi = await provider((req) => {
      if (req.url.endsWith(":loadCodeAssist")) {
        return { status: 200, body: { paidTier: { id: "g1-pro-tier" }, cloudaicompanionProject: "aicode-consumers" } };
      }
      if (req.url.endsWith(":retrieveUserQuotaSummary")) {
        // Google omits the Gemini Models group when User-Agent lacks the CLI product segment.
        const includeGemini = cliUserAgent.test(String(req.headers["user-agent"] ?? ""));
        return {
          status: 200,
          body: {
            quotaSummary: {
              groups: [
                ...(includeGemini
                  ? [
                      {
                        displayName: "Gemini Models",
                        buckets: [
                          { bucketId: "gemini-5h", remainingFraction: 0.5 },
                          ...(hasGeminiWeekly ? [{ bucketId: "gemini-weekly", remainingFraction: 0.68, resetTime: weeklyReset }] : []),
                        ],
                      },
                    ]
                  : []),
                { displayName: "Gemini 4 Argon", buckets: [{ bucketId: "gemini-argon-wtu-weekly", remainingFraction: 0.8 }] },
              ],
            },
          },
        };
      }
      return { status: 404, body: {} };
    });
    try {
      const apiUrls = { ...URLS, agyQuota: quotaApi.base };
      const complete = await checkQuota(profile, { PATH: fakePath }, undefined, apiUrls, "zh");
      assert.deepEqual(complete.windows, q.windows);
      assert.deepEqual(quotaApi.asked, []);

      const partialEnv = { PATH: fakePath, FAKE_AGY_USAGE_NO_GEMINI_WEEKLY: "1" };
      const supplemented = await checkQuota(profile, partialEnv, undefined, apiUrls, "zh");
      assert.deepEqual(supplemented.windows, [
        { label: "每周 · Gemini", usedPercent: 32, resetsAt: Date.parse(weeklyReset), minutes: 10080, scope: "gemini" },
        ...q.windows.slice(1),
      ]);
      assert.deepEqual(
        quotaApi.asked.map(({ url, body, headers }) => [url, body, headers["user-agent"]]),
        [
          ["/v1internal:loadCodeAssist", { metadata: { ideType: "ANTIGRAVITY" } }, "antigravity/cli/1.5.15"],
          ["/v1internal:retrieveUserQuotaSummary", { project: "aicode-consumers" }, "antigravity/cli/1.5.15"],
        ],
      );

      // Turned off on the profile (`directQuota: false`), only the CLI is asked: Gemini's week stays missing.
      const cliOnly = { ...profile, directQuota: false };
      quotaApi.asked.length = 0;
      const notSupplemented = await checkQuota(cliOnly, partialEnv, undefined, apiUrls, "zh");
      assert.deepEqual(notSupplemented.windows, q.windows.slice(1));
      assert.deepEqual(quotaApi.asked, []);

      hasGeminiWeekly = false;
      const unavailable = await checkQuota(profile, partialEnv, undefined, apiUrls, "zh");
      assert.deepEqual(unavailable.windows, q.windows.slice(1));
    } finally {
      await quotaApi.close();
    }

    // Supplementing a missing Gemini weekly window queries daily before production so the active daily pool's real
    // usage wins over production's separate pool, falling back to production only when daily answered cleanly and
    // omitted the window. A failed daily summary request must not fall back to production's untouched 0% pool.
    let dailySummaryStatus = 200;
    let dailyWeekly = true;
    const prodReset = "2030-01-21T08:00:00Z";
    const splitGeminiReset = "2030-01-15T08:00:00Z";
    const splitThirdPartyReset = "2030-01-15T08:15:00Z";
    const dailyApi = await provider((req) => {
      if (req.url.endsWith(":loadCodeAssist")) {
        return { status: 200, body: { paidTier: { id: "g1-ultra-tier" }, cloudaicompanionProject: "aicode-consumers" } };
      }
      if (req.url.endsWith(":retrieveUserQuotaSummary")) {
        if (dailySummaryStatus !== 200) return { status: dailySummaryStatus, body: { error: { message: "internal" } } };
        const includeGemini = cliUserAgent.test(String(req.headers["user-agent"] ?? ""));
        return {
          status: 200,
          body: {
            groups: [
              ...(includeGemini && dailyWeekly
                ? [{ displayName: "Gemini Models", buckets: [{ bucketId: "gemini-weekly", window: "weekly", remainingFraction: 0.68, resetTime: weeklyReset }] }]
                : []),
              { displayName: "Claude and GPT models", buckets: [{ bucketId: "3p-weekly", window: "weekly", remainingFraction: 0.6 }] },
            ],
          },
        };
      }
      if (req.url.endsWith(":fetchAvailableModels")) {
        return {
          status: 200,
          body: {
            models: {
              "gemini-4-hydrogen-sonar": { quotaInfo: { remainingFraction: 0.92, resetTime: splitGeminiReset } },
              "claude-opus-5-5-high": { quotaInfo: { remainingFraction: 0.9, resetTime: splitThirdPartyReset } },
            },
          },
        };
      }
      return { status: 404, body: {} };
    });
    const prodApi = await provider((req) => {
      if (req.url.endsWith(":retrieveUserQuotaSummary")) {
        const includeGemini = cliUserAgent.test(String(req.headers["user-agent"] ?? ""));
        return {
          status: 200,
          body: {
            groups: [
              ...(includeGemini
                ? [{ displayName: "Gemini Models", buckets: [{ bucketId: "gemini-weekly", window: "weekly", remainingFraction: 1, resetTime: prodReset }] }]
                : []),
            ],
          },
        };
      }
      return { status: 404, body: {} };
    });
    try {
      const splitUrls = { ...URLS, agyQuota: dailyApi.base, agyQuotaProduction: prodApi.base };
      const partialEnv = { PATH: fakePath, FAKE_AGY_USAGE_NO_GEMINI_WEEKLY: "1" };

      const fromDaily = await checkQuota(profile, partialEnv, undefined, splitUrls, "zh");
      assert.deepEqual(fromDaily.windows[0], { label: "每周 · Gemini", usedPercent: 32, resetsAt: Date.parse(weeklyReset), minutes: 10080, scope: "gemini" });
      assert.equal(prodApi.asked.length, 0, "production is not queried when daily returns Gemini weekly");

      // Daily summary fails (500): do not query production or fabricate a 0% Gemini weekly window.
      dailySummaryStatus = 500;
      const dailyFailed = await checkQuota(profile, partialEnv, undefined, splitUrls, "zh");
      assert.deepEqual(dailyFailed.windows, q.windows.slice(1));
      assert.equal(prodApi.asked.length, 0, "production is not queried when daily summary fails");

      // Direct location-ineligible fallback with daily summary returning 500: do not query production either.
      const splitLocationErr = "Eligibility check failed: Your current account is not eligible for Antigravity, because it is not currently available in your location.";
      const directDailyFailed = await checkQuota(profile, { PATH: fakePath, FAKE_AGY_USAGE_ERROR: splitLocationErr }, undefined, splitUrls, "zh");
      assert.equal(directDailyFailed.state, "ok");
      assert.equal(directDailyFailed.windows.some((w) => w.scope === "gemini" && w.minutes === 10080), false);
      assert.deepEqual(directDailyFailed.windows, [
        { label: "5 小时 · Gemini", usedPercent: 8, resetsAt: Date.parse(splitGeminiReset), minutes: 300, scope: "gemini" },
        { label: "5 小时 · Claude / GPT", usedPercent: 10, resetsAt: Date.parse(splitThirdPartyReset), minutes: 300, scope: "3p" },
      ]);
      assert.equal(prodApi.asked.length, 0, "direct fallback does not query production when daily summary fails");

      // Daily answers 200 cleanly but omits Gemini weekly: fall back to production on both paths.
      dailySummaryStatus = 200;
      dailyWeekly = false;
      const fromProd = await checkQuota(profile, partialEnv, undefined, splitUrls, "zh");
      assert.deepEqual(fromProd.windows[0], { label: "每周 · Gemini", usedPercent: 0, resetsAt: Date.parse(prodReset), minutes: 10080, scope: "gemini" });
      assert.deepEqual(
        prodApi.asked.map(({ url, body, headers }) => [url, body, headers["user-agent"]]),
        [["/v1internal:retrieveUserQuotaSummary", { project: "aicode-consumers" }, "antigravity/cli/1.5.15"]],
      );

      const directFromProd = await checkQuota(profile, { PATH: fakePath, FAKE_AGY_USAGE_ERROR: splitLocationErr }, undefined, splitUrls, "zh");
      assert.deepEqual(directFromProd.windows.find((w) => w.scope === "gemini" && w.minutes === 10080), {
        label: "每周 · Gemini",
        usedPercent: 0,
        resetsAt: Date.parse(prodReset),
        minutes: 10080,
        scope: "gemini",
      });
      assert.equal(prodApi.asked.length, 2);
    } finally {
      await dailyApi.close();
      await prodApi.close();
    }

    // macOS: `agy` is kept to the profile's file (`AGY_FILE_TOKENS`, HOME its agy/), never the login keychain's one
    // item. A profile whose file `agy` had moved into that item takes it back when the item is its noted account; an
    // unsigned profile (even with `agy/sessions` linked by `linkTranscripts` and a cancelled `agy` home) and one whose
    // item is another account's spawn nothing.
    const keyringHome = temp("agy-quota-keyring");
    const keyringDump = join(keyringHome, "dump");
    mkdirSync(agyConversations(keyringHome), { recursive: true });
    writeFileSync(join(agyConversations(keyringHome), "conv.db"), "db");
    writeFileSync(agyAccountFile(keyringHome), JSON.stringify({ email: "me@gmail.com" }));
    const kept = JSON.stringify({ token: { access_token: "ya29.kept" }, auth_method: "consumer", id_token_email: "me@gmail.com" });
    const keyringProfile = hubConfig({ profiles: [{ id: "ag-k", home: keyringHome, runtime: "agy", access: { kind: "subscription" } }] }, "/x").profiles[0]!;
    const hadKeychain = platform.hasKeychain;
    const read = agyKeychain.read;
    platform.hasKeychain = true;
    agyKeychain.read = async () => `go-keyring-base64:${Buffer.from(kept).toString("base64")}`;
    try {
      const kq = await checkQuota(keyringProfile, { HOME: temp("agy-real-home"), PATH: fakePath, FAKE_DUMP: keyringDump }, undefined, URLS, "zh");
      assert.equal(kq.state, "ok");
      const kran = JSON.parse(readFileSync(keyringDump, "utf8").trim().split("\n")[0]!);
      assert.deepEqual([kran.home, kran.geminiDir, kran.fileTokens], [agyHome(keyringHome), geminiDir(keyringHome), AGY_FILE_TOKENS.SSH_CLIENT]);
      assert.equal(readFileSync(agyToken(keyringHome), "utf8"), kept);

      const otherHome = temp("agy-quota-other");
      const otherDump = join(otherHome, "dump");
      mkdirSync(agyHome(otherHome), { recursive: true });
      writeFileSync(agyAccountFile(otherHome), JSON.stringify({ email: "other@gmail.com" }));
      const otherProfile = hubConfig({ profiles: [{ id: "ag-o", home: otherHome, runtime: "agy", access: { kind: "subscription" } }] }, "/x").profiles[0]!;
      const oq = await checkQuota(otherProfile, { PATH: fakePath, FAKE_DUMP: otherDump }, undefined, URLS, "zh");
      assert.deepEqual([oq.state, oq.detail], ["unavailable", "登录已过期或失效"]);
      assert.equal(existsSync(otherDump), false, "another account's item is not taken");

      const unsignedHome = temp("agy-quota-unsigned");
      const unsignedDump = join(unsignedHome, "dump");
      mkdirSync(join(agyHome(unsignedHome), SESSIONS), { recursive: true });
      mkdirSync(join(unsignedHome, "agy", ".gemini", "antigravity-cli"), { recursive: true });
      const unsignedProfile = hubConfig({ profiles: [{ id: "ag-u", home: unsignedHome, runtime: "agy", access: { kind: "subscription" } }] }, "/x").profiles[0]!;
      const uq = await checkQuota(unsignedProfile, { PATH: fakePath, FAKE_DUMP: unsignedDump }, undefined, URLS, "zh");
      assert.deepEqual([uq.state, uq.signedOut, uq.detail], ["unavailable", undefined, "登录已过期或失效"]);
      assert.equal(existsSync(unsignedDump), false, "unsigned profile does not spawn agy");
    } finally {
      platform.hasKeychain = hadKeychain;
      agyKeychain.read = read;
    }

    // Expired sign-in prompting interactive OAuth marks signedOut without hanging 60s.
    const sq = await checkQuota(profile, { PATH: fakePath, FAKE_AGY_SIGNED_OUT: "1" }, undefined, URLS, "zh");
    assert.deepEqual([sq.state, sq.signedOut, sq.detail], ["unavailable", true, "登录已过期或失效"]);

    // Network failure (including whole-word EOF, but not substrings like `typeof`) marks unanswered so previous quota stands.
    const nq = await checkQuota(profile, { PATH: fakePath, FAKE_AGY_USAGE_ERROR: "dial tcp 127.0.0.1:1: connect: connection refused" }, undefined, URLS, "zh");
    assert.deepEqual([nq.state, nq.unanswered, nq.detail], ["unavailable", true, "无法连接服务商，请检查此 station 的网络或代理"]);
    const eofQ = await checkQuota(profile, { PATH: fakePath, FAKE_AGY_USAGE_ERROR: "Post https://cloudcode-pa.googleapis.com: unexpected EOF" }, undefined, URLS, "zh");
    assert.equal(eofQ.unanswered, true);
    const blockedQ = await checkQuota(profile, { PATH: fakePath, FAKE_AGY_USAGE_ERROR: "Your account has been suspended (typeof check)" }, undefined, URLS, "zh");
    assert.deepEqual([blockedQ.state, blockedQ.unanswered], ["blocked", undefined]);
    // Google holding the account until it is verified: blocked (the pool passes it over), with the page to verify it on,
    // which comes after the 300 characters other errors are cut to.
    const page = "https://accounts.google.com/v3/signin/continue?plt=AKgnsbvgpMGWUxHL-LdY6TaKwyqigcx13EZGzlKmZcGrDxrNDt57SPhlkbXKa1uIKydtd8wIqmUCw2x25ooo2v5G_JN2S8spn6C0rCAJWTFB47we5La_Ckx-UMLZpie3MBHPZkmLQIIq&continue=https://developers.google.com/gemini-code-assist/auth/auth_success_gemini&sarp=1&scc=1&flowName=GlifWebSignIn&authuser";
    const verifyQ = await checkQuota(
      profile,
      {
        PATH: fakePath,
        FAKE_AGY_USAGE_ERROR: `Eligibility check failed: Your current account is not eligible for Antigravity. Verify your account to continue.\n\nAlternatively, try signing in with another personal Google account.\n\nPlease verify your account in your browser to continue:\n${page}`,
      },
      undefined,
      URLS,
      "zh",
    );
    assert.deepEqual([verifyQ.state, verifyQ.unanswered, verifyQ.detail], ["blocked", undefined, `Google 要求先验证这个账号才能用 Antigravity。用登录了这个 Google 账号的浏览器打开下面的链接完成验证，然后重新查询额度\n${page}`]);
    assert.equal(agyVerify("PERMISSION_DENIED (code 403): Verify your account to continue."), "");
    assert.equal(agyVerify("Your account has been suspended"), null);
    const locationErr = "Eligibility check failed: Your current account is not eligible for Antigravity, because it is not currently available in your location.";
    assert.equal(agyVerify(locationErr), null);

    // Paid account whose free-tier is ineligible in the current location: `agy -p /usage` fails its eligibility check,
    // so `agyQuota` confirms an active tier via `loadCodeAssist` and falls back to `retrieveUserQuotaSummary` +
    // `fetchAvailableModels` to fill missing pools (e.g. Gemini).
    let paidTier = true;
    let geminiSpent = false;
    let dailyHasGeminiWeekly = false;
    let dailyHasGeminiFiveHour = false;
    const geminiReset = "2030-01-15T08:00:00Z";
    const thirdPartyReset = "2030-01-15T08:15:00Z";
    const agyApi = await provider((req) => {
      if (req.url.endsWith(":loadCodeAssist")) {
        return {
          status: 200,
          body: paidTier
            ? {
                currentTier: { id: "free-tier", name: "Free" },
                paidTier: { id: "g1-ultra-lite-tier", name: "Google AI Ultra" },
                cloudaicompanionProject: "aicode-consumers",
                ineligibleTiers: [{ tierId: "free-tier", reasonCode: "UNSUPPORTED_LOCATION" }],
              }
            : { ineligibleTiers: [{ tierId: "free-tier", reasonCode: "UNSUPPORTED_LOCATION" }] },
        };
      }
      if (req.url.endsWith(":retrieveUserQuotaSummary")) {
        const includeGemini = cliUserAgent.test(String(req.headers["user-agent"] ?? ""));
        const geminiBuckets = [
          ...(dailyHasGeminiWeekly ? [{ bucketId: "gemini-weekly", window: "weekly", remainingFraction: 0.68, resetTime: weeklyReset }] : []),
          ...(dailyHasGeminiFiveHour ? [{ bucketId: "gemini-5h", window: "5h", remainingFraction: 0.96, resetTime: geminiReset }] : []),
        ];
        return {
          status: 200,
          body: {
            groups: [
              ...(includeGemini && geminiBuckets.length > 0 ? [{ displayName: "Gemini Models", buckets: geminiBuckets }] : []),
              {
                displayName: "Claude and GPT models",
                buckets: [
                  { bucketId: "3p-weekly", window: "weekly", remainingFraction: 1 },
                  { bucketId: "3p-5h", window: "5h", remainingFraction: 0.9, resetTime: thirdPartyReset },
                ],
              },
            ],
          },
        };
      }
      if (req.url.endsWith(":fetchAvailableModels")) {
        return {
          status: 200,
          body: {
            models: {
              "gemini-4-hydrogen-sonar": { quotaInfo: { remainingFraction: geminiSpent ? undefined : 0.92, resetTime: geminiReset } },
              "gemini-3.8-flash-tiered": { quotaInfo: { remainingFraction: geminiSpent ? undefined : 0.98, resetTime: geminiReset } },
              "claude-opus-5-5-high": { quotaInfo: { remainingFraction: 0.9, resetTime: thirdPartyReset } },
              tab_flash_lite_preview: { quotaInfo: { remainingFraction: 1 } },
            },
          },
        };
      }
      return { status: 404, body: {} };
    });
    try {
      // Turned off on the profile, the CLI's refusal is said as it is and nothing is asked of Google's API.
      const refused = await checkQuota({ ...profile, directQuota: false }, { PATH: fakePath, FAKE_AGY_USAGE_ERROR: locationErr }, undefined, { ...URLS, agyQuota: agyApi.base }, "zh");
      assert.equal(refused.state, "unavailable");
      assert.ok(refused.detail?.includes("not currently available in your location"));
      assert.equal(agyApi.asked.length, 0);

      const fallbackQ = await checkQuota(profile, { PATH: fakePath, FAKE_AGY_USAGE_ERROR: locationErr }, undefined, { ...URLS, agyQuota: agyApi.base }, "zh");
      assert.equal(fallbackQ.state, "ok");
      assert.equal(fallbackQ.plan, "Ultra 5x");
      assert.deepEqual(fallbackQ.windows, [
        { label: "5 小时 · Gemini", usedPercent: 8, resetsAt: Date.parse(geminiReset), minutes: 300, scope: "gemini" },
        { label: "每周 · Claude / GPT", usedPercent: 0, resetsAt: null, minutes: 10080, scope: "3p" },
        { label: "5 小时 · Claude / GPT", usedPercent: 10, resetsAt: Date.parse(thirdPartyReset), minutes: 300, scope: "3p" },
      ]);

      // Google omits remainingFraction when the model pool is exhausted, but still gives its reset time.
      geminiSpent = true;
      const spentQ = await checkQuota(profile, { PATH: fakePath, FAKE_AGY_USAGE_ERROR: locationErr }, undefined, { ...URLS, agyQuota: agyApi.base }, "zh");
      assert.equal(spentQ.state, "ok");
      assert.deepEqual(spentQ.windows, [
        { ...fallbackQ.windows[0]!, usedPercent: 100 },
        ...fallbackQ.windows.slice(1),
      ]);

      dailyHasGeminiWeekly = true;
      const beforeWeekly = agyApi.asked.length;
      const weeklyQ = await checkQuota(profile, { PATH: fakePath, FAKE_AGY_USAGE_ERROR: locationErr }, undefined, { ...URLS, agyQuota: agyApi.base }, "zh");
      assert.deepEqual(weeklyQ.windows, [
        spentQ.windows[0],
        { label: "每周 · Gemini", usedPercent: 32, resetsAt: Date.parse(weeklyReset), minutes: 10080, scope: "gemini" },
        ...spentQ.windows.slice(1),
      ]);
      const weeklyAsked = agyApi.asked.slice(beforeWeekly);
      assert.ok(weeklyAsked.length > 0 && weeklyAsked.every((r) => r.headers["user-agent"] === "antigravity/cli/1.5.15"));

      // When daily retrieveUserQuotaSummary returns both Gemini buckets (weekly + 5h), the direct fallback keeps
      // all four windows without duplicating the 5-hour Gemini pool from fetchAvailableModels.
      dailyHasGeminiFiveHour = true;
      const fullDirectQ = await checkQuota(profile, { PATH: fakePath, FAKE_AGY_USAGE_ERROR: locationErr }, undefined, { ...URLS, agyQuota: agyApi.base }, "zh");
      assert.deepEqual(fullDirectQ.windows, [
        { label: "每周 · Gemini", usedPercent: 32, resetsAt: Date.parse(weeklyReset), minutes: 10080, scope: "gemini" },
        { label: "5 小时 · Gemini", usedPercent: 4, resetsAt: Date.parse(geminiReset), minutes: 300, scope: "gemini" },
        ...spentQ.windows.slice(1),
      ]);
      dailyHasGeminiFiveHour = false;

      // Account with no active tier at all in this location: falls through to report the location error, never a
      // verification hold.
      paidTier = false;
      const trulyBlockedQ = await checkQuota(profile, { PATH: fakePath, FAKE_AGY_USAGE_ERROR: locationErr }, undefined, { ...URLS, agyQuota: agyApi.base }, "zh");
      assert.equal(trulyBlockedQ.state, "unavailable");
      assert.ok(trulyBlockedQ.detail?.includes("not currently available in your location"));
    } finally {
      await agyApi.close();
    }
    assert.deepEqual(
      agyModelWindows({
        models: {
          "gemini-2.5-pro": { quotaInfo: { remainingFraction: 0.75, resetTime: geminiReset } },
          "gemini-3-flash": { quotaInfo: {} },
          "gemini-2.5-flash": { quotaInfo: { remainingFraction: "unknown", resetTime: geminiReset } },
          tab_jump_flash_lite_preview: { quotaInfo: { remainingFraction: 1 } },
        },
      }),
      [{ label: "5 小时 · Gemini", usedPercent: 25, resetsAt: Date.parse(geminiReset), minutes: 300, scope: "gemini" }],
    );

    // Another error a link is cut in: the link kept whole, which cut short opens a 400.
    assert.equal(clipKeepingLinks(`${"x".repeat(10)} ${page} after`, 30), `${"x".repeat(10)} ${page}`);
    assert.equal(clipKeepingLinks("x".repeat(40), 30), "x".repeat(30));

    // No windows: a person's account says it could not read them; a company's paying as it goes has none to show.
    const emptyQ = await checkQuota(profile, { PATH: fakePath, FAKE_AGY_USAGE_EMPTY: "1" }, undefined, URLS, "zh");
    assert.deepEqual([emptyQ.state, emptyQ.detail], ["unavailable", "Antigravity CLI 没有返回额度信息"]);
    writeFileSync(tokenPath, JSON.stringify({ token: { access_token: "ya29.ok", token_type: "Bearer", refresh_token: "1//refresh" }, auth_method: "gcp", id_token_email: "me@company.test", project_id: "company-project" }));
    const payGo = await checkQuota(profile, { PATH: fakePath, FAKE_AGY_USAGE_EMPTY: "1" }, undefined, URLS, "zh");
    assert.deepEqual([payGo.state, payGo.windows, payGo.detail], ["unsupported", [], "这个企业账号按用量计费，没有固定额度"]);

    assert.equal(agyScopeForModel("google/gemini-3.1-pro"), "gemini");
    assert.equal(agyScopeForModel("us.google.gemma-3-27b"), "gemini");
    assert.equal(agyScopeForModel("anthropic/claude-opus-4-6"), "3p");

    // Paid Pro accounts carry a separate weekly bucket for Gemini 4 Argon (`gemini-argon-wtu-weekly`), which goes into
    // `scoped` under `Argon` rather than duplicating `每周 · Gemini` in `windows`.
    const proAllowance = agyAllowance({
      command: {
        data: {
          groups: [
            {
              name: "Gemini Models",
              buckets: [
                { id: "gemini-weekly", window: "weekly", remaining_fraction: 1, reset_time: "2026-11-23T04:49:34Z" },
                { id: "gemini-5h", window: "5h", remaining_fraction: 0.99, reset_time: "2026-11-16T09:49:34Z" },
              ],
            },
            {
              name: "Claude and GPT models",
              buckets: [
                { id: "3p-weekly", window: "weekly", remaining_fraction: 1, reset_time: "2026-11-22T13:43:14Z" },
                { id: "3p-5h", window: "5h", remaining_fraction: 1, reset_time: "2026-11-16T09:58:00Z" },
              ],
            },
            {
              name: "Gemini 4 Argon",
              buckets: [
                { id: "gemini-argon-wtu-weekly", window: "weekly", remaining_fraction: 0.87, reset_time: "2026-11-23T04:25:54Z" },
              ],
            },
          ],
        },
      },
    });
    assert.deepEqual(
      proAllowance.windows.map((w) => [w.label, w.scope, w.usedPercent]),
      [
        ["每周 · Gemini", "gemini", 0],
        ["5 小时 · Gemini", "gemini", 1],
        ["每周 · Claude / GPT", "3p", 0],
        ["5 小时 · Claude / GPT", "3p", 0],
      ],
    );
    assert.deepEqual(proAllowance.scoped, [
      { label: "每周 · Argon", usedPercent: 13, resetsAt: Date.parse("2026-11-23T04:25:54Z"), minutes: 10080, scope: "Argon" },
    ]);
  });

  test("a codex login's allowance is read with its auth.json's tokens", async () => {
    const dir = temp("codex-usage");
    const file = join(dir, "auth.json");
    writeFileSync(file, JSON.stringify({ tokens: { access_token: "at", account_id: "acc" } }));
    const body = {
      plan_type: "pro",
      rate_limit: {
        primary_window: { used_percent: 30, limit_window_seconds: 18_000, reset_at: 1_900_000_000 },
        secondary_window: { used_percent: 80, limit_window_seconds: 604_800, reset_at: 1_900_500_000 },
      },
    };
    const p = await provider(() => ({ status: 200, body }));
    const quota = await codexUsage(file, { ...URLS, chatgpt: p.base });
    assert.equal(quota!.plan, "pro");
    assert.deepEqual(quota!.windows, [
      { label: "5 小时", usedPercent: 30, resetsAt: 1_900_000_000_000, minutes: 300 },
      { label: "每周", usedPercent: 80, resetsAt: 1_900_500_000_000, minutes: 10080 },
    ]);
    assert.equal(p.asked[0]!.headers.authorization, "Bearer at");
    assert.equal(p.asked[0]!.headers["chatgpt-account-id"], "acc");
    assert.equal(p.asked[0]!.url, "/backend-api/wham/usage");
    // No file (the keychain keeps it): nothing to read.
    assert.equal(await codexUsage(join(dir, "none", "auth.json"), { ...URLS, chatgpt: p.base }), null);
    await p.close();
  });

  test("Codex's wrapped usage errors say what to do without exposing its RPC response", async () => {
    const profile = hubConfig({ profiles: [{ id: "cx", home: "homes/cx", runtime: "codex", access: { kind: "subscription" } }] }, "/x").profiles[0]!;
    const ask = (said: string, lang: "zh" | "en" = "zh") => checkQuota(profile, {}, async () => {
      throw new Error(`codex ${JSON.stringify({ code: -32603, message: said })}`);
    }, URLS, lang);
    const revoked = 'failed to fetch codex rate limits: GET https://chatgpt.com/backend-api/wham/usage failed: 401 Unauthorized; content-type=text/plain; body={"error":{"message":"Encountered invalidated oauth token for user, failing request","code":"token_revoked"},"status":401}';
    const q = await ask(revoked);
    assert.deepEqual([q.state, q.signedOut, q.detail], ["unavailable", true, "ChatGPT 登录已失效，请重新登录"]);
    assert.equal((await ask(revoked, "en")).detail, "ChatGPT sign-in is no longer valid. Sign in again.");
    const network = await ask("failed to fetch codex rate limits: error sending request: connection refused");
    assert.deepEqual([network.state, network.signedOut, network.detail], ["unavailable", undefined, "无法连接服务商，请检查此 station 的网络或代理"]);
    // Not reached, or the provider in trouble itself: no answer about the allowance (the one read before stands a
    // while: Accounts). What it says of the account is an answer.
    assert.deepEqual([q.unanswered, network.unanswered], [undefined, true]);
    const busy = await ask("failed to fetch codex rate limits: GET /usage failed: 503 Service Unavailable; body=private");
    assert.deepEqual([busy.state, busy.signedOut, busy.detail], ["unavailable", undefined, "ChatGPT 暂时无法提供额度信息（HTTP 503）"]);
    assert.equal(busy.unanswered, true);
    const blocked = await ask("failed to fetch codex rate limits: GET /usage failed: 403 Forbidden; account has been suspended");
    assert.deepEqual([blocked.state, blocked.detail], ["blocked", "ChatGPT 账号已被停用"]);
    assert.equal(blocked.unanswered, undefined);
    const other = await ask("internal error: private diagnostics 401");
    assert.deepEqual([other.state, other.signedOut, other.detail], ["unavailable", undefined, "暂时无法查询 ChatGPT 额度，请稍后重试"]);
  });

  test("a provider the station cannot reach is said so, not as Node says it", async () => {
    const dir = temp("codex-unreached");
    writeFileSync(join(dir, "auth.json"), JSON.stringify({ tokens: { access_token: "at" } }));
    // (port 1 is never bound by a test server: connection refused with no ephemeral-port reuse race)
    const quota = await machineUsage("codex", { CODEX_HOME: dir }, { ...URLS, chatgpt: "http://127.0.0.1:1" }, "zh");
    assert.deepEqual([quota!.state, quota!.detail], ["unavailable", "无法连接服务商，请检查此 station 的网络或代理"]);
    assert.equal(quota!.unanswered, true);
  });

  test("a provider in trouble itself gives no answer about the allowance; what it says of the account is one", async () => {
    const said: Record<number, boolean | undefined> = {};
    for (const status of [500, 503, 429, 401, 403, 404]) {
      const p = await provider(() => ({ status, body: {} }));
      said[status] = (await claudeUsage(p.base, "t", "zh")).unanswered;
      await p.close();
    }
    assert.deepEqual(said, { 500: true, 503: true, 429: true, 401: undefined, 403: undefined, 404: undefined });
  });

  test("codex credits and resets are independent of windows and preserve unknowns", () => {
    const q = codexQuota({ rateLimits: { credits: { hasCredits: true, unlimited: false, balance: "123.45" } }, rateLimitResetCredits: { availableCount: 2, credits: [] } });
    assert.equal(q.state, "ok");
    assert.deepEqual(q.windows, []);
    assert.equal(q.credits!.balance, "123.45");
    assert.equal(q.resetCount, 2);
    const old = codexQuota({ rateLimits: { primary: { usedPercent: 10 } } });
    assert.equal(old.credits, undefined);
    assert.equal(old.resetCount, undefined);
    assert.ok(codexQuota({ rateLimits: { credits: { hasCredits: true, unlimited: true, balance: null } } }).credits!.unlimited);
    const zero = codexQuota({ rateLimits: { credits: { hasCredits: false, unlimited: false, balance: "0" } }, rateLimitResetCredits: { availableCount: 0 } });
    assert.equal(zero.resetCount, 0);
    assert.equal(zero.credits!.balance, "0");
  });

  test("available Codex reset credits retain each known expiry", () => {
    const q = codexQuota({ rateLimits: {}, rateLimitResetCredits: { availableCount: 4, credits: [
      { status: "available", expiresAt: 1_900_200_000 },
      { status: "redeemed", expiresAt: 1_800_000_000 },
      { status: "available", expiresAt: null },
      { status: "available", expiresAt: 1_900_000_000 },
      { status: "available", expiresAt: "bad" },
    ] } });
    assert.equal(q.resetCount, 4);
    assert.deepEqual(q.resetExpiries, [1_900_000_000_000, 1_900_200_000_000]);
    assert.equal(codexQuota({ rateLimitResetCredits: { availableCount: 2, credits: null } }).resetExpiries, undefined);
    assert.equal(codexQuota({ rateLimitResetCredits: { availableCount: 0, credits: [{ status: "available", expiresAt: 1_900_000_000 }] } }).resetExpiries, undefined);
  });

  test("a machine or borrowed Codex login reads reset details without losing usage when they fail", async () => {
    const dir = temp("codex-reset-details");
    const file = join(dir, "auth.json");
    writeFileSync(file, JSON.stringify({ tokens: { access_token: "at", account_id: "acc" } }));
    let detailsOk = true;
    const p = await provider((request) => request.url.endsWith("/usage")
      ? { status: 200, body: { rate_limit_reset_credits: { available_count: 2 }, rate_limit: { primary_window: { used_percent: 30 } } } }
      : detailsOk
        ? { status: 200, body: { credits: [{ status: "available", expires_at: "2030-03-17T00:00:00Z" }] } }
        : { status: 503, body: {} });
    const urls = { ...URLS, chatgpt: p.base };
    const got = await codexUsage(file, urls);
    assert.equal(got!.resetCount, 2);
    assert.deepEqual(got!.resetExpiries, [Date.parse("2030-03-17T00:00:00Z")]);
    assert.equal(p.asked[1]!.url, "/backend-api/wham/rate-limit-reset-credits");
    assert.equal(p.asked[1]!.headers.authorization, "Bearer at");
    assert.equal(p.asked[1]!.headers["chatgpt-account-id"], "acc");
    detailsOk = false;
    const fallback = await codexUsage(file, urls);
    assert.deepEqual([fallback!.state, fallback!.resetCount, fallback!.resetExpiries], ["ok", 2, undefined]);
    await p.close();
  });

  test("a Codex app-server's missing or partial reset details are read with the same profile's login", async () => {
    const data = temp("codex-app-server-reset-details");
    const home = join(data, "homes", "cx");
    mkdirSync(home, { recursive: true });
    writeFileSync(join(home, "auth.json"), JSON.stringify({ tokens: { access_token: "at", account_id: "acc" } }));
    const profile = hubConfig({ profiles: [{ id: "cx", home: "homes/cx", runtime: "codex", access: { kind: "subscription" } }] }, data).profiles[0]!;
    const dates = ["2030-03-17T00:00:00Z", "2030-03-19T00:00:00Z"];
    let status = 200;
    let usageCount = 2;
    let detail: any = { available_count: 2, credits: dates.map((expires_at) => ({ status: "available", expires_at })) };
    const p = await provider((request) => request.url.endsWith("/usage")
      ? { status: 200, body: { rate_limit_reset_credits: { available_count: usageCount }, rate_limit: { primary_window: { used_percent: 35 } } } }
      : { status, body: detail });
    const urls = { ...URLS, chatgpt: p.base };
    const ask = (credits: any[], count: number) => checkQuota(profile, {}, async () => ({ rateLimits: { primary: { usedPercent: 30 } }, rateLimitResetCredits: { availableCount: count, credits } }), urls);
    const got = await ask([], 2);
    assert.deepEqual(got.resetExpiries, dates.map(Date.parse));
    assert.equal(got.windows[0]!.usedPercent, 35, "the dates and windows come from the same login");
    assert.equal(p.asked[0]!.url, "/backend-api/wham/usage");
    assert.equal(p.asked[0]!.headers.authorization, "Bearer at");
    assert.equal(p.asked[0]!.headers["chatgpt-account-id"], "acc");
    assert.equal(p.asked[1]!.url, "/backend-api/wham/rate-limit-reset-credits");
    // No extra request when the app-server already provided every date.
    const complete = dates.map((expiresAt) => ({ status: "available", expiresAt }));
    await ask(complete, 2);
    assert.equal(p.asked.length, 2);
    // An incomplete detail reply cannot erase dates already known from the app-server.
    usageCount = 3;
    detail = { available_count: 3, credits: complete.slice(0, 1) };
    assert.deepEqual((await ask(complete, 3)).resetExpiries, dates.map(Date.parse));
    // If the count changed during the requests, only the newer detail response's cards are shown.
    usageCount = 2;
    detail = { available_count: 0, credits: [] };
    const changed = await ask(complete.slice(0, 1), 2);
    assert.equal(changed.resetCount, 0);
    assert.equal(changed.resetExpiries, undefined);
    status = 503;
    const unavailable = await ask([], 2);
    assert.deepEqual([unavailable.state, unavailable.resetCount, unavailable.resetExpiries], ["ok", 2, undefined]);
    await p.close();
  });

  test("codex app-server limits and window names", () => {
    const limits = { rateLimits: { primary: { usedPercent: 12.4, windowDurationMins: 300, resetsAt: 1_900_000_000 }, secondary: null } };
    assert.deepEqual(codexWindows(limits), [{ label: "5 小时", usedPercent: 12, resetsAt: 1_900_000_000_000, minutes: 300 }]);
    assert.equal(codexQuota({ rateLimits: { ...limits.rateLimits, planType: "ultra" } }).plan, "ultra");
    assert.equal(codexQuota(limits).plan, undefined);
    assert.equal(windowLabel(10080, "x"), "每周");
    assert.equal(windowLabel(43200, "x"), "每月");
    assert.equal(windowLabel(2880, "x"), "2 天");
    assert.equal(windowLabel(null, "每周"), "每周");
    assert.equal(at("2026-09-27T00:00:02.500Z"), Date.parse("2026-09-27T00:00:02.500Z"));
  });

  // ── renewing ──

  const credentials = (expires: number) => ({
    otherCredential: { keep: true },
    claudeAiOauth: { accessToken: "old", refreshToken: "refresh-old", expiresAt: expires, scopes: ["user:profile", "user:inference"], subscriptionType: "max", clientId: "test-client" },
  });

  /// The token endpoint (POST) answers `status` with new tokens; usage (GET) answers the new token 42%, others 401.
  const oauthProvider = (status: number) =>
    provider((asked) => {
      if (asked.method === "POST") {
        return { status, delayMs: 50, body: { access_token: "new", refresh_token: "refresh-new", expires_in: 28800, refresh_token_expires_in: 86400, scope: "user:profile user:inference" } };
      }
      if (asked.headers.authorization === "Bearer new") return { status: 200, body: { five_hour: { utilization: 42 } } };
      return { status: 401, body: { error: { message: "expired" } } };
    });

  test("an abandoned lock is taken over, and its old owner cannot remove the one that replaced it", async () => {
    const dir = temp("lock");
    const path = join(dir, ".oauth_refresh.lock");
    mkdirSync(path);
    const old = (Date.now() - 61_000) / 1000;
    utimesSync(path, old, old);
    const owner = await RefreshLock.acquire(path);
    rmdirSync(path);
    mkdirSync(path);
    await owner.release();
    assert.ok(existsSync(path));
  });

  test("parallel quota reads renew once without a claude process and keep what else the login holds", async () => {
    const home = temp("renew");
    const path = join(home, ".credentials.json");
    writeFileSync(path, JSON.stringify(credentials(1)));
    const p = await oauthProvider(200);
    const urls = { ...URLS, anthropic: p.base, claudeToken: p.base };
    const [a, b] = await Promise.all([claudeWithRefresh({}, home, urls), claudeWithRefresh({}, home, urls)]);
    for (const q of [a, b]) assert.equal(q.windows[0]!.usedPercent, 42);
    const posts = p.asked.filter((r) => r.method === "POST");
    assert.equal(posts.length, 1);
    assert.equal(posts[0]!.body.refresh_token, "refresh-old");
    assert.equal(posts[0]!.body.client_id, "test-client");
    assert.equal(posts[0]!.body.scope, "user:profile user:inference");
    const stored = JSON.parse(readFileSync(path, "utf8"));
    assert.equal(stored.claudeAiOauth.refreshToken, "refresh-new");
    assert.equal(stored.claudeAiOauth.subscriptionType, "max");
    assert.equal(stored.otherCredential.keep, true);
    if (process.platform !== "win32") assert.equal(statSync(path).mode & 0o777, 0o600);
    assert.ok(!existsSync(join(home, ".oauth_refresh.lock")));
    await p.close();
  });

  test("an early 401 renews and asks the allowance once more", async () => {
    const home = temp("early");
    writeFileSync(join(home, ".credentials.json"), JSON.stringify(credentials(Date.now() + 3_600_000)));
    const p = await oauthProvider(200);
    const got = await claudeWithRefresh({}, home, { ...URLS, anthropic: p.base, claudeToken: p.base });
    assert.equal(got.state, "ok");
    assert.deepEqual(p.asked.map((r) => r.method), ["GET", "POST", "GET"]);
    await p.close();
  });

  test("a failed renewal keeps the login as it was, and the next try renews", async () => {
    const home = temp("failed");
    const path = join(home, ".credentials.json");
    const original = JSON.stringify(credentials(1));
    writeFileSync(path, original);
    let p = await oauthProvider(503);
    const error = await claudeOAuthToken({}, home, null, p.base).then(
      () => "renewed",
      (e) => (e as Error).message,
    );
    assert.ok(error.includes("503") && !error.includes("refresh-old"), error);
    assert.equal(readFileSync(path, "utf8"), original);
    await p.close();
    p = await oauthProvider(200);
    assert.equal((await claudeOAuthToken({}, home, null, p.base))[0], "new");
    await p.close();
  });

  test("a login that can no longer be renewed is over: its allowance says so, for its profile to be checked again", async () => {
    const home = temp("over");
    const path = join(home, ".credentials.json");
    const profile = { ...hubConfig({ profiles: [{ id: "cc", home: "homes/cc", runtime: "claude", access: { kind: "subscription" } }] }, "/x").profiles[0]!, home };
    let p = await oauthProvider(400);
    const urls = { ...URLS, anthropic: p.base, claudeToken: p.base };
    // Run out with nothing to renew it with, or its refresh token refused.
    writeFileSync(path, JSON.stringify({ claudeAiOauth: { accessToken: "old", expiresAt: 1 } }));
    const none = await checkQuota(profile, {}, undefined, urls, "zh");
    assert.deepEqual([none.state, none.detail, none.signedOut], ["unavailable", "Claude 登录已过期且无法续期，请重新登录", true]);
    writeFileSync(path, JSON.stringify(credentials(1)));
    const refused = await checkQuota(profile, {}, undefined, urls, "zh");
    assert.deepEqual([refused.state, refused.signedOut], ["unavailable", true]);
    await p.close();
    // Not renewed for now: nothing is said of the login, but recheck is flagged so checkProfile can mark it failed.
    p = await oauthProvider(503);
    const later = await checkQuota(profile, {}, undefined, { ...urls, anthropic: p.base, claudeToken: p.base }, "zh");
    assert.deepEqual([later.state, later.signedOut, later.recheck], ["unavailable", undefined, true]);
    await p.close();
  });

  test("claudeWithRefresh marks signedOut when usage still returns 401 after renewal", async () => {
    const home = temp("still-401");
    writeFileSync(join(home, ".credentials.json"), JSON.stringify(credentials(Date.now() + 3_600_000)));
    const p = await provider((asked) =>
      asked.method === "POST"
        ? { status: 200, body: { access_token: "still-bad", refresh_token: "refresh-new", expires_in: 3600 } }
        : { status: 401, body: { error: "unauthorized" } },
    );
    const got = await claudeWithRefresh({}, home, { ...URLS, anthropic: p.base, claudeToken: p.base }, "zh");
    assert.deepEqual([got.state, got.signedOut], ["unavailable", true]);
    assert.deepEqual(p.asked.map((r) => r.method), ["GET", "POST", "GET"]);
    await p.close();
  });

  test("a token handed out is renewed while it still lasts the usual margin, and given as it is when that fails", async () => {
    const home = temp("handed");
    const path = join(home, ".credentials.json");
    writeFileSync(path, JSON.stringify(credentials(Date.now() + 1_800_000)));
    let p = await oauthProvider(503);
    const [kept] = await claudeOAuthToken({}, home, null, p.base, "en", 3_600_000);
    assert.notEqual(kept, "new", "renewing failed: the token lasting half an hour is given");
    assert.ok(p.asked.some((r) => r.method === "POST"), "it was renewed first");
    await p.close();
    p = await oauthProvider(200);
    assert.equal((await claudeOAuthToken({}, home, null, p.base, "en", 3_600_000))[0], "new");
    await p.close();
  });

  test("the CLI's legacy lock is waited for, and the token it saved is read again", async () => {
    const home = temp("legacy");
    const path = join(home, ".credentials.json");
    writeFileSync(path, JSON.stringify(credentials(1)));
    const lock = `${realpathSync(home)}.lock`;
    mkdirSync(lock);
    const renewed = claudeOAuthToken({}, home, null, "http://127.0.0.1:1");
    // Its own lock taken, it is waiting on the legacy one (taken in the same run of microtasks): the CLI saves and leaves.
    await until(() => existsSync(join(home, ".oauth_refresh.lock")), "its own lock taken");
    const data = credentials(Date.now() + 3_600_000);
    data.claudeAiOauth.accessToken = "cli-won";
    writeFileSync(path, JSON.stringify(data));
    rmdirSync(lock);
    const [token] = await renewed;
    assert.equal(token, "cli-won");
  });

  test("a keychain read failure never replays a stale file's refresh token", { skip: process.platform !== "darwin" }, async () => {
    const m = machine({ security: "exit 36" }); // errSecInteractionNotAllowed, not errSecItemNotFound (44)
    mkdirSync(join(m.home, ".claude"));
    const file = join(m.home, ".claude", ".credentials.json");
    const stale = JSON.stringify(credentials(1));
    writeFileSync(file, stale);
    const p = await oauthProvider(200);
    try {
      await assert.rejects(claudeOAuthToken(m.env, null, null, p.base, "en"), /keychain/i);
      assert.equal(p.asked.length, 0, "no stale refresh token leaves the machine");
      assert.equal(readFileSync(file, "utf8"), stale);
    } finally {
      await p.close();
    }
  });

  test("a keychain failure on the locked reread cannot switch to the file", { skip: process.platform !== "darwin" }, async () => {
    const m = machine({ security: `if [ -f "$HOME/read-once" ]; then exit 36; fi
: > "$HOME/read-once"
/bin/cat "$HOME/keychain"` });
    mkdirSync(join(m.home, ".claude"));
    const original = JSON.stringify(credentials(1));
    writeFileSync(join(m.home, "keychain"), original);
    const file = join(m.home, ".claude", ".credentials.json");
    writeFileSync(file, original);
    const p = await oauthProvider(200);
    try {
      await assert.rejects(claudeOAuthToken(m.env, null, null, p.base, "en"), /keychain/i);
      assert.equal(p.asked.length, 0);
      assert.equal(readFileSync(file, "utf8"), original);
      assert.equal(readFileSync(join(m.home, "keychain"), "utf8"), original);
      assert.equal(existsSync(join(m.home, ".claude", ".oauth_refresh.lock")), false);
      assert.equal(existsSync(`${realpathSync(join(m.home, ".claude"))}.lock`), false);
    } finally {
      await p.close();
    }
  });

  test("machine credential discovery does not fall back on keychain errors or malformed entries", { skip: process.platform !== "darwin" }, async () => {
    for (const security of ["exit 36", "printf 'not-json'", "printf '{}'", "kill -TERM $$", "missing-executable"]) {
      const m = machine({ security });
      if (security === "missing-executable") m.env.PATH = join(m.home, "missing-bin");
      mkdirSync(join(m.home, ".claude"));
      writeFileSync(join(m.home, ".claude", ".credentials.json"), JSON.stringify(credentials(Date.now() + 3_600_000)));
      assert.equal(await readClaudeCredentials(m.env), undefined, security);
    }
  });

  test("a missing keychain item still permits a file-only machine login", { skip: process.platform !== "darwin" }, async () => {
    const m = machine(); // security exits 44: item not found
    mkdirSync(join(m.home, ".claude"));
    const data = credentials(Date.now() + 3_600_000);
    writeFileSync(join(m.home, ".claude", ".credentials.json"), JSON.stringify(data));
    assert.equal((await readClaudeCredentials(m.env))?.token, "old");
    assert.equal((await claudeOAuthToken(m.env, null, null, "http://127.0.0.1:1"))[0], "old");
  });

  test("the machine's login renews in the keychain and never uses the stale file", { skip: process.platform !== "darwin" }, async () => {
    const home = temp("keychain");
    mkdirSync(join(home, ".claude"));
    const file = join(home, ".claude", ".credentials.json");
    writeFileSync(file, "stale file must not be read or replaced");
    const keychain = join(home, "keychain");
    writeFileSync(keychain, JSON.stringify(credentials(1)));
    // A stand-in `security` keeping its item in a file of the test's own (never the real keychain). Its PATH is only the
    // home: what it runs is named whole.
    script(
      join(home, "security"),
      `#!/bin/sh
p="$HOME/keychain"
if [ "$1" = "-i" ]; then
  command=$(/bin/cat)
  hex=\${command#* -X \\"}
  hex=\${hex%%\\"*}
  printf '%s' "$hex" | /usr/bin/xxd -r -p > "$p"
else
  /bin/cat "$p"
  echo
fi
`,
    );
    const p = await oauthProvider(200);
    const [token] = await claudeOAuthToken({ HOME: home, PATH: home }, null, null, p.base);
    assert.equal(token, "new");
    // What it was handed to keep is the whole login, as JSON.
    assert.equal(JSON.parse(readFileSync(keychain, "utf8")).claudeAiOauth.refreshToken, "refresh-new");
    assert.equal(readFileSync(file, "utf8"), "stale file must not be read or replaced");
    await p.close();
  });

  test("claudeOAuthToken, claudeWithRefresh, and machineUsage send claude-cli User-Agent only when claudeVersion is given", async () => {
    const ua = "claude-cli/2.1.100 (external, cli)";
    const home = temp("claude-ua");
    writeFileSync(join(home, ".credentials.json"), JSON.stringify(credentials(1)));
    const p = await oauthProvider(200);
    const urls = { ...URLS, anthropic: p.base, claudeToken: p.base };
    try {
      // 1. claudeOAuthToken with version sends claude-cli UA on POST refresh.
      const [tok] = await claudeOAuthToken({}, home, null, p.base, "zh", undefined, undefined, "2.1.100");
      assert.equal(tok, "new");
      assert.equal(p.asked.at(-1)!.method, "POST");
      assert.equal(p.asked.at(-1)!.headers["user-agent"], ua);

      // 2. claudeOAuthToken without version does not fabricate claude-cli UA.
      writeFileSync(join(home, ".credentials.json"), JSON.stringify(credentials(1)));
      await claudeOAuthToken({}, home, null, p.base, "zh");
      assert.equal(p.asked.at(-1)!.method, "POST");
      assert.ok(!String(p.asked.at(-1)!.headers["user-agent"] ?? "").startsWith("claude-cli/"));

      // 3. claudeWithRefresh forwards version to both refresh POST and usage GET.
      p.asked.length = 0;
      writeFileSync(join(home, ".credentials.json"), JSON.stringify(credentials(Date.now() + 3_600_000)));
      const refreshed = await claudeWithRefresh({}, home, urls, "zh", "2.1.100");
      assert.equal(refreshed.state, "ok");
      assert.deepEqual(p.asked.map((r) => [r.method, r.headers["user-agent"]]), [
        ["GET", ua],
        ["POST", ua],
        ["GET", ua],
      ]);

      // 4. machineUsage forwards claudeVersion to refresh POST and usage GET while keeping scoped stripped.
      const m = machine();
      mkdirSync(join(m.home, ".claude"));
      writeFileSync(join(m.home, ".claude", ".credentials.json"), JSON.stringify(credentials(1)));
      p.asked.length = 0;
      const offered = await machineUsage("claude", m.env, urls, "zh", "2.1.100");
      assert.equal(offered!.state, "ok");
      assert.equal("scoped" in offered!, false);
      assert.deepEqual(p.asked.map((r) => [r.method, r.headers["user-agent"]]), [
        ["POST", ua],
        ["GET", ua],
      ]);
    } finally {
      await p.close();
    }
  });
});
