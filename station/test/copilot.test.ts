// The Copilot driver's own rules: how the station's tools are named to Copilot, and which profile token it uses.
import assert from "node:assert/strict";
import { test } from "node:test";
import { copilotHome, copilotRules, copilotToken } from "../src/agents/copilot.ts";
import type { Profile } from "../src/agents/runtime.ts";

const profile = (access: Record<string, unknown> = {}, env: Record<string, unknown> = {}): Profile =>
  ({ id: "copilot", runtime: "copilot", home: "/tmp/copilot", access, env }) as Profile;

test("copilotRules names MCP tools as the Copilot SDK does, not mcp__stillfail__", () => {
  const rules = copilotRules("Be brief.");
  assert.match(rules, /^Be brief\./);
  assert.match(rules, /stillfail-chat_post/);
  assert.doesNotMatch(rules, /mcp__stillfail__/);
});

test("copilotToken reads a supported token from the profile, then its env", () => {
  assert.equal(copilotToken(profile({ key: "gho_abc" })), "gho_abc");
  assert.equal(copilotToken(profile({ key: "github_pat_abc" })), "github_pat_abc");
  assert.equal(copilotToken(profile({}, { COPILOT_GITHUB_TOKEN: "ghu_abc" })), "ghu_abc");
  assert.equal(copilotToken(profile({ key: "sk-not-a-github-token" })), undefined);
  assert.equal(copilotToken(profile({ key: "ghp_classic" })), undefined);
});

test("copilotHome is the profile's copilot directory", () => {
  assert.equal(copilotHome("/home/p"), "/home/p/copilot");
});
