#!/bin/bash
# still.fail preview on macOS as an app: out/mac/still.fail preview.app (fail.still.mbui; arm64, as still.fail's desktop app
# ships), its zip beside it. The app is APP=stillfail's release build (scripts/mac.sh) with what it carries: the core's
# bytecode (Resources/core.hbc, which the core host finds in the app: src/host/apple_core.mm) and Hermes
# (Frameworks/hermes.framework, React Native 0.81.4's, as Android's; scripts/core.sh hermes-apple), its icon
# (scripts/mac-icon.swift, its variant's), an Info.plist of its own. Signed with MAC_SIGN_IDENTITY (CI: still.fail's,
# imported by .github/mac_signing.py), else ad hoc; checked with codesign's strict verify. Signed with a Developer ID,
# it is notarized before it is zipped (mac_signing.py notarize): Gatekeeper lets it open downloaded. Its ticket is not
# stapled: stapling fetches it from Apple's CloudKit, whose connection from CI's Mac dropped in most of main's runs
# (Error 68, the app notarized), and nothing needs it there: a download is opened online (Gatekeeper asks Apple for the
# ticket then), and the app's own updates are not quarantined.
#   apps/mbui/scripts/mac-app.sh            build and bundle it, then sign it (below)
#   apps/mbui/scripts/mac-app.sh build      build and bundle it only (signed ad hoc)
#   apps/mbui/scripts/mac-app.sh sign       sign it (MAC_SIGN_IDENTITY, else ad hoc), check it, zip it:
#                                           out/mac/stillfail-mbui-<n>-arm64-mac.zip (CI: under .github/mac_signing.py,
#                                           which holds the signing lock only for this)
# The oldest macOS it runs on: still.fail's desktop app's (Electron's: 12.0), MACOSX_DEPLOYMENT_TARGET for clang and
# cargo alike, and its Info.plist's LSMinimumSystemVersion; an object built for a newer one fails the build.
# MBUI_BUILD: the build's number (default git rev-list --count HEAD of still.fail). The core's parts are scripts/core.sh
# apple's: the shell as still.fail's natives have it for its sources (shell-apple), the engine and core.hbc made when
# stale.
set -eo pipefail
# (a command that fails with nothing said, said by where it was: main 199e1d03's desktop stopped between the build and
# the signing with no word, 41399442984, 2026-11-02)
trap 'echo "mac-app.sh: line $LINENO failed ($?): $BASH_COMMAND" >&2' ERR
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$D/env.sh"
cd "$A"
now() { python3 -c 'import time;print(time.time())'; }
secs() { python3 -c "print(f'{$(now)-$1:.1f}')"; }
N=${MBUI_BUILD:-$(git -C "$SF_SRC" rev-list --count HEAD 2>/dev/null || echo 1)}
# MBUI_VARIANT, which app it is built as (as Android's apk.json variants are): preview (the default) still.fail preview, an app
# beside still.fail's desktop app (fail.still.mbui, its feed mac/mbui); stable and beta still.fail's desktop app itself,
# to take its place: Electron's ids, names and links (apps/desktop/package.json, build.sh), so that app's updater takes
# it and it keeps that app's data, sign-in and sealed keys where they were (src/sfcore/apple_engine.m, src/host/
# apple_core.mm electron_sealed); their feed mac (the beta's core asks mac/beta, as still.fail's beta builds do). The
# beta's core and still.fail preview's are a beta's (MBUI_BETA): builds of every commit, the test channel's.
VARIANT=${MBUI_VARIANT:-preview}
load_variant() {
  local meta MBUI_APP_ID MBUI_APP_NAME MBUI_EXECUTABLE MBUI_VERSION MBUI_BUILD MBUI_VARIANT \
    MBUI_RUNTIME MBUI_MODULE_DIR MBUI_ENTRY MBUI_SCHEMES MBUI_UPDATE_FEED MBUI_UPDATE_CHANNEL \
    MBUI_ENV_KV MBUI_MAC_MIN_VERSION MBUI_WIN_INSTALL_DIR MBUI_WIN_COMPANY
  # mbui meta builds tools/pack with moon; CI's signing jobs (pipeline.yml desktop and monoid-desktop, stable.yml)
  # only rename and sign a built app (MBUI_MAC_FROM) and have no MoonBit (main 365a364872's desktop, 44558955185):
  # there python3 reads mbui.json as tools/pack/manifest.mbt does (the variant deep-merged over the top level, the
  # same defaults, env sorted into k=v;k=v, schemes joined by commas), for the fields read below
  if [ -n "${MBUI_REAL_MOON:-}" ]; then
    meta=$("$MBUI_DIR/scripts/ui" meta "$A/mbui.json" --variant "$VARIANT" --format sh)
  else
    meta=$(python3 - "$A/mbui.json" "$VARIANT" <<'PY'
import json, shlex, sys
root = json.load(open(sys.argv[1]))
v = root.get("variants", {}).get(sys.argv[2])
if not isinstance(v, dict):
    sys.exit(1)
def merge(b, o):
    if isinstance(b, dict) and isinstance(o, dict):
        out = dict(b)
        for k, x in o.items():
            out[k] = merge(out[k], x) if k in out else x
        return out
    return o
m = merge({k: x for k, x in root.items() if k != "variants"}, v)
def obj(k):
    return m.get(k) or {}
env = m.get("env") or {}
for k, x in [
    ("MBUI_APP_ID", m.get("appId", "")),
    ("MBUI_APP_NAME", m.get("name", "")),
    ("MBUI_EXECUTABLE", m.get("executable", "")),
    ("MBUI_SCHEMES", ",".join(m.get("urlSchemes") or [])),
    ("MBUI_UPDATE_FEED", obj("updater").get("feed", "")),
    ("MBUI_ENV_KV", ";".join(f"{k}={env[k]}" for k in sorted(env))),
    ("MBUI_MAC_MIN_VERSION", obj("macos").get("minVersion", "13.0")),
    ("MBUI_WIN_INSTALL_DIR", obj("windows").get("installDir", "")),
]:
    print(f"{k}={shlex.quote(x)}")
PY
)
  fi || {
    echo "mac-app.sh: MBUI_VARIANT is preview, stable, beta, monoid or monoid-beta, not $VARIANT" >&2
    exit 1
  }
  eval "$meta"
  ID=$MBUI_APP_ID
  NAME=$MBUI_APP_NAME
  # its program: built in the Electron app's place, named as that app's is (its name): the Electron app's updater
  # (Squirrel.Mac) names the bundle it puts in place after the new one's program, and would leave the app renamed
  EXE=$MBUI_EXECUTABLE
  FEED=$MBUI_UPDATE_FEED
  ZIP_NAME=$MBUI_WIN_INSTALL_DIR
  ENV_KV=$MBUI_ENV_KV
  MAC_MIN_VERSION=$MBUI_MAC_MIN_VERSION
  OWN=
  case ";$ENV_KV;" in *";MBUI_OWN=1;"*) OWN=1 ;; esac
  SCHEMES=()
  if [ -n "$MBUI_SCHEMES" ]; then
    IFS=, read -r -a SCHEMES <<< "$MBUI_SCHEMES"
  fi
}
# sourced by mbui-meta-test.sh with MBUI_IN_MAC_APP_SH=1: load_variant alone, nothing built
if [ "${MBUI_IN_MAC_APP_SH:-}" = 1 ]; then return 0 2>/dev/null || exit 0; fi
load_variant
OUT=$A/out/mac
APPDIR="$OUT/$NAME.app"
ZIP=$OUT/$ZIP_NAME-$N-arm64-mac.zip
mkdir -p "$OUT"
t0=$(now)
export MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-$MAC_MIN_VERSION}
# what was built for another one goes (moon's and mbc's objects, the shell's .a: their keys do not hold it), and the
# Rust shell builds in a target of its own for it
if [ "$(cat _build/.macos-min 2>/dev/null)" != "$MACOSX_DEPLOYMENT_TARGET" ]; then
  rm -rf _build out/mbc out/core/aarch64-apple-darwin
  mkdir -p _build && echo "$MACOSX_DEPLOYMENT_TARGET" > _build/.macos-min
