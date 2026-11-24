#!/bin/bash
# Deterministic contract test for apps/mbui/mbui.json across all 5 release variants
# (preview, stable, beta, monoid, monoid-beta) and invalid variant handling.
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
. "$D/env.sh"

MANIFEST="$A/mbui.json"
MBUI="$MBUI_DIR/scripts/ui"

fail() {
  echo "mbui-meta-test.sh: FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local label=$1 got=$2 want=$3
  if [ "$got" != "$want" ]; then
    fail "$label: got '$got', want '$want'"
  fi
}

check_variant() {
  local v=$1
  local want_id=$2
  local want_name=$3
  local want_exe=$4
  local want_schemes=$5
  local want_dir=$6
  local want_feed=$7
  local want_env_kv=$8

  "$MBUI" check "$MANIFEST" --variant "$v" > /dev/null || fail "mbui check --variant $v failed"

  local meta
  meta=$("$MBUI" meta "$MANIFEST" --variant "$v" --format sh) || fail "mbui meta --variant $v failed"

  local MBUI_APP_ID MBUI_APP_NAME MBUI_EXECUTABLE MBUI_VERSION MBUI_BUILD MBUI_VARIANT \
    MBUI_RUNTIME MBUI_MODULE_DIR MBUI_ENTRY MBUI_SCHEMES MBUI_UPDATE_FEED MBUI_UPDATE_CHANNEL \
    MBUI_ENV_KV MBUI_MAC_MIN_VERSION MBUI_WIN_INSTALL_DIR MBUI_WIN_COMPANY
  eval "$meta"

  assert_eq "$v.MBUI_APP_ID" "$MBUI_APP_ID" "$want_id"
  assert_eq "$v.MBUI_APP_NAME" "$MBUI_APP_NAME" "$want_name"
  assert_eq "$v.MBUI_EXECUTABLE" "$MBUI_EXECUTABLE" "$want_exe"
  assert_eq "$v.MBUI_SCHEMES" "$MBUI_SCHEMES" "$want_schemes"
  assert_eq "$v.MBUI_WIN_INSTALL_DIR" "$MBUI_WIN_INSTALL_DIR" "$want_dir"
  assert_eq "$v.MBUI_WIN_COMPANY" "$MBUI_WIN_COMPANY" "AFK AI, Inc."
  assert_eq "$v.MBUI_MAC_MIN_VERSION" "$MBUI_MAC_MIN_VERSION" "12.0"
  assert_eq "$v.MBUI_UPDATE_FEED" "$MBUI_UPDATE_FEED" "$want_feed"
  assert_eq "$v.MBUI_ENV_KV" "$MBUI_ENV_KV" "$want_env_kv"
  assert_eq "$v.MBUI_ENTRY" "$MBUI_ENTRY" "src/stillfail"
  assert_eq "$v.MBUI_RUNTIME" "$MBUI_RUNTIME" "native"
  echo "ok: variant $v"
}

check_variant preview \
  "fail.still.mbui" \
  "still.fail preview" \
  "stillfail-mbui" \
  "" \
  "stillfail-mbui" \
  "mac/mbui" \
  "MBUI_BETA=1"

check_variant stable \
  "fail.still.desktop" \
  "still.fail" \
  "still.fail" \
  "stillfail" \
  "stillfail" \
  "mac" \
  "MBUI_OWN=1"

check_variant beta \
  "fail.still.desktop.beta" \
  "youdid.wtf" \
  "youdid.wtf" \
  "stillfail-beta,stillfail" \
  "stillfail-beta" \
  "mac" \
  "MBUI_BETA=1;MBUI_OWN=1"

check_variant monoid \
  "build.monoid.desktop" \
  "monoid" \
  "monoid" \
  "monoid" \
  "monoid" \
  "mac" \
  "MBUI_CLOUD=https://app.monoid.build;MBUI_OWN=1;MBUI_PRODUCT=monoid;MBUI_STATION_ID=monoid;MBUI_STATION_LABEL=build.monoid.station;MBUI_STATION_NAME=monoid"

check_variant monoid-beta \
  "build.monoid.desktop.beta" \
  "monoid.zone" \
  "monoid.zone" \
  "monoid-beta,monoid" \
  "monoid-beta" \
  "mac" \
  "MBUI_BETA=1;MBUI_CLOUD=https://app.monoid.build;MBUI_OWN=1;MBUI_PRODUCT=monoid;MBUI_STATION_ID=monoid;MBUI_STATION_LABEL=build.monoid.station;MBUI_STATION_NAME=monoid"

# Verify invalid variant fails non-zero
if "$MBUI" check "$MANIFEST" --variant bogus > /dev/null 2>&1; then
  fail "mbui check --variant bogus unexpectedly succeeded"
fi
if "$MBUI" meta "$MANIFEST" --variant bogus --format sh > /dev/null 2>&1; then
  fail "mbui meta --variant bogus unexpectedly succeeded"
fi
echo "ok: invalid variant rejected"

# Verify bash syntax of mac-app.sh and win.sh
bash -n "$A/scripts/mac-app.sh" "$A/scripts/win.sh" || fail "bash -n failed"
echo "ok: bash -n mac-app.sh win.sh"

