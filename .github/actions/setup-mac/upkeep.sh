#!/bin/sh
# Disk cleanup for persistent self-hosted runners on macos-ci (Mini1).
# Removes stale MoonBit cache units, native cache versions over budget, old runner logs, timed-out temp directories,
# old Xcode and Homebrew caches, and Shutdown iOS Simulator wallpaper caches.
# setup-mac and the mbui-moonbit action run it once an hour, or at each job start below 15 GiB free.
# Mini1 ran out of space in a burst of merges (ENOSPC, 44253499545 and 44252522547, 2026-11-18).
#   upkeep.sh [checkout]      (default: the current directory; its scripts/native.ts trims the native cache)
set -u
checkout=${1:-.}
echo "disk before upkeep: $(df -h / | awk 'NR==2 {print $4 " free of " $2}')"

# Old Cargo targets (target-*, check-*, linux-*): no job reads them now.
find "$HOME/stillfail-ci" -mindepth 1 -maxdepth 1 -type d \( -name 'target*' -o -name 'check-*' -o -name 'linux*' \) -mmin +240 -exec rm -rf {} + 2>/dev/null || true

# station/mb/build.sh writes compiled MoonBit units to ~/stillfail-ci/reader-mbc-store.
# libs/ui/tools/mbc/mbc.mbt touches each unit directory on use. Delete units unused for 12 hours.
if [ -d "$HOME/stillfail-ci/reader-mbc-store" ]; then
  find "$HOME/stillfail-ci/reader-mbc-store" -name '*.lock' -mmin +120 -delete 2>/dev/null || true
  find "$HOME/stillfail-ci/reader-mbc-store" -mindepth 2 -maxdepth 2 -type d -mmin +720 -exec rm -rf {} + 2>/dev/null || true
fi
# station/mb/build.sh shares each reader's prepared C (~120 MB) among this machine's runners in
# ~/stillfail-ci/reader-mbc-prepped, touched on use. Delete those unused for 3 hours, and locks and partial writes
# left for 30 minutes.
if [ -d "$HOME/stillfail-ci/reader-mbc-prepped" ]; then
  find "$HOME/stillfail-ci/reader-mbc-prepped" -maxdepth 1 \( -name '*.lock' -o -name '*.tmp.*' \) -mmin +30 -exec rm -rf {} + 2>/dev/null || true
  find "$HOME/stillfail-ci/reader-mbc-prepped" -maxdepth 1 -type f -name 'prepped-*.c' -mmin +180 -delete 2>/dev/null || true
fi

# The native cache (scripts/native.ts). Delete the .tmp-<pid>-* directories of processes that are gone, after 30
# minutes. Then trim the versions over STILLFAIL_NATIVE_CACHE_MAX_BYTES (native.ts trim: only versions unused for 15
# minutes or more).
find "$HOME/Library/Caches/stillfail-native" -mindepth 2 -maxdepth 2 -type d -name '.tmp-*' -mmin +30 2>/dev/null |
  while IFS= read -r tmp; do
    pid=$(basename "$tmp" | sed -n 's/^\.tmp-\([0-9][0-9]*\)-.*/\1/p')
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then continue; fi
    rm -rf "$tmp" 2>/dev/null || true
  done
if [ -f "$checkout/scripts/native.ts" ]; then
  node="$(sh "$checkout/scripts/node-here.sh" 2>/dev/null)/node"
  if [ -x "$node" ]; then
    STILLFAIL_NATIVE_CACHE_MAX_BYTES=${STILLFAIL_NATIVE_CACHE_MAX_BYTES:-5368709120} "$node" "$checkout/scripts/native.ts" trim || true
  fi
fi

# Delete Xcode builds, Homebrew downloads and simulator logs untouched for a day. Delete a directory only when nothing
# in it changed in the last hour: a build keeps its directory's mtime while files under it change.
for top in "$HOME/Library/Developer/Xcode/DerivedData" "$HOME/Library/Caches/Homebrew/downloads" "$HOME/Library/Logs/CoreSimulator"; do
  [ -d "$top" ] || continue
  find "$top" -mindepth 1 -maxdepth 1 -mtime +1 2>/dev/null |
    while IFS= read -r old; do
      [ -z "$(find "$old" -mmin -60 -print 2>/dev/null | head -n 1)" ] || continue
      rm -rf "$old" 2>/dev/null || true
    done
done

# Delete closed Worker_*.log files after 1 day and older runner diagnostic logs after 3 days.
for diag in "$HOME"/actions-runner*/_diag; do
  [ -d "$diag" ] || continue
  find "$diag" -maxdepth 1 -type f -name 'Worker_*.log' -mtime +1 -delete 2>/dev/null || true
  find "$diag" -maxdepth 2 -type f -mtime +3 -delete 2>/dev/null || true
done

# Delete temp directories left behind when a CI job hits its timeout.
find "${TMPDIR:-/tmp}" -mindepth 1 -maxdepth 1 \( \
  -name 'selfhost-side-*' -o \
  -name 'release-delta-old-*' -o \
  -name 'stillfail-native-*' -o \
  -name 'stillfail-prebuild-*' -o \
  -name 'stillfail-store-sync-*' -o \
  -name 'download-artifact.*' \
\) -mmin +240 -exec rm -rf {} + 2>/dev/null || true

# Delete CoreSimulator temp directories whose simulator UUID no longer exists.
devs="$HOME/Library/Developer/CoreSimulator/Devices"
for simtmp in /private/var/tmp/com.apple.CoreSimulator.SimDevice.*; do
  [ -d "$simtmp" ] || continue
  [ -n "$(find "$simtmp" -maxdepth 0 -mmin +240 2>/dev/null)" ] || continue
  uuid=${simtmp##*.SimDevice.}
  if [ ! -d "$devs/$uuid" ]; then
    rm -rf "$simtmp" 2>/dev/null || true
  fi
done

# Delete unavailable simulator devices and PosterBoard wallpaper caches on Shutdown devices (state == 1).
# Skip without waiting if an iOS test holds ~/.mbui-ios-sim.lock.
lock=${MBUI_IOS_LOCK:-$HOME/.mbui-ios-sim.lock}
if mkdir "$lock" 2>/dev/null; then
  (
    trap 'rm -rf "$lock" 2>/dev/null || true' EXIT INT TERM
    printf 'setup-mac upkeep\npid %s\n' "$$" > "$lock/owner" 2>/dev/null || true
    xcrun simctl delete unavailable >/dev/null 2>&1 || true
    for dev in "$devs"/*; do
      [ -f "$dev/device.plist" ] || continue
      state=$(plutil -extract state raw -o - "$dev/device.plist" 2>/dev/null || true)
      [ "$state" = 1 ] || continue
      rm -rf "$dev/data/Library/Application Support/PRBPosterExtensionDataStore" \
             "$dev/data/Library/Application Support/com.apple.PosterKit/trash" 2>/dev/null || true
    done
  )
fi

echo "disk after upkeep: $(df -h / | awk 'NR==2 {print $4 " free of " $2}')"