fi
export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-$A/out/core-target}-macos$MACOSX_DEPLOYMENT_TARGET

sign() {
  local t=$(now)
  # signed: still.fail's identity, else ad hoc; what it carries (Hermes's framework) first. A Developer ID's signature
  # is what notarization takes: the hardened runtime and Apple's timestamp.
  local how=(--timestamp=none)
  case "${MAC_SIGN_IDENTITY:-}" in "Developer ID Application:"*) how=(--options runtime --timestamp) ;; esac
  codesign --force --sign "${MAC_SIGN_IDENTITY:--}" "${how[@]}" "$APPDIR/Contents/Frameworks/hermes.framework"
  [ ! -d "$APPDIR/Contents/Frameworks/Squirrel.framework" ] ||
    codesign --force --sign "${MAC_SIGN_IDENTITY:--}" "${how[@]}" "$APPDIR/Contents/Frameworks/Squirrel.framework"
  # (the hardened runtime keeps the microphone from the app unless it says it takes it: a screen's 麦克风, apple_core.mm)
  local app=("${how[@]}")
  case "${MAC_SIGN_IDENTITY:-}" in "Developer ID Application:"*)
    # (plistlib writes the dotted entitlement key literally; plutil -insert splits dots into a nested key path)
    python3 -c 'import plistlib, sys
