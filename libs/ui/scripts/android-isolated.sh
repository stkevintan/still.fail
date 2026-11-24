#!/bin/bash
# An APK run on an emulator of its own, on a machine whose other runs have theirs at the same time: a free port of
# 5600-5780 taken (none adb lists, none listened on, and claimed by a lock no live run holds), the AVD started on it
# read-only (-read-only: several runs of one AVD, none writing its files or a snapshot) and with no window, the APK
# installed, the app started, and at the end, however the run ends, that emulator alone stopped (`emu kill` on its port).
#   scripts/android-isolated.sh --apk FILE [--avd NAME] [--app-id ID] [--activity CLASS] [--env "K=V;K2=V2"]
#     [--script NAME] [--shot-at MS] [--deadline S] [-- COMMAND...]
# --avd: the AVD (default $AVD, else the machine's first, `emulator -list-avds`); --app-id: the APK's package (default
# MBUI_APP_ID, else dev.mbui.demo); --activity: what is started (default dev.mbui.MainActivity); --env, --script: the
# test hooks' (the intent's env and script, opened with debug.mbui.hooks 1). The app is ready once its window is the
# one shown (scripts/android.sh shown), or with --shot-at once its frame of that moment is drawn ("SHOT n t", as
# scripts/android-launch.sh); its crash first (FATAL EXCEPTION, its process's Fatal signal) fails the run. COMMAND then
# runs with EMU_PORT and ANDROID_SERIAL saying the emulator (scripts/android.sh's commands take EMU_PORT: record, log,
# put…), its end the run's, failed too where the app crashed meanwhile. Each wait is for its event, --deadline (default
# 600 s) only what a hung one is given before it fails. The emulator's log and logcat: out/android/isolated/<port>/.
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
SDK=${ANDROID_HOME:-$HOME/Library/Android/sdk}
ADB=$SDK/platform-tools/adb
EMU=$SDK/emulator/emulator
usage() { sed -n '6,7p' "$0" | sed 's/^# *//' >&2; exit 2; }
APK= AVD_NAME=${AVD:-} APP_ID=${MBUI_APP_ID:-dev.mbui.demo} ACTIVITY=dev.mbui.MainActivity HOOK_ENV= SCRIPT= SHOT=
DEADLINE=600
while [ "$#" -gt 0 ]; do
  case $1 in
    --apk) APK=${2:-} ; shift 2 ;;
    --avd) AVD_NAME=${2:-} ; shift 2 ;;
    --app-id) APP_ID=${2:-} ; shift 2 ;;
    --activity) ACTIVITY=${2:-} ; shift 2 ;;
    --env) HOOK_ENV=${2:-} ; shift 2 ;;
    --script) SCRIPT=${2:-} ; shift 2 ;;
    --shot-at) SHOT=${2:-} ; shift 2 ;;
    --deadline) DEADLINE=${2:-} ; shift 2 ;;
    -h | --help) usage ;;
    --) shift; break ;;
    *) echo "android-isolated: no option $1" >&2; usage ;;
  esac
done
[ -n "$APK" ] && [ -f "$APK" ] || { echo "android-isolated: --apk FILE, an APK built (scripts/android.sh build)" >&2; exit 2; }
[ -z "$SHOT" ] || [[ $SHOT =~ ^[0-9]+$ ]] || { echo "android-isolated: --shot-at is a moment in ms" >&2; exit 2; }
[ -x "$ADB" ] && [ -x "$EMU" ] || { echo "android-isolated: no Android SDK at $SDK (ANDROID_HOME)" >&2; exit 2; }
[ -n "$AVD_NAME" ] || AVD_NAME=$("$EMU" -list-avds 2>/dev/null | grep -v '^INFO' | head -1)
"$EMU" -list-avds 2>/dev/null | grep -qx -- "$AVD_NAME" \
  || { echo "android-isolated: no AVD ${AVD_NAME:-at all} on this machine (scripts/android.sh emu makes mbui-avd)" >&2; exit 2; }

