#!/bin/bash
# A command run for so long at most, to the second, on Linux and macOS alike (macOS has no `timeout`): CI's steps that
# must end before their job does, so that what comes after them (stopping what they left, keying and saving the
# caches) still has its time. A step's own `timeout-minutes` is no use for it: GitHub's runner takes it in whole
# minutes, 3.8, 3.5, 3.4 and 3.2 all cut at 3 (`has timed out after 3 minutes`, preview's ios 43924444930 and
# 43925936518 at 192 s, mbc's link done and the .ipa some 5 s off, 50 s of the job left), so the steps say none.
#   bash scripts/with-timeout.sh LIMIT COMMAND [ARG...]
# LIMIT is seconds, or @T: until T (seconds since the epoch). A job's first step writes when the job is cut
# (JOB_END, in $GITHUB_ENV) and its long step runs `with-timeout.sh @$((JOB_END - 35)) …`: what the job leaves it less
# what comes after it. The command's own exit status is this one's; out of time, the command and all its processes are
# stopped (TERM, then KILL 5 s on) and this exits 124, as GNU timeout does, so that `if: always()` steps after it take
# the failed way. What a stopped process left behind, reparented, is the step after's to stop (by MBUI_BUILD_TREE).
set -u
limit=${1:?usage: with-timeout.sh SECONDS|@EPOCH COMMAND [ARG...]}
shift
[ $# -gt 0 ] || { echo "with-timeout.sh: no command" >&2; exit 2; }
case $limit in
  @*) left=$(( ${limit#@} - $(date +%s) )) ;;
  *) left=$limit ;;
esac
case $left in -*|0) echo "with-timeout.sh: no time left ($limit) for $1" >&2; exit 124 ;; esac

# (the command and what it started, each process's children found again at each stop: no process group asked of the
# shell, which a shell without a terminal may not give)
# On Linux each thread's children are read from /proc, no process started for them (a `pgrep` a process, each reading
# all of /proc, took seconds of a loaded runner's 4 cores); elsewhere, or without that file, `pgrep -P`.
if [ -e "/proc/$$/task/$$/children" ]; then
  tree() {
    local f c kids
    for f in /proc/"$1"/task/*/children; do
      kids=
      { read -r kids < "$f"; } 2>/dev/null
      for c in $kids; do tree "$c"; done
    done
    echo "$1"
  }
else
  tree() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do tree "$c"; done; echo "$1"; }
fi

# (the limit's watcher says that its TERM is now its trap's, and the command that ended first stops it only then: a
# TERM come before the trap was set may go unseen by its shell, the watcher left to stop the command at its limit, or
# end it with the shell's own word of a job killed. It says so on a pipe; where there is none (Git for Windows' bash,
# whose mkfifo is not implemented), by a file, looked for every 0.05 s. Either is waited for 5 s at most, or until
# the watcher is gone, so that one ended unready holds nothing up.)
dir=$(mktemp -d "${TMPDIR:-/tmp}/with-timeout.XXXXXX")
trap 'rm -rf "$dir"' EXIT
# (exec's own redirections are this shell's from then on: its error is put aside in a group, not with a 2>/dev/null of
# the exec, which would make that this shell's stderr, and the command's)
if mkfifo "$dir/ready" 2>/dev/null && { exec 4<>"$dir/ready"; } 2>/dev/null; then fifo=1; else fifo=0; fi
rm -f "$dir/ready"
ready() {
  if [ $fifo = 1 ]; then echo >&4; exec 4<&-; else : > "$dir/ready"; fi
}
if [ $fifo = 1 ]; then "$@" 4<&- & else "$@" & fi
pid=$!
(
  # (its sleep stopped with it, and waited for, when the command ends first: nothing of this left running past the
  # step; nothing said of it either, the shell's word of a job killed included. KILL, as a TERM come between the
  # sleep's fork and its exec is lost with the shell's trap there, the sleep left to run out)
  trap 'exec 2>/dev/null; kill -KILL $s; wait $s; exit 0' TERM
  sleep "$left" < /dev/null > /dev/null 2>&1 &
  s=$!
  ready
  wait $s
  : > "$dir/out"
  echo "with-timeout.sh: $1 still running after ${left} s: stopped" >&2
  pids=$(tree $pid)
  # shellcheck disable=SC2086 # pids, one word each
  kill -TERM $pids 2>/dev/null
  # (5 s for TERM by the clock, not by a count of sleeps that each take longer on a loaded machine; looked at every
  # 0.1 s, done as soon as it ended)
  grace=$((SECONDS + 5))
  while [ $SECONDS -lt $grace ] && kill -0 $pid 2>/dev/null; do sleep 0.1; done
  pids="$pids $(tree $pid 2>/dev/null)"
  # shellcheck disable=SC2086
  kill -KILL $pids 2>/dev/null
) < /dev/null &
watch=$!
wait $pid
code=$?
if [ -e "$dir/out" ]; then
  wait $watch 2>/dev/null
  exit 124
fi
if [ $fifo = 1 ]; then
  read -r -t 5 _ <&4 2>/dev/null || true
else
  t_end=$((SECONDS + 5))
  while [ ! -e "$dir/ready" ] && [ $SECONDS -lt $t_end ] && kill -0 $watch 2>/dev/null; do sleep 0.05; done
fi
kill -TERM $watch 2>/dev/null
wait $watch 2>/dev/null
exit $code
