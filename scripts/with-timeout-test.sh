#!/bin/bash
# scripts/with-timeout.sh: a command that ends in time gives its own status, its output as it was; one that does not is
# stopped at its limit, with what it started, and says 124; an end time already gone runs nothing.
set -u
w=$(cd "$(dirname "$0")" && pwd)/with-timeout.sh
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "with-timeout-test: $*" >&2; exit 1; }

out=$(bash "$w" 5 sh -c 'echo said; exit 0') || fail "a command that ended at once: exit $?"
[ "$out" = said ] || fail "its output: '$out'"
# (and says nothing of its own: the limit's watcher stopped quietly, however soon the command ended)
for _ in 1 2 3 4 5 6 7 8 9 10; do
  err=$(bash "$w" 5 true 2>&1) || fail "true: exit $?"
  [ -z "$err" ] || fail "a command that ended in time, said: $err"
done
bash "$w" 5 sh -c 'exit 7'
[ $? = 7 ] || fail "a command's own status was not passed on"
bash "$w" "@$(( $(date +%s) + 5 ))" true || fail "an end time 5 s on: exit $?"

# (stopped at its limit, its child (a sleep of its own) and grandchild with it, not at the command's own end)
t0=$(date +%s)
bash "$w" 2 sh -c "sleep 30 & echo \$! > '$t/child'; sh -c 'echo \$\$ > \"$t/grandchild\"; sleep 30' & sleep 30"
code=$?
took=$(( $(date +%s) - t0 ))
[ $code = 124 ] || fail "out of time: exit $code, not 124"
[ $took -ge 2 ] && [ $took -le 10 ] || fail "out of time after $took s, its limit 2"
for f in child grandchild; do
  p=$(cat "$t/$f")
  ! kill -0 "$p" 2>/dev/null || fail "its $f ($p) still running"
done

# (one that will not end on TERM is killed)
t0=$(date +%s)
bash "$w" 1 bash -c 'trap "" TERM; sleep 30'
code=$?
took=$(( $(date +%s) - t0 ))
[ $code = 124 ] || fail "deaf to TERM: exit $code"
[ $took -le 12 ] || fail "deaf to TERM: stopped after $took s"

# (an end gone by: nothing run)
bash "$w" "@$(( $(date +%s) - 1 ))" touch "$t/ran" 2>/dev/null
[ $? = 124 ] || fail "an end gone by: not 124"
[ ! -e "$t/ran" ] || fail "an end gone by: the command ran"

# (a command that ends in time leaves nothing of the limit's running)
bash "$w" 37 true
! pgrep -fx "sleep 37" > /dev/null || fail "its sleep left running"
echo "with-timeout-test: ok"