# A port: even (the emulator takes it and the next for its console and adb), not one adb lists, nothing listening on
# either, and its lock taken (mkdir: one run gets it). A lock whose run has ended (its pid gone) is taken over.
LOCKS=/tmp/mbui-emu-ports
mkdir -p "$LOCKS" 2>/dev/null; chmod 1777 "$LOCKS" 2>/dev/null || true
listed=$("$ADB" devices 2>/dev/null | awk '/^emulator-/ { sub("emulator-", "", $1); print $1 }')
PORT=
for p in $(seq 5600 2 5780); do
  echo "$listed" | grep -qx "$p" && continue
  nc -z 127.0.0.1 "$p" 2>/dev/null && continue
  nc -z 127.0.0.1 $((p + 1)) 2>/dev/null && continue
  if ! mkdir "$LOCKS/$p" 2>/dev/null; then
    held=$(cat "$LOCKS/$p/pid" 2>/dev/null || true)
    { [ -n "$held" ] && kill -0 "$held" 2>/dev/null; } && continue
    rm -rf "$LOCKS/$p"
    mkdir "$LOCKS/$p" 2>/dev/null || continue
  fi
  echo $$ > "$LOCKS/$p/pid"
  PORT=$p
  break
done
[ -n "$PORT" ] || { echo "android-isolated: no free port in 5600-5780" >&2; exit 1; }
SERIAL=emulator-$PORT
O=out/android/isolated/$PORT
rm -rf "$O" && mkdir -p "$O"
O=$(cd "$O" && pwd)
EPID=
LOGPIDS=()

# The end, however it comes: this port's emulator alone told to stop (its console's kill) and waited for (its
# process's end: scripts/chk logwait), the one this run started ended by its pid where its console never came up, the
# loggers this run started ended, the port let go.
stop() {
  local code=$?
  trap - EXIT INT TERM
  for p in ${LOGPIDS[@]+"${LOGPIDS[@]}"}; do kill "$p" 2>/dev/null || true; done
  if [ -n "$EPID" ] && kill -0 "$EPID" 2>/dev/null; then
    "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || kill "$EPID" 2>/dev/null || true
    "$D/chk" logwait --pid "$EPID" --deadline 120 >/dev/null 2>&1 || kill -9 "$EPID" 2>/dev/null || true
  fi
  rm -rf "${LOCKS:?}/$PORT"
  echo "android-isolated: $SERIAL stopped" >&2
  exit "$code"
}
trap stop EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "android-isolated: $AVD_NAME on $SERIAL"
"$EMU" -avd "$AVD_NAME" -port "$PORT" -read-only -no-window -no-audio -no-boot-anim -no-snapshot \
  -gpu swiftshader_indirect ${EMU_FLAGS:-} > "$O/emulator.log" 2>&1 &
EPID=$!

# Booted: init's own word as the system sets sys.boot_completed, read from the log of the boot's start (logcat -b all
# reads what is there, then waits; -m 1 its first such line), or the emulator's end first.
"$ADB" -s "$SERIAL" wait-for-device logcat -b all -v brief -m 1 -e 'processing action \(sys\.boot_completed=1' \
  > "$O/boot.log" 2>&1 &
LOGPIDS+=($!)
"$D/chk" logwait --log "$O/boot.log" --line 'boot_completed' --pid "$EPID" --deadline "$DEADLINE" >/dev/null || {
  echo "android-isolated: $SERIAL did not boot (its log: $O/emulator.log)" >&2
  tail -20 "$O/emulator.log" >&2
  exit 1
}
[ "$("$ADB" -s "$SERIAL" shell getprop sys.boot_completed | tr -d '\r')" = 1 ] \
  || { echo "android-isolated: $SERIAL said boot_completed, but its property is not set" >&2; exit 1; }
