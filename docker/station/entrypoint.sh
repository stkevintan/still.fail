#!/bin/sh
# A disposable station: a local test workspace (station-load setup), one Copilot profile, the station over its own
# loopback mesh port, and a small chat page on GATEWAY_PORT.
set -eu

DATA=${DATA:-/data}
PORT=${PORT:-8899}
MESH_PORT=${MESH_PORT:-4761}
GATEWAY_PORT=${GATEWAY_PORT:-8080}
mkdir -p "$DATA/homes/copilot"

if [ ! -f "$DATA/mesh/cloud.json" ]; then
  station-load setup "$DATA" > "$DATA/station-id"
fi
STATION_ID=$(cat "$DATA/station-id")

node - "$DATA/config.json" <<'NODE'
const fs = require("node:fs");
const file = process.argv[2];
const token = process.env.COPILOT_GITHUB_TOKEN ?? "";
const profile = {
  id: "copilot",
  name: "GitHub Copilot",
  runtime: "copilot",
  model: "gpt-6.2-sol",
  access: { kind: "subscription" },
  home: "homes/copilot",
  env: token === "" ? {} : { COPILOT_GITHUB_TOKEN: token },
  models: ["gpt-6.2-sol"],
};
fs.writeFileSync(file, JSON.stringify({ autoUpdate: false, profiles: [profile] }, null, 2));
NODE

export STILLFAIL_MESH_BIND_ADDR="0.0.0.0:$MESH_PORT"
node /app/station/main.js run --app /app --data "$DATA" --port "$PORT" > "$DATA/station.log" 2>&1 &
echo $! > "$DATA/station.pid"

i=0
while [ "$i" -lt 90 ]; do
  if curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then break; fi
  i=$((i + 1))
  sleep 1
done
if ! curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then
  echo "station did not come up; last log lines:" >&2
  tail -40 "$DATA/station.log" >&2
  exit 1
fi

export DATA STATION_ID MESH_ADDR="127.0.0.1:$MESH_PORT" GATEWAY_PORT
exec node /app/gateway.mjs