with open(sys.argv[1], "wb") as f:
    plistlib.dump({"com.apple.security.device.audio-input": True}, f)
' "$OUT/entitlements.plist"
    app+=(--entitlements "$OUT/entitlements.plist") ;;
  esac
  codesign --force --sign "${MAC_SIGN_IDENTITY:--}" "${app[@]}" "$APPDIR"
  codesign --verify --deep --strict --verbose=2 "$APPDIR" 2>&1 | sed 's/^/codesign: /'
  codesign -dvv "$APPDIR" 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier|Signature|Format)=' | sed 's/^/codesign: /'
  case "${MAC_SIGN_IDENTITY:-}" in "Developer ID Application:"*) python3 "$SF_SRC/.github/mac_signing.py" notarize "$APPDIR" --no-staple ;; esac
  spctl --assess --type execute -vv "$APPDIR" 2>&1 | sed 's/^/spctl: /' || true
  rm -f "$ZIP"
  (cd "$OUT" && ditto -c -k --sequesterRsrc --keepParent "$NAME.app" "$(basename "$ZIP")")
  echo "mac-app.sh: $(basename "$ZIP") $(wc -c < "$ZIP" | tr -d ' ') bytes, signed and zipped in $(secs $t) s"
}
if [ "${1:-build}" = sign ]; then
  [ -d "$APPDIR" ] || { echo "mac-app.sh: no app (mac-app.sh build)" >&2; exit 1; }
  sign
  exit 0
fi

