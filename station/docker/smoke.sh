#!/bin/sh
# What the station's image must do, run against an image built from this directory (CI's station-docker.yml):
#   sh station/docker/smoke.sh <image> entrypoint|release   (1 and 2, or 3)
# 1. With no workspace joined and no token it says how to give one, and ends.
# 2. Its entrypoint keeps the station running: started again after it ends, not while an install holds its lock, and
#    stopped with the container (a stand-in release that says what it was asked).
# 3. The real release on the cloud installs and runs on it (a station joined by a stand-in cloud.json: the release
#    fetched, the station started; its id said). The MoonBit station's release (station/stillfail-reader, no main.js)
#    has no Node and is given none; one from before is given its Node.
set -eu
image=$1
part=$2
vol=stillfail-smoke-$$
name=stillfail-smoke-$$
cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; docker volume rm -f "$vol" >/dev/null 2>&1 || true; }
trap cleanup EXIT
fail() { echo "smoke: $*" >&2; docker logs "$name" 2>&1 | tail -40 >&2 || true; exit 1; }
# Waits up to $1 seconds for the shell condition $2, run in the container.
until_in() {
  for _ in $(seq 1 "$1"); do docker exec "$name" sh -c "$2" 2>/dev/null && return 0; sleep 1; done
  return 1
}

if [ "$part" = entrypoint ]; then
echo "smoke: 1. nothing joined, no token"
code=0
out=$(docker run --rm -v "$vol:/home/stillfail" "$image" 2>&1) || code=$?
[ "$code" = 2 ] || fail "no token: exit $code, not 2: $out"
echo "$out" | grep -q "joined no workspace" || fail "no token: not said how to give one: $out"

echo "smoke: 2. kept running, held by an install, stopped with the container"
docker run --rm -v "$vol:/home/stillfail" --entrypoint sh "$image" -c '
  set -e
  d=$HOME/.stillfail
  mkdir -p "$d/mesh" "$d/app/bin"
  echo "{\"origin\": \"https://app.still.fail\"}" > "$d/mesh/cloud.json"
  cat > "$d/app/bin/stillfail" <<FAKE
#!/bin/sh
echo "\$*" >> "\$HOME/started"
trap "echo ended >> \$HOME/ended; exit 0" TERM
echo \$\$ > "\$HOME/station.pid"
while :; do sleep 1; done
FAKE
  chmod +x "$d/app/bin/stillfail"'
docker run -d --name "$name" -v "$vol:/home/stillfail" "$image" ignored-token >/dev/null
until_in 20 '[ "$(wc -l < ~/started)" = 1 ]' || fail "not started"
docker exec "$name" grep -qx start /home/stillfail/started || fail "not started with start"
docker exec "$name" sh -c 'kill -KILL "$(cat ~/station.pid)"'
until_in 30 '[ "$(wc -l < ~/started)" = 2 ]' || fail "not started again after it ended"
# An install under way (its holder a process of the container's): not started again until it lets go.
docker exec -d "$name" sh -c 'mkdir -p ~/.stillfail/run/install.lock && echo $$ > ~/.stillfail/run/install.lock/pid && exec sleep 600'
until_in 10 '[ -f ~/.stillfail/run/install.lock/pid ]' || fail "no lock"
docker exec "$name" sh -c 'kill -KILL "$(cat ~/station.pid)"'
sleep 15
[ "$(docker exec "$name" sh -c 'wc -l < ~/started')" = 2 ] || fail "started while an install held its lock"
docker exec "$name" sh -c 'kill "$(cat ~/.stillfail/run/install.lock/pid)"; rm -rf ~/.stillfail/run/install.lock'
until_in 30 '[ "$(wc -l < ~/started)" = 3 ]' || fail "not started once the install let go"
docker stop -t 20 "$name" >/dev/null
[ "$(docker inspect -f '{{.State.ExitCode}}' "$name")" = 0 ] || fail "stopped with exit $(docker inspect -f '{{.State.ExitCode}}' "$name")"
docker run --rm -v "$vol:/home/stillfail" --entrypoint cat "$image" /home/stillfail/ended | grep -qx ended || fail "the station was not ended by the stop"
fi

if [ "$part" = release ]; then
echo "smoke: 3. the cloud's release installed and run"
docker run --rm -v "$vol:/home/stillfail" --entrypoint sh "$image" -c '
  mkdir -p ~/.stillfail/mesh && echo "{\"origin\": \"https://app.still.fail\"}" > ~/.stillfail/mesh/cloud.json'
docker run -d --name "$name" -v "$vol:/home/stillfail" -e STILLFAIL_CHANNEL="${STILLFAIL_CHANNEL:-beta}" "$image" >/dev/null
until_in 240 '[ -f ~/.stillfail/run/station.json ]' || fail "the release did not install and start"
docker exec "$name" sh -c '~/.stillfail/app/bin/stillfail station id' || fail "no station id"
docker exec "$name" sh -c 'cat ~/.stillfail/app/VERSION; if [ -x ~/.stillfail/app/station/stillfail-reader ] && [ ! -f ~/.stillfail/app/station/main.js ]; then test ! -e ~/.stillfail/app/node; else ~/.stillfail/app/node/bin/node -v; fi'
docker stop -t 30 "$name" >/dev/null
fi
echo "smoke: $part passed"
