// GitHub Copilot driver: one ACP session per session, served by src/agents/copilot-bridge.mjs, which hosts the
// official Copilot SDK. The station speaks ACP to the bridge (acp.ts), so sessions, tools, permissions, live steps and
// the kept transcript are the same as any ACP runtime; the bridge owns the SDK runtime and its GitHub identity.
//
// The SDK's own surfaces this uses:
// - `mode: "empty"` with an explicit tool allowlist (`mcp:*`, `custom:*`), so a station session gets no ambient CLI
//   tools and only the MCP server the station passes in session/new;
// - a per-session `github.tokenProvider`; the profile's token when it has one, else the bridge falls back to `gh auth`
//   for development (the driver never lets the station's own environment decide a profile's identity);
// - `events.streaming`, so the bridge can send agent_message_chunk updates as the model writes;
// - `systemMessage` append for the station's instructions, and `mcp.servers` for its tools.
//
// The bridge is a separate file because the SDK's runtime is a child process of its own and its package is not bundled
// into main.js; the station's build copies copilot-bridge.mjs beside main.js. See docs/copilot.md.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { peerHttpBase } from "../tools/http.ts";
import { AcpDriver, AcpSession, KeptTranscript, type AcpStart } from "./acp.ts";
import type { Events } from "./own-process.ts";
import { expandRoute, profileEnv, profileModel } from "./profiles.ts";
import { cleanEnv, failureOf, uuid, type FailureReason, type OpenOptions } from "./runtime.ts";

const run = promisify(execFile);

type Json = any;

/// Where Copilot keeps a profile (COPILOT_HOME): its session state, its login (headless: settings.json's
/// storeTokenPlaintext), its instructions file.
export const copilotHome = (home: string) => join(home, "copilot");

/// Inherited variables that would let a session use another account, another Copilot home or another provider than its
/// profile's.
const SCRUBBED = [
  "COPILOT_HOME",
  "COPILOT_GITHUB_TOKEN",
  "GH_TOKEN",
  "GITHUB_TOKEN",
  "COPILOT_PROVIDERS_CONFIG",
  "COPILOT_PROVIDER_BASE_URL",
  "COPILOT_PROVIDER_API_KEY",
  "COPILOT_PROVIDER_TYPE",
];

/// The station's instructions as Copilot is given them, with how its MCP tools are named there: the SDK prefixes a
/// server's tools with the server's name (`stillfail-chat_post`), not the `mcp__stillfail__…` another runtime uses.
export const copilotRules = (instructions: string) =>
  `${instructions}${instructions === "" ? "" : "\n\n"}The station's tools (chat_post, chat_state and the others named in these instructions) are MCP tools named stillfail-<tool>: stillfail-chat_post and so on. Call one by that name without listing the server's tools first.`;

/// The profile's GitHub token, when it has one (a fine-grained PAT or an OAuth token: gho_, ghu_, github_pat_).
/// None leaves the bridge to `gh auth` (development); a station that wants no ambient identity sets one.
export function copilotToken(profile: OpenOptions["profile"]): string | undefined {
  const access = profile.access as { key?: unknown } | undefined;
  const key = typeof access?.key === "string" ? access.key.trim() : "";
  if (key !== "" && key !== "none" && /^(gho_|ghu_|github_pat_)/.test(key)) return key;
  const env = (profile.env as Record<string, unknown> | undefined)?.COPILOT_GITHUB_TOKEN;
  if (typeof env === "string" && env.trim() !== "") return env.trim();
  // The token a sign-in kept (accounts/copilot.ts): a gho_/ghu_ token from GitHub's device grant.
  try {
    const kept = readFileSync(join(copilotHome(profile.home), "github-token"), "utf8").trim();
    if (kept !== "") return kept;
  } catch {}
  return undefined;
}

/// The bridge, beside this file in src/ and in dist/ (the station's build copies it).
const BRIDGE = fileURLToPath(new URL("./copilot-bridge.mjs", import.meta.url));

export class CopilotDriver extends AcpDriver<CopilotSession> {
  constructor(options: { data: string }) {
    super(options.data);
  }

