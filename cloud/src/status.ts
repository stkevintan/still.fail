// What still.fail/status shows (status/status.html, GET /v1/status): each of still.fail's services, checked by the cron
// every minute, and how each has done on each of the last days. What is checked is only what still.fail runs itself: a
// station's own state is seen from the devices that reach it, and a client that fails on what a service
// answers is not seen here: those are incidents people open, as GitHub issues labelled `incident` (P1 or P2 beside it),
// and end by closing them, with no deploy and nothing else to sign in to. Only the repository's own can label an issue,
// and a workflow sends them here when one changes (receiveIncidents).
import { DurableObject } from "cloudflare:workers";
import { AwsClient } from "aws4fetch";
import { createRemoteJWKSet, jwtVerify, type JWTPayload } from "jose";
import { bearerToken, denied, nowSeconds, readJson, reply } from "./auth";
import type { Env } from "./env";
import { relayName, relayUrls, type Relays } from "./relays";

/** How many days the page shows. */
export const DAYS = 30;
/** A relay is up while its counters came this recently (seconds): they come about a minute apart (relay-load.ts). It is
 * not fetched from here: a Worker cannot fetch an IP address, and the relay's Worker is on this Worker's own zone. */
const RELAY_SAMPLED = 300;
/** Nothing checked for this long (seconds): the cron has stopped, and what was last found says nothing of now. */
const STALE = 300;
/** A service is down from this many failed checks in a row: a single one is as often the check's own line. */
const DOWN_AFTER = 2;
/** How long a page is given to answer a check. */
const CHECK_MS = 10_000;

/** `degraded`: running, but refusing some: still.fail's own relay at its budget's limit (relay.ts admit). */
type Found = "up" | "degraded" | "down";
export type Check = { id: string; found: Found };
export type ServiceView = {
  id: string;
  state: Found | "unknown";
  /** What it is called, and where a browser can time it (its /ping), for a relay. */
  name?: string;
  relay?: string;
  /** The share of its checks that passed on each day, oldest first, the last today; null: not checked that day. */
  days: (number | null)[];
};

/** An incident as the page shows it. `end` null: still open. */
export type Incident = { number: number; url: string; level: string; title: string; body: string; start: string; end: string | null };

/** A line of an issue's body saying when it began, when that was before the issue was opened. */
const STARTED = /^started:[ \t]*(\S+)[ \t]*$/im;

/** Incidents from what GitHub lists of a repository's issues: pull requests are listed as issues too. */
export function incidentsOf(issues: unknown): Incident[] {
  if (!Array.isArray(issues)) return [];
  return issues.flatMap((issue: Record<string, unknown>): Incident[] => {
    if (issue.pull_request || typeof issue.title !== "string" || typeof issue.html_url !== "string" || typeof issue.number !== "number" || typeof issue.created_at !== "string") return [];
    const labels = Array.isArray(issue.labels) ? issue.labels.map((l: { name?: unknown }) => l.name) : [];
    const text = typeof issue.body === "string" ? issue.body : "";
    const started = STARTED.exec(text)?.[1];
    return [{
      number: issue.number,
      url: issue.html_url,
      level: labels.includes("P1") ? "P1" : "P2",
      title: issue.title,
      body: text.replace(STARTED, "").trim(),
      start: started && !Number.isNaN(Date.parse(started)) ? started : issue.created_at,
      end: typeof issue.closed_at === "string" ? issue.closed_at : null,
    }];
  });
}

const dayOf = (seconds: number) => Math.floor(seconds / 86_400);