case $VARIANT in beta | monoid-beta) FACE=beta ;; *) FACE=stable ;; esac
if [ -n "${MBUI_MAC_FROM:-}" ]; then
  # Another variant's app of this build, signed or not (its .app, or its zip), made this one: the program, Hermes, the
  # core's bytecode and the icon are the same bytes whichever app they are in (what a variant is, is its Info.plist,
  # its program's name and its updater's id, below), so monoid's apps are still.fail's, renamed, not built again. Its
  # face (stable or beta) has to be this one's: the icon is not made again.
  t2=$(now)
  from=$MBUI_MAC_FROM
  if [ -f "$from" ]; then
    rm -rf "$OUT/from" && mkdir -p "$OUT/from" && ditto -x -k "$from" "$OUT/from"
    from=$(find "$OUT/from" -maxdepth 1 -name '*.app' | head -1)
  fi
  [ -d "$from/Contents" ] || { echo "mac-app.sh: no app in $MBUI_MAC_FROM" >&2; exit 1; }
  their_id=$(plutil -extract CFBundleIdentifier raw "$from/Contents/Info.plist")
  their_build=$(plutil -extract CFBundleVersion raw "$from/Contents/Info.plist")
  [ "$their_build" = "$N" ] || { echo "mac-app.sh: $MBUI_MAC_FROM is build $their_build, not $N" >&2; exit 1; }
  case $their_id in *.beta) their_face=beta ;; *) their_face=stable ;; esac
  [ "$their_face" = "$FACE" ] || { echo "mac-app.sh: $MBUI_MAC_FROM ($their_id) has the $their_face face, not $FACE" >&2; exit 1; }
  rm -rf "$APPDIR" "$ZIP"
  ditto "$from" "$APPDIR"
  rm -rf "$OUT/from" "$APPDIR/Contents/_CodeSignature"
  their_exe=$(plutil -extract CFBundleExecutable raw "$APPDIR/Contents/Info.plist")
  [ "$their_exe" = "$EXE" ] || mv "$APPDIR/Contents/MacOS/$their_exe" "$APPDIR/Contents/MacOS/$EXE"
  BIN=$APPDIR/Contents/MacOS/$EXE
  SQUIRREL=$APPDIR/Contents/Frameworks/Squirrel.framework
  if [ -n "$OWN" ] && [ -d "$SQUIRREL" ]; then
    plutil -replace CFBundleIdentifier -string "$ID.shipit" "$SQUIRREL/Versions/A/Resources/Info.plist"
  else
    [ -z "$OWN" ] || { echo "mac-app.sh: $MBUI_MAC_FROM has no updater (Squirrel.framework)" >&2; exit 1; }
    rm -rf "$SQUIRREL"
  fi
  echo "mac-app.sh: $NAME.app from $their_id's ($(basename "$MBUI_MAC_FROM"))"
