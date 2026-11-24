#!/bin/bash
# Exercise the background build's ordering and failures without building an app or touching the real cache.
set -eu
script=$(cd "$(dirname "$0")" && pwd)/mac-release-prebuild.sh
app_mac=$(cd "$(dirname "$0")/.." && pwd)/apps/mbui/scripts/mac.sh
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
case_dir() {
  export GITHUB_WORKSPACE="$root/$1/work" RUNNER_TEMP="$root/$1/temp" RUNNER_TOOL_CACHE="$root/$1/tools"
  mkdir -p "$GITHUB_WORKSPACE/apps/mbui/scripts" "$GITHUB_WORKSPACE/libs/ui/scripts" \
    "$GITHUB_WORKSPACE/apps/mbui/_build" "$RUNNER_TEMP" "$RUNNER_TOOL_CACHE"
  cat > "$GITHUB_WORKSPACE/apps/mbui/scripts/env.sh" <<'EOF'
A="$GITHUB_WORKSPACE/apps/mbui"
MBUI_DIR="$GITHUB_WORKSPACE/libs/ui"
export A MBUI_DIR
EOF
  cat > "$GITHUB_WORKSPACE/apps/mbui/scripts/core.sh" <<'EOF'
#!/bin/bash
set -eu
[ "$MACOSX_DEPLOYMENT_TARGET" = 12.0 ]
[ "$CARGO_TARGET_DIR" = "$GITHUB_WORKSPACE/apps/mbui/out/core-target-macos12.0" ]
case "$*" in
  'apple-native aarch64-apple-darwin')
    echo called >> "$RUNNER_TEMP/apple-native-calls"
    [ "${FAIL_CORE:-0}" = 0 ] || exit 7
    mkdir -p "$GITHUB_WORKSPACE/apps/mbui/out/core"
    if [ ! -e "$RUNNER_TEMP/core-finished" ]; then
      touch "$RUNNER_TEMP/core-finished"
      [ ! -p "$RUNNER_TEMP/core-signal" ] || printf 'ready\n' > "$RUNNER_TEMP/core-signal"
    fi
    ;;
  'hermes apple')
    [ ! -e "$RUNNER_TEMP/mac-prebuild/packages-pending" ] || exit 11
    [ "${FAIL_HBC:-0}" = 0 ] || exit 9
    touch "$RUNNER_TEMP/bytecode-built"
    ;;
  *) exit 10 ;;
esac
EOF
  cp "$app_mac" "$GITHUB_WORKSPACE/apps/mbui/scripts/mac.sh"
  cat > "$GITHUB_WORKSPACE/libs/ui/scripts/chk" <<'EOF'
#!/bin/bash
[ "$1" = logwait ] && [ "$2" = --gone ] || exit 12
while [ -e "$3" ]; do sleep 0.1; done
EOF
  chmod +x "$GITHUB_WORKSPACE/libs/ui/scripts/chk"
  cat > "$GITHUB_WORKSPACE/libs/ui/scripts/mac.sh" <<'EOF'
#!/bin/bash
set -eu
[ "$*" = build ]
[ "$APP" = stillfail ] && [ "$MODE" = release ]
[ "$MOON_HOME" = "$RUNNER_TOOL_CACHE/moon-ci" ]
touch "$RUNNER_TEMP/app-built"
[ "${FAIL_APP:-0}" = 0 ] || exit 8
[ "${SAY_NEWER:-0}" = 0 ] || echo "ld: warning: object file (x.o) was built for newer macOS version (15.0) than being linked (12.0)"
# (the app, with libghostty-vt's calls unless NO_GHOSTTY: the app's mac.sh fails one without them)
exe="$A/_build/native/release/build/stillfail/stillfail/stillfail.exe"
mkdir -p "$(dirname "$exe")"
if [ "${NO_GHOSTTY:-0}" = 0 ]; then c='int ghostty_terminal_new(void) { return 0; } int main(void) { return 0; }'; else c='int main(void) { return 0; }'; fi
printf '%s\n' "$c" | cc -x c - -o "$exe"
EOF
}
case_dir exit_race
mkdir -p "$RUNNER_TEMP/mac-prebuild"
printf '99999999\n' > "$RUNNER_TEMP/mac-prebuild/pid"
: > "$RUNNER_TEMP/mac-prebuild/log"
# The worker can write its result and exit after wait checks the file but before it probes the PID.
kill() {
  [ "$1" = -0 ] && [ "$2" = 99999999 ] || return 2
  printf '0\n' > "$RUNNER_TEMP/mac-prebuild/status"
  return 1
}
export -f kill
bash "$script" wait
unset -f kill