# Verify win.sh variant() directly (including preview exe=stillfail, win feed rewrite,
# MBUI_STATION_LABEL omission, bogus rejection, and MBUI_BUILD preservation)
(
  export MBUI_IN_WIN_SH=1
  export MBUI_BUILD=9999
  # shellcheck source=/dev/null
  . "$A/scripts/win.sh"

  check_win_variant() {
    local v=$1 want_id=$2 want_name=$3 want_exe=$4 want_dir=$5 want_schemes=$6 want_extra=$7
    local id name exe dir company schemes extra
    MBUI_VARIANT=$v variant || fail "win.sh variant $v failed"
    assert_eq "win.$v.id" "$id" "$want_id"
    assert_eq "win.$v.name" "$name" "$want_name"
    assert_eq "win.$v.exe" "$exe" "$want_exe"
    assert_eq "win.$v.dir" "$dir" "$want_dir"
    assert_eq "win.$v.company" "$company" "AFK AI, Inc."
    assert_eq "win.$v.schemes" "$schemes" "$want_schemes"
    assert_eq "win.$v.extra" "$extra" "$want_extra"
    assert_eq "win.$v.MBUI_BUILD" "$MBUI_BUILD" "9999"
  }

  check_win_variant preview "fail.still.mbui" "still.fail preview" "stillfail" "stillfail-mbui" "" \
    $'MBUI_UPDATE_FEED=win/mbui\nMBUI_BETA=1'
  check_win_variant stable "fail.still.desktop" "still.fail" "still.fail" "stillfail" "stillfail" \
    $'MBUI_UPDATE_FEED=win\nMBUI_OWN=1'
  check_win_variant beta "fail.still.desktop.beta" "youdid.wtf" "youdid.wtf" "stillfail-beta" "stillfail-beta,stillfail" \
    $'MBUI_UPDATE_FEED=win\nMBUI_BETA=1\nMBUI_OWN=1'
  check_win_variant monoid "build.monoid.desktop" "monoid" "monoid" "monoid" "monoid" \
    $'MBUI_UPDATE_FEED=win\nMBUI_CLOUD=https://app.monoid.build\nMBUI_OWN=1\nMBUI_PRODUCT=monoid\nMBUI_STATION_ID=monoid\nMBUI_STATION_NAME=monoid'
  check_win_variant monoid-beta "build.monoid.desktop.beta" "monoid.zone" "monoid.zone" "monoid-beta" "monoid-beta,monoid" \
    $'MBUI_UPDATE_FEED=win\nMBUI_BETA=1\nMBUI_CLOUD=https://app.monoid.build\nMBUI_OWN=1\nMBUI_PRODUCT=monoid\nMBUI_STATION_ID=monoid\nMBUI_STATION_NAME=monoid'

  if MBUI_VARIANT=bogus variant 2>/dev/null; then
    fail "win.sh variant bogus unexpectedly succeeded"
  fi
)
echo "ok: win.sh variant() contract"

# Verify mac-app.sh load_variant() without MoonBit (CI's signing jobs have none: it reads mbui.json with python3)
# gives what it gives through mbui meta, for every variant, and rejects an unknown one
mac_variant() { # $1 variant, $2 "nomoon" to take MoonBit away
  (
    if [ "${2:-}" = nomoon ]; then
      unset MBUI_REAL_MOON MOON_HOME
      export MBUI_TOOLS=/nonexistent
      local p= dir
      IFS=: read -r -a dirs <<< "$PATH"
      for dir in "${dirs[@]}"; do
        [ -x "$dir/moon" ] || p=${p:+$p:}$dir
      done
      export PATH=$p
    fi
    export MBUI_IN_MAC_APP_SH=1 MBUI_VARIANT=$1
    # shellcheck source=/dev/null
    . "$A/scripts/mac-app.sh" > /dev/null 2>&1
    if [ "${2:-}" = nomoon ] && [ -n "${MBUI_REAL_MOON:-}" ]; then
      echo "MoonBit still found: $MBUI_REAL_MOON" >&2
      exit 1
    fi
    load_variant
    printf '%s\n' "ID=$ID" "NAME=$NAME" "EXE=$EXE" "FEED=$FEED" "ZIP_NAME=$ZIP_NAME" "ENV_KV=$ENV_KV" \
      "MAC_MIN_VERSION=$MAC_MIN_VERSION" "OWN=$OWN" "SCHEMES=${SCHEMES[*]:-}"
  )
}
for v in preview stable beta monoid monoid-beta; do
  with=$(mac_variant "$v") || fail "mac-app.sh load_variant $v (with moon) failed"
  without=$(mac_variant "$v" nomoon) || fail "mac-app.sh load_variant $v (without moon) failed"
  assert_eq "mac.$v" "$without" "$with"
  echo "ok: mac-app.sh load_variant $v without moon"
done
if mac_variant bogus nomoon > /dev/null 2>&1; then
  fail "mac-app.sh load_variant bogus (without moon) unexpectedly succeeded"
fi
echo "ok: mac-app.sh load_variant without moon rejects bogus"

echo "mbui-meta-test.sh: all checks passed"
