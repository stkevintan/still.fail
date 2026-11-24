#!/bin/sh
# The entrypoint of still.fail's station container (Dockerfile beside it): installs the station on the first start and
# runs it, starting it again whenever it ends (a restart the installer asks for, a crash), until the container stops.
#   <token> [<lock>] [rig:<person>]   what 「添加 station」 gives install.sh: used only while the station has joined no
#                                     workspace, so the same `docker run` line starts the container again unchanged
#   STILLFAIL_ORIGIN                  the cloud, https://app.still.fail unless said (another product's, a self-hosted one)
#   STILLFAIL_CHANNEL=beta            the test channel's release, on the first install
#   STILLFAIL_LANG=en                 the installer's words (zh unless said)
# The release, the station's data and the agents' homes are all in the volume ($HOME): the installer puts the release in
# ~/.stillfail/app, and from then on the station updates itself there (cloud/src/install.ts, STILLFAIL_CONTAINER).
set -eu
origin=${STILLFAIL_ORIGIN:-https://app.still.fail}
data=${STILLFAIL_DATA:-$HOME/.stillfail}
log="$data/stillfail.log"
say() { printf 'stillfail-container: %s\n' "$*" >&2; }

# A volume made root's (a bind mount of a directory docker made): nothing could be written in it.
if [ ! -w "$HOME" ]; then
  say "$HOME is not writable by $(id -un) (uid $(id -u)): give it to that uid, e.g. sudo chown -R $(id -u):$(id -g) <the host directory>"
  exit 1
fi

# The installer from the cloud, as the machine's own command does it: the release for this machine, its Node, joining.
install() {
  mkdir -p "$data"
  case "${STILLFAIL_LANG:-zh}" in en) lang=en ;; *) lang=zh ;; esac
  curl -fsSL --retry 5 --retry-all-errors "$origin/install.sh?lang=$lang" -o "$data/install.sh.part"
  mv "$data/install.sh.part" "$data/install.sh"
  STILLFAIL_DATA="$data" sh "$data/install.sh" "$@"
  rm -f "$data/install.sh"
}

joined() { [ -f "$data/mesh/cloud.json" ]; }
if [ -f "$data/uninstalled" ]; then
  say "the station here was uninstalled (stillfail uninstall); its data is kept in the volume. Remove $data/uninstalled to install it again"
  exit 0
fi
if ! joined; then
  if [ $# -eq 0 ]; then
    say "this station has joined no workspace yet: give the token from 「添加 station」 in still.fail as the container's argument"
    say "  docker run -d --name stillfail --restart unless-stopped -v stillfail:/home/stillfail <image> <token>"
    exit 2
  fi
  install "$@"
elif [ ! -x "$data/app/bin/stillfail" ]; then
  # Joined, its release gone (a volume restored without it): installed again, the same station.
  install
fi

# The station's output goes to its log in the data, as the installer's services write it (the station cuts it in place);
# what is added to it is shown on the container's own output too, for docker logs.
touch "$log"
tail -n 0 -F "$log" 2>/dev/null &
tailer=$!

station=""
stopping=""
stop() {
  stopping=yes
  [ -z "$station" ] || kill -TERM "$station" 2>/dev/null || true
}
trap stop TERM INT HUP

# An install under way (the station updating itself while it could not hand over): its lock is held until the new
# release is in place, so the station is started again only once it is let go of (or its holder is gone).
install_done() {
  lock="$data/run/install.lock"
  waited=0
  while [ -d "$lock" ] && [ -z "$stopping" ]; do
    holder=$(cat "$lock/pid" 2>/dev/null || true)
    { [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; } && break
    [ "$waited" -lt 600 ] || break
    sleep 1
    waited=$((waited + 1))
  done
}

while [ -z "$stopping" ]; do
  install_done
  [ -z "$stopping" ] || break
  if [ ! -x "$data/app/bin/stillfail" ]; then
    [ -f "$data/uninstalled" ] && { say "the station was uninstalled; its data is kept in the volume"; break; }
    say "no release in $data/app; installing it again"
    install || { sleep 10; continue; }
  fi
  started=$(date +%s)
  # (its data named, as the installer is told it: never what bin/stillfail makes of the path it is called by)
  STILLFAIL_DATA="$data" "$data/app/bin/stillfail" start >> "$log" 2>&1 &
  station=$!
  # (wait returns at a signal too: waited for again until the station has ended)
  while kill -0 "$station" 2>/dev/null; do wait "$station" 2>/dev/null || true; done
  station=""
  [ -z "$stopping" ] || break
  # Ended at once, again and again: not started faster than every 10 s.
  [ $(($(date +%s) - started)) -ge 10 ] || sleep 10
done
kill "$tailer" 2>/dev/null || true
