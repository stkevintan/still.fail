#!/bin/sh
# Farview's client (AFK-surf/farview-legacy, private: its client/, the module fvclient, which draws a chat's Farview tab in the
# app) at the commit farview.pin names, into deps/farview/client, which moon.work names (the user, 2026-11-14: kept out
# of this repository, pulled at a pinned commit). Nothing is fetched while deps/farview holds that commit. In CI its
# read-only deploy key is FARVIEW_DEPLOY_KEY (the workflows' secret); elsewhere git's own credentials for GitHub.
set -eu
A=$(cd "$(dirname "$0")/.." && pwd)
pin=$(tr -d ' \n' < "$A/farview.pin")
d=$A/deps/farview
[ "$(cat "$d/.pin" 2>/dev/null || true)" = "${pin}-ui" ] && [ -f "$d/client/moon.mod" ] && exit 0
tmp=$A/deps/farview.tmp
rm -rf "$tmp"
mkdir -p "$tmp"
urls=https://github.com/AFK-surf/farview-legacy.git
if [ -n "${FARVIEW_DEPLOY_KEY:-}" ]; then
  umask 077
  printf '%s\n' "$FARVIEW_DEPLOY_KEY" > "$tmp/key"
  # (GitHub's SSH on port 22, and the same on 443 where 22 is cut: Studio's runners behind its proxy, whose node closed
  # every connection to 22 in 300 ms, mbui-media-runtime red on 43868680757 and 43869405355, 2026-11-16)
  urls="git@github.com:AFK-surf/farview-legacy.git ssh://git@ssh.github.com:443/AFK-surf/farview-legacy.git"
  export GIT_SSH_COMMAND="ssh -i '$tmp/key' -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
fi
# (each way in turn, three rounds, no wait of a fixed time between (detlint's script-wait): a failed fetch's half
# begun repository started again)
fetched=
for round in 1 2 3; do
  for url in $urls; do
    rm -rf "$tmp/git"
    git init -q "$tmp/git"
    if git -C "$tmp/git" fetch -q --depth 1 "$url" "$pin"; then fetched=1; break 2; fi
    echo "farview.sh: fetching from $url failed (round $round)" >&2
  done
done
[ -n "$fetched" ] || { echo "farview.sh: farview at $pin not fetched" >&2; exit 1; }
git -C "$tmp/git" checkout -q FETCH_HEAD
rm -rf "$d"
mkdir -p "$d"
mv "$tmp/git/client" "$d/client"
for f in "$d/client/moon.mod" "$d/client"/src/*/moon.pkg "$d/client"/src/*/pkg.generated.mbti; do
  [ -f "$f" ] || continue
  sed -e 's|"mbui@0\.1\.0"|"ui@0.1.0"|g' -e 's|"mbui/|"ui/|g' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done
printf '%s-ui\n' "$pin" > "$d/.pin"
rm -rf "$tmp"
