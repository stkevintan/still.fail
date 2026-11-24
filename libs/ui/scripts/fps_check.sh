#!/bin/bash
# The Tester's tests at other frame rates: by default a test's run_for goes straight to its end (no frames between);
# here they run again with frames drawn on its way while the app asks for them, as a host draws them (MBUI_TEST_FPS:
# frames a second), at 60, 120, 24 and 7, and must come out the same: what a test asserts at a moment is what is so
# at that moment, however many frames came before it. Only run_for's way has them: what the test walks itself (its
# inputs, `frame()`) is on the display's frames as ever.
# FPS="…" for other rates; PKGS="…" for other packages (the Tester's: ui/view's own tests make their frames
# themselves, each at the moment it says).
# In CI on native as scripts/test_native.sh builds them (the same programs, their units kept); elsewhere on wasm-gc.
set -o pipefail
D="$(cd "$(dirname "$0")" && pwd)"
. "$D/env.sh"
cd "$D/.."
pkgs=${PKGS:-ui/ui ui/motion ui/kit ui/player ui/headless ui/kitdemo/gallery ui/effectdemo}
code=0
for fps in ${FPS:-60 120 24 7}; do
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    out=$(MBUI_TEST_FPS=$fps LINES_OUT=100000 bash "$D/test_native.sh" $pkgs 2>&1 | grep -av '^TDUMP')
  else
    args=()
    for p in $pkgs; do args+=(-p "$p"); done
    out=$(MBUI_TEST_FPS=$fps moon_tests "${args[@]}" 2>&1 | grep -av '^TDUMP')
  fi
  st=$?
  # (how what moves goes and each file's bars, said where the run says them (src/ui/tester_fps.mbt: motion_runs): kept
  # whole, out of what is shown)
  [ -z "${MOTION_OUT:-}" ] || echo "$out" | grep -a '^MOTION ' >> "$MOTION_OUT"
  out=$(echo "$out" | grep -av '^MOTION ')
  echo "$fps fps: $(echo "$out" | grep -a '^Total tests' | tail -1)"
  if [ $st != 0 ]; then
    # (what failed, and the words of what stopped the run with them (@halt.saying: its words, then the line said them,
    # "  at …mbt:…"), whatever they are: a Tester's check stopping a test on its own (sizes not steady) said no more than
    # the signal it ended on)
    # (and where none of that is in it, a build that failed or a tool not found: its last lines, as they are)
    said=$(echo "$out" | awk '
      /test .* failed|not built whole|takes no presses|Abort|exited with/ { print; prev = ""; next }
      /^  at [^ ]+\.mbt:[0-9]/ { if (prev != "") print prev; print; prev = ""; next }
      { prev = $0 }' | cut -c1-600 | head -40)
    if [ -n "$said" ]; then echo "$said"; else echo "$out" | tail -20 | cut -c1-600; fi
    code=1
  fi
done
exit $code