/** What was last found of each service and its days, in one object ("primary"). */
export class ServiceStatus extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.storage.sql.exec("CREATE TABLE IF NOT EXISTS last (service TEXT PRIMARY KEY, at INTEGER NOT NULL, found TEXT NOT NULL, fails INTEGER NOT NULL)");
    ctx.storage.sql.exec("CREATE TABLE IF NOT EXISTS kept (key TEXT PRIMARY KEY, value TEXT NOT NULL)");
    ctx.storage.sql.exec("CREATE TABLE IF NOT EXISTS days (service TEXT NOT NULL, day INTEGER NOT NULL, ok INTEGER NOT NULL, total INTEGER NOT NULL, PRIMARY KEY (service, day))");
  }

  record(checks: Check[]): void {
    const now = nowSeconds();
    const today = dayOf(now);
    for (const { id, found } of checks) {
      const ok = found === "up" ? 1 : 0;
      this.ctx.storage.sql.exec("INSERT INTO last (service, at, found, fails) VALUES (?, ?, ?, ?) ON CONFLICT (service) DO UPDATE SET at = excluded.at, found = excluded.found, fails = CASE WHEN excluded.fails = 0 THEN 0 ELSE last.fails + 1 END", id, now, found, 1 - ok);
      this.ctx.storage.sql.exec("INSERT INTO days (service, day, ok, total) VALUES (?, ?, ?, 1) ON CONFLICT (service, day) DO UPDATE SET ok = ok + excluded.ok, total = total + 1", id, today, ok);
    }
    this.ctx.storage.sql.exec("DELETE FROM days WHERE day <= ?", today - DAYS);
  }

  /** The cloud's relays as the last round of checks found them listed (relay-registry.ts), each with its name: what the
   * page shows, so that reading it asks the Directory nothing. */
  keepRelays(relays: { url: string; name: string }[]): void {
    this.ctx.storage.sql.exec("INSERT OR REPLACE INTO kept (key, value) VALUES ('relays', ?)", JSON.stringify(relays));
  }

  relays(): { url: string; name: string }[] {
    const kept = this.ctx.storage.sql.exec<{ value: string }>("SELECT value FROM kept WHERE key = 'relays'").toArray()[0]?.value;
    return kept ? (JSON.parse(kept) as { url: string; name: string }[]) : [];
  }

  keepIncidents(incidents: Incident[]): void {
    this.ctx.storage.sql.exec("INSERT OR REPLACE INTO kept (key, value) VALUES ('incidents', ?)", JSON.stringify(incidents));
  }

  incidents(): Incident[] {
    const kept = this.ctx.storage.sql.exec<{ value: string }>("SELECT value FROM kept WHERE key = 'incidents'").toArray()[0]?.value;
    return kept ? (JSON.parse(kept) as Incident[]) : [];
  }

  view(ids: string[]): Omit<ServiceView, "name" | "relay">[] {
    const now = nowSeconds();
    const first = dayOf(now) - DAYS + 1;
    return ids.map((id) => {
      const last = this.ctx.storage.sql.exec<{ at: number; found: Found; fails: number }>("SELECT at, found, fails FROM last WHERE service = ?", id).toArray()[0];
      const days: (number | null)[] = Array.from({ length: DAYS }, () => null);
      for (const row of this.ctx.storage.sql.exec<{ day: number; ok: number; total: number }>("SELECT day, ok, total FROM days WHERE service = ? AND day >= ?", id, first)) days[row.day - first] = row.ok / row.total;
      const state = !last || now - last.at > STALE ? "unknown" : last.found === "down" && last.fails < DOWN_AFTER ? "up" : last.found;
      return { id, state, days };
    });
  }
}

/** The services, in the order the page shows them: the pages STATUS_PAGES names, the API, the releases, then the relays. */
function serviceIds(env: Env, relays: string[]): string[] {
  return [...Object.keys(env.STATUS_PAGES ?? {}), "api", ...(env.RELEASES && !env.RELEASES_UPSTREAM ? ["releases"] : []), ...relays.map((url) => `relay:${url}`)];
}

const passes = async (check: () => Promise<boolean>) => (await check().catch(() => false)) ? "up" : "down";

const GITHUB_ACTIONS = "https://token.actions.githubusercontent.com";
// (a cold isolate's first fetch of GitHub's keys has taken over jose's default 5 s, refusing a pipeline's upload)
const githubKeys = createRemoteJWKSet(new URL(`${GITHUB_ACTIONS}/.well-known/jwks`), { timeoutDuration: 10_000 });
/** What jose throws when the token itself is not good: anything else is GitHub's keys not being had now. */
const REFUSED = /^ERR_(JWT|JWS)_|^ERR_JWKS_(NO_MATCHING_KEY|MULTIPLE_MATCHING_KEYS)$|^ERR_JOSE_(ALG_NOT_ALLOWED|NOT_SUPPORTED)$/;
/** At most this much of what GitHub lists is read (20 issues, each up to its limit of some 64 KB). */
const MAX_ISSUES = 2 * 1024 * 1024;

/**
 * The claims of the OIDC token GitHub gave a workflow of STATUS_REPO_ID's repository, or null for any other's or none;
 * undefined where no repository is set. The repository is known by its id, which its renaming leaves as it was (the
 * name in `repository` and `workflow_ref` is then the new one). "unavailable" where GitHub's keys could not be had (a
 * timeout, an answer not 200): a 503 the workflow can try again, not a refusal. GitHub's clock may run ahead of the
 * edge's by a second or more, so `nbf` and `iat` are given 30 s.
 */