else
  # the app with the core's parts: its Rust shell and its engine (linked in), Hermes and its bytecode (carried), which
  # scripts/mac.sh makes (the bytecode beside the app's compile). (Not `core.sh shell` first when the .a was missing, as
  # before: that built the shell with cargo, past its prebuilt part, on every CI run whose Actions cache of out/core
  # missed: 253 s of 427, 2026-10-24, 40069429045.)
  BIN=$A/_build/native/release/build/stillfail/stillfail/stillfail.exe
  # (MBUI_BUILT: the app and core.hbc this job's build made just before, CI's desktop-build's prebuild, checked there as
  # here: taken as they are, mac.sh's 12-20 s of finding them up to date cut a build done at the job's five minutes,
  # 133850663609, 2026-11-17)
  if [ "${MBUI_BUILT:-}" = 1 ] && [ -f "$BIN" ] && [ -f "$A/out/core/core.hbc" ]; then
    echo "mac-app.sh: the app and core.hbc as this job's build made them (MBUI_BUILT), not built again"
  else
    APP=stillfail MODE=release bash "$D/mac.sh" build > "$OUT/build.log" 2>&1 || { tail -40 "$OUT/build.log"; exit 1; }
    if grep -q 'built for newer macOS version' "$OUT/build.log"; then
      grep 'built for newer macOS version' "$OUT/build.log" | head -5 >&2
      echo "mac-app.sh: something was built for a newer macOS than $MACOSX_DEPLOYMENT_TARGET" >&2; exit 1
    fi
    # (where the build's time went, said: mbc's account of the app's units and its link, the core's parts; the log
    # itself kept only for a failure, and the app's 73 s of a release's 185 s Mac job could not be told apart, 2026-10-31)
    grep -E '^mbc: |^mac\.sh: |^core\.sh|hermes|^real|took|in [0-9.]+ s' "$OUT/build.log" | cut -c1-220 | head -20 || true
  fi
  t2=$(now)

  # the icon, the app's own (still.fail's face; youdid.wtf's under its tape; still.fail preview's still.fail's), made once
  # for each version of its script: an Icon Composer document whose tile and face are each appearance's own (the black
  # face, the white one on a dark system), compiled by actool into the app's Assets.car, which macOS 26 draws as the
  # system's appearance is, the app open or not; and the black face's .icns for the macOS before (CFBundleIconFile).
  # actool knows .icon from Xcode 26: the newest Xcode's that does, whichever is selected.
  ICON=$OUT/AppIcon-$(shasum -a 256 "$D/mac-icon.swift" | cut -c1-12)-$FACE
  [ -f "$ICON.icns" ] || swift "$D/mac-icon.swift" "$FACE" "$ICON.icns" > /dev/null
  if [ ! -f "$ICON.assets/Assets.car" ]; then
    ACTOOL=
    for dev in "$(xcode-select -p)" $(ls -d /Applications/Xcode*.app/Contents/Developer 2>/dev/null | sort -rV); do
      v=$(DEVELOPER_DIR=$dev xcrun actool --version 2>/dev/null | awk -F'[<>.]' '/short-bundle-version/ { getline; print $3 }') || true
      if [ "${v:-0}" -ge 26 ] 2>/dev/null; then ACTOOL=$dev; break; fi
    done
    [ -n "$ACTOOL" ] || { echo "mac-app.sh: no Xcode 26 or later's actool here, to compile the app's icon" >&2; exit 1; }
    # (the document named as the icon it is: actool compiles nothing for a name it is not)
    rm -rf "$ICON.assets" && mkdir -p "$ICON.assets"
    swift "$D/mac-icon.swift" --icon "$FACE" "$ICON.assets/AppIcon.icon" > /dev/null
    DEVELOPER_DIR=$ACTOOL xcrun actool "$ICON.assets/AppIcon.icon" --compile "$ICON.assets" --app-icon AppIcon --platform macosx \
      --target-device mac --minimum-deployment-target "$MACOSX_DEPLOYMENT_TARGET" \
      --output-partial-info-plist "$ICON.assets/partial.plist" > "$ICON.assets/actool.log" 2>&1 \
      && [ -f "$ICON.assets/Assets.car" ] || { cat "$ICON.assets/actool.log" >&2; rm -rf "$ICON.assets"; exit 1; }
  fi

  rm -rf "$APPDIR" "$ZIP"
  mkdir -p "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources" "$APPDIR/Contents/Frameworks"
  cp "$BIN" "$APPDIR/Contents/MacOS/$EXE"
  # Only the copies in the app are trimmed, before signing: the build keeps its symbols for diagnostics.
  strip -S -x "$APPDIR/Contents/MacOS/$EXE"
  # Hermes from the app's Frameworks (@executable_path/../Frameworks), not from the build's tree (the other rpath, gone)
  install_name_tool -delete_rpath @executable_path/../../../../../../out/core/hermes/Library/Frameworks/macosx "$APPDIR/Contents/MacOS/$EXE"
  ditto out/core/hermes/Library/Frameworks/macosx/hermes.framework "$APPDIR/Contents/Frameworks/hermes.framework"
  # The app is arm64 only; the upstream framework also carries x86_64. Keep its versioned layout and exported symbols.
  HERMES=$APPDIR/Contents/Frameworks/hermes.framework/Versions/Current/hermes
  if [ "$(lipo -archs "$HERMES")" != arm64 ]; then
    lipo "$HERMES" -thin arm64 -output "$HERMES.arm64"
    mv "$HERMES.arm64" "$HERMES"
  fi
  strip -S -x "$HERMES"
  # Built in the Electron app's place: what that app's updater runs out of the app it has put in place to open it
  # (src/host/shipit.c), where it runs it: Frameworks/Squirrel.framework/Resources/ShipIt, here the framework's program
  SQUIRREL=$APPDIR/Contents/Frameworks/Squirrel.framework
  if [ -n "$OWN" ]; then
    mkdir -p "$SQUIRREL/Versions/A/Resources"
    clang -O2 -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" -o "$SQUIRREL/Versions/A/Squirrel" src/host/shipit.c
    ln -s ../Squirrel "$SQUIRREL/Versions/A/Resources/ShipIt"
    # (written in one go, as the app's below)
    python3 -c 'import plistlib, sys; id, n, out = sys.argv[1:]