  runtime(): "copilot" {
    return "copilot";
  }

  /// Every model this GitHub account may use, as the SDK lists them (`copilot-bridge.mjs --models`): the profile's
  /// check offers these, and a chat may pick any of them.
  async models(profile: OpenOptions["profile"]): Promise<string[]> {
    const home = copilotHome(profile.home);
    mkdirSync(home, { recursive: true });
    const env: Record<string, string> = { ...cleanEnv(SCRUBBED), COPILOT_HOME: home };
    const token = copilotToken(profile);
    if (token !== undefined) env.COPILOT_GITHUB_TOKEN = token;
    const { stdout } = await run(process.execPath, [BRIDGE, "--models"], { env, maxBuffer: 4 * 1024 * 1024 });
    const line = stdout.split("\n").map((l) => l.trim()).find((l) => l.startsWith("["));
    if (line === undefined) return [];
    const models = JSON.parse(line) as unknown;
    return Array.isArray(models) ? models.filter((m): m is string => typeof m === "string" && m !== "") : [];
  }

  protected session(options: OpenOptions, events: Events): CopilotSession {
    return new CopilotSession(this, events, options);
  }

  protected starting(options: OpenOptions, _probe: boolean): AcpStart {
    const home = copilotHome(options.profile.home);
    mkdirSync(home, { recursive: true });
    mkdirSync(join(home, "sessions"), { recursive: true });
    const instructions = join(home, "stillfail-instructions.md");
    writeFileSync(instructions, copilotRules(options.instructions), { mode: 0o600 });

    const env: Record<string, string> = { ...cleanEnv(SCRUBBED), ...expandRoute(profileEnv(options.profile, "copilot"), options.route) };
    env.COPILOT_HOME = home;
    env.COPILOT_INSTRUCTIONS = instructions;
    env.STILLFAIL_PEER_HTTP = peerHttpBase(options.mcpUrl);
    const token = copilotToken(options.profile);
    if (token !== undefined) env.COPILOT_GITHUB_TOKEN = token;

    return { command: process.execPath, args: [BRIDGE], env };
  }

  /// The model the profile names is set once the bridge's session is open; its own default is "auto".
  protected async ready(session: CopilotSession): Promise<void> {
    const model = session.model;
    if (model === null || model === "" || model === "auto") return;
    await session.request(`config:${uuid()}`, "session/set_config_option", { sessionId: session.id(), configId: "model", value: model }).catch(() => undefined);
  }
}

export class CopilotSession extends AcpSession {
  /// The models its `model` config option lists, for a change between turns.
  private models: string[] = [];

  constructor(driver: CopilotDriver, events: Events, options: OpenOptions) {
    super(driver, events, new KeptTranscript("copilot", join(copilotHome(options.profile.home), "sessions")));
    this.model = options.model ?? profileModel(options.profile) ?? null;
  }

  protected classify(text: string): FailureReason {
    return failureOf(text);
  }

  opened(result: Json) {
    super.opened(result);
    const model = (Array.isArray(result?.configOptions) ? result.configOptions : []).find((o: Json) => o?.id === "model");
    if (model === undefined) return;
    if (Array.isArray(model.options)) this.models = model.options.map((o: Json) => o?.value).filter((v: unknown): v is string => typeof v === "string");
    if (typeof model.currentValue === "string" && model.currentValue !== "" && this.model === null) this.model = model.currentValue;
  }

  protected kept() {
    return { models: this.models };
  }

  protected taken(snapshot: Json) {
    this.models = Array.isArray(snapshot.models) ? snapshot.models : [];
  }

  /// Another model between turns: the bridge sets it on the SDK session, read from its next turn on.
  retune(options: OpenOptions): boolean {
    if (this.turn.closed || this.turn.busy || this.sessionId === "") return false;
    const model = options.model ?? profileModel(options.profile);
    if (model === undefined) return false;
    if (this.models.length > 0 && !this.models.includes(model)) return false;
    this.send("session/set_config_option", { sessionId: this.sessionId, configId: "model", value: model });
    this.model = model;
    return true;
  }
}