echo "android-isolated: $SERIAL booted (Android $("$ADB" -s "$SERIAL" shell getprop ro.build.version.release | tr -d '\r'))"

"$ADB" -s "$SERIAL" shell setprop debug.mbui.hooks 1
"$ADB" -s "$SERIAL" install -r "$APK" > "$O/install.log" 2>&1 \
  || { cat "$O/install.log" >&2; echo "android-isolated: $APK not installed" >&2; exit 1; }
UID_=$("$ADB" -s "$SERIAL" shell pm list packages -U "$APP_ID" | tr -d '\r' | sed -n "s/^package:$APP_ID uid:\([0-9]*\).*/\1/p")
[ -n "$UID_" ] || { echo "android-isolated: $APP_ID is not what $APK installed (--app-id)" >&2; exit 1; }

# The app's log from its start on, kept whole for the crash's check and for people: out/…/logcat.txt
"$ADB" -s "$SERIAL" logcat -c
"$ADB" -s "$SERIAL" logcat -v brief > "$O/logcat.txt" 2>&1 &
LOGPIDS+=($!)
CRASH="FATAL EXCEPTION|Fatal signal .*pid [0-9]+ \\(${APP_ID//./\\.}"
"$ADB" -s "$SERIAL" shell am start -W -n "$APP_ID/$ACTIVITY" ${HOOK_ENV:+--es env "'$HOOK_ENV'"} \
  ${SCRIPT:+--es script "$SCRIPT"} ${SHOT:+--ei shot_at "$SHOT"} > "$O/start.log" 2>&1
grep -q '^Status: ok' "$O/start.log" || { cat "$O/start.log" >&2; echo "android-isolated: $APP_ID/$ACTIVITY not started" >&2; exit 1; }

if [ -n "$SHOT" ]; then
  said=$("$D/chk" logwait --log "$O/logcat.txt" --line "SHOT [0-9]+ [0-9]|$CRASH" --pid "$EPID" --deadline "$DEADLINE") || {
    echo "android-isolated: no frame at $SHOT ms on $SERIAL" >&2; exit 1; }
else
  ready_log=$O/shown.log
  EMU_PORT=$PORT MBUI_APP_ID=$APP_ID ANDROID_HOME=$SDK bash "$D/android.sh" shown > "$ready_log" 2>&1 &
  SHOWN=$!
  # (shown's end, or the app's crash first)
  "$D/chk" logwait --log "$O/logcat.txt" --line "$CRASH" --pid "$SHOWN" --deadline "$DEADLINE" > "$O/crash-first.txt"
  case $? in
    0) said=$(cat "$O/crash-first.txt"); kill "$SHOWN" 2>/dev/null || true ;;
    1) wait "$SHOWN" || { cat "$ready_log" >&2; exit 1; }; said=$(tail -1 "$ready_log") ;;
    *) kill "$SHOWN" 2>/dev/null || true; echo "android-isolated: $APP_ID not shown in $DEADLINE s" >&2; exit 1 ;;
  esac
fi
if echo "$said" | grep -qE "$CRASH"; then
  echo "::error::$APP_ID crashed as it started on $SERIAL" >&2
  grep -a -E "FATAL|Fatal signal|Abort message|AndroidRuntime|JNI DETECTED" "$O/logcat.txt" | head -40 >&2
  exit 1
fi
echo "android-isolated: ready ($said)"

code=0
if [ "$#" -gt 0 ]; then
  EMU_PORT=$PORT ANDROID_SERIAL=$SERIAL "$@" || code=$?
fi
# a crash of the app while it ran on, or its process's native end (a tombstone), is the run's failure
if grep -a -qE "$CRASH" "$O/logcat.txt"; then
  echo "::error::$APP_ID crashed on $SERIAL" >&2
  grep -a -E "FATAL|Fatal signal|Abort message|AndroidRuntime|JNI DETECTED" "$O/logcat.txt" | head -40 >&2
  [ "$code" != 0 ] || code=1
fi
exit "$code"