case_dir dead_worker
mkdir -p "$RUNNER_TEMP/mac-prebuild"
printf '99999999\n' > "$RUNNER_TEMP/mac-prebuild/pid"
: > "$RUNNER_TEMP/mac-prebuild/log"
if bash "$script" wait; then echo 'a worker that exited without a result was not reported' >&2; exit 1; fi

case_dir order
echo 12.0 > "$GITHUB_WORKSPACE/apps/mbui/_build/.macos-min"
mkfifo "$RUNNER_TEMP/core-signal"
bash "$script" start
read -r ready < "$RUNNER_TEMP/core-signal"
[ "$ready" = ready ]
[ -f "$RUNNER_TEMP/core-finished" ] && [ ! -e "$RUNNER_TEMP/app-built" ]
bash "$script" ready
bash "$script" packages
bash "$script" wait > "$root/order.out"
grep -Eq '^Mac prebuild: apple-native in [0-9]+ s$' "$root/order.out" || { echo "the core native parts' time was not said" >&2; exit 1; }
[ -f "$RUNNER_TEMP/app-built" ]
[ -f "$RUNNER_TEMP/bytecode-built" ] || { echo 'core bytecode was not prepared before packaging' >&2; exit 1; }
[ -f "$RUNNER_TEMP/mac-prebuild/built" ] || { echo 'a whole build did not say built (MBUI_BUILT)' >&2; exit 1; }
[ "$(wc -l < "$RUNNER_TEMP/apple-native-calls" | tr -d ' ')" = 1 ] || { echo 'the core native parts were made more than once' >&2; exit 1; }

# The app is linked again when the native parts it links changed, told by what they are made of ($exe.native-libs),
# not by the engine's mtime, which a fresh runner's build always makes newer than the app restored from the cache.
case_dir relink
echo 12.0 > "$GITHUB_WORKSPACE/apps/mbui/_build/.macos-min"
A="$GITHUB_WORKSPACE/apps/mbui"
o="$A/out/core/aarch64-apple-darwin"
exe="$A/_build/native/release/build/stillfail/stillfail/stillfail.exe"
mkdir -p "$o" "$A/src/host" "$A/src/stillfail" "$(dirname "$exe")" "$root/relink-bin"
# (the app restored is one linked with Hermes, as CI's)
printf '#!/bin/sh\necho "\t@rpath/hermes.framework/Versions/0/hermes"\n' > "$root/relink-bin/otool"
chmod +x "$root/relink-bin/otool"
saved_path=$PATH
export PATH="$root/relink-bin:$PATH"
echo 'engine one' > "$A/src/host/apple_core.mm"
echo 'shell one' > "$o/libstillfail_shell.a"
printf '%s\n' 'int ghostty_terminal_new(void) { return 0; } int main(void) { return 0; }' | cc -x c - -o "$exe"
touch -t 202001010000 "$exe"
build_relink() {
  touch -t 200001010000 "$A/src/stillfail/core_engine.m"
  # (the engine made again, newer than the app)
  echo "engine archive $1" > "$o/libmbui_core.a"
  bash "$script" start
  bash "$script" ready
  bash "$script" packages
  bash "$script" wait > /dev/null
}
relinked() { [ "$A/src/stillfail/core_engine.m" -nt "$root/relink-bin/otool" ]; }
touch -t 200101010000 "$root/relink-bin/otool"
# (an app with no mark: the engine's mtime decides, as before)
build_relink 1
relinked || { echo 'an app older than its engine, with no mark, was not linked again' >&2; exit 1; }
[ -s "$exe.native-libs" ] || { echo 'the app built kept no mark of its native parts' >&2; exit 1; }
first=$(cat "$exe.native-libs")
build_relink 2
! relinked || { echo 'the app was linked again for an engine made again of the same sources' >&2; exit 1; }
[ "$(cat "$exe.native-libs")" = "$first" ] || { echo 'the mark changed with nothing changed' >&2; exit 1; }
echo 'engine two' > "$A/src/host/apple_core.mm"
build_relink 3
relinked || { echo "the app was not linked again for the engine's source changed" >&2; exit 1; }
second=$(cat "$exe.native-libs")
[ "$second" != "$first" ] || { echo "the mark did not follow the engine's source" >&2; exit 1; }
echo 'shell two' > "$o/libstillfail_shell.a"
build_relink 4
relinked || { echo "the app was not linked again for the shell's archive changed" >&2; exit 1; }
[ "$(cat "$exe.native-libs")" != "$second" ] || { echo "the mark did not follow the shell's archive" >&2; exit 1; }
[ "$(wc -l < "$RUNNER_TEMP/apple-native-calls" | tr -d ' ')" = 4 ] || { echo 'the core native parts were made more than once a build' >&2; exit 1; }
export PATH=$saved_path
unset A o exe saved_path first second

