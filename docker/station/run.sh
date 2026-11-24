#!/bin/sh
# A disposable local station with the Copilot runtime, and a small chat page.
#   COPILOT_GITHUB_TOKEN=... ./run.sh
set -eu
APP=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PATH="$APP/bin:$PATH"
export PATH
DATA=${DATA:-$APP/data}
PORT=${PORT:-8899}
MESH_PORT=${MESH_PORT:-4761}
GATEWAY_PORT=${GATEWAY_PORT:-8080}
mkdir -p "$DATA/homes/copilot"
if [ ! -f "$DATA/mesh/cloud.json" ]; then
  "$APP/bin/station-load" setup "$DATA" > "$DATA/station-id"
fi
node "$APP/init.mjs" "$DATA"
STATION_ID=$(cat "$DATA/station-id")
export STILLFAIL_MESH_BIND_ADDR="0.0.0.0:$MESH_PORT"
STILLFAIL_MESH_NATIVE="$APP/app/station/mesh.node" \
STILLFAIL_RUNNER="$APP/app/station/stillfail-runner" \
  node "$APP/app/station/main.js" run --app "$APP/app" --data "$DATA" --port "$PORT" > "$DATA/station.log" 2>&1 &
echo $! > "$DATA/station.pid"
i=0
while [ "$i" -lt 90 ]; do
  if curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then break; fi
  i=$((i + 1)); sleep 1
done
if ! curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then
  echo "station did not come up; see $DATA/station.log" >&2
  tail -40 "$DATA/station.log" >&2
  exit 1
fi
DATA="$DATA" STATION_ID="$STATION_ID" MESH_ADDR="127.0.0.1:$MESH_PORT" GATEWAY_PORT="$GATEWAY_PORT" exec node "$APP/gateway.mjs"
