#!/usr/bin/env node
/**
 * ACP server backed by the GitHub Copilot SDK (copilot.ts).
 *
 * The station speaks ACP to this process (one per session); the process hosts the SDK's Copilot runtime and maps its
 * events to ACP session/update notifications. It exists as a separate file because the SDK's runtime is a child
 * process and its package is not bundled into main.js: the station's build copies this file beside main.js.
 */
import { execFileSync } from 'node:child_process'
import { createInterface } from 'node:readline'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { readFileSync } from 'node:fs'
import { CopilotClient, RuntimeConnection, approveAll } from '@microsoft/copilot-sdk'

const HOME = process.env.COPILOT_HOME ?? join(homedir(), '.copilot-stillfail-demo')
const token = process.env.COPILOT_GITHUB_TOKEN || (() => { try { return execFileSync('gh', ['auth', 'token'], { encoding: 'utf8' }).trim() } catch { return '' } })()
const instructionsFile = process.env.COPILOT_INSTRUCTIONS
const instructions = instructionsFile === undefined ? '' : readFileSync(instructionsFile, 'utf8')

if (process.argv.includes('--models')) {
  // The station's check asks for every model this account may use; no session, no tools.
  const client = new CopilotClient({
    mode: 'empty',
    runtime: RuntimeConnection.forSpawnedStdio({ baseDirectory: HOME }),
    github: { useLoggedInUser: false, token },
    clientInfo: { applicationName: 'stillfail-copilot', applicationVersion: '0.1.0' },
  })
  await client.start()
  const models = await client.listModels()
  process.stdout.write(`${JSON.stringify(models.map((m) => m.id))}\n`)
  await client.stop()
  process.exit(0)
}

let client = null
let session = null
let sessionId = ''
let streamed = 0
let currentModel = 'auto'

