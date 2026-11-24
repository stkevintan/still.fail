#!/bin/bash
# The desktop job's native parts, Moon build and core bytecode, started while it restores what they do not need.
# `ready` means the Moon toolchain and _build cache have been restored and source mtimes set; `packages` that the job's
# pnpm install is over, the core's bytecode's own install waiting for it (one store, two installs at once lost files:
# its pending file, made at the start, taken away). `wait` reports failures
# before the usual release script signs or publishes anything; that script still does its own up-to-date build.
set -eu
dir="$RUNNER_TEMP/mac-prebuild"
case "${1:-}" in
  start)
    mkdir -p "$dir"
    rm -f "$dir/built"
    # the PostHog project the core sends what people use to (scripts/core.sh posthog_define): the file the bundling
    # step writes too, the same, so that core.hbc made here is the one it takes
    if [ -n "${POSTHOG_JSON:-}" ]; then
      (umask 077 && printf '%s' "$POSTHOG_JSON" > "$RUNNER_TEMP/posthog.json")
      export STILLFAIL_POSTHOG="$RUNNER_TEMP/posthog.json"
    fi
    unset POSTHOG_JSON
    rm -f "$dir/store-pending.failed" "$dir/status"
    : > "$dir/packages-pending"
    : > "$dir/store-pending"
    export MBC_STORE_WAIT="$dir/store-pending"
    nohup bash "$0" work > "$dir/log" 2>&1 < /dev/null &
    echo "$!" > "$dir/pid"
    ;;
  ready)
    touch "$dir/ready"
    ;;
  store)
    rm -f "$dir/store-pending"
    ;;
  packages)
    rm -f "$dir/packages-pending"
    ;;
  wait)
    while [ ! -s "$dir/status" ]; do
      if ! kill -0 "$(cat "$dir/pid")" 2>/dev/null; then
        # The worker may have written its result after the loop's check and then exited.
        [ ! -s "$dir/status" ] || break
        cat "$dir/log"
        echo 'Mac prebuild exited without reporting its result' >&2
        exit 1
      fi
      sleep 1
    done
    cat "$dir/log"
    [ "$(cat "$dir/status")" = 0 ] || exit 1
    ;;
  stop)
    # (the build cut short by the Finish step's own limit: the worker and all it started end before the store is keyed
    # and saved, so that nothing writes units while they are packed)
    tree() { for c in $(pgrep -P "$1" 2>/dev/null); do tree "$c"; done; echo "$1"; }
    [ -s "$dir/pid" ] || exit 0
    pids=$(tree "$(cat "$dir/pid")")
    # shellcheck disable=SC2086 # pids, one word each
    kill -TERM $pids 2>/dev/null || :
    for _ in 1 2 3 4 5; do kill -0 "$(cat "$dir/pid")" 2>/dev/null || break; sleep 1; done
    # shellcheck disable=SC2086
    kill -KILL $pids 2>/dev/null || :
    # (and, on GitHub's own VM alone, the compilers that left the worker's tree: a parent gone, they were nobody's
    # child to find, and wrote units on while the store was keyed and packed. Never by name on a machine of ours, whose
    # other runners' and sessions' compilers are theirs)
    if [ "${RUNNER_ENVIRONMENT:-}" = github-hosted ]; then
      left=$(pgrep -x 'moon|moonc|mbc|mbc.exe|clang|clang\+\+|clang-[0-9]+' 2>/dev/null || true)
      # shellcheck disable=SC2086
      [ -z "$left" ] || kill -KILL $left 2>/dev/null || :
    fi
    ;;
  work)
    set +e
    bash "$0" build
    result=$?
    printf '%s\n' "$result" > "$dir/status.tmp"
    mv "$dir/status.tmp" "$dir/status"
    exit "$result"
    ;;
  build)
    cd "$GITHUB_WORKSPACE"
    . apps/mbui/scripts/env.sh
    export MACOSX_DEPLOYMENT_TARGET=12.0
    export CARGO_TARGET_DIR="$A/out/core-target-macos$MACOSX_DEPLOYMENT_TARGET"
    t0=$SECONDS
    bash "$A/scripts/core.sh" apple-native aarch64-apple-darwin
    echo "Mac prebuild: apple-native in $((SECONDS - t0)) s"
    # (made: the app's mac.sh does not make them again, and says itself whether the app is linked again)
    export MBUI_APPLE_NATIVE_READY=1
    while [ ! -f "$dir/ready" ]; do sleep 1; done
    # What was built for another macOS (moon's and mbc's objects) goes, as mac-app.sh would have it go, and the marker is
    # written so that it does not: the core just built for this one (out/core/aarch64-apple-darwin) is kept. Left to
    # mac-app.sh, with no Moon build restored the prebuild gave up, mac-app.sh took the core away and built it all again
    # in the bundling step alone, past the job's five minutes (#6955's 133961020901, main's 133951721953, 2026-11-17).
    if [ "$(cat "$A/_build/.macos-min" 2>/dev/null || :)" != "$MACOSX_DEPLOYMENT_TARGET" ]; then
      echo "Mac prebuild: no Moon build for macOS $MACOSX_DEPLOYMENT_TARGET restored; built here whole"
      rm -rf "$A/_build" "$A/out/mbc"
      mkdir -p "$A/_build"
      echo "$MACOSX_DEPLOYMENT_TARGET" > "$A/_build/.macos-min"
    fi
    export MOON_HOME="$RUNNER_TOOL_CACHE/moon-ci"
    export PATH="$MOON_HOME/bin:$PATH" APP=stillfail MODE=release MBUI_PACKAGES_PENDING="$dir/packages-pending"
    . apps/mbui/scripts/env.sh
    # The app's wrapper builds core.hbc beside the app. Leaving it until mac-app.sh bundled the app added 26 s after
    # the compile and let a successful build time out during cleanup (42588746155, 2026-11-09).
    # (built whole here, `built` says so: the bundling step takes it as it is, MBUI_BUILT, not running mac.sh again
    # (12-20 s that cut a build done at the job's five minutes, 133850663609, 2026-11-17); so the check mac-app.sh made of
    # its log is made here)
    set -o pipefail
    bash "$A/scripts/mac.sh" build 2>&1 | tee "$dir/build.log"
    if grep -q 'built for newer macOS version' "$dir/build.log"; then
      grep 'built for newer macOS version' "$dir/build.log" | head -5 >&2
      echo "Mac prebuild: something was built for a newer macOS than $MACOSX_DEPLOYMENT_TARGET" >&2
      exit 1
    fi
    touch "$dir/built"
    ;;
  *) echo "usage: $0 start|ready|store|packages|wait|stop" >&2; exit 2 ;;
esac