plistlib.dump({"CFBundleIdentifier": id + ".shipit", "CFBundleExecutable": "Squirrel", "CFBundleName": "Squirrel",
  "CFBundlePackageType": "FMWK", "CFBundleInfoDictionaryVersion": "6.0", "CFBundleShortVersionString": "0.1." + n,
  "CFBundleVersion": n}, open(out, "wb"), fmt=plistlib.FMT_XML)' "$ID" "$N" "$SQUIRREL/Versions/A/Resources/Info.plist"
    ln -s A "$SQUIRREL/Versions/Current"
    ln -s Versions/Current/Squirrel "$SQUIRREL/Squirrel"
    ln -s Versions/Current/Resources "$SQUIRREL/Resources"
  fi
  cp out/core/core.hbc "$APPDIR/Contents/Resources/core.hbc"
  cp "$ICON.icns" "$APPDIR/Contents/Resources/AppIcon.icns"
  cp "$ICON.assets/Assets.car" "$APPDIR/Contents/Resources/Assets.car"
fi
# the oldest macOS the program runs on, as it was linked: the one asked for
# (awk reads otool's output to its end: one that stopped at the first minos left otool writing into a closed pipe,
# which pipefail took for a failure now and then: main 199e1d03 and 40c02d09's desktop, 41408771483, 2026-11-02)
MINOS=$(otool -l "$BIN" | awk '/LC_BUILD_VERSION/ { b = 1 } b && $1 == "minos" && m == "" { m = $2 } END { print m }')
[ "$MINOS" = "$MACOSX_DEPLOYMENT_TARGET" ] || { echo "mac-app.sh: linked for macOS $MINOS, not $MACOSX_DEPLOYMENT_TARGET" >&2; exit 1; }
PLIST=$APPDIR/Contents/Info.plist
# The updater replaces an installed bundle in place, preserving its old filename and its Dock links. Finder uses the
# localized display name only when the unlocalized one matches that filename. Keep the old name in the plist solely
# for that match; both newly downloaded and existing bundles display the new name in every supported localization.
if [ "$VARIANT" = mbui ]; then
  DISPLAY="still.fail mbui"
  for locale in en zh-Hans zh_CN; do
    mkdir -p "$APPDIR/Contents/Resources/$locale.lproj"
    printf '"CFBundleName" = "%s";\n"CFBundleDisplayName" = "%s";\n' "$NAME" "$NAME" \
      > "$APPDIR/Contents/Resources/$locale.lproj/InfoPlist.strings"
  done
else
  DISPLAY=$NAME
fi
# PostHog's project its window thread's hangs and the errors it got past go to (src/host/apple_reports.m), as iOS's
# (ios-core.sh) and Android's: the file STILLFAIL_POSTHOG names ({host, key}: .github/release-desktop.sh writes it from
# POSTHOG_JSON); still.fail's own app alone. Without it the app sends nothing and shows no switch for it.
ph_host= ph_key=
if [ -n "${STILLFAIL_POSTHOG:-}" ] && [ -n "$OWN" ]; then
  ph_host=$(plutil -extract host raw -o - "$STILLFAIL_POSTHOG") && ph_key=$(plutil -extract key raw -o - "$STILLFAIL_POSTHOG") \
    && [ -n "$ph_key" ] || { echo "mac-app.sh: no PostHog key in $STILLFAIL_POSTHOG" >&2; exit 1; }