# No Moon build for this macOS restored (none, or another's): what was built for another goes, the marker is written,
# the core just built is kept, and the app is built here all the same.
for before in none 11.0; do
  case_dir "uncached-$before"
  mkdir -p "$GITHUB_WORKSPACE/apps/mbui/out/mbc"
  touch "$GITHUB_WORKSPACE/apps/mbui/_build/old-unit" "$GITHUB_WORKSPACE/apps/mbui/out/mbc/old-object"
  [ "$before" = none ] || echo "$before" > "$GITHUB_WORKSPACE/apps/mbui/_build/.macos-min"
  bash "$script" start
  bash "$script" ready
  bash "$script" packages
  bash "$script" wait
  [ "$(cat "$GITHUB_WORKSPACE/apps/mbui/_build/.macos-min")" = 12.0 ] || { echo "uncached-$before: no marker for 12.0" >&2; exit 1; }
  [ ! -e "$GITHUB_WORKSPACE/apps/mbui/_build/old-unit" ] && [ ! -e "$GITHUB_WORKSPACE/apps/mbui/out/mbc/old-object" ] || { echo "uncached-$before: another macOS's build kept" >&2; exit 1; }
  [ -d "$GITHUB_WORKSPACE/apps/mbui/out/core" ] && [ -f "$RUNNER_TEMP/core-finished" ] || { echo "uncached-$before: the core built was taken away" >&2; exit 1; }
  [ -f "$RUNNER_TEMP/app-built" ] && [ -f "$RUNNER_TEMP/bytecode-built" ] || { echo "uncached-$before: the app was not built" >&2; exit 1; }
done

case_dir core_failure
export FAIL_CORE=1
bash "$script" start
if bash "$script" wait; then echo 'native failure was not reported' >&2; exit 1; fi
unset FAIL_CORE

case_dir app_failure
echo 12.0 > "$GITHUB_WORKSPACE/apps/mbui/_build/.macos-min"
export FAIL_APP=1
bash "$script" start
bash "$script" ready
bash "$script" packages
if bash "$script" wait; then echo 'app failure was not reported' >&2; exit 1; fi
[ ! -e "$RUNNER_TEMP/mac-prebuild/built" ] || { echo 'a failed build said built' >&2; exit 1; }
unset FAIL_APP

case_dir newer_macos
echo 12.0 > "$GITHUB_WORKSPACE/apps/mbui/_build/.macos-min"
export SAY_NEWER=1
bash "$script" start
bash "$script" ready
bash "$script" packages
if bash "$script" wait; then echo 'a build for a newer macOS was not reported' >&2; exit 1; fi
[ ! -e "$RUNNER_TEMP/mac-prebuild/built" ] || { echo 'a build for a newer macOS said built' >&2; exit 1; }
unset SAY_NEWER

case_dir no_terminal
echo 12.0 > "$GITHUB_WORKSPACE/apps/mbui/_build/.macos-min"
export NO_GHOSTTY=1
bash "$script" start
bash "$script" ready
bash "$script" packages
if bash "$script" wait; then echo 'an app without libghostty-vt was not reported' >&2; exit 1; fi
unset NO_GHOSTTY

case_dir bytecode_failure
echo 12.0 > "$GITHUB_WORKSPACE/apps/mbui/_build/.macos-min"
export FAIL_HBC=1
bash "$script" start
bash "$script" ready
bash "$script" packages
if bash "$script" wait; then echo 'bytecode failure was not reported' >&2; exit 1; fi
unset FAIL_HBC
echo 'Mac prebuild ordering and failure handling passed'
