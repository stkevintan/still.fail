// GitHub's OAuth device grant for a Copilot profile (the Copilot CLI's OAuth app): a code the person
// enters at github.com/login/device, then the token the profile keeps. The Copilot SDK takes that token
// as its `github` token; a fine-grained PAT works the same way.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import type { Device, DeviceAnswer } from "./console.ts";
import { copilotHome } from "../agents/copilot.ts";

/// The GitHub OAuth app the Copilot CLI signs in with.
const CLIENT_ID = "Iv1.b507a08c87ecfe98";
const DEVICE_CODE = "https://github.com/login/device/code";
const ACCESS_TOKEN = "https://github.com/login/oauth/access_token";

const post = async (url: string, body: Record<string, string>): Promise<Record<string, unknown>> => {
  const answer = await fetch(url, {
    method: "POST",
    headers: { accept: "application/json", "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(body),
  });
  const said = (await answer.json().catch(() => ({}))) as Record<string, unknown>;
  if (!answer.ok) throw new Error(typeof said.error_description === "string" ? said.error_description : `GitHub answered ${answer.status}`);
  return said;
};

/// A code to enter at github.com/login/device, and how often to ask whether it was entered.
export async function startCopilotDevice(): Promise<Device> {
  const said = await post(DEVICE_CODE, { client_id: CLIENT_ID, scope: "read:user" });
  const deviceCode = String(said.device_code ?? "");
  const userCode = String(said.user_code ?? "");
  const url = String(said.verification_uri ?? "https://github.com/login/device");
  const expires = Number(said.expires_in);
  const interval = Number(said.interval);
  if (deviceCode === "" || userCode === "") throw new Error("GitHub did not give a device code");
  return { deviceCode, userCode, url, expiresInMs: (Number.isFinite(expires) ? expires : 900) * 1000, intervalMs: (Number.isFinite(interval) ? interval : 5) * 1000 };
}

/// Whether the code was entered: the token, still waiting, or GitHub's refusal.
export async function copilotDeviceToken(deviceCode: string): Promise<DeviceAnswer> {
  const said = await post(ACCESS_TOKEN, {
    client_id: CLIENT_ID,
    device_code: deviceCode,
    grant_type: "urn:ietf:params:oauth:grant-type:device_code",
  });
  const access = typeof said.access_token === "string" ? said.access_token : "";
  if (access !== "") return { token: { access, refresh: "", expiresInMs: 365 * 24 * 60 * 60 * 1000, org: null } };
  const error = typeof said.error === "string" ? said.error : "unknown_error";
  if (error === "authorization_pending") return { pending: true, slowDown: false };
  if (error === "slow_down") return { pending: true, slowDown: true };
  return { error };
}

/// Where a Copilot profile keeps its GitHub token (beside its SDK home, in its own home).
export const copilotTokenFile = (home: string) => join(copilotHome(home), "github-token");

/// Writes the token the sign-in gave, readable by its owner alone.
export function writeCopilotToken(home: string, token: string): void {
  const file = copilotTokenFile(home);
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, `${token}\n`, { mode: 0o600 });
}

/// The token a sign-in kept, when it did.
export function readCopilotToken(home: string): string | null {
  try {
    const token = readFileSync(copilotTokenFile(home), "utf8").trim();
    return token === "" ? null : token;
  } catch {
    return null;
  }
}
