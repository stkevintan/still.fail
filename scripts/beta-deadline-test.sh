#!/bin/bash
# apps/mbui/scripts/beta.sh's deltas-deadline: the seconds `publish` gives a release's deltas, STILLFAIL_DELTAS_SECONDS
# (60) and never past 35 s before the job's end (JOB_END), none at all (0 or less) when that leaves none, so the package
# and its feed go out within the job (.github/AGENTS.md: deltas never hold back a release). The cases of main
# 44efbac9's preview, 43981921907 (2026-11-17), each before its fix: linux x64 put with 60 s of the job left, all 60
# given to its deltas, cancelled 11 ms after its feed; the Windows app's with 24 s left, 25 given, its installer never put.
# And of main bd0f01ab's, 43990130513: the Windows app's deltas ended 25 s before the job's end, its put, upload and
# post steps took 19 s of them, and the job, all done, was cancelled at its end (its JOB_END 8 s late besides).
set -u
d=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fails=0
# expect WANT NOW [VAR=VALUE...]: deltas-deadline at NOW, with those set (and nothing else of the job's)
expect() {
  local want=$1 at=$2 got
  shift 2
  got=$(env -u JOB_END -u STILLFAIL_DELTAS_SECONDS MBUI_CACHE="$t" "$@" bash "$d/apps/mbui/scripts/beta.sh" deltas-deadline "$at")
  if [ "$got" != "$want" ]; then
    echo "beta-deadline-test: at $at with ${*:-nothing set}: $got s, not $want" >&2
    fails=$((fails + 1))
  fi
}
# no job's end: STILLFAIL_DELTAS_SECONDS, 60 when unset
expect 60 1000
expect 25 1000 STILLFAIL_DELTAS_SECONDS=25
# room enough (200 s left: 165 after the put's 35)
expect 60 1000 JOB_END=1200
expect 25 1000 JOB_END=1200 STILLFAIL_DELTAS_SECONDS=25
# just enough, and one short
expect 60 1000 JOB_END=1095
expect 59 1000 JOB_END=1094
# linux x64 of 43981921907: 60 s left, 25 to the deltas (was 60)
expect 25 1000 JOB_END=1060
# the Windows app's: 24 s left, none (was 25)
expect -11 1000 JOB_END=1024 STILLFAIL_DELTAS_SECONDS=25
# 36 s left: 1 (was 11)
expect 1 1000 JOB_END=1036
# exactly 35 s left: none
expect 0 1000 JOB_END=1035
[ "$fails" = 0 ] || exit 1
echo "beta-deadline-test: 10 cases"