async function repositoryClaims(request: Request, env: Env): Promise<({ repository: string } & JWTPayload) | null | undefined | "unavailable"> {
  if (!env.STATUS_REPO_ID) return undefined;
  const token = bearerToken(request);
  let claims: JWTPayload | null = null;
  if (token) {
    try {
      claims = (await jwtVerify(token, githubKeys, { issuer: GITHUB_ACTIONS, audience: env.PUBLIC_ORIGIN, clockTolerance: 30 })).payload;
    } catch (error) {
      const code = (error as { code?: unknown } | null)?.code;
      if (typeof code !== "string" || !REFUSED.test(code)) return "unavailable";
    }
  }
  if (!claims || claims.repository_id !== env.STATUS_REPO_ID || typeof claims.repository !== "string") return null;
  return { ...claims, repository: claims.repository };
}

const NATIVE_CHUNK_MAX = 32 * 1024 * 1024;
const NATIVE_UPLOAD_TTL_SECONDS = 120;

/** A push of this repository's pipeline can stage a chunk for its other runners. The read receipt names only that chunk. */
export async function stageNative(request: Request, env: Env): Promise<Response> {
  const direct = request.method === "POST";
  const { RELEASES: releases, CI_NATIVE_R2_SIGNER: signer, CI_NATIVE_R2_ACCOUNT_ID: account } = env;
  if (!releases || (direct && (!signer || !account))) {
    return reply({ error: "not_found" }, 404);
  }
  const claims = await repositoryClaims(request, env);
  if (claims === undefined) return reply({ error: "not_found" }, 404);
  if (claims === "unavailable") return reply({ error: "jwks_unavailable" }, 503);
  if (!claims || typeof claims.ref !== "string" || !claims.ref.startsWith("refs/heads/") || claims.ref === "refs/heads/main" ||
    (claims.event_name !== "push" && claims.event_name !== "workflow_dispatch") ||
    claims.workflow_ref !== `${claims.repository}/.github/workflows/pipeline.yml@${claims.ref}` ||
    typeof claims.sha !== "string" || !/^[0-9a-f]{40}$/.test(claims.sha)) return denied();
  const length = direct
    ? (await readJson(request, 256).catch(() => null))?.length
    : Number(request.headers.get("content-length"));
  if (!request.body || typeof length !== "number" || !Number.isSafeInteger(length) || length <= 0 || length > NATIVE_CHUNK_MAX) {
    return reply({ error: "invalid_length" }, 400);
  }
  const receipt = `${nowSeconds()}-${claims.sha}/${crypto.randomUUID()}`;
  const key = `staged/ci-natives/${receipt}`;
  if (direct) {
    try {
      const { accessKeyId, secretAccessKey, sessionToken, expiresAt } = JSON.parse(signer!);
      if (!/^[a-f0-9]{32}$/.test(account!) || ![accessKeyId, secretAccessKey, sessionToken].every((value) =>
        typeof value === "string" && value.length > 0) || !Number.isSafeInteger(expiresAt)) {
        return reply({ error: "r2_signer_unavailable" }, 503);
      }
      if (expiresAt < nowSeconds() + NATIVE_UPLOAD_TTL_SECONDS) return reply({ error: "not_found" }, 404);
      const client = new AwsClient({ accessKeyId, secretAccessKey, sessionToken, service: "s3", region: "auto" });
      const target = new URL(`https://${account}.r2.cloudflarestorage.com/stillfail-releases/${key}`);
      target.searchParams.set("X-Amz-Expires", String(NATIVE_UPLOAD_TTL_SECONDS));
      const signed = await client.sign(target.href, {
        method: "PUT",
        headers: { "content-length": String(length), "if-none-match": "*" },
        aws: { signQuery: true, allHeaders: true },
      });
      return reply({ receipt, upload: signed.url }, 201);
    } catch {
      return reply({ error: "r2_signer_unavailable" }, 503);
    }
  }
  await releases.put(key, request.body);
  return reply({ receipt }, 201);
}

/**
 * POST /v1/status/incidents: the repository's issues labelled `incident`, as GitHub lists them, from its workflow
 * (.github/workflows/status-incidents.yml), believed by the OIDC token GitHub gives that workflow on the default branch.
 */
