# GitHub Copilot

The station's `copilot` runtime runs each session as one ACP session (`station/src/agents/acp.ts`) served by
`station/src/agents/copilot-bridge.mjs`, which hosts the official **GitHub Copilot SDK** (`@microsoft/copilot-sdk`). The
bridge is a separate process because the SDK's runtime is a process of its own and its package is not bundled into
`main.js`; the station's build copies `copilot-bridge.mjs` beside the bundle.

## What the bridge does

- Starts `CopilotClient` in `mode: "empty"`, with `RuntimeConnection.forSpawnedStdio({ baseDirectory: COPILOT_HOME })`.
- `session/new` / `session/load`: creates or resumes a Copilot session with the station's MCP server from ACP
  (`{type:"http", url, headers:[{name,value}]}` becomes `mcp.servers` with a header object) and the profile's
  instructions file (`systemMessage: { mode: "append" }`).
- `session/prompt`: `session.sendAndWait(...)`; the SDK's `events.streaming` deltas become `agent_message_chunk`,
  `tool.execution_start/complete` become `tool_call` / `tool_call_update`; `stopReason: "end_turn"` ends the ACP turn.
- `session/set_config_option` `model`: `session.setModel(value)`.
- `session/cancel`: `session.abort()`.

## Auth

The profile's `access.key` (a `gho_`, `ghu_` or `github_pat_` token) is passed as `COPILOT_GITHUB_TOKEN` for both the
client and the per-session token provider. With none, the bridge falls back to `gh auth token` for development. Copilot
accepts fine-grained PATs with the "Copilot Requests" permission; classic `ghp_` tokens are refused.

For a headless station that should not depend on `gh`, put the token in the profile (`access.key`) or configure a
`copilot login` in `COPILOT_HOME` with `settings.json`'s `storeTokenPlaintext: true`.

## Models

The bridge lists models with `client.listModels()` and exposes them as the ACP `model` config option. The profile's
model is applied once the session is open; `auto` keeps Copilot's own routing.

## Tools

MCP tools are named `<server>-<tool>` by the SDK, so the station's `chat_post` is `stillfail-chat_post`, not
`mcp__stillfail__chat_post`. `copilotRules()` appends that to the station's instructions.

## Packaging and limits

- `@microsoft/copilot-sdk` is a station dependency; it brings the platform runtime package
  (`@microsoft/copilot-sdk-<os>-<arch>`). A packaged station must ship that runtime or install it beside the bundle. The
  current station build copies only the bridge; running from a checkout works because Node resolves the SDK from
  `station/node_modules`.
- ACP support in the Copilot SDK is evolving. Pin the SDK version and probe `initialize` capabilities rather than
  assuming.
- The Copilot runtime is closed source; the SDK is MIT. Do not vendor or patch the runtime binary.

## Trying it

```sh
pnpm install
pnpm --filter @stillfail/station build
# run a disposable station from source (see docs/development.md)
```

Add a profile with `runtime: "copilot"` and a Copilot token, then open a chat on it. The session's runtime is
`copilot`; its transcript is kept under `<profile home>/copilot/sessions`.
