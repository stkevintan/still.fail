// A tiny chat page over the station's own admin API: station-load speaks the member protocol to the station, the page
// reads the station's SQLite entries. No cloud, no workspace enrollment: this is the local test workspace.
import { execFile } from 'node:child_process'
import { createServer } from 'node:http'
import { promisify } from 'node:util'

const run = promisify(execFile)
const DATA = process.env.DATA ?? '/data'
const STATION_ID = process.env.STATION_ID ?? ''
const MESH_ADDR = process.env.MESH_ADDR ?? '127.0.0.1:4761'
const PORT = Number(process.env.GATEWAY_PORT ?? 8080)

async function station(method, path, body = '') {
  const { stdout } = await run('station-load', ['send', DATA, STATION_ID, MESH_ADDR, method, path, body], {
    maxBuffer: 32 * 1024 * 1024,
  })
  // station-load prints the body, then the status: the first JSON line is the answer.
  return stdout.split('\n').find((line) => line.trim().startsWith('{')) ?? ''
}

async function entries(thread) {
  const { stdout } = await run('sqlite3', ['-json', `${DATA}/stillfail.db`, `select n, author_kind, text, at from entries where thread='${thread}' order by n`], {
    maxBuffer: 32 * 1024 * 1024,
  })
  return stdout.trim() === '' ? [] : JSON.parse(stdout)
}

let session
for (let i = 0; i < 90; i += 1) {
  try {
    const made = JSON.parse(await station('POST', '/admin/api/sessions', JSON.stringify({ runtime: 'copilot', model: 'gpt-6.2-sol' })))
    if (made?.thread?.id === undefined || made?.thread?.id === null) throw new Error(`no thread in ${JSON.stringify(made)}`)
    session = { key: made.key, thread: String(made.thread.id) }
    break
  } catch (error) {
    if (i === 89) {
      console.error(`could not create a Copilot session: ${error.message}`)
      process.exit(1)
    }
    await new Promise((r) => setTimeout(r, 1000))
  }
}
console.log(`session ${session.key}, thread ${session.thread}`)

const html = `<!doctype html><meta charset="utf-8"><title>still.fail · Copilot</title>
<style>
  body{font:15px/1.5 system-ui,sans-serif;max-width:820px;margin:2rem auto;padding:0 1rem;background:#0d1117;color:#e6edf3}
  h1{font-size:18px} .msg{padding:.6rem .8rem;margin:.5rem 0;border-radius:8px;white-space:pre-wrap}
  .user{background:#1f6feb22;border:1px solid #1f6feb55} .assistant{background:#161b22;border:1px solid #30363d}
  form{display:flex;gap:.5rem;margin-top:1rem} input{flex:1;padding:.6rem;background:#0d1117;color:inherit;border:1px solid #30363d;border-radius:6px}
  button{padding:.6rem 1rem} .meta{color:#8b949e;font-size:12px;margin-top:.2rem}
</style>
<h1>still.fail · GitHub Copilot <span class="meta" id="sid"></span></h1>
<div id="log"></div>
<form id="f"><input id="text" placeholder="Message Copilot…" autocomplete="off"><button>Send</button></form>
<script>
const sid = ${JSON.stringify(session.key)};
document.getElementById('sid').textContent = sid;
let last = 0;
async function refresh(){
  const r = await fetch('/messages'); if(!r.ok) return;
  const list = await r.json();
  if(list.length === last) return;
  last = list.length;
  document.getElementById('log').innerHTML = list.map(m =>
    '<div class="msg ' + (m.author_kind === 'person' ? 'user' : 'assistant') + '">' +
    String(m.text ?? '').replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c])) + '</div>').join('');
  window.scrollTo(0, document.body.scrollHeight);
}
document.getElementById('f').onsubmit = async (e) => {
  e.preventDefault();
  const text = document.getElementById('text').value.trim();
  if(!text) return;
  document.getElementById('text').value = '';
  await fetch('/send', {method:'POST', headers:{'content-type':'application/json'}, body: JSON.stringify({text})});
  await refresh();
};
setInterval(refresh, 1500); refresh();
</script>`

createServer(async (req, res) => {
  try {
    if (req.method === 'GET' && req.url === '/') {
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' }).end(html)
      return
    }
    if (req.method === 'GET' && req.url === '/messages') {
      res.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify(await entries(session.thread)))
      return
    }
    if (req.method === 'POST' && req.url === '/send') {
      let body = ''
      for await (const chunk of req) body += chunk
      const text = String(JSON.parse(body || '{}').text ?? '')
      if (text === '') {
        res.writeHead(400).end()
        return
      }
      const before = await entries(session.thread)
      const last = before.reduce((max, m) => Math.max(max, Number(m.n) || 0), 0)
      await station('POST', `/admin/api/threads/${session.thread}/messages`, JSON.stringify({ text }))
      // The turn runs in the station; wait for an assistant entry after this message.
      let list = before
      for (let i = 0; i < 120; i += 1) {
        list = await entries(session.thread)
        if (list.some((m) => Number(m.n) > last && m.author_kind !== 'person' && String(m.text ?? '').trim() !== '')) break
        await new Promise((r) => setTimeout(r, 1000))
      }
      res.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify(list))
      return
    }
    res.writeHead(404).end()
  } catch (error) {
    res.writeHead(500, { 'content-type': 'text/plain' }).end(String(error?.stack ?? error))
  }
}).listen(PORT, '0.0.0.0', () => console.log(`chat: http://127.0.0.1:${PORT}`))
