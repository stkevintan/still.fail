// Writes the disposable station's config and station id; the token comes from COPILOT_GITHUB_TOKEN.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const data = process.argv[2]
mkdirSync(join(data, 'homes', 'copilot'), { recursive: true })
const token = process.env.COPILOT_GITHUB_TOKEN ?? ''
const profile = {
  id: 'copilot',
  name: 'GitHub Copilot',
  runtime: 'copilot',
  model: 'gpt-6.2-sol',
  access: { kind: 'subscription' },
  home: 'homes/copilot',
  env: token === '' ? {} : { COPILOT_GITHUB_TOKEN: token },
  models: ['gpt-6.2-sol'],
}
writeFileSync(join(data, 'config.json'), `${JSON.stringify({ autoUpdate: false, profiles: [profile] }, null, 2)}\n`)
if (existsSync(join(data, 'mesh', 'cloud.json'))) {
  const cloud = JSON.parse(readFileSync(join(data, 'mesh', 'cloud.json'), 'utf8'))
  if (typeof cloud.station === 'string') writeFileSync(join(data, 'station-id'), `${cloud.station}\n`)
}
