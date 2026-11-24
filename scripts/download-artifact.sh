#!/bin/bash
# A run's artifact, unzipped into a directory whole or not at all: what mbui-size's jobs measure. actions/download-artifact
# can end 0 with half of it on the disk (mbui-size 43955196994's idle, 2026-11-16, on Mini1's runner 2.338.2 and its
# Node 24: Azure's stream of mac-unsigned cut at 15,482,825 of 31,527,777 bytes, the unzip's promise never settled, the
# process out with 0 and a bundle.zip without its end; idlemem.sh's ditto failed the job on it, and the APK downloaded
# whole before it was lost with it). Here the zip is checked by its size and its digest before anything is unzipped,
# a cut download resumed from where it was cut (Range), and the directory is made only from what passed.
#   bash scripts/download-artifact.sh [--optional] RUN_ID NAME DEST
# GITHUB_REPOSITORY (owner/name), GH_TOKEN or GITHUB_TOKEN, GITHUB_API_URL (https://api.github.com by default; the test
# points it at a server of its own). Three tries each of the list and of the download; what still fails leaves no DEST,
# and exits 1, or with --optional says a warning and exits 0 (the measure is left out: mbui-size's record carries the
# one before's).
set -u
optional=
if [ "${1:-}" = --optional ]; then optional=1; shift; fi
run=${1:?usage: download-artifact.sh [--optional] RUN_ID NAME DEST}
name=${2:?usage: download-artifact.sh [--optional] RUN_ID NAME DEST}
dest=${3:?usage: download-artifact.sh [--optional] RUN_ID NAME DEST}
[ $# = 3 ] || { echo "usage: download-artifact.sh [--optional] RUN_ID NAME DEST" >&2; exit 2; }
repo=${GITHUB_REPOSITORY:?download-artifact.sh: GITHUB_REPOSITORY not set}
token=${GH_TOKEN:-${GITHUB_TOKEN:-}}
[ -n "$token" ] || { echo "download-artifact.sh: neither GH_TOKEN nor GITHUB_TOKEN set" >&2; exit 2; }
api=${GITHUB_API_URL:-https://api.github.com}
api=${api%/}
# (seconds between tries; the test's 0)
pause=${DOWNLOAD_ARTIFACT_PAUSE:-3}
tries=3

rm -rf "$dest"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/download-artifact.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

say() { echo "download-artifact.sh: $name (run $run): $*" >&2; }
give_up() {
  rm -rf "$dest"
  if [ -n "$optional" ]; then
    echo "::warning::download-artifact.sh: $name of run $run not downloaded whole ($*): left out" >&2
    exit 0
  fi
  say "$*"
  exit 1
}

# (GitHub's own requests carry the token; the blob's signed URL is asked with none: Azure refuses a request it does not
# know the Authorization of, 403)
gh_curl() {
  curl -sS --connect-timeout 15 --max-time 60 \
    -H "Authorization: Bearer $token" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "$@"
}
size_of() { wc -c < "$1" | tr -d ' '; }
sha256_of() {
  if command -v sha256sum > /dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print tolower($1)}'
}

# The artifact: the first of its name not expired
found=
for i in $(seq 1 $tries); do
  [ "$i" = 1 ] || sleep "$pause"
  if body=$(gh_curl -f "$api/repos/$repo/actions/runs/$run/artifacts?name=$name&per_page=100") &&
    found=$(printf '%s' "$body" | jq -er --arg n "$name" \
      'first(.artifacts[] | select(.name == $n and (.expired | not))) | "\(.archive_download_url)\t\(.size_in_bytes)\t\(.digest // "")"'); then
    break
  fi
  found=
  say "listing the run's artifacts, try $i of $tries, failed"
done
[ -n "$found" ] || give_up "no such artifact, or its run's artifacts not listed"
IFS=$'\t' read -r url size digest <<EOF
$found
EOF
want=
case $digest in sha256:*) want=$(printf '%s' "${digest#sha256:}" | tr '[:upper:]' '[:lower:]') ;; esac

zip=$tmp/archive.zip
fetch() { curl -fsS --connect-timeout 15 --speed-limit 1024 --speed-time 20 "$@" -o "$zip" "$blob"; }
whole=
for i in $(seq 1 $tries); do
  [ "$i" = 1 ] || sleep "$pause"
  # (the blob's URL is signed for a minute or so: asked again each try, its redirect not followed with the token)
  blob=$(gh_curl -o /dev/null -w '%{http_code} %{redirect_url}' "$url") || blob=
  case $blob in
    30[1237]\ ?*) blob=${blob#* } ;;
    *) say "no redirect to the blob, try $i of $tries (${blob:-no answer})"; continue ;;
  esac
  # (a cut download is taken on from where it was cut, but on the last try it is downloaded whole again; a file as long
  # as the artifact or longer is no cut one)
  if [ -s "$zip" ] && { [ "$i" = $tries ] || [ "$(size_of "$zip")" -ge "$size" ]; }; then rm -f "$zip"; fi
  if [ -s "$zip" ]; then
    fetch -C -
    rc=$?
    # (33: the server took no Range)
    if [ $rc = 33 ]; then rm -f "$zip"; fetch; rc=$?; fi
  else
    fetch
    rc=$?
  fi
  if [ $rc != 0 ]; then
    say "download, try $i of $tries, failed (curl $rc, $( [ -e "$zip" ] && size_of "$zip" || echo 0) of $size bytes)"
    continue
  fi
  got=$(size_of "$zip")
  if [ "$got" != "$size" ]; then
    say "download, try $i of $tries: $got bytes, not $size"
    rm -f "$zip"
    continue
  fi
  if [ -n "$want" ] && [ "$(sha256_of "$zip")" != "$want" ]; then
    say "download, try $i of $tries: its sha256 is not the artifact's digest"
    rm -f "$zip"
    continue
  fi
  whole=1
  break
done
[ -n "$whole" ] || give_up "$tries tries"

mkdir -p "$tmp/out"
if command -v unzip > /dev/null 2>&1; then
  unzip -q "$zip" -d "$tmp/out"
else
  python3 -m zipfile -e "$zip" "$tmp/out"
fi || give_up "its zip not unzipped"
{ mkdir -p "$(dirname "$dest")" && mv "$tmp/out" "$dest"; } || give_up "not moved to $dest"
say "$size bytes${want:+, sha256 as its digest}"
