#!/bin/sh
# Regression tests for apps/mbui/scripts/used.sh:
# - When no MBC_STORE unit directory is newer than START, keep the store whole (still remove .lock files).
# - When at least one MBC_STORE unit directory is newer than START, prune older directories and keep newer ones.
set -eu
D="$(cd "$(dirname "$0")" && pwd)"
USED="$D/used.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Case 1: no store entry touched during this run -> keep whole store.
store1="$tmp/store1"
start1="$tmp/start1"
mkdir -p "$store1/aa/aa0001" "$store1/bb/bb0002"
printf 'obj1' > "$store1/aa/aa0001/obj"
printf 'obj2' > "$store1/bb/bb0002/obj"
: > "$store1/aa/aa0001.lock"
touch -t 202001010000 "$store1/aa/aa0001" "$store1/bb/bb0002"
touch -t 202001020000 "$start1"

out1=$(sh "$USED" "$start1" "$store1")
case "$out1" in
  *"none of it touched by this run: kept whole"*) ;;
  *) echo "used-test: expected kept-whole message, got: $out1" >&2; exit 1 ;;
esac
[ -d "$store1/aa/aa0001" ] || { echo "used-test: aa0001 was wrongly deleted" >&2; exit 1; }
[ -d "$store1/bb/bb0002" ] || { echo "used-test: bb0002 was wrongly deleted" >&2; exit 1; }
[ ! -e "$store1/aa/aa0001.lock" ] || { echo "used-test: .lock file was not deleted" >&2; exit 1; }

# Case 2: one store entry touched after START -> prune untouched entries, keep touched one.
store2="$tmp/store2"
start2="$tmp/start2"
mkdir -p "$store2/aa/aa0001" "$store2/bb/bb0002"
printf 'old' > "$store2/aa/aa0001/obj"
printf 'new' > "$store2/bb/bb0002/obj"
touch -t 202001010000 "$store2/aa/aa0001"
touch -t 202001020000 "$start2"
touch -t 202001030000 "$store2/bb/bb0002"

out2=$(sh "$USED" "$start2" "$store2")
case "$out2" in
  *"MB of it used"*) ;;
  *) echo "used-test: expected prune summary, got: $out2" >&2; exit 1 ;;
esac
[ ! -d "$store2/aa/aa0001" ] || { echo "used-test: stale aa0001 was not pruned" >&2; exit 1; }
[ -d "$store2/bb/bb0002" ] || { echo "used-test: fresh bb0002 was wrongly pruned" >&2; exit 1; }

echo "used-test: ok"