export async function receiveIncidents(request: Request, env: Env): Promise<Response> {
  const claims = await repositoryClaims(request, env);
  if (claims === undefined) return reply({ error: "not_found" }, 404);
  if (claims === "unavailable") return reply({ error: "jwks_unavailable" }, 503);
  if (!claims || claims.workflow_ref !== `${claims.repository}/.github/workflows/status-incidents.yml@refs/heads/main`) return denied();
  if (Number(request.headers.get("content-length") ?? 0) > MAX_ISSUES) return reply({ error: "too_large" }, 413);
  const issues: unknown = await request.json().catch(() => null);
  if (!Array.isArray(issues)) return reply({ error: "invalid_request" }, 400);
  await env.SERVICE_STATUS.getByName("primary").keepIncidents(incidentsOf(issues));
  return reply({ ok: true });
}

/** The workflows that put releases in the bucket (their feeds last): pipeline.yml's on main, stable.yml's. */
const RELEASING = ["pipeline.yml", "stable.yml"];

/**
 * POST /v1/releases/out: a release's feeds were just put in the bucket (by one of RELEASING, believed by the OIDC token
 * GitHub gives it on the default branch); every device and station connected is told, to read its feed again.
 */
export async function receiveReleased(request: Request, env: Env): Promise<Response> {
  const claims = await repositoryClaims(request, env);
  if (claims === undefined) return reply({ error: "not_found" }, 404);
  if (claims === "unavailable") return reply({ error: "jwks_unavailable" }, 503);
  if (!claims || !RELEASING.some((file) => claims.workflow_ref === `${claims.repository}/.github/workflows/${file}@refs/heads/main`)) return denied();
  await env.DIRECTORY.getByName("primary").tellAll({ type: "release" }, { type: "release" }, { ephemeral: true });
  return reply({ ok: true });
}

/** One round of checks (the cron's, a minute apart). `full`: which limits of its budget still.fail's own relay has reached (relay-load.ts). */
export async function checkServices(env: Env, full: string[]): Promise<void> {
  const loads = env.RELAY_LOAD.getByName("primary");
  const now = nowSeconds();
  const pages = Object.entries(env.STATUS_PAGES ?? {}).map(async ([id, url]): Promise<Check> => ({
    id,
    found: await passes(async () => (await fetch(url, { method: "HEAD", signal: AbortSignal.timeout(CHECK_MS) })).ok),
  }));
  // The API: this Worker runs, as the cron shows, and reaches the object every signed-in call goes through, which
  // answers which relays are listed (relay-registry.ts); none checked while it does not.
  const got: { relays?: Relays } = {};
  const api = passes(async () => ((got.relays = await env.DIRECTORY.getByName("primary").relaysNow()), true)).then((found): Check => ({ id: "api", found }));
  // What installing and updating read first.
  const releases = env.RELEASES && !env.RELEASES_UPSTREAM ? [passes(async () => (await env.RELEASES!.head("station.json")) !== null).then((found): Check => ({ id: "releases", found }))] : [];
  const asked = await api;
  const listed = got.relays ?? null;
  const status = env.SERVICE_STATUS.getByName("primary");
  const relays = listed === null ? [] : relayUrls(listed).map(async (url, i): Promise<Check> => {
    const at = await loads.lastSampled(url);
    // Its budget run out stops the process, and its counters come no more: refusing for the day, not down.
    const found = i === 0 && !env.RELAY_URL && full.length > 0 ? "degraded" : at === null || now - at > RELAY_SAMPLED ? "down" : "up";
    return { id: `relay:${url}`, found };
  });
  if (listed !== null) await status.keepRelays(relayUrls(listed).map((url) => ({ url, name: relayName(listed, url) })));
  await status.record(await Promise.all([...pages, asked, ...releases, ...relays]));
}

/** GET /v1/status. From any page, as the site's status page is on a host of its own; what it says is no secret. */
export async function serveStatus(env: Env): Promise<Response> {
  const status = env.SERVICE_STATUS.getByName("primary");
  const relays = await status.relays();
  const [views, incidents] = await Promise.all([status.view(serviceIds(env, relays.map((r) => r.url))), status.incidents()]);
  const services = views.map((view): ServiceView => {
    if (!view.id.startsWith("relay:")) return view;
    const relay = view.id.slice("relay:".length);
    return { ...view, id: "relay", relay, name: relays.find((r) => r.url === relay)?.name ?? new URL(relay).host };
  });
  return reply({ now: nowSeconds(), days: DAYS, services, incidents }, 200, { "access-control-allow-origin": "*", "cache-control": "public, max-age=30" });
}