fi
# The Info.plist written in one go: plutil's 30-odd inserts, each its own process reading and writing the file, were
# 2-3 s of the Mac app's job.
rm -f "$PLIST"
ID=$ID NAME=$NAME DISPLAY=$DISPLAY EXE=$EXE N=$N MINOS=$MINOS FEED=$FEED ENV_KV=$ENV_KV \
  PH_HOST=$ph_host PH_KEY=$ph_key python3 - "$PLIST" "${SCHEMES[@]}" <<'PY'
import os, plistlib, sys
e = os.environ
p = {
    "CFBundleIdentifier": e["ID"],
    "CFBundleName": e["NAME"],
    "CFBundleDisplayName": e["DISPLAY"],
    "CFBundleExecutable": e["EXE"],
    "CFBundleIconFile": "AppIcon",
    "CFBundleIconName": "AppIcon",
    "CFBundlePackageType": "APPL",
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleShortVersionString": "0.1." + e["N"],
    "CFBundleVersion": e["N"],
    "CFBundleDevelopmentRegion": "zh_CN",
    "LSMinimumSystemVersion": e["MINOS"] or "13.0",
    "LSApplicationCategoryType": "public.app-category.developer-tools",
    "NSPrincipalClass": "NSApplication",
    "NSHighResolutionCapable": True,
    "NSSupportsAutomaticGraphicsSwitching": True,
    # the core reaches stations on the local network directly when it can (as still.fail's desktop app says it)
    "NSLocalNetworkUsageDescription": e["NAME"] + " connects straight to your stations on the local network when it can.",
    # a remote screen's 麦克风: this Mac's microphone shared into the screen's virtual one while an app there records it
    # (src/host/apple_core.mm; without it the system ends an app that opens the microphone)
    "NSMicrophoneUsageDescription": e["NAME"] + " shares your microphone with a remote screen you control, only while an app there is recording and you turned it on.",
}
# where its newer builds come from (src/stillfail main: MBUI_UPDATE_FEED; the host installs them: mac_app.m Updates),
# the feed beta.sh mac publishes; built in still.fail's desktop app's place, still.fail's own (the device named as that
# app named it: src/sfcore/signin.mbt MBUI_OWN), a core on the test channel a beta's (MBUI_BETA); monoid's cloud,
# product and station label from apps/mbui/mbui.json (ENV_KV). The system gives these to the app opened from the
# Finder, the Dock or `open`.
env = p["LSEnvironment"] = {"MBUI_UPDATE_FEED": e["FEED"]}
for item in e.get("ENV_KV", "").split(";"):
    if "=" in item:
        k, v = item.split("=", 1)
        if k != "MBUI_STATION_NAME":
            env[k] = v
if e["PH_KEY"]:
    p["StillfailPosthogHost"] = e["PH_HOST"]
    p["StillfailPosthogKey"] = e["PH_KEY"]
# the links that open it (stillfail://o/…, as still.fail's desktop app takes them: mac_app.m, then sfapp's links)
if sys.argv[2:]:
    p["CFBundleURLTypes"] = [{"CFBundleURLName": e["NAME"], "CFBundleURLSchemes": sys.argv[2:]}]
with open(sys.argv[1], "wb") as f:
    plistlib.dump(p, f, fmt=plistlib.FMT_XML)
PY
plutil -lint "$PLIST" > /dev/null

# A standalone build can be opened ad hoc. beta.sh immediately runs `sign` on its release bundle: do not first
# sign the same frameworks and app ad hoc only to replace those signatures there.
if [ "${MBUI_SIGN_AFTER_BUILD:-}" != 1 ]; then
  codesign --force --sign - --timestamp=none "$APPDIR/Contents/Frameworks/hermes.framework"
  [ -z "$OWN" ] || codesign --force --sign - --timestamp=none "$SQUIRREL"
  codesign --force --sign - --timestamp=none "$APPDIR"
fi
echo "mac-app.sh: $NAME.app 0.1.$N in $(secs $t0) s: the app and the core's parts $(python3 -c "print(f'{$t2-$t0:.1f}')") s," \
  "the bundle $(secs $t2) s"
[ "${1:-}" = build ] || sign