function send(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`)
}
const result = (id, value) => send({ jsonrpc: '2.0', id, result: value })
const failure = (id, message, code = -32000) => send({ jsonrpc: '2.0', id, error: { code, message } })
const notify = (method, params) => send({ jsonrpc: '2.0', method, params })

async function ensureRuntime() {
  if (client !== null) return
  client = new CopilotClient({
    mode: 'empty',
    runtime: RuntimeConnection.forSpawnedStdio({ baseDirectory: HOME }),
    github: { useLoggedInUser: false, token },
    clientInfo: { applicationName: 'stillfail-copilot', applicationVersion: '0.1.0' },
  })
  await client.start()
}

function toMcpServers(list) {
  const out = {}
  for (const server of Array.isArray(list) ? list : []) {
    if (typeof server?.url !== 'string' || server.url === '') continue
    const headers = {}
    for (const header of Array.isArray(server.headers) ? server.headers : []) {
      if (typeof header?.name === 'string' && typeof header?.value === 'string') headers[header.name] = header.value
    }
    out[server.name ?? `mcp-${Object.keys(out).length}`] = {
      type: server.type === 'sse' ? 'sse' : 'http',
      url: server.url,
      ...(Object.keys(headers).length > 0 ? { headers } : {}),
    }
  }
  return out
}

async function modelInfo() {
  const models = await client.listModels()
  const available = models.map((m) => ({ modelId: m.id, name: m.name ?? m.id, ...(m.description ? { description: m.description } : {}) }))
  return {
    models: { availableModels: available, currentModelId: currentModel },
    configOptions: [
      {
        id: 'model',
        name: 'Model',
        currentValue: currentModel,
        options: available.map((m) => ({ value: m.modelId, name: m.name })),
      },
    ],
  }
}

function attach(handle) {
  session = handle
  sessionId = handle.sessionId
  streamed = 0
  handle.on((event) => {
    if (event.type === 'text_delta') {
      streamed += event.text.length
      notify('session/update', {
        sessionId,
        update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: event.text } },
      })
    } else if (event.type === 'tool_start') {
      notify('session/update', {
        sessionId,
        update: {
          sessionUpdate: 'tool_call',
          toolCallId: event.id,
          title: event.name,
          kind: 'other',
          status: 'pending',
          ...(event.input !== undefined ? { rawInput: event.input } : {}),
        },
      })
    } else if (event.type === 'tool_end') {
      notify('session/update', {
        sessionId,
        update: {
          sessionUpdate: 'tool_call_update',
          toolCallId: event.id,
          status: event.ok ? 'completed' : 'failed',
          content: [{ type: 'content', content: { type: 'text', text: event.error ?? 'ok' } }],
        },
      })
    }
  })
}

async function open(params, resume) {
  await ensureRuntime()
  if (session !== null) await session.disconnect().catch(() => {})
  session = null
  sessionId = ''
  const cwd = typeof params?.cwd === 'string' ? params.cwd : process.cwd()
  const created = {
    cwd,
    model: 'auto',
    tools: { availableTools: ['mcp:*', 'custom:*'] },
    events: { streaming: true },
    permissions: { onRequest: approveAll },
    github: { tokenProvider: async () => ({ kind: 'token', accessToken: token, expiresIn: 8 * 60 * 60 }) },
    mcp: { servers: toMcpServers(params?.mcpServers) },
    ...(instructions === '' ? {} : { systemMessage: { mode: 'append', content: instructions } }),
  }
  const handle = resume ? await client.resumeSession(params.sessionId, created) : await client.createSession(created)
  attach(handle)
  const info = await modelInfo()
  return { sessionId, ...info }
}

async function promptText(params) {
  const blocks = Array.isArray(params?.prompt) ? params.prompt : []
  return blocks.filter((b) => b?.type === 'text').map((b) => String(b.text ?? '')).join('\n')
}

const methods = {
  async initialize() {
    return {
      protocolVersion: 1,
      agentCapabilities: {
        loadSession: true,
        mcpCapabilities: { http: true, sse: true },
        promptCapabilities: { image: true, audio: false, embeddedContext: true },
      },
      agentInfo: { name: 'GitHub Copilot (still.fail adapter)', version: '0.1.0' },
      authMethods: [],
    }
  },
  async authenticate() {
    return {}
  },
  async 'session/new'(params) {
    return open(params, false)
  },
  async 'session/load'(params) {
    return open(params, true)
  },
  async 'session/prompt'(params) {
    if (session === null) throw new Error('no session is open')
    streamed = 0
    const text = await promptText(params)
    const answer = await session.sendAndWait({ prompt: text }, 180_000)
    const content = answer?.data?.content ?? ''
    if (streamed === 0 && content !== '') {
      notify('session/update', {
        sessionId,
        update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: content } },
      })
    }
    return { stopReason: 'end_turn' }
  },
  async 'session/set_config_option'(params) {
    if (session === null) throw new Error('no session is open')
    if (params?.configId === 'model' && typeof params.value === 'string') {
      currentModel = params.value
      await session.setModel(params.value)
    }
    return {}
  },
  async 'session/cancel'() {
    if (session !== null) await session.abort().catch(() => {})
    return {}
  },
  async 'session/close'() {
    if (session !== null) await session.disconnect().catch(() => {})
    session = null
    sessionId = ''
    return {}
  },
}

const lines = createInterface({ input: process.stdin })
lines.on('line', async (line) => {
  let message
  try {
    message = JSON.parse(line)
  } catch {
    return
  }
  const method = message?.method
  if (typeof method !== 'string') {
    // A response to something this server never asks for: ignore.
    return
  }
  const handler = methods[method]
  if (handler === undefined) {
    if (message.id !== undefined) failure(message.id, `${method} is not supported`, -32601)
    return
  }
  try {
    const value = await handler(message.params)
    if (message.id !== undefined) result(message.id, value)
  } catch (error) {
    if (message.id !== undefined) failure(message.id, String(error?.message ?? error))
  }
})

lines.on('close', async () => {
  if (session !== null) await session.disconnect().catch(() => {})
  if (client !== null) await client.stop().catch(() => {})
  process.exit(0)
})
